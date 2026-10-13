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
`gemini/client.ts`, `ai/anthropic.ts` et `moderation/vision.ts` — le premier et le
dernier par un `await import()` **dynamique**. Le SDK Vision tire gRPC et protobuf : le
charger au démarrage d'`index.ts` fait dépasser le budget de dix secondes du déploiement et
ralentit le démarrage à froid des cinquante fonctions du bundle. `@google/genai` coûte une
centaine de millisecondes à l'import (contre 4 ms pour l'ancien `@google/generative-ai`) :
`gemini/client.ts` ne l'importe qu'en `import type` au niveau module et le charge au premier
appel de modèle (`loadSdk()`, promesse mémorisée, oubliée si l'import échoue).

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
`TAGGING_PROMPT` (`gemini/tagging.ts` → `tagAndNormalize`, ~3 600 jetons, rôle du repas,
protéine et féculent inclus) : les deux plus gros prompts du projet, sur les deux postes les plus appelés.
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
| Partage entrant (Android) | aucun paquet — `MethodChannel` `dev.kassbi.kass_dalle/share` de `MainActivity` | — (Android seul, §12) |
| Parsing CookLang | implémentation maison, jumelée avec `functions/src/cooklang/` | — |
| **IA côté client** | **aucune** — pas de SDK de fournisseur dans le binaire ni dans le bundle web | — |

Côté Cloud Functions (Node 22, TypeScript) :

| Composant | Paquet |
|---|---|
| Runtime Functions | `firebase-functions` ^7.2.5, `firebase-admin` ^12.7.0 |
| Gemini | `@google/genai` ^2.28.0, chargé au premier appel |
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
│   ├── preferences/{prefId}                       ← book_order, recipe_search_scope, explore_filters, meal_staples, planning_refusals
│   ├── planning_runs/{runId}                      ← générations de planning, serveur seul
│   └── shopping/current                           ← panier de courses personnel, titulaire seul
├── user_profiles/{uid}/                           ← nom public, écrit par le serveur seul
├── books/{bookId}/
├── recipes/{recipeId}/
│   ├── annotations/{annotationId}/
│   └── origine/texte                              ← texte d'avant traduction, écrit par le serveur seul
├── recipe_ratings/{uid}_{recipeId}/
├── groups/{groupId}/
├── invitations/{invitationId}/                    ← invitations par e-mail, écrites par le serveur seul
├── invitation_sends_daily/{uid}_{AAAA-MM-JJ}/     ← compteur du plafond d'envois d'invitations
├── member_email_search_daily/{uid}_{AAAA-MM-JJ}/  ← compteur du plafond de recherches de membre par adresse
├── processing_jobs/{jobId}/
├── dead_letters/{jobId}/
├── planned_meals/{mealId}/                        ← porteur du contexte (personne ou groupe, date)
├── meal_suggestions/{suggestionId}/               ← suggestions de plats des membres d'un groupe à son propriétaire
├── planning_config/{uid}/
├── planning_reach/{uid}/                          ← plannings lisibles par uid (personnels et de groupe), écrit par le serveur seul
├── nutrition_ingredients/{ingredientId}/
├── nutrition_units/{unitId}/
├── meal_staples/{stapleId}/                       ← garnitures simples, référentiel partagé
├── image_moderation/{moderationId}/
├── ai_usage/{id}/                                 ← une ligne par appel
├── ai_usage_monthly/{AAAA-MM}/
├── ai_daily_spend/{uid}_{AAAA-MM-JJ}/
├── scan_spend/{scanId}/                           ← compteur et plafond d'un import de livre
├── url_import_daily/{uid}_{AAAA-MM-JJ}/           ← compteur du plafond d'imports par lien
├── web_search_daily/{uid}_{AAAA-MM-JJ}/           ← compteur du plafond de recherches web
├── web_search_cache/{sha256}/                     ← cache partagé des recherches web, 7 jours
├── ai_reconciliation_monthly/{AAAA-MM}/
├── token_usage/{uid}/
├── error_reports/{id}/
├── tickets/{ticketId}/                            ← tickets des membres, écrits par le serveur (sauf seen_by_author_at)
├── ticket_quotas/{uid}_{AAAAMMJJ}, _global_{AAAAMMJJ} ← compteurs du plafond quotidien des tickets, serveur seul
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
| `free_recipe_cover_url` | `String?` | Couverture choisie pour « Mes recettes libres ». Écrite par `auth_repository.dart` : l'image passe par la modération, qui la publie sous `users/{uid}/free_recipe_cover_*.jpg` ; le fichier précédent est supprimé au remplacement. Les règles n'admettent que `null` ou l'adresse de téléchargement exacte de la modération, `users%2F{uid du document}%2Ffree_recipe_cover_{n}.{jpg|jpeg|png|webp}` dans le bucket du projet, sans `..`, `%2E` ni `%25` (`coverUrlOk`, 500 caractères au plus, v0.23.48) ; `syncUserClaims` écarte toute autre valeur à la recopie dans `user_profiles` (`publicCoverUrl`) |
| `import_illustrations` | `Boolean` | Défaut de la case « Extraire les illustrations » de l'écran d'import. Absent = `true`. Écrit par **Préférences** (`features/auth/presentation/preferences_screen.dart`), lu par `UserPreferencesRepository`. C'est un **défaut**, pas un verrou : chaque import peut le changer pour lui seul, sans que ce choix remonte ici. |

**Nom préféré et nom Google :** `display_name` est réécrit à chaque connexion depuis le compte
Google — il ne peut pas servir de nom modifiable. `preferred_name` est un champ libre, et son
absence n'est jamais comblée par une écriture : la valeur par défaut se **calcule** à la lecture
(`AppUser.defaultPreferredName`). Figer le prénom dans Firestore le laisserait périmé le jour où le
compte Google change de nom.

**Rôle à la création :** forcé à `pending` **par les règles**, avec `is_revoked == false`,
`email == request.auth.token.email` et `request.auth.token.email_verified == true` (adresse
vérifiée par le fournisseur d'identité, toujours vrai pour un compte Google). Le client ne
choisit ni le rôle, ni l'identité. Un rôle absent
ou inconnu est relu comme `pending` par `AppUser.fromFirestore` : le repli ferme.

**Exception décidée par le serveur — l'invitation par e-mail :** le déclencheur
`applyEmailInvitation` (`triggers/invitationSignup.ts`, `onDocumentCreated` sur `users/{uid}`)
lit l'adresse du compte **Auth** (`getUser`), exige `emailVerified`, et cherche une invitation
active de même `email_key` (§3.5 ter). S'il en trouve une et que le document est encore
`pending` et non révoqué, et que l'administrateur du dernier envoi (`last_sent_by`, sinon
`invited_by`) est encore `admin` et non révoqué (tous deux relus dans la transaction), il écrit
`role` (`reader` ou `editor`), ajoute l'uid à `member_ids` du groupe et passe l'invitation à
`accepted`, dans une seule transaction. Un invitant destitué ou révoqué : rien n'est appliqué,
le compte reste `pending` et l'invitation inchangée. Le fondateur n'est jamais concerné. Le document est toujours créé `pending` par
le client : le rôle arrive une à quelques secondes plus tard. Seules les invitations de compte
neuf (`target` absent ou `new`) s'appliquent ici ; une invitation de compte révoqué ne nomme
jamais un compte qui naît.

**Seconde exception — le retour d'un compte révoqué invité par e-mail :** le déclencheur
`applyRevokedInvitation` (même fichier, `onDocumentUpdated` sur `users/{uid}`) ne réagit qu'à
une écriture où le compte est révoqué avant et après, et où `last_seen_at` change
(`isRevokedSignIn`) : c'est l'écriture de connexion du client (`AuthRepository._upsertUser`),
que les règles permettent au titulaire révoqué, puisqu'elle ne touche ni `role` ni `is_revoked`.
Il vérifie d'abord qu'une invitation de retour active vise ce compte (requête `target_uid ==
uid`, statut et expiration lus dans le code : index automatique d'un seul champ, aucun index
composite) ; sans elle, il s'arrête sans appeler Auth. Il lit ensuite l'adresse **Auth** (`getUser`, `emailVerified` exigé) et cherche l'invitation active de
même `email_key` qui vise **ce** compte (`target: "revoked"`, `target_uid == uid`). Dans une
transaction, il relit : le compte toujours révoqué et non fondateur, l'invitant (dernier envoi)
encore `admin` non révoqué, et l'appartenance de l'invitant au groupe. Il écrit alors `is_revoked: false` et le `role` de l'invitation,
ajoute l'uid à `invited_ids` du groupe — **jamais** à `member_ids` : l'invité accepte dans
Groupes familiaux —, et passe l'invitation à `accepted` avec `group_invite`. Il n'écrit rien au
groupe si le compte y est déjà membre ou invité, ou si 50 invitations y attendent (plafond de
`boundedGroup`) ; groupe supprimé : rôle seul, `group_missing: true` ; invitant qui n'est plus
ni propriétaire ni membre du groupe : rôle seul, `group_invite: "missing"`, `group_missing:
false`. Le statut `accepted`, relu
dans la transaction, empêche une seconde application. L'écriture réveille `syncUserClaims`
(claims `revoked: false` et nouveau rôle, sans couper la session) et `syncPlanningReachOnRole`.

**Invitation de retour sans objet.** Quand `is_revoked` passe de `true` à `false`,
`syncUserClaims` annule les invitations de retour encore actives qui visent le compte
(`cancelStaleReturnInvitations`, `triggers/invitationSignup.ts`) : `status: "cancelled"`,
`cancelled_by: "system"`, `cancelled_at`, et `last_error` « Accès rétabli à la main :
invitation sans objet. » (rétablissement dans l'onglet Comptes) ou « Accès rétabli par une
autre invitation : invitation sans objet. » (une invitation de retour acceptée par ce compte à
moins de 60 s du rétablissement). Laissée active, une telle invitation rétablirait le compte
après une nouvelle révocation. Celle qu'`applyRevokedInvitation` applique est déjà `accepted`,
dans la transaction qui rétablit le compte, et n'est pas reprise. Chaque invitation est relue
dans sa transaction, avec `users/{uid}` : si le compte est de nouveau révoqué
(`is_revoked === true`), rien n'est annulé, et seule une invitation envoyée au plus tard au
rétablissement (`last_sent_at`, à défaut `created_at`, ≤ heure de l'événement) est annulée — une
invitation envoyée ou renvoyée après répond à une révocation postérieure
(`isStaleReturnInvitation`, `invitations/rules.ts`). Une erreur est journalisée et n'arrête pas
les autres. Aucune fonction
déployée de plus. Il n'existe pas de date de révocation sur `users/{uid}` : `applyRevokedInvitation`
ne compare donc pas `last_sent_at` à la révocation, et cette annulation tient lieu de garde.

**Écran de révocation.** `/login?revoked=true` dit « Votre accès a été révoqué. Contactez
l'administrateur. Vous avez reçu une invitation ? Reconnectez-vous avec le compte Google de
l'adresse invitée. » Le bouton passe par `AuthRepository.signInAgainAfterRevocation`, qui
appelle `signInWithGoogle(forceAccountChooser: true)` : sur le web, la fenêtre Google s'ouvre
directement avec `prompt: select_account` ; sur mobile et desktop, la session est fermée puis la
connexion silencieuse (`attemptLightweightAuthentication`) est sautée. Le choix du compte
s'affiche donc partout. Dans les deux cas, `_upsertUser` écrit `last_seen_at`.
L'écran se ferme seul quand le document n'est plus révoqué (le routeur suit `appUserProvider`).

**Connexion web par redirection.** Quand la fenêtre surgissante échoue, `signInWithGoogle`
retombe sur `signInWithRedirect`, et la page se recharge. Au démarrage web, `main.dart` appelle
`AuthRepository.completeRedirectSignIn` : `getRedirectResult`, puis `_upsertUser` si une
connexion revient. Sans cet appel, un compte neuf n'avait pas de document `users/{uid}` et
restait sur l'écran de connexion, et un compte révoqué n'écrivait pas `last_seen_at`. Un échec
est rapporté (`auth_web_redirect_result`).

**Jeton en retard sur le document.** À sa reconnexion, le compte reçoit un jeton dont le claim
`revoked` vaut encore `true` : les règles croient un jeton qui confirme une révocation. Le
client renouvelle le jeton quand ses claims sont en retard (`tokenLagsBehind` : jeton révoqué
alors que le document ne l'est plus, ou rôle du jeton différent du rôle nommé du document), par
`TokenClaimsAligner` dans `AuthRepository.watchAppUser`. Une version du document en retard
attend au plus deux renouvellements à 1,5 s d'intervalle (moins de 3 s), puis est émise ; sans
cette attente, l'accueil ouvert par le routeur démarrerait ses lectures avec l'ancien jeton.
Si le jeton n'a pas suivi, l'alignement continue après l'émission (huit renouvellements en
tout), et le document est émis une seconde fois quand le jeton suit, pour que les écrans qui
lisent le compte relancent leurs lectures. Au-delà, l'écart est rapporté
(`auth_token_claims_lag`). L'alignement a lieu une fois par session et par état du compte
(uid, rôle, révocation) : un écart qui persiste n'est pas retenté à chaque version du document.

**Bootstrap Admin :** le déclencheur `enforceFounderRole` (`triggers/founderRole.ts`) rend le rôle
`admin` au seul compte fondateur, identifié par l'adresse du compte **Auth** (`getAuth().getUser`)
et non par le champ `email` du document, qu'un client a pu écrire. Depuis v0.23.48, l'adresse
doit être vérifiée (`emailVerified`) et le compte rattaché à une connexion Google
(`providerData[].providerId == 'google.com'`) : `isFounderAccount`, qui sert aussi au
multiplicateur de plafond (`founderUid`, `ai/budget.ts`). Les règles exigent l'équivalent sur le
jeton (`isFounder()` : `email_verified` et `firebase.sign_in_provider == 'google.com'`). Il est *idempotent* et
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
base : un profil absent se recrée à la première écriture du compte. `backfillUserProfilesFn`,
qui appliquait la même fonction à tous les comptes existants, est retiré depuis la v0.23.23 :
lancé en production, son travail est fait.

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
| `id` | `String` | ID auto-généré Firestore, sauf livres système : `kassdalle_{uid}`, `libres_{uid}`, `secretes_{uid}`, `web_{uid}` (repli `web2_{uid}`) |
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
| `is_private` | `bool` | Livre réservé à son créateur. Basculé depuis le formulaire de livre ; verrouillé à `true` sur « Mes Recettes Secrètes » (`__secretes`). « Mes recettes du web » (`__web`) est créé à `true` et reste basculable. `onBookWritten` recopie la valeur sur toutes les recettes du livre |
| `created_by` | `String` | UID de l'utilisateur créateur |
| `created_at` | `Timestamp` | Date de création |
| `updated_at` | `Timestamp` | Date de dernière modification |
| `source_file_url` | `String?` | URL du fichier source IA |
| `source_file_name` | `String?` | Nom du fichier source |
| `ai_processed_at` | `Timestamp?` | Date du traitement IA |

**Les quatre livres système** se reconnaissent à un tag interne (préfixe `__`, refusé dans le
formulaire de livre) : « Mes créations Kass'Dalle » (`__kassdale_ia`), « Mes recettes libres »
(`__libres`), « Mes Recettes Secrètes » (`__secretes`) et « Mes recettes du web » (`__web`). Ils
se renomment mais ne se suppriment pas : `BookRepository.deleteBook` refuse, et les règles
Firestore aussi (`isSystemBook`, `keepsSystemTags`, §4). Ils sont posés à l'ouverture de la
bibliothèque (`ensureSystemBooks`), pour un éditeur ou un administrateur seulement : un lecteur ne
crée pas de recette, il n'a pas besoin des livres qui les reçoivent (les règles lui refusent
d'ailleurs la création d'un livre), et il garde ceux qu'il avait. Les trois premiers sont créés
par le client. Le serveur crée aussi ceux qui manquent à tout compte approuvé, lecteurs compris
(`ensureSystemBooksFor`, `books/systemBooks.ts`) : `syncUserClaims` quand le compte reçoit
l'accès (`gainsAccess` : approbation d'un compte en attente, invitation par e-mail acceptée, levée d'une révocation ; un échec est
journalisé et n'empêche pas l'accès), et la reprise *Admin › Backfills › Livres système des
comptes* (`backfillSystemBooksFn`, §7.10) pour les comptes approuvés avant la v0.23.50. Ces trois livres
ont un identifiant fixe, `kassdalle_{uid}`, `libres_{uid}` et `secretes_{uid}` (`systemBookId`
côté serveur, `_createSystemBook` côté client) : à l'approbation d'un éditeur, le déclencheur et
l'application peuvent tourner en même temps, et un livre système en double ne se supprime pas.
Les livres créés avant la v0.23.50 gardent leur identifiant aléatoire. Le serveur crée en
transaction et retrouve un livre déjà posé par le client ; le client aussi, et ne réécrit jamais
un livre existant : hors ligne, un `set` mis en file aurait remplacé à la reconnexion un livre que
le cache ne montrait pas, `is_private` compris. Pour cette transaction, les règles laissent un
éditeur lire son propre identifiant fixe encore absent (`ownSystemBookId`). Un identifiant occupé
par un autre document (étranger au compte, ou livre sans le tag) est journalisé et n'empêche pas
la création des autres livres. Les règles réservent ces identifiants au compte qu'ils nomment
(§4). Un livre système reste reconnu à son tag, quel que soit son identifiant. Mêmes
champs que le client, couverture vide : l'écran affiche
alors l'image du livre système (`Book.defaultCoverAsset`), et le client dépose la couverture à
la prochaine ouverture de la bibliothèque par leur propriétaire, s'il est éditeur ou administrateur ; pour un lecteur, `url_couverture` reste vide. « Mes recettes du web » est créé **par le serveur** (`findOrCreateWebBook`,
`pipeline/urlImport.ts`) : par `ensureWebBookFn` (`callable/urlImportCallable.ts`,
`requireEditor`), appelée par `ensureSystemBooks` avec les autres livres, et à défaut au premier
import par lien. Identifiant déterministe `books/web_{uid}` (deux appels simultanés ne créent
pas deux livres), `is_private: true`, auteur « Kass'Dalle ». Sa couverture,
`assets/FromTheWeb.png` (`Book.defaultCoverAsset`, empreinte dans `moderation/origin.ts`), est
posée par le client comme celle des trois autres (`_uploadAssetCover`), dès que le livre n'en a
pas : un livre déjà créé par un import la reçoit à l'ouverture suivante de la bibliothèque, sans
backfill. Le client ne peut créer ni un livre d'identifiant `web_…`, ni un livre portant le
tag `__web` (règles, §4) : sans cela, un éditeur créait `books/web_{uid d'un autre}`, public et à
son nom, et les brouillons importés de l'autre compte y tombaient. Le serveur vérifie en plus le
document trouvé (`isOwnWebBook` : `created_by` du compte et tag `__web`) ; un document étranger
n'est jamais réutilisé : le livre du compte est cherché par son tag, sinon créé sous le second
identifiant déterministe `web2_{uid}`, en transaction (deux appels simultanés ne créent pas deux
livres), et l'incident est journalisé une fois, à cette création (`logError`). Les règles
refusent au client tout identifiant `web…_` (`web_`, `web2_`).

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
| `langue` | `String` | Code ISO 639-1 de la langue de la recette. Vaut `fr` pour toute recette importée, traduite ou non |
| `langue_origine` | `String?` | Code ISO 639-1 de la langue de la page, posé par `recipeProcessor` **seulement sur une recette traduite** à l'import (v0.23.16). Absent = écrite en français : les recettes existantes n'ont rien à reprendre. Le client le lit (`Recipe.langueOrigine`, `isTranslated`) et ne l'écrit jamais : `toFirestore` l'omet, une mise à jour le laisse en place, une copie ne le reprend pas. Le texte d'origine vit dans `recipes/{id}/origine/texte` (§3.6 bis). Le texte collé traduit (`extractRecipeFromTextFn`) ne le pose pas : la callable le renvoie à l'écran seulement |
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
| `allergens` | `Map?` | Allergènes majeurs de la recette — les 14 de l'annexe II INCO — **déduits sans appel de modèle** des `allergens` du référentiel (§3.10). Écrit par le serveur seul (`onRecipeWritten` → `syncRecipeAllergens`, et le backfill « Allergènes des ingrédients et des recettes ») — par convention du client : comme pour `nutrition`, les règles de `recipes` ne restreignent pas les champs qu'un créateur écrit ; le client le lit (`Recipe.allergens`, `RecipeAllergens`) et ne l'écrit jamais : `toFirestore` l'omet, une mise à jour partielle le laisse en place, une copie ne le reprend pas. Absent tant qu'aucun calcul n'a eu lieu — la fiche n'affiche alors rien. Voir structure ci-dessous |
| `estimated_times` | `Map?` | Durées de préparation et de cuisson **estimées par le modèle** pour une recette qui ne les donne pas (poste `time_estimate`). Hors du CookLang : ce n'est pas ce que dit la recette. **Écrit par le serveur seul** (`onRecipeWritten` → `syncRecipeEstimatedTimes` ; le backfill « Durées estimées », qui a repris les recettes antérieures, est retiré en v0.23.52) ; les règles de `recipes` refusent au client de le poser à la création et de le changer ou l'effacer à une mise à jour, administrateur compris (§4). Le client le lit (`Recipe.estimatedTimes`, `RecipeEstimatedTimes`) ; `toFirestore` l'omet, une copie ne le reprend pas (le serveur réestime la copie). Une durée lue (`tags.prep_time`, `tags.cook_time`, métadonnée `>> temps_preparation:` / `>> temps_cuisson:`) garde la priorité. Absent tant que la recette n'a jamais manqué d'une durée. Quand les deux durées sont lues, le champ est **vidé** (`prep` et `cook` à `null`) et garde l'empreinte, pas supprimé. Voir structure ci-dessous |
| `fidelity_level` | `string?` | `avertissement` ou `rupture` — verdict du contrôle de fidélité entre la transcription et le balisage. Absent quand tout concorde. Affiché par `FidelityBanner` sur le seul écran de **relecture d'un brouillon**, jamais sur la recette : c'est un outil pour décider, pas pour cuisiner. **Effacé par `validateDraft`** — valider, c'est avoir relu et tranché ; garder le doute reviendrait à le conserver sans que personne puisse plus le lever, et à rouvrir le débat au premier écran qui l'afficherait. Une ligne isolée (l'écran de relecture) laisse un brouillon à réserve de côté ; une **validation en lot** (`WorkQueueScreen`, depuis le 28 septembre 2026) avertit puis le valide quand même si l'utilisateur confirme — voir `DraftValidationPlan.validatableInBatch` |
| `fidelity_findings` | `List<Map>?` | Ce qui a été constaté : `{message, items?}`. Les éléments vivent à part de la phrase parce qu’ils s’affichent en **liste à puces** — sept mots mal lus concaténés forment un pavé qu’on ne relit pas, et une alerte qu’on ne relit pas ne sert à rien. `FidelityFinding.listFrom` lit aussi l’ancien format (liste de chaînes) |
| `nutrition_catch_up_attempts` | `int?` | Tentatives de rattrapage planifié consommées pour la liste d'ingrédients courante (5 au plus). Remis à 0 par `syncRecipeNutrition` dès qu'un changement d'entrée relance le calcul. C'est ce compteur qui transforme un échec permanent en dépense finie |
| ~~`nutrition_stale`~~ | — | **Retiré.** Bornait les réveils que `onRecipeWritten` se provoquait lui-même. La garde porte désormais sur ses entrées : plus de réveil, plus de drapeau. Peut subsister sur d'anciens documents, plus rien ne le lit |
| ~~`nutrition_enrichment_attempts`~~ | — | **Retiré.** Compteur de rattrapages qui ne bornait rien : il n'était lu que dans la branche où la nutrition existait déjà, jamais pendant la salve de réveils. Peut subsister sur d'anciens documents, plus rien ne le lit |
| `source_recipe_id` | `String?` | Recette d'origine quand ce document est une copie/amélioration. Nul pour un brouillon issu d'un scan |
| `source_url` | `String?` | Adresse de la page web d'une recette importée depuis un lien, **normalisée** (`normalizeUrl`, `web/urlGuard.ts` : sans fragment ni paramètres de suivi `utm_*`, `fbclid`…, paramètres triés, hôte en minuscules, sans barre finale). Écrite par `recipeProcessor` ; c'est la valeur que `importRecipeFromUrlFn` compare pour le doublon (`created_by` + `source_url`, deux égalités servies sans index composite). Le client ne la saisit jamais ; il la réécrit telle quelle à une mise à jour et la recopie sur une **copie** (`copyRecipeAsDraft`, décision du 11 octobre 2026). Les règles refusent toute autre écriture (`sourceUrlAccepted`, `!changes('source_url')`, §4) ; une copie n'est acceptée que si la recette copiée est lisible par l'appelant (`canReadRecipe`). Absent sur toute autre recette |
| `source_site` | `String?` | Nom du site de `source_url` (« marmiton.org » : hôte en minuscules, sans `www.`), écrit par `recipeProcessor` à côté de l'adresse (`siteName`, `web/urlGuard.ts`). Le client l'affiche tel quel (« Source : marmiton.org ») et ne le calcule pas : la règle n'existe qu'au serveur. Mêmes règles d'écriture que `source_url` (recopie sur une copie à l'identique, jamais modifié) |
| `source_author` | `String?` | Auteur annoncé par la page d'origine : `author` de son JSON-LD (`readAuthor`, `web/recipePage.ts` — chaîne, `Person` ou `Organization`, ou tableau ; noms joints par « , », sans doublon, sans adresse, 120 caractères au plus, coupé au dernier nom entier suivi de « … »). Écrit par `recipeProcessor` sur le chemin `json_ld` seulement. Le client l'affiche au-dessus du lien source (« Par Marie Dupont », masqué quand il répète le nom du site) et ne le saisit jamais. Mêmes règles d'écriture que `source_url`. Absent quand la page n'en publie pas, et sur les recettes importées avant la v0.23.43 |
| `source_nutrition` | `Map?` | Nutrition **par portion** annoncée par la page d'origine (`nutrition` de son JSON-LD, `readNutrition`) : `per_portion` (`kcal`, `protein_g`, `carbs_g`, `fat_g`, seules les valeurs lisibles, `kcal` ≤ 10 000, grammes ≤ 2 000, kJ convertis), `portions` (le `recipeYield` du site, ou `null`) et `ingredients_fingerprint` (`ingredientsFingerprint` des ingrédients écrits à l'import). Écrit par `recipeProcessor`, chemin `json_ld` seulement. **Jamais affiché ni utilisé à la place du calcul** : il ne sert qu'à `source_nutrition_check`. Serveur seul : les règles refusent au client de le poser, de le changer ou de l'effacer ; une copie ne le reprend pas (absent du modèle Dart) |
| `source_nutrition_check` | `Map?` | Écart entre le calcul de la nutrition et `source_nutrition`, écrit par `computeAndPersistRecipeNutrition` à chaque calcul (`compareWithSourceNutrition`, `nutrition/sourceNutrition.ts`). `state` : `ok`, `gap` (une valeur hors d'un facteur 2, dans un sens ou dans l'autre), `ingredients_changed` (l'empreinte des ingrédients ne correspond plus à celle de l'import : pas de comparaison), `low_coverage` (couverture sous le seuil `minCoverageForPartial` : pas de comparaison, `coverage` écrite). Pour `ok` et `gap` : `portions` (celles du site, sinon celles de la recette), `ratios` (notre valeur par portion divisée par celle du site, au centième), `gaps` (les clés hors du facteur 2). Plus `checked_at`. Un `gap` est journalisé en `WARNING` (module `DESIGN`, recette, site, ratios, couverture). Serveur seul, mêmes règles que `source_nutrition` |
| `origin` | `String?` | Ce qui a écrit le document la première fois : `scan` (`recipeProcessor`), `web` (`recipeProcessor`, import depuis un lien), `ai` (conception pour le planning, Explorer), `manual` (saisie, texte collé compris), `copy` (copie de travail). Écrit par celui qui crée le document, jamais déduit du livre porteur. Absent sur les documents antérieurs au champ : l'écran de relecture déduit alors `copy` d'une recette source, `scan` d'un fichier source, et n'affirme rien sinon — il disait « issu d'un scan » à toute recette conçue par l'IA |
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

#### Détail du champ `allergens` (Map imbriqué)

| Clé | Type | Rôle |
|---|---|---|
| `present` | `List<String>` | Clés présentes, triées dans l'ordre du règlement, sans doublon : `gluten`, `crustaces`, `oeuf`, `poisson`, `arachide`, `soja`, `lait`, `fruits_a_coque`, `celeri`, `moutarde`, `sesame`, `sulfites`, `lupin`, `mollusques` (fixture `allergens.json`) |
| `complete` | `bool` | `false` dès qu'un ingrédient de la recette n'a pas encore été examiné, et pour une recette sans ingrédient nommé : « aucun allergène » ne se déduit pas d'une liste vide |
| `by_ingredient` | `Map<String, List<String>>` | Pour chaque clé de `present`, les noms d'ingrédients en cause, tels que la recette les écrit |
| `computed_at` | `Timestamp` | Date du calcul |

Pas de liste des ingrédients non examinés, ni de « traces » : la fiche dit seulement si
l'analyse est incomplète. L'identité d'un ingrédient est celle de la nutrition et du produit
acheté (`buildIngredientLookupIds`, du plus précis au plus général) : le premier document du
référentiel qui **porte** le champ décide, même vide. Le calcul (`computeRecipeAllergens`,
`nutrition/allergens.ts`) est serveur seul ; le client ne reprend que les clés et leurs
libellés (`features/recipes/domain/allergens.dart`).

**Quand il s'écrit.** `onRecipeWritten` le recalcule dans deux cas, et l'écrit seulement si le
résultat a changé (transaction sur la recette, ingrédients relus au moment d'écrire) :

- à la création, quand les ingrédients changent, ou quand le champ manque alors qu'une
  autre entrée a changé : **après** `syncRecipeNutrition`, qui vient de créer les documents
  des ingrédients neufs et de les faire examiner par le modèle (poste `allergens_auto`) ;
- quand le champ manque et qu'aucune entrée n'a changé (recette antérieure au champ, écho
  d'une écriture du déclencheur pendant un calcul en cours) : tout de suite, avec ce que le
  référentiel sait déjà, **sans appel de modèle** — un écho ne refacture pas les ingrédients
  qu'un premier passage est en train d'examiner.

`allergens` n'est pas une entrée du déclencheur (`recipeTriggerInputsFingerprint`) : l'écho
de son écriture trouve le champ présent et les entrées inchangées, et s'arrête.

#### Détail du champ `estimated_times` (Map imbriqué)

| Clé | Type | Rôle |
|---|---|---|
| `status` | `String` | `done` : estimation rendue ; `pending` : appel en cours (réservation) |
| `fingerprint` | `String` | Empreinte du contenu estimé : SHA-256 (32 premiers caractères hexadécimaux) du titre et du texte CookLang (`draft_cooklang`, sinon `raw_cooklang`) **sans ses lignes `>>`** (`estimateFingerprint`). Saisir une durée ne la change pas ; modifier une étape ou le titre la change |
| `prep` · `cook` | `int?` | Minutes estimées, entier de 1 à 1440 (`boundedEstimatedMinutes`) ; `null` quand le modèle n'a pas su, qu'il n'y a pas de cuisson, ou que la recette **donne déjà** cette durée au moment de l'écriture (`doneEstimatedTimes` relit `readRecipeDurations` dans la transaction) : une estimation n'est jamais conservée pour une durée lue. Les deux sont demandées au modèle. Présentes quand `status == done` |
| `estimated_at` | `Timestamp` | Date de l'estimation (`status == done`) |
| `claim_id` · `claimed_at` | `String` · `Timestamp` | Réservation (`status == pending`) : identifiant tiré par l'invocation qui appelle le modèle, et sa date |

**Quand il s'écrit** (`triggers/recipeEstimatedTimes.ts`, `decideEstimatedTimes`). À chaque
écriture d'une recette, **avant** la garde d'empreinte des entrées, en parallèle du rôle dans
un repas :

- les deux durées sont lues : rien n'est appelé ; un champ présent est **vidé** —
  `status: done`, l'empreinte du contenu actuel, `prep` et `cook` à `null` — c'est ainsi
  qu'une durée saisie à la main retire l'estimation. Il n'est pas supprimé : ajouter puis
  retirer une ligne `>> temps_cuisson:` ne change pas l'empreinte, et l'aller-retour ne
  relance pas d'appel facturé. Contrepartie : la durée retirée reste sans estimation jusqu'à
  ce que le texte ou le titre de la recette change ;
- une durée manque et aucun champ ne porte l'empreinte du contenu actuel : le module
  **réserve** l'estimation dans une transaction (`status: pending`), appelle le modèle, puis
  écrit le résultat dans une seconde transaction, seulement si la réservation est toujours la
  sienne. Les échos qui arrivent pendant l'appel (rôle dans un repas, nutrition) trouvent la
  réservation et ne rappellent pas le modèle ;
- l'empreinte correspond et `status == done` : rien, même si les deux valeurs sont `null`
  (le modèle n'a pas su : on ne refacture pas le même contenu) ;
- une réservation de plus de dix minutes (`PENDING_TTL_MS`, appel en échec) se reprend à la
  prochaine écriture ou au backfill.

`estimated_times` n'est pas une entrée du déclencheur (`recipeTriggerInputsFingerprint`) :
son écriture ne relance ni nutrition, ni courses, ni allergènes, et son écho trouve une
estimation à jour. Coût : une estimation coûte deux à trois invocations du déclencheur de plus
(réservation, résultat), sans appel de modèle.

**Durée lue**, même règle des deux côtés : `readDurations` (`cooklang/parser.ts`,
`core/services/cooklang_parser.dart`, fixture `cooklang_parsing.json`, section
`readDurations`) — `tags.prep_time` / `cook_time` strictement positifs, puis les métadonnées
du brouillon, puis du texte validé, avec les alias de `extractTags`.

**Lecture côté client** (`features/recipes/domain/recipe_filter.dart`) : `recipeTimes`
compose, durée par durée, la valeur lue (`readDurations`, mémorisée par instance de recette)
puis l'estimation. Le temps total d'Explorer
(`recipeTotalMinutesWithEstimates`) ne l'emploie que si l'interrupteur « Compter les durées
estimées » est coché (`RecipeFilter.countEstimatedTimes`, `RecipeFilterContext.forFilter`).
Le sélecteur du planning (`RecipeFilterContext.empty`, durées lues, métadonnées comprises),
le serveur du planning et les courses n'emploient pas l'estimation. La fiche n'affiche une
estimation que pour une durée absente à la fois de `tags` et du texte (`recipeShownEstimate`,
puis `CooklangMetaRow` sur le texte affiché).

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
| `ai_usage_monthly/{AAAA-MM}` | agrégat mensuel : `by_feature` (avec `by_provider` imbriqué — `calls`, `cost_usd`, `input_tokens`, `output_tokens`, `analyzed_image_units`, `grounded_searches`), `by_provider`, `by_model`, `by_user`, totaux | l'écran des coûts |

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
et de `totalTokenCount − prompt − candidates − toolUsePrompt` : ce que le total
compte en plus de l'entrée, de la sortie et du résultat d'un outil (recherche
Google, facturé au tarif d'entrée) ne peut être que du raisonnement, et ce repli
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
inchangé tant que personne n'a tranché. Le budget est passé au SDK en
`config.thinkingConfig.thinkingBudget` (typé par `@google/genai`), qui l'envoie
à l'API en `generationConfig.thinkingConfig` ; `buildGeminiRequest()` construit
la requête. Un repli s'y ajoute : une erreur nommant `thinking` fait
retenter l'appel **une fois sans le plafond**, parce qu'une facture plus lourde
vaut mieux qu'un poste qui ne répond plus. Réglable dans Admin → Moteur d'IA.

**Réessais et erreurs Gemini.** `@google/genai` ne retente rien tant que
`httpOptions.retryOptions` n'est pas posé, et `client.ts` ne le pose pas : les
seuls réessais restent ceux de `callGemini` (quota, backoff exponentiel plafonné à
60 s, jusqu'au délai de l'appel), chacun journalisé. Le SDK lève une `ApiError`
dont `status` porte le code HTTP et dont le message est le corps JSON de
l'erreur ; `classifyError()` classe `status === 429`, puis à défaut un message
contenant le nombre `429` (mot entier), `quota` ou `resource_exhausted`, en `QUOTA_EXCEEDED`.
Le délai d'un appel `callGemini` annule la requête HTTP (`config.abortSignal`) : la
connexion est fermée et la réponse n'est plus attendue. Le client est construit avec
`vertexai: false` et l'hôte `https://generativelanguage.googleapis.com` en dur : le SDK
ignore donc `GOOGLE_GEMINI_BASE_URL` et `GOOGLE_GENAI_USE_VERTEXAI`, qui sinon pourraient
envoyer la clé vers un autre hôte.

**Recherche Google (grounding).**
`GeminiCallContext.googleSearch` ajoute l'outil `{ googleSearch: {} }` à la
requête, et `toGeminiResponse()` remplit `GeminiResponse.grounding` depuis le
`groundingMetadata` du premier candidat : `sources` (`groundingChunks[].web` —
URI obligatoire, doublons retirés, titre facultatif), `webSearchQueries`, et
`searchEntryPointHtml` (`searchEntryPoint.renderedContent`, le bloc de
suggestions Google à afficher avec la réponse). Un seul poste le pose :
`web_recipe_search` (« Chercher sur le web », voir *L'écran Explorer*), qui appelle
`callGemini` directement ; `callModel` ne transmet pas `googleSearch`.

Le grounding se facture à deux titres :

- **Les jetons.** Le résultat de la recherche relu par le modèle
  (`toolUsePromptTokenCount`) est facturé au tarif d'entrée. `inputTokensOf()`
  (`gemini/client.ts`) l'ajoute à `promptTokenCount` ; `thinkingTokensOf()` le
  retire du raisonnement. Le routeur emploie la même somme, pour le jour où un poste
  routé activerait l'outil.
- **L'appel ancré.** Google facture gemini-2.5-flash au *prompt ancré* : 35 $ les
  mille, soit 0,035 $ l'appel qui a lancé au moins une recherche, au-delà d'une
  franchise de 1 500 prompts ancrés par jour, partagée avec Flash-Lite. La grille
  porte ce prix dans `grounded_search_per_unit` (`groundedSearchPerUnit` en
  TypeScript et en Dart), semé à 0,035 sur `gemini-2.5-flash` et éditable dans
  Admin › Comptabilité › Grille tarifaire. **Tarif relevé sur la page des prix de
  Google le 12 octobre 2026, à revérifier contre la facture du premier mois.**
  `recordUsage` reçoit `groundedSearchCount` (1 quand la réponse porte au moins une
  requête ou une page citée, 0 sinon) et l'écrit sur la ligne
  (`grounded_search_count`), dans l'agrégat (`total_grounded_searches`,
  `by_feature.*.grounded_searches`, `by_model.*.grounded_searches`) et dans le coût
  (`estimateAiCostUsd`). La reconstruction des agrégats relit
  `grounded_search_count` pour rechiffrer.

**La franchise quotidienne de Google n'est pas déduite.** Elle est comptée par jour et
par projet, et l'application ne fait jamais 1 500 recherches par jour : tant que le
volume reste sous ce seuil, l'estimé porte 0,035 $ par recherche que Google ne facture
pas. L'écart apparaît du côté « estimé supérieur au facturé » de la réconciliation, sur
la ligne Gemini ; `total_grounded_searches × 0,035 $` l'explique, et il se lit mois par
mois dans `ai_usage_monthly`.

**Un prix ajouté après l'amorçage est semé champ par champ.** `loadAiPricingTable` ne
semait que les modèles absents de la grille. `missingUnitPriceFields()` sème aussi
`grounded_search_per_unit` sur une entrée existante qui ne porte pas ce champ ; un zéro
saisi depuis l'écran est un champ présent et n'est jamais recouvert. Sans cela,
`gemini-2.5-flash`, présent en base depuis l'amorçage, aurait lu un prix de recherche nul.

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
| `meal_role` | `String?` | **Rôle dans un repas** : `plat` \| `accompagnement` \| `entree` \| `dessert` \| `snack`. Reconnu une fois par le modèle — passe 2 de l'import, suggestion de tags, `onRecipeWritten` à toute écriture d'une recette sans rôle, backfill « Rôle des recettes » — et lu par le programme pour composer un repas. Absent = pas encore classée. Modifiable par l'utilisateur dans la liste « Rôle dans un repas » du panneau de métadonnées (relecture d'un import, correction, création) ; « Non classé » retire les trois champs, et `main_protein` et `main_starch` avec eux (`clearMealRole` dans `validateDraft`, carte entière dans `updateRecipe`). Les valeurs et la lecture de la réponse vivent dans `functions/src/gemini/mealRole.ts` ; `lib/features/recipes/domain/meal_role.dart` les reprend pour la liste et l'affichage, `test-fixtures/meal_roles.json` verrouille l'égalité |
| `contains` | `List<String>` | Ce que la recette apporte déjà : `proteine`, `feculent`, `legume`. Un plat à qui il manque l'un des deux derniers appelle un accompagnement (`needsSide`) |
| `suggested_sides` | `List<String>` | Accompagnements classiques d'un plat, noms courts, quatre au plus ; vide pour les autres rôles. Le programme y choisit au moment du planning, jamais le modèle |
| `roles_tagged_at` | `Timestamp?` | Quand le backfill a posé le rôle |
| `main_protein` | `String?` | **Protéine principale** d'un plat ou d'un accompagnement : `boeuf` \| `porc` \| `volaille` \| `agneau` \| `poisson` \| `fruits_de_mer` \| `oeuf` \| `vegetarien` \| `legumineuses`. Rendue par le même appel que `meal_role` (`MEAL_ROLE_PROMPT`) — passe 2 de l'import, suggestion de tags, `onRecipeWritten`, backfill « Rôle des recettes » — ou, pour les recettes classées avant v0.23.24, par le backfill « Protéine et féculent des plats » (retiré en v0.23.52). Une valeur hors liste est lue comme absente (`parseMainProtein`), jamais rangée dans une valeur voisine. Absente pour une entrée, un dessert ou un snack. Écrite seulement quand elle est connue. Lue par la présélection du planning (`proteinOf`) et affichée dans « Catégorisation ». Corrigeable à la main dans la liste « Protéine principale » du panneau de métadonnées (relecture d'un import, correction, création), visible pour un plat ou un accompagnement seulement ; voir « Correction à la main de la protéine et du féculent » ci-dessous |
| `main_starch` | `String?` | **Féculent principal** : `pates` \| `riz` \| `pommes_de_terre` \| `semoule` \| `pain` \| `aucun`. Même origine, même règle de lecture (`parseMainStarch`), même affichage. Lu par la présélection pour alterner les féculents (`starchOf`). Corrigeable à la main dans la liste « Féculent principal », mêmes règles que `main_protein` |
| `main_ingredients_checked_at` | `Timestamp?` | **Marqueur d'examen** : le modèle a répondu sur la protéine et le féculent, même par une valeur hors liste (« veau ») qui laisse les champs vides. Posé par la passe 2 de l'import, `onRecipeWritten`, le backfill « Rôle des recettes » (heure serveur) et « Suggérer les tags » (heure du client) ; le backfill « Protéine et féculent des plats », retiré en v0.23.52, le posait aussi. Deux chaînes vides ou des clés absentes ne sont pas une réponse : pas de marqueur. `RecipeTags` le relit et le réécrit, pour qu'une carte `tags` réécrite en bloc ne l'efface pas ; « Non classé » le retire. Posé aussi (heure du client) quand l'utilisateur renseigne à la main les deux champs ; retiré quand il remet l'un des deux à « Non renseigné », ou quand le rôle final est une entrée, un dessert ou un snack |

**Le rôle survit aux réécritures de `tags`.** Côté client, `RecipeTags.toMap()` n'écrit
les trois champs que si le rôle est connu, et `validateDraft` écrit `tags` champ par champ
(`tags.themes`, `tags.cuisines`, …) au lieu de remplacer la carte : un brouillon validé depuis
le formulaire, qui ne connaît pas le rôle, ne l'efface pas. Le pipeline d'import écrit
`meal_role: null` quand la passe 2 n'a pas su ; le backfill repasse sur ces recettes.
`main_protein` et `main_starch` suivent la même règle : `toMap()` ne les écrit que s'ils sont
connus, une carte réécrite depuis un objet lu en base les garde, et « Non classé » les retire
avec le rôle. Une valeur restée d'un ancien rôle (plat devenu dessert) n'est ni affichée ni
envoyée au planning (`RecipeTags.carriesMainIngredients`).

**Correction à la main de la protéine et du féculent.** Le panneau de métadonnées
(`recipe_meta_panel.dart`) montre deux listes sous « Rôle dans un repas » : « Protéine
principale » et « Féculent principal », avec « Non renseigné » en tête puis `kMainProteins` /
`kMainStarches`. Elles n'apparaissent que si le rôle choisi dans le formulaire est un plat ou un
accompagnement (`kRolesWithMainIngredients`). Une valeur hors liste lue en base reste affichée
telle quelle. L'état vit dans `RecipeFormMixin` (`selectedMainProtein`, `selectedMainStarch`,
`mainIngredientsCheckedAt`), initialisé depuis la recette quand son rôle porte ces champs ;
« Suggérer les tags » remplit les deux listes quand le modèle répond. `buildTagsFromForm` écrit
les valeurs du formulaire, `null` compris (`RecipeTags.withMainIngredients`) :

- un choix à la main remplace la valeur de la base ; quand les deux champs sont renseignés, le
  marqueur `main_ingredients_checked_at` prend l'heure du choix ;
- « Non renseigné » retire le champ **et** le marqueur. Aucun chemin automatique ne redemande
  ensuite le champ manquant : le backfill « Protéine et féculent des plats », qui le faisait,
  est retiré en v0.23.52. « Suggérer les tags » le propose à la demande ;
- un rôle final qui ne les porte pas (entrée, dessert, snack, non classé) retire les deux champs
  et le marqueur. Changer de rôle puis revenir à plat dans la même session retrouve les valeurs
  du formulaire.

Écriture : `updateRecipe` et `createRecipe` écrivent la carte `tags` entière, donc un champ absent
de l'objet disparaît. `validateDraft` écrit champ par champ et efface par `FieldValue.delete()`
`tags.main_protein`, `tags.main_starch` et `tags.main_ingredients_checked_at` absents de l'objet
quand le rôle final ne les porte pas, ou quand l'écran de relecture passe
`mainIngredientsFromForm: true`. La validation en lot de la file de travail ne passe pas ce
drapeau : un champ posé par le serveur depuis la lecture du brouillon reste. Aucun chemin
serveur ne remplace une valeur posée à la main : l'import écrit une recette neuve,
`onRecipeWritten` ne classe qu'une recette sans rôle, et le backfill « Rôle des recettes » passe
par `mainIngredientsPatch`.

**Le rôle se pose aussi à l'écriture.** Trois chemins créent une recette sans rôle : une
création manuelle sans clic « Suggérer », une recette de l'Explorer IA (`generateRecipeFn` ne
demande pas ce champ), une copie d'une recette non classée (`copyRecipeAsDraft`).
`onRecipeWritten` appelle `syncRecipeMealRole` (`triggers/recipeMealRoleAutoSync.ts`) sur
toute écriture d'une recette (`page_type` recette) dont `tags.meal_role` est vide, **avant** la
garde des entrées : la classification n'attend pas un changement d'ingrédients. Un appel de
modèle, poste `inline_meal_role_classification`, qui écrit `tags.meal_role`, `contains`,
`suggested_sides` et `roles_tagged_at`, plus `main_protein` et `main_starch` quand le modèle
les rend et qu'ils sont absents (`mainIngredientsPatch` : une valeur posée à la main n'est pas
remplacée), et `main_ingredients_checked_at` dès qu'il a répondu. Si le modèle ne rend aucun rôle, rien n'est écrit et la prochaine écriture retente ;
une erreur passe par `logError`. L'absence de `main_protein` seule ne déclenche aucun appel :
un déclencheur qui rappellerait le modèle tant qu'elle manque le rappellerait à chaque écho de
sa propre écriture. Une recette classée sans elle la garde absente : le backfill qui reprenait
ces recettes est retiré en v0.23.52.

**Les durées estimées se posent au même endroit.** `onRecipeWritten` appelle
`syncRecipeEstimatedTimes` (`triggers/recipeEstimatedTimes.ts`) en parallèle de
`syncRecipeMealRole`, avant la garde des entrées : voir « Détail du champ `estimated_times` ».

---

### 3.4 Collection `processing_jobs`

Jobs de traitement asynchrone pour scans recettes/livres et imports par lien.

| Champ | Type | Description |
|---|---|---|
| `id` | `String` | ID auto-généré Firestore |
| `type` | `String` | Enum : `recipeScan` \| `bookCoverScan` \| `bookDocumentScan` \| `recipeUrlImport`. Le dernier n'est créé que par `importRecipeFromUrlFn` : les règles refusent sa création par le client |
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
| `current_step` | `String?` | Étape courante du traitement IA. `fetch` (« Lecture de la page web… ») n'existe que pour `recipeUrlImport`. `translate` (« Traduction de la recette par l'IA… ») n'apparaît que pour une recette écrite dans une autre langue : entre `gemini_call` et `parse` pour un scan, entre `parse` et `tagging` pour un `recipeUrlImport`. Son jalon n'est dans le fil d'icônes (`processing_trail`) que si le job porte `translated` |
| `translated` | `Boolean?` | **Posé par le serveur** à `true` dans la même écriture que `current_step: "translate"` (`recipeProcessor.ts`, `urlImport.ts`), jamais retiré. Le fil d'icônes de la file de travail y ajoute le jalon « Traduction », et le garde jusqu'à la fin du traitement. Absent pour une recette française |
| `scan_id` | `String?` | Le scan d'où vient ce job. **Posé par le client** au premier envoi, avant même que le job existe : le contrôle du fichier a lieu dans une callable séparée, et une page supplémentaire arrive par un appel séparé. Le `jobDispatcher` le relit, le réécrit — pour qu'une relance retrouve le même scan — et le transmet au `recipeProcessor` dans le payload de la tâche. Un job créé avant l'existence du champ en reçoit un fabriqué côté serveur, qui couvre au moins l'import et ses suites. **À la création, la valeur du client n'est pas crue telle quelle** (v0.23.12, `dispatchScanId`) : un `bookDocumentScan` reçoit toujours un identifiant tiré par le serveur, et un autre job reçoit un identifiant neuf si `scan_spend/{scan_id}` appartient déjà à un autre compte (`user_id`). Sans cela, un éditeur qui reprenait le `scan_id` d'un import d'autrui relevait son plafond et y imputait ses dépenses. Le client ne peut plus changer ce champ ensuite (règles) |
| `import_illustrations` | `Boolean` | Extraire les illustrations des pages de ce job. Copié depuis la case de l'écran d'import au moment de la création, **jamais relu depuis le profil** : le serveur traite ce job après coup, et la préférence a pu changer entre-temps. Ce qui a été demandé au moment de l'import est ce qui est fait. Toujours `false` hors `recipeScan`. |
| `parent_job_id` | `String?` | **Posé par le serveur** sur le job d'une tranche de livre : l'identifiant du job `bookDocumentScan` qui l'a créé. Sert au retrait d'un livre vide après un échec, et à retrouver les enfants d'un import. |
| `book_window` | `Map?` | **Posé par le serveur** sur le job d'une tranche : `{ kind: "pdf" \| "text", owned?: Number, context: Number }`. `owned` = pages à transcrire, `context` = pages (ou 0/1 pour un texte) de contexte qui suivent. `recipeProcessor` en fait un préambule de prompt (`bookWindowPreamble`) et saute le comptage d'illustrations pour ces jobs. |
| `windows_total` / `windows_created` | `Number?` | Sur un job `bookDocumentScan` : nombre de tranches prévu, puis nombre déjà créé (mis à jour toutes les 10 tranches). |
| `budget_limit_usd` | `Number?` | **Posé par le client** sur le job `bookDocumentScan` : le plafond de dépense de l'import, en dollars, fixé sur l'écran de confirmation. `runBookImport` le pose sur `scan_spend/{scan_id}` avant de créer la première tranche, borné par le serveur (`effectiveImportLimitUsd`, v0.23.12) : au plus `MAX_IMPORT_BUDGET_PER_WINDOW_EUR` (4 €) par tranche depuis v0.23.13, convertis en dollars au moment du calcul avec le taux de la facture (`app_config/currency_rate`, `getUsdToEurRate`), jamais plus de `MAX_IMPORT_BUDGET_PER_WINDOW_HARD_USD` (8 $) par tranche, et arrondis au centime inférieur. Sans taux, ou avec un taux hors des bornes de vraisemblance de la réconciliation (`MIN_PLAUSIBLE_RATE` 0,1 – `MAX_PLAUSIBLE_RATE` 10, `usableRate`), aucun taux n'est inventé : le maximum vaut 4 $ par tranche, valeur plus basse que 4 € tant qu'un dollar vaut moins qu'un euro, et `runBookImport` le journalise (`logWarn`). La valeur du client ne peut que réduire ce maximum ; un job sans plafond reçoit le maximum. |
| `source_url` | `String?` | **Posé par `importRecipeFromUrlFn`** sur un job `recipeUrlImport` : l'adresse normalisée de la page. `file_url` vaut alors `""`, `file_name` le nom du site, `mime_type` `text/html`, `book_titre` « Mes recettes du web » et `book_id` `null` jusqu'à l'écriture du brouillon. Le client ne peut pas le changer (règles : une relance ne touche que les champs de relance) |
| `error_code` | `String?` | **Posé par le serveur** sur un `recipeUrlImport` en échec : `page_blocked` (401, 402, 403, 429, 451), `page_not_found` (404, 410), `no_recipe`, `timeout` (délai, réseau, 5xx), `url_refused` (adresse non publique, plus de 3 redirections, contenu non HTML, page de plus de 3 Mo). La tuile de la file choisit ses actions sur ce code. Effacé au début de chaque tentative |
| `recettes_trouvees` | `Number?` | **Posé par le serveur** sur un `recipeUrlImport` : nombre de recettes trouvées sur la page. Une seule est reprise ; au-delà d'une, la tuile le dit |
| `photo_status` | `String?` | **Posé par le serveur** sur un `recipeUrlImport` terminé : `attached`, `held` (modération en attente), `refused`, `none` (pas de photo sur la page), `failed` (récupération ou conversion en échec, journalisée) |
| `url_retry_count` | `Number?` | Sur un `recipeUrlImport` : relances faites depuis la file. **Écrit par le client** à chaque relance (`retryJob`), qui doit l'incrémenter d'exactement un ; les règles n'admettent la relance que d'un job en `error` dont `error_code` vaut `timeout` ou est absent (incident du pipeline, annulation), et deux fois au plus (`urlRelaunchAllowed`). Une annulation le laisse inchangé (`retryCountUnchanged`) : sinon chaque annulation le remettrait à zéro et la borne de deux ne tiendrait plus. Un job terminé ou refusé par le site ne se relance pas : chaque relance relance le pipeline facturé, hors du plafond quotidien compté par la callable |
| `forced_duplicate` | `Boolean?` | Sur un `recipeUrlImport` : l'utilisateur a choisi « Importer quand même » malgré une recette existante de même `source_url` |
| `transcription_checkpoint` | `String?` | **Posé par le serveur** sur un job `recipeScan` : la transcription réussie de la page, en JSON (`pipeline/transcriptionCheckpoint.ts`). Une nouvelle tentative après un échec du balisage, ou une relance depuis la file (qui copie le job), la relit au lieu de refaire l'appel de modèle. Réécrit après chaque recette étrangère traduite : une relance ne retraduit pas les recettes déjà traduites. Supprimé quand le job aboutit ; non écrit au-delà de 300 000 caractères. Un point de reprise illisible est journalisé et la page est transcrite de nouveau. |

**`bookDocumentScan` ne transcrit rien.** `recipeProcessor` l'aiguille sur `runBookImport` (`pipeline/bookImport.ts`), qui ouvre le fichier (`books/bookFile.ts`), crée le livre s'il n'y en a pas (`book_id` absent → document `books/book_import_{jobId}`, couverture dans `scans/{uid}/book_import_{jobId}/`), puis découpe le contenu en tranches et crée **un job `recipeScan` par tranche** (`processing_jobs/book_import_{jobId}_{NNNN}`, fichier dans `scans/{uid}/book_import_{jobId}/{NNNN}.pdf|txt`). Ces jobs suivent le pipeline d'une page scannée et partagent le `scan_id` du parent : le coût du livre se lit sur un seul groupe. L'opération est idempotente — livre et enfants ont des identifiants déterminés par le parent, un enfant existant n'est jamais recréé (`create()` refusé, code gRPC 6) — et un livre neuf qui n'a aucun enfant est supprimé si l'import échoue. Un `BookFileError` (PDF chiffré, EPUB sans texte, plus de 400 tranches) part directement en dead letter sans nouvelle tentative, comme un plafond de dépense.

**Découpage** (`books/bookFile.ts`). PDF : `pdf-lib` (chargé à la demande), fenêtres de 3 pages + 1 page de contexte (`planWindows`) ; une tranche de plus de 12 Mo est coupée en deux, chaque moitié gardant son contexte, parce que le fichier part en base64 dans une requête plafonnée à 20 Mo chez Gemini. EPUB et Word : texte extrait par du code (OPF + XHTML pour l'EPUB, `docxToPlainText` pour Word), fenêtres d'environ 6 000 caractères + 1 500 de contexte, un paragraphe n'étant jamais coupé (`planTextWindows`). La ligne `BOOK_WINDOW_CONTEXT_MARKER` sépare le texte à transcrire du contexte. Mesuré sur un PDF synthétique de 190 Mo et 300 pages : ouverture 0,14 s, découpage en 100 tranches 0,3 s, pic de mémoire 462 Mo (`recipeProcessor` passe à 2 GiB).

**`recipeUrlImport` ne télécharge aucun fichier.** `recipeProcessor` l'aiguille, après
`assertJobTargetBook`, sur `prepareUrlImport` (`pipeline/urlImport.ts`) : lecture protégée de la
page (`fetch`), données structurées `schema.org/Recipe` projetées sans modèle ou, à défaut,
texte principal transcrit (`gemini_call`, poste `url_import_fallback`), traduction si besoin
(`translate`), balisage (`tagging`, poste `url_import`). Puis `findOrCreateWebBook`, le texte de
la page déposé comme document original (`scans/{uid}/web_{jobId}_page_web_{site}.txt`,
`source_file_url` / `source_file_name` de la recette), `saveDraft` (`origin: "web"`,
`source_url`, normalisation `normalize` puis `save`), et enfin la photo (`design`,
`attachWebPhoto`). Détail au §6, « Import d'une recette depuis un lien ».

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
| `invited_ids` | `List<String>?` | UIDs des comptes invités qui n'ont pas encore répondu (v0.23.19). Un invité n'est pas membre : il lit le groupe, rien de ses livres. Absent sur les groupes antérieurs : vaut liste vide |
| `created_at` | `Timestamp` | Date de création |

**Entrer dans un groupe se fait de son propre chef** (v0.23.19). Être membre ouvre la lecture des
livres et recettes non privés des autres membres, dans les deux sens. Le propriétaire invite
(`inviteMember` : `invited_ids` reçoit l'uid), l'invité accepte (`acceptInvitation` : une seule
écriture qui retire l'uid de `invited_ids` et l'ajoute à `member_ids`) ou refuse
(`withdrawInvitation`, la même écriture que l'annulation par le propriétaire). Avant, le
propriétaire écrivait `member_ids` directement : n'importe quel compte créait un groupe, y
ajoutait un inconnu, et lisait ses livres. Les membres ajoutés ainsi avant la v0.23.19 restent
membres.

**Requêtes clés :**
- `where('member_ids', arrayContains: uid)` → groupes de l'utilisateur
- `where('invited_ids', arrayContains: uid)` → invitations reçues (`watchMyInvitations`, badge du menu compte)
- Visibilité cross-utilisateur : la portée `group_reach/{uid}` (§3.5 bis) → `whereIn created_by` sur `books` et `recipes`. Le client part de la portée et non de l'union des `member_ids` : un membre que les groupes viennent de recevoir n'est lisible qu'une fois `syncGroupReach` passé, et le nommer plus tôt ferait refuser la requête entière
- **Toute lecture portant sur autrui écarte le privé** : `where('is_private', isEqualTo: false)` s'ajoute à la requête, et non au filtrage client. `watchValidatedBooksByOwners`, `watchUnattachedByOwners`, `watchDraftsByOwners`, `getFamilyValidatedRecipes` et le volet familial de la recherche l'appliquent. Le corpus de recherche part en **deux requêtes** — les miennes sans filtre, celles de la famille avec — parce qu'un appel unique mêlant les deux publics ne peut appliquer qu'une règle, et applique donc la plus permissive.

> **Le partage nominatif n'existe plus.** `books.shared_with` et son index ont été
> retirés : `shareBook`/`unshareBook` n'avaient jamais eu d'écran pour les appeler,
> et `watchSharedBooks` rendait donc toujours une liste vide. Un livre est partagé
> avec les membres de ses groupes, ou privé. Il n'y a pas de troisième état.

---

### 3.5 bis Collection `group_reach` — la portée des groupes

Un document par compte : les **autres** comptes avec qui il partage au moins un groupe.
Les règles Firestore le relisent pour décider si un livre ou une recette partagé d'un autre
compte est lisible (§4, `sharesGroupWith`). Elles ne peuvent pas parcourir `groups` pour
répondre à cette question ; la portée la leur donne en une lecture.

| Champ | Type | Description |
|---|---|---|
| `uids` | `List<String>` | UIDs des comptes qui partagent un groupe **actif** avec le titulaire, sans lui, triés, sans doublon. Membre d'un groupe = présent dans `member_ids` ou égal à `owner_id`. Groupe actif = son propriétaire est éditeur ou administrateur non révoqué (`isPlannerAccount`, `triggers/groupMembers.ts`) : un groupe dont le propriétaire est rétrogradé ne relie plus personne, propriétaire compris, sans que rien ne soit effacé |
| `updated_at` | `Timestamp` | heure serveur de la dernière écriture |

**Qui l'écrit :** le serveur seul. `syncGroupReach`, déclencheur sur `groups/{groupId}`, recalcule
la portée de chaque compte présent avant ou après l'écriture, dans une transaction qui relit
tous ses groupes (`member_ids array-contains uid` et `owner_id == uid`) et le document `users`
de leurs propriétaires. Un renommage ne déclenche rien. `syncPlanningReachOnRole`
(`triggers/plannerRole.ts`) la recalcule aussi pour les membres des groupes d'un compte dont le
droit de planifier change : un propriétaire rétrogradé masque son groupe, et le rétablit en
redevenant éditeur. **Pourquoi par la portée et non par les règles** : `group_reach` ne dit pas
quel groupe relie deux comptes ; vérifier le rôle du propriétaire dans les règles des livres et
recettes coûterait une lecture de plus par document lu, à chaque requête. Le retrait de la
portée ne coûte que des lectures de déclencheur, à chaque changement de rôle. Le délai est
celui de `syncGroupReach` (quelques secondes). Le backfill « Portée des groupes et des
plannings » (`backfillGroupPlanningReachFn`, §7.10) recalcule les portées antérieures. Un compte sorti de tous ses groupes reçoit `uids: []` ; le document n'est pas supprimé.
Un échec est journalisé et l'événement rejoué (`retry: true`) : une portée périmée laisserait
un membre sorti lire encore les livres du groupe. `backfillGroupReachFn`, qui a semé le fonds
après la v0.23.19, est retiré depuis la v0.23.23 : lancé en production, son travail est fait.

**Risque accepté (v0.23.23).** Hors du backfill ponctuel `group_planning_reach` (§7.10),
aucun outil ne recalcule la portée en masse ; une fois ce backfill retiré du code, plus aucun. Si
`syncGroupReach` échoue au-delà de la fenêtre de nouvelles tentatives d'Eventarc (environ
7 jours), la portée des comptes concernés reste périmée jusqu'à la prochaine modification des
membres de ce groupe ; un renommage ne la corrige pas. Un membre retiré pendant cette panne
lirait encore les livres et recettes non privés du groupe. L'échec est journalisé
(`logError`) : il se voit dans Admin › Journaux. Le jour où ce cas se produit, la réparation
passe par un nouveau backfill (Admin › Backfills).

**Qui le lit :** son titulaire (`GroupRepository.watchReach`, d'où le client tire ses requêtes)
et un administrateur.

---

### 3.5 ter Collection `invitations` — invitations par e-mail

Une invitation envoyée par un administrateur à une personne qui n'a pas encore de compte, ou
dont le compte est révoqué. Écrite par le serveur seul (`manageInvitationFn`,
`applyEmailInvitation`, `applyRevokedInvitation`) ; lue par un
administrateur (Admin › Gestion des utilisateurs › Invitations, tri `created_at` décroissant,
index simple).

| Champ | Type | Description |
|---|---|---|
| `email` | `String` | Adresse saisie, espaces retirés, minuscules. C'est elle qui reçoit l'e-mail |
| `email_key` | `String` | Clé de comparaison (`normalizeEmailKey`, `functions/src/invitations/rules.ts`) : minuscules ; pour `gmail.com` et `googlemail.com`, points et suffixe `+…` de la partie locale retirés, `googlemail.com` → `gmail.com`. Logique serveur seule, sans jumeau Dart |
| `role` | `String` | `reader` ou `editor`. Jamais `admin` : la callable le refuse |
| `group_id` | `String` | Groupe que l'invité rejoindra |
| `group_name` | `String` | Nom du groupe au moment de l'invitation, pour l'e-mail et la liste |
| `message` | `String` | Message de l'administrateur, 500 caractères au plus. Le formulaire le préremplit (`defaultInvitationMessage`, client seul) ; vide, il reste vide et l'e-mail part sans paragraphe personnel |
| `invited_by` | `String` | UID de l'administrateur qui a créé l'invitation |
| `invited_by_name` | `String` | Son nom (préféré, sinon Google, sinon adresse) |
| `status` | `String` | `sent` \| `send_failed` \| `accepted` \| `cancelled`. `expired` n'est jamais écrit |
| `created_at` | `Timestamp` | Création |
| `last_sent_at` | `Timestamp` | Dernier envoi (création ou renvoi) |
| `last_sent_by` | `String` | UID de l'administrateur du dernier envoi ; c'est son nom et son adresse que porte l'e-mail renvoyé |
| `expires_at` | `Timestamp` | `last_sent_at` + 30 jours. Un renvoi la repousse |
| `send_count` | `int` | Nombre d'envois |
| `last_error` | `String?` | Raison lisible du dernier échec d'envoi (300 caractères au plus, partie locale des adresses masquée : `t***@gmail.com`), `null` après un envoi réussi. « Envoi en cours ou interrompu. » entre l'enregistrement et la réponse du serveur SMTP. Sur une invitation annulée par le serveur : « Adresse refusée par Gmail : … », ou « Accès rétabli à la main : invitation sans objet. » / « Accès rétabli par une autre invitation : invitation sans objet. » (invitation de retour, compte rétabli) |
| `accepted_uid` | `String?` | Compte qui a reçu le rôle |
| `accepted_at` | `Timestamp?` | Date de l'acceptation |
| `cancelled_by` | `String?` | UID de l'administrateur qui a annulé, ou `system` quand le serveur SMTP a refusé définitivement l'adresse, ou quand une invitation de retour est devenue sans objet (compte rétabli, `syncUserClaims`) |
| `cancelled_at` | `Timestamp?` | Date de l'annulation |
| `group_missing` | `Boolean` | `true` si le groupe n'existait plus à l'acceptation : le rôle a été donné sans groupe |
| `target` | `String` | Compte visé, fixé à la création : `new` (aucun compte sous l'adresse ; appliquée par `applyEmailInvitation`) ou `revoked` (compte révoqué ; appliquée par `applyRevokedInvitation`). Absent sur les invitations créées avant l'invitation des comptes révoqués : lu `new`. Aucun backfill |
| `target_uid` | `String?` | Pour `target: "revoked"`, l'uid du compte révoqué visé. Seul ce compte peut l'appliquer, même si un autre compte avait la même clé d'adresse. `null` sinon |
| `group_invite` | `String?` | Pour un compte révoqué revenu : `invited` (uid ajouté à `invited_ids`), `already_member`, `already_invited`, `full` (50 invitations en attente, rien écrit) ou `missing` (groupe supprimé, ou invitant qui n'en est plus ni propriétaire ni membre : rien écrit). `null` sinon |

**Statut effectif.** Une invitation `sent` ou `send_failed` dont `expires_at` est passée,
égale à l'instant présent ou absente est **expirée** à la lecture, côté serveur
(`effectiveStatus`) comme côté client (`EmailInvitation.statusAt`). Un statut stocké inconnu se
lit `send_failed`. Logique dupliquée : les deux rejouent
`test-fixtures/email_invitation_status.json`. Aucune tâche planifiée. Une invitation **active** est `sent` ou
`send_failed`, non expirée : elle seule donne un rôle. Une seule invitation active par
`email_key`, contrôlée dans la transaction de création et de renvoi.

**Enregistrer avant d'envoyer.** La callable écrit l'invitation (`status: send_failed`,
`last_error: "Envoi en cours ou interrompu."`), puis envoie l'e-mail, puis écrit `sent` ou
`send_failed` avec la raison, dans une transaction qui ne touche pas une invitation acceptée
ou annulée pendant l'envoi. Un refus définitif du destinataire (code 5xx avec un code étendu `5.1.x` sur `RCPT TO`, ex.
`550 5.1.1`, ou enveloppe rejetée) passe l'invitation à `cancelled` (`cancelled_by: "system"`,
`last_error` « Adresse refusée par Gmail : … ») : une adresse inexistante ne reste pas active.
Une fonction interrompue pendant l'envoi laisse une invitation visible et renvoyable, jamais
une invitation fantôme.

**Migration :** aucune. La collection naît vide, rien n'est à reprendre.

`invitation_sends_daily/{uid}_{AAAA-MM-JJ}` (jour UTC) : `uid` `String`, `day` `String`,
`count` `int`, `updated_at` `Timestamp`. Compteur du plafond de 20 envois (créations et
renvois) par administrateur et par jour, incrémenté dans la transaction qui enregistre
l'envoi. Écrit par les Functions seules, lu par un administrateur.

`member_email_search_daily/{uid}_{AAAA-MM-JJ}` (jour UTC) : `uid` `String`, `day` `String`,
`count` `int`, `misses` `int?`, `updated_at` `Timestamp`, `expires_at` `Timestamp`. Compteur du
plafond de 10 recherches d'un membre par adresse (`findMemberByEmailFn`) par compte et par jour,
incrémenté dans une transaction avant la recherche, que le compte soit trouvé ou non. `misses`
compte les réponses « aucun compte » du jour (seuil d'alerte : 5). `expires_at` vaut la dernière
écriture + 30 jours (`searchCounterExpiry`) ; une politique TTL sur ce champ
(`firestore.indexes.json` › `fieldOverrides`, active au déploiement des index) supprime le
document, la suppression TTL pouvant prendre jusqu'à quelques jours. N'enregistre aucune
adresse. Écrit par les Functions seules, lu par personne côté client. **Migration :** aucune, la
collection naît vide.

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

### 3.6 bis Sous-collection `recipes/{recipeId}/origine` — le texte d'avant traduction

Un seul document, `texte` (`pipeline/originalText.ts`, `SUBCOLL_ORIGINAL_TEXT`,
`ORIGINAL_TEXT_DOC_ID`). Il n'existe que sur une recette qui porte `langue_origine`. Il est
écrit par `saveDraft` (`recipeProcessor`) **dans le même lot** (`batch`) que la recette : une
recette marquée traduite sans son original afficherait un lien vide. Il vit à part de la recette
parce que la recette est lue dans toutes les listes, et ce texte seulement à la demande.

| Champ | Type | Description |
|---|---|---|
| `langue` | `String` | Code ISO 639-1 de la langue d'origine, égal à `langue_origine` de la recette |
| `titre` | `String` | Titre tel que la page l'écrit |
| `introduction` | `String?` | Chapeau de la recette, `null` s'il n'y en a pas |
| `portions` | `int?` | Recopié de la transcription |
| `temps_preparation` · `temps_cuisson` · `temps_repos` | `String?` | Durées telles qu'écrites, unités d'origine |
| `sections_ingredients` | `List<Map>` | `{titre, lignes: List<String>}`, lignes d'ingrédients dans la langue et les unités d'origine |
| `sections_etapes` | `List<Map>` | `{titre, etapes: List<String>}` |
| `notes` | `List<Map>` | `{genre, texte}` |
| `created_at` | `Timestamp` | Horodatage serveur de l'écriture |

Les lectures incertaines et l'inventaire de la transcription n'y figurent pas : ils servent au
contrôle de l'import, pas au lecteur. Le client le lit par `OriginalTextRepository`
(`originalTextProvider`, `OriginalText.fromMap`) à l'ouverture de la vue « Texte d'origine »,
jamais avant. Il n'entre pas dans `ingredients_index` ni dans la recherche.

**Écriture interdite au client** (règles, §4), administrateur compris. **Suppression** :
`onRecipeWritten`, à la suppression de toute recette, sans condition sur `langue_origine` (le champ a
pu être retiré avant) : supprimer un document absent ne fait rien, et une
sous-collection ne disparaît pas avec son document. Best-effort : un échec est journalisé
(`logError`, « Texte d'origine non supprimé avec sa recette ») et laisse un document que les
règles ne laissent plus lire, puisque la recette n'existe plus.

---

### 3.7 Collection `planned_meals`

Le repas planifié est **le porteur du contexte** : c'est le couple (personne, date). Une
adaptation d'une recette — un nombre de parts différent — vit ici, jamais dans la recette
partagée.

Depuis v0.23.47, seul un éditeur ou un administrateur crée et modifie ses repas. Un lecteur
garde la lecture de ses repas antérieurs ; depuis le planning de groupe, il ne les supprime
plus (`delete` exige `isEditor()`).

**Planning de groupe.** Un repas est personnel (`group_id` `null` ; absent sur les repas
antérieurs jusqu'au passage du backfill `group_planning_reach`, qui le pose), ou du planning
d'un groupe familial (`group_id` =
identifiant du groupe). `uid` reste le cuisinier : pour un repas de groupe, c'est le
propriétaire du groupe, seul à y écrire (règles : `get(groups/{group_id}).owner_id ==
request.auth.uid` à la création et à la modification). `group_id` est figé à la modification
côté client. Seul le backfill paramétré « Déplacer mes repas vers un groupe »
(`backfillMoveMealsToGroupFn`, §7.10) le change, par l'Admin SDK : il fait passer les repas
personnels d'un administrateur, sur une période, dans un groupe dont il est propriétaire, sans
toucher `uid` ni les parts.
Les membres du groupe le lisent par `planning_reach/{lecteur}.group_ids` (§3.8 quater) ; le
client ouvre **un flux par groupe affiché** (`group_id == groupe` et `uid == propriétaire du
groupe`, `planned_at` sur 90 jours, `PlanningRepository.watchGroupMeals`, index composite
`uid`, `group_id`, `planned_at`). La règle vérifie que `uid` est le propriétaire **actuel** du
groupe (`get(groups/{group_id}).owner_id`) : un groupe supprimé puis recréé sous le même
identifiant par un autre compte n'ouvre pas aux nouveaux membres les repas de l'ancien
propriétaire. Une requête sans le filtre `uid` est refusée. Le titre d'une recette privée
planifiée pour le groupe se lit sur le repas ; la recette, elle, reste fermée.
**Un repas personnel porte `group_id: null` explicite** (`PlannedMeal.toFirestore`), et le
partage d'un planning personnel n'ouvre que ces repas : la règle de lecture n'accepte
`canReadPlanningOf(uid)` que si `resource.data.group_id == null` — le champ présent et nul : la
forme `.get('group_id', null)` rendait la condition vraie sur une requête qui ne contraint pas
`group_id`, et `uid == propriétaire` seul ramenait les repas de groupe. Sans cela, un compte qui lit le planning
personnel d'un membre recevait aussi, par `uid == propriétaire`, les repas des groupes de ce
membre dont il n'est pas membre. Le flux d'un planning partagé filtre donc `uid ==
propriétaire` **et** `group_id == null` (index `uid`, `group_id`, `planned_at`) ; une égalité à
`null` ne trouve pas un document sans le champ, et le backfill « Portée des groupes et des
plannings » (§7.10) pose `group_id: null` sur les repas antérieurs ; d'ici là, un repas
antérieur sans le champ ne se lit plus par le partage, ni un par un ni par requête. Le titulaire garde sa
requête `uid == moi` sans filtre (« Mon planning », archive, reprise de « Nouveau planning ») :
les repas qui portent un `group_id` y sont écartés côté client, et un repas antérieur non encore
marqué lui reste visible. La fenêtre de variété lit tous les repas du cuisinier
(`getCookedMealsBetween`, et `readServedHistory` côté serveur sur `uid ==`). La suppression
d'un groupe supprime ses repas (`deleteGroupMeals`, appelé par `syncGroupReach`), et ses
suggestions de repas (`meal_suggestions`, §3.7 bis). Les repas
personnels d'un propriétaire se lisent, en lecture seule, par les comptes de `planning_reach`
(§3.8 quater) : le client ouvre **un flux par planning affiché** (`uid == propriétaire`,
`group_id == null`, `planned_at` sur 90 jours, `PlanningRepository.watchSharedMeals`), jamais
une requête `in`.
Le client n'affiche sur un repas d'autrui ni `justification`, ni `choice_source`, ni
menu, ni heure modifiable. L'écran d'un planning partagé couvre les 90 derniers jours et la suite ;
il ne propose l'archive plus ancienne que pour son propre planning. C'est une limite du
client : la règle ne borne pas `planned_at`, et l'audience peut lire tout l'historique du
propriétaire par une requête directe. Sa recette se résout par une lecture groupée
(`readableRecipeIds`, lots de 30, repli recette par recette sur refus) : une recette refusée
s'affiche par `recipe_titre` avec « Recette non partagée », sans élargir la lecture des
recettes. Les refus d'un lot sont remontés une fois par lot au rapport d'erreurs
(`planning.shared_recipe_denied`, avec leur nombre). Si la résolution échoue, le repas
s'ouvre quand même : la fiche affiche « Recette non partagée » sur un refus.

**Champs lisibles par l'audience (décision provisoire, v0.23.47).** La règle de lecture
porte sur le document entier : un compte de `planning_reach` lit tous les champs d'un repas
partagé, dont `justification`, `choice_source`, `dismissed_recipe_ids` et
`components[].justification`, sur tout l'historique du propriétaire. Le client ne les affiche pas sur un repas d'autrui. Ce n'est
pas une protection : un client modifié les lit. Ce choix est accepté et documenté en
attendant une décision.

| Champ | Type | Description |
|---|---|---|
| `uid` | `String` | Le cuisinier : propriétaire du planning personnel, ou propriétaire du groupe pour un repas de groupe. Figé |
| `group_id` | `String?` | Groupe dont ce repas fait partie du planning ; `null` = planning personnel. Toujours écrit par le client, `null` compris : le flux d'un planning partagé filtre `group_id == null`. Absent sur un repas antérieur jusqu'au passage du backfill `group_planning_reach`, qui le pose à `null`. Figé côté client ; seul le backfill `move_meals_to_group` le change, de `null` (ou absent) vers un groupe de l'appelant |
| `recipe_id` | `String?` | Recette servie ; `null` pour un créneau resté vide |
| `recipe_titre` | `String` | Titre dénormalisé, pour afficher sans lire la recette |
| `planned_at` | `Timestamp` | Date et heure du repas |
| `duration_minutes` | `int` | Durée totale, pour l'export calendrier |
| `prep_minutes` · `cook_minutes` | `int?` | Détail des deux temps |
| `base_portions` | `int?` | Parts de la recette d'origine |
| `target_portions` | `int?` | Parts voulues ce jour-là — avec `base_portions`, c'est **tout** ce qu'il faut pour recalculer les quantités à l'affichage |
| `prep_date` | `Timestamp?` | Jour de préparation, quand il diffère du jour du repas |
| `justification` | `String?` | Pourquoi ce plat, ce jour-là. Depuis v0.23.18, des **faits produits par le serveur** (`codeJustification`, `gemini/planning.ts`) : protéine lue dans les types de plat, durée sous la limite du jour, note personnelle ≥ 8, dernier service (« pas servie depuis 6 semaines »), « peu d'autres choix » quand un filtre s'est relâché — jamais un texte du modèle ; pour une recette conçue, la justification de la conception. Le client n'écrit plus de phrase générique de repli. Il appartient au **repas** et non à la recette : il parle de cette date, de la contrainte de ce jour et de la variété du cycle. Sur la recette, il aurait menti au prochain qui la planifie |
| `dismissed_recipe_ids` | `List<String>?` | Recettes écartées de ce repas — par « Changer la recette », « Vider le créneau », une nouvelle suggestion, et déjà pendant la composition d'un cycle. Le client les retire des candidats **avant** l'appel à l'IA : une consigne dans le prompt est un vœu, un candidat absent de la liste est une certitude. Elles appartiennent au repas, pas au profil : écarter un plat un mardi ne dit rien du samedi suivant. Ajoutées par `arrayUnion`, jamais retirées |
| `choice_source` | `String?` | **Qui a choisi la recette** : `ai` (le modèle, parmi les candidats présélectionnés), `rules` (le code de Kass'Dalle, sans modèle : « Autre suggestion », panne du modèle, plafond), `concept` (recette conçue par l'IA), `manual` (l'utilisateur). Écrit à la validation d'un cycle et à chaque changement de recette depuis le planning ; « Remettre à blanc » le retire, avec `justification`. L'écran affiche la ligne d'origine « Choisie par l'IA » · « Choisie par Kass'Dalle » · « Conçue par l'IA » · « Choisie par vous », suivie de `justification`. Absent sur un repas antérieur à v0.23.18 : pas de ligne d'origine, et une `justification` « Sélection manuelle… » est lue comme `manual`. Aucun backfill |
| `components` | `List<Map>?` | **Ce qui accompagne le plat.** Une entrée par composant : `role` (`accompagnement` \| `entree` \| `dessert`), soit `recipe_id` (une recette d'accompagnement), soit `staple_id` (une garniture), `label`, et pour une garniture la part **figée** au choix — `quantity_per_portion`, `unit`, `shopping_product`, `note` — plus `justification` (« le plat n'apporte pas de féculent : riz, accompagnement classique »). Le plat lui-même n'y figure pas, il reste dans `recipe_id`. Choisi par le **programme** (`side_chooser.dart` : ce que le plat n'apporte pas, ses accompagnements classiques, les garnitures visibles du compte, rotation sur les jours voisins), jamais par le modèle au moment du planning. L'**entrée** et le **dessert**, eux, viennent du même appel de planning que le plat, quand le format du jour (`meal_format`) en demande, parmi les recettes de ce rôle, une fois chacun dans le cycle (`starter_id`, `dessert_id`). Absent = aucun composant |
| `created_at` | `Timestamp` | Création |

---

### 3.7 bis Collection `meal_suggestions` — les suggestions de repas (v0.23.58)

Un membre d'un groupe actif, autre que son propriétaire, lecteur compris, suggère au
propriétaire un plat pour un jour du planning du groupe. Pas de statut : le propriétaire
lit, et planifie lui-même ce qu'il retient (« Planifier ce jour-là », qui écrit un
`planned_meals` ordinaire). La suggestion n'est jamais modifiée ; « Au planning » se calcule
à l'affichage (`plannedMatchFor`, `meal_suggestion.dart` : même groupe, même jour, même
recette ou même titre sans casse). Aucun appel d'IA, aucun poste de coût.

| Champ | Type | Description |
|---|---|---|
| `group_id` | `String` | Le groupe, 128 caractères au plus |
| `group_owner_id` | `String` | Le propriétaire du groupe, **dénormalisé** et vérifié à la création contre `groups/{group_id}.owner_id` (figé) : la requête du propriétaire, `group_owner_id == moi`, est prouvable par les règles |
| `author_uid` | `String` | L'auteur ; égal à l'appelant à la création |
| `day` | `String` | Le jour visé, `AAAA-MM-JJ` (jour local de l'auteur). Les règles exigent une date réelle (`isSuggestionDay` : mois 1 à 12, jour cohérent via `timestamp.date`) dont la fin tombe au plus tôt un jour avant `request.time` (la veille UTC passe, pour le décalage de fuseau) et le début au plus tard 60 jours après. Le client propose aujourd'hui à aujourd'hui + 59 jours (`kSuggestionDaysAhead`, marge d'un fuseau en avance sur UTC) |
| `recipe_id` | `String?` | La recette suggérée — exclusif de `free_title` |
| `recipe_titre` | `String?` | Le titre de la recette, **copié** (200 caractères au plus) : le propriétaire le lit si la recette lui est fermée (privée), sans ouvrir la fiche (« Recette non partagée »). Une recette qu'il lit s'affiche sous son titre actuel, relu par `PlanningRepository.readableRecipeTitles` : un auteur ne fait pas passer un autre texte sous le nom d'une recette ouverte |
| `free_title` | `String?` | Un nom libre, 1 à 60 caractères — exclusif de `recipe_id` et `recipe_titre` |
| `note` | `String?` | Le mot de l'auteur, 200 caractères au plus ; absent s'il est vide |
| `created_at` | `Timestamp` | Heure du serveur (`request.time`), seule valeur admise |

**Identifiant imposé.** `{group_id}_{author_uid}_{day}_{n}`, n de 0 à 4
(`suggestionIds`, règles ; `mealSuggestionId`, client). Le client lit ses suggestions du
jour pour ce groupe (trois égalités, sans index composite) et prend le premier n libre ;
une suggestion retirée libère le sien, et « Annuler » la recrée sous le même identifiant.

**Lectures du client** (`MealSuggestionRepository`, `features/planning/data/`) : le
propriétaire, `group_owner_id == moi` et `day` d'aujourd'hui − 90 jours à aujourd'hui +
60 jours, triées par `day`, 500 au plus (`watchReceived`) ; l'auteur, `author_uid == moi`
sur la même fenêtre (`watchSent`).
« Voir les plus anciennes » lit `day <` cette borne, du plus récent au plus ancien, 100 au plus
(`loadOlder`). Quatre index composites : (`group_owner_id`, `day` croissant et décroissant),
(`author_uid`, `day` croissant et décroissant). Un document mal formé est écarté, et signalé
une fois par lecture (`meal_suggestions.malformed`). Les flux ne s'ouvrent que pour un
propriétaire d'un groupe actif qui compte un autre membre, ou pour un membre d'un groupe actif
d'un autre propriétaire (`suggestionOwnerGroups`, `suggestableGroups`).

**Plafond.** Cinq suggestions au plus par auteur, par groupe et par jour
(`kSuggestionsPerAuthorPerDay`), **tenu par les règles** (revue sécurité v0.23.58) : une
sixième n'a pas d'identifiant admis, et réécrire un identifiant pris est une mise à jour,
refusée. Avec le jour borné à soixante et un jours, un membre écrit au plus
5 × 61 suggestions par groupe à un instant donné, chacune de quelques centaines d'octets.

**Suppressions.** L'auteur retire sa suggestion (« Annuler » la recrée sous le même
identifiant, `created_at` reprenant l'heure du serveur) ; le propriétaire peut aussi la
supprimer (règles), sans geste dans l'écran. Le serveur supprime, dans `syncGroupReach`, les
suggestions d'un groupe supprimé (`deleteGroupSuggestions`) et celles d'un membre sorti du
groupe — départ ou retrait par le propriétaire (`departedMembers`,
`deleteMemberSuggestions`), par lots de 400, `retry: true`. Rien d'autre n'est purgé : une
suggestion reste après son jour. Aucune migration : la collection est neuve.

---

### 3.8 Collection `planning_config`

Un document par utilisateur (`{uid}`), écrit depuis « Préférences du planning » par un
éditeur ou un administrateur (un lecteur le relit, il ne l'écrit plus depuis v0.23.47).

| Champ | Type | Description |
|---|---|---|
| `meals_per_cycle` | `int` | Nombre de repas d'un cycle |
| `cycle_start_day` | `int` | Jour de démarrage (1 = lundi) |
| `batch_cooking_day` | `int?` | Jour de préparation groupée |
| `daily_constraints` | `Map<int, …>` | Par jour : temps de préparation maximum, parts visées, batch cooking, notes en langage naturel, heure propre, et `meal_format` — le **format du repas** : `plat` \| `plat_dessert` \| `entree_plat` \| `entree_plat_dessert` \| `leger`. Absent = plat seul, jamais stocké comme tel. C'est le format qui fait demander une entrée ou un dessert à `suggestMealPlanFn`, dans le même appel que le plat (`mealFormatOf`, fixture `planning_slot_rules.json` › `meal_format`) ; une contrainte en prose ne les ouvre plus. Il se change aussi sur un créneau pendant la composition d'un cycle |
| `global_constraints` | `String` | Contraintes valables pour tout le cycle, en langage naturel. **Absent** : le client lit `kDefaultGlobalConstraints` (règles de variété des protéines, féculents et cuisines). Une chaîne vide enregistrée est gardée |
| `default_meal_hour` · `default_meal_minute` | `int` | Heure par défaut d'un repas |
| `default_calendar_duration_minutes` | `int` | Durée d'un événement Google Calendar, depuis tous les points d'export : le repas à table, jamais les temps de la recette (ceux-ci ne servent qu'au rappel et à `duration_minutes` du repas) |
| `calendar_id` · `calendar_name` | `String` | Calendrier Google cible |
| `variety_window_weeks` | `int` | **Fenêtre de variété**, de 0 à 4 semaines (défaut 2, absent = 2, hors bornes = ramené). Un plat servi dans les N semaines qui précèdent le premier jour du cycle n'est pas reproposé. Le client lit ses propres `planned_meals` sur cette fenêtre (`recentlyServedBefore`, `planning_history.dart`) et envoie la liste à `suggestMealPlanFn` ; le serveur retire ces recettes du corpus tant qu'il en reste au moins autant que de créneaux à remplir, du plus récent au plus ancien ; celles qu'il a dû garder restent candidates avec une note de fraîcheur basse (`applyRecentlyServed`, fixture `planning_slot_rules.json` › `recently_served`). Zéro désactive. Depuis v0.23.18, la fenêtre de variété reste lue par le client ; la **note de fraîcheur** de la présélection, elle, est lue par le serveur sur 90 jours de `planned_meals` (voir §6, « Le planning »). |
| `shared_group_ids` | `List<String>` | **Partager mon planning** (v0.23.47) : les groupes familiaux dont les membres voient ce planning, en lecture seule. Absent ou vide = rien n'est partagé (aucune migration). Cochés parmi les groupes dont le compte est membre, propriétaire compris ; 50 au plus (règles). Le serveur ignore un identifiant de groupe disparu, quitté ou mal formé (`sharedGroupIdsOf`). Un propriétaire qui n'est plus éditeur ou administrateur, ou révoqué, garde ses groupes en base : le partage est **suspendu**, et reprend s'il redevient éditeur. Un changement déclenche `syncPlanningReachOnConfig` |
| `group_portions` | `Map<String, int>?` | Parts par défaut des repas de chaque groupe dont le compte est propriétaire (identifiant du groupe → parts). Absent ou groupe absent = nombre de membres du groupe, propriétaire compris (`groupDefaultPortions`). 50 entrées au plus (`isPlanningConfig`). Lu par « Nouveau planning » et un jour libre du planning d'un groupe ; aucun écran ne l'écrit encore |

---

### 3.8 quater Collection `planning_reach` — la portée des plannings

Un document par compte lecteur : les propriétaires dont il peut lire le planning personnel,
et les groupes dont il lit le planning (`planned_meals`). Les règles Firestore le relisent
(§4, `canReadPlanningOf`, `canReadGroupPlanning`) : elles ne peuvent ni parcourir `groups`,
ni croiser les groupes avec le rôle de leur propriétaire.

| Champ | Type | Description |
|---|---|---|
| `uids` | `List<String>` | Propriétaires dont le titulaire lit le planning personnel, sans lui, triés, sans doublon. `owner` y figure quand il est éditeur ou administrateur non révoqué, et qu'un groupe **actif** de son `shared_group_ids` existe et compte `owner` et le titulaire parmi ses **membres** (`owner_id` ou `member_ids`, jamais `invited_ids`). Pas de réciprocité |
| `group_ids` | `List<String>` | Groupes actifs dont le titulaire est membre, propriétaire compris, triés : il en lit le planning (`canReadGroupPlanning`), et, s'il n'en est pas le propriétaire, y suggère un plat (`meal_suggestions`, §3.7 bis). Groupe actif = propriétaire éditeur ou administrateur non révoqué |
| `masked_group_ids` | `List<String>` | Groupes « en pause » : le titulaire en est membre et leur propriétaire ne planifie plus. Lu par le client (`GroupRepository.watchMaskedGroupIds`) : le planning les masque, l'écran Groupes les liste marqués « En pause » (le propriétaire y garde retirer, annuler une invitation, supprimer ; un membre les quitte) ; aucune règle ne le lit. Absent sur un document antérieur : rien n'est en pause |
| `masked_invitation_ids` | `List<String>` | Groupes qui invitent le titulaire et sont en pause. Le client masque ces invitations (`GroupRepository.watchMyInvitations`) ; aucune règle ne le lit. Recalculé pour les invités ajoutés ou retirés d'un groupe (`invitationsToResync`, `syncGroupReach`) et pour les invités des groupes d'un compte dont le rôle change (`syncPlanningReachOnRole`) |
| `updated_at` | `Timestamp` | heure serveur de la dernière écriture |

**Qui l'écrit :** le serveur seul (`triggers/planningReach.ts`, `syncPlanningReachFor`, dans
une transaction qui relit les groupes du titulaire et les groupes qui l'invitent, puis
`planning_config` et `users` de chaque membre, titulaire compris, et du propriétaire de chaque
groupe qui l'invite). Trois déclencheurs :

- `syncGroupReach` (écriture d'un groupe dont la composition change) recalcule, pour les
  mêmes comptes, `group_reach` puis `planning_reach` ; l'un peut échouer sans l'autre. Il
  recalcule aussi `planning_reach` des invités ajoutés ou retirés, et de tous les invités d'un
  groupe supprimé (`invitationsToResync`) : leur `masked_invitation_ids` peut changer ;
- `syncPlanningReachOnConfig` (écriture de `planning_config/{uid}` dont `shared_group_ids`
  change) recalcule les membres des groupes ajoutés ou retirés, `retry: true` ;
- `syncPlanningReachOnRole` (`triggers/plannerRole.ts` ; écriture de `users/{uid}` dont `role`
  ou `is_revoked` fait changer le droit de planifier, `planningShareChanged`) recalcule les
  membres des groupes cochés par ce compte et ceux des groupes dont il est propriétaire, lui
  compris — `planning_reach`, puis `group_reach` de ces derniers —, ainsi que `planning_reach`
  des invités des groupes dont il est propriétaire (`invitedOfOwnedGroups`), `retry: true`. Il lève à l'échec pour que l'événement soit rejoué :
  un éditeur rétrogradé ou révoqué ne doit pas rester lisible. `syncUserClaims` ne s'en
  occupe pas.

Un backfill, « Portée des groupes et des plannings » (`backfillGroupPlanningReachFn`, §7.10),
écrit `group_ids`, `masked_group_ids` et `masked_invitation_ids` sur les comptes antérieurs,
membres et invités de tous les groupes (`groupAccounts`) — sans lui, un membre d'un
groupe que personne n'a touché depuis le déploiement ne lirait pas le planning du groupe —, puis
pose `group_id: null` sur les repas antérieurs, sans quoi un planning partagé n'en montrerait
aucun.
Sans `shared_group_ids` rien n'est partagé, et sans `planning_reach` rien ne se lit. Le même risque accepté que `group_reach` (§3.5 bis) vaut ici : un échec au-delà de la
fenêtre de nouvelles tentatives laisse une portée périmée jusqu'au prochain changement, et se
voit dans Admin › Journaux.

**Qui le lit :** son titulaire (`PlanningRepository.watchPlanningReach`, d'où le client tire
le sélecteur « Plannings affichés ») et un administrateur.

**Ce que l'appareil garde.** Les plannings affichés ne sont pas stockés dans Firestore. Le
défaut dépend du rôle — l'éditeur voit son planning seul, le lecteur tous les plannings
partagés avec lui et pas le sien — et l'appareil mémorise l'**écart** à ce défaut, par compte
et par rôle (`SharedPreferences`, clé `planning_toggled.<editor|reader>.<uid>`,
`planning_visibility_store.dart`).

---

### 3.8 bis Sous-collection `users/{uid}/planning_runs` — les générations de planning

Un document par génération (`suggestMealPlanFn` en mode `model`, y compris quand aucun créneau n'a demandé d'appel de modèle : un corpus vide avec conception IA cochée a besoin du `runId` pour borner ses conceptions), identifiant
`pr_` + 32 hexadécimaux tiré par le serveur. **Écrit par le serveur seul** : il porte le
compteur qui borne les conceptions facturées. Sert de journal des propositions (taux de
répétition, concentration) et de plafond par génération. Conservé 180 jours par une
politique TTL sur `expires_at` (`firestore.indexes.json` › `fieldOverrides`, active au
déploiement des index).

| Champ | Type | Contenu |
|---|---|---|
| `created_at` · `expires_at` | `Timestamp` | heure serveur ; `created_at` + 180 jours |
| `correlation_id` | `String` | fil des journaux de la génération |
| `group_id` | `String?` | groupe dont le planning est généré, `null` pour le planning personnel |
| `cycle_start` | `String` | `YYYY-MM-DD` du premier créneau |
| `slots` | `int` | créneaux du cycle |
| `corpus_size` · `candidates_sent` · `duration_ms` · `rejected_choices` | `int` | recettes reçues, candidats envoyés au modèle, durée, choix du modèle remplacés |
| `history_available` | `bool` | l'historique des repas a été lu |
| `model_status` | `String` | `ok` · `partial` · `failed` · `budget` · `skipped` |
| `provider` · `model` | `String?` | moteur qui a répondu ; `null` sans appel |
| `proposals` | `List<Map>` | `{slot, date, recipe_id, starter_id, dessert_id, source}` — `source` `model` ou `code` |
| `concepts_max` | `int` | conceptions automatiques ouvertes : `concepts_per_generation` au moment de la génération, borné par le nombre de créneaux restés vides (`conceptsAllowance`) — une génération qui a tout rempli n'en ouvre aucune |
| `concepts_used` | `int` | incrémenté en transaction **avant** chaque conception rattachée (une conception en échec a pu être facturée) |
| `cost_cap_usd` | `Number?` | plafond de la génération converti au taux de la facture ; `null` sans taux utilisable (le plafond en euros ne s'applique pas) |
| `cost_usd` | `Number` | somme des coûts enregistrés (`recordedCostUsd`) de l'appel de planning et des conceptions |
| `reserved_usd` | `Number` | coût estimé des conceptions réservées dont le coût réel n'est pas encore reporté : augmenté dans la transaction de réservation, diminué par `addPlanningRunCost`. Une conception en échec garde sa réservation, ce qui rend le plafond plus strict, jamais plus large |
| `unpriced_calls` | `int` | appels sans montant (grille illisible) |

Le coût d'une génération se relit aussi dans `ai_usage` : chaque ligne de l'appel de
planning et des conceptions rattachées porte `entity_type: "planning_run"` et
`entity_id: <runId>`. `ai_usage` reste la source d'audit ; `cost_usd` sert au plafond.

---

### 3.8 ter Document `users/{uid}/preferences/planning_refusals` — la mémoire des refus

Depuis v0.23.22. Un seul document par compte. Il retient les recettes **proposées** que le
titulaire a écartées, pour qu'elles pèsent moins dans les générations suivantes. Écrit par
le client (`PlanningRefusalsRepository`, `features/planning/data/`), lu par
`suggestMealPlanFn` pour l'appelant seul (`readUserRefusals`, `gemini/planningStore.ts`).
Rien n'est écrit dans la recette partagée : un refus de l'un ne pénalise pas la recette pour
un autre membre.

| Champ | Type | Contenu |
|---|---|---|
| `entries` | `Map<String, Map>` | clé : `recipeId` ; valeur : `refused_at` (`Timestamp`, dernier refus) et `count` (`int` ≥ 1, refus depuis le premier encore actif). 300 entrées au plus (`kRefusalMaxEntries` / `REFUSAL_MAX_ENTRIES`), les plus anciennes sortent |
| `updated_at` | `Timestamp` | heure serveur de la dernière écriture |

**Ce qui compte comme un refus.** Une recette dont l'origine (`choice_source`, ou l'origine du
créneau pendant la composition) est `ai`, `rules` ou `concept`, écartée par « Autre
suggestion », « Changer la recette », « Tout régénérer », ou remplacée par une conception sur
un repas planifié (`countsAsRefusal`, `planning_refusals.dart`). Ne comptent pas : une recette
choisie à la main ou d'origine inconnue (repas antérieur à `choice_source`), « Réessayer avec
l'IA » après une panne, « Remettre à blanc », le retrait d'une recette d'un créneau, la
suppression d'un repas. Dans Nouveau planning, les refus de la session s'écrivent **à la
validation du cycle**, en une transaction : un cycle abandonné n'en laisse aucun, et une
recette écartée puis reprise dans le cycle n'est pas refusée. Sur un repas déjà planifié, le
refus s'écrit au remplacement.

**Écriture** (`record`, transaction) : les entrées de plus de 21 jours sortent ; un refus
encore actif voit `count` augmenter et `refused_at` avancer ; sinon `count` repart à 1. Un
échec est remonté au rapport d'erreurs (`planning.recordRefusals`) et ne bloque pas le geste.
**Lecture serveur** (`readRefusals`, donnée non fiable) : entrée sans date lisible ignorée,
compte illisible = 1, entrées de plus de 21 jours ou datées de plus d'un jour dans le futur
ignorées (`REFUSAL_FUTURE_TOLERANCE_DAYS` : l'horloge d'un téléphone peut avancer, une date
lointaine ne s'éteindrait jamais), 300 au plus. Le client applique le même prédicat
(`isActiveAt`) pour élaguer et compter. Lecture en échec :
`logError`, génération sans pénalité de refus.

**« Oublier mes refus »** (Préférences du planning) supprime le document. Pas de backfill : le
document naît au premier refus.

---

### 3.8 quinquies Document `users/{uid}/shopping/current` — le panier de courses

Un seul document par compte : la liste de courses du titulaire, la même sur tous ses
appareils, lue en temps réel (`myShoppingCartProvider`). Écrit et lu par le client seul
(`ShoppingCartRepository`, `features/recipes/data/`) ; aucune Cloud Function ne le touche.
Les produits ajoutés depuis le repas d'un autre membre vont dans le panier de **celui qui
ajoute** : rien n'est écrit dans la recette, dans le repas ni dans le planning d'origine. Les
quantités suivent les parts du repas (`planningScaleRecipeForMeal`), calculées en mémoire.

| Champ | Type | Contenu |
|---|---|---|
| `items` | `Map<String, Map>` | clé : l'identité du produit (`shoppingProductKey` du nom, 200 caractères au plus) ; valeur : un article. 300 articles au plus (`kShoppingCartMaxItems`, même borne dans les règles) |
| `items.*.name` | `String` | nom du produit acheté, 200 caractères au plus |
| `items.*.quantities` | `List<Map>` | une entrée `{qty: String, unit: String}` par famille d'unité (« 400 ml + 250 g »), 10 au plus, 40 caractères par champ |
| `items.*.category` | `String` | rayon (`IngredientCategorizer`), 60 caractères au plus |
| `items.*.source` | `String?` | d'où vient la ligne : « Curry de poulet (400 ml) · Riz (250 g) », 500 caractères au plus |
| `items.*.checked` | `bool` | article déjà dans le panier |
| `items.*.pos` | `int` | rang d'ajout, pour l'ordre d'affichage dans un rayon |
| `updated_at` | `Timestamp` | heure serveur de la dernière écriture |

**Pourquoi une carte et pas une liste.** Cocher une case écrit le seul champ
`items.<clé>.checked` (`update` par `FieldPath`) : l'écriture part aussi hors ligne, dans le
magasin, et deux appareils qui cochent des articles différents ne s'écrasent pas. « Retirer les
articles cochés » supprime les clés montrées cochées (`FieldValue.delete()`) ; « Vider la
liste » écrit une carte vide.

**Ajouter et remplacer** passent par une transaction (`addItems`) : la fusion part de la liste
à jour. « Ajouter » fusionne (`mergeShoppingItems` : même produit → même ligne, quantités
additionnées famille par famille par `mergeShoppingProducts`, provenances réunies ; une ligne
cochée qui reçoit une quantité redevient à acheter). « Remplacer » écrit les seuls nouveaux
articles et rend l'ancienne liste, que « Annuler » réécrit (`restore`). Un résultat de plus de
300 articles lève `ShoppingCartFullException` et n'écrit rien. Une transaction exige le
réseau : hors ligne, l'ajout échoue avec un message, la case cochée non.

**Lecture tolérante.** Un article sans nom ou mal formé est écarté, le reste s'affiche ; un
document absent est un panier vide.

**Reprise de l'ancienne liste locale** (`migrateLocalList`, côté client, pas de backfill). Avant
ce document, la liste vivait dans `SharedPreferences` (`sl_items_{uid}`, `sl_date_{uid}`),
valable le jour même, propre à un appareil. À la première lecture du panier sur un appareil, si
`sl_items_{uid}` existe et que le panier Firestore est vide, ses lignes y sont écrites (en
transaction, après fusion des doublons) ; dans tous les cas, les deux clés locales sont
ensuite effacées. Un panier déjà rempli depuis un autre appareil fait foi. Un texte local
illisible est remonté (`shopping.migrateLocal.parse`) et la clé effacée ; un échec d'écriture
est remonté (`shopping.migrateLocal`), les clés restent pour le lancement suivant, et le panier
s'affiche quand même.

**Erreurs.** Chaque écriture en échec est remontée par le repository
(`shopping.load`, `shopping.addItems`, `shopping.restore`, `shopping.setChecked`,
`shopping.removeItems`, `shopping.clear`), sans attendre l'écriture du rapport, puis relancée à
l'écran qui la dit.

---

### 3.9 Collection `recipe_ratings`

Une note personnelle sur 10, clé `{uid}_{recipeId}` : une note appartient à celui qui la
donne, pas à la recette.

| Champ | Type | Description |
|---|---|---|
| `user_id` | `String` | Auteur de la note, figé |
| `recipe_id` | `String` | Recette notée, figée |
| `rating` | `int` | De 0 à 10 ; 0 est une vraie note |
| `updated_at` | `Timestamp` | Dernière modification |

La fiche recette lit toutes les notes d'une recette par `where recipe_id ==`
(`RecipeRatingRepository.watchAllForRecipe`) ; la règle de lecture prouve cette requête par
son `get()` sur `recipe_id`, et `rules-tests` le vérifie. Le filtre par groupe se fait côté
client (`familyRatingsProvider`, `FamilyRatings.from`) : ne restent que les notes des membres
de `groupMemberIdsProvider` dont le profil public existe, plus la mienne. La moyenne est
dérivée à l'affichage et n'est stockée nulle part. Aucun index composite : le tri par date se
fait côté client. Le planning ne lit que la note de l'utilisateur (`getAllForUser`).

Depuis v0.23.18, `suggestMealPlanFn` lit les notes **de l'appelant seul**
(`where user_id == uid`, `readUserRatings`, `gemini/planningStore.ts`) : jamais celles des
autres membres. Une note ≤ 3 exclut la recette des propositions (elle reste choisissable à la
main) ; de 4 à 6, poids ÷ 2 ; ≥ 8, poids × 1,5 ; 7 ou sans note, inchangé.

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
| `shopping_product` | `String?` | Le produit qu'on achète, sur la liste de courses : « beurre » pour `beurre_fondu`, « œuf » pour `jaune_d_oeuf`. **Absent** : jamais examiné. **Vide** : le nom est déjà le produit. Posé automatiquement à l'import pour un ingrédient neuf (`recipeNutritionAutoSync.ts`, poste `shopping_product_alias_auto`), rattrapé pour le passé par le backfill « Produit acheté des ingrédients » (mode `aliases` de `backfillShoppingFn`, poste `backfill_shopping_aliases`), passé au complet puis retiré le 5 octobre 2026, corrigé à la main depuis *Admin › Référentiels › Ingrédients* — l'une des deux écritures du référentiel ouvertes au client, à un administrateur, avec les allergènes. Les deux passes automatiques partagent la même résolution (`shoppingAliases.ts`) : quand le produit proposé par le modèle correspond à un ingrédient déjà connu du référentiel, son orthographe exacte est reprise plutôt qu'une variante inventée — « beurre fondu » ne crée pas un second « Beurre » qui ne fusionnerait pas avec l'existant. Lu par `onRecipeWritten` quand il compose `shopping_products` |
| `shopping_product_source` | `String?` | `ai_estimated` \| `admin` |
| `allergens` | `String[]?` | Allergènes majeurs de l'ingrédient, clés de la liste de l'annexe II INCO (fixture `allergens.json`). **Absent** : jamais examiné. **Vide** : examiné, aucun. Posé par le modèle (`allergenExamination.ts`, lots de quarante, schéma JSON fermé) pour un ingrédient de la recette pas encore examiné, juste après sa création par `syncRecipeNutrition` (poste `allergens_auto`), ou par le backfill « Allergènes des ingrédients et des recettes » (poste `backfill_allergens`). **Jamais redemandé** une fois posé, et **jamais écrasé** par le modèle : l'écriture est conditionnelle, dans une transaction. L'examen ne **crée** jamais de document : un document créé avec ce seul champ ferait échouer le `create` de la nutrition, qui ne poserait plus ni `canonical_name`, ni `per100g`, ni le produit acheté. Corrigé à la main depuis *Admin › Référentiels › Ingrédients* ; les recettes ne le reprennent qu'au backfill ou à la prochaine modification de leurs ingrédients |
| `allergens_source` · `allergens_at` | `String?` · `Timestamp?` | `ai_estimated` \| `admin` ; date de l'examen ou de la correction. Enregistrer sans changement depuis l'écran passe la source à `admin` |
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
| `ai_usage/{id}` | **Une ligne par appel** : `uid`, `feature`, `provider`, `model`, jetons d'entrée (résultat d'outil de la recherche Google compris), de sortie, de réflexion, de cache (écriture et lecture), `image_output_count`, `analyzed_image_units` (image ANALYSÉE, facturée à l'unité — sans lui, une reconstruction qui rechiffre rendait un appel Cloud Vision à zéro), `grounded_search_count` (`int`, 0 ou 1 : appel ancré dans la recherche Google, facturé à l'appel ; absent des lignes antérieures à octobre 2026, lu comme 0), `estimated_cost_usd`, `status`, `cost_bucket`, `correlation_id`, `scan_id` (le scan de l'utilisateur, quand l'appel en vient un — c'est lui qui rend le coût d'un scan additionnable en une requête), `call_id` (le même identifiant que les lignes de journal de cet appel : c'est lui qui met un montant exact en face d'un appel dans l'écran des journaux, sans rapprochement par l'heure), `entity_type`, `entity_id`, `period`, `timestamp`. Un appel passé pendant une panne de grille porte en plus `pricing_unavailable: true` — c'est lui qui le rend retrouvable pour un rechiffrage |
| `token_usage/{uid}` | Agrégat par compte : total de jetons, coût, et le détail `features.{poste}` |
| `ai_usage_monthly/{AAAA-MM}` | Agrégat mensuel lu tel quel par l'écran des coûts : totaux (dont `total_unpriced_calls`, `total_analyzed_image_units` et `total_grounded_searches`), puis les ventilations `by_feature` (dont `by_provider` **dans** le poste, seule façon de juger une bascule), `by_provider`, `by_model` et `by_user`. `by_feature` et `by_model` portent `analyzed_image_units` (la seule quantité dont dépend une franchise mensuelle) et `grounded_searches` (appels ancrés dans Google, à rapprocher de la ligne « grounding » de la facture). `getMonthlyCostsFn` rend ce dernier total en `ai.groundedSearches` |
| `ai_daily_spend/{uid}_{AAAA-MM-JJ}` | Ce que le plafond relit avant chaque appel : `uid`, `day`, `calls`, `cost_usd`, `unpriced_calls` (incrémentés par `recordUsage` après l'appel — d'un appel, ou du nombre d'images analysées pour la relance de modération, `dailyCalls`, depuis v0.23.48), `updated_at`, et `reservations` (`Map<String, {at_ms: Number, usd: Number, feature: String}>`, depuis v0.23.10) — les appels en cours, réservés avant de partir et retirés à leur fin ; une entrée de plus de quinze minutes est ignorée puis supprimée. Aucune reprise : un document sans `reservations` se lit comme « rien en cours ». Un document par jour : aucune remise à zéro à planifier, et l'historique reste lisible tel quel — `getAiBudgetFn` accepte un paramètre `day` (`AAAA-MM-JJ`), ce qui permet à Admin → Dépense par utilisateur de remonter à une journée passée. Un second paramètre, `scope` (`months` par défaut, ou `day`), ramène **le tableau entier** à cette journée : l'agrégat mensuel n'ayant pas de dimension jour, la ventilation par compte et par poste est alors reconstruite depuis `ai_usage` sur les bornes UTC du jour, par pages de mille lignes et jusqu'à vingt mille — au-delà, la réponse porte `spendsTruncated: true` et l'écran annonce des montants incomplets. Deux paramètres `from` et `to` (`HH:MM` UTC, ignorés hors `scope: day`) resserrent la lecture à une partie du jour, la minute `to` comprise ; la réponse rend les bornes appliquées (`spendFrom`, `spendTo`), une fin qui précède le début étant écartée et rendue nulle. Ce mode ne lit aucun document de `ai_usage_monthly`. Le serveur refuse une date impossible ou à venir et retombe alors sur aujourd'hui ; il renvoie `day` (le jour lu) **et** `currentDay` (le jour courant), pour que l'écran sache s'il regarde une journée close |
| `scan_spend/{scanId}` | Compteur de ce qu'un scan a coûté et plafond d'un import de livre. `recordUsage` y ajoute chaque appel qui porte un `scanId` (`cost_usd`, `calls`, `unpriced_calls`). `runBookImport` y pose `limit_usd`, `step_usd` et `user_id` depuis `budget_limit_usd`, jamais à la baisse ; `setImportCeiling` et `raiseImportCeiling` refusent (`ForeignScanError`) un compteur dont `user_id` désigne un autre compte. `recipeProcessor` le relit avant le premier appel de chaque tranche de livre, et avant chaque traduction d'une recette étrangère de la tranche (`assertWithinImportBudget`) et lève `BudgetExceededError` (`reason: import`) quand `cost_usd >= limit_usd` : la tranche part en dead letter `budget_exceeded`. Relancer une tranche depuis la file — `jobDispatcher` voit le job revenir en `queued` — relève le plafond à `cost_usd + step_usd` si, et seulement si, il est atteint. Le contrôle ne vaut que pour le pipeline d'import : la nutrition calculée plus tard sur ces recettes porte le même `scanId` et n'est pas bloquée. Un plafond est en dollars, unité du coût mesuré |
| `ai_reconciliation_monthly/{AAAA-MM}` | Rapprochement entre le coût estimé et le coût facturé |

---

### 3.12 Exploitation — `dead_letters`, `error_reports`

- `dead_letters/{jobId}` : job d'import abandonné après trois tentatives, avec son motif et
  son étape. Relancé ou purgé depuis *Admin › File d'échecs*.
- `error_reports/{id}` : erreurs remontées par le client via `ErrorReportService` —
  `feature`, message, pile, `userId` et un `context` (chaîne JSON depuis v0.23.48, carte
  avant), champs et longueurs bornés par les règles (§7.7). C'est le seul endroit où un
  échec côté client laisse une trace : `debugPrint` est invisible en production.

---

### 3.12 bis Collection `tickets` — bugs, idées et questions des membres

Un ticket créé par un membre approuvé depuis le menu du compte (« Signaler ou proposer »),
publié en Issue sur le dépôt **public** `ChinaFred/KassDalle`, et suivi dans « Mes tickets »
et Admin › Tickets (§5, « Tickets »). Écrit par les Functions seules (`submitTicket`,
`attachTicketScreenshot`, `retryTicketSend`, `githubTicketWebhook`, `ticketsSyncSchedule`),
à une exception : l'auteur pose `seen_by_author_at`. Lu par l'auteur (approuvé, non révoqué)
et par l'administrateur. Le document est **privé** : le nom de l'auteur, son uid et la capture
ne partent jamais sur GitHub.

| Champ | Type | Description |
|---|---|---|
| `type` | `String` | `bug` \| `evolution` \| `feature` \| `question` |
| `title` | `String` | 5 à 100 caractères, une ligne (espaces et retours à la ligne ramenés à une espace) |
| `description` | `String` | 1 à 2 000 caractères, caractères de contrôle retirés sauf retour à la ligne et tabulation |
| `screen` | `String` | Modèle de route go_router (`/recipes/:recipeId`), `autre` ou `inconnu`. Jamais d'identifiant ni de requête : un écran reçu sans la forme d'un modèle (segment autre qu'un littéral en minuscules ou un `:param`) est remplacé par `inconnu` (`routeTemplateOrNull`) |
| `app_version` | `String` | Version de l'application qui a envoyé (`0.23.53+400`), 40 caractères au plus |
| `platform` | `String` | `android` \| `ios` \| `web` \| `windows` |
| `screenshot_path` | `String?` | `tickets/{uid}/{ticketId}/screenshot.png` ou `.jpg`, écrit par `attachTicketScreenshot` ; `null` sans capture |
| `author_uid` | `String` | Compte auteur |
| `created_at` | `Timestamp` | Heure serveur de création |
| `updated_at` | `Timestamp` | Heure serveur de la dernière écriture serveur |
| `status` | `String` | `sending` → `received` → `analyzed` → `validated` → `in_progress` → `delivered` ; fins `refused`, `answered` |
| `status_changed_at` | `Timestamp` | Dernier changement visible du suivi : changement de statut, ou réponse arrivée sur un ticket déjà clos. Allume le point de notification du compte quand `status` ∈ {`answered`, `refused`, `delivered`} et que `seen_by_author_at` est absent ou antérieur |
| `seen_by_author_at` | `Timestamp?` | Posé par l'auteur à l'ouverture du détail, à `request.time` (seule écriture client permise) |
| `github_issue_number` | `int?` | Numéro de l'Issue, `null` tant que l'envoi n'a pas abouti |
| `github_url` | `String?` | Adresse de l'Issue, montrée à l'administrateur seulement |
| `send_attempts` | `int` | Essais d'envoi en échec. À 10 (`TICKET_MAX_SEND_ATTEMPTS`) sans numéro d'Issue, le ticket est « en anomalie » et la tâche horaire ne le reprend plus. Un jeton GitHub absent ou refusé n'use pas les essais |
| `last_send_error` | `String?` | Dernière erreur d'envoi (300 caractères au plus, jamais le jeton), `null` après un envoi réussi |
| `reply_text` | `String?` | Réponse de l'administrateur : le dernier commentaire du compte `ChinaFred` (identifiant numérique 16348852) qui commence par « Réponse : », préfixe retiré. Réponse à une Question, motif d'un refus |
| `send_lease_until` | `Timestamp?` | Champ technique : bail de deux minutes posé pendant un envoi, pour qu'un « Relancer l'envoi » et la tâche horaire ne publient pas deux Issues. Retiré à la fin de l'envoi |

**Correspondance GitHub → statut** (`statusFromIssue`, `nextTicketStatus`,
`functions/src/tickets/rules.ts`, logique serveur seule) :

| État de l'Issue | Statut |
|---|---|
| créée (étiquettes `source:app`, `type:<type>`, `statut:à-analyser`) | `received` |
| étiquette `statut:analysé` | `analyzed` |
| étiquette `validé` | `validated` |
| PR ouverte dont le corps porte un mot-clé de fermeture (« Closes #N », « Fixes #N », « Resolves #N »), et dont l'auteur est le mainteneur ou un `OWNER`, `MEMBER` ou `COLLABORATOR` du dépôt (`isTrustedPrAuthor`) | `in_progress` |
| fermée `completed` | `delivered`, ou `answered` pour une Question |
| fermée `not_planned` (ou `duplicate`) | `refused` |

Un statut ne recule jamais : une étiquette retirée ou une PR refermée ne le font pas
redescendre. Une fin suit l'Issue : rouverte, elle ramène au statut dérivé de ses étiquettes.

**Plafonds.** `ticket_quotas/{uid}_{AAAAMMJJ}` (`uid` `String`, `day` `String`, `count` `int`,
`expires_at` `Timestamp`) et `ticket_quotas/_global_{AAAAMMJJ}` (mêmes champs sans `uid`),
jour calendaire Europe/Paris (`parisDay`). Lus et incrémentés dans la transaction de
`submitTicket` qui crée le ticket. `expires_at` vaut la création + 7 jours ; une politique TTL
(`firestore.indexes.json` › `fieldOverrides`) supprime les compteurs. L'administrateur n'a pas
de plafond et n'incrémente pas le compteur de la famille. Aucun accès client.

**Index.** Aucun index composite : « Mes tickets » filtre sur `author_uid` et trie côté
client, Admin › Tickets trie sur `created_at` seul, et les requêtes serveur (`status ==`,
`status in`, `github_issue_number ==`) se servent des index simples.

**Migration :** aucune. Les deux collections naissent vides ; `app_config/tickets` n'a pas
besoin d'être semé (§3.13).

---

### 3.13 Collection `app_config` — les décisions

Un document par décision. Aucune ne demande de déploiement pour changer.

| Document | Ce qu'il décide |
|---|---|
| `ai_routing_policy` | Quel moteur sert quel poste, et les budgets de réflexion |
| `ai_pricing` | La grille tarifaire — **plus aucun prix n'existe dans le code** ; la table du serveur ne sert qu'à semer ce document au premier démarrage. Par modèle (`models.{id}`) : `input_per_million`, `output_per_million`, `image_output_per_unit`, `analyzed_image_per_unit`, `free_units_per_month`, `grounded_search_per_unit` (`Number`, prix d'un appel ancré dans la recherche Google), `introductory` |
| `ai_budget_policy` | Plafonds quotidiens par compte, en euros et en nombre d'appels, et le seuil d'alerte mensuel |
| `app_check_policy` | Mode d'attestation : `off`, `monitor`, `enforce` |
| `image_moderation` | Seuils, labels culinaires, moteur retenu |
| `planning_policy` | Présélection du planning : `plats_per_slot` (5, de 3 à 10), `starters_per_slot` et `desserts_per_slot` (3, de 1 à 10), `ranked_depth` (15, de `plats_per_slot` à 30 — profondeur de la liste gardée pour « Autre suggestion »), `concepts_per_generation` (2, de 0 à 7), `cost_cap_eur_per_generation` (0,50, de 0,05 à 5). Lu par `getPlanningPolicy` (cache 60 s), borné par `readPlanningPolicy` ; absent ou illisible : valeurs par défaut du code — ce sont des réglages, pas des prix. Aucun écran ne l'édite encore : il s'écrit depuis la console par un admin |
| Politique nutrition | Seuils d'affichage, repli, priorité des sources |
| `tickets` | Plafonds des tickets : `per_member_per_day` (`int`, 5 par défaut) et `global_per_day` (`int`, 30 par défaut). Document absent : `submitTicket` applique 5 et 30, réglage par défaut du produit. Champ présent mais pas un entier positif : l'envoi est refusé (`failed-precondition`) plutôt qu'un plafond inventé. Lisible par tout compte approuvé (le formulaire annonce les envois restants), écrit par un administrateur. Le client lit `per_member_per_day` sans recopier le réglage par défaut du serveur (`fetchPerMemberDailyLimit`, `ticket_repository.dart`) : document ou champ absent → plafond inconnu, sans rapport, et le formulaire attend `remaining_today` du premier envoi ; valeur qui n'est pas un entier strictement positif → plafond inconnu et rapport d'erreur `tickets`. Ainsi la valeur 5 n'existe que côté serveur. Aucun semis : l'absence est un état lu et documenté |
| `tickets_status` | État du jeton GitHub des tickets : `token_invalid_since` (`Timestamp?`), posé au premier refus du jeton (401, 403 hors limite de débit, 404 sur le dépôt) ou quand le secret est vide, effacé au premier appel GitHub réussi. Lu par l'administrateur seul (bandeau d'Admin › Tickets), écrit par le serveur seul — les règles refusent l'écriture client, administrateur compris |

`ai_routing_policy` porte un champ de plus, `presets_seeded_at` : la marque du
jour où la politique en vigueur a été recopiée dans une première configuration.
Elle empêche cette configuration de revenir après une suppression volontaire.

Des documents de plus ne décident rien : ce sont les **points de reprise** des
backfills (§7.10). Le serveur les écrit via `setBackfillCursor`
(`callable/_backfillCursor.ts`). Aucun code client ne les écrit, mais les règles
Firestore ne l'interdisent pas : un `admin` peut écrire sur tout `app_config`.

| Document | Écrit par |
|---|---|
| `nutrition_catch_up_checkpoint` | `backfillNutritionFn`, passage manuel seulement : le passage programmé repart du début à chaque fois, comme l'ancienne tâche de 5 h |
| `shopping_products_backfill_checkpoint` | `backfillShoppingFn` |
| `recipe_roles_backfill_checkpoint` | `backfillRecipeRolesFn` |
| `recipe_protein_backfill_checkpoint` | `backfillRecipeProteinFn`, retiré en v0.23.52 : le document reste en base, plus rien ne l'écrit ni ne le lit |
| `allergens_ingredients_backfill_checkpoint` | `backfillAllergensFn` — curseur du parcours du référentiel |
| `allergens_recipes_backfill_checkpoint` | `backfillAllergensFn` — curseur du recalcul des recettes |
| `estimated_times_backfill_checkpoint` | `backfillEstimatedTimesFn`, retiré en v0.23.52 : le document reste en base, verrou `running_until` compris, plus rien ne l'écrit ni ne le lit |
| `user_profiles_backfill_checkpoint` | `backfillUserProfilesFn`, retiré en v0.23.23 : le document reste en base, plus rien ne l'écrit ni ne le lit |
| `group_reach_backfill_checkpoint` | `backfillGroupReachFn`, retiré en v0.23.23 : le document reste en base, plus rien ne l'écrit ni ne le lit |
| `group_planning_reach_backfill_checkpoint` | `backfillGroupPlanningReachFn` : `last_doc_id`, le dernier repas planifié parcouru par la phase des repas ; `null` quand `planned_meals` a été parcourue en entier |
| `backfill_cursor_enrich_referentials_ingredients` | `backfillEnrichReferentialsFn`, remplissage normal |
| `backfill_cursor_refresh_sodium_ingredients` | `backfillEnrichReferentialsFn`, réparation du sodium |

| Champ | Type | Contenu |
|---|---|---|
| `operation` | `String` | le nom du backfill |
| `last_doc_id` | `String?` | le dernier document traité ; `null` quand le passage est terminé, et l'appel suivant repart du début. Pour la nutrition, le curseur est la dernière recette **reprise**, et le passage n'est terminé que si la collection a été parcourue **et** qu'aucune recette n'a été laissée |
| `updated_at` | `Timestamp` | heure serveur de la dernière écriture |
| `updated_by` | `String?` | uid de l'admin qui a lancé l'appel |
| `last_report` | `Map?` | ancien compte rendu du dernier passage, écrit jusqu'en v0.23.44 par cinq backfills. Depuis v0.23.45, le compte rendu part dans l'état du backfill (`backfill_run_<clé>`, ci-dessous) ; le champ reste dans les documents existants, plus rien ne l'écrit ni ne le lit |

**État et programmation des backfills** (v0.23.45). Chaque backfill d'Admin › Backfills
est classé **ponctuel** ou **récurrent** dans un registre, `functions/src/backfills/registry.ts`,
et son pendant client `lib/features/admin/domain/backfill_registry.dart` (mêmes clés :
`nutrition`, `enrich_referentials`, `allergens`, `recipe_roles`, `shopping_products` —
récurrents ; `refresh_sodium`, `system_books`, `group_planning_reach`, `move_meals_to_group` —
ponctuels). `move_meals_to_group` est paramétré (groupe, période) et réutilisable : sa passe
rend un reste inconnu (`remaining: null`), il n'est donc jamais marqué terminé tout seul, et
il n'a pas de point de reprise — chaque passage relit les repas de sa période. Il partage son verrou avec `group_planning_reach` (`LOCK_GROUPS`) : les deux écrivent
`planned_meals.group_id`, et l'un refuse de partir pendant que l'autre tourne. Les ponctuels `recipe_protein`,
`estimated_times` et `planning_defaults` sont retirés en v0.23.52 : leur `backfill_run_<clé>`
reste en base, et l'écran ignore une clé absente du registre. Deux sortes de documents, écrits par le serveur seul — les règles refusent
l'écriture client, administrateur compris (§4) —, lus en continu par l'écran
(administrateurs seulement) :

`backfill_run_<clé>` — l'état d'un backfill, écrit par `backfills/runner.ts` à chaque passage,
manuel ou programmé, et par `setBackfillDoneFn`. Un backfill jamais lancé n'a pas de document.
L'écran les lit par la requête `doc_type == "backfill_run"`.

| Champ | Type | Contenu |
|---|---|---|
| `doc_type` | `String` | toujours `backfill_run` |
| `key` | `String` | clé du registre |
| `dernier_passage_statut` | `String` | `en_cours` (verrou posé) \| `termine` \| `incomplet` \| `erreur` |
| `en_cours_depuis` | `Timestamp?` | pose du verrou |
| `en_cours_expire_le` | `Timestamp?` | échéance du verrou, `en_cours_depuis` + dix minutes (`BACKFILL_LOCK_TTL_MS`). Passée, le verrou est celui d'un passage interrompu : il se reprend, et l'écran affiche « En erreur — passage interrompu ». Le client compare l'heure à cette échéance et ne connaît pas la durée |
| `en_cours_id`, `en_cours_origine`, `en_cours_par_uid` | `String?` | identifiant du passage qui tient le verrou, son origine, son auteur ; remis à `null` à la fin |
| `dernier_passage_le` | `Timestamp?` | fin du dernier passage |
| `dernier_passage_origine` | `String?` | `manuel` \| `programme` |
| `dernier_passage_erreur` | `String?` | message court quand le passage a levé une erreur, ou « L'auteur de la programmation n'est plus administrateur. » quand un passage programmé a été refusé pour cette raison |
| `arret_plafond` | `bool` | le dernier passage s'est arrêté au plafond de dépense quotidien |
| `reprise_due` | `bool` | un passage programmé est resté incomplet sans toucher le plafond, ou n'a pas tenu dans le tick : la tâche horaire le reprend à l'heure suivante |
| `dernier_creneau` | `String?` | créneau (`AAAA-MM-JJTHH`, heure de Paris) du dernier passage programmé : un créneau ne part qu'une fois |
| `last_report` | `Map?` | réponse complète du dernier passage, liste `aRevoir` comprise (§7.10) |
| `last_correlation_id` | `String?` | fil de journaux du dernier passage |
| `termine_le`, `termine_version`, `termine_par`, `termine_par_uid` | `Timestamp?`, `String?`, `String?`, `String?` | ponctuel terminé : date, version de l'application qui a lancé ou marqué (`0.23.43`, envoyée par le client, `null` si absente), `auto` (passage sans aucun reste : tout parcouru, 0 restant, 0 à revoir) ou `manuel` (marqué depuis l'écran). Retirés par « Remettre à lancer » |
| `updated_at` | `Timestamp` | heure serveur de la dernière écriture |

`backfill_schedules` — la programmation des récurrents, une entrée par clé, écrite par
`setBackfillScheduleFn` : `{ enabled: bool, days: int[] (ISO, lundi = 1), hour: int (0–23),
timezone: "Europe/Paris", programme_par_uid: String, updated_at: Timestamp }`.
`programme_par_uid` est l'administrateur qui a enregistré : les passages programmés qui
appellent un modèle lui sont imputés (plafond quotidien de base, §7.10). Lecture stricte des
deux côtés (`parseSchedule`, `BackfillSchedule.fromMap`, fixture `backfill_schedule.json`) :
jours et heure entiers, sans conversion ; une entrée illisible vaut « non programmé ». Sans
entrée pour `nutrition`, le défaut du registre s'applique (`defaultSchedule` : tous les jours
à 5 h), et `scheduledBackfills` l'écrit (`programme_par_uid: null`) au premier tick. Avant ce
tick, l'écran l'affiche « Tous les jours à 5 h (par défaut) » et l'éditeur en part : un
« Enregistrer » ne coupe pas le rattrapage quotidien. Le défaut est dans les deux registres,
vérifié par la fixture. Une écriture du défaut en échec est journalisée (`logError`) sans
abandonner le tick. Aucune migration manuelle.

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

- `web_search_daily/{uid}_{AAAA-MM-JJ}` : le compteur du plafond de « Chercher sur le web »
  (`uid` `String`, `day` `String`, `count` `int`, `updated_at` `Timestamp`), jour UTC comme
  `ai_daily_spend`. `searchWebRecipesFn` le réserve dans une transaction avant l'appel de
  modèle et le décrémente, dans une seconde transaction, si l'appel de modèle lève une
  erreur (moteur, quota du fournisseur, plafond de dépense). Une réponse rendue par le
  modèle garde sa place, même sans recherche ancrée ni page retenue : elle est facturée. Écrit par
  les Functions seules ; le titulaire et l'administrateur le lisent.
- `web_search_cache/{sha256}` : le cache partagé des recherches web. Clé : SHA-256 de
  `v{WEB_SEARCH_CACHE_VERSION}:` suivi de la requête en minuscules, espaces resserrées,
  accents gardés (`webSearchCacheKey`). La version vaut 2 depuis le tri des pages en
  français d'abord : les entrées écrites avant, sous une clé sans préfixe et avec l'ancien
  prompt, ne sont plus lues, et la politique TTL les supprime à leur `expires_at` (sept
  jours au plus). Aucune reprise de données. Un changement de prompt ou d'ordre des
  résultats incrémente la version. Les résultats sont rangés dans l'ordre servi au client.
  Champs :
  `query` (`String`, la requête normalisée), `results` (`List<Map>` : `url`, `title`,
  `site`, `snippet?`, `directImport` — adresses https de 2 048 caractères au plus ; aucune
  vignette, une entrée plus ancienne qui porte encore `imageUrl` se relit sans ce champ),
  `search_entry_point_html` (`String?`), `web_search_queries` (`List<String>`), `cached_at`
  et `expires_at` (`Timestamp`, sept jours). Rien de propre à un compte. Lu et écrit par
  `searchWebRecipesFn` seule ; une entrée de plus de sept jours est ignorée à la lecture.
  Une politique TTL sur `expires_at` (`firestore.indexes.json` › `fieldOverrides`, active
  au déploiement des index) supprime les entrées périmées ; la suppression TTL peut
  tarder de quelques heures, d'où le contrôle de fraîcheur à la lecture. Une
  recherche sans page retenue n'est pas mise en cache. Aucune reprise de données : la
  collection naît vide.
- `url_import_daily/{uid}_{AAAA-MM-JJ}` : le compteur du plafond d'imports par lien (`uid`,
  `day`, `count`, `updated_at`), jour UTC comme `ai_daily_spend`. Incrémenté par
  `importRecipeFromUrlFn` dans la même transaction que la création du job, relu par
  `getUrlImportQuotaFn`. Une relance depuis la file ne le consomme pas ; elle est bornée par les
règles (`url_retry_count`, deux au plus, §3.4). Écrit par les Functions
  seules ; le titulaire et l'administrateur le lisent.
- `image_moderation/{moderationId}` : décrit en tête de ce document, section *Spécification
  technique — Modération des images*.
- `users/{uid}/nutrition_portion_overrides/{recipeId}` : le nombre de portions choisi par
  **cet** utilisateur. Il vit sous lui, pas dans la recette — sans quoi chacun écraserait le
  choix de l'autre, silencieusement.
- `users/{uid}/preferences/book_order` : `book_ids`, la liste ordonnée des livres telle que
  **ce** lecteur a rangé sa bibliothèque au glisser-déposer, et `updated_at`. Même raison : un
  livre est vu par toute la famille, chacun le range où il veut. Les identifiants disparus sont
  ignorés à la lecture, les livres créés depuis se rangent à la fin.
- `users/{uid}/preferences/planning_refusals` : la mémoire des refus du planning, voir §3.8 ter.
- `users/{uid}/preferences/recipe_search_scope` : `sources` (clés de `RecipeSource` — recettes
  validées, brouillons, recettes famille, conception IA) et `book_ids`, le dernier périmètre
  choisi dans « Où chercher des recettes ? » du planning par lots. Un livre absent de `book_ids`
  est écarté de la recherche — y compris un livre créé depuis le dernier choix, qui se coche à la
  main comme les autres. Une recette sans `book_id` n'est jamais écartée par ce filtre : il ne
  peut pas se prononcer sur elle. Document absent = comportement d'avant ce réglage, recettes
  validées, tous les livres du moment.
- `users/{uid}/preferences/explore_filters` : sources, filtres et tri de l'écran Explorer
  (`/search`), relus à l'ouverture et réécrits une demi-seconde après chaque changement
  (`ExplorePreferencesRepository`, `ExplorePreferences.toMap`). Le texte du champ de recherche
  n'y est pas. Schéma :

  | Champ | Type | Contenu |
  |---|---|---|
  | `sources` | `List<String>` | sous-ensemble de `mine`, `family`, `drafts` (« Mes recettes », « Ma famille », « Mes brouillons ») |
  | `sort` | `String` | `best_rated` (défaut), `fastest`, `newest`, `title` |
  | `filters.dish_types`, `cuisines`, `meal_roles`, `proteins`, `starches`, `difficulties`, `themes` | `List<String>` | clés d'étiquette en minuscules (`recipeTagKey`) ; `themes` couvre thèmes et occasions |
  | `filters.excluded_ingredients` | `List<String>` | mots saisis dans « Sans l'ingrédient… » |
  | `filters.excluded_allergens` | `List<String>` | clés de `kAllergenKeys` |
  | `filters.book_ids`, `author_ids` | `List<String>` | identifiants de livre et de compte, tels quels |
  | `filters.max_total_minutes` | `int?` | 15, 30, 45, 60 ou 120 |
  | `filters.min_rating` | `int?` | 5, 7 ou 8 (note du lecteur, sur 10) |
  | `filters.max_kcal_per_portion` | `int?` | 400, 600 ou 800 |
  | `filters.count_estimated_times` | `bool` | « Compter les durées estimées » ; absent ou illisible : `true`. Gardé par « Effacer tout » (`RecipeFilter.cleared`) |
  | `updated_at` | `Timestamp` | heure serveur de la dernière écriture |

  Une valeur mal formée est ignorée à la lecture (`RecipeFilter.fromMap`) ; document absent ou
  illisible = valeurs par défaut (mes recettes et la famille, sans brouillons, aucun filtre,
  « Mieux notées »). Aucune migration : le document naît à la première modification. Forme
  bornée par les règles (`isExploreFilters`, §4) : seules les clés `sources`, `sort`,
  `filters`, `updated_at`, au plus 10 sources, un tri de 32 caractères, 20 filtres. Le serveur
  ne le lit pas ; le titulaire et un administrateur le lisent.

---

### 3.15 Structure Firebase Storage

```
gs://{bucket}/
├── quarantine/{uid}/…      ← SEULE porte d'entrée des images publiées
├── tickets/{uid}/{ticketId}/screenshot.(png|jpg) ← capture privée d'un ticket, écrite par l'auteur, lue par lui et l'admin
├── covers/{bookId}/…       ← écriture serveur uniquement
├── scans/{uid}/…           ← écriture serveur uniquement
├── illustrations/{uid}/…   ← écriture serveur uniquement
├── recipes/{recipeId}/…    ← écriture serveur uniquement
├── users/{uid}/…           ← couverture « Recette libre », écriture serveur uniquement
└── rejected/{uid}/…        ← images refusées, LECTURE ADMIN uniquement
```

L'import par lien écrit deux fichiers avec l'Admin SDK : le texte de la page sous
`scans/{uid}/web_{jobId}_page_web_{site}.txt`, et la photo du site convertie en JPEG sous
`quarantine/{uid}/web_{jobId}.jpg`, d'où la modération la promeut vers
`recipes/{recipeId}/illus_{horodatage}.jpg`.

Le fichier atterrit en quarantaine, le serveur l'inspecte (extension, type MIME, signature
binaire, taille), la modération le juge, et lui seul le promeut dans un dossier publié. Les
URL de téléchargement des images promues sont stockées dans `recipes.image_urls`.

La capture d'un ticket est la seule autre écriture client : PNG ou JPEG de 5 Mo au plus,
déposée par l'auteur sous son uid après `submitTicket`, puis rattachée au ticket par
`attachTicketScreenshot`, qui vérifie l'auteur, le chemin et l'objet, y compris la signature
PNG ou JPEG de ses premiers octets. Elle n'est jamais publiée — ni dans l'application, ni sur GitHub — et ne passe donc pas par la modération.
Aucune purge en V1.

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

    /// Forme de `users/{uid}/preferences/planning_refusals` :
    /// `{ entries: { recipeId: { refused_at, count } }, updated_at }`.
    function isPlanningRefusals(data) {
      return data.keys().hasOnly(['entries', 'updated_at'])
        && data.entries is map
        && data.entries.size() <= 300
        && (!('updated_at' in data) || data.updated_at is timestamp);
    }

    /// Forme de `users/{uid}/preferences/explore_filters` (écran Explorer).
    function isExploreFilters(data) {
      return data.keys().hasOnly(['sources', 'sort', 'filters', 'updated_at'])
        && (!('sources' in data) || (data.sources is list && data.sources.size() <= 10))
        && (!('sort' in data) || (data.sort is string && data.sort.size() <= 32))
        && (!('filters' in data) || (data.filters is map && data.filters.size() <= 20))
        && (!('updated_at' in data) || data.updated_at is timestamp);
    }

    function founderEmail() {
      return 'china.fred.75@gmail.com';
    }

    // Adresse vérifiée et connexion Google (v0.23.48) : l'adresse seule
    // suffisait, quel que soit le fournisseur.
    function isFounder() {
      return isAuthenticated() && 'email' in request.auth.token
        && request.auth.token.email.lower() == founderEmail()
        && request.auth.token.get('email_verified', false) == true
        && request.auth.token.get('firebase', {}).get('sign_in_provider', '') == 'google.com';
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
      // Couverture « Recette libre » : nulle, ou l'adresse exacte que produit
      // la modération, `users/{uid}/free_recipe_cover_{n}.{ext}` (ni `..`, ni
      // `%2E`, ni `%25`), dans le bucket du projet
      // (v0.23.48). Recopiée dans `user_profiles`, lu par toute la famille.
      function coverUrlOk() {
        let url = request.resource.data.get('free_recipe_cover_url', null);
        return url == null
          || (url is string && url.size() <= 500
              && url.matches('https://firebasestorage[.]googleapis[.]com/v0/b/kassdale-6d948[.](firebasestorage[.]app|appspot[.]com)/o/users%2F'
                             + uid + '%2Ffree_recipe_cover_[0-9]+[.](jpg|jpeg|png|webp)([?][^/#%]*)?'));
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
      // L'adresse recopiée doit être vérifiée par le fournisseur d'identité.
      allow create: if isAuthenticated() && request.auth.uid == uid
                      && request.resource.data.role == 'pending'
                      && request.resource.data.is_revoked == false
                      && request.resource.data.email == request.auth.token.email
                      && request.auth.token.email_verified == true
                      && namesBounded()
                      && coverUrlOk();

      // Un administrateur nomme et révoque — sauf le fondateur, que lui seul
      // peut destituer.
      allow update: if !touchesEmail()
                      && touchedNamesBounded()
                      && (!request.resource.data.diff(resource.data).affectedKeys()
                             .hasAny(['free_recipe_cover_url'])
                          || coverUrlOk())
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
      // `preferences/planning_refusals` : la mémoire des refus du planning,
      // lue par `suggestMealPlanFn`. Sa forme est bornée.
      match /preferences/{prefId} {
        allow read, delete: if isOwner(uid) || isAdmin();
        allow create, update: if (isOwner(uid) || isAdmin())
          && (prefId != 'planning_refusals'
              || isPlanningRefusals(request.resource.data))
          && (prefId != 'explore_filters'
              || isExploreFilters(request.resource.data));
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
    // ── Cloisonnement par groupe familial (v0.23.19) ─────────────────────
    // Un document partagé d'un autre compte ne se lit que si ce compte
    // partage un groupe avec moi. `group_reach/{moi}.uids` porte la liste,
    // tenue par `syncGroupReach`. Sans document de portée : rien des autres.
    function sharesGroupWith(ownerUid) {
      return ownerUid is string
        && exists(/databases/$(database)/documents/group_reach/$(request.auth.uid))
        && ownerUid in get(/databases/$(database)/documents/group_reach/$(request.auth.uid))
             .data.get('uids', []);
    }
    function isSharedWithMe(data) {
      return isSharedDoc(data) && sharesGroupWith(data.get('created_by', null));
    }
    // Un brouillon partagé reste lisible par un éditeur de mes groupes.
    function canReadRecipe(data) {
      return isApproved() && (
        isCreator(data)
        || isAdmin()
        || ((data.review_status == 'validated' || isEditor()) && isSharedWithMe(data)));
    }
    function recipeDoc(recipeId) {
      return get(/databases/$(database)/documents/recipes/$(recipeId)).data;
    }

    // Collection books
    match /books/{bookId} {
      // Les quatre livres système se reconnaissent à leur tag interne. Ils se
      // renomment, mais ne se suppriment pas : ce sont les destinations par
      // défaut des recettes sans livre, des créations de l'IA et des recettes
      // importées depuis un lien (« Mes recettes du web », `__web`, créé par
      // le serveur). Les perdre laisserait la règle « toute recette a un
      // livre » sans issue.
      function systemTags() {
        return ['__libres', '__kassdale_ia', '__secretes', '__web'];
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
        && (isCreator(resource.data) || isAdmin() || isSharedWithMe(resource.data));
      // « Mes recettes du web » est créé par le serveur seul (`web_{uid}`).
      // Les trois autres, sous `kassdalle_{uid}`, `libres_{uid}`, `secretes_{uid}`,
      // par le seul compte qu'ils nomment (client et serveur écrivent le même document).
      // Son propre livre système encore absent se lit : le client le crée en transaction.
      allow get: if isEditor() && resource == null && ownSystemBookId();
      allow create: if isEditor() && request.resource.data.created_by == request.auth.uid
        && !bookId.matches('web[0-9]*_.*')
        && (!bookId.matches('(kassdalle|libres|secretes)_.*') || ownSystemBookId())
        && !(request.resource.data.get('tags', []) is list
             && request.resource.data.get('tags', []).hasAny(['__web']));
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
      // `source_url`, `source_site`, `source_author` : écrits par le serveur ;
      // le client ne les pose qu'en recopiant ceux d'une recette copiée qu'il
      // peut lire.
      function sourceUrlAccepted() {
        let url = request.resource.data.get('source_url', null);
        let site = request.resource.data.get('source_site', null);
        let author = request.resource.data.get('source_author', null);
        let from = request.resource.data.get('source_recipe_id', null);
        return (url == null && site == null && author == null)
          || (from is string && from != '' && !from.matches('.*/.*')
              && exists(/databases/$(database)/documents/recipes/$(from))
              && canReadRecipe(get(/databases/$(database)/documents/recipes/$(from)).data)
              && get(/databases/$(database)/documents/recipes/$(from)).data.get('source_url', null) == url
              && get(/databases/$(database)/documents/recipes/$(from)).data.get('source_site', null) == site
              && get(/databases/$(database)/documents/recipes/$(from)).data.get('source_author', null) == author);
      }
      // `source_nutrition`, `source_nutrition_check` : serveur seul.
      function serverOnlySourceFields() {
        return ['source_nutrition', 'source_nutrition_check'];
      }

      allow read: if canReadRecipe(resource.data);
      // Création : éditeur et administrateur seulement. Le lecteur ne crée aucune
      // recette (saisie, copie, création par l'IA, import) ; il garde les siennes.
      // `estimated_times` (durées estimées) : serveur seul, ni posé, ni changé,
      // ni effacé par un client, administrateur compris.
      allow create: if isEditor() && request.resource.data.created_by == request.auth.uid
        && !('estimated_times' in request.resource.data)
        && !request.resource.data.keys().hasAny(serverOnlySourceFields())
        && bookCheck(true) && sourceUrlAccepted();
      allow update: if isApproved() && (isCreator(resource.data) || isAdmin()) && keepsCreator()
        && !changes('source_url') && !changes('source_site') && !changes('source_author')
        && !request.resource.data.diff(resource.data).affectedKeys().hasAny(serverOnlySourceFields())
        && !changes('estimated_times')
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

      // Texte d'origine d'une recette traduite à l'import : lu avec les droits
      // de la recette, écrit seulement par le serveur (`recipeProcessor`), et
      // retiré avec elle par `onRecipeWritten`.
      match /origine/{docId} {
        allow read: if isApproved() && canReadRecipe(recipeDoc(recipeId));
        allow write: if false;
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
| `user_profiles` | `isApproved()` | **serveur seul** (`allow write: if false`) — `syncUserClaims` |
| `group_reach` | le titulaire, ou un admin | **serveur seul** — `syncGroupReach` ; un compte qui pourrait s'ajouter la portée d'un autre lirait ses livres |
| `recipes/{id}/origine` | compte nommé qui peut lire la recette (`canReadRecipe` par `get()` sur la recette) | **serveur seul** (`allow write: if false`) — `recipeProcessor` écrit, `onRecipeWritten` supprime |
| `users/{uid}/nutrition_portion_overrides` | propriétaire ou admin | propriétaire ou admin |
| `users/{uid}/preferences` | propriétaire ou admin | propriétaire ou admin ; pour `planning_refusals`, création et modification exigent la forme `isPlanningRefusals` (`entries` en carte de 300 entrées au plus, `updated_at` en `timestamp`, aucun autre champ). Pour `explore_filters`, la forme `isExploreFilters` (clés `sources`, `sort`, `filters`, `updated_at` seulement, bornées). Un autre compte ne lit ni n'écrit les préférences d'un autre (`rules-tests`) |
| `users/{uid}/shopping/current` | le titulaire seul, compte nommé (`isOwner(uid) && isApproved()`) ; un administrateur n'y a pas accès | le titulaire seul, compte nommé ; un seul document (`current`) ; création et modification exigent la forme `isShoppingCart` : `items` en carte de 300 articles au plus, `updated_at` en `timestamp`, aucun autre champ. Les règles ne parcourent pas une carte : les longueurs de chaque article sont bornées par le client (§3.8 quinquies), le document par la limite de 1 Mio de Firestore (`rules-tests/test/shopping.test.mjs`) |
| `users/{uid}/planning_runs` | admin | **serveur seul** (`allow write: if false`) — `suggestMealPlanFn` l'écrit, `generateRecipeConceptFn` y incrémente le compteur de conceptions. Le titulaire ne le lit pas ; un client qui l'écrirait remettrait son plafond de conceptions à zéro |
| `recipe_ratings` | l'auteur, ou tout compte qui peut lire la recette notée (`canReadRecipe` par `get()` sur `recipe_id`) — donc un membre de mes groupes | création par un compte nommé, à son nom (`user_id`), sur une recette qu'il peut lire, sous l'identifiant `{uid}_{recipeId}` et aucun autre : une note par membre et par recette, sans quoi un doublon compterait deux fois dans la moyenne de la famille ; modification et suppression par l'auteur ou un admin, compte nommé et non révoqué, `user_id` et `recipe_id` figés. Création et modification exigent une note bien formée (`isValidRating`) : `rating` entier de 0 à 10, `updated_at` en `timestamp`, aucun autre champ que les quatre du schéma. La famille entière décode les notes d'une recette : une note mal formée ferait échouer l'affichage chez tous |
| `groups` | membres du groupe, et ses invités (`invited_ids`) | création par un editor ou un admin (`isEditor()`, v0.23.54 : plus le reader), à son nom, soi seul membre, sans invité ; `owner_id` figé ; cinq mises à jour et elles seules : **gestion** (`isManagement`) par le propriétaire s'il est editor (`isEditor()`, v0.23.54), ou par un admin — renommer, inviter, annuler une invitation, retirer un membre, jamais en ajouter un, le propriétaire restant membre ; **réduction** (`isShrinking`, v0.23.54) par le propriétaire quel que soit son rôle — `invited_ids` et `member_ids` ne font que perdre des comptes, le propriétaire reste membre, rien d'autre ne change (ni nom, ni invitation nouvelle) ; **acceptation** par l'invité — son uid passe de `invited_ids` à `member_ids`, rien d'autre ; **refus** par l'invité — son uid sort de `invited_ids` ; **sortie** d'un membre autre que le propriétaire — son uid sort de `member_ids` (refusée avant la v0.23.19 : « Quitter le groupe » échouait). Acceptation, refus et sortie restent ouverts à tout rôle approuvé. Suppression par le propriétaire quel que soit son rôle, ou par un admin : un reader propriétaire d'un groupe créé avant la v0.23.54 ne peut pas le quitter, la suppression est sa seule sortie. Testé dans `rules-tests` (« groupes — rôle éditeur requis ») |
| `processing_jobs` | admin, ou propriétaire du job — un éditeur ne lit plus les jobs d'autrui (v0.23.12) ; sa file de travail ne liste que les siens, la vue de tous les jobs est réservée à l'admin | création par un éditeur ou un admin (`isEditor()`), à son propre nom (`created_by == request.auth.uid`) : un `reader` n'importe pas, un job lançant le pipeline facturé (`jobDispatcher`) ; jamais de type `recipeUrlImport`, que seule `importRecipeFromUrlFn` crée après ses contrôles (adresse, doublon, plafond) ; un `recipeUrlImport` ne se relance qu'en `error` de code `timeout` ou sans code, en incrémentant `url_retry_count` de un, deux fois au plus (`urlRelaunchAllowed`), et ne s'annule qu'en `queued` ou `processing` (`urlJobInFlight`) — annuler un job terminé le rendrait relançable ; une annulation, de tout job, laisse `url_retry_count` inchangé (`retryCountUnchanged`), pour qu'elle ne remette pas le compteur à zéro ; le propriétaire ne peut ensuite toucher qu'aux champs de relance et d'annulation, et la relance (retour en `queued`, qui relance le pipeline) exige aussi `isEditor()` — un propriétaire qui n'est pas éditeur ne peut écrire que l'annulation exacte de `cancelJob` (`status: 'error'` et `cancel_requested: true`), car `jobDispatcher` met aussi en file un job au statut absent ou vide |
| `planned_meals` | le propriétaire, même en attente ou révoqué ; et, en lecture seule, un compte nommé (`isApproved()`) dont `planning_reach/{lecteur}.uids` contient le propriétaire (`canReadPlanningOf`, une lecture de `planning_reach` par requête, avec `exists()`), **pour un repas personnel seulement** (`resource.data.group_id == null`, champ présent : un repas antérieur sans le champ attend le backfill `group_planning_reach`) — la requête du client filtre `uid == propriétaire` et `group_id == null`, et une requête sans ce second filtre est refusée : le partage personnel n'ouvre pas les repas des groupes du propriétaire. Cette lecture porte sur tout le document : `justification`, `choice_source`, `dismissed_recipe_ids` et `components[].justification` sont lisibles par l'audience ; le client ne les affiche pas, ce qui n'est pas une protection (décision provisoire, §3.7). **Planning de groupe** : en lecture seule aussi, un compte nommé dont `planning_reach/{lecteur}.group_ids` contient le `group_id` du repas (`canReadGroupPlanning`) et dont le `uid` est le propriétaire actuel du groupe (une lecture de `groups/{group_id}`) — la requête du client filtre `group_id == groupe` et `uid == propriétaire` ; un invité ne lit pas | création et modification par le propriétaire **éditeur ou administrateur** (`isEditor()`, v0.23.47) : un lecteur, un compte en attente ou révoqué ne planifie pas ; `uid` d'un repas figé ; `group_id` figé ; un repas qui porte `group_id` exige que l'appelant soit `owner_id` de ce groupe (`ownsMealGroup`, une lecture de `groups/{group_id}`) ; suppression d'un repas par son propriétaire **éditeur ou administrateur** seul (`isEditor()`) : un lecteur ne supprime plus ses repas antérieurs |
| `planning_config` | le propriétaire seul, même en attente ou révoqué | création, modification et suppression par le propriétaire **éditeur ou administrateur** (`isEditor()`, v0.23.47) ; `shared_group_ids`, s'il est présent, est une liste de 50 éléments au plus, et `group_portions` une table de 50 entrées au plus (`isPlanningConfig`) — les règles ne vérifient pas le type de chaque élément, le serveur ignore ce qui n'est pas un identifiant de groupe |
| `planning_reach` | le titulaire, ou un admin | **serveur seul** — `syncPlanningReachFor` (déclencheurs `syncGroupReach`, `syncPlanningReachOnConfig`, `syncPlanningReachOnRole`) ; un compte qui pourrait s'ajouter la portée d'un autre lirait ses repas |
| `meal_suggestions` | l'auteur (`author_uid`) ou le propriétaire du groupe (`group_owner_id`), compte nommé (`isApproved()`) ; un autre membre ne lit pas les suggestions des autres ; une requête sans l'un de ces deux filtres est refusée | création par un compte nommé, à son nom, sous l'identifiant imposé `{group_id}_{uid}_{day}_{0..4}` (`suggestionIds` : cinq au plus par auteur, groupe et jour), membre d'un groupe **actif** (`canReadGroupPlanning`, `planning_reach.group_ids`) et présent dans `member_ids` du groupe, **pas** son propriétaire ; `group_owner_id` égal à `owner_id` du groupe (une lecture de `groups/{group_id}`) ; forme `isMealSuggestion` : liste de champs fermée, `day` date réelle de la veille à J+60 (`isSuggestionDay`), recette (`recipe_id` + `recipe_titre` ≤ 200) **ou** nom libre (`free_title` ≤ 60), `note` ≤ 200, `created_at == request.time`. Aucune mise à jour. Suppression par l'auteur ou le propriétaire du groupe. Le serveur supprime celles d'un groupe supprimé et d'un membre sorti (`syncGroupReach`) |
| `error_reports` | admin, ou l'auteur du rapport | création par l'auteur non révoqué — un compte en attente, et un compte neuf sans document, en écrivent ; la révocation est lue par `exists()` pour ne pas échouer avant la création du document. Forme imposée (`isErrorReport`, v0.23.48) : les neuf champs de `ErrorReport.toFirestore` et aucun autre, `user_id` égal à l'appelant, `timestamp` en `timestamp`, textes facultatifs bornés — `job_id`, `feature`, `error_type` 400 caractères, `app_version` 100, `error_message` 8 000, `stack_trace` 4 000, `context` 8 000 (une chaîne JSON ; une carte est refusée, la règle ne pouvant pas en mesurer les valeurs). Le client tronque à la moitié de ces bornes : aucun rapport n'est refusé pour sa taille. Modification et purge par l'admin |
| `app_config` | admin ; `usage`, `ai_pricing` et `tickets` par tout compte nommé (`isApproved()`) | admin, **sauf** `backfill_schedules`, `backfill_run_*` et `tickets_status` (`isServerOnlyConfig`), écrits par le serveur seul : un administrateur qui les écrirait directement pourrait programmer un passage imputé au plafond d'un autre compte, lever un verrou, ou effacer l'alerte d'un jeton GitHub refusé ; sur `usage`, tout compte nommé, limité à `storage_bytes`, `updated_at` et au compteur `scans_AAAA_MM` du mois courant ou précédent (`hasOnly`), chaque compteur écrit restant un entier positif qui ne recule pas (`countsUp`) |
| `ai_routing_presets` | admin | **serveur seul** — `aiRoutingPresetsFn` contrôle une configuration contre le catalogue de postes avant de l'écrire |
| `nutrition_ingredients` | `isApproved()` | serveur ; l'admin modifie seulement `shopping_product`, `shopping_product_source`, `allergens`, `allergens_source`, `allergens_at` et `updated_at`. Création et suppression refusées au client |
| `nutrition_units` | `isApproved()` | admin |
| `meal_staples` | `isApproved()` | admin — les retouches de chacun vivent sous `users/{uid}/preferences/meal_staples`, jamais ici |
| `image_moderation` | admin, ou celui qui a envoyé l'image | **serveur seul** — une décision de modération que le client peut écrire n'est pas une décision |
| `ai_usage` · `ai_daily_spend` | admin, ou le compte concerné | **serveur seul** — un client pouvait autrefois y inscrire des dépenses imaginaires que la réconciliation aurait présentées comme réelles |
| `scan_spend` | admin | **serveur seul** — un client qui pourrait relever son propre plafond ne serait plus plafonné |
| `url_import_daily` | admin, ou le compte concerné (`uid`) | **serveur seul** — un client qui pourrait remettre son compteur à zéro ne serait plus plafonné |
| `web_search_daily` | admin, ou le compte concerné (`uid`) | **serveur seul** — même raison que `url_import_daily` |
| `invitations` · `invitation_sends_daily` | admin | **serveur seul** (`allow write: if false`) — `manageInvitationFn`, `applyEmailInvitation` et `applyRevokedInvitation`. Une invitation décide du rôle d'un compte à sa première connexion : un client qui pourrait en écrire une s'inviterait lui-même, sous une autre adresse, avec le rôle de son choix. Testé dans `rules-tests` (admin lit ; editor, reader, pending, révoqué et anonyme refusés ; aucune écriture client) |
| `web_search_cache` | **personne** | **serveur seul** — ouvert au client, il laisserait servir à toute la famille des pages choisies par un seul compte, sans appel ni décompte |
| `member_email_search_daily` | **personne** | **serveur seul** (`allow read, write: if false`) — `findMemberByEmailFn`. Un client qui pourrait remettre son compteur à zéro essaierait des adresses sans borne. Testé dans `rules-tests` (aucun rôle ne lit ni n'écrit) |
| `dead_letters` · `ai_reconciliation_monthly` | admin | **serveur seul** |
| `tickets` | admin, ou l'auteur (`author_uid`) approuvé et non révoqué — un compte en attente ou révoqué ne relit pas ses tickets ; un ticket absent se lit comme absent par un compte approuvé (`resource == null`), pour que le détail affiche « Ce ticket n'existe plus » au lieu d'un refus | **serveur seul**, sauf une mise à jour de l'auteur approuvé et non révoqué qui ne touche que `seen_by_author_at` (`affectedKeys().hasOnly`) et le pose à `request.time`. Création et suppression refusées à tous, administrateur compris : un ticket créé par le client échapperait aux plafonds, et un statut écrit par le client ne dirait plus l'état de l'Issue |
| `ticket_quotas` | **personne** | **serveur seul** (`allow read, write: if false`) — `submitTicket`. Un client qui pourrait remettre son compteur à zéro ne serait plus plafonné |

Toutes les lectures partagées passent par `isApproved()` : être connecté ne donne accès à rien.

**Un groupe familial est un lieu de partage** (décision de l'utilisateur, 2026-10-10, v0.23.19).
Un livre ou une recette non privé d'un autre compte ne se lit que si ce compte partage au moins
un groupe avec le lecteur : `sharesGroupWith`, une lecture de `group_reach/{lecteur}`. Il en va de
même des annotations et des notes, qui suivent la recette par `canReadRecipe`. La relecture des
brouillons partagés par un éditeur est limitée de la même façon. Un compte hors de mes groupes
ne lit rien de moi, et je ne lis rien de lui. Un membre sorti d'un groupe est traité comme un
compte supprimé : dès que `syncGroupReach` a réécrit les portées, il ne lit plus les livres du
groupe, et le groupe ne lit plus les siens. Il garde ses propres documents. L'administrateur lit
tout, comme avant. On n'entre dans un groupe qu'en acceptant une invitation (§3.5) : sans cela,
le cloisonnement se contournait en ajoutant n'importe quel compte à son propre groupe. Seule
exception, écrite par le serveur et non par une règle : `applyEmailInvitation` ajoute un compte
**neuf** au groupe de l'invitation par e-mail qu'un administrateur, propriétaire ou membre de ce
groupe, a envoyée à son adresse (§3.5 ter). Un compte **révoqué** invité par e-mail n'en
bénéficie pas : à son retour, `applyRevokedInvitation` ne fait que l'ajouter à `invited_ids`, et
il accepte comme toute invitation de groupe. Le
cloisonnement existait déjà côté client (`groupMemberIdsProvider`) ; une
requête Firestore directe le contournait.

Coût : une lecture facturée de plus par requête ou par lecture de document d'autrui (la portée),
pas par document rendu.

**Délai connu.** Entre l'écriture qui retire un membre et la fin de `syncGroupReach` (démarrage
à froid et transaction, quelques secondes), le membre sorti lit encore. Si le déclencheur
échoue, ce délai dure jusqu'à la tentative qui réussit (`retry: true`). Un écouteur
`snapshots()` déjà ouvert n'est pas forcément réévalué quand seule la portée change : le client
de l'application en ouvre de nouveaux dès que sa portée change (`RecipeViewer` change), mais un
client modifié pourrait garder l'ancien jusqu'à la prochaine écriture du document écouté.

**Décisions de l'utilisateur sur les cas limites (2026-10-10).** Les membres ajoutés sans leur
accord avant la v0.23.19 restent membres. Une annotation ou une note posée sur une recette se lit
par qui lit la recette, même si son auteur ne partage aucun groupe avec le lecteur : elle porte
sur la recette, et un filtre par auteur rendrait les requêtes du client improuvables. La
couverture « Recette libre » reste dans le profil public (`user_profiles`).

**Bornes d'un groupe.** Le nom compte 60 caractères au plus, et 50 invitations au plus
attendent une réponse (`boundedGroup`) : chaque invité lit le groupe, et sans borne un compte
poussait un texte de taille quelconque chez tous ceux qu'il invitait.

**Une règle n'est pas un filtre.** Firestore refuse une requête entière dès que ses filtres ne
suffisent pas à prouver que chaque résultat possible est lisible. Les requêtes du client sur
`recipes` et `books` portent donc `created_by == uid` (le sien), ou `is_private == false` avec
`created_by in` des comptes de la portée (contenu partagé de mes groupes) ; hors administrateur,
`RecipeRepository` scinde une requête par livre ou par statut en ces requêtes et fusionne les
résultats sans doublon (`RecipeViewer.groupPeers`, `_visibleQueries`). Firestore borne une requête
à 30 disjonctions : les comptes partent par lots de 30, de 15 pour les brouillons, dont la
requête porte déjà `review_status in [draft, inReview]`. Une valeur de `created_by in` hors de la
portée fait refuser la requête entière. Les requêtes par propriétaires
(`watchValidatedBooksByOwners`, `watchUnattachedByOwners`, `watchDraftsByOwners`,
`getAllByOwners`, `getFamilyValidatedRecipes`) prennent leurs comptes dans la portée et restent
prouvables ; elles s'arrêtent aux 30 premiers. Un lecteur ne relit que ses propres brouillons. Une requête
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
recettes libres », « Mes créations Kass'Dalle », « Mes Recettes Secrètes », « Mes recettes du
web ») appartiennent à leur utilisateur. Le sélecteur de livre ne propose que les livres de l'utilisateur, tous les
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

**La normalisation écrit dans le référentiel partagé** (v0.23.48).
`normalizeRecipeReferentialsFn` crée et enrichit des fiches `nutrition_ingredients` à partir
des noms reçus. `assertCanNormalizeReferentials` (`callable/_recipeAccess.ts`, décision pure
`referentialNormalizationDenial` testée) la réserve à l'éditeur et à l'administrateur
(`isEditorAccount`), et au lecteur créateur de la recette `recipeId` : c'est le seul parcours
qui l'y amène, l'enregistrement d'une de ses recettes (`RecipeRepository.updateRecipe`). Les
noms restent ceux de la requête, la normalisation précédant l'enregistrement. Un lecteur sans
`recipeId`, ou sur la recette d'un autre, reçoit `permission-denied` avant toute écriture.

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

    // Capture d'un ticket — privée, jamais publiée. Pas de lecture Firestore :
    // `attachTicketScreenshot` vérifie ensuite que le ticket est à l'appelant.
    match /tickets/{uid}/{ticketId}/{fileName} {
      allow read: if (isActive() && isOwner(uid)) || isAdmin();
      allow create, update: if isOwner(uid) && isApprovedToken()
        && fileName.matches('screenshot[.](png|jpg)')
        && request.resource.size <= 5 * 1024 * 1024
        && baseContentType() in ['image/png', 'image/jpeg'];
    }
  }
}
```

> Les six dossiers publiés (`covers/`, `scans/`, `rejected/`, `illustrations/`, `recipes/`,
> `users/`) sont fermés en écriture : seul le serveur y dépose, par l'Admin SDK.
> `tickets/` est le seul dossier écrit par le client hors de la quarantaine : par le compte
> lui-même, sous son uid, un fichier nommé `screenshot.png` ou `screenshot.jpg`. La
> suppression est refusée à tous (aucune purge en V1).

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
  propriétaire, `app_config`, collections de coût, `processing_jobs`, référentiels, mémoire des
  refus du planning (`preferences/planning_refusals`) ; `test/mealSuggestions.test.mjs` couvre
  les suggestions de repas (création par un membre, refus au propriétaire, à l'invité, à
  l'étranger, au groupe en pause, à un `group_owner_id` faux ; lecture par l'auteur et le
  propriétaire seuls ; aucune mise à jour ; identifiant imposé `_0` à `_4` et sixième
  refusée ; jour mal formé, impossible ou hors de la veille à J+60 refusé ; bornes) ; côté
  Storage, dossiers publiés, quarantaine (propriété, rôle, types, tailles), `rejected/`.
- Le bloc « requêtes du client » rejoue la forme des requêtes de `recipe_repository.dart`,
  `book_repository.dart`, `planning_providers.dart`, `annotation_repository.dart` et
  `recipe_rating_repository.dart`. L'émulateur évalue une requête sur ses filtres, comme la
  production : une requête qui perd son filtre `is_private` ou `created_by` y échoue, même sur
  une collection vide.
- La création d'une recette a ses tests : un `reader` ne crée pas de recette, même à son nom,
  ni de copie ; un éditeur et un administrateur créent la leur ; un `reader` modifie toujours
  la sienne. Les cas de confidentialité et de rangement à la création sont rejoués avec
  l'éditeur. `users/{uid}/preferences/explore_filters` se lit et s'écrit par son titulaire et
  par un administrateur, dans la forme bornée par `isExploreFilters` (clé inconnue refusée) ;
  l'interrupteur `filters.count_estimated_times` s'y enregistre sans changer la règle (il vit
  dans la carte `filters`, bornée à vingt clés). `estimated_times` ne se pose pas à la
  création d'une recette, et ne se change ni ne s'efface à une mise à jour, administrateur
  compris.
  Un éditeur ne crée pas `books/web2_{autre uid}`, le repli du livre web.
- L'import par lien a ses tests : « Mes recettes du web » (`__web`) ne se supprime pas et garde
  son tag ; un éditeur ne crée ni `books/web_{autre uid}` ni un livre tagué `__web`, mais crée
  toujours « Mes recettes libres » ; `source_url`, `source_site` et `source_author` ne se
  posent pas à la création, sauf recopiés à l'identique depuis une recette copiée **lisible**
  (une recette privée d'un autre est refusée), et ne se modifient ni ne s'effacent,
  administrateur compris ; `source_nutrition` et `source_nutrition_check` ne se posent pas à la
  création, même sur une copie, et ne se modifient ni ne s'effacent ;
  un éditeur ne crée pas de job `recipeUrlImport` et ne change pas la source d'un job en le
  relançant ; un import terminé ne se remet pas en file ni ne s'annule, un délai dépassé se
  relance avec `url_retry_count` + 1, pas au-delà de deux, pas sans compteur, et un import
  refusé par le site ne se relance pas ; une annulation ne remet pas le compteur de relances à zéro ; `url_import_daily` se lit par son titulaire et ne
  s'écrit pas depuis le client.

**Convention `todo`.** Une faille relevée et encore ouverte a son test, écrit avec l'attendu
corrigé et marqué `{ todo: "faille ouverte, audit 2026-10-09" }` (constante `OPEN_FLAW`). Sous
`node:test`, un `todo` qui échoue ne fait pas échouer la suite. La correction de la faille
retire l'option dans le même commit : le test devient bloquant. Une règle corrigée sans test
est une anomalie de relecture.

La décision de propriété est en vigueur depuis la v0.23.8 : une recette ou un livre privé ne se
lit que par son créateur et l'administrateur ; chacun ne modifie que ses propres recettes et
livres, éditeur compris ; l'administrateur agit comme le créateur. Un éditeur lit encore les
brouillons **partagés** des membres de ses groupes (relecture), sans pouvoir les modifier.
Depuis la v0.23.19, tout ce qui est partagé ne se lit que par les membres des groupes du
créateur (suite « groupes — cloisonnement des lectures »).

**Comptes au 2026-10-10 (v0.23.19)** : 384 tests attendus, aucun `todo` — 321 avant la v0.23.15,
11 ajoutés par la v0.23.15 (notes de la famille), 5 par la v0.23.16 (texte d'origine), 5 par la
v0.23.18 (planning), 42 par la v0.23.19 (cloisonnement par groupe, portée `group_reach`,
invitations). La CI confirme le compte.

- Firestore : 316 tests attendus, aucun `todo`.
- Storage : 68 tests, 68 actifs, aucun `todo`.

L'invitation par e-mail ajoute 3 tests à « users — création de compte » : un jeton dont
`email_verified` vaut `false`, ou ne le porte pas, ne crée pas son document ; `true` le crée.
Les tests de création existants fournissent `email_verified: true` dans leur jeton. Compte
relevé le 2026-10-12 : 466 tests, aucun `todo`.

L'invitation des comptes révoqués ajoute 2 tests à « users — rôle et révocation », sans
changer les règles : un compte révoqué écrit sa connexion (`last_seen_at`, nom, photo), écriture
sur laquelle se déclenche `applyRevokedInvitation` ; il ne se donne pas de rôle dans la même
écriture. Compte relevé le 2026-10-12 : 509 tests (Firestore et Storage), aucun `todo`.

La v0.23.16 ajoute 5 tests sur `recipes/{id}/origine/texte` : un lecteur lit le texte d'origine
d'une recette visible, ne lit pas celui d'une recette privée d'autrui, un compte en attente ne
le lit pas, un administrateur ne le réécrit pas, un éditeur ne le crée pas. Ces tests n'ont pas
tourné sur le poste de développement (Java absent) : la CI les rejoue.

La v0.23.47 (plannings partagés) ajoute 17 tests et en réécrit 4 : le lecteur ne crée pas de
repas, ne modifie pas son ancien repas, le relit et le supprime, n'écrit pas `planning_config` ;
il lit le repas d'un planning partagé avec lui (`planning_reach`), pas celui d'un planning non
partagé, et ne modifie ni ne supprime un repas partagé ; un compte sans `planning_reach`, un
compte révoqué ou en attente qui en a un, ne lit rien ; une requête `uid == propriétaire`
partagé est acceptée, une requête sur un propriétaire non partagé ou sans filtre est refusée ;
`planning_reach` se lit par son titulaire et un administrateur, et ne s'écrit par aucun
client ; l'éditeur écrit `shared_group_ids`, liste de 50 au plus, pour lui seul. Les tests
« repas créé au nom d'un autre », « modifier son repas », « uid figé » et « planifier et
écrire `planning_config` » portent désormais sur l'éditeur.

Le planning de groupe ajoute 11 tests (« plannings de groupe ») et en réécrit 1 : un membre lit
le repas du groupe et la requête `group_id ==` ; un invité et un compte hors du groupe ne lisent
rien ; un membre n'écrit ni ne supprime ; le propriétaire crée, modifie, lit et supprime ; un
éditeur ne planifie pas avec le `group_id` d'un groupe dont il n'est pas propriétaire, ni avec
un groupe inexistant ou un `group_id` non textuel ; `group_id` est figé ; un lecteur ne supprime
aucun repas (le test « le relit et le supprime » devient « le relit, sans le supprimer ») ; un
propriétaire rétrogradé, dont le serveur a retiré le groupe de `group_ids` et de `group_reach`,
ne laisse plus ses membres lire ni le planning ni les livres du groupe ; `group_portions` est
bornée à 50 entrées. La correction de relecture ajoute 2 tests et en réécrit 1 : un compte qui
lit le planning personnel d'un éditeur ne lit pas son repas de groupe (`get` refusé, requête
`uid ==` sans filtre refusée, requête `uid ==` et `group_id == null` acceptée) ; un repas
antérieur sans le champ ne se lit plus par le partage, ni un par un ni par requête, et son
propriétaire le relit ; le test
« requête uid == propriétaire partagé » filtre désormais `group_id == null`.

La v0.23.14 rend bloquant le dernier `todo`, « un éditeur ne lit pas le document d'un autre »,
et ajoute 13 tests : un éditeur ne liste pas `users`, un administrateur lit et liste `users` ;
sur `user_profiles`, un lecteur et un éditeur lisent le profil d'un autre, un lecteur liste les
profils, un compte en attente, un compte révoqué et un anonyme n'en lisent aucun, et personne
n'écrit ni ne supprime un profil côté client, administrateur compris.

La v0.23.12 rend bloquants 12 des 13 `todo` et ajoute 20 tests qui vérifient que le cas
légitime reste accepté : renommer un livre système et lui ajouter un tag, changer les tags
d'un livre ordinaire, retirer le champ `tags` (refusé) ; ajouter un membre à son groupe,
`owner_id` figé pour l'administrateur aussi, modifier son repas ; un lecteur planifie et écrit
`planning_config` (cas inversé en v0.23.47 : c'est l'éditeur qui planifie), un compte en attente et un compte neuf écrivent un rapport d'erreur, un
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
membres d'un groupe (`GroupRepository.searchUsers`) interroge `user_profiles`, par nom. La
recherche par adresse exacte passe par la callable `findMemberByEmailFn` (§5, « Recherche d'un
membre par adresse ») : le client ne lit toujours aucune adresse.

Les tickets ajoutent 38 tests. Firestore (29) : `tickets` — l'auteur lit et liste les siens, un
ticket absent se lit comme absent par un compte approuvé et non par un compte en attente, un
autre membre et un éditeur ne les lisent pas, un membre ne liste pas toute la collection,
l'administrateur lit tout ; un compte révoqué (jeton à jour ou périmé) et un compte en attente ne
relisent pas leur ticket ; l'auteur pose `seen_by_author_at` à l'heure du serveur, pas à une
date de son choix, et ne modifie aucun autre champ ; un autre membre, un compte révoqué ou en
attente ne le posent pas ; personne ne crée ni ne supprime un ticket, administrateur compris, et
l'administrateur ne modifie pas le ticket d'un membre ; `ticket_quotas` ne se lit ni ne s'écrit
par aucun rôle ; `app_config/tickets` se lit par un compte approuvé, pas par un compte en
attente ou révoqué, ne s'écrit pas par un membre et s'écrit par l'administrateur ; `app_config/tickets_status` se lit par
l'administrateur seul et ne s'écrit par aucun client. Storage (9) : `tickets/` — l'auteur dépose
une capture PNG ou JPEG sous son uid, nommée `screenshot`, de 5 Mo au plus ; personne ne dépose
chez un autre, administrateur compris ; un compte en attente, révoqué ou anonyme ne dépose
rien ; l'auteur et l'administrateur lisent la capture, un autre membre non ; un compte révoqué
ne relit pas la sienne ; l'auteur ne la supprime pas ; un autre membre ne liste pas le dossier de
l'auteur. Compte relevé le 2026-10-13 : 560 tests
(Firestore et Storage), aucun `todo`.

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
    │                   │ Adresse invitée par e-mail ?     │
    │                   │ → applyEmailInvitation pose le   │
    │                   │   rôle et le groupe ; la salle   │
    │                   │   d'attente se referme seule     │
    │                   │ Existant ?                       │
    │                   │ → last_seen_at mis à jour        │
    │                   │ Révoqué et invité par e-mail ?   │
    │                   │ → applyRevokedInvitation rétablit│
    │                   │   l'accès, pose le rôle et       │
    │                   │   l'invitation de groupe ; jeton │
    │                   │   renouvelé, l'écran de          │
    │                   │   révocation se referme seul     │
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

### Invitations par e-mail

Un administrateur invite une personne qui n'a pas encore de compte. À sa première connexion
Google sous l'adresse invitée, le compte reçoit le rôle et entre dans le groupe. Il peut aussi
inviter l'adresse d'un compte révoqué : le compte reste révoqué à l'envoi ; à sa
reconnexion sous cette adresse, son accès est rétabli avec le rôle de l'invitation, et il
reçoit une invitation de groupe à accepter. Aucun appel de modèle : ce n'est pas un poste d'IA.

**`manageInvitationFn`** (`callable/invitationsCallable.ts`, `onCall`, `requireAdmin` — admin
non révoqué, App Check selon la politique) aiguille sur `action` :

| `action` | Entrée | Ce que le serveur vérifie, puis fait |
|---|---|---|
| `create` | `email`, `role`, `groupId`, `message` | `role` vaut `reader` ou `editor` (`admin` → `invalid-argument`) ; adresse de forme valide (`cleanEmail`, `normalizeEmailKey`) ; groupe existant dont l'appelant est propriétaire ou membre ; aucun compte `users` dont la clé d'adresse est la même, ou un compte révoqué qui n'est pas le fondateur (parcours de `users`, trois champs, comparaison sur `email_key` : une requête d'égalité ne retrouverait pas `jean.dupont@gmail.com` saisi `jeandupont@gmail.com` ; décision `accountDecision`). Compte révoqué : l'invitation porte `target: "revoked"` et `target_uid` ; sinon `target: "new"`. Puis, dans une transaction : aucune invitation active de même `email_key`, moins de 20 envois du jour (`invitation_sends_daily`), écriture de l'invitation et du compteur. L'e-mail part ensuite |
| `resend` | `invitationId` | invitation ni acceptée ni annulée (une expirée se renvoie) ; même contrôle de groupe qu'à la création (groupe existant — sinon « Ce groupe n'existe plus. » —, appelant propriétaire ou membre) ; le compte visé n'a pas changé (`resendRefusal` : invitation de compte neuf, toujours aucun compte ; invitation de compte révoqué, le même `target_uid` toujours révoqué ; sinon refus `target_changed`, « Le compte de cette adresse a changé depuis l'invitation. Annulez-la, puis invitez de nouveau. », ou le refus du compte actif ou en attente), aucune autre invitation active pour elle, plafond du jour ; `last_sent_at`, `expires_at` (+30 jours), `send_count`, `last_sent_by`, `group_name` mis à jour, puis envoi |
| `cancel` | `invitationId` | invitation non acceptée ; `status: cancelled`, `cancelled_by`, `cancelled_at` |

Réponses : `{status: "sent", invitationId, target}`, `{status: "send_failed", invitationId,
error, target}` (`target` : `new` ou `revoked`, pour que le formulaire annonce le
rétablissement), `{status: "cancelled", invitationId}`, ou un refus métier `{status: "refused",
reason, message, field, invitationId?, existingUid?}` — `reason` parmi `invalid_email`,
`group_required`, `group_missing`, `group_not_member`, `account_active`, `account_pending`,
`founder`, `target_changed`, `duplicate`, `daily_limit`, `not_found`, `not_resendable`, `not_cancellable`,
`address_rejected` (Gmail a refusé l'adresse, l'invitation est annulée ; `invitationId` fourni) ;
`field` (`email`, `group` ou `null`) dit sous quel champ le formulaire affiche le message.
Un refus n'est pas une exception : le client l'affiche sans rapport d'erreur. `existingUid`
accompagne `account_pending` : le formulaire propose alors « Lui donner le rôle (sans
groupe) », qui passe par `AdminRepository.updateRole`, le geste de l'onglet Comptes. L'arrivée
automatique dans le groupe est réservée aux comptes neufs : pour un compte existant, l'ajout
au groupe passe par l'invitation de groupe (Groupes familiaux), ce que le formulaire dit. Un
compte révoqué n'est plus refusé (le refus `account_revoked` a disparu) : le
formulaire le signale sous l'adresse avant l'envoi quand l'adresse saisie est, sans casse,
celle d'un compte révoqué de la liste des comptes (`isRevokedAccountEmail`, indication du
client seul ; une autre écriture d'une adresse Gmail n'est reconnue qu'à la réponse du
serveur, par `target`).

**Enregistrer, puis envoyer.** Un échec SMTP temporaire (4xx, réseau) ou de configuration
(secret vide, `535` sur `AUTH`) ne lève pas : l'invitation passe en `send_failed` avec
`last_error` lisible (une ligne, 300 caractères ; « Envoi d'e-mail non configuré. » pour un
secret vide), l'erreur est journalisée (`logError`, `firestoreDocId` = l'invitation), et la
réponse est `send_failed`. Un refus **définitif** du destinataire
(`isPermanentRecipientRejection` : code 5xx sur `RCPT TO` ou `EENVELOPE`, avec un code étendu `5.1.x` ; un `5.4.x` ou `5.7.x`, quota ou politique de Gmail, reste en `send_failed`)
passe l'invitation à `cancelled`, `cancelled_by: "system"`, `last_error` « Adresse refusée par
Gmail : … », et la réponse est le refus `address_rejected`, affiché sous l'adresse ; l'onglet
Invitations la range dans l'historique, Annulée, avec ce motif. Dans le texte journalisé comme
dans `last_error`, la partie locale des adresses est masquée (`maskEmails` :
`toto@gmail.com` → `t***@gmail.com`). L'écriture du résultat se fait dans une transaction qui
laisse intacte une invitation acceptée ou annulée pendant l'envoi. Le client signale l'échec
à l'utilisateur et le rapporte (`ErrorReportService`, feature `admin.invitations`).

**L'e-mail** (`invitations/rules.ts` → `buildInvitationEmail`, envoi par
`invitations/mailer.ts`). SMTP Gmail (`smtp.gmail.com:465`, TLS) par `nodemailer`, chargé par
`await import()` au premier envoi, transport mémorisé pour l'instance. Expéditeur : l'adresse
de `GMAIL_SENDER`, nom affiché « {Admin} via Kass'Dalle » ; `Reply-To` : l'adresse de
l'administrateur qui envoie. Objet : « {Admin} t'invite dans « {Groupe} » sur Kass'Dalle ».
Corps en texte et en HTML simple : le message, s'il n'est pas vide (échappé dans le HTML, comme
le nom de l'admin et celui du groupe ; le serveur n'a pas de message par défaut, le formulaire
seul en préremplit un), un bouton « Ouvrir Kass'Dalle » vers `https://kassdale-6d948.web.app`, le lien
de l'APK (`/app-release.apk`, servi par le Hosting), « Connecte-toi avec le compte Google
{adresse}. Avec une autre adresse, ton accès devra être validé à la main. » (compte révoqué :
« Connecte-toi avec le compte Google {adresse} : ton accès sera rétabli, et l'invitation au
groupe « {groupe} » t'attendra dans Groupes familiaux. », `restoresAccess` ; l'aperçu du
formulaire compose la même ligne, `invitationAccountLine`), la date
d'expiration (jj/mm/aaaa, heure de Paris) et la signature. Le nom de l'en-tête `From` est
nettoyé (`headerSafeName` : ni retour à la ligne, ni guillemet, ni chevron) ; l'adresse
destinataire a passé `cleanEmail`, qui refuse espace, virgule, chevron et retour à la ligne.

**`applyEmailInvitation`** (`triggers/invitationSignup.ts`, `onDocumentCreated` sur
`users/{uid}`) : voir §3.1, « Exception décidée par le serveur ». Il relit dans la
transaction le compte de l'administrateur du dernier envoi (`inviterUidOf` : `last_sent_by`,
sinon `invited_by`) et n'applique rien s'il n'est plus `admin` ou s'il est révoqué
(`inviterStillAdmin`, même règle `accessDenial` que `requireAdmin`) : journal `logInfo`, compte
`pending`, invitation inchangée. Un rôle illisible ou un invitant absent de l'invitation est
journalisé en `logError`. Échec journalisé, sans nouvelle tentative : le compte reste en
attente, l'administrateur peut le nommer à la main, et l'invitation reste active.

**`applyRevokedInvitation`** (`triggers/invitationSignup.ts`, `onDocumentUpdated` sur
`users/{uid}`) : voir §3.1, « Seconde exception ». Mêmes gardes (adresse Auth vérifiée,
invitant encore admin, rôle invitable), mêmes journaux, préfixés `applyRevokedInvitation`.
L'invitation n'est cherchée que pour une écriture de connexion d'un compte révoqué
(`isRevokedSignIn`) ; un compte révoqué sans invitation de retour active qui se connecte coûte
une requête `target_uid == uid`, sans appel Auth ni écriture. Rétabli autrement (onglet
Comptes), le compte voit ses invitations de retour actives annulées par `syncUserClaims`
(§3.1, « Invitation de retour sans objet »). Un échec n'est pas rejoué : la connexion suivante relance le
déclencheur, et l'invitation reste active.

**Claims et course entre deux déclencheurs.** La création du document (`pending`) et la pose
du rôle par `applyEmailInvitation`, une seconde plus tard, réveillent deux exécutions de
`syncUserClaims` dont l'ordre n'est pas garanti. Si celle de la création passait en dernier,
elle écrivait le claim `pending` et supprimait le profil public d'un compte déjà nommé.
`syncUserClaims` relit donc le document au moment d'agir, quand l'événement change le rôle ou
la révocation (`rereadUser`, `stateAfterReread`), et écrit claims et profil d'après cet état.
Un document absent à la relecture est traité comme une suppression (claims effacés, sessions
coupées s'il avait un rôle nommé, profil public retiré), jamais comme l'instantané de
l'événement ; seul un échec de lecture retombe sur l'instantané ; une écriture qui
ne touche ni l'un ni l'autre (`last_seen_at`) ne coûte pas de lecture de plus. Le jeton du
client, émis à la connexion, ne porte pas encore de claim de rôle : les règles lisent alors le
document (`roleOf()`), et la salle d'attente se referme dès que le flux de `users/{uid}`
apporte le rôle.

**Secrets.** `GMAIL_SENDER` (l'adresse Gmail expéditrice) et `GMAIL_APP_PASSWORD` (son mot de
passe d'application), déclarés par `defineSecret` (`config.ts`) et attachés à
`manageInvitationFn` seule. Un secret déclaré mais absent de Secret Manager fait échouer **tout**
le déploiement des Functions : les deux doivent exister avant de fusionner. Création :

1. sur le compte Google expéditeur, activer la validation en deux étapes (myaccount.google.com
   › Sécurité) ;
2. myaccount.google.com/apppasswords : créer un mot de passe d'application nommé
   « Kass'Dalle », et copier les seize lettres (les espaces affichés sont retirés à l'usage) ;
3. `firebase functions:secrets:set GMAIL_SENDER --project kassdale-6d948`, saisir l'adresse ;
4. `firebase functions:secrets:set GMAIL_APP_PASSWORD --project kassdale-6d948`, saisir le mot
   de passe d'application.

Une valeur vide (ou un seul espace) est acceptée par le déploiement : chaque envoi rend alors
« Envoi d'e-mail non configuré », et l'invitation est enregistrée. Révoquer le mot de passe
d'application coupe l'envoi sans redéploiement ; le remplacer demande un
`functions:secrets:set` puis un redéploiement de `manageInvitationFn` (une version de secret est
figée au déploiement). Gmail limite l'envoi à environ 500 destinataires par jour pour un compte
personnel : le plafond de 20 envois par administrateur en reste loin.

**Client.** `InvitationsRepository` (`features/admin/data/`) lit `invitations` par
`orderBy('created_at', descending: true)` et appelle la callable ; `emailInvitationsProvider`
et `invitationsRepositoryProvider` vivent dans `admin_providers.dart` ; le modèle
`EmailInvitation` (`features/admin/domain/email_invitation.dart`) calcule le statut effectif
(`statusAt`, jumeau de `effectiveStatus`, fixture `email_invitation_status.json`) et porte le
message prérempli (`defaultInvitationMessage`, client seul). Le client ne fait qu'un contrôle
de forme de l'adresse (`looksLikeEmail`) : la normalisation est une logique serveur seule,
sans fixture partagée.

Le formulaire (`InviteByEmailScreen`) : groupes en chargement, champ désactivé « Chargement
des groupes… » ; groupes illisibles, `AppErrorState` compact « Groupes illisibles » avec
Réessayer ; aucun groupe, message et bouton « Ouvrir Groupes familiaux » (`/groups`). Le bouton
« Envoyer l'invitation » est actif hors envoi dès qu'au moins un groupe existe ; la validation
se fait au clic (« Saisissez une adresse e-mail. », « Adresse e-mail invalide. », « Choisissez
un groupe. », sous leur champ). Entrée dans l'adresse et Ctrl/Cmd+S (`AppShortcuts`) envoient.
L'aperçu suit chaque frappe (`ListenableBuilder` sur les deux contrôleurs). L'onglet s'intitule
« Invitations (n) », n invitations en attente ; chaque ligne porte sa puce de statut en tête du
sous-titre et un seul menu, où « Copier le lien » n'apparaît que si l'invitation peut être
renvoyée.

### Recherche d'un membre par adresse

Le propriétaire d'un groupe cherche un compte existant à inviter par son adresse e-mail
complète. `users/{uid}` n'est pas lisible par lui (§4) : le serveur fait la recherche. Aucun
appel de modèle : ce n'est pas un poste d'IA.

**`findMemberByEmailFn`** (`callable/memberSearchCallable.ts`, `onCall`, `requireEditor` —
editor ou admin, non révoqué, App Check selon la politique (v0.23.54 : un reader
propriétaire d'un ancien groupe n'invite plus) ; traitement
`recherche_membre_adresse`). Entrée `{groupId, email}`. Le serveur vérifie, dans cet ordre :

1. `groupId` lisible (`readGroupId` : non vide, 128 caractères au plus, sans `/`), sinon
   `invalid-argument` ;
2. adresse de forme valide après espaces retirés et minuscules (`cleanEmail`), sinon
   `invalid-argument` « Adresse e-mail invalide. » ;
3. groupe existant (`not-found` « Ce groupe n'existe plus. ») dont l'appelant est
   **propriétaire** (`searcherDenial`, `permission-denied`) — le propriétaire éditeur seul
   invite (`isManagement` dans `firestore.rules`) ;
4. moins de 10 recherches du jour UTC pour l'appelant : transaction sur
   `member_email_search_daily/{uid}_{AAAA-MM-JJ}`, incrémentée avant la recherche, trouvée ou
   non, qui pose aussi `expires_at` (TTL, 30 jours) ; au-delà, `resource-exhausted` « Trop de
   recherches aujourd'hui. Réessayez demain. » et un `logWarn`.

Puis `users` est parcourue (cinq champs : `email`, `role`, `is_revoked`, `display_name`,
`preferred_name`), comme `existingAccountFor` des invitations : une requête d'égalité
manquerait une adresse stockée avec des majuscules. `findAccountByEmail`
(`invitations/memberSearch.ts`) retient le premier compte dont `cleanEmail(users.email)` vaut
l'adresse saisie, non révoqué et doté d'un profil public (`publicProfileFrom` : rôle `reader`,
`editor` ou `admin`). La correspondance est **stricte** : pas de clé normalisée Gmail
(`normalizeEmailKey`), qui ferait trouver un compte sous une autre écriture de l'adresse que
celle saisie.

Réponse : `{found: false}`, ou `{found: true, uid, displayName, preferredName}` — les deux noms
de `user_profiles/{uid}`, déjà lisibles par tout compte approuvé. Jamais l'adresse, jamais le
rôle. Un compte en attente ou révoqué répond `{found: false}`, comme une adresse inconnue.

Une réponse `{found: false}` incrémente `misses` dans le même document (transaction
best-effort : un échec est journalisé par `logError` et la réponse part quand même). À la
cinquième du jour (`shouldWarnMisses`, égalité stricte : une fois par jour), un `logWarn`
« 5 recherches par adresse sans résultat aujourd'hui » part, sans adresse, visible dans
Admin › Logs.

Journaux : jamais l'adresse. L'identifiant de groupe n'entre dans un message qu'après
`searcherDenial` ; une erreur Firestore survenue avant ne le porte que tronqué à 32 caractères
(`unverifiedGroupRef`), en `firestoreDocId`, avec le message « groupe non vérifié ». Une erreur
Firestore est journalisée (`logError`) et rendue `internal`.

**Écart assumé.** Un propriétaire qui connaît le nom d'un compte peut confirmer son adresse
par devinette : il essaie des adresses plausibles jusqu'à ce que la réponse rende ce nom. Le
plafond borne la devinette à dix essais par jour, et la cinquième réponse vide du jour
déclenche l'avertissement. La recherche n'expose aucune liste d'adresses et n'en rend aucune ;
elle confirme seulement une adresse que l'appelant a déjà formulée en entier.

Client : `GroupRepository.findMemberByEmail(groupId, email)` appelle la callable et lit la
réponse par `memberFromSearchResponse` (`groups/domain/member_email_search.dart`) ;
`resource-exhausted` devient `MemberSearchLimitReached`. Toute erreur est signalée
(`ErrorReportService`, feature `group_search_email`, contexte `group_id` et issue, sans
l'adresse). Dans la feuille « Gérer les membres », une saisie qui contient `@` suspend la
recherche par nom ; une adresse complète (`looksLikeEmail`) part à la validation de la saisie
ou au bouton « Chercher cette adresse », jamais à chaque frappe. Les recherches par nom et par
adresse ont chacune leur indicateur (`_searching`, `_emailSearching`) : la fin de l'une ne
coupe pas celui de l'autre. Une réponse arrivée après une modification de la saisie est
écartée. Le plafond pose `_limitReached` pour la durée de vie de la feuille : la flèche
disparaît, la validation est ignorée, et le message s'affiche en ligne, en
`colorScheme.error`, à la place de l'aide ; un échec réseau s'affiche de même, pour la saisie
qui l'a provoqué.


### Tickets — bugs, idées et questions envoyés sur GitHub

Un membre approuvé (`reader`, `editor`, `admin`) envoie un ticket depuis le menu du compte. Le
serveur l'enregistre dans `tickets` (§3.12 bis), le publie en Issue sur le dépôt **public**
`ChinaFred/KassDalle`, et en suit le statut par un webhook GitHub, doublé d'une relecture
horaire. Aucun appel de modèle : pas de poste d'IA, rien au reporting de coûts. L'analyse des
tickets est faite par une session Claude Code, sur demande de l'administrateur.

Code serveur : `functions/src/tickets/` — `rules.ts` (règles pures, testées par
`tests/tickets.test.ts`), `github.ts` (client REST par `fetch`, aucun SDK), `service.ts`
(envoi et application des retours), `webhook.ts` ; `callable/ticketsCallable.ts` ;
`scheduled/ticketsSyncSchedule.ts`.

| Fonction | Type | Garde | Contrat |
|---|---|---|---|
| `submitTicket` | Callable | `requireAuth` (approuvé, non révoqué, App Check) | `{ type, title, description, screen, app_version, platform }` → `{ ticketId, status: "received" \| "sending", remaining_today: int \| null }` (`null` pour l'admin). Erreurs : `invalid-argument` (bornes, `details.field`), `permission-denied`, `resource-exhausted` avec `details: { reason: "member_daily_limit" \| "global_daily_limit", limit }`, `failed-precondition` (`app_config/tickets` illisible) |
| `attachTicketScreenshot` | Callable | `requireAuth`, auteur du ticket | `{ ticketId, path }` → `{ ok: true }`. `path` vaut `tickets/{uid}/{ticketId}/screenshot.png` ou `.jpg` ; l'objet doit exister, au type annoncé par son extension, 5 Mo au plus, et ses 8 premiers octets porter la signature de ce format (`screenshotBytesMatch` : `89 50 4E 47 0D 0A 1A 0A` pour PNG, `FF D8 FF` pour JPEG), sinon `invalid-argument` |
| `retryTicketSend` | Callable | `requireAdmin` | `{ ticketId }` → `{ status }`. Remet `send_attempts` à zéro et tente l'envoi une fois ; sans effet sur un ticket déjà publié |
| `githubTicketWebhook` | HTTPS (`onRequest`, `invoker: "public"`) | signature `X-Hub-Signature-256` | voir ci-dessous |
| `ticketsSyncSchedule` | Cloud Scheduler, toutes les heures | — | reprise des envois, resynchronisation |

**Envoi.** `submitTicket` valide les entrées (`readTicketInput` : titre 5 à 100 caractères,
description 1 à 2 000, écran réduit à un modèle de route, version, plateforme), après une garde
de taille brute (`requireBoundedText`, `_inputBounds.ts`). Les plafonds (`app_config/tickets`,
5 par membre et 30 pour la famille par jour Europe/Paris, l'admin exempté) sont lus et
incrémentés dans la transaction qui crée le ticket en `sending`. Puis `sendTicket` publie
l'Issue : titre du ticket, corps sur un gabarit fixe (`buildIssueBody` : type, écran, version,
plateforme, référence opaque = identifiant du document, description), étiquettes `source:app`,
`type:<type>`, `statut:à-analyser`. Ne partent **jamais** : nom, adresse, uid, capture, contenu
de recette. Les mentions `@nom` du titre et de la description reçoivent une espace sans chasse
(`neutralizeMentions`) : GitHub ne notifie personne. Les renvois `#N` et `owner/repo#N`
reçoivent la même espace après le `#` (`neutralizeIssueReferences`) : l'Issue ne crée aucun
lien ni aucun événement « mentioned this » sur une autre Issue ou PR. Le numéro et l'adresse de l'Issue sont
écrits avec `status: received` avant que l'envoi soit tenu pour fait. En échec :
`send_attempts` + 1, `last_send_error`, `logError`, et la callable réussit quand même avec
`status: "sending"`.

**Pas de double publication.** Un bail de deux minutes (`send_lease_until`, posé en
transaction) empêche deux envois simultanés du même ticket. Une reprise (`retryTicketSend`,
tâche horaire) cherche d'abord l'Issue par la référence du ticket (`GET /search/issues`) : une
création réussie chez GitHub dont le numéro n'a pas été écrit est rattachée, pas republiée.

**Jeton refusé.** Un secret `GITHUB_TICKETS_TOKEN` vide, une réponse 401, 403 (hors limite de
débit) ou 404 sur le dépôt posent `app_config/tickets_status.token_invalid_since` ; le premier
appel réussi l'efface. Ces échecs n'usent pas `send_attempts` : les tickets repartent quand le
jeton est remplacé, comme l'annonce le bandeau d'Admin › Tickets. La tâche horaire s'arrête au
premier jeton refusé.

**Webhook.** `githubTicketWebhook` n'accepte que `POST`, et calcule le HMAC SHA-256 du corps
**brut** (`req.rawBody`) sous `GITHUB_WEBHOOK_SECRET`, comparé à temps constant
(`verifyGithubSignature`, `timingSafeEqual`). Avant le HMAC, un corps de plus de 25 Mo
(`WEBHOOK_MAX_BODY_BYTES`, plafond des livraisons GitHub) rend 413, et une requête sans en-tête
`X-GitHub-Event` rend 400. Secret vide : 503, journalisé au plus une fois par minute et par instance ; signature absente ou fausse : 401, journalisé
par un `logWarn` au plus une fois par minute et par instance, qui porte le nombre de refus
depuis le relevé précédent (`SignatureRejectionLog`) ; corps illisible : 400. Événements
traités (`updatesFromEvent`) :

- `issues` (`opened`, `edited`, `labeled`, `unlabeled`, `closed`, `reopened`) : statut dérivé
  des étiquettes et de l'état (§3.12 bis) ;
- `issue_comment` (`created`, `edited`, hors commentaires de PR) : seul un commentaire du
  compte `ChinaFred` qui commence par « Réponse : » devient `reply_text`, préfixe retiré. Le
  contrôle compare `comment.user.id` à l'identifiant numérique `GITHUB_TICKETS_MAINTAINER_ID`
  (16348852), pas le login : un login se renomme et peut être repris par un autre compte ;
- `pull_request` (`opened`, `reopened`, `edited`, `ready_for_review`, PR ouverte) : chaque
  Issue citée par un mot-clé de fermeture passe à `in_progress`, jamais depuis une fin, si
  l'auteur de la PR est le mainteneur (`user.id`) ou si `author_association` vaut `OWNER`,
  `MEMBER` ou `COLLABORATOR` (`isTrustedPrAuthor`). Une PR ouverte depuis un fork par un autre
  compte ne change aucun ticket ;
- `ping` : 200.

Tout autre événement, un autre dépôt, ou une Issue sans ticket (elle ne vient pas de
l'application) : 200, ignoré. Aucun texte de GitHub n'est écrit hormis `reply_text` filtré.
Une panne Firestore rend 500 : GitHub affiche la livraison en échec, et la tâche horaire
rattrape l'état. Un commentaire supprimé ne retire pas `reply_text`.

**Resynchronisation.** Chaque heure, `ticketsSyncSchedule` relit l'Issue de chaque ticket
`received`, `analyzed`, `validated` ou `in_progress` (200 au plus) : état et étiquettes
(`GET /issues/{n}`), PR ouvertes qui la ferment (chronologie, événements `cross-referenced`,
« Closes #N » dans leur corps, auteur de confiance selon la même règle que le webhook, lue sur
`source.issue.user.id` et `source.issue.author_association`), dernière réponse du compte
16348852 (commentaires). Les tickets
clos ne sont pas relus : une réouverture dont le webhook est perdu n'est pas rattrapée.

**Secrets.** `GITHUB_TICKETS_TOKEN` : jeton « fine-grained » limité au dépôt
`ChinaFred/KassDalle`, permissions Issues lecture-écriture, Metadata lecture, Pull requests
lecture ; attaché à `submitTicket`, `retryTicketSend` et `ticketsSyncSchedule`.
`GITHUB_WEBHOOK_SECRET` : secret partagé du webhook, attaché à `githubTicketWebhook` seule. Les
deux sont lus par `process.env`, comme `ANTHROPIC_API_KEY` : une valeur vide n'arrête aucune
fonction, elle laisse les tickets en « Envoi en cours » (jeton) ou refuse les livraisons du
webhook (secret). Comme `GMAIL_SENDER`, un secret déclaré mais **absent** de Secret Manager fait
échouer tout le déploiement des Functions : les deux doivent exister avant de fusionner (une
valeur vide suffit pour débloquer le déploiement) :

1. `firebase functions:secrets:set GITHUB_TICKETS_TOKEN --project kassdale-6d948`, coller le
   jeton (GitHub › Settings › Developer settings › Fine-grained tokens, dépôt
   `ChinaFred/KassDalle` seul) ;
2. `firebase functions:secrets:set GITHUB_WEBHOOK_SECRET --project kassdale-6d948`, coller une
   chaîne aléatoire longue (par exemple `openssl rand -hex 32`).

Remplacer un jeton demande un `functions:secrets:set` puis un redéploiement des trois fonctions
qui le montent (une version de secret est figée au déploiement).

**Mise en place du webhook GitHub** (dépôt `ChinaFred/KassDalle` › Settings › Webhooks › Add
webhook), après le premier déploiement :

- *Payload URL* : `https://europe-west1-kassdale-6d948.cloudfunctions.net/githubTicketWebhook`
  (l'adresse exacte est affichée par `firebase deploy` et dans la console Cloud Run) ;
- *Content type* : `application/json` — le format `x-www-form-urlencoded` n'est pas lu ;
- *Secret* : la valeur de `GITHUB_WEBHOOK_SECRET` ;
- *SSL verification* : activée ;
- *Which events* : « Let me select individual events » › **Issues**, **Issue comments**,
  **Pull requests** ;
- *Active* : coché. GitHub envoie un `ping` à l'enregistrement : il doit revenir en 200.

Les étiquettes `source:app`, `type:bug`, `type:evolution`, `type:feature`, `type:question`,
`statut:à-analyser`, `statut:analysé` et `validé` sont créées par GitHub à la première Issue qui
les porte, si elles n'existent pas.

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

Mêmes réservations pour les quatre chemins qui n'empruntent pas `callModel` : la production
d'image (`runImageModel`), l'amélioration d'illustration (`enhanceCulinaryImage`, jusque-là
hors plafond), le bac à sable (`askModel` sur un modèle choisi) et la modération d'images
(`moderateAndPromote`, depuis v0.23.48). La modération réserve une place **par image analysée**,
au coût connu d'avance — unités Cloud Vision fois le prix de l'unité, lus dans la grille
(`visionAnalysisCostUsd`, option `estimateUsd` de `reserveDailyBudget`) — et enregistre
chaque analyse par `recordUsage` avant de rendre sa place (`analyseAndRecord`). `assertWithinDailyBudget`
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
| 1 — transcription | `gemini/transcription.ts` | `transcription_page` (scan), `text_extraction` (texte collé) ou `url_import_fallback` (page web sans données structurées ; une page qui en porte n'a pas de passe 1) | l'image, ou le texte | **du JSON** — type de page, inventaire déclaré, sections d'ingrédients, sections d'étapes, notes, chapeau, `langue` de chaque recette |
| 1 bis — traduction, si `langue` ≠ `fr` | `gemini/translation.ts` | `recipe_translation` (scan et texte collé) | le JSON de la passe 1, **jamais l'image** | le même JSON, en français, mesures en métrique |
| 2 — balisage | `gemini/tagging.ts` | `recipe_tagging`, ou `url_import` pour une page web | la transcription, **jamais l'image** | **du CookLang**, plus la liste normalisée, les cuisines et les types de plat |

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

**La traduction (v0.23.16).** La passe 1 rend `langue`, code ISO 639-1 lu sur les **étapes** :
le titre et les noms d'ingrédients ne décident pas (« cheesecake », « wok » restent `fr`). Elle
recopie dans la langue de la page, unités comprises, sans rien traduire.
`normalizeLanguageCode` ramène la valeur à deux lettres minuscules ; toute valeur illisible
vaut `fr`, et une transcription antérieure au champ aussi. Traduire à tort réécrirait une
recette française ; une recette étrangère laissée telle quelle se corrige à la main.
`needsTranslation` décide, sans appel. Une page française ne coûte rien de plus.

`translateRecipe` envoie `TRANSLATION_PROMPT` (mis en cache) et le JSON transcrit, sans image,
avec `effort: "medium"`, `maxTokens: 16 000` et un délai de 3 minutes. Le prompt impose :
traduire phrase par phrase, sans résumer ni fusionner ; garder les noms établis en français ;
garder le nom d'un ingrédient sans équivalent, suivi d'un équivalent courant entre parenthèses ;
convertir un solide mesuré en volume en grammes selon l'ingrédient, un liquide en millilitres,
°F en °C arrondis à 5 °C, inch en cm ; valeurs US par défaut, UK si la source est britannique ;
`tbsp` et `tsp` en cuillères, nombre gardé ; portions et page recopiées.

`translationShapeMismatches` contrôle la réponse, sans appel : mêmes nombres de groupes
d'ingrédients et de lignes par groupe, de groupes d'étapes et d'étapes par groupe, de notes ;
aucun titre, introduction, titre de groupe, ligne, étape ou note vidé (les durées ne sont
pas contrôlées). Une réponse illisible ou un écart lève « Traduction
impossible : … » après un `logError`. Le job suit alors le chemin ordinaire d'une erreur de
pipeline : nouvelles tentatives Cloud Tasks, puis `dead_letters` (`pipeline_error`) ; il se
relance depuis la file. La réponse brute est journalisée sous le stage `traduction`
(`logAiText`).

Dans `recipeProcessor`, l'étape `translate` se place entre `gemini_call` et `parse`
(`STEP_ORDER`). Pour une tranche de livre, `assertWithinImportBudget(scanId,
"recipe_translation")` précède chaque traduction. Le point de reprise
(`transcription_checkpoint`) est réécrit après chaque recette traduite : une relance après un balisage en
échec ne retraduit pas. Le balisage, `checkFidelity`, les tags et la nutrition travaillent sur
la traduction. `saveDraft` pose `langue_origine` et écrit `origine/texte` dans le même lot
(§3.6 bis). Le texte collé (`extractRecipeFromText`) traduit de la même façon, renvoie
`langue_origine` au client et ne stocke pas l'original : le texte collé est déjà conservé en
`.txt` comme fichier source. Une page qui n'est pas une recette n'est pas traduite.

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

### Import d'une recette depuis un lien

Un éditeur ou un administrateur colle l'adresse d'une page de recette. La recette arrive en
brouillon dans « Mes recettes du web », par le pipeline asynchrone de tout import.

**Côté client**, une seule boîte : `showUrlImportDialog` (`url_import_dialog.dart`), qui rend
`true` quand le lien est parti. Le paramètre `initialUrl` pose l'adresse dans le champ, sans
lui donner le focus ; rien ne part avant « Importer ». Points d'entrée : « Importer depuis un
lien » d'Explorer, de `/scan` et de la saisie manuelle ; le bandeau d'Explorer au retour de
Google (§6, « L'écran Explorer : filtre local, IA sur demande ») ; « Partager vers Kass'Dalle » sur Android (§12,
`SharedLinkImportHost`). Les deux derniers posent `initialUrl`.

**Entrée : `importRecipeFromUrlFn`** (`callable/urlImportCallable.ts`, `requireEditor`, 30 s).
Dans l'ordre, avant toute dépense :

1. **Adresse** (`parseImportUrl`, `web/urlGuard.ts`) : `http` ou `https`, 2 048 caractères au
   plus, sans identifiants (`user:pass@`), port 80, 443, 8080 ou 8443, nom d'hôte non interne
   (`localhost`, `*.localhost`, `metadata.google.internal`, `*.internal`, `*.local`, nom sans
   point), IP littérale publique. Puis **résolution DNS** (`assertPublicHost`) : une seule adresse
   non publique suffit à refuser. Réponses `invalid_url` (ce n'est pas un lien web) ou `refused`
   (hôte refusé), journalisées en `WARNING`.
2. **Doublon** : une recette du compte de même `source_url` normalisée → `duplicate` avec son
   identifiant et son titre, sauf `force: true` (« Importer quand même »).
3. **Plafond du jour** : `URL_IMPORT_DAILY_LIMIT` = 10 imports par compte et par jour UTC,
   multiplié par `budgetMultiplierFor` (×100 pour le fondateur, `FOUNDER_DAILY_BUDGET_MULTIPLIER`).
   Compteur `url_import_daily/{uid}_{jour}`, lu et incrémenté **dans la même transaction** que la
   création du job : deux demandes simultanées ne dépassent pas le plafond. Atteint →
   `quota_exceeded` avec `limit`.
4. **Job** `recipeUrlImport` (`queued`, `source_url`, `scan_id` tiré par le serveur) → `queued`
   avec `jobId` et `remaining`.

`getUrlImportQuotaFn` (`requireEditor`) rend `{limit, used, remaining}` pour la boîte du client.
`ensureWebBookFn` (`requireEditor`, sans appel de modèle) crée ou retrouve « Mes recettes du
web » (`findOrCreateWebBook`) et rend `{bookId, titre}` ; `ensureSystemBooks` l'appelle à
l'ouverture de la bibliothèque, avec les autres livres système (§3).
Les issues attendues sont des réponses, pas des `HttpsError` : le client les affiche sans
rapport d'erreur.

**Lecture de la page** (`web/safeFetch.ts`), dans `recipeProcessor` via `prepareUrlImport`.
L'adresse est revérifiée : un job relancé ne repasse pas par la callable. La requête part sur
`node:http` / `node:https`, pas sur `fetch` : `fetch` résout le nom lui-même après le contrôle,
et un DNS qui répondrait « public » puis `169.254.169.254` passerait entre les deux. Ici la
résolution du socket **est** le contrôle (`guardedLookup`) : toute adresse non publique
(boucle locale, privées RFC 1918, lien local dont `169.254.169.254`, CGNAT `100.64.0.0/10`,
IPv6 ULA `fc00::/7`, lien local `fe80::/10`, IPv4 mappée ou NAT64 vers une adresse privée,
NAT64 local `64:ff9b:1::/48`, SIIT `::ffff:0:0:0/96`, Teredo `2001:0::/32`, 6to4 `2002::/16`,
multidiffusion, documentation) fait échouer la connexion. Trois redirections au plus, chacune
revérifiée ; 10 s en tout ; 3 Mo après décompression (gzip, deflate, brotli) ; `text/html` ou
`application/xhtml+xml` exigé ; User-Agent `KassDalle-RecipeImport/1.0`. Aucune dépendance de
plus : modules natifs de Node.

**Le flux décompressé suit la requête.** `decodedStream` détruit le décompresseur dès que la
réponse échoue ou se ferme avant sa fin : un délai dépassé fait échouer la lecture aussitôt,
au lieu d'attendre la fin des 540 s de la tâche.

**Extraction** (`web/recipePage.ts`, pur, testé sur des pages réduites dans
`functions/src/tests/fixtures/web/`). Tout le découpage du HTML se fait par `indexOf`, en un
passage : une expression de la forme `<tag[\s\S]*?</tag>` ou `<[^>]*>` repart de chaque `<`
quand la balise n'est jamais fermée, et trois mégaoctets de `<script` sans `</script>`
rendaient la lecture quadratique. Une balise ouvrante de plus de 8 Ko n'est pas lue, et ses attributs ne sont lus que sur
ses 1 024 premiers caractères (`ATTRIBUTES_MAX_CHARS`), avec un nom d'attribut qui ne démarre
qu'en début de mot et se lit d'un bloc : la lecture des attributs reste linéaire ; un
élément jamais fermé arrête la lecture ou emporte la suite.

- **Données structurées** d'abord : chaque bloc `<script type="application/ld+json">`, `@graph`,
  tableaux et `ItemList` compris. Une recette `schema.org/Recipe` **complète** (un titre, au
  moins un ingrédient, au moins une étape — `HowToStep`, `HowToSection`, texte multiligne) est
  **projetée sans modèle** dans la forme de la transcription (`projectJsonLdRecipe`), si elle
  tient dans `JSON_LD_BOUNDS` — 60 000 caractères au total, 200 ingrédients, 150 étapes,
  2 000 caractères par ligne. Au-delà, le job finit en `no_recipe`, sans appel de modèle : lignes
  d'ingrédients telles quelles, sections d'étapes, `recipeYield` → portions, durées ISO 8601 →
  « 1 h 30 min », langue de `inLanguage` sinon `<html lang>`. Un bloc JSON illisible est
  journalisé (`WARNING`) et ignoré. Deux champs de la recette JSON-LD sont lus sans entrer
  dans aucun prompt : `author` (`readAuthor`) devient `source_author`, et `nutrition`
  (`readNutrition`, valeurs par portion) devient `source_nutrition`, comparé ensuite au calcul
  de la nutrition (`source_nutrition_check`, §3). `recipeCategory`, `recipeCuisine`,
  `keywords` et `aggregateRating` ne sont pas lus : les tags viennent du balisage.
- **Sinon, le texte principal** de la page (`extractMainText` : `<article>`, sinon `<main>`,
  sinon `<body>`, sans scripts, styles, menus, en-tête, pied, formulaires ; 60 000 caractères au
  plus) suit la chaîne du texte collé : `transcribeText` avec le poste **`url_import_fallback`**.
  Moins de 80 caractères, ou aucune recette transcrite : `no_recipe`.
- Plusieurs recettes : la première est reprise, le nombre part dans `recettes_trouvees`.

Puis, comme pour un scan : traduction si la langue n'est pas le français
(`recipe_translation`), balisage par `tagAndNormalize` avec le poste **`url_import`** (même
prompt que `recipe_tagging`), contrôle de fidélité, **bornes des ingrédients**
(`boundIngredients` : 200 lignes au plus, nom ≤ 120 caractères, unité ≤ 40, lignes écartées
journalisées en `WARNING`), écriture par `saveDraft` avec `origin: "web"`, `source_url`,
`source_site`, et sur le chemin `json_ld` `source_author` et `source_nutrition` quand la page
les publie, dans le livre système « Mes recettes du web »
(`findOrCreateWebBook`). Le texte principal de la page (ou, à défaut, la recette projetée) est
joint comme document original, précédé de l'adresse et de la date de lecture.

**Photo** (`attachWebPhoto`), **après** l'écriture : l'image de la recette JSON-LD, sinon
`og:image`, récupérée par le même garde (`image/*`, 8 Mo, 10 s), décodée par `sharp` (importé à
la demande) avec `limitInputPixels: 40 000 000` et `failOn: "error"`, son format vérifié par
`metadata()` (JPEG, PNG, WebP, AVIF/HEIF, GIF ; SVG refusé), convertie en JPEG 1 600 px au plus — la modération n'accepte que JPEG et PNG, et la
conversion retire les métadonnées —, déposée en quarantaine, puis
`moderateAndPromote` vers `recipe_illustration` avec `attachOnApproval`. Approuvée : ajoutée à
`image_urls`. En attente : la recette est créée sans photo, et la photo la rejoint quand
`reviewModeratedImageFn` ou `retryPendingModerationFn` l'approuve (`attachApprovedIllustration`,
champ `attach_on_approval` de `image_moderation`). Refusée ou en échec : recette sans photo,
sans échec du job, incident journalisé. La modération est comptée sous son poste habituel,
`image_moderation`.

**Postes de coût.** `url_import` (balisage) et `url_import_fallback` (transcription d'une page
sans données structurées), inscrits dans `ROUTABLE_FEATURES` (groupe « Import ») et dans
`kFeatureCatalog` / `kFeatureProcess` (« Rédaction d'une recette »). Une page à données
structurées coûte **un** appel de modèle (le balisage), plus la traduction le cas échéant ; une
page sans données en coûte deux. Le plafond quotidien d'IA (`ai_daily_spend`) s'applique en
plus, comme à tout appel.

**Échecs**, codés sur le job (`error_code`) et en dead letter (`failure_reason: url_{code}`) :
`page_blocked`, `page_not_found`, `no_recipe` et `url_refused` ne se rejouent pas ; `timeout`
(délai, réseau, 5xx) suit la reprise Cloud Tasks. Chaque échec passe par `logError`. Depuis la
file, l'utilisateur relance un `timeout` ou un échec sans code, deux fois au plus
(`url_retry_count`, §3.4) ; une relance ne consomme pas d'import du plafond quotidien.

**Ce qui n'est pas borné ici.** Les imports par scan et par texte collé écrivent dans
`nutrition_ingredients` sans les bornes de `boundIngredients` : leur texte vient de
l'utilisateur, pas d'un tiers. La borne ne vaut que pour l'import par lien.

### Où vivent les prompts

| Fichier | Ce qu'il porte |
|---|---|
| `gemini/promptsExtraction.ts` | `TRANSCRIPTION_PROMPT`, `TEXT_TRANSCRIPTION_PREAMBLE`, `TAGGING_PROMPT` |
| `gemini/translation.ts` | `TRANSLATION_PROMPT` |
| `gemini/prompts.ts` | `GEMINI_BOOK_COVER_PROMPT`, `GEMINI_POLISH_PROMPT`, `COOKLANG_RULES` |
| `illustrations/prompts.ts` | les cinq questions de la chaîne d'illustrations |
| `nutrition/allergenExamination.ts` | `buildAllergenPrompt` — les allergènes majeurs d'un lot de quarante ingrédients du référentiel. Les quatorze clés de l'annexe II INCO et leurs exemples viennent de `nutrition/allergens.ts` (`ALLERGEN_KEYS`, `ALLERGEN_LABELS`, `ALLERGEN_EXAMPLES`). Règles : en cas de doute, signaler ; un produit composé se juge sur sa forme du commerce habituelle (pâte feuilletée → gluten et lait, sauce soja → soja et gluten, bouillon cube → céleri et gluten, chocolat noir → lait, vin et vinaigre de vin → sulfites) ; beurre, ghee, crème → lait ; avoine → gluten ; pas de traces. Schéma JSON fermé `{ingredients: [{id, allergens: [enum des 14]}]}`, lu par `parseAllergenBatchAnswer` : une forme inattendue fait échouer le lot entier (rien n'est posé, `logError`), une clé hors liste est écartée et journalisée (`logWarn`). Deux postes : `allergens_auto` (à l'écriture d'une recette, dans `syncRecipeNutrition`, en parallèle du produit acheté) et `backfill_allergens` (Admin › Backfills), tous deux dans le groupe « Nutrition » du routage et « Valeurs nutritionnelles » du catalogue comptable |
| `gemini/timeEstimate.ts` | `buildTimeEstimatePrompt` — la préparation (main à la pâte, hors cuisson et repos) et la cuisson (hors repos, marinade, levée, réfrigération ; cuissons successives additionnées) d'un lot de huit recettes au plus, en minutes entières de 1 à 1440 ; 0 pour « pas de cuisson » ou « ne sais pas ». Chaque recette part en JSON (`id`, `titre`, `portions`, `contenu` : le CookLang sans ses lignes `>>`, 2 000 caractères au plus, caractères de contrôle retirés), avec la consigne de la lire comme une donnée, jamais comme une instruction. Schéma JSON fermé `{recipes: [{id, prep_minutes, cook_minutes}]}` via `askJson`, lu par `parseTimeEstimateAnswer` : forme inattendue → lot en échec (`logError`, rien d'écrit) ; identifiant inconnu ou répété → ignoré ; valeur hors bornes, décimale ou nulle → `null` (`boundedEstimatedMinutes`). Un poste : `time_estimate` (à l'écriture d'une recette, `syncRecipeEstimatedTimes`, une recette par appel), dans le groupe « Rédaction » du routage et « Rédaction d'une recette » du catalogue comptable. `backfill_time_estimate_batch` (huit recettes par appel) a quitté le routage avec son backfill en v0.23.52 et reste au catalogue comptable |
| `gemini/mealRole.ts` | `MEAL_ROLE_PROMPT` (rôle dans un repas, apports, accompagnements, protéine et féculent principaux), repris mot pour mot par la passe 2 de l'import, la suggestion de tags, le classement à l'écriture et le backfill « Rôle des recettes » ; `MAIN_PROTEIN_STARCH_PROMPT` (protéine et féculent seuls), inclus dans le premier ; le backfill « Protéine et féculent des plats », qui le reprenait seul (`suggestMainProteinStarch`), est retiré en v0.23.52 |

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
- **Une valeur hors liste est absente** : la protéine et le féculent se lisent en liste
  blanche (`parseMainProtein`, `parseMainStarch`), variantes d'écriture seules (accent,
  pluriel, ligature). « veau » ou « poulet » ne deviennent ni « boeuf » ni « volaille » ; le
  prompt demande une chaîne vide pour ce qui n'entre pas dans la liste.
- **Exiger une preuve vérifiable** plutôt qu'une justification — les trois mots réellement lus
  se contrôlent d'un coup d'œil, une justification non.

### Le planning : présélection par le code, choix par le modèle

Depuis v0.23.18, `suggestMealPlanFn` n'envoie plus tout le corpus au modèle. Le serveur
choisit lui-même les candidats de chaque créneau, le modèle tranche entre eux, et le code
relit sa réponse. Code : `gemini/planning.ts` (fonctions pures, fixture
`planning_slot_rules.json`), `gemini/planningStore.ts` (lectures et écritures Firestore).

**Entrée.** Les résumés de recettes envoyés par le client portent `portions` en plus. Deux
champs nouveaux : `mode` (`model` par défaut ; `code` : présélection seule, aucun appel de
modèle, aucune ligne `ai_usage`) et `slotDismissed` (écartés par créneau). Un `alreadyAssigned`
de `slot` hors des dates de la demande (−1) désigne une recette posée ailleurs dans le cycle.
Le serveur lit lui-même `app_config/planning_policy`, les `planned_meals` de l'appelant sur les
90 jours qui précèdent le cycle (`readServedHistory`, index `uid` + `planned_at` existant) et
ses `recipe_ratings` (`readUserRatings`), et depuis v0.23.22 sa mémoire des refus
(`readUserRefusals`, §3.8 ter). Une lecture en échec : `logError`, la génération continue
sans historique (`historyAvailable: false`, aucun fait de service affirmé), sans note ou sans
pénalité de refus.

**Planning d'un groupe.** `suggestMealPlanFn` accepte `groupId` (identifiant de document,
`readPlanningGroupId`) : le planning généré est celui de ce groupe. Le serveur lit
`groups/{groupId}` et refuse (`permission-denied`, « Seul le propriétaire du groupe planifie
pour lui. ») si l'appelant n'en est pas `owner_id` (`assertGroupPlanningOwner`) ; une lecture
en échec rend `unavailable` après `logError`. Rien d'autre ne change : l'appelant est le
propriétaire, et ce sont son historique (`uid ==`, repas de groupe compris : même cuisinier),
ses notes, sa mémoire des refus et ses préférences qui servent. `groupId` ne part pas au
modèle ; il est écrit dans le document de génération (`planning_runs.group_id`). Aucun poste
d'IA de plus : le coût reste imputé à `planning` (et `planning_concept`), au nom de l'appelant.

**Présélection** (`preselect`), créneau par créneau dans l'ordre des dates :

1. **Filtres durs** (`hardFilterReason`), dans l'ordre : rôle (`plat` ; entrée ou en-cas en
   repas léger ; `entree` et `dessert` pour leurs listes), préparation au-delà du maximum du
   jour (plat seulement ; durée absente : passe), repos ≥ 240 min si le créneau tombe
   aujourd'hui ou avant, note personnelle ≤ 3, écartée du créneau, déjà au cycle.
2. **Poids** (`candidateWeight`) = fraîcheur (1 si pas servie en 90 jours, sinon
   jours / 90 borné entre 0,1 et 1) × 2 pour un plat qui se réchauffe sur un créneau de
   réchauffage × 0,6 par répétition d'une protéine déjà au cycle × facteur de note (0,5 de 4
   à 6, 1,5 à partir de 8) × facteur de refus (`refusalFactor` : 0,5 si l'appelant a refusé
   la recette dans les 21 derniers jours, 0,25 à partir de 3 refus ; jamais une exclusion)
   × 0,5 si le féculent du plat est celui d'un créneau voisin (`STARCH_REPEAT_FACTOR`,
   `isStarchRepeat` : veille ou lendemain, recette déjà assignée ou premier plat classé du
   créneau précédent ; « aucun » et un féculent inconnu ne se répètent pas)
   × 0,5 si la protéine du plat est celle d'un créneau voisin (`PROTEIN_NEIGHBOUR_FACTOR`,
   `isProteinNeighbourRepeat` : même lecture que le féculent ; « inconnue » ne se répète pas)
   × 0,5 par répétition de sa famille de cuisine déjà au cycle (`CUISINE_REPEAT_FACTOR`,
   `cuisineRepeatsOf` : recettes déjà assignées et premier plat classé de chaque créneau
   traité). La famille se lit dans les étiquettes `cuisines` (`cuisineFamilyOf` : asiatique,
   indienne, orientale, Amériques, africaine, italienne, européenne, française, inconnue ;
   une famille étrangère l'emporte sur l'européenne, qui l'emporte sur la française). La
   cuisine française et une cuisine inconnue ne sont jamais pénalisées.
   La protéine se lit dans `mainProtein` d'abord (`proteinOf` : le tag `main_protein`, envoyé
   par le client, relu en liste blanche), puis dans `dishTypes` en repli (viande, volaille,
   poisson, fruits de mer, végétarien, inconnue). Le féculent se lit dans `mainStarch`
   (`starchOf`). La justification produite par le code cite la protéine lue ; le prompt
   décrit chaque candidat avec sa protéine et son féculent quand ils sont connus.
3. **Tirage pondéré sans remise** (`weightedOrder`, Efraimidis–Spirakis, graine tirée par
   `crypto`) : deux générations ne rendent pas la même liste. Les recettes déjà en tête d'un
   autre créneau passent après les autres. La tête couvre au moins trois protéines quand la
   liste le permet (`spreadProteins`).
4. **Relâchement** quand un créneau n'a aucun plat : « déjà au cycle », puis « fenêtre de
   variété » ; la recette est alors marquée `repeat` et sa justification dit « peu d'autres
   choix ». La note personnelle ne se relâche **que si tous les plats du corpus sont notés
   ≤ 3**. Le rôle, la durée, le repos et les écartés ne se relâchent jamais : sans
   candidat, le créneau reste vide.

Têtes de liste : `plats_per_slot` plats (5), `starters_per_slot` entrées et
`desserts_per_slot` desserts (3) si le format en demande. Liste gardée pour « Autre
suggestion » : `ranked_depth` plats (15).

**Prompt compact** (`buildPlanningPrompt`) : chaque candidat décrit une fois dans une
section `RECETTES`, puis par créneau les identifiants proposés ; les deux listes sont
mélangées. Un créneau sans choix à faire (un seul candidat partout) n'est pas envoyé. Le
nombre de parts n'est plus une consigne : « les quantités sont recalculées à l'affichage ».
Le modèle rend `[{slot, recipe_id, starter_id?, dessert_id?}]`, sans phrase. `maxTokens` :
4 000 (`PLANNING_MAX_TOKENS`) ; sur Gemini, la sortie reste bornée par
`thinking_budgets.planning`.

**Lecture de la réponse** (`validateModelChoices`) : un identifiant hors de la tête du
créneau, déjà pris, ou un créneau oublié est remplacé par le premier candidat libre de la
liste (`source: "code"`, en évitant la protéine du créneau précédent) ; `rejected_choices`
les compte, `logWarn` si > 0. Les justifications sont les faits du code (`codeJustification`,
qui ajoute « refusée récemment » en dernier quand la pénalité de refus s'applique) ;
le redimensionnement est calculé (`resizeOf` : « Écrite pour 4 parts, servie pour 6. »),
jamais demandé au modèle, et rien n'est écrit dans la recette.

**Remplissage par le code** (`codeFill`) quand le modèle ne choisit pas :

| Cas | Journal | `modelStatus` | Avis à l'écran (`notice`) |
|---|---|---|---|
| appel en erreur (repli compris), réponse vide ou illisible | `logError` | `failed` | « L'IA n'a pas répondu. Kass'Dalle a choisi les plats selon vos contraintes. » |
| estimation au-delà du plafond de la génération | `logWarn` | `budget` | « Cette génération aurait coûté plus de 0,50 € en IA. Kass'Dalle a choisi les plats selon vos contraintes. Rien n'a été facturé. » |
| plafond du jour atteint (`BudgetExceededError`) | `logWarn` | `budget` | « Votre plafond d'IA du jour est atteint. … Rien n'a été facturé. » — au lieu de l'erreur `resource-exhausted` d'avant |
| mode `code`, ou aucun créneau avec un choix | `logInfo` | `skipped` | — |

**Plafond par génération.** Avant l'appel, `ceilingEstimator` résout le moteur et le modèle
du poste (`resolveCallTarget`, `ai/router.ts`, sans appel de fournisseur) et chiffre le coût
plafond sur la grille en vigueur (`estimateCallCeilingUsd` : caractères / 3 en entrée,
`maxTokens` en sortie, plus le plafond de raisonnement Gemini ou 8 192). Le plafond
`cost_cap_eur_per_generation` est converti au taux de la facture (`getUsdToEurRate`). Grille
illisible ou taux absent : pas d'estimation inventée, `logWarn`, le plafond en euros ne
s'applique pas — le plafond de nombre de conceptions et le plafond du jour restent actifs.

**Conceptions** (`generateRecipeConceptFn`, poste `planning_concept`, `maxTokens` 6 000).
Avec `runId`, la conception est rattachée à sa génération : `reservePlanningConcept`
(transaction sur `users/{uid}/planning_runs/{runId}`) refuse une génération inconnue sous
l'appelant (`not-found`), de plus de 6 heures, au compteur atteint, ou dont le coût cumulé
plus les réservations en cours plus l'estimation dépasserait le plafond
(`resource-exhausted`, `details.reason`). Le compteur est incrémenté et l'estimation réservée
(`reserved_usd`) **avant** l'appel, dans la même transaction : des conceptions lancées en
parallèle se voient l'une l'autre. Après, `addPlanningRunCost` ajoute le coût enregistré et
libère la réservation. La réponse porte `conceptsRemaining`. Sans `runId`, la conception est un geste
unitaire (« Concevoir avec l'IA » sur un créneau, idée retenue dans le sélecteur) : hors
plafond de génération, borné par le plafond du jour. Le plafond de génération ne borne donc
que les conceptions automatiques ; le total des conceptions, automatiques et manuelles, n'est
borné que par le plafond du jour de chaque compte.

**Réponse de `suggestMealPlanFn`** : `runId` (`null` en mode `code` ou si le document n'a pas
pu être écrit), `mode`, `modelStatus`, `notice`, `suggestions` (`slot`, `recipeId`,
`starterId?`, `dessertId?`, `justification`, `resized`, `resizeReason?`, `prepDate?`,
`source` `model` | `code`, `repeat?`), `rankedCandidates` (par créneau : `plats`, `entrees`,
`desserts` — `{recipeId, why, repeat?, resizeReason?}` —, `relaxed`, `prepDate?`),
`excludedRecentIds`, `conceptsRemaining`, `stats` (`corpus`, `candidatesSent`, `durationMs`,
`rejectedChoices`, `historyAvailable`). Une réponse lue par un client antérieur reste
compatible : `suggestions` et `excludedRecentIds` n'ont pas changé de forme.

**Côté client.** « Autre suggestion » (Nouveau planning, et menu d'un repas du planning,
ex-« Suggestion IA ») ne fait plus d'appel de modèle : il prend la recette suivante de la
liste classée gardée en mémoire (`nextRankedCandidate`, `ranked_candidates.dart` — filtrage
seulement : écartées, posées ailleurs, sorties du corpus), sinon il rappelle
`suggestMealPlanFn` en mode `code` sur ce créneau. La liste d'un créneau est oubliée quand
son format, sa préparation maximale ou son réchauffage changent. Les conceptions
automatiques ne bouclent que sur `conceptsRemaining` créneaux et s'arrêtent au premier refus.
Les recettes proposées que l'utilisateur écarte sont enregistrées dans sa mémoire des refus
(§3.8 ter) ; Préférences du planning en affiche le nombre et propose « Oublier mes refus ».

### L'écran Explorer : filtre local, IA sur demande

`/search` (`features/search/`) liste à l'ouverture les recettes des sources choisies
(`exploreCorpusProvider` : mes recettes par `getAllByOwners([uid], includeDrafts)`, la famille
par une seconde requête `excludePrivate: true` — deux publics, deux requêtes, pour qu'une
recette secrète d'un autre membre n'entre jamais dans le corpus). Tout le reste se calcule sur
l'appareil, sans appel de modèle (`features/recipes/domain/recipe_filter.dart`, partagé avec le
sélecteur du planning) :

- **Texte** (`matchRecipeQuery`) : minuscules, sans accents (`foldSearchText`). Un mot tapé
  correspond quand un mot du texte **commence** par lui (« bla » ne trouve plus « sablé ») ;
  « poivre blanc » n'est plus trouvé non plus, car le poivre est un petit ingrédient, lu
  seulement dans le titre ; tous les mots tapés doivent correspondre. La recette se range dans la
  première section où tous les mots se trouvent (`RecipeQuerySection`) : `title` (titre),
  `tags` (titre ∪ cuisines, thèmes, occasions, types de plat), `ingredients` (titre ∪
  étiquettes ∪ noms d'ingrédients et `ingredients_index` hors petits ingrédients). Petits
  ingrédients (`isSearchMinorIngredient`) : `NutritionQuantityConverter.isSeasoning`, lu sans
  être modifié, plus `kSearchMinorIngredientWords` (huile, beurre, vinaigre, eau, persil,
  ciboulette, coriandre, basilic, menthe, sucre, farine, ail, oignon), comparé au premier mot
  du nom au singulier, après un mot de mesure (« gousse d' », « noix de », « filet d' »). Cette
  liste est propre à la recherche, côté Dart seul : ce n'est pas une logique dupliquée, et le
  filtre « Sans l'ingrédient » ne la lit pas. Un mot tapé qui nomme un petit ingrédient
  (`titleOnlyQueryWords`) n'est cherché que dans le titre ; la ligne d'état le dit
  (`titleOnlyWordsLine`), avec le mot tel que tapé (« « Sésame » n'est cherché que dans les
  titres. ») — la forme repliée ne sert qu'à reconnaître le petit ingrédient et à écarter un
  doublon. `applyRecipeFilter` trie chaque section avec le tri choisi, dans
  l'ordre fixe des sections, et rend `RecipeFilterOutcome.sections` (vide sans texte),
  `matchedIngredients` (« Avec : lait de coco » sur la tuile) et `recipes`, le total de toutes
  les sections — compteur de l'écran et « Voir N recettes » de la feuille. À l'écran, chaque
  section a un en-tête repliable (`QuerySectionHeader` : 48 px, `Semantics(button, expanded)`,
  infobulle « Afficher » / « Masquer ») ; `ingredients` est repliée quand `title` ou `tags`
  a des résultats. L'état ouvert/fermé vit dans l'état de l'écran et revient au défaut quand
  le texte change. Sans texte, la liste est simple ; l'en-tête « Vos recettes » ne s'affiche
  que sans texte. Entrée ferme le clavier et ne lance rien.
- **Filtres** (`RecipeFilter`) : OU dans une dimension, ET entre les dimensions ; les exclusions
  (ingrédient, allergène) écartent une recette qui contient l'une OU l'autre valeur. Une recette
  sans donnée pour un filtre actif est écartée et comptée par dimension
  (`RecipeFilterOutcome.missingData`, ligne « N recettes sans … écartées »). Temps total =
  préparation + cuisson, l'une des deux suffit, le repos n'est pas compté
  (`recipeTotalMinutes` : `tags`, puis métadonnées CookLang — `readDurations`). Durée estimée (`estimated_times`, §3) : `RecipeFilterContext.forFilter`
  branche `recipeTotalMinutesWithEstimates` sur `totalMinutesOf` quand
  `RecipeFilter.countEstimatedTimes` est coché (défaut) — filtre « Temps total », nombres des
  seuils et tri « Plus rapides ». Décoché, une recette que son estimation aurait retenue est
  comptée dans `RecipeFilterOutcome.estimatedTimeExcluded` (« N recettes à durée estimée
  écartées »). La tuile affiche toujours l'estimation, marquée « ≈ …, estimé »
  (`recipeTimes`, `exploreDurationText`). Calories par portion =
  `nutrition.perPortionFor(portions)['kcal']`, calculées à l'affichage, rien n'est écrit.
  « Sans allergène » écarte une recette jamais analysée ou d'analyse incomplète
  (`allergens.complete == false`). Note minimale et tri « Mieux notées » : la note du lecteur
  (`recipe_ratings` filtrées sur son uid), pas une moyenne familiale.
- **Préférence** : sources, filtres et tri sous `users/{uid}/preferences/explore_filters` (§3).

L'IA ne part que sur un bouton. Le `reader` n'a que « Chercher sur le web » :

| Bouton | Callable | Poste | Garde | Ce qui part |
|---|---|---|---|---|
| « Chercher avec l'IA · N recettes » | `searchRecipesFn` | `search` | `requireEditor` | le texte du champ comme demande ; comme corpus, les recettes retenues par les filtres **sans** le filtre texte (N), résumées par `buildRecipeSummary` |
| « Imaginer 3 recettes » | `generateRecipeFn` ×3 (+ une relance par doublon) | `generate` | `requireEditor` | le texte du champ seul ; douze résumés du corpus et l'observation locale tirée des notes |
| « Chercher sur le web » | `searchWebRecipesFn` | `web_recipe_search` | `requireAuth` (tous les rôles approuvés) | le texte du champ seul, nettoyé et borné à 200 caractères ; aucun appel quand le cache partagé a la réponse |
| « Voir sur Google » (section « Sur le web ») | — | — | — | aucun appel : `google.com/search?q=<texte> recette` (`googleRecipeSearchUri`) |

**« Chercher sur le web »** (`searchWebRecipesFn`, `callable/webSearchCallable.ts`,
`requireAuth`, 90 s, 512 Mio, secret `GEMINI_API_KEY`). L'enchaînement vit dans
`web/webSearchFlow.ts` (`runWebSearch`, testé sans Firestore) :

1. **Requête** : `readWebSearchQuery` retire les caractères de contrôle, resserre les
   espaces, refuse un texte vide ou de plus de 200 caractères (`invalid-argument`,
   `details: { reason: "web_search_query" }`) — refus, jamais troncature. Le refus est
   journalisé avant d'être levé (`logWarn`, longueur mesurée et borne seulement, jamais le
   texte). Le client ne vérifie pas la borne : il affiche le message du refus
   (`WebSearchQueryRefused`), et la règle n'existe qu'une fois. Le champ d'Explorer sert
   aussi au filtre local, qui n'a pas de limite, donc pas de `maxLength` sur le champ.
2. **Cache** (`web_search_cache`, §3.14) : une entrée de moins de sept jours est rendue
   telle quelle, `fromCache: true`, sans appel de modèle et sans décompte ; `remaining`
   relit le compteur. Une lecture en échec est journalisée (`logError`) et traitée comme
   absente : la recherche part, et elle est décomptée.
3. **Plafond** : 50 recherches par jour et par compte, multipliées par
   `budgetMultiplierFor` (×100 pour le fondateur). La place est **réservée** dans une
   transaction sur `web_search_daily/{uid}_{jour}` avant l'appel : deux appels simultanés
   ne passent pas sur la dernière place. Plafond atteint : `resource-exhausted` avec
   `details: { reason: "web_search_daily_quota", limit, remaining: 0 }` ; le plafond de
   dépense d'IA du jour (`BudgetExceededError`) part aussi en `resource-exhausted`, avec
   `reason: "ai_daily_budget"`.
4. **Appel de modèle** (`gemini/webRecipeSearch.ts`) : `callGemini` direct, outil
   `googleSearch`, plafond de raisonnement du poste dans la politique, `0` à défaut, 40 s,
   sous `withDailyBudget`. `callModel` n'est pas employé : son repli enverrait le poste
   chez Claude, qui n'a ni la recherche Google ni le bloc de suggestions, et son résultat ne
   porte pas les pages citées. Le prompt demande des pages de recettes, sans vidéo ni réseau
   social ; il demande de **formuler les recherches Google en français** et de retenir des
   pages rédigées en français (sites français, belges, suisses, québécois…), l'anglais
   seulement en complément s'il existe moins de huit pages en français. La réponse rédigée
   n'est pas lue, seules les pages citées comptent. L'appel est enregistré par `recordUsage` (échec compris, en
   `status: "error"`), avec `groundedSearchCount`. Après un appel abouti, l'écriture passe
   par `recordSearchUsage`, qui ne lève jamais : un échec d'écriture d'`ai_usage` est
   journalisé (`logError`, jetons et appel ancré dans `extra`, pour la réconciliation) et
   les pages sont rendues. Lever ferait rendre la place de recherche alors que l'appel est
   facturé. Le poste `web_recipe_search` est aux
   trois endroits : `ctx.feature` ; `ROUTABLE_FEATURES`, groupe « Recherche »,
   `providers: ["gemini"]` et `lockedReason` (verrouillé comme la modération : l'écran
   Moteur d'IA le montre et règle son plafond de raisonnement, sans bascule possible) ;
   `kFeatureCatalog` / `kFeatureProcess` (processus « Recherche »).
5. **Pages** (`web/webSearchResults.ts`) : au plus douze liens de Google, chacun suivi
   par `fetchPublicResource` (garde SSRF, trois redirections revérifiées, 1,5 Mo, 6 s), en
   parallèle. Les liens sont des redirections
   `vertexaisearch.cloud.google.com/grounding-api-redirect/…` : l'adresse finale est celle
   de la page. Écartés : YouTube, youtu.be, TikTok, Instagram, Facebook (fb.com, fb.watch),
   Pinterest (tous ses domaines nationaux, pin.it), sous-domaines compris ; toute adresse
   hors https ; une adresse restée sur la redirection. Une page lue donne titre
   (`og:title`, `<title>`), extrait (`meta description`, `og:description`, description
   JSON-LD) et `directImport` (une recette `schema.org/Recipe` complète,
   `isCompleteRecipe`, la même règle que l'import). **Aucune image n'est relevée** : la
   carte montre une icône sur toutes les plateformes. Une vignette tierce chargée par
   l'appareil donnerait l'adresse IP du lecteur au site, et afficherait une image non
   modérée (règle v0.23.13 : seul `AppNetworkImage` affiche une image réseau, et seulement
   celles du stockage de l'application). Une adresse de plus de 2 048 caractères
   (`WEB_SEARCH_URL_MAX_CHARS`, `httpsUrlOrNull`) est écartée. Une page qui refuse d'être
   lue (403, délai, type inattendu) garde sa carte sans extrait, `directImport` à faux, son adresse
   réelle étant connue
   (`WebFetchError.lastUrl`) ; un refus de la garde SSRF n'en rend aucune. Dédoublonnage
   par adresse finale (sans fragment ni barre finale), huit cartes au plus. **Langue et
   ordre** : chaque page lue donne sa langue (`detectPageLanguage`) — `inLanguage` de la
   recette JSON-LD, puis `<html lang>`, puis `og:locale`, réduits à leur code principal
   (`primaryLanguageCode` : `fr-BE`, `fr_CA` → `fr`) ; sans déclaration, un indice tiré de
   l'adresse seule (`urlSuggestsFrench` : domaine `.fr`, sous-domaine `fr.`, chemin
   `/fr/` ou `/fr-xx/`), sinon langue inconnue. Une page non lue n'a que l'indice de son
   adresse. Le texte des pages n'est pas analysé. `orderByLanguage` range les cartes —
   français, puis inconnue, puis autre langue — par un tri stable qui garde l'ordre de
   Google dans chaque groupe, **avant** la coupe à huit cartes : une page en français citée
   en dixième passe devant une page en anglais citée en premier. Aucune page n'est écartée
   pour sa langue. La langue reste côté serveur (`SourceOutcome.language`) : elle n'est ni
   renvoyée au client ni mise en cache, l'ordre du cache suffit. **Le texte des
   pages est non fiable** : il ne sert qu'à ces champs courts, renvoyés au client, et
   n'entre dans aucun prompt.
6. **Erreur** : la place n'est **rendue** que si l'appel de modèle **lève** une erreur —
   moteur indisponible, quota du fournisseur, plafond de dépense d'IA
   (`BudgetExceededError`) : rien n'a été facturé (transaction qui décrémente, un échec
   journalisé laisse le plafond plus strict d'une unité). Dès que le modèle a répondu,
   l'appel est facturé et la place est **gardée** : réponse sans aucune recherche ancrée
   (`WebSearchUnreadableError`), erreur inattendue en lisant les pages, ou aucune page
   retenue. `reportFailure(err, refunded)` journalise les deux cas (`logError`, `extra.refunded`).
   Une erreur levée avant l'appel du modèle (compteur, réservation) est journalisée
   par la callable (`logError`, « Recherche web échouée avant l'appel du modèle »).
   Le client reçoit `unavailable` avec `details: { reason: "web_search_engine" }` et un
   message écrit pour lui ; `resource-exhausted` avec `reason: "ai_daily_budget"` pour le
   plafond de dépense. Une recherche aboutie sans page retenue n'est pas mise en cache.

Réponse : `{ query, results: [{ url, title, site, snippet, directImport }],
searchEntryPointHtml, webSearchQueries, fromCache, limit, remaining }`.

**Côté client.** `GeminiService.searchWebRecipes` traduit les refus attendus par
`webSearchErrorFrom` (code `resource-exhausted` du SDK ou `resource_exhausted` de l'appel
HTTP du web, ramenés à une forme ; puis `details.reason`) : `WebSearchQuotaExceeded`
(`web_search_daily_quota`), `WebSearchAiBudgetExceeded` (`ai_daily_budget`),
`WebSearchQueryRefused` (`invalid-argument`, `web_search_query`) et
`WebSearchEngineUnavailable` (`unavailable`, `web_search_engine`). Un `unavailable` sans
raison est une coupure réseau : il reste une `GeminiCallableException`. `WebSearchNotifier`
(`webSearchProvider`, en mémoire, autoDispose) range le plafond en `WebSearchQuotaReached`
et le budget en `WebSearchBudgetReached` — deux cartes `secondaryContainer` sans
« Réessayer », avec « Voir sur Google » — et le refus de requête comme la panne du moteur
(`WebSearchEngineUnavailable`) en `WebSearchError`, sans rapport d'erreur (le serveur les
journalise) ; toute autre erreur part par
`reportUnexpectedError(feature: 'search.web')` et donne `WebSearchError`. L'erreur
s'affiche par `AppErrorState` compact : message du serveur (`advice`) et « Réessayer » pour
le moteur, message sans « Réessayer » pour un refus, et `describeError` sinon — qui lit
aussi `GeminiCallableException.code` (hors ligne : « Connexion perdue »). Le pied
« Vidéos et réseaux sociaux exclus. » + « Voir sur Google » suit les cartes, l'état vide
(un encart resserré, `_WebEmptyNotice`, sans icône) et l'erreur. Quand `remaining` vaut 0,
« Il ne vous reste aucune recherche aujourd'hui. » s'affiche sous le bouton du lecteur et
sous la rangée de boutons du grand écran ; le bouton reste actif. Une
recherche en cours ne repart pas ; une réponse arrivée après une nouvelle demande est
ignorée ; `remaining` survit à « Effacer » pour la feuille « Aller plus loin ».
`WebRecipeResult.fromMap` revérifie que chaque adresse est en https. La carte
(`WebResultTile`, `search_widgets.dart`) : `WebResultThumbnail`, l'icône `Icons.public`
64 × 64 sur `surfaceContainerHighest`, toujours ; libellé sémantique unique « titre,
site » ; « Ouvrir », le toucher de la carte, « Ouvrir dans le navigateur » et « Voir sur
Google » passent par `openWebPage` (`web_page_opener.dart`) : sur Android et iOS
(`PlatformUtils.hostPlatform`), `LaunchMode.inAppBrowserView` — Custom Tabs,
SFSafariViewController — quand `supportsLaunchMode` le confirme, et
`LaunchMode.externalApplication` sinon ; sur le web et le bureau,
`externalApplication` (nouvel onglet, navigateur). Une question au plugin en
échec est remontée (`reportUnexpectedError`, `search.web.launchMode`) et la page part
dans le navigateur. Sur Android 11+, `supportsLaunchMode` ne voit les Custom Tabs que
grâce à la requête `android.support.customtabs.action.CustomTabsService` déclarée dans
`<queries>` d'`AndroidManifest.xml`. L'ouverture arme le bandeau d'import du retour avec
l'adresse de la carte (`_armWebReturn`, `_pendingBannerLink`), sans lire le
presse-papiers ; « Importer » ouvre `showUrlImportDialog(initialUrl:)` et, sur `true`, la
carte affiche « Import envoyé ». « Importer » est le même bouton pour toutes les pages
(icône lien, infobulle « Importer cette recette dans vos brouillons ») : le client ne lit
pas `directImport`, que le serveur rend et compte dans son journal
(`logInfo`, `extra.directImport`), et ne l'affiche pas. Sur
le web, le titre est un `Link` dont l'`InkWell` ne prend pas le focus
(`canRequestFocus: false`, l'ancre a `tabIndex = -1`) : un seul arrêt de focus par carte ;
le suivre arme aussi le bandeau (`onLinkFollowed`). Sur un ordinateur, le clic droit
propose « Ouvrir dans le navigateur », « Copier le lien » (`showSuccessSnackBar`
« Lien copié. »), « Importer ». « Recherche de pages de recettes… » est en
`Semantics(liveRegion: true)` ; les `WebResultPlaceholderTile` sont sous
`ExcludeSemantics`.

**Le bloc « Suggestions de recherche »** (`GoogleSearchSuggestions`, 56 px,
`Semantics(label: 'Suggestions de recherche Google')`) est affiché tel que Google le rend,
dans une page minimale (`wrapGoogleSuggestions`) qui ajoute `<meta viewport>`,
`<base target="_blank">` et une CSP `script-src 'none'`. Sans `searchEntryPointHtml`, rien
n'est affiché, marges comprises. Le mode suit le vrai système
(`googleSuggestionsModeFor(PlatformUtils.hostPlatform)`, lu par `dart:io`, pas
`defaultTargetPlatform` que les tests remplacent) :

- **Android, iOS, macOS** : `webview_flutter` (`WebViewController.loadHtmlString`),
  JavaScript désactivé ; le `NavigationDelegate` laisse passer le document lui-même
  (`about:`, `data:`) et bloque toute autre navigation, ouverte par `openWebPage` si
  elle est en https — navigateur intégré sur Android et iOS, navigateur sous macOS. Les réglages sont attendus dans un seul `try` remonté par
  `reportUnexpectedError`. Sous macOS, le fond n'est pas rendu transparent : WKWebView
  macOS n'expose pas ce réglage. macOS n'est pas construit (`FunctionalRequirements.md`, plateformes) : ce chemin n'a
  jamais tourné.
- **Web** : `HtmlElementView` sur une `iframe` `srcdoc`
  (`google_suggestions_frame_web.dart`), `sandbox="allow-popups
  allow-popups-to-escape-sandbox"`, sans `allow-scripts`, `referrerpolicy="no-referrer"`.
  Le document `srcdoc` hérite de la CSP de la page ; il n'est pas chargé par une requête,
  `frame-src` ne s'y applique pas, et `firebase.json` reste inchangé.
- **Windows** : `webview_windows` 0.4.0 (WebView2, paquet tiers de jnschulze, dernière
  version publiée en février 2024 ; son build CMake télécharge `nuget.exe` et le SDK
  WebView2 1.0.1210.39). `WebviewController.getWebViewVersion()` vérifie d'abord que le
  WebView2 Runtime est installé ; absent, ou `initialize` en échec, le bloc retombe sur les
  puces, et l'absence est remontée une fois par session (`reportUnexpectedError`,
  `trigger: windows_runtime`). Le paquet n'a **ni réglage JavaScript ni délégué de
  navigation** : la CSP `script-src 'none'` du document empêche tout script ; les fenêtres
  surgissantes (`<base target="_blank">`) s'ouvrent dans la vue
  (`WebviewPopupWindowPolicy.sameWindow`), et toute adresse signalée par le flux `url`
  autre que le document lui-même fait recharger le bloc et part dans le navigateur
  (https seul). Un lien suivi signale chaque étape de ses redirections
  (`consent.google.com`, puis `/search`) : `ExternalOpenGate` n'ouvre que la première
  adresse, et ignore les suivantes tant qu'elles se suivent à moins d'une seconde ; chaque
  étape repousse la fenêtre (le bloc est rechargé à chaque fois). La navigation a donc
  commencé dans la vue avant d'être défaite : la page Google peut s'y charger un instant.
  Rien n'est affiché pendant l'initialisation de WebView2 : le cadre de 56 px n'apparaît
  qu'une fois la vue prête. Le build Windows n'est pas vérifié par la CI.
- **Linux** : pas de WebView. Les requêtes lancées par Google (`webSearchQueries`)
  s'affichent en puces (`GoogleSuggestionChips`, `Wrap` sans hauteur fixe) qui ouvrent la
  recherche Google : un repli, pas le bloc lui-même. Sans requête, rien n'est affiché.

**Retour du navigateur : bandeau d'import** (éditeur et admin). Quand `launchUrl` a ouvert
Google (« Voir sur Google ») ou une page (« Ouvrir » d'une carte « Sur le web »), l'écran note
en mémoire qu'un retour est attendu (`_awaitingGoogleReturn`) ; une carte y ajoute son
adresse (`_pendingBannerLink`), posée dans le bandeau au retour, sans lecture du
presse-papiers. Au retour,
`AppLifecycleListener.onResume` — le moteur web le déclenche aussi, sur `focus` et
`visibilitychange` — affiche une carte `secondaryContainer` (`_ImportBanner`). Seule sa
phrase est en `Semantics(liveRegion: …)`, pas toute la carte, et seulement quand le bandeau
apparaît au retour (`_bannerAnnounced`).
La carte se pose **sous** la liste des résultats, hors d'elle, sur toutes les tailles
d'écran (`_ListWithBanner`) : au-dessus de `_BottomActions` sur téléphone, en bas de la
colonne des résultats sur grand écran. Elle ne réduit la zone visible que par le bas : le
décalage de la liste et la position à l'écran des cartes ne changent pas. La liste reste
le premier enfant d'un même arbre, avec ou sans bandeau, et n'est pas reconstruite.
Sur téléphone (`compact`), une seule ligne : `importBannerShortSentence` (« Une recette
trouvée ? », `maxLines: 1`), le bouton (libellé tronqué, adresse abrégée en infobulle) et
« Fermer ». Grand écran : `importBannerSentence`, l'adresse abrégée, le bouton et
« Fermer ». Le bandeau est masqué quand le clavier est ouvert : `View.of(context).viewInsets`,
relu à chaque `didChangeMetrics` (`WidgetsBindingObserver`). `MediaQuery.viewInsetsOf`
vaudrait toujours 0 : l'écran est dans le corps du `Scaffold` d'`AppShell`
(`resizeToAvoidBottomInset`), qui retire `viewInsets` du `MediaQuery`. Il est masqué aussi
quand la liste garderait moins de `importBannerMinListHeight` (120 px) à côté de lui.
`_ListWithBanner` reçoit les variantes, de la préférée à la plus petite — grand écran :
complète puis compacte ; téléphone : compacte — et `_FirstThatFits` (rendu à plusieurs
enfants) les mesure toutes à leur hauteur réelle, largeur et taille du texte comprises,
contre la hauteur donnée par le `LayoutBuilder` moins 120 px. Seule la première qui tient
prend place, se peint, reçoit le toucher et la sémantique ; aucune si aucune ne tient. Le
choix est rendu à l'écran après le rendu (`onShown`), et chaque variante non affichée est
sous `ExcludeFocus` : Tab ne s'y arrête pas, Entrée ne la déclenche pas. Il revient quand
la place le permet. Au retour, après le rendu,
`_revealOpenedCard` ramène en vue la carte ouverte (`_openedWebLink`, une `GlobalKey` par
adresse dans `_webCardKeys`) par `Scrollable.ensureVisible` avec
`ScrollPositionAlignmentPolicy.keepVisibleAtEnd` : la liste ne défile que si le bandeau
recouvre le bas de la carte, et juste assez pour l'aligner sur le bas de la liste. Sur
iOS, SFSafariViewController s'ouvre dans l'application, qui ne quitte pas le premier
plan : aucun `onResume` n'arrive. Après une ouverture en `inAppBrowserView` — carte ou
« Voir sur Google » —, `_revealBannerNowOnIos` pose le bandeau tout de suite, sans
annonce, et sa phrase n'est pas annoncée à la fermeture de la page non plus : ni le cycle
de vie ni url_launcher (dont l'appel rend la main au premier chargement de la page) ne
signalent cette fermeture. Sur Android, Custom Tabs met l'activité en pause : `onResume` arrive au retour,
et le bandeau s'annonce. Sans adresse de carte, sur Android
et Windows (`PlatformUtils.isAndroidApp`, `isWindowsApp`), `Clipboard.getData` est lu au
retour : la première adresse http(s) du texte (`firstWebLink`) s'affiche en abrégé
(`shortLinkLabel` : domaine sans `www.`, début du chemin, 27 caractères puis « … ») avec
« Importer ce lien ». Sur le web et iOS, « Coller le lien » lit le presse-papiers à l'appui.
Le bouton ouvre `showUrlImportDialog(context, initialUrl:)` ; quand il est rempli, le champ
n'a pas le focus sur téléphone (`PlatformUtils.isMobile`, ou web sous `wideBreakpoint`), et
l'a au bureau et sur le web en grand écran, où Entrée envoie. Rien ne part avant « Importer ». La boîte rend `true` quand le lien est
parti : le bandeau se retire ; « Annuler » le laisse. Une lecture du presse-papiers en échec
est remontée (`reportUnexpectedError`, `searchScreen.importBanner.clipboard`) et la boîte
s'ouvre vide. Rien n'est enregistré : le bandeau disparaît avec l'écran.

Le poste `web_search_query` (`generateWebSearchQueryFn`, reformulation de la requête Google par
le modèle) est retiré : la callable et son export sont supprimés, le poste quitte
`ROUTABLE_FEATURES` et reste dans `kFeatureCatalog` / `kFeatureProcess` pour les mois déjà
comptabilisés. `getAiRoutingPolicyFn` le retire de la politique enregistrée à l'affichage
(`withoutRetiredFeatures`).

Une réponse du classement arrivée après une nouvelle demande est ignorée
(`AiRankingNotifier`). « Chercher avec l'IA » est inactif pendant un classement en cours et quand
les filtres ne retiennent aucune recette ; `rank` ne relance pas une demande identique déjà en
cours. « Imaginer 3 recettes » est inactif pendant une rédaction, et `imagine` ne relance pas
de second lot. Si le texte, les filtres ou les sources changent après la demande, la section
l'affiche (« Recherche ou filtres modifiés depuis la demande. ») et propose « Relancer ». « Réessayer »
après une erreur relance la même demande. Une recette imaginée n'existe qu'en mémoire ;
« Enregistrer en brouillon » (`AiIdeasNotifier.saveGeneratedRecipe`) la crée en `draft`,
`origin: ai`, dans « Mes créations Kass'Dalle ✨ ». Des idées non enregistrées posent un garde
de sortie (`leaveGuardProvider` et `PopScope`) sur l'Explorer comme sur l'écran d'une idée :
le retour, la barre de navigation et le menu latéral demandent « Quitter sans enregistrer ? ».
L'écran d'une idée rend, en se fermant, le garde de l'Explorer (`LeaveGuardNotifier.restoreIf`) ;
tant qu'il est ouvert, la navigation du shell pose la question de l'Explorer quand elle existe,
un seul dialogue. `markSaved` garde l'identifiant du brouillon : la tuile d'une idée enregistrée
ouvre `/drafts/{id}`. Au retour Android, sans page dessous, l'Explorer appelle
`SystemNavigator.pop()` après « Quitter ».
Les créations du planning (« Générer avec
l'IA » du sélecteur, « Concevoir avec l'IA », source « Conception IA ») passent aussi toutes par
`PlanningRepository.saveAsDraft` : un repas planifié lit un brouillon comme une recette validée
(`getRecipesByIds`), courses comprises.

**Le `reader` ne planifie pas** (v0.23.47) : `suggestMealPlanFn` (`planning`),
`suggestStorageAdviceFn` (`storage_advice`) et `consolidateShoppingListFn` (`shopping_list`,
sans appelant client) exigent `requireEditor`, comme `generateRecipeConceptFn` et
`suggestMealIdeasFn`. Les règles `planned_meals` et `planning_config` exigent `isEditor()` à
l'écriture (§4). Côté client, `canEditProvider` masque « Planifier » sur la fiche recette,
« Nouveau planning », « Préférences du planning », l'export du
planning, « Choisir une recette » d'un jour libre, l'heure et le menu d'un repas (sauf
« Supprimer » et « Ajouter aux courses » sur ses propres repas), et « Préférences du planning » et « Mes garnitures » de
l'écran Préférences ; `canWriteRecipeAdviceProvider` rend faux pour un lecteur, et la fiche lui
montre le conseil de conservation déjà stocké, ou rien. Les courses restent ouvertes au
lecteur — « Ajouter aux courses » sur un repas (le sien, ou celui d'un planning partagé),
« Ajouter la période aux courses », « Mes courses », et la fiche recette — : elles s'écrivent
dans son seul panier (`users/{uid}/shopping/current`, §3.8 quinquies) et n'appellent aucun
modèle.

**Le `reader` ne crée aucune recette** : la règle `recipes` create exige `isEditor()` (§4) ; les
callables qui produisent une recette à enregistrer exigent `requireEditor` —
`generateRecipeFn`, `extractRecipeFromTextFn`, `generateRecipeConceptFn`, `suggestMealIdeasFn` —,
ainsi que `searchRecipesFn` (classement facturé). L'interface masque les points d'entrée
(`canEditProvider`) : copie et « Améliorer avec l'IA » de la fiche, copie d'un brouillon,
« Générer avec l'IA » et « Concevoir avec l'IA » du planning, source « Conception IA » de Nouveau
planning, « Chercher avec l'IA », « Imaginer 3 recettes », « Importer depuis un lien »,
« Importer » des pages « Sur le web », et le bandeau d'import au
retour du navigateur de l'Explorer. Il garde la modification et la suppression de ses recettes existantes, et
« Raffiner le brouillon par IA » sur ses brouillons (`refineRecipeFn`, `requireAuth`).

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
   gardes : `requireEditor(req, "generation_recette")`.
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
| 2 | `import_recette` | `jobDispatcher` → `recipeProcessor` | `transcription_page`, `recipe_translation` pour une recette étrangère, `recipe_tagging`, la normalisation contre les référentiels |
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
| `context` | `string` | les paramètres au moment de l'erreur, en **JSON** (v0.23.48) : chaque valeur passée en texte de 500 caractères au plus, 4 000 caractères en tout, les entrées qui ne tiennent plus comptées sous `_omis`. Les rapports antérieurs portent une carte, que la lecture accepte toujours |

Les longueurs sont bornées par le client (`ErrorReport.toFirestore`) : `feature`,
`error_type` et `job_id` à 200 caractères, `app_version` à 50, `error_message` à 4 000.
Les règles (`isErrorReport`, §4) admettent le double et refusent tout autre champ : un compte
en attente en écrit, et un rapport sans borne servait de stockage libre.

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
| `importRecipeFromUrlFn` | — (aucun appel de modèle) | `url` → 2 048 car., requis, lu par `parseImportUrl` (forme et hôte, §6) ; le texte de la page transmis au modèle est borné à 60 000 car. par `extractMainText` |
| `polishCooklangFn` | `polish_cooklang` | `cooklang` → 100 000 car., requis |
| `polishMarkdownFn` | `polish_markdown` | `markdown` → 100 000 car., requis ; `instruction` → 5 000 car. |
| `refineRecipeFn` | `refine` | `instruction` → 5 000 car., requis ; `currentCooklang` → 100 000 car., requis ; `currentTitre` → 5 000 car. ; `currentIngredients` → 500 éléments de 20 000 car. ; `currentTags` → 100 000 car. JSON ; `currentPortions` → nombre de 0 à 1 000 |
| `generateRecipeFn` | `generate` | `query` → 5 000 car., requis ; `preferenceInsight` → 100 000 car. ; `libraryContext` → 500 éléments de 20 000 car. ; `variantLabel`, `variantInstruction` → 5 000 car. ; `siblingVariantLabels`, `avoidTitles` → 500 éléments de 5 000 car. |
| `searchRecipesFn` | `search` | `query` → 5 000 car., requis ; `recipes`, `ratedRecipes` → 5 000 éléments de 20 000 car. |
| `searchWebRecipesFn` | `web_recipe_search` | `query` → 200 car., requis (`readWebSearchQuery`, caractères de contrôle retirés, espaces resserrées) |
| `extractBookCoverFn` | `book_cover` | `bytesBase64` → 8 Mo décodés, requis ; `mimeType` → 5 000 car., requis |
| `detectAndCropIllustrationsFn` | `detect_illustrations` | `bytesBase64` → 20 Mo décodés, requis ; `mimeType` → 5 000 car., requis |
| `suggestMealPlanFn` | `planning` | `slotDates` → 31 éléments de 5 000 car., requis, chacun commençant par `AAAA-MM-JJ` ; `recipes` → 5 000 éléments de 20 000 car. ; `globalConstraints` → 5 000 car. ; `dailyConstraints` → 100 000 car. JSON ; `slotConstraints`, `alreadyAssigned`, `recentlyServed` → 500 éléments de 20 000 car. ; `slotDismissed` → pas plus d'éléments que `slotDates`, chacun une liste de 30 identifiants de 128 car. au plus (un élément qui n'est pas une liste devient `null`, les identifiants non textuels sont retirés) ; `batchCookingDay` → entier de 1 à 7 ; `mode` → `model` ou `code`, toute autre valeur refusée ; `groupId` → absent, `null`, ou identifiant de document (lettres, chiffres, `_`, `-`, 128 car. au plus), lu hors de l'entrée du modèle |
| `generateRecipeConceptFn` | `planning_concept` | `slotDate` → 5 000 car., requis ; `globalConstraints` → 5 000 car. ; `dayConstraint`, `requestedDish` → 20 000 car. JSON ; `alreadyPlanned` → 500 éléments de 5 000 car. ; `runId` → motif `^pr_[0-9a-f]{32}$`, sinon refusé |
| `suggestMealIdeasFn` | `planning_meal_ideas` | règles propres au poste (voir ci-dessus) ; tailles relevées avant troncature : `prompt`, `previousTitles`, `globalConstraints` |
| `consolidateShoppingListFn` | `shopping_list` | `ingredients` → 500 éléments de 20 000 car., requis et non vide |
| `suggestRecipeTagsFn` | `suggest_tags` | `titre` → 5 000 car., requis ; `cooklang` → 100 000 car. |
| `generateRecipeIllustrationFn` | `generate_recipe_illustration` | `recipeTitle` → 5 000 car., requis ; `recipeContext` → 100 000 car., requis ; `userInstruction`, `style` → 5 000 car. |
| `suggestPlatingFn` | `plating_coach` | `userInstruction` → 5 000 car. |
| `normalizeRecipeReferentialsFn` | `normalisation_referentiels` | `cooklang` → 100 000 car. ; `ingredients` → 500 éléments de 20 000 car. Garde (v0.23.48) : éditeur ou admin, ou lecteur créateur de la recette `recipeId` (`assertCanNormalizeReferentials`, `callable/_recipeAccess.ts`) — la fonction écrit dans le référentiel partagé `nutrition_ingredients` |

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
lecture (`archive_limit_exceeded`, `ZipLimitError`). Un import par lien bloqué par le site, sans
recette, introuvable ou à une adresse refusée (`UrlImportError` non rejouable) y part aussi,
sous `url_page_blocked`, `url_no_recipe`, `url_page_not_found` ou `url_url_refused` ; un délai
dépassé (`url_timeout`) suit la reprise normale. Un livre EPUB ou Word au-delà des bornes
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
| `failure_reason` | `budget_exceeded`, `quota_exceeded`, `book_file_unreadable`, `tagging_truncated`, `foreign_book`, `forbidden_source_path`, `archive_limit_exceeded`, `url_page_blocked`, `url_page_not_found`, `url_no_recipe`, `url_url_refused`, `url_timeout`, `pipeline_error` |
| `last_error` | le message de l'exception |
| `retry_count` | le nombre de tentatives consommées |
| `file_path` | le fichier téléversé, pour pouvoir rejouer ; l'adresse de la page pour un import par lien |
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

Quatre tâches planifiées (Cloud Scheduler), huit reprises manuelles et deux réglages. Aucune
tâche n'est déclenchée par un utilisateur ; toutes journalisent sous leur propre
`correlationId`.

| Fonction | Cadence | Ce qu'elle fait |
|---|---|---|
| `scheduledBackfills` | `0 * * * *` — toutes les heures, heure de Paris | lance les backfills **récurrents** échus (`backfills/schedule.ts`, `dueReason`) : jour et heure de la programmation (`app_config/backfill_schedules`), ou reprise d'un passage programmé resté incomplet. Défaut sans réglage : « Reprendre la nutrition » tous les jours à 5 h — elle remplace `scheduledNutritionCatchUp`, retirée en v0.23.45, avec ses bornes (voir ci-dessous). Détail plus bas, « Backfills ponctuels et récurrents » |
| `scheduledAiBudgetAlert` | `0 7 * * *` — chaque matin à 7 h | compare le cumul du mois au seuil réglé. Se tait dans quatre cas : pas de seuil, pas de taux de change, seuil non franchi, alerte déjà émise |
| `scheduledAiReconciliation` | `0 6 4 * *` — le 4 de chaque mois à 6 h | réconcilie le mois précédent avec la facturation BigQuery |
| `ticketsSyncSchedule` | `every 60 minutes` | renvoie les tickets « Envoi en cours » de moins de dix essais, puis relit sur GitHub les Issues des tickets non finaux (webhook perdu) ; s'arrête au premier jeton refusé (§5, « Tickets ») |

| Reprise manuelle | Réservée à | Ce qu'elle traite |
|---|---|---|
| `backfillNutritionFn` | `admin` | recalcule la nutrition, 40 recettes par appel par défaut, avec un point de reprise dans `app_config` — un backfill qui repart de zéro à chaque appel ne finit jamais. Lève les bornes de patience (vingt heures entre deux tentatives, cinq tentatives par liste d'ingrédients) ; le passage programmé les garde |
| `backfillEnrichReferentialsFn` | `admin` | enrichit les référentiels d'unités et d'ingrédients (backfill récurrent `enrich_referentials`) ; avec `refreshSodium`, la réparation du sel compté deux fois (backfill ponctuel `refresh_sodium`) |
| `backfillShoppingFn` | `admin` | recalcule `shopping_products` sur toutes les recettes, sans appel de modèle, sans réécrire une recette dont le résultat ne change pas. 500 recettes par appel par défaut, point de reprise dans `app_config/shopping_products_backfill_checkpoint` |
| `backfillAllergensFn` | `admin` | deux phases à chaque appel. **Ingrédients** : parcourt `nutrition_ingredients` et soumet au modèle, par lots de quarante (poste `backfill_allergens`, 400 ingrédients par appel par défaut), ceux qui n'ont pas de champ `allergens` ; un ingrédient déjà examiné, par le modèle ou par l'admin, n'est ni redemandé ni refacturé, et l'écriture est conditionnelle (transaction). **Recettes** : seulement quand le référentiel a été parcouru en entier, recalcule `allergens` sur chaque recette sans appel de modèle (500 par appel par défaut), sans réécrire une recette dont le résultat ne change pas. S'arrête après trois lots ou trois recettes en échec de suite. Compte rendu : ingrédients examinés, ignorés, en erreur ; recettes calculées, identiques, encore incomplètes, hors recette, échecs. Points de reprise dans `app_config/allergens_ingredients_backfill_checkpoint` et `app_config/allergens_recipes_backfill_checkpoint`. À lancer après le déploiement, puis après chaque correction d'un ingrédient — Admin › Backfills, « Allergènes des ingrédients et des recettes » |
| `backfillSystemBooksFn` | `admin` | parcourt `users` et crée, pour chaque compte `reader`, `editor` ou `admin` non révoqué, ceux des quatre livres système qui lui manquent, reconnus à leur tag (`missingSystemBooks`) : `__kassdale_ia`, `__libres`, `__secretes` par `books.add` avec les champs de `BookRepository.findOrCreate…Book`, `__web` par `findOrCreateWebBook`. Couverture vide. Comptes en attente ou révoqués sautés. 500 comptes complétés par appel au plus, arrêt sur trois échecs de suite. Sans appel de modèle, sans curseur : réentrant parce qu'un compte complet est sauté |
| `backfillGroupPlanningReachFn` | `admin` | ponctuel `group_planning_reach`. Lit tous les `groups` une fois, et recalcule pour chacun de leurs membres et de leurs invités `group_reach` (`syncReachFor`) et `planning_reach` (`syncPlanningReachFor`, dont `group_ids`, `masked_group_ids` et `masked_invitation_ids`), les fonctions des déclencheurs ; un document déjà juste n'est pas réécrit. Puis, si la première phase n'a pas été arrêtée, parcourt `planned_meals` par identifiant depuis le point de reprise `app_config/group_planning_reach_backfill_checkpoint` (pages de 400, projection `group_id`) et pose `group_id: null` sur chaque repas qui n'a pas le champ, par lots ; un lot en échec est repris repas par repas. À lancer une fois après le déploiement du planning de groupe : sans lui, un membre d'un groupe que personne n'a touché depuis ne lit pas le planning du groupe, un groupe dont le propriétaire est déjà lecteur reste ouvert, et un planning personnel partagé ne montre aucun repas antérieur. 500 comptes réécrits et 4 000 repas marqués par appel au plus, arrêt sur trois échecs de suite dans chaque phase. Sans appel de modèle. Réentrant : un compte à jour est sauté, un repas qui porte le champ n'est pas réécrit |
| `backfillMoveMealsToGroupFn` | `admin` | ponctuel paramétré `move_meals_to_group`, « Déplacer mes repas vers un groupe ». Entrée `{ groupId, fromDay, toDay, startAt, endAt, appVersion? }` : identifiant de groupe au format sûr (`[A-Za-z0-9_-]{1,128}`), jours `AAAA-MM-JJ` inclusifs, `fromDay <= toDay`, 62 jours au plus ; `startAt` et `endAt` sont les instants (ms) du minuit local du premier jour et du lendemain du dernier, calculés par l'appareil (`MoveMealsRequest`), et doivent tomber à moins de quatorze heures des jours annoncés. Le fuseau de l'appareil fait foi : le serveur ne le devine pas. Entrée invalide : `invalid-argument`, avant le verrou. Le passage lit `groups/{groupId}` : absent, `not-found` ; `owner_id` différent de l'appelant, `permission-denied`. L'appelant est administrateur non révoqué (`requireAdmin`), donc planificateur, et ses groupes sont actifs. Sélection : `uid == appelant` et `startAt <= planned_at < endAt` (index `uid` + `planned_at`, 2 000 repas lus au plus), puis les repas dont `group_id` est nul ou absent ; un repas déjà dans un groupe est compté « ignoré ». Chaque repas s'écrit dans une **transaction** qui relit `groups/{groupId}` (présent, `owner_id` = appelant) et le repas (présent, `uid` = appelant, `group_id` nul ou absent), puis pose `group_id: groupId`. Un groupe supprimé ou cédé pendant le passage l'arrête (`groupeIndisponible: true`) : aucun repas n'est rattaché à un groupe que `deleteGroupMeals` a déjà vidé. Un repas qui a changé entre la lecture et la transaction est compté « ignoré ». Rien d'autre n'est écrit : ni `uid`, ni `base_portions`, ni `target_portions`, ni la recette. 500 repas déplacés par passage, arrêt sur trois échecs de suite. Compte rendu : `groupId`, période (`du`, `au`), examinés, déplacés, ignorés, en erreur, restants, `lectureTronquee`, `groupeIndisponible` — **ni nom de groupe ni titre de recette** : il est recopié dans `app_config/backfill_run_move_meals_to_group`, que tout administrateur lit. Réentrant sans curseur : un repas déplacé n'est plus sélectionné. Jamais marqué terminé tout seul (`summarizeMoveMealsToGroup`, `remaining: null`), et le menu ⋮ de sa tuile ne propose pas de le marquer (`reusable` au registre client, `backfillOffersDoneMenu`). Verrou commun avec `group_planning_reach`. Sans appel de modèle |
| `backfillRecipeRolesFn` | `admin` | pose `tags.meal_role`, `contains`, `suggested_sides` et `roles_tagged_at` — plus `main_protein` et `main_starch` s'ils sont absents (`mainIngredientsPatch`), et `main_ingredients_checked_at` quand le modèle a répondu — sur les recettes antérieures à leur ajout. Un appel de modèle par recette (poste `backfill_recipe_roles`), 40 recettes par appel par défaut ; une recette déjà classée est sautée, sauf `force`. S'arrête après trois échecs de suite. Point de reprise dans `app_config/recipe_roles_backfill_checkpoint` |

Trois reprises ponctuelles, menées au bout en production, sont retirées en v0.23.52 avec leur
callable : `backfillRecipeProteinFn` (« Protéine et féculent des plats »),
`backfillEstimatedTimesFn` (« Durées estimées ») et `backfillPlanningDefaultsFn` (« Contraintes
de variété par défaut »). Leurs postes de coût `backfill_recipe_protein` et
`backfill_time_estimate_batch` quittent `ROUTABLE_FEATURES` et restent au catalogue comptable.
`onRecipeWritten` estime les durées et classe les recettes neuves ; un compte sans
`global_constraints` enregistrées lit les règles de variété par défaut
(`kDefaultGlobalConstraints`, §3).

Le point de reprise est la seule chose qui distingue un backfill d'une boucle : chacun écrit
où il s'est arrêté, et l'appel suivant repart de là.

| Réglage | Réservé à | Ce qu'il écrit |
|---|---|---|
| `setBackfillScheduleFn` | `admin` | `{ key, enabled, days, hour }` → l'entrée `key` de `app_config/backfill_schedules`, avec `timezone` et `programme_par_uid` (l'appelant). Refuse un ponctuel (`failed-precondition`), une clé inconnue, une heure ou un jour qui n'est pas un entier dans sa plage (chaîne, booléen, `null`, décimal compris), aucun jour quand `enabled` (`invalid-argument`) |
| `setBackfillDoneFn` | `admin` | `{ key, done, appVersion }` → pose (`termine_par: "manuel"`) ou retire `termine_*` sur `app_config/backfill_run_<clé>`. Ponctuels seulement |

**Backfills ponctuels et récurrents** (v0.23.45). Chaque backfill est classé dans
`backfills/registry.ts` (§3.13). Toutes les reprises ci-dessus passent par
`runBackfillPass` (`backfills/runner.ts`), qui :

- pose un **verrou** par backfill, en transaction, sur `app_config/backfill_run_<clé>` : un
  second passage du même backfill — un double clic, un autre appareil, la tâche horaire — est
  refusé, `failed-precondition`, et l'écran affiche le message du serveur. Deux backfills
  différents tournent ensemble, sauf ceux d'un même `LOCK_GROUPS` (`backfills/registry.ts`) :
  `enrich_referentials` et `refresh_sodium` réécrivent tous deux `per100g` des ingrédients, et
  l'un refuse de partir pendant que l'autre tient son verrou (même transaction, qui lit l'état
  des deux) ; de même `group_planning_reach` et `move_meals_to_group`, qui écrivent tous deux
  `planned_meals.group_id`. Un verrou dont l'échéance est passée est repris ;
- enregistre l'issue : statut, origine, date, compte rendu complet (`last_report`), ou le
  message de l'erreur, puis relève l'erreur ;
- pour un **ponctuel**, pose `termine_*` (`termine_par: "auto"`) quand le passage finit sans
  aucun reste : collection parcourue, 0 restant, 0 élément à revoir (`shouldAutoMarkDone`). Un
  reste inconnu (décompte impossible) n'est pas un reste nul. La réponse du callable porte alors
  `termineAuto: true`.

Les callables gardent leur nom et leur contrat ; la réponse gagne `termineAuto`, la requête
accepte `appVersion`. La passe de chaque récurrent est sortie du callable dans une fonction
appelable sans requête (`runNutritionBackfillPass`, `runEnrichReferentialsPass`,
`runAllergensPass`, `runRecipeRolesPass`, `runShoppingPass`) : le callable et
`scheduledBackfills` appellent la même.

**Passage programmé.** À chaque tick, `scheduledBackfills` lit les programmations et les
états, écrit le défaut de la nutrition s'il manque, puis lance en séquence les récurrents échus, chacun borné par ce qui reste des 540 s de
la fonction (huit minutes et demie au plus, trois minutes au moins). Ce qui ne tient pas est
marqué `reprise_due` et part au tick suivant. Un passage incomplet reprend l'heure suivante,
depuis son point de reprise, jusqu'à la fin. Un créneau tombé pendant un passage manuel est
reporté d'une heure. Bornes par passage : nutrition 20 recettes, bornes de patience **actives**,
sans point de reprise (le comportement de l'ancienne tâche de 5 h) ; rôle des recettes 40
recettes ; allergènes 400 ingrédients et 500 recettes ; produits d'achat 500 recettes ;
enrichissement des référentiels, le délai seul — et en reprise à l'heure suivante, sans la
phase 1 (poids des unités, sans curseur, que l'heure précédente vient de parcourir).

**Auteur de la programmation.** Avant chaque passage programmé, le rôle de
`programme_par_uid` est relu sur son document (`isAdminAccount`) : un compte qui n'est plus
administrateur — rétrogradé ou révoqué — n'a plus de passage imputé en son nom. Le passage ne
part pas, l'état passe en `erreur` avec « L'auteur de la programmation n'est plus
administrateur. », `reprise_due` à faux, et un `logWarn` le trace. Un administrateur
reprogramme le backfill pour le relancer. Sans auteur (défaut de la nutrition), rien à
vérifier.

**Plafond de dépense.** Un passage programmé qui appelle un modèle est imputé à
l'administrateur qui a enregistré la programmation (`programme_par_uid`) : ses appels passent par
`callModel` sous cet uid, et `assertWithinDailyBudget` est consulté avant le passage, puis relu
s'il s'arrête avant la fin (un `logWarn` trace un plafond atteint en cours de passage). C'est le
plafond de **base** : le passage tourne dans `runWithBaseBudgetCap` (`ai/callOrigin.ts`), et
`effectiveBudgetMultiplier` (`ai/budget.ts`) y rend 1 au lieu du multiplicateur du compte —
un passage que personne ne surveille ne profite pas de la marge du fondateur (×100). Plafond atteint : statut « incomplet », `arret_plafond: true`, et la
reprise attend le **prochain créneau**, pas l'heure suivante. **Exception assumée : la
nutrition** impute chaque recette à son propriétaire (`recipeBudgetUserId`), comme l'ancienne
tâche — le calcul sert la recette de quelqu'un, et c'est le compte que `syncRecipeNutrition`
débite ; elle garde aussi les multiplicateurs de ces comptes. Aucun poste de coût nouveau : les passages programmés s'imputent aux postes de leurs
backfills (`backfill_recipe_roles`, `backfill_allergens`,
`backfill_enrich_referentials_per100g`, et ceux de la chaîne nutrition).

Cloud Tasks n'est pas utilisé : chaque backfill a déjà son point de reprise et son verrou, et
une tâche horaire qui reprend où le passage s'est arrêté suffit, sans file à créer ni à
surveiller.

Journaux : la tâche écrit sous `backfill_programme`, chaque passage programmé sous
`backfill_programme:<clé>` (la nutrition garde `rattrapage_nutrition`).

**Liste « à revoir ».** Chaque reprise manuelle renvoie, en plus de ses compteurs, le champ
`aRevoir: { items, total }` : les éléments que le passage n'a pas pu traiter, nommés. Une
entrée vaut `{ kind, id, label, reason }` : `kind` est `ingredient`, `unit`, `recipe`,
`account` ou `meal` ; `label` le nom canonique, le titre de la recette (`titre`) ou le nom du compte ;
`reason` la raison en français simple. Le collecteur commun, `callable/_backfillReview.ts`
(`BackfillReview`), garde les cent premières entrées dans l'ordre de traitement ; `total`
compte au-delà. La liste vit dans la réponse du passage, et n'est recopiée que dans le
`last_report` de l'état du backfill, `app_config/backfill_run_<clé>` (§3.13).

| Reprise | Ce que la liste nomme |
|---|---|
| `backfillEnrichReferentialsFn` (et « Reprendre le sel ») | unités dont le poids n'a pas été estimé ou d'un lot en échec ; ingrédients sans valeurs nutritionnelles estimées (« Valeurs nutritionnelles introuvables ») ou d'un lot en échec |
| `backfillNutritionFn` | recettes reprises encore incomplètes : erreur de la reprise, calcul en échec, ou ingrédients sans valeurs (`missing_ingredients`, cinq noms au plus) |
| `backfillRecipeRolesFn` | recettes que le modèle n'a pas su classer, recettes en échec |
| `backfillShoppingFn` | recettes sans ingrédient (liste de courses vide), recettes en échec d'écriture |
| `backfillAllergensFn` | ingrédients sans réponse du modèle (« Pas de réponse de l'IA ») ou d'un lot en échec (« Lot en échec : <message> ») ; recettes incomplètes avec les ingrédients non examinés (« Recette incomplète : beurre, farine non examinés »), recettes en échec. Les ingrédients sans réponse sont aussi journalisés, avec leurs noms (`logWarn`, `allergenExamination.ts`) |
| `backfillSystemBooksFn` | comptes en échec de création (« Échec de création : <message> »), nommés par `display_name`, à défaut l'uid |
| `backfillGroupPlanningReachFn` | comptes dont une portée n'a pas pu être recalculée (« Portée non recalculée : <message> »), nommés par leur uid ; repas planifiés restés sans `group_id` (« group_id non posé : <message> », nature `meal`, « Repas <id> ») |
| `backfillMoveMealsToGroupFn` | repas dont l'écriture a échoué (« Repas non déplacé : <message> », nature `meal`), nommés par leur identifiant et leur jour (« Repas <id> — AAAA-MM-JJ »), sans titre de recette |

Côté client, `BackfillFailures` (`features/admin/domain/backfill_failures.dart`) lit le champ ;
absent, il vaut `null` et l'écran n'affiche que les compteurs. La tuile relit la liste du
dernier passage dans `last_report` (lien « Voir les N à revoir »). Un backfill ajouté à Admin ›
Backfills renvoie `aRevoir` par ce collecteur, s'inscrit aux deux registres et se branche dans
`_runPass` de l'écran.

La liste ne part jamais dans les journaux : elle porte des noms de comptes et des titres de
recettes privées. Le `logInfo` de fin de passage reçoit le compte rendu par
`withoutReviewList`, qui remplace la liste par son total (`aRevoirTotal`).

### 7.11 Les échecs qui ne se rejouent pas

Tous les échecs ne méritent pas une seconde tentative. La distinction est explicite dans le
code, et une réimplémentation doit la reproduire :

| Cas | Comportement |
|---|---|
| JSON malformé rendu par un modèle | `JsonAnswerError`, réponse brute journalisée, **pas de retry** — le modèle rendra la même chose |
| Aucune recette sur la page | Aucun brouillon créé ; le job se termine proprement plutôt que d'écrire une recette vide |
| Timeout / erreur réseau | Retry Cloud Tasks, backoff 10 s → 300 s, trois tentatives, puis dead letter |
| Plafond de dépense atteint | Refus **avant** l'appel, dead letter immédiate |
| Page web bloquée (401, 402, 403, 429, 451), introuvable, sans recette, ou adresse refusée (import par lien) | `UrlImportError` non rejouable : dead letter dès la première tentative, `error_code` lisible sur le job |
| Recette JSON-LD au-delà des bornes (60 000 car., 200 ingrédients, 150 étapes, 2 000 car. par ligne) | `no_recipe`, aucun appel de modèle |
| Adresse d'import non publique, à la callable ou à la connexion | `parseImportUrl` / `assertPublicHost` refusent avant la requête ; `guardedLookup` refuse au moment de la connexion. Aucun octet n'est envoyé |
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
- Sur un brouillon traduit, la mention « Traduit de l'… » (`TranslatedFromLabel`) sous le titre.
  Sur grand écran, une icône `translate` (« Afficher / Masquer le texte d'origine ») ouvre un
  panneau `OriginalTextView` de 360 px à droite du corps, séparé par un `VerticalDivider` ; la
  mention l'ouvre aussi. Le panneau exige une fenêtre d'au moins 1 150 px
  (`_originalPanelMinWindowWidth`) ; en dessous, `OriginalTextButton` ouvre la feuille ou la
  fenêtre de la fiche.
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

`font-src` et `connect-src` admettent `https://fonts.gstatic.com` (v0.23.16) : CanvasKit y
télécharge les polices de secours des écritures que ses polices embarquées ne couvrent pas
(japonais, arabe…). Le texte d'origine d'une recette traduite en a besoin.

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
précédente (`cancel-in-progress`). Le workflow n'a que le droit `contents: read` ; le seul
job « Déjà testé en PR » reçoit en plus `pull-requests: read` et `actions: read`. Ses actions sont épinglées par SHA de commit, la version en commentaire (v0.23.12), comme
celles de `deploy.yml`. Cinq jobs, sur `ubuntu-latest` :

| Job | Étapes, dans l'ordre |
|---|---|
| Version — numéro libre (racine, historique complet) | `.github/scripts/check-version.sh <base> <tête>` : sur une PR, la base est la `master` du moment (`git fetch origin master`) et la tête le dernier commit de la PR ; sur un push, la base est le commit d'avant le push. Sauté sur un lancement manuel |
| Déjà testé en PR (push seulement, API GitHub) | Sur un push, sort `skip=true` quand le commit poussé a le même arbre que la tête d'une PR associée qui vise `master`, que cette tête contient la `master` d'avant le push (`compare` : `ahead` ou `identical`) et que toutes les exécutions de `ci.yml` sur cette tête, en `pull_request`, ont réussi (au moins une, aucune en cours ni en échec). La CI de la PR a alors testé ce même arbre. Une réponse d'API manquante laisse `skip=false` |
| Flutter (`kass_dalle/`, Flutter 3.44.6 stable) | `flutter pub get` · `flutter analyze` (erreurs, warnings et infos bloquants) · `dart format --output=none --set-exit-if-changed lib test` · `git diff --exit-code pubspec.lock` · `flutter test` · `flutter build web --release` |
| Functions (`kass_dalle/functions/`, Node 22) | `npm ci` · `npm run lint` (ESLint) · `npm run format:check` (Prettier) · `npm run build` (tsc) · `npm test` |
| Règles — émulateur (`kass_dalle/rules-tests/`, Node 22, Java 21 Temurin) | `npm ci` · `npm test` : émulateurs Firestore et Storage sur le projet fictif `demo-kassdalle`, tests des règles (voir §4, « Tests des règles ») |

Les jobs Flutter, Functions et Règles dépendent de « Déjà testé en PR » et sont sautés quand
il sort `skip=true` (v0.23.44). La fusion d'une PR à jour de `master` ne relance donc que le
job Version, au lieu des douze minutes facturées de la CI entière. Un workflow dont des jobs
sont sautés conclut `success` : `deploy.yml` part comme avant. Sur une PR et un lancement
manuel, « Déjà testé en PR » est sauté et les trois jobs tournent (`!cancelled()`).

#### Le contrôle de version

Le PC pousse directement sur `master` pendant que des PR attendent leur fusion. Deux livraisons
qui passent toutes deux de 0.23.14 à 0.23.15 écrivent la même ligne `version:` : Git les
fusionne sans conflit, et le second déploiement conserve l'APK en ligne, dont la version n'est
pas plus ancienne. `check-version.sh` détecte ce cas.

Deux contrôles. Le premier porte sur tout l'historique de la tête : son nom de version (avant
le `+`) ne doit avoir été introduit que par un seul commit ordinaire (`git log --full-history
--no-merges -G'^version:'`). Il ne dépend pas de la plage poussée : après un push refusé pour
doublon, un push suivant qui ne touche pas la version échoue encore, et une CI annulée par
`cancel-in-progress` ne laisse pas passer son doublon. Un job rouge sur `master` se corrige
par un commit qui passe à la version suivante.

Le second compare la tête à la base, quand le changement touche la version : l'un de ses
commits ordinaires modifie la ligne `version:` de `kass_dalle/pubspec.yaml` par rapport à son
parent, ou la tête descend de la base sans en avoir la version (hausse faite dans un commit de
fusion). Les commits de fusion ne comptent pas comme hausse : fusionner `master` dans une
branche y apporte la version de `master` sans que la branche l'ait choisie. Le script échoue
alors quand le nom de version n'est pas strictement supérieur à celui de la base. Dans tous
les cas, `documentation/CHANGELOG.md` doit avoir au moins un titre `### v<nom> — fonctionnel`
ou `### v<nom> — technique` pour la version de la tête, au plus un de chaque type, et aucun
autre titre `### v<nom>`. Deux titres doivent avoir été ajoutés par un seul commit ordinaire.
Un rebase sur une hausse identique vide le changement de `pubspec.yaml`, et seul le
`CHANGELOG.md` garde alors la trace des deux livraisons : deux titres du même type, ou deux
titres ajoutés chacun par son commit. Une livraison qui ajoute son second titre dans un
commit à part échoue aussi ; elle regroupe les deux titres dans un commit. `CLAUDE.md` demande d'intégrer
`origin/master` par une fusion, jamais par un rebase. Une base
introuvable (premier push, historique réécrit) saute ce second contrôle ; une tête
introuvable fait échouer le script.

Un script modifié par une PR s'exécute dans sa version modifiée, sur la PR puis sur le push de
fusion : seule la relecture empêche d'affaiblir le contrôle. `relecteur-regles` signale tout
diff qui touche `check-version.sh`, `ci.yml` ou `deploy.yml` (contrôle 14), et l'utilisateur
décide avant la fusion. Un `CODEOWNERS` avec protection de branche a été écarté : il
bloquerait les pushes directs du PC sur `master`, et les PR ouvertes sous le compte de
l'utilisateur ne peuvent pas recevoir son approbation. `.gitattributes` force les fins
de ligne LF sur les `*.sh`, pour que le `bash` de Git for Windows les lise sur le PC.

Le même script se lance à la main avant un push depuis le PC ou avant la fusion d'une PR :
`bash .github/scripts/check-version.sh origin/master HEAD` (voir `CLAUDE.md`, « Un numéro de
version par livraison »). La CI d'une PR ne se rejoue pas quand `master` avance : ce lancement
manuel couvre l'intervalle, et le job du push sur `master` arrête le déploiement si un doublon
passe quand même. `deploy.ps1` n'appelle pas le script : le lancer avant lui.

Le déploiement automatique ne part qu'après une CI verte sur un push sur `master` : `deploy.yml`
exige la conclusion `success` du workflow entier, donc un seul job en échec, celui des règles
compris, bloque la mise en production.

#### Les fixtures partagées

`kass_dalle/test-fixtures/*.json` sont rejouées par `flutter test` (`test/*_test.dart`) et par
`npm test` (`functions/src/tests/`). Une logique « serveur seul » n'est rejouée que côté
Functions.

| Fixture | Logique | Dart | TypeScript |
|---|---|---|---|
| `cooklang_parsing.json` | parseur CookLang, index, type de page, durées, durées lues d'une recette (`readDurations` : `tags` puis métadonnées du brouillon et du texte validé) | `core/services/cooklang_parser.dart` | `cooklang/parser.ts` |
| `quantity_parsing.json` | parsing d'une quantité | `core/utils/nutrition_quantity_converter.dart` | `nutrition/quantityConversion.ts` |
| `unit_to_grams.json` | conversion en grammes, quantité absente | idem | idem |
| `ingredient_names.json` | identité d'un ingrédient | `core/utils/ingredient_name.dart` | `nutrition/ingredientName.ts` |
| `ai_pricing.json` | résolution d'un modèle, coût d'un appel | `features/admin/data/ai_pricing.dart` | `ai/pricing.ts` |
| `planning_slot_rules.json` | règles de créneau et présélection du planning, dont la pénalité de refus — serveur ; le client rejoue les constantes de la mémoire des refus (21 jours, 300 entrées, un jour de tolérance dans le futur) et le prédicat d'activité d'un refus, pour élaguer le document qu'il écrit et compter les refus actifs | `features/planning/domain/planning_refusals.dart` (constantes et prédicat d'activité) | `gemini/planning.ts` |
| `meal_storage_rules.json` | seuils d'hygiène (constantes) | `features/planning/domain/meal_storage_rules.dart` | `gemini/storageAdvice.ts` |
| `image_moderation_rules.json` | verdict d'une image, paliers Vision — serveur seul | — | `moderation/decision.ts`, `moderation/vision.ts` |
| `page_homography.json` | redressement d'une page : taille de sortie, homographie | `core/presentation/image_enhancer_processing.dart` | `gemini/perspective.ts` |
| `meal_roles.json` | vocabulaire des rôles dans un repas, des protéines et des féculents principaux, et des rôles qui portent ces deux derniers ; la section `unsafe_keys` (clés héritées du prototype) est serveur seul | `features/recipes/domain/meal_role.dart` | `gemini/mealRole.ts` |
| `shopping_products.json` | regroupement des lignes de courses | `core/utils/shopping_products.dart` | `nutrition/shoppingDerivation.ts` |
| `allergens.json` | les quatorze allergènes majeurs (annexe II INCO) : clés dans l'ordre du règlement et libellés — valeurs seules ; le calcul du champ `allergens` d'une recette est serveur seul | `features/recipes/domain/allergens.dart` | `nutrition/allergens.ts` |

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
- `Secret Manager Admin` : les fonctions référencent `GEMINI_API_KEY`, `ANTHROPIC_API_KEY`,
  `GMAIL_SENDER`, `GMAIL_APP_PASSWORD`, `GITHUB_TICKETS_TOKEN` et `GITHUB_WEBHOOK_SECRET`, et la CLI accorde au compte d'exécution l'accès à ces
  secrets. Le workflow ne transporte aucune valeur de secret : il n'a rien à connaître de plus
  pour un secret ajouté, mais le secret doit exister dans Secret Manager avant le déploiement
  qui le déclare (§5, « Invitations par e-mail ») ;
- `Cloud Scheduler Admin` (fonctions planifiées) ;
- `Cloud Tasks Admin` : `recipeProcessor` est une fonction de file Cloud Tasks, et la CLI lit et
  met à jour sa file (`cloudtasks.queues.get`, `cloudtasks.queues.update`).

Le projet doit aussi avoir l'API `cloudbilling.googleapis.com` activée : la CLI la vérifie avant
de déployer les Functions, et le compte de service n'a pas le droit d'activer une API. Activée
le 8 octobre 2026.

Un déploiement dit s'il manque un rôle : le message d'erreur de la CLI nomme la permission
refusée, et le workflow le reprend dans ses avertissements.

### Sauvegardes de Firestore

Firestore ne garde aucune copie sans réglage : une suppression ou un backfill qui écrit une
mauvaise valeur ne se défait pas. La base `(default)` de `kassdale-6d948` reçoit donc deux
sauvegardes planifiées, gérées par Google Cloud, hors du code et hors du déploiement :

| Planification | Rétention | Ce qu'elle couvre |
|---|---|---|
| quotidienne | 7 jours | une erreur vue dans la semaine |
| hebdomadaire, le dimanche | 14 semaines (le maximum) | une erreur vue tard |

**État.** Les deux planifications sont actives depuis le 11 octobre 2026. La première
sauvegarde quotidienne date du 12 octobre 2026 (`READY`). Les sauvegardes sont rangées dans la
région `eur3`, celle de la base.

Une base n'accepte qu'une planification quotidienne et une hebdomadaire. Chaque sauvegarde
est une copie complète de la base. Elle est facturée au Go stocké ; une restauration est
facturée au Go restauré. Les fichiers de Storage (photos, scans) ne sont pas couverts : voir
« Versions des fichiers de Storage » ci-dessous.

Les planifications se créent une fois, depuis le PC, avec un compte qui a le rôle
`roles/datastore.owner` (le propriétaire du projet l'a). Ni le workflow ni `deploy.ps1` ne
les touchent :

```powershell
gcloud firestore backups schedules create --project=kassdale-6d948 --database="(default)" --recurrence=daily --retention=7d
gcloud firestore backups schedules create --project=kassdale-6d948 --database="(default)" --recurrence=weekly --day-of-week=SUN --retention=14w
gcloud firestore backups schedules list --project=kassdale-6d948 --database="(default)"
```

La première sauvegarde apparaît dans les 24 heures :
`gcloud firestore backups list --project=kassdale-6d948`.

**Restaurer.** Une sauvegarde ne se restaure jamais par-dessus `(default)` : elle crée une
**nouvelle base**, que l'application ne lit pas. On y vérifie les données, puis on reporte
ce qu'il faut dans `(default)`.

1. Choisir la sauvegarde (`gcloud firestore backups list --project=kassdale-6d948`) et noter son nom complet
   `projects/kassdale-6d948/locations/eur3/backups/<id>`.
2. La restaurer dans une base neuve :
   `gcloud firestore databases restore --project=kassdale-6d948 --source-backup=<nom complet> --destination-database=restore-AAAAMMJJ`.
   Le temps de restauration dépend du volume, de quelques minutes à une heure.
3. Lire la base restaurée dans la console Firebase (sélecteur de base) et vérifier les
   documents attendus.
4. Reporter dans `(default)` :
   - **quelques documents** : les recopier depuis la console ;
   - **des collections entières** : exporter la base restaurée vers un bucket
     (`gcloud firestore export gs://<bucket>/restore-AAAAMMJJ --project=kassdale-6d948 --database=restore-AAAAMMJJ --collection-ids=<ids>`),
     puis importer dans `(default)` (`gcloud firestore import gs://<bucket>/restore-AAAAMMJJ --project=kassdale-6d948 --database="(default)"`).
     L'import **écrase** les documents de même identifiant et **ne supprime pas** ceux
     créés depuis : ce n'est pas un retour en arrière complet.
5. Supprimer la base restaurée une fois le travail fini
   (`gcloud firestore databases delete --project=kassdale-6d948 --database=restore-AAAAMMJJ`) : elle est facturée
   tant qu'elle existe.

Rien de cela ne s'écrit depuis une session cloud : la restauration est une opération
d'exploitation, lancée à la main depuis le PC.

### Versions des fichiers de Storage

Les sauvegardes de Firestore ne couvrent pas les fichiers : photos de recettes, scans,
couvertures, fichiers importés. Le bucket `gs://kassdale-6d948.firebasestorage.app` garde donc
les **versions** de ses objets : un fichier remplacé ou supprimé reste récupérable **30 jours**.
Réglage actif depuis le 12 octobre 2026 (`versioning_enabled: true`, règle `Delete` à 30 jours).
Au-delà, une règle de cycle de vie supprime l'ancienne version. Les anciennes versions sont
facturées au Go comme les fichiers en ligne, pendant ces 30 jours.

Le réglage se fait une fois, depuis le PC, avec le compte propriétaire du projet :

```powershell
gcloud storage buckets update gs://kassdale-6d948.firebasestorage.app --versioning
Set-Content -Path "$env:TEMP\lifecycle.json" -Value '{"rule":[{"action":{"type":"Delete"},"condition":{"isLive":false,"daysSinceNoncurrentTime":30}}]}'
gcloud storage buckets update gs://kassdale-6d948.firebasestorage.app --lifecycle-file="$env:TEMP\lifecycle.json"
gcloud storage buckets describe gs://kassdale-6d948.firebasestorage.app --format="yaml(versioning_enabled,lifecycle_config)"
```

La dernière commande doit afficher `versioning_enabled: true` et la règle `Delete` sur
`daysSinceNoncurrentTime: 30`.

**Récupérer un fichier.** Lister ses versions, puis recopier celle qu'on veut à sa place :

```powershell
gcloud storage ls -a gs://kassdale-6d948.firebasestorage.app/<chemin>
gcloud storage cp gs://kassdale-6d948.firebasestorage.app/<chemin>#<generation> gs://kassdale-6d948.firebasestorage.app/<chemin>
```

`<generation>` est le nombre qui suit `#` dans la liste. La copie reprend les métadonnées de la
version, dont le jeton de téléchargement Firebase : l'URL enregistrée dans Firestore pointe de
nouveau sur le fichier. À vérifier en ouvrant l'image dans l'application après la copie.

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
| Partage entrant | Filtre d'intention `ACTION_SEND` `text/plain` sur `MainActivity`, `launchMode="singleTop"`, canal `dev.kassbi.kass_dalle/share` — voir « Partager vers Kass'Dalle » ci-dessous |
| Caméra | `<uses-feature android:name="android.hardware.camera.any" android:required="false" />` — l'absence de caméra n'empêche pas l'installation |
| Configuration Firebase | `android/app/google-services.json`, présent |
| Signature | `android/key.properties` et `signingConfigs.release` |
| Empreintes | SHA-1 et SHA-256 enregistrées dans la console Firebase |
| Attestation | Play Integrity |
| Icône | Adaptative — `mipmap-anydpi-v26/ic_launcher.xml`, fond `#6B7B3A` dans `values/colors.xml`, couches `drawable-*dpi/ic_launcher_foreground.png` |
| Distribution | `app-release.apk` servi par le même déploiement Firebase Hosting, avec un `Content-Disposition: attachment` |
| Mise à jour | L'application se met à jour elle-même — voir ci-dessous |

#### Partager vers Kass'Dalle

Depuis le navigateur ou une autre application, le menu de partage d'Android propose
Kass'Dalle pour un texte. Le filtre d'intention `ACTION_SEND` / `text/plain` de
`MainActivity` le déclare ; ni image ni fichier ne sont déclarés.

Aucun paquet tiers ne reçoit le partage. `MainActivity` (Kotlin) lit l'intention
`ACTION_SEND` de type `text/plain` dans `onCreate` et dans `onNewIntent` : `EXTRA_TEXT`, à
défaut `EXTRA_SUBJECT`, chaîne vide si aucun des deux n'est lisible. Le texte est gardé en
attente et exposé par le `MethodChannel` `dev.kassbi.kass_dalle/share` :

| Méthode | Sens | Effet |
|---|---|---|
| `getInitialSharedText` | Dart → natif | rend le partage en attente (ou `null`) et l'efface |
| `onSharedText` | natif → Dart | pousse un partage reçu par `onNewIntent` ; le texte reste en attente tant que Dart n'a pas répondu, et `getInitialSharedText` le rend sinon |

`onCreate` ignore l'intention d'une activité restaurée (`savedInstanceState` non nul) ou
rouverte depuis les applications récentes (`FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`) : le
système y redonne l'intention d'origine, déjà traitée.

`launchMode` reste `singleTop`. Un partage depuis une autre application crée une instance
dans la tâche de l'expéditeur : `onCreate` lit le partage, et « Retour » ramène au
navigateur. Quand Kass'Dalle est déjà au premier plan, le partage arrive par `onNewIntent`.
`singleTask` fermerait à chaque partage les activités ouvertes par-dessus l'application
(sélecteur d'images, connexion Google).

Côté Dart, `ShareIntentSource` (`features/recipes/data/share_intent_source.dart`) écoute ce
canal sur Android seulement (`PlatformUtils.isAndroidApp`) ; iOS, web et Windows ne reçoivent
pas de partage, et le canal n'y est pas interrogé. Sur Android, toute erreur du canal —
`MissingPluginException` comprise, qui signale un code natif absent ou renommé — est
remontée par `reportUnexpectedError` sous `shareIntent.receive`. Le code natif n'ajoute
aucune dépendance Gradle et suit la configuration de l'application (compileSdk de Flutter,
AGP 8.11.1, Java 17).

`pendingSharedTextProvider` (`recipe_providers.dart`) écoute la source dès le démarrage
(`KassDalleApp`) et garde le dernier texte non traité. `SharedLinkImportHost`, posé dans
`AppShell`, ne le prend (`take`) qu'une fois `appUserProvider` chargé avec un compte : tant
que le compte se lit, ou que personne n'est connecté, le texte reste en attente. Il écoute
`pendingSharedTextProvider` et `appUserProvider`, et traite le partage dès que les deux sont
prêts. Le rôle se lit sur le compte chargé (`AppUser.canEdit`) ; `canEditProvider` vaut
`false` pendant le chargement et refusait l'import à un éditeur. `resolveSharedText`
(`url_import.dart`) décide :

| Cas | Effet |
|---|---|
| `editor` ou `admin`, une adresse http(s) dans le texte (`firstWebLink`) | `showUrlImportDialog(initialUrl:)` par-dessus l'écran courant |
| `reader` | `ImportReservedDialog` : « Import réservé aux éditeurs » |
| aucune adresse web | `showErrorSnackBar` « Ce partage ne contient pas d'adresse web. » |

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
    ├── recipes/                   # Scan, révision, détail, liste, nutrition, courses (+ services/)
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
├── books/         # import d'un livre entier : ouverture, découpage en tranches, estimation ; livres système d'un compte (`ensureSystemBooksFor`)
├── callable/      # entrées HTTPS callable + gardes (_auth.ts)
├── cooklang/      # parseur, jumeau TypeScript du parseur Dart
├── gemini/        # client Gemini, transcription, balisage, fidélité, prompts par poste
├── illustrations/ # extraction en six étapes, écriture, journal de coût
├── invitations/   # invitations par e-mail : règles pures (clé d'adresse, statut, e-mail), envoi SMTP
├── moderation/    # décision pure, moteur Cloud Vision, promotion
├── nutrition/     # per100g, conversions, référentiels, huile de friture
├── pipeline/      # jobDispatcher, recipeProcessor, deadLetterHandler
├── sandbox/       # une seule fonction déployée, sandboxFn, qui aiguille
├── scheduled/     # réconciliation mensuelle, alerte de budget, rattrapage nutrition
├── security/      # App Check
├── tests/         # node --test, fixtures partagées avec Dart
├── triggers/      # onRecipeWritten, onBookWritten, syncUserClaims, enforceFounderRole, syncGroupReach (+ suppression des repas et des suggestions d'un groupe supprimé, et des suggestions d'un membre sorti, groupMeals.ts), syncPlanningReachOnConfig, syncPlanningReachOnRole (plannerRole.ts), applyEmailInvitation, applyRevokedInvitation
└── utils/         # sécurité d'upload, DOCX, images
```

---

### 13.1 Carte de navigation — les 50 routes

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
la garde de la callable, **jamais par le routeur** : hors `/admin` et les trois écrans de
planification (13.2, étape 8), il laisse passer tout compte nommé. L'import (`/scan`) est réservé à l'éditeur et à l'admin, et `firestore.rules`
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
| `/recipes/new` | `RecipeCreateScreen` | `editor` — gardée par `EditorOnlyGate` : un `reader` arrivé par un lien voit « Création réservée aux éditeurs », comme sur `/scan`. Paramètre `?sourceUrl=` : l'adresse d'un import par lien qui a échoué, rappelée en haut de l'écran (« Page à recopier : »), jamais enregistrée sur la recette |
| `/recipes/:recipeId` | `RecipeDetailScreen` | `reader` |
| `/recipes/:recipeId/edit` | `RecipeEditScreen` | `reader` sur les siennes, `editor` sur celles d'autrui |
| `/book-pages/:pageId` | `BookPageDetailScreen` | `reader` — page de livre sans transition |
| `/scan` | `ScanScreen` | `editor` |
| `/drafts` | `WorkQueueScreen` | `reader` |
| `/drafts/:recipeId` | `DraftReviewScreen` | `reader` |
| `/processing` | — | **redirige vers `/drafts`** : l'écran d'avancement a été fondu dans la file de travail |
| `/search` | `SearchScreen` | `reader` — liste, filtres locaux, « Chercher sur le web » (ouvrir une page) et « Voir sur Google » ; « Chercher avec l'IA », « Imaginer 3 recettes », « Importer depuis un lien », « Importer » d'une page web, et le bandeau d'import au retour du navigateur : `editor` |
| `/planning` | `PlanningScreen` | `reader` — lit les plannings partagés avec lui et ceux de ses groupes, relit ses repas antérieurs et les ajoute aux courses ; planifier : `editor`. `?reserve=1` (posé par 13.2) affiche « Planification réservée aux éditeurs » une fois, puis l'adresse perd le paramètre |
| `/planning/batch` | `BatchPlanningScreen` | `editor` — un `reader` est renvoyé vers `/planning?reserve=1` (13.2). `?group=<groupId>` (`kPlanningGroupParam`) ouvre le planning d'un groupe dont l'utilisateur est le propriétaire ; sinon l'écran dit « Le planning de ce groupe ne vous est pas accessible. » |
| `/planning/config` | `PlanningConfigScreen` | `editor` — « Préférences du planning », dont « Partager mon planning » ; un `reader` est renvoyé vers `/planning?reserve=1` |
| `/planning/staples` | `MyStaplesScreen` | `editor` — ses garnitures, retouchées pour soi ; un `reader` est renvoyé vers `/planning?reserve=1` |
| `/groups` | `GroupsScreen` | `reader` |
| `/account` | `AccountScreen` | `reader` |
| `/preferences` | `PreferencesScreen` | `reader` |
| `/tickets` | `MyTicketsScreen` — « Mes tickets » (liste, et détail côte à côte au-delà du seuil large) | `reader` — ses propres tickets (`firestore.rules`, `author_uid`) ; entrée « Mes tickets » du menu du compte |
| `/tickets/new` | `TicketFormScreen` — « Signaler ou proposer » | `reader` — paramètre `?ecran=` : le modèle de route de l'écran d'où vient le membre, jamais l'adresse réelle ; envoi par `submitTicket` (§5, « Tickets ») |
| `/tickets/:ticketId` | `MyTicketsScreen`, ticket sélectionné | `reader` — l'auteur seul ; ouvrir le détail pose `seen_by_author_at` |
| `/logs` | `LogsScreen` | *voir l'avertissement ci-dessous* |
| `/error-reports` | `ErrorReportsScreen` | *idem* |
| `/dead-letters` | `DeadLettersScreen` | *idem* |

**Sous `/admin`** — la seule branche que le routeur garde vraiment :

| Route | Écran | Ce qu'on y fait |
|---|---|---|
| `/admin` | `AdminHubScreen` | le sommaire de l'administration |
| `/admin/users` | `AdminScreen` | onglets « Comptes » (nommer, changer de rôle, révoquer) et « Invitations » (liste, renvoi, annulation) |
| `/admin/users/invite` | `InviteByEmailScreen` | inviter un proche par e-mail (`manageInvitationFn`, §5) ; formulaire, donc exclu de la pleine largeur de `/admin` (`_wantsFullWidth`, `app_shell.dart`) : la coquille pose `ReadableWidth` |
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
| `/admin/backfills` | `AdminBackfillsScreen` | lancer, programmer et suivre les reprises |
| `/admin/tickets` | `AdminTicketsScreen` — « Tickets des membres » (liste filtrable) | suivre les tickets de la famille, les tickets en anomalie, et le bandeau « Jeton GitHub invalide » (`app_config/tickets_status`) |
| `/admin/tickets/:ticketId` | `AdminTicketsScreen`, ticket sélectionné | auteur, capture, lien vers l'Issue, « Relancer l'envoi » d'un ticket en anomalie (`retryTicketSend`) |
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
8. `/planning/batch`, `/planning/config` ou `/planning/staples` (`kPlanningEditorRoutes`) et
   pas éditeur (`!user.canEdit`) → `/planning?reserve=1` (v0.23.47). L'écran du planning
   lit `kPlanningReservedParam` et affiche « Planification réservée aux éditeurs. Demandez à un administrateur de vous nommer éditeur. »
9. `/processing` → `/drafts`.

Le routeur écoute `appUserProvider` par un `_RouterNotifier` branché en `ref.listen` : cela
**n'ajoute pas de dépendance réactive**, donc le `GoRouter` n'est jamais reconstruit — un
routeur recréé perdrait la pile de navigation à chaque rafraîchissement du compte.

> **Le routeur ne garde que `/admin` et les trois écrans de planification.** `/logs`, `/error-reports` et `/dead-letters` sont
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
  `Secret.png`, `FromTheWeb.png`). Sinon l'image est analysée, et un `WARNING` le journalise. Le test
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
| `attach_on_approval` | `bool` | posé à `true` par l'import par lien seulement (`attachWebPhoto`) : à l'approbation — immédiate, par un administrateur (`reviewModeratedImageFn`) ou par une relance (`retryPendingModerationFn`) —, `attachApprovedIllustration` ajoute `published_url` à `image_urls` de la recette `owner_id` (`recipe_illustration`). Une recette supprimée entre-temps est journalisée et ignorée. `false` partout ailleurs : une image envoyée par le client et mise en attente ne s'attache pas d'elle-même |

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
  réservation dans le plafond quotidien du compte (`withDailyBudget`, v0.23.48) →
  `analyse()` → `decideModeration()` → écriture du document → promotion si `approved`.
  Plafond atteint : `resource-exhausted`.
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
- **Dans le plafond quotidien** (v0.23.48). La modération en était exclue, pour ne jamais
  empêcher de publier une image légitime. Un compte pouvait alors déposer une image en
  quarantaine et rappeler `moderateAndPromoteImagesFn` en boucle : chaque appel déclenchait
  une analyse facturée, sans limite (audit sécurité, « Moyenne »). `moderateAndPromote`
  réserve désormais une place par image analysée (`withDailyBudget`, au coût de l'analyse
  lu dans la grille), avant l'appel à Cloud Vision. Plafond atteint : `BudgetExceededError`,
  rendu au client en `resource-exhausted`. Le client ne lit pas son message :
  `describeError` (`core/widgets/error_message.dart`) traduit tout `resource-exhausted` en
  « Quota atteint — Le service a atteint sa limite pour aujourd'hui. Réessayez plus tard. ».
  Chaque analyse est enregistrée dès qu'elle est faite, réussie ou non (`analyseAndRecord`,
  une ligne `ai_usage` par image, écrite avant que la réservation soit rendue) : l'image
  suivante du lot lit une dépense du jour à jour, et un lot interrompu ne perd aucune analyse
  facturée. L'import par lien perd alors sa photo, la recette reste créée. La relance
  `retryPendingModerationFn`, réservée à l'administrateur et bornée à vingt images, n'est pas
  soumise au plafond ; elle écrit une ligne par relance, qui compte une image analysée pour un
  appel dans `ai_daily_spend` (`dailyCalls`).
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
