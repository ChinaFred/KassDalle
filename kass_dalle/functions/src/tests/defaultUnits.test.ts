/**
 * Semis des unités standard (`backfillDefaultUnitsFn`).
 *
 * Ce que ces tests verrouillent : la liste recopiée du client en v0.24.40
 * garde ses 40 unités, chacune a le même facteur que la table de repli de
 * `quantityConversion.ts`, et le semis ne fait que créer ou compléter — une
 * valeur présente n'est jamais écrasée, une unité complète n'est pas réécrite.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { DEFAULT_NUTRITION_UNITS, defaultUnitPlan } from "../nutrition/defaultUnits";
import { getKnownUnitMetadata } from "../nutrition/quantityConversion";
import { summarizeDefaultUnits } from "../callable/defaultUnitsBackfillCallable";
import { shouldAutoMarkDone } from "../backfills/schedule";

const brin = DEFAULT_NUTRITION_UNITS.find((u) => u.normalizedUnit === "brin")!;
const cas = DEFAULT_NUTRITION_UNITS.find((u) => u.normalizedUnit === "c_a_s")!;
const piece = DEFAULT_NUTRITION_UNITS.find((u) => u.normalizedUnit === "piece")!;

describe("liste des unités standard", () => {
  test("40 unités, identifiants uniques", () => {
    assert.equal(DEFAULT_NUTRITION_UNITS.length, 40);
    const ids = DEFAULT_NUTRITION_UNITS.map((u) => u.normalizedUnit);
    assert.equal(new Set(ids).size, ids.length);
  });

  for (const unit of DEFAULT_NUTRITION_UNITS) {
    test(`${unit.normalizedUnit} : même type et même facteur que la table de repli`, () => {
      const meta = getKnownUnitMetadata(unit.normalizedUnit);
      assert.ok(meta, "unité inconnue de quantityConversion.ts");
      assert.equal(meta.normalizedUnit, unit.normalizedUnit);
      assert.equal(meta.measurementType, unit.measurementType);
      if (unit.measurementType === "weight") {
        assert.equal(unit.volumeMlPerUnit, null);
        assert.equal(meta.gramsPerUnit, unit.gramsPerUnit);
      } else if (unit.measurementType === "volume") {
        // Une unité de volume ne porte que son volume.
        assert.equal(unit.gramsPerUnit, null);
        assert.equal(meta.mlPerUnit, unit.volumeMlPerUnit);
      } else {
        assert.equal(unit.gramsPerUnit, null);
        assert.equal(unit.volumeMlPerUnit, null);
      }
    });
  }
});

describe("décision du semis", () => {
  test("document absent : création complète, known, builtin", () => {
    assert.deepEqual(defaultUnitPlan(null, cas), {
      action: "create",
      fields: {
        normalized_unit: "c_a_s",
        display_label: "Cuillère à soupe",
        aliases: ["cs", "cas", "tbsp", "c.a.s", "c. à s."],
        measurement_type: "volume",
        grams_per_unit: null,
        volume_ml_per_unit: 15,
        status: "known",
        source: "builtin",
        seen_count: 0,
      },
    });
  });

  test("unité complète : rien d'écrit, même hors statut known", () => {
    assert.deepEqual(
      defaultUnitPlan(
        {
          display_label: "Brin",
          measurement_type: "weight",
          grams_per_unit: 4,
          status: "pending_review",
          source: "fallback_auto",
        },
        brin,
      ),
      { action: "unchanged" },
    );
  });

  test("grammage manquant : complété, statut known, fallback_auto devient builtin", () => {
    assert.deepEqual(
      defaultUnitPlan(
        {
          display_label: "brins",
          measurement_type: "weight",
          status: "unknown",
          source: "fallback_auto",
        },
        brin,
      ),
      {
        action: "patch",
        fields: { grams_per_unit: 2, status: "known", source: "builtin" },
      },
    );
  });

  test("valeurs présentes jamais écrasées ; source admin_validated gardée", () => {
    assert.deepEqual(
      defaultUnitPlan(
        {
          display_label: "",
          measurement_type: "unknown",
          volume_ml_per_unit: 14,
          status: "known",
          source: "admin_validated",
        },
        cas,
      ),
      {
        action: "patch",
        fields: { display_label: "Cuillère à soupe", measurement_type: "volume" },
      },
    );
  });

  test("libellé mal formé : compté comme présent, pas réécrit", () => {
    assert.deepEqual(
      defaultUnitPlan({ display_label: 12, measurement_type: "count", status: "known" }, piece),
      { action: "unchanged" },
    );
  });

  test("type absent : laissé tel quel, comme l'ancien semis", () => {
    assert.deepEqual(defaultUnitPlan({ display_label: "Pièce" }, piece), {
      action: "unchanged",
    });
  });
});

describe("compte rendu", () => {
  const base = {
    total: 40,
    examinees: 40,
    creees: 3,
    completees: 2,
    dejaAJour: 35,
    echouees: 0,
    restantes: 0,
    stoppedByDeadline: false,
    stoppedByErrors: false,
    completed: true,
    aRevoir: { items: [], total: 0 },
  };
  test("liste entière sans échec : ponctuel terminé", () => {
    assert.equal(shouldAutoMarkDone("ponctuel", summarizeDefaultUnits(base)), true);
  });
  test("un échec : ni terminé, ni sans reste", () => {
    const s = summarizeDefaultUnits({
      ...base,
      dejaAJour: 34,
      echouees: 1,
      restantes: 1,
      completed: false,
      aRevoir: { items: [], total: 1 },
    });
    assert.equal(s.complete, false);
    assert.equal(s.remaining, 1);
    assert.equal(shouldAutoMarkDone("ponctuel", s), false);
  });
});
