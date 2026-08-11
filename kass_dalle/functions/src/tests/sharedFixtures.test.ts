/**
 * Suite de tests des Cloud Functions — rejoue les fixtures PARTAGÉES avec Dart.
 *
 * Le projet porte trois logiques métier en double, en Dart côté client et en
 * TypeScript côté Functions : parseur CookLang, parsing de quantité, conversion
 * d'unités en grammes. Rien ne garantissait qu'elles restent d'accord ; une
 * correction faite d'un seul côté partait silencieusement en production.
 *
 * Les fichiers de `kass_dalle/test-fixtures/` sont ce garde-fou : ils sont lus
 * ici ET par `kass_dalle/test/*_test.dart`. Corriger un bug d'un seul côté fait
 * désormais échouer la CI de l'autre.
 *
 * Exécution : `npm test` (build tsc puis `node --test`, aucune dépendance).
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import {
  parseQuantityToNumber,
  unitFactorToGrams,
  resolveUnitFactorToGrams,
} from "../nutrition/quantityConversion";
import {
  extractIngredientsStructured,
  extractIngredientNames,
  extractTitle,
  extractPortions,
  extractPageNumber,
  extractPageType,
  extractTags,
  stripMeta,
} from "../cooklang/parser";

// __dirname vaut functions/lib/tests une fois compilé → remonter à kass_dalle/.
const FIXTURE_DIR = path.join(__dirname, "..", "..", "..", "test-fixtures");

function loadFixture<T>(name: string): T {
  const file = path.join(FIXTURE_DIR, name);
  try {
    return JSON.parse(readFileSync(file, "utf8")) as T;
  } catch (err) {
    throw new Error(
      `Fixture partagée illisible : ${file}. ` +
        `Elle doit rester au même endroit que pour la suite Dart. Cause : ${
          err instanceof Error ? err.message : String(err)
        }`,
    );
  }
}

const EPSILON = 1e-6;

function assertCloseOrNull(actual: number | null, expected: number | null, message: string): void {
  if (expected === null) {
    assert.equal(actual, null, message);
    return;
  }
  assert.notEqual(actual, null, `${message} — attendu ${expected}, obtenu null`);
  assert.ok(
    Math.abs((actual as number) - expected) < EPSILON,
    `${message} — attendu ${expected}, obtenu ${actual}`,
  );
}

// ── Parsing de quantité ───────────────────────────────────────────────────────

interface QuantityCase {
  input: string;
  expected: number | null;
  why: string;
}

describe("parseQuantityToNumber — cas partagés Dart/TypeScript", () => {
  const fixture = loadFixture<{ cases: QuantityCase[] }>("quantity_parsing.json");
  assert.ok(fixture.cases.length > 0, "la fixture partagée est vide");

  for (const c of fixture.cases) {
    test(`« ${c.input} » → ${c.expected ?? "null"}  (${c.why})`, () => {
      assertCloseOrNull(parseQuantityToNumber(c.input), c.expected, `« ${c.input} »`);
    });
  }
});

// ── Conversion en grammes ─────────────────────────────────────────────────────

interface GramsCase {
  ingredient: string;
  qty: string;
  unit: string;
  grams: number | null;
  why: string;
}

interface GramsDivergence {
  ingredient: string;
  qty: string;
  unit: string;
  dart: number | null;
  ts: number | null;
  why: string;
}

/** Reproduit la composition faite par nutritionCallable : quantité × facteur. */
function toGrams(ingredient: string, qty: string, unit: string): number | null {
  const quantity = parseQuantityToNumber(qty);
  if (quantity === null) return null;
  const factor = unitFactorToGrams(unit, ingredient);
  if (factor === null) return null;
  return quantity * factor;
}

describe("unitFactorToGrams — cas partagés Dart/TypeScript", () => {
  const fixture = loadFixture<{ cases: GramsCase[]; divergences: GramsDivergence[] }>(
    "unit_to_grams.json",
  );

  for (const c of fixture.cases) {
    test(`${c.qty} ${c.unit} de ${c.ingredient} → ${c.grams ?? "null"} g  (${c.why})`, () => {
      assertCloseOrNull(
        toGrams(c.ingredient, c.qty, c.unit),
        c.grams,
        `${c.qty} ${c.unit} de ${c.ingredient}`,
      );
    });
  }

  describe("divergences connues avec le convertisseur Dart", () => {
    for (const d of fixture.divergences) {
      test(`ÉCART — ${d.qty} ${d.unit} de ${d.ingredient} : TS=${d.ts ?? "null"} vs Dart=${
        d.dart ?? "null"
      }`, () => {
        assertCloseOrNull(
          toGrams(d.ingredient, d.qty, d.unit),
          d.ts,
          `Si ce test échoue, le référentiel TS a changé : mettre à jour ` +
            `test-fixtures/unit_to_grams.json (section divergences)`,
        );
      });
    }
  });
});

