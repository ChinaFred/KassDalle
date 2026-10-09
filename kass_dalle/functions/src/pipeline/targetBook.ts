/**
 * Le livre cible d'un import : seulement un livre de l'importateur, ou
 * n'importe lequel pour un administrateur.
 *
 * Décision de l'utilisateur (v0.23.8) : on ne range une recette que dans ses
 * propres livres. Les règles Firestore l'imposent au client, mais le pipeline
 * écrit les recettes par l'Admin SDK, hors règles, dans le `book_id` que le
 * client a posé sur le job. Sans ce contrôle, un éditeur importait des pages
 * dans le livre d'un autre en passant son identifiant.
 */

import { getFirestore } from "firebase-admin/firestore";

import { COLL_BOOKS } from "../config";
import { isAdminAccount } from "../callable/_auth";
import { isValidDocumentId } from "../moderation/promote";

/** Livre cible refusé : il ne se rejoue pas, le job part en dead letter. */
export class TargetBookNotOwned extends Error {
  constructor(
    readonly bookId: string,
    detail: string,
  ) {
    super(detail);
    this.name = "TargetBookNotOwned";
  }
}

/**
 * Refus de ranger dans ce livre, ou `null` si permis. Pure et exportée pour
 * être testée.
 */
export function targetBookDenial(args: {
  bookId: string;
  bookExists: boolean;
  bookCreatedBy: unknown;
  ownerUid: string;
  ownerIsAdmin: boolean;
}): string | null {
  if (!isValidDocumentId(args.bookId)) return "Identifiant de livre invalide.";
  if (!args.bookExists) return "Le livre choisi n'existe plus.";
  if (args.ownerIsAdmin) return null;
  const createdBy = typeof args.bookCreatedBy === "string" ? args.bookCreatedBy : "";
  if (createdBy.length > 0 && createdBy === args.ownerUid) return null;
  return "On ne range une recette que dans ses propres livres.";
}

/**
 * Lève [TargetBookNotOwned] si le job vise le livre d'un autre. Un job sans
 * livre passe. Le rôle administrateur n'est relu que hors propriété.
 */
export async function assertJobTargetBook(bookId: unknown, ownerUid: string): Promise<void> {
  if (typeof bookId !== "string" || bookId.length === 0) return;
  const snap = isValidDocumentId(bookId)
    ? await getFirestore().collection(COLL_BOOKS).doc(bookId).get()
    : null;
  const bookExists = snap?.exists === true;
  const bookCreatedBy = snap?.data()?.created_by;
  const isOwner = typeof bookCreatedBy === "string" && bookCreatedBy === ownerUid;
  const denial = targetBookDenial({
    bookId,
    bookExists,
    bookCreatedBy,
    ownerUid,
    ownerIsAdmin: bookExists && !isOwner ? await isAdminAccount(ownerUid) : false,
  });
  if (denial) throw new TargetBookNotOwned(bookId, denial);
}
