/**
 * Sections CookLang (`== Pour la pâte ==`) — lecture ET écriture.
 *
 * La catégorie d'un ingrédient EST sa section. Le CookLang est la source de
 * vérité : une catégorie créée dans l'éditeur de liste d'ingrédients n'existe
 * que dans le champ `ingredients` tant qu'aucun `== Nom ==` ne la porte dans le
 * texte. Elle disparaît donc au rechargement, puisque la liste est réécrite
 * depuis le CookLang. Ce module fournit les deux sens :
 *
 * - lecture   : `parseSectionHeader`
 * - écriture  : `planSectionHeaders`, qui insère les en-têtes manquants
 * - identité  : `ingredientRefKey`, `ingredientSectionKey`
 * - fusion    : `dedupeResolvedIngredients`, qui ne fusionne pas deux sections
 *
 * Le projet n'écrit pas de liste d'ingrédients séparée : les ingrédients sont
 * balisés dans la prose des étapes (cf. le prompt d'extraction). Un en-tête ne
 * peut donc s'insérer qu'avant une LIGNE, jamais au milieu d'une phrase.
 *
 * Logique pure, sans Firestore : testable directement.
 */

/** Ingrédient résolu, réduit aux champs nécessaires ici. */
export interface DedupableIngredient {
  name: string;
  qty: string;
  unit: string;
  category?: string;
  ingredient_ref_id: string;
}

/** Identité d'un ingrédient dans le référentiel, avec repli sur son nom. */
export function ingredientRefKey(ingredient: { ingredient_ref_id?: string; name: string }): string {
  return (ingredient.ingredient_ref_id || ingredient.name).trim().toLowerCase();
}

/**
 * Clé d'identité d'un ingrédient dans une recette : nom + section.
 *
 * Deux ingrédients de même nom dans deux sections différentes sont deux
 * ingrédients, avec chacun leur quantité.
 */
export function ingredientSectionKey(name: string, category?: string | null): string {
  return `${name.trim().toLowerCase()}|${(category ?? "").trim().toLowerCase()}`;
}

/** Nom de la section si la ligne est un en-tête `== … ==`, sinon null. */
export function parseSectionHeader(line: string): string | null {
  const trimmed = line.trim();
  if (!trimmed.startsWith("==")) return null;
  return trimmed.replaceAll("==", "").trim();
}

/** Écrit un en-tête de section au format attendu par le parseur. */
export function formatSectionHeader(category: string): string {
  return `== ${category} ==`;
}

/**
 * Catégorie de chaque ingrédient, telle que décidée par la liste résolue.
 *
 * Un ingrédient présent dans DEUX sections est volontairement absent du
 * résultat : c'est le texte CookLang, et lui seul, qui sait laquelle des deux
 * occurrences est laquelle. Y répondre au jugé déplacerait un ingrédient de
 * section à chaque sauvegarde.
 */
export function buildCategoryByRefId(ingredients: DedupableIngredient[]): Map<string, string> {
  const byKey = new Map<string, string>();
  const ambiguous = new Set<string>();
  for (const ing of ingredients) {
    const key = ingredientRefKey(ing);
    if (!key) continue;
    const category = (ing.category ?? "").trim();
    const known = byKey.get(key);
    if (known === undefined) {
      byKey.set(key, category);
    } else if (known !== category) {
      ambiguous.add(key);
    }
  }
  for (const key of ambiguous) byKey.delete(key);
  return byKey;
}

/**
 * Insère les en-têtes `== Nom ==` manquants dans un CookLang déjà réécrit.
 *
 * `targetCategories[i]` porte la catégorie que la liste d'ingrédients attribue
 * à la ligne `i` — `null` quand la ligne ne permet pas de trancher (pas
 * d'ingrédient, ou ingrédient que la liste ne sait pas situer). Un en-tête est
 * émis dès que cette catégorie diffère de la section en vigueur : le premier
 * ingrédient de chaque catégorie ouvre donc sa section, dans l'ordre du texte.
 *
 * Deux limites assumées :
 *
 * - CookLang n'a pas de marqueur de fin de section. Un ingrédient SANS
 *   catégorie placé après une section ne peut pas être exprimé : il hérite de
 *   la section précédente. L'éditeur range les ingrédients sans catégorie en
 *   tête, ce qui rend le cas rare.
 * - Un en-tête existant encore vide de tout contenu au moment où l'on doit en
 *   émettre un autre est RENOMMÉ plutôt que doublé : c'est le cas d'une
 *   catégorie renommée depuis l'éditeur, qui laisserait sinon une section
 *   orpheline derrière elle.
 */
export function planSectionHeaders(args: {
  lines: string[];
  targetCategories: Array<string | null>;
}): string[] {
  const out: string[] = [];
  let currentCategory = "";
  // Index dans `out` d'un en-tête sous lequel rien n'a encore été écrit.
  let emptyHeaderIndex = -1;

  for (let i = 0; i < args.lines.length; i++) {
    const line = args.lines[i];
    const header = parseSectionHeader(line);
    if (header !== null) {
      currentCategory = header;
      emptyHeaderIndex = out.length;
      out.push(line);
      continue;
    }

    const target = args.targetCategories[i];
    if (target != null && target !== "" && target !== currentCategory) {
      if (emptyHeaderIndex >= 0) {
        out[emptyHeaderIndex] = formatSectionHeader(target);
      } else {
        out.push(formatSectionHeader(target));
      }
      currentCategory = target;
    }

    out.push(line);
    if (line.trim()) emptyHeaderIndex = -1;
  }
  return out;
}

/**
 * Fusionne les ingrédients qui désignent la même chose DANS LA MÊME SECTION.
 *
 * Cas visé : Gemini extrait « @cerfeuil frais{} » ET « @brins de cerfeuil
 * frais{} » d'une même section — après normalisation, le même identifiant.
 * On garde l'entrée la plus informative (unité > quantité), en récupérant sur
 * l'autre ce qui manque à la gagnante.
 */
export function dedupeResolvedIngredients<T extends DedupableIngredient>(items: T[]): T[] {
  const result: T[] = [];
  const indexByKey = new Map<string, number>();
  const score = (i: T): number => (i.unit ? 2 : 0) + (i.qty ? 1 : 0);

  for (const ing of items) {
    const key = ingredientSectionKey(ingredientRefKey(ing), ing.category);
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
