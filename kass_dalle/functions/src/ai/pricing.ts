/**
 * Grille tarifaire des modèles d'IA du projet, tous fournisseurs confondus.
 *
 * Anciennement `gemini/pricing.ts`. Le fichier a changé de nom le jour où un
 * second fournisseur est entré : une table nommée « Gemini » qui contient les
 * tarifs Claude est le genre de mensonge de nommage qui finit par tromper
 * quelqu'un — et ici, ce quelqu'un lit un chiffre de coûts qu'il croit exact.
 *
 * ## Deux étages
 *
 * La table de ce fichier est le **repli en dur**. La grille qui fait foi vit
 * dans Firestore (`app_config/ai_pricing`), modifiable depuis Admin → Moteur
 * d'IA : un tarif change chez un fournisseur bien plus souvent qu'on ne
 * déploie, et attendre une livraison pour corriger un prix, c'est accepter de
 * chiffrer faux entre-temps.
 *
 * Le repli n'est pas décoratif. Table injoignable ou modèle absent, le calcul
 * doit continuer avec un tarif plausible **et le dire** : un coût tombé à zéro
 * dans le silence est exactement le mensonge que toute ce fichier cherche à
 * empêcher.
 *
 * Ce fichier garde son jumeau Dart (`lib/features/admin/data/ai_pricing.dart`)
 * et sa fixture (`test-fixtures/ai_pricing.json`) : ils asservissent les
 * **valeurs de repli** et l'arithmétique, que les deux côtés portent encore.
 * La surcouche Firestore, elle, n'est plus dupliquée nulle part — les deux
 * lisent le même document.
 */

import { getFirestore } from "firebase-admin/firestore";

import { COLL_APP_CONFIG } from "../config";
import { logError } from "../logging";

/**
 * Tarif promotionnel d'un modèle, borné dans le temps.
 *
 * `until` est une borne **exclue** : au premier instant de cette date, le tarif
 * catalogue reprend. Sans date, une promotion se transforme en tarif permanent
 * le jour où elle expire, et le reporting se met à sous-estimer sans que rien
 * ne le signale.
 */
export interface AiIntroductoryPricing {
  inputPerMillion: number;
  outputPerMillion: number;
  untilIso: string;
}

export interface AiModelPricing {
  inputPerMillion: number;
  outputPerMillion: number;
  imageOutputPerUnit?: number;
  introductory?: AiIntroductoryPricing;
}

const DEFAULT_PRICING: AiModelPricing = {
  inputPerMillion: 0.3,
  outputPerMillion: 2.5,
  imageOutputPerUnit: 0,
};

const PRICING_TABLE: Record<string, AiModelPricing> = {
  // ── Google Gemini ────────────────────────────────────────────────────────
  "gemini-2.5-flash": { inputPerMillion: 0.3, outputPerMillion: 2.5, imageOutputPerUnit: 0 },
  // Ancien modèle image du projet, conservé pour les mois déjà consommés : leurs
  // lignes portent cet identifiant, et sans l'entrée elles se reliraient au
  // tarif par défaut, images comprises — c'est-à-dire à zéro.
  "gemini-2.5-flash-image": {
    inputPerMillion: 0.3,
    outputPerMillion: 2.5,
    imageOutputPerUnit: 0.04,
  },
  "gemini-2.5-pro": { inputPerMillion: 1.25, outputPerMillion: 10.0, imageOutputPerUnit: 0 },
  "gemini-2.0-flash": { inputPerMillion: 0.1, outputPerMillion: 0.4, imageOutputPerUnit: 0 },
  "gemini-1.5-flash": { inputPerMillion: 0.075, outputPerMillion: 0.3, imageOutputPerUnit: 0 },
  "gemini-1.5-pro": { inputPerMillion: 1.25, outputPerMillion: 5.0, imageOutputPerUnit: 0 },
  // Nano Banana 2 Lite — modèle image courant (`GEMINI_IMAGE_MODEL`).
  // 0,0336 $ l'image 1K : 1120 jetons de sortie facturés 30 $ le million.
  "gemini-3.1-flash-lite-image": {
    inputPerMillion: 0.25,
    outputPerMillion: 1.5,
    imageOutputPerUnit: 0.0336,
  },

  // ── Anthropic Claude ─────────────────────────────────────────────────────
  // Tarifs catalogue au 12 août 2026.
  //
  // Le tarif d'introduction de Sonnet 5 était volontairement ignoré, au motif
  // qu'une surestimation valait mieux qu'une sous-estimation. La confrontation
  // à la facture d'août a montré l'erreur : 1,20 € estimés contre 0,80 €
  // facturés, soit 50 % d'écart — assez pour rendre le rapprochement
  // inexploitable, et pour masquer un vrai défaut de comptage le jour où il
  // s'en produirait un. Une marge de sécurité posée sur un instrument de
  // mesure ne le sécurise pas : elle le casse.
  "claude-opus-5": { inputPerMillion: 5.0, outputPerMillion: 25.0, imageOutputPerUnit: 0 },
  "claude-opus-4-8": { inputPerMillion: 5.0, outputPerMillion: 25.0, imageOutputPerUnit: 0 },
  "claude-sonnet-5": {
    inputPerMillion: 3.0,
    outputPerMillion: 15.0,
    imageOutputPerUnit: 0,
    introductory: {
      inputPerMillion: 2.0,
      outputPerMillion: 10.0,
      untilIso: "2026-09-01T00:00:00Z",
    },
  },
  "claude-sonnet-4-6": { inputPerMillion: 3.0, outputPerMillion: 15.0, imageOutputPerUnit: 0 },
  "claude-haiku-4-5": { inputPerMillion: 1.0, outputPerMillion: 5.0, imageOutputPerUnit: 0 },
};

