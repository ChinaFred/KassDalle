/**
 * Résolution du moteur de modération et de ses seuils.
 *
 * La **politique** est partagée avec le reste de l'IA — un document Firestore,
 * un écran d'administration. L'**exécution** ne l'est pas : `callModel` raisonne
 * en jetons et en messages, Vision rend des paliers. Ce module lit la même
 * politique et choisit son adaptateur.
 */

import { getFirestore } from "firebase-admin/firestore";

import { logError } from "../logging";
import {
  DEFAULT_MODERATION_THRESHOLDS,
  type ModerationSignals,
  type ModerationThresholds,
} from "./decision";
import { VISION_MODEL_ID, VISION_UNITS_PER_IMAGE, analyseWithVision } from "./vision";

export const MODERATION_CONFIG_DOC_ID = "image_moderation";

/** Poste de coût — à tenir en phase avec `feature_catalog.dart`. */
export const MODERATION_FEATURE = "image_moderation";
export const MODERATION_FEATURE_BATCH = "image_moderation_batch";

/**
 * Moteurs acceptables pour ce poste.
 *
 * Un seul aujourd'hui. La liste existe quand même : c'est elle que lit l'écran
 * *Moteur d'IA* pour afficher un sélecteur inactif plutôt que de masquer le
 * poste. Un poste absent de cet écran est un poste qu'il faudra redéployer pour
 * faire bouger.
 */
export const MODERATION_PROVIDERS = ["vision"] as const;
export type ModerationProvider = (typeof MODERATION_PROVIDERS)[number];

export interface ModerationConfig {
  /** Interrupteur global — à faux, aucune image n'est analysée. */
  enabled: boolean;
  provider: ModerationProvider;
  thresholds: ModerationThresholds;
}

export const DEFAULT_MODERATION_CONFIG: ModerationConfig = {
  enabled: true,
  provider: "vision",
  thresholds: DEFAULT_MODERATION_THRESHOLDS,
};

let cached: { value: ModerationConfig; readAt: number } | null = null;
/** Un seuil corrigé prend effet en une minute, comme la grille tarifaire. */
const CONFIG_TTL_MS = 60_000;

function readNumber(raw: unknown, fallback: number): number {
  const n = Number(raw);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}

function readLabels(raw: unknown, fallback: string[]): string[] {
  if (!Array.isArray(raw)) return fallback;
  const cleaned = raw
    .map((v) => (typeof v === "string" ? v.trim().toLowerCase() : ""))
    .filter((v) => v.length > 0);
  return cleaned.length > 0 ? cleaned : fallback;
}

export function parseModerationConfig(raw: unknown): ModerationConfig {
  if (raw === null || typeof raw !== "object") return DEFAULT_MODERATION_CONFIG;
  const map = raw as Record<string, unknown>;
  const d = DEFAULT_MODERATION_THRESHOLDS;
  return {
    enabled: map.enabled !== false,
    // Un fournisseur inconnu n'est pas une raison de ne pas modérer : on
    // applique le seul moteur admis et la lecture reste explicable.
    provider: MODERATION_PROVIDERS.includes(map.provider as ModerationProvider)
      ? (map.provider as ModerationProvider)
      : DEFAULT_MODERATION_CONFIG.provider,
    thresholds: {
      sexualReject: readNumber(map.sexual_reject, d.sexualReject),
      violenceReject: readNumber(map.violence_reject, d.violenceReject),
      violenceAlert: readNumber(map.violence_alert, d.violenceAlert),
      racyReview: readNumber(map.racy_review, d.racyReview),
      culinaryLabelScore: readNumber(map.culinary_label_score, d.culinaryLabelScore),
      culinaryLabelCount: readNumber(map.culinary_label_count, d.culinaryLabelCount),
      culinaryStrongScore: readNumber(map.culinary_strong_score, d.culinaryStrongScore),
      culinaryLabels: readLabels(map.culinary_labels, d.culinaryLabels),
    },
  };
}

/**
 * Configuration en vigueur.
 *
 * Une lecture impossible n'arrête pas la modération : elle applique les défauts
 * et le dit dans les traces. Le contraire — refuser de modérer parce qu'un
 * document manque — laisserait passer des images sur un incident d'infra.
 */
export async function getModerationConfig(): Promise<ModerationConfig> {
  const now = Date.now();
  if (cached !== null && now - cached.readAt < CONFIG_TTL_MS) return cached.value;
  try {
    const snap = await getFirestore().collection("app_config").doc(MODERATION_CONFIG_DOC_ID).get();
    const value = snap.exists ? parseModerationConfig(snap.data()) : DEFAULT_MODERATION_CONFIG;
    cached = { value, readAt: now };
    return value;
  } catch (err) {
    await logError({
      message: "getModerationConfig: lecture impossible, seuils par défaut appliqués",
      moduleType: "MODERATION",
      errorDescription: err instanceof Error ? err.message : String(err),
    });
    return DEFAULT_MODERATION_CONFIG;
  }
}

/** Vide le cache — réservé aux tests et à l'écriture d'un seuil. */
export function invalidateModerationConfigCache(): void {
  cached = null;
}

export interface EngineAnalysis {
  signals: ModerationSignals;
  provider: ModerationProvider;
  model: string;
  /** Unités facturées par le fournisseur pour cette analyse. */
  units: number;
}

/** Lance l'analyse auprès du moteur retenu. Lève si le moteur échoue. */
export async function analyseImage(
  bytes: Buffer,
  config: ModerationConfig,
): Promise<EngineAnalysis> {
  switch (config.provider) {
    case "vision": {
      const signals = await analyseWithVision(bytes);
      return {
        signals,
        provider: "vision",
        model: VISION_MODEL_ID,
        units: VISION_UNITS_PER_IMAGE,
      };
    }
  }
}
