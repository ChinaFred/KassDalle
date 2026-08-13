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
 */

import { logError, logInfo } from "../logging";

const COST_REPORT_URL = "https://api.anthropic.com/v1/organizations/cost_report";

/** Coût facturé par Anthropic pour un mois donné. */
export interface AnthropicMonthlyCost {
  /** `AAAA-MM`. */
  period: string;
  billedUsd: number;
}

export interface AnthropicCostReport {
  /** Vrai quand la clé d'administration est posée et le rapport lisible. */
  available: boolean;
  months: AnthropicMonthlyCost[];
  /** Renseigné quand la lecture a échoué — distingue « zéro » de « on ne sait pas ». */
  error?: string;
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
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  return `${date.getUTCFullYear()}-${month}`;
}

/**
 * Somme, mois par mois, ce qu'Anthropic a facturé entre deux dates.
 *
 * Le rapport est journalier et paginé ; on agrège au mois, la seule granularité
 * que le reste du reporting connaisse.
 */
export async function fetchAnthropicMonthlyCosts(args: {
  startIso: string;
  endIso: string;
  correlationId: string;
}): Promise<AnthropicCostReport> {
  const key = anthropicAdminKey();
  if (!key) {
    return { available: false, months: [] };
  }

  const byPeriod = new Map<string, number>();
  let page: string | null = null;
  let requests = 0;

  try {
    do {
      const url = new URL(COST_REPORT_URL);
      url.searchParams.set("starting_at", args.startIso);
      url.searchParams.set("ending_at", args.endIso);
      if (page) url.searchParams.set("page", page);

      const response = await fetch(url, {
        headers: {
          "x-api-key": key,
          "anthropic-version": "2023-06-01",
          "user-agent": "KassDalle/1.0 (https://kassdale-6d948.web.app)",
        },
      });

      if (!response.ok) {
        const body = await response.text();
        throw new Error(`HTTP ${response.status} — ${body.slice(0, 300)}`);
      }

      const payload = (await response.json()) as {
        data?: Array<{ starting_at?: string; results?: Array<{ amount?: unknown }> }>;
        has_more?: boolean;
        next_page?: string | null;
      };

      for (const bucket of payload.data ?? []) {
        const period = periodOf(bucket.starting_at);
        if (!period) continue;
        const total = (bucket.results ?? []).reduce(
          (sum, entry) => sum + centsToUsd(entry.amount),
          0,
        );
        byPeriod.set(period, (byPeriod.get(period) ?? 0) + total);
      }

      page = payload.has_more === true ? (payload.next_page ?? null) : null;
      requests += 1;
      // Garde-fou : une pagination qui ne se termine pas boucle sur le quota
      // plutôt que de rendre la main.
    } while (page != null && requests < 40);

    const months = [...byPeriod.entries()]
      .map(([period, billedUsd]) => ({ period, billedUsd: Number(billedUsd.toFixed(6)) }))
      .sort((a, b) => a.period.localeCompare(b.period));

    await logInfo({
      message: `fetchAnthropicMonthlyCosts: ${months.length} mois lus`,
      correlationId: args.correlationId,
      provider: "anthropic",
      extra: { requests, months: months.length },
    });

    return { available: true, months };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await logError({
      message: "fetchAnthropicMonthlyCosts: rapport de coûts Anthropic illisible",
      correlationId: args.correlationId,
      provider: "anthropic",
      errorDescription: message,
    });
    // « Illisible » n'est pas « zéro » : l'écran doit pouvoir le dire.
    return { available: false, months: [], error: message };
  }
}
