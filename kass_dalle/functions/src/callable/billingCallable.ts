/**
 * Cloud Function HTTPS Callable : `getGcpCostsFn`.
 *
 * Requête BigQuery l'export de facturation Cloud Billing pour retourner
 * les coûts GCP agrégés par service sur une période donnée.
 *
 * Pré-requis (côté Console GCP, fait par l'admin) :
 *   Facturation → Exportation BigQuery → activer "Données d'utilisation
 *   standard" vers le dataset `billing_export` du projet `kassdale-6d948`.
 *
 * La fonction utilise un wildcard `gcp_billing_export_v1_*` pour éviter
 * de hardcoder l'ID du compte de facturation. Si la table n'existe pas
 * encore (export tout juste activé), retourne un résultat vide avec
 * `ready: false`.
 *
 * Sécurité : admin uniquement.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { BigQuery } from "@google-cloud/bigquery";
import { Logging } from "@google-cloud/logging";
import { getStorage } from "firebase-admin/storage";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { createHash } from "node:crypto";

import {
  REGION,
  COLL_AI_USAGE,
  LOG_NAME,
  GEMINI_MODEL,
  COLL_RECIPES,
  GEMINI_API_KEY,
  COLL_AI_RECONCILIATION_MONTHLY,
} from "../config";
import { computeAndPersistRecipeNutrition } from "./nutritionCallable";
import { requireAdmin } from "./_auth";
import { logError, logInfo } from "../logging";
import { consolidateShoppingList, type ShoppingIngredientInput } from "../gemini/shopping";
import { callGemini, extractJsonObject, textPart } from "../gemini/client";
import { normalizeNutrients } from "../nutrition/nutrients";

const DATASET = "billing_export";
const TABLE_WILDCARD = "gcp_billing_export_v1_*";

// Origines web autorisées pour les appels callable depuis le navigateur.
// Sans cette config CORS, le preflight OPTIONS est rejeté et le client web
// reçoit `ClientException: Failed to fetch` (même symptôme que les callables
// Gemini sans `cors`). Doit rester aligné avec geminiCallables.ts.
const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

interface GetGcpCostsRequest {
  /** Borne basse (inclusive) en millisecondes epoch. */
  startMs: number;
  /** Borne haute (exclusive) en millisecondes epoch. */
  endMs: number;
}

interface ServiceCostDto {
  service: string;
  /** Coût net en USD (coût brut + crédits, donc déjà déduit). */
  costUsd: number;
  /** Coût brut avant crédits, en USD. */
  grossUsd: number;
  /** Somme des crédits (négatifs typiquement), en USD. */
  creditsUsd: number;
}

interface GetGcpCostsResponse {
  /** False si la table d'export n'existe pas encore. */
  ready: boolean;
  services: ServiceCostDto[];
  totalUsd: number;
  totalGrossUsd: number;
  totalCreditsUsd: number;
  currency: string;
  /** Indique si des données ont été trouvées sur la période. */
  hasData: boolean;
}

const bigquery = new BigQuery();
const logging = new Logging();
async function ensureAdminWithAudit(req: Parameters<typeof requireAdmin>[0], op: string): Promise<void> {
  try {
    await requireAdmin(req);
  } catch (err) {
    const errMsg = err instanceof Error ? err.message : String(err);
    await logError({
      message: `${op}: accès refusé`,
      errorDescription: errMsg,
      extra: { uid: req.auth?.uid ?? null },
    });
    throw err;
  }
}

interface BackfillAiUsageFromLogsRequest {
  startMs: number;
  endMs: number;
}

interface BackfillAiUsageFromLogsResponse {
  created: number;
  skipped: number;
  scanned: number;
  skippedNotGeminiSuccess?: number;
  skippedMissingFeatureOrUsage?: number;
  skippedAlreadyExists?: number;
}

const GEMINI_IMAGE_MODEL = "gemini-2.5-flash-image";

interface BackfillShoppingProductsRequest {
  limit?: number;
  onlyMissing?: boolean;
}

interface BackfillShoppingProductsResponse {
  scanned: number;
  updated: number;
  skipped: number;
  failed: number;
  stoppedByDeadline?: boolean;
  // Nombre de recettes restant à traiter (page_type recipe avec
  // shopping_products manquant ou vide) APRÈS ce passage.
  remaining: number;
}

interface GenerateAiReconciliationMonthlyRequest {
  period?: string; // YYYY-MM
}

interface GenerateAiReconciliationMonthlyResponse {
  period: string;
  estimatedTraceableUsd: number;
  billedIaUsd: number;
  unattributedUsd: number;
  deltaUsd: number;
  reportId: string;
}

interface BackfillRecipeNutritionRequest {
  limit?: number;
  onlyMissing?: boolean;
}

interface BackfillRecipeNutritionResponse {
  scanned: number;
  updated: number;
  skipped: number;
  failed: number;
  stoppedByDeadline?: boolean;
  remaining: number;
}

interface BackfillNutritionIngredientsFromRecipesRequest {
  limit?: number;
}

interface BackfillNutritionIngredientsFromRecipesResponse {
  scannedRecipes: number;
  scannedIngredients: number;
  created: number;
  updatedExisting: number;
  skippedInvalid: number;
  failed: number;
  stoppedByDeadline?: boolean;
}

interface BackfillNutritionIngredientsPer100gRequest {
  limit?: number;
  onlyPending?: boolean;
}

interface BackfillNutritionIngredientsPer100gResponse {
  scanned: number;
  enriched: number;
  skippedNoName: number;
  skippedHasPer100g: number;
  failed: number;
  remaining: number;
  stoppedByDeadline?: boolean;
}

function quote(value: string): string {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

function toNumber(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function toDate(value: unknown): Date {
  if (typeof value === "string") {
    const d = new Date(value);
    if (!isNaN(d.getTime())) return d;
  }
  if (value && typeof value === "object") {
    const v = value as { seconds?: number; nanos?: number };
    if (typeof v.seconds === "number") {
      return new Date(v.seconds * 1000 + Math.floor((v.nanos ?? 0) / 1e6));
    }
  }
  return new Date();
}

function normalizeIngredientKey(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_|_$/g, "");
}

function asNonEmptyString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const out = value.trim();
  return out.length > 0 ? out : null;
}

