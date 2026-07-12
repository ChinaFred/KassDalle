/**
 * Configuration centrale des Cloud Functions Kass'Dalle.
 *
 * Toutes les constantes (région GCP, modèle Gemini, noms de queues, etc.)
 * sont définies ici pour éviter les magic strings dans le code métier.
 */

import { defineSecret } from "firebase-functions/params";

// ── Secrets ──────────────────────────────────────────────────────────────────

/** Clé API Gemini, stockée dans Secret Manager. */
export const GEMINI_API_KEY = defineSecret("GEMINI_API_KEY");

// ── Région ───────────────────────────────────────────────────────────────────

/**
 * Région GCP unique pour toutes les fonctions, queues et logs.
 * `europe-west1` (Belgique) = proche de la France et compatible Cloud Tasks.
 */
export const REGION = "europe-west1";

/** ID du projet GCP (résolu depuis l'environnement Cloud Functions). */
export const PROJECT_ID =
  process.env.GCLOUD_PROJECT ?? process.env.GOOGLE_CLOUD_PROJECT ?? "kassdale-6d948";

/** Nom de la fonction Cloud Tasks (handler du worker). */
export const TASK_QUEUE_FUNCTION = "recipeProcessor";

// ── Gemini ───────────────────────────────────────────────────────────────────

export const GEMINI_MODEL = "gemini-2.5-flash";

// ── Cloud Tasks ──────────────────────────────────────────────────────────────

/** Nom de la queue principale pour le traitement des scans. */
export const QUEUE_RECIPE_PROCESSING = "recipe-processing-queue";

/** Nom de la dead-letter queue (jobs ayant échoué après 3 retries). */
export const QUEUE_DLQ = "recipe-dlq";

/** Nombre maximal de jobs traités en parallèle. */
export const MAX_CONCURRENT_DISPATCHES = 5;

/** Nombre de dispatches par seconde (rate limit pour préserver le quota Gemini). */
export const MAX_DISPATCHES_PER_SECOND = 2;

/** Nombre maximal de tentatives avant passage en DLQ. */
export const MAX_RETRY_ATTEMPTS = 3;

// ── Firestore collections ────────────────────────────────────────────────────

export const COLL_PROCESSING_JOBS = "processing_jobs";
export const COLL_RECIPES = "recipes";
export const COLL_BOOKS = "books";
export const COLL_NUTRITION_INGREDIENTS = "nutrition_ingredients";
export const COLL_DEAD_LETTERS = "dead_letters";
export const COLL_TOKEN_USAGE = "token_usage";
export const COLL_AI_USAGE = "ai_usage";
export const COLL_USERS = "users";
export const COLL_APP_CONFIG = "app_config";
export const COLL_AI_RECONCILIATION_MONTHLY = "ai_reconciliation_monthly";
export const COLL_NUTRITION_UNITS = "nutrition_units";

// ── Collections backup ───────────────────────────────────────────────────────
export const COLL_BACKUP_RECIPES = "backup_recipes";
export const COLL_BACKUP_BOOKS = "backup_books";
export const COLL_BACKUP_NUTRITION_INGREDIENTS = "backup_nutrition_ingredients";

// ── Logging ──────────────────────────────────────────────────────────────────

/**
 * Nom du log Cloud Logging unique pour toute l'orchestration.
 * Consultable via `gcloud logging read 'logName="projects/<id>/logs/kass-dalle-pipeline"'`.
 */
export const LOG_NAME = "kass-dalle-pipeline";