/** Identifiant du document Firestore portant la grille en vigueur. */
export const AI_PRICING_DOC_ID = "ai_pricing";

/** Grille de repli, telle qu'elle est écrite dans ce fichier. */
export function builtinPricingTable(): Record<string, AiModelPricing> {
  return { ...PRICING_TABLE };
}

/**
 * Lit une entrée de tarif depuis sa forme Firestore (snake_case).
 *
 * Une entrée dont les deux tarifs de jetons sont illisibles est rejetée : mieux
 * vaut le repli en dur qu'un modèle facturé zéro parce qu'une saisie a mis du
 * texte là où on attendait un nombre.
 */
export function parsePricingEntry(raw: unknown): AiModelPricing | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const num = (v: unknown): number | null =>
    typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : null;

  const input = num(o.input_per_million);
  const output = num(o.output_per_million);
  if (input == null || output == null) return null;

  const entry: AiModelPricing = {
    inputPerMillion: input,
    outputPerMillion: output,
    imageOutputPerUnit: num(o.image_output_per_unit) ?? 0,
  };

  const promoRaw = o.introductory;
  if (promoRaw && typeof promoRaw === "object") {
    const p = promoRaw as Record<string, unknown>;
    const pIn = num(p.input_per_million);
    const pOut = num(p.output_per_million);
    const until = typeof p.until_iso === "string" ? p.until_iso : "";
    // Une promotion sans date de fin lisible devient un tarif permanent le jour
    // où elle expire : on la refuse plutôt que de sous-estimer indéfiniment.
    if (pIn != null && pOut != null && Number.isFinite(Date.parse(until))) {
      entry.introductory = { inputPerMillion: pIn, outputPerMillion: pOut, untilIso: until };
    }
  }
  return entry;
}

/** Rend une entrée sous sa forme Firestore. */
export function pricingEntryToMap(entry: AiModelPricing): Record<string, unknown> {
  return {
    input_per_million: entry.inputPerMillion,
    output_per_million: entry.outputPerMillion,
    image_output_per_unit: entry.imageOutputPerUnit ?? 0,
    introductory: entry.introductory
      ? {
          input_per_million: entry.introductory.inputPerMillion,
          output_per_million: entry.introductory.outputPerMillion,
          until_iso: entry.introductory.untilIso,
        }
      : null,
  };
}

/**
 * Tarif d'un identifiant de modèle dans une table donnée, correspondance exacte
 * d'abord, puis repli sur le préfixe LE PLUS LONG.
 *
 * Le repli rendait autrefois le premier préfixe rencontré. Comme
 * « gemini-2.5-flash » précède « gemini-2.5-flash-image » dans la table, une
 * révision datée d'un modèle d'image (« …-image-preview ») était résolue vers
 * le tarif texte : ses images étaient facturées zéro, et le reporting de coûts
 * restait crédible tout en étant faux. Le jumeau Dart portait le même défaut.
 */
export function pricingForModelIn(
  table: Record<string, AiModelPricing>,
  model: string,
): AiModelPricing {
  if (table[model]) return table[model];

  let best: AiModelPricing | null = null;
  let bestLength = -1;
  for (const [prefix, pricing] of Object.entries(table)) {
    if (model.startsWith(prefix) && prefix.length > bestLength) {
      best = pricing;
      bestLength = prefix.length;
    }
  }
  return best ?? DEFAULT_PRICING;
}