function hasPer100gValues(value: unknown): boolean {
  if (!value || typeof value !== "object") return false;
  const record = value as Record<string, unknown>;
  for (const v of Object.values(record)) {
    if (typeof v === "number" && Number.isFinite(v) && v > 0) {
      return true;
    }
    if (typeof v === "string") {
      const parsed = Number(v.replace(",", "."));
      if (Number.isFinite(parsed) && parsed > 0) {
        return true;
      }
    }
  }
  return false;
}

async function estimatePer100gWithGemini(params: {
  apiKey: string;
  ingredientId: string;
  canonicalName: string;
  aliases: string[];
  correlationId: string;
}): Promise<Record<string, number>> {
  const aliases = params.aliases
    .map((a) => a.trim())
    .filter((a) => a.length > 0)
    .slice(0, 8)
    .join(", ");

  const prompt = [
    "Tu es un expert nutrition.",
    "Retourne UNIQUEMENT un objet JSON valide sans markdown.",
    "But: estimer les nutriments pour 100g d'ingrédient brut standard.",
    "N'invente pas d'unités exotiques.",
    "Champs autorisés (nombres >= 0): kcal, protein_g, carbs_g, sugar_g, fiber_g, fat_g, saturated_fat_g, sodium_mg, salt_g.",
    "Si inconnu: mets 0.",
    "Format strict attendu:",
    '{"per100g":{"kcal":0,"protein_g":0,"carbs_g":0,"sugar_g":0,"fiber_g":0,"fat_g":0,"saturated_fat_g":0,"sodium_mg":0,"salt_g":0}}',
    `ingredient_id: ${params.ingredientId}`,
    `nom canonique: ${params.canonicalName}`,
    `aliases: ${aliases || "(aucun)"}`,
  ].join("\n");

  const result = await callGemini(
    params.apiKey,
    [textPart(prompt)],
    {
      correlationId: params.correlationId,
      feature: "nutrition_ingredients_enrichment",
      moduleType: "DESIGN",
      timeoutMs: 45_000,
    },
  );

  const text = (result.response.text() ?? "").trim();
  if (!text) {
    return {};
  }

  const parsed = JSON.parse(extractJsonObject(text)) as Record<string, unknown>;
  const rawPer100g = (
    parsed.per100g && typeof parsed.per100g === "object"
      ? parsed.per100g
      : parsed
  ) as Record<string, unknown>;

  return normalizeNutrients(rawPer100g);
}

type ErrorInfo = {
  name: string;
  message: string;
  stack?: string;
  code?: string;
};

function getErrorInfo(err: unknown): ErrorInfo {
  const asRecord = (err && typeof err === "object") ? (err as Record<string, unknown>) : null;
  const name = err instanceof Error
    ? err.name
    : String(asRecord?.name ?? "Error");
  const message = err instanceof Error
    ? err.message
    : String(asRecord?.message ?? err);
  const stackRaw = err instanceof Error
    ? err.stack
    : (typeof asRecord?.stack === "string" ? asRecord.stack : undefined);
  const codeRaw = asRecord?.code;
  const code = typeof codeRaw === "string" || typeof codeRaw === "number"
    ? String(codeRaw)
    : undefined;
  return {
    name,
    message,
    stack: stackRaw?.slice(0, 8000),
    code,
  };
}

async function logFailure(params: {
  operation: string;
  correlationId: string;
  req: Parameters<typeof requireAdmin>[0];
  err: unknown;
  extra?: Record<string, unknown>;
}): Promise<void> {
  const info = getErrorInfo(params.err);
  await logError({
    message: `${params.operation}: ERREUR`,
    correlationId: params.correlationId,
    errorDescription: info.message,
    extra: {
      adminUid: params.req.auth?.uid ?? null,
      errorName: info.name,
      errorCode: info.code ?? null,
      errorStack: info.stack ?? null,
      ...params.extra,
    },
  });
}

export const getGcpCostsFn = onCall<GetGcpCostsRequest>(
  {
    region: REGION,
    timeoutSeconds: 60,
    memory: "256MiB",
    cors: ALLOWED_ORIGINS,
  },
  async (req) => {
    await ensureAdminWithAudit(req, "getGcpCostsFn");
    const correlationId = `gcp-costs-${Date.now()}`;

    const projectId = process.env.GCLOUD_PROJECT ?? process.env.GCP_PROJECT;
    if (!projectId) {
      throw new HttpsError("internal", "Project ID indisponible.");
    }

    const data = req.data ?? ({} as GetGcpCostsRequest);
    const startMs = Number(data.startMs);
    const endMs = Number(data.endMs);
    if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs <= startMs) {
      throw new HttpsError(
        "invalid-argument",
        "startMs / endMs invalides (ms epoch, end > start).",
      );
    }

    // Limite à 13 mois glissants max pour éviter un scan trop large.
    const maxRangeMs = 400 * 24 * 60 * 60 * 1000;
    if (endMs - startMs > maxRangeMs) {
      throw new HttpsError(
        "invalid-argument",
        "Plage trop large (max 13 mois).",
      );
    }

    const tableRef = `\`${projectId}.${DATASET}.${TABLE_WILDCARD}\``;

    // Filtre `usage_start_time` (instant de consommation, plus précis que
    // `_PARTITIONTIME` qui correspond à la date d'export, en retard d'~24h).
    const sql = `
      SELECT
        service.description AS service,
        SUM(cost) AS gross_usd,
        COALESCE(SUM((
          SELECT SUM(c.amount) FROM UNNEST(credits) c
        )), 0) AS credits_usd,
        currency
      FROM ${tableRef}
      WHERE usage_start_time >= TIMESTAMP_MILLIS(@startMs)
        AND usage_start_time < TIMESTAMP_MILLIS(@endMs)
      GROUP BY service, currency
      ORDER BY gross_usd DESC
    `;

    try {
      const [rows] = await bigquery.query({
        query: sql,
        params: { startMs, endMs },
        types: { startMs: "INT64", endMs: "INT64" },
        location: "EU",
      });

      let currency = "USD";
      const services: ServiceCostDto[] = rows.map((r) => {
        const gross = Number(r.gross_usd ?? 0);
        const credits = Number(r.credits_usd ?? 0);
        if (typeof r.currency === "string" && r.currency.length > 0) {
          currency = r.currency;
        }
        return {
          service: String(r.service ?? "Inconnu"),
          costUsd: gross + credits,
          grossUsd: gross,
          creditsUsd: credits,
        };
      });

      const totalGrossUsd = services.reduce((s, x) => s + x.grossUsd, 0);
      const totalCreditsUsd = services.reduce((s, x) => s + x.creditsUsd, 0);

      const resp: GetGcpCostsResponse = {
        ready: true,
        services,
        totalUsd: totalGrossUsd + totalCreditsUsd,
        totalGrossUsd,
        totalCreditsUsd,
        currency,
        hasData: services.length > 0,
      };
      return resp;
    } catch (err) {
      const info = getErrorInfo(err);
      // Table pas encore créée par l'export (peut prendre 24h).
      if (
        info.message.includes("Not found") ||
        info.message.includes("does not match any table") ||
        info.message.includes("matched no table")
      ) {
        await logInfo({
          message: "getGcpCostsFn: export BigQuery non prêt",
          correlationId,
          extra: { startMs, endMs },
        });
        const resp: GetGcpCostsResponse = {
          ready: false,
          services: [],
          totalUsd: 0,
          totalGrossUsd: 0,
          totalCreditsUsd: 0,
          currency: "USD",
          hasData: false,
        };
        return resp;
      }
      await logFailure({
        operation: "getGcpCostsFn",
        correlationId,
        req,
        err,
        extra: { startMs, endMs },
      });
      throw new HttpsError(
        "internal",
        `Erreur interne getGcpCostsFn (corr=${correlationId})`,
        { correlationId },
      );
    }
  },
);

