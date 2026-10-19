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
 *    les accompagnements classiques, nommés simplement ;
 *  - `main_protein`, `main_starch` — pour un plat ou un accompagnement, la
 *    protéine et le féculent principaux, que la présélection du planning lit
 *    pour varier le cycle (`proteinOf`, `starchOf` dans `planning.ts`).
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

/**
 * Protéine principale d'un plat ou d'un accompagnement. Même ordre que
 * `main_proteins` dans `test-fixtures/meal_roles.json` : le client les affiche.
 */
export const MAIN_PROTEINS = [
  "boeuf",
  "porc",
  "volaille",
  "agneau",
  "poisson",
  "fruits_de_mer",
  "oeuf",
  "vegetarien",
  "legumineuses",
] as const;
export type MainProtein = (typeof MAIN_PROTEINS)[number];

/** Féculent principal. « aucun » est une valeur : la recette n'en porte pas. */
export const MAIN_STARCHES = [
  "pates",
  "riz",
  "pommes_de_terre",
  "semoule",
  "pain",
  "aucun",
] as const;
export type MainStarch = (typeof MAIN_STARCHES)[number];

/** Seuls ces rôles portent une protéine et un féculent principaux. */
export const ROLES_WITH_MAIN_INGREDIENTS: readonly MealRole[] = ["plat", "accompagnement"];

export interface MainProteinStarch {
  mainProtein: MainProtein | null;
  mainStarch: MainStarch | null;
  /**
   * Vrai quand le modèle a répondu à la question : au moins une des deux clés
   * porte une chaîne non vide, admise ou non. « veau » est une réponse — la
   * recette est examinée et ne sera pas requestionnée. Deux chaînes vides ou
   * des clés absentes ne sont pas une réponse. Les écrivains posent alors
   * `tags.main_ingredients_checked_at`.
   */
  mainIngredientsChecked: boolean;
}

export interface MealRoleFields extends MainProteinStarch {
  mealRole: MealRole | null;
  contains: MealComponent[];
  suggestedSides: string[];
}

export const EMPTY_MEAL_ROLE_FIELDS: MealRoleFields = {
  mealRole: null,
  contains: [],
  suggestedSides: [],
  mainProtein: null,
  mainStarch: null,
  mainIngredientsChecked: false,
};

/** Longueur maximale d'un nom d'accompagnement ; au-delà, c'est une phrase. */
const MAX_SIDE_LENGTH = 40;
/** Accompagnements gardés au plus : le programme n'en choisit qu'un par repas. */
const MAX_SIDES = 4;

/**
 * La protéine et le féculent principaux, mot pour mot, dans le prompt du rôle.
 *
 * Une valeur hors liste est lue comme absente, jamais rangée dans une valeur
 * voisine : le prompt demande donc de laisser vide ce qui ne rentre pas.
 */
export const MAIN_PROTEIN_STARCH_PROMPT = `"main_protein" = pour un "plat" ou un "accompagnement" seulement, la protéine principale, UNE valeur parmi :
boeuf | porc | volaille | agneau | poisson | fruits_de_mer | oeuf | vegetarien | legumineuses
- "volaille" : poulet, dinde, canard, pintade
- "fruits_de_mer" : crevettes, moules, coquillages, calamars
- "oeuf" : un plat dont les œufs sont la protéine principale (omelette, œufs cocotte)
- "legumineuses" : lentilles, pois chiches, haricots secs au cœur du plat
- "vegetarien" : ni viande, ni poisson, ni fruits de mer, ni œuf, ni légumineuses au cœur du plat
- une viande absente de la liste (veau, lapin, gibier) : chaîne vide

"main_starch" = pour un "plat" ou un "accompagnement" seulement, le féculent principal, UNE valeur parmi :
pates | riz | pommes_de_terre | semoule | pain | aucun
- "aucun" : la recette ne contient pas de féculent
- un autre féculent (polenta, quinoa, pâte à tarte) : chaîne vide

Pour une "entree", un "dessert" ou un "snack" : "main_protein" et "main_starch" vides.`;

/** Les deux clés JSON de la protéine et du féculent. */
export const MAIN_PROTEIN_STARCH_JSON_KEYS = `"main_protein": "<boeuf | porc | volaille | agneau | poisson | fruits_de_mer | oeuf | vegetarien | legumineuses>",
  "main_starch": "<pates | riz | pommes_de_terre | semoule | pain | aucun>"`;

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
Tableau vide pour un plat complet, un accompagnement, une entrée, un dessert ou un snack.

