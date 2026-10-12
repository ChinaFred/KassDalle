/**
 * Livres système — crée, pour chaque compte approuvé, ceux des quatre livres
 * système qui lui manquent, sans appel de modèle.
 *
 * Le client les crée à l'ouverture de la bibliothèque (`ensureSystemBooks`,
 * `book_repository.dart`), et pour un éditeur ou un administrateur seulement.
 * Un compte qui n'a pas rouvert la bibliothèque depuis l'ajout d'un livre
 * système, et tout lecteur, en restent dépourvus. Ce backfill les crée côté
 * serveur pour tous les comptes `reader`, `editor` et `admin` non révoqués.
 *
 * Les livres créés ici reprennent les champs que pose le client. La couverture
 * reste vide : l'écran affiche l'image du livre système livrée avec
 * l'application. Le client la dépose à la prochaine ouverture de la
 * bibliothèque par leur propriétaire, s'il est éditeur ou administrateur ;
 * pour un lecteur, `url_couverture` reste vide. « Mes recettes du web » passe par
 * `findOrCreateWebBook`, comme à l'import par lien.
 *
 * Réentrant : un livre est reconnu à son tag interne, quel que soit son titre.
 * Un compte qui a ses quatre livres est sauté. Un document par compte,
 * quelques dizaines : pas de curseur, mais les mêmes bornes que les autres
 * backfills.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore, Timestamp } from "firebase-admin/firestore";

import { COLL_BOOKS, COLL_USERS, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { WEB_BOOK_TAG, findOrCreateWebBook } from "../pipeline/urlImport";
import { accessDenial, requireAdmin, type AuthContext } from "./_auth";
import { runBackfillFromCallable } from "../backfills/runner";
import type { PassSummary } from "../backfills/schedule";
import { BackfillReview, shortErrorMessage, withoutReviewList } from "./_backfillReview";
import type { BackfillReviewList } from "./_backfillReview";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const FEATURE = "system_books_backfill";

/** Comptes traités (au moins un livre créé) par appel. */
const MAX_DOCS = 500;
/** Marge gardée sur le délai de la fonction. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois comptes difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

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

/** Vrai pour un compte `reader`, `editor` ou `admin` non révoqué. Pur, testé. */
export function isApprovedAccount(data: Record<string, unknown> | undefined): boolean {
  const role = typeof data?.role === "string" ? data.role.trim() : null;
  return accessDenial({ role, revoked: data?.is_revoked === true }, "approved") === null;
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

export interface BackfillSystemBooksResponse {
  examines: number;
  /** Comptes à qui au moins un livre a été créé. */
  completes: number;
  /** Livres créés, tous comptes confondus. */
  livresCrees: number;
  /** Comptes qui avaient déjà leurs quatre livres. */
  dejaAJour: number;
  /** Comptes en attente ou révoqués : sautés. */
  ignores: number;
  echoues: number;
  /** Comptes pas encore examinés à l'arrêt du passage. */
  restants: number;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  completed: boolean;
  /** Comptes en échec, nommés, avec la raison. */
  aRevoir: BackfillReviewList;
}

interface BackfillSystemBooksRequest {
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export const backfillSystemBooksFn = onCall<BackfillSystemBooksRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req) => {
    const ctx = await requireAdmin(req, FEATURE);
    return runBackfillFromCallable({
      key: "system_books",
      ctx,
      appVersion: req.data?.appVersion,
      summarize: summarizeSystemBooks,
      run: () => runSystemBooksPass(ctx),
    });
  },
);

/** Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`). */
export function summarizeSystemBooks(r: BackfillSystemBooksResponse): PassSummary {
  return {
    complete: r.completed,
    remaining: r.restants,
    toReview: r.aRevoir.total,
    spendCapHit: false,
  };
}

/** Un passage sur tous les comptes, borné par le délai d'une fonction. */
async function runSystemBooksPass(ctx: AuthContext): Promise<BackfillSystemBooksResponse> {
  const db = getFirestore();
  const deadline = Date.now() + 540_000 - DEADLINE_MARGIN_MS;
  const response: BackfillSystemBooksResponse = {
    examines: 0,
    completes: 0,
    livresCrees: 0,
    dejaAJour: 0,
    ignores: 0,
    echoues: 0,
    restants: 0,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: false,
    aRevoir: { items: [], total: 0 },
  };
  const review = new BackfillReview();

  // Un document par compte : toute la collection tient en une lecture.
  // Les comptes déjà à jour ne comptent pas dans la borne d'écritures,
  // si bien qu'une relance avance toujours au-delà des précédents.
  const users = await db.collection(COLL_USERS).get();
  let consecutiveFailures = 0;
  let treated = 0;
  for (const user of users.docs) {
    if (Date.now() > deadline) {
      response.stoppedByDeadline = true;
      break;
    }
    if (treated >= MAX_DOCS) {
      response.stoppedByBudget = true;
      break;
    }
    if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
      response.stoppedByErrors = true;
      break;
    }
    response.examines += 1;
    const data = user.data() as Record<string, unknown>;
    if (!isApprovedAccount(data)) {
      response.ignores += 1;
      continue;
    }
    const uid = user.id;
    const displayName = (typeof data.display_name === "string" && data.display_name.trim()) || "";
    let created = 0;
    try {
      const owned = await db.collection(COLL_BOOKS).where("created_by", "==", uid).get();
      const missing = missingSystemBooks(owned.docs.map((d) => d.data()));
      if (missing.length === 0) {
        response.dejaAJour += 1;
        consecutiveFailures = 0;
        continue;
      }
      const now = Timestamp.now();
      for (const tag of missing) {
        if (tag === WEB_BOOK_TAG) {
          await findOrCreateWebBook(uid, ctx);
        } else {
          await db.collection(COLL_BOOKS).add(systemBookDocument(tag, uid, displayName, now));
        }
        created += 1;
      }
      response.completes += 1;
      response.livresCrees += created;
      treated += 1;
      consecutiveFailures = 0;
    } catch (e) {
      // Les livres déjà créés pour ce compte restent : le passage suivant
      // ne crée que ceux qui manquent encore.
      response.livresCrees += created;
      response.echoues += 1;
      consecutiveFailures += 1;
      review.add({
        kind: "account",
        id: uid,
        label: displayName || uid,
        reason: `Échec de création : ${shortErrorMessage(e)}`,
      });
      await logError("Livres système — échec sur un compte", {
        correlationId: ctx.correlationId,
        userId: ctx.userId,
        moduleType: "DESIGN",
        feature: FEATURE,
        errorDescription: e instanceof Error ? e.message : String(e),
        extra: { accountUid: uid, created, consecutiveFailures },
      });
    }
  }
  response.restants = users.size - response.examines;
  response.completed = response.restants === 0 && !response.stoppedByErrors;
  response.aRevoir = review.toJSON();

  await logInfo({
    message: "Livres système des comptes — passage",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: { ...withoutReviewList(response) },
  });

  return response;
}
