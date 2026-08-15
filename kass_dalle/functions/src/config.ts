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

/**
 * Clé API Anthropic (Claude), stockée dans Secret Manager.
 *
 * Attachée aux fonctions de la chaîne nutrition et au pilotage du routage.
 * `ai/anthropic.ts` la lit via `process.env.ANTHROPIC_API_KEY` — que ce secret
 * peuple une fois monté — plutôt que par `.value()` : une fonction à laquelle
 * le secret n'est pas attaché continue ainsi de fonctionner, servie par Gemini,
 * au lieu de lever une erreur au premier appel.
 */
export const ANTHROPIC_API_KEY = defineSecret("ANTHROPIC_API_KEY");

/**
 * Clé d'administration Anthropic (`sk-ant-admin...`), stockée dans Secret Manager.
 *
 * Distincte de la clé d'inférence : elle seule ouvre le rapport de coûts de
 * l'organisation, qui dit ce qu'Anthropic a réellement facturé. Sans elle, la
 * part Claude de nos coûts reste une estimation que rien ne confronte — la
 * facturation Google, elle, ne la contient pas.
 *
 * Son absence n'est pas une erreur : la réconciliation Claude s'affiche alors
 * comme indisponible, exactement comme le routage se replie sur Gemini quand la
 * clé d'inférence n'est pas posée.
 */
export const ANTHROPIC_ADMIN_KEY = defineSecret("ANTHROPIC_ADMIN_KEY");

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

/**
 * Modèle de génération et de retouche d'images — seul poste facturé à l'unité
 * produite.
 *
 * Nano Banana 2 Lite remplace `gemini-2.5-flash-image` : 0,0336 $ l'image 1K
 * contre 0,04 $, pour une génération annoncée autour de quatre secondes.
 *
 * La constante est ici, et non dans chaque module, parce qu'elle vivait en
 * triple — `imageGenerator.ts`, `enhancer.ts` et `tokenUsage.ts`. Les deux
 * premiers choisissent le modèle appelé, le troisième choisit le modèle
 * FACTURÉ : un changement de version oublié dans `tokenUsage.ts` aurait imputé
 * la dépense au tarif de l'ancien modèle sans qu'aucun écran ne bronche.
 */
export const GEMINI_IMAGE_MODEL = "gemini-3.1-flash-lite-image";

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

/**
 * Agrégats mensuels de consommation — un document par mois (`AAAA-MM`).
 *
 * Les écrans lisaient `ai_usage` document par document, plafonnés à mille
 * lignes, puis additionnaient dans le navigateur : au-delà du plafond, un total
 * affiché n'était plus un total. Ici, un mois se lit en un document.
 */
export const COLL_AI_USAGE_MONTHLY = "ai_usage_monthly";
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