/**
 * Reconstruit rétroactivement les entrées `ai_usage` pour les améliorations
 * d'images passées (feature `enhance_illustration`) en scannant Firebase Storage.
 *
 * Chaque fichier `illustrations/{uid}/{ts}_enhanced.*` donne lieu à un document
 * `ai_usage` avec un ID déterministe (basé sur le chemin Storage) pour que la
 * fonction soit idempotente (aucun doublon si appelée plusieurs fois).
 *
 * Retourne : { created, skipped, total }
 */
export const backfillEnhanceUsageFn = onCall(
  { region: REGION, timeoutSeconds: 300, memory: "256MiB" as const, cors: ALLOWED_ORIGINS },
  async (req) => {
    await ensureAdminWithAudit(req, "backfillEnhanceUsage");

    const correlationId = `backfill-enhance-${Date.now()}`;
    await logInfo({
      message: "backfillEnhanceUsage: démarrage",
      correlationId,
      extra: { adminUid: req.auth?.uid },
    });

    try {
      const bucket = getStorage().bucket();
      const db = getFirestore();

      // Liste tous les fichiers sous illustrations/
      const [files] = await bucket.getFiles({ prefix: "illustrations/" });

      // Filtre uniquement les fichiers *_enhanced.*
      const enhanced = files.filter((f) => f.name.includes("_enhanced"));

      let created = 0;
      let skipped = 0;

      for (const file of enhanced) {
        // Path attendu : illustrations/{uid}/{ts}_enhanced.{ext}
        const segments = file.name.split("/");
        if (segments.length < 3) { skipped++; continue; }

        const uid = segments[1];
        const filename = segments[2];
        const tsStr = filename.split("_")[0];
        const ts = parseInt(tsStr, 10);

        // Sanity check : ts doit être un timestamp milliseconde plausible (> jan 2020)
        if (isNaN(ts) || ts < 1577836800000) { skipped++; continue; }

        // ID déterministe basé sur le chemin Storage → idempotent
        const docId = "backfill_" + file.name.replace(/[/.]/g, "_");
        const docRef = db.collection(COLL_AI_USAGE).doc(docId);

        // Crée uniquement si absent (évite d'écraser une entrée retouchée manuellement)
        const snap = await docRef.get();
        if (snap.exists) { skipped++; continue; }

        await docRef.set({
          uid,
          feature: "enhance_illustration",
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          image_output_count: 1,
          model: "gemini-2.5-flash-image",
          timestamp: new Date(ts),
          backfilled: true,
        });
        created++;
      }

      await logInfo({
        message: `backfillEnhanceUsage: terminé — created=${created} skipped=${skipped} total=${enhanced.length}`,
        correlationId,
        extra: { created, skipped, total: enhanced.length },
      });

      return { created, skipped, total: enhanced.length };
    } catch (err) {
      await logFailure({
        operation: "backfillEnhanceUsage",
        correlationId,
        req,
        err,
      });
      throw new HttpsError(
        "internal",
        `Erreur interne backfillEnhanceUsage (corr=${correlationId})`,
        { correlationId },
      );
    }
  },
);

/**
 * Backfill `ai_usage` à partir des logs Cloud Logging "Gemini call OK (...)".
 *
 * Usage:
 * - cible les appels texte/tokens non comptabilisés dans `ai_usage`
 * - crée des docs idempotents basés sur `insertId` (ou hash fallback)
 * - n'écrase pas les documents existants
 */
