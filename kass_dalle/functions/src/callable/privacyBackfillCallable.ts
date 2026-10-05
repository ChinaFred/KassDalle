/**
 * Rattrapage de la confidentialité des recettes.
 *
 * Le champ `is_private` vient d'apparaître sur `recipes`. Les documents écrits
 * avant ne le portent pas, et une absence n'est pas un `false` : Firestore
 * exclut d'un `where("is_private", "==", false)` tout document où le champ
 * manque. Sans cette passe, la recherche familiale et le planning familial
 * cesseraient de voir l'intégralité du fonds existant — l'inverse exact du
 * défaut qu'on corrige.
 *
 * Elle pose donc la valeur sur TOUTES les recettes, pas seulement sur celles
 * des livres privés : `false` explicite pour les autres.
 *
 * Chaque écriture réveille `onRecipeWritten`. Ce réveil est court et sans
 * appel d'IA — la synchro constate l'accord, et la garde d'empreinte sort
 * aussitôt puisque `is_private` ne figure pas parmi ses entrées. C'est le prix
 * assumé d'une reprise qui passe par le même chemin que le reste.
 *
 * À usage unique, mais réentrante : une recette déjà correcte n'est pas
 * réécrite, et le curseur permet de reprendre où l'appel précédent s'est
 * arrêté — un backfill qui repart du début à chaque appel ne finit jamais.
 *
 * Restée invocable par personne jusqu'au 5 octobre 2026 : sa politique IAM
 * Cloud Run n'accordait `run.invoker` à aucun compte, alors que toute
 * fonction `onCall` sœur l'accorde à `allUsers` (l'autorisation réelle reste
 * `requireAdmin`, à l'intérieur). Le premier appel échouait donc en pur
 * réseau — « Failed to fetch » côté client, un `403` de zéro seconde sur la
 * requête `OPTIONS`, avant même d'atteindre ce fichier. Comme son code n'avait
 * jamais changé depuis sa création, chaque déploiement la sautait
 * (« Skipped — No changes detected ») et ne reconciliait jamais cette
 * politique. Ce commentaire est le changement qui force la reconciliation.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import { COLL_BOOKS, COLL_RECIPES, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logInfo } from "../logging";
import { bookIdOf } from "../triggers/recipePrivacy";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin } from "./_auth";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

/** Où l'on retient la dernière recette examinée. */
export const RECIPE_PRIVACY_CHECKPOINT_DOC_ID = "recipe_privacy_backfill_checkpoint";

/** Recettes lues par page. Firestore accepte 500 écritures par batch. */
const PAGE_SIZE = 400;

/** Marge gardée sur le délai de la fonction, pour écrire le curseur avant la fin. */
const DEADLINE_MARGIN_MS = 45_000;

interface BackfillPrivacyRequest {
  maxMinutes?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
}

interface BackfillPrivacyResponse {
  examinees: number;
  corrigees: number;
  passeesEnPrive: number;
  livresPrives: number;
  collectionParcourue: boolean;
  stoppedByDeadline: boolean;
}

export const backfillRecipePrivacyFn = onCall<BackfillPrivacyRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: "512MiB",
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req): Promise<BackfillPrivacyResponse> => {
    const ctx = await requireAdmin(req, "backfill_recipe_privacy");
    const db = getFirestore();

    const maxMinutes = Math.min(Math.max(Number(req.data?.maxMinutes) || 8, 1), 8);
    const deadline = Date.now() + maxMinutes * 60_000 - DEADLINE_MARGIN_MS;

    const resumeFromCheckpoint = parseBoolean(req.data?.resumeFromCheckpoint, true);
    const resetCheckpoint = parseBoolean(req.data?.resetCheckpoint, false);
    let cursor = await getBackfillCursor({
      db,
      docId: RECIPE_PRIVACY_CHECKPOINT_DOC_ID,
      resumeFromCheckpoint,
      resetCheckpoint,
    });

    // Les livres privés tiennent en mémoire : il y en a un par utilisateur au
    // départ — le livre « Mes Recettes Secrètes » — et quelques-uns ensuite.
    // Les charger une fois évite une lecture de livre par recette examinée.
    const privateBooks = await db.collection(COLL_BOOKS).where("is_private", "==", true).get();
    const privateBookIds = new Set(privateBooks.docs.map((doc) => doc.id));

    let examinees = 0;
    let corrigees = 0;
    let passeesEnPrive = 0;
    let collectionParcourue = false;
    let stoppedByDeadline = false;

    for (;;) {
      if (Date.now() > deadline) {
        stoppedByDeadline = true;
        break;
      }

      let query = db.collection(COLL_RECIPES).orderBy("__name__").limit(PAGE_SIZE);
      if (cursor) query = query.startAfter(cursor);
      const page = await query.get();
      if (page.empty) {
        collectionParcourue = true;
        break;
      }

      const batch = db.batch();
      let pending = 0;
      for (const doc of page.docs) {
        examinees += 1;
        const data = doc.data() as Record<string, unknown>;
        const expected = privateBookIds.has(bookIdOf(data) ?? "");
        if (data.is_private === expected) continue;
        batch.update(doc.ref, { is_private: expected });
        pending += 1;
        if (expected) passeesEnPrive += 1;
      }
      if (pending > 0) {
        await batch.commit();
        corrigees += pending;
      }

      cursor = page.docs[page.docs.length - 1].id;
      await setBackfillCursor({
        db,
        docId: RECIPE_PRIVACY_CHECKPOINT_DOC_ID,
        lastDocId: cursor,
        operation: "backfill_recipe_privacy",
        adminUid: ctx.userId,
      });

      if (page.size < PAGE_SIZE) {
        collectionParcourue = true;
        break;
      }
    }

    // Le curseur revient au début quand tout est passé : un rappel de la
    // fonction reprendrait sinon une collection déjà traitée en entier.
    if (collectionParcourue) {
      await setBackfillCursor({
        db,
        docId: RECIPE_PRIVACY_CHECKPOINT_DOC_ID,
        lastDocId: null,
        operation: "backfill_recipe_privacy",
        adminUid: ctx.userId,
      });
    }

    await logInfo({
      message: "Rattrapage de la confidentialité des recettes",
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      feature: "backfill_recipe_privacy",
      extra: {
        examinees,
        corrigees,
        passeesEnPrive,
        livresPrives: privateBookIds.size,
        collectionParcourue,
        stoppedByDeadline,
      },
    });

    return {
      examinees,
      corrigees,
      passeesEnPrive,
      livresPrives: privateBookIds.size,
      collectionParcourue,
      stoppedByDeadline,
    };
  },
);
