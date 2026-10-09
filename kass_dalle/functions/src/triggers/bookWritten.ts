/**
 * onBookWritten — le basculement d'un livre descend sur ses recettes.
 *
 * Rendre un livre privé doit rendre privées les recettes qu'il contient, sinon
 * la confidentialité ne vit que sur la couverture : les recettes continuent de
 * remonter dans la recherche et le planning des autres membres du groupe.
 *
 * Ce déclencheur ne réagit QU'À ce champ. Un livre se réécrit souvent — titre,
 * couverture, tags, `updated_at` — et se réveiller pour chacune de ces
 * écritures ferait une requête sur `recipes` à chaque fois, pour constater
 * qu'il n'y a rien à faire.
 *
 * À la suppression d'un livre, il détache les recettes qui y restent — les
 * pages ajoutées par d'autres membres, que le créateur du livre n'a pas le
 * droit de toucher (`detachRecipesOfDeletedBook`). Elles deviennent des
 * recettes libres de leurs auteurs, privées si le livre l'était.
 */

import { onDocumentWritten } from "firebase-functions/v2/firestore";

import { REGION } from "../config";
import { logError, logInfo, newCorrelationId, qualify } from "../logging";
import { detachRecipesOfDeletedBook, propagateBookPrivacy } from "./recipePrivacy";

/** Confidentialité portée par un instantané de livre, absente valant publique. */
function privacyOf(data: Record<string, unknown> | undefined): boolean {
  return data?.is_private === true;
}

export const onBookWritten = onDocumentWritten(
  { document: "books/{bookId}", region: REGION },
  async (event) => {
    const after = event.data?.after;
    if (!after?.exists) {
      if (!event.data?.before?.exists) return;
      const bookId = event.params.bookId;
      const correlationId = newCorrelationId(qualify("ecriture_livre", "suppression"));
      try {
        const wasPrivate = privacyOf(
          event.data.before.data() as Record<string, unknown> | undefined,
        );
        const detached = await detachRecipesOfDeletedBook(bookId, wasPrivate);
        if (detached > 0) {
          await logInfo({
            message: "Livre supprimé : ses recettes restantes deviennent des recettes libres",
            correlationId,
            feature: "book_deletion_detach",
            extra: { bookId, recettesDetachees: detached },
          });
        }
      } catch (error) {
        await logError({
          message: "onBookWritten : détachement des recettes d'un livre supprimé impossible",
          errorDescription: error instanceof Error ? error.message : String(error),
          moduleType: "DESIGN",
          correlationId,
          extra: { bookId },
        });
      }
      return;
    }

    const before = privacyOf(event.data?.before?.data() as Record<string, unknown> | undefined);
    const now = privacyOf(after.data() as Record<string, unknown>);
    if (before === now) return;

    const bookId = event.params.bookId;
    const correlationId = newCorrelationId(
      qualify("ecriture_livre", now ? "passage-en-prive" : "passage-en-partage"),
    );

    try {
      const touched = await propagateBookPrivacy({ bookId, isPrivate: now, correlationId });
      await logInfo({
        message: now
          ? "Livre passé en privé : ses recettes quittent la bibliothèque familiale"
          : "Livre repassé en partagé : ses recettes reviennent dans la bibliothèque familiale",
        correlationId,
        feature: "book_privacy_propagation",
        extra: { bookId, isPrivate: now, recettesTouchees: touched },
      });
    } catch (error) {
      await logError({
        message: "onBookWritten : propagation de la confidentialité impossible",
        errorDescription: error instanceof Error ? error.message : String(error),
        moduleType: "DESIGN",
        correlationId,
        extra: { bookId, isPrivate: now },
      });
    }
  },
);
