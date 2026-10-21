/**
 * Ranger les illustrations — backfill ponctuel d'écriture, sans appel de
 * modèle (suite du contrôle « Dossiers des illustrations », ticket #154).
 *
 * Le contrôle `illustration_folders` liste les recettes dont une URL de
 * `image_urls` ou de `thumbnail_urls` n'est pas sous `illustrations/` ou
 * `recipes/`, et enregistre dans son état la liste fermée des images
 * signalées (`signalees`). L'administrateur a regardé ces images et les garde
 * telles quelles. Seules les images de cette liste, sous `scans/{uid}/` ou
 * `users/{uid}/`, se rangent : une image ajoutée à une
 * recette après le contrôle n'a été vue par personne, et part dans « À
 * revoir ». Sans liste, le passage ne fait rien. Pour chacune, ce passage :
 *
 *  1. copie le fichier vers `recipes/{recipeId}/illus_moved_{empreinte}.{ext}`
 *     (`movedIllustrationPath`), avec le type lu sur ses octets, le cache d'une
 *     illustration publiée et un nouveau jeton de téléchargement ;
 *  2. écrit une ligne `image_moderation` approuvée par décision de
 *     l'administrateur (`manual_folder_move`, `engine: "none"`) : aucune
 *     analyse, rien de facturé ;
 *  3. réécrit, dans une transaction, chaque champ de la recette qui cite le
 *     fichier, sauf les champs du fichier importé (`SOURCE_FIELDS`) ;
 *  4. supprime l'ancien fichier seulement si plus aucun document lu ne le
 *     cite : recettes et brouillons, jobs d'import, livres, comptes, profils,
 *     lignes de modération, sauvegardes, annotations et textes d'origine.
 *     Une lecture inachevée ou en échec le conserve, et le passage suivant
 *     reprend la décision depuis la ligne de modération
 *     (`source_file_status: "keep_unverified"`).
 *
 * Réentrant : une recette rangée n'a plus rien hors des dossiers modérés, et
 * une copie déjà faite est retrouvée par son nom. Ponctuel : un passage qui a
 * lu toutes les recettes, n'en laisse aucune à ranger, aucune à revoir et
 * aucun ancien fichier en attente de décision le marque terminé.
 *
 * Les journaux ne reçoivent que les compteurs : ni titre, ni URL, ni chemin.
 */

import { randomUUID } from "node:crypto";

import { onCall } from "firebase-functions/v2/https";
import {
  FieldValue,
  getFirestore,
  type DocumentData,
  type Query,
  type QueryDocumentSnapshot,
} from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";

import {
  COLL_APP_CONFIG,
  COLL_BACKUP_BOOKS,
  COLL_BACKUP_RECIPES,
  COLL_BOOKS,
  COLL_PROCESSING_JOBS,
  COLL_RECIPES,
  COLL_USERS,
  COLL_USER_PROFILES,
  MAX_CALLABLE_INSTANCES,
  REGION,
} from "../config";
import { logError, logInfo } from "../logging";
import { requireAdmin, type AuthContext } from "./_auth";
import { backfillRunDocId, runBackfillFromCallable } from "../backfills/runner";
import type { PassSummary } from "../backfills/schedule";
import {
  LEGACY_APP_BUCKET,
  illustrationObjectRef,
  type StorageObjectRef,
} from "../backfills/illustrationFolders";
import {
  MOVE_MODERATION_REASON,
  downloadUrlFor,
  illustrationMimeOf,
  moveModerationId,
  movedIllustrationPath,
  objectKey,
  recipeMovePlan,
  referencedObjectKeys,
  rewriteIllustrationReferences,
  readFlaggedList,
  downloadTokensOf,
  scrubbedErrorMessage,
  citationVariants,
  sourceFileDecision,
  sourceFolder,
  type BucketOptions,
  type MovedObject,
  type SourceFileDecision,
} from "../backfills/illustrationFoldersMove";
import { storageEmulatorActive } from "../utils/storagePath";
import {
  BackfillReview,
  recipeReviewLabel,
  type BackfillReviewList,
  withoutReviewList,
} from "./_backfillReview";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const FEATURE = "illustration_folders_move_backfill";
const COLL_IMAGE_MODERATION = "image_moderation";

