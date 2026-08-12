/**
 * onRecipeWritten — déclencheur unique sur `recipes/{recipeId}`.
 *
 * Deux déclencheurs écoutaient autrefois ce même document : l'un recalculait
 * les produits d'achat, l'autre la nutrition. Chacun réécrivait la recette à la
 * fin de son travail, donc chacun réveillait l'autre. Une seule sauvegarde de
 * recette déclenchait ainsi quatre invocations de fonctions 512 MiB — trois de
 * trop, dont deux ne servaient qu'à constater qu'il n'y avait rien à faire.
 *
 * Les gardes communes (suppression, type de page, empreinte des ingrédients)
 * sont évaluées une fois ici, puis les deux traitements partent ensemble. Ils
 * restent indépendants : l'échec de l'un ne prive pas la recette de l'autre.
 */

import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { ANTHROPIC_API_KEY, GEMINI_API_KEY, REGION } from "../config";
import { logError } from "../logging";
import { ingredientsFingerprint, type StoredIngredient } from "./recipeIngredients";
import { refreshShoppingProducts } from "./recipeShoppingProducts";
import { syncRecipeNutrition } from "./recipeNutritionAutoSync";

export const onRecipeWritten = onDocumentWritten(
  {
    document: "recipes/{recipeId}",
    region: REGION,
    secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY],
    memory: "512MiB" as const,
    // La somme des deux anciens délais : les traitements partent en parallèle,
    // mais le plus lent (nutrition, 180 s) peut désormais devoir attendre son
    // tour derrière les appels Gemini de l'autre en cas de contention.
    timeoutSeconds: 300,
  },
  async (event) => {
    const after = event.data?.after;
    if (!after?.exists) return; // suppression — ignorer

    const data = after.data() as Record<string, unknown>;
    const beforeData = event.data?.before?.data() as Record<string, unknown> | undefined;

    // Ne traiter que les recettes (pas les pages techniques, notes, etc.)
    if (resolvePageType(data) !== "recipe") return;

    const ingredients = (data.ingredients as StoredIngredient[] | undefined) ?? [];
    const beforeIngredients = (beforeData?.ingredients as StoredIngredient[] | undefined) ?? [];
    const ingredientsChanged =
      ingredientsFingerprint(ingredients) !== ingredientsFingerprint(beforeIngredients);

    const args = { after, data, ingredientsChanged };
    const outcomes = await Promise.allSettled([
      refreshShoppingProducts(args),
      syncRecipeNutrition(args),
    ]);

    const labels = ["refreshShoppingProducts", "syncRecipeNutrition"];
    outcomes.forEach((outcome, i) => {
      if (outcome.status !== "rejected") return;
      logError({
        message: `onRecipeWritten: ${labels[i]} a échoué`,
        errorDescription:
          outcome.reason instanceof Error ? outcome.reason.message : String(outcome.reason),
        moduleType: "DESIGN",
        extra: { recipeId: after.id },
      });
    });
  },
);

/**
 * Type de page d'une recette, champ Firestore d'abord, métadonnée CookLang
 * ensuite.
 *
 * Le backend ne lisait que `page_type`. Or le client accepte aussi
 * `>> page_type:` dans le CookLang, et n'écrit le champ Firestore que lorsqu'il
 * vaut autre chose que `recipe` : une page dont le type ne vivait que dans son
 * CookLang était donc traitée ici comme une recette, et recevait un calcul
 * nutritionnel Gemini qu'elle n'aurait jamais dû déclencher.
 */
function resolvePageType(data: Record<string, unknown>): string {
  const field = (data.page_type as string | undefined)?.trim();
  if (field) return field;

  const cooklang = (data.raw_cooklang as string | undefined) ?? "";
  const match = /^>>\s*page_type\s*:\s*(.+)$/im.exec(cooklang);
  return match ? match[1].trim().toLowerCase() : "recipe";
}
