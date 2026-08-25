/**
 * Confidentialité d'une recette — la vérité du livre, recopiée sur la recette.
 *
 * Un livre porte `is_private`. Une recette, non : pour savoir si on avait le
 * droit de la montrer, il fallait aller lire son livre. La recherche familiale
 * et le planning familial ne le faisaient pas, et remontaient donc les recettes
 * du livre « Mes Recettes Secrètes » des autres membres.
 *
 * Le corriger côté client ne suffit pas, et le corriger dans les règles
 * Firestore est **impossible** : une règle dispose de vingt lectures de
 * document par requête de liste, et un `get()` sur le livre porteur en coûte
 * une PAR RECETTE renvoyée. La vingt-et-unième recette ferait échouer la
 * requête entière.
 *
 * L'information descend donc sur la recette. Elle y est écrite par le serveur,
 * jamais par le client, à trois moments :
 *
 *  1. à chaque écriture de recette — {@link syncRecipePrivacy}, appelée en tête
 *     de `onRecipeWritten`, avant sa garde d'empreinte ;
 *  2. au basculement d'un livre — {@link propagateBookPrivacy}, appelée par
 *     `onBookWritten` ;
 *  3. au rattrapage des documents antérieurs — le callable de backfill.
 *
 * `book_id` n'a volontairement PAS rejoint les entrées de `onRecipeWritten` :
 * déplacer une recette d'un livre à l'autre ne change ni sa nutrition ni ses
 * produits d'achat, et l'y ajouter aurait relancé des appels d'IA facturés à
 * chaque rangement de bibliothèque.
 */

import { getFirestore } from "firebase-admin/firestore";

import { COLL_BOOKS, COLL_RECIPES } from "../config";
import { logError } from "../logging";

/**
 * Recettes réécrites par lot. Firestore en accepte 500 par batch ; on en garde
 * sous le pied pour ne pas frôler la limite si un jour l'écriture s'enrichit.
 */
const BATCH_SIZE = 400;

/** Identifiant de livre exploitable, ou `null`. Une chaîne vide n'en est pas un. */
export function bookIdOf(data: Record<string, unknown> | undefined): string | null {
  const raw = data?.book_id;
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

/**
 * Confidentialité que la recette DEVRAIT porter, connaissant son livre.
 *
 * Une recette sans livre — une « recette libre » — n'est jamais privée : elle
 * n'a pas de porteur d'où tenir sa confidentialité.
 *
 * Un livre introuvable rend `false` plutôt que de laisser la recette dans un
 * état indéterminé. C'est le choix le moins mauvais : le livre a été supprimé,
 * la recette est orpheline, et la marquer privée la ferait disparaître de la
 * bibliothèque de son propre auteur sans qu'aucun écran ne puisse l'en sortir.
 */
export async function expectedPrivacy(bookId: string | null): Promise<boolean> {
  if (!bookId) return false;
  const snap = await getFirestore().collection(COLL_BOOKS).doc(bookId).get();
  if (!snap.exists) return false;
  return snap.data()?.is_private === true;
}

/**
 * Aligne `is_private` d'une recette sur son livre, si besoin.
 *
 * Appelée à chaque écriture de recette. Le raccourci évite la lecture du livre
 * dans le cas courant — une sauvegarde qui ne touche ni le livre porteur ni la
 * confidentialité ne peut pas les avoir désaccordés depuis le passage
 * précédent, et c'est `onBookWritten` qui répercute le basculement d'un livre.
 *
 * Rend `true` quand elle a écrit. L'écriture réveille `onRecipeWritten`, dont
 * la garde d'empreinte sort aussitôt : `is_private` ne figure pas parmi ses
 * entrées, l'empreinte est donc inchangée et aucun recalcul ne part.
 */
export async function syncRecipePrivacy(args: {
  recipeId: string;
  data: Record<string, unknown>;
  beforeData: Record<string, unknown> | undefined;
  correlationId: string;
}): Promise<boolean> {
  const { recipeId, data, beforeData, correlationId } = args;
  const current = data.is_private;
  const bookId = bookIdOf(data);

  const settled =
    typeof current === "boolean" &&
    beforeData !== undefined &&
    beforeData.is_private === current &&
    bookIdOf(beforeData) === bookId;
  if (settled) return false;

  try {
    const expected = await expectedPrivacy(bookId);
    if (current === expected) return false;

    await getFirestore().collection(COLL_RECIPES).doc(recipeId).update({
      is_private: expected,
    });
    return true;
  } catch (error) {
    // Best-effort assumé, mais jamais silencieux : la recette garde alors une
    // confidentialité périmée, et c'est le backfill qui la rattrapera.
    await logError({
      message: "syncRecipePrivacy : alignement de la confidentialité impossible",
      errorDescription: error instanceof Error ? error.message : String(error),
      moduleType: "DESIGN",
      correlationId,
      extra: { recipeId, bookId },
    });
    return false;
  }
}

/**
 * Écrit `is_private` sur toutes les recettes d'un livre.
 *
 * Rend le nombre de recettes réécrites — sans quoi un livre basculé et un
 * livre vide se ressemblent, et l'écran ne peut rien annoncer.
 */
export async function propagateBookPrivacy(args: {
  bookId: string;
  isPrivate: boolean;
  correlationId: string;
}): Promise<number> {
  const db = getFirestore();
  const snap = await db.collection(COLL_RECIPES).where("book_id", "==", args.bookId).get();

  const stale = snap.docs.filter((doc) => doc.data().is_private !== args.isPrivate);
  if (stale.length === 0) return 0;

  for (let i = 0; i < stale.length; i += BATCH_SIZE) {
    const batch = db.batch();
    for (const doc of stale.slice(i, i + BATCH_SIZE)) {
      batch.update(doc.ref, { is_private: args.isPrivate });
    }
    await batch.commit();
  }

  return stale.length;
}
