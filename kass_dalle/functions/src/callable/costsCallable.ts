/**
 * Ce que coûte l'application, mois par mois.
 *
 * Deux natures de coûts, une seule lecture :
 *
 *  - l'**IA**, mesurée par l'application elle-même, ventilable par poste
 *    fonctionnel, par moteur et par modèle ;
 *  - l'**infrastructure** (Functions, Storage, Tasks, BigQuery…), connue
 *    seulement par la facturation Google, ventilable par service et par rien
 *    d'autre. Aucune clé de répartition honnête ne permet d'imputer une seconde
 *    de Cloud Function à un poste fonctionnel ; prétendre le contraire
 *    fabriquerait un chiffre précis et faux.
 *
 * Les montants IA ne sont **jamais recalculés ici** : ils sont lus tels que la
 * consommation les a figés au moment de l'appel. Deux grilles tarifaires
 * appliquées au même appel finissent toujours par diverger, et l'écart ne casse
 * aucun écran — il fait seulement mentir le reporting.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

import {
  ANTHROPIC_ADMIN_KEY,
  COLL_AI_USAGE,
  COLL_AI_USAGE_MONTHLY,
  COLL_APP_CONFIG,
  REGION,
  MAX_CALLABLE_INSTANCES,
} from "../config";
import { requireAdmin } from "./_auth";
import { logError, logInfo } from "../logging";
import { periodBounds, periodOf } from "../billing/periods";
import { sanitizeMapKey } from "../ai/usage";
import {
  estimateAiCostUsd,
  freeTierCredits,
  loadAiPricingTable,
  type AiModelPricing,
} from "../ai/pricing";
import { fetchAnthropicMonthlyCosts } from "../ai/anthropicCosts";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const DATASET = "billing_export";
const TABLE_WILDCARD = "gcp_billing_export_v1_*";

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

/**
 * Profondeur maximale de la facturation Google.
 *
 * L'export BigQuery ne remonte pas indéfiniment et un scan large coûte plus
 * qu'il n'apprend. La part IA, elle, se lit dans nos propres agrégats : elle
 * peut remonter au premier appel jamais enregistré, ce que « depuis le début »
 * exploite.
 */
const MAX_GCP_MONTHS = 13;

function toNumber(value: unknown): number {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

/**
 * Services Google qui facturent l'inférence Gemini.
 *
 * Ils arrivent par la même porte que Cloud Functions ou Storage — la
 * facturation Google — mais ce ne sont pas des coûts d'infrastructure : c'est
 * l'IA, au même titre que Claude. Les laisser dans l'infrastructure rendait la
 * comparaison des deux moteurs impossible, l'un ayant sa section et l'autre
 * étant noyé dans une liste de services.
 */
const GEMINI_SERVICE_PATTERNS = ["gemini", "generative language", "vertex ai", "aiplatform"];

function isGeminiService(service: string): boolean {
  const lower = service.toLowerCase();
  return GEMINI_SERVICE_PATTERNS.some((pattern) => lower.includes(pattern));
}

/**
 * Nature d'une ligne de facture Gemini.
 *
 * Google libelle ses SKU en clair — « Generate content output token count
 * gemini 2.5 flash short input text ». Les classer permet de comparer, jeton
 * pour jeton, ce qui a été facturé et ce que l'application a compté. C'est ce
 * rapprochement qui transforme un écart en diagnostic : un écart en euros
 * n'apprend rien, un écart de deux millions de jetons de sortie désigne le
 * raisonnement sans ambiguïté.
 */
function billedTokenKind(sku: string): "input" | "output" | null {
  const lower = sku.toLowerCase();
  if (!lower.includes("token count")) return null;
  if (lower.includes("output token")) return "output";
  // Les jetons mis en cache sont de l'entrée facturée moins cher : les ranger
  // ailleurs ferait apparaître une entrée manquante qui n'existe pas.
  if (lower.includes("input token")) return "input";
  return null;
}

/** Les `count` derniers mois, du plus ancien au plus récent. */
function recentPeriods(count: number, now: Date): string[] {
  const periods: string[] = [];
  for (let i = count - 1; i >= 0; i--) {
    const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - i, 1));
    periods.push(periodOf(d));
  }
  return periods;
}

// ── Lecture ──────────────────────────────────────────────────────────────────

