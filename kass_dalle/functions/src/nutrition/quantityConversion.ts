import { normalizeIngredientCanonicalId, normalizeIngredientStrictId } from "./ingredientName";

export interface KnownUnitMetadata {
  normalizedUnit: string;
  measurementType: "weight" | "volume" | "count";
  gramsPerUnit: number;
  mlPerUnit?: number;
  source: "builtin";
}

/** Fractions Unicode courantes en cuisine → valeur décimale. */
const UNICODE_FRACTIONS: Record<string, number> = {
  "½": 0.5,
  "⅓": 1 / 3,
  "⅔": 2 / 3,
  "¼": 0.25,
  "¾": 0.75,
  "⅕": 0.2,
  "⅖": 0.4,
  "⅗": 0.6,
  "⅘": 0.8,
  "⅙": 1 / 6,
  "⅚": 5 / 6,
  "⅐": 1 / 7,
  "⅛": 0.125,
  "⅜": 0.375,
  "⅝": 0.625,
  "⅞": 0.875,
  "⅑": 1 / 9,
  "⅒": 0.1,
};

/**
 * Parse une quantité culinaire en nombre positif.
 * Gère : entiers, décimaux (`,` ou `.`), fractions ASCII (`1/2`),
 * fractions Unicode (`½`) et nombres mixtes (`1 ½`, `1 1/2`).
 * Retourne `null` si non parsable ou si le résultat est <= 0.
 */
