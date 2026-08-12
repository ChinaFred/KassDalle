/**
 * Taux de change USD → devise du compte de facturation.
 *
 * La grille tarifaire Gemini est libellée en dollars ; la facture Google, elle,
 * est en euros. Convertir l'une vers l'autre demandait jusqu'ici un taux codé en
 * dur (`0.92`), qui vieillit sans prévenir : rien ne casse, aucun écran ne
 * proteste, seuls les montants en euros dérivent lentement d'avec la réalité.
 *
 * Le taux réel est pourtant déjà là. Chaque ligne de l'export de facturation
 * porte `currency_conversion_rate`, le taux que Google a lui-même appliqué. On
 * le relève donc au même moment que les coûts — pendant la réconciliation
 * mensuelle — et on le range dans `app_config/currency_rate`.
 *
 * Ce module ne contient que la partie qui se teste sans BigQuery : la validation
 * du taux relevé et la forme du document écrit.
 */

/** Identifiant du document de taux dans `app_config`. Miroir Dart : `CurrencyRateRepository`. */
export const CURRENCY_RATE_DOC = "currency_rate";

/**
 * Bornes de vraisemblance d'un taux USD → devise du compte.
 *
 * Un taux aberrant — requête vide, colonne absente, devise exotique mal lue —
 * écraserait celui qui sert à tous les affichages en euros. Le refuser laisse
 * en place le dernier taux valide, ce qui est toujours préférable à un chiffre
 * inventé. Assez large pour couvrir n'importe quelle devise raisonnable, assez
 * étroit pour rejeter un zéro, un infini ou un facteur mille.
 */
export const MIN_PLAUSIBLE_RATE = 0.1;
export const MAX_PLAUSIBLE_RATE = 10;

export interface CurrencyRateReading {
  /** Taux USD → [currency], tel que Google l'a appliqué sur la période. */
  rate: number;
  /** Devise du compte de facturation (`EUR`). */
  currency: string;
}

export type CurrencyRateRejection =
  | { ok: true; reading: CurrencyRateReading }
  | { ok: false; reason: string };

/**
 * Valide un taux relevé dans l'export avant de l'enregistrer.
 *
 * Rend un motif en clair plutôt qu'un booléen : c'est ce motif qui part dans
 * `logError`, et sans lui un taux refusé serait indiscernable d'un taux jamais
 * relevé.
 */
export function validateCurrencyRate(args: {
  rate: unknown;
  currency: unknown;
}): CurrencyRateRejection {
  const rate = typeof args.rate === "number"
    ? args.rate
    : (typeof args.rate === "string" ? Number(args.rate) : Number.NaN);

  if (!Number.isFinite(rate)) {
    return { ok: false, reason: "aucun taux exploitable sur la période" };
  }
  if (rate < MIN_PLAUSIBLE_RATE || rate > MAX_PLAUSIBLE_RATE) {
    return {
      ok: false,
      reason: `taux hors bornes de vraisemblance (${rate}, attendu entre ` +
        `${MIN_PLAUSIBLE_RATE} et ${MAX_PLAUSIBLE_RATE})`,
    };
  }

  const currency = typeof args.currency === "string" ? args.currency.trim() : "";
  if (currency.length === 0) {
    return { ok: false, reason: "devise du compte de facturation absente" };
  }

  return { ok: true, reading: { rate, currency } };
}
