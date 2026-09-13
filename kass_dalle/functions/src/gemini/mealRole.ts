/**
 * Le rôle d'une recette dans un repas, et ce qu'elle apporte déjà.
 *
 * Un repas n'est pas une recette : une blanquette réclame un féculent à côté,
 * un couscous n'a besoin de rien, une tarte aux pommes se sert après. Les
 * types de plat historiques (`dish_types`) mélangent la protéine et la
 * structure et ne disent rien de tout cela. Trois champs le disent, une fois
 * pour toutes, sur la recette :
 *
 *  - `meal_role` — plat, accompagnement, entrée, dessert ou snack ;
 *  - `contains` — protéine, féculent, légume : ce que la recette apporte déjà ;
 *  - `suggested_sides` — pour un plat qui manque de féculent ou de légume,
 *    les accompagnements classiques, nommés simplement.
 *
 * Au modèle la reconnaissance, une fois par recette ; au programme la
 * composition, à chaque planning. Ce module porte ce qu'on demande au modèle
 * — le même texte dans la passe 2 de l'import et dans la suggestion de tags —
 * et la lecture de sa réponse, qui ne garde que les valeurs admises.
 *
 * Logique pure, testée par `tests/mealRole.test.ts`.
 */

export const MEAL_ROLES = ["plat", "accompagnement", "entree", "dessert", "snack"] as const;
export type MealRole = (typeof MEAL_ROLES)[number];

export const MEAL_COMPONENTS = ["proteine", "feculent", "legume"] as const;
export type MealComponent = (typeof MEAL_COMPONENTS)[number];

export interface MealRoleFields {
  mealRole: MealRole | null;
  contains: MealComponent[];
  suggestedSides: string[];
}

export const EMPTY_MEAL_ROLE_FIELDS: MealRoleFields = {
  mealRole: null,
  contains: [],
  suggestedSides: [],
};

/** Longueur maximale d'un nom d'accompagnement ; au-delà, c'est une phrase. */
const MAX_SIDE_LENGTH = 40;
/** Accompagnements gardés au plus : le programme n'en choisit qu'un par repas. */
const MAX_SIDES = 4;

/**
 * Ce qu'on demande au modèle, mot pour mot, partout où une recette se classe.
 *
 * Aucun exemple rempli : tout ce qui ressemble à une valeur finit recopié.
 * Les valeurs admises sont énumérées ; la forme attendue est décrite.
 */
export const MEAL_ROLE_PROMPT = `"meal_role" = le rôle de cette recette dans un repas, UNE seule valeur parmi :
plat | accompagnement | entree | dessert | snack
- "plat" : ce autour de quoi le repas s'organise (viande, poisson, œufs, plat mijoté, gratin, plat complet)
- "accompagnement" : ce qui se sert À CÔTÉ d'un plat (purée, riz cuisiné, légumes poêlés, frites, salade servie en garniture)
- "entree" : ce qui se sert avant le plat (soupe, salade, terrine, tarte salée en petite part)
- "dessert" : ce qui se sert après le plat (gâteau, tarte sucrée, mousse, glace, compote)
- "snack" : ce qui se mange seul, hors repas (goûter, en-cas, boisson, petit-déjeuner)

"contains" = ce que la recette apporte DÉJÀ, zéro à trois valeurs parmi : proteine | feculent | legume
- "proteine" : viande, volaille, poisson, fruits de mer, œufs, tofu, légumineuses en plat principal
- "feculent" : riz, pâtes, pommes de terre, semoule, pain, pâte à tarte, polenta, légumineuses en garniture
- "legume" : une vraie portion de légumes — pas les herbes, ni l'oignon d'un fond de sauce

"suggested_sides" = pour un "plat" à qui il manque un féculent ou un légume, deux ou trois accompagnements
classiques pour CE plat, en français, chacun en un nom court de garniture courante, sans quantité.
Tableau vide pour un plat complet, un accompagnement, une entrée, un dessert ou un snack.`;

/** Les clés JSON attendues, à recopier dans le format de sortie d'un prompt. */
export const MEAL_ROLE_JSON_KEYS = `"meal_role": "<plat | accompagnement | entree | dessert | snack>",
  "contains": ["<proteine | feculent | legume>"],
  "suggested_sides": ["<nom court d'une garniture courante>"]`;

