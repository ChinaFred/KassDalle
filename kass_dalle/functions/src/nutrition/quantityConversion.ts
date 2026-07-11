import { normalizeIngredientCanonicalId, normalizeIngredientStrictId } from "./ingredientName";

export interface KnownUnitMetadata {
  normalizedUnit: string;
  measurementType: "weight" | "volume";
  gramsPerUnit: number;
  mlPerUnit?: number;
  source: "builtin";
}

const WEIGHT_UNIT_TO_GRAMS: Record<string, number> = {
  g: 1,
  gram: 1,
  grams: 1,
  gr: 1,
  kg: 1000,
  mg: 0.001,
};

const VOLUME_UNIT_TO_ML: Record<string, number> = {
  ml: 1,
  millilitre: 1,
  millilitres: 1,
  milliliter: 1,
  milliliters: 1,
  cl: 10,
  dl: 100,
  l: 1000,
  litre: 1000,
  litres: 1000,
  liter: 1000,
  liters: 1000,
  cc: 5,
  c_c: 5,
  cac: 5,
  c_a_c: 5,
  cuillere_cafe: 5,
  cuilleres_cafe: 5,
  cuillere_the: 5,
  cuilleres_the: 5,
  cuillere_a_cafe: 5,
  cuilleres_a_cafe: 5,
  cuillere_a_the: 5,
  cuilleres_a_the: 5,
  teaspoon: 5,
  teaspoons: 5,
  tsp: 5,
  cs: 15,
  c_s: 15,
  cas: 15,
  c_a_s: 15,
  cuillere_soupe: 15,
  cuilleres_soupe: 15,
  cuillere_a_soupe: 15,
  cuilleres_a_soupe: 15,
  tablespoon: 15,
  tablespoons: 15,
  tbsp: 15,
  tasse: 240,
  tasses: 240,
  cup: 240,
  cups: 240,
  verre: 200,
  verres: 200,
  verre_a_the: 200,
  verres_a_the: 200,
  bol: 350,
  bols: 350,
};

type DensityProfile = {
  matchers: string[];
  densityGPerMl: number;
};

const DENSITY_PROFILES: DensityProfile[] = [
  { matchers: ["miel", "melasse", "sirop_d_erable", "sirop_agave"], densityGPerMl: 1.35 },
  { matchers: ["huile", "huile_d_olive", "huile_de_tournesol", "ghee", "beurre_fondu"], densityGPerMl: 0.92 },
  { matchers: ["farine", "fecule", "maizena", "poudre_d_amande", "amande_en_poudre"], densityGPerMl: 0.55 },
  { matchers: ["sucre_glace", "sucre_iced"], densityGPerMl: 0.5 },
  { matchers: ["sucre", "cassonade", "sucre_roux", "sucre_blanc"], densityGPerMl: 0.85 },
  { matchers: ["cacao", "chocolat_en_poudre"], densityGPerMl: 0.4 },
  { matchers: ["sel", "gros_sel", "fleur_de_sel"], densityGPerMl: 1.2 },
  { matchers: ["riz", "semoule", "polenta", "quinoa", "lentille", "pois_chiche", "haricot_sec"], densityGPerMl: 0.8 },
  { matchers: ["creme", "creme_fraiche", "yaourt", "fromage_blanc"], densityGPerMl: 1 },
  { matchers: ["lait", "eau", "bouillon", "vinaigre", "vin", "jus", "cafe", "the"], densityGPerMl: 1 },
];

function densityForIngredient(name: string): number {
  const normalized = normalizeIngredientCanonicalId(name);
  if (!normalized) return 1;
  for (const profile of DENSITY_PROFILES) {
    if (profile.matchers.some((matcher) => normalized.includes(matcher))) {
      return profile.densityGPerMl;
    }
  }
  return 1;
}

export function normalizeObservedUnit(unit: unknown): string {
  if (typeof unit !== "string") return "";
  return normalizeIngredientStrictId(unit);
}

export function getKnownUnitMetadata(unit: unknown, ingredientName?: string): KnownUnitMetadata | null {
  if (typeof unit !== "string") return null;
  const normalizedUnit = normalizeIngredientStrictId(unit);
  if (!normalizedUnit) return null;

  const weightFactor = WEIGHT_UNIT_TO_GRAMS[normalizedUnit];
  if (weightFactor != null) {
    return {
      normalizedUnit,
      measurementType: "weight",
      gramsPerUnit: weightFactor,
      source: "builtin",
    };
  }

  const volumeMl = VOLUME_UNIT_TO_ML[normalizedUnit];
  if (volumeMl == null) return null;

  return {
    normalizedUnit,
    measurementType: "volume",
    mlPerUnit: volumeMl,
    gramsPerUnit: volumeMl * densityForIngredient(ingredientName ?? ""),
    source: "builtin",
  };
}

export function unitFactorToGrams(unit: unknown, ingredientName?: string): number | null {
  return getKnownUnitMetadata(unit, ingredientName)?.gramsPerUnit ?? null;
}
