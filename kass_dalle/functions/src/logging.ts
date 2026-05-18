/**
 * Logger structuré pour Cloud Logging.
 *
 * Chaque log est écrit dans Cloud Logging avec un payload JSON conforme
 * au schéma défini dans TechnicalRequirements.md :
 *   severity, message, errorDescription, correlationId, moduleType,
 *   firestoreDocId, executionTimeMs, geminiStatus, jobId, userId, stepIndex
 *
 * Avantages d'utiliser le client `@google-cloud/logging` plutôt que `console.log` :
 *  - Sévérité explicite (vs auto-parsing fragile).
 *  - Labels indexables pour requêtage rapide (correlationId, moduleType…).
 *  - Possibilité de requêter depuis l'app via une Cloud Function admin.
 */

import { Logging } from "@google-cloud/logging";
import { LOG_NAME } from "./config";

export type ModuleType = "IMPORT" | "IMAGE_DECODE" | "SEARCH" | "DESIGN";
export type GeminiStatus = "SUCCESS" | "QUOTA_EXCEEDED" | "ERROR";
export type LogSeverity = "INFO" | "ERROR" | "WARNING" | "DEBUG";

export interface StructuredLogEntry {
  severity: LogSeverity;
  message: string;
  errorDescription?: string;
  correlationId: string;
  moduleType?: ModuleType;
  firestoreDocId?: string;
  executionTimeMs?: number;
  geminiStatus?: GeminiStatus;
  jobId?: string;
  userId?: string;
  stepIndex?: number;
  /** Champs additionnels libres (ex: tokens consommés, taille fichier…). */
  extra?: Record<string, unknown>;
}

const logging = new Logging();
const log = logging.log(LOG_NAME);

/**
 * Émet une entrée de log structurée vers Cloud Logging.
 *
 * Les labels permettent un filtrage rapide dans la console GCP et via l'API.
 * Les champs non-label sont conservés dans `jsonPayload`.
 */
export async function writeLog(entry: StructuredLogEntry): Promise<void> {
  const { severity, message, ...rest } = entry;

  // Labels = indexés et requêtables. On ne met que les champs courts et discrets.
  const labels: Record<string, string> = {
    correlationId: entry.correlationId,
  };
  if (entry.moduleType) labels.moduleType = entry.moduleType;
  if (entry.geminiStatus) labels.geminiStatus = entry.geminiStatus;
  if (entry.jobId) labels.jobId = entry.jobId;
  if (entry.userId) labels.userId = entry.userId;

  const metadata = {
    resource: { type: "cloud_function" } as const,
    severity,
    labels,
  };

  const data = {
    message,
    ...rest,
    timestamp: new Date().toISOString(),
  };

  try {
    await log.write(log.entry(metadata, data));
  } catch (err) {
    // Fallback console si Cloud Logging indisponible.
    // eslint-disable-next-line no-console
    console.error("[writeLog] Failed to write to Cloud Logging", err, data);
  }
}

/** Raccourci pour un log INFO. */
export function logInfo(
  message: string,
  ctx: Omit<StructuredLogEntry, "severity" | "message">,
): Promise<void> {
  return writeLog({ severity: "INFO", message, ...ctx });
}

/** Raccourci pour un log ERROR. */
export function logError(
  message: string,
  ctx: Omit<StructuredLogEntry, "severity" | "message">,
): Promise<void> {
  return writeLog({ severity: "ERROR", message, ...ctx });
}

/** Génère un correlationId unique pour un job ou un appel. */
export function newCorrelationId(prefix = "corr"): string {
  return `${prefix}_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
}
