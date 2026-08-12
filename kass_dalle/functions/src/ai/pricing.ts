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

export interface AiModelPricing {
  inputPerMillion: number;
  outputPerMillion: number;
  imageOutputPerUnit?: number;
}

const DEFAULT_PRICING: AiModelPricing = {
  inputPerMillion: 0.30,
  outputPerMillion: 2.50,
  imageOutputPerUnit: 0,
};

const PRICING_TABLE: Record<string, AiModelPricing> = {
  // ── Google Gemini ────────────────────────────────────────────────────────
  "gemini-2.5-flash": { inputPerMillion: 0.30, outputPerMillion: 2.50, imageOutputPerUnit: 0 },
  "gemini-2.5-flash-image": { inputPerMillion: 0.30, outputPerMillion: 2.50, imageOutputPerUnit: 0.04 },
  "gemini-2.5-pro": { inputPerMillion: 1.25, outputPerMillion: 10.00, imageOutputPerUnit: 0 },
  "gemini-2.0-flash": { inputPerMillion: 0.10, outputPerMillion: 0.40, imageOutputPerUnit: 0 },
  "gemini-1.5-flash": { inputPerMillion: 0.075, outputPerMillion: 0.30, imageOutputPerUnit: 0 },
  "gemini-1.5-pro": { inputPerMillion: 1.25, outputPerMillion: 5.00, imageOutputPerUnit: 0 },

  // ── Anthropic Claude ─────────────────────────────────────────────────────
  // Tarifs catalogue au 12 août 2026. Claude Sonnet 5 bénéficie d'un tarif
  // d'introduction (2,00 / 10,00) jusqu'au 31 août 2026 : on facture au tarif
  // plein, pour que le reporting ne sous-estime jamais le coût réel.
  "claude-opus-5": { inputPerMillion: 5.00, outputPerMillion: 25.00, imageOutputPerUnit: 0 },
  "claude-opus-4-8": { inputPerMillion: 5.00, outputPerMillion: 25.00, imageOutputPerUnit: 0 },
  "claude-sonnet-5": { inputPerMillion: 3.00, outputPerMillion: 15.00, imageOutputPerUnit: 0 },
  "claude-sonnet-4-6": { inputPerMillion: 3.00, outputPerMillion: 15.00, imageOutputPerUnit: 0 },
  "claude-haiku-4-5": { inputPerMillion: 1.00, outputPerMillion: 5.00, imageOutputPerUnit: 0 },
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

export function estimateAiCostUsd(args: {
  model: string;
  inputTokens: number;
  outputTokens: number;
  imageOutputCount?: number;
}): number {
  const pricing = getPricingForModel(args.model);
  const images = args.imageOutputCount ?? 0;
  return (args.inputTokens / 1e6) * pricing.inputPerMillion +
    (args.outputTokens / 1e6) * pricing.outputPerMillion +
    images * (pricing.imageOutputPerUnit ?? 0);
}