export const backfillAiUsageFromLogsFn = onCall<BackfillAiUsageFromLogsRequest>(
  { region: REGION, timeoutSeconds: 300, memory: "512MiB", cors: ALLOWED_ORIGINS },
  async (req): Promise<BackfillAiUsageFromLogsResponse> => {
    await ensureAdminWithAudit(req, "backfillAiUsageFromLogs");

    const projectId = process.env.GCLOUD_PROJECT ?? process.env.GCP_PROJECT;
    if (!projectId) {
      throw new HttpsError("internal", "Project ID indisponible.");
    }

    const data = req.data ?? ({} as BackfillAiUsageFromLogsRequest);
    const startMs = Number(data.startMs);
    const endMs = Number(data.endMs);
    if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs <= startMs) {
      throw new HttpsError(
        "invalid-argument",
        "startMs / endMs invalides (ms epoch, end > start).",
      );
    }

    const correlationId = `backfill-logs-${Date.now()}`;
    await logInfo({
      message: "backfillAiUsageFromLogs: démarrage",
      correlationId,
      extra: { adminUid: req.auth?.uid, startMs, endMs },
    });

    const db = getFirestore();
    const startIso = new Date(startMs).toISOString();
    const endIso = new Date(endMs).toISOString();
    const geminiSuccessMessagesFilter = [
      `jsonPayload.message:${quote("Gemini call OK (")}`,
      `jsonPayload.message:${quote("Gemini image enhance OK")}`,
      `jsonPayload.message:${quote("Gemini image generate OK")}`,
    ].join(" OR ");

    const filter = [
      `logName=${quote(`projects/${projectId}/logs/${LOG_NAME}`)}`,
      "severity=INFO",
      `timestamp >= ${quote(startIso)}`,
      `timestamp < ${quote(endIso)}`,
      `(${["jsonPayload.geminiStatus=\"SUCCESS\"", geminiSuccessMessagesFilter].join(" OR ")})`,
    ].join(" AND ");

    let pageToken: string | undefined;
    let created = 0;
    let skipped = 0;
    let scanned = 0;
    let skippedNotGeminiSuccess = 0;
    let skippedMissingFeatureOrUsage = 0;
    let skippedAlreadyExists = 0;

    try {
    do {
      const [entries, nextQuery] = await logging.getEntries({
        filter,
        pageSize: 500,
        orderBy: "timestamp desc",
        autoPaginate: false,
        pageToken,
      });

      for (const entry of entries) {
        scanned++;

        const meta = (entry.metadata ?? {}) as {
          insertId?: string;
          timestamp?: string | { seconds?: number; nanos?: number };
          labels?: Record<string, string>;
        };
        const payload = ((entry.data ?? {}) as Record<string, unknown>) ?? {};
        const extra = ((payload.extra ?? {}) as Record<string, unknown>) ?? {};

        const message = String(payload.message ?? "");
        const isTokenCall = message.includes("Gemini call OK (");
        const isImageCall = message.includes("Gemini image enhance OK");
        const isSuccessByStatus = String(payload.geminiStatus ?? "") === "SUCCESS";
        if (!isSuccessByStatus && !isTokenCall && !isImageCall) {
          skippedNotGeminiSuccess++;
          skipped++;
          continue;
        }

        const feature = String(extra.feature ?? "").trim();
        const uidRaw = String(payload.userId ?? meta.labels?.userId ?? "").trim();
        const uid = uidRaw || "non_attribue";
        const input = toNumber(extra.inputTokens);
        const output = toNumber(extra.outputTokens);
        const imageOutputCount = isImageCall ? 1 : 0;
        const total = toNumber(extra.totalTokens) || input + output;

        if (!feature || (total <= 0 && imageOutputCount === 0)) {
          skippedMissingFeatureOrUsage++;
          skipped++;
          continue;
        }

        const insertId = (meta.insertId ?? "").trim();
        const fallbackKey = createHash("sha1")
          .update(
            `${uid}|${feature}|${input}|${output}|${total}|${String(payload.correlationId ?? "")}`,
          )
          .digest("hex")
          .slice(0, 24);
        const docId = `log_${insertId || fallbackKey}`.replace(/[^a-zA-Z0-9_-]/g, "_");
        const docRef = db.collection(COLL_AI_USAGE).doc(docId);
        const exists = await docRef.get();
        if (exists.exists) {
          skippedAlreadyExists++;
          skipped++;
          continue;
        }

        await docRef.set({
          uid,
          feature,
          input_tokens: input,
          output_tokens: output,
          total_tokens: total,
          image_output_count: imageOutputCount,
          model: isImageCall ? GEMINI_IMAGE_MODEL : GEMINI_MODEL,
          timestamp: toDate(meta.timestamp),
          backfilled: true,
          backfill_source: "cloud_logging",
          log_insert_id: insertId || null,
          correlation_id: String(payload.correlationId ?? "") || null,
        });
        created++;
      }

      pageToken = (nextQuery as { pageToken?: string } | undefined)?.pageToken;
    } while (pageToken);

    await logInfo({
      message: `backfillAiUsageFromLogs: terminé — created=${created} skipped=${skipped} scanned=${scanned}`,
      correlationId,
      extra: {
        created,
        skipped,
        scanned,
        skippedNotGeminiSuccess,
        skippedMissingFeatureOrUsage,
        skippedAlreadyExists,
      },
    });

    return {
      created,
      skipped,
      scanned,
      skippedNotGeminiSuccess,
      skippedMissingFeatureOrUsage,
      skippedAlreadyExists,
    };
    } catch (err) {
      await logFailure({
        operation: "backfillAiUsageFromLogs",
        correlationId,
        req,
        err,
        extra: { startMs, endMs },
      });
      throw new HttpsError(
        "internal",
        `Erreur interne backfillAiUsageFromLogs (corr=${correlationId})`,
        { correlationId },
      );
    }
  },
);

/**
 * Backfill des `shopping_products` dans `recipes`.
 *
 * - cible les recettes (page_type absent ou "recipe")
 * - lit le champ `ingredients`
 * - calcule les produits consolidés via Gemini
 * - met à jour `shopping_products`
 *
 * Paramètres:
 * - `limit` (optionnel, défaut 10, max 50)
 * - `onlyMissing` (optionnel, défaut true) : si true, ignore les docs qui ont
 *   déjà un tableau `shopping_products` non vide.
 */
