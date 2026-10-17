/**
 * Clé de titre des recettes — pose `titre_key` sur les recettes antérieures à
 * la détection des doublons à l'import, sans appel de modèle.
 *
 * `recipeProcessor` pose la clé sur un brouillon importé, et `onRecipeWritten`
 * la tient à jour à chaque écriture. Une recette qui n'a pas été réécrite
 * depuis n'en a pas : un nouveau scan de sa page ne serait pas reconnu comme un
 * doublon. Une recette dont la clé est déjà à jour n'est pas réécrite.
 *
 * Ponctuel : une fois la collection parcourue sans reste, le déclencheur suffit.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import { COLL_RECIPES, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { titleKeyUpdate } from "../triggers/recipeTitleKey";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin, type AuthContext } from "./_auth";
import { runBackfillFromCallable } from "../backfills/runner";
import type { PassSummary } from "../backfills/schedule";
import {
  BackfillReview,
  recipeReviewLabel,
  shortErrorMessage,
  type BackfillReviewList,
  withoutReviewList,
} from "./_backfillReview";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

/** Où l'on retient le dernier document examiné. */
export const TITLE_KEYS_CHECKPOINT_DOC_ID = "recipe_title_keys_backfill_checkpoint";

const FEATURE = "recipe_title_keys_backfill";

/** Recettes examinées par appel de la fonction, par défaut. */
const DEFAULT_MAX_RECIPES = 2000;
const PAGE_SIZE = 400;
/** Marge gardée sur le délai de la fonction, pour écrire le curseur avant la fin. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois recettes difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

interface BackfillTitleKeysRequest {
  maxMinutes?: number;
  maxDocs?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export interface BackfillTitleKeysResponse {
  examinees: number;
  /** `titre_key` écrite. */
  posees: number;
  /** Clé déjà à jour, rien d'écrit. */
  identiques: number;
  echouees: number;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  /** Vrai quand la collection a été parcourue en entier : le curseur est remis au début. */
  completed: boolean;
  /** Recettes en échec dans ce passage, nommées, avec la raison. */
  aRevoir: BackfillReviewList;
}

/** Ce qu'un passage a le droit de faire. */
export interface TitleKeysPassOptions {
  deadlineMs: number;
  maxDocs: number;
  resumeFromCheckpoint: boolean;
  resetCheckpoint: boolean;
}

export const backfillTitleKeysFn = onCall<BackfillTitleKeysRequest>(
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
      ? Math.max(1, Math.min(10000, Math.trunc(maxDocsRaw)))
      : DEFAULT_MAX_RECIPES;
    const options: TitleKeysPassOptions = {
      deadlineMs: Date.now() + maxMinutes * 60_000,
      maxDocs,
      resumeFromCheckpoint: parseBoolean(req.data?.resumeFromCheckpoint, true),
      resetCheckpoint: parseBoolean(req.data?.resetCheckpoint, false),
    };

    return runBackfillFromCallable({
      key: "recipe_title_keys",
      ctx,
      appVersion: req.data?.appVersion,
      run: () => runTitleKeysPass(ctx, options),
      summarize: summarizeTitleKeys,
    });
  },
);

/** Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`). */
export function summarizeTitleKeys(r: BackfillTitleKeysResponse): PassSummary {
  return {
    complete: r.completed,
    remaining: r.completed ? 0 : null,
    toReview: r.aRevoir.total,
    spendCapHit: false,
    // Une écriture en échec se retente au passage suivant.
    unresolved: 0,
  };
}

/** Un passage. Aucun appel de modèle. */
export async function runTitleKeysPass(
  ctx: AuthContext,
  options: TitleKeysPassOptions,
): Promise<BackfillTitleKeysResponse> {
  const db = getFirestore();
  const deadline = options.deadlineMs - DEADLINE_MARGIN_MS;
  const review = new BackfillReview();
  const response: BackfillTitleKeysResponse = {
    examinees: 0,
    posees: 0,
    identiques: 0,
    echouees: 0,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: false,
    aRevoir: { items: [], total: 0 },
  };

  let cursor = await getBackfillCursor({
    db,
    docId: TITLE_KEYS_CHECKPOINT_DOC_ID,
    resumeFromCheckpoint: options.resumeFromCheckpoint,
    resetCheckpoint: options.resetCheckpoint,
  });
  let consecutiveFailures = 0;

  pages: for (;;) {
    let query = db.collection(COLL_RECIPES).orderBy("__name__").limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) {
      response.completed = true;
      break;
    }

    for (const doc of page.docs) {
      if (Date.now() > deadline) {
        response.stoppedByDeadline = true;
        break pages;
      }
      if (response.examinees >= options.maxDocs) {
        response.stoppedByBudget = true;
        break pages;
      }
      if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        response.stoppedByErrors = true;
        break pages;
      }

      response.examinees += 1;
      const data = doc.data() as Record<string, unknown>;
      const expected = titleKeyUpdate(data);
      if (expected == null) {
        response.identiques += 1;
        consecutiveFailures = 0;
        cursor = doc.id;
        continue;
      }
      try {
        await doc.ref.update({ titre_key: expected });
        response.posees += 1;
        consecutiveFailures = 0;
      } catch (e) {
        response.echouees += 1;
        consecutiveFailures += 1;
        review.add({
          kind: "recipe",
          id: doc.id,
          label: recipeReviewLabel(doc.id, data),
          reason: `Échec d'écriture : ${shortErrorMessage(e)}`,
        });
        await logError("Clé de titre — échec sur une recette", {
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

    if (page.size < PAGE_SIZE) {
      response.completed = true;
      break;
    }
  }

  response.aRevoir = review.toJSON();
  // Le curseur revient au début quand la collection est parcourue, même avec
  // des échecs : le passage suivant repart du début et reprend les recettes en
  // échec (les autres sont comptées « identiques », sans écriture). Sinon il
  // retient le dernier document examiné.
  const reachedEnd = response.completed;
  if (response.echouees > 0) response.completed = false;
  await setBackfillCursor({
    db,
    docId: TITLE_KEYS_CHECKPOINT_DOC_ID,
    lastDocId: reachedEnd ? null : cursor,
    operation: FEATURE,
    adminUid: ctx.userId,
  });

  await logInfo({
    message: "Clé de titre des recettes — reprise",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: { ...withoutReviewList(response), maxDocs: options.maxDocs },
  });

  return response;
}
