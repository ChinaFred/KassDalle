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

export function buildIngredientLookupIds(value: string): string[] {
  const strict = normalizeIngredientStrictId(value);
  const canonical = normalizeIngredientCanonicalId(value);
  if (!strict && !canonical) return [];
  if (!strict) return [canonical];
  if (!canonical || canonical === strict) return [strict];
  return [strict, canonical];
}
