# Spécifications Techniques — Kass'dalle
## Livre de Cuisine Digital (Flutter + Firebase)

> Version : 2.2 — 2 Juin 2026

> **Ce document décrit l'état actuel de l'application.** Ce qui a changé d'une version à
> l'autre se lit dans [CHANGELOG.md](CHANGELOG.md), où 32 sections « Mise à jour
> release » ont été déplacées telles quelles.

## 1. Architecture Générale

Le client ne parle à aucun fournisseur d'IA. Il parle à Firebase, et Firebase parle aux
moteurs — jamais l'inverse. C'est ce qui permet aux clés de vivre en Secret Manager, et au
choix du moteur de se faire dans un document Firestore plutôt que dans un déploiement.

```
┌──────────────────────────────────────────────────────────────┐
│                       Clients Flutter                         │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│   │   Mobile     │  │     Web      │  │    Desktop       │   │
│   │ iOS/Android  │  │   Browser    │  │    Windows       │   │
│   └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘   │
└──────────┼─────────────────┼───────────────────┼─────────────┘
           │                 │                   │
           └─────────────────┼───────────────────┘
                             │ Firebase SDK (FlutterFire) + App Check
           ┌─────────────────▼─────────────────────────────────┐
           │                 Firebase Backend                   │
           │  ┌──────────┐ ┌───────────┐ ┌────────┐ ┌────────┐ │
           │  │   Auth   │ │ Firestore │ │Storage │ │Hosting │ │
           │  │ Google + │ │  données  │ │ quaran-│ │  web   │ │
           │  │  claims  │ │ + config  │ │ taine  │ │        │ │
           │  └──────────┘ └───────────┘ └────────┘ └────────┘ │
           │  ┌──────────────────────────────────────────────┐ │
           │  │        Cloud Functions (Node 22 / TS)         │ │
           │  │  callable · pipeline Cloud Tasks · triggers   │ │
           │  │  scheduled · gardes requireAuth/Editor/Admin  │ │
           │  └───────────────────┬──────────────────────────┘ │
           └──────────────────────┼────────────────────────────┘
                                  │ ai/router — lit app_config,
                                  │ vérifie le plafond, écrit le coût
        ┌─────────────────────────┼─────────────────────────┐
        ▼                         ▼                         ▼
┌───────────────┐        ┌────────────────┐       ┌──────────────────┐
│ Google Gemini │        │ Anthropic      │       │ Google Cloud     │
│ gemini-2.5-*  │        │ Claude Sonnet  │       │ Vision           │
│ défaut, repli │        │ si désigné     │       │ modération seule │
└───────────────┘        └────────────────┘       └──────────────────┘
```

Trois fichiers, et trois seulement, importent un SDK de fournisseur :
`gemini/client.ts`, `ai/anthropic.ts` et `moderation/vision.ts` — ce dernier par un
`await import()` **dynamique**. Le SDK Vision tire gRPC et protobuf : le charger au
démarrage d'`index.ts` fait dépasser le budget de dix secondes du déploiement et ralentit
le démarrage à froid des cinquante fonctions du bundle.

**Aucun SDK lourd au niveau module.** Même règle, élargie : Cloud Logging (écriture *et*
lecture) et BigQuery se chargent par `await import()` au premier usage, leur client
mémorisé. Un client construit au niveau module — `const x = new Logging()` — est un import
statique déguisé et coûte le même prix. Le bundle est passé de 547 ms à 328 ms au
chargement ; c'est ce plafond de découverte qui faisait échouer la première tentative de
chaque déploiement, invariablement rattrapée par une relance. `deploy.ps1` porte en outre
`FUNCTIONS_DISCOVERY_TIMEOUT=120` : un échec systématique que l'on rattrape finit par
masquer le jour où l'échec est réel.

**Le modèle Claude se choisit par POSTE.** `AiRoutingPolicy.anthropicModels`
(`Record<feature, model>`) l'emporte sur `anthropicModel` ; `resolveAnthropicModel(policy,
feature)` tranche, et sert aussi bien à l'appel qu'à l'enregistrement de la consommation —
un modèle appliqué mais mal reporté fausserait la comptabilité sans lever d'erreur. Le
fournisseur se choisissait déjà poste par poste, le modèle non : basculer un poste sur Claude
imposait le même modèle à tous les autres. Transcrire une page de livre demande de la
précision et se paie à la page ; estimer les calories d'une carotte est un rappel de
connaissances répété quinze fois par recette. Écran **Admin → Moteur d'IA** : le sélecteur
n'apparaît que sous un poste effectivement routé vers Claude — l'afficher inactif ailleurs
ferait croire qu'il manque un réglage alors qu'il manque une bascule ; un poste réglé sur le
défaut **n'écrit rien**, pour ne pas le figer le jour où le défaut change ; et seuls les
identifiants de `ANTHROPIC_MODEL_CHOICES` sont acceptés à l'écriture, tous présents dans la
grille tarifaire — un modèle hors grille se facturerait sans montant et gonflerait
`total_unpriced_calls`.

**L'effort de réflexion Claude se choisit aussi par POSTE, depuis le 27 septembre 2026.**
`AiRoutingPolicy.anthropicEfforts` (`Record<feature, "low"|"medium"|"high">`) est résolu par
`resolveAnthropicEffort(policy, feature)` et appliqué dans `callModel`, avant l'appel Claude.
Contrairement au modèle, il n'y a pas de repli global : un poste sans réglage garde l'effort
que **son propre code** pose (`ModelCallContext.effort`), parce qu'aucun effort commun n'a de
sens entre la lecture d'une page et un rappel de calories. Écran **Admin → Moteur d'IA**, même
sélecteur de visibilité que le modèle, avec une puce « Réglage du code » qui efface
l'exception plutôt que de la pointer vers une valeur partagée.

**Le soin se choisit par poste.** `ModelCallContext.effort` (`low` par défaut) pilote
`output_config.effort` chez Claude. Ce réglage était figé à `low` pour tous les postes, avec
une justification qui ne vaut que pour la nutrition — estimer les calories d'un ingrédient
est un rappel de connaissances, pas un problème de raisonnement, et les jetons de réflexion
se facturent au tarif de sortie. Transcrire une page de livre est l'exact contraire :
`transcription_page` demande `high` ; `recipe_tagging` est passé à `low` le 26 septembre 2026,
mesuré sur les mêmes 33 transcriptions rejouées aux deux efforts : même contrôle `checkFidelity`,
aucune rupture de plus, 0,118 $ l'appel contre 0,298 $. Le balisage recopie un texte déjà lu et
`checkFidelity` le compare à cette entrée, alors que la transcription lit une image sans contrôle
équivalent — c'est ce qui rend l'effort réduit sûr d'un côté et risqué de l'autre. La panne n'était
visible que depuis la réparation du streaming : jusque-là Claude échouait sur la transcription et
Gemini prenait le relais, si bien que réparer l'appel a confié la lecture à un moteur réglé pour
aller vite.

Côté Gemini, le levier équivalent existe depuis l'origine et se règle sans déploiement —
`thinking_budgets` par poste dans `app_config/ai_routing_policy` (`anthropic_efforts` côté
Claude, en snake_case dans le même document).

**La lecture de page a été mesurée sur 6 pages, à trois réglages** (27-28 septembre 2026) :
Opus 5 forte (la référence de l'époque), Sonnet 5 forte, Opus 5 moyenne. Sonnet 5 coûte 14 à
62 % de moins qu'Opus 5 à effort égal ; réduire l'effort d'Opus, lui, économise entre rien et
16 %, parfois négatif. Chaque candidat a montré une fois un résultat différent de la référence
— une lettre insérée par Sonnet dans un titre à lettrine décorative, un désaccord de comptage
par candidat sur deux autres pages — jugés mineurs et sans effet sur la compréhension de la
recette. Décision : `transcription_page` passe à Sonnet 5, effort `high` inchangé — un
changement de MODÈLE, posé dans `anthropic_models` depuis Admin → Moteur d'IA, sans
déploiement.

**Deux prompts se mettent en cache, depuis le 28 septembre 2026** —
`TRANSCRIPTION_PROMPT` (`gemini/transcription.ts` → `transcribePage`, ~2 900 jetons) et
`TAGGING_PROMPT` (`gemini/tagging.ts` → `tagAndNormalize`, ~3 250 jetons, rôle du repas
inclus) : les deux plus gros prompts du projet, sur les deux postes les plus appelés.
`textPart(texte, { cache: true })` marque le fragment ; `toAnthropicContent`
(`ai/anthropic.ts`) pose `cache_control: { type: "ephemeral" }` sur le bloc correspondant —
Anthropic met alors en cache tout ce qui précède ce bloc, lui compris, et le relit à un
dixième du tarif d'entrée pendant cinq minutes, prolongées à chaque relecture.

Un bloc marqué ne sert que s'il est un PRÉFIXE identique d'un appel à l'autre — jamais ce
qu'il précède. `TRANSCRIPTION_PROMPT` est donc passé en tête des `parts`, devant l'image de
la page (qui change à chaque appel) : il y était en dernier, ce qui aurait empêché tout cache,
l'image divergente arrivant avant lui. `TAGGING_PROMPT` était déjà en tête, mais fondu avec la
transcription dans une seule chaîne — Anthropic ne met en cache qu'un bloc ENTIER, jamais un
fragment d'une chaîne : il fallait le séparer en deux `textPart`, pas le déplacer.

**Les réponses Claude sont streamées.** Le SDK Anthropic refuse un appel non-streamé dès
que `max_tokens` dépasse `128 000 / 6 ≈ 21 333` — au-delà, il estime que la réponse
*pourrait* demander plus de dix minutes et lève « Streaming is required for operations that
may take longer than 10 minutes » **avant d'envoyer quoi que ce soit**. Ce n'est pas une
durée constatée, c'est une borne calculée depuis le plafond demandé. La transcription d'une
page en réclame 24 000 pour ne pas tronquer un JSON verbeux : elle échouait donc
systématiquement sur Claude et se repliait sur Gemini à chaque import — le repli
fonctionnait, il masquait la panne. Baisser le plafond serait la mauvaise réponse :
`max_tokens` ne réserve rien, il borne, et le réduire tronquerait les pages longues.
`callAnthropic` utilise donc `messages.stream(...).finalMessage()`, qui rend exactement
l'objet attendu — jetons, `stop_reason` et blocs de contenu compris.

---

## 2. Stack Technique

| Composant | Technologie | Version |
|---|---|---|
| Framework UI | Flutter | Dart SDK `^3.11.4` |
| Authentification | `firebase_auth` + `google_sign_in` | `^6.4.0` / `^7.2.0` |
| Base de données | `cloud_firestore` | `^6.3.0` |
| Stockage fichiers | `firebase_storage` | `^13.3.0` |
| Appels serveur | `cloud_functions` | `^6.3.1` |
| Attestation | `firebase_app_check` | `^0.4.6` (ni Windows ni Linux) |
| State management | Riverpod | `^3.3.1` |
| Navigation | go_router | `^17.2.3` |
| Image (mobile) | `image_picker` + `image_cropper` | `^1.2.2` / `^12.2.1` |
| Export PDF | `pdf` | `^3.11.1` |
| Parsing CookLang | implémentation maison, jumelée avec `functions/src/cooklang/` | — |
| **IA côté client** | **aucune** — pas de SDK de fournisseur dans le binaire ni dans le bundle web | — |

Côté Cloud Functions (Node 22, TypeScript) :

| Composant | Paquet |
|---|---|
| Runtime Functions | `firebase-functions` ^7.2.5, `firebase-admin` ^12.7.0 |
| Gemini | `@google/generative-ai` ^0.21.0 |
| Claude | `@anthropic-ai/sdk` ^0.116.0 |
| Modération d'images | `@google-cloud/vision` ^6.0.0, chargé dynamiquement |
| File d'import | `@google-cloud/tasks` ^5.5.2 |
| Coûts d'infrastructure | `@google-cloud/bigquery` ^7.9.4 |
| Explorateur de logs | `@google-cloud/logging` ^11.2.0 |
| Images et archives | `sharp` ^0.35.5, `jszip` ^3.10.1 |
| Découpage des livres PDF | `pdf-lib` ^1.17.1, chargé à la demande |

---

## 3. Schéma de Données Firestore

### Vue d'ensemble

```
firestore/
├── users/{uid}/
│   ├── nutrition_portion_overrides/{recipeId}     ← état propre à UN lecteur
│   └── preferences/{prefId}                       ← book_order, recipe_search_scope
├── user_profiles/{uid}/                           ← nom public, écrit par le serveur seul
├── books/{bookId}/
├── recipes/{recipeId}/
│   └── annotations/{annotationId}/
├── recipe_ratings/{uid}_{recipeId}/
├── groups/{groupId}/
├── processing_jobs/{jobId}/
├── dead_letters/{jobId}/
├── planned_meals/{mealId}/                        ← porteur du contexte (personne, date)
├── planning_config/{uid}/
├── nutrition_ingredients/{ingredientId}/
├── nutrition_units/{unitId}/
├── meal_staples/{stapleId}/                       ← garnitures simples, référentiel partagé
├── image_moderation/{moderationId}/
├── ai_usage/{id}/                                 ← une ligne par appel
├── ai_usage_monthly/{AAAA-MM}/
├── ai_daily_spend/{uid}_{AAAA-MM-JJ}/
├── scan_spend/{scanId}/                           ← compteur et plafond d'un import de livre
├── ai_reconciliation_monthly/{AAAA-MM}/
├── token_usage/{uid}/
├── error_reports/{id}/
└── app_config/{decision}/                         ← routage, tarifs, plafonds, attestation…
```

---

### 3.1 Collection `users`

Créée automatiquement à la première connexion Google.

| Champ | Type | Description |
|---|---|---|
| `uid` | `String` | UID Google Firebase (= ID du document) |
| `email` | `String` | Adresse email du compte Google |
| `display_name` | `String` | Nom d'affichage Google, coupé à 60 unités UTF-16 par le client (`UserProfile.truncateName` ; un emoji compte pour 2, comme `string.size()` dans les règles) ; `""` si le compte Google n'en a pas (avant la v0.23.14 : `"Utilisateur"`). Les règles refusent plus de 60 unités UTF-16 à la création et à la modification du champ |
| `preferred_name` | `String?` | 60 unités UTF-16 au plus, un emoji comptant pour 2 (règles, champ de saisie et `AuthRepository.updatePreferredName`). Nom sous lequel la famille voit cette personne et sa bibliothèque. Absent ou vide = le **prénom** du compte Google (premier mot de `display_name`). Écrit depuis **Profil et compte** par chacun pour soi, et depuis **Admin → Gestion des utilisateurs** par un administrateur pour n'importe qui. Lu par `AppUser.displayedName`, qui applique le repli. |
| `photo_url` | `String?` | URL de l'avatar Google |
| `role` | `String` | Enum : `admin` \| `editor` \| `reader` \| `pending` |
| `created_at` | `Timestamp` | Date de première connexion |
| `last_seen_at` | `Timestamp` | Date de dernière connexion active |
| `is_revoked` | `Boolean` | `true` si l'accès a été révoqué par un Admin |
| `free_recipe_cover_url` | `String?` | Couverture choisie pour « Mes recettes libres ». Écrite par `auth_repository.dart` sous `users/{uid}/free_recipe_cover_*.jpg` ; le fichier précédent est supprimé au remplacement |
| `import_illustrations` | `Boolean` | Défaut de la case « Extraire les illustrations » de l'écran d'import. Absent = `true`. Écrit par **Préférences** (`features/auth/presentation/preferences_screen.dart`), lu par `UserPreferencesRepository`. C'est un **défaut**, pas un verrou : chaque import peut le changer pour lui seul, sans que ce choix remonte ici. |

**Nom préféré et nom Google :** `display_name` est réécrit à chaque connexion depuis le compte
Google — il ne peut pas servir de nom modifiable. `preferred_name` est un champ libre, et son
absence n'est jamais comblée par une écriture : la valeur par défaut se **calcule** à la lecture
(`AppUser.defaultPreferredName`). Figer le prénom dans Firestore le laisserait périmé le jour où le
compte Google change de nom.

**Rôle à la création :** forcé à `pending` **par les règles**, avec `is_revoked == false` et
`email == request.auth.token.email`. Le client ne choisit ni le rôle, ni l'identité. Un rôle absent
ou inconnu est relu comme `pending` par `AppUser.fromFirestore` : le repli ferme.

**Bootstrap Admin :** le déclencheur `enforceFounderRole` (`triggers/founderRole.ts`) rend le rôle
`admin` au seul compte fondateur, identifié par l'adresse du compte **Auth** (`getAuth().getUser`)
et non par le champ `email` du document, qu'un client a pu écrire. Il est *idempotent* et
*réparateur* : il rétablit `role: 'admin'`, `is_revoked: false` si l'un des deux a été modifié, et
ne réécrit rien quand ils sont corrects — d'où l'absence de boucle. Les règles interdisent par
ailleurs à tout autre administrateur de toucher au rôle, à la révocation ou à l'existence de ce
document.

**Lecture :** `users/{uid}` ne se lit que par son titulaire et par un administrateur
(v0.23.14). Le nom d'un autre membre se lit dans `user_profiles/{uid}` (§3.1 bis).

### 3.1 bis Collection `user_profiles` — le profil public

La part d'un compte que les autres membres voient. Le document a pour identifiant l'`uid` du
compte. Il est **écrit par le serveur seul** et lu par tout compte nommé (`isApproved()`).

| Champ | Type | Description |
|---|---|---|
| `display_name` | `String` | Copie de `users/{uid}.display_name`, espaces de bord retirés, coupée à 60 unités UTF-16 (`truncateName`, `MAX_NAME_LENGTH`), sans couper un caractère en deux ; `""` si absent ou mal formé |
| `preferred_name` | `String?` | Copie de `users/{uid}.preferred_name`, coupée à 60 unités UTF-16 ; `null` si absent ou vide |
| `free_recipe_cover_url` | `String?` | Copie de `users/{uid}.free_recipe_cover_url` : la couverture de « Mes recettes libres », affichée dans le détail d'une recette libre de ce compte |
| `updated_at` | `Timestamp` | Heure serveur de la dernière écriture |

**Jamais recopiés :** `email`, `role`, `is_revoked`, `photo_url`, `created_at`, `last_seen_at`,
`import_illustrations`. Aucun écran n'affiche la photo d'un autre membre : elle n'est pas
recopiée.

**Qui a un profil :** un compte de rôle `reader`, `editor` ou `admin`, révoqué ou non. Un compte
révoqué garde son nom d'auteur sur ses recettes. Un compte `pending` (ou sans rôle) n'a pas de
profil : il n'apparaît ni dans la recherche de membres d'un groupe, ni sous un nom. Un compte
supprimé perd son profil.

**Qui l'écrit :** `syncUserClaims`, déclencheur sur `users/{uid}`, à chaque écriture du compte,
par `syncPublicProfile` (`triggers/userPublicProfile.ts`). Il lit le profil stocké, le compare
aux champs publics attendus, et n'écrit que s'ils diffèrent : une connexion, qui ne change que
`last_seen_at`, coûte une lecture et aucune écriture. La comparaison se fait contre le profil en
base : un profil absent se recrée à la première écriture du compte. `backfillUserProfilesFn`
(Admin › Backfills, §7.10) applique la même fonction à tous les comptes existants.

**Lecture côté client :** `UserProfileRepository.getProfile` (`features/auth/data/`), exposé
par `userProfileProvider(uid)` et `memberNameProvider(uid)` (`auth_providers.dart`). Un profil
lu avec succès est gardé pour la session (`keepAlive`) ; une lecture en échec ne l'est pas. Le
compte courant ne lit pas son profil : il se tire de son propre document (`appUserProvider`),
en direct, et garde le repli sur la partie locale de son adresse s'il n'a pas de nom Google.

**Un seul repli : « Membre »** (`UserProfile.fallbackName`), pour un profil absent ou illisible
comme pour un compte sans nom. Le nom affiché suit `UserProfile.displayedName` : nom préféré,
sinon premier mot de `display_name`, sinon « Membre » — la règle d'`AppUser.displayedName`,
sans le repli sur l'adresse. Là où « Membre » ferait une phrase vide, l'écran la reformule ou se
tait : « Livres d'un membre », « Recettes libres d'un membre », et pas de phrase d'origine
(`libraryOriginProvider`) sur un livre partagé. Le filtre par compte de la file de travail,
réservé à l'administrateur, lit `users/` (`allUsersProvider`) et affiche le nom et l'adresse,
pour que deux comptes sans profil restent distincts.

---

### 3.2 Collection `books`

| Champ | Type | Description |
|---|---|---|
| `id` | `String` | ID auto-généré Firestore |
| `titre` | `String` | Titre du livre |
| `sous_titre` | `String?` | Sous-titre du livre |
| `editeur` | `String?` | Maison d'edition |
| `serie` | `String?` | Nom de serie (si applicable) |
| `auteur` | `String` | Auteur(s) — champ libre |
| `annee` | `int?` | Année de publication |
| `langue` | `String` | Code ISO 639-1 (ex : `fr`, `it`, `zh`, `nl`) |
| `isbn` | `String?` | ISBN detecte ou saisi |
| `description` | `String?` | Description structuree du livre |
| `url_couverture` | `String?` | URL Firebase Storage vers la photo de couverture |
| `tags` | `List<String>` | Étiquettes libres (ex : `pâtisserie`, `terroir belge`) |
| `review_status` | `String` | Enum : `draft` \| `validated` |
| `is_private` | `bool` | Livre réservé à son créateur. Basculé depuis le formulaire de livre ; verrouillé à `true` sur « Mes Recettes Secrètes » (`__secretes`). `onBookWritten` recopie la valeur sur toutes les recettes du livre |
| `created_by` | `String` | UID de l'utilisateur créateur |
| `created_at` | `Timestamp` | Date de création |
| `updated_at` | `Timestamp` | Date de dernière modification |
| `source_file_url` | `String?` | URL du fichier source IA |
| `source_file_name` | `String?` | Nom du fichier source |
| `ai_processed_at` | `Timestamp?` | Date du traitement IA |

---

### 3.3 Collection `recipes`

Document principal d'une recette.

| Champ | Type | Description |
|---|---|---|
| `id` | `String` | ID auto-généré Firestore |
| `titre` | `String` | Titre de la recette |
| `book_id` | `String?` | Identifiant du livre (`books/{bookId}`), nullable si sans livre |
| `book_titre` | `String?` | Dénormalisation du titre du livre pour les requêtes |
| `page_number` | `int?` | Numéro de page dans le livre source |
| `langue` | `String` | Code ISO 639-1 de la langue de la recette |
| `raw_cooklang` | `String` | Contenu Cooklang validé (version finale) |
| `draft_cooklang` | `String?` | Version en cours de révision (avant validation) |
| `image_urls` | `List<String>` | URLs Firebase Storage des scans originaux (multi-pages) |
| `thumbnail_urls` | `List<String>` | Vignettes WebP 400 px générées côté serveur, **même ordre et même longueur que `image_urls`** — voir « L'alignement des vignettes » ci-dessous. Vide sur les anciens enregistrements : l'UI retombe alors sur `image_urls` |
| `review_status` | `String` | Enum : `draft` \| `in_review` \| `validated` |
| `is_private` | `bool` | Confidentialité **du livre porteur**. Écrite par le client depuis le livre à chaque écriture qui pose ou change le livre (`privacyOfBook`, exigé par la règle `bookCheck` ; sans livre, rien n'est réécrit), et alignée par le serveur (`onRecipeWritten` → `syncRecipePrivacy`, `onBookWritten`). Les recettes antérieures au champ l'ont reçu d'un backfill, `backfillRecipePrivacyFn`, passé au complet puis retiré le 5 octobre 2026. Une recette sans livre **garde** sa valeur (`privacyWithoutBook`) : une page détachée d'un livre privé reste privée ; une recette neuve sans livre vaut `false`. Sans ce champ, savoir si l'on peut montrer une recette obligeait à lire son livre — ce qu'une règle Firestore ne peut pas faire sur une requête de liste (20 lectures de document au plus, et un `get()` sur le livre en coûterait une par recette renvoyée) |
| `tags` | `Map<String, dynamic>` | Voir structure détaillée ci-dessous |
| `ingredients_index` | `List<String>` | Noms des ingrédients en minuscules, sans doublon — index de recherche. Dérivé de `ingredients`, jamais du CookLang brut (cf. « Écrivain unique » ci-dessous) |
| `created_by` | `String` | UID du créateur |
| `created_at` | `Timestamp` | Date de création |
| `updated_at` | `Timestamp` | Date de dernière modification |
| `source_file_url` | `String?` | URL du fichier source importe |
| `source_file_name` | `String?` | Nom du fichier source importe |
| `additional_source_file_urls` | `List<String>` | Pages supplémentaires d'un scan multi-pages |
| `ai_processed_at` | `Timestamp?` | Date du traitement IA |
| `portions` | `int?` | Nombre de portions extrait/saisi |
| `rest_time` | `int?` | Temps de repos en minutes, distinct de la préparation et de la cuisson. Une pâte qui lève trois heures ne se prépare pas en trois heures |
| `ingredients` | `List<Map>` | Liste structurée `{name, qty, unit, category?, note?}` — cf. « Contrat ingrédient ». `note` porte ce que la ligne du livre dit en plus de la quantité (« avec la peau mais écaillée ») : la quantité se compte, la précision se lit. La couleur, la variété et l'espèce font partie de `name` (« poivron rouge »), jamais de `note` : la lecture fusionne les entrées de même nom et même section, sauf si chacune porte une note et que les notes diffèrent |
| `page_type` | `String?` | `recipe` \| `technique` \| `equipment` \| `ingredient_note` \| `other`. **Écrit uniquement s'il vaut autre chose que `recipe`** ; à défaut, les lecteurs se rabattent sur `>> page_type:` dans `raw_cooklang` |
| `shopping_products` | `List<Map>` | Produits d'achat `{name, qty, unit}`, écrits par `onRecipeWritten` (`deriveShoppingProducts`, fixture `shopping_products.json`). **Une entrée par produit et famille d'unité** : kilo et grammes s'additionnent (`1,5 kg`), litre, centilitre et millilitre aussi ; un comptage et un poids restent deux entrées sous le même nom — le client les affiche sur une ligne, « 2 kg + 6 pommes de terre ». Le nom est le `shopping_product` du référentiel quand il existe (« beurre » pour « beurre fondu »), sinon la première orthographe lue. Absent tant qu'aucun calcul n'a eu lieu ; *Admin › Backfills › Recalculer les produits d'achat* le refait sur tout le fonds sans appel de modèle |
| `nutrition` | `Map?` | Snapshot nutritionnel calculé côté backend (totaux, par portion, per100g, qualité, ingrédients manquants, huile absorbée à la friture) |
| `nutrition_validation` | `Map?` | Diagnostic de la dernière synchronisation nutrition (état, quantités invalides, unités inconnues) |
| `fidelity_level` | `string?` | `avertissement` ou `rupture` — verdict du contrôle de fidélité entre la transcription et le balisage. Absent quand tout concorde. Affiché par `FidelityBanner` sur le seul écran de **relecture d'un brouillon**, jamais sur la recette : c'est un outil pour décider, pas pour cuisiner. **Effacé par `validateDraft`** — valider, c'est avoir relu et tranché ; garder le doute reviendrait à le conserver sans que personne puisse plus le lever, et à rouvrir le débat au premier écran qui l'afficherait. Une ligne isolée (l'écran de relecture) laisse un brouillon à réserve de côté ; une **validation en lot** (`WorkQueueScreen`, depuis le 28 septembre 2026) avertit puis le valide quand même si l'utilisateur confirme — voir `DraftValidationPlan.validatableInBatch` |
| `fidelity_findings` | `List<Map>?` | Ce qui a été constaté : `{message, items?}`. Les éléments vivent à part de la phrase parce qu’ils s’affichent en **liste à puces** — sept mots mal lus concaténés forment un pavé qu’on ne relit pas, et une alerte qu’on ne relit pas ne sert à rien. `FidelityFinding.listFrom` lit aussi l’ancien format (liste de chaînes) |
| `nutrition_catch_up_attempts` | `int?` | Tentatives de rattrapage planifié consommées pour la liste d'ingrédients courante (5 au plus). Remis à 0 par `syncRecipeNutrition` dès qu'un changement d'entrée relance le calcul. C'est ce compteur qui transforme un échec permanent en dépense finie |
| ~~`nutrition_stale`~~ | — | **Retiré.** Bornait les réveils que `onRecipeWritten` se provoquait lui-même. La garde porte désormais sur ses entrées : plus de réveil, plus de drapeau. Peut subsister sur d'anciens documents, plus rien ne le lit |
| ~~`nutrition_enrichment_attempts`~~ | — | **Retiré.** Compteur de rattrapages qui ne bornait rien : il n'était lu que dans la branche où la nutrition existait déjà, jamais pendant la salve de réveils. Peut subsister sur d'anciens documents, plus rien ne le lit |
| `source_recipe_id` | `String?` | Recette d'origine quand ce document est une copie/amélioration. Nul pour un brouillon issu d'un scan |
| `origin` | `String?` | Ce qui a écrit le document la première fois : `scan` (`recipeProcessor`), `ai` (conception pour le planning, Explorer), `manual` (saisie, texte collé compris), `copy` (copie de travail). Écrit par celui qui crée le document, jamais déduit du livre porteur. Absent sur les documents antérieurs au champ : l'écran de relecture déduit alors `copy` d'une recette source, `scan` d'un fichier source, et n'affirme rien sinon — il disait « issu d'un scan » à toute recette conçue par l'IA |
| `scan_id` | `String?` | Le scan d'où vient la recette. Écrit par `recipeProcessor` au moment de l'enregistrement, et lu par `onRecipeWritten` : c'est le seul fil entre l'import et les calculs qu'il déclenche. Le déclencheur part sur une écriture Firestore, sans lien avec la tâche qui l'a produite — sans ce champ, la nutrition et les courses d'un import formaient un groupe de journaux à part, et leur coût sortait du total du scan. Absent sur une recette écrite à la main |
| `import_version` | `String?` | Version de l'app utilisée lors de l'import (ex : `'0.13.53'`) |
| `illustration_report` | `Map?` | Ce que la recherche d'illustrations a donné : `{detectees, retenues, publiees, pagesEnEchec}` — la quatrième clé est en camelCase là où les trois autres sont en snake_case ; l'écrivain et le lecteur emploient la même graphie, en changer une seule perdrait le compte. `detectees` compte ce que la page **porte**, jamais ce qu'on en a tiré — c'est ce chiffre qui permet au bandeau de relecture d'annoncer « trois photos repérées, à extraire à la main » alors même que rien n'a été extrait. Sans lui, « aucune photo » posait trois questions sans réponse : la page n'en portait-elle pas, l'extraction a-t-elle échoué, ou la page a-t-elle été sautée ? |
| `plating_advice` | `Map?` | Conseil de dressage produit par l'IA à la demande. Écrit **uniquement** par `suggestPlatingFn` / `generatePlatingImageFn`, à la demande du créateur de la recette ou d'un administrateur (§4, `assertCanModifyRecipe`). Absent tant que personne ne l'a demandé — cf. structure ci-dessous |

#### Détail du champ `nutrition` (Map imbriqué)

Écrit par `onRecipeWritten` pour toutes les recettes, et par `computeRecipeNutritionFn` à la
demande du créateur de la recette ou d'un administrateur (§4). **Tout ce qu'il contient décrit
la recette, pas un lecteur** — sauf `per_portion`, qui vaut pour `selected_portions` parts.

| Clé | Type | Rôle |
|---|---|---|
| `selected_portions` | `int` | Les portions **de la recette**, pas celles d'un lecteur. Y écrire le choix d'un utilisateur faisait que chaque membre de la famille écrasait l'affichage des autres, en silence |
| `total_weight_g` | `double` | Poids total des ingrédients reconnus |
| `coverage` | `double` | Part des ingrédients couverts par le référentiel, de 0 à 1 |
| `coverage_state` | `String` | `full` quand le per-100 g est publiable, `partial` au-dessus du seuil d'affichage partiel, `low` en dessous — les deux seuils viennent de `app_config`. Une quatrième valeur, `failed`, marque un calcul qui n'a pas abouti |
| `totals` | `Map<String, double>` | Les nutriments pour la recette entière |
| `per_portion` | `Map<String, double>` | `totals` divisé par `selected_portions` |
| `per_100g` | `Map<String, double>?` | Valeurs ramenées à 100 g. Absent quand le poids total n'est pas connu |
| `quality` | `Map` | `{score: int, level: String, warnings: List<String>}` — `level` vaut `A` au-dessus de 80, `B` au-dessus de 60, `C` en dessous. Trois niveaux seulement, pas cinq |
| `missing_ingredients` | `List<String>` | Ce que le référentiel ne sait pas peser ni chiffrer |
| `duplicate_ingredients` | `List<String>` | Lignes qui reprennent un ingrédient déjà listé — la pièce achetée, puis la même découpée au dressage. Le verdict vient du **serveur** : il demande de comprendre le texte, pas de comparer des noms |
| `absorbed_oil` | `Map?` | `{grams, absorption_ratio, fried_weight_g, source_name, capped, per_ingredient}`. Huile passée du bain de friture dans l'assiette. `null` dès que rien n'est frit — le cas de presque toutes les recettes |

**Une valeur dérivable ne se stocke pas.** Les calories par portion valent `totals / N` : la
division a lieu au moment de l'affichage, pour le nombre de parts que le lecteur a choisi. C'est
ainsi que la nutrition a cessé d'écrire le choix d'un lecteur dans une recette partagée — aucun
nouveau document, un champ de moins, et un appel serveur en moins à chaque coup de curseur.

Le nombre de parts retenu par un lecteur vit sous lui, dans
`users/{uid}/nutrition_portion_overrides/{recipeId}`.

#### Détail du champ `plating_advice` (Map imbriqué)

```json
{
  "complexite": "simple | intermediaire | complexe",
  "resume": "l'intention visuelle du plat, en une phrase",
  "contenant": "quel contenant, et pourquoi pour ce plat",
  "etapes": [
    {
      "titre": "Le lit de poireaux fondus",
      "geste": "Étaler les poireaux en disque de 10 cm au centre.",
      "elements": ["poireaux fondus"],
      "image_prompt": "ce que montre le visuel, consistances comprises",
      "image_url": "URL Storage du visuel généré, ou null"
    }
  ],
  "pieges": ["ce qui rate sur ce plat précis"],
  "derniere_minute": ["ce qui se pose à l'envoi"],
  "user_instruction": "contrainte de service saisie, ou null",
  "provider": "gemini | anthropic",
  "model": "identifiant du modèle qui a répondu",
  "prompt_version": 1,
  "generated_by": "uid",
  "generated_at": "Timestamp"
}
```

### Comptage et facturation

**Un seul point d'écriture : `ai/usage.ts`, fonction `recordUsage`.** Trois
chemins écrivaient auparavant leur propre version du même événement — le
routeur pour le texte, `tokenUsage.ts` pour les images, la callable pour le scan
de sécurité — chacun avec ses champs et ses oublis. Additionner ces écritures
revenait à additionner trois unités différentes.

`recordUsage` écrit trois choses d'un coup :

| Cible | Contenu | Lu par |
|---|---|---|
| `ai_usage/{auto}` | la ligne d'appel, avec `provider`, `model`, jetons, coût figé, `correlation_id`, `period` | réconciliation, audit |
| `token_usage/{uid}` | agrégat par utilisateur, **schéma unique** pour tous les types d'appel | profil utilisateur |
| `ai_usage_monthly/{AAAA-MM}` | agrégat mensuel : `by_feature` (avec `by_provider` imbriqué — `calls`, `cost_usd`, `input_tokens`, `output_tokens`, `analyzed_image_units`), `by_provider`, `by_model`, `by_user`, totaux | l'écran des coûts |

**La grille tarifaire peut rester périmée sans lever d'erreur.** Claude Sonnet 5
portait un tarif d'introduction (2,00 / 10,00 au lieu de 3,00 / 15,00) censé
s'arrêter le 1er septembre 2026. Relu ligne à ligne dans `ai_usage` et comparé
au rapport de coûts d'Anthropic du 26 septembre 2026, le tarif plein n'a jamais
pris effet : la page tarifaire d'Anthropic confirme que Sonnet 5 vaut toujours
2 $ / 10 $. La grille en vigueur portait donc 3 $ / 15 $ depuis un mois sans
qu'aucun écran ne le signale — un tarif faux ne casse rien, il fait seulement
mentir le reporting.

Un tarif se corrige depuis **Admin › Comptabilité › Grille tarifaire** (`/admin/ai-pricing`), qui
écrit `app_config/ai_pricing` par `setAiPricingFn`, réservée à l'admin. Aucun tarif
corrigé n'est écrit dans le code : `app_config/ai_pricing` est la seule source.

Chaque entrée de la table peut donc porter un bloc `introductory`
(`inputPerMillion`, `outputPerMillion`, `untilIso` — **borne exclue**), et
`effectivePricing(model, at)` / `AiPricing.effectiveFor(model, at:)` décide du
tarif en vigueur. `estimateAiCostUsd` prend un `at` : **un appel se facture au
tarif du jour où il a eu lieu**, jamais à celui du jour où on relit le rapport
— sans quoi une reconstruction postérieure à la fin d'une promotion réécrirait
le passé à la hausse. La fixture `ai_pricing.json` date chacun de ses cas, un
test dont le résultat dépend du calendrier étant précisément ce qu'elle existe
pour empêcher.

**Le coût est calculé une fois, à l'appel, et jamais recalculé à l'affichage.**
L'écran relisait chaque ligne et réappliquait la grille tarifaire Dart
par-dessus le montant déjà écrit par le backend : deux grilles pour un même
appel finissent par diverger, et l'écart ne casse aucun écran — il fait
seulement mentir le reporting.

**Les jetons de raisonnement sont facturés, donc comptés.** Gemini 2.5 Flash
raisonne par défaut. Ces jetons vivent dans `usageMetadata.thoughtsTokenCount`,
sont **exclus** de `candidatesTokenCount` et facturés au tarif de sortie —
2,50 $/M, soit huit fois l'entrée. Le backend ne lisait que
`candidatesTokenCount` : sur un appel d'extraction typique (1 000 entrée,
200 de texte rendu, 1 800 de raisonnement), le coût affiché valait un sixième du
coût réel. Aucune erreur, aucun écran cassé — juste un chiffre plausible et
faux, et un écart de réconciliation qu'on attribuait à autre chose.

`thinkingTokensOf()` (dans `gemini/client.ts`) retient le maximum du champ dédié
et de `totalTokenCount − prompt − candidates` : ce que le total compte en plus
de l'entrée et de la sortie ne peut être que du raisonnement, et ce repli
survit à une version du SDK qui cesserait de remonter le champ. Le coût est
calculé sur `outputTokens + thinkingTokens` ; les deux restent stockés
séparément (`thinking_tokens`, `total_thinking_tokens`,
`by_feature.*.thinking_tokens`, `by_provider.*.thinking_tokens`) pour distinguer
un poste qui produit beaucoup d'un poste qui fait beaucoup réfléchir. Claude
inclut déjà son raisonnement dans ses jetons de sortie : `thinkingTokens` y
reste à zéro, sans quoi il serait compté deux fois.

**Le raisonnement se plafonne depuis Firestore.**
`app_config/ai_routing_policy` porte `thinking_budget` (global) et
`thinking_budgets` (par poste, l'emporte sur le global) ; `0` coupe le
raisonnement, `null` — le défaut — laisse le modèle décider, comportement
inchangé tant que personne n'a tranché. Le budget est transmis en
`generationConfig.thinkingConfig.thinkingBudget` ; le type n'existe pas dans
`@google/generative-ai` 0.21, qui transmet néanmoins `generationConfig` tel
quel — d'où un cast, doublé d'un repli : une erreur nommant `thinking` fait
retenter l'appel **une fois sans le plafond**, parce qu'une facture plus lourde
vaut mieux qu'un poste qui ne répond plus. Réglable dans Admin → Moteur d'IA.

**Une mesure du poids réel** : sur août 2026, Google a facturé 2 457 734 jetons
de sortie Gemini là où l'application en comptait 323 900. Les 2 133 834
manquants — du raisonnement — valaient 5,33 $, soit 4,67 € au taux du mois,
pour un écart constaté de 4,62 €. La cause explique la totalité de l'écart.

**Un appel échoué est un appel facturé.** Un dépassement de délai côté client
n'arrête pas le calcul côté fournisseur, et le repli sur l'autre moteur en
ajoute un second par-dessus. `callModel` enregistre donc une ligne
`status: "error"` — zéro jeton, zéro coût, mais l'appel cesse d'être invisible,
et `total_failed_calls` permet de rapprocher notre nombre d'appels de celui de
la facture.

**Aucun appel n'est ignoré.** `recordModelUsage` commençait par
`if (totalTokens === 0) return;` : un appel dont le modèle ne renvoyait pas ses
métadonnées d'usage n'apparaissait nulle part, tout en étant facturé par le
fournisseur. Il ressortait plus tard en « non attribué », sans origine.

**`provider: "internal"`** distingue ce qui n'est pas de l'inférence (scan de
sécurité). Écrit sans fournisseur, ce poste était déduit « gemini » à la lecture
et gonflait d'autant l'écart de réconciliation.

**La part Claude se vérifie chez Anthropic, pas chez Google.**
`ai/anthropicCosts.ts` interroge `GET /v1/organizations/cost_report` (API
d'administration Anthropic, granularité journalière, montants en cents) et
agrège au mois. L'appel exige une clé `sk-ant-admin…` — secret
`ANTHROPIC_ADMIN_KEY`, distinct de la clé d'inférence — attachée à
`getMonthlyCostsFn`. Contrat identique à celui de la clé d'inférence : absente,
la fonction rend `available: false` et l'écran affiche l'estimation en
signalant qu'elle n'est confrontée à rien. Le facturé n'est **jamais** additionné
à l'estimé : ce sont deux mesures de la même dépense.

**Le rapport Anthropic est mis en cache, parce que son API est limitée en
débit.** `cost_report` rend des **journées** : une fenêtre d'un an coûte des
dizaines de requêtes paginées, et la demander à chaque affichage d'écran a
suffi à obtenir un `HTTP 429 rate_limit_error`. L'écran affichait alors
« facturé : — » — une limite de débit rendue comme une absence de facture.

**La première cause était la taille de page.** `cost_report` rend des journées
et sa page en vaut **7 par défaut**, pour un maximum documenté de **31** : une
année d'historique coûtait donc près de soixante requêtes là où elle en coûte
treize. Le garde-fou de pagination (40 requêtes) aurait d'ailleurs tronqué la
lecture avant la fin, sans le signaler. `limit=31` est désormais explicite.

Quatre corrections tiennent ensemble : la page passe à 31 journées ; la fenêtre
demandée se limite aux périodes réellement affichées ; les montants sont
mémorisés dans `app_config/anthropic_costs` (`months.{AAAA-MM}`), un mois clos
n'étant relu qu'une fois et le mois courant toutes les six heures
(`current_month_fetched_at_ms`) ; un 429 est attendu puis retenté deux fois en
respectant `retry-after`. Un échec final ne vide plus rien : les montants déjà
connus sont rendus avec `stale: true`.

Anthropic recommande **une interrogation par minute en régime établi**, les
rafales n'étant admises que pour dérouler une pagination, et conseille
explicitement de mettre les résultats en cache pour un tableau de bord — ce que
fait le cache ci-dessus. `refreshAnthropicPeriods: ["AAAA-MM"]` force la
relecture d'un mois précis, sur demande explicite depuis l'écran : un mois clos
ne bouge qu'en cas de correction rétroactive, et le relire seul coûte une
requête au lieu de treize.

**La lecture avance par tranches, et ce qui est lu est écrit.** Douze mois
faisaient encore douze requêtes d'un bloc, et l'échec empêchait d'écrire :
l'affichage suivant repartait de zéro, rallumait la limite, et la boucle ne
pouvait que se refermer. Trois règles la cassent :

- **`MAX_PERIODS_PER_CALL` / `MAX_PAGES_PER_CALL` (4)** bornent chaque
  affichage à quatre mois, **les plus récents d'abord** — le mois en cours est
  le seul qu'on regarde vraiment, le lire en dernier remplissait le cache par
  le bout inutile. Une pause de 400 ms sépare deux pages.
- **L'écriture est inconditionnelle** : les montants relevés sont persistés
  même quand la lecture s'arrête en chemin. Un mois n'est inscrit à zéro que
  s'il est **entièrement couvert** (`ending_at` du dernier seau lu, ou
  pagination terminée) — un mois effleuré figerait un chiffre faux dans un
  cache qui ne se relit plus.
- **`rate_limited_until_ms`** impose cinq minutes de pause après un 429 : sans
  elle, chaque ouverture d'écran relançait la lecture et repoussait le retour à
  la normale. Le bouton de relecture d'un mois ignore cette pause.

`partial: true` distingue « pas encore tout lu » de « en panne » : l'écran
annonce une lecture qui se complète, pas un incident.

**Un écart connu et irréparable n'est pas une anomalie.** `thinkingCountedSince`
(14 août 2026) marque le jour où les jetons de raisonnement ont commencé à être
enregistrés. `MonthlyCost.predatesThinkingCount` et `spansThinkingCount`
qualifient chaque mois : entièrement antérieur, l'écart Gemini est définitif —
la donnée n'existe pas, aucune reconstruction ne la produira. L'écran l'explique
au lieu de l'alerter. Peindre en rouge un écart dont la cause est établie ne
protège de rien : cela noie le jour où un vrai écart se produira.

**L'âge du relevé fait partie de la mesure.** Le cache porte `fetched_at.{AAAA-MM}`,
remonté jusqu'à l'écran (`billedAtMs`). Un montant facturé est une photographie
et nos compteurs sont vivants : soustraire un total à jour d'un relevé vieux de
six heures produit un écart qui ne mesure qu'un décalage d'horloge. Au-delà de
deux heures, l'écart cesse d'être signalé comme une anomalie et l'écran invite à
relire le mois pour comparer deux chiffres du même instant.

**`getMonthlyCostsFn` accepte `all: true`.** La série remonte alors au premier
mois enregistré — une lecture de la collection entière, soit un document par
mois. C'est l'ancien modèle (une ligne par appel) qui rendait cela impossible.
La facturation Google, elle, reste bornée à `MAX_GCP_MONTHS` (13) : au-delà,
l'export n'existe pas. Le drapeau `gcpTruncated` le dit à l'écran.

**La réconciliation compare fournisseur par fournisseur.** La facturation Google
ne contient ni les appels Claude (facturés par Anthropic) ni les postes
internes. Le rapport porte donc `estimated_gemini_usd` (la seule part
comparable), `estimated_anthropic_usd` et `estimated_internal_usd` ; l'écart se
mesure contre la part Gemini seule. Auparavant, activer Claude sur un poste
créait un écart négatif spectaculaire, présenté comme un fait.

**Gemini est un moteur d'IA, pas une ligne d'infrastructure.** Ses appels sont
facturés par Google, dans le même export BigQuery que Cloud Functions ou
Storage. `getMonthlyCostsFn` en extrait les services d'inférence (`gemini`,
`generative language`, `vertex ai`, `aiplatform`) et les rend sous la même forme
que Claude — estimé, facturé, écart — au lieu de les laisser noyés dans la liste
des services. Un mois se lit donc en trois blocs : **Claude**, **Gemini**,
**infrastructure**. La symétrie est la condition d'une comparaison : deux
moteurs présentés dans deux formats différents ne se comparent pas.

**La facture Gemini est rendue ligne par ligne.** La requête BigQuery groupe
aussi par `sku.description` et remonte `usage.amount` / `usage.unit` : la
section Gemini affiche « Gemini 2.5 Flash Output Tokens — N tokens », etc. Un
écart réduit à un seul nombre ne se diagnostique pas ; rapproché des lignes de
la facture, il désigne le poste sous-compté. C'est cette lecture qui a permis de
nommer le raisonnement.

**Le total du mois privilégie le facturé.** `infra + (facturé Claude ?? estimé) +
(facturé Gemini ?? estimé) + interne`. Le facturé est le montant réellement payé ;
l'estimation ne prend le relais que lorsqu'il manque, un poste approché valant
mieux qu'un poste absent. Estimé et facturé ne sont jamais additionnés.

**Un taux de change par mois, relevé sur la facture.** L'export porte
`currency_conversion_rate`, le taux USD → devise du compte que Google a
lui-même appliqué à la ligne. Chaque mois porte le sien (`usdToEur`) ; le taux
global de `app_config/currency_rate` n'est plus qu'un dernier recours pour les
mois sans ligne Google. Une agrégation pluri-mensuelle convertit **chaque mois à
son propre taux avant de sommer** : appliquer le cours du jour à une dépense de
l'an dernier produit un total que personne n'a payé. L'affichage est belge —
euros, virgule décimale, séparateur de milliers (`intl`, locale `fr_BE`).

**`rebuildAiUsageMonthlyFn`** reconstruit les agrégats depuis les lignes
d'appel, par pagination et en écrasant le document (`set` sans fusion) : un
recalcul doit pouvoir corriger un compteur trop haut, pas seulement le
compléter. Il sert au rattrapage de l'historique comme à la réparation d'un mois
dérivé.

`recomputeCosts: true` (case à cocher explicite dans la boîte de dialogue)
ignore le coût figé et rechiffre chaque appel à la grille actuelle, au tarif du
jour de l'appel. C'est la **seule** réparation possible quand la grille
elle-même était fausse — et elle réécrit des montants déjà publiés, d'où le
choix explicite. Les postes `internal` gardent toujours leur montant : il vient
d'un prix imposé qu'aucune grille ne saurait retrouver.

**Toute fonction qui appelle `callModel` déclare les DEUX clés.** Un secret
Firebase n'est monté dans `process.env` que si la fonction le déclare dans
`secrets: [...]`, et `anthropicApiKey()` lit `process.env.ANTHROPIC_API_KEY`.
Une fonction qui oublie `ANTHROPIC_API_KEY` voit donc une clé absente, et
`resolveProvider` la sert par Gemini — sans erreur, puisqu'une clé non posée
est l'état normal avant activation. La politique est alors lue, appliquée, puis
annulée à l'exécution, pendant que l'écran d'administration affirme que la clé
est présente parce qu'une autre fonction, elle, la déclare. C'est exactement ce
qui est arrivé à `geminiCallables.ts` : tous ses postes (extraction, refine,
génération, recherche, tags, planning, courses, dressage) ignoraient la bascule
vers Claude. `callModel` émet désormais un `WARNING` dans ce cas.

**Seuls le créateur de la recette et un administrateur demandent un conseil.** Le conseil, son
instruction libre et ses visuels s'écrivent sur la recette partagée : `suggestPlatingFn` et
`generatePlatingImageFn` refusent les autres comptes avant l'appel de modèle (§4). Le client ne
leur montre ni « Demander un dressage sur mesure », ni « Régénérer », ni les boutons de visuel ;
sans conseil enregistré, l'onglet affiche une ligne de texte (`kPlatingAdviceReservedMessage`).
Le visuel d'étape exige en plus le rôle éditeur : pour le créateur qui n'est que lecteur, les
boutons de visuel sont masqués et une ligne le dit (`kPlatingImagesEditorOnlyMessage`) ; il
garde « Régénérer », « Intégrer » et « Retirer ».

Même règle pour le conseil de conservation. `StorageRepository.ensure` rend un
`StorageAdviceLookup` : `StorageAdviceAvailable` (conseil relu, ou produit si
`canWriteRecipeAdviceProvider` l'autorise), `StorageAdviceReserved` (aucun conseil, pas le
droit d'en demander) ou `StorageAdviceRecipeMissing` (« Recette introuvable. »). Le droit est un
`FutureProvider` qui attend le profil : décidé avant son chargement, il refusait le créateur
lui-même. Le bandeau de préparation et le planning affichent `kStorageAdviceReservedMessage` ;
le batch retient la recette refusée (`_storageReservedRecipeIds`) et remplace le bouton du
créneau par ce texte. Le bouton « Calculer » / « Recalculer » de la nutrition suit la même
règle (`kNutritionReservedMessage`).

**Le conseil n'est pas une modification de la recette** : `suggestPlatingFn`
n'écrit pas `updated_at`, sans quoi demander un dressage remonterait la recette
en tête de tous les tris « récemment modifiées ».

**L'intégration dans `raw_cooklang` est idempotente.** `applyPlatingSection`
(`plating_text.dart`) retire la section `## Dressage` existante **avant**
d'écrire la nouvelle : intégrer trois fois ne laisse qu'une section, celle du
dernier conseil, visuels compris. La contrepartie est assumée et annoncée dans
le dialogue de confirmation — une section retouchée à la main est écrasée par
l'intégration suivante. `removeSectionFromRecipe` permet de tout défaire.