${MAIN_PROTEIN_STARCH_PROMPT}`;

/** Les clés JSON attendues, à recopier dans le format de sortie d'un prompt. */
export const MEAL_ROLE_JSON_KEYS = `"meal_role": "<plat | accompagnement | entree | dessert | snack>",
  "contains": ["<proteine | feculent | legume>"],
  "suggested_sides": ["<nom court d'une garniture courante>"],
  ${MAIN_PROTEIN_STARCH_JSON_KEYS}`;

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

/**
 * La protéine et le féculent à écrire, sans le marqueur : seulement les champs
 * absents de la recette. Une valeur déjà posée — à la main ou par un autre
 * chemin — n'est jamais remplacée.
 */
export function mainIngredientsPatch(
  existingTags: Record<string, unknown>,
  fields: Pick<MainProteinStarch, "mainProtein" | "mainStarch">,
): { main_protein?: MainProtein; main_starch?: MainStarch } {
  const absent = (v: unknown) => typeof v !== "string" || v.trim().length === 0;
  return {
    ...(fields.mainProtein && absent(existingTags.main_protein)
      ? { main_protein: fields.mainProtein }
      : {}),
    ...(fields.mainStarch && absent(existingTags.main_starch)
      ? { main_starch: fields.mainStarch }
      : {}),
  };
}

/**
 * Vrai quand ce que la recette apporte (`tags.contains`) a été corrigé à la
 * main : le client pose `tags.contains_manual = true`, booléen strict. Une
 * autre valeur, une chaîne `"true"` comprise, n'est pas une correction.
 * Cas verrouillés par `contains_manual_cases` de `test-fixtures/meal_roles.json`.
 */
export function isContainsManual(existingTags: Record<string, unknown>): boolean {
  return existingTags.contains_manual === true;
}

/**
 * `contains` à écrire : celui du modèle, sauf si la recette porte une
 * correction à la main. Rien alors : le modèle ne réécrit jamais ce que
 * l'utilisateur a corrigé, ni au classement, ni au backfill forcé.
 */
export function containsPatch(
  existingTags: Record<string, unknown>,
  contains: MealComponent[],
): { contains?: MealComponent[] } {
  return isContainsManual(existingTags) ? {} : { contains };
}

/**
 * Variantes d'écriture admises : accent, pluriel, ligature, espace au lieu du
 * tiret bas. Aucun synonyme de sens (« poulet », « veau ») : une valeur
 * voisine rangée par le code serait une valeur inventée.
 */
const PROTEIN_ALIASES: Record<string, MainProtein> = {
  boeuf: "boeuf",
  bœuf: "boeuf",
  porc: "porc",
  volaille: "volaille",
  volailles: "volaille",
  agneau: "agneau",
  poisson: "poisson",
  poissons: "poisson",
  "fruits de mer": "fruits_de_mer",
  oeuf: "oeuf",
  oeufs: "oeuf",
  œuf: "oeuf",
  œufs: "oeuf",
  vegetarien: "vegetarien",
  legumineuses: "legumineuses",
  legumineuse: "legumineuses",
};

const STARCH_ALIASES: Record<string, MainStarch> = {
  pates: "pates",
  pate: "pates",
  riz: "riz",
  "pommes de terre": "pommes_de_terre",
  "pomme de terre": "pommes_de_terre",
  semoule: "semoule",
  pain: "pain",
  aucun: "aucun",
  aucune: "aucun",
};

/** La protéine principale, ou `null` hors liste. */
export function parseMainProtein(value: unknown): MainProtein | null {
  if (typeof value !== "string") return null;
  return ownAlias(PROTEIN_ALIASES, normalizeRoleKey(value));
}

/** Le féculent principal, ou `null` hors liste. */
export function parseMainStarch(value: unknown): MainStarch | null {
  if (typeof value !== "string") return null;
  return ownAlias(STARCH_ALIASES, normalizeRoleKey(value));
}

/**
 * Les deux champs, sans regarder le rôle : `parseMealRoleFields` ne l'appelle
 * que pour un plat ou un accompagnement.
 */
export function parseMainProteinStarch(json: Record<string, unknown>): MainProteinStarch {
  const answered = (v: unknown) => typeof v === "string" && v.trim().length > 0;
  return {
    mainProtein: parseMainProtein(json.main_protein),
    mainStarch: parseMainStarch(json.main_starch),
    mainIngredientsChecked: answered(json.main_protein) || answered(json.main_starch),
  };
}

/**
 * Lit une table d'alias sur ses propres clés seulement. Un accès direct
 * `table[cle]` rendait `Object` pour « constructor » : une réponse du modèle
 * devenait un rôle.
 */
function ownAlias<T>(table: Record<string, T>, key: string): T | null {
  return Object.prototype.hasOwnProperty.call(table, key) ? table[key] : null;
}

/** Le rôle, ou `null` si la valeur n'est pas parmi celles admises. */
export function parseMealRole(value: unknown): MealRole | null {
  if (typeof value !== "string") return null;
  return ownAlias(ROLE_ALIASES, normalizeRoleKey(value));
}

/** Les composants reconnus, dans l'ordre de `MEAL_COMPONENTS`, une fois chacun. */
export function parseMealContains(value: unknown): MealComponent[] {
  if (!Array.isArray(value)) return [];
  const found = new Set<MealComponent>();
  for (const v of value) {
    if (typeof v !== "string") continue;
    const component = ownAlias(COMPONENT_ALIASES, normalizeRoleKey(v));
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
 * à quoi il s'applique. Les accompagnements n'ont de sens que pour un plat ;
 * la protéine et le féculent, que pour un plat ou un accompagnement.
 */
export function parseMealRoleFields(json: Record<string, unknown>): MealRoleFields {
  const mealRole = parseMealRole(json.meal_role);
  if (mealRole == null) return { ...EMPTY_MEAL_ROLE_FIELDS };
  const main = ROLES_WITH_MAIN_INGREDIENTS.includes(mealRole)
    ? parseMainProteinStarch(json)
    : { mainProtein: null, mainStarch: null, mainIngredientsChecked: false };
  return {
    mealRole,
    contains: parseMealContains(json.contains),
    suggestedSides: mealRole === "plat" ? parseSuggestedSides(json.suggested_sides) : [],
    ...main,
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
