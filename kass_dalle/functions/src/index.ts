/**
 * Point d'entrée des Cloud Functions Kass'Dalle.
 *
 * Toutes les fonctions exportées ici sont déployées via `firebase deploy --only functions`.
 *
 * Architecture :
 *   ┌────────────────────────────────────────────────────────────────┐
 *   │  Flutter Client                                                │
 *   │   ├─ upload fichier → Storage                                  │
 *   │   └─ crée processing_jobs/{id}  (status: queued)              │
 *   └───────────────────┬────────────────────────────────────────────┘
 *                       │ Firestore trigger
 *                       ▼
 *   [jobDispatcher] ── enqueue ──▶ Cloud Tasks (recipe-processing-queue)
 *                                          │ max 5 // 2/s, 3 retries
 *                                          ▼
 *                                  [recipeProcessor]
 *                                          │   pipeline IMPORT → DECODE → GEMINI → SAVE
 *                                          ▼
 *                                  Firestore (recipes/, processing_jobs/)
 *                                  Cloud Logging (structured logs)
 *
 * Si un job échoue après 3 retries → [deadLetterHandler] le déplace dans dead_letters/.
 *
 * En parallèle, des fonctions HTTPS callable exposent les appels Gemini
 * synchrones (refineRecipe, polishCooklang, searchRecipes, etc.) pour
 * que le client n'ait jamais accès à la clé API.
 */

import { initializeApp } from "firebase-admin/app";

initializeApp();

// ── Async pipeline (Cloud Tasks) ─────────────────────────────────────────────

export { jobDispatcher } from "./pipeline/jobDispatcher";
export { recipeProcessor } from "./pipeline/recipeProcessor";
export {
  relaunchDeadLetterFn,
  deleteDeadLetterFn,
} from "./pipeline/deadLetterHandler";

// ── Sync callable functions (Gemini wrappers) ────────────────────────────────

export {
  extractRecipeFromTextFn,
  polishCooklangFn,
  polishMarkdownFn,
  refineRecipeFn,
  generateRecipeFn,
  searchRecipesFn,
  extractBookCoverFn,
  suggestMealPlanFn,
  consolidateShoppingListFn,
  generateRecipeConceptFn,
  generateWebSearchQueryFn,
  suggestRecipeTagsFn,
  scanAndPromoteUploadFn,
  detectMainCulinaryPhotoFn,
  detectAndCropIllustrationsFn,
  enhanceIllustrationFn,
  generateRecipeIllustrationFn,
} from "./callable/geminiCallables";

// ── Admin functions (logs explorer) ──────────────────────────────────────────
export { queryLogsFn } from "./callable/logsCallable";
export {
  getGcpCostsFn,
  backfillEnhanceUsageFn,
  backfillAiUsageFromLogsFn,
  backfillShoppingProductsFn,
  generateAiReconciliationMonthlyFn,
  backfillRecipeNutritionFn,
  backfillNutritionIngredientsFromRecipesFn,
  backfillNutritionIngredientsPer100gFn,
  backfillNutritionUnitsFromRecipesFn,
  backfillRecipesReferentialsFn,
  rebuildAllNutritionFn,
  resetNutritionReferencesFn,
  initNutritionUnitsFromCsvFn,
  backfillNutritionUnitsLabelFn,
  backupCollectionsFn,
} from "./callable/billingCallable";
export {
  getNutritionSourcePolicyFn,
  setNutritionSourcePolicyFn,
  normalizeNutrientsFn,
  computeRecipeNutritionFn,
  normalizeRecipeReferentialsFn,
} from "./callable/nutritionCallable";

// ── Firestore triggers ────────────────────────────────────────────────────────
export { onRecipeShoppingProductsRefresh } from "./triggers/recipeShoppingProducts";
export { onRecipeNutritionAutoSync } from "./triggers/recipeNutritionAutoSync";

