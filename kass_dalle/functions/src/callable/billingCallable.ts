/**
 * Callables Administration : Comptabilité + KPIs + Backfill d'enrichissement.
 *
 * Contenu :
 *  - `getGcpCostsFn` : coûts GCP agrégés par service (BigQuery billing export).
 *  - `generateAiReconciliationMonthlyFn` : réconciliation mensuelle coûts IA.
 *  - `getRecipeReferentialKpisFn` : KPIs de normalisation des référentiels.
 *  - `backfillEnrichReferentialsFn` : enrichissement des poids d'unités
 *    manquants + des per100g d'ingrédients manquants (idempotent, reprise).
 *
 * Sécurité : admin uniquement.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

import {
  REGION,
  COLL_AI_USAGE,
  COLL_APP_CONFIG,
  COLL_NUTRITION_UNITS,
  COLL_RECIPES,
  COLL_NUTRITION_INGREDIENTS,
  GEMINI_API_KEY,
  ANTHROPIC_API_KEY,
  COLL_AI_RECONCILIATION_MONTHLY,
  MAX_CALLABLE_INSTANCES,
} from "../config";
import { enrichUnknownUnitsWithAI, unitAcceptsOwnWeight } from "../nutrition/aiEnrichment";
import { requireAdmin } from "./_auth";
import { logError, logInfo } from "../logging";
import {
  AI_PER100G_MARKERS,
  estimatePer100gForTargets,
  hasPer100gValues,
  type Per100gEnrichmentTarget,
} from "../nutrition/per100gEnrichment";
import { nowPeriod, periodBounds } from "../billing/periods";
import { CURRENCY_RATE_DOC, validateCurrencyRate } from "../billing/currencyRate";
import {
  asNonEmptyString,
  getBackfillCursor,
  parseBoolean,
  setBackfillCursor,
} from "./_backfillCursor";

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
  /** Coût net dans la devise du compte de facturation — le chiffre de la facture. */
  costNative: number;
  grossNative: number;
  creditsNative: number;
}

interface GetGcpCostsResponse {
  /** False si la table d'export n'existe pas encore. */
  ready: boolean;
  services: ServiceCostDto[];
  totalUsd: number;
  totalGrossUsd: number;
  totalCreditsUsd: number;
  /** Total dans la devise du compte de facturation. */
  totalNative: number;
  /** Devise du compte de facturation — celle dans laquelle Google facture. */
  currency: string;
  /**
   * Nombre de lignes de facturation sans taux de change exploitable : leur
   * montant manque aux totaux USD. Un total amputé sans le dire est le pire
   * cas — il reste plausible.
   */
  unconvertedRows: number;
  /** Indique si des données ont été trouvées sur la période. */
  hasData: boolean;
}

interface GenerateAiReconciliationMonthlyRequest {
  period?: string; // YYYY-MM
}

interface GenerateAiReconciliationMonthlyResponse {
  period: string;
  estimatedTraceableUsd: number;
  /** Part Gemini de l'estimé — la seule qui figure dans la facturation Google. */
  estimatedGeminiUsd: number;
  /** Part Claude, facturée par Anthropic : hors de ce rapprochement. */
  estimatedAnthropicUsd: number;
  /** Postes internes (scan de sécurité), qui ne sont pas de l'inférence. */
  estimatedInternalUsd: number;
  billedIaUsd: number;
  /** Le même montant dans la devise du compte de facturation — le chiffre de la facture. */
  billedIaNative: number;
  /** Devise du compte de facturation (`EUR` ici). */
  billingCurrency: string;
  unattributedUsd: number;
  deltaUsd: number;
  /** Vrai si l'export de facturation n'a pas pu être lu : `billedIaUsd` ne veut alors rien dire. */
  billingQueryFailed: boolean;
  reportId: string;
}

interface GetRecipeReferentialKpisResponse {
  recipesTotal: number;
  nutritionIngredientsTotal: number;
  nutritionIngredientsEnriched: number;
  nutritionIngredientsPending: number;
}

interface BackfillEnrichReferentialsRequest {
  maxMinutes?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
  /**
   * Reprend les profils DÉJÀ remplis qui portent du sodium, au lieu de ne
   * traiter que les manquants.
   *
   * Réparation d'un référentiel faussé : `normalizeNutrients` additionnait le
   * sodium et le sel, deux écritures d'une même grandeur, si bien que tout
   * ingrédient salé pesait le double de son vrai sel. La correction du code
   * empêche le doublement futur ; elle ne défait pas ce qui est écrit, et
   * aucune règle ne permet de distinguer après coup un profil doublé d'un
   * profil juste — la formule fautive les rendait cohérents dans les deux cas.
   * Seule une nouvelle estimation répare.
   *
   * Réservé à cette réparation : ce mode redemande au modèle des profils qu'on
   * possède déjà, et coûte donc autant qu'un premier remplissage.
   */
  refreshSodium?: boolean;
}

