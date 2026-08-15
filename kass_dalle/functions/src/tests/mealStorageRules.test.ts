/**
 * Seuils d'hygiène cités dans le prompt de conservation.
 *
 * La décision « réfrigérateur ou congélateur » n'existe qu'une fois, côté
 * client, dans `lib/features/planning/domain/meal_storage_rules.dart` : c'est
 * lui qui affiche la consigne. Le serveur ne reprend que les nombres, pour
 * dire au modèle de ne pas les répéter.
 *
 * Ces nombres doivent rester égaux des deux côtés. Un prompt qui parle de cinq
 * jours quand l'écran en affiche trois se contredit sans lever d'erreur, et
 * c'est de la sécurité alimentaire. La fixture partagée les verrouille.
 *
 * Logique pure : ni Firestore, ni réseau, ni appel de modèle.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import { MAX_FRIDGE_DAYS, MAX_COOLING_HOURS } from "../gemini/storageAdvice";

const FIXTURE = path.join(__dirname, "..", "..", "..", "test-fixtures", "meal_storage_rules.json");

const fixture = JSON.parse(readFileSync(FIXTURE, "utf8")) as {
  max_fridge_days: number;
  max_cooling_hours: number;
};

test("la limite du réfrigérateur est la même que côté client", () => {
  assert.equal(MAX_FRIDGE_DAYS, fixture.max_fridge_days);
});

test("le délai de mise au froid est le même que côté client", () => {
  assert.equal(MAX_COOLING_HOURS, fixture.max_cooling_hours);
});
