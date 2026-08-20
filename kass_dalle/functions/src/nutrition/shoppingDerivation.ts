/**
 * Produits d'achat d'une recette, dérivés de sa liste d'ingrédients.
 *
 * Ce regroupement coûtait un appel de modèle par écriture de recette. Il en
 * valait la peine tant que la liste d'ingrédients était reconstituée depuis les
 * balises des étapes : le même aliment y apparaissait sous plusieurs
 * orthographes, découpé, générique, et il fallait un jugement pour recoller les
 * morceaux.
 *
 * Depuis la transcription en deux passes, la liste vient de la LISTE DU LIVRE :
 * une entrée par ligne, nommée une fois, avec sa quantité. Regrouper n'est plus
 * un jugement, c'est une addition — et une addition ne se demande pas à un
 * modèle.
 *
 * Ce que cette fonction ne fait PAS : convertir entre unités. Deux gousses d'ail
 * et une cuillère d'ail en poudre restent deux lignes. Additionner supposerait
 * un taux de conversion, et un taux inventé produit une quantité fausse
 * présentée comme exacte.
 */

import { normalizeIngredientCanonicalId } from "./ingredientName";

export interface ShoppingInput {
  name: string;
  qty?: string | null;
  unit?: string | null;
}

export interface ShoppingProduct {
  name: string;
  qty: string;
  unit: string;
}

/** Unité comparable : casse et accents ignorés, pluriel simple retiré. */
function unitKey(unit: string): string {
  return unit
    .trim()
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/s$/, "");
}

/** Valeur numérique d'une quantité, ou `null` si elle ne s'additionne pas. */
export function numericQty(qty: string | null | undefined): number | null {
  const raw = (qty ?? "").trim();
  if (!raw) return null;

  // Fractions vulgaires courantes des livres de cuisine.
  const vulgar: Record<string, number> = {
    "½": 0.5,
    "¼": 0.25,
    "¾": 0.75,
    "⅓": 1 / 3,
    "⅔": 2 / 3,
  };
  let normalized = raw;
  for (const [glyph, value] of Object.entries(vulgar)) {
    // « 2½ » vaut 2,5 : le glyphe s'ajoute au nombre qui le précède.
    normalized = normalized.replace(new RegExp(`(\\d*)\\s*${glyph}`, "g"), (_m, digits: string) =>
      String((digits ? Number(digits) : 0) + value),
    );
  }
  normalized = normalized.replace(",", ".");

  // « 1/2 » écrit à la main.
  const fraction = /^(\d+(?:\.\d+)?)\s*\/\s*(\d+(?:\.\d+)?)$/.exec(normalized);
  if (fraction) {
    const denominator = Number(fraction[2]);
    return denominator === 0 ? null : Number(fraction[1]) / denominator;
  }

  const parsed = Number(normalized);
  return Number.isFinite(parsed) ? parsed : null;
}

/** Rend une quantité additionnée sans traîner de décimales inutiles. */
function formatQty(value: number): string {
  const rounded = Math.round(value * 100) / 100;
  return Number.isInteger(rounded) ? String(rounded) : String(rounded).replace(".", ",");
}

/**
 * Regroupe les ingrédients en produits d'achat.
 *
 * Clé de regroupement : identité de l'ingrédient + unité. La SECTION est
 * volontairement ignorée — deux cuillères de sauce soja pour la farce et six
 * pour la sauce font une seule bouteille à acheter. C'est la différence entre
 * la liste de courses et la liste d'ingrédients : l'une se compte au magasin,
 * l'autre dans la casserole.
 */
export function deriveShoppingProducts(inputs: ShoppingInput[]): ShoppingProduct[] {
  const order: string[] = [];
  const groups = new Map<
    string,
    { name: string; unit: string; total: number | null; textual: string[] }
  >();

  for (const input of inputs) {
    const name = (input.name ?? "").trim();
    if (!name) continue;
    const unit = (input.unit ?? "").trim();
    const key = `${normalizeIngredientCanonicalId(name) || name.toLowerCase()}|${unitKey(unit)}`;

    if (!groups.has(key)) {
      order.push(key);
      groups.set(key, { name, unit, total: null, textual: [] });
    }
    const group = groups.get(key)!;

    const value = numericQty(input.qty);
    if (value == null) {
      // Une quantité qu'on ne sait pas additionner n'est pas jetée : elle est
      // conservée telle quelle. « qsp », « à volonté » doivent rester visibles
      // au magasin, sinon l'ingrédient disparaît de la liste sans un mot.
      const raw = (input.qty ?? "").trim();
      if (raw) group.textual.push(raw);
      continue;
    }
    group.total = (group.total ?? 0) + value;
  }

  return order.map((key) => {
    const group = groups.get(key)!;
    const parts: string[] = [];
    if (group.total != null) parts.push(formatQty(group.total));
    parts.push(...group.textual);
    return { name: group.name, qty: parts.join(" + "), unit: group.unit };
  });
}