/**
 * Ce profil porte-t-il du sodium ?
 *
 * Sert à choisir les ingrédients à réparer : le double comptage sel/sodium ne
 * pouvait fausser que ceux-là. Un profil sans sodium — la farine, le sucre —
 * n'a rien à redemander.
 *
 * Le test porte sur `sodium_mg` ET `salt_g` : les deux sont écrits ensemble
 * par la normalisation, mais un profil ancien peut n'avoir que l'un des deux.
 */
function carriesSodium(value: unknown): boolean {
  if (!value || typeof value !== "object") return false;
  const record = value as Record<string, unknown>;
  for (const key of ["sodium_mg", "salt_g"]) {
    const raw = record[key];
    const parsed = typeof raw === "string" ? Number(raw.replace(",", ".")) : raw;
    if (typeof parsed === "number" && Number.isFinite(parsed) && parsed > 0) return true;
  }
  return false;
}

interface BackfillEnrichReferentialsResponse {
  scannedUnits: number;
  enrichedUnits: number;
  scannedIngredients: number;
  enrichedIngredients: number;
  failedIngredients: number;
  remainingUnitsWithoutWeight: number;
  completed: boolean;
  stoppedByDeadline: boolean;
  /** Profils repris parce qu'ils portaient du sodium — mode `refreshSodium`. */
  refreshedIngredients: number;
}

/**
 * Client BigQuery, chargé à la PREMIÈRE requête.
 *
 * Le SDK tire une pile de dépendances — auth, gRPC, protobuf — et son import
 * statique compte dans le budget de découverte des cinquante fonctions du
 * bundle. Or il ne sert qu’aux écrans de comptabilité, que personne n’ouvre
 * pendant un import de recette. Même raison que le SDK Vision : ce qu’on ne
 * charge pas au démarrage ne ralentit ni le déploiement ni le premier appel
 * des autres fonctions.
 */
let bigqueryClient: import("@google-cloud/bigquery").BigQuery | null = null;
async function bigQuery(): Promise<import("@google-cloud/bigquery").BigQuery> {
  if (!bigqueryClient) {
    const { BigQuery } = await import("@google-cloud/bigquery");
    bigqueryClient = new BigQuery();
  }
  return bigqueryClient;
}