La reconnaissance porte sur le **titre exact** : une section « Cuisson et
dressage » rédigée par un cuisinier n'est jamais confondue avec celle de l'IA.
Les deux écritures de section sont reconnues (`## Dressage` et le `== Dressage`
de l'éditeur visuel), sans quoi une seconde insertion laisserait la première en
place. Cas de test dans `test/plating_text_test.dart`.

**`prompt_version`** accompagne le conseil pour qu'on sache, plus tard, si un
texte affiché vient de la consigne actuelle ou d'une version corrigée depuis —
un conseil périmé ne lève aucune erreur et s'affiche parfaitement.

**Les visuels s'enchaînent, ils ne se rejouent pas.** `generatePlatingImageFn`
reprend le dernier `image_url` renseigné avant l'étape demandée et le transmet
au modèle d'image comme point de départ, avec la consigne de ne rien changer
d'autre. Sans cette reprise, chaque étape produisait une assiette indépendante
— autre cadrage, autres formes, autre lumière — et la série de visuels cessait
de raconter un montage.

L'image de départ n'est relue que si son URL désigne un dossier publié
(`illustrations/` ou `recipes/`, `PUBLISHED_IMAGE_PREFIXES` dans
`utils/storagePath.ts`) : le créateur peut écrire `plating_advice` par les
règles, et une URL vers `rejected/` ou vers la quarantaine d'un autre compte
faisait lire ce fichier par le serveur (v0.23.10). Refus en `permission-denied`
avant tout téléchargement. Même contrôle sur `enhanceIllustrationFn`, qui
n'améliore qu'une illustration déjà publiée.

**La chaîne impose l'ordre à l'interface.** Trois règles en découlent, portées
par le domaine (`plating_advice.dart`) et non par l'écran :
`missingImageIndexesUpTo(i)` liste les étapes à produire pour que la `i`-ème
existe — c'est la cascade ; `lastIllustratedIndex` désigne la seule étape
qu'on puisse refaire ; `clearImages` efface toute la série, seule reprise
cohérente pour revenir sur une étape ancienne. Cas de test dans
`test/plating_advice_test.dart`.

**Il n'existe pas de visuel « résultat final ».** Il en a existé un, le temps
d'une version : puisque la génération part de l'image précédente et qu'on lui
demande d'y ajouter quelque chose, un visuel final ne pouvait qu'ajouter un
objet de plus — il posait un ramequin de sauce à côté de l'assiette. La
dernière étape du dressage est le résultat, et elle s'illustre comme les
autres.

**Le confinement au contenant est une consigne à part** (`CONTAINER_RULES` dans
`imageGenerator.ts`). Livré à lui-même, le modèle sort de l'assiette : coupelle
annexe, planche, couverts, ingrédients crus en décor. Un guide de dressage
montre ce qu'il y a dans le contenant, et rien d'autre.

**Les consistances sont décrites par le coach, tenues par le générateur.**
`image_prompt` doit nommer la texture de chaque élément (émulsion épaisse, purée
mate, jus sirupeux) et le prompt d'image l'exige explicitement. Un modèle
d'image livré à lui-même peint toutes les sauces en liquide clair : une
anchoïade montée à l'huile ressortait en bouillon.

**Écrivain unique pour `ingredients_index`.** Il se construit par
`buildIngredientsIndex(ingredients)` — `cooklang_parser.dart` côté Dart,
`cooklang/parser.ts` côté Functions — et par rien d'autre. Trois chemins de
sauvegarde le fabriquaient autrefois différemment (noms normalisés par le
référentiel, noms bruts du CookLang, noms du formulaire sans mise en
minuscules) : la même recette n'était pas indexée de la même façon selon la
manière dont elle avait été enregistrée, et la recherche par ingrédient
répondait en conséquence. Cas de test partagés dans
`test-fixtures/cooklang_parsing.json`, clé `index`.

**L'alignement des vignettes.** L'onglet Photos lit `thumbnail_urls[i]` pour la
photo `i`. Deux listes de tailles différentes ne laissent pas la fin sans
vignette : elles décalent, et la première carte affiche la photo d'une autre.
Trois recettes ont fini avec deux photos et une seule vignette — celle de la
seconde —, chaque fois après un ajout d'illustration sur un brouillon qui
n'avait aucune vignette : la liste des vignettes partait vide et l'ajout
atterrissait en position 0.

`RecipeRepository.alignThumbnails(imageUrls, thumbnailUrls)` tranche à
l'écriture : longueurs égales, la liste passe ; longueurs différentes, rien ne
dit à quelle photo chaque vignette appartient, et ce sont les URLs pleine
résolution qui sont écrites. Les sept appelants — ajout, remplacement,
suppression unitaire, suppression multiple, génération par IA, ajout manuel,
atelier de retouche — partent de cette liste alignée avant de modifier. Côté
lecture, `draft_illustrations_tab.dart` n'utilise `thumbnail_urls` que si sa
longueur égale celle de `image_urls` : c'est ce qui rend leur bon affichage aux
documents déjà écrits, sans migration. Cas de test dans
`test/repositories/recipe_repository_test.dart`.

#### Détail du champ `tags` (Map imbriqué)

```json
{
  "themes":    ["Noël", "Hiver", "Festif"],
  "cuisines":  ["Belge", "Terroir"],
  "occasions": ["Anniversaire", "Fête de famille"],
  "difficulty": "medium",
  "prep_time":  30,
  "cook_time":  60
}
```

| Sous-champ | Type | Valeurs possibles |
|---|---|---|
| `themes` | `List<String>` | Libre (ex : Été, Noël, Rapide) |
| `cuisines` | `List<String>` | Libre (ex : Italien, Belge, Asiatique) |
| `occasions` | `List<String>` | Libre (ex : Anniversaire, Quotidien) |
| `dish_types` | `List<String>` | Types de plat normalisés : viande, volaille, poisson, fruits de mer, végétarien, vegan, dessert, pâtisserie, soupe, entrée, plat complet, snack |
| `difficulty` | `String?` | `easy` \| `medium` \| `hard` |
| `prep_time` | `int?` | Durée en minutes |
| `cook_time` | `int?` | Durée en minutes |
| `rest_time` | `int?` | Temps de repos en minutes — marinade, réfrigération, levée |
| `meal_role` | `String?` | **Rôle dans un repas** : `plat` \| `accompagnement` \| `entree` \| `dessert` \| `snack`. Reconnu une fois par le modèle — passe 2 de l'import, suggestion de tags, `onRecipeWritten` à toute écriture d'une recette sans rôle, backfill « Rôle des recettes » — et lu par le programme pour composer un repas. Absent = pas encore classée. Modifiable par l'utilisateur dans la liste « Rôle dans un repas » du panneau de métadonnées (relecture d'un import, correction, création) ; « Non classé » retire les trois champs (`clearMealRole` dans `validateDraft`, carte entière dans `updateRecipe`). Les valeurs et la lecture de la réponse vivent dans `functions/src/gemini/mealRole.ts` ; `lib/features/recipes/domain/meal_role.dart` les reprend pour la liste et l'affichage, `test-fixtures/meal_roles.json` verrouille l'égalité |
| `contains` | `List<String>` | Ce que la recette apporte déjà : `proteine`, `feculent`, `legume`. Un plat à qui il manque l'un des deux derniers appelle un accompagnement (`needsSide`) |
| `suggested_sides` | `List<String>` | Accompagnements classiques d'un plat, noms courts, quatre au plus ; vide pour les autres rôles. Le programme y choisit au moment du planning, jamais le modèle |
| `roles_tagged_at` | `Timestamp?` | Quand le backfill a posé le rôle |

**Le rôle survit aux réécritures de `tags`.** Côté client, `RecipeTags.toMap()` n'écrit
les trois champs que si le rôle est connu, et `validateDraft` écrit `tags` champ par champ
(`tags.themes`, `tags.cuisines`, …) au lieu de remplacer la carte : un brouillon validé depuis
le formulaire, qui ne connaît pas le rôle, ne l'efface pas. Le pipeline d'import écrit
`meal_role: null` quand la passe 2 n'a pas su ; le backfill repasse sur ces recettes.

**Le rôle se pose aussi à l'écriture.** Trois chemins créent une recette sans rôle : une
création manuelle sans clic « Suggérer », une recette de l'Explorer IA (`generateRecipeFn` ne
demande pas ce champ), une copie d'une recette non classée (`copyRecipeAsDraft`).
`onRecipeWritten` appelle `syncRecipeMealRole` (`triggers/recipeMealRoleAutoSync.ts`) sur
toute écriture d'une recette (`page_type` recette) dont `tags.meal_role` est vide, **avant** la
garde des entrées : la classification n'attend pas un changement d'ingrédients. Un appel de
modèle, poste `inline_meal_role_classification`, qui écrit `tags.meal_role`, `contains`,
`suggested_sides` et `roles_tagged_at`. Si le modèle ne rend aucun rôle, rien n'est écrit et
la prochaine écriture retente ; une erreur passe par `logError`.

---

### 3.4 Collection `processing_jobs`

Jobs de traitement asynchrone pour scans recettes/livres.

| Champ | Type | Description |
|---|---|---|
| `id` | `String` | ID auto-généré Firestore |
| `type` | `String` | Enum : `recipeScan` \| `bookCoverScan` \| `bookDocumentScan` |
| `status` | `String` | Enum : `queued` \| `processing` \| `done` \| `error` \| `rejected` |
| `created_by` | `String` | UID du demandeur |
| `created_at` | `Timestamp` | Date de creation |
| `updated_at` | `Timestamp` | Date de mise a jour du job |
| `file_name` | `String` | Nom du fichier source |
| `titre` | `String?` | Titre lu par l'IA, **posé par le serveur** après la transcription (titres joints par une virgule pour une page à plusieurs recettes) ou après l'extraction d'une couverture. La file « Brouillons & Traitements » l'affiche à la place de `file_name` dès qu'il existe : entre la lecture et l'enregistrement du brouillon, le balisage et la normalisation durent jusqu'à 7 min. Le client ne l'écrit jamais. |
| `file_url` | `String` | URL Firebase Storage du fichier source |
| `mime_type` | `String?` | MIME detecte du fichier |
| `book_id` | `String?` | Livre cible pour rattachement recettes |
| `book_titre` | `String?` | Titre denormalise du livre cible |
| `created_recipe_ids` | `List<String>` | IDs des brouillons recettes crees. **Écrit dès la création de chaque brouillon**, pas à la fin du job : la normalisation des référentiels qui suit dure jusqu'à 7 min, et la file de travail masque un job dès qu'il a produit un brouillon (sauf `error` / `rejected`). |
| `created_book_id` | `String?` | ID du brouillon livre cree |
| `error_message` | `String?` | Message d'erreur si statut `error`, ou raison du rejet si statut `rejected` |
| `error_id` | `String?` | Identifiant du rapport d'erreur (`error_reports`) lié à un job en `error`. La file « Brouillons & Traitements » l'affiche en puce « Code : … », copiable. Remis à `null` par `relaunchDeadLetterFn` sur le job relancé. Aucun code actuel n'y écrit d'autre valeur que `null` : le client le lit seulement |
| `additional_file_urls` | `List<String>` | URLs Storage des pages supplémentaires (multi-pages) |
| `current_step` | `String?` | Étape courante du traitement IA |
| `scan_id` | `String?` | Le scan d'où vient ce job. **Posé par le client** au premier envoi, avant même que le job existe : le contrôle du fichier a lieu dans une callable séparée, et une page supplémentaire arrive par un appel séparé. Le `jobDispatcher` le relit, le réécrit — pour qu'une relance retrouve le même scan — et le transmet au `recipeProcessor` dans le payload de la tâche. Un job créé avant l'existence du champ en reçoit un fabriqué côté serveur, qui couvre au moins l'import et ses suites. **À la création, la valeur du client n'est pas crue telle quelle** (v0.23.12, `dispatchScanId`) : un `bookDocumentScan` reçoit toujours un identifiant tiré par le serveur, et un autre job reçoit un identifiant neuf si `scan_spend/{scan_id}` appartient déjà à un autre compte (`user_id`). Sans cela, un éditeur qui reprenait le `scan_id` d'un import d'autrui relevait son plafond et y imputait ses dépenses. Le client ne peut plus changer ce champ ensuite (règles) |
| `import_illustrations` | `Boolean` | Extraire les illustrations des pages de ce job. Copié depuis la case de l'écran d'import au moment de la création, **jamais relu depuis le profil** : le serveur traite ce job après coup, et la préférence a pu changer entre-temps. Ce qui a été demandé au moment de l'import est ce qui est fait. Toujours `false` hors `recipeScan`. |
| `parent_job_id` | `String?` | **Posé par le serveur** sur le job d'une tranche de livre : l'identifiant du job `bookDocumentScan` qui l'a créé. Sert au retrait d'un livre vide après un échec, et à retrouver les enfants d'un import. |
| `book_window` | `Map?` | **Posé par le serveur** sur le job d'une tranche : `{ kind: "pdf" \| "text", owned?: Number, context: Number }`. `owned` = pages à transcrire, `context` = pages (ou 0/1 pour un texte) de contexte qui suivent. `recipeProcessor` en fait un préambule de prompt (`bookWindowPreamble`) et saute le comptage d'illustrations pour ces jobs. |
| `windows_total` / `windows_created` | `Number?` | Sur un job `bookDocumentScan` : nombre de tranches prévu, puis nombre déjà créé (mis à jour toutes les 10 tranches). |
| `budget_limit_usd` | `Number?` | **Posé par le client** sur le job `bookDocumentScan` : le plafond de dépense de l'import, en dollars, fixé sur l'écran de confirmation. `runBookImport` le pose sur `scan_spend/{scan_id}` avant de créer la première tranche, borné par le serveur (`effectiveImportLimitUsd`, v0.23.12) : au plus `MAX_IMPORT_BUDGET_PER_WINDOW_EUR` (4 €) par tranche depuis v0.23.13, convertis en dollars au moment du calcul avec le taux de la facture (`app_config/currency_rate`, `getUsdToEurRate`), jamais plus de `MAX_IMPORT_BUDGET_PER_WINDOW_HARD_USD` (8 $) par tranche, et arrondis au centime inférieur. Sans taux, ou avec un taux hors des bornes de vraisemblance de la réconciliation (`MIN_PLAUSIBLE_RATE` 0,1 – `MAX_PLAUSIBLE_RATE` 10, `usableRate`), aucun taux n'est inventé : le maximum vaut 4 $ par tranche, valeur plus basse que 4 € tant qu'un dollar vaut moins qu'un euro, et `runBookImport` le journalise (`logWarn`). La valeur du client ne peut que réduire ce maximum ; un job sans plafond reçoit le maximum. |
| `transcription_checkpoint` | `String?` | **Posé par le serveur** sur un job `recipeScan` : la transcription réussie de la page, en JSON (`pipeline/transcriptionCheckpoint.ts`). Une nouvelle tentative après un échec du balisage, ou une relance depuis la file (qui copie le job), la relit au lieu de refaire l'appel de modèle. Supprimé quand le job aboutit ; non écrit au-delà de 300 000 caractères. Un point de reprise illisible est journalisé et la page est transcrite de nouveau. |

**`bookDocumentScan` ne transcrit rien.** `recipeProcessor` l'aiguille sur `runBookImport` (`pipeline/bookImport.ts`), qui ouvre le fichier (`books/bookFile.ts`), crée le livre s'il n'y en a pas (`book_id` absent → document `books/book_import_{jobId}`, couverture dans `scans/{uid}/book_import_{jobId}/`), puis découpe le contenu en tranches et crée **un job `recipeScan` par tranche** (`processing_jobs/book_import_{jobId}_{NNNN}`, fichier dans `scans/{uid}/book_import_{jobId}/{NNNN}.pdf|txt`). Ces jobs suivent le pipeline d'une page scannée et partagent le `scan_id` du parent : le coût du livre se lit sur un seul groupe. L'opération est idempotente — livre et enfants ont des identifiants déterminés par le parent, un enfant existant n'est jamais recréé (`create()` refusé, code gRPC 6) — et un livre neuf qui n'a aucun enfant est supprimé si l'import échoue. Un `BookFileError` (PDF chiffré, EPUB sans texte, plus de 400 tranches) part directement en dead letter sans nouvelle tentative, comme un plafond de dépense.

