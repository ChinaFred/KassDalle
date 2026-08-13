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
  correlationId?: string;
  moduleType?: ModuleType;
  firestoreDocId?: string;
  executionTimeMs?: number;
  geminiStatus?: GeminiStatus;
  jobId?: string;
  userId?: string;
  stepIndex?: number;
  /**
   * Fournisseur d'inférence de l'appel — `gemini` ou `anthropic`.
   *
   * Champ de premier plan et label indexable, pas une clé perdue dans `extra` :
   * depuis qu'il y a deux moteurs, « lequel a servi cet appel » est la première
   * question qu'on pose à un log, et elle doit être filtrable.
   */
  provider?: string;
  /** Identifiant exact du modèle appelé (`gemini-2.5-flash`, `claude-sonnet-5`…). */
  model?: string;
  /** Poste fonctionnel — la même clé que celle du reporting de coûts. */
  feature?: string;
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
  const labels: Record<string, string> = {};
  if (entry.correlationId) labels.correlationId = entry.correlationId;
  if (entry.moduleType) labels.moduleType = entry.moduleType;
  if (entry.geminiStatus) labels.geminiStatus = entry.geminiStatus;
  if (entry.jobId) labels.jobId = entry.jobId;
  if (entry.userId) labels.userId = entry.userId;
  if (entry.provider) labels.provider = entry.provider;
  if (entry.model) labels.model = entry.model;
  if (entry.feature) labels.feature = entry.feature;

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
    console.error("[writeLog] Failed to write to Cloud Logging", err, data);
  }
}

/** Raccourci pour un log INFO. Accepte soit un objet entry, soit (message, ctx). */
export function logInfo(
  entryOrMessage: (Omit<StructuredLogEntry, "severity"> & { message: string }) | string,
  ctx?: Omit<StructuredLogEntry, "severity" | "message">,
): Promise<void> {
  if (typeof entryOrMessage === "string") {
    return writeLog({ severity: "INFO", message: entryOrMessage, ...(ctx ?? {}) });
  }
  return writeLog({ severity: "INFO", ...entryOrMessage });
}

/**
 * Raccourci pour un log WARNING — le traitement aboutit, mais pas comme prévu.
 *
 * Entre l'INFO qu'on ne lit pas et l'ERROR qui n'a pas eu lieu, il manquait ce
 * niveau : une bascule de moteur restée sans effet, par exemple, ne casse rien
 * et ne doit pourtant pas passer inaperçue. L'écran de logs le filtre déjà
 * (chip « WARN+ »).
 */
export function logWarn(
  entryOrMessage: (Omit<StructuredLogEntry, "severity"> & { message: string }) | string,
  ctx?: Omit<StructuredLogEntry, "severity" | "message">,
): Promise<void> {
  if (typeof entryOrMessage === "string") {
    return writeLog({ severity: "WARNING", message: entryOrMessage, ...(ctx ?? {}) });
  }
  return writeLog({ severity: "WARNING", ...entryOrMessage });
}

/**
 * Raccourci pour un log DEBUG — instrumentation, pas événement métier.
 *
 * Réservé à ce qui n'intéresse que celui qui débogue : prompt envoyé, réponse
 * brute, ouverture d'un appel. Un import écrivait une cinquantaine de lignes
 * dont une quinzaine seulement portait une information ; le reste noyait
 * précisément ce qu'on venait lire. L'écran filtre ce niveau par défaut.
 */
export function logDebug(
  entryOrMessage: (Omit<StructuredLogEntry, "severity"> & { message: string }) | string,
  ctx?: Omit<StructuredLogEntry, "severity" | "message">,
): Promise<void> {
  if (typeof entryOrMessage === "string") {
    return writeLog({ severity: "DEBUG", message: entryOrMessage, ...(ctx ?? {}) });
  }
  return writeLog({ severity: "DEBUG", ...entryOrMessage });
}

/** Raccourci pour un log ERROR. Accepte soit un objet entry, soit (message, ctx). */
export function logError(
  entryOrMessage: (Omit<StructuredLogEntry, "severity"> & { message: string }) | string,
  ctx?: Omit<StructuredLogEntry, "severity" | "message">,
): Promise<void> {
  if (typeof entryOrMessage === "string") {
    return writeLog({ severity: "ERROR", message: entryOrMessage, ...(ctx ?? {}) });
  }
  return writeLog({ severity: "ERROR", ...entryOrMessage });
}

/** Génère un correlationId unique pour un job ou un appel. */
export function newCorrelationId(prefix = "corr"): string {
  return `${prefix}_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
}
