/**
 * Grille tarifaire des modèles d'IA du projet, tous fournisseurs confondus.
 *
 * Anciennement `gemini/pricing.ts`. Le fichier a changé de nom le jour où un
 * second fournisseur est entré : une table nommée « Gemini » qui contient les
 * tarifs Claude est le genre de mensonge de nommage qui finit par tromper
 * quelqu'un — et ici, ce quelqu'un lit un chiffre de coûts qu'il croit exact.
 *
 * Jumeau Dart : `lib/features/admin/data/ai_pricing.dart`.
 * Cas partagés : `test-fixtures/ai_pricing.json`.
 *
 * C'est le cas le plus sournois des logiques dupliquées du projet : un écart
 * ne casse aucun écran et ne lève aucune erreur, il fait seulement mentir le
 * reporting de coûts — le chiffre continue de s'afficher.
 */

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

/**
 * Tarif d'un identifiant de modèle, correspondance exacte d'abord, puis repli
 * sur le préfixe LE PLUS LONG.
 *
 * Le repli rendait autrefois le premier préfixe rencontré. Comme
 * « gemini-2.5-flash » précède « gemini-2.5-flash-image » dans la table, une
 * révision datée d'un modèle d'image (« …-image-preview ») était résolue vers
 * le tarif texte : ses images étaient facturées zéro, et le reporting de coûts
 * restait crédible tout en étant faux. Le jumeau Dart portait le même défaut.
 */
export function getPricingForModel(model: string): AiModelPricing {
  if (PRICING_TABLE[model]) return PRICING_TABLE[model];

  let best: AiModelPricing | null = null;
  let bestLength = -1;
  for (const [prefix, pricing] of Object.entries(PRICING_TABLE)) {
    if (model.startsWith(prefix) && prefix.length > bestLength) {
      best = pricing;
      bestLength = prefix.length;
    }
  }
  return best ?? DEFAULT_PRICING;
}

/**
 * Tarif réellement en vigueur à une date donnée.
 *
 * `getPricingForModel` rend l'entrée de catalogue, promotion comprise ; c'est
 * ici qu'on décide laquelle des deux s'applique.
 */
export function effectivePricing(model: string, at: Date): AiModelPricing {
  const pricing = getPricingForModel(model);
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
}): number {
  const pricing = effectivePricing(args.model, args.at ?? new Date());
  const images = args.imageOutputCount ?? 0;
  return (
    (args.inputTokens / 1e6) * pricing.inputPerMillion +
    (args.outputTokens / 1e6) * pricing.outputPerMillion +
    images * (pricing.imageOutputPerUnit ?? 0)
  );
}
