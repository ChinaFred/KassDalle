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
// (à implémenter en Phase 1.4 — 1.7)

// export { jobDispatcher } from "./pipeline/jobDispatcher";
// export { recipeProcessor } from "./pipeline/recipeProcessor";
// export { deadLetterHandler } from "./pipeline/deadLetterHandler";

// ── Sync callable functions (Gemini wrappers) ────────────────────────────────
// (à implémenter en Phase 1.3)

// export { extractRecipeFromText } from "./callable/extractRecipeFromText";
// export { polishCooklang } from "./callable/polishCooklang";
// export { refineRecipe } from "./callable/refineRecipe";
// export { searchRecipes } from "./callable/searchRecipes";
// export { generateRecipe } from "./callable/generateRecipe";
// export { extractBookCover } from "./callable/extractBookCover";
// export { suggestMealPlan } from "./callable/suggestMealPlan";
// export { detectMainCulinaryPhoto } from "./callable/detectMainCulinaryPhoto";
// export { detectIllustrationRegions } from "./callable/detectIllustrationRegions";

// ── Admin functions ──────────────────────────────────────────────────────────
// (à implémenter en Phase 3)

// export { queryLogs } from "./admin/queryLogs";
// export { relaunchDeadLetter } from "./admin/relaunchDeadLetter";
// export { deleteDeadLetter } from "./admin/deleteDeadLetter";
