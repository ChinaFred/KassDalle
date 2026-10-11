/**
 * Allergènes majeurs — vocabulaire et calcul, sans Firestore ni modèle.
 *
 * Les quatorze allergènes de l'annexe II du règlement INCO (UE n° 1169/2011),
 * dans l'ordre du règlement. Les clés sont reprises par le client
 * (`lib/features/recipes/domain/allergens.dart`) pour l'affichage ; la
 * fixture `test-fixtures/allergens.json` verrouille les deux listes.
 *
 * Le jugement « cet ingrédient contient-il du lait ? » est rendu par le modèle,
 * une fois par ingrédient du référentiel (`nutrition_ingredients.allergens`).
 * Le champ `allergens` d'une recette se DÉDUIT de ces jugements, sans appel :
 * c'est `computeRecipeAllergens`, serveur seul.
 */

import { buildIngredientLookupIds } from "./ingredientName";

/** Les quatorze clés, dans l'ordre du règlement. */
export const ALLERGEN_KEYS = [
  "gluten",
  "crustaces",
  "oeuf",
  "poisson",
  "arachide",
  "soja",
  "lait",
  "fruits_a_coque",
  "celeri",
  "moutarde",
  "sesame",
  "sulfites",
  "lupin",
  "mollusques",
] as const;

export type AllergenKey = (typeof ALLERGEN_KEYS)[number];

/** Libellés affichés, et cités dans le prompt. */
export const ALLERGEN_LABELS: Readonly<Record<AllergenKey, string>> = {
  gluten: "Gluten",
  crustaces: "Crustacés",
  oeuf: "Œuf",
  poisson: "Poisson",
  arachide: "Arachide",
  soja: "Soja",
  lait: "Lait",
  fruits_a_coque: "Fruits à coque",
  celeri: "Céleri",
  moutarde: "Moutarde",
  sesame: "Sésame",
  sulfites: "Sulfites",
  lupin: "Lupin",
  mollusques: "Mollusques",
};

/** Exemples donnés au modèle pour chaque clé. Prompt seul, pas d'affichage. */
export const ALLERGEN_EXAMPLES: Readonly<Record<AllergenKey, string>> = {
  gluten:
    "farine de blé, seigle, orge, avoine, épeautre, chapelure, pâtes, pain, semoule, boulgour, pâte feuilletée ou brisée, bière, sauce soja",
  crustaces: "crevette, langoustine, homard, crabe, écrevisse",
  oeuf: "œuf, jaune, blanc, mayonnaise, pâtes aux œufs, meringue",
  poisson: "tout poisson, anchois, nuoc-mâm, sauce Worcestershire, surimi",
  arachide: "cacahuète, beurre de cacahuète, huile d'arachide",
  soja: "sauce soja, tofu, edamame, miso, lécithine de soja",
  lait: "lait, beurre, crème, fromage, yaourt, lactosérum, chocolat au lait",
  fruits_a_coque: "amande, noisette, noix, cajou, pécan, pistache, macadamia, praliné, frangipane",
  celeri: "céleri branche ou rave, sel de céleri, bouillon cube",
  moutarde: "moutarde, graines de moutarde, vinaigrette du commerce",
  sesame: "graines de sésame, tahini, huile de sésame, houmous",
  sulfites: "vin, vinaigre de vin, porto, abricots secs, cidre",
  lupin: "farine de lupin",
  mollusques: "moule, huître, calamar, poulpe, Saint-Jacques, escargot, sauce d'huître",
};

const KEY_SET: ReadonlySet<string> = new Set(ALLERGEN_KEYS);

/** Vrai pour une des quatorze clés, et pour elle seule (`__proto__` compris). */
export function isAllergenKey(value: unknown): value is AllergenKey {
  return typeof value === "string" && KEY_SET.has(value);
}

/** Clés dans l'ordre du règlement, sans doublon. */
export function sortAllergenKeys(keys: Iterable<AllergenKey>): AllergenKey[] {
  const wanted = new Set(keys);
  return ALLERGEN_KEYS.filter((key) => wanted.has(key));
}

/**
 * Sépare une liste reçue — du modèle ou du référentiel — en clés connues,
 * triées et dédoublonnées, et en valeurs écartées. Les valeurs écartées sont
 * rendues pour être journalisées : une clé hors liste n'est jamais devinée.
 *
 * `null` quand la valeur n'est pas une liste : « jamais examiné », à ne pas
 * confondre avec `[]`, « examiné, aucun ».
 */
export function sanitizeAllergenList(
  value: unknown,
): { keys: AllergenKey[]; rejected: string[] } | null {
  if (!Array.isArray(value)) return null;
  const kept: AllergenKey[] = [];
  const rejected: string[] = [];
  for (const raw of value) {
    const key = typeof raw === "string" ? raw.trim().toLowerCase() : raw;
    if (isAllergenKey(key)) kept.push(key);
    else rejected.push(typeof raw === "string" ? raw : JSON.stringify(raw));
  }
  return { keys: sortAllergenKeys(kept), rejected };
}

