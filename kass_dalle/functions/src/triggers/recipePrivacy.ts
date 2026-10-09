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
import { isValidDocumentId } from "../moderation/promote";

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
 * Une recette sans livre rend `false` ici : c'est la valeur d'une recette
 * NEUVE sans livre (`recipeProcessor`). Une recette existante sans livre garde
 * la sienne (`privacyWithoutBook`, appliqué par `syncRecipePrivacy`).
 *
 * Un livre introuvable rend `false` plutôt que de laisser la recette dans un
 * état indéterminé. C'est le choix le moins mauvais : le livre a été supprimé,
 * la recette est orpheline, et la marquer privée la ferait disparaître de la
 * bibliothèque de son propre auteur sans qu'aucun écran ne puisse l'en sortir.
 */
export async function expectedPrivacy(bookId: string | null): Promise<boolean> {
  if (!bookId) return false;
  // Un identifiant qui n'en est pas un (« / ») viserait un autre document que
  // le livre. Les règles le refusent au client ; ici, il se signale.
  if (!isValidDocumentId(bookId)) {
    await logError({
      message: "expectedPrivacy : book_id invalide, traité comme un livre introuvable",
      moduleType: "DESIGN",
      extra: { bookId },
    });
    return false;
  }
  const snap = await getFirestore().collection(COLL_BOOKS).doc(bookId).get();
  if (!snap.exists) return false;
  return snap.data()?.is_private === true;
}

/**
 * Confidentialité qu'une recette doit porter : celle de son livre, et pour une
 * recette sans livre, celle qu'elle porte déjà.
 *
 * Une recette sans livre retombait à `false` : détacher les pages d'un livre
 * privé — ou supprimer ce livre — les rendait lisibles par toute la famille.
 * Une recette libre déjà privée reste privée ; une recette libre sans valeur
 * est partagée. Pure et exportée pour être testée.
 */
export function privacyWithoutBook(current: unknown): boolean {
  return current === true;
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
  /** Scan de l'utilisateur d'où vient ce travail, quand il en vient un. */
  scanId?: string;
}): Promise<boolean> {
  const { recipeId, data, beforeData, correlationId, scanId } = args;
  const current = data.is_private;
  const bookId = bookIdOf(data);

  const settled =
    typeof current === "boolean" &&
    beforeData !== undefined &&
    beforeData.is_private === current &&
    bookIdOf(beforeData) === bookId;
  if (settled) return false;

  try {
    const expected = bookId ? await expectedPrivacy(bookId) : privacyWithoutBook(current);
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
      scanId,
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
  /** Scan de l'utilisateur d'où vient ce travail, quand il en vient un. */
  scanId?: string;
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

/**
 * Détache les recettes restées dans un livre supprimé.
 *
 * Le créateur d'un livre ne supprime ni ne détache que ses propres recettes
 * (`firestore.rules`) : les pages ajoutées par d'autres membres restaient
 * avec un `book_id` qui ne désignait plus rien. Elles deviennent des recettes
 * libres de leurs auteurs. Celles d'un livre privé restent privées
 * (`is_private: true` écrit avec le détachement) ; `migrateLibresRecipes` ne
 * range que les recettes libres partagées dans « Mes recettes libres ».
 *
 * `book_id` ne fait pas partie des entrées de la garde d'empreinte de
 * `onRecipeWritten` : détacher ne relance ni la nutrition ni les produits
 * d'achat. Il réveille pourtant `onRecipeWritten`, dont `syncRecipeMealRole`
 * passe AVANT cette garde : une recette encore sans rôle de repas déclenche
 * alors un appel de modèle (non traité, voir TechnicalRequirements §4). Rend
 * le nombre de recettes détachées.
 */
export async function detachRecipesOfDeletedBook(
  bookId: string,
  bookWasPrivate: boolean,
): Promise<number> {
  const db = getFirestore();
  const snap = await db.collection(COLL_RECIPES).where("book_id", "==", bookId).get();
  for (let i = 0; i < snap.docs.length; i += BATCH_SIZE) {
    const batch = db.batch();
    for (const doc of snap.docs.slice(i, i + BATCH_SIZE)) {
      // Les pages d'un livre privé restent privées une fois détachées :
      // `syncRecipePrivacy` garde la valeur d'une recette sans livre.
      batch.update(doc.ref, {
        book_id: null,
        book_titre: null,
        ...(bookWasPrivate ? { is_private: true } : {}),
      });
    }
    await batch.commit();
  }
  return snap.docs.length;
}
