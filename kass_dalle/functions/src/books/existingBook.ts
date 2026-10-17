/**
 * Livre déjà en bibliothèque, vérifié avant l'import d'un livre entier.
 *
 * Le même livre peut arriver de plusieurs sources — un PDF scanné, un EPUB
 * acheté — : le titre et l'auteur font le critère principal. L'empreinte du
 * fichier ne couvre que le même fichier ; elle s'ajoute aux deux autres, elle ne
 * les remplace pas. La comparaison porte sur les livres de l'appelant : une
 * bibliothèque compte quelques dizaines de livres, lus en une requête.
 */

import { createHash } from "node:crypto";

import { getFirestore, Timestamp } from "firebase-admin/firestore";

import { COLL_BOOKS } from "../config";
import { titleKey } from "../pipeline/duplicateDetection";

/** Empreinte SHA-256 d'un fichier, en hexadécimal. */
export function fileSha256(bytes: Buffer): string {
  return createHash("sha256").update(bytes).digest("hex");
}

/** Un livre de l'appelant, tel que la comparaison le lit. */
export interface LibraryBook {
  id: string;
  titre: string;
  auteur: string | null;
  sha256: string | null;
  createdAtMs: number | null;
}

export interface ExistingBookMatch {
  id: string;
  titre: string;
  auteur: string | null;
  sameFile: boolean;
  sameTitle: boolean;
  /** Date de création du livre existant, ISO 8601. */
  importedAt: string | null;
}

/** Un auteur absent d'un côté — ou « Auteur inconnu » — n'écarte pas le doublon. */
function authorsCompatible(a: string | null | undefined, b: string | null | undefined): boolean {
  const ka = titleKey(a);
  const kb = titleKey(b);
  if (!ka || !kb || ka === "auteur inconnu" || kb === "auteur inconnu") return true;
  return ka === kb;
}

/**
 * Le livre de la bibliothèque qui correspond, ou `null`. Le même fichier
 * l'emporte sur le même titre. Fonction pure.
 */
export function pickExistingBook(args: {
  books: LibraryBook[];
  titre: string | null;
  auteur: string | null;
  sha256: string;
}): ExistingBookMatch | null {
  const key = titleKey(args.titre);
  let best: ExistingBookMatch | null = null;
  for (const book of args.books) {
    const sameFile = book.sha256 != null && book.sha256 === args.sha256;
    const sameTitle =
      key.length > 0 && titleKey(book.titre) === key && authorsCompatible(book.auteur, args.auteur);
    if (!sameFile && !sameTitle) continue;
    const match: ExistingBookMatch = {
      id: book.id,
      titre: book.titre,
      auteur: book.auteur,
      sameFile,
      sameTitle,
      importedAt: book.createdAtMs != null ? new Date(book.createdAtMs).toISOString() : null,
    };
    if (sameFile) return match;
    best ??= match;
  }
  return best;
}

/** Lit les livres de `uid` et rend celui qui correspond, ou `null`. */
export async function findExistingBook(args: {
  uid: string;
  titre: string | null;
  auteur: string | null;
  sha256: string;
}): Promise<ExistingBookMatch | null> {
  const snap = await getFirestore()
    .collection(COLL_BOOKS)
    .where("created_by", "==", args.uid)
    .get();
  const books: LibraryBook[] = snap.docs.map((doc) => {
    const data = doc.data();
    return {
      id: doc.id,
      titre: typeof data.titre === "string" ? data.titre : "",
      auteur: typeof data.auteur === "string" ? data.auteur : null,
      sha256: typeof data.source_file_sha256 === "string" ? data.source_file_sha256 : null,
      createdAtMs: data.created_at instanceof Timestamp ? data.created_at.toMillis() : null,
    };
  });
  return pickExistingBook({ books, titre: args.titre, auteur: args.auteur, sha256: args.sha256 });
}
