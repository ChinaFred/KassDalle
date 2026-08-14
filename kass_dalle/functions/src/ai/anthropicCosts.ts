/**
 * Ce qu'Anthropic a réellement facturé.
 *
 * La facturation Google ne contient pas les appels Claude : ils sont facturés
 * par Anthropic, hors de tout export BigQuery. Sans cette lecture, la part
 * Claude de nos coûts resterait une estimation que rien ne confronte — et une
 * estimation jamais confrontée finit toujours par diverger sans prévenir.
 *
 * Le rapport de coûts vit sur l'API d'administration Anthropic
 * (`/v1/organizations/cost_report`), qui exige une clé `sk-ant-admin...`
 * distincte de la clé d'inférence. Granularité : la journée, en USD, montants
 * rendus en cents sous forme de chaîne.
 *
 * **Cette API est sévèrement limitée en débit**, et la granularité journalière
 * multiplie les pages : une année d'historique en demande plusieurs dizaines.
 * Interroger à chaque affichage d'écran a suffi à la faire répondre 429, et
 * l'écran affichait alors « facturé : — » comme si Anthropic n'avait rien
 * facturé. Les montants sont donc mis en cache : un mois clos ne bouge plus
 * jamais, seul le mois courant mérite d'être redemandé.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { COLL_APP_CONFIG } from "../config";
import { logError, logInfo, logWarn } from "../logging";

const COST_REPORT_URL = "https://api.anthropic.com/v1/organizations/cost_report";

/** Document de cache des montants déjà lus. */
const CACHE_DOC_ID = "anthropic_costs";

/**
 * Fraîcheur exigée du mois courant.
 *
 * Lui seul bouge encore. Six heures suffisent à suivre une dépense mensuelle,
 * et ramènent la consommation de l'API à quelques appels par jour au lieu d'un
 * par affichage d'écran.
 */
const CURRENT_MONTH_TTL_MS = 6 * 60 * 60 * 1000;

/** Tentatives supplémentaires après un 429, en respectant `retry-after`. */
const MAX_RATE_LIMIT_RETRIES = 2;

/** Attente maximale consentie à un `retry-after` : au-delà, la fonction expire. */
const MAX_RETRY_WAIT_MS = 15_000;

/** Coût facturé par Anthropic pour un mois donné. */
export interface AnthropicMonthlyCost {
  /** `AAAA-MM`. */
  period: string;
  billedUsd: number;
}

export interface AnthropicCostReport {
  /** Vrai dès qu'on dispose de montants — fraîchement lus ou mis en cache. */
  available: boolean;
  months: AnthropicMonthlyCost[];
  /** Renseigné quand la lecture a échoué — distingue « zéro » de « on ne sait pas ». */
  error?: string;
  /** Vrai quand les montants viennent du cache faute d'avoir pu interroger l'API. */
  stale?: boolean;
}

/**
 * Préfixe d'une clé d'administration Anthropic.
 *
 * Le secret doit exister pour que la fonction se déploie — Firebase refuse
 * d'attacher un secret absent. Il est donc créé avec une valeur d'attente, et
 * ce contrôle de préfixe distingue cette valeur d'une vraie clé : sans lui, le
 * rapport serait demandé à chaque affichage pour se faire refuser en 401, et
 * les logs se rempliraient d'une panne qui n'en est pas une.
 */
const ADMIN_KEY_PREFIX = "sk-ant-admin";

/**
 * Clé d'administration, lue depuis l'environnement.
 *
 * Même contrat que la clé d'inférence : absente — ou pas encore posée — la
 * fonction rend `null` et l'appelant sert un rapport « indisponible » au lieu
 * d'échouer.
 */
export function anthropicAdminKey(): string | null {
  const key = (process.env.ANTHROPIC_ADMIN_KEY ?? "").trim();
  return key.startsWith(ADMIN_KEY_PREFIX) ? key : null;
}

