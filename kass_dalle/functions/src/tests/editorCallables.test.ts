/**
 * Callables réservées aux éditeurs et aux administrateurs (ticket #163, point 1).
 *
 * Ces sept entrées écrivent dans une recette, ou préparent un import : polir le
 * CookLang ou le Markdown, affiner une recette, lire une couverture de livre,
 * suggérer des tags, découper des illustrations, contrôler un dépôt en
 * quarantaine. Un lecteur ne modifie ni n'importe rien ; elles passaient
 * pourtant par `requireAuth`, qui laisse entrer tout compte nommé.
 *
 * La garde se lit sur le source : chaque callable doit appeler `requireEditor`
 * avec son poste, et jamais `requireAuth`.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const SOURCE = fs.readFileSync(
  path.join(__dirname, "..", "..", "src", "callable", "geminiCallables.ts"),
  "utf8",
);

/** Le corps d'une callable exportée, jusqu'à l'export suivant. */
function bodyOf(name: string): string {
  const start = SOURCE.indexOf(`export const ${name} = onCall(`);
  assert.notEqual(start, -1, `${name} introuvable dans geminiCallables.ts`);
  const next = SOURCE.indexOf("\nexport ", start + 1);
  return SOURCE.slice(start, next === -1 ? undefined : next);
}

const EDITOR_ONLY: ReadonlyArray<[string, string]> = [
  ["polishCooklangFn", "polish_cooklang"],
  ["polishMarkdownFn", "polish_markdown"],
  ["refineRecipeFn", "refine"],
  ["extractBookCoverFn", "book_cover"],
  ["suggestRecipeTagsFn", "suggest_tags"],
  ["scanAndPromoteUploadFn", "upload_security_scan"],
  ["detectAndCropIllustrationsFn", "detect_illustrations"],
];

describe("callables réservées aux éditeurs (ticket #163, point 1)", () => {
  for (const [name, feature] of EDITOR_ONLY) {
    test(`${name} exige requireEditor("${feature}")`, () => {
      const body = bodyOf(name);
      assert.ok(
        body.includes(`await requireEditor(req, "${feature}")`),
        `${name} doit appeler requireEditor avec le poste ${feature}`,
      );
      assert.ok(!body.includes("requireAuth("), `${name} ne doit plus appeler requireAuth`);
    });
  }
});
