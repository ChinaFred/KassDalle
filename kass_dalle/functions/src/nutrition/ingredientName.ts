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

/** Le seul sous-ensemble de `PREPARATION_TOKENS` qui reste neutre pour une viande. */
const HACHE_TOKENS = new Set<string>(["hache", "hachee", "haches", "hachees"]);

/**
 * Viandes pour lesquelles « haché » change le produit, pas seulement la coupe.
 *
 * « persil haché » et « persil » sont le même achat : couper une herbe ne
 * change rien à sa valeur nutritionnelle, et c'est pour ce cas que
 * `PREPARATION_TOKENS` existe. Pour une viande, « haché » désigne un produit
 * du boucher à part entière, avec son propre taux de matière grasse — souvent
 * plus élevé qu'une coupe entière. Fusionner « porc haché » et « porc » sous
 * un même identifiant a donné le même chiffre de calories aux deux, faux pour
 * l'un comme pour l'autre. Ces bases gardent donc « haché » dans leur
 * identifiant canonique ; les autres mots de préparation (émincé, râpé,
 * coupé, ciselé) restent neutres même pour elles.
 */
const MEAT_BASE_TOKENS = new Set<string>([
  "porc",
  "boeuf",
  "veau",
  "agneau",
  "mouton",
  "poulet",
  "dinde",
  "canard",
  "oie",
  "lapin",
  "cheval",
  "pintade",
  "caille",
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
  const withoutLigatures = [...lowered].map((char) => LIGATURES[char] ?? char).join("");
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

  const tokens = strict.split("_").filter((token) => token.length > 0);
  // Les mots de préparation neutres partent toujours, « haché » y compris
  // pour l'instant : il ne revient que si la base restante est une viande.
  const withoutNeutralPrep = tokens.filter(
    (token) => !PREPARATION_TOKENS.has(token) || HACHE_TOKENS.has(token),
  );
  const baseTokens = withoutNeutralPrep.filter((token) => !HACHE_TOKENS.has(token));
  const hasHache = withoutNeutralPrep.length > baseTokens.length;
  const isMeat = baseTokens.length === 1 && MEAT_BASE_TOKENS.has(baseTokens[0]);

  const kept = isMeat && hasHache ? withoutNeutralPrep : baseTokens;
  const collapsed = kept.join("_").replace(/^_|_$/g, "");

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
