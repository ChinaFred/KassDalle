import { callGemini, extractJsonObject, textPart } from "../gemini/client";
import { recordTokenUsage } from "../gemini/tokenUsage";
import { normalizeNutrients } from "./nutrients";
import { logError, logInfo } from "../logging";

export function hasPer100gValues(value: unknown): boolean {
  if (!value || typeof value !== "object") return false;
  const record = value as Record<string, unknown>;
  for (const v of Object.values(record)) {
    if (typeof v === "number" && Number.isFinite(v) && v > 0) {
      return true;
    }
    if (typeof v === "string") {
      const parsed = Number(v.replace(",", "."));
      if (Number.isFinite(parsed) && parsed > 0) {
        return true;
      }
    }
  }
  return false;
}

export async function estimatePer100gWithGemini(params: {
  apiKey: string;
  ingredientId: string;
  canonicalName: string;
  aliases: string[];
  correlationId: string;
  userId?: string;
  feature?: string;
}): Promise<Record<string, number>> {
  const aliases = params.aliases
    .map((a) => a.trim())
    .filter((a) => a.length > 0)
    .slice(0, 8)
    .join(", ");

  const prompt = [
    "Tu es un expert nutrition.",
    "Retourne UNIQUEMENT un objet JSON valide sans markdown.",
    "But: estimer les nutriments pour 100g d'ingrédient brut standard.",
    "N'invente pas d'unités exotiques.",
    "Champs autorisés (nombres >= 0): kcal, protein_g, carbs_g, sugar_g, fiber_g, fat_g, saturated_fat_g, sodium_mg, salt_g.",
    "Si inconnu: mets 0.",
    "Format strict attendu:",
    '{"per100g":{"kcal":0,"protein_g":0,"carbs_g":0,"sugar_g":0,"fiber_g":0,"fat_g":0,"saturated_fat_g":0,"sodium_mg":0,"salt_g":0}}',
    `ingredient_id: ${params.ingredientId}`,
    `nom canonique: ${params.canonicalName}`,
    `aliases: ${aliases || "(aucun)"}`,
  ].join("\n");

  void logInfo({
    message: `estimatePer100gWithGemini: prompt envoyé pour "${params.ingredientId}"`,
    extra: {
      correlationId: params.correlationId,
      ingredientId: params.ingredientId,
      canonicalName: params.canonicalName,
      aliases,
      prompt,
    },
  });

  const result = await callGemini(
    params.apiKey,
    [textPart(prompt)],
    {
      correlationId: params.correlationId,
      feature: params.feature ?? "nutrition_ingredients_enrichment",
      moduleType: "DESIGN",
      timeoutMs: 45_000,
      userId: params.userId,
    },
  );

  await recordTokenUsage(
    result,
    params.feature ?? "nutrition_ingredients_enrichment",
    params.userId,
    {
      correlationId: params.correlationId,
      entityType: "nutrition_ingredient",
      entityId: params.ingredientId,
    },
  );

  const text = (result.text ?? "").trim();
  void logInfo({
    message: `estimatePer100gWithGemini: réponse brute pour "${params.ingredientId}"`,
    extra: { correlationId: params.correlationId, rawResponse: text.slice(0, 600) },
  });

  if (!text) {
    void logError({
      message: `estimatePer100gWithGemini: réponse vide pour "${params.ingredientId}"`,
      errorDescription: "Gemini a retourné une réponse vide",
      correlationId: params.correlationId,
    });
    return {};
  }

  try {
    const parsed = JSON.parse(extractJsonObject(text)) as Record<string, unknown>;
    const rawPer100g = (
      parsed.per100g && typeof parsed.per100g === "object"
        ? parsed.per100g
        : parsed
    ) as Record<string, unknown>;

    const normalized = normalizeNutrients(rawPer100g);
    void logInfo({
      message: `estimatePer100gWithGemini: per100g normalisé pour "${params.ingredientId}"`,
      extra: { correlationId: params.correlationId, per100g: normalized },
    });
    return normalized;
  } catch (err) {
    void logError({
      message: `estimatePer100gWithGemini: erreur parsing JSON pour "${params.ingredientId}"`,
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId: params.correlationId,
      extra: { rawText: text.slice(0, 400) },
    });
    return {};
  }
}
