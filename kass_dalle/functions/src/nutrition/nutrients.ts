export interface NormalizedNutrients {
  [key: string]: number;
}

export const NUTRIENT_ALIASES: Record<string, string> = {
  kcal: "kcal",
  calories: "kcal",
  energie: "kcal",
  energy: "kcal",
  proteines: "protein_g",
  protein: "protein_g",
  proteins: "protein_g",
  glucides: "carbs_g",
  carbs: "carbs_g",
  sucres: "sugar_g",
  sugar: "sugar_g",
  fibres: "fiber_g",
  fiber: "fiber_g",
  lipides: "fat_g",
  fat: "fat_g",
  saturates: "saturated_fat_g",
  saturated_fat: "saturated_fat_g",
  sodium: "sodium_mg",
  sodium_mg: "sodium_mg",
  sel: "salt_g",
  salt: "salt_g",
};

const SALT_TO_SODIUM_FACTOR = 393.4;
const SODIUM_TO_SALT_FACTOR = 1 / SALT_TO_SODIUM_FACTOR;

function normalizeKey(key: string): string {
  return key
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_]/g, "_")
    .replace(/_+/g, "_")
    .replace(/^_|_$/g, "");
}

function asNumber(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Number(value.replace(",", "."));
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

export function normalizeNutrients(input: Record<string, unknown>): NormalizedNutrients {
  const out: NormalizedNutrients = {};

  for (const [rawKey, rawValue] of Object.entries(input)) {
    const key = normalizeKey(rawKey);
    const canonical = NUTRIENT_ALIASES[key] ?? key;
    const value = asNumber(rawValue);
    if (!Number.isFinite(value) || value <= 0) continue;
    out[canonical] = (out[canonical] ?? 0) + value;
  }

  // Sel / sodium considérés interchangeables côté produit.
  // Canonique backend: sodium_mg.
  if (out["salt_g"] != null) {
    out["sodium_mg"] = (out["sodium_mg"] ?? 0) + out["salt_g"] * SALT_TO_SODIUM_FACTOR;
  }

  // Expose aussi salt_g pour l'UI à partir de sodium canonique.
  if (out["sodium_mg"] != null) {
    out["salt_g"] = out["sodium_mg"] * SODIUM_TO_SALT_FACTOR;
  }

  return out;
}
