/**
 * Effort de réflexion Claude que reçoit un poste, rejoué depuis la fixture
 * partagée `test-fixtures/ai_effort_resolution.json`.
 *
 * Ordre : effort du poste dans la politique, puis effort par défaut de la
 * politique, puis effort du code (`codeEffortFor`). Le client rejoue le même
 * ordre pour l'affichage (`AiRoutingPolicy.effectiveEffortFor`,
 * `test/ai_effort_resolution_test.dart`). Un écart fait annoncer à l'écran
 * une réflexion que le poste ne reçoit pas.
 *
 * Section `model_cases` : serveur seul. Le client reçoit `supportsEffort` du
 * serveur et ne décide pas.
 *
 * Logique pure : ni Firestore, ni réseau.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import {
  DEFAULT_AI_ROUTING_POLICY,
  resolveAnthropicEffort,
  type AiRoutingPolicy,
} from "../ai/router";
import { codeEffortFor, type AnthropicEffort } from "../ai/featureEfforts";
import { modelSupportsEffort, requestShapeFor } from "../ai/anthropic";

const FIXTURE = path.join(
  __dirname,
  "..",
  "..",
  "..",
  "test-fixtures",
  "ai_effort_resolution.json",
);

interface ResolutionCase {
  name: string;
  feature: string;
  code_effort: AnthropicEffort;
  anthropic_efforts: Record<string, AnthropicEffort>;
  anthropic_effort: AnthropicEffort | null;
  expected: AnthropicEffort;
}

interface ModelCase {
  name: string;
  model: string;
  requested: AnthropicEffort;
  supports_effort: boolean;
  sent: AnthropicEffort | null;
}

const fixture = JSON.parse(readFileSync(FIXTURE, "utf8")) as {
  cases: ResolutionCase[];
  model_cases: ModelCase[];
};

function policyFor(c: ResolutionCase): AiRoutingPolicy {
  return {
    ...DEFAULT_AI_ROUTING_POLICY,
    anthropicEfforts: c.anthropic_efforts,
    anthropicEffort: c.anthropic_effort,
  };
}

describe("effort reçu par un poste (fixture partagée)", () => {
  for (const c of fixture.cases) {
    test(c.name, () => {
      // L'effort du code que la fixture donne au client est celui de la table.
      assert.equal(codeEffortFor(c.feature), c.code_effort, "code_effort");
      const effective = resolveAnthropicEffort(policyFor(c), c.feature) ?? codeEffortFor(c.feature);
      assert.equal(effective, c.expected);
    });
  }
});

describe("effort transmis selon le modèle (serveur seul)", () => {
  for (const c of fixture.model_cases) {
    test(c.name, () => {
      assert.equal(modelSupportsEffort(c.model), c.supports_effort);
      assert.equal(requestShapeFor(c.model, c.requested).effort, c.sent);
    });
  }
});
