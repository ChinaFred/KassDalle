/**
 * Dossiers des illustrations — contrôle en lecture seule, sans appel de
 * modèle (suite de l'audit #151, ticket #154).
 *
 * Parcourt `recipes` et liste dans « À revoir » chaque recette dont une URL de
 * `image_urls` ou de `thumbnail_urls` n'est pas sous `illustrations/` ou
 * `recipes/` du bucket, les deux dossiers où n'arrive qu'une image modérée.
 * N'écrit rien dans les recettes : seuls le point de reprise et l'état du
 * backfill sont écrits. Un parcours entier, parti du début, écrit aussi la
 * liste des images signalées (`signalees` : recette et `bucket/chemin`) dans
 * `app_config/backfill_run_illustration_folders`, serveur seul : c'est la
 * liste fermée que « Ranger les illustrations » copie, et rien d'autre. Si
 * la liste « À revoir » est vide, une version suivante limitera l'affichage
 * des illustrations à ces deux dossiers.
 *
 * Ponctuel : un passage parti du début de la collection et arrivé au bout sans
 * recette à revoir le marque terminé. Un passage repris en cours de
 * collection ne voit pas les recettes des passages précédents : il ne le
 * marque jamais terminé.
 *
 * Les journaux ne reçoivent que les compteurs : ni titre, ni URL, ni chemin.
 */

import { onCall } from "firebase-functions/v2/https";
import { FieldValue, getFirestore } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";

import { COLL_APP_CONFIG, COLL_RECIPES, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin, type AuthContext } from "./_auth";
import { backfillRunDocId, runBackfillFromCallable } from "../backfills/runner";
import type { PassSummary } from "../backfills/schedule";
import {
  FLAGGED_LIST_LIMIT,
  LEGACY_APP_BUCKET,
  flaggedIllustrationKeys,
  recipeIllustrationIssues,
  type FlaggedIllustration,
} from "../backfills/illustrationFolders";
import { storageEmulatorActive } from "../utils/storagePath";
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
export const ILLUSTRATION_FOLDERS_CHECKPOINT_DOC_ID = "illustration_folders_backfill_checkpoint";

const FEATURE = "illustration_folders_backfill";

/** Recettes examinées par appel de la fonction, par défaut. */
const DEFAULT_MAX_RECIPES = 2000;
const PAGE_SIZE = 400;
/** Marge gardée sur le délai de la fonction, pour écrire le curseur avant la fin. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois recettes difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

interface BackfillIllustrationFoldersRequest {
  maxMinutes?: number;
  maxDocs?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export interface BackfillIllustrationFoldersResponse {
  examinees: number;
  /** Toutes les illustrations sous `illustrations/` ou `recipes/`, ou aucune. */
  conformes: number;
  /** Au moins une illustration ailleurs : listée dans `aRevoir`. */
  horsDossiers: number;
  /** Recette illisible : listée dans `aRevoir`, journalisée. */
  echouees: number;
  /** Le passage est parti du début de `recipes` (pas d'un point de reprise). */
  depuisLeDebut: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  /** Vrai quand la collection a été parcourue jusqu'au bout : le curseur est remis au début. */
  completed: boolean;
  /** Recettes hors dossiers et recettes en échec, nommées, avec la raison. */
  aRevoir: BackfillReviewList;
}

/** Ce qu'un passage a le droit de faire. */
export interface IllustrationFoldersPassOptions {
  deadlineMs: number;
  maxDocs: number;
  resumeFromCheckpoint: boolean;
  resetCheckpoint: boolean;
}

export const backfillIllustrationFoldersFn = onCall<BackfillIllustrationFoldersRequest>(
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
    const options: IllustrationFoldersPassOptions = {
      deadlineMs: Date.now() + maxMinutes * 60_000,
      maxDocs,
      resumeFromCheckpoint: parseBoolean(req.data?.resumeFromCheckpoint, true),
      resetCheckpoint: parseBoolean(req.data?.resetCheckpoint, false),
    };

    return runBackfillFromCallable({
      key: "illustration_folders",
      ctx,
      appVersion: req.data?.appVersion,
      run: () => runIllustrationFoldersPass(ctx, options),
      summarize: summarizeIllustrationFolders,
    });
  },
);

/** Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`). */
export function summarizeIllustrationFolders(r: BackfillIllustrationFoldersResponse): PassSummary {
  // Terminé seulement après un parcours entier dans un même passage : un
  // passage repris ignore ce que les précédents ont listé.
  const complete = r.completed && r.depuisLeDebut;
  return {
    complete,
    remaining: complete ? 0 : null,
    toReview: r.aRevoir.total,
    spendCapHit: false,
    unresolved: 0,
  };
}

/** Un passage. Aucun appel de modèle, aucune écriture dans `recipes`. */
export async function runIllustrationFoldersPass(
  ctx: AuthContext,
  options: IllustrationFoldersPassOptions,
): Promise<BackfillIllustrationFoldersResponse> {
  const db = getFirestore();
  const deadline = options.deadlineMs - DEADLINE_MARGIN_MS;
  const review = new BackfillReview();
  const buckets = [getStorage().bucket().name, LEGACY_APP_BUCKET];
  const allowEmulator = storageEmulatorActive();
  const response: BackfillIllustrationFoldersResponse = {
    examinees: 0,
    conformes: 0,
    horsDossiers: 0,
    echouees: 0,
    depuisLeDebut: false,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: false,
    aRevoir: { items: [], total: 0 },
  };

  let cursor = await getBackfillCursor({
    db,
    docId: ILLUSTRATION_FOLDERS_CHECKPOINT_DOC_ID,
    resumeFromCheckpoint: options.resumeFromCheckpoint,
    resetCheckpoint: options.resetCheckpoint,
  });
  response.depuisLeDebut = cursor == null;
  let consecutiveFailures = 0;
  /** Images signalées, recette par recette : la liste fermée du rangement. */
  const flagged: FlaggedIllustration[] = [];

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
      let data: Record<string, unknown> = {};
      try {
        data = (doc.data() ?? {}) as Record<string, unknown>;
        const issues = recipeIllustrationIssues(data, { buckets, allowEmulator });
        if (issues.length === 0) {
          response.conformes += 1;
        } else {
          response.horsDossiers += 1;
          for (const key of flaggedIllustrationKeys(data, { buckets, allowEmulator })) {
            flagged.push({ recipe_id: doc.id, key });
          }
          review.add({
            kind: "recipe",
            id: doc.id,
            label: recipeReviewLabel(doc.id, data),
            reason: `Illustration hors des dossiers modérés : ${issues.join(", ")}`,
          });
        }
        consecutiveFailures = 0;
      } catch (e) {
        response.echouees += 1;
        consecutiveFailures += 1;
        review.add({
          kind: "recipe",
          id: doc.id,
          label: recipeReviewLabel(doc.id, data),
          reason: `Recette illisible : ${shortErrorMessage(e)}`,
        });
        await logError("Dossiers des illustrations — échec sur une recette", {
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

  // Seul un parcours entier, parti du début, remplace la liste : un passage
  // repris ne voit pas les recettes des passages précédents.
  if (response.depuisLeDebut && response.completed) {
    await db
      .collection(COLL_APP_CONFIG)
      .doc(backfillRunDocId("illustration_folders"))
      .set(
        {
          signalees: flagged.slice(0, FLAGGED_LIST_LIMIT),
          signalees_tronquee: flagged.length > FLAGGED_LIST_LIMIT,
          signalees_le: FieldValue.serverTimestamp(),
          signalees_par: ctx.userId,
        },
        { merge: true },
      );
  }

  await setBackfillCursor({
    db,
    docId: ILLUSTRATION_FOLDERS_CHECKPOINT_DOC_ID,
    lastDocId: response.completed ? null : cursor,
    operation: FEATURE,
    adminUid: ctx.userId,
  });

  await logInfo({
    message: "Dossiers des illustrations — contrôle",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: { ...withoutReviewList(response), maxDocs: options.maxDocs },
  });

  return response;
}
