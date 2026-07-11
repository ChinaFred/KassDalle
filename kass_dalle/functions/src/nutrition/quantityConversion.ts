import { normalizeIngredientCanonicalId, normalizeIngredientStrictId } from "./ingredientName";

export interface KnownUnitMetadata {
  normalizedUnit: string;
  measurementType: "weight" | "volume" | "count";
  gramsPerUnit: number;
  mlPerUnit?: number;
  source: "builtin";
}

const COUNT_UNITS = new Set([
  "piece",
  "pieces",
  "unite",
  "unites",
  "pc",
  "pcs",
]);

const CANONICAL_UNIT_ALIASES: Record<string, string> = {
  // Cuillère à café
  cac: "c_a_c",
  c_a_c: "c_a_c",
  c_c: "c_a_c",
  c_a_cafe: "c_a_c",
  cuillere_cafe: "c_a_c",
  cuilleres_cafe: "c_a_c",
  cuillere_a_cafe: "c_a_c",
  cuilleres_a_cafe: "c_a_c",
  teaspoon: "c_a_c",
  teaspoons: "c_a_c",
  tsp: "c_a_c",

  // Cuillère à soupe
  cas: "c_a_s",
  c_a_s: "c_a_s",
  c_s: "c_a_s",
  c_a_soupe: "c_a_s",
  cuillere_soupe: "c_a_s",
  cuilleres_soupe: "c_a_s",
  cuillere_a_soupe: "c_a_s",
  cuilleres_a_soupe: "c_a_s",
  tablespoon: "c_a_s",
  tablespoons: "c_a_s",
  tbsp: "c_a_s",

  // Cuillère à thé
  c_a_the: "c_a_the",
  cuillere_the: "c_a_the",
  cuilleres_the: "c_a_the",
  cuillere_a_the: "c_a_the",
  cuilleres_a_the: "c_a_the",

  // Compteurs / pièces
  piece: "piece",
  pieces: "piece",
  unite: "piece",
  unites: "piece",
  pc: "piece",
  pcs: "piece",
};

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
  c_a_c: 5,
  c_a_the: 5,
  cs: 15,
  c_a_s: 15,
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

type PieceWeightProfile = {
  matchers: string[];
  gramsPerPiece: number;
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

const PIECE_WEIGHT_PROFILES: PieceWeightProfile[] = [
  { matchers: ["aubergine"], gramsPerPiece: 300 },
  { matchers: ["concombre"], gramsPerPiece: 300 },
  { matchers: ["courgette"], gramsPerPiece: 200 },
  { matchers: ["poivron"], gramsPerPiece: 150 },
  { matchers: ["tomate"], gramsPerPiece: 120 },
  { matchers: ["oignon"], gramsPerPiece: 110 },
  { matchers: ["carotte"], gramsPerPiece: 80 },
  { matchers: ["pomme_de_terre"], gramsPerPiece: 170 },
  { matchers: ["ail"], gramsPerPiece: 5 },
  { matchers: ["steak", "steack"], gramsPerPiece: 150 },
  { matchers: ["escalope"], gramsPerPiece: 150 },
  { matchers: ["blanc_de_poulet", "filet_de_poulet"], gramsPerPiece: 180 },
  { matchers: ["haut_de_cuisse_de_poulet", "haut_de_cuisse"], gramsPerPiece: 130 },
  { matchers: ["cuisse_de_poulet"], gramsPerPiece: 180 },
  { matchers: ["saucisse"], gramsPerPiece: 100 },
  { matchers: ["cotelette"], gramsPerPiece: 140 },
  { matchers: ["tranche_de_jambon", "jambon"], gramsPerPiece: 40 },
  { matchers: ["boulette"], gramsPerPiece: 30 },
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

function matchedPieceWeightForIngredient(name: string): number | null {
  const normalized = normalizeIngredientCanonicalId(name);
  if (!normalized) return null;
  for (const profile of PIECE_WEIGHT_PROFILES) {
    if (profile.matchers.some((matcher) => normalized.includes(matcher))) {
      return profile.gramsPerPiece;
    }
  }
  return null;
}

function pieceWeightForIngredient(name: string): number {
  const matched = matchedPieceWeightForIngredient(name);
  if (matched != null) return matched;
  return 100;
}

export function canonicalizeNormalizedUnit(normalizedUnit: string): string {
  if (!normalizedUnit) return "";
  if (CANONICAL_UNIT_ALIASES[normalizedUnit]) {
    return CANONICAL_UNIT_ALIASES[normalizedUnit];
  }
  if (COUNT_UNITS.has(normalizedUnit)) return "piece";
  return normalizedUnit;
}

export function normalizeObservedUnit(unit: unknown): string {
  if (typeof unit !== "string") return "";
  const strict = normalizeIngredientStrictId(unit);
  return canonicalizeNormalizedUnit(strict);
}

export function getKnownUnitMetadata(unit: unknown, ingredientName?: string): KnownUnitMetadata | null {
  if (typeof unit !== "string") return null;
  const normalizedUnit = normalizeObservedUnit(unit);
  if (!normalizedUnit) {
    const inferredPieceWeight = matchedPieceWeightForIngredient(ingredientName ?? "");
    if (inferredPieceWeight != null) {
      return {
        normalizedUnit: "piece",
        measurementType: "count",
        gramsPerUnit: inferredPieceWeight,
        source: "builtin",
      };
    }
    return null;
  }

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
  if (volumeMl != null) {
    return {
      normalizedUnit,
      measurementType: "volume",
      mlPerUnit: volumeMl,
      gramsPerUnit: volumeMl * densityForIngredient(ingredientName ?? ""),
      source: "builtin",
    };
  }

  if (normalizedUnit === "piece") {
    return {
      normalizedUnit,
      measurementType: "count",
      gramsPerUnit: pieceWeightForIngredient(ingredientName ?? ""),
      source: "builtin",
    };
  }

  return null;
}

export function unitFactorToGrams(unit: unknown, ingredientName?: string): number | null {
  return getKnownUnitMetadata(unit, ingredientName)?.gramsPerUnit ?? null;
}