/** Une réponse du modèle pour un ingrédient du lot, par position dans le lot. */
export interface AllergenAnswer {
  index: number;
  keys: AllergenKey[];
  rejected: string[];
}

/**
 * Lit la réponse du modèle pour un lot de `batchSize` ingrédients.
 *
 * `null` quand la forme n'est pas `{ ingredients: [...] }` : le lot entier est
 * alors en échec, et rien n'est posé. Une entrée illisible — identifiant hors
 * du lot, `allergens` absent ou pas une liste — est sautée : cet ingrédient
 * reste « jamais examiné », et sera redemandé. Un identifiant répété garde sa
 * première réponse.
 */
export function parseAllergenBatchAnswer(
  parsed: unknown,
  batchSize: number,
): AllergenAnswer[] | null {
  if (!parsed || typeof parsed !== "object") return null;
  const list = (parsed as { ingredients?: unknown }).ingredients;
  if (!Array.isArray(list)) return null;

  const out: AllergenAnswer[] = [];
  const seen = new Set<number>();
  for (const entry of list) {
    if (!entry || typeof entry !== "object") continue;
    const record = entry as Record<string, unknown>;
    const rawId = record.id;
    if (typeof rawId !== "string" && typeof rawId !== "number") continue;
    const text = String(rawId).trim();
    if (!/^\d+$/.test(text)) continue;
    const index = Number(text);
    if (index >= batchSize || seen.has(index)) continue;
    const sanitized = sanitizeAllergenList(record.allergens);
    if (!sanitized) continue;
    seen.add(index);
    out.push({ index, keys: sanitized.keys, rejected: sanitized.rejected });
  }
  return out;
}

/** Le champ `allergens` d'une recette, sans son horodatage. */
export interface RecipeAllergens {
  present: AllergenKey[];
  complete: boolean;
  by_ingredient: Partial<Record<AllergenKey, string[]>>;
}

/**
 * Union des allergènes des ingrédients d'une recette.
 *
 * `lookup(name)` rend les clés de l'ingrédient, ou `null` s'il n'a jamais été
 * examiné. Un seul ingrédient non examiné rend le résultat incomplet ; une
 * recette sans ingrédient nommé aussi — « aucun allergène » ne se déduit pas
 * d'une liste vide. Les noms sont ceux de la recette, sans doublon, dans
 * l'ordre où elle les cite.
 */
export function computeRecipeAllergens(
  ingredientNames: readonly string[],
  lookup: (name: string) => readonly AllergenKey[] | null,
): RecipeAllergens {
  const names: string[] = [];
  for (const raw of ingredientNames) {
    const name = (raw ?? "").trim();
    if (name && !names.includes(name)) names.push(name);
  }

  let complete = names.length > 0;
  const byKey = new Map<AllergenKey, string[]>();
  for (const name of names) {
    const keys = lookup(name);
    if (keys == null) {
      complete = false;
      continue;
    }
    for (const key of keys) {
      const list = byKey.get(key) ?? [];
      if (!list.includes(name)) list.push(name);
      byKey.set(key, list);
    }
  }

  const present = sortAllergenKeys(byKey.keys());
  const by_ingredient: Partial<Record<AllergenKey, string[]>> = {};
  for (const key of present) by_ingredient[key] = byKey.get(key) ?? [];
  return { present, complete, by_ingredient };
}

/**
 * Forme comparable d'un champ `allergens`, horodatage exclu : deux calculs
 * identiques ne réécrivent pas la recette.
 */
export function recipeAllergensSignature(value: unknown): string {
  if (!value || typeof value !== "object") return "";
  const record = value as Record<string, unknown>;
  const present = Array.isArray(record.present)
    ? record.present.filter((k): k is string => typeof k === "string")
    : [];
  const byRaw = (
    record.by_ingredient && typeof record.by_ingredient === "object" ? record.by_ingredient : {}
  ) as Record<string, unknown>;
  const by = present.map((key) => {
    const names = byRaw[key];
    return [
      key,
      Array.isArray(names) ? names.filter((n): n is string => typeof n === "string") : [],
    ];
  });
  return JSON.stringify([present, record.complete === true, by]);
}

/**
 * Allergènes d'un ingrédient nommé, lus dans des documents du référentiel déjà
 * chargés (indexés par identifiant).
 *
 * Même identité que la nutrition et le produit acheté : les identifiants de
 * `buildIngredientLookupIds`, du plus précis au plus général. Le premier
 * document qui PORTE le champ décide, même vide — un « aucun allergène » posé
 * par l'admin sur « beurre doux » n'est pas contredit par le « beurre »
 * général. Un document sans le champ laisse la main au suivant. `null` quand
 * aucun ne le porte : l'ingrédient n'a jamais été examiné.
 */
export function allergensFromReferential(
  name: string,
  docs: ReadonlyMap<string, Record<string, unknown>>,
): AllergenKey[] | null {
  for (const id of buildIngredientLookupIds(name)) {
    const doc = docs.get(id);
    if (!doc) continue;
    const sanitized = sanitizeAllergenList(doc.allergens);
    if (sanitized) return sanitized.keys;
  }
  return null;
}