**Découpage** (`books/bookFile.ts`). PDF : `pdf-lib` (chargé à la demande), fenêtres de 3 pages + 1 page de contexte (`planWindows`) ; une tranche de plus de 12 Mo est coupée en deux, chaque moitié gardant son contexte, parce que le fichier part en base64 dans une requête plafonnée à 20 Mo chez Gemini. EPUB et Word : texte extrait par du code (OPF + XHTML pour l'EPUB, `docxToPlainText` pour Word), fenêtres d'environ 6 000 caractères + 1 500 de contexte, un paragraphe n'étant jamais coupé (`planTextWindows`). La ligne `BOOK_WINDOW_CONTEXT_MARKER` sépare le texte à transcrire du contexte. Mesuré sur un PDF synthétique de 190 Mo et 300 pages : ouverture 0,14 s, découpage en 100 tranches 0,3 s, pic de mémoire 462 Mo (`recipeProcessor` passe à 2 GiB).

**Statut `rejected`** : créé côté client lorsqu'un fichier est bloqué par le scan de sécurité (`scanAndPromoteUpload` renvoie `failed-precondition`). Le fichier source reste en quarantaine et n'est pas promu ; `file_url` est donc vide et `error_message` contient la raison du rejet. Ces jobs apparaissent dans l'écran « Brouillons & Traitements » (badge rouge « Rejeté ») et ne proposent que l'action **Supprimer** (pas de **Relancer**, un re-scan du même fichier produirait le même rejet).

---

### 3.5 Collection `groups`

Groupes familiaux pour le partage de livres et recettes entre utilisateurs.

| Champ | Type | Description |
|---|---|---|
| `id` | `String` | ID auto-généré Firestore |
| `name` | `String` | Nom du groupe (ex : "Famille Dupont") |
| `owner_id` | `String` | UID du créateur/propriétaire |
| `member_ids` | `List<String>` | UIDs de tous les membres (propriétaire inclus) |
| `created_at` | `Timestamp` | Date de création |

**Requêtes clés :**
- `where('member_ids', arrayContains: uid)` → groupes de l'utilisateur
- Visibilité cross-utilisateur : union des `member_ids` de tous mes groupes → `whereIn created_by` sur `books` et `recipes`
- **Toute lecture portant sur autrui écarte le privé** : `where('is_private', isEqualTo: false)` s'ajoute à la requête, et non au filtrage client. `watchValidatedBooksByOwners`, `watchUnattachedByOwners`, `watchDraftsByOwners`, `getFamilyValidatedRecipes` et le volet familial de la recherche l'appliquent. Le corpus de recherche part en **deux requêtes** — les miennes sans filtre, celles de la famille avec — parce qu'un appel unique mêlant les deux publics ne peut appliquer qu'une règle, et applique donc la plus permissive.

> **Le partage nominatif n'existe plus.** `books.shared_with` et son index ont été
> retirés : `shareBook`/`unshareBook` n'avaient jamais eu d'écran pour les appeler,
> et `watchSharedBooks` rendait donc toujours une liste vide. Un livre est partagé
> avec les membres de ses groupes, ou privé. Il n'y a pas de troisième état.

---

### 3.6 Sous-collection `recipes/{recipeId}/annotations`

| Champ | Type | Description |
|---|---|---|
| `id` | `String` | ID auto-généré |
| `uid` | `String` | UID de l'auteur de l'annotation |
| `author_name` | `String` | Nom d'affichage (dénormalisé pour affichage) |
| `text` | `String` | Contenu de l'annotation |
| `type` | `String` | Enum : `note` \| `tip` \| `correction` |
| `created_at` | `Timestamp` | Date de création |
| `updated_at` | `Timestamp?` | Date de modification |

---

### 3.7 Collection `planned_meals`

Le repas planifié est **le porteur du contexte** : c'est le couple (personne, date). Une
adaptation d'une recette — un nombre de parts différent — vit ici, jamais dans la recette
partagée.

| Champ | Type | Description |
|---|---|---|
| `uid` | `String` | Propriétaire du repas |
| `recipe_id` | `String?` | Recette servie ; `null` pour un créneau resté vide |
| `recipe_titre` | `String` | Titre dénormalisé, pour afficher sans lire la recette |
| `planned_at` | `Timestamp` | Date et heure du repas |
| `duration_minutes` | `int` | Durée totale, pour l'export calendrier |
| `prep_minutes` · `cook_minutes` | `int?` | Détail des deux temps |
| `base_portions` | `int?` | Parts de la recette d'origine |
| `target_portions` | `int?` | Parts voulues ce jour-là — avec `base_portions`, c'est **tout** ce qu'il faut pour recalculer les quantités à l'affichage |
| `prep_date` | `Timestamp?` | Jour de préparation, quand il diffère du jour du repas |
| `justification` | `String?` | Pourquoi ce plat, ce jour-là — écrit par l'IA à la suggestion. Il appartient au **repas** et non à la recette : il parle de cette date, de la contrainte de ce jour et de la variété du cycle. Sur la recette, il aurait menti au prochain qui la planifie |
| `dismissed_recipe_ids` | `List<String>?` | Recettes écartées de ce repas — par « Changer la recette », « Vider le créneau », une nouvelle suggestion, et déjà pendant la composition d'un cycle. Le client les retire des candidats **avant** l'appel à l'IA : une consigne dans le prompt est un vœu, un candidat absent de la liste est une certitude. Elles appartiennent au repas, pas au profil : écarter un plat un mardi ne dit rien du samedi suivant. Ajoutées par `arrayUnion`, jamais retirées |
| `components` | `List<Map>?` | **Ce qui accompagne le plat.** Une entrée par composant : `role` (`accompagnement` \| `entree` \| `dessert`), soit `recipe_id` (une recette d'accompagnement), soit `staple_id` (une garniture), `label`, et pour une garniture la part **figée** au choix — `quantity_per_portion`, `unit`, `shopping_product`, `note` — plus `justification` (« le plat n'apporte pas de féculent : riz, accompagnement classique »). Le plat lui-même n'y figure pas, il reste dans `recipe_id`. Choisi par le **programme** (`side_chooser.dart` : ce que le plat n'apporte pas, ses accompagnements classiques, les garnitures visibles du compte, rotation sur les jours voisins), jamais par le modèle au moment du planning. L'**entrée** et le **dessert**, eux, viennent du même appel de planning que le plat, quand le format du jour (`meal_format`) en demande, parmi les recettes de ce rôle, une fois chacun dans le cycle (`starter_id`, `dessert_id`). Absent = aucun composant |
| `created_at` | `Timestamp` | Création |

---

### 3.8 Collection `planning_config`

Un document par utilisateur (`{uid}`), écrit depuis l'écran de configuration du planning.

