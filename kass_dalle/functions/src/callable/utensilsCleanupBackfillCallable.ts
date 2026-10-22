/**
 * Ustensiles — retire des recettes existantes les ustensiles écrits comme
 * ingrédients, puis supprime leurs fiches du référentiel nutrition. Aucun
 * appel de modèle.
 *
 * Entre v0.21.31 et v0.24.56, le balisage pouvait écrire « @papier
 * sulfurisé{} » : le nom entrait dans `ingredients`, dans `ingredients_index`,
 * puis dans le référentiel (`nutrition_ingredients/papier_sulfurise`). Depuis
 * v0.24.57, la liste fermée `nutrition/utensils.ts` l'empêche pour les
 * nouvelles recettes. Ce backfill reprend les anciennes.
 *
 * Deux phases :
 *  1. Recettes : `@nom{…}` devient `#nom{…}` dans `raw_cooklang` et
 *     `draft_cooklang`, et les ustensiles sortent de `ingredients` et de
 *     `ingredients_index`. Un nom reconnu qui porte une parenthèse
 *     (« caissettes (ou beurre) ») n'est pas touché : la parenthèse peut citer
 *     un aliment, et la recette part dans « à revoir » (`isUtensilLine`, même
 *     prudence que le contrôle de fidélité). L'écriture est conditionnée à la
 *     version lue : une recette modifiée entre-temps n'est pas écrasée, elle
 *     est reprise au passage suivant. L'écriture réveille `onRecipeWritten`,
 *     qui recalcule nutrition, courses et allergènes comme après toute
 *     modification d'ingrédients — ce recalcul peut appeler un modèle, sur le
 *     plafond du propriétaire de la recette.
 *  2. Fiches : une fois toutes les recettes parcourues, une fiche dont
 *     l'identifiant ou le nom canonique est un ustensile est supprimée, si
 *     plus aucune recette ne la cite dans `ingredients_index`. Une fiche
 *     encore citée reste, et part dans la liste « à revoir ».
 *
 * Essai à blanc (`dryRun`) : rien n'est écrit ni supprimé ; chaque recette et
 * chaque fiche qui seraient corrigées partent dans la liste « à revoir », avec
 * ce qui changerait. Son curseur est distinct de celui du passage réel.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import {
  COLL_NUTRITION_INGREDIENTS,
  COLL_RECIPES,
  MAX_CALLABLE_INSTANCES,
  REGION,
} from "../config";
import { logError, logInfo } from "../logging";
import { buildIngredientsIndex } from "../cooklang/parser";
import { isUtensil, isUtensilLine } from "../nutrition/utensils";
import type { StoredIngredient } from "../triggers/recipeIngredients";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin, type AuthContext } from "./_auth";
import { runBackfillFromCallable } from "../backfills/runner";
import type { PassSummary } from "../backfills/schedule";
import {
  BackfillReview,
  namesList,
  recipeReviewLabel,
  shortErrorMessage,
  type BackfillReviewList,
  withoutReviewList,
} from "./_backfillReview";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

/** Où le passage réel retient la dernière recette examinée. */
export const UTENSILS_CLEANUP_CHECKPOINT_DOC_ID = "utensils_cleanup_backfill_checkpoint";
/** Curseur de l'essai à blanc : il ne déplace jamais celui du passage réel. */
export const UTENSILS_CLEANUP_DRY_RUN_CHECKPOINT_DOC_ID =
  "utensils_cleanup_dry_run_backfill_checkpoint";

const FEATURE = "utensils_cleanup_backfill";

/** Recettes examinées par appel, par défaut. */
const DEFAULT_MAX_RECIPES = 2000;
const PAGE_SIZE = 200;
/** Marge gardée sur le délai de la fonction, pour écrire le curseur avant la fin. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois recettes difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;
/** Plafond de valeurs d'un `array-contains-any` Firestore. */
const MAX_USAGE_VALUES = 30;