export const backfillShoppingProductsFn = onCall<BackfillShoppingProductsRequest>(
  {
    region: REGION,
    timeoutSeconds: 300,
    memory: "512MiB",
    secrets: [GEMINI_API_KEY],
    cors: ALLOWED_ORIGINS,
  },
  async (req): Promise<BackfillShoppingProductsResponse> => {
    const correlationId = `backfill-shopping-${Date.now()}`;

    try {
      await ensureAdminWithAudit(req, "backfillShoppingProducts");

      await logInfo({
        message: "backfillShoppingProducts: étape 1/4 - admin validé",
        correlationId,
        extra: { adminUid: req.auth?.uid },
      });

      const data = req.data ?? {};
      const limitRaw = Number(data.limit ?? 10);
      const limit = Number.isFinite(limitRaw)
        ? Math.max(1, Math.min(50, Math.trunc(limitRaw)))
        : 10;
      const onlyMissing = data.onlyMissing !== false;

      // Budget runtime: on s'arrête avant le timeout callable (300s) pour
      // éviter un échec générique `internal` côté client.
      const startedAt = Date.now();
      const softDeadlineMs = startedAt + 240_000;
      const pageSize = Math.max(10, Math.min(40, limit * 2));
      const maxScanned = Math.max(pageSize, Math.min(1000, limit * 20));

      await logInfo({
        message: "backfillShoppingProducts: étape 2/4 - paramètres résolus, démarrage du scan",
        correlationId,
        extra: { adminUid: req.auth?.uid, limit, onlyMissing, pageSize, maxScanned },
      });

      const db = getFirestore();

      let scanned = 0;
      let updated = 0;
      let skipped = 0;
      let failed = 0;

      let stoppedByDeadline = false;
      let lastDocId: string | null = null;

      while (Date.now() < softDeadlineMs && scanned < maxScanned && (updated + failed) < limit) {
        let query = db
          .collection(COLL_RECIPES)
          .orderBy("__name__")
          .limit(pageSize);
        if (lastDocId) {
          query = query.startAfter(lastDocId);
        }

        const snap = await query.get();
        if (snap.empty) break;

        await logInfo({
          message: "backfillShoppingProducts: étape 3/4 - page Firestore récupérée",
          correlationId,
          extra: { pageDocs: snap.size, lastDocId, scanned, updated, skipped, failed },
        });

        for (const doc of snap.docs) {
          if (Date.now() >= softDeadlineMs) {
            stoppedByDeadline = true;
            break;
          }
          if (scanned >= maxScanned || (updated + failed) >= limit) {
            break;
          }

          lastDocId = doc.id;

          try {
            scanned++;
            const recipe = doc.data() as Record<string, unknown>;
            const pageTypeRaw = recipe.page_type;
            const pageType = typeof pageTypeRaw === "string" ? pageTypeRaw : "recipe";
            if (pageType !== "recipe") {
              skipped++;
              continue;
            }

            const existingProducts = recipe.shopping_products;
            if (
              onlyMissing &&
              Array.isArray(existingProducts) &&
              existingProducts.length > 0
            ) {
              skipped++;
              continue;
            }

            const ingredientsRaw = Array.isArray(recipe.ingredients)
              ? recipe.ingredients
              : [];
            const inputs: ShoppingIngredientInput[] = ingredientsRaw
              .filter((entry): entry is Record<string, unknown> => (
                entry !== null && typeof entry === "object"
              ))
              .map((i) => ({
                name: String(i.name ?? "").trim(),
                qty: String(i.qty ?? ""),
                unit: String(i.unit ?? ""),
              }))
              .filter((i) => i.name.length > 0);

            if (inputs.length === 0) {
              await doc.ref.update({ shopping_products: [] });
              updated++;
              continue;
            }

            const userId = String(recipe.created_by ?? "");

            await logInfo({
              message: "backfillShoppingProducts: avant appel Gemini",
              correlationId,
              extra: { recipeId: doc.id, ingredientCount: inputs.length },
            });

            const products = await consolidateShoppingList(
              GEMINI_API_KEY.value(),
              inputs,
              {
                correlationId,
                feature: "shopping_products_backfill",
                moduleType: "DESIGN",
                userId,
              },
              {
                geminiFeature: "shopping_products_backfill",
                usageFeature: "shopping_products_backfill",
                // On ne trace pas le backfill dans ai_usage pour ne pas fausser
                // la ventilation des usages fonctionnels quotidiens.
                logUsage: false,
                // Timeout Gemini réduit pour limiter le risque de timeout global.
                geminiTimeoutMs: 30_000,
              },
            );

            await doc.ref.update({
              shopping_products: products.map((p) => ({
                name: p.name,
                qty: p.qty,
                unit: p.unit,
              })),
            });
            updated++;

            await logInfo({
              message: "backfillShoppingProducts: recette mise à jour",
              correlationId,
              extra: { recipeId: doc.id, productCount: products.length },
            });
          } catch (err) {
            failed++;
            await logFailure({
              operation: "backfillShoppingProducts.recipe",
              correlationId,
              req,
              err,
              extra: { recipeId: doc.id },
            });
          }
        }

        if (stoppedByDeadline || scanned >= maxScanned || (updated + failed) >= limit) {
          break;
        }
      }

      await logInfo({
        message: "backfillShoppingProducts: étape 4/4 - terminé",
        correlationId,
        extra: {
          scanned,
          updated,
          skipped,
          failed,
          limit,
          onlyMissing,
          stoppedByDeadline,
          maxScanned,
          elapsedMs: Date.now() - startedAt,
        },
      });

      // Comptage des recettes restant à traiter (page_type recipe avec
      // shopping_products manquant ou vide). Scan léger (select de 2 champs),
      // borné par le même deadline pour éviter tout dépassement de timeout.
      let remaining = 0;
      let remainingPartial = false;
      {
        const countPageSize = 300;
        let cursor: string | null = null;
        while (true) {
          if (Date.now() >= softDeadlineMs) {
            remainingPartial = true;
            break;
          }
          let q = db
            .collection(COLL_RECIPES)
            .orderBy("__name__")
            .select("page_type", "shopping_products")
            .limit(countPageSize);
          if (cursor) {
            q = q.startAfter(cursor);
          }
          const s = await q.get();
          if (s.empty) break;
          for (const d of s.docs) {
            cursor = d.id;
            const r = d.data() as Record<string, unknown>;
            const pt = typeof r.page_type === "string" ? r.page_type : "recipe";
            if (pt !== "recipe") continue;
            const sp = r.shopping_products;
            if (!Array.isArray(sp) || sp.length === 0) {
              remaining++;
            }
          }
          if (s.size < countPageSize) break;
        }
      }

      await logInfo({
        message: "backfillShoppingProducts: recettes restantes",
        correlationId,
        extra: { remaining, remainingPartial },
      });

      return { scanned, updated, skipped, failed, stoppedByDeadline, remaining };
    } catch (err) {
      await logFailure({
        operation: "backfillShoppingProducts.fatal",
        correlationId,
        req,
        err,
      });
      if (err instanceof HttpsError) throw err;
      throw new HttpsError(
        "internal",
        `Erreur interne backfillShoppingProducts (corr=${correlationId})`,
        { correlationId },
      );
    }
  },
);

/**
 * Bootstrap du référentiel `nutrition_ingredients` à partir des recettes existantes.
 *
 * Objectif:
 * - créer les entrées manquantes avec un statut `pending`
 * - enrichir alias/compteurs sur les entrées déjà présentes
 * - ne jamais écraser les champs nutritionnels existants (`per100g`)
 */
