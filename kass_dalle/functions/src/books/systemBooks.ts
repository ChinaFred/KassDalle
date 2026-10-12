/**
 * Les quatre livres système d'un compte, créés côté serveur.
 *
 * Le client les crée à l'ouverture de la bibliothèque (`ensureSystemBooks`,
 * `book_repository.dart`), pour un éditeur ou un administrateur seulement.
 * Le serveur les crée pour tout compte approuvé, lecteurs compris : à
 * l'approbation du compte (`syncUserClaims`), et pour les comptes existants
 * par le backfill `system_books` (`systemBooksBackfillCallable.ts`).
 *
 * Un livre est reconnu à son tag interne, quel que soit son titre : un livre
 * renommé n'est pas recréé. Un livre créé depuis la v0.23.49 porte un
 * identifiant fixe (`systemBookId`) : le serveur et le client, qui peuvent
 * tourner en même temps à l'approbation d'un éditeur, écrivent le même
 * document au lieu de créer chacun le leur. Les trois livres du client reprennent ses champs ;
 * « Mes recettes du web » passe par `findOrCreateWebBook`. La couverture reste
 * vide : l'écran affiche l'image du livre système livrée avec l'application.
 */

import { getFirestore, Timestamp } from "firebase-admin/firestore";

import { COLL_BOOKS } from "../config";
import { logError } from "../logging";
import { WEB_BOOK_TAG, findOrCreateWebBook } from "../pipeline/urlImport";

/** Les tags internes des livres système, dans l'ordre où le client les crée. */
export const SYSTEM_BOOK_TAGS = ["__kassdale_ia", "__libres", "__secretes", WEB_BOOK_TAG] as const;
export type SystemBookTag = (typeof SYSTEM_BOOK_TAGS)[number];

/** Les livres système absents de `books`, reconnus à leur tag. Pur, testé. */
export function missingSystemBooks(books: readonly { tags?: unknown }[]): SystemBookTag[] {
  const present = new Set<string>();
  for (const book of books) {
    if (!Array.isArray(book.tags)) continue;
    for (const tag of book.tags) if (typeof tag === "string") present.add(tag);
  }
  return SYSTEM_BOOK_TAGS.filter((tag) => !present.has(tag));
}

/**
 * Le document d'un livre système créé par le client, hors « Mes recettes du
 * web » (créé par `findOrCreateWebBook`). Mêmes champs, même texte que
 * `BookRepository.findOrCreate…Book`. Pur, testé.
 */
export function systemBookDocument(
  tag: Exclude<SystemBookTag, typeof WEB_BOOK_TAG>,
  uid: string,
  displayName: string,
  now: Timestamp,
): Record<string, unknown> {
  const base = {
    sous_titre: null,
    editeur: null,
    serie: null,
    annee: null,
    langue: "fr",
    isbn: null,
    url_couverture: null,
    review_status: "validated",
    created_by: uid,
    created_at: now,
    updated_at: now,
    source_file_url: null,
    source_file_name: null,
    ai_processed_at: null,
  };
  switch (tag) {
    case "__kassdale_ia":
      return {
        ...base,
        titre: "Mes créations Kass'Dalle ✨",
        auteur: "Kass'Dalle",
        description:
          "Recettes créées par l'intelligence artificielle Kass'Dalle. " +
          "Vous pouvez modifier ce livre comme n'importe quel autre.",
        tags: [tag, "ia", "kassdale"],
        is_private: false,
      };
    case "__libres":
      return {
        ...base,
        titre: "Mes recettes libres",
        auteur: displayName,
        description: "Mes recettes créées en dehors de tout livre.",
        tags: [tag],
        is_private: false,
      };
    case "__secretes":
      return {
        ...base,
        titre: "Mes Recettes Secrètes",
        auteur: displayName,
        description: "Mes recettes privées — non visibles par la famille.",
        tags: [tag],
        is_private: true,
      };
  }
}

/**
 * Identifiant fixe d'un livre système créé par le client ou par le serveur :
 * `kassdalle_{uid}`, `libres_{uid}`, `secretes_{uid}`. Même forme que
 * `_createSystemBook` (`book_repository.dart`) ; les règles Firestore
 * réservent ces identifiants au compte qu'ils nomment. Pur, testé.
 */
export function systemBookId(
  tag: Exclude<SystemBookTag, typeof WEB_BOOK_TAG>,
  uid: string,
): string {
  const prefix = { __kassdale_ia: "kassdalle", __libres: "libres", __secretes: "secretes" }[tag];
  return `${prefix}_${uid}`;
}

/**
 * Crée les livres système absents du compte [uid] et rend leur nombre.
 * `progress.created` compte les livres au fil de l'eau : sur une erreur,
 * l'appelant sait combien ont été créés avant elle. Lève à la première
 * erreur ; un nouvel appel ne crée que ce qui manque encore.
 */
export async function ensureSystemBooksFor(
  uid: string,
  displayName: string,
  ctx: { userId: string; correlationId: string },
  progress: { created: number } = { created: 0 },
): Promise<number> {
  const db = getFirestore();
  const owned = await db.collection(COLL_BOOKS).where("created_by", "==", uid).get();
  const missing = missingSystemBooks(owned.docs.map((d) => d.data()));
  const now = Timestamp.now();
  for (const tag of missing) {
    if (tag === WEB_BOOK_TAG) {
      await findOrCreateWebBook(uid, ctx);
      progress.created += 1;
      continue;
    }
    // Identifiant fixe, créé en transaction : le client (`_createSystemBook`)
    // écrit le même document. Si l'un l'a créé entre la lecture par tag et
    // cette transaction, l'autre le retrouve et n'en crée pas un second.
    const ref = db.collection(COLL_BOOKS).doc(systemBookId(tag, uid));
    const outcome = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        tx.create(ref, systemBookDocument(tag, uid, displayName, now));
        return "created" as const;
      }
      if (snap.get("created_by") !== uid) return "foreign" as const;
      const tags = snap.get("tags");
      return Array.isArray(tags) && tags.includes(tag)
        ? ("present" as const)
        : ("untagged" as const);
    });
    if (outcome === "created") {
      progress.created += 1;
    } else if (outcome !== "present") {
      // Un document occupe l'identifiant sans être ce livre : étranger au
      // compte (posé avant la règle qui réserve ces identifiants), ou livre
      // ordinaire du compte sans le tag. Journalisé, et les autres livres
      // système sont tout de même créés.
      await logError({
        message: `Livre système ${ref.id} non créé : identifiant occupé (${outcome})`,
        ...ctx,
        extra: { bookId: ref.id, tag, outcome },
      });
    }
  }
  return progress.created;
}