export function parseQuantityToNumber(value: unknown): number | null {
  if (typeof value === "number") {
    return Number.isFinite(value) && value > 0 ? value : null;
  }
  if (typeof value !== "string") return null;

  let s = value.trim().replace(",", ".");
  if (!s) return null;

  // Extrait les fractions Unicode (gère aussi les nombres mixtes "1 ½").
  let total = 0;
  let matchedUnicode = false;
  for (const [glyph, dec] of Object.entries(UNICODE_FRACTIONS)) {
    if (s.includes(glyph)) {
      total += dec;
      s = s.replace(glyph, " ").trim();
      matchedUnicode = true;
    }
  }

  if (s.length > 0) {
    // Fraction ASCII "a/b", éventuellement précédée d'un entier ("1 1/2").
    const mixed = s.match(/^(?:(\d+)\s+)?(\d+)\s*\/\s*(\d+)$/);
    if (mixed) {
      const whole = mixed[1] ? Number(mixed[1]) : 0;
      const num = Number(mixed[2]);
      const den = Number(mixed[3]);
      if (Number.isFinite(num) && Number.isFinite(den) && den > 0) {
        total += whole + num / den;
        return total > 0 ? total : null;
      }
    }
    const parsed = Number(s);
    if (Number.isFinite(parsed)) {
      total += parsed;
      return total > 0 ? total : null;
    }
    // Reste non numérique : valable uniquement si une fraction Unicode a matché.
    if (!matchedUnicode) return null;
  }

  return total > 0 ? total : null;
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
  // « cuillerée » (le contenu de la cuillère) est aussi courant que « cuillère »
  // (l'ustensile) dans les recettes, et « cuiller » reste une orthographe
  // valide. Sans ces graphies, l'unité était déclarée inconnue et l'ingrédient
  // sortait du calcul nutritionnel.
  cuilleree_cafe: "c_a_c",
  cuillerees_cafe: "c_a_c",
  cuilleree_a_cafe: "c_a_c",
  cuillerees_a_cafe: "c_a_c",
  cuiller_a_cafe: "c_a_c",
  cuillers_a_cafe: "c_a_c",
  cuil_a_cafe: "c_a_c",
  cuil_cafe: "c_a_c",
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
  cuilleree_soupe: "c_a_s",
  cuillerees_soupe: "c_a_s",
  cuilleree_a_soupe: "c_a_s",
  cuillerees_a_soupe: "c_a_s",
  cuiller_a_soupe: "c_a_s",
  cuillers_a_soupe: "c_a_s",
  cuil_a_soupe: "c_a_s",
  cuil_soupe: "c_a_s",
  tablespoon: "c_a_s",
  tablespoons: "c_a_s",
  tbsp: "c_a_s",

  // Cuillère à thé
  c_a_the: "c_a_the",
  cuillere_the: "c_a_the",
  cuilleres_the: "c_a_the",
  cuillere_a_the: "c_a_the",
  cuilleres_a_the: "c_a_the",
  cuilleree_a_the: "c_a_the",
  cuillerees_a_the: "c_a_the",
  cuiller_a_the: "c_a_the",

  // Cuillère à dessert
  c_a_d: "c_a_d",
  cad: "c_a_d",
  cuillere_a_dessert: "c_a_d",
  cuilleres_a_dessert: "c_a_d",
  cuilleree_a_dessert: "c_a_d",
  cuillerees_a_dessert: "c_a_d",
  cuiller_a_dessert: "c_a_d",

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

  // Unités de découpe et de prise en main — sans poids par défaut : il dépend
  // trop de l'ingrédient pour qu'une moyenne ait un sens. Leur pluriel est
  // néanmoins canonisé, sinon le poids appris pour « tranche » ne serait jamais
  // retrouvé pour une recette qui écrit « 4 tranches ».
  tranches: "tranche",
  poignees: "poignee",
  morceaux: "morceau",
  gousses: "gousse",
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

/**
 * Poids de référence d'une pièce, par ingrédient.
 *
 * Table d'AMORÇAGE : elle sert à peupler `nutrition_ingredients` au premier
 * démarrage, et de filet quand le référentiel n'a pas encore appris. En régime
 * permanent, c'est le référentiel qui décide — voir recipeNutrition.ts.
 */
export const PIECE_WEIGHT_PROFILES: PieceWeightProfile[] = [
  // Œufs — l'ORDRE compte : la recherche se fait par `includes`, donc les
  // formes les plus spécifiques doivent précéder « oeuf », sinon un jaune
  // hériterait du poids d'un œuf entier. Poids sans coquille, calibre moyen.
  // Les pluriels sont listés explicitement : « jaunes d'œufs » se normalise en
  // `jaunes_d_oeufs`, que « jaune_d_oeuf » ne peut pas atteindre.
  { matchers: ["jaune_d_oeuf", "jaunes_d_oeuf", "jaune_oeuf"], gramsPerPiece: 18 },
  { matchers: ["blanc_d_oeuf", "blancs_d_oeuf", "blanc_oeuf"], gramsPerPiece: 30 },
  { matchers: ["oeuf"], gramsPerPiece: 50 },
  { matchers: ["aubergine"], gramsPerPiece: 300 },
  { matchers: ["concombre"], gramsPerPiece: 300 },
  { matchers: ["courgette"], gramsPerPiece: 200 },
  { matchers: ["poivron"], gramsPerPiece: 150 },
  { matchers: ["tomate"], gramsPerPiece: 120 },
  { matchers: ["oignon"], gramsPerPiece: 110 },
  { matchers: ["echalote"], gramsPerPiece: 30 },
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

/**
 * Densité en g/ml de l'ingrédient, 1 par défaut (eau).
 *
 * C'est la densité — pas un poids figé par unité — qui fait foi pour convertir
 * un volume en grammes : une cuillère à soupe d'huile, de miel et de farine ne
 * pèsent pas la même chose.
 */
export function densityForIngredient(name: string): number {
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

/** Valeurs issues d'un document du référentiel Firestore `nutrition_units`. */
export interface ReferentialUnitOverride {
  measurementType?: string;
  gramsPerUnit?: number;
  volumeMlPerUnit?: number;
}

/**
 * Poids connus d'un ingrédient, lus sur son document `nutrition_ingredients`.
 *
 * `gramsPerUnit` est indexé par unité canonique (`branche`, `brin`, `tranche`…) :
 * c'est le poids du COUPLE ingrédient/unité, la seule donnée qui ait un sens
 * pour ces unités. Une branche de thym pèse 1 g, une branche de céleri 60 —
 * aucune valeur portée par l'unité seule ne peut être vraie pour les deux.
 */
export interface IngredientWeightOverride {
  gramsPerPiece?: number;
  gramsPerUnit?: Record<string, number>;
}

/**
 * Unités dont le poids dépend entièrement de l'ingrédient compté.
 *
 * Elles figurent dans la table des poids avec une valeur moyenne qui ne décrit
 * aucun ingrédient réel — `branche: 15 g` donnait 60 g pour quatre branches de
 * thym, soit soixante fois le poids réel. Cette valeur reste un dernier recours ;
 * dès que le référentiel connaît le couple, c'est lui qui gagne.
 */
export const INGREDIENT_DEPENDENT_UNITS = new Set([
  "piece",
  "brin",
  "branche",
  "tige",
  "feuille",
  "bouquet",
  "filet",
  "noisette",
  "zeste",
  "tranche",
  "poignee",
  "morceau",
  "gousse",
]);

/** Cette unité tire-t-elle son poids de l'ingrédient plutôt que d'elle-même ? */
export function isIngredientDependentUnit(unit: unknown): boolean {
  const normalized = normalizeObservedUnit(unit);
  return normalized.length > 0 && INGREDIENT_DEPENDENT_UNITS.has(normalized);
}

/**
 * Poids en grammes d'UNE unité, en combinant le référentiel Firestore et la
 * table de repli intégrée.
 *
 * Règle : pour une unité de VOLUME, seul le volume est intrinsèque à l'unité —
 * les grammes dépendent de la densité de l'ingrédient. Un `grams_per_unit`
 * stocké sur une unité de volume est une valeur d'un seul ingrédient et ne doit
 * jamais être appliqué aux autres ; il est ici délibérément ignoré.
 *
 * Même règle pour une unité de COMPTAGE — « pièce » : elle n'a pas de poids
 * intrinsèque, elle prend celui de l'ingrédient compté. Un `grams_per_unit`
 * figé sur `piece` est le poids du premier ingrédient rencontré, 100 g par
 * défaut, et s'imposait ensuite à tous : un blanc d'œuf et une échalote pesaient
 * 100 g comme le reste. C'est la table par ingrédient, ou le poids à la pièce du
 * référentiel d'ingrédients, qui font foi.
 *
 * Pour une unité de POIDS (pincée, brin, poignée estimée par l'IA),
 * `grams_per_unit` est au contraire la bonne donnée et le référentiel prime sur
 * la table intégrée — c'est ce qui permet de corriger un poids depuis l'écran
 * d'administration sans redéployer.
 */
export function resolveUnitFactorToGrams(
  unit: unknown,
  ingredientName: string | undefined,
  override: ReferentialUnitOverride | null,
  ingredientOverride?: IngredientWeightOverride | null,
): number | null {
  // Le poids du couple ingrédient/unité prime sur tout le reste : c'est la
  // donnée la plus spécifique dont on dispose, et la seule qui distingue une
  // branche de thym d'une branche de céleri.
  const normalizedUnit = normalizeObservedUnit(unit);
  const coupleWeight = normalizedUnit
    ? ingredientOverride?.gramsPerUnit?.[normalizedUnit]
    : undefined;
  if (coupleWeight != null && Number.isFinite(coupleWeight) && coupleWeight > 0) {
    return coupleWeight;
  }

  // `grams_per_piece` est le même arbitrage, écrit avant que la map existe : le
  // poids d'une pièce d'un ingrédient. Il vaut aussi quand l'unité est absente.
  const pieceWeight = ingredientOverride?.gramsPerPiece;
  if (
    (normalizedUnit === "" || normalizedUnit === "piece") &&
    pieceWeight != null &&
    Number.isFinite(pieceWeight) &&
    pieceWeight > 0
  ) {
    return pieceWeight;
  }

  const builtin = getKnownUnitMetadata(unit, ingredientName);
  const isVolume =
    override?.measurementType === "volume" || builtin?.measurementType === "volume";

  if (isVolume) {
    const ml =
      (override?.volumeMlPerUnit != null && override.volumeMlPerUnit > 0
        ? override.volumeMlPerUnit
        : null) ?? builtin?.mlPerUnit ?? null;
    if (ml != null && ml > 0) {
      return ml * densityForIngredient(ingredientName ?? "");
    }
  }

  // La table seule décide qu'une unité est un comptage : un document du
  // référentiel ne peut pas transformer une unité qu'elle ignore — donc
  // corrigeable à la main — en comptage dont on jetterait la correction.
  const isCount = builtin?.measurementType === "count";

  if (!isVolume && !isCount && override?.gramsPerUnit != null && override.gramsPerUnit > 0) {
    return override.gramsPerUnit;
  }

  return builtin?.gramsPerUnit ?? null;
}
