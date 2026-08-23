/**
 * La FORME de l'agrégat mensuel.
 *
 * Ce qui s'est cassé n'est pas un calcul : c'est une forme. `recordUsage`
 * écrivait ses compteurs avec des clés pointées — `by_user.abc.cost_usd` — et
 * `set()` du SDK Admin ne lit pas les points comme un chemin. Il a donc créé
 * pendant des mois des champs dont le NOM contenait des points, à côté des
 * cartes que les écrans lisent.
 *
 * Les deux ont grandi dans le même document, sans se rencontrer. Les cartes ne
 * bougeaient qu'au passage de la reconstruction ; les champs plats, eux,
 * suivaient chaque appel. L'écran « Dépense par utilisateur » affichait 5 €
 * quand le mois en portait 38, et les deux chiffres étaient sincères — ils ne
 * parlaient pas de la même chose.
 *
 * Rien ne l'a signalé. Ni Firestore, qui accepte un point dans un nom de champ.
 * Ni les règles de sécurité, qui ne valident pas cette collection. Ni un test :
 * la construction de l'objet vivait au milieu d'un `await db.set(...)`, donc
 * n'était vérifiable qu'avec une base.
 *
 * D'où ces cas. Le premier est le seul qui compte vraiment.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { aggregateKeyPaths, buildMonthlyAggregate, sanitizeMapKey } from "../ai/usage";

/** Un appel type, dont on fait varier ce qui compte au cas par cas. */
function appel(surcharge: Partial<Parameters<typeof buildMonthlyAggregate>[0]> = {}) {
  return buildMonthlyAggregate({
    period: "2026-08",
    feature: "recipe_tagging",
    provider: "anthropic",
    model: "claude-sonnet-5",
    userKey: "B2kFStrNovcGTDagtctjzCfcqcI2",
    failed: false,
    priced: true,
    inputTokens: 4813,
    outputTokens: 21693,
    thinkingTokens: 0,
    cacheWriteTokens: 0,
    cacheReadTokens: 0,
    imageOutputCount: 0,
    costIncrement: 0.3398,
    ...surcharge,
  });
}

/**
 * Les clés BRUTES de l'objet, niveau par niveau.
 *
 * Et non les chemins pointés : une fois aplati, `by_user.abc.cost_usd` est
 * indiscernable de trois cartes imbriquées. C'est exactement la confusion qui a
 * produit le défaut, et un test qui la reproduit ne prouve rien.
 */
function clesBrutes(value: unknown): string[] {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return [];
  if (value.constructor && value.constructor.name !== "Object") return [];
  return Object.entries(value as Record<string, unknown>).flatMap(([cle, sous]) => [
    cle,
    ...clesBrutes(sous),
  ]);
}

describe("agrégat mensuel — la forme", () => {
  test("aucune clé ne contient de point", () => {
    const fautives = clesBrutes(appel()).filter((cle) => cle.includes("."));
    assert.deepEqual(
      fautives,
      [],
      "une clé pointée crée un champ dont le NOM porte des points, à côté de la carte",
    );
  });

  test("les compteurs sont des cartes imbriquées, pas des noms pointés", () => {
    const doc = appel();
    // Si la régression revient, ces quatre clés existeront au premier niveau
    // avec un point dans leur nom, et les cartes resteront vides.
    for (const nomPointe of [
      "by_user.B2kFStrNovcGTDagtctjzCfcqcI2.cost_usd",
      "by_feature.recipe_tagging.calls",
      "by_provider.anthropic.cost_usd",
      "by_model.claude-sonnet-5.calls",
    ]) {
      assert.equal(
        Object.prototype.hasOwnProperty.call(doc, nomPointe),
        false,
        `« ${nomPointe} » est un nom de champ, pas un chemin`,
      );
    }

    for (const carte of ["by_user", "by_feature", "by_provider", "by_model"]) {
      assert.equal(typeof doc[carte], "object", `${carte} doit être une carte`);
    }
  });

  test("le poste vit DANS le compte, et pas seulement à côté", () => {
    const chemins = aggregateKeyPaths(appel());
    assert.ok(
      chemins.includes("by_user.B2kFStrNovcGTDagtctjzCfcqcI2.by_feature.recipe_tagging.cost_usd"),
      "sans ce chemin, l'écran « Dépense par utilisateur » n'a rien à ventiler",
    );
  });

  test("le moteur vit DANS le poste, pour qu'une bascule se juge", () => {
    const chemins = aggregateKeyPaths(appel());
    assert.ok(chemins.includes("by_feature.recipe_tagging.by_provider.anthropic.cost_usd"));
  });

  test("les totaux du mois restent au premier niveau", () => {
    const doc = appel();
    for (const total of [
      "total_calls",
      "total_cost_usd",
      "total_input_tokens",
      "total_output_tokens",
      "total_unpriced_calls",
      "total_failed_calls",
    ]) {
      assert.ok(Object.prototype.hasOwnProperty.call(doc, total), `${total} manque`);
    }
    assert.equal(doc.period, "2026-08");
  });

  test("un identifiant de modèle assaini ne casse plus la carte", () => {
    // `gemini-2.5-flash` porte des points : employé tel quel comme clé de
    // carte, il créerait trois niveaux d'imbrication au lieu d'un.
    const cle = sanitizeMapKey("gemini-2.5-flash");
    assert.equal(cle, "gemini-2_5-flash");
    const doc = appel({ model: cle, provider: "gemini" });
    const chemins = aggregateKeyPaths(doc);
    assert.ok(chemins.includes("by_model.gemini-2_5-flash.calls"));
    assert.ok(!chemins.some((c) => c.startsWith("by_model.gemini-2.5")));
  });
});
