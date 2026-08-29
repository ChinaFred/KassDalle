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

/**
 * Clé de nutriment ramenée à sa forme comparable.
 *
 * Les accents sont retirés AVANT le filtrage : sans cela « Énergie » devenait
 * « nergie », un nutriment que la table d'alias ne connaît pas et qui
 * disparaissait sans un mot. Même règle que le reste du projet
 * (`normalizeBase`, ingredientName.ts).
 */
function normalizeKey(key: string): string {
  return key
    .trim()
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
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

    // Deux écritures du MÊME nutriment ne s'additionnent pas : « sodium » et
    // « sodium_mg » désignent une seule grandeur, pas deux apports. La forme
    // canonique gagne quand elle est là — c'est celle que le schéma demande —
    // sinon la première rencontrée. Un `+=` ici doublait la valeur dès que le
    // modèle répondait sous deux noms.
    const existing = out[canonical];
    if (existing != null && key !== canonical) continue;
    out[canonical] = value;
  }

  // Sel et sodium sont UNE grandeur dans deux unités, pas deux apports à
  // cumuler. Le schéma d'enrichissement réclame les deux champs, le modèle
  // répond les deux — cohérents entre eux — et la conversion du sel était
  // ajoutée au sodium déjà fourni. Résultat : le sel pur pesait 200 g pour
  // 100 g, la sauce soja 11 g de sodium au lieu de 5,5, et TOUTE l'application
  // affichait un apport en sel deux fois trop élevé. Aucune erreur ne se
  // levait : la seconde formule reconstruisait un sel cohérent avec le sodium
  // faux.
  //
  // Le sodium fait foi quand il est fourni : c'est la mesure des tables de
  // composition, dont le sel n'est qu'une conversion. Le sel ne sert de source
  // que s'il est seul.
  if (out["sodium_mg"] != null) {
    out["salt_g"] = out["sodium_mg"] * SODIUM_TO_SALT_FACTOR;
  } else if (out["salt_g"] != null) {
    out["sodium_mg"] = out["salt_g"] * SALT_TO_SODIUM_FACTOR;
  }

  return out;
}
