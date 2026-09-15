/**
 * Produits d'achat — rejoue la fixture PARTAGÉE avec le client.
 *
 * Le serveur regroupe les ingrédients d'une recette à son écriture ; le client
 * regroupe entre recettes dans le planning et la feuille de courses. Un écart
 * entre les deux ne lève rien : le riz d'une garniture ferait une seconde
 * ligne, ou deux kilos deviendraient deux grammes. La fixture
 * `test-fixtures/shopping_products.json` est lue ici ET par
 * `test/shopping_products_test.dart`.
 *
 * Logique pure : ni Firestore, ni réseau, ni appel de modèle.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import {
  deriveShoppingProducts,
  formatShoppingTotal,
  mergeShoppingEntries,
  shoppingProductKey,
  shoppingUnitFamily,
  type ShoppingInput,
} from "../nutrition/shoppingDerivation";

interface UnitFamilyCase {
  unit: string;
  family: string;
  factor: number;
}

interface TotalCase {
  why: string;
  total: number;
  family: string;
  qty: string;
  unit: string | null;
}

interface FixtureInput {
  name: string;
  qty: string;
  unit: string;
  shopping_product?: string;
}

interface MergeCase {
  why: string;
  inputs: FixtureInput[];
  expected: Array<{ name: string; qty: string; unit: string }>;
}

interface Fixture {
  unit_families: UnitFamilyCase[];
  totals: TotalCase[];
  cases: MergeCase[];
}

const fixturePath = path.join(
  __dirname,
  "..",
  "..",
  "..",
  "test-fixtures",
  "shopping_products.json",
);
const fixture = JSON.parse(readFileSync(fixturePath, "utf8")) as Fixture;

describe("fixture partagée — familles d'unités", () => {
  test("la fixture n'est pas vide", () => {
    assert.ok(fixture.unit_families.length > 0);
    assert.ok(fixture.totals.length > 0);
    assert.ok(fixture.cases.length > 0);
  });

  for (const c of fixture.unit_families) {
    test(`« ${c.unit || "(vide)"} » → ${c.family} × ${c.factor}`, () => {
      const out = shoppingUnitFamily(c.unit);
      assert.equal(out.family, c.family);
      assert.ok(Math.abs(out.factor - c.factor) < 1e-9);
    });
  }
});

describe("fixture partagée — écriture d'un total", () => {
  for (const c of fixture.totals) {
    test(`${c.total} ${c.family} (${c.why})`, () => {
      assert.deepEqual(formatShoppingTotal(c.total, c.family), { qty: c.qty, unit: c.unit });
    });
  }
});

describe("fixture partagée — regroupement", () => {
  for (const c of fixture.cases) {
    test(c.why, () => {
      const inputs: ShoppingInput[] = c.inputs.map((i) => ({
        name: i.name,
        qty: i.qty,
        unit: i.unit,
        shoppingProduct: i.shopping_product ?? null,
      }));
      assert.deepEqual(deriveShoppingProducts(inputs), c.expected);
    });
  }
});

describe("identité d'un produit", () => {
  test("singulier et pluriel, casse et accents, mots de préparation", () => {
    assert.equal(shoppingProductKey("Tomates"), shoppingProductKey("tomate"));
    assert.equal(shoppingProductKey("Œufs"), shoppingProductKey("oeuf"));
    assert.equal(shoppingProductKey("oignon haché"), shoppingProductKey("oignons"));
  });

  test("mergeShoppingEntries ne lit aucun alias : c'est deriveShoppingProducts qui le pose", () => {
    const out = mergeShoppingEntries([
      { name: "beurre fondu", qty: "50", unit: "g" },
      { name: "beurre", qty: "100", unit: "g" },
    ]);
    assert.equal(out.length, 2);
  });
});