// ── Arbitrage référentiel Firestore / table intégrée ─────────────────────────

interface ReferentialCase {
  ingredient: string;
  qty: string;
  unit: string;
  override: {
    measurementType?: string;
    gramsPerUnit?: number;
    volumeMlPerUnit?: number;
  } | null;
  grams: number | null;
  why: string;
}

describe("resolveUnitFactorToGrams — cas partagés Dart/TypeScript", () => {
  const fixture = loadFixture<{ referential: ReferentialCase[] }>("unit_to_grams.json");

  for (const c of fixture.referential) {
    const label = c.override === null ? "sans référentiel" : "avec référentiel";
    test(`${c.qty} ${c.unit} de ${c.ingredient}, ${label} → ${c.grams ?? "null"} g  (${c.why})`, () => {
      const quantity = parseQuantityToNumber(c.qty);
      const factor = resolveUnitFactorToGrams(c.unit, c.ingredient, c.override);
      const actual = quantity === null || factor === null ? null : quantity * factor;
      assertCloseOrNull(actual, c.grams, `${c.qty} ${c.unit} de ${c.ingredient}`);
    });
  }
});

// ── Parseur CookLang ──────────────────────────────────────────────────────────

interface CookLangRecipeCase {
  label: string;
  cooklang: string;
  title: string;
  portions: number | null;
  pageNumber: number | null;
  pageType: string;
  tags: {
    difficulty: string | null;
    prepTime: number | null;
    cookTime: number | null;
    dishTypes: string[];
  };
  ingredients: { name: string; qty: string; unit: string; category: string | null }[];
  names: string[];
  why: string;
}

describe("parseur CookLang — cas partagés Dart/TypeScript", () => {
  const fixture = loadFixture<{
    recipes: CookLangRecipeCase[];
    stripMeta: { input: string; expected: string; why: string }[];
  }>("cooklang_parsing.json");

  for (const r of fixture.recipes) {
    describe(r.label, () => {
      test(`ingrédients structurés (${r.why})`, () => {
        const actual = extractIngredientsStructured(r.cooklang);
        assert.equal(
          actual.length,
          r.ingredients.length,
          `attendu ${r.ingredients.length} ingrédient(s), obtenu ${JSON.stringify(
            actual.map((i) => `${i.name}(${i.qty}${i.unit})`),
          )}`,
        );
        r.ingredients.forEach((expected, i) => {
          assert.equal(actual[i].name, expected.name, `nom #${i}`);
          assert.equal(actual[i].qty, expected.qty, `quantité #${i}`);
          assert.equal(actual[i].unit, expected.unit, `unité #${i}`);
          assert.equal(actual[i].category ?? null, expected.category, `catégorie #${i}`);
        });
      });

      test("liste des noms d'ingrédients", () => {
        assert.deepEqual(extractIngredientNames(r.cooklang), r.names);
      });

      test("titre", () => {
        assert.equal(extractTitle(r.cooklang), r.title);
      });

      test("portions", () => {
        assert.equal(extractPortions(r.cooklang), r.portions);
      });

      test("numéro de page", () => {
        assert.equal(extractPageNumber(r.cooklang), r.pageNumber);
      });

      test("type de page", () => {
        assert.equal(extractPageType(r.cooklang), r.pageType);
      });

      test("tags", () => {
        const actual = extractTags(r.cooklang);
        assert.equal(actual.difficulty ?? null, r.tags.difficulty, "difficulté");
        assert.equal(actual.prepTime ?? null, r.tags.prepTime, "temps de prépa");
        assert.equal(actual.cookTime ?? null, r.tags.cookTime, "temps de cuisson");
        assert.deepEqual(actual.dishTypes, r.tags.dishTypes, "types de plat");
      });
    });
  }

  describe("stripMeta", () => {
    for (const c of fixture.stripMeta) {
      test(c.why, () => {
        assert.equal(stripMeta(c.input), c.expected);
      });
    }
  });
});
