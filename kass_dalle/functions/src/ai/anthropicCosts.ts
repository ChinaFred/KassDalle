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
 * La lecture demande `group_by[]=description` : chaque journée revient alors
 * ventilée par modèle et par nature de jeton — entrée, sortie, écriture et
 * lecture de cache — au lieu d'un montant unique. Ce regroupement ne change ni
 * le nombre de journées ni le nombre de pages, donc rien au quota, et c'est
 * lui qui transforme « il manque de l'argent » en diagnostic : un modèle qu'on
 * ne croyait pas appeler, ou une nature de consommation que nos compteurs
 * ignorent, se lisent directement dans le détail.
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
import { periodOf } from "../billing/periods";

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

/**
 * Journées demandées par page.
 *
 * Le rapport de coûts est **journalier** et sa page vaut 7 journées par défaut :
 * une année d'historique coûtait donc près de soixante requêtes, là où le
 * maximum documenté — 31 journées, la granularité `1d` — la ramène à treize.
 * C'est la première cause du 429, avant même la fréquence d'appel : le
 * plafond de pagination ci-dessous aurait d'ailleurs tronqué la lecture bien
 * avant d'avoir tout lu, sans le dire.
 */
const BUCKETS_PER_PAGE = 31;

/**
 * Pages lues par affichage d'écran.
 *
 * Anthropic tolère une rafale pour dérouler une pagination, mais pas une
 * rafale d'une année entière. On s'arrête volontairement en chemin : ce qui a
 * été lu est conservé, l'affichage suivant reprend la suite, et le cache se
 * remplit en quelques ouvertures au lieu de ne jamais se remplir.
 */
const MAX_PAGES_PER_CALL = 4;

/**
 * Mois demandés par affichage — quatre, soit à peu près les quatre pages
 * ci-dessus. Ce sont les **plus récents** qui sont lus en premier : le mois en
 * cours est le seul qu'on regarde vraiment.
 */
const MAX_PERIODS_PER_CALL = 4;

/** Respiration entre deux pages — une rafale serrée est ce qui déclenche le refus. */
const PAGE_INTERVAL_MS = 400;

/**
 * Pause observée après un refus pour limite de débit.
 *
 * Sans elle, chaque ouverture d'écran relançait la lecture et repoussait
 * d'autant le retour à la normale — le remède entretenait la panne.
 */
const RATE_LIMIT_COOLDOWN_MS = 5 * 60 * 1000;

/** Tentatives supplémentaires après un 429, en respectant `retry-after`. */
const MAX_RATE_LIMIT_RETRIES = 2;

/** Attente maximale consentie à un `retry-after` : au-delà, la fonction expire. */
const MAX_RETRY_WAIT_MS = 15_000;

/**
 * Une ligne de la facture Anthropic : un modèle, une nature de jeton.
 *
 * Un écart réduit à un seul montant ne se diagnostique pas. Ventilé, il
 * désigne : un modèle qu'on croyait ne pas utiliser, une nature de jeton qu'on
 * ne compte pas — du cache, une recherche web — ou simplement un tarif qui
 * n'est pas celui de la grille.
 */
export interface AnthropicCostLine {
  label: string;
  costUsd: number;
}

/** Coût facturé par Anthropic pour un mois donné. */
export interface AnthropicMonthlyCost {
  /** `AAAA-MM`. */
  period: string;
  billedUsd: number;
  /** Le détail de ce montant, du plus cher au moins cher. */
  lines: AnthropicCostLine[];
  /**
   * Instant du relevé, en millisecondes.
   *
   * Un montant facturé est une photographie ; nos compteurs, eux, sont vivants.
   * Comparer les deux sans dire l'âge du relevé fabrique un écart qui n'est
   * qu'un décalage d'horloge — et fait chercher une erreur là où il n'y en a
   * pas.
   */
  fetchedAtMs: number | null;
}

