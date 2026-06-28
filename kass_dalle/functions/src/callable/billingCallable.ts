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
import { getFirestore } from "firebase-admin/firestore";
import { createHash } from "node:crypto";

import { REGION, COLL_AI_USAGE, LOG_NAME, GEMINI_MODEL, COLL_RECIPES, GEMINI_API_KEY } from "../config";
import { requireAdmin } from "./_auth";
import { logError, logInfo } from "../logging";
import { consolidateShoppingList, type ShoppingIngredientInput } from "../gemini/shopping";

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
    ].join(" OR ");

    const filter = [
      `logName=${quote(`projects/${projectId}/logs/${LOG_NAME}`)}`,
      "severity=INFO",
      `timestamp >= ${quote(startIso)}`,
      `timestamp < ${quote(endIso)}`,
      `(${geminiSuccessMessagesFilter})`,
    ].join(" AND ");

    let pageToken: string | undefined;
    let created = 0;
    let skipped = 0;
    let scanned = 0;

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
        if (!isTokenCall && !isImageCall) {
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
      extra: { created, skipped, scanned },
    });

    return { created, skipped, scanned };
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