export async function ensureAdminWithAudit(
  req: Parameters<typeof requireAdmin>[0],
  op: string,
): Promise<void> {
  try {
    // `op` nomme déjà l'opération : il devient la racine du correlationId,
    // faute de quoi l'écran de journaux titrait ce traitement « call ».
    await requireAdmin(req, op);
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

function toNumber(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

type ErrorInfo = {
  name: string;
  message: string;
  stack?: string;
  code?: string;
};

function getErrorInfo(err: unknown): ErrorInfo {
  const asRecord = err && typeof err === "object" ? (err as Record<string, unknown>) : null;
  const name = err instanceof Error ? err.name : String(asRecord?.name ?? "Error");
  const message = err instanceof Error ? err.message : String(asRecord?.message ?? err);
  const stackRaw =
    err instanceof Error
      ? err.stack
      : typeof asRecord?.stack === "string"
        ? asRecord.stack
        : undefined;
  const codeRaw = asRecord?.code;
  const code =
    typeof codeRaw === "string" || typeof codeRaw === "number" ? String(codeRaw) : undefined;
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

// ─────────────────────────────────────────────────────────────────────────────
// Comptabilité : coûts GCP par service (BigQuery billing export)
// ─────────────────────────────────────────────────────────────────────────────

export const getGcpCostsFn = onCall<GetGcpCostsRequest>(
  {
    region: REGION,
    timeoutSeconds: 60,
    memory: "256MiB",
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req) => {
    await ensureAdminWithAudit(req, "couts_gcp");
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
      throw new HttpsError("invalid-argument", "Plage trop large (max 13 mois).");
    }

    const tableRef = `\`${projectId}.${DATASET}.${TABLE_WILDCARD}\``;

    // Filtre `usage_start_time` (instant de consommation, plus précis que
    // `_PARTITIONTIME` qui correspond à la date d'export, en retard d'~24h).
    //
    // `cost` est libellé dans la devise du COMPTE DE FACTURATION, pas en dollars :
    // ce compte facture en euros. Le convertir avec un taux codé en dur donnait un
    // chiffre faux mais crédible ; `currency_conversion_rate` est le taux
    // USD → devise du compte que Google a lui-même appliqué à la ligne.
    const sql = `
      SELECT
        service.description AS service,
        currency,
        SUM(cost) AS gross_native,
        COALESCE(SUM((
          SELECT SUM(c.amount) FROM UNNEST(credits) c
        )), 0) AS credits_native,
        SUM(SAFE_DIVIDE(cost, NULLIF(currency_conversion_rate, 0))) AS gross_usd,
        COALESCE(SUM(SAFE_DIVIDE(
          (SELECT SUM(c.amount) FROM UNNEST(credits) c),
          NULLIF(currency_conversion_rate, 0)
        )), 0) AS credits_usd,
        COUNTIF(currency_conversion_rate IS NULL OR currency_conversion_rate = 0)
          AS unconverted_rows
      FROM ${tableRef}
      WHERE usage_start_time >= TIMESTAMP_MILLIS(@startMs)
        AND usage_start_time < TIMESTAMP_MILLIS(@endMs)
      GROUP BY service, currency
      ORDER BY gross_native DESC
    `;

    try {
      const [rows] = await (
        await bigQuery()
      ).query({
        query: sql,
        params: { startMs, endMs },
        types: { startMs: "INT64", endMs: "INT64" },
        location: "EU",
      });

      let currency = "USD";
      let unconvertedRows = 0;
      const services: ServiceCostDto[] = rows.map((r) => {
        const gross = toNumber(r.gross_usd);
        const credits = toNumber(r.credits_usd);
        const grossNative = toNumber(r.gross_native);
        const creditsNative = toNumber(r.credits_native);
        unconvertedRows += toNumber(r.unconverted_rows);
        if (typeof r.currency === "string" && r.currency.length > 0) {
          currency = r.currency;
        }
        return {
          service: String(r.service ?? "Inconnu"),
          costUsd: gross + credits,
          grossUsd: gross,
          creditsUsd: credits,
          costNative: grossNative + creditsNative,
          grossNative,
          creditsNative,
        };
      });

      const totalGrossUsd = services.reduce((s, x) => s + x.grossUsd, 0);
      const totalCreditsUsd = services.reduce((s, x) => s + x.creditsUsd, 0);

      // Une ligne sans taux de change manque au total USD sans rien casser :
      // seul ce log permet de s'apercevoir que le chiffre affiché est amputé.
      if (unconvertedRows > 0) {
        await logError({
          message: "getGcpCostsFn: lignes de facturation sans taux de change",
          correlationId,
          errorDescription:
            `${unconvertedRows} ligne(s) sans currency_conversion_rate : ` +
            "leur montant est absent des totaux USD.",
          extra: { startMs, endMs, currency },
        });
      }

      const resp: GetGcpCostsResponse = {
        ready: true,
        services,
        totalUsd: totalGrossUsd + totalCreditsUsd,
        totalGrossUsd,
        totalCreditsUsd,
        totalNative: services.reduce((s, x) => s + x.costNative, 0),
        currency,
        unconvertedRows,
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
          totalNative: 0,
          currency: "USD",
          unconvertedRows: 0,
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
      throw new HttpsError("internal", `Erreur interne getGcpCostsFn (corr=${correlationId})`, {
        correlationId,
      });
    }
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// KPIs : état de la normalisation des référentiels
// ─────────────────────────────────────────────────────────────────────────────

export const getRecipeReferentialKpisFn = onCall(
  {
    region: REGION,
    timeoutSeconds: 60,
    memory: "256MiB",
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req): Promise<GetRecipeReferentialKpisResponse> => {
    await ensureAdminWithAudit(req, "kpis_referentiels");

    const db = getFirestore();

    // Nombre total de recettes via requête count (pas de scan)
    const recipesCountSnap = await db.collection(COLL_RECIPES).count().get();
    const recipesTotal = recipesCountSnap.data().count;

    // Scan nutrition_ingredients (max 5 000 docs)
    let nutritionIngredientsTotal = 0;
    let nutritionIngredientsEnriched = 0;
    let lastDocId: string | null = null;
    const PAGE = 500;

    while (nutritionIngredientsTotal < 5000) {
      let query = db.collection(COLL_NUTRITION_INGREDIENTS).orderBy("__name__").limit(PAGE);
      if (lastDocId) query = query.startAfter(lastDocId);

      const snap = await query.get();
      if (snap.empty) break;

      for (const doc of snap.docs) {
        nutritionIngredientsTotal++;
        lastDocId = doc.id;
        const data = doc.data() as Record<string, unknown>;
        const per100g = data.per100g;
        const hasNutrition =
          per100g !== null &&
          per100g !== undefined &&
          typeof per100g === "object" &&
          Object.keys(per100g as object).length > 0;
        if (hasNutrition) {
          nutritionIngredientsEnriched++;
        }
      }

      if (snap.size < PAGE) break;
    }

    return {
      recipesTotal,
      nutritionIngredientsTotal,
      nutritionIngredientsEnriched,
      nutritionIngredientsPending: nutritionIngredientsTotal - nutritionIngredientsEnriched,
    };
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// Comptabilité : réconciliation mensuelle des coûts IA
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Relève le taux USD → devise du compte sur la période et le range dans
 * `app_config/currency_rate`.
 *
 * Appelé pendant la réconciliation : le taux se périme au même rythme que les
 * coûts qu'il sert à convertir, il n'y a donc aucune raison de le rafraîchir
 * ailleurs — ni de laisser un `0.92` de 2024 continuer à décider ce que l'écran
 * Comptabilité affiche en euros.
 *
 * Le taux rendu est la moyenne pondérée par le coût des taux de la période :
 * `SUM(cost) / SUM(cost / rate)`. Google applique en pratique un taux unique par
 * période de facturation, la pondération n'a donc rien à corriger le plus
 * souvent — mais elle évite qu'une ligne marginale à taux différent pèse autant
 * qu'un mois entier de consommation.
 *
 * Best-effort : un échec ne doit pas emporter la réconciliation, mais il est
 * journalisé. Le taux précédent reste alors en place, ce qui vaut toujours mieux
 * qu'un taux inventé.
 */
async function refreshCurrencyRate(args: {
  db: FirebaseFirestore.Firestore;
  projectId: string;
  startMs: number;
  endMs: number;
  period: string;
  correlationId: string;
}): Promise<void> {
  const sql = `
    SELECT
      ANY_VALUE(currency) AS currency,
      SAFE_DIVIDE(
        SUM(cost),
        SUM(SAFE_DIVIDE(cost, NULLIF(currency_conversion_rate, 0)))
      ) AS usd_to_account
    FROM \`${args.projectId}.${DATASET}.${TABLE_WILDCARD}\`
    WHERE usage_start_time >= TIMESTAMP_MILLIS(@startMs)
      AND usage_start_time < TIMESTAMP_MILLIS(@endMs)
      AND cost > 0
  `;

  try {
    const [rows] = await (
      await bigQuery()
    ).query({
      query: sql,
      params: { startMs: args.startMs, endMs: args.endMs },
      types: { startMs: "INT64", endMs: "INT64" },
      location: "EU",
    });
    const first = (rows[0] ?? {}) as Record<string, unknown>;
    const validation = validateCurrencyRate({
      rate: first.usd_to_account,
      currency: first.currency,
    });

    if (!validation.ok) {
      await logError({
        message: "refreshCurrencyRate: taux refusé",
        correlationId: args.correlationId,
        errorDescription: `${validation.reason} — le taux précédent reste en vigueur.`,
        extra: { period: args.period },
      });
      return;
    }

    await args.db
      .collection(COLL_APP_CONFIG)
      .doc(CURRENCY_RATE_DOC)
      .set(
        {
          usd_to_account_rate: Number(validation.reading.rate.toFixed(6)),
          currency: validation.reading.currency,
          source_period: args.period,
          source: "gcp_billing_export",
          updated_at: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );

    await logInfo({
      message:
        `refreshCurrencyRate: 1 USD = ${validation.reading.rate.toFixed(4)} ` +
        `${validation.reading.currency} (${args.period})`,
      correlationId: args.correlationId,
      extra: { period: args.period, rate: validation.reading.rate },
    });
  } catch (err) {
    await logError({
      message: "refreshCurrencyRate: ERREUR",
      correlationId: args.correlationId,
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: { period: args.period },
    });
  }
}

function parsePeriodBounds(period: string): { start: Date; end: Date } {
  const bounds = periodBounds(period);
  if (!bounds) {
    throw new HttpsError("invalid-argument", "period doit être au format YYYY-MM.");
  }
  return bounds;
}

/**
 * Confronte ce que le suivi interne a estimé à ce que Google a réellement
 * facturé, pour un mois donné, et écrit le rapport dans
 * `ai_reconciliation_monthly/{period}`.
 *
 * Corps partagé par le déclenchement manuel (bouton de l'écran Comptabilité) et
 * par la tâche planifiée mensuelle. Une réconciliation qu'il faut penser à
 * lancer n'est pas lancée ; une réconciliation qu'on ne peut pas relancer à la
 * main ne sert à rien le jour où on veut vérifier quelque chose. Il faut les
 * deux, et donc un seul traitement pour les deux.
 *
 * [triggeredBy] est l'uid de l'admin, ou `null` quand c'est la planification.
 */
export async function runAiReconciliation(args: {
  period: string;
  triggeredBy: string | null;
}): Promise<GenerateAiReconciliationMonthlyResponse> {
  const { period, triggeredBy } = args;
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

  // La confrontation n'a de sens que fournisseur par fournisseur : la
  // facturation Google ne contient pas les appels Claude, facturés par
  // Anthropic, ni le scan de sécurité, qui n'est pas de l'inférence. Additionner
  // les trois et comparer le total à la facture Google produisait un écart
  // spectaculaire et faux — présenté comme un fait.
  let estimatedTraceableUsd = 0;
  let estimatedGeminiUsd = 0;
  let estimatedAnthropicUsd = 0;
  let estimatedInternalUsd = 0;
  const byFeature: Record<string, number> = {};
  for (const doc of aiUsageSnap.docs) {
    const data = doc.data();
    const feature = String(data.feature ?? "unknown");
    const value = toNumber(data.estimated_cost_usd);
    const model = String(data.model ?? "");
    // Les lignes antérieures au multi-fournisseur ne portent pas de `provider` :
    // le modèle en tient lieu, comme partout ailleurs dans le projet.
    const provider = String(data.provider ?? (model.startsWith("claude") ? "anthropic" : "gemini"));

    estimatedTraceableUsd += value;
    byFeature[feature] = (byFeature[feature] ?? 0) + value;

    if (provider === "anthropic") {
      estimatedAnthropicUsd += value;
    } else if (provider === "internal") {
      estimatedInternalUsd += value;
    } else {
      estimatedGeminiUsd += value;
    }
  }

  const projectId = process.env.GCLOUD_PROJECT ?? process.env.GCP_PROJECT;
  if (!projectId) {
    throw new HttpsError("internal", "Project ID indisponible.");
  }

  // Le service porte le nom « Gemini API » dans la facturation de ce compte :
  // sans cette ligne, il n'était retenu que par le filtre SKU, c'est-à-dire par
  // chance. `cost` est libellé dans la devise du compte (EUR) ; la grille
  // tarifaire qui alimente `ai_usage` est en dollars. Sans la division par
  // `currency_conversion_rate`, l'écart additionnait deux monnaies.
  const aiBillingSql = `
    SELECT
      ANY_VALUE(currency) AS currency,
      SUM(cost) AS gross_native,
      COALESCE(SUM((SELECT SUM(c.amount) FROM UNNEST(credits) c)), 0) AS credits_native,
      SUM(SAFE_DIVIDE(cost, NULLIF(currency_conversion_rate, 0))) AS gross_usd,
      COALESCE(SUM(SAFE_DIVIDE(
        (SELECT SUM(c.amount) FROM UNNEST(credits) c),
        NULLIF(currency_conversion_rate, 0)
      )), 0) AS credits_usd,
      COUNTIF(currency_conversion_rate IS NULL OR currency_conversion_rate = 0)
        AS unconverted_rows
    FROM \`${projectId}.${DATASET}.${TABLE_WILDCARD}\`
    WHERE usage_start_time >= TIMESTAMP_MILLIS(@startMs)
      AND usage_start_time < TIMESTAMP_MILLIS(@endMs)
      AND (
        LOWER(service.description) LIKE '%vertex ai%'
        OR LOWER(service.description) LIKE '%generative language%'
        OR LOWER(service.description) LIKE '%gemini api%'
        OR LOWER(sku.description) LIKE '%gemini%'
      )
      -- L'assistance Gemini de la console (Code Assist, Gemini for Google Cloud)
      -- porte « gemini » dans son SKU sans être un appel de l'application.
      AND LOWER(service.description) NOT LIKE '%code assist%'
      AND LOWER(service.description) NOT LIKE '%gemini for google cloud%'
  `;

  // `billingQueryFailed` distingue « aucun coût facturé » d'un « on n'a pas pu
  // savoir ». Sans lui, une requête BigQuery en échec produisait un rapport
  // affirmant que Google n'a rien facturé, et donc un écart négatif spectaculaire
  // présenté comme un fait.
  let billedIaUsd = 0;
  let billedIaNative = 0;
  let billingCurrency = "USD";
  let unconvertedRows = 0;
  let billingQueryFailed = false;
  try {
    const [rows] = await (
      await bigQuery()
    ).query({
      query: aiBillingSql,
      params: { startMs, endMs },
      types: { startMs: "INT64", endMs: "INT64" },
      location: "EU",
    });
    const first = (rows[0] ?? {}) as Record<string, unknown>;
    billedIaUsd = toNumber(first.gross_usd) + toNumber(first.credits_usd);
    billedIaNative = toNumber(first.gross_native) + toNumber(first.credits_native);
    unconvertedRows = toNumber(first.unconverted_rows);
    if (typeof first.currency === "string" && first.currency.length > 0) {
      billingCurrency = first.currency;
    }
  } catch (err) {
    billingQueryFailed = true;
    await logError({
      message: "runAiReconciliation.billingQuery: ERREUR",
      correlationId,
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: { period, triggeredBy },
    });
  }

  // Une ligne non convertie manque au montant facturé en dollars, donc à
  // l'écart, sans qu'aucun écran ne s'en plaigne.
  if (unconvertedRows > 0) {
    await logError({
      message: "runAiReconciliation: lignes de facturation sans taux de change",
      correlationId,
      errorDescription:
        `${unconvertedRows} ligne(s) sans currency_conversion_rate : ` +
        "le montant facturé converti en USD est incomplet.",
      extra: { period, billingCurrency },
    });
  }

  // Le taux de change se relève ici, et nulle part ailleurs : il vieillit au
  // même rythme que les coûts qu'il convertit.
  await refreshCurrencyRate({
    db,
    projectId,
    startMs,
    endMs,
    period,
    correlationId,
  });

  // L'écart se mesure contre la seule part que Google facture.
  const deltaUsd = billedIaUsd - estimatedGeminiUsd;
  const unattributedUsd = Math.max(0, deltaUsd);

  const reportDoc = {
    period,
    period_start: start,
    period_end: end,
    estimated_traceable_usd: Number(estimatedTraceableUsd.toFixed(6)),
    estimated_gemini_usd: Number(estimatedGeminiUsd.toFixed(6)),
    /** Facturé par Anthropic, hors facturation Google : non réconciliable ici. */
    estimated_anthropic_usd: Number(estimatedAnthropicUsd.toFixed(6)),
    /** Postes qui ne sont pas de l'inférence (scan de sécurité). */
    estimated_internal_usd: Number(estimatedInternalUsd.toFixed(6)),
    billed_ia_usd: Number(billedIaUsd.toFixed(6)),
    billed_ia_native: Number(billedIaNative.toFixed(6)),
    billing_currency: billingCurrency,
    delta_usd: Number(deltaUsd.toFixed(6)),
    unattributed_usd: Number(unattributedUsd.toFixed(6)),
    billing_query_failed: billingQueryFailed,
    by_feature: Object.fromEntries(
      Object.entries(byFeature).map(([k, v]) => [k, Number(v.toFixed(6))]),
    ),
    anomalies: [
      ...(billingQueryFailed
        ? ["facturation GCP illisible — le montant facturé de ce rapport ne veut rien dire"]
        : []),
      ...(unconvertedRows > 0
        ? [
            `${unconvertedRows} ligne(s) facturées sans taux de change : montant facturé sous-estimé`,
          ]
        : []),
      ...(!billingQueryFailed && deltaUsd > 0
        ? ["facturé Google supérieur à l'estimé Gemini"]
        : []),
      ...(!billingQueryFailed && Math.abs(deltaUsd) > 5 ? ["écart absolu > 5 USD"] : []),
      ...(estimatedAnthropicUsd > 0
        ? [
            `${estimatedAnthropicUsd.toFixed(2)} USD estimés sur Claude : facturés par ` +
              "Anthropic, hors de ce rapprochement",
          ]
        : []),
    ],
    generated_at: FieldValue.serverTimestamp(),
    generated_by: triggeredBy,
    generated_source: triggeredBy === null ? "scheduler" : "manual",
  };

  await db.collection(COLL_AI_RECONCILIATION_MONTHLY).doc(period).set(reportDoc, { merge: true });

  await logInfo({
    message: `runAiReconciliation: rapport ${period} écrit`,
    correlationId,
    extra: {
      period,
      estimatedTraceableUsd,
      billedIaUsd,
      billedIaNative,
      billingCurrency,
      deltaUsd,
      billingQueryFailed,
      source: triggeredBy === null ? "scheduler" : "manual",
    },
  });

  return {
    period,
    estimatedTraceableUsd: Number(estimatedTraceableUsd.toFixed(6)),
    estimatedGeminiUsd: Number(estimatedGeminiUsd.toFixed(6)),
    estimatedAnthropicUsd: Number(estimatedAnthropicUsd.toFixed(6)),
    estimatedInternalUsd: Number(estimatedInternalUsd.toFixed(6)),
    billedIaUsd: Number(billedIaUsd.toFixed(6)),
    billedIaNative: Number(billedIaNative.toFixed(6)),
    billingCurrency,
    unattributedUsd: Number(unattributedUsd.toFixed(6)),
    deltaUsd: Number(deltaUsd.toFixed(6)),
    billingQueryFailed,
    reportId: period,
  };
}

/** Déclenchement manuel depuis l'écran Comptabilité. */
export const generateAiReconciliationMonthlyFn = onCall<GenerateAiReconciliationMonthlyRequest>(
  {
    region: REGION,
    timeoutSeconds: 120,
    memory: "512MiB",
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req): Promise<GenerateAiReconciliationMonthlyResponse> => {
    await ensureAdminWithAudit(req, "reconciliation_ia_mensuelle");
    return runAiReconciliation({
      period: req.data?.period ?? nowPeriod(),
      triggeredBy: req.auth?.uid ?? null,
    });
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// Backfill unique : enrichissement des poids d'unités + per100g d'ingrédients
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Enrichit, de manière idempotente et avec reprise sur checkpoint :
 *  1) les unités de `nutrition_units` sans `grams_per_unit` (poids estimé par IA
 *     avec le contexte des ingrédients associés) ;
 *  2) les ingrédients de `nutrition_ingredients` sans `per100g` (valeurs
 *     nutritionnelles estimées par IA).
 *
 * Le traitement s'arrête proprement avant le timeout (deadline douce) et peut
 * être relancé : la phase ingrédients reprend depuis le dernier curseur.
 */
export const backfillEnrichReferentialsFn = onCall<BackfillEnrichReferentialsRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: "512MiB",
    secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY],
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req): Promise<BackfillEnrichReferentialsResponse> => {
    await ensureAdminWithAudit(req, "backfill_referentiels");
    const correlationId = `backfill-enrich-referentials-${Date.now()}`;

    const maxMinutesRaw = Number(req.data?.maxMinutes ?? 8.5);
    const maxMinutes = Number.isFinite(maxMinutesRaw)
      ? Math.max(2, Math.min(8.8, maxMinutesRaw))
      : 8.5;
    const softDeadlineMs = Date.now() + Math.floor(maxMinutes * 60_000);
    const resumeFromCheckpoint = parseBoolean(req.data?.resumeFromCheckpoint, true);
    const resetCheckpoint = parseBoolean(req.data?.resetCheckpoint, false);
    const refreshSodium = parseBoolean(req.data?.refreshSodium, false);

    const db = getFirestore();

    let scannedUnits = 0;
    let enrichedUnits = 0;
    let scannedIngredients = 0;
    let enrichedIngredients = 0;
    let failedIngredients = 0;
    let remainingUnitsWithoutWeight = 0;
    let refreshedIngredients = 0;
    let stoppedByDeadline = false;

    await logInfo({
      message: "backfillEnrichReferentials: démarrage",
      correlationId,
      extra: { adminUid: req.auth?.uid, maxMinutes, refreshSodium },
    });

    // ── Phase 1 : poids des unités manquants ────────────────────────────────
    // La collection nutrition_units est petite : parcours intégral.
    //
    // Sautée en mode réparation : le sel doublé est une affaire de valeurs
    // nutritionnelles, pas de poids d'unités. Repasser ici ferait dépenser des
    // appels pour un problème qui n'existe pas.
    if (!refreshSodium) {
      const unitsWithoutWeight: Array<{ id: string; ingredients: string[] }> = [];
      let cursor: string | null = null;
      const PAGE = 300;
      for (;;) {
        let q = db.collection(COLL_NUTRITION_UNITS).orderBy("__name__").limit(PAGE);
        if (cursor) q = q.startAfter(cursor);
        const snap = await q.get();
        if (snap.empty) break;
        for (const doc of snap.docs) {
          cursor = doc.id;
          scannedUnits++;
          // Comptage et volume n'ont pas de poids propre. Les compter ici parmi
          // les unités « sans poids » gonflait un reste qui ne descend jamais :
          // l'enrichissement les écarte, le rapport les réclamait encore.
          if (!unitAcceptsOwnWeight(doc.id)) continue;
          const data = doc.data() as Record<string, unknown>;
          const hasGrams = typeof data.grams_per_unit === "number" && data.grams_per_unit > 0;
          if (hasGrams) continue;
          const ingredients = Array.isArray(data.sample_ingredient_names)
            ? (data.sample_ingredient_names as unknown[]).filter(
                (v): v is string => typeof v === "string",
              )
            : [];
          unitsWithoutWeight.push({ id: doc.id, ingredients });
        }
        if (snap.size < PAGE) break;
      }

      remainingUnitsWithoutWeight = unitsWithoutWeight.length;

      // Enrichissement par lots : l'IA reçoit le contexte ingrédient de chaque unité.
      const BATCH = 15;
      for (let i = 0; i < unitsWithoutWeight.length; i += BATCH) {
        if (Date.now() >= softDeadlineMs) {
          stoppedByDeadline = true;
          break;
        }
        const batch = unitsWithoutWeight.slice(i, i + BATCH);
        const unitIngredientNames = new Map<string, string[]>();
        for (const u of batch) {
          if (u.ingredients.length > 0) unitIngredientNames.set(u.id, u.ingredients);
        }
        try {
          await enrichUnknownUnitsWithAI({
            unitCanonicals: batch.map((u) => u.id),
            userId: req.auth?.uid ?? undefined,
            unitIngredientNames,
          });
          // Vérifie combien de docs du lot ont effectivement reçu un poids.
          const refs = batch.map((u) => db.collection(COLL_NUTRITION_UNITS).doc(u.id));
          const after = await db.getAll(...refs);
          for (const s of after) {
            const d = s.data() as Record<string, unknown> | undefined;
            if (d && typeof d.grams_per_unit === "number" && d.grams_per_unit > 0) {
              enrichedUnits++;
              remainingUnitsWithoutWeight = Math.max(0, remainingUnitsWithoutWeight - 1);
            }
          }
        } catch (err) {
          await logFailure({
            operation: "backfillEnrichReferentials.units",
            correlationId,
            req,
            err,
            extra: { unitIds: batch.map((u) => u.id) },
          });
        }
      }
    }

    // ── Phase 2 : per100g des ingrédients manquants ─────────────────────────
    if (!stoppedByDeadline) {
      // Curseur propre au mode : une réparation reprise à mi-chemin ne doit pas
      // faire croire au remplissage normal qu'il a déjà vu ces ingrédients.
      const cursorDocId = refreshSodium
        ? "backfill_cursor_refresh_sodium_ingredients"
        : "backfill_cursor_enrich_referentials_ingredients";
      let cursor: string | null = await getBackfillCursor({
        db,
        docId: cursorDocId,
        resumeFromCheckpoint,
        resetCheckpoint,
      });
      const PAGE = 100;
      let finishedScan = false;
      while (Date.now() < softDeadlineMs) {
        let q = db.collection(COLL_NUTRITION_INGREDIENTS).orderBy("__name__").limit(PAGE);
        if (cursor) q = q.startAfter(cursor);
        const snap = await q.get();
        if (snap.empty) {
          finishedScan = true;
          break;
        }

        // Une page de cent ingrédients part en lots de vingt : le backfill
        // dépensait auparavant un appel Gemini par ingrédient, ce qui le faisait
        // buter sur son échéance bien avant d'avoir fini le référentiel.
        const pageTargets: Per100gEnrichmentTarget[] = [];
        for (const doc of snap.docs) {
          cursor = doc.id;
          scannedIngredients++;
          const data = doc.data() as Record<string, unknown>;
          // En mode normal : les profils vides. En mode réparation : ceux qui
          // portent du sodium, remplis ou non — ce sont exactement ceux que le
          // double comptage pouvait fausser.
          const keep = refreshSodium
            ? carriesSodium(data.per100g)
            : !hasPer100gValues(data.per100g);
          if (!keep) continue;
          pageTargets.push({
            id: doc.id,
            canonicalName: asNonEmptyString(data.canonical_name) ?? doc.id.replace(/_/g, " "),
            aliases: Array.isArray(data.aliases)
              ? (data.aliases as unknown[]).filter((v): v is string => typeof v === "string")
              : [],
          });
        }

        if (pageTargets.length > 0) {
          try {
            const estimated = await estimatePer100gForTargets({
              targets: pageTargets,
              correlationId,
              userId: req.auth?.uid ?? undefined,
              // Poste distinct : cette réparation est une dépense ponctuelle et
              // massive, que personne ne saurait retrouver si elle se mêlait au
              // rattrapage courant.
              feature: refreshSodium
                ? "backfill_refresh_sodium_per100g"
                : "backfill_enrich_referentials_per100g",
              deadlineMs: softDeadlineMs,
            });
            for (const [ingredientId, per100g] of estimated) {
              const ref = db.collection(COLL_NUTRITION_INGREDIENTS).doc(ingredientId);
              const payload = {
                per100g,
                ...AI_PER100G_MARKERS,
                last_enriched_at: FieldValue.serverTimestamp(),
                updated_at: FieldValue.serverTimestamp(),
              };
              // Une réparation REMPLACE le profil : `set(merge)` fusionne les
              // cartes champ par champ et laisserait survivre l'ancienne valeur
              // de sodium si la nouvelle estimation ne la citait pas. `update`
              // écrase la carte entière — et le document existe forcément, on
              // vient de le lire.
              if (refreshSodium) {
                await ref.update(payload);
                refreshedIngredients++;
              } else {
                await ref.set(payload, { merge: true });
              }
              enrichedIngredients++;
            }
            failedIngredients += pageTargets.length - estimated.size;
          } catch (err) {
            failedIngredients += pageTargets.length;
            await logFailure({
              operation: "backfillEnrichReferentials.ingredients",
              correlationId,
              req,
              err,
              extra: { ingredientIds: pageTargets.map((t) => t.id) },
            });
          }
        }

        if (Date.now() >= softDeadlineMs) stoppedByDeadline = true;

        if (stoppedByDeadline) break;
        if (snap.size < PAGE) {
          finishedScan = true;
          break;
        }
      }

      // Reprise : on garde le curseur si on n'a pas terminé, sinon on le remet à zéro.
      await setBackfillCursor({
        db,
        docId: cursorDocId,
        lastDocId: finishedScan ? null : cursor,
        operation: "backfillEnrichReferentials",
        adminUid: req.auth?.uid,
      });
    }

    const completed = !stoppedByDeadline;

    await logInfo({
      message: "backfillEnrichReferentials: terminé",
      correlationId,
      extra: {
        scannedUnits,
        enrichedUnits,
        scannedIngredients,
        enrichedIngredients,
        failedIngredients,
        refreshedIngredients,
        refreshSodium,
        completed,
        stoppedByDeadline,
      },
    });

    return {
      scannedUnits,
      enrichedUnits,
      scannedIngredients,
      enrichedIngredients,
      failedIngredients,
      refreshedIngredients,
      remainingUnitsWithoutWeight,
      completed,
      stoppedByDeadline,
    };
  },
);
