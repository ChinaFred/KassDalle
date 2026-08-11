/**
 * Sections CookLang (`== Pour la pâte ==`) et déduplication qui les respecte.
 *
 * La catégorie d'un ingrédient EST sa section : le parseur la porte déjà
 * (`extractIngredientsStructured`), et le client Dart déduplique par
 * (nom, catégorie) — voir `_dedupeStructuredIngredients` dans `recipe.dart`.
 * La normalisation référentiels, elle, dédupliquait par `ingredient_ref_id`
 * seul : la même farine dans deux sections était fusionnée en une, et la
 * seconde section perdait son ingrédient — donc sa catégorie.
 *
 * Logique pure, sans Firestore : testable directement.
 */

/** Ingrédient résolu, réduit aux champs nécessaires à la déduplication. */
export interface DedupableIngredient {
  name: string;
  qty: string;
  unit: string;
  category?: string;
  ingredient_ref_id: string;
}

/** Position d'un en-tête `== … ==` dans le texte CookLang. */
export interface SectionMarker {
  /** Offset du premier caractère qui SUIT la ligne d'en-tête. */
  start: number;
  category: string;
}

/**
 * Clé d'identité d'un ingrédient dans une recette : nom + section.
 *
 * Deux ingrédients de même nom dans deux sections différentes sont deux
 * ingrédients distincts, avec chacun leur quantité.
 */
export function ingredientSectionKey(name: string, category?: string | null): string {
  return `${name.trim().toLowerCase()}|${(category ?? "").trim().toLowerCase()}`;
}

/** Relève les en-têtes de section et leur position dans le CookLang. */
export function buildSectionMarkers(cooklang: string): SectionMarker[] {
  const markers: SectionMarker[] = [];
  let offset = 0;
  for (const line of cooklang.split("\n")) {
    const trimmed = line.trim();
    if (trimmed.startsWith("==")) {
      markers.push({
        start: offset + line.length,
        category: trimmed.replaceAll("==", "").trim(),
      });
    }
    offset += line.length + 1;
  }
  return markers;
}

/** Section active à l'offset donné ("" si le texte n'a pas encore d'en-tête). */
export function sectionCategoryAt(markers: SectionMarker[], offset: number): string {
  let current = "";
  for (const marker of markers) {
    if (marker.start > offset) break;
    current = marker.category;
  }
  return current;
}

/**
 * Fusionne les ingrédients qui désignent la même chose DANS LA MÊME SECTION.
 *
 * Cas visé : Gemini extrait « @cerfeuil frais{} » ET « @brins de cerfeuil
 * frais{} » d'une même liste — après normalisation, le même identifiant.
 * On garde l'entrée la plus informative (unité > quantité), en récupérant sur
 * l'autre ce qui manque à la gagnante.
 */
export function dedupeResolvedIngredients<T extends DedupableIngredient>(items: T[]): T[] {
  const result: T[] = [];
  const indexByKey = new Map<string, number>();
  const score = (i: T): number => (i.unit ? 2 : 0) + (i.qty ? 1 : 0);

  for (const ing of items) {
    const key = ingredientSectionKey(ing.ingredient_ref_id || ing.name, ing.category);
    const existing = indexByKey.get(key);
    if (existing === undefined) {
      indexByKey.set(key, result.length);
      result.push(ing);
      continue;
    }
    const prev = result[existing];
    const winner = score(ing) > score(prev) ? ing : prev;
    const loser = winner === ing ? prev : ing;
    result[existing] = {
      ...winner,
      qty: winner.qty || loser.qty,
      // La casse de la section peut différer entre deux occurrences : la clé
      // les a rapprochées, mais la gagnante peut n'avoir aucune catégorie.
      ...(winner.category ? {} : loser.category ? { category: loser.category } : {}),
    };
  }
  return result;
}