| Champ | Type | Description |
|---|---|---|
| `meals_per_cycle` | `int` | Nombre de repas d'un cycle |
| `cycle_start_day` | `int` | Jour de démarrage (1 = lundi) |
| `batch_cooking_day` | `int?` | Jour de préparation groupée |
| `daily_constraints` | `Map<int, …>` | Par jour : temps de préparation maximum, parts visées, batch cooking, notes en langage naturel, heure propre, et `meal_format` — le **format du repas** : `plat` \| `plat_dessert` \| `entree_plat` \| `entree_plat_dessert` \| `leger`. Absent = plat seul, jamais stocké comme tel. C'est le format qui fait demander une entrée ou un dessert à `suggestMealPlanFn`, dans le même appel que le plat (`mealFormatOf`, fixture `planning_slot_rules.json` › `meal_format`) ; une contrainte en prose ne les ouvre plus. Il se change aussi sur un créneau pendant la composition d'un cycle |
| `global_constraints` | `String` | Contraintes valables pour tout le cycle, en langage naturel |
| `default_meal_hour` · `default_meal_minute` | `int` | Heure par défaut d'un repas |
| `default_calendar_duration_minutes` | `int` | Durée d'un événement Google Calendar, depuis tous les points d'export : le repas à table, jamais les temps de la recette (ceux-ci ne servent qu'au rappel et à `duration_minutes` du repas) |
| `calendar_id` · `calendar_name` | `String` | Calendrier Google cible |
| `variety_window_weeks` | `int` | **Fenêtre de variété**, de 0 à 4 semaines (défaut 2, absent = 2, hors bornes = ramené). Un plat servi dans les N semaines qui précèdent le premier jour du cycle n'est pas reproposé. Le client lit ses propres `planned_meals` sur cette fenêtre (`recentlyServedBefore`, `planning_history.dart`) et envoie la liste à `suggestMealPlanFn` ; le serveur retire ces recettes du corpus tant qu'il en reste au moins autant que de créneaux à remplir, du plus récent au plus ancien, et nomme au modèle celles qu'il a dû garder (`applyRecentlyServed`, fixture `planning_slot_rules.json` › `recently_served`). Zéro désactive. |

---

### 3.9 Collection `recipe_ratings`

Une note personnelle sur 10, clé `{uid}_{recipeId}` : une note appartient à celui qui la
donne, pas à la recette.

---

### 3.10 Référentiels nutrition — `nutrition_ingredients`, `nutrition_units`

`nutrition_ingredients/{ingredientId}` — l'identifiant est **dérivé du nom** par
`normalizeIngredientStrictId`, des deux côtés (Dart et TypeScript, fixture
`ingredient_names.json`).

| Champ | Type | Description |
|---|---|---|
| `canonical_name` | `String` | Nom de référence |
| `aliases` | `String[]` | Toutes les orthographes rencontrées |
| `per100g` | `Map` | Valeurs pour 100 g (énergie, macronutriments, …) |
| `grams_per_piece` | `num?` | Poids d'une pièce, quand l'ingrédient se compte |
| `usual_portion_g` | `num?` | Grammes qu'une recette pour quatre personnes emploie d'ordinaire de cet ingrédient quand elle **n'écrit ni nombre ni unité** (« roquette », « parmesan pour râper dessus »). Estimée par l'IA (poste `estimate_usual_portions`, `aiEnrichment.ts`), une seule fois dans la vie de l'ingrédient, jamais redemandée tant qu'elle est renseignée — une correction à la main est donc conservée. Bornée à 500 g. Lue par `resolveWeighingInput` (TypeScript et Dart, fixture `unit_to_grams.json`, section `usual_portion`) : elle ne sert que sur une ligne nue, après la pincée d'un assaisonnement et après toute unité écrite. Reprise pour le passé par la reprise de la nutrition (*Admin › Backfills*), qui repasse par `syncRecipeNutrition` |
| `usual_portion_source` · `usual_portion_at` | `String?` · `Timestamp?` | `ai_estimated` ; date de l'estimation |
| `usual_portion_attempt_at` | `Timestamp?` | Dernière tentative sans réponse exploitable : la question n'est reposée qu'après vingt-quatre heures |
| `shopping_product` | `String?` | Le produit qu'on achète, sur la liste de courses : « beurre » pour `beurre_fondu`, « œuf » pour `jaune_d_oeuf`. **Absent** : jamais examiné. **Vide** : le nom est déjà le produit. Posé automatiquement à l'import pour un ingrédient neuf (`recipeNutritionAutoSync.ts`, poste `shopping_product_alias_auto`), rattrapé pour le passé par le backfill « Produit acheté des ingrédients » (mode `aliases` de `backfillShoppingFn`, poste `backfill_shopping_aliases`), passé au complet puis retiré le 5 octobre 2026, corrigé à la main depuis *Admin › Référentiels › Ingrédients* — la seule écriture du référentiel ouverte au client, à un administrateur, sur ce champ et sa source. Les deux passes automatiques partagent la même résolution (`shoppingAliases.ts`) : quand le produit proposé par le modèle correspond à un ingrédient déjà connu du référentiel, son orthographe exacte est reprise plutôt qu'une variante inventée — « beurre fondu » ne crée pas un second « Beurre » qui ne fusionnerait pas avec l'existant. Lu par `onRecipeWritten` quand il compose `shopping_products` |
| `shopping_product_source` | `String?` | `ai_estimated` \| `admin` |
| `source` | `String` | D'où viennent les valeurs : résolution, estimation d'IA, correction humaine |
| `status` · `quality_status` | `String` | `proposed` \| `known` ; qualité `pending` tant que rien n'a été vérifié |
| `seen_count` | `int` | Nombre de rencontres — sert à prioriser l'enrichissement |
| `first_seen_at` · `last_seen_at` · `updated_at` | `Timestamp` | Traçabilité |

`nutrition_units/{unitId}` porte les mêmes champs de traçabilité, plus les alias observés,
des exemples d'ingrédients associés et un `grams_per_unit` — **jamais** posé sur une unité
de volume ni de comptage, où il n'aurait aucun sens.

> Le référentiel dépasse le millier de documents : toute lecture plafonnée coupe la fin de
> l'alphabet, et ressemble alors à un défaut d'enrichissement.

**Le diagnostic de qualité — `getDataQualityReportFn`** (`callable/dataQualityCallable.ts`).
Callable réservée à l'admin (`ensureAdminWithAudit`, opération `data_quality_dashboard`),
appelée par *Admin › Qualité des données* (`/admin/data-quality`). **Lecture seule** : elle
n'écrit rien, contrairement à un backfill. Deux passages paginés par 500 documents :

| Passage | Contrôle | Condition |
|---|---|---|
| `nutrition_ingredients` | produit d'achat manquant | `shopping_product` absent (jamais examiné) |
| `nutrition_ingredients` | nutrition incomplète | `per100g` vide, ou `quality_status == estimation_failed` |
| `nutrition_ingredients` | sel implausible | plus de 100 g de sel pour 100 g, sel lu ou dérivé du sodium |
| `nutrition_units` | unité non confirmée | `status != known`, triées par `seen_count` décroissant |

Chaque contrôle rend un `count` exhaustif et au plus 200 exemples (`truncatedExamples` dit si
l'échantillon est coupé). Le parcours s'arrête à 480 s (délai de la fonction : 540 s) ;
`scanComplete: false` signale alors un rapport partiel. Modèle client :
`features/admin/domain/data_quality_report.dart`.

---

### 3.10 bis Garnitures simples — `meal_staples`, `users/{uid}/preferences/meal_staples`

Ce qui accompagne un plat sans avoir de recette : riz, pâtes, salade verte, yaourt. Un repas
en a besoin pour dire « blanquette et riz », pour compter le riz dans la liste de courses et
pour connaître la part par personne. Deux niveaux, un seul modèle (`meal_staple.dart`).

**Le référentiel partagé**, `meal_staples/{stapleId}` — lu par tout compte nommé, écrit par un
administrateur depuis *Admin › Référentiels › Garnitures simples*. L'identifiant est un slug
(`riz`, `pates`, `pommes_de_terre_vapeur`), dérivé du nom par `stapleIdFromName` quand il
n'est pas saisi.

| Champ | Type | Description |
|---|---|---|
| `name` | `String` | Nom affiché |
| `category` | `String` | `feculent` \| `legume` \| `salade` \| `pain` \| `fromage` \| `fruit` \| `laitage` \| `autre` — tri, affichage, et plus tard la composition d'un repas |
| `quantity_per_portion` | `num` | Quantité pour une part, dans `unit` |
| `unit` | `String` | `g` \| `ml` \| `pièce` |
| `note` | `String` | Précision de pesée ou d'achat : « poids sec » |
| `shopping_product` | `String` | Nom du produit sur la liste de courses ; vide = `name` (la purée s'achète en pommes de terre) |
| `sort_order` | `int` | Rang dans sa famille |
| `active` | `bool` | Désactivée par un admin : proposée à personne, retouches comprises |
| `source` | `String` | `builtin` (semée) \| `admin` (créée depuis l'écran) |
| `created_at` · `updated_at` | `Timestamp` | Traçabilité |

Le référentiel vit dans Firestore seul : aucune liste de garnitures n'existe dans le code.
Les entrées `source: builtin` viennent du semis initial ; une garniture s'ajoute ou se corrige
depuis l'écran d'administration.

**Les retouches de chacun**, `users/{uid}/preferences/meal_staples` — un seul document,
lu et écrit par son propriétaire depuis *Préférences › Mes garnitures*. Rien de personnel
n'écrit dans le référentiel partagé.

| Champ | Type | Description |
|---|---|---|
| `entries` | `Map<String, Map>` | Une entrée par identifiant de garniture. Sur un identifiant du référentiel, **seuls les champs présents remplacent** ceux de la base (`name`, `category`, `quantity_per_portion`, `unit`, `note`, `shopping_product`) : le reste continue de suivre les corrections de l'admin. `hidden: true` masque la garniture pour ce compte. `own: true` marque une garniture propre à l'utilisateur, qui porte alors tous ses champs |
| `updated_at` | `Timestamp` | Dernière écriture |

Chaque entrée est remplacée **en entier** à l'écriture (`SetOptions(mergeFields:
[entries.{id}])`) : une retouche est un tout, pas une fusion — sinon effacer une quantité
retouchée laisserait l'ancienne valeur en place. Une entrée qui ne dit plus rien est
supprimée plutôt que stockée. La lecture fusionnée vit dans `mergeStaples`
(`meal_staple.dart`) ; aucun test ne la couvre.

---

### 3.11 Comptabilité de l'IA

Cinq collections, écrites par `recordUsage` et par lui seul — sauf la carte `reservations` de
`ai_daily_spend`, écrite par `reserveDailyBudget` et `releaseDailyBudget`.

| Collection | Contenu |
|---|---|
| `ai_usage/{id}` | **Une ligne par appel** : `uid`, `feature`, `provider`, `model`, jetons d'entrée, de sortie, de réflexion, de cache (écriture et lecture), `image_output_count`, `analyzed_image_units` (image ANALYSÉE, facturée à l'unité — sans lui, une reconstruction qui rechiffre rendait un appel Cloud Vision à zéro), `estimated_cost_usd`, `status`, `cost_bucket`, `correlation_id`, `scan_id` (le scan de l'utilisateur, quand l'appel en vient un — c'est lui qui rend le coût d'un scan additionnable en une requête), `call_id` (le même identifiant que les lignes de journal de cet appel : c'est lui qui met un montant exact en face d'un appel dans l'écran des journaux, sans rapprochement par l'heure), `entity_type`, `entity_id`, `period`, `timestamp`. Un appel passé pendant une panne de grille porte en plus `pricing_unavailable: true` — c'est lui qui le rend retrouvable pour un rechiffrage |
| `token_usage/{uid}` | Agrégat par compte : total de jetons, coût, et le détail `features.{poste}` |
| `ai_usage_monthly/{AAAA-MM}` | Agrégat mensuel lu tel quel par l'écran des coûts : totaux (dont `total_unpriced_calls` et `total_analyzed_image_units`), puis les ventilations `by_feature` (dont `by_provider` **dans** le poste, seule façon de juger une bascule), `by_provider`, `by_model` et `by_user`. `by_feature` et `by_model` portent `analyzed_image_units` : c'est la seule quantité dont dépend une franchise mensuelle |
| `ai_daily_spend/{uid}_{AAAA-MM-JJ}` | Ce que le plafond relit avant chaque appel : `uid`, `day`, `calls`, `cost_usd`, `unpriced_calls` (incrémentés par `recordUsage` après l'appel), `updated_at`, et `reservations` (`Map<String, {at_ms: Number, usd: Number, feature: String}>`, depuis v0.23.10) — les appels en cours, réservés avant de partir et retirés à leur fin ; une entrée de plus de quinze minutes est ignorée puis supprimée. Aucune reprise : un document sans `reservations` se lit comme « rien en cours ». Un document par jour : aucune remise à zéro à planifier, et l'historique reste lisible tel quel — `getAiBudgetFn` accepte un paramètre `day` (`AAAA-MM-JJ`), ce qui permet à Admin → Dépense par utilisateur de remonter à une journée passée. Un second paramètre, `scope` (`months` par défaut, ou `day`), ramène **le tableau entier** à cette journée : l'agrégat mensuel n'ayant pas de dimension jour, la ventilation par compte et par poste est alors reconstruite depuis `ai_usage` sur les bornes UTC du jour, par pages de mille lignes et jusqu'à vingt mille — au-delà, la réponse porte `spendsTruncated: true` et l'écran annonce des montants incomplets. Deux paramètres `from` et `to` (`HH:MM` UTC, ignorés hors `scope: day`) resserrent la lecture à une partie du jour, la minute `to` comprise ; la réponse rend les bornes appliquées (`spendFrom`, `spendTo`), une fin qui précède le début étant écartée et rendue nulle. Ce mode ne lit aucun document de `ai_usage_monthly`. Le serveur refuse une date impossible ou à venir et retombe alors sur aujourd'hui ; il renvoie `day` (le jour lu) **et** `currentDay` (le jour courant), pour que l'écran sache s'il regarde une journée close |
| `scan_spend/{scanId}` | Compteur de ce qu'un scan a coûté et plafond d'un import de livre. `recordUsage` y ajoute chaque appel qui porte un `scanId` (`cost_usd`, `calls`, `unpriced_calls`). `runBookImport` y pose `limit_usd`, `step_usd` et `user_id` depuis `budget_limit_usd`, jamais à la baisse ; `setImportCeiling` et `raiseImportCeiling` refusent (`ForeignScanError`) un compteur dont `user_id` désigne un autre compte. `recipeProcessor` le relit avant le premier appel de chaque tranche de livre (`assertWithinImportBudget`) et lève `BudgetExceededError` (`reason: import`) quand `cost_usd >= limit_usd` : la tranche part en dead letter `budget_exceeded`. Relancer une tranche depuis la file — `jobDispatcher` voit le job revenir en `queued` — relève le plafond à `cost_usd + step_usd` si, et seulement si, il est atteint. Le contrôle ne vaut que pour le pipeline d'import : la nutrition calculée plus tard sur ces recettes porte le même `scanId` et n'est pas bloquée. Un plafond est en dollars, unité du coût mesuré |
| `ai_reconciliation_monthly/{AAAA-MM}` | Rapprochement entre le coût estimé et le coût facturé |

---

### 3.12 Exploitation — `dead_letters`, `error_reports`

- `dead_letters/{jobId}` : job d'import abandonné après trois tentatives, avec son motif et
  son étape. Relancé ou purgé depuis *Admin › File d'échecs*.
- `error_reports/{id}` : erreurs remontées par le client via `ErrorReportService` —
  `feature`, message, pile, `userId` et un `context` libre. C'est le seul endroit où un
  échec côté client laisse une trace : `debugPrint` est invisible en production.

---

### 3.13 Collection `app_config` — les décisions

Un document par décision. Aucune ne demande de déploiement pour changer.

| Document | Ce qu'il décide |
|---|---|
| `ai_routing_policy` | Quel moteur sert quel poste, et les budgets de réflexion |
| `ai_pricing` | La grille tarifaire — **plus aucun prix n'existe dans le code** ; la table du serveur ne sert qu'à semer ce document au premier démarrage |
| `ai_budget_policy` | Plafonds quotidiens par compte, en euros et en nombre d'appels, et le seuil d'alerte mensuel |
| `app_check_policy` | Mode d'attestation : `off`, `monitor`, `enforce` |
| `image_moderation` | Seuils, labels culinaires, moteur retenu |
| Politique nutrition | Seuils d'affichage, repli, priorité des sources |

`ai_routing_policy` porte un champ de plus, `presets_seeded_at` : la marque du
jour où la politique en vigueur a été recopiée dans une première configuration.
Elle empêche cette configuration de revenir après une suppression volontaire.

Six documents de plus ne décident rien : ce sont les **points de reprise** des
backfills (§7.10). Le serveur les écrit via `setBackfillCursor`
(`callable/_backfillCursor.ts`). Aucun code client ne les écrit, mais les règles
Firestore ne l'interdisent pas : un `admin` peut écrire sur tout `app_config`.

| Document | Écrit par |
|---|---|
| `nutrition_catch_up_checkpoint` | `backfillNutritionFn` |
| `shopping_products_backfill_checkpoint` | `backfillShoppingFn` |
| `recipe_roles_backfill_checkpoint` | `backfillRecipeRolesFn` |
| `user_profiles_backfill_checkpoint` | `backfillUserProfilesFn` |
| `backfill_cursor_enrich_referentials_ingredients` | `backfillEnrichReferentialsFn`, remplissage normal |
| `backfill_cursor_refresh_sodium_ingredients` | `backfillEnrichReferentialsFn`, réparation du sodium |

| Champ | Type | Contenu |
|---|---|---|
| `operation` | `String` | le nom du backfill |
| `last_doc_id` | `String?` | le dernier document traité ; `null` quand le passage est terminé, et l'appel suivant repart du début. Pour la nutrition, le curseur est la dernière recette **reprise**, et le passage n'est terminé que si la collection a été parcourue **et** qu'aucune recette n'a été laissée |
| `updated_at` | `Timestamp` | heure serveur de la dernière écriture |
| `updated_by` | `String?` | uid de l'admin qui a lancé l'appel |
| `last_report` | `Map?` | compte rendu du dernier passage, avec `finished_at` (heure serveur). Écrit par `backfillShoppingFn` et `backfillRecipeRolesFn` seulement. L'écran Admin › Backfills relit à l'ouverture celui du rôle des recettes (`backfill_reports_repository.dart`) : un passage dure plusieurs minutes, et son résultat affiché en fin de traitement n'était pas lu. Celui des produits d'achat n'est lu par aucun écran |

---

### 3.13 bis Collection `ai_routing_presets` — les configurations de routage

Un document par configuration enregistrée. Chacun porte `name`, `name_key` (le
nom en minuscules, qui interdit deux homonymes), `policy` — les sept réglages de
l'écran, aux mêmes clés que `ai_routing_policy` —, `created_at`, `updated_at` et
`updated_by`.

**Une configuration ne commande rien.** La politique en vigueur reste
`app_config/ai_routing_policy`, et elle seule. Charger une configuration remplit
le formulaire de l'écran ; c'est `setAiRoutingPolicyFn` qui écrit, après que
l'administrateur a vu l'écart et enregistré. Un chargement ne doit pas pouvoir
déplacer quarante-trois postes sans que personne l'ait lu.

**Le chargement est un remplacement, pas une fusion.** Un poste absent de la
configuration repart au moteur par défaut. Une fusion rendrait le résultat
dépendant de ce qui était en place avant, et deux essais successifs ne seraient
plus comparables — ce qui est le seul usage de cet écran.

**Une configuration vieillit.** La liste des postes routables perd des entrées à
chaque version : huit sont déjà parties avec le code qui les appelait. Une
configuration écrite en juillet qui nomme `detect_illustrations` reste
chargeable ; le poste disparu est écarté et la raison remonte à l'écran, dans
`stale`. La refuser en bloc laisserait un état ancien inatteignable sans dire
lequel des quarante-trois postes bloque.

Une même fonction de lecture juge les deux cas, `readRoutingPolicy`
(`ai/routingPresets.ts`), sur deux modes : `reject` pour ce que l'écran écrit —
un poste inconnu refuse la politique entière — et `drop` pour la relecture d'une
configuration. Sans ce partage, une configuration s'enregistrerait valide et se
chargerait invalide.

La politique en vigueur suit une troisième voie. `getAiRoutingPolicyFn` en retire
les postes sortis de `ROUTABLE_FEATURES` (`withoutRetiredFeatures`), et rien d'autre.
Sans ce filtre, l'écran renverrait le poste retiré à l'enregistrement, et `reject`
refuserait la politique entière. Un modèle par poste sorti de la liste de l'écran
reste affiché : son remplacement doit être un choix, pas un effacement.

**Une seule fonction déployée**, `aiRoutingPresetsFn`, aiguillée sur un champ
`action` : `save`, `update`, `rename`, `delete`. Le bundle porte déjà cinquante
fonctions et le budget de découverte du déploiement est de dix secondes. La
liste des configurations part avec `getAiRoutingPolicyFn`, dont la panne
n'interrompt pas l'écran : elle s'annonce par `presetsFailed`.

Au premier affichage de l'écran, la politique en vigueur est recopiée dans une
configuration nommée **« Haute performance »**. Sans elle, essayer une autre
configuration demanderait d'abord de penser à enregistrer l'état courant, et
personne n'y penserait avant de l'avoir perdu.

Règle Firestore : lecture administrateur, **écriture serveur uniquement**. Une
configuration écrite directement par le client échapperait au contrôle contre le
catalogue de postes, et se chargerait ensuite amputée sans que personne sache
pourquoi.

---

### 3.14 Le reste

- `image_moderation/{moderationId}` : décrit en tête de ce document, section *Spécification
  technique — Modération des images*.
- `users/{uid}/nutrition_portion_overrides/{recipeId}` : le nombre de portions choisi par
  **cet** utilisateur. Il vit sous lui, pas dans la recette — sans quoi chacun écraserait le
  choix de l'autre, silencieusement.
- `users/{uid}/preferences/book_order` : `book_ids`, la liste ordonnée des livres telle que
  **ce** lecteur a rangé sa bibliothèque au glisser-déposer, et `updated_at`. Même raison : un
  livre est vu par toute la famille, chacun le range où il veut. Les identifiants disparus sont
  ignorés à la lecture, les livres créés depuis se rangent à la fin.
- `users/{uid}/preferences/recipe_search_scope` : `sources` (clés de `RecipeSource` — recettes
  validées, brouillons, recettes famille, conception IA) et `book_ids`, le dernier périmètre
  choisi dans « Où chercher des recettes ? » du planning par lots. Un livre absent de `book_ids`
  est écarté de la recherche — y compris un livre créé depuis le dernier choix, qui se coche à la
  main comme les autres. Une recette sans `book_id` n'est jamais écartée par ce filtre : il ne
  peut pas se prononcer sur elle. Document absent = comportement d'avant ce réglage, recettes
  validées, tous les livres du moment.

---

### 3.15 Structure Firebase Storage

```
gs://{bucket}/
├── quarantine/{uid}/…      ← SEULE porte d'entrée : le client n'écrit que là
├── covers/{bookId}/…       ← écriture serveur uniquement
├── scans/{uid}/…           ← écriture serveur uniquement
├── illustrations/{uid}/…   ← écriture serveur uniquement
├── recipes/{recipeId}/…    ← écriture serveur uniquement
├── users/{uid}/…           ← couverture « Recette libre », écriture serveur uniquement
└── rejected/{uid}/…        ← images refusées, LECTURE ADMIN uniquement
```

Le fichier atterrit en quarantaine, le serveur l'inspecte (extension, type MIME, signature
binaire, taille), la modération le juge, et lui seul le promeut dans un dossier publié. Les
URL de téléchargement des images promues sont stockées dans `recipes.image_urls`.

Les images refusées sont **conservées** sous `rejected/` : sans l'image, personne ne peut
dire si le refus était fondé, et une modération qu'on ne peut pas évaluer ne se corrige
jamais. Aucun lien n'est stocké — l'écran d'administration lit le fichier avec les droits de
celui qui le consulte, si bien que retirer le rôle admin retire l'accès dans la seconde.

---

## 4. Firebase Security Rules

### Modèle d'autorisation : le rôle dans le jeton, la révocation dans le document

Le rôle et la révocation vivent à **deux endroits** : le document `users/{uid}`
et les custom claims du jeton, tenus à jour par le déclencheur `syncUserClaims`
(un amorçage en masse a rattrapé les comptes antérieurs au déclencheur, puis a
été retiré une fois son travail fait). Ce n'est pas une duplication
accidentelle : les règles **Storage** ne peuvent lire que le jeton — une lecture
Firestore depuis Storage est facturée et, surtout, peut échouer et faire refuser
la règle entière, ce qui a déjà cassé l'import de recettes.

Les règles **Firestore**, elles, ont accès aux deux sources. La question n'est
donc pas « l'une ou l'autre » mais « laquelle pour quoi » :

| | Source | Pourquoi |
|---|---|---|
| **Rôle** | jeton, repli sur le document si le claim est absent | change rarement ; une latence d'une heure sur une promotion est sans effet, et le lire dans le jeton évite une lecture facturée par requête. Le repli évite de mettre dehors les comptes dont le jeton n'est pas encore rafraîchi |
| **Révocation** | document, le jeton pouvant seulement la **confirmer** | c'est le seul contrôle qui doit mordre tout de suite : couper l'accès à quelqu'un et devoir attendre le renouvellement de son jeton n'est pas une révocation |

**Écart assumé et connu :** sur Storage, une révocation ne prend effet qu'au
renouvellement du jeton (une heure au plus) ; sur Firestore elle est immédiate.
Storage ne peut pas faire mieux sans réintroduire la lecture inter-services qui
avait cassé l'import. Depuis la v0.23.12, `syncUserClaims` appelle en plus
`revokeRefreshTokens` quand un compte perd l'accès — passage à révoqué, rôle qui sort de
reader/editor/admin, document supprimé d'un compte nommé ou révoqué : la session ne se
renouvelle plus, et le jeton en cours n'est pas prolongé au-delà de son heure.

La présence d'un claim se teste par `'clé' in request.auth.token` plutôt que par
comparaison à `null` : c'est la seule forme dont la sémantique est garantie sur
un claim absent.

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    // Fonctions utilitaires
    function isAuthenticated() {
      return request.auth != null;
    }

    function getUserData() {
      return get(/databases/$(database)/documents/users/$(request.auth.uid)).data;
    }

    function tokenHasRole() {
      return 'role' in request.auth.token && request.auth.token.role != null;
    }

    // Le rôle en vigueur : le claim s'il existe, le document sinon.
    function roleOf() {
      return tokenHasRole() ? request.auth.token.role : getUserData().role;
    }

    function approvedRoles() {
      return ['reader', 'editor', 'admin'];   // `pending` n'y est pas
    }

    // Un rôle ne suffit pas : il faut aussi ne pas être révoqué. Le contrôle
    // manquait ici — un éditeur révoqué continuait d'écrire.
    function hasRole(role) {
      return isAuthenticated() && !isRevoked() && roleOf() == role;
    }

    function isAdmin() {
      return hasRole('admin');
    }

    function isEditor() {
      return hasRole('editor') || isAdmin();
    }

    // Le jeton confirme une révocation, jamais ne l'infirme.
    function isRevoked() {
      return ('revoked' in request.auth.token && request.auth.token.revoked == true)
        || getUserData().is_revoked == true;
    }

    // Le sas d'entrée : garde tout ce qui est partagé. Remplace l'ancien
    // `isReader()`, qui se contentait d'« authentifié et non révoqué ».
    function isApproved() {
      return isAuthenticated() && !isRevoked() && roleOf() in approvedRoles();
    }

    function isOwner(uid) {
      return isAuthenticated() && request.auth.uid == uid;
    }

    function founderEmail() {
      return 'china.fred.75@gmail.com';
    }

    function isFounder() {
      return isAuthenticated() && 'email' in request.auth.token
        && request.auth.token.email.lower() == founderEmail();
    }

    // Collection users
    match /users/{uid} {
      function touchesAuthority() {
        return request.resource.data.diff(resource.data).affectedKeys()
                 .hasAny(['role', 'is_revoked']);
      }
      // L'adresse ne change plus après la création, administrateur compris
      // (v0.23.10) : c'est elle qui désigne le fondateur dans targetIsFounder.
      function touchesEmail() {
        return request.resource.data.diff(resource.data).affectedKeys()
                 .hasAny(['email']);
      }
      function targetIsFounder() {
        return resource.data.get('email', '').lower() == founderEmail();
      }
      // Un nom est absent, nul, ou une chaîne de 60 unités UTF-16 au plus
      // (v0.23.14) : il est recopié dans le profil public.
      function nameOk(field) {
        return !(field in request.resource.data)
               || request.resource.data[field] == null
               || (request.resource.data[field] is string
                   && request.resource.data[field].size() <= 60);
      }
      function namesBounded() {
        return nameOk('display_name') && nameOk('preferred_name');
      }
      // À la mise à jour, seul un nom modifié est contrôlé.
      function touchedNamesBounded() {
        let keys = request.resource.data.diff(resource.data).affectedKeys();
        return (!keys.hasAny(['display_name']) || nameOk('display_name'))
               && (!keys.hasAny(['preferred_name']) || nameOk('preferred_name'));
      }

      // Titulaire ou administrateur (v0.23.14) : le nom d'un autre membre
      // se lit dans `user_profiles/{uid}`.
      allow read: if isOwner(uid) || isAdmin();

      // Le rôle et l'identité d'un compte neuf sont imposés, pas proposés.
      allow create: if isAuthenticated() && request.auth.uid == uid
                      && request.resource.data.role == 'pending'
                      && request.resource.data.is_revoked == false
                      && request.resource.data.email == request.auth.token.email
                      && namesBounded();

      // Un administrateur nomme et révoque — sauf le fondateur, que lui seul
      // peut destituer.
      allow update: if !touchesEmail()
                      && touchedNamesBounded()
                      && ((isAdmin() && (!touchesAuthority() || !targetIsFounder() || isFounder()))
                          || (isAuthenticated() && request.auth.uid == uid
                              && !touchesAuthority()));

      allow delete: if isAdmin() && !targetIsFounder();

      // Deux sous-collections, et la même règle pour les deux : ce sont des
      // choix de LECTEUR. Ils n'appartiennent qu'à leur propriétaire et
      // n'existent pas dans les documents partagés.
      //
      // `nutrition_portion_overrides/{recipeId}` : le nombre de parts retenu
      // pour cette recette-là. `preferences/{prefId}` : l'affichage, dont
      // `book_order`, le rangement de la bibliothèque.
      match /nutrition_portion_overrides/{recipeId} {
        allow read, write: if isOwner(uid) || isAdmin();
      }
      match /preferences/{prefId} {
        allow read, write: if isOwner(uid) || isAdmin();
      }
    }

    // ── Confidentialité et propriété (v0.23.8) ───────────────────────────
    // Privé = créateur seul, plus l'administrateur. On ne modifie que ses
    // propres livres et recettes, éditeur compris ; l'administrateur agit
    // comme le créateur. `created_by` = l'appelant à la création, figé ensuite.
    //
    // Un document n'est partagé que s'il porte `is_private == false` : pas de
    // `get('is_private', false)`, car dans une requête la valeur par défaut
    // n'est pas prouvée par les filtres et une liste sans filtre passait.
    function isSharedDoc(data) { return data.is_private == false; }
    function isCreator(data) {
      return isAuthenticated() && data.created_by == request.auth.uid;
    }
    function keepsCreator() {
      return request.resource.data.get('created_by', null)
        == resource.data.get('created_by', null);
    }
    // Un brouillon partagé reste lisible par un éditeur (relecture).
    function canReadRecipe(data) {
      return isApproved() && (
        (isSharedDoc(data) && (data.review_status == 'validated' || isEditor()))
        || isCreator(data)
        || isAdmin());
    }
    function recipeDoc(recipeId) {
      return get(/databases/$(database)/documents/recipes/$(recipeId)).data;
    }

    // Collection books
    match /books/{bookId} {
      // Les trois livres système se reconnaissent à leur tag interne. Ils se
      // renomment, mais ne se suppriment pas : ce sont les destinations par
      // défaut des recettes sans livre et des créations de l'IA. Les perdre
      // laisserait la règle « toute recette a un livre » sans issue.
      function systemTags() {
        return ['__libres', '__kassdale_ia', '__secretes'];
      }

      function isSystemBook(data) {
        return data.tags is list && data.tags.hasAny(systemTags());
      }

      // Une mise à jour garde chaque tag système que le livre portait :
      // sans cela, retirer le tag puis supprimer le livre contournait la garde.
      function keepsSystemTags() {
        return !isSystemBook(resource.data)
          || (request.resource.data.get('tags', null) is list
              && request.resource.data.tags.toSet().hasAll(
                   resource.data.tags.toSet().intersection(systemTags().toSet())));
      }

      allow read: if isApproved()
        && (isSharedDoc(resource.data) || isCreator(resource.data) || isAdmin());
      allow create: if isEditor() && request.resource.data.created_by == request.auth.uid;
      allow update: if isEditor() && (isCreator(resource.data) || isAdmin()) && keepsCreator()
        && keepsSystemTags();
      allow delete: if isEditor() && (isCreator(resource.data) || isAdmin())
        && !isSystemBook(resource.data);
    }

    // Collection recipes
    match /recipes/{recipeId} {
      // Le livre d'une recette, contrôlé à toute écriture qui pose ou change
      // `book_id` (propriété + confidentialité) ou qui change `is_private`
      // (confidentialité seule). Un seul `get()` du livre par écriture.
      // Sans livre : rien à vérifier. Livre inexistant ou `book_id` avec
      // « / » : refusé.
      function bookAccepts(book, checkOwner) {
        return book != null
          && (!checkOwner || isAdmin() || book.data.get('created_by', null) == request.auth.uid)
          && request.resource.data.get('is_private', false) == book.data.get('is_private', false);
      }
      function bookCheck(checkOwner) {
        let bookId = request.resource.data.get('book_id', null);
        return !(bookId is string) || bookId == ''
          || (!bookId.matches('.*/.*')
              && exists(/databases/$(database)/documents/books/$(bookId))
              && bookAccepts(get(/databases/$(database)/documents/books/$(bookId)), checkOwner));
      }
      function changes(field) {
        return request.resource.data.diff(resource.data).affectedKeys().hasAny([field]);
      }

      allow read: if canReadRecipe(resource.data);
      allow create: if isApproved() && request.resource.data.created_by == request.auth.uid
        && bookCheck(true);
      allow update: if isApproved() && (isCreator(resource.data) || isAdmin()) && keepsCreator()
        && ((changes('book_id') && bookCheck(true))
            || (!changes('book_id') && (!changes('is_private') || bookCheck(false))));
      allow delete: if isApproved() && (isCreator(resource.data) || isAdmin());

      // Tout compte nommé qui voit la recette lit et pose des annotations ;
      // l'auteur (et l'admin) les modifie ou les supprime, `uid` figé.
      match /annotations/{annotationId} {
        allow read: if isApproved()
          && (isOwner(resource.data.uid) || canReadRecipe(recipeDoc(recipeId)));
        allow create: if isApproved() && request.resource.data.uid == request.auth.uid
          && canReadRecipe(recipeDoc(recipeId));
        allow update: if isApproved() && (isOwner(resource.data.uid) || isAdmin())
          && request.resource.data.uid == resource.data.uid;
        allow delete: if isApproved() && (isOwner(resource.data.uid) || isAdmin());
      }
    }

    // Suivi de l'usage des tokens IA — écrit par les Cloud Functions seules.
    // La règle de création était ouverte au client : n'importe quel compte
    // pouvait inscrire des dépenses imaginaires que la réconciliation aurait
    // présentées comme réelles.
    match /ai_usage/{docId} {
      allow read: if isAdmin() || (isAuthenticated() && resource.data.uid == request.auth.uid);
      allow write: if false;
    }
  }
}
```

> Extrait du **cœur d'autorisation** et non copie intégrale : `kass_dalle/firestore.rules`
> fait foi. Voici ce qu'il couvre en plus, et selon quelle logique :

| Collection | Lecture | Écriture |
|---|---|---|
| `user_profiles` | `isApproved()` | **serveur seul** (`allow write: if false`) — `syncUserClaims` et `backfillUserProfilesFn` |
| `users/{uid}/nutrition_portion_overrides` | propriétaire ou admin | propriétaire ou admin |
| `users/{uid}/preferences` | propriétaire ou admin | propriétaire ou admin |
| `recipe_ratings` | l'auteur, ou tout compte qui peut lire la recette notée (`canReadRecipe` par `get()` sur `recipe_id`) | création par un compte nommé, à son nom (`user_id`), sur une recette qu'il peut lire ; modification et suppression par l'auteur ou un admin, `user_id` et `recipe_id` figés |
| `groups` | membres du groupe | création à son nom, soi seul membre ; modification et suppression par le propriétaire ou un admin, `owner_id` figé |
| `processing_jobs` | admin, ou propriétaire du job — un éditeur ne lit plus les jobs d'autrui (v0.23.12) ; sa file de travail ne liste que les siens, la vue de tous les jobs est réservée à l'admin | création par un éditeur ou un admin (`isEditor()`), à son propre nom (`created_by == request.auth.uid`) : un `reader` n'importe pas, un job lançant le pipeline facturé (`jobDispatcher`) ; le propriétaire ne peut ensuite toucher qu'aux champs de relance et d'annulation, et la relance (retour en `queued`, qui relance le pipeline) exige aussi `isEditor()` — un propriétaire qui n'est pas éditeur ne peut écrire que l'annulation exacte de `cancelJob` (`status: 'error'` et `cancel_requested: true`), car `jobDispatcher` met aussi en file un job au statut absent ou vide |
| `planned_meals` · `planning_config` | le propriétaire seul, même en attente ou révoqué | création et modification par le propriétaire **nommé** (`isApproved()`) : un compte en attente ou révoqué ne planifie pas ; `uid` d'un repas figé ; suppression d'un repas par le propriétaire |
| `error_reports` | admin, ou l'auteur du rapport | création par l'auteur non révoqué — un compte en attente, et un compte neuf sans document, en écrivent ; la révocation est lue par `exists()` pour ne pas échouer avant la création du document ; modification et purge par l'admin |
| `app_config` | admin ; `usage` et `ai_pricing` par tout compte nommé (`isApproved()`) | admin ; sur `usage`, tout compte nommé, limité à `storage_bytes`, `updated_at` et au compteur `scans_AAAA_MM` du mois courant ou précédent (`hasOnly`), chaque compteur écrit restant un entier positif qui ne recule pas (`countsUp`) |
| `ai_routing_presets` | admin | **serveur seul** — `aiRoutingPresetsFn` contrôle une configuration contre le catalogue de postes avant de l'écrire |
| `nutrition_ingredients` | `isApproved()` | serveur ; l'admin modifie seulement `shopping_product`, `shopping_product_source` et `updated_at`. Création et suppression refusées au client |
| `nutrition_units` | `isApproved()` | admin |
| `meal_staples` | `isApproved()` | admin — les retouches de chacun vivent sous `users/{uid}/preferences/meal_staples`, jamais ici |
| `image_moderation` | admin, ou celui qui a envoyé l'image | **serveur seul** — une décision de modération que le client peut écrire n'est pas une décision |
| `ai_usage` · `ai_daily_spend` | admin, ou le compte concerné | **serveur seul** — un client pouvait autrefois y inscrire des dépenses imaginaires que la réconciliation aurait présentées comme réelles |
| `scan_spend` | admin | **serveur seul** — un client qui pourrait relever son propre plafond ne serait plus plafonné |
| `dead_letters` · `ai_reconciliation_monthly` | admin | **serveur seul** |

Toutes les lectures partagées passent par `isApproved()` : être connecté ne donne accès à rien.

**Une règle n'est pas un filtre.** Firestore refuse une requête entière dès que ses filtres ne
suffisent pas à prouver que chaque résultat possible est lisible. Les requêtes du client sur
`recipes` et `books` portent donc `is_private == false` (contenu partagé) ou
`created_by == uid` (le sien) ; hors administrateur, `RecipeRepository` scinde une requête par
livre ou par statut en ces deux requêtes et fusionne les résultats sans doublon
(`RecipeViewer`, `_visibleQueries`). Un lecteur ne relit que ses propres brouillons. Une requête
par identifiants (`FieldPath.documentId whereIn`, planning) est évaluée document par document :
une recette devenue privée fait refuser le lot, que `PlanningRepository.getRecipesByIds` relit
alors recette par recette en écartant celles qui sont refusées. Un document sans `is_private`
n'est lisible que par son créateur et l'administrateur. Toute écriture pose le champ depuis sa
création. Le fonds antérieur l'a reçu par deux reprises lancées en production puis retirées
du code : « Reprendre la confidentialité » pour les recettes, `backfillBookPrivacyFn` pour les
livres (v0.23.8, retirée en v0.23.14).

**Une recette prend la confidentialité de son livre à l'écriture.** Une recette créée ou
déplacée dans un livre privé avec `is_private: false` restait lisible par la famille jusqu'au
passage de `syncRecipePrivacy`. La règle `bookCheck` l'interdit ; le client écrit
`is_private` depuis le livre (`privacyOfBook`, `withBookPrivacy`, `recipe_repository.dart`) à
la création, à la mise à jour, à la validation d'un brouillon, au rattachement aux recettes
libres et à l'enregistrement d'une recette du planning. Sans livre, il n'écrit rien de nouveau :
la recette garde sa confidentialité, et une recette libre privée ne redevient pas publique à
l'enregistrement.

**On ne range une recette que dans ses propres livres** (décision de l'utilisateur, option A,
v0.23.8) ; l'administrateur partout. À la création, et à toute mise à jour qui change
`book_id`, `bookCheck(true)` exige que le livre existe et que son `created_by` soit l'appelant.
Les pages d'autrui déjà rangées dans un livre y restent, sans migration : une mise à jour qui
ne change pas `book_id` n'est pas contrôlée sur la propriété. Les livres système (« Mes
recettes libres », « Mes créations Kass'Dalle », « Mes Recettes Secrètes ») appartiennent à
leur utilisateur. Le sélecteur de livre ne propose que les livres de l'utilisateur, tous les
livres pour un administrateur (`targetBooksProvider`). Le pipeline d'import écrit par l'Admin
SDK, hors règles, dans le `book_id` posé sur le job : `assertJobTargetBook`
(`pipeline/targetBook.ts`) le vérifie au début de `recipeProcessor` — livre de l'importateur, ou
importateur administrateur — et un refus part en dead letter dès la première tentative, avec
`failure_reason: foreign_book`. Le sélecteur d'un administrateur masque les livres système des
autres membres, tous titrés pareil ; le nom du propriétaire n'est pas ajouté au titre, qui
s'écrit dans `book_titre`. Une page rangée dans le livre d'un autre garde ce livre en tête du
sélecteur (`booksWithOrigin`). Un lien `/scan?bookId=` vers un livre hors de cette liste
n'est pas verrouillé : le choix est effacé. Le client ne relit le livre d'une recette qu'à un
changement de livre (`bookChanges`) : l'auteur d'une page rangée dans le livre privé d'un
autre ne peut pas lire ce livre. `book_id` doit être nul ou une chaîne. Le serveur (Admin SDK) écrit hors des règles, et
`onBookWritten` continue de propager un basculement de livre.

**Un livre supprimé ne laisse pas de `book_id` orphelin.** Son créateur ne supprime ni ne
détache que ses propres recettes ; à la suppression, `onBookWritten` détache les autres
(`detachRecipesOfDeletedBook`), qui deviennent des recettes libres de leurs auteurs. Celles
d'un livre privé reçoivent `is_private: true` avec le détachement, et `syncRecipePrivacy`
garde la confidentialité d'une recette sans livre : une page détachée d'un livre privé — par
le serveur ou par le bouton « Détacher » du client — ne devient pas lisible par la famille.
`migrateLibresRecipes` ne range pas une recette libre privée dans « Mes recettes libres ».
Non traité : le détachement réveille `onRecipeWritten`, qui peut lancer `syncRecipeMealRole`
(un appel de modèle) sur une recette encore sans rôle de repas.

**Un `book_id` contenant « / » est refusé** par `bookCheck` ; côté serveur,
`expectedPrivacy` le traite comme un livre introuvable et le signale par `logError`.

**Les callables qui écrivent sur une recette suivent `allow update`.** `suggestPlatingFn`,
`suggestStorageAdviceFn`, `generatePlatingImageFn` et `computeRecipeNutritionFn` lisent et
écrivent la recette par l'Admin SDK, hors règles. `assertCanModifyRecipe`
(`callable/_recipeAccess.ts`, décision pure `recipeWriteDenial` testée) les fait refuser en
`permission-denied` à tout compte qui n'est ni le créateur (`created_by` non vide, égal à
l'appelant) ni un administrateur (relu par `isAdminAccount`), avant tout appel de modèle.
Une recette absente répond `not-found`. Ce contrôle couvre aussi la confidentialité : le
créateur et l'administrateur lisent une recette privée. `generatePlatingImageFn` exige en plus
le rôle éditeur. Conséquence : l'instruction libre `plating_advice.user_instruction` n'est plus
celle d'un tiers, seuls le créateur et l'administrateur l'écrivent. Les déclencheurs
(`onRecipeWritten`, rattrapage nutrition) ne passent pas par ces callables et calculent pour
toutes les recettes.

Les autres écritures déclenchées par un utilisateur sur une recette passent par le client et
donc par les règles : affinage, étiquettes, rôle de repas, illustration ajoutée, intégration du
dressage au texte. Les callables correspondantes (`refineRecipeFn`, `suggestRecipeTagsFn`,
`generateRecipeIllustrationFn`, `normalizeRecipeReferentialsFn`…) rendent un résultat sans
écrire sur la recette. `enhanceIllustrationFn`, qui remplace une URL dans `image_urls`, est
réservée aux administrateurs.

Les déclencheurs d'une recette imputent la dépense d'IA à son `created_by`. Les règles le
figent ; côté serveur, une recette sans propriétaire s'impute à `system_recipe_without_owner`
(plafond commun), et un appel sans uid au compte `system_unattributed`, plafonné au
multiplicateur du fondateur (voir §6, « Principe »).

### Firebase Storage Rules

Ces règles ne voient **que le jeton** : aucune lecture Firestore, sous peine de rendre la règle
faillible et facturée. L'écriture exige donc un claim de rôle **explicite**. Elle acceptait
auparavant tout jeton n'affirmant pas être `reader` — précaution du temps où aucun jeton ne portait
encore de claim, et qui aurait suffi à un compte `pending` pour déposer des images dans les dossiers
partagés.

```javascript
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {

    function isAuthenticated() { return request.auth != null; }

    // Un jeton sans claim de révocation est traité comme actif : la migration
    // ne doit verrouiller personne dehors. La présence se teste avant la
    // valeur : comparer une clé absente lève une erreur, et l'erreur refusait
    // l'accès (écart corrigé en v0.23.8).
    function isActive() {
      return isAuthenticated()
        && (!('revoked' in request.auth.token) || request.auth.token.revoked != true);
    }

    // Le sas d'entrée, côté fichiers. Ne concerne que l'écriture : fermer aussi
    // la lecture ferait clignoter les images de qui n'a pas renouvelé son jeton,
    // pour un gain nul (les URL ne se devinent pas).
    function isApprovedToken() {
      return isActive() && request.auth.token.role in ['reader', 'editor', 'admin'];
    }

    function isOwner(uid) { return isAuthenticated() && request.auth.uid == uid; }

    // Le type MIME sans ses paramètres : le texte collé s'envoie en
    // `text/plain; charset=utf-8`, qu'une comparaison exacte refuserait.
    function baseContentType() {
      return request.resource.contentType.split(';')[0].trim();
    }

    // Les seuls types qu'un import produit. Même liste que ALLOWED_MIME_TYPES
    // côté serveur, qui inspecte le fichier avant de le promouvoir : ce
    // contrôle-ci évite seulement que le dépôt serve à autre chose.
    function isImportableUnder(maxBytes) {
      return request.resource.size < maxBytes
        && baseContentType() in [
             'image/jpeg', 'image/png', 'application/pdf',
             'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
             'text/plain'
           ];
    }

    // Administrateur, sur la foi du claim. Sert la seule lecture qui ne soit
    // pas ouverte à la famille : les images refusées par la modération. Ici,
    // l'absence de preuve vaut refus.
    function isAdmin() {
      return isActive() && request.auth.token.role == 'admin';
    }

    // ── Les dossiers PUBLIÉS sont fermés en écriture ────────────────────────
    //
    // Une image vue par toute la famille passe par la quarantaine et par la
    // modération avant d'atterrir ici. Laisser le client y écrire en direct
    // rendrait la modération contournable en une ligne de code.

    match /covers/{allPaths=**} {
      allow get: if isActive();
      allow list: if isAdmin();   // lister : administrateur seul
      allow write: if false;
    }

    // Quarantaine : SEULE porte d'entrée d'une image.
    //
    // Début d'une chaîne d'appels d'IA facturés : la propriété du dossier ne
    // suffit pas, le compte doit avoir été nommé. Et le dépôt n'accepte que ce
    // qu'un import produit — il acceptait auparavant n'importe quel fichier
    // jusqu'à cinquante mégaoctets, ce qui en faisait un hébergement gratuit.
    //
    // La lecture est ouverte à l'ADMINISTRATEUR en plus du propriétaire : une
    // image « à revoir » attend ici, et personne ne tranche sur une photo qu'il
    // ne peut pas voir.
    match /quarantine/{uid}/{allPaths=**} {
      allow read: if isOwner(uid) || isAdmin();
      allow write: if isOwner(uid) && isApprovedToken()
        && isImportableUnder(50 * 1024 * 1024);
    }

    // Un livre entier — PDF, EPUB ou Word — à découper en recettes. Plafond de
    // 300 Mo, et seulement sous `livres/`. Les deux blocs `match` se recouvrent :
    // l'accès est accordé si l'un d'eux l'autorise, et le premier refuse toujours
    // plus de 50 Mo. Même plafond que `MAX_BOOK_UPLOAD_SIZE_BYTES`
    // (`utils/uploadSecurity.ts`) et que `_maxBookBytes` (`scan_upload_service.dart`).
    match /quarantine/{uid}/livres/{fileName} {
      allow read: if isOwner(uid) || isAdmin();
      allow write: if isOwner(uid) && isApprovedToken()
        && request.resource.size < 300 * 1024 * 1024
        && baseContentType() in [
             'application/pdf',
             'application/epub+zip',
             'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
           ];
    }

    // Lire un fichier dont on a l'adresse : tout compte actif. LISTER le
    // dossier : son propriétaire ou un admin (v0.23.8). Le client ne liste
    // aucun dossier publié ; `covers/`, `illustrations/{uid}` et `users/{uid}`
    // ne se listent que par un admin.
    match /scans/{uid}/{allPaths=**} {
      allow get: if isActive();
      allow list: if isActive() && (isOwner(uid) || isAdmin());
      allow write: if false;              // Admin SDK uniquement
    }

    // Images refusées par la modération — lecture ADMIN uniquement. Elles sont
    // conservées : sans l'image, un administrateur ne peut pas juger si le
    // refus était fondé, et une modération qu'on ne peut pas évaluer ne se
    // corrige jamais.
    match /rejected/{uid}/{allPaths=**} {
      allow read: if isAdmin();
      allow write: if false;
    }

    match /illustrations/{uid}/{allPaths=**} {
      allow get: if isActive();
      allow list: if isAdmin();   // lister : administrateur seul
      allow write: if false;
    }

    // Lister le dossier d'une recette, qui peut être privée : admin seul.
    match /recipes/{recipeId}/{allPaths=**} {
      allow get: if isActive();
      allow list: if isAdmin();
      allow write: if false;
    }

    match /users/{uid}/{allPaths=**} {
      allow get: if isActive();
      allow list: if isAdmin();   // lister : administrateur seul
      allow write: if false;
    }
  }
}
```

> Les six dossiers publiés (`covers/`, `scans/`, `rejected/`, `illustrations/`, `recipes/`,
> `users/`) sont fermés en écriture : seul le serveur y dépose, par l'Admin SDK.

**Un refus Storage ne dit jamais lequel de ses contrôles a mordu.** Sur `quarantine/`, un
`[firebase_storage/unauthorized]` peut vouloir dire quatre choses : le chemin n'appartient
pas à l'appelant, son jeton ne porte pas encore de rôle (compte `pending`, ou jeton émis
avant la propagation — une heure au plus), le fichier dépasse 50 Mo (300 Mo sous
`quarantine/{uid}/livres/`), ou son type MIME n'est pas dans la liste. C'est pourquoi le rapport d'erreur du client porte `sizeBytes`,
`storagePath` et `mimeType` : sans eux, les quatre causes sont indiscernables.

### Tests des règles

`kass_dalle/rules-tests/` est un paquet Node à part, séparé de `functions/` pour que le
`npm test` des Functions n'exige pas Java. Il dépend de `@firebase/rules-unit-testing`, de
`firebase` et de `firebase-tools` épinglé à la version de `deploy.yml` (15.32.1).

```bash
cd kass_dalle/rules-tests
npm ci
npm test   # firebase emulators:exec --only firestore,storage --project demo-kassdalle "node --test …"
```

- Les règles chargées sont celles du dépôt : `kass_dalle/firestore.rules` et
  `kass_dalle/storage.rules`, lues par `firebase.json`. Le projet `demo-kassdalle` empêche tout
  appel vers `kassdale-6d948`.
- Java 21 au moins : firebase-tools 15 refuse de lancer les émulateurs avant cette version.
- `test/helpers.mjs` décrit les comptes de test : `admin`, `editor`, `reader`, `pending`,
  révoqué (jeton à jour, ou jeton périmé avec `is_revoked` posé sur le document), compte sans
  claim de rôle, fondateur, et anonyme. Chaque compte a un jeton (`role`, `revoked`, `email`,
  comme les frappe `syncUserClaims`) et un document `users/{uid}`, relu par les règles Firestore.
- `test/firestore.test.mjs` et `test/storage.test.mjs` couvrent le comportement actuel, rôle par
  rôle : création de compte, rôle et fondateur, livres, recettes, annotations, notes, champs
  propriétaire, `app_config`, collections de coût, `processing_jobs`, référentiels ; côté
  Storage, dossiers publiés, quarantaine (propriété, rôle, types, tailles), `rejected/`.
- Le bloc « requêtes du client » rejoue la forme des requêtes de `recipe_repository.dart`,
  `book_repository.dart`, `planning_providers.dart`, `annotation_repository.dart` et
  `recipe_rating_repository.dart`. L'émulateur évalue une requête sur ses filtres, comme la
  production : une requête qui perd son filtre `is_private` ou `created_by` y échoue, même sur
  une collection vide.

**Convention `todo`.** Une faille relevée et encore ouverte a son test, écrit avec l'attendu
corrigé et marqué `{ todo: "faille ouverte, audit 2026-10-09" }` (constante `OPEN_FLAW`). Sous
`node:test`, un `todo` qui échoue ne fait pas échouer la suite. La correction de la faille
retire l'option dans le même commit : le test devient bloquant. Une règle corrigée sans test
est une anomalie de relecture.

La décision de propriété est en vigueur depuis la v0.23.8 : une recette ou un livre privé ne se
lit que par son créateur et l'administrateur ; chacun ne modifie que ses propres recettes et
livres, éditeur compris ; l'administrateur agit comme le créateur. Un éditeur lit encore les
brouillons **partagés** d'autrui (relecture), sans pouvoir les modifier.

**Comptes au 2026-10-10 (v0.23.14)** : 321 tests, 321 actifs, aucun `todo`.

- Firestore : 253 tests, 253 actifs, aucun `todo`.
- Storage : 68 tests, 68 actifs, aucun `todo`.

La v0.23.14 rend bloquant le dernier `todo`, « un éditeur ne lit pas le document d'un autre »,
et ajoute 13 tests : un éditeur ne liste pas `users`, un administrateur lit et liste `users` ;
sur `user_profiles`, un lecteur et un éditeur lisent le profil d'un autre, un lecteur liste les
profils, un compte en attente, un compte révoqué et un anonyme n'en lisent aucun, et personne
n'écrit ni ne supprime un profil côté client, administrateur compris.

La v0.23.12 rend bloquants 12 des 13 `todo` et ajoute 20 tests qui vérifient que le cas
légitime reste accepté : renommer un livre système et lui ajouter un tag, changer les tags
d'un livre ordinaire, retirer le champ `tags` (refusé) ; ajouter un membre à son groupe,
`owner_id` figé pour l'administrateur aussi, modifier son repas ; un lecteur planifie et écrit
`planning_config`, un compte en attente et un compte neuf écrivent un rapport d'erreur, un
compte révoqué à l'instant n'en écrit pas, un compte révoqué ne modifie pas son repas, un compte
en attente relit sa configuration ; `storage_bytes` qui recule ou n'est pas entier, incrément du
client par `FieldValue.increment`, remise à zéro par un administrateur ; un éditeur liste ses
jobs mais pas tous, un administrateur les lit tous.

La v0.23.10 rend bloquant le test « un administrateur ne change pas l'adresse du fondateur » et
ajoute huit tests sur l'adresse immuable : retrait de l'adresse du fondateur, changement
d'adresse puis de rôle en une écriture, adresse d'un autre compte, propre adresse d'un
administrateur et du fondateur, champ neutre d'un autre compte modifiable par un
administrateur, réécriture à l'identique permise, compte ancien sans adresse toujours
nommable.

La lecture de `users/{uid}` d'autrui par un éditeur est fermée depuis la v0.23.14. Une règle
Firestore ne filtre pas les champs d'une lecture : les écrans qui affichaient un nom — file de
travail, relecture d'un brouillon, détail et liste des recettes, bibliothèque, membres d'un
groupe — lisent désormais le profil public `user_profiles/{uid}` (§3.1 bis), et la recherche de
membres d'un groupe (`GroupRepository.searchUsers`) interroge `user_profiles`, par nom seulement.

---

## 5. Authentification Google Sign-In

### Flux d'authentification

```
App Launch
    │
    ▼
Firebase Auth state listener
    │
    ├─ Non connecté ──► Écran Google Sign-In
    │                        │
    │                        ▼
    │                   GoogleSignIn.signIn()
    │                        │
    │                        ▼
    │                   Firebase Auth (credential)
    │                        │
    │                        ▼
    │                   Vérification users/{uid} dans Firestore
    │                        │
    │                   ┌────┴─────────────────────────────┐
    │                   │ Nouveau ?                        │
    │                   │ → Créer document users/{uid}     │
    │                   │   role = 'pending' (imposé par   │
    │                   │   les règles) → salle d'attente  │
    │                   └──────────────────────────────────┘
    │                        │
    └─ Connecté ──────────── ▼
                        Charger profil + rôle
                             │
                             ▼
                        Router selon rôle
```

### Bootstrap Admin

Le rôle n'est **pas** décidé par le client. Il l'était : l'application comptait la collection
`users` et s'attribuait `admin` si elle la trouvait vide. Comme les règles ne contraignaient aucun
champ à la création, l'astuce n'était même pas nécessaire — écrire soi-même `role: "admin"` dans son
propre document, hors application, suffisait, et `syncUserClaims` frappait le claim correspondant.

Ce qui se passe désormais, dans l'ordre :

```
Client                          Règles Firestore              Serveur
  │                                   │                          │
  ├─ set users/{uid}                  │                          │
  │    role: 'pending'  ─────────────►│ create autorisé SSI      │
  │    is_revoked: false              │  role == 'pending'       │
  │    email: <celui du jeton>        │  && is_revoked == false  │
  │                                   │  && email == token.email │
  │                                   │                          │
  │                                   │        onDocumentWritten │
  │                                   │◄─────── enforceFounderRole
  │                                   │           │ getAuth().getUser(uid).email
  │                                   │           │ == fondateur ?
  │                                   │           └─► role: 'admin'
  │                                   │                          │
  │                                   │◄─────────── syncUserClaims
  │                                   │      claims {role, revoked}
  ▼                                   ▼                          ▼
/pending tant que role == 'pending'  isApproved() = false   pas d'appel d'IA
```

Toute autre promotion est une **nomination** : un administrateur écrit `role` sur le document d'un
autre. Les règles réservent ce champ aux administrateurs, et le document du fondateur à lui seul.

**L'adresse d'un compte est immuable (v0.23.10).** Les règles reconnaissent le document du
fondateur à son champ `email` (`targetIsFounder`). Ce champ n'était figé que pour le titulaire :
un administrateur pouvait remplacer l'adresse du fondateur, puis changer son rôle ou supprimer
son document. `touchesEmail()` refuse désormais toute mise à jour qui modifie, ajoute ou retire
`email`, pour tous les comptes et administrateur compris. L'adresse posée à la création, égale à
celle du jeton, fait donc foi jusqu'à la suppression du document, que les règles refusent pour
le fondateur. Aucun parcours client n'écrit `email` après la création : `_upsertUser`
(`auth_repository.dart`) ne met à jour que `last_seen_at`, `photo_url` et `display_name`. Le
serveur (Admin SDK) reste libre. Côté serveur, le multiplicateur du fondateur ne lit pas ce
champ : `founderUid()` le résout depuis Auth.

---

## 6. Intégration des moteurs d'IA

### Principe

Aucun appel ne part du client. Tout passe par `callModel` (`functions/src/ai/router.ts`),
qui est le point de passage unique : il lit la politique de routage, vérifie le plafond du
compte, choisit le moteur, appelle, et écrit le coût **au tarif du modèle qui a réellement
répondu**. Seules exceptions : la **production** d'image, câblée sur Gemini faute
d'équivalent chez Claude, et la **modération**, qui lit la même politique sans emprunter
`callModel` — c'est le seul poste facturé à l'unité plutôt qu'au jeton.

```
ctx.feature ──▶ callModel ──┬─▶ reserveDailyBudget             (le compte peut-il ? place réservée)
                            ├─▶ app_config/ai_routing_policy   (quel moteur ?)
                            ├─▶ Gemini | Claude
                            ├─▶ recordUsage                    (appel, moteur, modèle, coût réel)
                            └─▶ releaseDailyBudget             (réservation retirée, succès ou échec)
```

**Réservation avant l'appel (v0.23.10).** Le plafond lisait la dépense avant l'appel et
l'enregistrait après : vingt appels lancés au même instant lisaient le même compteur et
passaient tous. Chaque appel réserve désormais sa place par une transaction sur
`ai_daily_spend/{uid}_{jour}` (`reserveDailyBudget`, `ai/budget.ts`), champ `reservations` :

- un appel en cours compte pour **un appel** : le plafond d'appels est exact sous rafale ;
- il compte pour une **dépense estimée** : le coût moyen d'un appel chiffré de ce compte dans
  la journée (`estimatedCallCostUsd`). Aucun prix n'est écrit dans le code. Sans appel chiffré
  dans la journée, ou sans grille tarifaire, l'estimation vaut zéro : le plafond d'appels et la
  limite de concurrence tiennent seuls ;
- **appel déclenché par un utilisateur** (callable) : il occupe l'une des
  `MAX_CONCURRENT_AI_CALLS_PER_USER` = 10 places du compte (×100 pour le fondateur et
  `system_unattributed`). Places toutes prises : attente jusqu'à 20 s, puis
  `BudgetExceededError` de motif `concurrency`, rendu en `resource-exhausted` ;
- **appel du serveur** (pipeline Cloud Tasks, déclencheur Firestore, tâche planifiée) : il
  réserve sa place et compte dans les deux plafonds, mais n'attend jamais et n'est jamais
  refusé pour `concurrency`. Un import de livre lance cinq tranches à la fois, plus la
  nutrition de chaque recette écrite, toutes imputées au même compte : les limiter ferait
  échouer un import légitime. Ses réservations occupent toutefois les places du compte : un
  appel lancé à la main pendant un import peut attendre.

L'origine se lit dans `ai/callOrigin.ts`. `baseContext` (`callable/_auth.ts`), première
instruction synchrone de chaque garde (`requireAuth`, `requireEditor`, `requireAdmin`), pose un
marqueur dans un `AsyncLocalStorage` (`markInteractiveCall`). Le marqueur suit la requête
jusqu'à l'appel de modèle, y compris à travers les fonctions qui reconstruisent leur contexte
d'appel, et n'existe pas dans un déclencheur ni dans une tâche Cloud Tasks. Un champ du contexte
d'appel aurait été perdu par ces reconstructions. Une callable qui n'emploie aucune garde
n'est pas limitée en simultanéité.

La décision de plafond se prend sur `dépensé + en cours`. `recordUsage` ajoute ensuite le coût
réel, et la réservation est retirée en `finally`, réussite ou échec (`releaseDailyBudget`). Une
réservation qu'aucune fin n'a retirée (instance arrêtée) cesse de compter après
`RESERVATION_TTL_MS` = 15 min, et la transaction suivante la supprime. Les plafonds coupés
(`enabled: false`) ne réservent rien. Le dépassement possible se borne à l'écart entre le coût
réel et l'estimation, sur au plus dix appels simultanés d'utilisateur, plus les appels du
serveur en cours.

Mêmes réservations pour les trois chemins qui n'empruntent pas `callModel` : la production
d'image (`runImageModel`), l'amélioration d'illustration (`enhanceCulinaryImage`, jusque-là
hors plafond) et le bac à sable (`askModel` sur un modèle choisi). `assertWithinDailyBudget`
reste la vérification en lecture seule du rattrapage nutrition nocturne, avant d'engager une
recette. La limite de concurrence est une constante du code, comme le multiplicateur du
fondateur : elle ne se règle pas depuis Admin.

**Aucun appel hors plafond.** Un uid vide laissait auparavant l'appel passer sans contrôle.
Trois comptes portent désormais ce qui n'est pas imputé à une personne :

| Compte | Qui y tombe | Plafond |
|---|---|---|
| `system_unattributed` | un appel de modèle passé **sans aucun uid** (`reserveDailyBudget` → `budgetUserId`) ; `recordUsage` y ajoute la dépense du jour | ×100, comme le fondateur |
| `system_recipe_without_owner` | une recette au `created_by` vide : déclencheurs nutrition, rôle de repas, produits de courses, **et le rattrapage nutrition nocturne**, qui impute chaque recette à son `created_by` (`recipeBudgetUserId`) | ×1, partagé par toutes les recettes orphelines |
| `system` (littéral) | l'enrichissement des référentiels sans uid transmis (`nutrition/aiEnrichment.ts`, `nutrition/fryAbsorption.ts` remplacent l'uid absent par `"system"`) | ×1 — un compte ordinaire pour le plafond |

