/**
 * Parseur CookLang minimal — porté depuis lib/core/services/cooklang_parser.dart.
 *
 * Extrait les métadonnées, ingrédients (avec quantités/unités/catégories),
 * titre, portions, tags et type de page depuis un bloc CookLang.
 */

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
      meta.set(content.substring(0, colon).trim().toLowerCase(), content.substring(colon + 1).trim());
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
    "à": "a", "â": "a", "é": "e", "è": "e", "ê": "e", "ë": "e",
    "î": "i", "ï": "i", "ô": "o", "ö": "o", "ù": "u", "û": "u",
    "ü": "u", "ç": "c", "æ": "ae", "œ": "oe",
    "\u2019": "'", "\u2018": "'", "\u02BC": "'",
  };
  const s = name.toLowerCase().replace(/./g, (c) => accents[c] ?? c);
  return s
    .split(" ")
    .map((w) => (w.endsWith("s") && w.length > 2 ? w.slice(0, -1) : w))
    .join(" ");
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
      const key = ingredientKey(name);
      const parts = (m[2] ?? "").split("%");
      const qty = parts[0]?.trim() ?? "";
      const unit = parts[1]?.trim() ?? "";
      if (indexMap.has(key)) {
        const idx = indexMap.get(key)!;
        const existing = result[idx];
        // On garde la PREMIÈRE quantité rencontrée (typiquement celle de la
        // liste d'ingrédients) ; les occurrences ultérieures dans les étapes
        // ne sont pas additionnées ("4 + 1 cuillère" était trompeur).
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
      } else {
        indexMap.set(key, result.length);
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

function parseTimeToMinutes(raw: string | undefined): number | null {
  if (!raw || !raw.trim()) return null;
  const text = raw.toLowerCase().trim();
  const match = text.match(/(\d+)/);
  if (!match) return null;
  const value = parseInt(match[1], 10);
  if (!Number.isFinite(value)) return null;
  if (text.includes("h")) return value * 60;
  return value;
}

function parseCsvList(raw: string | undefined): string[] {
  if (!raw || !raw.trim()) return [];
  return raw.split(",").map((s) => s.trim().toLowerCase()).filter((s) => s.length > 0);
}

export function extractTags(cooklang: string): CookLangTags {
  const meta = parseMeta(cooklang);
  return {
    difficulty: meta.get("difficulte") ?? meta.get("difficulté") ?? meta.get("difficulty") ?? null,
    prepTime: parseTimeToMinutes(meta.get("temps_preparation") ?? meta.get("temps_préparation") ?? meta.get("prep_time")),
    cookTime: parseTimeToMinutes(meta.get("temps_cuisson") ?? meta.get("cook_time") ?? meta.get("cuisson")),
    dishTypes: parseCsvList(meta.get("dish_types")),
  };
}

export function extractPageType(cooklang: string): CookLangPageType {
  const meta = parseMeta(cooklang);
  const raw = (meta.get("page_type") ?? "").toLowerCase().trim();
  switch (raw) {
    case "technique": return "technique";
    case "equipment": return "equipment";
    case "ingredient_note":
    case "ingredient note": return "ingredient_note";
    case "other": return "other";
    default: return "recipe";
  }
}

export function stripMeta(content: string): string {
  return content
    .split("\n")
    .filter((line) => !line.trimStart().startsWith(">>"))
    .join("\n")
    .trim();
}
