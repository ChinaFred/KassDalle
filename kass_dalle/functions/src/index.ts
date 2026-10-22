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
 *                                  [recipeProcessor]   (les couvertures : [coverProcessor], file à part)
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
export { recipeProcessor, coverProcessor } from "./pipeline/recipeProcessor";
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
  suggestRecipeTagsFn,
  scanAndPromoteUploadFn,
  detectAndCropIllustrationsFn,
  enhanceIllustrationFn,
  generateRecipeIllustrationFn,
  suggestPlatingFn,
  suggestStorageAdviceFn,
  generatePlatingImageFn,
} from "./callable/geminiCallables";

// Import d'une recette depuis un lien : contrôles, plafond du jour, mise en file.
export {
  importRecipeFromUrlFn,
  getUrlImportQuotaFn,
  ensureWebBookFn,
} from "./callable/urlImportCallable";

// « Chercher sur le web » (Explorer) : recherche Google ancrée, pages résolues,
// plafond du jour et cache partagé. Tous les rôles approuvés.
export { searchWebRecipesFn } from "./callable/webSearchCallable";

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
// Invitations par e-mail : création, renvoi, annulation. Seule fonction qui
// monte les secrets GMAIL_SENDER et GMAIL_APP_PASSWORD ; nodemailer se charge
// au premier envoi.
export { manageInvitationFn } from "./callable/invitationsCallable";
// Recherche d'un membre à inviter dans un groupe, par son adresse exacte :
// réservée au propriétaire du groupe, dix recherches par jour.
export { findMemberByEmailFn } from "./callable/memberSearchCallable";
// Titres des recettes validées des livres privés des membres de mes groupes,
// pour « Suggérer un plat » : le titre seul, jamais le contenu.
export { listFamilyPrivateTitlesFn } from "./callable/privateTitlesCallable";

// ── Tickets (bugs, idées, questions → Issues GitHub) ─────────────────────────
// Création par un membre approuvé, capture jointe par l'auteur, relance,
// validation, refus et réponse à une analyse par l'administrateur. GITHUB_TICKETS_TOKEN est monté par
// ces callables (sauf la capture), la tâche horaire et le webhook (relecture des
// analyses) ; le webhook seul monte
// GITHUB_WEBHOOK_SECRET. Les trois lancements de session (routines Claude Code :
// analyse, développement, livraison) montent l'identifiant et le jeton de leur
// routine ; la livraison prend ceux du développement. Aucun appel d'IA facturé
// au projet.
export {
  submitTicket,
  attachTicketScreenshot,
  retryTicketSend,
  validateTicket,
  refuseTicket,
  answerTicketAnalysis,
  closeTicket,
  launchTicketAnalysis,
  launchTicketDevelopment,
  launchTicketDelivery,
} from "./callable/ticketsCallable";
export { githubTicketWebhook } from "./tickets/webhook";
export { ticketsSyncSchedule } from "./scheduled/ticketsSyncSchedule";
export { releaseNotificationSchedule } from "./scheduled/releaseNotificationSchedule";

// ── Hébergement web ──────────────────────────────────────────────────────────
// Rapports de violation de la Content Security Policy, reçus par la réécriture
// Hosting `/csp-report` (firebase.json). Publique, journalise seulement.
export { cspReportFn } from "./csp/cspReportFn";

// ── Tâches planifiées (Cloud Scheduler) ──────────────────────────────────────
export { scheduledAiReconciliation } from "./scheduled/aiReconciliationSchedule";
export { scheduledAiBudgetAlert } from "./scheduled/aiBudgetAlertSchedule";
export { backfillNutritionFn } from "./callable/nutritionBackfillCallable";
// `scheduledNutritionCatchUp` (tous les jours à 5 h) est retirée en v0.23.45 :
// `scheduledBackfills` lance chaque heure les backfills récurrents programmés
// depuis Admin › Backfills, la nutrition par défaut tous les jours à 5 h.
export { scheduledBackfills } from "./scheduled/backfillSchedule";
export { setBackfillScheduleFn, setBackfillDoneFn } from "./callable/backfillAdminCallable";
export { backfillRecipeRolesFn } from "./callable/recipeRolesBackfillCallable";
export { backfillShoppingFn } from "./callable/shoppingBackfillCallable";
export { backfillAllergensFn } from "./callable/allergensBackfillCallable";
export { backfillUtensilsCleanupFn } from "./callable/utensilsCleanupBackfillCallable";
export { backfillRetentionFn } from "./callable/retentionBackfillCallable";
// `backfillDefaultUnitsFn` (v0.24.40) et `backfillUsersSchemaCheckFn` (v0.24.42) sont retirés en
// v0.24.52 : lancés en production et marqués terminés, leur travail est fait.
// `backfillUserProfilesFn` (v0.23.14) et `backfillGroupReachFn` (v0.23.19) sont retirés en
// v0.23.23 : lancés en production, leur travail est fait. Les déclencheurs `syncUserClaims`
// et `syncGroupReach` tiennent profils et portée à jour.
// `backfillRecipeProteinFn` (v0.23.24), `backfillPlanningDefaultsFn` (v0.23.28) et
// `backfillEstimatedTimesFn` (v0.23.38) sont retirés en v0.23.52 : lancés en production et marqués
// terminés, leur travail est fait. `onRecipeWritten` tient protéine, féculent et durées
// estimées à jour ; un compte sans contraintes enregistrées lit celles par défaut.
// `backfillSystemBooksFn` (v0.23.51), `backfillGroupPlanningReachFn` (v0.23.58),
// `backfillTicketAnalysesFn` (v0.23.63), `backfillTitleKeysFn` (v0.23.97),
// `backfillTicketDeliveredPrFn` (v0.23.99) et `backfillInvitationGroupOwnerFn` (v0.24.14) sont
// retirés en v0.24.33 : marqués terminés en production, leur travail est fait. `syncUserClaims`
// crée les livres système d'un compte approuvé, `syncGroupReach` tient la portée des groupes et
// des plannings, la tâche horaire et le webhook des tickets relisent analyses et PR livrées,
// `onRecipeWritten` pose `titre_key`, et `manageInvitationFn` écrit `group_owner_id`.

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
export { syncPlanningReachOnConfig } from "./triggers/planningReach";
export { syncPlanningReachOnRole } from "./triggers/plannerRole";
export { enforceFounderRole } from "./triggers/founderRole";
// Invitations par e-mail : première connexion d'un compte neuf, reconnexion d'un compte révoqué.
export { applyEmailInvitation, applyRevokedInvitation } from "./triggers/invitationSignup";