interface UtensilsCleanupRequest {
  dryRun?: boolean;
  maxMinutes?: number;
  maxDocs?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export interface UtensilsCleanupResponse {
  essaiABlanc: boolean;
  examinees: number;
  /** Recettes réécrites (ou qui le seraient, à blanc). */
  corrigees: number;
  /** Rien à changer. */
  dejaPropres: number;
  echouees: number;
  /** Modifiées entre la lecture et l'écriture : laissées telles quelles, reprises au passage suivant. */
  aReprendre: number;
  /** Un ustensile avec parenthèse : non touchées, à revoir à la main. */
  aRevoirALaMain: number;
  /** Fiches du référentiel dont le nom est un ustensile. */
  fichesTrouvees: number;
  /** Fiches supprimées (ou qui le seraient, à blanc). */
  fichesSupprimees: number;
  /** Fiches laissées : une recette les cite encore. */
  fichesEncoreCitees: number;
  fichesEchouees: number;
  /** Toutes les recettes ont été parcourues : le curseur revient au début. */
  recettesParcourues: boolean;
  /** La phase des fiches a eu lieu en entier. */
  fichesParcourues: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  completed: boolean;
  aRevoir: BackfillReviewList;
}

function emptyResponse(dryRun: boolean): UtensilsCleanupResponse {
  return {
    essaiABlanc: dryRun,
    examinees: 0,
    corrigees: 0,
    dejaPropres: 0,
    echouees: 0,
    aReprendre: 0,
    aRevoirALaMain: 0,
    fichesTrouvees: 0,
    fichesSupprimees: 0,
    fichesEncoreCitees: 0,
    fichesEchouees: 0,
    recettesParcourues: false,
    fichesParcourues: false,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: false,
    aRevoir: { items: [], total: 0 },
  };
}

/** Ce qu'une recette deviendrait, et les ustensiles retirés. */
export interface RecipeCleanup {
  /** Champs à écrire ; vide quand la recette est déjà propre. */
  patch: Record<string, unknown>;
  /** Noms des ustensiles retirés, sans doublon, dans l'ordre rencontré. */
  removed: string[];
  /**
   * Noms reconnus comme ustensiles mais qui portent une parenthèse : laissés
   * en place, à revoir à la main.
   */
  withParentheses: string[];
}

/**
 * Un nom à retirer : un ustensile sans parenthèse. `isUtensil` ignore les
 * parenthèses ; « caissettes (ou beurre) » cite pourtant un aliment.
 */
function removable(name: string): boolean {
  return isUtensilLine(name);
}

/** Ustensile reconnu, mais avec une parenthèse : on n'y touche pas. */
function utensilWithParentheses(name: string): boolean {
  return /[()]/.test(name) && isUtensil(name);
}

/**
 * Le nettoyage d'une recette, sans rien écrire : pure, testée seule.
 *
 * Un champ absent ou d'un autre type n'est pas touché.
 */
export function cleanupRecipe(data: Record<string, unknown>): RecipeCleanup {
  const patch: Record<string, unknown> = {};
  const removed: string[] = [];
  const withParentheses: string[] = [];
  const note = (list: string[], name: string) => {
    const clean = name.trim();
    if (clean && !list.some((r) => r.toLowerCase() === clean.toLowerCase())) list.push(clean);
  };
  const check = (name: string): boolean => {
    if (removable(name)) {
      note(removed, name);
      return true;
    }
    if (utensilWithParentheses(name)) note(withParentheses, name);
    return false;
  };

  for (const field of ["raw_cooklang", "draft_cooklang"] as const) {
    const text = data[field];
    if (typeof text !== "string") continue;
    // Même motif que `retagUtensils`, avec la règle plus stricte de `removable`.
    const retagged = text.replace(
      /@([^{@#~\n]+)\{([^}]*)\}/g,
      (match, name: string, inner: string) => (check(name.trim()) ? `#${name}{${inner}}` : match),
    );
    if (retagged !== text) patch[field] = retagged;
  }

  if (Array.isArray(data.ingredients)) {
    const ingredients = data.ingredients as StoredIngredient[];
    const kept = ingredients.filter((i) => !check(typeof i?.name === "string" ? i.name : ""));
    if (kept.length !== ingredients.length) patch.ingredients = kept;
  }

  if (Array.isArray(data.ingredients_index)) {
    const index = data.ingredients_index as unknown[];
    const kept = index.filter((n) => typeof n !== "string" || !check(n));
    if (kept.length !== index.length) patch.ingredients_index = kept;
  }

  return { patch, removed, withParentheses };
}

/**
 * Valeurs cherchées dans `ingredients_index` pour une fiche, par lots de
 * trente (plafond d'un `array-contains-any`) : nom canonique, identifiant lu
 * comme un nom, et TOUS les alias. La normalisation est celle de l'index
 * lui-même (`buildIngredientsIndex`), jamais une copie.
 *
 * L'écran Ingrédients nutrition (`ingredientUsageSearchValues`,
 * `lib/features/admin/domain/ingredient_recipe_usage.dart`) cherche les mêmes
 * trois sources : une source ajoutée là-bas s'ajoute ici. Il n'affiche que les
 * trente premières valeurs ; ici, une suppression ne se décide qu'après avoir
 * tout cherché. Pas de fixture partagée : ce backfill est ponctuel et sera
 * retiré du code une fois passé.
 */
export function sheetUsageBatches(id: string, data: Record<string, unknown>): string[][] {
  const names: string[] = [];
  if (typeof data.canonical_name === "string") names.push(data.canonical_name);
  names.push(id.replaceAll("_", " "));
  if (Array.isArray(data.aliases)) {
    for (const a of data.aliases) if (typeof a === "string") names.push(a);
  }
  const values = buildIngredientsIndex(names.map((name) => ({ name, qty: "", unit: "" })));
  const batches: string[][] = [];
  for (let i = 0; i < values.length; i += MAX_USAGE_VALUES) {
    batches.push(values.slice(i, i + MAX_USAGE_VALUES));
  }
  return batches;
}

/** Vrai quand la fiche désigne un ustensile, par son identifiant ou son nom canonique. */
export function isUtensilSheet(id: string, data: Record<string, unknown>): boolean {
  const canonical = typeof data.canonical_name === "string" ? data.canonical_name : "";
  return isUtensil(id.replaceAll("_", " ")) || (canonical !== "" && isUtensil(canonical));
}

interface Bounds {
  deadline: number;
  maxDocs: number;
}

/** Écriture refusée parce que le document a changé depuis sa lecture (gRPC 9). */
function isPreconditionFailure(e: unknown): boolean {
  const code = (e as { code?: unknown } | null)?.code;
  return code === 9 || code === "failed-precondition" || code === "FAILED_PRECONDITION";
}

// ── Phase 1 : recettes ──────────────────────────────────────────────────────

async function runRecipesPhase(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
  bounds: Bounds,
  startAfter: string | null,
  dryRun: boolean,
  response: UtensilsCleanupResponse,
  review: BackfillReview,
  checkpointDocId: string,
): Promise<string | null> {
  let cursor = startAfter;
  let consecutiveFailures = 0;

  pages: for (;;) {
    let query = db.collection(COLL_RECIPES).orderBy("__name__").limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) {
      response.recettesParcourues = true;
      break;
    }

    for (const doc of page.docs) {
      if (Date.now() > bounds.deadline) {
        response.stoppedByDeadline = true;
        break pages;
      }
      if (response.examinees >= bounds.maxDocs) {
        response.stoppedByBudget = true;
        break pages;
      }
      if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        response.stoppedByErrors = true;
        break pages;
      }

      response.examinees += 1;
      const data = doc.data() as Record<string, unknown>;
      const { patch, removed, withParentheses } = cleanupRecipe(data);
      if (withParentheses.length > 0) {
        response.aRevoirALaMain += 1;
        review.add({
          kind: "recipe",
          id: doc.id,
          label: recipeReviewLabel(doc.id, data),
          reason: `Ustensile avec parenthèse, laissé tel quel : ${namesList(withParentheses)}. À corriger à la main`,
        });
      }
      if (Object.keys(patch).length === 0) {
        if (withParentheses.length === 0) response.dejaPropres += 1;
        cursor = doc.id;
        continue;
      }

      if (dryRun) {
        response.corrigees += 1;
        review.add({
          kind: "recipe",
          id: doc.id,
          label: recipeReviewLabel(doc.id, data),
          reason: `Essai à blanc : ${namesList(removed)} ${
            removed.length > 1 ? "seraient retirés" : "serait retiré"
          } des ingrédients`,
        });
        cursor = doc.id;
        continue;
      }

      try {
        // Conditionnée à la version lue : une modification faite depuis la
        // lecture de la page n'est pas écrasée.
        await doc.ref.update(patch, { lastUpdateTime: doc.updateTime });
        response.corrigees += 1;
        consecutiveFailures = 0;
      } catch (e) {
        if (isPreconditionFailure(e)) {
          // Pas une panne : la recette a bougé. Elle est relue au passage
          // suivant, qui repart du début une fois la collection parcourue.
          response.aReprendre += 1;
          consecutiveFailures = 0;
          review.add({
            kind: "recipe",
            id: doc.id,
            label: recipeReviewLabel(doc.id, data),
            reason: "Modifiée pendant le passage : relancer pour la corriger",
          });
          await logInfo({
            message: "Ustensiles — recette modifiée pendant le passage, laissée",
            correlationId: ctx.correlationId,
            userId: ctx.userId,
            moduleType: "DESIGN",
            feature: FEATURE,
            extra: { recipeId: doc.id },
          });
          cursor = doc.id;
          continue;
        }
        response.echouees += 1;
        consecutiveFailures += 1;
        review.add({
          kind: "recipe",
          id: doc.id,
          label: recipeReviewLabel(doc.id, data),
          reason: `Échec d'écriture : ${shortErrorMessage(e)}`,
        });
        await logError("Ustensiles — échec sur une recette", {
          correlationId: ctx.correlationId,
          userId: ctx.userId,
          moduleType: "DESIGN",
          feature: FEATURE,
          errorDescription: e instanceof Error ? e.message : String(e),
          extra: { recipeId: doc.id, consecutiveFailures },
        });
      }
      cursor = doc.id;
    }

    await setBackfillCursor({
      db,
      docId: checkpointDocId,
      lastDocId: cursor,
      operation: FEATURE,
      adminUid: ctx.userId,
    });

    if (page.size < PAGE_SIZE) {
      response.recettesParcourues = true;
      break;
    }
  }

  return cursor;
}

// ── Phase 2 : fiches du référentiel ─────────────────────────────────────────

async function runSheetsPhase(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
  bounds: Bounds,
  dryRun: boolean,
  response: UtensilsCleanupResponse,
  review: BackfillReview,
): Promise<void> {
  // Le référentiel compte quelques milliers de fiches : une lecture, sans
  // curseur. La phase est sautée tant qu'une recette peut encore citer une
  // fiche ; elle se rejoue entière au passage suivant si le délai l'arrête.
  const sheets = await db.collection(COLL_NUTRITION_INGREDIENTS).get();
  let consecutiveFailures = 0;
  for (const doc of sheets.docs) {
    const data = doc.data() as Record<string, unknown>;
    if (!isUtensilSheet(doc.id, data)) continue;
    if (Date.now() > bounds.deadline) {
      response.stoppedByDeadline = true;
      return;
    }
    if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
      response.stoppedByErrors = true;
      return;
    }
    response.fichesTrouvees += 1;
    const label =
      typeof data.canonical_name === "string" && data.canonical_name.trim()
        ? data.canonical_name.trim()
        : doc.id;

    try {
      let user: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      for (const values of sheetUsageBatches(doc.id, data)) {
        const found = await db
          .collection(COLL_RECIPES)
          .where("ingredients_index", "array-contains-any", values)
          .limit(1)
          .get();
        if (!found.empty) {
          user = found.docs[0];
          break;
        }
      }
      // À blanc, les recettes n'ont pas été corrigées : une recette qui la
      // cite encore est celle que le passage réel corrigera d'abord.
      if (user && !dryRun) {
        consecutiveFailures = 0;
        response.fichesEncoreCitees += 1;
        const first = user;
        review.add({
          kind: "ingredient",
          id: doc.id,
          label,
          reason: `Fiche gardée : encore citée par « ${recipeReviewLabel(
            first.id,
            first.data() as Record<string, unknown>,
          )} »`,
        });
        continue;
      }
      consecutiveFailures = 0;
      if (dryRun) {
        response.fichesSupprimees += 1;
        review.add({
          kind: "ingredient",
          id: doc.id,
          label,
          reason: "Essai à blanc : fiche d'ustensile, serait supprimée",
        });
        continue;
      }
      await doc.ref.delete();
      response.fichesSupprimees += 1;
    } catch (e) {
      response.fichesEchouees += 1;
      consecutiveFailures += 1;
      review.add({
        kind: "ingredient",
        id: doc.id,
        label,
        reason: `Échec de suppression : ${shortErrorMessage(e)}`,
      });
      await logError("Ustensiles — échec sur une fiche du référentiel", {
        correlationId: ctx.correlationId,
        userId: ctx.userId,
        moduleType: "DESIGN",
        feature: FEATURE,
        errorDescription: e instanceof Error ? e.message : String(e),
        extra: { ingredientId: doc.id },
      });
    }
  }
  response.fichesParcourues = true;
}

// ── Point d'entrée ──────────────────────────────────────────────────────────

export const backfillUtensilsCleanupFn = onCall<UtensilsCleanupRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: "512MiB",
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req) => {
    const ctx = await requireAdmin(req, FEATURE);

    const maxMinutesRaw = Number(req.data?.maxMinutes ?? 8);
    const maxMinutes = Number.isFinite(maxMinutesRaw)
      ? Math.max(1, Math.min(8.5, maxMinutesRaw))
      : 8;
    const maxDocsRaw = Number(req.data?.maxDocs ?? DEFAULT_MAX_RECIPES);
    const maxDocs = Number.isFinite(maxDocsRaw)
      ? Math.max(1, Math.min(5000, Math.trunc(maxDocsRaw)))
      : DEFAULT_MAX_RECIPES;
    const options: UtensilsCleanupPassOptions = {
      deadlineMs: Date.now() + maxMinutes * 60_000,
      maxDocs,
      // Par défaut à blanc : un appel sans l'argument n'écrit rien.
      dryRun: parseBoolean(req.data?.dryRun, true),
      resumeFromCheckpoint: parseBoolean(req.data?.resumeFromCheckpoint, true),
      resetCheckpoint: parseBoolean(req.data?.resetCheckpoint, false),
    };

    return runBackfillFromCallable({
      key: "utensils_cleanup",
      ctx,
      appVersion: req.data?.appVersion,
      run: () => runUtensilsCleanupPass(ctx, options),
      summarize: summarizeUtensilsCleanup,
    });
  },
);

