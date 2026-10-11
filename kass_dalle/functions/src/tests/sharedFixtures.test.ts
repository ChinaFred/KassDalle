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
import { computeHomography, outputSize, type Quad as PerspectiveQuad } from "../gemini/perspective";
import path from "node:path";

import {
  parseQuantityToNumber,
  unitFactorToGrams,
  resolveUnitFactorToGrams,
  resolveWeighingInput,
} from "../nutrition/quantityConversion";
import {
  normalizeIngredientStrictId,
  normalizeIngredientCanonicalId,
  normalizeIngredientSingularId,
  buildIngredientLookupIds,
} from "../nutrition/ingredientName";
import {
  extractIngredientsStructured,
  extractIngredientNames,
  buildIngredientsIndex,
  extractTitle,
  extractPortions,
  extractPageNumber,
  extractPageType,
  parseTimeToMinutes,
  parsePageTypeLabel,
  extractTags,
  readDurations,
  stripMeta,
} from "../cooklang/parser";
import {
  getPricingForModel,
  effectivePricing,
  estimateAiCostUsd,
  type AiModelPricing,
} from "../ai/pricing";

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

/**
 * Reproduit la composition faite par le calcul de recette : quantité effective
 * × facteur.
 *
 * La quantité passe par `resolveWeighingInput`, comme dans `weightOf` : une
 * pincée sans nombre et un « poivre » nu se pèsent, et le test doit le voir.
 */
function toGrams(ingredient: string, qty: string, unit: string): number | null {
  const weighing = resolveWeighingInput(ingredient, qty, unit);
  if (weighing === null) return null;
  const factor = unitFactorToGrams(weighing.unit, ingredient);
  if (factor === null) return null;
  return weighing.qty * factor;
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

// ── Normalisation des noms d'ingrédients ─────────────────────────────────────

interface IngredientNameCase {
  input: string;
  strict: string;
  canonical: string;
  singular: string;
  lookup: string[];
  why: string;
}

describe("normalisation des noms d'ingrédients — cas partagés Dart/TypeScript", () => {
  const fixture = loadFixture<{ cases: IngredientNameCase[] }>("ingredient_names.json");
  assert.ok(fixture.cases.length > 0, "la fixture partagée est vide");

  for (const c of fixture.cases) {
    test(`« ${c.input} » → ${c.strict || "(vide)"} / ${c.canonical || "(vide)"}  (${c.why})`, () => {
      assert.equal(normalizeIngredientStrictId(c.input), c.strict, "identifiant strict");
      assert.equal(normalizeIngredientCanonicalId(c.input), c.canonical, "identifiant canonique");
      assert.equal(normalizeIngredientSingularId(c.input), c.singular, "identifiant singularisé");
      assert.deepEqual(buildIngredientLookupIds(c.input), c.lookup, "identifiants de recherche");
    });
  }
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
  /** Poids connus de l'ingrédient — absent quand le cas ne les met pas en jeu. */
  ingredientOverride?: {
    gramsPerPiece?: number;
    gramsPerUnit?: Record<string, number>;
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
      const factor = resolveUnitFactorToGrams(
        c.unit,
        c.ingredient,
        c.override,
        c.ingredientOverride ?? null,
      );
      const actual = quantity === null || factor === null ? null : quantity * factor;
      assertCloseOrNull(actual, c.grams, `${c.qty} ${c.unit} de ${c.ingredient}`);
    });
  }
});

// ── Portion usuelle d'une ligne nue ──────────────────────────────────────────

interface UsualPortionCase {
  ingredient: string;
  qty: string;
  unit: string;
  usualPortionGrams: number | null;
  grams: number | null;
  why: string;
}