export const getMonthlyCostsFn = onCall(
  {
    region: REGION,
    timeoutSeconds: 120,
    memory: "512MiB",
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
    secrets: [ANTHROPIC_ADMIN_KEY],
  },
  async (req) => {
    await requireAdmin(req, "couts_mensuels");
    const correlationId = `monthly-costs-${Date.now()}`;

    const data = (req.data ?? {}) as {
      months?: number;
      all?: boolean;
      /** Périodes `AAAA-MM` à relire chez Anthropic, cache ignoré. */
      refreshAnthropicPeriods?: string[];
    };
    const requested = Number(data.months);
    const months = Number.isFinite(requested) ? Math.max(1, Math.trunc(requested)) : 12;
    const wantsAll = data.all === true;

    const db = getFirestore();

    // ── Part IA : un document par mois, déjà agrégé ─────────────────────────
    //
    // « Depuis le début » lit la collection entière : un document par mois,
    // quelques dizaines au plus. Ce qui interdisait une telle lecture, c'était
    // l'ancien modèle — une ligne par appel.
    const aiByPeriod = new Map<string, Record<string, unknown>>();
    if (wantsAll) {
      const snap = await db.collection(COLL_AI_USAGE_MONTHLY).get();
      for (const doc of snap.docs) aiByPeriod.set(doc.id, doc.data() ?? {});
    } else {
      const wanted = recentPeriods(months, new Date());
      const snaps = await db.getAll(
        ...wanted.map((p) => db.collection(COLL_AI_USAGE_MONTHLY).doc(p)),
      );
      for (const snap of snaps) {
        if (snap.exists) aiByPeriod.set(snap.id, snap.data() ?? {});
      }
    }

    // La série affichée couvre les mois demandés, plus tout mois enregistré qui
    // les précède quand on regarde depuis le début.
    const periods = [
      ...new Set([
        ...(wantsAll ? [...aiByPeriod.keys()] : []),
        ...recentPeriods(wantsAll ? 1 : months, new Date()),
      ]),
    ].sort();

    // ── Part infrastructure : la facturation Google, groupée par mois ───────
    const projectId = process.env.GCLOUD_PROJECT ?? process.env.GCP_PROJECT;
    if (!projectId) {
      throw new HttpsError("internal", "Project ID indisponible.");
    }

    // La facturation Google ne remonte que sur la fenêtre d'export : « depuis
    // le début » couvre donc toute l'IA mais seulement l'infrastructure encore
    // exportée. L'écran doit le dire plutôt que de laisser croire à une
    // infrastructure gratuite avant cette date.
    const gcpPeriods = periods.slice(-MAX_GCP_MONTHS);
    const gcpTruncated = gcpPeriods.length < periods.length;

    const startMs = periodBounds(gcpPeriods[0])?.start.getTime();
    const endMs = periodBounds(gcpPeriods[gcpPeriods.length - 1])?.end.getTime();
    if (startMs == null || endMs == null) {
      throw new HttpsError("internal", "Bornes de période illisibles.");
    }

    // `currency_conversion_rate` est le taux USD → devise du compte que Google
    // a lui-même appliqué à la ligne. Le relever mois par mois vaut mieux qu'un
    // taux unique appliqué à tout l'historique : un montant de l'an dernier
    // converti au taux d'aujourd'hui n'est pas le montant qui a été payé.
    // Le SKU est la ligne réelle de la facture : « Gemini 2.5 Flash Output
    // Tokens », « Input Tokens », « Image Generation »… Sans lui, l'écart entre
    // l'estimé et le facturé reste un seul nombre rouge qu'aucune lecture ne
    // décompose — et c'est précisément la décomposition qui désigne le poste
    // sous-compté.
    const sql = `
      SELECT
        FORMAT_TIMESTAMP('%Y-%m', usage_start_time) AS period,
        service.description AS service,
        sku.description AS sku,
        ANY_VALUE(currency) AS currency,
        AVG(NULLIF(currency_conversion_rate, 0)) AS usd_to_native,
        SUM(usage.amount) AS usage_amount,
        ANY_VALUE(usage.unit) AS usage_unit,
        SUM(cost) AS gross_native,
        COALESCE(SUM((SELECT SUM(c.amount) FROM UNNEST(credits) c)), 0) AS credits_native,
        SUM(SAFE_DIVIDE(cost, NULLIF(currency_conversion_rate, 0))) AS gross_usd,
        COALESCE(SUM(SAFE_DIVIDE(
          (SELECT SUM(c.amount) FROM UNNEST(credits) c),
          NULLIF(currency_conversion_rate, 0)
        )), 0) AS credits_usd
      FROM \`${projectId}.${DATASET}.${TABLE_WILDCARD}\`
      WHERE usage_start_time >= TIMESTAMP_MILLIS(@startMs)
        AND usage_start_time < TIMESTAMP_MILLIS(@endMs)
      GROUP BY period, service, sku
      ORDER BY period, gross_usd DESC
    `;

    // `gcpQueryFailed` distingue « rien facturé » de « on n'a pas pu savoir ».
    // Sans cette distinction, une requête en échec produit un écran affirmant
    // que l'infrastructure est gratuite.
    /** Une ligne de la facture Gemini, telle que Google la libelle. */
    interface GeminiSku {
      sku: string;
      costUsd: number;
      /** Quantité facturée et son unité, quand Google les renseigne. */
      amount: number;
      unit: string;
    }

    interface GcpMonth {
      /** Infrastructure seule : l'inférence Gemini en est retirée. */
      services: Map<string, number>;
      /** Ce que Google a facturé pour Gemini, tous services d'inférence confondus. */
      geminiBilledUsd: number;
      /** Le détail de cette facture, ligne par ligne. */
      geminiSkus: Map<string, GeminiSku>;
      /** Jetons réellement facturés, à confronter à ceux que nous comptons. */
      billedInputTokens: number;
      billedOutputTokens: number;
      currency: string;
      /** Taux USD → devise du compte appliqué par Google ce mois-là. */
      rate: number;
      rateWeight: number;
    }

    const gcpByPeriod = new Map<string, GcpMonth>();
    let gcpQueryFailed = false;
    try {
      const [rows] = await (
        await bigQuery()
      ).query({
        query: sql,
        params: { startMs, endMs },
        types: { startMs: "INT64", endMs: "INT64" },
        location: "EU",
      });
      for (const row of rows as Record<string, unknown>[]) {
        const period = String(row.period ?? "");
        if (!period) continue;
        const entry = gcpByPeriod.get(period) ?? {
          services: new Map(),
          geminiBilledUsd: 0,
          geminiSkus: new Map(),
          billedInputTokens: 0,
          billedOutputTokens: 0,
          currency: "USD",
          rate: 0,
          rateWeight: 0,
        };
        const service = String(row.service ?? "Autre");
        const usd = toNumber(row.gross_usd) + toNumber(row.credits_usd);
        if (isGeminiService(service)) {
          entry.geminiBilledUsd += usd;
          const sku = String(row.sku ?? "Ligne non libellée");
          const line = entry.geminiSkus.get(sku) ?? {
            sku,
            costUsd: 0,
            amount: 0,
            unit: String(row.usage_unit ?? ""),
          };
          line.costUsd += usd;
          line.amount += toNumber(row.usage_amount);
          entry.geminiSkus.set(sku, line);

          const kind = billedTokenKind(sku);
          if (kind === "input") entry.billedInputTokens += toNumber(row.usage_amount);
          if (kind === "output") entry.billedOutputTokens += toNumber(row.usage_amount);
        } else {
          entry.services.set(service, (entry.services.get(service) ?? 0) + usd);
        }
        if (typeof row.currency === "string" && row.currency.length > 0) {
          entry.currency = row.currency;
        }
        // Moyenne simple des taux relevés sur les lignes du mois : Google
        // n'applique qu'un taux par mois, les rares écarts sont des arrondis.
        const rate = toNumber(row.usd_to_native);
        if (rate > 0) {
          entry.rate += rate;
          entry.rateWeight += 1;
        }
        gcpByPeriod.set(period, entry);
      }
    } catch (err) {
      gcpQueryFailed = true;
      await logError({
        message: "getMonthlyCostsFn: facturation GCP illisible",
        correlationId,
        errorDescription: err instanceof Error ? err.message : String(err),
      });
    }

    // ── Part Claude réellement facturée, lue chez Anthropic ────────────────
    // Elle n'apparaît dans aucun export Google : sans cette lecture, la moitié
    // du coût d'IA reste une estimation que rien ne confronte.
    //
    // Les périodes affichées, et elles seules : l'API d'administration
    // Anthropic rend des journées, si bien qu'une fenêtre d'un an coûte des
    // dizaines de requêtes sur une limite de débit basse. Demander large « au
    // cas où » a suffi à la faire répondre 429, et l'écran affichait alors
    // « facturé : — » comme si Anthropic n'avait rien facturé.
    const anthropic = await fetchAnthropicMonthlyCosts({
      periods,
      correlationId,
      forcePeriods: Array.isArray(data.refreshAnthropicPeriods)
        ? data.refreshAnthropicPeriods.filter((p) => typeof p === "string")
        : undefined,
    });
    const anthropicByPeriod = new Map(anthropic.months.map((m) => [m.period, m]));

    // ── Taux de change ─────────────────────────────────────────────────────
    //
    // Le taux du mois, relevé sur la facture elle-même, prime toujours. Le taux
    // global n'est qu'un dernier recours pour les mois sans ligne Google — sans
    // lui, un mois d'IA pure resterait affiché en dollars au milieu d'euros.
    const rateSnap = await db.collection(COLL_APP_CONFIG).doc("currency_rate").get();
    const configuredRate = toNumber(rateSnap.data()?.usd_to_eur) || 0;

    /** Taux de la facture la plus récente, à défaut de mieux pour les autres mois. */
    const latestBilledRate = [...gcpByPeriod.entries()]
      .sort((a, b) => a[0].localeCompare(b[0]))
      .reduce(
        (rate, [, month]) =>
          month.currency === "EUR" && month.rateWeight > 0 ? month.rate / month.rateWeight : rate,
        0,
      );
    const fallbackRate = latestBilledRate || configuredRate;

    // Grille en vigueur, pour les franchises mensuelles. Une grille illisible
    // n'en accorde aucune : un avoir deviné ferait afficher un mois moins cher
    // qu'il ne l'a été, et l'écran n'aurait rien pour le dire.
    let pricingTable: Record<string, AiModelPricing> | null = null;
    try {
      pricingTable = await loadAiPricingTable();
    } catch (err) {
      await logError({
        message: "getMonthlyCostsFn: grille illisible, aucune franchise n'est déduite",
        correlationId,
        errorDescription: err instanceof Error ? err.message : String(err),
      });
    }

    /** Part d'un moteur dans nos propres compteurs. */
    function providerUsage(ai: Record<string, unknown>, provider: string) {
      const byProvider = (ai.by_provider ?? {}) as Record<string, Record<string, unknown>>;
      const entry = byProvider[provider] ?? {};
      return {
        estimatedUsd: toNumber(entry.cost_usd),
        calls: toNumber(entry.calls),
        inputTokens: toNumber(entry.input_tokens),
        outputTokens: toNumber(entry.output_tokens),
        thinkingTokens: toNumber(entry.thinking_tokens),
        // Jetons de prompt passés par le cache. Non nuls sur `transcription_page`
        // et `recipe_tagging` depuis le 28 septembre 2026, zéro partout ailleurs
        // — c'est justement ce que l'écran doit pouvoir montrer plutôt que
        // laisser supposer.
        cacheWriteTokens: toNumber(entry.cache_creation_input_tokens),
        cacheReadTokens: toNumber(entry.cache_read_input_tokens),
      };
    }

    const result = periods.map((period) => {
      const ai = aiByPeriod.get(period) ?? {};
      const gcp = gcpByPeriod.get(period);
      const gcpServices = gcp
        ? [...gcp.services.entries()]
            .map(([service, costUsd]) => ({ service, costUsd }))
            .sort((a, b) => b.costUsd - a.costUsd)
        : [];
      const infraTotal = gcpServices.reduce((sum, s) => sum + s.costUsd, 0);
      const aiTotal = toNumber(ai.total_cost_usd);

      const anthropicEntry = anthropicByPeriod.get(period);
      const anthropicBilled = anthropicEntry?.billedUsd ?? null;
      // Un mois sans ligne Gemini dans un export lisible a réellement coûté
      // zéro. Un export illisible, lui, ne dit rien : `null` porte cette
      // nuance jusqu'à l'écran.
      const geminiBilled = gcpQueryFailed ? null : (gcp?.geminiBilledUsd ?? 0);

      const anthropic = providerUsage(ai, "anthropic");
      const gemini = providerUsage(ai, "gemini");
      const internal = providerUsage(ai, "internal");

      // ── Franchises du mois ────────────────────────────────────────────────
      //
      // Lues sur le tarif du mois concerné, jamais sur celui du jour où l'on
      // relit : pour le mois en cours, l'instant est maintenant ; pour un mois
      // clos, son dernier instant. Sans cette borne, une promotion terminée
      // depuis réécrirait un mois passé.
      //
      // Les unités viennent de `by_model`, dont les clés sont assainies : c'est
      // la grille qui donne les identifiants vrais, et `sanitizeMapKey` fait le
      // pont dans ce sens-là, le seul qui soit exact.
      const bounds = periodBounds(period);
      const monthEnd = bounds ? new Date(bounds.end.getTime() - 1) : new Date();
      const at = monthEnd.getTime() > Date.now() ? new Date() : monthEnd;
      const byModel = (ai.by_model ?? {}) as Record<string, Record<string, unknown>>;
      const credits = pricingTable
        ? freeTierCredits({
            table: pricingTable,
            at,
            unitsFor: (m) => toNumber(byModel[sanitizeMapKey(m)]?.analyzed_image_units),
            costFor: (m) => toNumber(byModel[sanitizeMapKey(m)]?.cost_usd),
          })
        : [];
      const freeTierUsd = credits.reduce((sum, c) => sum + c.creditUsd, 0);

      const monthRate =
        gcp && gcp.rateWeight > 0 && gcp.currency === "EUR"
          ? gcp.rate / gcp.rateWeight
          : fallbackRate;

      return {
        period,
        /** Taux USD → EUR de ce mois-là, tel que Google l'a appliqué. */
        usdToEur: monthRate,
        ai: {
          totalCostUsd: aiTotal,
          calls: toNumber(ai.total_calls),
          failedCalls: toNumber(ai.total_failed_calls),
          inputTokens: toNumber(ai.total_input_tokens),
          outputTokens: toNumber(ai.total_output_tokens),
          thinkingTokens: toNumber(ai.total_thinking_tokens),
          imageOutputs: toNumber(ai.total_image_outputs),
          analyzedImageUnits: toNumber(ai.total_analyzed_image_units),
          groundedSearches: toNumber(ai.total_grounded_searches),
          // `totalCostUsd` reste BRUT, et les ventilations avec lui : elles
          // comptent des appels, et un appel a coûté ce qu'il a coûté. L'avoir
          // est rendu à part, avec son détail, pour que l'écran le pose sur une
          // ligne à lui. Une remise fondue dans un total est une remise que
          // personne ne peut vérifier.
          freeTierUsd,
          freeTier: credits,
          byFeature: ai.by_feature ?? {},
          byProvider: ai.by_provider ?? {},
          byModel: ai.by_model ?? {},
          byUser: ai.by_user ?? {},
        },
        // Les deux moteurs sont rendus sous la même forme — estimé d'un côté,
        // facturé de l'autre — pour que la comparaison soit possible. Estimé et
        // facturé ne sont jamais additionnés : ce sont deux mesures de la même
        // dépense, les sommer la compterait deux fois.
        anthropic: {
          ...anthropic,
          billedUsd: anthropicBilled,
          // L'âge du relevé, sans lequel l'écart n'est pas interprétable :
          // nos compteurs bougent en continu, la facture est une photographie.
          billedAtMs: anthropicEntry?.fetchedAtMs ?? null,
          // Le détail de la facture, modèle par modèle et nature de jeton par
          // nature de jeton. Même forme que les lignes Gemini — un écart global
          // ne se diagnostique pas, ventilé il désigne le modèle ou la nature
          // de consommation que nos compteurs ne voient pas.
          //
          // `amount` et `unit` restent vides : l'API de coûts d'Anthropic rend
          // des montants, jamais des quantités. Annoncer zéro jeton facturé
          // serait plus faux que ne rien annoncer.
          billedLines: (anthropicEntry?.lines ?? []).map((line) => ({
            sku: line.label,
            costUsd: line.costUsd,
            amount: 0,
            unit: "",
          })),
          billedInputTokens: null,
          billedOutputTokens: null,
        },
        gemini: {
          ...gemini,
          billedUsd: geminiBilled,
          // Ce que Google a facturé en jetons, à confronter à ce que nous
          // comptons. `null` quand l'export est illisible — une absence de
          // donnée n'est pas un zéro.
          billedInputTokens: gcpQueryFailed ? null : (gcp?.billedInputTokens ?? 0),
          billedOutputTokens: gcpQueryFailed ? null : (gcp?.billedOutputTokens ?? 0),
          // Le détail de la facture, du plus cher au moins cher : c'est lui qui
          // désigne le poste sous-compté quand l'écart se creuse.
          billedLines: gcp
            ? [...gcp.geminiSkus.values()].sort((a, b) => b.costUsd - a.costUsd)
            : [],
        },
        internal,
        gcp: {
          totalCostUsd: infraTotal,
          services: gcpServices,
          currency: gcp?.currency ?? "USD",
        },
        anthropicBilledUsd: anthropicBilled,
        // Le total privilégie le facturé quand il existe : c'est le montant
        // réellement payé. À défaut, l'estimation prend le relais — un poste
        // absent vaut moins qu'un poste approché.
        totalCostUsd:
          infraTotal +
          (anthropicBilled ?? anthropic.estimatedUsd) +
          (geminiBilled ?? gemini.estimatedUsd) +
          internal.estimatedUsd,
      };
    });

    await logInfo({
      message: `getMonthlyCostsFn: ${result.length} mois servis`,
      correlationId,
      extra: {
        months: result.length,
        all: wantsAll,
        gcpQueryFailed,
        gcpTruncated,
        anthropicAvailable: anthropic.available,
      },
    });

    return {
      months: result,
      /** Dernier recours : chaque mois porte le sien, relevé sur sa facture. */
      usdToEur: fallbackRate,
      gcpQueryFailed,
      /** Vrai quand l'historique IA remonte plus loin que la facturation Google. */
      gcpTruncated,
      anthropicAvailable: anthropic.available,
      anthropicError: anthropic.error ?? null,
      /** Montants Anthropic issus du cache faute d'avoir pu relire l'API. */
      anthropicStale: anthropic.stale === true,
      /** Tous les mois n'ont pas encore été lus — la suite viendra d'elle-même. */
      anthropicPartial: anthropic.partial === true,
    };
  },
);