/** Recettes rangées par appel de la fonction, par défaut. */
const DEFAULT_MAX_RECIPES = 100;
const PAGE_SIZE = 400;
/** Marge gardée sur le délai de la fonction, pour finir les écritures. */
const DEADLINE_MARGIN_MS = 45_000;
/** Part du délai accordée à la lecture des références. */
const INDEX_TIME_SHARE = 0.4;
/** Trois échecs de suite : une panne, pas trois recettes difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;
/** Cache d'une illustration publiée (`illustrations/store.ts`). */
const PUBLISHED_CACHE_CONTROL = "public, max-age=31536000";

/**
 * Collections lues pour savoir si un ancien fichier est encore cité. Les
 * recettes (brouillons compris) sont lues à part, au début du passage.
 */
const REFERENCE_COLLECTIONS: readonly string[] = [
  COLL_PROCESSING_JOBS,
  COLL_BOOKS,
  COLL_USERS,
  COLL_USER_PROFILES,
  COLL_IMAGE_MODERATION,
  COLL_BACKUP_RECIPES,
  COLL_BACKUP_BOOKS,
];
/** Sous-collections des recettes, lues par groupe de collections. */
const REFERENCE_COLLECTION_GROUPS: readonly string[] = ["annotations", "origine"];

/** États d'un ancien fichier qu'un passage suivant doit reprendre. */
const PENDING_SOURCE_STATUSES = new Set(["pending", "keep_unverified", "delete_failed"]);

interface BackfillIllustrationFoldersMoveRequest {
  maxMinutes?: number;
  maxRecipes?: number;
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export interface BackfillIllustrationFoldersMoveResponse {
  /**
   * Pas de liste du contrôle « Dossiers des illustrations » : rien n'a été
   * fait. Il faut d'abord lancer un contrôle complet.
   */
  listeAbsente: boolean;
  /** Recettes lues. */
  examinees: number;
  /** Recettes qui avaient au moins une image à ranger au début du passage. */
  aRanger: number;
  /** Recettes réécrites par ce passage. */
  rangees: number;
  /** Fichiers copiés vers `recipes/{id}/`. */
  imagesCopiees: number;
  /** Copies retrouvées d'un passage précédent interrompu. */
  copiesRetrouvees: number;
  /** Recettes dont une image ne peut pas être rangée (autre bucket…) : à revoir. */
  nonDeplacables: number;
  /** Recettes en échec (fichier introuvable, format, écriture) : à revoir. */
  echouees: number;
  /** Recettes encore à ranger après ce passage (quota, délai, échec). */
  restantes: number;
  /** Anciens fichiers supprimés. */
  anciensSupprimes: number;
  /** Anciens fichiers conservés : un autre document les cite. */
  anciensConservesCites: number;
  /** Anciens fichiers conservés : lecture des références inachevée. */
  anciensEnAttente: number;
  /** Anciens fichiers déjà absents. */
  anciensIntrouvables: number;
  /** Documents lus pour chercher les références. */
  referencesLues: number;
  /** Toutes les collections de références ont été lues jusqu'au bout. */
  indexComplet: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  /** Toutes les recettes ont été lues. */
  completed: boolean;
  aRevoir: BackfillReviewList;
}

export interface IllustrationFoldersMovePassOptions {
  deadlineMs: number;
  maxRecipes: number;
}

export const backfillIllustrationFoldersMoveFn = onCall<BackfillIllustrationFoldersMoveRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: "1GiB",
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req) => {
    const ctx = await requireAdmin(req, FEATURE);

    const maxMinutesRaw = Number(req.data?.maxMinutes ?? 8);
    const maxMinutes = Number.isFinite(maxMinutesRaw)
      ? Math.max(1, Math.min(8.5, maxMinutesRaw))
      : 8;
    const maxRecipesRaw = Number(req.data?.maxRecipes ?? DEFAULT_MAX_RECIPES);
    const maxRecipes = Number.isFinite(maxRecipesRaw)
      ? Math.max(1, Math.min(500, Math.trunc(maxRecipesRaw)))
      : DEFAULT_MAX_RECIPES;
    const options: IllustrationFoldersMovePassOptions = {
      deadlineMs: Date.now() + maxMinutes * 60_000,
      maxRecipes,
    };

    return runBackfillFromCallable({
      key: "illustration_folders_move",
      ctx,
      appVersion: req.data?.appVersion,
      run: () => runIllustrationFoldersMovePass(ctx, options),
      summarize: summarizeIllustrationFoldersMove,
    });
  },
);

/** Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`). */
export function summarizeIllustrationFoldersMove(
  r: BackfillIllustrationFoldersMoveResponse,
): PassSummary {
  const remaining = r.completed && !r.listeAbsente ? r.restantes + r.anciensEnAttente : null;
  return {
    complete: r.completed && remaining === 0,
    remaining,
    toReview: r.aRevoir.total,
    spendCapHit: false,
    unresolved: r.echouees,
  };
}

/** Une recette à ranger, lue au début du passage. */
interface RecipeToMove {
  id: string;
  label: string;
  refs: StorageObjectRef[];
}

/** Un ancien fichier dont le sort reste à décider, et ses lignes de modération. */
interface SourceToDecide {
  ref: StorageObjectRef;
  moderationIds: Set<string>;
}

/** Un passage. Aucun appel de modèle. */
export async function runIllustrationFoldersMovePass(
  ctx: AuthContext,
  options: IllustrationFoldersMovePassOptions,
): Promise<BackfillIllustrationFoldersMoveResponse> {
  const db = getFirestore();
  const startMs = Date.now();
  const deadline = options.deadlineMs - DEADLINE_MARGIN_MS;
  const indexDeadline = startMs + (deadline - startMs) * INDEX_TIME_SHARE;
  const review = new BackfillReview();
  const storage = getStorage();
  const defaultBucket = storage.bucket();
  const opts: BucketOptions = {
    buckets: [defaultBucket.name, LEGACY_APP_BUCKET],
    allowEmulator: storageEmulatorActive(),
  };
  const response: BackfillIllustrationFoldersMoveResponse = {
    listeAbsente: false,
    examinees: 0,
    aRanger: 0,
    rangees: 0,
    imagesCopiees: 0,
    copiesRetrouvees: 0,
    nonDeplacables: 0,
    echouees: 0,
    restantes: 0,
    anciensSupprimes: 0,
    anciensConservesCites: 0,
    anciensEnAttente: 0,
    anciensIntrouvables: 0,
    referencesLues: 0,
    indexComplet: false,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: false,
    aRevoir: { items: [], total: 0 },
  };
  const logCtx = { correlationId: ctx.correlationId, userId: ctx.userId, feature: FEATURE };

  // ── 0. La liste fermée du dernier contrôle complet. Seuls les couples
  // (recette, fichier) qu'il a signalés, et que l'administrateur a regardés,
  // se rangent : une image ajoutée depuis n'a été vue par personne.
  const reviewDoc = await db
    .collection(COLL_APP_CONFIG)
    .doc(backfillRunDocId("illustration_folders"))
    .get();
  const flagged = readFlaggedList(reviewDoc.data()?.signalees);
  if (flagged == null) {
    response.listeAbsente = true;
    await logInfo({
      message: "Ranger les illustrations — aucune liste du contrôle, rien à faire",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      feature: FEATURE,
    });
    return response;
  }

  // ── 1. Toutes les recettes, gardées en mémoire : elles sont aussi des
  // références des anciens fichiers.
  const recipeData = new Map<string, Record<string, unknown>>();
  const toMove: RecipeToMove[] = [];
  /** URL exactes lues dans `image_urls` et `thumbnail_urls`, par objet. */
  const citations = new Map<string, Set<string>>();
  let lastRecipe: QueryDocumentSnapshot | null = null;
  for (;;) {
    if (Date.now() > deadline) {
      response.stoppedByDeadline = true;
      break;
    }
    let query: Query = db.collection(COLL_RECIPES).orderBy("__name__").limit(PAGE_SIZE);
    if (lastRecipe) query = query.startAfter(lastRecipe);
    const page = await query.get();
    for (const doc of page.docs) {
      response.examinees += 1;
      let data: Record<string, unknown> = {};
      try {
        data = (doc.data() ?? {}) as Record<string, unknown>;
        recipeData.set(doc.id, data);
        const plan = recipeMovePlan(data, opts, { recipeId: doc.id, flagged });
        if (plan.blocking.length > 0) {
          response.nonDeplacables += 1;
          review.add({
            kind: "recipe",
            id: doc.id,
            label: recipeReviewLabel(doc.id, data),
            reason: `Image impossible à ranger : ${plan.blocking.join(", ")}`,
          });
        }
        for (const field of ["image_urls", "thumbnail_urls"] as const) {
          const list = data[field];
          if (!Array.isArray(list)) continue;
          for (const url of list) {
            const ref = illustrationObjectRef(url, opts);
            if (ref == null || typeof url !== "string") continue;
            const key = objectKey(ref);
            const seen = citations.get(key) ?? new Set<string>();
            seen.add(url);
            citations.set(key, seen);
          }
        }
        if (plan.refs.length > 0) {
          toMove.push({ id: doc.id, label: recipeReviewLabel(doc.id, data), refs: plan.refs });
        }
      } catch (e) {
        response.echouees += 1;
        review.add({
          kind: "recipe",
          id: doc.id,
          label: recipeReviewLabel(doc.id, data),
          reason: `Recette illisible : ${scrubbedErrorMessage(e)}`,
        });
        await logError("Ranger les illustrations — recette illisible", {
          ...logCtx,
          moduleType: "DESIGN",
          errorDescription: scrubbedErrorMessage(e),
          extra: { recipeId: doc.id },
        });
      }
    }
    if (page.size < PAGE_SIZE) {
      response.completed = !response.stoppedByDeadline;
      break;
    }
    lastRecipe = page.docs[page.docs.length - 1];
  }
  response.aRanger = toMove.length;

  // ── 2. Anciens fichiers laissés en attente par un passage précédent.
  const sources = new Map<string, SourceToDecide>();
  const addSource = (ref: StorageObjectRef, moderationId: string) => {
    const key = objectKey(ref);
    const entry = sources.get(key) ?? { ref, moderationIds: new Set<string>() };
    entry.moderationIds.add(moderationId);
    sources.set(key, entry);
  };
  try {
    const previous = await db
      .collection(COLL_IMAGE_MODERATION)
      .where("decision_reason", "==", MOVE_MODERATION_REASON)
      .get();
    for (const doc of previous.docs) {
      const d = doc.data();
      const bucket = typeof d.moved_from_bucket === "string" ? d.moved_from_bucket : "";
      const path = typeof d.moved_from_path === "string" ? d.moved_from_path : "";
      const status = typeof d.source_file_status === "string" ? d.source_file_status : "";
      if (bucket && path && PENDING_SOURCE_STATUSES.has(status)) {
        addSource({ bucket, path }, doc.id);
      }
    }
  } catch (e) {
    // Sans cette liste, les fichiers en attente ne sont pas repris ce
    // passage-ci : ils restent en place, et le passage n'est pas terminé.
    response.anciensEnAttente += 1;
    await logError("Ranger les illustrations — lignes de modération illisibles", {
      ...logCtx,
      moduleType: "MODERATION",
      errorDescription: scrubbedErrorMessage(e),
    });
  }

  // ── 3. Qui cite encore chaque ancien fichier ?
  const wanted = new Set<string>(sources.keys());
  for (const recipe of toMove) for (const ref of recipe.refs) wanted.add(objectKey(ref));
  const holders = new Map<string, Set<string>>();
  const hold = (holder: string, keys: Iterable<string>) => {
    for (const key of keys) {
      const set = holders.get(key) ?? new Set<string>();
      set.add(holder);
      holders.set(key, set);
    }
  };
  for (const [id, data] of recipeData) {
    hold(`${COLL_RECIPES}/${id}`, referencedObjectKeys(data, wanted, opts));
  }
  response.indexComplet = response.completed;
  if (wanted.size > 0) {
    const scans: { label: string; base: Query }[] = [
      ...REFERENCE_COLLECTIONS.map((c) => ({ label: c, base: db.collection(c) as Query })),
      ...REFERENCE_COLLECTION_GROUPS.map((c) => ({ label: c, base: db.collectionGroup(c) })),
    ];
    for (const scan of scans) {
      const done = await indexCollection({
        scan,
        wanted,
        opts,
        deadlineMs: indexDeadline,
        onDoc: (doc) => {
          response.referencesLues += 1;
          const data = doc.data();
          // Les lignes de ce backfill citent l'ancien chemin pour mémoire.
          if (scan.label === COLL_IMAGE_MODERATION) {
            if (data.decision_reason === MOVE_MODERATION_REASON) return;
          }
          hold(doc.ref.path, referencedObjectKeys(data, wanted, opts));
        },
        logCtx,
      });
      if (!done) response.indexComplet = false;
    }
  }

  // ── 4. Ranger, recette par recette.
  let consecutiveFailures = 0;
  let processed = 0;
  for (const recipe of toMove) {
    if (Date.now() > deadline) {
      response.stoppedByDeadline = true;
      break;
    }
    if (processed >= options.maxRecipes) {
      response.stoppedByBudget = true;
      break;
    }
    if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
      response.stoppedByErrors = true;
      break;
    }
    processed += 1;

    const moves = new Map<string, MovedObject>();
    const failures: string[] = [];
    for (const ref of recipe.refs) {
      try {
        const moved = await copyToRecipeFolder({
          recipeId: recipe.id,
          ref,
          defaultBucketName: defaultBucket.name,
          response,
        });
        if (typeof moved === "string") {
          failures.push(moved);
          continue;
        }
        const moderationId = moveModerationId(recipe.id, ref);
        const createdBy = recipeData.get(recipe.id)?.created_by;
        await db
          .collection(COLL_IMAGE_MODERATION)
          .doc(moderationId)
          .set({
            status: "approved",
            uid: typeof createdBy === "string" && createdBy ? createdBy : ctx.userId,
            quarantine_path: null,
            quarantine_generation: null,
            target_path: moved.path,
            target_kind: "recipe_illustration",
            owner_id: recipe.id,
            mime_type: moved.mime,
            size_bytes: moved.sizeBytes,
            signals: {},
            culinary_matches: [],
            engine: "none",
            engine_version: null,
            decision_reason: MOVE_MODERATION_REASON,
            correlation_id: ctx.correlationId,
            published_url: moved.url,
            rejected_path: null,
            attach_on_approval: false,
            created_at: FieldValue.serverTimestamp(),
            decided_at: FieldValue.serverTimestamp(),
            reviewed_by: ctx.userId,
            reviewed_at: FieldValue.serverTimestamp(),
            review_note:
              `Image déjà affichée, rangée depuis ${sourceFolder(ref.path)} par ` +
              "« Ranger les illustrations » : validée telle quelle par l'administrateur.",
            moved_from_bucket: ref.bucket,
            moved_from_path: ref.path,
            source_file_status: "pending",
          });
        moves.set(objectKey(ref), { path: moved.path, url: moved.url });
        addSource(ref, moderationId);
      } catch (e) {
        failures.push(`copie impossible (${scrubbedErrorMessage(e)})`);
        await logError("Ranger les illustrations — copie en échec", {
          ...logCtx,
          moduleType: "DESIGN",
          errorDescription: scrubbedErrorMessage(e),
          extra: { recipeId: recipe.id, folder: sourceFolder(ref.path) },
        });
      }
    }

    if (moves.size > 0) {
      try {
        const after = await rewriteRecipe(recipe.id, moves, opts);
        if (after == null) {
          failures.push("recette supprimée pendant le passage");
        } else {
          response.rangees += 1;
          // La recette ne cite plus ce qu'elle a quitté.
          const stillCited = referencedObjectKeys(after, wanted, opts);
          const holder = `${COLL_RECIPES}/${recipe.id}`;
          for (const [key, set] of holders) if (!stillCited.has(key)) set.delete(holder);
          hold(holder, stillCited);
        }
      } catch (e) {
        failures.push(`écriture impossible (${scrubbedErrorMessage(e)})`);
        await logError("Ranger les illustrations — réécriture de la recette en échec", {
          ...logCtx,
          moduleType: "DESIGN",
          errorDescription: scrubbedErrorMessage(e),
          extra: { recipeId: recipe.id },
        });
      }
    }

    if (failures.length > 0) {
      response.echouees += 1;
      response.restantes += 1;
      consecutiveFailures += 1;
      review.add({
        kind: "recipe",
        id: recipe.id,
        label: recipe.label,
        reason: `Rangement incomplet : ${failures.join(", ")}`,
      });
    } else {
      consecutiveFailures = 0;
    }
  }
  response.restantes += toMove.length - processed;

  // ── 5. Le sort des anciens fichiers.
  for (const [key, source] of sources) {
    if (Date.now() > options.deadlineMs - 10_000) {
      response.anciensEnAttente += 1;
      continue;
    }
    let status: SourceFileDecision | "delete_failed";
    try {
      const [exists] = await storage.bucket(source.ref.bucket).file(source.ref.path).exists();
      status = sourceFileDecision({
        holders: holders.get(key),
        indexComplete: response.indexComplet,
        sourceExists: exists,
      });
      // Relecture juste avant la suppression : une recette a pu citer le
      // fichier depuis la lecture du début du passage.
      if (status === "delete") {
        const [meta] = await storage.bucket(source.ref.bucket).file(source.ref.path).getMetadata();
        const tokens = downloadTokensOf(meta.metadata);
        if (await citedByRecipe(source.ref, citations.get(key) ?? [], tokens, logCtx)) {
          status = "keep_referenced";
        }
      }
      if (status === "delete") {
        await storage.bucket(source.ref.bucket).file(source.ref.path).delete();
      }
    } catch (e) {
      status = "delete_failed";
      await logError("Ranger les illustrations — ancien fichier non supprimé", {
        ...logCtx,
        moduleType: "DESIGN",
        errorDescription: scrubbedErrorMessage(e),
        extra: { folder: sourceFolder(source.ref.path) },
      });
    }
    if (status === "delete") response.anciensSupprimes += 1;
    else if (status === "keep_referenced") response.anciensConservesCites += 1;
    else if (status === "missing") response.anciensIntrouvables += 1;
    else response.anciensEnAttente += 1;

    const finalStatus = status === "delete" ? "deleted" : status;
    for (const moderationId of source.moderationIds) {
      try {
        await db.collection(COLL_IMAGE_MODERATION).doc(moderationId).update({
          source_file_status: finalStatus,
          source_file_checked_at: FieldValue.serverTimestamp(),
        });
      } catch (e) {
        await logError("Ranger les illustrations — état de l'ancien fichier non écrit", {
          ...logCtx,
          moduleType: "MODERATION",
          errorDescription: scrubbedErrorMessage(e),
          extra: { moderationId, status: finalStatus },
        });
      }
    }
  }

  response.aRevoir = review.toJSON();
  await logInfo({
    message: "Ranger les illustrations — passage",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: { ...withoutReviewList(response), maxRecipes: options.maxRecipes },
  });
  return response;
}

