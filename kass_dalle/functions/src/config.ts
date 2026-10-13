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

/**
 * Compte Gmail expéditeur des invitations par e-mail, et son mot de passe
 * d'application (Secret Manager).
 *
 * Attachés à la seule `manageInvitationFn`. Un secret déclaré et attaché mais
 * absent de Secret Manager fait échouer tout le déploiement : les deux doivent
 * exister avant le premier déploiement qui les déclare (procédure dans
 * TechnicalRequirements.md, « Invitations par e-mail »). Une valeur vide est
 * tolérée : l'envoi est alors refusé avec « Envoi d'e-mail non configuré »,
 * l'invitation reste enregistrée.
 */
export const GMAIL_SENDER = defineSecret("GMAIL_SENDER");
export const GMAIL_APP_PASSWORD = defineSecret("GMAIL_APP_PASSWORD");

/**
 * Jeton GitHub des tickets (Secret Manager) : jeton « fine-grained » limité au
 * dépôt `ChinaFred/KassDalle`, Issues en lecture-écriture, Metadata et Pull
 * requests en lecture.
 *
 * Attaché à `submitTicket`, `retryTicketSend` et `ticketsSyncSchedule`, et lu
 * par `process.env.GITHUB_TICKETS_TOKEN` comme `ANTHROPIC_API_KEY` : une valeur
 * vide n'est pas une erreur, le ticket reste « Envoi en cours » et
 * `app_config/tickets_status.token_invalid_since` le signale à l'administrateur.
 * Comme pour `GMAIL_SENDER`, le secret doit EXISTER dans Secret Manager avant le
 * premier déploiement qui le déclare (une valeur vide suffit) : un secret
 * déclaré et absent fait échouer tout le déploiement des Functions.
 */
export const GITHUB_TICKETS_TOKEN = defineSecret("GITHUB_TICKETS_TOKEN");

/**
 * Secret partagé du webhook GitHub des tickets (Secret Manager), attaché à
 * `githubTicketWebhook` seule. Vide : chaque livraison est refusée (HTTP 503)
 * et journalisée ; la tâche horaire resynchronise les statuts quand même.
 * Même condition d'existence que `GITHUB_TICKETS_TOKEN`.
 */
export const GITHUB_WEBHOOK_SECRET = defineSecret("GITHUB_WEBHOOK_SECRET");

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

/**
 * Nom commercial du modèle image, pour les écrans.
 *
 * L'identifiant technique ne dit pas de quel moteur il s'agit à qui n'a pas la
 * grille en tête. Le label le nomme ; l'identifiant reste affiché à côté, c'est
 * lui qui se retrouve dans le reporting de coûts.
 */
export const GEMINI_IMAGE_MODEL_LABEL = "Nano Banana 2 Lite";

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

/**
 * Plafond d'instances simultanées pour une entrée HTTPS callable.
 *
 * Sans plafond, chaque callable peut monter jusqu'à la limite du projet — cent
 * instances par défaut. Multiplié par les quatre-vingts requêtes concurrentes
 * qu'une instance de 2ᵉ génération sert, et par des appels qui partent chez
 * Gemini ou Anthropic, une boucle mal écrite — la nôtre autant qu'une
 * malveillante — dépense très vite. Dix instances tiennent largement une
 * famille : c'est un garde-fou, pas un dimensionnement.
 *
 * Ce plafond borne le *parallélisme*, pas le total dépensé. Le plafond par
 * compte et par jour reste à écrire, et c'est lui qui bornera la facture.
 */
export const MAX_CALLABLE_INSTANCES = 10;

// ── Firestore collections ────────────────────────────────────────────────────

export const COLL_PROCESSING_JOBS = "processing_jobs";
export const COLL_RECIPES = "recipes";
export const COLL_BOOKS = "books";
export const COLL_NUTRITION_INGREDIENTS = "nutrition_ingredients";
export const COLL_DEAD_LETTERS = "dead_letters";
export const COLL_TOKEN_USAGE = "token_usage";
export const COLL_AI_USAGE = "ai_usage";
export const COLL_USERS = "users";
/**
 * Projection publique de `users/{uid}` : nom et couverture « Recette libre »,
 * lisibles par tout compte approuvé. Écrite par le serveur seul.
 */
