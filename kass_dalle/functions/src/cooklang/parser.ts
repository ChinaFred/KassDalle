/**
 * Parseur CookLang minimal — porté depuis lib/core/services/cooklang_parser.dart.
 *
 * Extrait les métadonnées, ingrédients (avec quantités/unités/catégories),
 * titre, portions, tags et type de page depuis un bloc CookLang.
 */

import { depluralizeToken } from "../nutrition/ingredientName";

export interface CookLangIngredient {
  name: string;
  qty: string;
  unit: string;
  category?: string | null;
}

export interface CookLangTags {
  difficulty?: string | null;
  prepTime?: number | null;
  cookTime?: number | null;
  /** Marinade, réfrigération, levée : l'attente qu'on ne passe pas à cuisiner. */
  restTime?: number | null;
  dishTypes: string[];
}

export type CookLangPageType = "recipe" | "technique" | "equipment" | "ingredient_note" | "other";

export function parseMeta(cooklang: string): Map<string, string> {
  const meta = new Map<string, string>();
  for (const line of cooklang.split("\n")) {
    const t = line.trim();
    if (!t.startsWith(">>")) continue;
    const content = t.substring(2);
    const colon = content.indexOf(":");
    if (colon > 0) {
      meta.set(
        content.substring(0, colon).trim().toLowerCase(),
        content.substring(colon + 1).trim(),
      );
    }
  }
  return meta;
}

function isTemperatureLike(name: string): boolean {
  const n = name.trim().toLowerCase();
  return n.includes("°") || /^\d/.test(n);
}

function ingredientKey(name: string): string {
  const accents: Record<string, string> = {
    à: "a",
    â: "a",
    é: "e",
    è: "e",
    ê: "e",
    ë: "e",
    î: "i",
    ï: "i",
    ô: "o",
    ö: "o",
    ù: "u",
    û: "u",
    ü: "u",
    ç: "c",
    æ: "ae",
    œ: "oe",
    "\u2019": "'",
    "\u2018": "'",
    "\u02BC": "'",
  };
  const s = name.toLowerCase().replace(/./g, (c) => accents[c] ?? c);
  return s.split(" ").map(depluralizeToken).join(" ");
}

/**
 * Index de recherche d'une recette : les noms de ses ingrédients structurés, en
 * minuscules, sans doublon, dans l'ordre d'apparition.
 *
 * Jumeau de `buildIngredientsIndex` dans `lib/core/services/cooklang_parser.dart`.
 * Écrivain unique de `ingredients_index` côté backend : le pipeline le dérivait
 * du CookLang brut pendant que le client le dérivait des ingrédients normalisés
 * par le référentiel, si bien qu'une recette réenregistrée changeait d'index.
 */
export function buildIngredientsIndex(ingredients: CookLangIngredient[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const ingredient of ingredients) {
    const name = ingredient.name.trim().toLowerCase();
    if (!name || seen.has(name)) continue;
    seen.add(name);
    result.push(name);
  }
  return result;
}