/**
 * Lit une collection de références jusqu'au bout ou jusqu'à l'échéance. Rend
 * `false` si la lecture n'a pas abouti : l'ancien fichier ne sera pas
 * supprimé ce passage-ci.
 */
async function indexCollection(args: {
  scan: { label: string; base: Query };
  wanted: ReadonlySet<string>;
  opts: BucketOptions;
  deadlineMs: number;
  onDoc: (doc: QueryDocumentSnapshot<DocumentData>) => void;
  logCtx: { correlationId: string; userId: string; feature: string };
}): Promise<boolean> {
  let last: QueryDocumentSnapshot | null = null;
  try {
    for (;;) {
      if (Date.now() > args.deadlineMs) return false;
      let query = args.scan.base.orderBy("__name__").limit(PAGE_SIZE);
      if (last) query = query.startAfter(last);
      const page = await query.get();
      for (const doc of page.docs) args.onDoc(doc);
      if (page.size < PAGE_SIZE) return true;
      last = page.docs[page.docs.length - 1];
    }
  } catch (e) {
    await logError("Ranger les illustrations — références illisibles", {
      ...args.logCtx,
      moduleType: "DESIGN",
      errorDescription: scrubbedErrorMessage(e),
      extra: { collection: args.scan.label },
    });
    return false;
  }
}