// ── Reconstruction ───────────────────────────────────────────────────────────

/**
 * Reconstruit les agrégats mensuels depuis les lignes d'appel.
 *
 * Sert deux usages avec le même code : rattraper l'historique accumulé avant
 * l'existence des agrégats, et réparer un mois dont les compteurs auraient
 * dérivé. L'écriture écrase le document (`set` sans fusion) : un recalcul doit
 * pouvoir corriger un compteur trop haut, pas seulement le compléter.
 */
export const rebuildAiUsageMonthlyFn = onCall(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: "1GiB",
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req) => {
    const ctx = await requireAdmin(req, "reconstruction_usage_mensuel");
    const correlationId = `rebuild-usage-monthly-${Date.now()}`;
    const data = (req.data ?? {}) as {
      periods?: string[];
      months?: number;
      /**
       * Recalcule le coût de chaque appel au lieu de relire celui qui y a été
       * figé. À n'employer que lorsque la grille tarifaire elle-même était
       * fausse — c'est la seule réparation possible dans ce cas, et elle
       * réécrit des montants déjà publiés.
       */
      recomputeCosts?: boolean;
    };
    const recompute = data.recomputeCosts === true;
    // Une seule lecture de la grille pour toute la reconstruction : la relire
    // par appel ferait des milliers de lectures, et surtout laisserait une
    // modification en cours de route couper le mois en deux tarifs.
    //
    // Une reconstruction sans grille n'a aucun sens : elle réécrirait des
    // montants publiés à partir de rien. Elle échoue franchement, plutôt que
    // de produire un mois entier de zéros crédibles.
    let pricingTable;
    try {
      pricingTable = await loadAiPricingTable();
    } catch (err) {
      throw new HttpsError(
        "failed-precondition",
        "Grille tarifaire indisponible : la reconstruction réécrirait des " +
          `montants sans savoir à quel prix. ${err instanceof Error ? err.message : String(err)}`,
      );
    }

    const periods =
      Array.isArray(data.periods) && data.periods.length > 0
        ? data.periods.filter((p) => typeof p === "string" && periodBounds(p) != null)
        : // La reconstruction relit nos propres lignes d'appel, pas la
          // facturation Google : rien ne l'oblige à s'arrêter à la fenêtre
          // d'export. Le plafond n'est là que pour borner un appel accidentel.
          recentPeriods(
            Math.min(Math.max(1, Math.trunc(Number(data.months) || 12)), 36),
            new Date(),
          );

    if (periods.length === 0) {
      throw new HttpsError("invalid-argument", "Aucune période valide à reconstruire.");
    }

    const db = getFirestore();
    const rebuilt: Array<{ period: string; calls: number; costUsd: number }> = [];

    for (const period of periods) {
      const bounds = periodBounds(period);
      if (!bounds) continue;

      const doc: Record<string, unknown> = {
        period,
        total_calls: 0,
        // Reconstruits comme les autres, et pour la meme raison : un `set` sans
        // fusion efface le document, et ces trois compteurs disparaitraient
        // sans qu aucun montant ne bouge — un mois traverse par une panne de
        // grille se relirait ensuite comme un mois sans incident.
        total_failed_calls: 0,
        total_unpriced_calls: 0,
        total_input_tokens: 0,
        total_output_tokens: 0,
        total_thinking_tokens: 0,
        total_cache_creation_input_tokens: 0,
        total_cache_read_input_tokens: 0,
        total_image_outputs: 0,
        total_analyzed_image_units: 0,
        total_grounded_searches: 0,
        total_cost_usd: 0,
      };
      const byFeature: Record<string, Record<string, unknown>> = {};
      const byProvider: Record<string, Record<string, number>> = {};
      const byModel: Record<string, Record<string, number>> = {};
      const byUser: Record<string, Record<string, unknown>> = {};

      // Pagination par curseur : un mois chargé d'un bloc tiendrait peut-être
      // en mémoire aujourd'hui, sûrement plus dans un an.
      let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      let scanned = 0;
      for (;;) {
        let query = db
          .collection(COLL_AI_USAGE)
          .where("timestamp", ">=", bounds.start)
          .where("timestamp", "<", bounds.end)
          .orderBy("timestamp")
          .limit(1000);
        if (cursor) query = query.startAfter(cursor);
        const snap = await query.get();
        if (snap.empty) break;

        for (const entry of snap.docs) {
          const d = entry.data();
          const feature = sanitizeMapKey(String(d.feature ?? "inconnu"));
          const model = String(d.model ?? "");
          const provider = sanitizeMapKey(
            String(d.provider ?? (model.startsWith("claude") ? "anthropic" : "gemini")),
          );
          const input = toNumber(d.input_tokens);
          const output = toNumber(d.output_tokens);
          const thinking = toNumber(d.thinking_tokens);
          // Jetons de prompt passés par le cache : absents des lignes les plus
          // anciennes, et facturés à un autre tarif que l'entrée. Les oublier
          // ici rendrait une reconstruction moins chère que la réalité.
          const cacheWrite = toNumber(d.cache_creation_input_tokens);
          const cacheRead = toNumber(d.cache_read_input_tokens);
          const images = toNumber(d.image_output_count);
          // Unités d'image ANALYSÉE. Absentes des lignes écrites avant qu'on
          // les persiste : elles valent alors zéro, et un rechiffrage rendait
          // un appel Cloud Vision à zéro — le coût de la modération
          // disparaissait du mois reconstruit sans qu'aucune erreur ne sorte.
          const analyzedUnits = toNumber(d.analyzed_image_units);
          // Appels ancrés dans la recherche Google : même règle que les unités
          // d'image analysée, facturés à l'appel et absents des lignes écrites
          // avant octobre 2026.
          const groundedSearches = toNumber(d.grounded_search_count);
          // Le coût figé à l'appel fait foi. Il n'est recalculé que s'il est
          // absent — les lignes les plus anciennes n'en portaient pas. Le
          // recalcul se fait alors au tarif en vigueur **le jour de l'appel** :
          // au tarif du jour de la reconstruction, une promotion expirée
          // réécrirait le passé à la hausse.
          const calledAt =
            d.timestamp != null && typeof d.timestamp?.toDate === "function"
              ? (d.timestamp.toDate() as Date)
              : bounds.start;
          //
          // Un poste interne garde toujours son montant : il vient d'un prix
          // imposé (scan de sécurité facturé à l'unité), qu'aucune grille
          // tarifaire ne saurait retrouver.
          const keepFrozen =
            d.estimated_cost_usd != null && (!recompute || provider === "internal");
          const cost = keepFrozen
            ? toNumber(d.estimated_cost_usd)
            : estimateAiCostUsd({
                model,
                inputTokens: input,
                outputTokens: output + thinking,
                cacheCreationInputTokens: cacheWrite,
                cacheReadInputTokens: cacheRead,
                imageOutputCount: images,
                analyzedImageUnits: analyzedUnits,
                groundedSearchCount: groundedSearches,
                at: calledAt,
                table: pricingTable,
              });
          const uid = sanitizeMapKey(String(d.uid ?? "system_unattributed"));
          const modelKey = sanitizeMapKey(model || "inconnu");

          doc.total_calls = toNumber(doc.total_calls) + 1;
          doc.total_failed_calls =
            toNumber(doc.total_failed_calls) + (d.status === "error" ? 1 : 0);
          // Chaque ligne repasse par la grille quand elle n a pas de montant
          // fige : apres reconstruction, plus aucun appel n est sans prix. On
          // l ecrit tout de meme, plutot que de laisser le champ absent — un
          // champ absent se lit zero sans dire depuis quand.
          doc.total_unpriced_calls = toNumber(doc.total_unpriced_calls);
          doc.total_input_tokens = toNumber(doc.total_input_tokens) + input;
          doc.total_output_tokens = toNumber(doc.total_output_tokens) + output;
          doc.total_thinking_tokens = toNumber(doc.total_thinking_tokens) + thinking;
          doc.total_cache_creation_input_tokens =
            toNumber(doc.total_cache_creation_input_tokens) + cacheWrite;
          doc.total_cache_read_input_tokens =
            toNumber(doc.total_cache_read_input_tokens) + cacheRead;
          doc.total_image_outputs = toNumber(doc.total_image_outputs) + images;
          doc.total_analyzed_image_units = toNumber(doc.total_analyzed_image_units) + analyzedUnits;
          doc.total_grounded_searches = toNumber(doc.total_grounded_searches) + groundedSearches;
          doc.total_cost_usd = toNumber(doc.total_cost_usd) + cost;

          const f = (byFeature[feature] ??= {
            calls: 0,
            input_tokens: 0,
            output_tokens: 0,
            thinking_tokens: 0,
            image_outputs: 0,
            analyzed_image_units: 0,
            grounded_searches: 0,
            cost_usd: 0,
            by_provider: {},
          });
          f.calls = toNumber(f.calls) + 1;
          f.input_tokens = toNumber(f.input_tokens) + input;
          f.output_tokens = toNumber(f.output_tokens) + output;
          f.thinking_tokens = toNumber(f.thinking_tokens) + thinking;
          f.image_outputs = toNumber(f.image_outputs) + images;
          f.analyzed_image_units = toNumber(f.analyzed_image_units) + analyzedUnits;
          f.grounded_searches = toNumber(f.grounded_searches) + groundedSearches;
          f.cost_usd = toNumber(f.cost_usd) + cost;
          const fp = f.by_provider as Record<string, Record<string, number>>;
          const fpp = (fp[provider] ??= {
            calls: 0,
            cost_usd: 0,
            input_tokens: 0,
            output_tokens: 0,
            thinking_tokens: 0,
          });
          fpp.calls += 1;
          fpp.cost_usd += cost;
          fpp.input_tokens += input;
          fpp.output_tokens += output;
          fpp.thinking_tokens += thinking;

          const p = (byProvider[provider] ??= {
            calls: 0,
            input_tokens: 0,
            output_tokens: 0,
            thinking_tokens: 0,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0,
            cost_usd: 0,
          });
          p.calls += 1;
          p.input_tokens += input;
          p.output_tokens += output;
          p.thinking_tokens += thinking;
          // « Relus du cache » est affiche par moteur : sans ces deux lignes,
          // une reconstruction repond zero a une question dont la reponse
          // attendue est justement zero. Indiscernable, et faux.
          p.cache_creation_input_tokens += cacheWrite;
          p.cache_read_input_tokens += cacheRead;
          p.cost_usd += cost;

          // Les unités vivent aussi par MODÈLE : c'est le fournisseur qui offre
          // une franchise, et il l'offre sur un produit. La déduire depuis les
          // postes obligerait à recomposer les unités d'un modèle éclaté entre
          // plusieurs d'entre eux.
          const m = (byModel[modelKey] ??= {
            calls: 0,
            cost_usd: 0,
            analyzed_image_units: 0,
            grounded_searches: 0,
          });
          m.calls += 1;
          m.cost_usd += cost;
          m.analyzed_image_units += analyzedUnits;
          m.grounded_searches += groundedSearches;

          const u = (byUser[uid] ??= { calls: 0, cost_usd: 0, by_feature: {} });
          (u.calls as number) += 1;
          (u.cost_usd as number) += cost;

          // Le poste DANS le compte. Reconstruit ici comme il est ecrit en
          // direct par recordUsage : sans cette ligne, l ecran « Depense par
          // utilisateur » resterait vide sur tout mois reconstruit.
          const uf = u.by_feature as Record<string, Record<string, number>>;
          const ufe = (uf[feature] ??= { calls: 0, cost_usd: 0 });
          ufe.calls += 1;
          ufe.cost_usd += cost;
        }

        scanned += snap.size;
        cursor = snap.docs[snap.docs.length - 1];
        if (snap.size < 1000) break;
      }

      doc.by_feature = byFeature;
      doc.by_provider = byProvider;
      doc.by_model = byModel;
      doc.by_user = byUser;
      doc.rebuilt_at = FieldValue.serverTimestamp();
      doc.rebuilt_by = ctx.userId;
      doc.updated_at = FieldValue.serverTimestamp();

      await db.collection(COLL_AI_USAGE_MONTHLY).doc(period).set(doc);

      rebuilt.push({
        period,
        calls: toNumber(doc.total_calls),
        costUsd: Number(toNumber(doc.total_cost_usd).toFixed(6)),
      });

      await logInfo({
        message: `rebuildAiUsageMonthly: ${period} reconstruit`,
        correlationId,
        userId: ctx.userId,
        extra: {
          period,
          scanned,
          calls: doc.total_calls,
          costUsd: doc.total_cost_usd,
          recompute,
        },
      });
    }

    return { rebuilt };
  },
);