Ces comptes apparaissent sous ces clés dans `ai_usage`, `ai_daily_spend` et l'écran des
plafonds.

Un poste routé vers Claude mais servi par Gemini faute de clé montée émet un `WARNING` :
c'est le silence de ce cas qui avait rendu une panne indéchiffrable. **Toute fonction qui
appelle `callModel` doit déclarer les deux secrets** — un secret non déclaré n'est pas monté
dans `process.env`, et le repli est alors silencieux.

### La lecture d'une page, en deux passes

Le détail vit au chapitre 8 de `FunctionalRequirements.md` et dans les séquences 01 et 22.
Ce qui compte ici, c'est ce que chaque passe demande au moteur :

| Passe | Fichier | Poste | Entrée | Sortie |
|---|---|---|---|---|
| 1 — transcription | `gemini/transcription.ts` | `transcription_page` (scan) ou `text_extraction` (texte collé) | l'image, ou le texte | **du JSON** — type de page, inventaire déclaré, sections d'ingrédients, sections d'étapes, notes, chapeau |
| 2 — balisage | `gemini/tagging.ts` | `recipe_tagging` | la transcription, **jamais l'image** | **du CookLang**, plus la liste normalisée, les cuisines et les types de plat |

Un seul appel faisait autrefois les deux, et rendait du CookLang directement. Il perdait la
transcription au profit de la mise en forme : ingrédients fusionnés, précisions déplacées,
énumérations abrégées. La classification n'est plus un appel séparé — c'est un champ de la
réponse de la passe 1, ce qui garantit que le verdict porte sur ce qui a été lu. `NO_RECIPE`
a disparu au profit de `page_type: "no_recipe"`.

**Une page écrite en prose n'a pas de liste d'ingrédients.** La passe 2 normalise les lignes
que la passe 1 a recopiées : sans liste sur la page, elle n'a rien à normaliser et rend
`ingredients: []`, pendant que son CookLang nomme pourtant tous les aliments. La recette
s'enregistrait alors sans ingrédients — donc sans liste de courses, sans planification
(`onSchedule` exige une liste non vide) et sans nutrition. Deux dispositions couvrent le cas :
la passe 2 reçoit la mention « aucune : la recette est écrite en prose » et une règle qui lui
fait construire la liste depuis les étapes, sans inventer de quantité ; et `saveDraft` dérive
la liste du CookLang par `pipeline/ingredientsFromCooklang.ts` quand elle arrive vide malgré
tout. La dérivation a lieu **avant** la normalisation référentiel, et ne rend ni la note ni le
`source` — il n'y a pas de ligne de livre à citer.

`gemini/extractor.ts` ne porte plus que l'entrée « texte collé ». Les trois anciens appels
qui vivaient là — classification, extraction depuis une image, extraction d'un document — ont
été remplacés par la passe 1. Leurs trois postes de coût **restent au catalogue comptable**,
sans quoi les mois déjà comptabilisés cesseraient de les nommer, mais ils ont quitté
`ROUTABLE_FEATURES` : un sélecteur de moteur qui ne commande aucun appel fait croire à un
réglage.

Deux réglages tiennent à ce que ces passes demandent :

- **`effort: "high"`** sur `transcription_page` et `text_extraction`. Le défaut `low` venait de
  la chaîne nutrition, où estimer des calories est un rappel de connaissances. Appliqué à une
  page de livre, il donnait un modèle pressé : « en poudre » recollé au mauvais ingrédient, une
  énumération de grains de poivre et de graines de coriandre résumée en « les épices ».
- **`effort: "low"`** sur `recipe_tagging` (`TAGGING_EFFORT` dans `gemini/tagging.ts`). Mesuré sur
  33 recettes rejouées à `high` et à `low` (26 septembre 2026) : même contrôle `checkFidelity`,
  aucune rupture de plus. Dans les ÉTAPES, `low` remplit environ 27 % de quantités en moins (21
  recettes sur 27) — sans conséquence quand la LISTE d'ingrédients porte déjà le nombre, ce qui est
  le cas ordinaire. Le risque accepté est l'inverse : un ingrédient dont l'ÉTAPE est la seule
  source du nombre, la liste ne le portant pas (une pincée de sel, par exemple) — rejoué deux fois
  sur la même recette, `low` l'a perdu les deux fois. `TAGGING_RETRY_EFFORT` valant déjà `low`,
  `taggingEfforts()` ne tente plus qu'un seul effort : il n'y a rien de plus bas où retomber si la
  réponse est coupée, mais le risque de coupure recule avec l'effort (0 appel coupé sur 33 mesurés
  à `low`, contre 40 sur 75 à `high`). Coupé malgré tout (`stop_reason: max_tokens`,
  `MAX_TOKENS` chez Gemini), il lève `TaggingTruncatedError` : `recipeProcessor` envoie le job en
  dead letter (`failure_reason: tagging_truncated`) sans nouvelle tentative Cloud Tasks, qui rejouerait la
  mêmes appels.
- **`maxTokens: 24 000`** sur la transcription, qui ne résume rien. C'est ce plafond qui
  impose le streaming côté Claude (chapitre 1).

### Où vivent les prompts

| Fichier | Ce qu'il porte |
|---|---|
| `gemini/promptsExtraction.ts` | `TRANSCRIPTION_PROMPT`, `TEXT_TRANSCRIPTION_PREAMBLE`, `TAGGING_PROMPT` |
| `gemini/prompts.ts` | `GEMINI_BOOK_COVER_PROMPT`, `GEMINI_POLISH_PROMPT`, `COOKLANG_RULES` |
| `illustrations/prompts.ts` | les cinq questions de la chaîne d'illustrations |

**Ils ne sont pas recopiés ici** : un prompt dupliqué dans la documentation diverge en une
semaine. Ce qui est stable, et mérite d'être écrit, ce sont les invariants qu'ils imposent :

- **Copie fidèle** : recopier, ne pas reformuler, ne pas résumer, n'inventer ni ingrédient ni
  quantité, ne pas « réparer » un mot mal lu en expression plus courante.
- **Une orthographe par aliment** dans toute la recette — sans quoi le même ingrédient compte
  deux fois dans l'index de recherche, la nutrition et la liste de courses.
- **Ustensile ou ingrédient**, jamais les deux : `#moule à tarte{}` contre `@moule{}`.
- **Accolades jamais vides quand la quantité est connue** ; vides quand la quantité n'est
  qu'un contexte (« pour la cuisson », « à volonté »).
- **Aucun exemple rempli** dans un prompt qui n'en a pas besoin : le modèle recopiait la
  réponse d'exemple, sa valeur de confiance comprise.
- **Exiger une preuve vérifiable** plutôt qu'une justification — les trois mots réellement lus
  se contrôlent d'un coup d'œil, une justification non.

### Les réponses JSON

Les autres postes — nutrition, planning, tags, dressage — demandent du JSON. Un seul module
décide comment le lire : `ai/askJson.ts`. Il cherche le premier `{` et le dernier `}` après
avoir retiré un éventuel bloc de code Markdown, parce que les modèles enrobent volontiers
leur réponse. Auparavant, cinq expressions régulières légèrement différentes coexistaient
dans un même fichier ; l'écart ne se voyait que le jour où le modèle ajoutait une phrase.

Une réponse illisible lève une `JsonAnswerError`, distincte d'un échec réseau : la première
ne se réessaie pas, la seconde oui.

### Gestion des erreurs

Le tableau complet — ce qui se rejoue, ce qui ne se rejoue pas, et ce qui est comptabilisé
malgré l'échec — vit au chapitre 7, section 7.11. Il y est écrit une seule fois : dupliqué
ici, il divergeait à la première correction.

Les entrées envoyées par le client sont bornées avant tout appel de modèle : bornes,
refus et relevé des tailles en section 7.8 bis.

Un point appartient en propre à l'intégration des moteurs :

- un poste routé vers un moteur dont la clé manque est **servi par Gemini**, et le repli
  émet un `WARNING` nommant le poste et le moteur attendu. Servir Gemini entre le
  déploiement du code et la création du secret est le comportement voulu ; le silence, lui,
  a masqué des mois durant une fonction qui avait oublié de déclarer le secret.

---

## 7. Observabilité — journaliser, échouer, reprendre

Ce chapitre décrit **entièrement** ce qui se passe quand quelque chose se passe mal, et ce
qui reste écrit quand tout s'est bien passé. Il est écrit pour être réimplémenté tel quel :
noms de champs, seuils, sévérités, codes d'erreur, nombres de tentatives.

Une règle domine, et elle est la plus stricte du projet : **aucun `catch` silencieux**. Un
échec avalé ne produit ni écran d'erreur, ni ligne de journal, ni rapport — il produit un
résultat faux que personne ne sait relire six mois plus tard.

### 7.1 Trois journaux, trois publics

Ils ne se remplacent pas. Chacun répond à une question que les deux autres ne savent pas
poser.

| Journal | Qui écrit | Où | La question à laquelle il répond | Écran |
|---|---|---|---|---|
| Cloud Logging | les Cloud Functions | journal `kass-dalle-pipeline`, ressource `cloud_function` | *que s'est-il passé côté serveur, dans quel ordre ?* | Admin › Journaux |
| `error_reports/{id}` | le client Flutter | Firestore | *qu'est-ce qui a cassé chez l'utilisateur, dans quelle version ?* | Admin › Rapports d'erreur |
| `dead_letters/{jobId}` | le pipeline d'import | Firestore | *quels imports ont été abandonnés, et peut-on les rejouer ?* | Admin › File d'échecs |

Le client n'écrit **jamais** dans Cloud Logging : il n'en a pas le droit et n'en aurait pas
le moyen. Le serveur n'écrit **jamais** dans `error_reports` : la collection est le seul
endroit où une panne côté appareil laisse une trace, et la mélanger avec les erreurs serveur
ferait perdre cette propriété.

### 7.2 Le journal serveur — schéma d'une entrée

Source unique : `functions/src/logging.ts`. Aucun `console.log` n'est employé sur un chemin
normal ; `console.error` ne sert que de dernier recours, quand Cloud Logging lui-même
échoue.

Une entrée est un objet `StructuredLogEntry` :

| Champ | Type | Rôle |
|---|---|---|
| `severity` | `INFO` \| `WARNING` \| `DEBUG` \| `ERROR` | obligatoire |
| `message` | `string` | phrase en français, lisible telle quelle |
| `errorDescription` | `string?` | le message de l'exception, séparé du nôtre |
| `correlationId` | `string?` | le fil du traitement — voir 7.3 |
| `moduleType` | `IMPORT` \| `IMAGE_DECODE` \| `SEARCH` \| `DESIGN` \| `MODERATION` | grande famille |
| `firestoreDocId` | `string?` | le document concerné |
| `executionTimeMs` | `number?` | durée mesurée, pas estimée |
| `geminiStatus` | `SUCCESS` \| `QUOTA_EXCEEDED` \| `ERROR` | issue d'un appel de modèle |
| `jobId` | `string?` | job d'import |
| `userId` | `string?` | compte à l'origine |
| `stepIndex` | `number?` | rang de l'étape dans le pipeline |
| `provider` | `string?` | `gemini` ou `anthropic` |
| `model` | `string?` | identifiant exact du modèle appelé |
| `feature` | `string?` | poste de coût — **la même clé que le reporting** |
| `scanId` | `string?` | le scan de l'utilisateur — voir 7.3 bis |
| `callId` | `string?` | l'appel de modèle auquel la ligne appartient — voir 7.3 bis |
| `extra` | `Record<string, unknown>?` | tout le reste, non indexé |

**`provider`, `model` et `feature` sont des champs de premier plan, pas des clés perdues
dans `extra`.** Depuis qu'il y a deux moteurs, « lequel a servi cet appel » est la première
question posée à un journal, et elle doit être filtrable. Même raison pour `feature` : c'est
la clé qui relie une ligne de journal à une ligne de facture.

**Ce qui devient un label indexé** — donc requêtable — est limité aux champs courts :
`correlationId`, `moduleType`, `geminiStatus`, `jobId`, `userId`, `provider`, `model`,
`feature`, `scanId`, `callId`. Tout le reste part dans `jsonPayload`, avec un
`timestamp` ISO ajouté à l'écriture.

**Les quatre sévérités ne sont pas interchangeables.**

| Sévérité | Ce qu'elle signifie | Exemple |
|---|---|---|
| `DEBUG` | instrumentation, pas événement métier — filtré par défaut à l'écran | prompt envoyé, réponse brute, ouverture d'un appel |
| `INFO` | un événement métier a eu lieu | page transcrite, recette écrite, job mis en file |
| `WARNING` | le traitement aboutit, mais pas comme prévu | poste routé vers Claude servi par Gemini faute de clé |
| `ERROR` | le traitement n'aboutit pas | pipeline en échec, JSON illisible |

Le niveau `WARNING` existe parce qu'il manquait : entre l'INFO qu'on ne lit pas et l'ERROR
qui n'a pas eu lieu, une bascule de moteur restée sans effet ne casse rien et ne doit pas
passer inaperçue. L'écran le filtre par une puce « WARN+ ».

**Le SDK Cloud Logging est chargé au premier usage**, par `await import()`, et son client
est mémorisé. C'est la règle générale du bundle (voir 1) : il tire gRPC et protobuf, et un
import statique coûtait deux cents millisecondes de démarrage aux cinquante fonctions, y
compris à celles qui ne journalisent rien.

**Si l'écriture échoue**, `writeLog` rattrape et écrit sur `console.error` avec le payload
complet. Une panne du journal ne fait jamais échouer le traitement qu'il observait.

### 7.3 Le fil qui relie tout : `correlationId`

Un import fait une trentaine d'appels dans cinq fonctions différentes. Sans fil, les
journaux sont une liste plate où rien ne se rattache à rien.

**Forme** : `{racine}_{millisecondes}_{aléa}`, produit par `newCorrelationId(prefix)`. Le
préfixe **nomme le traitement**, et c'est lui que l'écran affiche en titre de groupe.

Trois conséquences de conception, toutes tirées de pannes réelles :

1. **Chaque fonction nomme son traitement.** Toutes les callables partageaient le préfixe
   par défaut `call`, si bien que l'écran alignait des dizaines de groupes tous intitulés
   « call » — un regroupement correct, et illisible. Le nom se passe en second argument des
   gardes : `requireAuth(req, "generation_recette")`.
2. **Deux départs du même traitement se distinguent par un suffixe.** `qualify(feature,
   detail)` produit `ecriture_recette:ingredients-modifies` — le deux-points est la
   frontière que l'écran connaît : avant, l'étape ; après, laquelle. Le détail est
   translittéré (sans accents, minuscules, tirets, 32 caractères) ; sans détail utilisable,
   on rend le nom seul plutôt qu'un suffixe vide.
3. **Le fil traverse les frontières de fonction.** Le `jobDispatcher` écrit son
   `correlationId` sur le job **avant** de mettre en file, et le `recipeProcessor` le
   reprend. Un seul fil couvre donc la mise en file et tout le traitement. `disp` et `proc`
   nommaient chacun un morceau du couloir, jamais le voyage.

**Le `correlationId` est stocké sur le document produit** (`correlation_id`) : depuis
l'écran d'une recette, on remonte à son import.

**La traduction en français vit côté client**, dans `kLogTreatmentLabels`
(`features/admin/domain/log_treatment_label.dart`). Un identifiant reste stable et
filtrable ; un libellé change. Une racine inconnue n'est pas une erreur : on affiche la
racine telle quelle, parce qu'un nom technique reste cherchable là où « Traitement inconnu »
ne l'est plus.

### 7.3 bis Le fil au-dessus du fil : `scanId` et `callId`

Le `correlationId` relie les lignes d'**un traitement**. Il n'en relie pas quatre.

Photographier une page de livre en déroule quatre, chacun tirant son propre identifiant :

| Ordre | Traitement | Où | Ce qu'il contient |
|---|---|---|---|
| 1 | `upload_security_scan` | `scanAndPromoteUploadFn` | le contrôle du fichier envoyé, facturé à l'unité |
| 2 | `import_recette` | `jobDispatcher` → `recipeProcessor` | `transcription_page`, `recipe_tagging`, la normalisation contre les référentiels |
| 3 | `import_recette…_p1`, `_p2` | `illustrations/` | une détection d'illustrations par page |
| 4 | `ecriture_recette:creation` | `onRecipeWritten` | la liste de courses et toute la nutrition |

L'écran en faisait quatre groupes sans lien, et le coût d'un scan se lisait sur quatre
lignes qu'il fallait retrouver une à une.

**`scanId` chapeaute le `correlationId`, il ne le remplace pas.** Forme :
`scan_{millisecondes}_{aléa}`.

**Le client le pose**, et lui seul peut le faire : le contrôle du fichier a lieu avant que
le job existe, et les pages supplémentaires arrivent par des appels séparés.
`ScanUploadNotifier` le tire une fois par import, le passe à chaque
`scanAndPromoteUpload` et l'écrit sur le job. Le `jobDispatcher` le relit, le réécrit
sur le job — pour qu'une relance retrouve le même scan — et le transmet dans le payload de
la tâche. Le `recipeProcessor` le porte dans son `ctx`, d'où il descend dans chaque
`ModelCallContext`. `saveDraft` l'écrit sur la recette (`scan_id`), et
`onRecipeWritten` l'y relit : c'est ce dernier maillon qui ramène la nutrition et les
courses dans le total du scan.

Un job créé avant l'existence du champ n'en a pas : `newScanId()` en fabrique un côté
serveur, qui couvre au moins l'import et ses suites.

**`callId` nomme un appel de modèle.** Forme : `call_{base36}_{aléa}`, tiré par
`callModel` **à chaque tentative** — un repli sur l'autre moteur produit deux appels
réellement facturés, deux lignes de consommation et deux séries de lignes de journal ; leur
donner le même identifiant afficherait un seul appel au coût doublé sans raison lisible.

Il est écrit sur les lignes de journal de l'appel **et** sur sa ligne `ai_usage`
(`call_id`). C'est ce qui met un montant exact en face d'un appel dans l'écran, sans avoir
à rapprocher une ligne de consommation d'une ligne de journal par son poste et son heure —
rapprochement qui se trompe dès que le même poste part quarante fois de suite.

Un appel écrit deux à quatre lignes — le prompt en `DEBUG`, la fin de l'appel, le texte
rendu. Elles étaient posées au même rang que celles du pipeline.

### 7.4 Journaliser l'échange avec un modèle

Les journaux disaient qu'un appel avait eu lieu, avec son poste, son moteur et ses jetons —
jamais ce qu'il avait répondu. Quand une recette extraite s'écarte du livre, ces lignes-là
ne servent à rien : elles prouvent que l'appel a réussi, pas ce qu'il a produit, et ne
disent pas quelle étape a interprété.

`logAiText(...)` trace donc **le texte** à chaque sortie :

| Argument | Rôle |
|---|---|
| `stage` | le moment — `classification`, `extraction`, `polish.avant`, `polish.après`… |
| `text` | le texte rendu, ou celui qu'on s'apprête à écrire |
| `correlationId`, `scanId`, `callId`, `jobId`, `userId`, `feature`, `provider`, `model`, `moduleType` | le contexte habituel |

`callId` vient de `ModelCallResult.callId`, rendu par `callModel` : le texte est
journalisé **après** l'appel, par celui qui l'a demandé, et sans cet identifiant sa ligne se
retrouvait au même rang que les étapes du pipeline, sans lien avec l'appel qui l'avait
produite.

L'entrée part en `INFO`, avec un message de la forme « Texte IA — extraction (3 214
caractères) », et dans `extra` : `stage`, `textLength`, `truncated`, `text`.

**Plafond : `AI_TEXT_LOG_LIMIT = 12 000` caractères.** Une page de livre extraite pèse deux
à quatre mille caractères ; douze mille couvrent une page entière et ses variantes sans
approcher la limite d'une entrée Cloud Logging. Ce qui dépasse est coupé, suffixé d'une
marque de coupure, et `truncated: true` le dit — un texte tronqué qui ne s'annonce pas se
lit comme un texte perdu.

Les entrées d'un même scan partageant le `correlationId`, elles se lisent dans l'ordre et
l'on voit le texte évoluer d'un traitement au suivant — **ou ne pas évoluer**, ce qui est
l'information qu'on cherche quand une étape n'a rien fait.

**Le prompt lui-même part en `DEBUG`**, pas en `INFO` : il est identique d'un appel à
l'autre et noierait la lecture. Un import écrivait une cinquantaine de lignes dont une
quinzaine seulement portait une information.

**Ce qui n'est jamais journalisé** : les clés de fournisseur, le jeton d'authentification,
le contenu binaire d'une image. Les clés vivent dans Secret Manager et ne transitent par
aucun champ de journal.

### 7.5 Relire les journaux depuis l'application

`queryLogsFn` (`callable/logsCallable.ts`), **réservée aux administrateurs**, interroge
Cloud Logging et rend une liste de `{ timestamp, severity, labels, payload }`.

Filtres acceptés, traduits en syntaxe de requête Cloud Logging :

| Entrée | Filtre produit |
|---|---|
| `severity` | `severity>=WARNING` — sauf `DEBUG`, traduit en `severity=DEBUG`, sans quoi il ramènerait tout |
| `correlationId` | `labels.correlationId="…"` |
| `scanId` | `labels.scanId="…"` — rend les quatre traitements d'un scan, et eux seuls |
| `jobId` | `labels.jobId="…"` |
| `userId` | `labels.userId="…"` |
| `freeText` | `jsonPayload.message:"…"` |

La pagination se fait par `nextPageToken`.

**La réponse porte aussi les montants.** `queryLogsFn` relit `ai_usage` pour les
`scan_id` et les `correlation_id` présents dans la page, et rend un tableau `calls`
— un objet par appel facturé : `callId`, `correlationId`, `scanId`, `feature`,
`provider`, `model`, `status`, jetons, `costUsd`, `timestamp` — plus le
`usdToEur` du jour.

Le montant n'est **pas** recalculé depuis les jetons journalisés : il est lu où il vit
déjà. Le chiffrer une seconde fois, autrement, produirait deux montants pour un même
appel — deux écrans, deux chiffres, et aucun moyen de dire lequel est juste.

Trois conséquences :

- `costUsd` vaut `null` quand la grille tarifaire était en panne au moment de l'appel.
  L'écran écrit « sans montant » et n'additionne rien : un total à zéro se lit comme une
  dépense nulle.
- Sans taux du jour, les montants restent en **dollars**. Une constante du code produirait
  des euros périmés présentés comme exacts.
- Une lecture de coûts en échec ne fait pas échouer l'écran : les journaux s'affichent sans
  montant, et l'incident part dans `logError`.

**L'écran (`admin/presentation/logs_screen.dart`) rend trois niveaux**, le regroupement
vivant dans `admin/domain/log_scan_group.dart` — donc testable
(`test/log_scan_group_test.dart`) :

| Niveau | Ce qu'il montre | Son montant |
|---|---|---|
| 1 — le scan | les quatre traitements d'un scan sous un seul titre, ou le traitement seul quand aucun scan ne le chapeaute | somme de ses appels, suivie du nombre d'appels et de ceux qui n'ont pas de montant |
| 2 — l'appel | un appel de modèle, nommé par son poste traduit (`featureLabel`, le catalogue comptable) ; les lignes qui ne relèvent d'aucun appel restent à ce niveau, mêlées aux appels dans l'ordre du temps | son coût exact |
| 3 — la ligne | prompt, fin d'appel, texte rendu — les labels et le `jsonPayload` complet | — |

Le rattachement se fait sur `scanId`, et retombe sur `correlationId` pour les journaux
écrits avant que le champ existe. Une carte `correlationId → scanId`, apprise des lignes
qui portent les deux, rattrape au passage les appels dont seule la corrélation est connue.

Deux choix qui évitent un total faux :

- **Un appel dont aucune ligne n'est visible ouvre quand même son groupe.** Son coût est
  réel ; l'écarter parce que le niveau `DEBUG` est masqué amputerait le total sans que
  rien ne le dise.
- **« Charger la suite » fusionne les appels sur leur `callId`.** Deux pages voisines
  partagent souvent un traitement : sans cette fusion, le coût du scan doublait à chaque
  page chargée.

`DEBUG` reste filtré par défaut.

### 7.6 Aucun `catch` silencieux — les deux applications de la règle

**Côté TypeScript.** Tout `catch` appelle `logError(...)` depuis `../logging`, **y compris
pour une erreur best-effort**, avant de retourner un résultat dégradé. À défaut de contexte,
`console.error`. Un `catch {}` vide ou un `catch (err)` dont `err` n'est pas utilisé **fait
échouer la CI** : ESLint applique `no-empty` avec `allowEmptyCatch: false` et
`caughtErrors: "all"`. Rendre la CI verte en désactivant la règle est interdit.

**Côté Dart.** Deux voies, selon la couche :

- **Repositories et services** : un `ErrorReportService` injecté par constructeur
  (`ErrorReportService()` par défaut), appelé par
  `reportError(feature:, error:, stackTrace:, context:)`. L'injection existe pour les tests,
  pas pour la production.
- **Couche présentation, callbacks de widgets, traitements dégradés** :
  `reportUnexpectedError(feature:, error:, stackTrace:, context:)`
  (`core/services/error_reporting.dart`). L'appel est **volontairement synchrone et non
  attendu** : l'interface ne doit jamais se figer parce qu'un rapport met du temps à partir.

`ErrorReportService.protect<T>(feature:, action:)` enveloppe une opération : il rapporte
puis **relance**. Il ne convertit jamais un échec en succès silencieux.

`debugPrint` seul ne suffit jamais : il est invisible en production. Il ne subsiste qu'en
dernier recours, quand la remontée elle-même échoue — hors ligne, règles Firestore, quota.
On perd alors l'erreur en production, mais on ne masque ni l'erreur d'origine ni celle de la
remontée.

### 7.7 Le rapport d'erreur client — `error_reports`

| Champ | Type | Note |
|---|---|---|
| `user_id` | `string` | `anonymous` si aucun compte connecté |
| `job_id` | `string?` | quand l'erreur se rattache à un import |
| `timestamp` | `Timestamp` | horloge de l'appareil |
| `app_version` | `string` | `kAppVersion`, synchronisé depuis `pubspec.yaml` |
| `feature` | `string` | l'étape — `admin.saveAiPricing`, `auth_lightweight_sign_in` |
| `error_type` | `string` | le type Dart de l'exception (`TimeoutException`, `FirebaseException`) |
| `error_message` | `string` | `error.toString()` |
| `stack_trace` | `string?` | **tronquée à 2 000 caractères** |
| `context` | `map` | libre — les paramètres au moment de l'erreur |

`app_version` est obligatoire pour une raison simple : un rapport sans version ne se
diagnostique pas, l'application se déployant plusieurs fois par jour.

`save(...)` **retourne l'identifiant du document**. C'est ce numéro que l'écran peut montrer
à l'utilisateur et qu'il communique à l'administrateur.

Le champ `feature` est un identifiant libre, mais sa forme est une convention :
`domaine.action` pour le code récent, `domaine_action` pour l'ancien. Il n'est pas contrôlé
à l'écriture — s'en servir comme clé de regroupement suppose donc de le lire, pas de le
supposer.

### 7.8 Les codes d'erreur d'une callable

Toutes les Cloud Functions HTTPS lèvent une `HttpsError`. Le code n'est pas décoratif : le
client s'en sert pour décider s'il propose de réessayer.

| Code | Quand | Ce que fait le client |
|---|---|---|
| `unauthenticated` | aucun jeton | renvoi au login |
| `permission-denied` | compte `pending`, révoqué, ou rôle insuffisant | message, pas de réessai |
| `invalid-argument` | requête mal formée — le cas le plus fréquent | message, pas de réessai |
| `failed-precondition` | l'état ne permet pas l'opération (document absent, politique manquante) | message, pas de réessai |
| `not-found` | la cible n'existe pas ou plus | message |
| `resource-exhausted` | plafond de dépense atteint | message nommant le plafond, pas de réessai |
| `internal` | tout le reste | réessai possible |

**Trois gardes**, dans `callable/_auth.ts`, toutes précédées de la vérification App Check :

| Garde | Exige | Source du rôle |
|---|---|---|
| `requireAuth(req, feature)` | compte nommé et non révoqué | le **document**, relu à chaque appel (`mergeAccount`) ; le rôle du jeton en repli seulement ; document absent : refusé |
| `requireEditor(req, feature)` | `editor` ou `admin` | lecture Firestore |
| `requireAdmin(req, feature)` | `admin` | lecture Firestore |

Depuis la v0.23.12, `requireAuth` lit le document `users/{uid}` à chaque appel, et ce document
fait foi (`mergeAccount`) : le rôle est celui du document, celui du jeton ne sert que si le
document n'en porte pas ; le compte est révoqué si le jeton **ou** le document le dit ; un
document absent ou un rôle `pending` est refusé. Avant, le rôle du jeton tranchait seul : un
compte révoqué, remis en attente ou supprimé gardait l'accès aux callables d'IA jusqu'à
l'expiration de son jeton, une heure au plus. Une lecture Firestore par appel coûte moins
qu'un appel d'IA laissé passer. `requireAdmin` et `requireEditor` lisent **toujours** le
document.

Chaque garde retourne un `AuthContext` porteur du `userId` et d'un `correlationId` frais
dont la racine est le `feature` passé en argument.

### 7.8 bis Bornes des entrées envoyées aux modèles

Depuis la v0.23.11, chaque callable qui envoie une entrée du client à un modèle la lit par
`readAiInputs` (`callable/_inputBounds.ts`), juste après la garde d'accès et **avant** tout
appel de modèle et toute réservation de budget. Les entrées produites par le serveur
(pipeline d'import, déclencheurs) et le bac à sable (`sandboxFn`, réservé à `admin`) ne
passent pas par là.

Les bornes sont **larges** : aucun texte réel ne les atteint, seuls les envois de plusieurs
centaines de milliers de jetons sont refusés. Au-delà, la callable lève
`invalid-argument` avec un message qui nomme le champ et la limite, par exemple
« Texte trop long : « text » dépasse la limite de 200 000 caractères (250 123 reçus). ».
Rien n'est tronqué : un texte coupé ferait travailler le modèle sur une recette amputée. Seul
`suggestMealIdeasFn` garde ses règles antérieures (consigne refusée au-delà de
600 caractères, titres et préférences tronqués à dessein).

| Borne (constante) | Valeur | Unité |
|---|---|---|
| `PASTED_TEXT_MAX_CHARS` | 200 000 | caractères |
| `RECIPE_TEXT_MAX_CHARS` | 100 000 | caractères |
| `SHORT_TEXT_MAX_CHARS` | 5 000 | caractères |
| `LIST_MAX_ITEMS` | 500 | éléments |
| `CORPUS_MAX_ITEMS` | 5 000 | éléments (bibliothèque de recettes entière) |
| `STRUCTURED_ITEM_MAX_CHARS` | 20 000 | caractères JSON d'un élément de liste ou d'un petit objet |
| `STRUCTURED_OBJECT_MAX_CHARS` | 100 000 | caractères JSON d'un objet |
| `COVER_IMAGE_MAX_BYTES` | 8 Mo | octets décodés |
| `PAGE_IMAGE_MAX_BYTES` | 20 Mo | octets décodés |

| Callable | Relevé (`feature`) | Champ → borne |
|---|---|---|
| `extractRecipeFromTextFn` | `text_extraction` | `text` → 200 000 car., requis |
| `polishCooklangFn` | `polish_cooklang` | `cooklang` → 100 000 car., requis |
| `polishMarkdownFn` | `polish_markdown` | `markdown` → 100 000 car., requis ; `instruction` → 5 000 car. |
| `refineRecipeFn` | `refine` | `instruction` → 5 000 car., requis ; `currentCooklang` → 100 000 car., requis ; `currentTitre` → 5 000 car. ; `currentIngredients` → 500 éléments de 20 000 car. ; `currentTags` → 100 000 car. JSON ; `currentPortions` → nombre de 0 à 1 000 |
| `generateRecipeFn` | `generate` | `query` → 5 000 car., requis ; `preferenceInsight` → 100 000 car. ; `libraryContext` → 500 éléments de 20 000 car. ; `variantLabel`, `variantInstruction` → 5 000 car. ; `siblingVariantLabels`, `avoidTitles` → 500 éléments de 5 000 car. |
| `searchRecipesFn` | `search` | `query` → 5 000 car., requis ; `recipes`, `ratedRecipes` → 5 000 éléments de 20 000 car. |
| `extractBookCoverFn` | `book_cover` | `bytesBase64` → 8 Mo décodés, requis ; `mimeType` → 5 000 car., requis |
| `detectAndCropIllustrationsFn` | `detect_illustrations` | `bytesBase64` → 20 Mo décodés, requis ; `mimeType` → 5 000 car., requis |
| `suggestMealPlanFn` | `planning` | `slotDates` → 500 éléments de 5 000 car., requis ; `recipes` → 5 000 éléments de 20 000 car. ; `globalConstraints` → 5 000 car. ; `dailyConstraints` → 100 000 car. JSON ; `slotConstraints`, `alreadyAssigned`, `recentlyServed` → 500 éléments de 20 000 car. ; `batchCookingDay` → entier de 1 à 7 |
| `generateRecipeConceptFn` | `planning_concept` | `slotDate` → 5 000 car., requis ; `globalConstraints` → 5 000 car. ; `dayConstraint`, `requestedDish` → 20 000 car. JSON ; `alreadyPlanned` → 500 éléments de 5 000 car. |
| `suggestMealIdeasFn` | `planning_meal_ideas` | règles propres au poste (voir ci-dessus) ; tailles relevées avant troncature : `prompt`, `previousTitles`, `globalConstraints` |
| `consolidateShoppingListFn` | `shopping_list` | `ingredients` → 500 éléments de 20 000 car., requis et non vide |
| `suggestRecipeTagsFn` | `suggest_tags` | `titre` → 5 000 car., requis ; `cooklang` → 100 000 car. |
| `generateWebSearchQueryFn` | `web_search_query` | `userQuery` → 5 000 car., requis |
| `generateRecipeIllustrationFn` | `generate_recipe_illustration` | `recipeTitle` → 5 000 car., requis ; `recipeContext` → 100 000 car., requis ; `userInstruction`, `style` → 5 000 car. |
| `suggestPlatingFn` | `plating_coach` | `userInstruction` → 5 000 car. |
| `normalizeRecipeReferentialsFn` | `normalisation_referentiels` | `cooklang` → 100 000 car. ; `ingredients` → 500 éléments de 20 000 car. |

**Liste blanche.** `refineRecipeFn`, `searchRecipesFn`, `suggestMealPlanFn` et
`generateRecipeConceptFn` passent au générateur un objet construit par
`callable/_aiInputReaders.ts` (`readRefineInput`, `readSearchInput`, `readPlanningInput`,
`readConceptInput`) à partir des **seuls champs validés** ci-dessus. Un champ que le client
ajoute n'atteint aucun prompt. Les éléments de liste et les objets imbriqués (résumé de
recette, contrainte du jour) passent tels quels, bornés par la taille de leur JSON. Un
nombre recopié dans un prompt est borné comme un texte (`requireBoundedNumber`) : un type
autre qu'un nombre fini, ou une valeur hors bornes, lève `invalid-argument`.

