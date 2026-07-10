export interface GeminiModelPricing {
  inputPerMillion: number;
  outputPerMillion: number;
  imageOutputPerUnit?: number;
}

const DEFAULT_PRICING: GeminiModelPricing = {
  inputPerMillion: 0.30,
  outputPerMillion: 2.50,
  imageOutputPerUnit: 0,
};

const PRICING_TABLE: Record<string, GeminiModelPricing> = {
  "gemini-2.5-flash": { inputPerMillion: 0.30, outputPerMillion: 2.50, imageOutputPerUnit: 0 },
  "gemini-2.5-flash-image": { inputPerMillion: 0.30, outputPerMillion: 2.50, imageOutputPerUnit: 0.04 },
  "gemini-2.5-pro": { inputPerMillion: 1.25, outputPerMillion: 10.00, imageOutputPerUnit: 0 },
  "gemini-2.0-flash": { inputPerMillion: 0.10, outputPerMillion: 0.40, imageOutputPerUnit: 0 },
  "gemini-1.5-flash": { inputPerMillion: 0.075, outputPerMillion: 0.30, imageOutputPerUnit: 0 },
  "gemini-1.5-pro": { inputPerMillion: 1.25, outputPerMillion: 5.00, imageOutputPerUnit: 0 },
};

export function getPricingForModel(model: string): GeminiModelPricing {
  if (PRICING_TABLE[model]) return PRICING_TABLE[model];
  const prefixMatch = Object.entries(PRICING_TABLE).find(([prefix]) => model.startsWith(prefix));
  if (prefixMatch) return prefixMatch[1];
  return DEFAULT_PRICING;
}

export function estimateGeminiCostUsd(args: {
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
