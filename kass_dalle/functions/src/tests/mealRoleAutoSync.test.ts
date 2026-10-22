/**
 * Le classement du rôle à l'écriture d'une recette (`syncRecipeMealRole`).
 *
 * Ce que ces tests verrouillent : le déclencheur ne redemande pas au modèle
 * une recette que le backfill a exclue après trois échecs, sauf si son
 * contenu change — le compteur repart alors à zéro —, et l'écriture par
 * laquelle le backfill compte un échec (ou le déclencheur le remet à zéro)
 * ne coûte pas un second appel.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  mealRoleCallAllowed,
  mealRoleContentChanged,
  mealRoleFailureResetNeeded,
  onlyStyleTagsChanged,
} from "../triggers/recipeMealRoleAutoSync";

const base = { titre: "Quiche", raw_cooklang: "@oeufs{3}", tags: { dish_types: ["entrée"] } };

describe("le déclencheur peut-il demander le rôle ?", () => {
  test("recette sans rôle, jamais en échec : oui", () => {
    assert.equal(mealRoleCallAllowed(base, undefined), true);
  });

  test("rôle déjà posé : non", () => {
    assert.equal(mealRoleCallAllowed({ ...base, tags: { meal_role: "plat" } }, undefined), false);
  });

  test("exclue après trois échecs, sans changement de contenu : non", () => {
    const exclue = { ...base, meal_role_failure_count: 3 };
    assert.equal(mealRoleCallAllowed(exclue, undefined), false);
    assert.equal(
      mealRoleCallAllowed({ ...exclue, notes: "à refaire" }, exclue),
      false,
      "une écriture qui ne touche ni le titre ni le CookLang ne la resoumet pas",
    );
    assert.equal(mealRoleCallAllowed(exclue, { ...exclue }), false, "écho identique");
    assert.equal(mealRoleFailureResetNeeded({ ...exclue, notes: "à refaire" }, exclue), false);
    assert.equal(mealRoleCallAllowed({ ...base, meal_role_failure_count: 2 }, undefined), true);
  });

  test("exclue après trois échecs, contenu changé : oui, et le compteur repart à zéro", () => {
    const exclue = { ...base, meal_role_failure_count: 3, meal_role_attempt_at: 1 };
    for (const apres of [
      { ...exclue, titre: "Quiche lorraine" },
      { ...exclue, raw_cooklang: "@oeufs{3}\n@lardons{200%g}" },
      { ...exclue, draft_cooklang: "@oeufs{4}" },
    ]) {
      assert.equal(mealRoleContentChanged(apres, exclue), true);
      assert.equal(mealRoleCallAllowed(apres, exclue), true);
      assert.equal(mealRoleFailureResetNeeded(apres, exclue), true);
    }
  });

  test("remise à zéro : ni à la création, ni sans échec compté", () => {
    const exclue = { ...base, meal_role_failure_count: 3 };
    assert.equal(mealRoleFailureResetNeeded(exclue, undefined), false);
    assert.equal(
      mealRoleFailureResetNeeded({ ...base, titre: "Quiche lorraine" }, base),
      false,
      "aucun compteur : rien à écrire",
    );
  });

  test("écho de la remise à zéro : ni appel, ni nouvelle remise", () => {
    const avant = { ...base, titre: "Quiche lorraine", meal_role_failure_count: 3 };
    const apres = { ...avant, meal_role_failure_count: 0 };
    assert.equal(mealRoleCallAllowed(apres, avant), false);
    assert.equal(mealRoleFailureResetNeeded(apres, avant), false);
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

describe("remise à zéro — recette déjà classée", () => {
  test("une recette qui a un rôle ne remet pas son compteur à zéro", () => {
    const before = { titre: "A", tags: { meal_role: "plat" }, meal_role_failure_count: 2 };
    const after = { ...before, titre: "B" };
    assert.equal(mealRoleFailureResetNeeded(after, before), false);
  });
});

describe("une écriture du seul style ne déclenche pas de classement", () => {
  const before = { ...base, tags: { dish_types: ["entrée"] } };
  const after = {
    ...base,
    tags: { dish_types: ["entrée"], styles: ["street_food"], styles_checked_at: 1 },
  };

  test("le backfill « Style des recettes » écrit le style d'une recette sans rôle : non", () => {
    assert.equal(onlyStyleTagsChanged(before, after), true);
    assert.equal(mealRoleCallAllowed(after, before), false);
  });

  test("un autre tag change avec le style : la garde ne s'applique pas", () => {
    const other = { ...after, tags: { ...after.tags, dish_types: ["plat"] } };
    assert.equal(onlyStyleTagsChanged(before, other), false);
    assert.equal(mealRoleCallAllowed(other, before), true);
  });

  test("le titre change : la garde ne s'applique pas", () => {
    assert.equal(onlyStyleTagsChanged(before, { ...after, titre: "Tarte" }), false);
  });

  test("écho identique : rien n'a changé, ce n'est pas une écriture de style", () => {
    assert.equal(onlyStyleTagsChanged(before, { ...before }), false);
  });
});