/** Tarif d'un modèle dans la grille de repli en dur. */
export function getPricingForModel(model: string): AiModelPricing {
  return pricingForModelIn(PRICING_TABLE, model);
}

/**
 * Tarif réellement en vigueur à une date donnée.
 *
 * `getPricingForModel` rend l'entrée de catalogue, promotion comprise ; c'est
 * ici qu'on décide laquelle des deux s'applique.
 */
export function effectivePricing(model: string, at: Date): AiModelPricing {
  return effectivePricingIn(PRICING_TABLE, model, at);
}

/** Idem, dans une grille donnée. */
export function effectivePricingIn(
  table: Record<string, AiModelPricing>,
  model: string,
  at: Date,
): AiModelPricing {
  const pricing = pricingForModelIn(table, model);
  const promo = pricing.introductory;
  if (!promo) return pricing;

  const until = Date.parse(promo.untilIso);
  // Une date de fin illisible ne doit pas offrir une promotion perpétuelle :
  // dans le doute, on facture au tarif catalogue.
  if (!Number.isFinite(until) || at.getTime() >= until) return pricing;

  return {
    inputPerMillion: promo.inputPerMillion,
    outputPerMillion: promo.outputPerMillion,
    imageOutputPerUnit: pricing.imageOutputPerUnit,
  };
}

export function estimateAiCostUsd(args: {
  model: string;
  inputTokens: number;
  outputTokens: number;
  imageOutputCount?: number;
  /**
   * Instant de l'appel. Un appel se facture au tarif en vigueur **quand il a
   * eu lieu**, jamais au tarif du jour où on relit le rapport : sans cela, une
   * reconstruction d'agrégats après la fin d'une promotion réécrirait le passé.
   */
  at?: Date;
  /**
   * Grille à appliquer. Par défaut la table de repli en dur — les appelants qui
   * peuvent attendre une lecture Firestore passent la grille en vigueur, via
   * `loadAiPricingTable()`.
   */
  table?: Record<string, AiModelPricing>;
}): number {
  const table = args.table ?? PRICING_TABLE;
  const pricing = effectivePricingIn(table, args.model, args.at ?? new Date());
  const images = args.imageOutputCount ?? 0;
  return (
    (args.inputTokens / 1e6) * pricing.inputPerMillion +
    (args.outputTokens / 1e6) * pricing.outputPerMillion +
    images * (pricing.imageOutputPerUnit ?? 0)
  );
}

// ── Grille en vigueur (Firestore, par-dessus le repli) ───────────────────────

let cachedTable: { value: Record<string, AiModelPricing>; readAt: number } | null = null;
/** Durée de vie du cache mémoire — un tarif corrigé prend effet en une minute. */
const PRICING_TTL_MS = 60_000;

/** Vide le cache — réservé aux tests et à l'écriture d'un tarif. */
export function invalidateAiPricingCache(): void {
  cachedTable = null;
}

/**
 * Grille en vigueur : le repli en dur, recouvert par `app_config/ai_pricing`.
 *
 * Une lecture impossible ne doit jamais interrompre un traitement ni faire
 * tomber un coût à zéro : on continue avec le repli, et l'incident est écrit.
 */
export async function loadAiPricingTable(): Promise<Record<string, AiModelPricing>> {
  if (cachedTable && Date.now() - cachedTable.readAt < PRICING_TTL_MS) {
    return cachedTable.value;
  }

  const merged = builtinPricingTable();
  try {
    const snap = await getFirestore().collection(COLL_APP_CONFIG).doc(AI_PRICING_DOC_ID).get();
    if (snap.exists) {
      const raw = (snap.data()?.models ?? {}) as Record<string, unknown>;
      const rejected: string[] = [];
      for (const [model, entry] of Object.entries(raw)) {
        const parsed = parsePricingEntry(entry);
        if (parsed) merged[model] = parsed;
        else rejected.push(model);
      }
      if (rejected.length > 0) {
        // Silencieusement ignorée, une entrée mal saisie ferait facturer le
        // modèle au tarif de repli sans que personne ne sache pourquoi.
        await logError({
          message: "Grille tarifaire : entrées illisibles ignorées",
          errorDescription: `Modèles rejetés : ${rejected.join(", ")}`,
          extra: { rejected },
        });
      }
    }
    cachedTable = { value: merged, readAt: Date.now() };
    return merged;
  } catch (err) {
    await logError({
      message: "Grille tarifaire : lecture impossible, repli en dur appliqué",
      errorDescription: err instanceof Error ? err.message : String(err),
    });
    return merged;
  }
}