/**
 * Une recette cite-t-elle encore [ref] dans `image_urls` ou `thumbnail_urls`,
 * sous l'une des formes connues ? Une requête en échec vaut « oui » : dans le
 * doute, le fichier reste.
 */
async function citedByRecipe(
  ref: StorageObjectRef,
  seen: Iterable<string>,
  tokens: readonly string[],
  logCtx: { correlationId: string; userId: string; feature: string },
): Promise<boolean> {
  const db = getFirestore();
  // `array-contains` compare une valeur entière : une requête par forme.
  for (const value of citationVariants(ref, seen, tokens)) {
    for (const field of ["image_urls", "thumbnail_urls"]) {
      try {
        const hit = await db
          .collection(COLL_RECIPES)
          .where(field, "array-contains", value)
          .limit(1)
          .get();
        if (!hit.empty) return true;
      } catch (e) {
        await logError("Ranger les illustrations — relecture avant suppression en échec", {
          ...logCtx,
          moduleType: "DESIGN",
          errorDescription: scrubbedErrorMessage(e),
          extra: { field, folder: sourceFolder(ref.path) },
        });
        return true;
      }
    }
  }
  return false;
}

/** Une copie faite ou retrouvée. */
interface CopiedImage {
  path: string;
  url: string;
  mime: "image/jpeg" | "image/png" | "image/webp";
  sizeBytes: number;
}

