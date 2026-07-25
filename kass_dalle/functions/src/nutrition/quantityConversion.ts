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

  // Cuillère à dessert
  c_a_d: "c_a_d",
  cad: "c_a_d",
  cuillere_a_dessert: "c_a_d",
  cuilleres_a_dessert: "c_a_d",

  // Once liquide américaine
  fl_oz: "fl_oz",
  once_liquide_americaine: "fl_oz",

  // Once liquide impériale
  uk_fl_oz: "uk_fl_oz",
  once_liquide_imperiale: "uk_fl_oz",

  // Tasse à café
  tasse_a_cafe: "tasse_a_cafe",
  tasses_a_cafe: "tasse_a_cafe",

  // Verre à vin
  verre_a_vin: "verre_vin",
  verre_vin: "verre_vin",

  // Grand verre
  grand_verre: "grand_verre",
  grand_verre_a_moutarde: "grand_verre",

  // Quart de litre
  quart_de_litre: "quart_de_litre",

  // Chopine
  chopine: "chopine",
  choppe: "chopine",

  // Pinte américaine
  pinte_americaine: "pinte_americaine",
  pt_us: "pinte_americaine",

  // Pinte impériale
  pinte_imperiale: "pinte_imperiale",
  pt_uk: "pinte_imperiale",

  // Demi-litre
  demi_litre: "demi_litre",

  // Quart américain
  quart_americain: "quart_americain",
  qt_us: "quart_americain",

  // Gallon américain
  gallon_americain: "gallon_americain",
  gal_us: "gallon_americain",

  // Pincée (poids fixe)
  pincee: "pincee",
  pincees: "pincee",
  pinch: "pincee",

  // Pointe de couteau (poids fixe)
  pointe_de_couteau: "pointe_de_couteau",
  pointe: "pointe_de_couteau",

  // Larme / goutte
  larme: "larme",
  larmes: "larme",
  goutte: "goutte",
  gouttes: "goutte",

  // Tasse métrique
  tasse_metrique: "tasse_metrique",
  tasses_metriques: "tasse_metrique",

  // Compteurs / pièces
  piece: "piece",
  pieces: "piece",
  unite: "piece",
  unites: "piece",
  pc: "piece",
  pcs: "piece",

  // Unités botaniques — formes plurielles → canonique singulier
  brins: "brin",
  filets: "filet",
  tiges: "tige",
  noisettes: "noisette",
  zestes: "zeste",
  bouquets: "bouquet",
  feuilles: "feuille",
  branches: "branche",
};

const WEIGHT_UNIT_TO_GRAMS: Record<string, number> = {
  g: 1,
  gram: 1,
  grams: 1,
  gr: 1,
  kg: 1000,
  mg: 0.001,
  // Petites mesures fixes (poids indépendant du volume)
  pincee: 0.5,
  pointe_de_couteau: 1,
  // Unités botaniques — valeurs par défaut codées en dur pour fiabilité.
  // Le référentiel Firestore (nutrition_units) peut les surcharger sans redéploiement.
  brin: 2,
  filet: 5,
  bouquet: 30,
  feuille: 1,
  branche: 15,
  tige: 3,
  noisette: 5,
  zeste: 3,
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
  // Petits volumes
  larme: 0.05,
  goutte: 0.05,
  // Cuillère à dessert
  c_a_d: 10,
  // Once liquide
  fl_oz: 29.5,
  uk_fl_oz: 28.4,
  // Tasse à café
  tasse_a_cafe: 70,
  // Verre à vin
  verre_vin: 120,
  // Tasse US (236 ml) — "tasse"/"cup" existants restent à 240 ml
  tasse_metrique: 250,
  // Grand verre
  grand_verre: 200,
  // Quart de litre
  quart_de_litre: 250,
  // Chopine
  chopine: 480,
  // Pinte
  pinte_americaine: 473,
  pinte_imperiale: 568,
  // Demi-litre
  demi_litre: 500,
  // Quart américain
  quart_americain: 946,
  // Gallon américain
  gallon_americain: 3785,
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