export const backfillNutritionIngredientsFromRecipesFn = onCall<BackfillNutritionIngredientsFromRecipesRequest>(
  {
    region: REGION,
    timeoutSeconds: 300,
    memory: "512MiB",
    cors: ALLOWED_ORIGINS,
  },
  async (req): Promise<BackfillNutritionIngredientsFromRecipesResponse> => {
    const correlationId = `backfill-nutrition-ingredients-${Date.now()}`;

    await ensureAdminWithAudit(req, "backfillNutritionIngredientsFromRecipes");

    const limitRaw = Number(req.data?.limit ?? 200);
    const limit = Number.isFinite(limitRaw)
      ? Math.max(1, Math.min(1000, Math.trunc(limitRaw)))
      : 200;

    const db = getFirestore();
    const startedAt = Date.now();
    const softDeadlineMs = startedAt + 240_000;
    const pageSize = Math.max(20, Math.min(200, limit));

    await logInfo({
      message: "backfillNutritionIngredientsFromRecipes: démarrage",
      correlationId,
      extra: { adminUid: req.auth?.uid, limit, pageSize },
    });

    let scannedRecipes = 0;
    let scannedIngredients = 0;
    let created = 0;
    let updatedExisting = 0;
    let skippedInvalid = 0;
    let failed = 0;
    let stoppedByDeadline = false;
    let lastDocId: string | null = null;

    while (Date.now() < softDeadlineMs && scannedRecipes < limit) {
      let query = db.collection(COLL_RECIPES).orderBy("__name__").limit(pageSize);
      if (lastDocId) query = query.startAfter(lastDocId);

      const snap = await query.get();
      if (snap.empty) break;

      for (const recipeDoc of snap.docs) {
        if (Date.now() >= softDeadlineMs) {
          stoppedByDeadline = true;
          break;
        }
        if (scannedRecipes >= limit) break;

        lastDocId = recipeDoc.id;
        scannedRecipes++;

        try {
          const recipe = recipeDoc.data() as Record<string, unknown>;
          const pageType = typeof recipe.page_type === "string" ? recipe.page_type : "recipe";
          if (pageType !== "recipe") {
            continue;
          }

          const ingredientsRaw = Array.isArray(recipe.ingredients) ? recipe.ingredients : [];
          for (const ingRaw of ingredientsRaw) {
            const ing = (ingRaw && typeof ingRaw === "object")
              ? (ingRaw as Record<string, unknown>)
              : null;
            if (!ing) {
              skippedInvalid++;
              continue;
            }

            const name = asNonEmptyString(ing.name);
            if (!name) {
              skippedInvalid++;
              continue;
            }

            const normalizedId = normalizeIngredientKey(name);
            if (!normalizedId) {
              skippedInvalid++;
              continue;
            }

            scannedIngredients++;

            const unit = asNonEmptyString(ing.unit);
            const docRef = db.collection("nutrition_ingredients").doc(normalizedId);

            try {
              await docRef.create({
                canonical_name: normalizedId.replace(/_/g, " "),
                aliases: [name],
                per100g: {},
                source: "bootstrap_recipes",
                source_priority: ["bootstrap_recipes"],
                quality_status: "pending",
                seen_count: 1,
                first_seen_at: FieldValue.serverTimestamp(),
                last_seen_at: FieldValue.serverTimestamp(),
                last_seen_recipe_id: recipeDoc.id,
                ...(unit ? { observed_units: [unit] } : {}),
                created_at: FieldValue.serverTimestamp(),
                updated_at: FieldValue.serverTimestamp(),
              });
              created++;
            } catch (err) {
              const codeRaw = (err as { code?: unknown })?.code;
              const code = typeof codeRaw === "string" || typeof codeRaw === "number"
                ? String(codeRaw)
                : "";
              const alreadyExists = code.includes("already-exists") || code === "6";
              if (!alreadyExists) {
                throw err;
              }

              await docRef.set({
                aliases: FieldValue.arrayUnion(name),
                ...(unit ? { observed_units: FieldValue.arrayUnion(unit) } : {}),
                seen_count: FieldValue.increment(1),
                last_seen_at: FieldValue.serverTimestamp(),
                last_seen_recipe_id: recipeDoc.id,
                updated_at: FieldValue.serverTimestamp(),
              }, { merge: true });
              updatedExisting++;
            }
          }
        } catch (err) {
          failed++;
          await logFailure({
            operation: "backfillNutritionIngredientsFromRecipes.recipe",
            correlationId,
            req,
            err,
            extra: { recipeId: recipeDoc.id },
          });
        }
      }

      if (stoppedByDeadline || scannedRecipes >= limit) break;
    }

    await logInfo({
      message: "backfillNutritionIngredientsFromRecipes: terminé",
      correlationId,
      extra: {
        scannedRecipes,
        scannedIngredients,
        created,
        updatedExisting,
        skippedInvalid,
        failed,
        stoppedByDeadline,
        elapsedMs: Date.now() - startedAt,
      },
    });

    return {
      scannedRecipes,
      scannedIngredients,
      created,
      updatedExisting,
      skippedInvalid,
      failed,
      stoppedByDeadline,
    };
  },
);

/**
 * Enrichit `nutrition_ingredients` avec des valeurs `per100g` estimées via Gemini.
 *
 * Cible prioritairement les entrées `pending` (sans valeurs per100g), afin de
 * rendre les calculs nutrition des recettes immédiatement exploitables.
 */