/** Les signes diacritiques détachés par NFD (U+0300 à U+036F). */
const COMBINING_MARKS = new RegExp(
  "[" + String.fromCharCode(0x300) + "-" + String.fromCharCode(0x36f) + "]",
  "g",
);

/** Minuscules, sans accent, espaces réduits : la clé de comparaison. */
export function normalizeRoleKey(value: string): string {
  return value
    .normalize("NFD")
    .replace(COMBINING_MARKS, "")
    .toLowerCase()
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

const ROLE_ALIASES: Record<string, MealRole> = {
  plat: "plat",
  "plat principal": "plat",
  principal: "plat",
  main: "plat",
  "main course": "plat",
  "plat complet": "plat",
  accompagnement: "accompagnement",
  garniture: "accompagnement",
  side: "accompagnement",
  "side dish": "accompagnement",
  entree: "entree",
  starter: "entree",
  appetizer: "entree",
  dessert: "dessert",
  snack: "snack",
  "en cas": "snack",
  gouter: "snack",
  "petit dejeuner": "snack",
  breakfast: "snack",
  boisson: "snack",
  drink: "snack",
};

const COMPONENT_ALIASES: Record<string, MealComponent> = {
  proteine: "proteine",
  proteines: "proteine",
  protein: "proteine",
  proteins: "proteine",
  feculent: "feculent",
  feculents: "feculent",
  starch: "feculent",
  starches: "feculent",
  legume: "legume",
  legumes: "legume",
  vegetable: "legume",
  vegetables: "legume",
};

/** Le rôle, ou `null` si la valeur n'est pas parmi celles admises. */
export function parseMealRole(value: unknown): MealRole | null {
  if (typeof value !== "string") return null;
  return ROLE_ALIASES[normalizeRoleKey(value)] ?? null;
}

/** Les composants reconnus, dans l'ordre de `MEAL_COMPONENTS`, une fois chacun. */
export function parseMealContains(value: unknown): MealComponent[] {
  if (!Array.isArray(value)) return [];
  const found = new Set<MealComponent>();
  for (const v of value) {
    if (typeof v !== "string") continue;
    const component = COMPONENT_ALIASES[normalizeRoleKey(v)];
    if (component) found.add(component);
  }
  return MEAL_COMPONENTS.filter((c) => found.has(c));
}

/**
 * Les accompagnements, nettoyés : chaînes non vides, courtes, une fois
 * chacune quel que soit l'accent ou la casse, quatre au plus.
 */
export function parseSuggestedSides(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const seen = new Set<string>();
  const out: string[] = [];
  for (const v of value) {
    if (typeof v !== "string") continue;
    const side = v.trim().replace(/\s+/g, " ");
    if (side.length === 0 || side.length > MAX_SIDE_LENGTH) continue;
    const key = normalizeRoleKey(side);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(side);
    if (out.length >= MAX_SIDES) break;
  }
  return out;
}

/**
 * Lit les trois champs dans la réponse du modèle.
 *
 * Sans rôle reconnu, rien n'est gardé : un « contains » sans rôle ne dit pas
 * à quoi il s'applique. Les accompagnements n'ont de sens que pour un plat.
 */
export function parseMealRoleFields(json: Record<string, unknown>): MealRoleFields {
  const mealRole = parseMealRole(json.meal_role);
  if (mealRole == null) return { ...EMPTY_MEAL_ROLE_FIELDS };
  return {
    mealRole,
    contains: parseMealContains(json.contains),
    suggestedSides: mealRole === "plat" ? parseSuggestedSides(json.suggested_sides) : [],
  };
}

/**
 * Vrai si un plat appelle un accompagnement : il lui manque un féculent ou un
 * légume. Un accompagnement, une entrée, un dessert n'en appellent jamais.
 */
export function needsSide(fields: Pick<MealRoleFields, "mealRole" | "contains">): boolean {
  if (fields.mealRole !== "plat") return false;
  return !fields.contains.includes("feculent") || !fields.contains.includes("legume");
}
