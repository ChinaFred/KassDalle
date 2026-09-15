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
 * Ce que ce module ne fait PAS : inventer une conversion. Deux gousses d'ail
 * et une cuillère d'ail en poudre restent deux lignes ; six pommes de terre et
 * deux kilos aussi. Seules les conversions EXACTES s'additionnent : kilo et
 * grammes, litre, centilitre et millilitre. Une densité ou un poids moyen
 * produirait une quantité fausse présentée comme exacte.
 *
 * Ce que le modèle faisait et que l'addition ne fait pas — ramener « beurre
 * fondu » à « beurre », « jaune d'œuf » à « œuf » — vit dans le référentiel :
 * `nutrition_ingredients.shopping_product`, lu par `shoppingAliases.ts` et
 * appliqué ici AVANT le regroupement.
 *
 * Logique jumelle de `lib/core/utils/shopping_products.dart` : le client
 * regroupe entre recettes dans le planning et dans la feuille de courses.
 * Fixture partagée : `test-fixtures/shopping_products.json`.
 */

import { normalizeIngredientSingularId } from "./ingredientName";
import { normalizeObservedUnit, parseQuantityToNumber } from "./quantityConversion";

export interface ShoppingInput {
  name: string;
  qty?: string | null;
  unit?: string | null;
  /**
   * Le produit qu'on achète, quand le référentiel le dit. Remplace `name`
   * avant le regroupement ; vide ou absent = le nom lui-même.
   */
  shoppingProduct?: string | null;
}

export interface ShoppingProduct {
  name: string;
  qty: string;
  unit: string;
}

/** Famille d'unité d'une ligne de courses, et facteur vers l'unité de base. */
export interface ShoppingUnitFamily {
  /** `g`, `ml`, `piece`, ou l'unité canonique elle-même (`gousse`, `c_a_s`). */
  family: string;
  /** Multiplicateur vers l'unité de base de la famille (kg → g : 1000). */
  factor: number;
}

/** Unités de masse, en grammes — clés : unité observée normalisée. */
const MASS_TO_GRAMS: Record<string, number> = {
  g: 1,
  gr: 1,
  grs: 1,
  gramme: 1,
  grammes: 1,
  gram: 1,
  grams: 1,
  kg: 1000,
  kgs: 1000,
  kilo: 1000,
  kilos: 1000,
  kilogramme: 1000,
  kilogrammes: 1000,
  mg: 0.001,
};

/** Unités de volume, en millilitres — conversions exactes seules. */
const VOLUME_TO_ML: Record<string, number> = {
  ml: 1,
  millilitre: 1,
  millilitres: 1,
  milliliter: 1,
  milliliters: 1,
  cl: 10,
  centilitre: 10,
  centilitres: 10,
  dl: 100,
  decilitre: 100,
  decilitres: 100,
  l: 1000,
  litre: 1000,
  litres: 1000,
  liter: 1000,
  liters: 1000,
};

/**
 * Famille d'une unité telle qu'écrite dans une recette.
 *
 * Une unité absente compte des pièces : « 6 pommes de terre ». Une cuillère à
 * soupe n'a pas de conversion exacte vers autre chose — elle forme sa propre
 * famille, et deux cuillères s'additionnent entre elles seulement.
 */
export function shoppingUnitFamily(unit: string | null | undefined): ShoppingUnitFamily {
  const normalized = normalizeObservedUnit(unit ?? "");
  if (normalized === "" || normalized === "piece") return { family: "piece", factor: 1 };
  const grams = MASS_TO_GRAMS[normalized];
  if (grams !== undefined) return { family: "g", factor: grams };
  const ml = VOLUME_TO_ML[normalized];
  if (ml !== undefined) return { family: "ml", factor: ml };
  return { family: normalized, factor: 1 };
}

/** Identité d'un produit : nom singularisé, sans mot de préparation. */
export function shoppingProductKey(name: string): string {
  return normalizeIngredientSingularId(name) || name.trim().toLowerCase();
}

/** Nombre sans décimale inutile, virgule décimale, deux décimales au plus. */
export function formatShoppingNumber(value: number): string {
  const rounded = Math.round(value * 100) / 100;
  if (Number.isInteger(rounded)) return String(rounded);
  return rounded.toFixed(2).replace(/0+$/, "").replace(/\.$/, "").replace(".", ",");
}

/**
 * Quantité et unité d'un total additionné.
 *
 * En grammes ou millilitres tant que le total tient sous mille ; au-delà, en
 * kilo ou litre seulement si rien n'est perdu — 1 234 g restent 1 234 g plutôt
 * que de devenir 1,23 kg. Pour les autres familles, l'unité rendue est `null` :
 * c'est celle de la ligne qui s'applique.
 */