export const backfillNutritionIngredientsPer100gFn = onCall<BackfillNutritionIngredientsPer100gRequest>(
  {
    region: REGION,
    timeoutSeconds: 300,
    memory: "512MiB",
    secrets: [GEMINI_API_KEY],
    cors: ALLOWED_ORIGINS,
  },
  async (req): Promise<BackfillNutritionIngredientsPer100gResponse> => {
    const correlationId = `backfill-nutrition-per100g-${Date.now()}`;
    await ensureAdminWithAudit(req, "backfillNutritionIngredientsPer100g");

    const limitRaw = Number(req.data?.limit ?? 40);
    const limit = Number.isFinite(limitRaw)
      ? Math.max(1, Math.min(200, Math.trunc(limitRaw)))
      : 40;
    const onlyPending = req.data?.onlyPending !== false;

    const db = getFirestore();
    const startedAt = Date.now();
    const softDeadlineMs = startedAt + 240_000;
    const pageSize = Math.max(20, Math.min(80, limit * 2));

    let scanned = 0;
    let enriched = 0;
    let skippedNoName = 0;
    let skippedHasPer100g = 0;
    let failed = 0;
    let stoppedByDeadline = false;
    let lastDocId: string | null = null;

    await logInfo({
      message: "backfillNutritionIngredientsPer100g: démarrage",
      correlationId,
      extra: { adminUid: req.auth?.uid, limit, onlyPending, pageSize },
    });

    while (Date.now() < softDeadlineMs && (enriched + failed) < limit) {
      let query = db
        .collection("nutrition_ingredients")
        .orderBy("__name__")
        .limit(pageSize);
      if (lastDocId) query = query.startAfter(lastDocId);

      const snap = await query.get();
      if (snap.empty) break;

      for (const doc of snap.docs) {
        if (Date.now() >= softDeadlineMs) {
          stoppedByDeadline = true;
          break;
        }
        if ((enriched + failed) >= limit) break;

        lastDocId = doc.id;
        scanned++;

        const data = doc.data() as Record<string, unknown>;
        const currentPer100g = data.per100g;
        const alreadyFilled = hasPer100gValues(currentPer100g);
        if (onlyPending && alreadyFilled) {
          skippedHasPer100g++;
          continue;
        }

        const canonicalName = asNonEmptyString(data.canonical_name) ?? doc.id.replace(/_/g, " ");
        if (!canonicalName) {
          skippedNoName++;
          continue;
        }

        const aliases = Array.isArray(data.aliases)
          ? data.aliases
            .filter((v): v is string => typeof v === "string")
          : [];

        try {
          const normalized = await estimatePer100gWithGemini({
            apiKey: GEMINI_API_KEY.value(),
            ingredientId: doc.id,
            canonicalName,
            aliases,
            correlationId,
          });

          if (Object.keys(normalized).length === 0) {
            failed++;
            continue;
          }

          await doc.ref.set({
            per100g: normalized,
            source: "gemini_estimated",
            quality_status: "estimated_ai",
            last_enriched_at: FieldValue.serverTimestamp(),
            updated_at: FieldValue.serverTimestamp(),
          }, { merge: true });
          enriched++;
        } catch (err) {
          failed++;
          await logFailure({
            operation: "backfillNutritionIngredientsPer100g.ingredient",
            correlationId,
            req,
            err,
            extra: { ingredientId: doc.id },
          });
        }
      }

      if (stoppedByDeadline || (enriched + failed) >= limit) break;
    }

    let remaining = 0;
    {
      let cursor: string | null = null;
      const countPageSize = 300;
      while (Date.now() < softDeadlineMs) {
        let q = db
          .collection("nutrition_ingredients")
          .orderBy("__name__")
          .select("per100g")
          .limit(countPageSize);
        if (cursor) q = q.startAfter(cursor);
        const s = await q.get();
        if (s.empty) break;
        for (const d of s.docs) {
          cursor = d.id;
          const r = d.data() as Record<string, unknown>;
          if (!hasPer100gValues(r.per100g)) remaining++;
        }
        if (s.size < countPageSize) break;
      }
    }

    await logInfo({
      message: "backfillNutritionIngredientsPer100g: terminé",
      correlationId,
      extra: {
        scanned,
        enriched,
        skippedNoName,
        skippedHasPer100g,
        failed,
        remaining,
        stoppedByDeadline,
        elapsedMs: Date.now() - startedAt,
      },
    });

    return {
      scanned,
      enriched,
      skippedNoName,
      skippedHasPer100g,
      failed,
      remaining,
      stoppedByDeadline,
    };
  },
);