Les callables dont le modèle ne reçoit que des données relues en base —
`suggestStorageAdviceFn`, `generatePlatingImageFn`, `computeRecipeNutritionFn`,
`enhanceIllustrationFn` — n'ont aucun champ à borner : le client n'envoie qu'un
identifiant ou une URL Storage déjà contrôlée.

**Journalisation.** Chaque appel écrit une entrée de message fixe **« Taille des entrées
IA »**, jamais le contenu :

- accepté : `INFO`, label `feature`, `extra: { feature, sizes: { <champ>: <taille> } }` ;
- refusé pour dépassement : `WARNING`, même forme, plus
  `refused: { field, size, max, unit }` (`unit` : `chars`, `items` ou `bytes`) ;
- champ absent ou mal typé : `invalid-argument` sans entrée de journal, comme avant.

Un texte est mesuré en caractères, une image en octets décodés, un objet en caractères de
son JSON, un nombre en caractères de son écriture décimale. Une liste est relevée deux fois : `sizes.<champ>` en éléments et
`sizes.<champ>_chars` en caractères JSON cumulés, qui disent combien de jetons elle coûte.
Ce relevé sert à resserrer les bornes poste par poste. Filtre Cloud Logging :
`jsonPayload.message="Taille des entrées IA"`.

### 7.9 Reprendre — la politique du pipeline d'import

Le pipeline asynchrone est le seul endroit où un échec se rejoue tout seul.

**Mise en file.** `jobDispatcher` part sur chaque écriture de `processing_jobs/{id}` et
n'enfile que sur une **entrée** en `queued` : si le document était déjà `queued` avant
l'écriture, rien n'y est entré. Sans cette garde, chaque mise à jour de progression
réenfilait le job. `dispatchDeadlineSeconds: 540`.

**Reprise Cloud Tasks**, déclarée sur `recipeProcessor` :

| Réglage | Valeur |
|---|---|
| `maxAttempts` | 3 (`MAX_RETRY_ATTEMPTS`) |
| `minBackoffSeconds` | 10 |
| `maxBackoffSeconds` | 300 |
| `maxDoublings` | 4 |
| `MAX_CONCURRENT_DISPATCHES` | 5 |
| `MAX_DISPATCHES_PER_SECOND` | 2 |

Le rang de la tentative arrive dans `req.retryCount` et est écrit sur le job
(`attempt_count`).

**Quand la reprise n'a pas lieu.** Six échecs envoient le job **directement** en dead
letter, sans réessayer, parce qu'une nouvelle tentative échouerait à l'identique : un plafond
de dépense atteint (`budget_exceeded`), un livre illisible (`book_file_unreadable`), un
balisage coupé à tous les efforts (`tagging_truncated`), un livre cible qui n'appartient
pas au créateur du job (`foreign_book`), et un fichier source hors du dossier du créateur du
job (`forbidden_source_path`), un DOCX joint à un import de recette au-delà des bornes de
lecture (`archive_limit_exceeded`, `ZipLimitError`). Un livre EPUB ou Word au-delà des bornes
finit en `book_file_unreadable` : `openBookFile` transforme l'erreur en `BookFileError`. `foreign_book` et `forbidden_source_path` sont contrôlés avant tout téléchargement et
tout appel de modèle. Le refus `concurrency` du plafond ne concerne pas le pipeline : il ne
vise que les appels déclenchés par un utilisateur (§6).

**Le fichier source.** `file_url` et `additional_file_urls` sont posés par le client. Avant
de télécharger, `resolveJobSourcePath` (`pipeline/recipeProcessor.ts`, qui s'appuie sur `resolveAllowedStoragePath` de `utils/storagePath.ts`) extrait le chemin d'objet de
la référence (chemin nu, `gs://` du bucket par défaut, ou URL `firebasestorage.googleapis.com`
de ce bucket ; l'URL `http://localhost` de l'émulateur seulement quand il tourne), refuse tout
segment vide, `.` ou `..`, et n'admet que `scans/{created_by}/…` — là où
`scanAndPromoteUploadFn` promeut une page ou un livre, et où `runBookImport` découpe ses
tranches. `rejected/…`, la quarantaine, les scans d'un autre compte et toute URL externe sont
refusés (`StoragePathRefusedError`).

**La sortie.** À la dernière tentative — ou immédiatement dans les cinq cas ci-dessus —
`moveToDeadLetter(...)` écrit `dead_letters/{jobId}` avec :

| Champ | Valeurs |
|---|---|
| `failure_reason` | `budget_exceeded`, `quota_exceeded`, `book_file_unreadable`, `tagging_truncated`, `foreign_book`, `forbidden_source_path`, `archive_limit_exceeded`, `pipeline_error` |
| `last_error` | le message de l'exception |
| `retry_count` | le nombre de tentatives consommées |
| `file_path` | le fichier téléversé, pour pouvoir rejouer |
| `correlation_id`, `user_id` | le fil et le compte |

Le job passe alors en `status: "error"` avec son `error_message`, et le processeur **retourne
sans lever** : lever une seconde fois relancerait Cloud Tasks sur un job déjà classé.

**La reprise manuelle.** `relaunchDeadLetterFn` (admin) recrée un `processing_jobs` en
`queued` avec `attempt_count: 0` et horodate `relaunched_at` sur la dead letter.
`deleteDeadLetterFn` purge. Les deux sont exposées dans *Admin › File d'échecs*.

**L'import d'un livre entier** passe par trois étapes côté client, et deux fonctions côté serveur.

1. Le client envoie le fichier dans `quarantine/{uid}/livres/` (`putFile` depuis le disque, `putData`
   sur le web) puis appelle `scanAndPromoteUploadFn`. Sous `livres/`, celle-ci ne charge pas le
   fichier : elle lit les 64 premiers Ko pour la signature (`scanUploadHead`) et parcourt le reste
   en flux pour la signature EICAR (`streamContainsEicar`, qui reporte la fin de chaque morceau
   devant le suivant). Une archive ZIP est admise sous `.docx` et `.epub` seulement.
2. `analyzeBookFileFn` (éditeur ou admin, 2 GiB) ouvre le livre promu et rend le nombre de pages
   ou de caractères, le nombre de tranches, le coût estimé et le plafond proposé. L'estimation
   (`books/importEstimate.ts`) vient d'abord des **livres déjà importés** : somme des lignes
   `ai_usage` de leur scan divisée par leur nombre de tranches (`windows_total`), sur les 3
   derniers ; un livre dont un appel n'a pas de montant est écarté. À défaut, de la moyenne par
   scan des 15 dernières **pages scannées** de l'utilisateur — les tranches de livre en sont
   exclues (`book_window`), sinon un livre à soixante dollars compterait pour un scan — avec au
   moins 3 scans, sinon la mesure est `null`. Le plafond proposé (`suggestedBudgetUsd`,
   `suggestImportBudgetUsd`) est l'estimation plus la moitié, arrondie au dollar supérieur, ou
   0,50 $ par tranche sans estimation : une décision, pas une mesure. Il ne dépasse jamais le
   maximum serveur (`maxImportBudgetUsd`). La réponse porte aussi, depuis v0.23.13, le maximum
   (`maxBudgetUsd`), le maximum par tranche (`maxBudgetPerWindowUsd`) et le taux qui a servi
   (`budgetUsdToEur`, `null` s'il est absent ou hors bornes). Avec ce taux, l'écran fait saisir
   le plafond en euros (`BudgetCurrency`) et le convertit en dollars avant de l'écrire sur le
   job ; sans lui, en dollars. Il affiche « maximum … » sous le champ et refuse un plafond plus
   haut par « Au plus … (… par tranche) », montants lus dans la réponse, jamais en dur. Avec
   `discard: true`, la
   fonction supprime le fichier — seul son propriétaire, et seulement sous
   `scans/{uid}/livres/`. Elle ne dépense rien.
3. Sur « Lancer l'import », le client crée le job `bookDocumentScan` avec `budget_limit_usd`, le
   plafond lu dans le champ de l'écran de confirmation : le bouton reste grisé sans montant
   valide. `runBookImport` borne ce plafond côté serveur à 4 € par tranche, convertis en dollars
   au taux de la facture — 4 $ par tranche sans taux, journalisé —
   (`effectiveImportLimitUsd`) : la valeur du client ne peut que réduire ce maximum. Une tranche
   arrêtée par le plafond se relance, et la relance ouvre un palier de plus. `recipeProcessor`
   prend le relais (voir § 3.4 et `scan_spend`). Quitter l'écran avec un livre lu en attente
   appelle `discard`.

Un DOCX et un EPUB sont des archives ZIP : `utils/boundedZip.ts` les lit avec trois bornes,
vérifiées pendant le dépliage et non sur les tailles déclarées — 10 000 entrées, 50 Mo dépliés
par entrée, 200 Mo cumulés par archive (`DEFAULT_ZIP_LIMITS`). Le nombre d'entrées se
contrôle **avant** `JSZip.loadAsync` : `countCentralSignatures` compte les occurrences de la
signature d'en-tête central (`50 4B 01 02`) dans tout le buffer, arrêt à la borne plus un.
Chaque entrée que JSZip construit commence par cette signature à une position distincte : ce
compte majore toujours le nombre d'entrées de JSZip, quel que soit le point de départ du
parcours. L'enregistrement de fin d'archive (EOCD, ZIP64) n'est pas lu : son compteur, sa
position et son localisateur se falsifient. Une signature présente par hasard dans des données
compressées ne peut que surestimer le compte. Le nombre d'entrées est revérifié sur ce que
JSZip a lu.
Une borne franchie lève `ZipLimitError` : `BookFileError` pour un livre EPUB ou Word
(`book_file_unreadable`, jamais réessayé) ; pour un DOCX joint à un import de recette, le job
part en dead letter `archive_limit_exceeded` (`ai/attachment.ts` ne renvoie pas l'archive au
modèle). Une couverture EPUB
au-delà des bornes est écartée et journalisée ; le livre s'importe sans elle.

Aucun poste d'IA nouveau : la lecture de la première page d'un PDF s'impute à `book_cover`, chaque
tranche à `transcription_page` et aux postes de la chaîne d'import, sous le `scan_id` du livre.

### 7.10 Ce qui tourne tout seul, et ce qu'on relance à la main

Trois tâches planifiées (Cloud Scheduler) et quatre reprises manuelles. Aucune n'est
déclenchée par un utilisateur ; toutes journalisent sous leur propre `correlationId`.

| Fonction | Cadence | Ce qu'elle fait |
|---|---|---|
| `scheduledNutritionCatchUp` | `0 5 * * *` — chaque jour à 5 h | reprend les recettes dont la nutrition n'a pas abouti. Cinq tentatives au plus par liste d'ingrédients (`nutrition_catch_up_attempts`), remises à zéro dès qu'une entrée change. C'est ce compteur qui transforme un échec permanent en dépense finie |
| `scheduledAiBudgetAlert` | `0 7 * * *` — chaque matin à 7 h | compare le cumul du mois au seuil réglé. Se tait dans quatre cas : pas de seuil, pas de taux de change, seuil non franchi, alerte déjà émise |
| `scheduledAiReconciliation` | `0 6 4 * *` — le 4 de chaque mois à 6 h | réconcilie le mois précédent avec la facturation BigQuery |

| Reprise manuelle | Réservée à | Ce qu'elle traite |
|---|---|---|
| `backfillNutritionFn` | `admin` | recalcule la nutrition, 40 recettes par appel par défaut, avec un point de reprise dans `app_config` — un backfill qui repart de zéro à chaque appel ne finit jamais |
| `backfillEnrichReferentialsFn` | `admin` | enrichit les référentiels d'unités et d'ingrédients |
| `backfillShoppingFn` | `admin` | recalcule `shopping_products` sur toutes les recettes, sans appel de modèle, sans réécrire une recette dont le résultat ne change pas. 500 recettes par appel par défaut, point de reprise et compte rendu dans `app_config/shopping_products_backfill_checkpoint` |
| `backfillUserProfilesFn` | `admin` | crée, met à jour ou retire le profil public `user_profiles/{uid}` de chaque compte, d'après `users/{uid}`, par `syncPublicProfile` (la fonction du déclencheur `syncUserClaims`). Un profil déjà conforme n'est pas réécrit ; un compte en attente n'a pas de profil. Sans appel de modèle, 2 000 comptes par appel par défaut, arrêt après trois échecs de suite. Point de reprise et compte rendu dans `app_config/user_profiles_backfill_checkpoint`. À lancer une fois **juste après** le déploiement de la v0.23.14 : jusque-là, les noms des autres membres s'affichent « Membre » |
| `backfillRecipeRolesFn` | `admin` | pose `tags.meal_role`, `contains`, `suggested_sides` et `roles_tagged_at` sur les recettes antérieures à leur ajout. Un appel de modèle par recette (poste `backfill_recipe_roles`), 40 recettes par appel par défaut ; une recette déjà classée est sautée, sauf `force`. S'arrête après trois échecs de suite. Point de reprise et compte rendu dans `app_config/recipe_roles_backfill_checkpoint` |

Le point de reprise est la seule chose qui distingue un backfill d'une boucle : chacun écrit
où il s'est arrêté, et l'appel suivant repart de là.

### 7.11 Les échecs qui ne se rejouent pas

Tous les échecs ne méritent pas une seconde tentative. La distinction est explicite dans le
code, et une réimplémentation doit la reproduire :

| Cas | Comportement |
|---|---|
| JSON malformé rendu par un modèle | `JsonAnswerError`, réponse brute journalisée, **pas de retry** — le modèle rendra la même chose |
| Aucune recette sur la page | Aucun brouillon créé ; le job se termine proprement plutôt que d'écrire une recette vide |
| Timeout / erreur réseau | Retry Cloud Tasks, backoff 10 s → 300 s, trois tentatives, puis dead letter |
| Plafond de dépense atteint | Refus **avant** l'appel, dead letter immédiate |
| Livre cible d'un autre membre (import) | `assertJobTargetBook` refuse avant tout téléchargement : dead letter dès la première tentative, `failure_reason: foreign_book` |
| Fichier source hors de `scans/{created_by}/` (import) | `resolveJobSourcePath` refuse avant tout téléchargement : dead letter dès la première tentative, `failure_reason: forbidden_source_path` |
| Image à relire hors des dossiers publiés (amélioration d'illustration, visuel de dressage précédent) | `downloadStorageBytes` n'admet que `illustrations/` et `recipes/` : `permission-denied` avant tout téléchargement |
| Trop d'appels d'IA simultanés pour un compte, depuis une callable | Attente jusqu'à 20 s, puis `BudgetExceededError` de motif `concurrency`, rendu en `resource-exhausted`. Le pipeline, les déclencheurs et les tâches planifiées ne sont pas limités en simultanéité |
| Chemin Storage refusé par une callable | `logWarn` avec le compte et le chemin, puis `permission-denied` : une tentative de lecture de `rejected/…` laisse une trace |
| Clé du fournisseur absente | Repli sur Gemini, avec un `WARNING` nommant le poste et le moteur attendu |
| Grille tarifaire illisible | L'appel a lieu, l'usage est enregistré **sans montant**, compté dans `total_unpriced_calls`. Jamais de prix de repli |
| Appel abouti puis échoué côté client | L'usage est enregistré **sans jetons** : le fournisseur facture, l'appel ne doit pas devenir invisible |

Cette dernière ligne est la plus facile à oublier lors d'une réécriture. Un appel qui atteint
le fournisseur puis échoue est facturé : ne rien écrire ferait disparaître du suivi une
dépense réelle, et le repli sur l'autre moteur en ajouterait une seconde par-dessus.

---
## 8. Parsing et Rendu CookLang

### Le parseur est une implémentation maison, jumelée

**Il n'existe pas de paquet Dart `cooklang` dans ce projet.** Le parseur vit dans
`core/services/cooklang_parser.dart`, et son jumeau TypeScript dans
`functions/src/cooklang/parser.ts`. Les deux rejouent la fixture
`test-fixtures/cooklang_parsing.json` — corriger un bug d'un seul côté fait échouer la CI de
l'autre.

Le client en a besoin pour afficher et travailler hors connexion ; le serveur pour décider sans
lui, à l'import. C'est le seul motif qui justifie la duplication.

### Ce que le parseur rend

| Fonction | Ce qu'elle produit |
|---|---|
| `parseCooklangMeta(cooklang)` | les métadonnées `>> clé: valeur` en `Map<String, String>` |
| `extractIngredients(cooklang)` | les noms `@ingrédient`, dans l'ordre d'apparition, sans doublon |
| `extractIngredientsStructured(cooklang)` | la liste `RecipeIngredient` — nom, quantité, unité, catégorie |
| `buildIngredientsIndex(ingredients)` | `ingredients_index`, l'index de recherche |
| `ingredientKey(nom)` | la clé de déduplication |
| `extractPortions(cooklang)` | l'entier de `>> portions: N` |

Deux syntaxes de section coexistent et sont **toutes deux** reconnues : `== Nom ==`, écrite par
l'éditeur visuel, et `## Nom`, écrite à la main ou par le balisage. N'en reconnaître qu'une
suffisait à laisser une section en double après une seconde insertion.

### Trois règles qui ne se devinent pas

**`buildIngredientsIndex` est l'écrivain unique de `ingredients_index`.** Il en a existé trois,
qui ne produisaient pas la même chose : les noms normalisés par le référentiel à la création et à
la mise à jour, les noms bruts du CookLang à la validation, et les noms du formulaire sans mise en
minuscules à la création libre. Une même recette était indexée différemment selon la façon dont
elle avait été enregistrée, et la recherche par ingrédient répondait en conséquence.

**`ingredientKey` normalise pour comparer, pas pour afficher.** Minuscules, apostrophes
typographiques ramenées à l'apostrophe droite, accents retirés, `s` final de chaque mot supprimé.
Sans le dernier point, « oeufs » et « oeuf » comptaient pour deux ingrédients.

**Une température n'est pas un ingrédient.** Un jeton dont le nom ressemble à `180°c` ou commence
par un chiffre est écarté. Sans cette garde, l'index de recherche se remplissait de degrés.

Un même ingrédient qui apparaît avec deux quantités différentes voit ses quantités **combinées** —
« 45 g + une poignée » — plutôt que dédoublé.

### Rendu

Le rendu est construit en widgets Flutter, jamais en HTML :

- chaque ingrédient, ustensile et minuteur devient une **pastille** (`cooklang_chip_widgets.dart`),
  distinguée par sa couleur et son icône ;
- les étapes sont numérotées, une ligne préfixée `+` prolongeant la précédente **sous le même
  numéro** ;
- les minuteurs sont lus et affichés avec leur durée. **Rien ne décompte** : un minuteur interactif
  demanderait des notifications locales, et figure dans « ce qui reste à construire ».

---

## 9. Écran de relecture d'un brouillon

`draft_review_screen.dart` et `draft_review_body.dart`. **Il n'y a pas de panneau éditeur et de
panneau rendu côte à côte** : le rendu est un mode de l'éditeur, pas un voisin.

### Quatre dispositions, selon la largeur et selon la page

La bascule se fait sur `PlatformUtils.compactDetailBreakpoint`. La nature de la page — recette ou
document — décide du reste : une page classée `ingredient_note`, `technique` ou `other` n'a pas
d'ingrédients à relire.

| Largeur | Page | Disposition |
|---|---|---|
| large | recette | panneau de métadonnées à gauche, onglets **Ingrédients · Recette · Photos** à droite |
| large | document | panneau de métadonnées à gauche, onglets **Éditeur · Photos** à droite (`MarkdownEditor`) |
| étroite | recette | onglets **Informations · Ingrédients · Recette · Photos** |
| étroite | document | onglets **Informations · Éditeur · Photos** |

### L'onglet Recette

Il porte un `HybridRecipeEditor`, décrit au chapitre 13. Trois modes permutables par une barre de
bascule — **texte** CookLang monospace avec coloration en direct, **visuel** WYSIWYG par blocs à
pastilles, **aperçu** (`CooklangPreview`) — partageant un seul `TextEditingController`. Basculer
est instantané et ne perd rien : chaque bloc garde sa ligne source, et la recomposition rejoint
ces lignes telles quelles.

### Ce qui reste hors onglets

- La barre d'actions : titre éditable, **Enregistrer en brouillon**, **Créer et valider**.
- Le bouton **« Voir l'original »** — visionneuse plein écran zoomable pour une image, ouverture
  système pour un PDF ou un DOCX. Le document source est lié à vie à la recette.
- Le `FidelityBanner`, quand le contrôle de fidélité a émis une réserve. Il n'apparaît **que**
  sur cet écran, jamais sur la recette : c'est un outil pour décider, pas pour cuisiner. Valider
  l'efface — valider, c'est avoir relu et tranché.

---

## 10. Application Desktop (Windows)

### Spécificités

- Construite depuis la même codebase, cible `flutter build windows --release`, puis copiée
  dans `Release/desktop`. macOS n'est pas construit aujourd'hui.
- **App Check n'y fonctionne pas** : sa seule voie serait un jeton de débogage, c'est-à-dire
  un secret partagé dans un binaire distribué. Passer l'attestation en *exigé* prive donc le
  desktop de l'IA. Cette limite ne se contourne pas par une exemption de plateforme — la
  plateforme est déclarée par le client, donc par un attaquant aussi.
- Pas d'accès caméra ; l'import de fichier couvre le besoin.
- Raccourcis clavier dans l'éditeur CookLang, sans effet là où il n'y a pas de clavier.

---

## 11. Application Web

### Spécificités

- Construite avec `flutter build web --release`, hébergée sur **Firebase Hosting**.
- **La caméra fonctionne sur le web** (`getUserMedia`) : le scan n'est pas réservé au mobile.
- **Ce qui change n'est pas la plateforme, c'est la largeur.** Toutes les routes, administration
  comprise, sont ouvertes partout. Trois seuils (`PlatformUtils`) commandent la présentation :
  navigation latérale ou barre basse à 800 px, présentation compacte du détail à 700 px,
  raccourci galerie à 900 px. La présentation compacte réorganise, elle ne retire rien.
- Authentification Google via le SDK Firebase JS (FlutterFire Web), attestation par
  reCAPTCHA Enterprise. La clé de *site* vit dans le code — c'est une clé publique par
  conception, la mettre en secret n'aurait rien caché.

### Cache — règle absolue

Dans `kass_dalle/firebase.json` :

- **Jamais** de `**/*.@(js|css|wasm)` en `immutable`. Seul `canvaskit/**` peut l'être.
- `index.html`, `flutter_service_worker.js`, `flutter_bootstrap.js`, `flutter.js`,
  `main.dart.js` et `version.json` restent en `no-cache, no-store, must-revalidate`
  (+ `Pragma: no-cache` et `Expires: 0` pour `index.html` et le service worker).

- `app-release.apk` porte les mêmes en-têtes anti-cache, plus
  `Content-Type: application/vnd.android.package-archive` et un
  `Content-Disposition: attachment` qui le nomme `kass-dalle.apk`. Sans le premier, le
  navigateur affiche le fichier au lieu de le télécharger ; sans les seconds, l'utilisateur
  réinstalle la version de la semaine dernière en croyant se mettre à jour.
- `apk_release.json` porte les mêmes en-têtes anti-cache. C'est le manifeste que
  l'application Android interroge au lancement : un cache d'une heure retarderait
  d'autant la proposition de mise à jour.
- Une seule règle de réécriture, `** → /index.html`, comme toute application à route unique.

Un cache long sur ces fichiers laisse les utilisateurs bloqués sur une ancienne version.

### En-têtes de sécurité et CSP

`firebase.json` pose `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy` et une
`Content-Security-Policy-Report-Only`. La CSP est **en rapport seul, sans destination de
rapport** (ni `report-uri`, ni `report-to`) : le projet n'a pas de point de collecte. Une
violation s'affiche dans la console du navigateur de celui qui la provoque, et nulle part
ailleurs. La CSP ne bloque donc rien, et personne n'est prévenu de ce qu'elle bloquerait.

Ce qui en dépend : `img-src` limite les images à `'self'`, `data:`, `blob:`,
`*.googleapis.com` (dont Firebase Storage) et `*.googleusercontent.com` (photos de profil
Google). Les champs d'image d'une recette ou d'un livre (`image_urls`, `thumbnail_urls`,
`url_couverture`) et les images insérées dans le texte d'une recette sont écrits par le
client ; aucune règle Firestore ne contrôle leur hôte — une règle ne parcourt pas une liste, ni
le texte CookLang. La CSP, en rapport seul, ne bloque aucune de ces URL ; c'est le filtre
client ci-dessous qui les refuse, sur toutes les plateformes, photo de profil exceptée. Le serveur ne télécharge aucune de ces
URL : pas de requête sortante vers une adresse fournie par un client.

**Filtre d'affichage côté client (v0.23.13).** L'application n'affiche que ses propres images,
sur toutes les plateformes et indépendamment de la CSP. `isAppImageUrl`
(`lib/core/utils/app_image_url.dart`) accepte trois formes, et elles seules :

| Forme | Exemple |
|---|---|
| URL de téléchargement du bucket du projet | `https://firebasestorage.googleapis.com/v0/b/kassdale-6d948.firebasestorage.app/o/<chemin encodé>?…` |
| URL publique du bucket du projet | `https://storage.googleapis.com/kassdale-6d948.firebasestorage.app/<chemin>` |
| Les deux mêmes formes sur l'ancien bucket par défaut du projet | `kassdale-6d948.appspot.com` (`kLegacyAppStorageBucket`) : des documents anciens peuvent y pointer |
| Émulateur Storage, en debug seulement | `http://localhost:9199/v0/b/<bucket du projet>/o/…` (aussi `127.0.0.1`, `10.0.2.2`) |

Le bucket est lu dans `DefaultFirebaseOptions.web.storageBucket` (le même pour toutes les
plateformes). Tout le reste est refusé : un autre bucket, un autre hôte, `http://`, un port ou
des identifiants dans l'URL, un chemin qui ne désigne pas un objet, une URL illisible, `data:`,
`blob:`, `file:`. Les assets embarqués (`assets/…`) s'affichent par `Image.asset` et ne passent
pas par ce filtre.

`AppNetworkImage` (`lib/core/widgets/app_network_image.dart`) est le seul point d'affichage
d'une image réseau : même interface que `CachedNetworkImage`, réduite aux paramètres employés.
Une URL refusée n'est jamais chargée : le widget appelle l'`errorWidget` de l'écran avec
`ForeignImageUrl`, et l'écran affiche son image de repli habituelle ; sans `errorWidget`,
`AppImageFallback` (fond `surfaceContainerHighest`, icône `broken_image_outlined`). Les éditeurs
CookLang et Markdown y écrivent « Image extérieure : importez-la depuis la galerie » ; la file
de modération montre la même vignette que pour une image sans URL, avec l'infobulle « Image
hors de Kass'Dalle ». Une vignette refusée n'ouvre pas de visionneuse (pages de livre, visuel
de dressage). Un refus d'affichage n'est pas une erreur et ne passe pas par
`ErrorReportService`. Les points couverts : photos et illustrations d'une recette (en-tête,
onglet Photos, galerie, étapes, aperçu CookLang, éditeurs CookLang et Markdown, feuille
d'insertion), pages de livre, visuel de dressage, source d'un import, cartes d'illustration des
brouillons et de la recherche, couvertures des livres (grille, validation, en-tête de liste),
file de modération, `ImageActionCard`. L'export PDF ne télécharge pas une image refusée
(`_fetchImageBytes`).

**Téléchargements.** `refFromURL` accepte une URL de n'importe quel bucket. Tout téléchargement
d'une image par le client passe donc d'abord par le filtre : `DraftReviewService.downloadImageBytes`
et `extractAndUploadIllustrations` (`_requireAppImage`), `ImageActionCard._downloadBytes`. Un
refus ne télécharge rien, est tracé par `ErrorReportService` (une donnée qui pointe ailleurs est
une anomalie) et s'affiche : « Cette image ne vient pas de Kass'Dalle : elle n'est pas
téléchargée. » (`ForeignImageUrl.message`, intercepté par `on ForeignImageUrl` dans
`recipe_edit_screen.dart` et `draft_review_screen.dart`).

Exception, décidée par l'utilisateur : la photo de profil (`photo_url`, `googleusercontent.com` pour un compte
Google) reste affichée sans filtre, dans le menu du compte (`app_shell.dart`), l'écran Compte
(`account_screen.dart`) et la liste des utilisateurs (`admin_screen.dart`).

Suite proposée pour la CSP (audit sécurité 2026-10-09, « Faible ») : mesurer d'abord, en
ajoutant une destination de rapport (petite fonction HTTP qui journalise par `logWarn`, ou
service externe), puis basculer en mode bloquant une fois les rapports vides.

### Build et déploiement

Le chemin normal est un push sur `master`, depuis le PC comme depuis une session cloud :
`.github/workflows/deploy.yml` déploie après une CI verte (voir « Déploiement automatique »).

Le script racine `deploy.ps1` est l'outil de secours, pour le jour où GitHub Actions est
indisponible. Jamais de commandes reconstituées à la main : il construit, déploie, copie dans
`Release/` et pousse le dépôt.

```powershell
./deploy.ps1              # secours : web + APK + functions + hosting/firestore/storage + git push
```

`deploy.ps1` lance la CLI Firebase avec `--non-interactive`. Sa sortie part dans un journal :
une question de la CLI n'apparaîtrait pas à l'écran, et le script attendrait une réponse
invisible, par exemple la confirmation de suppression d'une fonction retirée du code. En mode
non interactif, la CLI s'arrête avec son message. Une fonction retirée du code fait donc
échouer `deploy.ps1` ; le workflow, lui, la supprime (`--force`).

**Tout déploiement par `deploy.ps1` embarque l'APK.** `-WebOnly` a été retiré : le script s'arrête si on le lui
passe, au lieu de publier un site sans binaire. L'application Android lit le manifeste posé à côté
de l'APK pour savoir si une mise à jour existe ; un déploiement web seul lui annonce une version
que le téléchargement ne rend pas.

Le refus plutôt que la construction silencieuse de l'APK : un script qui fait plus que ce qu'on lui
demande est aussi difficile à comprendre qu'un script qui en fait moins.

Deux pièges connus, tous deux silencieux :

- `flutter build web` peut publier un `main.dart.js` **antérieur** à l'édition sans le
  signaler, et `flutter clean` échoue parfois sur un dossier verrouillé. Vérifier qu'une
  constante attendue figure bien dans `build/web/main.dart.js` : un bundle qui compile n'est
  pas un bundle à jour.
- `deploy.ps1` peut annoncer un succès et sortir en code 0 alors que des Cloud Functions ont
  échoué. Chercher `Functions deploy had errors` dans le log **avant** d'annoncer quoi que ce
  soit — le second `Deploy complete!` est celui du hosting.

Un déploiement hosting remplace tout le contenu de `build/web`. Un déploiement qui ne
reconstruit pas l'APK l'en supprimait donc, ou publiait celui d'un build précédent — c'est ce que
faisait `-WebOnly`, aujourd'hui retiré. Le filet reste utile : `-ResumeHostingOnly` reprend une
mise en ligne interrompue sans rejouer les builds. `Publish-ApkPayload`
s'exécute avant chaque déploiement : elle restaure la paire APK + manifeste depuis
`Release/mobile` quand le build n'a pas été rejoué, et ne publie ni l'un ni l'autre quand il
n'y a rien à restaurer. La paire se restaure **ensemble** — associer un manifeste à un
binaire qui n'est pas le sien annoncerait une version fausse. Le script nomme en fin de
course la version d'APK réellement en ligne dès qu'elle diffère de celle du web.

### Intégration continue (`ci.yml`)

`.github/workflows/ci.yml` part à chaque push sur `master`, à chaque pull request et à la
main (`workflow_dispatch`). Une nouvelle exécution sur la même référence annule la
précédente (`cancel-in-progress`). Le workflow n'a que le droit `contents: read`. Ses actions
sont épinglées par SHA de commit, la version en commentaire (v0.23.12), comme celles de
`deploy.yml`. Trois jobs, sur `ubuntu-latest` :

| Job | Étapes, dans l'ordre |
|---|---|
| Flutter (`kass_dalle/`, Flutter 3.44.6 stable) | `flutter pub get` · `flutter analyze` (erreurs, warnings et infos bloquants) · `dart format --output=none --set-exit-if-changed lib test` · `git diff --exit-code pubspec.lock` · `flutter test` · `flutter build web --release` |
| Functions (`kass_dalle/functions/`, Node 22) | `npm ci` · `npm run lint` (ESLint) · `npm run format:check` (Prettier) · `npm run build` (tsc) · `npm test` |
| Règles — émulateur (`kass_dalle/rules-tests/`, Node 22, Java 21 Temurin) | `npm ci` · `npm test` : émulateurs Firestore et Storage sur le projet fictif `demo-kassdalle`, tests des règles (voir §4, « Tests des règles ») |

Le déploiement automatique ne part qu'après une CI verte sur un push sur `master` : `deploy.yml`
exige la conclusion `success` du workflow entier, donc un seul job en échec, celui des règles
compris, bloque la mise en production.

#### Les fixtures partagées

`kass_dalle/test-fixtures/*.json` sont rejouées par `flutter test` (`test/*_test.dart`) et par
`npm test` (`functions/src/tests/`). Une logique « serveur seul » n'est rejouée que côté
Functions.

| Fixture | Logique | Dart | TypeScript |
|---|---|---|---|
| `cooklang_parsing.json` | parseur CookLang, index, type de page, durées | `core/services/cooklang_parser.dart` | `cooklang/parser.ts` |
| `quantity_parsing.json` | parsing d'une quantité | `core/utils/nutrition_quantity_converter.dart` | `nutrition/quantityConversion.ts` |
| `unit_to_grams.json` | conversion en grammes, quantité absente | idem | idem |
| `ingredient_names.json` | identité d'un ingrédient | `core/utils/ingredient_name.dart` | `nutrition/ingredientName.ts` |
| `ai_pricing.json` | résolution d'un modèle, coût d'un appel | `features/admin/data/ai_pricing.dart` | `ai/pricing.ts` |
| `planning_slot_rules.json` | règles de créneau du planning — serveur seul | — | `gemini/planning.ts` |
| `meal_storage_rules.json` | seuils d'hygiène (constantes) | `features/planning/domain/meal_storage_rules.dart` | `gemini/storageAdvice.ts` |
| `image_moderation_rules.json` | verdict d'une image, paliers Vision — serveur seul | — | `moderation/decision.ts`, `moderation/vision.ts` |
| `page_homography.json` | redressement d'une page : taille de sortie, homographie | `core/presentation/image_enhancer_processing.dart` | `gemini/perspective.ts` |
| `meal_roles.json` | vocabulaire des rôles dans un repas | `features/recipes/domain/meal_role.dart` | `gemini/mealRole.ts` |
| `shopping_products.json` | regroupement des lignes de courses | `core/utils/shopping_products.dart` | `nutrition/shoppingDerivation.ts` |

### Déploiement automatique (GitHub Actions)

C'est le chemin de déploiement normal depuis la v0.23.1, sur le PC comme depuis une session
cloud. Une session cloud fusionne sa PR sur `master` ; le PC commite sur `master` et pousse.
`.github/workflows/deploy.yml` déploie dans les deux cas.

| Quoi | Comment |
|---|---|
| Déclencheur | la CI (`ci.yml`) verte sur un **push** sur `master`, ou un lancement manuel (`workflow_dispatch`), accepté sur `master` seulement |
| Commit déployé | celui que la CI a validé, et seulement s'il est encore la tête de `master`, vérifié au début des deux jobs. Relancer une ancienne CI ou un ancien déploiement ne remet donc pas en ligne une version périmée |
| Ignoré | un commit signé `Deploy-Source: deploy.ps1` : `deploy.ps1`, l'outil de secours, vient de tout déployer depuis le PC. Un message qui commence par `deploy:` sans cette ligne est déployé |
| Déployé | Cloud Functions, puis hosting + règles Firestore + règles Storage |
| APK | construit et signé seulement si `version:` de `pubspec.yaml` dépasse celle de l'APK en ligne (`.github/scripts/build-apk.sh`), avant le déploiement des Functions ; sinon l'APK en ligne est conservé |
| Concurrence | un déploiement à la fois, jamais interrompu (`deploy-production`) |
| Droits et actions | jeton GitHub limité à `contents: read` ; actions tierces épinglées par SHA de commit, version en commentaire (`actions/checkout@11d5960… # v4.4.0`, etc.) : ce job reçoit la clé de signature Android et le compte de service Firebase, et une étiquette `@v4` peut être déplacée vers un autre code. `actions/checkout` avec `persist-credentials: false` : le jeton ne reste pas dans `.git/config` pendant les builds. Monter une action : remplacer le SHA par celui de la nouvelle étiquette (`git ls-remote --tags`) |

**Vérification.** `.github/scripts/firebase-deploy.sh` exige un code 0, la ligne
`Deploy complete`, et aucune ligne `Functions deploy had errors`. Les Functions ont droit à une
relance, qui vise les seules fonctions en échec (`--only functions:<nom>`), comme `deploy.ps1`.
Une relance complète ne suffit pas : la CLI saute toute fonction dont le code n'a pas changé
(« Skipped (No changes detected) »). Au premier déploiement automatique, le code de
`recipeProcessor` était parti mais sa file Cloud Tasks avait échoué ; une relance complète
l'a sautée et a annoncé un succès. Une fonction nommée par `--only` n'est jamais sautée.
`deploy.ps1` suit la même règle depuis la v0.22.109 : il lisait auparavant les seules lignes
`Failed to update function …`, que l'échec d'une file Cloud Tasks n'écrit pas (`Failed to upsert
task queue function …`), et commençait par une relance complète.

**`--force` n'est passé qu'aux Functions.** En mode non interactif, la CLI refuse sinon de
supprimer une fonction retirée du code : une fonction supprimée du dépôt disparaît donc de la
production au déploiement suivant. Il n'est pas passé à `firestore` : il y supprimerait tout
index absent de `firestore.indexes.json`.

**L'APK en ligne est conservé.** Le déploiement du hosting remplace tout le contenu en ligne par
`build/web`. Le workflow télécharge `app-release.apk` et `apk_release.json`
depuis le site et les replace dans `build/web`. Un fichier absent ne rend pas 404 — la
réécriture `**` sert `index.html` avec un code 200 — donc le contenu est jugé : un manifeste
JSON qui porte une `version`, un APK qui commence par `PK`, une taille égale à `size_bytes`.
Les cas suivent `Publish-ApkPayload` :

| En ligne | Résultat |
|---|---|
| APK et manifeste cohérents | republiés tels quels |
| APK seul | republié sans manifeste : aucune mise à jour annoncée |
| Ni l'un ni l'autre | rien n'est publié |
| Manifeste seul, ou taille différente | **déploiement arrêté** : il annoncerait une version que le téléchargement ne rend pas |

Le manifeste continue de décrire le binaire posé à côté de lui : les téléphones ne voient pas de
mise à jour tant qu'un nouvel APK n'est pas publié.

**Un nouvel APK quand la version change.** `build-apk.sh decide` compare `version:` de
`pubspec.yaml` (`x.y.z+n`) à `version` et `build_number` du manifeste en ligne. Il construit si
le pubspec est plus récent, ou s'il n'y a pas de manifeste en ligne. Une version plus ancienne
que celle en ligne — un `deploy.ps1` a publié plus récent — ne reconstruit rien. `build-apk.sh
build` décode la clé dans `$RUNNER_TEMP`, écrit `android/key.properties`, lance
`flutter build apk --release`, pose l'APK et son manifeste dans `build/web` (mêmes champs que
`Write-ApkManifest`), puis supprime la clé et `key.properties`, réussite ou échec. Le build a
lieu avant les Functions : un secret absent arrête tout avant le premier déploiement. Il ajoute
environ huit minutes. Juste avant le hosting, le manifeste en ligne est relu : si un
`deploy.ps1` a publié entre-temps un APK aussi récent ou plus récent, c'est lui qui est
conservé. Ni `Release/mobile` ni Google Drive ne reçoivent cet APK : ils restent
propres au PC.

**Le PC et le workflow.** Le cas ne se pose que si `deploy.ps1` sert de secours. Deux
déploiements simultanés publient chacun leur version, et le dernier arrivé l'emporte. Trois
protections, et une consigne :

- `deploy.ps1` refuse de partir si le PC est en retard sur `origin/master`, et le vérifie de
  nouveau juste avant `firebase deploy`, après les builds web et APK qui durent plusieurs
  minutes ;
- `deploy.ps1` s'arrête en erreur si son `git push` échoue : la production porte alors un commit
  absent de `origin/master` ;
- le workflow vérifie, au début de chaque job, que son commit est toujours la tête de `master` ;
- **pendant que `deploy.ps1` tourne, ne pas pousser à la main.** Un commit poussé à la main
  n'est pas signé : sa CI déclencherait le workflow en parallèle. On laisse `deploy.ps1`
  commiter et pousser.

Il reste une fenêtre de quelques secondes entre la seconde vérification et la fin de
`firebase deploy`. Le workflow recopie aussi l'APK en ligne juste avant son hosting : un
`deploy.ps1` qui publierait un nouvel APK à ce moment le verrait remplacé par l'ancien. En cas de
doute, relancer `deploy.ps1 -ResumeHostingOnly` une fois le workflow terminé.

**L'APK en ligne est vérifié deux fois.** Avant les Functions, `.github/scripts/keep-online-apk.sh`
télécharge la paire APK + manifeste, pour qu'une paire incohérente arrête tout avant le premier
déploiement. Juste avant le hosting, sans nouvel APK, le même script recopie la paire en ligne
(« Conserver l'APK en ligne »). Avec un nouvel APK, « Revérifier l'APK en ligne » ne télécharge
que le manifeste et le compare par `build-apk.sh decide` : si un APK aussi récent ou plus
récent est arrivé entre-temps, `keep-online-apk.sh` le recopie et il est conservé. Un manifeste
absent ou illisible à ce moment ne bloque pas la publication du nouvel APK. Chaque téléchargement a un délai (`curl --max-time` : 300 s pour
l'APK, 60 s pour le manifeste), et chaque étape aussi (`timeout-minutes` : 10, et 15 pour la
seconde lecture). Un échec de la seconde lecture laisse
les Functions neuves avec le web précédent : relancer le workflow une fois la cause réglée.

**Le disque du runner est compté.** Le 8 octobre 2026, trois tentatives se sont arrêtées au
début de « Revérifier l'APK en ligne », sans journal : le runner a planté sur `No space left on
device`. SDK Flutter, caches Gradle, build de l'APK et build web remplissaient son disque. Trois
mesures :

- l'étape « Libérer de la place sur le disque », en tête du job, supprime des outils
  préinstallés dont le déploiement ne se sert pas (.NET, GHC, Swift, Boost, CodeQL, images
  Docker…). Le SDK Android reste : le build de l'APK l'utilise. Elle affiche l'espace libre
  avant et après ;
- `build-apk.sh` supprime `build/app` une fois l'APK copié dans `build/web`, et arrête les
  démons Gradle et Kotlin ;
- la seconde lecture ne télécharge que le manifeste. L'APK en ligne n'est téléchargé que s'il
  faut le conserver.

**Les secrets de signature** (même page que ci-dessous) viennent de `kass_dalle/android/key.properties`
et du `.jks` qu'il désigne, sur le PC : `ANDROID_KEYSTORE_BASE64` (le `.jks` encodé en base64,
sur une ligne : `[Convert]::ToBase64String([IO.File]::ReadAllBytes("<chemin>.jks"))` en
PowerShell ; pas `certutil -encode`, dont les lignes `-----BEGIN` font échouer le décodage),
`ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. C'est la même clé que
celle de `deploy.ps1` : un APK signé par une autre clé serait refusé comme mise à jour.

**Le secret `FIREBASE_SERVICE_ACCOUNT`** (Settings › Secrets and variables › Actions du dépôt
GitHub) contient la clé JSON d'un compte de service du projet `kassdale-6d948`. Rôles IAM :

- `Firebase Admin` ;
- `Cloud Functions Admin` ;
- `Cloud Run Admin` (Functions de 2e génération) ;
- `Service Account User`, sur le compte d'exécution des fonctions ;
- `Artifact Registry Administrator` ;
- `Secret Manager Admin` : les fonctions référencent `GEMINI_API_KEY` et `ANTHROPIC_API_KEY`, et
  la CLI accorde au compte d'exécution l'accès à ces secrets ;
- `Cloud Scheduler Admin` (fonctions planifiées) ;
- `Cloud Tasks Admin` : `recipeProcessor` est une fonction de file Cloud Tasks, et la CLI lit et
  met à jour sa file (`cloudtasks.queues.get`, `cloudtasks.queues.update`).

Le projet doit aussi avoir l'API `cloudbilling.googleapis.com` activée : la CLI la vérifie avant
de déployer les Functions, et le compte de service n'a pas le droit d'activer une API. Activée
le 8 octobre 2026.

Un déploiement dit s'il manque un rôle : le message d'erreur de la CLI nomme la permission
refusée, et le workflow le reprend dans ses avertissements.

---

## 11 bis. Cadrer un document dans une photo

Deux implémentations, et le choix se fait sur la plateforme.

### Sur mobile : le scanner du système

Android expose ML Kit Document Scanner, iOS expose VisionKit. Le paquet `cunning_document_scanner`
enveloppe les deux. Ils cherchent les coins sur le **flux vidéo** de la caméra, avec un modèle
entraîné, sur le processeur dédié : trente images par seconde, et seul ce qui reste stable d'une
image à l'autre est retenu.

C'est ce que fait l'appareil photo du téléphone, et aucune heuristique écrite ici ne rivalisera.
Le scan par la caméra passe donc par lui, pour une couverture comme pour des pages de recette.

- **Couverture** : une page, l'image revient cadrée et redressée, elle part directement en file
  sans passer par l'atelier de retouche.
- **Pages de recette** : jusqu'à vingt par session. Elles rejoignent le lot en attente, comme
  celles prises une à une ou choisies dans un fichier. Le rang est écrit dans le nom
  (`page_<horodatage>_01.jpg`) pour que `comparePageNames` range un lot mêlé.
- Les fichiers rendus vivent dans un cache appartenant au greffon. On lit leurs octets, puis
  `cleanCache()` — best-effort, jamais silencieux.

**Les boutons « Prendre une photo » hors import passent par le même scanner**, via
`core/services/photo_capture_service.dart`. Quatre appelants : l'onglet Photos d'un brouillon
(`draft_illustrations_tab.dart`), le détail d'une recette (`recipe_illustration_actions.dart` et
`recipe_detail_widgets.dart`), la recette générée (`generated_recipe_illustrations.dart`) et le
formulaire de livre (`book_form_screen.dart`). Le service prend une page à la fois, sur le même
critère `PlatformUtils.isMobile` ; la galerie reste `image_picker` partout, et `imageQuality` /
`maxWidth` ne valent que pour lui — le scanner rend un JPEG à sa résolution. Le service ne réutilise
pas `scan_upload_service.dart`, qui garde sa chaîne multi-pages ; ils ne partagent que le critère.