/**
 * Copie [ref] vers le dossier de la recette, ou retrouve la copie d'un passage
 * interrompu. Pose le type, le cache et un nouveau jeton : la copie ne
 * s'ouvre pas avec le jeton de l'ancien fichier. Rend la raison d'un refus
 * (fichier introuvable, format) sous forme de chaîne ; lève sur une panne.
 */
async function copyToRecipeFolder(args: {
  recipeId: string;
  ref: StorageObjectRef;
  defaultBucketName: string;
  response: BackfillIllustrationFoldersMoveResponse;
}): Promise<CopiedImage | string> {
  const storage = getStorage();
  const source = storage.bucket(args.ref.bucket).file(args.ref.path);
  const [exists] = await source.exists();
  if (!exists) return `fichier introuvable dans ${sourceFolder(args.ref.path)}`;
  const [head] = await source.download({ start: 0, end: 15 });
  const mime = illustrationMimeOf(head);
  if (mime == null) return "fichier qui n'est pas une image JPEG, PNG ou WebP";
  const [meta] = await source.getMetadata();

  const path = movedIllustrationPath(args.recipeId, args.ref, mime);
  const target = storage.bucket(args.defaultBucketName).file(path);
  const [already] = await target.exists();
  if (already) {
    args.response.copiesRetrouvees += 1;
  } else {
    await source.copy(target);
    args.response.imagesCopiees += 1;
  }
  const token = randomUUID();
  await target.setMetadata({
    contentType: mime,
    cacheControl: PUBLISHED_CACHE_CONTROL,
    metadata: {
      firebaseStorageDownloadTokens: token,
      moderation_status: "approved",
      moderation_id: moveModerationId(args.recipeId, args.ref),
      moderated_at: new Date().toISOString(),
    },
  });
  const size = Number(meta.size);
  return {
    path,
    url: downloadUrlFor(args.defaultBucketName, path, token),
    mime,
    sizeBytes: Number.isFinite(size) ? size : 0,
  };
}

/**
 * Réécrit la recette dans une transaction, sur sa version relue : une
 * modification faite entre-temps par un membre n'est pas écrasée. Rend la
 * recette après écriture, ou `null` si elle n'existe plus. `updated_at`
 * n'est pas touché : le contenu de la recette ne change pas.
 */
async function rewriteRecipe(
  recipeId: string,
  moves: ReadonlyMap<string, MovedObject>,
  opts: BucketOptions,
): Promise<Record<string, unknown> | null> {
  const db = getFirestore();
  const ref = db.collection(COLL_RECIPES).doc(recipeId);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return null;
    const data = (snap.data() ?? {}) as Record<string, unknown>;
    const { update } = rewriteIllustrationReferences(data, moves, opts);
    if (Object.keys(update).length > 0) tx.update(ref, update);
    return { ...data, ...update };
  });
}
