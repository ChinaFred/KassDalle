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
export { relaunchDeadLetterFn, deleteDeadLetterFn } from "./pipeline/deadLetterHandler";

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
  suggestMealIdeasFn,
  generateWebSearchQueryFn,
  suggestRecipeTagsFn,
  scanAndPromoteUploadFn,
  detectAndCropIllustrationsFn,
  enhanceIllustrationFn,
  generateRecipeIllustrationFn,
  suggestPlatingFn,
  suggestStorageAdviceFn,
  generatePlatingImageFn,
} from "./callable/geminiCallables";

// Analyse d'un livre entier avant son import : pages, tranches, coût estimé.
export { analyzeBookFileFn } from "./callable/bookImportCallable";

// ── Bac à sable ──────────────────────────────────────────────────────────────
//
// UN seul point d'entrée, une fois pour toutes : `sandboxFn` aiguille sur un
// champ `experiment`. Les expériences suivantes s'ajoutent dans son `switch`
// et ne repassent jamais par ce fichier. Réservé aux administrateurs.
export { sandboxFn } from "./sandbox/callable";

// ── Admin functions (logs explorer) ──────────────────────────────────────────
export { queryLogsFn } from "./callable/logsCallable";
export { getMonthlyCostsFn, rebuildAiUsageMonthlyFn } from "./callable/costsCallable";
export {
  getGcpCostsFn,
  getRecipeReferentialKpisFn,
  backfillEnrichReferentialsFn,
  generateAiReconciliationMonthlyFn,
} from "./callable/billingCallable";
export { getDataQualityReportFn } from "./callable/dataQualityCallable";
export {
  computeRecipeNutritionFn,
  normalizeRecipeReferentialsFn,
  getNutritionSourcePolicyFn,
  setNutritionSourcePolicyFn,
} from "./callable/nutritionCallable";
export {
  getAiRoutingPolicyFn,
  setAiRoutingPolicyFn,
  aiRoutingPresetsFn,
  getAiPricingFn,
  setAiPricingFn,
} from "./callable/aiRoutingCallable";
export { getAppCheckPolicyFn, setAppCheckPolicyFn } from "./callable/appCheckCallable";
export {
  moderateAndPromoteImagesFn,
  reviewModeratedImageFn,
  retryPendingModerationFn,
} from "./callable/moderationCallables";
export { getAiBudgetFn, setAiBudgetFn } from "./callable/budgetCallable";

// ── Tâches planifiées (Cloud Scheduler) ──────────────────────────────────────
export { scheduledAiReconciliation } from "./scheduled/aiReconciliationSchedule";
export { scheduledAiBudgetAlert } from "./scheduled/aiBudgetAlertSchedule";
export { backfillNutritionFn } from "./callable/nutritionBackfillCallable";
export { scheduledNutritionCatchUp } from "./scheduled/nutritionCatchUpSchedule";
export { backfillRecipeRolesFn } from "./callable/recipeRolesBackfillCallable";
export { backfillShoppingFn } from "./callable/shoppingBackfillCallable";
// `backfillUserProfilesFn` (v0.23.14) et `backfillGroupReachFn` (v0.23.19) sont retirés en
// v0.23.23 : lancés en production, leur travail est fait. Les déclencheurs `syncUserClaims`
// et `syncGroupReach` tiennent profils et portée à jour.

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
export { onBookWritten } from "./triggers/bookWritten";
export { syncUserClaims } from "./triggers/userClaimsSync";
export { syncGroupReach } from "./triggers/groupReach";
export { enforceFounderRole } from "./triggers/founderRole";
