/**
 * Règles de décision de la modération d'images.
 *
 * Logique **serveur seule** : aucun jumeau Dart, donc aucune divergence
 * possible. La fixture n'en est pas moins partagée dans `test-fixtures/` —
 * c'est là que vivent les arbitrages du projet, et celui-ci se lit sans ouvrir
 * le code : violence + contexte culinaire fort = approuvée.
 *
 * Logique pure : ni Firestore, ni réseau, ni appel de modèle.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import {
  decideModeration,
  type ModerationSignals,
  type ModerationThresholds,
} from "../moderation/decision";
import { likelihoodToScore, toModerationSignals } from "../moderation/vision";

const FIXTURE = path.join(
  __dirname,
  "..",
  "..",
  "..",
  "test-fixtures",
  "image_moderation_rules.json",
);

interface Fixture {
  thresholds: ModerationThresholds;
  cases: Array<{
    why: string;
    signals: {
      adult: number | null;
      racy: number | null;
      violence: number | null;
      medical: number | null;
      labels: Array<[string, number]>;
    };
    status: string;
    reason: string;
  }>;
  likelihoods: Array<{ value: string | number; score: number | null }>;
}

const fixture = JSON.parse(readFileSync(FIXTURE, "utf8")) as Fixture;

function signalsOf(raw: Fixture["cases"][number]["signals"]): ModerationSignals {
  return {
    adult: raw.adult,
    racy: raw.racy,
    violence: raw.violence,
    medical: raw.medical,
    raw: {},
    labels: raw.labels.map(([name, score]) => ({ name, score })),
  };
}

describe("decideModeration — fixture partagée", () => {
  for (const c of fixture.cases) {
    test(c.why, () => {
      const decision = decideModeration(signalsOf(c.signals), fixture.thresholds);
      assert.equal(decision.status, c.status, c.why);
      assert.equal(decision.reason, c.reason, c.why);
    });
  }
});

describe("projection des paliers Cloud Vision", () => {
  for (const l of fixture.likelihoods) {
    test(`${JSON.stringify(l.value)} → ${l.score}`, () => {
      assert.equal(likelihoodToScore(l.value), l.score);
    });
  }

  test("un palier inconnu ne vaut pas zéro", () => {
    assert.equal(likelihoodToScore("PROBABLEMENT"), null);
    assert.equal(likelihoodToScore(undefined), null);
  });
});

describe("toModerationSignals", () => {
  test("le suggestif reste SÉPARÉ de l'explicite", () => {
    // Les fusionner par un `max()` a fait refuser une photo de violence pour
    // « contenu sexuel explicite », parce que la victime portait un débardeur.
    const signals = toModerationSignals({ adult: "UNLIKELY", racy: "VERY_LIKELY" }, []);
    assert.equal(signals.adult, 0.25);
    assert.equal(signals.racy, 1);
  });

  test("un critère illisible rend null, pas zéro", () => {
    const signals = toModerationSignals({ adult: "UNKNOWN", racy: "UNKNOWN" }, []);
    assert.equal(signals.adult, null);
    assert.equal(signals.racy, null);
  });

  test("les paliers d'origine sont conservés pour l'affichage", () => {
    const signals = toModerationSignals({ adult: "UNLIKELY", violence: "LIKELY" }, []);
    assert.equal(signals.raw.adult, "UNLIKELY");
    assert.equal(signals.raw.violence, "LIKELY");
  });

  test("un label sans description est écarté plutôt que compté à vide", () => {
    const signals = toModerationSignals({ adult: "VERY_UNLIKELY", violence: "VERY_UNLIKELY" }, [
      { description: "  ", score: 0.9 },
      { description: "food", score: 0.9 },
    ]);
    assert.equal(signals.labels.length, 1);
    assert.equal(signals.labels[0].name, "food");
  });

  test("une absence totale de SafeSearch part en revue, jamais en publication", () => {
    const signals = toModerationSignals(null, [{ description: "food", score: 0.99 }]);
    const decision = decideModeration(signals, fixture.thresholds);
    assert.equal(decision.status, "manual_review");
    assert.equal(decision.reason, "unreadable_signal");
  });
});