export function formatShoppingTotal(
  total: number,
  family: string,
): { qty: string; unit: string | null } {
  if (family === "g" || family === "ml") {
    const big = family === "g" ? "kg" : "l";
    const tenths = total / 10;
    const exactInBig = total >= 1000 && Math.abs(tenths - Math.round(tenths)) < 1e-6;
    if (exactInBig) return { qty: formatShoppingNumber(total / 1000), unit: big };
    return { qty: formatShoppingNumber(total), unit: family };
  }
  return { qty: formatShoppingNumber(total), unit: null };
}

/**
 * Valeur numérique d'une quantité, ou `null` si elle ne s'additionne pas.
 *
 * Délègue au parseur partagé avec le client (`quantity_parsing.json`) : une
 * quantité que le calcul nutritionnel sait lire, la liste de courses la lit
 * aussi.
 */
export function numericQty(qty: string | null | undefined): number | null {
  return parseQuantityToNumber(qty ?? "");
}

interface Group {
  key: string;
  productKey: string;
  family: ShoppingUnitFamily;
  /** Unité de la première ligne, telle qu'écrite. */
  unit: string;
  numericCount: number;
  /** Quantité de la première ligne chiffrée, telle qu'écrite. */
  firstQty: string;
  total: number;
  textual: string[];
}

/**
 * Regroupe des lignes (nom, quantité, unité) en lignes de courses.
 *
 * Clé de regroupement : identité du produit + famille d'unité. La SECTION est
 * volontairement ignorée — deux cuillères de sauce soja pour la farce et six
 * pour la sauce font une seule bouteille à acheter. C'est la différence entre
 * la liste de courses et la liste d'ingrédients : l'une se compte au magasin,
 * l'autre dans la casserole.
 *
 * Toutes les lignes d'un même produit portent le même nom, celui de la
 * première lue : « Lait de coco » en grammes et « lait de coco » en millilitres
 * restent deux lignes, mais une seule orthographe.
 *
 * Une ligne seule dans sa famille garde sa quantité et son unité telles
 * qu'écrites — « 0,5 kg », « 1/2 ». Dès qu'on additionne, le total s'écrit dans
 * l'unité de base de la famille, ou en kilo/litre quand c'est exact.
 */
export function mergeShoppingEntries(entries: ShoppingProduct[]): ShoppingProduct[] {
  const order: string[] = [];
  const groups = new Map<string, Group>();
  const displayName = new Map<string, string>();

  for (const entry of entries) {
    const name = (entry.name ?? "").trim();
    if (!name) continue;
    const productKey = shoppingProductKey(name);
    if (!displayName.has(productKey)) displayName.set(productKey, name);

    const unit = (entry.unit ?? "").trim();
    const family = shoppingUnitFamily(unit);
    const key = `${productKey}|${family.family}`;
    let group = groups.get(key);
    if (!group) {
      group = {
        key,
        productKey,
        family,
        unit,
        numericCount: 0,
        firstQty: "",
        total: 0,
        textual: [],
      };
      groups.set(key, group);
      order.push(key);
    }

    const rawQty = (entry.qty ?? "").trim();
    const value = numericQty(rawQty);
    if (value == null) {
      // Une quantité qu'on ne sait pas additionner n'est pas jetée : elle est
      // conservée telle quelle. « qsp », « à volonté » doivent rester visibles
      // au magasin, sinon l'ingrédient disparaît de la liste sans un mot.
      if (rawQty) group.textual.push(rawQty);
      continue;
    }
    if (group.numericCount === 0) group.firstQty = rawQty;
    group.numericCount += 1;
    group.total += value * family.factor;
  }

  return order.map((key) => {
    const group = groups.get(key)!;
    let qtyText = "";
    let unit = group.unit;
    if (group.numericCount === 1) {
      qtyText = group.firstQty;
    } else if (group.numericCount > 1) {
      const formatted = formatShoppingTotal(group.total, group.family.family);
      qtyText = formatted.qty;
      if (formatted.unit !== null) unit = formatted.unit;
    }
    const parts = qtyText ? [qtyText, ...group.textual] : group.textual;
    return { name: displayName.get(group.productKey) ?? "", qty: parts.join(" + "), unit };
  });
}

/**
 * Produits d'achat d'une recette : le produit acheté remplace le nom, puis les
 * lignes sont regroupées.
 */
export function deriveShoppingProducts(inputs: ShoppingInput[]): ShoppingProduct[] {
  const entries: ShoppingProduct[] = inputs.map((input) => {
    const alias = (input.shoppingProduct ?? "").trim();
    const name = (input.name ?? "").trim();
    return { name: alias || name, qty: input.qty ?? "", unit: input.unit ?? "" };
  });
  return mergeShoppingEntries(entries);
}
