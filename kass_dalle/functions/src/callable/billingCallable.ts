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

import { REGION } from "../config";
import { requireAdmin } from "./_auth";
import { logError } from "../logging";

const DATASET = "billing_export";
const TABLE_WILDCARD = "gcp_billing_export_v1_*";

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

export const getGcpCostsFn = onCall<GetGcpCostsRequest>(
  {
    region: REGION,
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async (req) => {
    await requireAdmin(req);

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
      const msg = err instanceof Error ? err.message : String(err);
      // Table pas encore créée par l'export (peut prendre 24h).
      if (
        msg.includes("Not found") ||
        msg.includes("does not match any table") ||
        msg.includes("matched no table")
      ) {
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
      await logError({
        message: "getGcpCostsFn failed",
        errorDescription: msg,
        extra: { startMs, endMs },
      });
      throw new HttpsError(
        "internal",
        `Échec de la requête BigQuery : ${msg}`,
      );
    }
  },
);