### Sur le web : une suggestion, annoncée comme telle

Aucune de ces API n'existe dans un navigateur. L'atelier de retouche garde la main et calcule un
cadre sur une seule prise, dans `core/presentation/image_enhancer_processing.dart`.

Le cadre est présenté pour ce qu'il est : « Cadre suggéré — vérifiez les coins et corrigez-les »,
ou « Aucun cadre reconnu — placez les quatre coins ».

**On sépare une région, on ne traque pas un contour.** Une première version calculait un gradient
de Sobel et balayait depuis le centre jusqu'au premier bord franc. Elle supposait un intérieur
uniforme — une page de texte. Sur une couverture de livre, qui est une photographie, l'intérieur
porte des contours plus marqués que la frontière carton/table : le balayage s'arrêtait sur le bord
d'une assiette, ou filait jusqu'au cadre de la photo.

La méthode retenue part de ce qui est simple dans la scène : le fond est uniforme et il occupe les
bords. Cinq étapes, chacune corrigeant un cas mesuré sur de vraies photos.

1. **Rognage des bandes.** Les bordures sombres et unies d'une photo de téléphone ne font pas
   partie de la scène. Sans ce rognage, la médiane de la bande extérieure sortait à 21,23,24 — du
   noir — au lieu du bois de la table, et le bois passait pour du document. Une bande est
   **sombre**, franchement unie et éloignée du centre ; le rognage est borné à 30 % par côté.
2. **Modèle du fond, couleur et texture**, pris sur la bande extérieure. La couleur seule ne
   suffit pas : le bois est à 132,101,54 et la couverture contient une planche en bois de la même
   teinte. La texture seule ne suffit pas non plus : la bande du titre et une assiette blanche sont
   lisses, autant que la table. La texture est l'écart-type de luminance sur une fenêtre de neuf
   pixels, calculé par images intégrales.
3. **Raffinement du modèle.** La bande n'est pas toujours pure. Sur une photo mesurée, elle
   longeait un ordinateur noir sur toute sa hauteur gauche : la dispersion brute sortait à 171, un
   seuil qui laissait passer le livre entier. Seuls les pixels de bande proches de la médiane
   servent à la mesurer. La texture du fond se mesure sur ces mêmes pixels.
4. **Cohérence de la bande.** La part de ses pixels serrés autour de leur médiane : 81 % sur une
   photo, 33 % sur une autre où un objet noir et un canapé sombre occupaient les bords. En dessous
   de 55 %, la couleur ne dit plus rien de fiable et **n'est pas utilisée** — la texture reste
   vraie, une table est lisse, un canapé aussi.
5. **Masque, nettoyage, rectangle.** Un pixel appartient au document s'il est loin du fond par la
   couleur **ou** plus texturé que lui. Ouverture morphologique de rayon 3, fermeture de rayon 3,
   puis remplissage : tout ce que le fond n'atteint pas depuis le bord de l'image appartient au
   document — c'est ainsi que l'assiette blanche rejoint le livre au lieu de le trouer. La plus
   grande tache reçoit son rectangle tourné d'aire minimale, cherché par balayage d'un quart de
   tour au degré près.

La détection rend `null` quand la scène ne porte pas de document identifiable — moins de 25 %
de l'image, ou plus de 97 %. Les coins par défaut restent alors, ce qui est plus honnête qu'un
cadre inventé.

**Un recalage sur les bords a été essayé et retiré.** Glisser chaque côté du rectangle le long de
sa normale et garder la position au gradient le plus fort tirait les côtés vers les contours
intérieurs de la couverture, et le cadre entrait dans le livre. La mesure reste en commentaire dans
le code : c'est une piste à ne pas reprendre telle quelle.

**Tout cela tourne sur l'appareil**, jamais sur le serveur : `compute` sur les octets locaux. Sur
le web, `compute` n'ouvre aucun isolate — Flutter web n'en a pas — et le calcul occupe donc le fil
principal.

### Le banc d'essai

`test/detection_sur_photo_reelle_test.dart` lit les photos déposées dans `kass_dalle/photo-test/`
(dossier ignoré par git), exécute la détection, imprime tous ses nombres et écrit une image de
contrôle avec le quadrilatère tracé. Sans photo, il ne fait rien.

Il existe parce que sept versions de cette détection ont été déployées sans jamais tourner sur la
photo qui échouait : les tests de `test/document_detection_test.dart` fabriquent la scène et
l'attente, donc ils passent toujours. Une seule photo réelle a suffi à trancher ce que trois jours
d'hypothèses n'avaient pas tranché.

---

## 12. Application Mobile

**Android est construit et distribué. iOS est déclaré, jamais construit.** La distinction
est nette dans le dépôt, et une réimplémentation ne doit pas prendre le second pour acquis.

### Android

| Élément | État |
|---|---|
| Permissions déclarées | `INTERNET`, `CAMERA` et `REQUEST_INSTALL_PACKAGES` dans `android/app/src/main/AndroidManifest.xml` |
| Caméra | `<uses-feature android:name="android.hardware.camera.any" android:required="false" />` — l'absence de caméra n'empêche pas l'installation |
| Configuration Firebase | `android/app/google-services.json`, présent |
| Signature | `android/key.properties` et `signingConfigs.release` |
| Empreintes | SHA-1 et SHA-256 enregistrées dans la console Firebase |
| Attestation | Play Integrity |
| Icône | Adaptative — `mipmap-anydpi-v26/ic_launcher.xml`, fond `#6B7B3A` dans `values/colors.xml`, couches `drawable-*dpi/ic_launcher_foreground.png` |
| Distribution | `app-release.apk` servi par le même déploiement Firebase Hosting, avec un `Content-Disposition: attachment` |
| Mise à jour | L'application se met à jour elle-même — voir ci-dessous |

#### Mise à jour hors magasin

Kass'Dalle n'est pas distribuée par le Play Store : elle vérifie sa version au lancement,
télécharge son propre APK et le passe à l'installateur du système.

| Pièce | Rôle |
|---|---|
| `apk_release.json` (hosting) | Manifeste de l'APK publié : `version`, `build_number`, `file`, `size_bytes`, `built_at` |
| `core/services/app_update_service.dart` | Lit le manifeste, compare, télécharge en suivant la progression |
| `core/services/app_installer.dart` | Canal `dev.kassbi.kass_dalle/app_installer` vers le natif |
| `MainActivity.kt` | Dossier de téléchargement, lecture de l'autorisation, ouverture de l'installateur |
| `res/xml/file_paths.xml` | Seul chemin exposé par le FileProvider : `cache/updates/` |
| `Publish-ApkPayload` (`deploy.ps1`) | Publie l'APK et son manifeste ensemble, ou aucun des deux |

**Le manifeste n'est pas `version.json`.** Ce dernier décrit le bundle web, et les deux
divergent dès qu'un déploiement ne reconstruit pas l'APK — ce que faisait `-WebOnly`, retiré
depuis, et ce que fait encore `-ResumeHostingOnly`. L'application lisait `version.json` : elle annonçait
alors une version que le téléchargement ne rendait pas, l'utilisateur installait, restait en
dessous, et la fenêtre revenait à chaque lancement. `apk_release.json` n'est écrit qu'au
moment où l'APK est compilé et copié, et décrit donc toujours le fichier servi à côté de lui.

**Pas de repli sur `version.json` quand le manifeste manque** : ce serait reproduire le
défaut qu'il corrige. Sans manifeste, aucune mise à jour n'est proposée.

À version égale, le numéro de build départage : un APK reconstruit sans changement de
`version:` porte le même nom de version et un build supérieur.

L'autorité du FileProvider est `${applicationId}.updateprovider` et non `.fileprovider` :
`image_picker`, `printing` et `cunning_document_scanner` déclarent chacun la leur, et deux
providers de même autorité font échouer la fusion des manifestes.

`REQUEST_INSTALL_PACKAGES` n'autorise pas à installer, elle autorise à le demander : le
système affiche toujours son écran de confirmation, et l'utilisateur doit avoir accordé
« installer des applications inconnues » à Kass'Dalle. L'installation silencieuse n'existe
pas hors Play Store. Quand l'installation directe échoue, la fenêtre propose le
téléchargement par le navigateur, qui était le chemin unique auparavant.

Le téléchargement écrit dans `cacheDir/updates`, vidé avant chaque transfert : un APK pèse
près de 90 Mo. Un fichier plus court que la taille annoncée est effacé sans être ouvert — un
APK tronqué échoue à l'installation sans dire pourquoi.

`test/app_update_service_test.dart` couvre la comparaison de versions, la lecture du
manifeste, l'absence de repli, la progression, le fichier tronqué et l'annulation.

`READ_MEDIA_IMAGES` **n'est pas déclarée**. Le choix d'une photo passe par le sélecteur du
système, qui rend un accès ponctuel sans permission — c'est le comportement voulu depuis
Android 13, et déclarer la permission demanderait une justification au Play Store pour un
accès dont l'application n'a pas besoin.

`INTERNET` était autrefois déclarée dans les seuls manifestes `debug/` et `profile/`.
L'APK de release fonctionnait par effet de bord, la fusion des manifestes des plugins
Firebase la réintroduisant. Elle est déclarée ici pour que ce soit une intention, pas une
chance.

**L'icône est adaptative, et elle ne l'a pas toujours été.** `flutter_launcher_icons`
n'avait que `image_path` : il produisait la seule icône ancienne, carrée, en RGB — la
transparence de `assets/Icon.png` aplatie sur du blanc. Le lanceur d'Android 8 et au-delà
posait son masque rond sur ce carré, et le blanc dépassant du médaillon faisait un liseré.
`adaptive_icon_background` et `adaptive_icon_foreground` dans `pubspec.yaml` créent les
deux couches attendues ; le fond d'une icône adaptative est toujours dessiné et ne peut pas
rester transparent, d'où le choix de l'olive du thème (`AppTheme._seed`). Le XML rentre la
couche avant de 16 %, pour une zone garantie visible de 66,7 %.

`remove_alpha_ios: true` accompagne le changement : la transparence conservée pour Android
avait introduit un canal alpha dans les vingt et une icônes iOS, que l'App Store refuse.

Les icônes sont **versionnées, pas régénérées au build** : après avoir changé
`assets/Icon.png`, il faut relancer `dart run flutter_launcher_icons`. Et une icône ne se met
à jour sur un téléphone qu'à la réinstallation de l'APK.

### iOS — déclaré, pas configuré

Ce qui existe : le projet Xcode (`ios/Runner.xcodeproj`), le bundle
`dev.kassbi.kassDalle`, et une entrée `FirebaseOptions.ios` complète dans
`lib/firebase_options.dart`.

Ce qui manque, et sans quoi une compilation ne servirait à rien :

| Manquant | Conséquence |
|---|---|
| `ios/Runner/GoogleService-Info.plist` | Firebase ne s'initialise pas |
| Le schéma d'URL du `REVERSED_CLIENT_ID` dans `Info.plist` | Google Sign-In ne revient jamais dans l'application |
| `NSCameraUsageDescription` | l'accès caméra fait terminer le processus |
| `NSPhotoLibraryUsageDescription` | l'accès à la photothèque fait terminer le processus |
| `ios/Podfile` | aucune installation de dépendances n'a jamais eu lieu |

**`deploy.ps1` ne construit ni iOS ni l'app bundle Android** : ses cibles sont le web et
l'APK. Une release iOS demanderait un poste macOS, un compte développeur et les cinq points
ci-dessus.

---

## 13. Architecture Flutter (Couches)

Chaque feature porte ses trois couches — `data/` (accès Firestore, Storage, callables),
`domain/` (modèles et règles), `presentation/` (écrans, widgets, providers Riverpod). Deux
features ajoutent un `services/` pour la logique qui ne tient dans aucune des trois.

```
lib/
├── main.dart
├── firebase_options.dart          # Généré par FlutterFire CLI
├── core/
│   ├── app_version.dart           # Lit la version : package_info_plus, version.json sur le web
│   ├── app_links.dart             # Adresse web publique d'une route (/#/recipes/{id})
│   ├── presentation/              # Coquille d'application, navigation
│   ├── router/                    # go_router
│   ├── services/                  # App Check, export PDF, parseur CookLang,
│   │                              # rapports d'erreurs, suivi d'usage, mise à jour APK
│   ├── theme/                     # Thème Material 3
│   ├── utils/                     # Plateforme, quantités, noms d'ingrédients
│   └── widgets/                   # Widgets transverses
└── features/
    ├── admin/                     # Utilisateurs, coûts, moteur d'IA, plafonds,
    │                              # App Check, référentiels, backfills, logs, dead letters
    ├── annotations/               # Remarques, astuces, corrections
    ├── auth/                      # Connexion Google, salle d'attente, rôles
    ├── books/                     # Livres, couvertures, mode lecture
    ├── groups/                    # Groupes familiaux
    ├── moderation/                # Publication d'images et écran de revue
    ├── planning/                  # Repas planifiés, batch planning, conservation (+ services/)
    ├── processing/                # Jobs d'import et leur avancement
    ├── recipes/                   # Scan, révision, détail, liste, nutrition (+ services/)
    ├── sandbox/                   # Bac à sable — hors release, voir 13.3
    └── search/                    # Recherche, filtres, génération de recette
```

Côté Functions :

```
functions/src/
├── index.ts       # les 58 exports déployés — rien d'autre n'est joignable
├── config.ts      # région, file d'attente, plafonds de reprise, nom du journal
├── logging.ts     # le journal structuré — cf. chapitre 7
├── ai/            # types neutres, routeur, client Claude, tarification, budget, usage
├── billing/       # coûts GCP (BigQuery), réconciliation mensuelle
├── books/         # import d'un livre entier : ouverture, découpage en tranches, estimation
├── callable/      # entrées HTTPS callable + gardes (_auth.ts)
├── cooklang/      # parseur, jumeau TypeScript du parseur Dart
├── gemini/        # client Gemini, transcription, balisage, fidélité, prompts par poste
├── illustrations/ # extraction en six étapes, écriture, journal de coût
├── moderation/    # décision pure, moteur Cloud Vision, promotion
├── nutrition/     # per100g, conversions, référentiels, huile de friture
├── pipeline/      # jobDispatcher, recipeProcessor, deadLetterHandler
├── sandbox/       # une seule fonction déployée, sandboxFn, qui aiguille
├── scheduled/     # réconciliation mensuelle, alerte de budget, rattrapage nutrition
├── security/      # App Check
├── tests/         # node --test, fixtures partagées avec Dart
├── triggers/      # onRecipeWritten, onBookWritten, syncUserClaims, enforceFounderRole
└── utils/         # sécurité d'upload, DOCX, images
```

---

### 13.1 Carte de navigation — les 44 routes

`go_router`, déclaré dans `core/router/app_router.dart`. Les constantes vivent dans
`AppRoutes`, une seule `ShellRoute` porte la coquille `AppShell` pour tout ce qui suit
l'authentification.

**Hors coquille** — pas de barre de navigation, pas de menu :

| Route | Écran | Qui y accède |
|---|---|---|
| `/login` | `LoginScreen` | tout le monde, y compris déconnecté ; `?revoked=true` affiche le motif, `?next=` porte l'adresse à rouvrir après la connexion (13.2) |
| `/pending` | `PendingApprovalScreen` | compte authentifié mais pas encore nommé |

**Dans la coquille `AppShell`.** La colonne « droit effectif » dit qui peut réellement
faire quelque chose de l'écran — droit tenu par les règles Firestore, les règles Storage ou
la garde de la callable, **jamais par le routeur** : hors `/admin`, il laisse passer tout
compte nommé. L'import (`/scan`) est réservé à l'éditeur et à l'admin, et `firestore.rules`
l'impose : la création d'un `processing_job`, seul point qui lance le pipeline facturé
(`jobDispatcher`), exige `isEditor()`, et sa relance aussi. La lecture d'un livre avant import
(`analyzeBookFileFn`) exige `requireEditor`. Un `reader` qui ouvre `/scan` par un lien voit un
état « Import réservé aux éditeurs » au lieu du formulaire, et aucune entrée vers `/scan` ne
lui est montrée. `quarantine/{uid}/` (`storage.rules`) et `scanAndPromoteUploadFn`
(`requireAuth`) restent ouverts au `reader` : il y dépose le fichier source de ses propres
recettes depuis `/recipes/new`, et ce contrôle n'appelle aucun modèle.

| Route | Écran | Droit effectif |
|---|---|---|
| `/` | `BookListScreen` | `reader` — l'accueil *est* la bibliothèque |
| `/books` | `BookListScreen` | `reader` |
| `/books/validation` | `BookValidationScreen` | `editor` |
| `/books/new` | `BookFormScreen` | `editor` |
| `/books/:bookId/edit` | `BookFormScreen` | `editor` |
| `/recipes` | `RecipeListScreen` | `reader` |
| `/recipes/new` | `RecipeCreateScreen` | `reader` — chacun crée les siennes |
| `/recipes/:recipeId` | `RecipeDetailScreen` | `reader` |
| `/recipes/:recipeId/edit` | `RecipeEditScreen` | `reader` sur les siennes, `editor` sur celles d'autrui |
| `/book-pages/:pageId` | `BookPageDetailScreen` | `reader` — page de livre sans transition |
| `/scan` | `ScanScreen` | `editor` |
| `/drafts` | `WorkQueueScreen` | `reader` |
| `/drafts/:recipeId` | `DraftReviewScreen` | `reader` |
| `/processing` | — | **redirige vers `/drafts`** : l'écran d'avancement a été fondu dans la file de travail |
| `/search` | `SearchScreen` | `reader` |
| `/planning` | `PlanningScreen` | `reader` |
| `/planning/batch` | `BatchPlanningScreen` | `reader` |
| `/planning/config` | `PlanningConfigScreen` | `reader` |
| `/planning/staples` | `MyStaplesScreen` | `reader` — ses garnitures, retouchées pour soi |
| `/groups` | `GroupsScreen` | `reader` |
| `/account` | `AccountScreen` | `reader` |
| `/preferences` | `PreferencesScreen` | `reader` |
| `/logs` | `LogsScreen` | *voir l'avertissement ci-dessous* |
| `/error-reports` | `ErrorReportsScreen` | *idem* |
| `/dead-letters` | `DeadLettersScreen` | *idem* |

**Sous `/admin`** — la seule branche que le routeur garde vraiment :

| Route | Écran | Ce qu'on y fait |
|---|---|---|
| `/admin` | `AdminHubScreen` | le sommaire de l'administration |
| `/admin/users` | `AdminScreen` | nommer, changer de rôle, révoquer |
| `/admin/costs` | `MonthlyCostsScreen` | la dépense d'IA par mois et par poste |
| `/admin/ai-spend` | `AiSpendScreen` | la dépense par compte et par service, et le plafond |
| `/admin/ai-routing` | `AiRoutingScreen` | quel moteur sert quel poste |
| `/admin/ai-pricing` | `AiPricingScreen` | la grille tarifaire |
| `/admin/app-check` | `AppCheckScreen` | le mode d'attestation |
| `/admin/moderation` | `AdminModerationScreen` | trancher sur une image en attente |
| `/admin/referentials` | `AdminReferentialsScreen` | l'état des référentiels |
| `/admin/nutrition-ingredients` | `NutritionIngredientsScreen` | corriger un ingrédient |
| `/admin/nutrition-units` | `NutritionUnitsScreen` | corriger un poids d'unité |
| `/admin/nutrition-policy` | `NutritionPolicyScreen` | priorité des sources, seuils |
| `/admin/data-quality` | `AdminDataQualityScreen` | le diagnostic des référentiels nutrition, en lecture seule (`getDataQualityReportFn`, §3.10) |
| `/admin/meal-staples` | `MealStaplesScreen` | le référentiel des garnitures simples |
| `/admin/backfills` | `AdminBackfillsScreen` | lancer une reprise |
| `/admin/sandbox` | `SandboxHubScreen` | bac à sable — **hors release**, voir 13.3 |
| `/admin/sandbox/:experimentId` | `SandboxExperimentScreen` | une expérience |

### 13.2 La redirection — la seule fonction qui décide qui voit quoi

`resolveRedirect({user, isLoading, location})` est **extraite** de la fermeture `redirect`
pour être testable. C'est le miroir client du sas d'entrée de `firestore.rules`. Elle rend
`null` quand la destination convient. L'ordre des tests est significatif :

1. `isLoading` → `null`. On ne redirige pas pendant le chargement, sinon chaque démarrage
   passe par `/login`.
2. `user == null` → `/login?next=<adresse demandée>` (`loginLocationFor`), ou `/login` nu
   si l'adresse demandée est l'accueil sans paramètre. Déjà sur `/login` → `null`. Un lien
   ouvert hors de l'application — l'événement Google Calendar d'un repas — rouvre ainsi la
   recette après la connexion.