export const COLL_USER_PROFILES = "user_profiles";
export const COLL_APP_CONFIG = "app_config";
/** Groupes familiaux : `owner_id` et `member_ids`. */
export const COLL_GROUPS = "groups";
/**
 * Portée des groupes : `group_reach/{uid}.uids` liste les autres comptes avec
 * qui `uid` partage au moins un groupe. Lue par les règles Firestore pour
 * cloisonner livres et recettes. Écrite par le serveur seul.
 */
export const COLL_GROUP_REACH = "group_reach";
/**
 * Invitations par e-mail — `invitations/{id}`. Écrites par les Functions
 * seulement (`manageInvitationFn`, `applyEmailInvitation`), lues par un
 * administrateur.
 */
export const COLL_INVITATIONS = "invitations";

/**
 * Envois d'invitations du jour, par administrateur — `{uid}_{AAAA-MM-JJ}`
 * (jour UTC). Compteur du plafond quotidien de `manageInvitationFn`, sur le
 * modèle de `url_import_daily`. Écrit par les Functions seulement.
 */
export const COLL_INVITATION_SENDS_DAILY = "invitation_sends_daily";

/**
 * Recherches d'un membre par adresse du jour, par compte — `{uid}_{AAAA-MM-JJ}`
 * (jour UTC). Compteur du plafond quotidien de `findMemberByEmailFn`, sur le
 * modèle de `url_import_daily`, avec le nombre de réponses vides du jour.
 * Supprimé par la politique TTL sur `expires_at`. Écrit par les Functions
 * seulement ; aucun accès client.
 */
export const COLL_MEMBER_EMAIL_SEARCH_DAILY = "member_email_search_daily";

/**
 * Portée des plannings : `planning_reach/{uid}.uids` liste les comptes dont
 * `uid` peut lire le planning (`planned_meals`), en lecture seule. Lue par
 * les règles Firestore. Écrite par le serveur seul (`triggers/planningReach.ts`).
 */
export const COLL_PLANNING_REACH = "planning_reach";
export const COLL_AI_RECONCILIATION_MONTHLY = "ai_reconciliation_monthly";

/**
 * Agrégats mensuels de consommation — un document par mois (`AAAA-MM`).
 *
 * Les écrans lisaient `ai_usage` document par document, plafonnés à mille
 * lignes, puis additionnaient dans le navigateur : au-delà du plafond, un total
 * affiché n'était plus un total. Ici, un mois se lit en un document.
 */
export const COLL_AI_USAGE_MONTHLY = "ai_usage_monthly";

/**
 * Dépense d'IA par compte et par jour — `{uid}_{AAAA-MM-JJ}`.
 *
 * Un document par jour plutôt qu'un compteur dans le profil : la remise à zéro
 * quotidienne n'a alors besoin d'aucune tâche planifiée, puisque le lendemain
 * écrit ailleurs, et l'historique reste lisible tel quel.
 */
export const COLL_AI_DAILY_SPEND = "ai_daily_spend";

/**
 * Dépense d'IA par scan — `{scanId}`.
 *
 * Porte le compteur de ce qu'un scan a coûté et, pour un livre importé, le
 * plafond que l'utilisateur a fixé sur l'écran de confirmation. Un import de
 * livre est un seul scan qui déclenche une centaine de jobs : le plafond du jour
 * ne le borne pas pour le fondateur, ce document oui.
 */
export const COLL_SCAN_SPEND = "scan_spend";

/**
 * Imports par lien du jour, par compte — `{uid}_{AAAA-MM-JJ}` (jour UTC).
 *
 * Compteur du plafond quotidien d'`importRecipeFromUrlFn`. Même découpage que
 * `ai_daily_spend` : le jour suivant écrit ailleurs, aucune remise à zéro.
 * Écrit par les Functions seulement.
 */
export const COLL_URL_IMPORT_DAILY = "url_import_daily";

/**
 * Recherches web du jour, par compte — `{uid}_{AAAA-MM-JJ}` (jour UTC).
 *
 * Compteur du plafond quotidien de `searchWebRecipesFn`, sur le modèle de
 * `url_import_daily`. Écrit par les Functions seulement ; le titulaire le lit.
 */
export const COLL_WEB_SEARCH_DAILY = "web_search_daily";

/**
 * Cache partagé des recherches web — `{sha256 de la requête normalisée}`.
 *
 * Sept jours. Ne porte rien de propre à un compte : la requête, les pages
 * trouvées, le bloc de suggestions de Google. Aucun accès client.
 */