export interface AnthropicCostReport {
  /** Vrai dès qu'on dispose de montants — fraîchement lus ou mis en cache. */
  available: boolean;
  months: AnthropicMonthlyCost[];
  /** Renseigné quand la lecture a échoué — distingue « zéro » de « on ne sait pas ». */
  error?: string;
  /** Vrai quand les montants viennent du cache faute d'avoir pu interroger l'API. */
  stale?: boolean;
  /**
   * Vrai quand tous les mois demandés n'ont pas encore été lus.
   *
   * Ce n'est pas une panne : la lecture est volontairement bornée par
   * affichage pour ménager la limite de débit, et se complète à la suivante.
   */
  partial?: boolean;
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
function periodOfIso(iso: unknown): string | null {
  if (typeof iso !== "string") return null;
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  return periodOf(date);
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
  data?: Array<{
    starting_at?: string;
    /** Fin exclue de la journée — c'est elle qui borne ce qui est acquis. */
    ending_at?: string;
    results?: Array<{
      amount?: unknown;
      /** Renseignés uniquement quand on regroupe par `description`. */
      description?: string | null;
      model?: string | null;
      token_type?: string | null;
      cost_type?: string | null;
    }>;
  }>;
  has_more?: boolean;
  next_page?: string | null;
}

/**
 * Nature d'un jeton, telle qu'Anthropic la libelle.
 *
 * `uncached_input_tokens` porte bien son nom : c'est l'entrée **hors cache**.
 * Voir apparaître une ligne de cache non nulle prouverait à elle seule qu'une
 * partie de nos prompts y passe — ce que nos compteurs ne verraient pas si
 * l'appel ne lisait que `input_tokens`.
 */
const TOKEN_TYPE_LABELS: Record<string, string> = {
  uncached_input_tokens: "entrée",
  output_tokens: "sortie",
  "cache_creation.ephemeral_5m_input_tokens": "écriture de cache (5 min)",
  "cache_creation.ephemeral_1h_input_tokens": "écriture de cache (1 h)",
  cache_read_input_tokens: "lecture de cache",
};

/** Natures de coût qui ne sont pas des jetons — elles n'ont aucun modèle. */
const COST_TYPE_LABELS: Record<string, string> = {
  web_search: "recherche web",
  code_execution: "exécution de code",
  session_usage: "temps de session",
};

/**
 * Libellé d'une ligne de facture, lisible sans connaître l'API.
 *
 * Les lignes sont regroupées sur ce libellé : la fenêtre de contexte et le
 * palier de service sont volontairement fondus. Le projet n'appelle ni en lot
 * ni au-delà de 200k jetons, et deux lignes de plus par modèle rendraient le
 * détail moins lisible sans rien apprendre. Le jour où l'un des deux
 * changerait, c'est le montant global qui bougerait — et il est comparé.
 */
function costLineLabel(result: {
  description?: string | null;
  model?: string | null;
  token_type?: string | null;
  cost_type?: string | null;
}): string {
  const model = (result.model ?? "").trim();
  const tokenLabel = result.token_type ? TOKEN_TYPE_LABELS[result.token_type] : undefined;
  if (model) {
    return tokenLabel ? `${model} — ${tokenLabel}` : model;
  }
  const costLabel = result.cost_type ? COST_TYPE_LABELS[result.cost_type] : undefined;
  if (costLabel) return costLabel;
  const description = (result.description ?? "").trim();
  return description.length > 0 ? description : "Ligne non libellée";
}

/** Les lignes d'un mois, telles qu'elles sont relues du cache. */
function parseCachedLines(raw: unknown): AnthropicCostLine[] {
  if (!Array.isArray(raw)) return [];
  const lines: AnthropicCostLine[] = [];
  for (const entry of raw) {
    if (!entry || typeof entry !== "object") continue;
    const o = entry as Record<string, unknown>;
    const label = typeof o.label === "string" ? o.label : "";
    const cost = Number(o.cost_usd);
    if (label.length === 0 || !Number.isFinite(cost)) continue;
    lines.push({ label, costUsd: cost });
  }
  return lines;
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
    url.searchParams.set("limit", String(BUCKETS_PER_PAGE));
    // Le regroupement par description ventile chaque journée par modèle et par
    // nature de jeton, sans changer ni le nombre de journées ni le nombre de
    // pages : la pagination porte sur les journées, pas sur les lignes. Il ne
    // coûte donc rien au quota et transforme « il manque de l'argent » en
    // « il manque CE modèle, sur CETTE nature de jeton ».
    url.searchParams.append("group_by[]", "description");
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
  /**
   * Périodes à relire quoi qu'en dise le cache.
   *
   * Ciblé plutôt que global : un mois clos ne bouge qu'en cas de correction
   * rétroactive, et relire un seul mois coûte une requête là où relire l'année
   * en coûte treize. La demande vient de l'écran, mois par mois.
   */
  forcePeriods?: string[];
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
  const cached: Record<string, number> = {
    ...((cacheData.months ?? {}) as Record<string, number>),
  };
  const fetchedAt: Record<string, number> = {
    ...((cacheData.fetched_at ?? {}) as Record<string, number>),
  };
  const cachedLines: Record<string, AnthropicCostLine[]> = {};
  for (const [period, raw] of Object.entries((cacheData.lines ?? {}) as Record<string, unknown>)) {
    cachedLines[period] = parseCachedLines(raw);
  }
  const currentFetchedAtMs =
    typeof cacheData.current_month_fetched_at_ms === "number"
      ? cacheData.current_month_fetched_at_ms
      : 0;

  const now = new Date();
  const currentPeriod = periodOf(now);
  // Le mois courant est le seul qui bouge encore ; les mois clos sont
  // définitifs, les redemander ne changerait qu'une chose : le quota consommé.
  const currentIsStale = now.getTime() - currentFetchedAtMs > CURRENT_MONTH_TTL_MS;

  const forced = new Set(args.forcePeriods ?? []);
  const missing = wanted.filter((period) => {
    if (forced.has(period)) return true;
    if (period === currentPeriod) return currentIsStale || !(period in cached);
    return !(period in cached);
  });

  const asReport = (extra: Partial<AnthropicCostReport> = {}): AnthropicCostReport => ({
    available: wanted.some((period) => period in cached),
    months: wanted
      .filter((period) => period in cached)
      .map((period) => ({
        period,
        billedUsd: cached[period],
        lines: [...(cachedLines[period] ?? [])].sort((a, b) => b.costUsd - a.costUsd),
        fetchedAtMs: fetchedAt[period] ?? null,
      })),
    ...extra,
  });

  if (missing.length === 0) {
    return asReport();
  }

  // Une pause en cours : on sert ce qu'on sait sans toucher à l'API. Réessayer
  // pendant la pénalité ne fait que la prolonger.
  const cooldownUntil =
    typeof cacheData.rate_limited_until_ms === "number" ? cacheData.rate_limited_until_ms : 0;
  if (Date.now() < cooldownUntil && forced.size === 0) {
    const waitSeconds = Math.ceil((cooldownUntil - Date.now()) / 1000);
    return asReport({
      stale: true,
      partial: true,
      error:
        `HTTP 429 — limite de débit atteinte, nouvelle lecture dans ${waitSeconds} s. ` +
        "Les montants affichés viennent du dernier relevé réussi.",
    });
  }

  // Les mois les plus récents d'abord. Lire dans l'ordre chronologique
  // réservait le mois en cours — le seul que l'on regarde vraiment — à la
  // toute dernière tranche : le cache se remplissait par le bout inutile.
  const batch = missing.slice(-MAX_PERIODS_PER_CALL);
  const startIso = startOfPeriod(batch[0]).toISOString();
  // Jamais au-delà de maintenant : demander un futur ne rend rien et compte
  // quand même dans le quota.
  const end = endOfPeriod(batch[batch.length - 1]);
  const endIso = (end.getTime() > now.getTime() ? now : end).toISOString();

  const fetched = new Map<string, number>();
  /** Ventilation lue cette fois-ci : période → libellé → montant. */
  const fetchedLines = new Map<string, Map<string, number>>();
  let page: string | null = null;
  let requests = 0;
  /** Fin de la dernière journée réellement lue — la frontière de l'acquis. */
  let coveredThrough = 0;
  let finished = false;
  let failure: string | null = null;

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
        const period = periodOfIso(bucket.starting_at);
        if (!period) continue;
        const lines = fetchedLines.get(period) ?? new Map<string, number>();
        let total = 0;
        for (const entry of bucket.results ?? []) {
          const amount = centsToUsd(entry.amount);
          total += amount;
          const label = costLineLabel(entry);
          lines.set(label, (lines.get(label) ?? 0) + amount);
        }
        fetchedLines.set(period, lines);
        fetched.set(period, (fetched.get(period) ?? 0) + total);
        const bucketEnd = Date.parse(String(bucket.ending_at ?? ""));
        if (Number.isFinite(bucketEnd) && bucketEnd > coveredThrough) {
          coveredThrough = bucketEnd;
        }
      }