3. `user.isRevoked` → `/login?revoked=true`. Le paramètre existe pour que l'écran dise
   *pourquoi*.
4. `user.isPending` → `/pending`. Il est authentifié : le renvoyer vers `/login` le ferait
   rebondir vers l'accueil, où les règles lui refuseraient tout sans jamais le lui dire.
5. Nommé entre-temps et encore sur `/pending` → `/`.
6. Connecté et sur `/login` → la valeur de `?next=` si `nextLocationAfterLogin` l'accepte,
   sinon `/`. Le filtre n'accepte qu'une route interne : elle commence par `/` mais pas par
   `//`, et son chemin n'est ni `/login` ni `/pending`. Un `next` vers un autre site ou vers
   ces deux routes est ignoré.
7. `location.startsWith('/admin')` et pas admin → `/`.
8. `/processing` → `/drafts`.

Le routeur écoute `appUserProvider` par un `_RouterNotifier` branché en `ref.listen` : cela
**n'ajoute pas de dépendance réactive**, donc le `GoRouter` n'est jamais reconstruit — un
routeur recréé perdrait la pile de navigation à chaque rafraîchissement du compte.

> **Le routeur ne garde que `/admin`.** `/logs`, `/error-reports` et `/dead-letters` sont
> atteignables par URL directe pour tout compte connecté. Ce n'est pas une faille de
> données : les callables qu'ils appellent exigent le rôle `admin` (`requireAdmin`) et les
> règles Firestore filtrent le reste. La garde utile est celle du backend, pas celle du
> routeur — à garder en tête en ajoutant un écran d'administration.

`AppRoutes.tokenUsage` (`/token-usage`) est **déclarée sans être routée** : l'écran de
consommation de jetons a été fondu dans `/admin/ai-spend`. La constante subsiste sans
appelant.

### 13.3 Le bac à sable dans l'arborescence

`features/sandbox/` côté client et `functions/src/sandbox/` côté serveur n'apparaissent pas
dans les arbres ci-dessus parce qu'ils **ne font partie d'aucune release**. Ils existent
pourtant, et une réimplémentation doit connaître leur contrat :

- une seule fonction déployée, `sandboxFn`, qui aiguille sur un champ `experiment` ; une
  expérience de plus ajoute un `case`, jamais un point d'entrée HTTPS ;
- rôle `admin` exigé ;
- rien n'y est enregistré — ni Firestore, ni Storage sur les chemins de production ;
- le bac à sable **lit** le code de l'application, ne l'édite jamais : une expérience qui
  doit modifier un comportement existant en copie le code.

Quatre points d'accrochage seulement le relient à l'application : la route ci-dessus,
l'entrée du menu Admin, l'export de `sandboxFn`, et cette section.
---

## 14. Ce qui reste à construire

Le périmètre fonctionnel restant est décrit dans
`FunctionalRequirements.md` § 7. Vu du code :

| Chantier | Complexité | Ce que ça demande |
|---|---|---|
| Mode hors-ligne | Moyenne | `Settings(persistenceEnabled: true)` ne suffit pas — il faut décider ce qui reste lisible sans réseau (recettes validées, planning du jour) et ce qui doit échouer franchement (tout appel d'IA) |
| Partage externe (lien public) | Faible | Une route non authentifiée, donc une décision sur ce qu'un lien expose et pour combien de temps ; les Security Rules actuelles ne connaissent que des comptes nommés |
| Minuteur interactif depuis CookLang | Faible | Les durées sont déjà analysées (`timer_display.dart`) ; manquent un décompte et des notifications locales |
| Attestation du client Windows | — | Sans solution : la seule voie serait un jeton de débogage dans un binaire distribué. Le passage d'App Check en *exigé* prive donc le desktop de l'IA, et c'est documenté comme tel |

---

## 15. Annexe — Modération des images (spécification technique détaillée)

Le moteur, le schéma et les règles d'accès de la modération figurent aux chapitres 3, 4
et 6. Cette annexe en donne le détail : projection des paliers Vision, décision, promotion,
journalisation et coût.

> **Implémentée.** Moteur : **Google Cloud Vision** — SafeSearch Detection + Label
> Detection. Pendant fonctionnel : *Spécification — Modération des images* dans
> `FunctionalRequirements.md`.
>
> **Prérequis d'exploitation** : `vision.googleapis.com` doit être activée sur le
> projet. Sans elle, `analyseImage` lève, chaque image part en `pending`, et rien
> ne se publie — le comportement est correct, la cause est ailleurs.

### 1. Le terrain existant

- **`quarantine/{uid}/{fichier}`** — zone d'atterrissage, `storage.rules` autorise
  l'écriture au propriétaire approuvé, lecture par lui seul, 50 Mo.
- **`scanAndPromoteUploadFn`** (`callable/geminiCallables.ts`) — télécharge, appelle
  `scanUpload()`, copie vers `scans/{uid}/`, pose `quarantine_status` en métadonnée
  Storage, rend l'URL de téléchargement, supprime la source en dernier. Idempotente :
  le SDK Android rejoue un appel dont la connexion est tombée, et le serveur reçoit deux
  requêtes pour le même chemin. Une seule copie (`ifGenerationMatch: 0`) ; l'autre
  requête attend la fin de la première et relit sa promotion au lieu d'échouer.
- **`utils/uploadSecurity.ts` — `scanUpload()`** juge le contenant : taille, extension,
  type MIME, signature binaire, EICAR. Il ne regarde pas l'image.
- **`scans/{uid}/`** est déjà en `allow write: if false` : la promotion serveur est un
  schéma qui existe et qui marche. La modération le généralise, elle ne l'invente pas.

### 2. Les quatre destinations publiées

| Chemin publié | `targetKind` | Règle Storage |
|---|---|---|
| `covers/{bookId}/…` | `book_cover` | `allow write: if false` |
| `recipes/{recipeId}/…` | `recipe_illustration` | `allow write: if false` |
| `illustrations/{uid}/…` | `draft_illustration` | `allow write: if false` |
| `users/{uid}/…` | `free_recipe_cover` | `allow write: if false` |

Le client écrit dans `quarantine/{uid}/` (`image_moderation_service.dart`), appelle
`moderateAndPromoteImagesFn` avec la **destination voulue**, et reçoit soit l'URL publiée,
soit un état d'attente. Seul le serveur écrit dans ces quatre dossiers, par l'Admin SDK.

**L'origine déclarée par le client n'est jamais crue** (`moderation/origin.ts`, v0.23.8). Le
callable lisait `origin: "ai" | "asset"` dans la requête et approuvait l'image sans analyse :
n'importe quel compte publiait l'image de son choix. Désormais :

- `ai` n'est retenu que s'il est posé par le code serveur ; venant d'un client, il devient
  `user` et l'image est analysée ;
- `asset` n'est retenu que si l'empreinte SHA-256 du fichier est celle d'une couverture livrée
  avec l'application (`BUNDLED_ASSET_SHA256` : `mycreations.png`, `opensource.png`,
  `Secret.png`). Sinon l'image est analysée, et un `WARNING` le journalise. Le test
  `moderationOrigin` relit `kass_dalle/assets/` et échoue si une image change sans son
  empreinte.

Une image retenue `asset` ou `ai` passe par la même promotion sans analyse : verdict
`approved`, motif `bundled_asset` ou `ai_generated`. Sans cette exception, chaque création de
livre système remplirait la file de modération.

**La version analysée est celle qu'on publie.** L'envoyeur pouvait réécrire son fichier de
quarantaine entre l'analyse et la promotion, et `copy()` relisait la nouvelle version. La
génération Storage lue avant le téléchargement est épinglée (`pinnedGeneration`,
`moderation/promote.ts`) : téléchargement, promotion et conservation d'un refus portent sur
cette génération, et la copie échoue si elle a été remplacée. Le document `image_moderation`
la garde (`quarantine_generation`) pour une décision d'administrateur ou une relance. Un
document antérieur, sans ce champ, n'est approuvé par un administrateur que si le fichier n'a
pas été mis à jour après la création du document (`legacyFileMayHaveChanged`) ; sinon l'image
repasse en attente et `failed-precondition` demande de relancer l'analyse.

**Propriété de la destination.** `book_cover` et `recipe_illustration` visent le document d'un
autre (`ownerId`). `ownerId` doit être un identifiant de document : un « / », `.`, `..` ou
`__…__` est refusé en `invalid-argument` (`isValidDocumentId`). Avant toute analyse, `assertTargetOwnership` (`moderation/promote.ts`) lit
`books/{ownerId}` ou `recipes/{ownerId}` : seul son `created_by` ou un administrateur
(`isAdminAccount`, lu sur le document) publie. Document absent ou `ownerId` manquant : refus.
Un refus porte sur le lot entier, renvoyé en `permission-denied`, sans analyse facturée.

### 3. Firestore — `image_moderation/{moderationId}`

| Champ | Type | Rôle |
|---|---|---|
| `status` | `string` | `approved` / `rejected` / `manual_review` / `pending` |
| `uid` | `string` | qui a envoyé |
| `quarantine_path` | `string` | où le fichier attend |
| `quarantine_generation` | `string?` | génération Storage du fichier analysé (v0.23.8). La promotion et la conservation d'un refus copient cette génération, et échouent si le fichier a été réécrit depuis. Absent sur les documents antérieurs |
| `target_path` | `string` | où il ira s'il est approuvé |
| `target_kind` | `string` | `book_cover` / `recipe_illustration` / `draft_illustration` / `free_recipe_cover` |
| `owner_id` | `string?` | `bookId` ou `recipeId` selon `target_kind` |
| `mime_type`, `size_bytes` | `string`, `number` | contexte de diagnostic |
| `signals` | `map` | ce que le moteur a vu — voir §4 |
| `engine`, `engine_version` | `string` | qui a jugé, dans quelle version |
| `decision_reason` | `string` | clé de motif — voir §9 |
| `preview_url` | `string?` | vignette signée, pour l'écran d'administration |
| `created_at`, `decided_at` | `timestamp` | |
| `reviewed_by`, `reviewed_at`, `review_note` | `string?`, `timestamp?`, `string?` | revue humaine |
| `published_url` | `string?` | posé à la promotion |
| `rejected_path` | `string?` | image conservée après un refus, sous `rejected/{uid}/` — `null` si le déplacement a échoué |
| `correlation_id` | `string` | relie la ligne aux traces Cloud Logging |

`status: pending` est l'état « moteur injoignable » : ni approuvé, ni refusé, ni soumis à
un humain qui n'aurait rien à lire. Il se relance ; il ne se devine pas.

**Un document par image, y compris pour les approuvées.** L'écran d'administration doit
montrer ce que la modération laisse passer, pas seulement ce qu'elle bloque — et une
approbation dont on n'a gardé aucune trace ne se vérifie jamais.

**Règles Firestore** — lecture par `isAdmin()` ou `isOwner(uid)` (l'envoyeur doit voir
l'état de son image), **écriture serveur uniquement** (`if false`). Une décision de
modération que le client peut écrire n'est pas une décision.

### 4. La couture du moteur — un seul fichier à remplacer

```
functions/src/moderation/
├── engine.ts             # interface + résolution du moteur configuré
├── vision.ts             # adaptateur Cloud Vision (seul importateur du SDK)
├── decision.ts           # règles pures : signaux → état + motif
├── promote.ts            # quarantaine → destination, métadonnées, URL
└── moderateAndPromote.ts # le chemin complet : quarantaine → verdict → promotion
```

**`moderateAndPromote.ts` décide si une image envoyée par une personne devient
visible.** Son seul appelant est `moderateAndPromoteImagesFn`. Les découpes
d'illustrations du pipeline d'import ne passent pas par lui : `illustrations/store.ts`
les écrit directement sous `illustrations/{uid}/` (voir §7).

Deux refus y sont des **erreurs typées** et non des verdicts : `ImageFormatRejected`
et `QuarantineFileMissing`. Le callable les rend au client en `HttpsError`
(`failed-precondition`, `not-found`).

- **`ModerationSignals`** — forme neutre, imposée à tout moteur :
  `{ sexual: number, violence: number, medical: number, labels: {name, score}[] }`,
  scores normalisés `0..1`. Vision rend cinq paliers (`VERY_UNLIKELY` … `VERY_LIKELY`) :
  la projection sur cette échelle vit **dans `vision.ts`**, pas ailleurs. Les paliers
  d'origine sont conservés tels quels dans `signals` pour l'affichage — c'est ce que le
  moteur a réellement dit.
- **`ImageModerationEngine.analyse(bytes, mimeType): Promise<ModerationSignals>`** — la
  seule chose qu'un moteur doit savoir faire.
- **`decideModeration(signals, thresholds): { status, reason }`** — fonction **pure**,
  sans réseau, sans horloge. C'est là que vit l'arbitrage culinaire, et c'est ce qui se
  teste.

**`moderation/vision.ts` est le troisième fichier autorisé à importer un SDK de
fournisseur**, aux côtés de `gemini/client.ts` et `ai/anthropic.ts`.

**Et il l'importe DYNAMIQUEMENT.** Le fichier ne garde qu'un `import type`, effacé à la
compilation ; le SDK arrive par un `await import()` dans `visionClient()`, à la première
analyse réellement demandée. Un import statique a fait échouer un déploiement — *« User
code failed to load. Cannot determine backend specification. Timeout after 10000 »* : le
SDK tire gRPC et protobuf, et tout ce paquet se chargeait au démarrage d'`index.ts`, donc
pour la cinquantaine de fonctions qui partagent le même bundle, y compris celles qui ne
modèrent rien. Ce n'était pas seulement un risque au déploiement, c'était du démarrage à
froid subi partout. **Ne pas le repasser en import statique.**

**Ordre des règles, non commutatif — c'est lui qui porte le sens :**

1. `adult ≥ seuil_refus` → `rejected`, motif `sexual_explicit`. Aucun contexte ne le
   rattrape.
2. `violence ≥ seuil_alerte` **et** contexte culinaire fort → `approved`, motif
   `culinary_context`. Évalué **avant** le refus pour violence : une découpe de volaille
   est une scène violente pour le moteur, et l'arbitrage du projet est qu'elle passe.
3. `violence ≥ seuil_refus` → `rejected`, motif `violent_content`. Aucune recette n'a
   besoin d'une scène de violence certaine ; l'envoyer en revue obligerait un
   administrateur à la regarder pour conclure ce que les signaux disaient déjà.
4. `violence ≥ seuil_alerte` sans contexte → `manual_review`, motif
   `violence_no_culinary_context`.
5. `racy ≥ seuil_revue` sans contexte → `manual_review`, motif `suggestive_content`.
   **Jamais un refus.**
6. sinon → `approved`, motif `no_signal`.

**`adult` et `racy` sont deux critères, jamais un seul.** Ils ont été fusionnés par un
`max()`, au prétexte qu'une image « racy » ne devait pas peser zéro. Le prix s'est vu sur
une photo de violence conjugale : la victime portait un débardeur, `racy` a répondu
`VERY_LIKELY`, et le verdict est tombé en *« contenu sexuel explicite »*. Le refus était
mérité, le motif était faux — et c'est le motif qu'on lit à l'écran, celui qui oriente le
réglage des seuils, celui qui fait rater la vraie raison.

« Suggestif » et « explicite » ne demandent pas la même décision : le second refuse, le
premier fait au plus réfléchir. Les additionner supprimait cette distinction avant que la
règle puisse s'en servir. `racyReview` est haut par construction (`VERY_LIKELY`) : `racy`
se déclenche sur des tenues d'été ordinaires, et une file pleine de faux positifs n'est
pas relue.

Le classement de la violence passe **avant** celui du suggestif, pour la même raison : le
suggestif volerait le motif d'une image dont le vrai problème est ailleurs.

Le **contexte culinaire fort** est un compte de labels d'une liste fermée (viande,
volaille, poisson, planche, couteau de cuisine, ustensile, ingrédient, plat, cuisine…)
dont le score dépasse un seuil. Un seul label faible ne fait pas un contexte : c'est ce
qui distingue une cuisine d'une scène qui contiendrait un couteau.

### 5. Les seuils vivent dans Firestore, avec des défauts

`app_config/image_moderation` : seuils, liste des labels culinaires, moteur retenu, et un
interrupteur global. Même mécanique que `app_config/ai_routing_policy` — un seuil trop
strict se corrige en une minute, pas en un déploiement.

**Des défauts existent dans le code**, et c'est voulu. Ce n'est pas la contradiction de la
règle « pas de valeur de repli » : celle-ci vise les **données** qui doivent être exactes —
un prix, un taux de change — dont une constante périmée ferait mentir un montant. Un seuil
de modération est une **décision**, comme les plafonds de dépense quotidiens, qui protègent
eux aussi avant tout réglage. L'absence de document ne doit pas vouloir dire « aucune
modération ».

### 6. Ce que la modération ne partage pas avec le client

**Aucun jumeau Dart des règles de décision.** Elles n'existent que côté serveur : le client
n'affiche pas de verdict, il en reçoit un. Écrire le jumeau « par symétrie » ajouterait une
divergence possible sans rien rendre — c'est exactement ce qu'ont montré les règles de
créneau du planning, qui ont fini par **quitter** le client.

La fixture `test-fixtures/image_moderation_rules.json` est donc **serveur seul**, comme
`planning_slot_rules.json`, et rejouée par `functions/src/tests/` uniquement. Ligne à
ajouter au tableau des logiques dupliquées de `CLAUDE.md`, colonne Dart : « — ».

**Les libellés, eux, sont côté client** (§9) : ce sont des mots d'écran, pas des règles.

### 7. Cloud Functions

- **`moderateAndPromoteImagesFn`** (callable, `requireAuth`) — `{ items: [{ quarantinePath,
  targetKind, ownerId?, contentType?, origin? }] }`, de 1 à 25 images par appel. Chaque
  `quarantinePath` doit commencer par `quarantine/{uid de l'appelant}/`, sinon
  `permission-denied`. `origin` n'est transmis que s'il vaut `asset`, à vérifier sur
  l'empreinte ; `ai` est ignoré. Avant tout : contrôle de propriété de `book_cover` et
  `recipe_illustration` (créateur ou admin, sinon `permission-denied` pour le lot). Pour
  chaque image : téléchargement, `scanUpload()` (le format d'abord : inutile d'envoyer un
  exécutable renommé à un moteur d'analyse), origine retenue (`resolveImageOrigin`), puis
  `analyse()` → `decideModeration()` → écriture du document → promotion si `approved`.
  Rend `{ results: [{ moderationId, status, reason, url }] }`, dans l'ordre des `items`.
- **`reviewModeratedImageFn`** (callable, `isAdmin`) — `{ moderationId, decision, note }`.
  Promeut ou marque refusée, écrit `reviewed_by` / `reviewed_at`, journalise.
- **`retryPendingModerationFn`** (callable, `isAdmin`) — relance les `pending` restés en
  panne de moteur. Un état qui ne se relance pas est une fuite.
- **Le poste `_batch`** — un appel de plus d'une image est imputé à
  `image_moderation_batch`, un appel d'une seule image à `image_moderation`. Distinguer les
  deux postes est le seul moyen de vérifier que le groupage fait son office.
- **Les découpes d'illustrations d'un import ne sont pas modérées.** `recipeProcessor`
  appelle `extractAndStorePageIllustrations` (`illustrations/store.ts`), qui écrit chaque
  découpe directement sous `illustrations/{uid}/` par l'Admin SDK, sans quarantaine, sans
  `scanUpload()` et sans Cloud Vision. Le fichier source a déjà passé `scanAndPromoteUploadFn`
  à l'envoi, et la découpe est un JPEG encodé par Sharp dans la même fonction. Les images
  produites par l'IA (`generateRecipeIllustrationFn`, `generatePlatingImageFn`) écrivent au
  même endroit, de la même façon.
- **Les filtres locaux de l'atelier manuel.** `detectAndCropIllustrationsFn` passe chaque
  découpe à `assessCrop` (`gemini/illustrationQuality.ts`), qui écarte ce qui n'est pas une
  photographie : moins de 120 px de côté ou moins de 1,5 % de la page, rapport de forme
  au-delà de 4:1, ou presque blanc **et** sans couleur. Les deux conditions du dernier sont
  exigées ensemble : une photographie en noir et blanc a une chroma nulle, mais jamais une
  luminance moyenne de papier.
- **Aucun `catch` silencieux** : `logError(...)` avant tout retour dégradé, y compris sur
  la suppression best-effort du fichier de quarantaine.

### 8. Journalisation et rapports d'erreur

- **`ModuleType` gagne `"MODERATION"`** (`functions/src/logging.ts:18`, aujourd'hui
  `"IMPORT" | "IMAGE_DECODE" | "SEARCH" | "DESIGN"`). Sans lui, les traces de modération
  se rangeraient sous `IMPORT` et ne se filtreraient plus dans *Admin › Cloud Logging*.
- **`logInfo`** à chaque verdict : `correlationId`, `uid`, `status`, `decision_reason`,
  `engine`, `sizeBytes`, `targetKind`. Une décision de blocage doit pouvoir se rejouer
  depuis les traces seules.
- **`logError`** sur panne de moteur, refus de promotion, échec d'écriture — avec le motif,
  jamais un `catch` muet.
- **Le `correlationId` est stocké sur le document** (`correlation_id`, §3) : depuis l'écran
  d'administration, on remonte à la trace ; depuis la trace, on retrouve la ligne.
- **Côté client**, les trois issues et la panne passent par
  `_errorReportService.reportError(feature: 'imageModeration.…')`, avec `sizeBytes`,
  `mimeType` et `targetKind` en contexte — le même patron que
  `scanUpload.uploadAndPromote`, dont l'expérience a montré que sans la taille et le
  chemin, un refus ne se distingue pas d'un dépassement.

### 8b. Les images refusées sont conservées, pas détruites

`quarantineToRejected()` (`moderation/promote.ts`) copie l'octet vers
`rejected/{uid}/…` puis retire le reliquat de quarantaine, et rend le chemin —
ou `null` si la copie a échoué. Le document dit alors la vérité sur ce qui est
réellement consultable ; il ne promet pas une image qui n'existe pas.

`storage.rules` ouvre `rejected/` en lecture au seul `isAdmin()` : ce dossier contient ce
qu'on a jugé impubliable, et un jeton sans claim n'y a pas accès.

**La lecture de `quarantine/` est ouverte au même `isAdmin()`**, en plus du
propriétaire. Une image `manual_review` y attend : sans cette ligne, l'administrateur
qui doit trancher ne pouvait pas la voir — sauf s'il l'avait envoyée lui-même — et
l'écran de revue se réduisait à des scores. `ModerationEntry.previewPath` choisit la
source selon l'état : `rejected/` s'il existe, sinon la quarantaine pour `manual_review`
et `pending`, sinon `null`. Ce `null` est affiché en toutes lettres — « image non
conservée, refus antérieur à la conservation » — plutôt que laissé en blanc : un blanc
passerait pour une panne alors que le fichier a bel et bien été supprimé, et ne
reviendra pas.

Une image qui attend une décision se charge **d'office** ; un refus déjà prononcé reste
replié derrière un bouton. La distinction n'est pas cosmétique : dans le premier cas on
vient pour regarder, dans le second on parcourt un journal.

**Aucune URL n'est émise ni stockée.** L'écran lit les octets avec
`FirebaseStorage.ref(path).getData()`, donc avec les droits de l'administrateur
qui consulte. Appeler `getDownloadURL()` créerait un jeton permanent, partageable,
qui survivrait au retrait du rôle — exactement ce qu'il ne faut pas pour ce
contenu-là. Le rendu est un `Image.memory`, replié par défaut derrière un bouton :
un journal qu'on parcourt ne doit pas exposer sans prévenir.

La première version supprimait le fichier. C'était défendable et c'était faux :
sans l'image, un administrateur ne peut pas juger si le refus était fondé, et ce
sont les **faux refus** — une photo de rôti prise pour une scène violente — qu'on
a le plus besoin de voir. Une modération qu'on ne peut pas évaluer ne se corrige
jamais.

La rétention de `rejected/` reste ouverte (§15) : à trancher le jour où le volume
le justifie, par une règle de cycle de vie sur le bucket, jamais en effaçant les
décisions elles-mêmes.

### 9. Les libellés — pourquoi une image a été refusée

L'écran ne montre jamais de clé technique. `features/moderation/domain/moderation_labels.dart`
porte trois tables :

| Table | Contenu |
|---|---|
| `kModerationCriteria` | `adult` → « Contenu adulte », `racy` → « Suggestif », `violence` → « Violence », `medical` → « Médical », `spoof` → « Montage » |
| `kModerationLikelihoods` | `VERY_UNLIKELY` → « Très peu probable » … `VERY_LIKELY` → « Très probable » |
| `kModerationReasons` | `sexual_explicit` → « Refusée : contenu sexuel explicite. » ; `violence_no_culinary_context` → « À revoir : violence détectée sans contexte culinaire. » ; `culinary_context` → « Approuvée : contexte culinaire reconnu malgré une alerte de violence. » ; `no_signal` → « Approuvée : aucun signal. » ; `engine_unavailable` → « Sans verdict : moteur injoignable. » ; `manual_approved` / `manual_rejected` → décision d'un administrateur |

**Un motif retiré du code reste à la table**, exactement comme un poste de coût retiré
reste au catalogue : les décisions déjà prises sous cette clé cesseraient sinon de
s'expliquer. `test/moderation_labels_test.dart` garde la cohérence entre les clés servies
par le serveur et celles que le client sait nommer — une clé inconnue doit s'afficher
telle quelle et faire échouer le test, jamais disparaître en silence.

Les labels de Vision arrivent en anglais. Ceux de notre liste culinaire portent leur
libellé français (c'est notre liste) ; les autres s'affichent bruts avec leur score — les
traduire à l'aveugle inventerait une précision qu'on n'a pas.

### 10. Coûts et comptabilité

**La grille sait déjà facturer à l'unité.** `AiModelPricing` porte `imageOutputPerUnit`,
et `estimateAiCostUsd()` le multiplie par `imageOutputCount` — c'est ainsi que la
génération d'image est chiffrée. La modération n'a donc **pas** besoin d'une grille à part,
ni du repli « appels sans montant » : le montant est calculable, il doit être affiché.

- **Un champ voisin, pas un détournement** : `analyzedImagePerUnit` s'ajoute à
  `AiModelPricing` et se somme dans `estimateAiCostUsd`. Une image *produite* et une image
  *analysée* sont deux produits à deux prix ; les faire passer par le même champ ferait
  mentir le reporting le jour où l'un des deux bouge. Champ optionnel : les documents
  existants ne le portent pas, il vaut zéro.
- **Deux unités par image** — SafeSearch et Label sont facturés séparément. C'est le
  nombre d'unités, pas d'images, qui est enregistré.
- **`freeUnitsPerMonth` sur l'entrée de tarif** : le fournisseur offre mille unités par
  mois. Les lignes d'appel restent **brutes** — ainsi elles ne dépendent pas de l'ordre
  dans lequel on les relit, et deux appels simultanés ne se disputent pas un compteur. La
  déduction se calcule **au mois**, dans l'écran des coûts, et s'affiche en ligne à part.
  Un mois à zéro doit se lire « mille unités offertes ont couvert la dépense », pas
  « rien n'a été analysé ».
- **Le poste s'ajoute aux trois endroits, dans le même commit** : `ctx.feature`,
  `ROUTABLE_FEATURES`, et `feature_catalog.dart` (`kFeatureCatalog` **et**
  `kFeatureProcess`) — avec sa variante `_batch`.
- **`ai_usage` et `ai_daily_spend`** reçoivent la ligne comme n'importe quel appel : c'est
  ce qui alimente *Admin › Dépense par utilisateur*, donc le nombre d'analyses demandées
  par personne.
- **Hors plafond quotidien.** Un plafond atteint doit empêcher de *dépenser*, jamais de
  *publier une image légitime* : sinon le contrôle punit celui qu'il protège. L'appel est
  compté, chiffré, affiché — et exclu de `BudgetExceededError`. L'écran de dépense le
  signale, faute de quoi l'écart entre « dépensé » et « décompté du plafond » passera pour
  un bug.
- **Ajouter la ligne à la fixture `ai_pricing.json`** avant d'écrire le code : elle est
  rejouée par les deux suites, et c'est la seule barrière contre un écart de tarif
  silencieux.

### 11. Le moteur au choix des moteurs d'IA

Vision est le seul choix acceptable aujourd'hui, et le poste figure quand même à
`ROUTABLE_FEATURES` — dans un groupe **« Modération »** propre, pas dans
« Illustrations — détection », dont les postes lisent une image pour l'extraire et non pour
la juger.

- `resolveProvider` apprend un troisième fournisseur, `vision`, et le poste déclare la
  liste des fournisseurs qu'il accepte. L'écran rend le sélecteur **inactif** avec la
  raison affichée plutôt que de masquer le poste : un poste absent de l'écran est un poste
  qu'il faudra redéployer pour faire bouger.
- **La modération ne passe pas par `callModel`.** Celui-ci raisonne en jetons et en
  messages ; Vision rend des paliers. C'est la **politique** qui est partagée — un document
  Firestore, un écran — pas l'exécution. `moderation/engine.ts` lit la même politique et
  choisit son adaptateur.
- **La clé Vision vit dans Secret Manager**, comme les autres, et **toute fonction qui
  appelle un moteur déclare toutes les clés qu'elle peut avoir à utiliser**. C'est la règle
  née de la panne de v0.19.79 : un secret non déclaré n'est pas monté, le repli s'applique
  en silence, et l'écran continue d'affirmer que la clé est là.

### 12. Client Flutter

**Recette générée par l'IA — section photos.**
`search/presentation/generated_recipe_illustrations.dart` ajoute un onglet *Photos*
à `GeneratedRecipeScreen`, dans ses **deux** dispositions (étroite à quatre onglets,
large à trois). Un seul `_illustrationsTab()` les sert : deux copies auraient
divergé, et c'est l'onglet le plus facile à oublier.

La recette n'a pas encore d'identifiant, et aucune des deux voies n'en a besoin —
`generateRecipeIllustration` part du titre et d'un prompt, l'envoi d'une photo se
range sous l'utilisateur. Les URL sont tenues en mémoire dans `_imageUrls` et
partent avec la recette : `_buildCurrentRecipe()` ne code plus `imageUrls: const []`.

Une photo envoyée passe par la modération ; une image produite par l'IA en est
dispensée, et le serveur la dépose lui-même sous `illustrations/{uid}/` par l'Admin
SDK — la fermeture en écriture des dossiers publiés ne l'affecte pas.

- **`features/moderation/`** — `data/moderation_repository.dart`,
  `domain/moderation_entry.dart`, `domain/moderation_labels.dart` (§9), `presentation/`.
- **Les quatre appelants d'upload** (`book_repository`, `recipe_repository`,
  `draft_review_service`, `auth_repository`) écrivent en quarantaine puis appellent la
  promotion. Ils reçoivent trois issues au lieu d'une, et l'écran doit les rendre :
  publiée, en attente, refusée.
- **`pendingModerationCountProvider`** — `StreamProvider<int>` sur `image_moderation`
  filtré `status == manual_review`, `limit(99)`. La file d'attente est courte par
  construction : un flux suffit, un compteur maintenu par trigger serait une donnée dérivée
  de plus à tenir juste. Le badge ne compte **pas** le journal entier.
- **Badge** — `_AdminIcon` dans `core/presentation/app_shell.dart`, sur le même patron que
  `_DraftsIcon` (masqué à zéro, `Semantics` explicite : « 3 » seul ne dit rien à l'oreille).
  Rappel du même compte sur la tuile *Modération* de `admin_hub_screen.dart`.
- **`AppRoutes.adminModeration` → `/admin/moderation`**, garde `isAdmin`, écran
  `admin_moderation_screen.dart` :
  - liste de **tous** les états, filtres par état et par date, tri par date ;
  - par entrée : vignette, envoyeur, date, destination, moteur ;
  - **les cinq critères avec leur libellé et leur palier en français**, les labels retenus
    comme contexte culinaire mis en évidence ;
  - **la phrase de motif** sous l'identification, tirée de `kModerationReasons` ;
  - **Approuver** / **Refuser** (avec motif) sur les entrées en attente, **Relancer** sur
    les `pending` ;
  - lien vers la trace Cloud Logging par `correlation_id`.

### 12b. Index Firestore

Le journal filtre par état ET trie par date : c'est une égalité sur un champ plus un tri
sur un autre, donc un **index composite** obligatoire. Sans lui, l'écran ne dégrade pas —
il échoue, et le filtre « Publiées » rend « Journal de modération illisible ».

```
collectionGroup: image_moderation — status ASC, created_at DESC
```

Déclaré dans `firestore.indexes.json`, déployé avec les règles par `deploy.ps1` ou par le workflow « Déploiement ». Le même
index sert les quatre filtres d'état, avec ou sans fenêtre de temps. Le badge n'en a pas
besoin : une égalité seule, sans tri, tient sur l'index automatique.

### 13. Tests

| Quoi | Où |
|---|---|
| Règles de décision, ordre compris | `functions/src/tests/moderationDecision.test.ts` + fixture |
| Violence + contexte culinaire → approuvée, sans file | même fixture, cas nommé |
| Sexuel explicite → refusée quel que soit le contexte | même fixture |
| Projection des cinq paliers Vision sur `0..1` | `functions/src/tests/moderationDecision.test.ts`, sur la fixture `image_moderation_rules.json` |
| Moteur en panne → `pending`, jamais publié | aucun test automatisé de `moderateAndPromote` |
| Coût d'un appel Vision, quota mensuel déduit | `ai_pricing.json` + `test/ai_pricing_test.dart` |
| Poste présent aux trois endroits | `test/feature_catalog_test.dart` |
| Toute clé de motif servie a un libellé | `test/moderation_labels_test.dart` |
| Badge masqué à zéro, affiché sinon | `test/widgets/` |
| Repository : lecture du journal, filtres, décision admin | `test/repositories/`, `fake_cloud_firestore` |

### 14. Livraison en quatre lots

1. **Fondation** — les quatre portes passent par la quarantaine, destinations fermées en
   écriture, collection et promotion serveur. Aucune analyse. Rien ne change à l'usage.
2. **Verdict** — Vision, seuils, quatre états, poste de coût aux trois endroits, tarif en
   fixture, `ModuleType` et traces.
3. **Revue** — écran Administration › Modération (tous états), libellés, badge, journal des
   décisions.
4. **Existant** — backfill des images déjà en ligne, ou décision assumée de ne pas le
   faire.

### 15. Ce qui reste ouvert

- **Le backfill de l'existant** (lot 4).
- **La latence perçue** : une illustration s'affiche aujourd'hui à la seconde. Avec la
  quarantaine, elle attend un aller-retour serveur. C'est un changement d'usage visible, à
  mesurer sur le lot 1 — avant que l'analyse ne s'y ajoute.
- **La rétention du journal** : un document par image, gardé indéfiniment. À trancher le
  jour où le volume le justifie — pas avant, et jamais en effaçant les décisions.
