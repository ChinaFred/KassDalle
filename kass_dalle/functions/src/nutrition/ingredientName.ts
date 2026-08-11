const PREPARATION_TOKENS = new Set<string>([
  "hache",
  "hachee",
  "haches",
  "hachees",
  "emince",
  "emincee",
  "eminces",
  "emincees",
  "rape",
  "rapee",
  "rapes",
  "rapees",
  "grossierement",
  "finement",
  "coupe",
  "coupee",
  "coupes",
  "coupees",
  "cisele",
  "ciselee",
  "ciseles",
  "ciselees",
]);

/**
 * Ligatures que la normalisation Unicode NFD ne d\u00e9compose pas : ce sont des
 * lettres \u00e0 part enti\u00e8re, pas des caract\u00e8res accentu\u00e9s. Sans ce traitement
 * elles tombaient dans \u00ab caract\u00e8re non alphanum\u00e9rique \u00bb et \u00ab \u0153uf \u00bb devenait
 * \u00ab uf \u00bb \u2014 un identifiant que le client, lui, \u00e9crivait \u00ab oeuf \u00bb.
 */
const LIGATURES: Record<string, string> = {
  "\u0153": "oe",
  "\u00e6": "ae",
};

function normalizeBase(value: string): string {
  const lowered = value.trim().toLowerCase();
  const withoutLigatures = [...lowered]
    .map((char) => LIGATURES[char] ?? char)
    .join("");
  return withoutLigatures
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_|_$/g, "");
}

export function normalizeIngredientStrictId(value: string): string {
  return normalizeBase(value);
}

export function normalizeIngredientCanonicalId(value: string): string {
  const strict = normalizeBase(value);
  if (!strict) return strict;

  const collapsed = strict
    .split("_")
    .filter((token) => token.length > 0 && !PREPARATION_TOKENS.has(token))
    .join("_")
    .replace(/^_|_$/g, "");

  return collapsed || strict;
}

/**
 * Retire le « s » final d'un mot d'au moins trois lettres.
 *
 * Règle unique de dépluralisation du projet, jumelle de `depluralizeToken`
 * dans `lib/core/utils/ingredient_name.dart`. La déduplication du parseur
 * CookLang fusionnait « tomate » et « tomates » avec sa propre copie de cette
 * règle, puis les cherchait sous deux identifiants différents.
 *
 * Volontairement naïve : « ananas » devient « anana ». Sans conséquence tant
 * qu'elle ne sert jamais à écrire un identifiant, seulement à en essayer un de
 * plus en dernier recours.
 */
export function depluralizeToken(token: string): string {
  return token.length > 2 && token.endsWith("s") ? token.slice(0, -1) : token;
}

/**
 * Identifiant singularisé : l'identifiant canonique dont chaque mot a perdu son
 * pluriel. Repli de lecture uniquement — voir `depluralizeToken`.
 */
export function normalizeIngredientSingularId(value: string): string {
  const canonical = normalizeIngredientCanonicalId(value);
  if (!canonical) return canonical;
  return canonical.split("_").map(depluralizeToken).join("_");
}

/**
 * Identifiants à essayer pour retrouver un ingrédient dans le référentiel, du
 * plus précis au plus général : strict, puis canonique, puis singularisé. Les
 * formes identiques sont éliminées en conservant cet ordre.
 */
export function buildIngredientLookupIds(value: string): string[] {
  const ids: string[] = [];
  for (const id of [
    normalizeIngredientStrictId(value),
    normalizeIngredientCanonicalId(value),
    normalizeIngredientSingularId(value),
  ]) {
    if (id && !ids.includes(id)) ids.push(id);
  }
  return ids;
}