export const COLL_WEB_SEARCH_CACHE = "web_search_cache";
export const COLL_NUTRITION_UNITS = "nutrition_units";

/**
 * Configurations de routage enregistrées — un document par configuration.
 *
 * Le routage se règle sur sept champs, dont trois par poste : le moteur, le
 * modèle Claude et le plafond de raisonnement de chacun des quarante-trois
 * postes. Comparer deux moteurs sur des données réelles demande de pouvoir
 * revenir à un état antérieur, et refaire quarante-trois bascules de mémoire
 * n'est pas revenir au même état.
 *
 * Une configuration ne commande rien tant qu'elle n'est pas chargée puis
 * enregistrée : la politique en vigueur reste `app_config/ai_routing_policy`,
 * et elle seule.
 */
export const COLL_AI_ROUTING_PRESETS = "ai_routing_presets";

/**
 * Générations de planning — `users/{uid}/planning_runs/{runId}`.
 *
 * Écrites par le serveur seul : journal des propositions d'une génération,
 * compteur des conceptions rattachées et coût cumulé, pour le plafond par
 * génération. Conservées 180 jours (politique TTL sur `expires_at`).
 */
export const COLL_PLANNING_RUNS = "planning_runs";
/** Préférences de planning, un document par utilisateur (`planning_config/{uid}`). */
export const COLL_PLANNING_CONFIG = "planning_config";

/** Réglages de la présélection du planning — `app_config/planning_policy`. */
export const PLANNING_POLICY_DOC_ID = "planning_policy";

/** Préférences d'un compte — sous-collection `users/{uid}/preferences`. */
export const COLL_USER_PREFERENCES = "preferences";

/**
 * Mémoire des refus du planning — `users/{uid}/preferences/planning_refusals`.
 * Écrite par le titulaire depuis l'application, lue par `suggestMealPlanFn`
 * pour l'appelant seul.
 */
export const PLANNING_REFUSALS_DOC_ID = "planning_refusals";

/** Notes personnelles des recettes — `recipe_ratings/{uid}_{recipeId}`. */
export const COLL_RECIPE_RATINGS = "recipe_ratings";

/** Repas planifiés — `planned_meals/{mealId}`, champ `uid`. */
export const COLL_PLANNED_MEALS = "planned_meals";

// ── Tickets (bugs, idées, questions des membres → Issues GitHub) ────────────

/**
 * Tickets des membres — `tickets/{ticketId}`. Écrits par les Functions seules,
 * sauf `seen_by_author_at`, que l'auteur pose en ouvrant le détail.
 */
export const COLL_TICKETS = "tickets";

/**
 * Compteurs du plafond quotidien des tickets — `{uid}_{AAAAMMJJ}` et
 * `_global_{AAAAMMJJ}` (jour calendaire Europe/Paris). Écrits par
 * `submitTicket` seule, dans la transaction qui crée le ticket ; aucun accès
 * client. Supprimés par la politique TTL sur `expires_at`.
 */
export const COLL_TICKET_QUOTAS = "ticket_quotas";

/** Plafonds des tickets — `app_config/tickets` (`per_member_per_day`, `global_per_day`). */
export const TICKETS_CONFIG_DOC_ID = "tickets";

/** État du jeton GitHub — `app_config/tickets_status` (`token_invalid_since`). Admin seul. */
export const TICKETS_STATUS_DOC_ID = "tickets_status";

/** Dépôt PUBLIC qui reçoit les Issues des tickets. */
export const GITHUB_TICKETS_OWNER = "ChinaFred";
export const GITHUB_TICKETS_REPO = "KassDalle";

/**
 * Seul compte GitHub dont un commentaire « Réponse : … » devient la réponse
 * montrée au membre (`reply_text`). Tout autre commentaire reste sur GitHub.
 *
 * La comparaison porte sur l'identifiant numérique du compte
 * (`user.id`), qui ne change pas : un login se renomme, et un login libéré
 * peut être repris par un autre compte.
 */
export const GITHUB_TICKETS_MAINTAINER_ID = 16348852; // compte ChinaFred

/**
 * Essais d'envoi au-delà desquels un ticket « Envoi en cours » n'est plus
 * repris par la tâche horaire : il passe « en anomalie » dans Admin › Tickets,
 * d'où `retryTicketSend` le relance.
 */
export const TICKET_MAX_SEND_ATTEMPTS = 10;

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
