/**
 * Le classement du rôle à l'écriture d'une recette (`syncRecipeMealRole`).
 *
 * Ce que ces tests verrouillent : le déclencheur ne redemande pas au modèle
 * une recette que le backfill a exclue après trois échecs, et l'écriture par
 * laquelle le backfill compte un échec ne coûte pas un second appel.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { mealRoleCallAllowed } from "../triggers/recipeMealRoleAutoSync";

const base = { titre: "Quiche", raw_cooklang: "@oeufs{3}", tags: { dish_types: ["entrée"] } };

describe("le déclencheur peut-il demander le rôle ?", () => {
  test("recette sans rôle, jamais en échec : oui", () => {
    assert.equal(mealRoleCallAllowed(base, undefined), true);
  });

  test("rôle déjà posé : non", () => {
    assert.equal(mealRoleCallAllowed({ ...base, tags: { meal_role: "plat" } }, undefined), false);
  });

  test("exclue après trois échecs du backfill : non, à toute écriture", () => {
    const exclue = { ...base, meal_role_failure_count: 3 };
    assert.equal(mealRoleCallAllowed(exclue, undefined), false);
    assert.equal(
      mealRoleCallAllowed({ ...exclue, titre: "Quiche lorraine" }, exclue),
      false,
      "même une vraie modification ne la resoumet pas",
    );
    assert.equal(mealRoleCallAllowed({ ...base, meal_role_failure_count: 2 }, undefined), true);
  });

  test("écriture qui ne change que la mémoire des échecs : non", () => {
    const avant = { ...base, meal_role_failure_count: 1, meal_role_attempt_at: 1 };
    const apres = { ...base, meal_role_failure_count: 2, meal_role_attempt_at: 2 };
    assert.equal(mealRoleCallAllowed(apres, avant), false);
    // Premier échec : les deux champs apparaissent.
    assert.equal(
      mealRoleCallAllowed({ ...base, meal_role_failure_count: 1, meal_role_attempt_at: 1 }, base),
      false,
    );
  });

  test("écriture qui change autre chose : oui", () => {
    const avant = { ...base, meal_role_failure_count: 1 };
    const apres = { ...base, meal_role_failure_count: 1, titre: "Quiche lorraine" };
    assert.equal(mealRoleCallAllowed(apres, avant), true);
    // Un écho identique (aucun champ changé) ne relève pas de cette garde.
    assert.equal(mealRoleCallAllowed(base, { ...base }), true);
  });
});
