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
//
// Ce qui est exporté ici est DÉPLOYÉ : chaque ligne est un point d'entrée HTTPS
// public, authentifié mais joignable. Six wrappers y figuraient sans qu'aucun
// écran Flutter ne les appelle — surface exposée et facturée pour rien. Ils
// sont retirés du déploiement, PAS du code : leur logique métier sert toujours
// au backend, et les réexposer se fait en remettant leur nom dans une de ces
// listes. Voir la note « points d'entrée sans client » plus bas.

export {
  extractRecipeFromTextFn,
  polishCooklangFn,
  polishMarkdownFn,
  refineRecipeFn,
  generateRecipeFn,
  searchRecipesFn,
  suggestMealPlanFn,
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
  getRecipeReferentialKpisFn,
  backfillEnrichReferentialsFn,
  generateAiReconciliationMonthlyFn,
} from "./callable/billingCallable";
export {
  computeRecipeNutritionFn,
  normalizeRecipeReferentialsFn,
  cleanupIngredientReferentialFn,
  seedIngredientPieceWeightsFn,
  getNutritionSourcePolicyFn,
  setNutritionSourcePolicyFn,
} from "./callable/nutritionCallable";
export {
  getAiRoutingPolicyFn,
  setAiRoutingPolicyFn,
} from "./callable/aiRoutingCallable";

// ── Tâches planifiées (Cloud Scheduler) ──────────────────────────────────────
export { scheduledAiReconciliation } from "./scheduled/aiReconciliationSchedule";

// ── Points d'entrée sans client ──────────────────────────────────────────────
//
// Déclarés, testés, mais volontairement NON déployés faute d'appelant. Chacun
// attend une décision produit, pas une décision technique :
//
//  • extractBookCoverFn        — l'extraction de couverture se fait dans le
//                                pipeline d'import ; le wrapper synchrone ne
//                                servait qu'à l'ancien import côté client.
//  • consolidateShoppingListFn — la consolidation se fait dans onRecipeWritten.
//  • normalizeNutrientsFn      — outil de reprise ponctuel.

// ── Firestore triggers ────────────────────────────────────────────────────────
export { onRecipeWritten } from "./triggers/recipeWritten";
export { syncUserClaims, backfillUserClaimsFn } from "./triggers/userClaimsSync";