/** Ce qu'un passage a le droit de faire. */
export interface UtensilsCleanupPassOptions {
  /** Instant de fin du passage ; la marge d'écriture du curseur est déduite ici. */
  deadlineMs: number;
  maxDocs: number;
  dryRun: boolean;
  resumeFromCheckpoint: boolean;
  resetCheckpoint: boolean;
}

/**
 * Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`).
 *
 * Un essai à blanc qui trouve quelque chose reste « incomplet », avec ce qu'il
 * a trouvé pour reste : la tuile ne doit pas afficher « Terminé » alors que
 * rien n'est corrigé. Il ne marque le backfill terminé que s'il ne trouve rien.
 */
export function summarizeUtensilsCleanup(r: UtensilsCleanupResponse): PassSummary {
  const found = r.essaiABlanc ? r.corrigees + r.fichesSupprimees : 0;
  return {
    complete: r.completed && found === 0,
    remaining: r.completed ? found : null,
    toReview: r.aRevoir.total,
    spendCapHit: false,
    // Une écriture en échec se retente au passage suivant, sans appel de
    // modèle.
    unresolved: 0,
  };
}

export async function runUtensilsCleanupPass(
  ctx: AuthContext,
  options: UtensilsCleanupPassOptions,
): Promise<UtensilsCleanupResponse> {
  const db = getFirestore();
  const bounds: Bounds = {
    deadline: options.deadlineMs - DEADLINE_MARGIN_MS,
    maxDocs: options.maxDocs,
  };
  const checkpointDocId = options.dryRun
    ? UTENSILS_CLEANUP_DRY_RUN_CHECKPOINT_DOC_ID
    : UTENSILS_CLEANUP_CHECKPOINT_DOC_ID;
  const response = emptyResponse(options.dryRun);
  const review = new BackfillReview();

  const startAfter = await getBackfillCursor({
    db,
    docId: checkpointDocId,
    resumeFromCheckpoint: options.resumeFromCheckpoint,
    resetCheckpoint: options.resetCheckpoint,
  });

  const cursor = await runRecipesPhase(
    db,
    ctx,
    bounds,
    startAfter,
    options.dryRun,
    response,
    review,
    checkpointDocId,
  );

  // Les fiches ne partent qu'après le parcours de toutes les recettes : avant,
  // une recette non encore corrigée en citerait une, et la recréerait à sa
  // prochaine écriture.
  if (response.recettesParcourues) {
    await runSheetsPhase(db, ctx, bounds, options.dryRun, response, review);
  }

  response.completed =
    response.recettesParcourues &&
    response.fichesParcourues &&
    response.echouees === 0 &&
    response.aReprendre === 0 &&
    response.fichesEchouees === 0;

  // Le curseur revient au début quand toutes les recettes sont passées ; sinon
  // il retient la dernière examinée.
  await setBackfillCursor({
    db,
    docId: checkpointDocId,
    lastDocId: response.recettesParcourues ? null : cursor,
    operation: FEATURE,
    adminUid: ctx.userId,
  });

  response.aRevoir = review.toJSON();

  await logInfo({
    message: options.dryRun
      ? "Ustensiles des recettes — essai à blanc"
      : "Ustensiles des recettes — nettoyage",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: { ...withoutReviewList(response), maxDocs: options.maxDocs },
  });

  return response;
}
