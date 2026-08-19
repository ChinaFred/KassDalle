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

export type ModuleType = "IMPORT" | "IMAGE_DECODE" | "SEARCH" | "DESIGN" | "MODERATION";
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

/**
 * Longueur conservée d'un texte de modèle dans les journaux.
 *
 * Une page de livre extraite pèse deux à quatre mille caractères ; douze mille
 * couvrent donc une page entière et ses variantes, sans approcher la limite
 * d'une entrée Cloud Logging. Ce qui dépasse est coupé et le dit.
 */
export const AI_TEXT_LOG_LIMIT = 12_000;

/**
 * Journalise le TEXTE rendu par un modèle, ou celui qu'on s'apprête à écrire.
 *
 * Les journaux disaient jusqu'ici qu'un appel avait eu lieu, avec son poste,
 * son moteur et ses jetons — mais jamais ce qu'il avait répondu. Quand une
 * recette extraite s'écarte du livre, ces logs-là ne servent à rien : ils
 * prouvent que l'appel a réussi, pas ce qu'il a produit. Impossible de dire
 * quelle étape a interprété.
 *
 * Chaque texte est donc tracé à sa sortie, avec le `correlationId` de l'import :
 * les entrées d'un même scan se lisent alors dans l'ordre, et l'on voit le
 * texte évoluer d'un traitement au suivant — ou ne pas évoluer, ce qui est
 * l'information qu'on cherche.
 *
 * `stage` nomme le moment (`classification`, `extraction`, `polish.avant`,
 * `polish.après`…) : c'est lui qui rend la lecture chronologique lisible.
 */
export function logAiText(args: {
  stage: string;
  text: string;
  message?: string;
  correlationId?: string;
  jobId?: string;
  userId?: string;
  feature?: string;
  provider?: string;
  model?: string;
  moduleType?: ModuleType;
  extra?: Record<string, unknown>;
}): Promise<void> {
  const { stage, text, message, extra, ...ctx } = args;
  const full = text ?? "";
  const truncated = full.length > AI_TEXT_LOG_LIMIT;
  return writeLog({
    severity: "INFO",
    message: message ?? `Texte IA — ${stage} (${full.length} caractères)`,
    ...ctx,
    extra: {
      ...(extra ?? {}),
      stage,
      textLength: full.length,
      truncated,
      text: truncated ? `${full.slice(0, AI_TEXT_LOG_LIMIT)}\n[…coupé]` : full,
    },
  });
}