describe("portion usuelle — cas partagés Dart/TypeScript", () => {
  const fixture = loadFixture<{ usual_portion: UsualPortionCase[] }>("unit_to_grams.json");
  assert.ok(fixture.usual_portion.length > 0, "la section usual_portion est vide");

  for (const c of fixture.usual_portion) {
    test(`${c.qty} ${c.unit} de ${c.ingredient}, portion ${c.usualPortionGrams ?? "absente"} → ${
      c.grams ?? "null"
    } g  (${c.why})`, () => {
      const weighing = resolveWeighingInput(c.ingredient, c.qty, c.unit, c.usualPortionGrams);
      const factor = weighing === null ? null : unitFactorToGrams(weighing.unit, c.ingredient);
      const actual = weighing === null || factor === null ? null : weighing.qty * factor;
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
    restTime: number | null;
    dishTypes: string[];
  };
  ingredients: { name: string; qty: string; unit: string; category: string | null }[];
  names: string[];
  index: string[];
  why: string;
}

describe("parseur CookLang — cas partagés Dart/TypeScript", () => {
  const fixture = loadFixture<{
    recipes: CookLangRecipeCase[];
    pageTypeLabels: { input: string; expected: string; why: string }[];
    stripMeta: { input: string; expected: string; why: string }[];
  }>("cooklang_parsing.json");

  describe("libellés de type de page", () => {
    for (const c of fixture.pageTypeLabels) {
      test(`« ${c.input} » → ${c.expected}  (${c.why})`, () => {
        assert.equal(parsePageTypeLabel(c.input), c.expected);
      });
    }
  });

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

      test("index de recherche", () => {
        assert.deepEqual(buildIngredientsIndex(extractIngredientsStructured(r.cooklang)), r.index);
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
        assert.equal(actual.restTime ?? null, r.tags.restTime, "temps de repos");
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

// ── Tarification des modeles d'IA ───────────────────────────────────────────────────────

interface PricingRow {
  model: string;
  inputPerMillion: number;
  outputPerMillion: number;
  imageOutputPerUnit: number;
  introductory?: { inputPerMillion: number; outputPerMillion: number; until: string };
}

interface PricingFixture {
  table: PricingRow[];
  default: Omit<PricingRow, "model">;
  effective: {
    model: string;
    at: string;
    inputPerMillion: number;
    outputPerMillion: number;
    why: string;
  }[];
  resolution: { model: string; expect: string | null; why: string }[];
  cost: {
    model: string;
    at: string;
    inputTokens: number;
    outputTokens: number;
    /** Facultatifs : jetons de prompt mis en cache, comptés en plus de l'entrée. */
    cacheCreationInputTokens?: number;
    cacheReadInputTokens?: number;
    imageOutputCount: number;
    /** Facultatif : unités facturées à l'unité pour une image analysée. */
    analyzedImageUnits?: number;
    usd: number;
    why: string;
  }[];
}

describe("tarification des modèles d'IA — cas partagés Dart/TypeScript", () => {
  const fixture = loadFixture<PricingFixture>("ai_pricing.json");

  function expectPricing(
    actual: AiModelPricing,
    expected: Omit<PricingRow, "model">,
    label: string,
  ): void {
    assert.equal(actual.inputPerMillion, expected.inputPerMillion, `${label} — entrée`);
    assert.equal(actual.outputPerMillion, expected.outputPerMillion, `${label} — sortie`);
    assert.equal(actual.imageOutputPerUnit ?? 0, expected.imageOutputPerUnit, `${label} — image`);
  }

  describe("table des tarifs", () => {
    for (const row of fixture.table) {
      test(`« ${row.model} » porte les prix de la fixture`, () => {
        expectPricing(getPricingForModel(row.model), row, row.model);
      });
    }
  });

  describe("promotion déclarée dans la table", () => {
    for (const row of fixture.table) {
      test(`« ${row.model} » ${row.introductory ? "avec" : "sans"} promotion`, () => {
        const actual = getPricingForModel(row.model).introductory;
        if (!row.introductory) {
          assert.equal(actual, undefined, `${row.model} — promotion inattendue`);
          return;
        }
        assert.ok(actual, `${row.model} — promotion manquante`);
        assert.equal(actual.inputPerMillion, row.introductory.inputPerMillion);
        assert.equal(actual.outputPerMillion, row.introductory.outputPerMillion);
        assert.equal(actual.untilIso, row.introductory.until);
      });
    }
  });

  describe("tarif en vigueur à une date", () => {
    for (const c of fixture.effective) {
      test(`${c.model} au ${c.at}  (${c.why})`, () => {
        const actual = effectivePricing(c.model, new Date(c.at));
        assert.equal(actual.inputPerMillion, c.inputPerMillion, `${c.model} — entrée`);
        assert.equal(actual.outputPerMillion, c.outputPerMillion, `${c.model} — sortie`);
      });
    }
  });

  describe("résolution du modèle", () => {
    for (const c of fixture.resolution) {
      test(`« ${c.model} » → ${c.expect ?? "(défaut)"}  (${c.why})`, () => {
        const expected =
          c.expect === null ? fixture.default : fixture.table.find((r) => r.model === c.expect)!;
        expectPricing(getPricingForModel(c.model), expected, c.model);
      });
    }
  });

  describe("coût en USD", () => {
    for (const c of fixture.cost) {
      const cacheWrite = c.cacheCreationInputTokens ?? 0;
      const cacheRead = c.cacheReadInputTokens ?? 0;
      const cacheLabel =
        cacheWrite > 0 || cacheRead > 0 ? ` / ${cacheWrite} cache+ / ${cacheRead} cache-` : "";
      test(`${c.model} : ${c.inputTokens} in / ${c.outputTokens} out${cacheLabel} / ${c.imageOutputCount} img → ${c.usd} $  (${c.why})`, () => {
        const actual = estimateAiCostUsd({
          model: c.model,
          inputTokens: c.inputTokens,
          outputTokens: c.outputTokens,
          cacheCreationInputTokens: cacheWrite,
          cacheReadInputTokens: cacheRead,
          imageOutputCount: c.imageOutputCount,
          analyzedImageUnits: c.analyzedImageUnits ?? 0,
          at: new Date(c.at),
        });
        assert.ok(Math.abs(actual - c.usd) < 1e-9, `attendu ${c.usd}, obtenu ${actual}`);
      });
    }
  });
});

// ── Géométrie du redressement d'une page ─────────────────────────────────────
//
// L'homographie existe en double : `gemini/perspective.ts` la calcule côté
// serveur, `core/presentation/image_enhancer_processing.dart` côté client, dans
// l'atelier de retouche. Les deux ont le même algorithme — normalisation de
// Hartley, DLT, Gauss avec pivot partiel — et rien ne garantissait qu'elles
// restent d'accord.
//
// Un écart ne lève aucune erreur et ne casse aucun écran. Il rend une page
// redressée de travers, parfaitement nette : le genre de faute qu'on découvre
// des semaines plus tard sur une découpe déjà publiée.

interface HomographyPoint {
  x: number;
  y: number;
}

interface HomographyCase {
  name: string;
  why: string;
  quad: HomographyPoint[];
  size: { width: number; height: number };
  probes: Array<{ from: HomographyPoint; to: HomographyPoint }>;
}

interface HomographyFixture {
  tolerance: number;
  cases: HomographyCase[];
}

/** Applique une homographie 3×3 (ligne par ligne) à un point. */
function projectPoint(h: number[], x: number, y: number): HomographyPoint {
  const denom = h[6] * x + h[7] * y + h[8];
  return {
    x: (h[0] * x + h[1] * y + h[2]) / denom,
    y: (h[3] * x + h[4] * y + h[5]) / denom,
  };
}

describe("page_homography.json — redressement d'une page", () => {
  const fixture = loadFixture<HomographyFixture>("page_homography.json");

  for (const c of fixture.cases) {
    const quad = c.quad as unknown as PerspectiveQuad;

    test(`${c.name} : taille de sortie ${c.size.width}×${c.size.height}  (${c.why})`, () => {
      const actual = outputSize(quad);
      assert.deepEqual(actual, c.size);
    });

    test(`${c.name} : l'homographie envoie chaque point où il faut`, () => {
      const destination = [
        { x: 0, y: 0 },
        { x: c.size.width, y: 0 },
        { x: c.size.width, y: c.size.height },
        { x: 0, y: c.size.height },
      ] as unknown as PerspectiveQuad;
      const h = computeHomography(quad, destination);

      for (const probe of c.probes) {
        const got = projectPoint(h, probe.from.x, probe.from.y);
        assert.ok(
          Math.abs(got.x - probe.to.x) < fixture.tolerance &&
            Math.abs(got.y - probe.to.y) < fixture.tolerance,
          `(${probe.from.x}, ${probe.from.y}) attendu en (${probe.to.x}, ${probe.to.y}), ` +
            `obtenu (${got.x}, ${got.y})`,
        );
      }
    });
  }
});

// ── Durées ───────────────────────────────────────────────────────────────────
//
// Le convertisseur prenait le premier nombre puis multipliait par soixante dès
// qu'un « h » traînait quelque part dans la chaîne. « 55 min, plus 4 h de
// réfrigération » rendait 3 300 minutes, et « 30 min de chauffe » en rendait
// 1 800 — parce que « chauffe » porte un h. Aucune erreur, un chiffre absurde
// affiché comme un temps de préparation.
//
// La même fixture est rejouée par `test/cooklang_parser_test.dart`.

interface DurationCase {
  input: string;
  minutes: number | null;
  why: string;
}

describe("cooklang_parsing.json — durées", () => {
  const fixture = loadFixture<{ durations: DurationCase[] }>("cooklang_parsing.json");

  for (const c of fixture.durations) {
    test(`« ${c.input} » → ${c.minutes ?? "aucune durée"}  (${c.why})`, () => {
      assert.equal(parseTimeToMinutes(c.input), c.minutes);
    });
  }
});

// ── Alias du temps de repos ──────────────────────────────────────────────────
//
// Trois clés admises — `temps_repos`, `rest_time`, `repos` — et un seul ORDRE.
// Les trois circulent : la métadonnée française du prompt, la clé Firestore, et
// la forme courte qu'un humain écrit à la main. Ce qui doit être identique des
// deux côtés n'est pas la liste, c'est la priorité : un CookLang qui porte deux
// de ces clés doit rendre la même valeur en Dart et ici.

interface RestAliasCase {
  cooklang: string;
  minutes: number | null;
  why: string;
}

describe("cooklang_parsing.json — priorité des alias du temps de repos", () => {
  const fixture = loadFixture<{ restTimeAliases: RestAliasCase[] }>("cooklang_parsing.json");

  for (const c of fixture.restTimeAliases) {
    test(c.why, () => {
      assert.equal(extractTags(c.cooklang).restTime ?? null, c.minutes);
    });
  }
});

// ── Durées lues d'une recette ────────────────────────────────────────────────
//
// `tags` d'abord, puis le brouillon, puis le texte validé. Le serveur décide ce
// qu'il estime, le client ce qu'il affiche et filtre : s'ils ne lisent pas les
// mêmes durées, la fiche affiche « 20 min » et Explorer « sans durée ».

interface ReadDurationsCase {
  tags: { prep_time?: number; cook_time?: number };
  draft_cooklang: string | null;
  raw_cooklang: string | null;
  prep: number | null;
  cook: number | null;
  why: string;
}

describe("cooklang_parsing.json — durées lues", () => {
  const fixture = loadFixture<{ readDurations: ReadDurationsCase[] }>("cooklang_parsing.json");

  for (const c of fixture.readDurations) {
    test(c.why, () => {
      assert.deepEqual(readDurations(c.tags, [c.draft_cooklang, c.raw_cooklang]), {
        prep: c.prep,
        cook: c.cook,
      });
    });
  }
});