function parsePeriodBounds(period: string): { start: Date; end: Date } {
  const match = /^(\d{4})-(\d{2})$/.exec(period);
  if (!match) {
    throw new HttpsError("invalid-argument", "period doit être au format YYYY-MM.");
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  if (!Number.isFinite(year) || !Number.isFinite(month) || month < 1 || month > 12) {
    throw new HttpsError("invalid-argument", "period invalide.");
  }
  const start = new Date(Date.UTC(year, month - 1, 1));
  const end = new Date(Date.UTC(year, month, 1));
  return { start, end };
}

function nowPeriod(): string {
  const now = new Date();
  const y = now.getUTCFullYear();
  const m = String(now.getUTCMonth() + 1).padStart(2, "0");
  return `${y}-${m}`;
}

export const generateAiReconciliationMonthlyFn = onCall<GenerateAiReconciliationMonthlyRequest>(
  { region: REGION, timeoutSeconds: 120, memory: "512MiB", cors: ALLOWED_ORIGINS },
  async (req): Promise<GenerateAiReconciliationMonthlyResponse> => {
    await ensureAdminWithAudit(req, "generateAiReconciliationMonthly");

    const period = req.data?.period ?? nowPeriod();
    const { start, end } = parsePeriodBounds(period);
    const startMs = start.getTime();
    const endMs = end.getTime();
    const correlationId = `ai-reco-${period}-${Date.now()}`;

    const db = getFirestore();

    const aiUsageSnap = await db
      .collection(COLL_AI_USAGE)
      .where("timestamp", ">=", start)
      .where("timestamp", "<", end)
      .get();

    let estimatedTraceableUsd = 0;
    const byFeature: Record<string, number> = {};
    for (const doc of aiUsageSnap.docs) {
      const data = doc.data();
      const feature = String(data.feature ?? "unknown");
      const value = toNumber(data.estimated_cost_usd);
      estimatedTraceableUsd += value;
      byFeature[feature] = (byFeature[feature] ?? 0) + value;
    }

    const projectId = process.env.GCLOUD_PROJECT ?? process.env.GCP_PROJECT;
    if (!projectId) {
      throw new HttpsError("internal", "Project ID indisponible.");
    }

    const aiBillingSql = `
      SELECT
        SUM(cost) AS gross_usd,
        COALESCE(SUM((SELECT SUM(c.amount) FROM UNNEST(credits) c)), 0) AS credits_usd
      FROM \`${projectId}.${DATASET}.${TABLE_WILDCARD}\`
      WHERE usage_start_time >= TIMESTAMP_MILLIS(@startMs)
        AND usage_start_time < TIMESTAMP_MILLIS(@endMs)
        AND (
          LOWER(service.description) LIKE '%vertex ai%'
          OR LOWER(service.description) LIKE '%generative language%'
          OR LOWER(sku.description) LIKE '%gemini%'
        )
    `;

    let billedIaUsd = 0;
    try {
      const [rows] = await bigquery.query({
        query: aiBillingSql,
        params: { startMs, endMs },
        types: { startMs: "INT64", endMs: "INT64" },
        location: "EU",
      });
      const first = (rows[0] ?? {}) as Record<string, unknown>;
      billedIaUsd = toNumber(first.gross_usd) + toNumber(first.credits_usd);
    } catch (err) {
      await logFailure({
        operation: "generateAiReconciliationMonthly.billingQuery",
        correlationId,
        req,
        err,
        extra: { period },
      });
    }

    const deltaUsd = billedIaUsd - estimatedTraceableUsd;
    const unattributedUsd = Math.max(0, deltaUsd);

    const reportDoc = {
      period,
      period_start: start,
      period_end: end,
      estimated_traceable_usd: Number(estimatedTraceableUsd.toFixed(6)),
      billed_ia_usd: Number(billedIaUsd.toFixed(6)),
      delta_usd: Number(deltaUsd.toFixed(6)),
      unattributed_usd: Number(unattributedUsd.toFixed(6)),
      by_feature: Object.fromEntries(
        Object.entries(byFeature).map(([k, v]) => [k, Number(v.toFixed(6))]),
      ),
      anomalies: [
        ...(deltaUsd > 0 ? ["facturé supérieur au traçable"] : []),
        ...(Math.abs(deltaUsd) > 5 ? ["écart absolu > 5 USD"] : []),
      ],
      generated_at: FieldValue.serverTimestamp(),
      generated_by: req.auth?.uid ?? null,
    };

    await db.collection(COLL_AI_RECONCILIATION_MONTHLY).doc(period).set(reportDoc, { merge: true });

    return {
      period,
      estimatedTraceableUsd: Number(estimatedTraceableUsd.toFixed(6)),
      billedIaUsd: Number(billedIaUsd.toFixed(6)),
      unattributedUsd: Number(unattributedUsd.toFixed(6)),
      deltaUsd: Number(deltaUsd.toFixed(6)),
      reportId: period,
    };
  },
);

export const backfillRecipeNutritionFn = onCall<BackfillRecipeNutritionRequest>(
  { region: REGION, timeoutSeconds: 300, memory: "512MiB", cors: ALLOWED_ORIGINS },
  async (req): Promise<BackfillRecipeNutritionResponse> => {
    await ensureAdminWithAudit(req, "backfillRecipeNutrition");
    const correlationId = `backfill-nutrition-${Date.now()}`;

    const data = req.data ?? {};
    const limitRaw = Number(data.limit ?? 50);
    const limit = Number.isFinite(limitRaw)
      ? Math.max(1, Math.min(100, Math.trunc(limitRaw)))
      : 50;
    const onlyMissing = data.onlyMissing !== false;

    const db = getFirestore();
    const startedAt = Date.now();
    const softDeadlineMs = startedAt + 240_000;
    const pageSize = Math.max(20, Math.min(100, limit * 2));
    const maxScanned = Math.max(pageSize, Math.min(2000, limit * 20));

    await logInfo({
      message: "backfillRecipeNutrition: démarrage",
      correlationId,
      extra: { adminUid: req.auth?.uid, limit, onlyMissing, pageSize, maxScanned },
    });

    let scanned = 0;
    let updated = 0;
    let skipped = 0;
    let failed = 0;
    let stoppedByDeadline = false;
    let lastDocId: string | null = null;

    while (Date.now() < softDeadlineMs && scanned < maxScanned && (updated + failed) < limit) {
      let query = db.collection(COLL_RECIPES).orderBy("__name__").limit(pageSize);
      if (lastDocId) query = query.startAfter(lastDocId);

      const snap = await query.get();
      if (snap.empty) break;

      for (const doc of snap.docs) {
        if (Date.now() >= softDeadlineMs) {
          stoppedByDeadline = true;
          break;
        }
        if (scanned >= maxScanned || (updated + failed) >= limit) {
          break;
        }

        lastDocId = doc.id;
        scanned++;

        try {
          const recipe = doc.data() as Record<string, unknown>;
          const pageType = typeof recipe.page_type === "string" ? recipe.page_type : "recipe";
          if (pageType !== "recipe") {
            skipped++;
            continue;
          }

          const hasNutrition = recipe.nutrition && typeof recipe.nutrition === "object";
          if (onlyMissing && hasNutrition) {
            skipped++;
            continue;
          }

          await computeAndPersistRecipeNutrition({
            recipeId: doc.id,
            selectedPortions: toNumber(recipe.portions) || undefined,
          });
          updated++;
        } catch (err) {
          failed++;
          await logFailure({
            operation: "backfillRecipeNutrition.recipe",
            correlationId,
            req,
            err,
            extra: { recipeId: doc.id },
          });
        }
      }

      if (stoppedByDeadline || scanned >= maxScanned || (updated + failed) >= limit) {
        break;
      }
    }

    // Comptage restant
    let remaining = 0;
    {
      let cursor: string | null = null;
      const countPageSize = 300;
      while (Date.now() < softDeadlineMs) {
        let q = db
          .collection(COLL_RECIPES)
          .orderBy("__name__")
          .select("page_type", "nutrition")
          .limit(countPageSize);
        if (cursor) q = q.startAfter(cursor);
        const s = await q.get();
        if (s.empty) break;
        for (const d of s.docs) {
          cursor = d.id;
          const r = d.data() as Record<string, unknown>;
          const pageType = typeof r.page_type === "string" ? r.page_type : "recipe";
          if (pageType !== "recipe") continue;
          const hasNutrition = r.nutrition && typeof r.nutrition === "object";
          if (!hasNutrition) remaining++;
        }
        if (s.size < countPageSize) break;
      }
    }

    await logInfo({
      message: "backfillRecipeNutrition: terminé",
      correlationId,
      extra: {
        scanned,
        updated,
        skipped,
        failed,
        remaining,
        stoppedByDeadline,
        elapsedMs: Date.now() - startedAt,
      },
    });

    return {
      scanned,
      updated,
      skipped,
      failed,
      stoppedByDeadline,
      remaining,
    };
  },
);
