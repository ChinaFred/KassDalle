/**
 * Callables réservées aux éditeurs et aux administrateurs (tickets #162 et
 * #163, décision de l'administrateur : toute IA est réservée aux éditeurs).
 *
 * Ces entrées écrivent dans une recette, préparent un import ou appellent un
 * modèle : polir le CookLang ou le Markdown, affiner une recette, lire une
 * couverture de livre, suggérer des tags, découper des illustrations,
 * contrôler un dépôt en quarantaine, conseiller un dressage, recalculer la
 * nutrition, modérer et publier une image. Elles passaient par `requireAuth`,
 * qui laisse entrer tout compte nommé, lecteur compris.
 *
 * La garde se lit sur le source : chaque callable doit appeler `requireEditor`
 * avec son poste, et jamais `requireAuth`.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

function source(file: string): string {
  return fs.readFileSync(path.join(__dirname, "..", "..", "src", "callable", file), "utf8");
}

/** Le corps d'une callable exportée, jusqu'à l'export suivant. */
function bodyOf(file: string, name: string): string {
  const text = source(file);
  const start = text.indexOf(`export const ${name} = onCall`);
  assert.notEqual(start, -1, `${name} introuvable dans ${file}`);
  const next = text.indexOf("\nexport ", start + 1);
  return text.slice(start, next === -1 ? undefined : next);
}

const EDITOR_ONLY: ReadonlyArray<[string, string, string]> = [
  ["geminiCallables.ts", "polishCooklangFn", '"polish_cooklang"'],
  ["geminiCallables.ts", "polishMarkdownFn", '"polish_markdown"'],
  ["geminiCallables.ts", "refineRecipeFn", '"refine"'],
  ["geminiCallables.ts", "extractBookCoverFn", '"book_cover"'],
  ["geminiCallables.ts", "suggestRecipeTagsFn", '"suggest_tags"'],
  ["geminiCallables.ts", "scanAndPromoteUploadFn", '"upload_security_scan"'],
  ["geminiCallables.ts", "detectAndCropIllustrationsFn", '"detect_illustrations"'],
  ["geminiCallables.ts", "suggestPlatingFn", '"plating_coach"'],
  ["nutritionCallable.ts", "computeRecipeNutritionFn", '"calcul_nutrition"'],
  ["moderationCallables.ts", "moderateAndPromoteImagesFn", "MODERATION_FEATURE"],
];

describe("callables réservées aux éditeurs (tickets #162 et #163)", () => {
  for (const [file, name, feature] of EDITOR_ONLY) {
    test(`${name} exige requireEditor(${feature})`, () => {
      const body = bodyOf(file, name);
      assert.ok(
        body.includes(`await requireEditor(req, ${feature})`),
        `${name} doit appeler requireEditor avec le poste ${feature}`,
      );
      assert.ok(!body.includes("requireAuth("), `${name} ne doit plus appeler requireAuth`);
    });
  }
});
