/**
 * Contrôler les comptes — parcourt `users` et liste dans « À revoir » chaque
 * document qui s'écarte du schéma de `firestore.rules`, avec la raison.
 * Lecture seule : rien n'est écrit dans `users`. Sans appel de modèle.
 *
 * Les règles imposent depuis v0.24.30 et v0.24.32 un schéma strict aux
 * documents `users/{uid}` (tickets #162, #163). Un document écrit avant peut ne
 * pas le respecter : `AppUser.fromFirestore` lève, `watchAllUsers` saute le
 * compte, et son titulaire ne peut plus mettre à jour son document. Les
 * contrôles vivent dans `security/userDocument.ts`.
 *
 * Sans point de reprise, à l'inverse des autres backfills : un contrôle ne
 * peut se dire « rien à revoir » que sur un parcours entier fait d'un seul
 * passage. Un curseur ferait marquer terminé un second passage qui n'aurait vu
 * que la fin de la collection. La collection compte quelques dizaines de
 * comptes ; un passage en lit 5 000 au plus. Borné aussi par le délai et par
 * trois échecs de suite.
 *
 * Réentrant : rien n'est écrit, relancer refait la même lecture. Le ponctuel
 * se marque terminé quand un passage complet ne trouve rien à revoir.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import { COLL_USERS, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { userDocumentIssues, userReviewLabel } from "../security/userDocument";
import { requireAdmin, type AuthContext } from "./_auth";
import { runBackfillFromCallable } from "../backfills/runner";
import type { PassSummary } from "../backfills/schedule";
import {
  BackfillReview,
  shortErrorMessage,
  type BackfillReviewList,
  withoutReviewList,
} from "./_backfillReview";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const FEATURE = "users_schema_check_backfill";

/** Comptes lus par passage, au plus. */
export const USERS_SCHEMA_CHECK_MAX_DOCS = 5000;
const PAGE_SIZE = 200;
/** Marge gardée sur le délai de la fonction. */
const DEADLINE_MARGIN_MS = 30_000;
/** Trois échecs de suite : une panne, pas trois comptes difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

interface BackfillUsersSchemaCheckRequest {
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export interface BackfillUsersSchemaCheckResponse {
  /** Comptes lus. */
  examines: number;
  /** Conformes au schéma des règles. */
  conformes: number;
  /** Au moins un écart, listés dans `aRevoir`. */
  nonConformes: number;
  /** Contrôle en échec (exception), listés dans `aRevoir`. */
  echoues: number;
  /** Vrai quand la collection a été lue jusqu'au bout. */
  collectionParcourue: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  /** Collection lue en entier, sans échec. */
  completed: boolean;
  /** Comptes non conformes ou en échec, nommés sans adresse, avec la raison. */
  aRevoir: BackfillReviewList;
}

export const backfillUsersSchemaCheckFn = onCall<BackfillUsersSchemaCheckRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req) => {
    const ctx = await requireAdmin(req, FEATURE);
    const deadlineMs = Date.now() + 8 * 60_000;
    return runBackfillFromCallable({
      key: "users_schema_check",
      ctx,
      appVersion: req.data?.appVersion,
      run: () => runUsersSchemaCheckPass(ctx, deadlineMs),
      summarize: summarizeUsersSchemaCheck,
    });
  },
);

/** Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`). */
export function summarizeUsersSchemaCheck(r: BackfillUsersSchemaCheckResponse): PassSummary {
  return {
    complete: r.completed,
    remaining: r.completed ? 0 : null,
    toReview: r.aRevoir.total,
    spendCapHit: false,
    unresolved: r.echoues,
  };
}

/** Contrôle d'un compte, ajouté à [review] s'il est à revoir. Pur, testé. */
export function checkUserDocument(
  docId: string,
  data: Record<string, unknown>,
  review: BackfillReview,
): boolean {
  const issues = userDocumentIssues(docId, data);
  if (issues.length === 0) return true;
  review.add({
    kind: "account",
    id: docId,
    label: userReviewLabel(docId, data),
    reason: issues.join(" ; "),
  });
  return false;
}

/** Un passage sur toute la collection `users`, en lecture seule. */
export async function runUsersSchemaCheckPass(
  ctx: AuthContext,
  deadlineMs: number,
  maxDocs: number = USERS_SCHEMA_CHECK_MAX_DOCS,
): Promise<BackfillUsersSchemaCheckResponse> {
  const db = getFirestore();
  const deadline = deadlineMs - DEADLINE_MARGIN_MS;
  const review = new BackfillReview();
  const response: BackfillUsersSchemaCheckResponse = {
    examines: 0,
    conformes: 0,
    nonConformes: 0,
    echoues: 0,
    collectionParcourue: false,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: false,
    aRevoir: { items: [], total: 0 },
  };
  let consecutiveFailures = 0;
  let cursor: string | null = null;

  pages: for (;;) {
    let query = db.collection(COLL_USERS).orderBy("__name__").limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) {
      response.collectionParcourue = true;
      break;
    }

    for (const doc of page.docs) {
      if (Date.now() > deadline) {
        response.stoppedByDeadline = true;
        break pages;
      }
      if (response.examines >= maxDocs) {
        response.stoppedByBudget = true;
        break pages;
      }
      if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        response.stoppedByErrors = true;
        break pages;
      }

      response.examines += 1;
      cursor = doc.id;
      try {
        const data = (doc.data() ?? {}) as Record<string, unknown>;
        if (checkUserDocument(doc.id, data, review)) response.conformes += 1;
        else response.nonConformes += 1;
        consecutiveFailures = 0;
      } catch (e) {
        response.echoues += 1;
        consecutiveFailures += 1;
        review.add({
          kind: "account",
          id: doc.id,
          label: userReviewLabel(doc.id, {}),
          reason: `Contrôle impossible : ${shortErrorMessage(e)}`,
        });
        await logError("Contrôle des comptes — échec sur un compte", {
          correlationId: ctx.correlationId,
          userId: ctx.userId,
          moduleType: "DESIGN",
          feature: FEATURE,
          errorDescription: e instanceof Error ? e.message : String(e),
          extra: { docId: doc.id, consecutiveFailures },
        });
      }
    }

    if (page.size < PAGE_SIZE) {
      response.collectionParcourue = true;
      break;
    }
  }

  response.completed = response.collectionParcourue && response.echoues === 0;
  response.aRevoir = review.toJSON();

  await logInfo({
    message: "Contrôle des comptes — schéma des règles",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: { ...withoutReviewList(response), maxDocs },
  });

  return response;
}
