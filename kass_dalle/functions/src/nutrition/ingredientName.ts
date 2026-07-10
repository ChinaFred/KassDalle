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

function normalizeBase(value: string): string {
  return value
    .trim()
    .toLowerCase()
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
