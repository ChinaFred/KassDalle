/**
 * Import d'une recette depuis un lien : l'entrée HTTPS.
 *
 * `importRecipeFromUrlFn` ne lit pas la page. Elle vérifie, dans cet ordre :
 * le rôle (éditeur ou administrateur), l'adresse (forme et résolution DNS
 * publique), le doublon dans les recettes du compte, puis le plafond du jour —
 * et crée le job `recipeUrlImport`, que le pipeline asynchrone traite comme
 * tout import (`jobDispatcher` → `recipeProcessor`).
 *
 * Le client ne crée pas ce type de job lui-même : les règles Firestore le
 * refusent. Sans cela, le plafond et le contrôle du doublon se contournaient
 * par une écriture directe dans `processing_jobs`.
 *
 * Les issues attendues — adresse mal formée, refusée, déjà importée, plafond
 * atteint — sont des réponses, pas des erreurs : le client les affiche dans la
 * boîte, sans rapport d'erreur.
 *
 * `getUrlImportQuotaFn` rend le compteur, pour l'afficher à l'ouverture.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";

import {
  COLL_PROCESSING_JOBS,
  COLL_RECIPES,
  COLL_URL_IMPORT_DAILY,
  MAX_CALLABLE_INSTANCES,
  REGION,
} from "../config";
import { requireEditor } from "./_auth";
import { budgetMultiplierFor, spendDay } from "../ai/budget";
import { logInfo, logWarn, newScanId } from "../logging";
import { UrlRefusedError, assertPublicHost, parseImportUrl } from "../web/urlGuard";
import { URL_IMPORT_JOB_TYPE, WEB_BOOK_TITLE } from "../pipeline/urlImport";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const opts = {
  region: REGION,
  cors: ALLOWED_ORIGINS,
  maxInstances: MAX_CALLABLE_INSTANCES,
  timeoutSeconds: 30,
};

/** Imports par lien autorisés par jour et par compte, avant multiplicateur. */
export const URL_IMPORT_DAILY_LIMIT = 10;

/** Le plafond d'un compte : dix, multiplié pour le fondateur (`budgetMultiplierFor`). */
export function urlImportLimit(multiplier: number): number {
  return URL_IMPORT_DAILY_LIMIT * Math.max(1, Math.floor(multiplier));
}

/** Imports restants. Pure, testée. */
export function remainingImports(used: number, limit: number): number {
  return Math.max(0, limit - Math.max(0, used));
}

function counterRef(uid: string, at = new Date()) {
  return getFirestore()
    .collection(COLL_URL_IMPORT_DAILY)
    .doc(`${uid}_${spendDay(at)}`);
}

function readCount(data: FirebaseFirestore.DocumentData | undefined): number {
  const n = data?.count;
  return typeof n === "number" && Number.isFinite(n) && n > 0 ? n : 0;
}

/** Le compteur du jour : plafond, utilisés, restants. */
export const getUrlImportQuotaFn = onCall(opts, async (req) => {
  const ctx = await requireEditor(req, "url_import_quota");
  const limit = urlImportLimit(await budgetMultiplierFor(ctx.userId));
  const used = readCount((await counterRef(ctx.userId).get()).data());
  return { limit, used, remaining: remainingImports(used, limit) };
});

export const importRecipeFromUrlFn = onCall(opts, async (req) => {
  const ctx = await requireEditor(req, "url_import");
  const data = (req.data ?? {}) as Record<string, unknown>;
  const force = data.force === true;

  let parsed;
  try {
    parsed = parseImportUrl(data.url);
    await assertPublicHost(parsed.url);
  } catch (err) {
    if (!(err instanceof UrlRefusedError)) throw err;
    // Refus attendu : journalisé en avertissement, rendu comme une réponse.
    await logWarn({
      message: `Import par lien refusé : ${err.reason}`,
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      feature: "url_import",
      moduleType: "IMPORT",
      extra: { reason: err.reason, detail: err.message },
    });
    return { status: err.notAWebLink ? "invalid_url" : "refused" };
  }

  const db = getFirestore();
  if (!force) {
    const dup = await db
      .collection(COLL_RECIPES)
      .where("created_by", "==", ctx.userId)
      .where("source_url", "==", parsed.normalized)
      .limit(1)
      .get();
    if (!dup.empty) {
      const doc = dup.docs[0];
      return {
        status: "duplicate",
        recipeId: doc.id,
        titre: (doc.get("titre") as string | undefined) ?? "",
      };
    }
  }

  const limit = urlImportLimit(await budgetMultiplierFor(ctx.userId));
  const counter = counterRef(ctx.userId);
  const jobRef = db.collection(COLL_PROCESSING_JOBS).doc();
  const scanId = newScanId();

  const outcome = await db.runTransaction(async (tx) => {
    const used = readCount((await tx.get(counter)).data());
    if (used >= limit) return { queued: false as const, used };
    const now = Timestamp.now();
    tx.set(
      counter,
      {
        uid: ctx.userId,
        day: spendDay(new Date()),
        count: FieldValue.increment(1),
        updated_at: now,
      },
      { merge: true },
    );
    tx.set(jobRef, {
      type: URL_IMPORT_JOB_TYPE,
      status: "queued",
      created_by: ctx.userId,
      created_at: now,
      updated_at: now,
      file_name: parsed.site,
      file_url: "",
      mime_type: "text/html",
      source_url: parsed.normalized,
      book_id: null,
      book_titre: WEB_BOOK_TITLE,
      created_recipe_ids: [],
      created_book_id: null,
      error_message: null,
      additional_file_urls: [],
      import_illustrations: false,
      scan_id: scanId,
      forced_duplicate: force,
    });
    return { queued: true as const, used: used + 1 };
  });

  if (!outcome.queued) {
    return { status: "quota_exceeded", limit, remaining: 0 };
  }

  await logInfo({
    message: `Import par lien mis en file : ${parsed.site}`,
    userId: ctx.userId,
    correlationId: ctx.correlationId,
    scanId,
    jobId: jobRef.id,
    feature: "url_import",
    moduleType: "IMPORT",
    extra: { site: parsed.site, force },
  });

  return {
    status: "queued",
    jobId: jobRef.id,
    limit,
    remaining: remainingImports(outcome.used, limit),
  };
});