/** Les montants arrivent en cents, sous forme de chaîne, pour éviter les flottants. */
function centsToUsd(value: unknown): number {
  const cents = Number(value);
  return Number.isFinite(cents) ? cents / 100 : 0;
}

/** Période `AAAA-MM` d'un horodatage ISO, en UTC — même convention que nos agrégats. */
function periodOf(iso: unknown): string | null {
  if (typeof iso !== "string") return null;
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  return periodOfDate(date);
}

function periodOfDate(date: Date): string {
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  return `${date.getUTCFullYear()}-${month}`;
}

/** Premier instant d'une période `AAAA-MM`, en UTC. */
function startOfPeriod(period: string): Date {
  const [year, month] = period.split("-").map(Number);
  return new Date(Date.UTC(year, month - 1, 1));
}

/** Premier instant de la période suivante, en UTC — borne de fin exclue. */
function endOfPeriod(period: string): Date {
  const [year, month] = period.split("-").map(Number);
  return new Date(Date.UTC(year, month, 1));
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Attente demandée par l'en-tête `retry-after`, bornée. */
function retryAfterMs(response: Response): number {
  const header = response.headers.get("retry-after");
  const seconds = Number(header);
  if (!Number.isFinite(seconds) || seconds <= 0) return 2_000;
  return Math.min(seconds * 1000, MAX_RETRY_WAIT_MS);
}

interface CostReportPage {
  data?: Array<{ starting_at?: string; results?: Array<{ amount?: unknown }> }>;
  has_more?: boolean;
  next_page?: string | null;
}

/**
 * Une page du rapport, avec patience sur la limite de débit.
 *
 * Un 429 n'est pas une panne : c'est une demande d'attendre. Le traiter comme
 * une erreur faisait perdre l'intégralité du rapport pour une seconde de trop.
 */
async function fetchPage(args: {
  key: string;
  startIso: string;
  endIso: string;
  page: string | null;
  correlationId: string;
}): Promise<CostReportPage> {
  for (let attempt = 0; ; attempt++) {
    const url = new URL(COST_REPORT_URL);
    url.searchParams.set("starting_at", args.startIso);
    url.searchParams.set("ending_at", args.endIso);
    if (args.page) url.searchParams.set("page", args.page);

    const response = await fetch(url, {
      headers: {
        "x-api-key": args.key,
        "anthropic-version": "2023-06-01",
        "user-agent": "KassDalle/1.0 (https://kassdale-6d948.web.app)",
      },
    });

    if (response.status === 429 && attempt < MAX_RATE_LIMIT_RETRIES) {
      const waitMs = retryAfterMs(response);
      await logWarn({
        message: `fetchAnthropicMonthlyCosts: limite de débit atteinte, nouvelle tentative dans ${waitMs} ms`,
        correlationId: args.correlationId,
        provider: "anthropic",
        extra: { attempt: attempt + 1 },
      });
      await sleep(waitMs);
      continue;
    }

    if (!response.ok) {
      const body = await response.text();
      throw new Error(`HTTP ${response.status} — ${body.slice(0, 300)}`);
    }

    return (await response.json()) as CostReportPage;
  }
}

/**
 * Ce qu'Anthropic a facturé sur les périodes demandées.
 *
 * Ne redemande que ce qui manque : un mois clos est lu une fois pour toutes,
 * le mois courant toutes les six heures. Un échec ne fait pas disparaître les
 * montants déjà connus — il les rend tels quels, signalés comme datés.
 */
export async function fetchAnthropicMonthlyCosts(args: {
  /** Périodes `AAAA-MM` affichées, dans n'importe quel ordre. */
  periods: string[];
  correlationId: string;
  /** Ignore le cache et relit tout — réservé à une demande explicite. */
  force?: boolean;
}): Promise<AnthropicCostReport> {
  const key = anthropicAdminKey();
  if (!key) {
    return { available: false, months: [] };
  }

  const wanted = [...new Set(args.periods)].filter((p) => /^\d{4}-\d{2}$/.test(p)).sort();
  if (wanted.length === 0) {
    return { available: true, months: [] };
  }

  const db = getFirestore();
  const cacheRef = db.collection(COLL_APP_CONFIG).doc(CACHE_DOC_ID);
  const cacheSnap = await cacheRef.get();
  const cacheData = cacheSnap.data() ?? {};
  const cached: Record<string, number> = { ...((cacheData.months ?? {}) as Record<string, number>) };
  const currentFetchedAtMs =
    typeof cacheData.current_month_fetched_at_ms === "number"
      ? cacheData.current_month_fetched_at_ms
      : 0;

  const now = new Date();
  const currentPeriod = periodOfDate(now);
  // Le mois courant est le seul qui bouge encore ; les mois clos sont
  // définitifs, les redemander ne changerait qu'une chose : le quota consommé.
  const currentIsStale = now.getTime() - currentFetchedAtMs > CURRENT_MONTH_TTL_MS;

  const missing = wanted.filter((period) => {
    if (args.force === true) return true;
    if (period === currentPeriod) return currentIsStale || !(period in cached);
    return !(period in cached);
  });

  const asReport = (extra: Partial<AnthropicCostReport> = {}): AnthropicCostReport => ({
    available: wanted.some((period) => period in cached),
    months: wanted
      .filter((period) => period in cached)
      .map((period) => ({ period, billedUsd: cached[period] })),
    ...extra,
  });

  if (missing.length === 0) {
    return asReport();
  }

  const firstPeriod = missing[0];
  const lastPeriod = missing[missing.length - 1];
  const startIso = startOfPeriod(firstPeriod).toISOString();
  // Jamais au-delà de maintenant : demander un futur ne rend rien et compte
  // quand même dans le quota.
  const end = endOfPeriod(lastPeriod);
  const endIso = (end.getTime() > now.getTime() ? now : end).toISOString();

  const fetched = new Map<string, number>();
  let page: string | null = null;
  let requests = 0;

  try {
    do {
      const payload = await fetchPage({
        key,
        startIso,
        endIso,
        page,
        correlationId: args.correlationId,
      });

      for (const bucket of payload.data ?? []) {
        const period = periodOf(bucket.starting_at);
        if (!period) continue;
        const total = (bucket.results ?? []).reduce(
          (sum, entry) => sum + centsToUsd(entry.amount),
          0,
        );
        fetched.set(period, (fetched.get(period) ?? 0) + total);
      }

      page = payload.has_more === true ? (payload.next_page ?? null) : null;
      requests += 1;
      // Garde-fou : une pagination qui ne se termine pas boucle sur le quota
      // plutôt que de rendre la main.
    } while (page != null && requests < 40);

    // Un mois couvert par la lecture et absent du rapport a réellement coûté
    // zéro : l'inscrire évite de le redemander à chaque affichage.
    for (const period of missing) {
      cached[period] = Number((fetched.get(period) ?? 0).toFixed(6));
    }
    for (const [period, amount] of fetched) {
      cached[period] = Number(amount.toFixed(6));
    }

    await cacheRef.set(
      {
        months: cached,
        updated_at: FieldValue.serverTimestamp(),
        ...(missing.includes(currentPeriod)
          ? { current_month_fetched_at_ms: now.getTime() }
          : {}),
      },
      { merge: true },
    );

    await logInfo({
      message: `fetchAnthropicMonthlyCosts: ${missing.length} mois relus en ${requests} requêtes`,
      correlationId: args.correlationId,
      provider: "anthropic",
      extra: { requests, refreshed: missing.length, cached: Object.keys(cached).length },
    });

    return asReport();
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await logError({
      message: "fetchAnthropicMonthlyCosts: rapport de coûts Anthropic illisible",
      correlationId: args.correlationId,
      provider: "anthropic",
      errorDescription: message,
    });
    // Ce qui est déjà connu reste affiché : une limite de débit passagère ne
    // doit pas transformer des montants facturés en « — ». Le drapeau `stale`
    // dit que le mois courant peut avoir bougé depuis.
    return asReport({ error: message, stale: true });
  }
}