/** Extrait la liste structurée des ingrédients (par ordre d'apparition, dédupliquée). */
export function extractIngredientsStructured(cooklang: string): CookLangIngredient[] {
  const re = /@([^{@#~\n]+)\{([^}]*)\}/g;
  const indexMap = new Map<string, number>();
  const result: CookLangIngredient[] = [];
  let currentCategory: string | null = null;

  for (const line of cooklang.split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("--") || t.startsWith(">>") || t.startsWith(">")) continue;
    if (t.startsWith("==")) {
      const name = t.replaceAll("==", "").trim();
      currentCategory = name || null;
      continue;
    }
    let m: RegExpExecArray | null;
    re.lastIndex = 0;
    while ((m = re.exec(t)) !== null) {
      const name = m[1].trim();
      if (isTemperatureLike(name)) continue;
      const nameKey = ingredientKey(name);
      // Clé de déduplication sensible à la section : le même ingrédient dans
      // deux sections différentes (ex : sauce soja pour la garniture ET pour
      // la sauce) doit apparaître deux fois dans la liste.
      const dedupeKey = `${currentCategory ?? ""}::${nameKey}`;
      const parts = (m[2] ?? "").split("%");
      const qty = parts[0]?.trim() ?? "";
      const unit = parts[1]?.trim() ?? "";
      if (indexMap.has(dedupeKey)) {
        const idx = indexMap.get(dedupeKey)!;
        const existing = result[idx];
        // Si la nouvelle occurrence a une quantité DIFFÉRENTE de celle déjà connue,
        // c'est un usage distinct dans la même section (ex : sauce soja dans la
        // garniture ET dans la sauce sans section séparée). On crée une entrée
        // supplémentaire plutôt que de la supprimer.
        if (qty && existing.qty && qty !== existing.qty) {
          const altKey = `${dedupeKey}|${qty}${unit}`;
          if (!indexMap.has(altKey)) {
            indexMap.set(altKey, result.length);
            result.push({ name, qty, unit, category: currentCategory });
          }
        } else {
          // Même quantité ou l'une des deux est vide : garder la première
          // (typiquement la déclaration en liste d'ingrédients).
          if (!existing.qty && qty) {
            result[idx] = {
              name: existing.name,
              qty,
              unit: existing.unit || unit,
              category: existing.category,
            };
          } else if (!existing.unit && unit) {
            result[idx] = {
              name: existing.name,
              qty: existing.qty,
              unit,
              category: existing.category,
            };
          }
        }
      } else {
        indexMap.set(dedupeKey, result.length);
        result.push({ name, qty, unit, category: currentCategory });
      }
    }
  }
  return result;
}

/** Liste des noms d'ingrédients (pour ingredients_index Firestore). */
export function extractIngredientNames(cooklang: string): string[] {
  const re = /@([^{@#~\n]+)(?:\{[^}]*\})?/g;
  const seen = new Set<string>();
  const result: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(cooklang)) !== null) {
    const name = m[1].trim().toLowerCase();
    if (isTemperatureLike(name)) continue;
    if (!seen.has(name)) {
      seen.add(name);
      result.push(name);
    }
  }
  return result;
}

export function extractTitle(cooklang: string): string {
  const meta = parseMeta(cooklang);
  return meta.get("titre") ?? meta.get("title") ?? meta.get("nom") ?? "Recette sans titre";
}

export function extractPortions(cooklang: string): number | null {
  const meta = parseMeta(cooklang);
  const raw = meta.get("portions") ?? meta.get("servings");
  if (!raw) return null;
  const n = parseInt(raw.split(" ")[0], 10);
  return Number.isFinite(n) ? n : null;
}

export function extractPageNumber(cooklang: string): number | null {
  const meta = parseMeta(cooklang);
  const raw = meta.get("page") ?? meta.get("page_number");
  if (!raw) return null;
  const n = parseInt(raw.trim().split(" ")[0], 10);
  return Number.isFinite(n) ? n : null;
}

/**
 * Combien de minutes vaut une unité, selon le mot qui suit le nombre.
 *
 * `null` marque les secondes, converties à part : elles ne valent pas un nombre
 * entier de minutes.
 *
 * Une nuit vaut douze heures. Ce n'est pas une mesure, c'est la convention des
 * livres : « laisser mariner une nuit » veut dire du soir au matin, et douze
 * heures est ce que tout le monde entend. Mieux vaut cette valeur assumée qu'un
 * champ vide sur la moitié des marinades.
 */
const MINUTES_PAR_UNITE: Array<[readonly string[], number]> = [
  [["h", "hr", "hrs", "heure", "heures"], 60],
  [["j", "jour", "jours"], 1440],
  [["nuit", "nuits"], 720],
  [["m", "mn", "min", "mins", "minute", "minutes"], 1],
];

const UNITES_SECONDES = new Set(["s", "sec", "secs", "seconde", "secondes"]);

/**
 * Lit une durée écrite en toutes lettres, en minutes.
 *
 * **Le premier nombre, l'unité qui le suit immédiatement, et rien d'autre.**
 *
 * La version précédente prenait le premier nombre puis multipliait par soixante
 * dès qu'un `h` traînait quelque part dans la chaîne. « 55 min, plus 4 h de
 * réfrigération » rendait 3 300 minutes ; « 30 min de chauffe » en rendait
 * 1 800, parce que « chauffe » porte un `h`. Aucune erreur levée, un chiffre
 * absurde affiché comme un temps de préparation.
 *
 * Ce qui suit la première durée n'appartient pas à ce champ : c'est une autre
 * durée, et elle a le sien. Une phrase qui en contient deux rend donc la
 * première, ce qui est le comportement voulu.
 *
 * Jumeau de `parseTimeToMinutes` dans `lib/core/services/cooklang_parser.dart`,
 * asservi par `test-fixtures/cooklang_parsing.json` (section `durations`).
 */
export function parseTimeToMinutes(raw: string | undefined | null): number | null {
  if (!raw || !raw.trim()) return null;
  const text = raw.toLowerCase().trim();

  // Le premier nombre, puis le mot qui le suit immédiatement — espaces admis
  // entre les deux, rien d'autre.
  const match = text.match(/(\d+)\s*([a-zà-ÿ]*)/);
  if (!match) return null;
  const value = parseInt(match[1], 10);
  if (!Number.isFinite(value)) return null;

  const mot = match[2];
  if (UNITES_SECONDES.has(mot)) {
    // Moins d'une minute compte pour une : zéro se lirait « pas de durée ».
    return Math.max(1, Math.round(value / 60));
  }

  const unite = MINUTES_PAR_UNITE.find(([mots]) => mots.includes(mot));
  // Sans unité reconnue, un nombre nu se lit en minutes : c'est ce qu'écrivent
  // les métadonnées de l'application elle-même (`>> temps_preparation: 20`).
  if (!unite) return value;

  const minutes = value * unite[1];
  if (unite[1] !== 60) return minutes;

  // « 4 h 55 » : le nombre qui suit immédiatement l'heure en est les minutes.
  // Il doit suivre l'unité sans rien entre les deux — une virgule ou un mot
  // ouvre une AUTRE durée, qui ne s'additionne pas à celle-ci.
  const reste = text.slice(match.index! + match[0].length);
  const suite = reste.match(/^\s*(\d+)/);
  return suite ? minutes + parseInt(suite[1], 10) : minutes;
}

function parseCsvList(raw: string | undefined): string[] {
  if (!raw || !raw.trim()) return [];
  return raw
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter((s) => s.length > 0);
}

export function extractTags(cooklang: string): CookLangTags {
  const meta = parseMeta(cooklang);
  return {
    difficulty: meta.get("difficulte") ?? meta.get("difficulté") ?? meta.get("difficulty") ?? null,
    prepTime: parseTimeToMinutes(
      meta.get("temps_preparation") ?? meta.get("temps_préparation") ?? meta.get("prep_time"),
    ),
    cookTime: parseTimeToMinutes(
      meta.get("temps_cuisson") ?? meta.get("cook_time") ?? meta.get("cuisson"),
    ),
    // Trois alias, dans cet ordre, et le MÊME ordre côté Dart. Une clé acceptée
    // d'un seul côté rendrait un repos ici et pas là, sans qu'aucune erreur ne
    // sorte — c'est la panne déjà rencontrée sur le type de page.
    restTime: parseTimeToMinutes(
      meta.get("temps_repos") ?? meta.get("rest_time") ?? meta.get("repos"),
    ),
    dishTypes: parseCsvList(meta.get("dish_types")),
  };
}

/**
 * Interprète un libellé de type de page, d'où qu'il vienne : champ Firestore
 * `page_type` ou métadonnée CookLang `>> page_type:`.
 *
 * Jumeau de `parsePageTypeLabel` dans `lib/core/services/cooklang_parser.dart`.
 * Les formes acceptées pour la note d'ingrédient sont les trois qui circulent
 * réellement — souligné (Firestore), espace (saisie humaine) et camelCase
 * (`PageType.name` côté Dart) — parce que chacune était acceptée par un seul
 * des lecteurs, et qu'une page changeait donc de type selon qui la lisait.
 *
 * Un libellé inconnu vaut `recipe` : mieux vaut une page traitée comme une
 * recette qu'une page qu'on refuse de lire.
 */
export function parsePageTypeLabel(raw: string): CookLangPageType {
  switch (raw.toLowerCase().trim()) {
    case "technique":
      return "technique";
    case "equipment":
      return "equipment";
    case "ingredient_note":
    case "ingredient note":
    case "ingredientnote":
      return "ingredient_note";
    case "other":
      return "other";
    default:
      return "recipe";
  }
}

export function extractPageType(cooklang: string): CookLangPageType {
  return parsePageTypeLabel(parseMeta(cooklang).get("page_type") ?? "");
}

export function stripMeta(content: string): string {
  return content
    .split("\n")
    .filter((line) => !line.trimStart().startsWith(">>"))
    .join("\n")
    .trim();
}