      page = payload.has_more === true ? (payload.next_page ?? null) : null;
      requests += 1;
      if (page == null) {
        finished = true;
        break;
      }
      // Une rafale illimitée est ce qui déclenche la limite de débit. On
      // s'arrête volontairement avant, quitte à ne rendre qu'une partie : ce
      // qui a été lu est conservé, et l'affichage suivant reprend la suite.
      if (requests >= MAX_PAGES_PER_CALL) break;
      await sleep(PAGE_INTERVAL_MS);
    } while (page != null);
  } catch (err) {
    failure = err instanceof Error ? err.message : String(err);
  }

  // Ce qui a été lu est conservé, même quand la lecture s'est arrêtée en
  // chemin. Sans cela, chaque affichage repartait de zéro : l'échec empêchait
  // d'écrire, l'absence d'écriture imposait de tout relire, et la relecture
  // rallumait la limite de débit. Une boucle qui ne pouvait que se refermer.
  for (const [period, amount] of fetched) {
    cached[period] = Number(amount.toFixed(6));
  }
  // La ventilation d'un mois est remplacée en bloc, jamais fusionnée : une
  // fusion laisserait survivre un libellé disparu de la facture, et ce vestige
  // gonflerait un détail dont la somme ne retomberait plus sur le total.
  const linesToWrite: Record<string, Array<{ label: string; cost_usd: number }>> = {};
  for (const [period, labels] of fetchedLines) {
    cachedLines[period] = [...labels.entries()]
      .map(([label, costUsd]) => ({ label, costUsd: Number(costUsd.toFixed(6)) }))
      .sort((a, b) => b.costUsd - a.costUsd);
    linesToWrite[period] = cachedLines[period].map((line) => ({
      label: line.label,
      cost_usd: line.costUsd,
    }));
  }
  // Un mois entièrement couvert par la lecture et absent du rapport a
  // réellement coûté zéro. Un mois seulement effleuré, non : l'inscrire à zéro
  // figerait un chiffre faux dans un cache qui ne se relit plus.
  const settled: string[] = [];
  for (const period of batch) {
    const isCovered = finished || endOfPeriod(period).getTime() <= coveredThrough;
    if (!isCovered) continue;
    settled.push(period);
    if (!(period in cached)) cached[period] = 0;
    fetchedAt[period] = now.getTime();
  }

  const rateLimited = failure != null && failure.includes("429");
  await cacheRef.set(
    {
      months: cached,
      lines: linesToWrite,
      fetched_at: fetchedAt,
      updated_at: FieldValue.serverTimestamp(),
      ...(settled.includes(currentPeriod) ? { current_month_fetched_at_ms: now.getTime() } : {}),
      // Une pause après un refus : sans elle, chaque ouverture d'écran
      // relançait la lecture et repoussait d'autant le retour à la normale.
      ...(rateLimited ? { rate_limited_until_ms: now.getTime() + RATE_LIMIT_COOLDOWN_MS } : {}),
    },
    { merge: true },
  );

  if (failure != null) {
    await logError({
      message: "fetchAnthropicMonthlyCosts: lecture interrompue",
      correlationId: args.correlationId,
      provider: "anthropic",
      errorDescription: failure,
      extra: { requests, settled: settled.length, remaining: missing.length - settled.length },
    });
    return asReport({ error: failure, stale: true, partial: true });
  }

  await logInfo({
    message: `fetchAnthropicMonthlyCosts: ${settled.length} mois relus en ${requests} requêtes`,
    correlationId: args.correlationId,
    provider: "anthropic",
    extra: { requests, settled: settled.length, cached: Object.keys(cached).length, finished },
  });

  // Une lecture bornée volontairement n'est pas une panne : elle se complète
  // au prochain affichage, et l'écran doit pouvoir le dire ainsi.
  return asReport({ partial: settled.length < missing.length });
}
