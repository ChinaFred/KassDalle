# Spécifications Techniques — Kass'dalle
## Livre de Cuisine Digital (Flutter + Firebase)

> Version : 2.2 — 2 Juin 2026

### Mise à jour release (05/07/2026 — v0.18.0)

#### Client Flutter — Version

- **`pubspec.yaml`** : version `0.18.0+1`.

#### Release engineering

- **Build desktop Windows** : génération en mode release (`flutter build windows --release`) pour alimenter le livrable desktop.
- **Déploiement unifié** : publication via le script racine `deploy.ps1` pour conserver un chemin de release unique et reproductible.

### Mise à jour release (11/07/2026 — v0.19.18)

#### Spécification technique — Gouvernance des unités ingrédients

##### Objectif

- Éliminer les divergences d'unités entre saisie manuelle, génération Gemini et scan OCR.
- Garantir une résolution canonique des unités avant tout calcul nutrition.
- Réduire drastiquement les lignes nutrition sans score dues aux unités non reconnues.

##### Référentiel d'unités (source de vérité)

- Collection Firestore : `nutrition_units`.
- Une unité canonique = un document unique (`normalized_unit`).
- Champs attendus :
  - `normalized_unit: string`
  - `display_label: string`
  - `aliases: string[]`
  - `measurement_type: "weight" | "volume" | "count" | "unknown"`
  - `grams_per_unit?: number`
  - `volume_ml_per_unit?: number`
  - `status: "known" | "unknown" | "pending_review" | "deprecated"`
  - `source: "builtin" | "fallback_auto" | "admin_validated"`
  - `seen_count: number`
  - `first_seen_at`, `last_seen_at`, `updated_at`

**`grams_per_unit` n'existe que sur une unité de POIDS.** Deux types d'unités
n'ont pas de poids intrinsèque et n'en portent donc jamais :

| Type | Ce qui est stocké | Ce qui fait le poids |
|---|---|---|
| `volume` | `volume_ml_per_unit` | `ml × densité(ingrédient)` |
| `count` (« pièce ») | rien | `grams_per_piece` de l'**ingrédient** |

La règle valait pour le volume depuis l'incident de la cuillère à soupe (une
recette à l'huile figeait 13,8 g sur `c_a_s`, imposés ensuite au miel et à
l'eau). Elle manquait pour le comptage, avec la même conséquence en pire : le
premier ingrédient croisé en pièces — inconnu de la table, donc 100 g par
défaut — figeait `grams_per_unit: 100` sur `piece`, et **tout** ce qui se
compte à la pièce pesait dès lors 100 g. Un blanc d'œuf au lieu de 30 g, trois
échalotes 300 g au lieu de 90.

Le champ est désormais supprimé du document à chaque passage sur une unité de
comptage : les référentiels déjà pollués se réparent seuls, sans backfill. Les
deux implémentations (`resolveUnitFactorToGrams`, Dart et TypeScript) ignorent
en outre un tel poids s'il subsiste, et les cas correspondants sont asservis
dans `unit_to_grams.json`.

##### Contrat ingrédient (recette)

Un ingrédient de `recipes.ingredients` porte **ce que la recette dit**, et rien d'autre :

- `name`, `qty`, `unit` (l'unité telle qu'écrite / affichée)
- `category?` — la section CookLang (`== Pour la pâte ==`) dont il relève

**Aucune forme résolue n'est persistée sur la recette.** `unit_raw`,
`unit_canonical`, `unit_resolution_*` et l'identité référentielle
(`ingredient_ref_id`, `ingredient_ref_status`, `ingredient_canonical_name`,
`ingredient_resolution_*`) sont des intermédiaires de calcul : ils se
recalculent depuis `name` et `unit` partout où ils servent, de façon
déterministe. Les stocker créait un champ que plusieurs traitements se
disputaient et que personne ne relisait — la resynchronisation nutrition
effaçait ainsi la catégorie écrite par la normalisation quelques secondes plus
tôt.

La traçabilité de résolution vit dans `nutrition_units` — chaque graphie
observée y est enregistrée en `aliases`, avec `status` et `source` — et non
recopiée sur chaque ligne de chaque recette.

**Un seul écrivain pour `recipes.ingredients` : la normalisation référentiels.**
Les déclencheurs (nutrition, liste de courses) écrivent leurs propres champs
(`nutrition`, `nutrition_validation`, `shopping_products`) et n'y touchent pas.

**Et réciproquement : la normalisation ne calcule pas la nutrition.** Elle l'a
longtemps fait, ce qui produisait deux défauts d'un coup. Le contrat ci-dessus
n'était pas tenu — deux écrivains pour `nutrition` — et surtout le calcul
tombait au mauvais moment : à l'édition d'une recette, le client appelle la
normalisation **avant** d'écrire, or `computeAndPersistRecipeNutrition` relit le
document depuis Firestore. Elle calculait donc sur la version d'avant la
modification et posait sur la recette une nutrition périmée, que le déclencheur
remplaçait quelques secondes plus tard.

La séparation est donc :

| Étape | Qui | Ce qu'elle fait |
|---|---|---|
| 1. Avant l'écriture | `normalizeRecipeReferentialsCore` | résout unités et identités, **enrichit les référentiels par IA** (poids d'unités, `per100g`). Ne touche pas à `nutrition`. |
| 2. L'écriture | client ou `recipeProcessor` | écrit la recette normalisée |
| 3. Après l'écriture | `onRecipeWritten` | calcule `nutrition` et `shopping_products` |

L'enrichissement reste **synchrone à la sauvegarde**, et c'est un choix : quand
le déclencheur calcule, le référentiel est déjà chaud, donc la nutrition est
juste dès le premier affichage. Le déclencheur porte le même enrichissement en
filet — pour les écritures qui ne passent pas par la normalisation, ou quand
celle-ci a manqué de temps — mais il ne coûte rien en double : les deux
fonctions d'enrichissement ne traitent que les entrées **dépourvues** de valeur,
et ne trouvent donc rien à faire au second passage.

**`recipes.nutrition_stale`** comble le seul trou de ce découpage. Quand
l'enrichissement remplit des `per100g` manquants **sans que les ingrédients de la
recette aient bougé**, le déclencheur conclurait à juste titre qu'il n'a rien à
faire : tous les ingrédients ont maintenant leurs valeurs. La nutrition en place
aurait pourtant été calculée sur un référentiel plus pauvre. La normalisation
lève donc ce drapeau, le déclencheur le lit et l'éteint après recalcul — y
compris sur le chemin « recette sans ingrédients », faute de quoi ce
déclencheur, qui réécrit la recette et se réveille lui-même, tournerait sans
fin.

##### Pipeline obligatoire de résolution unité

1. **Normalisation stricte**
  - lowercase, trim, suppression accents.
  - suppression ponctuation / séparateurs non significatifs.
  - uniformisation des graphies abrégées.

2. **Résolution référentiel**
  - lookup exact sur `normalized_unit` puis `aliases`.
  - mapping synonymes contrôlés (table canonique backend).

3. **Fallback contrôlé**
  - uniquement si échec des étapes précédentes.
  - création d'une entrée unique `unknown/pending_review` dans `nutrition_units`.
  - jamais de création de doublon proche d'une unité connue.

4. **Persist dans le référentiel, pas sur la recette**
  - écrire la graphie observée dans `nutrition_units.aliases`, avec `status` et `source`.
  - ne rien écrire de résolu sur `recipes.ingredients` (cf. contrat ingrédient).

##### Règles anti-doublons (exigence critique)

- Les variantes `CAC`, `cac`, `c.C`, `C.c`, `c.a.c`, `c à c`, `cuillère à café` doivent toutes converger vers `c_a_c`.
- Les variantes `CAS`, `c.a.s`, `c à s`, `cuillère à soupe` doivent toutes converger vers `c_a_s`.
- Une nouvelle entrée ne doit pas être créée si une unité canonique existante correspond déjà après normalisation.

##### Intégration par canal

- **Éditeur Flutter** : l'autocomplete unité doit être alimenté par `nutrition_units` et proposer en priorité les unités `known`.
- **Gemini génération** : le prompt doit imposer un catalogue d'unités canoniques ; la sortie doit rester soumise au pipeline backend de résolution.
- **Scan/OCR** : la sortie brute OCR doit passer par le même pipeline backend.
- **Backfill** : ré-analyse des unités historiques avec fusion/normalisation vers canoniques.

##### Administration

- Écran admin unités requis avec :
  - liste des unités `unknown/pending_review`,
  - actions de fusion alias -> canonique,
  - validation des conversions (`grams_per_unit`, `measurement_type`),
  - journal des résolutions.

##### Indicateurs/KPI de pilotage

- Taux d'ingrédients convertibles nutrition.
- Nombre de nouvelles unités fallback/jour.
- Nombre d'unités inconnues non traitées.
- Taux de lignes nutrition sans score par recette.

##### Critères d'acceptation

1. Même ingrédient/unité, quelle que soit la source (éditeur/Gemini/scan), se résout vers le même `normalized_unit` de `nutrition_units`.
2. Les variantes de `cuillère à café` ne créent pas de nouvelles unités.
3. Une unité réellement nouvelle (ex: `tige`) crée une seule entrée fallback réutilisable.
4. Le taux de lignes nutrition à `-` diminue après migration/backfill.

##### Plan de livraison recommandé

- **Lot 1 (backend)** : normalisation stricte + résolution référentiel + fallback contrôlé.
- **Lot 2 (Flutter)** : autocomplete dynamique sur référentiel + feedback de résolution.
- **Lot 3 (Gemini/scan)** : prompts contraints + post-traitement unifié.
- **Lot 4 (ops/admin)** : écran de revue unités + backfill historique + KPI.

### Mise à jour release (04/07/2026 — v0.17.0)

#### Client Flutter — Version

- **`pubspec.yaml`** : version `0.17.0+1`.

#### Retouche image — Atelier unifié

- **`lib/core/presentation/image_enhancer_screen.dart`** :
  - Nouveau mode `EnhancerMode.studio` (mode par défaut) en plus des modes compatibles `crop` et `color`.
  - UI restructurée en panneaux `Cadre`, `Lumière`, `Détails`, `Presets`.
  - Ajout d'un mode comparaison **avant/après** (appui long + toggle).
  - Ajout d'un historique local **undo/redo** basé sur snapshots d'état (image, coins, réglages).
  - Ajout des réglages `contrast` et `saturation` en plus de `brightness` et `sharpen`.

- **`lib/core/presentation/image_enhancer_processing.dart`** :
  - `WarpParams` étendu avec `contrast` et `saturation`.
  - Pipeline `warpIsolate` mis à jour pour appliquer `adjustColor(brightness, contrast, saturation)` avant netteté.
  - Ajout d'une analyse locale légère (`analyzeImageStatsIsolate`) pour suggérer un preset intelligent.

- **`lib/core/presentation/image_action_card.dart`** :
  - Simplification des actions en une entrée **Retoucher** ouvrant l'atelier unifié.

- **`lib/features/recipes/presentation/drafts/draft_review_widgets.dart`** :
  - Remplacement des actions séparées `onCrop` / `onColor` par une action unique `onEdit`.

- **`lib/features/recipes/presentation/drafts/draft_review_body.dart`**,
  **`lib/features/recipes/presentation/drafts/draft_review_screen.dart`**,
  **`lib/features/recipes/presentation/edit/recipe_edit_screen.dart`** :
  - Raccordement des boutons photos à `EnhancerMode.studio`.
  - Titre overlay harmonisé (« Atelier de retouche »).

### Mise à jour release (02/06/2026 — v0.15.31)

#### Sécurité — Firestore Rules

- **`recipe_ratings` — `allow create` restreint** :
  ```
  allow create: if isAuthenticated() && request.resource.data.user_id == request.auth.uid;
  ```
  Avant : `allow create: if isAuthenticated();` — un utilisateur pouvait écrire un document avec le `user_id` d'un autre. Corrigé en ajoutant la vérification d'appartenance.

#### Sécurité — Cloud Functions CORS

- **`cors: true` → liste blanche** dans `geminiCallables.ts` et `deadLetterHandler.ts` :
  ```typescript
  const ALLOWED_ORIGINS = [
    "https://kassdale-6d948.web.app",
    "https://kassdale-6d948.firebaseapp.com",
  ];
  ```
  Les fonctions callable ne répondent plus qu'aux origines connues.

#### Nettoyage — PWA install programmatique supprimé

- **Fichiers supprimés** : `lib/core/utils/web_install.dart`, `web_install_web.dart`, `web_install_stub.dart`. Ces fichiers n'étaient référencés nulle part dans l'UI (jamais importés).

- **`web/index.html`** : suppression de `window._pwaPrompt` et du listener `beforeinstallprompt`. Le navigateur affiche nativement sa bannière d'installation sans capture JS supplémentaire. Le bloc service worker (skip-waiting, controllerchange, update) est conservé intact.

#### Client Flutter — Version

- **`pubspec.yaml`** : version `0.15.31+1`.
- **`lib/core/app_version.dart`** : `kAppVersion = '0.15.31'`.

### Mise à jour release (01/06/2026 — v0.15.29)
git 
#### Client Flutter — Version

- **`pubspec.yaml`** : version `0.15.29+1`.
- **`lib/core/app_version.dart`** : `kAppVersion = '0.15.29'`.

#### Export PDF (`lib/core/services/`)

- **`recipe_pdf_export.dart`** :
  - `exportRecipeToPdf(Recipe, {bool includeImages})` retourne désormais `Future<({Uint8List bytes, String filename})>` au lieu de `Future<void>`. Le téléchargement est toujours effectué en interne (appel à `downloadPdf`), mais les bytes et le nom de fichier sont retournés pour permettre une réouverture post-export.
  - `openPdf(Uint8List bytes, String filename)` : nouvelle fonction publique qui appelle `downloadPdf` — permet de ré-ouvrir le share sheet mobile depuis un snackbar.
  - Import conditionnel : `pdf_download_stub.dart` si (dart.library.html) → `pdf_download_web.dart`.

- **`pdf_download_stub.dart`** (mobile/desktop) : `downloadPdf` = `Printing.sharePdf(bytes: bytes, filename: filename)` — ouvre la share sheet système.
- **`pdf_download_web.dart`** (web) : crée un `Blob` → `<a href download>` → click → revoke URL.

#### Distribution APK — Firebase Hosting

- **`firebase.json`** — bloc `headers` pour l'APK :
  ```json
  {
    "source": "/app-release.apk",
    "headers": [
      { "key": "Content-Type", "value": "application/vnd.android.package-archive" },
      { "key": "Content-Disposition", "value": "attachment; filename=\"kass-dalle.apk\"" }
    ]
  }
  ```
  Ce bloc permet au navigateur Android de déclencher le téléchargement du fichier sans l'ouvrir en ligne.

#### Installation PWA — `web/index.html`

- L'événement `beforeinstallprompt` est **non intercepté** (`e.preventDefault()` absent) : Chrome affiche sa propre bannière d'installation native au moment qu'il juge opportun. Aucun code Flutter ne déclenche ni ne contrôle cette bannière. Les fichiers `web_install*.dart` ont été supprimés (code mort).

#### Mise à jour applicative (`lib/core/presentation/app_shell.dart`)

- `_checkForUpdate()` : sur la version web (`kIsWeb`), la vérification est court-circuitée (`return`) — Chrome gère nativement l'installation PWA. Sur Android natif, la fonction appelle `checkForAppUpdate()` et affiche un dialogue de mise à jour si une nouvelle version est disponible.

#### Snackbar PDF (`lib/features/recipes/presentation/detail/recipe_detail_screen.dart`)

- `_exportPdf()` : après `exportRecipeToPdf`, le snackbar succès (`duration: 8s`) affiche un `SnackBarAction(label: 'Ouvrir')` uniquement si `PlatformUtils.isMobile` (Android/iOS natif). L'action appelle `openPdf(result.bytes, result.filename)` pour ré-ouvrir la share sheet.

#### Éditeur visuel CookLang (`lib/features/recipes/presentation/`)

- **`cooklang_visual_editor.dart`** : éditeur bloc-par-bloc. Chaque bloc est une instance de `BlockType` (section, step, ingredient, utensil, note, image, comment, etc.). L'édition inline se fait via `TextField` focusés dynamiquement. Enter dans un bloc le divise. La sauvegarde écrit le CookLang reconstitué dans Firestore.

- **`hybrid_recipe_editor.dart`** : toggle 3 modes (Texte / Visuel / Aperçu) via `SegmentedButton` ou icônes. Le mode est persisté dans `SharedPreferences`.

#### Éditeur Markdown pages non-recette

- **`markdown_page_editor.dart`** (nouveau) : `TextField` multiligne avec toolbar (H1/H2/H3/B/I/U/liste/image). Insertion d'images depuis la galerie du brouillon avec sélection position+largeur via `AlertDialog` + `ChoiceChip`.

- **Sélecteur de type de page** : `PageType` enum (`recipe`, `technique`, `equipment`, `ingredientNote`, `other`) stocké dans le champ Firestore `page_type` sous sa forme à souligné (`ingredient_note`). Le prompt Gemini de classification utilise un pipeline en 2 appels : classify (chain-of-thought + reasoning) puis extract.
  - **Un seul mapping libellé → type**, `parsePageTypeLabel`, côté Dart comme côté TypeScript. Il accepte les trois graphies qui circulent réellement pour la note d'ingrédient : `ingredient_note` (Firestore), `ingredient note` (saisie) et `ingredientNote` (`PageType.name` côté Dart). Chacune n'était auparavant reconnue que par un lecteur sur deux, si bien que la même page changeait de type selon l'endroit où on la lisait. Cas partagés : `test-fixtures/cooklang_parsing.json`, clé `pageTypeLabels`.

#### Pipeline image — Client

- **`flutter_image_compress`** : ajouté dans `pubspec.yaml`. Utilisé dans `scan_upload_service.dart` pour compresser les photos avant upload (qualité configurable, format JPEG/WebP).
- **Thumbnails WebP** : les miniatures d'illustrations sont générées et stockées au format WebP dans Firebase Storage.
- **Quality gate** : score calculé localement (netteté via Laplacien simulé, luminosité moyenne) avant envoi à Gemini — seuil configurable dans `image_quality_checker.dart`.

#### Bibliothèque de livres

- **Effet 3D couvertures** : `BookCoverWidget` applique `BoxDecoration` avec `BoxShadow` multiple (ombre portée + ombre de tranche) et un overlay gradient pour simuler le vernis. Rendu via `ClipRRect` + `Stack`.
- **Assets par défaut** (`assets/covers/`) : images locales pour les livres système utilisées si `coverUrl` est null.

#### Comptabilité (`lib/features/admin/`)

- **`billing_screen.dart`** : deux onglets via `TabBar`. Onglet GCP : appel Cloud Function `getGcpCostsFn` (BigQuery). Onglet Gemini : `StreamProvider` sur `ai_usage` Firestore, agrégation par `uid+feature+month`, `DataTable` avec tri, total dynamique en bas.
- **`GeminiPricing`** : map `feature → $/1M tokens` (input/output). Tarification images (`enhance_illustration`) : 0,04 $/image.
- **`backfillEnhanceUsageFn`** : Cloud Function HTTPS callable (admin) qui scanne `gs://kassdale-6d948.appspot.com/illustrations/` et backfille les documents manquants dans `ai_usage`.

#### Gestion du cache web — `firebase.json`

- Règle `headers` consolidée :
  - `index.html` + `flutter_service_worker.js` : `Cache-Control: no-cache, no-store, must-revalidate` + `Pragma: no-cache` + `Expires: 0`.
  - `canvaskit/**` : `Cache-Control: public, max-age=31536000, immutable`.
  - `app-release.apk` : `Content-Type: application/vnd.android.package-archive` + `Content-Disposition: attachment`.
  - **Ne jamais utiliser** `**/*.@(js|css|wasm)` avec cache long — le glob attrape `flutter_service_worker.js` et crée un conflit de headers `immutable` bloquant les mises à jour.

### Mise à jour release (18/05/2026 — v0.13.62)

#### Backend Cloud Functions (Node 20, TypeScript, 2nd gen, région `europe-west1`)

- **Structure `kass_dalle/functions/src/`** :
  - `index.ts` : exporte 15 fonctions (callables + handlers Cloud Tasks).
  - `config.ts` : constantes `REGION`, `PROJECT_ID`, `LOG_NAME = "kass-dalle-pipeline"`, `QUEUE_NAME = "recipe-processing-queue"`, `GEMINI_SECRET = "GEMINI_API_KEY"`.
  - `_auth.ts` : helpers `requireAuth(req)`, `requireAdmin(req)` (lit `users/{uid}.role`).
  - `_logger.ts` : wrapper `@google-cloud/logging` avec labels `{module, correlation_id, job_id, user_id}` et payload JSON structuré.
  - `callable/*Callable.ts` : callables clients (createScanJobFn, queryLogsFn, relaunchDeadLetterFn, deleteDeadLetterFn, geminiProxyFn, etc.).
  - `pipeline/recipeProcessor.ts` : handler Cloud Tasks principal (download Storage → Gemini extract → normalisation Cooklang → upsert Firestore `processing_jobs` + `recipes`).
  - `pipeline/dlq.ts` : sur 3e échec, écrit dans `dead_letters` (Admin SDK, bypass règles).
  - `triggers/recipeWritten.ts` : **déclencheur unique** sur `recipes/{recipeId}`.
  - `scheduled/aiReconciliationSchedule.ts` : réconciliation comptable mensuelle (Cloud Scheduler).
  - `billing/periods.ts` : périodes `YYYY-MM`, module pur et testé.

##### Politique de calcul nutritionnel

`app_config/nutrition_source_policy` porte les seuils qui décident de **ce que
l'utilisateur voit** sur l'onglet Nutrition d'une recette. Le document n'est pas
obligatoire : `getNutritionSourcePolicy()` retombe sur `DEFAULT_NUTRITION_POLICY`.

| Réglage | Défaut | Effet observable |
|---|---|---|
| `quality_policy.minCoverageForPartial` | 0,7 | En dessous, le détail est remplacé par « Trop peu d'ingrédients ont un poids connu pour que le calcul soit représentatif » |
| `quality_policy.minCoverageForPer100g` | 0,9 | En dessous, les valeurs **pour 100 g sont masquées** |
| `quality_policy.kcalConsistencyWarnDeltaPct` | 0,15 | Au-delà de cet écart entre kcal annoncées et kcal recalculées depuis les macros, avertissement d'incohérence du référentiel |
| `fallback_policy` | `strict` | Comportement quand aucune donnée n'est trouvée |
| `source_priority` | validé‑utilisateur → interne → externe → IA | Quelle origine gagne quand un ingrédient en a plusieurs |

Les trois seuils entrent aussi dans le **score de qualité A/B/C** de la recette.

**Écran** : *Admin › Référentiels › Politique nutrition*. Les trois seuils s'y
règlent au curseur, présentés par leur effet et non par leur nom technique.
`source_priority` y est en lecture seule : le modifier demande de comprendre la
chaîne d'enrichissement, pas de bouger un curseur.

**Les bornes sont garanties côté serveur**, pas dans le formulaire :
`setNutritionSourcePolicyFn` refuse une valeur hors de [0, 1], un
`kcalConsistencyWarnDeltaPct` nul (il sert de dénominateur au score) et un
`minCoverageForPer100g` inférieur à `minCoverageForPartial` — cette dernière
combinaison ferait afficher un détail pour 100 g sur une recette que l'app
déclare par ailleurs trop incomplète pour être représentative.

Ces réglages ont longtemps été inertes : le mécanisme de lecture existait, mais
aucun écran n'appelait le callable d'écriture, si bien que seules les valeurs
par défaut avaient jamais servi.

##### Politique de routage entre fournisseurs d'IA

`app_config/ai_routing_policy` décide **quel moteur sert quel poste**. Le
document n'est pas obligatoire : `getAiRoutingPolicy()` retombe sur
`DEFAULT_AI_ROUTING_POLICY`, c'est-à-dire Gemini partout — le code déployé ne
change donc aucun comportement tant que personne n'a écrit la politique.

| Champ | Type | Effet |
|---|---|---|
| `default_provider` | `"gemini"` \| `"anthropic"` | Moteur des postes sans choix explicite |
| `features` | `Map<String, provider>` | Choix par poste ; la clé est celle du reporting de coûts |
| `anthropic_model` | `String` | Modèle Claude servi quand le routage désigne Anthropic (défaut `claude-sonnet-5`) |
| `fallback_enabled` | `bool` | Repli sur l'autre moteur en cas d'échec **technique** ; une réponse déclinée pour raison de sûreté n'est jamais rejouée ailleurs |

**Écran** : *Admin › Moteur d'IA*. Les postes proposés viennent du serveur
(`ROUTABLE_FEATURES`) et ne sont pas dupliqués côté client : une bascule vers un
poste que le backend ignore ne produirait aucune erreur — elle ne routerait
simplement rien. Ils y sont groupés par famille (Import, Illustrations,
Rédaction, Recherche, Planning, Courses, Nutrition), chaque famille et l'écran
entier basculant d'un geste.

**Tout appel de texte ou de lecture d'image passe par `callModel`** : import et
classification de page, extraction de document, couverture de livre, détection
d'illustrations, rédaction et relecture, tags, recherche, planning, courses et
toute la chaîne nutrition. Les deux seuls appels non routables sont ceux qui
**produisent** une image (`enhance_illustration`,
`generate_recipe_illustration`) — Claude n'en fabrique pas.

La liste des postes n'est donc pas décorative : elle est exactement l'ensemble
des `feature` passées à `callModel`. Elle a un temps promis six bascules alors
qu'une seule était câblée, et une bascule sans effet se diagnostique très mal —
elle ressemble à une panne du moteur.

Deux garde-fous complètent le routage :

- **Format de pièce jointe.** Claude lit les images JPEG/PNG/GIF/WebP et les
  PDF ; il refuse le DOCX et les formats exotiques que Gemini accepte. Un poste
  routé vers Claude avec un tel fichier part directement chez Gemini, sans
  consommer un appel voué à l'échec ni écrire une erreur qui ressemblerait à une
  panne.
- **Poste littéral.** Chaque fonction impose son propre nom de poste au lieu de
  reprendre celui de l'appelant. Un poste dont le nom varie selon le point
  d'entrée ne peut être ni basculé ni comparé — et son coût se disperse sur
  plusieurs lignes du reporting.

**Garanties côté serveur** : `setAiRoutingPolicyFn` refuse un fournisseur
inconnu, un poste hors catalogue et un modèle vide. Et surtout, `resolveProvider`
sert avec Gemini tout poste routé vers Claude tant que la clé n'est pas posée :
l'absence de secret ne prive jamais l'utilisateur du service. L'écran affiche
explicitement cet état plutôt que de laisser croire à une bascule effective.

Le fournisseur et le modèle réellement utilisés sont écrits sur chaque ligne de
`ai_usage` (`provider`, `model`) et le coût est estimé au tarif de **ce**
modèle : sans cela, un appel Claude serait facturé au tarif Gemini sans qu'aucun
écran ne s'en aperçoive.

##### Réconciliation comptable des coûts IA

Répond à une question qu'on ne se pose pas spontanément : *le suivi de coûts
dit-il la vérité ?* Une erreur de tarification ne lève aucune exception — elle
produit un chiffre plausible. Seule la confrontation à la facture la révèle.

Pour un mois donné, `runAiReconciliation` compare :

- **l'estimé traçable** — somme des `estimated_cost_usd` de `ai_usage`, calculés
  appel par appel avec la grille tarifaire (`gemini/pricing.ts`), **en dollars** ;
- **le facturé réel** — requête BigQuery sur `billing_export`, filtrée sur
  Vertex AI, Generative Language, le service **Gemini API** et les SKU Gemini,
  hors assistance de console (*Code Assist*, *Gemini for Google Cloud*).

**La devise n'est pas le dollar.** La colonne `cost` de l'export est libellée
dans la devise du **compte de facturation** — l'euro pour ce projet. La comparer
telle quelle à une grille tarifaire en dollars additionne deux monnaies et
produit un écart faux, sans que rien n'échoue. Les deux requêtes divisent donc
`cost` par `currency_conversion_rate` — le taux que Google a lui-même appliqué à
la ligne — et conservent en parallèle le montant d'origine :

| Champ | Sens |
|---|---|
| `billed_ia_usd` | facturé converti en dollars, seule forme comparable à l'estimé |
| `billed_ia_native` | le chiffre de la facture, tel qu'il apparaît dans le Tableau des coûts |
| `billing_currency` | devise du compte (`EUR`) ; absent = rapport d'avant cette prise en compte, à recalculer |

Une ligne dépourvue de taux de change manque au total en dollars sans rien
casser : elle est comptée, journalisée par `logError` et remontée en anomalie.

**Le taux de change se relève avec les coûts.** Il n'existe plus de taux figé
dans le code : `refreshCurrencyRate` calcule, sur la même période, la moyenne du
taux pondérée par le coût — `SUM(cost) / SUM(cost / currency_conversion_rate)` —
et l'écrit dans `app_config/currency_rate` (`usd_to_account_rate`, `currency`,
`source_period`, `updated_at`). Un taux vieillit exactement au rythme des coûts
qu'il convertit : le rafraîchir ailleurs serait une occasion de l'oublier.

`validateCurrencyRate` (`billing/currencyRate.ts`, testé) refuse un taux hors de
`[0.1, 10]`, sans devise, ou absent : le taux précédent reste alors en vigueur et
le motif du refus part dans `logError`. Un taux aberrant accepté ne casserait
rien — il changerait silencieusement l'échelle de tous les montants en euros.

Côté client, `CurrencyRateRepository` lit ce document ; `GeminiPricing.usdToEurFallback`
(0,92) ne sert plus que tant qu'aucune réconciliation n'a eu lieu, et l'onglet
*Réconciliation* affiche alors explicitement qu'il convertit avec un repli.
Les coûts GCP en euros ne sont plus convertis du tout : le compte facturant en
euros, `costNative` **est** le montant de la facture.

Le résultat part dans `ai_reconciliation_monthly/{YYYY-MM}` : `delta_usd`,
`unattributed_usd`, ventilation `by_feature`, et `anomalies` en clair.

| Déclenchement | Quand | Période |
|---|---|---|
| `scheduledAiReconciliation` (Cloud Scheduler) | le 4 de chaque mois, 6 h Europe/Paris | le **mois écoulé** |
| `generateAiReconciliationMonthlyFn` (bouton admin) | à la demande | la période choisie |

Les deux passent par le **même traitement**. Le rapport porte sur le mois écoulé
et non sur le mois courant : l'export de facturation GCP se consolide avec
quelques jours de retard, et un mois partiel produirait un écart qui ne dit rien.

Le champ `billing_query_failed` distingue « Google n'a rien facturé » de « on
n'a pas pu savoir ». Sans lui, une requête BigQuery en échec produisait un
rapport affirmant un montant facturé nul, donc un écart négatif spectaculaire
présenté comme un fait.

**Écran** : onglet *Réconciliation* de l'écran Comptabilité.

##### Un seul importeur, un seul déclencheur par recette

**L'import se fait entièrement côté backend.** Le client envoie le fichier dans
`quarantine/`, crée un `processing_jobs/{id}` en `queued`, puis n'écoute plus
que le statut. `jobDispatcher` réagit à l'**entrée** en `queued` — création
comme relance — et enfile la tâche Cloud Tasks.

Le client portait auparavant un second pipeline d'import complet, utilisé par la
seule relance : le même fichier pouvait donner deux recettes différentes selon
qu'il avait été importé ou relancé. Ce pipeline client est supprimé. Relancer,
c'est désormais remettre le job en `queued` ; annuler, c'est poser
`cancel_requested: true`, que `recipeProcessor` relit avant chaque tentative —
le statut seul ne suffisait pas, le traitement backend l'écrasait en fin de
course.

**Un seul déclencheur écoute `recipes/{recipeId}` : `onRecipeWritten`.** Il
évalue les gardes communes (suppression, type de page, empreinte des
ingrédients) puis lance ensemble `refreshShoppingProducts` et
`syncRecipeNutrition`, indépendants l'un de l'autre. Deux déclencheurs
distincts écoutaient ce document, chacun le réécrivant en fin de traitement,
donc chacun réveillant l'autre : une sauvegarde de recette coûtait quatre
invocations de fonctions 512 MiB au lieu d'une.

- **Cloud Tasks `recipe-processing-queue`** :
  - Région `europe-west1`, max-dispatches-per-second=2, max-concurrent-dispatches=5, max-attempts=3, min-backoff=10s, max-backoff=600s.
  - Création via `gcloud tasks queues create` ; auth des tâches : OIDC du SA `{projectNumber}-compute@developer.gserviceaccount.com`.

- **Secret Manager** :
  - Secret `GEMINI_API_KEY` (v1) lu par les fonctions via `defineSecret("GEMINI_API_KEY").value()`.
  - Accordé au SA runtime par défaut (`roles/secretmanager.secretAccessor`).
  - Secret `ANTHROPIC_API_KEY` — **à créer avant d'activer Claude**. Lu par
    `ai/anthropic.ts` via `process.env.ANTHROPIC_API_KEY`, et non via
    `defineSecret`, tant qu'il n'existe pas : un secret déclaré et attaché mais
    absent de Secret Manager fait échouer **tout** le déploiement, y compris les
    fonctions qui n'en ont pas besoin. Activation en deux gestes, dans cet ordre :

    ```powershell
    # 1. Créer le secret (la commande demande la valeur en entrée standard)
    firebase functions:secrets:set ANTHROPIC_API_KEY

    # 2. Attacher le secret aux fonctions qui appellent la chaîne nutrition,
    #    en ajoutant ANTHROPIC_API_KEY à leur liste `secrets: [...]` :
    #      - onRecipeWritten            (triggers/recipeWritten.ts)
    #      - normalizeRecipeReferentialsFn (callable/nutritionCallable.ts)
    #      - recipeProcessor            (pipeline/recipeProcessor.ts)
    #      - backfillEnrichReferentialsFn (callable/billingCallable.ts)
    ```

    Tant que l'étape 1 n'est pas faite, la politique de routage peut désigner
    Claude sans risque : le routeur constate l'absence de clé et sert avec
    Gemini, ce que l'écran Admin → Moteur d'IA affiche explicitement.

- **Artifact Registry** :
  - Policy de cleanup `1 day` sur l'image `gcr.io/kassdale-6d948/gcf-artifacts` (Container images des fonctions).

#### Firestore

- **Collection `processing_jobs/{jobId}`** :
  - Champs : `user_id`, `file_path`, `correlation_id`, `task_name`, `status` (queued|processing|done|error), `created_at`, `updated_at`, `attempt_count`, `last_error?`, `recipe_id?`, `result?`.
  - Règles : owner read ; write côté Admin SDK uniquement (`allow write: if false`).

- **Collection `dead_letters/{dlqId}`** :
  - Champs : `original_job_id`, `user_id`, `correlation_id`, `failure_reason`, `last_error`, `retry_count`, `file_path`, `failed_at` (Timestamp), `relaunched_at?`, `relaunched_by?`, `relaunched_into_job_id?`, `queue_name`.
  - Règles : `allow read: if isAdmin();` `allow write: if false;` (écriture Admin SDK via DLQ handler / callables relaunch/delete).
  - Aucun index composite requis (orderBy `failed_at desc` champ unique).

#### Client Flutter

- **`pubspec.yaml`** : `cloud_functions: ^6.1.2`. Version `0.13.62+1`.

- **`lib/core/app_version.dart`** : `kAppVersion = '0.13.62'`.

- **Suppression de la clé Gemini côté client** : `--dart-define=GEMINI_API_KEY` retiré de tous les builds et du script `deploy.ps1`. Sept fichiers nettoyés (constante `_geminiApiKey` et tests `isEmpty` supprimés) : `scan_upload_service.dart`, `search_providers.dart`, `planning_screen.dart`, `batch_planning_screen.dart`, `draft_review_screen.dart`, `recipe_create_screen.dart`, `recipe_edit_screen.dart`. Le `GeminiService` reçoit désormais une chaîne vide en clé — il n'est plus utilisé que comme façade de types ; les appels effectifs passent par `FirebaseFunctions.instanceFor(region: 'europe-west1').httpsCallable(...)`.

- **`lib/features/admin/domain/dead_letter.dart`** : modèle `DeadLetter` avec `fromDoc(DocumentSnapshot)` (parse Timestamp `failed_at`/`relaunched_at`), getter `isRelaunched => relaunchedAt != null`.

- **`lib/features/admin/data/dead_letter_repository.dart`** :
  - `watchAll({int limit = 200})` : `_db.collection('dead_letters').orderBy('failed_at', descending: true).limit(limit).snapshots()` → `Stream<List<DeadLetter>>`.
  - `relaunch(String dlqId)` : `httpsCallable('relaunchDeadLetterFn').call({'deadLetterId': dlqId})` → renvoie `data['newJobId'] as String`.
  - `delete(String dlqId)` : `httpsCallable('deleteDeadLetterFn').call({'deadLetterId': dlqId})`.

- **`lib/features/admin/presentation/dead_letters_screen.dart`** : `ConsumerWidget` avec `deadLettersStreamProvider = StreamProvider.autoDispose`. Liste d'`ExpansionTile` ; chaque ligne `_KeyValueRow` a un `IconButton(Icons.copy_outlined)`. Boutons d'action `Relancer` / `Supprimer` sous `AlertDialog` de confirmation. État relancé matérialisé par `Icons.replay` vert et bouton désactivé.

- **`lib/features/admin/domain/log_entry.dart`** : `LogEntry.fromMap(Map)` avec champs `timestamp` (String), `severity` (String), `labels` (Map<String,String>), `payload` (Map). Getter `message` lit `payload['message']`. Getter `timestampDate => DateTime.tryParse(timestamp)`.

- **`lib/features/admin/data/logs_repository.dart`** :
  - `query({int timeRangeMinutes = 60, int pageSize = 100, String? severity, String? correlationId, String? jobId, String? userId, String? freeText})` → appelle `httpsCallable('queryLogsFn', HttpsCallableOptions(timeout: Duration(seconds: 60)))`.
  - **`severity` est un seuil** côté `queryLogsFn` : `severity>=INFO|WARNING|ERROR`, sauf `DEBUG` qui reste une égalité stricte (`severity=DEBUG`) pour isoler l'instrumentation. `null` ⇒ aucun filtre. Défaut du `LogsFilter` : `'INFO'`.
  - Côté Functions, `logDebug()` (`logging.ts`) écrit en severity `DEBUG` : « Appel IA démarré » (`gemini/client.ts`), « prompt envoyé à Gemini » et « réponse brute Gemini » (`nutrition/aiEnrichment.ts`). Un import passe ainsi d'une cinquantaine de lignes à une quinzaine.

- **`lib/features/admin/presentation/logs_screen.dart`** :
  - `LogsFilter` immuable avec `_sentinel` pattern dans `copyWith` pour distinguer "ne pas toucher" de "set null".
  - `LogsFilterNotifier extends Notifier<LogsFilter>` (Riverpod 3 n'a plus `StateProvider`).
  - `logsFilterProvider = NotifierProvider<LogsFilterNotifier, LogsFilter>(LogsFilterNotifier.new)`.
  - `logsQueryProvider = FutureProvider.autoDispose<List<LogEntry>>` qui watch le filtre et le repo.
  - UI : `ChoiceChip` (Tous/INFO/WARN/ERROR/DEBUG), `DropdownButton` (15/60/360/1440/10080 min), `TextField` × 4 (freeText/corr/job/user), `FilterChip` "Par traitement" (état local `_groupByTreatment`, actif par défaut), bouton `FilledButton` "Filtrer".
  - Regroupement par traitement : `_groupByCorrelation(List<LogEntry>) → List<_TreatmentGroup>` indexe sur `labels['correlationId']` en conservant l'ordre d'apparition des groupes (le plus récent d'abord, comme le flux) et inverse les entrées à l'intérieur (déroulement chronologique). `_TreatmentGroup.label` retient **d'abord** la racine du `correlationId` — l'identifiant privé de son horodatage (`RegExp(r'[-_]\d{10,}([-_][a-z0-9]+)?$')`), `null` si l'identifiant est un UUID, donc opaque — puis, à défaut seulement, `labels['feature']`, puis `labels['moduleType']` ; clé vide ⇒ « Hors traitement ». `feature` est le poste d'imputation d'un appel IA, pas le nom d'un traitement : en faire le titre étiquetait un import de recette « shopping_products_refresh ».
  - Côté Functions, `onRecipeWritten` pose un `newCorrelationId("recipe-written")` unique et le passe à `refreshShoppingProducts` et `syncRecipeNutrition` — qui tiraient auparavant chacun un `randomUUID()`, produisant deux traitements anonymes par écriture de recette. `_TreatmentTile` est un `ExpansionTile` avec `initiallyExpanded: group.hasError`, icône/couleur dérivées de `hasError`/`hasWarning`, et un `IconButton(Icons.filter_alt_outlined)` qui reporte le `correlationId` dans le filtre exact.
  - Entrée dépliable : icône+couleur selon sévérité (`Icons.error`/`warning`/`info`/`bug_report`), chips labels (module/corr/job) avec copie, `SelectableText` monospace pour JSON formaté via `JsonEncoder.withIndent('  ')`.

- **`lib/core/router/app_router.dart`** : routes `/dead-letters` et `/logs` ajoutées avec leurs `GoRoute`. Imports correspondants.

- **`lib/features/admin/presentation/admin_screen.dart`** : deux nouvelles tuiles `Card` cliquables — "Dead Letter Queue" (`Icons.report_problem_outlined`, `colorScheme.tertiary`) et "Cloud Logging" (`Icons.terminal`, `colorScheme.secondary`).

#### Permissions Cloud

- **SA runtime par défaut Cloud Functions** : `{projectNumber}-compute@developer.gserviceaccount.com` (rôle `roles/editor`) couvre `logging.logEntries.list` (utilisé par `queryLogsFn`), `cloudtasks.tasks.create` (utilisé par `createScanJobFn`), `datastore.documents.*` (Firestore via Admin SDK), `storage.objects.get`.
- **Secret accessor** : ajouté explicitement pour `GEMINI_API_KEY`.

### Mise à jour release (17/05/2026 — v0.13.53)

- **Nouveau champ `recipes.import_version`** :
  - Type : `String?`, clé Firestore : `import_version`.
  - Renseigné automatiquement avec `kAppVersion` lors de chaque création de brouillon dans `scan_upload_service.dart` (deux constructeurs `Recipe` : page non-recette et recette standard).
  - Absent sur les anciennes recettes → retourne `null` via `data['import_version'] as String?`.
  - Modèle `Recipe` (`lib/features/recipes/domain/recipe.dart`) : champ `final String? importVersion` ; sérialisé dans `toFirestore()` uniquement si non-null ; désérialisé dans `fromFirestore()` ; paramètre optionnel dans `copyWith`.

- **`recipe_meta_panel.dart` — affichage admin de la version d'import** :
  - Consomme `isAdminProvider` via `ref.watch(isAdminProvider)`.
  - Affiche un `Row` supplémentaire sous « Analysé le… » uniquement si `isAdmin && recipe.importVersion != null`.
  - Icône `Icons.build_outlined` (size 16) + texte `'Importé avec v${recipe!.importVersion}'` en `bodySmall`, couleur `onSurfaceVariant`, italique.

- **`draft_review_screen.dart` — images agrandissables dans l'Aperçu non-recette** :
  - Nouveau champ d'état `final Set<String> _expandedApercuImages = {}` sur `_DraftReviewScreenState`.
  - `buildPhoto(String photoUrl)` (fonction locale dans `_buildNonRecipeApercu`) : `Stack` contenant un `GestureDetector` global (tap = toggle expand), un `ConstrainedBox(maxHeight: 280)` si non-agrandi, un bouton `fullscreen`/`fullscreen_exit` positionné `Positioned(bottom: 6, right: isOwner ? 48 : 6)` (décalé pour ne pas masquer le bouton de suppression), et un bouton `delete_outline` `Positioned(top: 8, right: 8)` visible uniquement pour le propriétaire.

### Mise à jour release (17/05/2026 — v0.13.52)

- **`draft_review_widgets.dart` — bouton « Depuis l'original »** :
  - `DraftIllustrationsTab` : nouveau paramètre `VoidCallback? onExtractFromOriginal`.
  - Affiché comme `TextButton.icon(Icons.crop_outlined, 'Depuis l\'original')` dans la barre d'actions de l'onglet (coté droit, après le bouton « Ré-extraire ») si `isOwner && onExtractFromOriginal != null && _isImageSource(sourceFileUrl)`.
  - Désactivé pendant `aiRefining || saving`.

- **`draft_review_screen.dart` — `_startExtractFromOriginal(Recipe)`** :
  - Télécharge le fichier source via `FirebaseStorage.instance.refFromURL(url).getData(20 * 1024 * 1024)`.
  - Initialise l'enhancer : `_enhancerBytes = bytes`, `_enhancingIndex = null` (null = ajout d'une nouvelle illustration, pas remplacement d'une existante), `_enhancerMode = EnhancerMode.crop`, `_showingIllEnhancer = true`.
  - `_onIllustrationEnhancerResult` : si `_enhancingIndex == null`, appelle `_addNewIllustration(resultBytes)` plutôt que de remplacer une illustration existante.
  - Branché sur `onExtractFromOriginal:` de chaque instance `DraftIllustrationsTab` (4 occurrences dans les différents layouts narrow/wide).

- **`cooklang_preview_helpers.dart` — suppression directe visible** :
  - `CooklangIllustrationThumb` : bouton `delete_outline` rendu toujours visible en overlay (plus de longpress) dès que `onDelete != null`. Icône `Icons.delete_outline` (remplace `Icons.close`).

- **`draft_review_widgets.dart` — `_IllustrationCard`** :
  - Icône suppression : `Icons.delete_outline` (remplace `Icons.close`).

### Mise à jour release (17/05/2026 — v0.13.51)

- **`draft_review_screen.dart` — `_buildNonRecipeApercu(Recipe, {required bool isOwner})`** :
  - Nouvelle méthode de rendu pour les brouillons non-recette (pages textuelles avec illustrations intercalées).
  - Nettoyage syntaxe CookLang : regex `@([^{}]+)\{\}` → texte brut (retire les balises ingrédients).
  - Découpe le texte sur les marqueurs `[schéma : …]` (regex `\[schéma\s*:[^\]]*\]`) ; insère l'illustration correspondante par index `photoIndex++` entre chaque bloc texte.
  - Formatage textuel : lignes `#…` → `titleMedium` bold ; lignes `- …` ou `* …` → puce `• ` + texte ; lignes vides → `SizedBox(height: 8)` ; reste → `SelectableText` style `bodyMedium`.
  - Rendu dans `SingleChildScrollView > Padding(16) > Column`.
  - Affiché dans l'onglet « Aperçu » uniquement si la recette n'est pas une recette structurée Cooklang (détection basée sur l'absence d'ingrédients balisés `@`).

### Mise à jour release (17/05/2026 — v0.13.50)

- **Correction navigation enhancer → onglet Photos** : `_onIllustrationEnhancerResult` réinitialise `_showingIllEnhancer = false` en retournant toujours le `Stack` principal (préserve le `DefaultTabController`). L'écran ne remplace plus son widget racine par l'enhancer, il l'affiche en overlay dans le `Stack`.

- **Build web `--no-tree-shake-icons`** : tous les builds web release intègrent désormais `--no-tree-shake-icons` pour éviter la suppression des glyphes Material par le compilateur Dart (`dart2js`). Commande standard : `flutter build web --release --no-tree-shake-icons`. La clé Gemini n'est plus passée au client : voir Secret Manager côté Cloud Functions.

### Mise à jour release (15/05/2026 — v0.13.35)

- **Extraction `scan_state.dart`** (`lib/features/recipes/data/scan_state.dart`) :
  - `ScanStatus` (enum), `ScanIntent` (enum) et `ScanState` (classe immuable) extraits de `scan_upload_service.dart`.
  - `scan_upload_service.dart` expose `export 'scan_state.dart'` pour compatibilité des imports existants (zéro modification des consommateurs).

- **Extraction `cooklang_preview_helpers.dart`** (`lib/features/recipes/presentation/cooklang_preview_helpers.dart`) :
  - Contient tous les helpers réutilisables du widget CookLang : `CooklangIngredient`, `CooklangStepGroup`, `CooklangIllustrationThumb`, `cooklangFormatTimer()`, `cooklangFormatIngredient()`, `cooklangNormalizeStepTimers()`.
  - Tous les noms ont été rendus publics (prefixe `_` retiré) pour être accessibles hors du fichier.
  - `cooklang_preview.dart` réduit de 877L à 728L ; `cached_network_image` importé uniquement dans le fichier helpers.

- **Extraction `batch_planning_widgets.dart`** (`lib/features/planning/presentation/batch_planning_widgets.dart`) :
  - `BatchSlotTile` (ex `_SlotTile`) : tuile StatelessWidget d'un créneau de planning. Paramètres : `index`, `date`, `recipe`, `prefs`, `slotTime`, `isGenerating`, `onAssign`, `onRemove`, `onDelete`, `onTimeChanged`, `onGenerateWithAI?`, `onExportToCalendar?`.
  - `BatchRecipePickerSheet` (ex `_RecipePickerSheet`) : bottom sheet de recherche de recette avec champ de filtre textuel, suggestion IA et saisie de repas libre.
  - `batch_planning_screen.dart` réduit de 785L à 488L.

- **Qualité de code** :
  - `withOpacity(x)` → `withValues(alpha: x)` : 7 occurrences dans 5 fichiers (`recipe_detail_widgets.dart`, `shopping_list_sheet.dart`, `draft_list_screen.dart`, `work_queue_widgets.dart`, `search_screen.dart`).
  - Suppression de tous les `debugPrint` en code de production (`recipe_detail_screen.dart`, `recipe_detail_widgets.dart`).
  - `use_build_context_synchronously` : ajout de `if (!context.mounted) return` dans `source_viewer.dart` ; capture de `ScaffoldMessenger` avant `await` dans `work_queue_screen.dart` ; utilisation de `this.context` après vérification `mounted` dans `recipe_list_screen.dart`.
  - Corrections linter : accolades curly-brace, dangling doc comments → commentaires normaux, null-aware map entries (`'key': ?value` au lieu de `?'key': value`), empty catches documentés, wildcards `(_, _)` conformes Dart 3.7.
  - Résultat `flutter analyze` : 0 error, 0 warning, 2 infos inévitables (`dart:html` legacy).

### Mise à jour release (15/05/2026 — v0.13.27)

- **Collection Firestore `planning_config`** :
  - Document par utilisateur : `planning_config/{uid}`.
  - Schéma : `meals_per_cycle: int` (défaut 7), `cycle_start_day: int` (1=Lundi, 7=Dimanche), `batch_cooking_day: int?`, `daily_constraints: Map<String, Map>` (clé = weekday en string), `global_constraints: String`, `default_meal_hour: int`, `default_meal_minute: int`, `calendar_id: String` (identifiant du calendrier Google cible, défaut `'primary'`).
  - `DayConstraint` : `max_prep_minutes: int`, `is_batch_cooking: bool`, `notes: String`.

- **`PlanningPreferences`** (`lib/features/planning/domain/planning_preferences.dart`) :
  - `nextCycleDates()` : génère la liste des `DateTime` du prochain cycle à partir du `cycleStartDay` et `mealsPerCycle`.
  - `fromFirestore(Map)` / `toFirestore()`.
  - `copyWith(...)`.

- **`PlanningRepository`** — nouvelles méthodes :
  - `addMeals(List<PlannedMeal>)` : batch Firestore pour l'ajout groupé.
  - `updateMealRecipe(id, {recipeId, recipeTitre, durationMinutes, prepMinutes, cookMinutes})` : mise à jour de la recette assignée à un créneau.
  - `updateMealTime(id, DateTime)` : mise à jour de l'heure du créneau.
  - `watchPreferences()` : stream de `PlanningPreferences`.
  - `savePreferences(PlanningPreferences)` : upsert dans `planning_config/{uid}`.
  - `getValidatedRecipes()` : `Future<List<Recipe>>` — recettes validées de l'utilisateur.
  - Providers nouveaux : `planningPreferencesProvider` (`StreamProvider<PlanningPreferences>`).

- **`PlanningAiService`** (`lib/features/planning/services/planning_ai_service.dart`) :
  - Modèle : `gemini-2.5-flash`.
  - `suggestMealPlan({apiKey, recipes, slotDates, dailyConstraints, globalConstraints})` → `Future<List<Recipe?>>`.
  - Prompt structuré : liste des recettes disponibles (titre, temps prep/cuisson, tags), liste des créneaux avec leur jour de la semaine et contraintes, contraintes globales. Retourne un JSON `{ "slots": [{"index": i, "recipe_title": "..."}] }`. Parse chaque entrée en cherchant la recette correspondante par titre normalisé.
  - `suggestSingleSlot({...})` : variante pour un seul créneau.

- **`BatchPlanningScreen`** (`lib/features/planning/presentation/batch_planning_screen.dart`) :
  - Route `/batch-planning`.
  - `ConsumerStatefulWidget`. État : `_slots: Map<int, Recipe?>`, `_slotTimes: Map<int, TimeOfDay>`, `_slotDates: List<DateTime>`.
  - `_init()` : charge les recettes validées via `PlanningRepository.getValidatedRecipes()` et les préférences via `planningPreferencesProvider`.
  - `_applyPrefs(PlanningPreferences)` : initialise les créneaux avec `prefs.nextCycleDates()`.
  - Génération IA globale : appelle `PlanningAiService.suggestMealPlan()`, met à jour `_slots`.
  - Génération IA individuelle : appelle `PlanningAiService.suggestSingleSlot()` pour un créneau (`_generatingSlot` indique l'index en cours).
  - Picker recette : `RecipePickerDialog` avec filtre textuel et suggestion IA.
  - Sauvegarde : `PlanningRepository.addMeals()` avec tous les créneaux non-nuls.

- **`PlanningConfigScreen`** (`lib/features/planning/presentation/planning_config_screen.dart`) :
  - Route `/planning-config`.
  - Champs : `mealsPerCycle` (slider/champ), `cycleStartDay` (dropdown), `defaultMealHour`/`defaultMealMinute` (sélecteur heure), `globalConstraints` (TextField multilignes).
  - Pour chaque jour (Lundi–Dimanche) : `maxPrepMinutes` (TextField numérique), `isBatchCooking` (Switch), `notes` (TextField).
  - Sélection du calendrier Google : appelle `CalendarService.listCalendars(token)` → `DropdownButton` avec les calendriers disponibles (id + summary). Stocké dans `planningPreferences.calendarId`.
  - Sauvegarde : `PlanningRepository.savePreferences()`.

- **`CalendarService`** — évolutions :
  - `listCalendars(token)` : GET `https://www.googleapis.com/calendar/v3/users/me/calendarList` avec scope `calendar.readonly`. Retourne `List<{id, summary}>`.
  - `_getCalendarToken()` : cache le token en session (`static String? _cachedToken`) pour éviter les re-authentifications successives.
  - `createEvent(...)` : utilise `calendarId` depuis les préférences (défaut `'primary'`).
  - Durée des événements : toujours calculée depuis les préférences (`durationMinutes`) plutôt que depuis la recette seule.

- **`PlanningScreen`** — évolutions :
  - Agrégation d'ingrédients : `_normIngKey()` normalise les accents et pluriels. `_mergeQty()` additionne les quantités compatibles. La liste de courses agrégée (bottom sheet) affiche pour chaque ingrédient la liste des recettes sources.
  - `_MealTile` : heure cliquable (`onTap` sur `CircleAvatar`) → `showTimePicker` → `PlanningRepository.updateMealTime()`.
  - Bouton calendrier individuel sur `_MealTile` (hors kebab menu).
  - Bouton export global calendrier dans l'AppBar : boucle sur tous les repas visibles et crée un événement par repas.
  - Menu kebab `_MealTile` : "Changer la recette" → `RecipePickerDialog` puis `updateMealRecipe()` ; "Vider le créneau" → `updateMealRecipe()` avec `recipeId: null, recipeTitre: 'Repas libre'`.

- **`TokenUsageScreen`** — ajout énergie estimée :
  - Formule : `estimatedWh = totalTokens * 0.0000003` (estimation approximative basée sur consommation GPU).
  - `_SummaryBanner` : affiche le total tokens + l'estimation en Wh ou mWh selon l'ordre de grandeur.

- **Sélection multiple `BookListScreen` / `RecipeListScreen`** :
  - Long press active `_isSelecting = true` + `_selected.add(id)`.
  - AppBar contextuelle : count, `select_all`, `delete_outline` (confirmation rouge).
  - `_batchDelete()` : appelle `BookRepository.deleteBook()` / `RecipeRepository.deleteRecipe()` en parallèle pour les ids sélectionnés.

### Mise à jour release (14/05/2026 — v0.13.5)

- **Collection Firestore `planned_meals`** :
  - Schéma : `uid: String`, `recipe_id: String?`, `recipe_titre: String`, `planned_at: Timestamp`, `duration_minutes: int`, `created_at: Timestamp`.
  - Indexation Firestore : requête `where('uid', isEqualTo: uid).orderBy('planned_at')`.

- **`PlannedMeal`** (`lib/features/planning/domain/planned_meal.dart`) :
  - Modèle immuable avec `fromFirestore(String id, Map data)` et `toFirestore()`.
  - Champ `id` non inclus dans `toFirestore()` (géré par Firestore).

- **`PlanningRepository`** (`lib/features/planning/presentation/planning_providers.dart`) :
  - `watchMeals()` : stream de `List<PlannedMeal>` filtré par uid, ordonné par `planned_at` asc.
  - `addMeal(PlannedMeal)` : ajoute dans `planned_meals` (id auto-généré).
  - `deleteMeal(String id)` : supprime le document.
  - Provider `planningRepositoryProvider` : `Provider<PlanningRepository?>` — `null` si utilisateur non connecté.
  - Provider `plannedMealsProvider` : `StreamProvider.autoDispose<List<PlannedMeal>>`.

- **`PlanningScreen`** (`lib/features/planning/presentation/planning_screen.dart`) :
  - `ConsumerWidget` — route `/planning`.
  - Groupement des repas par journée (date sans heure) via `Map<DateTime, List<PlannedMeal>>`.
  - `_DayHeader` : affiche la date formatée (intl), "Aujourd'hui" si date du jour, couleur primaire si aujourd'hui, atténuée si passé.
  - `_MealTile` : `Card` avec `CircleAvatar` affichant l'heure, titre, durée, bouton poubelle. Opacité 0.6 si passé. `onTap` → `context.push('/recipes/${meal.recipeId}')` si `recipeId != null`.
  - Suppression : dialogue de confirmation avec `DateFormat('d MMMM à HH:mm', 'fr')`.

- **`schedule_recipe_sheet.dart`** — évolutions :
  - `_ScheduleSheet` devient `ConsumerStatefulWidget` / `_ScheduleSheetState extends ConsumerState`.
  - Nouveau paramètre `String? recipeId` dans `showScheduleRecipeSheet()` et `_ScheduleSheet`.
  - Après `CalendarService.createEvent()` réussi : lit `FirebaseAuth.instance.currentUser?.uid` puis `ref.read(planningRepositoryProvider)?.addMeal(PlannedMeal(...))`.

- **Route `/planning`** dans `app_router.dart` : `AppRoutes.planning = '/planning'`, builder `PlanningScreen`.
- **Navigation** dans `app_shell.dart` : entrée `_NavDestination(AppRoutes.planning, Icons.calendar_month_outlined, 'Planning')` insérée entre Recherche et Brouillons dans `_destinations()`.

### Mise à jour release (13/05/2026 — v0.13.4)

- **`CalendarService`** (`lib/features/planning/services/calendar_service.dart`) :
  - Classe statique. Scope : `'https://www.googleapis.com/auth/calendar.events'`.
  - `_getCalendarToken()` : Web → `FirebaseAuth.signInWithPopup(GoogleAuthProvider()..addScope(scope))` → `OAuthCredential.accessToken`. Mobile/Desktop → `GoogleSignIn.instance.authorizationClient.authorizationForScopes()` puis `authorizeScopes()` si null.
  - `createEvent({titre, startTime, duration, description, reminderMinutes})` : POST `https://www.googleapis.com/calendar/v3/calendars/primary/events` avec header `Authorization: Bearer $token`. Corps JSON : `summary`, `description`, `start/end` en UTC ISO8601, `reminders.overrides` si `reminderMinutes > 0`. Lance `Exception` si statusCode ∉ {200, 201}.

- **`schedule_recipe_sheet.dart`** :
  - `showScheduleRecipeSheet(context, {titre, recipeId?, prepTimeMin, cookTimeMin, ingredients})`.
  - `_ScheduleSheet` — bottom sheet avec : sélecteur de date (`showDatePicker`, firstDate = aujourd'hui - 1j), sélecteur d'heure (`showTimePicker`), champ "Rappel" (TextField numérique, pré-rempli avec `prepTimeMin ?? 30`). Bouton "Ajouter à Google Calendar" → `_addToCalendar()`.
  - `_buildDescription()` : ligne préparation, ligne cuisson, section ingrédients avec `• nom (qty unité)`.

- **`CooklangPreview`** — ajout paramètre `VoidCallback? onSchedule` :
  - Dans `_buildSectionHeader(...)` de la section "Ingrédients" : `action:` devient une `Row` contenant `IconButton(calendar_month_outlined, 'Planifier')` + `IconButton(shopping_cart_outlined, 'Liste de courses')` si les callbacks respectifs sont non-null.

- **`recipe_detail_screen.dart`** : passe `onSchedule:` et `recipeId:` à `CooklangPreview` et `showScheduleRecipeSheet`.

- **Dépendances ajoutées** : `http: ^1.2.0` (POST Calendar API).



- **`DraftListScreen` — filtre par livre** :
  - Nouveau champ `String? _bookFilter` : `null` = tous, `''` = sans livre, sinon `bookId`.
  - Nouveau widget `_BookFilterBar` : barre horizontale de `FilterChip`s construite à partir des `bookId` distincts présents dans la liste `myDrafts`. Chips : "Tous" (selected si `_bookFilter == null`), "Sans livre" (selected si `_bookFilter == ''`), puis un chip par livre distinct (titre récupéré depuis `BookRepository`). Barre invisible si 0 ou 1 livre distinct. Placée au-dessus du `MaterialBanner` dans le `Column` body.
  - Logique de filtrage appliquée dans le callback `data:` : renomme `myDrafts` en `myDraftsAll`, puis produit `myDrafts` filtré selon `_bookFilter` : `null` → `myDraftsAll`, `''` → recettes sans `bookId`, sinon → recettes dont `bookId == _bookFilter`.
  - Appel `setState(() => _bookFilter = ...)` depuis les callbacks `onSelected` des chips.

- **`RecipeListScreen` — suppression de livre depuis la liste** :
  - Nouvelle méthode `Future<void> _confirmDeleteBook(BuildContext context)` sur `_RecipeListScreenState`.
  - Dialogue `AlertDialog` avec 3 actions : "Annuler", "Détacher les recettes" (`_DeleteBookMode.detach`), "Supprimer aussi les recettes" (`_DeleteBookMode.deleteAll`).
  - Mode `detach` : appelle `BookRepository.deleteBook(bookId, detachRecipes: true)` — met `bookId = null` sur toutes les recettes du livre avant de supprimer le document livre.
  - Mode `deleteAll` : appelle `BookRepository.deleteBook(bookId, detachRecipes: false)` — supprime le livre et toutes ses recettes (requête `where('book_id', isEqualTo: bookId)`).
  - `IconButton` avec `Icons.delete_outline` ajouté dans `actions` de l'AppBar, visible uniquement si `inBookContext && canEdit`.
  - Après suppression : `context.go('/')` + `ScaffoldMessenger.showSnackBar` avec message de confirmation.
  - `enum _DeleteBookMode { detach, deleteAll }` ajouté en bas du fichier.

### Mise à jour release (13/05/2026 — v0.12.85)

- **`DraftReviewScreen` — onglet "Photos"** :
  - Nouveau widget `_IllustrationsTab` : affiche `recipe.imageUrls` dans une `GridView.builder` (crossAxisCount: 3).
  - `_IllustrationCard` : affiche l'image via `CachedNetworkImage` avec un `IconButton` de suppression (visible si `isOwner`). La suppression appelle `RecipeRepository.updateRecipeIllustrations()` pour retirer l'URL du tableau `image_urls`.
  - Bouton "Extraire les illustrations" / "Ré-extraire" : visible si `isOwner && recipe.sourceFileUrl != null && !sourceFileUrl.endsWith('.pdf')`. Appelle `_doExtractIllustrations()`.
  - `_doExtractIllustrations()` : télécharge le fichier source via `http.get(sourceFileUrl)`, appelle `GeminiService.detectIllustrationRegions(bytes, mimeType)`, découpe chaque bounding box avec `img.copyCrop`, uploade chaque crop sous `illustrations/{uid}/{timestamp}_ill_{i}.jpg`, puis appelle `RecipeRepository.updateRecipeIllustrations(recipeId, newUrls)`.
  - Onglet ajouté au `TabController` (index 3 en mode large, index 4 en mode étroit).

- **`DraftReviewScreen` — bouton IA dans AppBar** :
  - `IconButton` avec `Icons.auto_awesome` dans les `actions` de l'AppBar, visible uniquement si `isOwner`.
  - Pendant le raffinage (`_aiRefining == true`), remplacé par `CircularProgressIndicator`.
  - Appelle `_showRefineDialog(recipe)` : `AlertDialog` avec `TextField` (instructions libres) + `CheckboxListTile` "Extraire les illustrations" (visible si scan image disponible).
  - `_doRefine()` : appelle `GeminiService.refineRecipe(currentCooklang, instructions)`, met à jour `_cooklangCtrl.text`, titre et ingrédients dans le formulaire.
  - Si la case est cochée : `_doExtractIllustrations()` lancée en parallèle.
  - `isOwner` contrôle la visibilité : bouton IA, bouton supprimer, bouton valider (propriétaire) vs bouton copier (non propriétaire).

### Mise à jour release (13/05/2026 — v0.12.84)

- **Collection Firestore `ai_usage`** :
  - Schéma : `uid: String`, `feature: String`, `input_tokens: int`, `output_tokens: int`, `total_tokens: int`, `model: String`, `timestamp: Timestamp` (serverTimestamp).
  - `feature` values : `scan_extraction`, `detect_illustrations`, `search`, `generate`, `refine`, `book_scan`, `recipe_generation`, `chat_refine`.

- **`TokenUsageRepository`** :
  - `logUsage({uid, feature, inputTokens, outputTokens, totalTokens, model})` : ajoute un document dans `ai_usage` avec `FieldValue.serverTimestamp()`.
  - `watchByUser(uid)` : stream ordonné par `timestamp desc`, limit 500.
  - `watchAll()` : stream admin, limit 1000.
  - `static aggregate(records, {filterUid?})` : groupe par `(uid, feature)`, retourne `List<TokenUsageSummary>` triée par total décroissant.

- **`TokenUsageScreen`** :
  - Route `/usage` accessible depuis le menu compte (icône `bar_chart`).
  - `_SummaryBanner` : total appels, total tokens (entrée + sortie).
  - `_FiltersRow` : `DropdownButton` feature + (admin) `DropdownButton` utilisateur.
  - `_SummaryTable` : `DataTable` colonnes : fonctionnalité, appels, tokens entrée, tokens sortie, total. Tri par total décroissant. Formatage avec séparateur milliers.
  - Providers : `myTokenUsageProvider` (user), `allTokenUsageProvider` (admin).

- **Intégration dans `GeminiService`** : chaque appel Gemini (extraction, détection, recherche, génération, raffinement) appelle `TokenUsageRepository.logUsage()` avec les `usageMetadata.inputTokenCount` / `outputTokenCount` de la réponse.

### Mise à jour release (13/05/2026 — v0.12.74)

- **`WorkQueueScreen`** (`lib/features/recipes/presentation/drafts/work_queue_screen.dart`) :
  - Remplace les anciens écrans `DraftListScreen` et `ProcessingJobsScreen` séparés.
  - Sealed class `_QueueItem` : `_JobItem(ProcessingJob)` et `_DraftItem(Recipe)` — modèle unifié pour la liste.
  - `_Section` : regroupe les items par owner uid, avec flag `isCollapsed`.
  - `_FilterMode` enum : `me`, `family`, `allUsers`.
  - `_buildSections()` : fusionne jobs et brouillons, trie par date décroissante, regroupe par owner si famille/admin.
  - `isVisible(ProcessingJob)` : un job `queued`/`processing` n'est affiché que **tant qu'il n'a produit aucun brouillon** (`createdRecipeIds.isEmpty`) — au-delà, le `_DraftItem` le représente et une seule ligne subsiste pour un import. Les statuts `error` et `rejected` restent visibles inconditionnellement, brouillon produit ou non.
  - **Sélection multiple** : `Set<String> _selected` avec clés `'j:{jobId}'` ou `'d:{recipeId}'`. Actions groupées : `_batchValidate()`, `_batchRetry()`, `_batchDelete()`.
  - **Providers utilisés** : `processingJobsProvider`, `draftsProvider`, `groupMemberDraftsProvider`, `allProcessingJobsProvider`, `allDraftsProvider`, `isAdminProvider`.
  - Route `/work-queue` (remplace `/drafts` et `/processing-jobs`).

### Mise à jour release (12/05/2026 — v0.12.67)

- **`ImageEnhancerScreen` — détection automatique des coins** : à l'ouverture, `_runAutoDetect()` est appelée automatiquement. Elle lance `compute(_detectCornersIsolate, _DetectParams)` dans un isolate Dart dédié. Algorithme en 8 étapes :
  1. Décodage et redimensionnement à max 512 px (`img.copyResize`).
  2. Conversion niveaux de gris (`img.grayscale`).
  3. Calcul de la magnitude du gradient Sobel 3×3 sur chaque pixel.
  4. Seuil adaptatif = 85e percentile des magnitudes (borné à [5%, 60%] du max).
  5. Scan depuis les 4 bords (marge 8%) : pour chaque colonne/ligne, premier pixel dépassant le seuil.
  6. Élimination des outliers (trim 10%–90% par coordonnée projetée).
  7. Régression PCA sur chaque nuage → 4 droites en forme générale `(px·x + py·y = r)`.
  8. Intersections (règle de Cramer) → 4 coins ; validation convexité.
  - Retourne `null` si < 10 points détectés sur un bord ou si quadrilatère non convexe → corners par défaut conservés.
  - Indicateur visuel : `LinearProgressIndicator` orange en haut de l'image + bouton ⊕ (`center_focus_strong_outlined`) pour relance manuelle.
  - Nouvelles classes/fonctions top-level : `_DetectParams`, `_detectCornersIsolate`, `_dcSobel`, `_dcTrim`, `_Line2D`, `_dcFitLine`, `_dcIntersect`, `_dcIsConvex`.
  - Nouveau flag d'état : `bool _detecting` dans `_ImageEnhancerScreenState`.

- **`DraftListScreen` — sélection batch** :
  - Nouveau champ `Set<String> _selected` sur l'état.
  - `get _isSelecting` : actif quand `_selected` non vide.
  - Long press sur `_DraftTile` → `_selected.add(id)` → rebuild AppBar.
  - AppBar contextuelle : bouton ✕ (cancel), count badge, `select_all` (tout sélectionner/désélectionner), `check_circle` (valider), `delete_outline` (supprimer).
  - Valider : dialogue de confirmation → `recipeRepo.validateDraft()` pour chaque id sélectionné en parallèle.
  - Supprimer : dialogue de confirmation (rouge) → `recipeRepo.deleteRecipe()`.
  - `_DraftTile` : paramètres `isSelected`, `isSelecting`, `onTap`, `onLongPress` ajoutés. En mode sélection, le leading affiche une `Checkbox` à la place de l'avatar.
  - FAB masqué pendant la sélection (`if (!_isSelecting) FloatingActionButton`).
  - Les brouillons des membres du groupe n'ont pas de callback `onLongPress` (non sélectionnables).

- **`GeminiService._ingredientKey()` / `Recipe._ingredientKey()`** : normalisation des apostrophes typographiques (`'`, `'` → `'`) et des caractères accentués français (é,è,ê→e ; à→a ; ç→c ; ù→u ; ô→o ; î→i ; â→a ; û→u) avant `toLowerCase()` et trimming des pluriels, pour éviter les doublons d'ingrédients dus aux variantes Unicode retournées par Gemini.

### Mise à jour release (12/05/2026)

- **`ProcessingJob`** : ajout de deux champs :
  - `additional_file_urls: List<String>` — URLs Firebase Storage des pages supplémentaires (scan multi-pages).
  - `current_step: String?` — étape courante du traitement ("Extraction du texte…", "Extraction des illustrations…") affichée dans `ProcessingJobsScreen`.
- **`GeminiService.extractRecipes(bytes, mimeType, {additionalPages})`** : signature étendue pour envoyer plusieurs pages en un seul appel `Content.multi([DataPart, ..., TextPart])`.
- **`GeminiService.detectIllustrationRegions(bytes, mimeType)`** : nouvelle méthode — détecte les bounding boxes de photographies culinaires dans une image de recette. Retourne `List<[yMin, xMin, yMax, xMax]>` en coordonnées 0-1000. Utilise `image: ^4.8.0` pour le découpage (`img.copyCrop`).
- **`ScanStatus.pendingFiles`** : nouvel état d'accumulation multi-pages. L'utilisateur accède à cet état après la première sélection d'image pour recette. `isRunning` ne l'inclut pas (l'utilisateur est en contrôle).
- **`ScanState.pendingPageNames: List<String>`** : noms des fichiers en attente, pour affichage dans `ScanScreen`.
- **`ScanUploadNotifier.addPage()`** / **`addPageFromCamera()`** / **`processPages()`** : nouvelles méthodes pour le mode multi-pages.
- **`RecipeRepository.updateRecipeIllustrations(recipeId, imageUrls)`** : met à jour le champ `image_urls` d'une recette après extraction des illustrations.
- **`source_viewer.dart`** : bouton téléchargement ajouté (`url_launcher: ^6.3.1`) à côté du bouton prévisualisation.
- **`RecipeCreateScreen`** : lors d'un traitement IA ("Mettre en forme avec l'IA"), le texte original collé est uploadé sur Firebase Storage (`scans/{uid}/texte_colle_{ts}.txt`) et attaché comme `sourceFileUrl`/`sourceFileName` lors de la sauvegarde.

### Mise à jour release (08/05/2026)

- **`RecipeRepository.copyRecipeAsDraft({recipe, newOwnerUid})`** : crée une copie d'une recette ou d'un brouillon pour un autre utilisateur. Si la recette source est `validated`, la copie est également `validated` et le contenu provient de `rawCooklang`. Si la source est un brouillon, la copie est `draft` et le contenu provient de `draftCooklang ?? rawCooklang`. Les images ne sont pas copiées (`imageUrls: []`), le livre source n'est pas hérité (`bookId: null`).
- **`RecipeRepository.watchDraftsByOwners(List<String> ownerIds)`** : stream de brouillons (`draft` + `inReview`) pour une liste de propriétaires, filtré côté client.
- **`RecipeRepository.validateDraft()`** : vérification d'appartenance avant écriture — lit `created_by` depuis Firestore et lève `StateError` si le caller n'est pas le propriétaire.
- **`groupMemberDraftsProvider`** (Riverpod `StreamProvider`) : stream des brouillons des membres du groupe via `watchDraftsByOwners(memberIds)`.
- **`DraftReviewScreen`** : refactorisé en `ConsumerStatefulWidget`. Toggle 👥 dans l'AppBar pour afficher les brouillons des membres du groupe, organisés par sections collapsibles par membre (`_MemberSectionHeader`). Affichage auteur (icône 👤 + nom) et livre source dans l'AppBar pour les recettes d'autrui. Bouton "Copier" (📋) visible uniquement si non-propriétaire ; boutons Valider/Supprimer uniquement si propriétaire.
- **`RecipeDetailScreen`** : bouton "Copier" (📋) dans l'AppBar pour les recettes d'autrui. Dialogue de confirmation, puis redirection automatique vers la copie.
- **`KassDalleCoverGenerator`** (`lib/core/utils/kassdale_cover_generator.dart`) : génère une image PNG 600×800 avec `dart:ui` (gradient sombre, étoiles, sparkles, texte centré). Utilisé par `BookRepository._uploadGeneratedCover()`.
- **`BookRepository.findOrCreateKassDalleBook(uid)`** : retrouve ou crée le livre IA (`tag __kassdale_ia`), déclenche `_uploadGeneratedCover` si la couverture est absente.
- **`BookRepository.ensureKassDalleBookHasCover(uid)`** : migration silencieuse appelée dans `initState` de `BookListScreen`.

### Mise à jour release (03/05/2026)

- Ajout de la collection Firestore `groups` pour les groupes familiaux multi-utilisateurs.
- Nouveau domaine `FamilyGroup` (id, name, ownerId, memberIds, createdAt) + `GroupRepository` (watchMyGroups, createGroup, addMember, removeMember, renameGroup, deleteGroup, searchUsers).
- Providers Riverpod : `myGroupsProvider`, `groupMemberIdsProvider`, `visibleUserIdsProvider` pour le calcul de visibilité cross-utilisateur.
- `BookRepository.watchValidatedBooksByOwners(List<String>)` + `RecipeRepository.watchUnattachedByOwners(List<String>)` : requêtes `whereIn created_by` avec filtrage client-side pour éviter les index composites.
- `book_providers` : `groupMemberBooksProvider`, `accessibleBooksProvider` (union mes livres + livres des membres).
- `recipe_providers` : `groupMemberUnattachedRecipesProvider`.
- `BookListScreen` et `RecipeListScreen` convertis en `ConsumerStatefulWidget` avec sections par propriétaire et toggles.
- `ProcessingJobRepository.watchAll()` + `allProcessingJobsProvider` + `adminJobUserFilterProvider` + `filteredAdminJobsProvider`.
- `ProcessingJobsScreen` : vue admin avec filtre utilisateur (dropdown) et affichage du propriétaire sur chaque tuile `_JobTile` (ConsumerWidget).
- `GroupsScreen` : gestion complète des groupes (créer, renommer, supprimer, inviter/retirer membres via recherche temps réel).
- Route `/groups` ajoutée dans `AppRouter`. Accès depuis le menu compte.
- `app_shell.dart` : bouton "Télécharger l'APK Android" dans le menu compte (visible uniquement web/desktop), pointe vers `/app-release.apk` sur Firebase Hosting.
- L'APK est désormais inclus dans chaque déploiement Firebase Hosting.

### Mise a jour release (02/05/2026)

- Ajout d'un pipeline de traitements asynchrones avec collection Firestore `processing_jobs`.
- Refactor du scan pour supporter trois intentions : `recipeScan`, `bookCoverScan`, `bookDocumentScan`.
- Ajout de la creation de brouillons livre via extraction Gemini sur page de garde.
- Ajout d'un ecran de suivi des jobs de traitement et d'un indicateur de jobs actifs dans l'UI Brouillons.
- Extension du schema `books` (statut de revue, metadonnees structurees, source IA).
- Extension du flux de validation recette pour accepter les editions de champs structures (tags/temps/portions/ingredients).

### Mise a jour release (01/05/2026)

- Signature Android release activee via `android/key.properties` et `signingConfigs.release`.
- Configuration Firebase Android mise a jour avec `google-services.json` incluant les clients OAuth Android.
- Build targets validates pour release: Windows (`flutter build windows --release`), Web (`flutter build web --release --base-href /`), Android (`flutter build apk --release`).
- Pipeline d'icones automatise via `flutter_launcher_icons` depuis `assets/icon.jpg` pour Android, iOS, Web, Windows et macOS.
- Correctif de cycle de vie Flutter/Riverpod sur l'ecran de scan (suppression d'un acces `ref` apres `dispose`).

---

## 1. Architecture Générale

```
┌─────────────────────────────────────────────────────────────┐
│                        Clients Flutter                       │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│   │   Mobile     │  │     Web      │  │    Desktop       │  │
│   │ iOS/Android  │  │   Browser    │  │  Windows/macOS   │  │
│   └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘  │
└──────────┼─────────────────┼────────────────────┼────────────┘
           │                 │                    │
           └─────────────────┼────────────────────┘
                             │ Firebase SDK (FlutterFire)
           ┌─────────────────▼────────────────────────────────┐
           │                  Firebase Backend                  │
           │                                                    │
           │  ┌─────────────┐  ┌─────────────┐  ┌──────────┐  │
           │  │ Firebase    │  │  Firestore  │  │ Firebase │  │
           │  │    Auth     │  │     DB      │  │ Storage  │  │
           │  │ (Google     │  │  (recettes, │  │ (images) │  │
           │  │  Sign-In)   │  │  livres,    │  │          │  │
           │  └─────────────┘  │  users)     │  └──────────┘  │
           │                   └─────────────┘                 │
           └──────────────────────────────────────────────────┘
                             │
           ┌─────────────────▼────────────────────────────────┐
           │              Google AI (Gemini)                    │
           │        gemini-1.5-flash (Vision + Text)           │
           └──────────────────────────────────────────────────┘
```

---

## 2. Stack Technique

| Composant | Technologie | Version cible |
|---|---|---|
| Framework UI | Flutter | ≥ 3.22 |
| Langage | Dart | ≥ 3.4 |
| Authentification | Firebase Auth + Google Sign-In | FlutterFire latest |
| Base de données | Cloud Firestore | FlutterFire latest |
| Stockage fichiers | Firebase Storage | FlutterFire latest |
| IA / OCR | Google Generative AI SDK (Gemini 1.5 Flash) | `google_generative_ai` latest |
| Parsing Cooklang | `cooklang` (package Dart) | latest compatible |
| State management | Riverpod | ≥ 2.5 |
| Navigation | go_router | ≥ 14 |
| Image (mobile) | `image_picker` + `image_cropper` | latest |
| Éditeur code | `flutter_code_editor` ou `re_editor` | latest |

---

## 3. Schéma de Données Firestore

### Vue d'ensemble

```
firestore/
├── users/
│   └── {uid}/
├── books/
│   └── {bookId}/
├── recipes/
│   └── {recipeId}/
│       └── annotations/
│           └── {annotationId}/
├── processing_jobs/
│   └── {jobId}/
├── groups/
│   └── {groupId}/
├── ai_usage/
│   └── {usageId}/
├── planned_meals/
│   └── {mealId}/
└── planning_config/
    └── {uid}/
```

---

### 3.1 Collection `users`

Créée automatiquement à la première connexion Google.

| Champ | Type | Description |
|---|---|---|
| `uid` | `String` | UID Google Firebase (= ID du document) |
| `email` | `String` | Adresse email du compte Google |
| `display_name` | `String` | Nom d'affichage Google |
| `photo_url` | `String?` | URL de l'avatar Google |
| `role` | `String` | Enum : `admin` \| `editor` \| `reader` |
| `created_at` | `Timestamp` | Date de première connexion |
| `last_seen_at` | `Timestamp` | Date de dernière connexion active |
| `is_revoked` | `Boolean` | `true` si l'accès a été révoqué par un Admin |

**Règle de bootstrap :** lors de la création du premier document `users`, le rôle est automatiquement forcé à `admin` via une Cloud Function ou une logique client protégée par une transaction Firestore vérifiant que la collection `users` est vide.

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
| `thumbnail_urls` | `List<String>` | Vignettes WebP 400 px générées côté serveur, **même ordre que `image_urls`**. Vide sur les anciens enregistrements : l'UI retombe alors sur `image_urls` |
| `review_status` | `String` | Enum : `draft` \| `in_review` \| `validated` |
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
| `ingredients` | `List<Map>` | Liste structurée `{name, qty, unit, category?}` — cf. « Contrat ingrédient » |
| `page_type` | `String?` | `recipe` \| `technique` \| `equipment` \| `ingredient_note` \| `other`. **Écrit uniquement s'il vaut autre chose que `recipe`** ; à défaut, les lecteurs se rabattent sur `>> page_type:` dans `raw_cooklang` |
| `shopping_products` | `List<Map>` | Produits d'achat consolidés `{name, qty, unit}`, écrits par `onRecipeWritten`. Absent tant qu'aucun calcul n'a eu lieu |
| `nutrition` | `Map?` | Snapshot nutritionnel calculé côté backend (totaux, par portion, per100g, qualité, ingrédients manquants) |
| `nutrition_validation` | `Map?` | Diagnostic de la dernière synchronisation nutrition (état, quantités invalides, unités inconnues) |
| `nutrition_stale` | `bool?` | Levé par la normalisation quand un enrichissement a rempli des `per100g` sans que les ingrédients changent ; lu puis éteint par `onRecipeWritten`. Jamais écrit ni lu par le client |
| `nutrition_enrichment_attempts` | `int?` | Passages d'enrichissement consommés pour la liste d'ingrédients courante (3 au plus). Remis à 1 dès que les ingrédients changent. Borne le rattrapage d'un ingrédient que l'IA n'arrive pas à estimer, sans laisser le déclencheur se relancer sans fin |
| `source_recipe_id` | `String?` | Recette d'origine quand ce document est une copie/amélioration. Nul pour un brouillon issu d'un scan |
| `import_version` | `String?` | Version de l'app utilisée lors de l'import (ex : `'0.13.53'`) |

**Écrivain unique pour `ingredients_index`.** Il se construit par
`buildIngredientsIndex(ingredients)` — `cooklang_parser.dart` côté Dart,
`cooklang/parser.ts` côté Functions — et par rien d'autre. Trois chemins de
sauvegarde le fabriquaient autrefois différemment (noms normalisés par le
référentiel, noms bruts du CookLang, noms du formulaire sans mise en
minuscules) : la même recette n'était pas indexée de la même façon selon la
manière dont elle avait été enregistrée, et la recherche par ingrédient
répondait en conséquence. Cas de test partagés dans
`test-fixtures/cooklang_parsing.json`, clé `index`.

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
| `file_url` | `String` | URL Firebase Storage du fichier source |
| `mime_type` | `String?` | MIME detecte du fichier |
| `book_id` | `String?` | Livre cible pour rattachement recettes |
| `book_titre` | `String?` | Titre denormalise du livre cible |
| `created_recipe_ids` | `List<String>` | IDs des brouillons recettes crees. **Écrit dès la création de chaque brouillon**, pas à la fin du job : la normalisation des référentiels qui suit dure jusqu'à 7 min, et la file de travail masque un job dès qu'il a produit un brouillon (sauf `error` / `rejected`). |
| `created_book_id` | `String?` | ID du brouillon livre cree |
| `error_message` | `String?` | Message d'erreur si statut `error`, ou raison du rejet si statut `rejected` |
| `additional_file_urls` | `List<String>` | URLs Storage des pages supplémentaires (multi-pages) |
| `current_step` | `String?` | Étape courante du traitement IA |

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

### 3.6 Structure Firebase Storage

```
gs://{bucket}/
├── covers/
│   └── {bookId}/
│       └── cover.jpg
├── scans/
│   └── {uid}/
│       ├── {timestamp}_{filename}.jpg  (scan original)
│       └── texte_colle_{timestamp}.txt  (texte original collé depuis IA)
├── illustrations/
│   └── {uid}/
│       └── {timestamp}_ill_{i}.jpg  (photo culinaire extraite automatiquement)
└── recipes/
    └── {recipeId}/
        ├── scan_1.jpg
        └── ...
```

Les images sont uploadées avant l'appel Gemini. Les URLs de téléchargement Firebase sont stockées dans `recipes.image_urls`.

---

## 4. Firebase Security Rules

### Modèle d'autorisation : le rôle dans le jeton, la révocation dans le document

Le rôle et la révocation vivent à **deux endroits** : le document `users/{uid}`
et les custom claims du jeton, tenus à jour par le déclencheur `syncUserClaims`
(et amorcés en masse par `backfillUserClaimsFn`). Ce n'est pas une duplication
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
avait cassé l'import.

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

    function hasRole(role) {
      return isAuthenticated() && (
        tokenHasRole()
          ? request.auth.token.role == role
          : getUserData().role == role
      );
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

    function isReader() {
      return isAuthenticated() && !isRevoked();
    }

    function isOwner(uid) {
      return isAuthenticated() && request.auth.uid == uid;
    }

    // Collection users
    match /users/{uid} {
      allow read: if isAuthenticated() && (request.auth.uid == uid || isAdmin());
      allow create: if isAuthenticated() && request.auth.uid == uid;
      allow update: if isAdmin() || (isAuthenticated() && request.auth.uid == uid
                      && !request.resource.data.diff(resource.data).affectedKeys()
                         .hasAny(['role', 'is_revoked']));
      allow delete: if isAdmin();
    }

    // Collection books
    match /books/{bookId} {
      allow read: if isReader();
      allow create, update, delete: if isEditor();
    }

    // Collection recipes
    match /recipes/{recipeId} {
      // Les brouillons ne sont visibles que par editors/admins
      allow read: if isReader() &&
        (resource.data.review_status == 'validated' || isEditor());
      allow create, update: if isEditor();
      allow delete: if isAdmin();

      // Annotations
      match /annotations/{annotationId} {
        allow read: if isReader();
        allow create: if isAuthenticated() && !getUserData().is_revoked;
        allow update, delete: if isOwner(resource.data.uid) || isAdmin();
      }
    }
  }
}
```

### Firebase Storage Rules

```javascript
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {

    function isAuthenticated() {
      return request.auth != null;
    }

    // Couvertures de livres
    match /covers/{bookId}/{fileName} {
      allow read: if isAuthenticated();
      allow write: if isAuthenticated()
        && request.resource.size < 10 * 1024 * 1024   // max 10 MB
        && request.resource.contentType.matches('image/.*');
    }

    // Scans de recettes
    match /recipes/{recipeId}/{fileName} {
      allow read: if isAuthenticated();
      allow write: if isAuthenticated()
        && request.resource.size < 20 * 1024 * 1024   // max 20 MB
        && request.resource.contentType.matches('image/.*');
    }
  }
}
```

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
    │                   ┌────┴────────────────────────────┐
    │                   │ Nouveau ?                        │
    │                   │ → Créer document users/{uid}     │
    │                   │   role = 'reader'                │
    │                   │   (ou 'admin' si premier compte) │
    │                   └─────────────────────────────────┘
    │                        │
    └─ Connecté ──────────── ▼
                        Charger profil + rôle
                             │
                             ▼
                        Router selon rôle
```

### Bootstrap Admin

La logique de détection du "premier utilisateur" est implémentée via une **transaction Firestore** :

```dart
// Pseudo-code Dart
await firestore.runTransaction((tx) async {
  final usersCount = await firestore.collection('users').count().get();
  final role = usersCount.count == 0 ? 'admin' : 'reader';
  tx.set(firestore.collection('users').doc(uid), {
    'uid': uid,
    'role': role,
    // ...autres champs
  });
});
```

---

## 6. Intégration Gemini — Passe Unique Structurée

### Principe

Un seul appel API à `gemini-1.5-flash` avec les images en entrée. La réponse est un objet JSON structuré contenant le Cooklang et les métadonnées extraites.

### Prompt Système (system instruction)

```
Tu es un assistant spécialisé dans la numérisation de recettes de cuisine.
On te fournit une ou plusieurs photos d'une page de recette.
Tu dois extraire le contenu et le retourner EXCLUSIVEMENT sous forme d'un objet JSON valide,
sans texte supplémentaire avant ou après le JSON.
```

### Prompt Utilisateur

```
Analyse cette/ces image(s) de recette et retourne un JSON avec exactement cette structure :

{
  "titre": "Nom de la recette",
  "langue": "code ISO 639-1 (ex: fr, it, nl, en)",
  "cooklang": "Contenu complet de la recette au format Cooklang",
  "tags": {
    "themes": ["liste", "de", "thèmes"],
    "cuisines": ["type", "de", "cuisine"],
    "difficulty": "easy | medium | hard",
    "prep_time": <entier en minutes ou null>,
    "cook_time": <entier en minutes ou null>
  }
}

Règles pour le Cooklang :
- Les ingrédients sont balisés : @nom_ingrédient{quantité%unité}
- Le matériel est balisé : #nom_ustensile{}
- Les timers sont balisés : ~nom_timer{durée%unité}
- Chaque étape est un paragraphe séparé
- Le titre n'est PAS inclus dans le corps Cooklang (il est dans le champ "titre")
- Respecte la langue originale de la recette
```

### Gestion de la réponse

```dart
// Pseudo-code Dart
final response = await geminiModel.generateContent([
  Content.multi([
    TextPart(userPrompt),
    ...imageUrls.map((url) => DataPart('image/jpeg', imageBytes)),
  ])
]);

final jsonString = response.text!
    .replaceAll('```json', '').replaceAll('```', '').trim();
final Map<String, dynamic> parsed = jsonDecode(jsonString);

final draftRecipe = RecipeDraft.fromGeminiJson(parsed);
// → Naviguer vers l'écran de révision split view
```

### Gestion des erreurs Gemini

| Cas | Comportement |
|---|---|
| JSON malformé | Afficher l'éditeur brut avec le texte retourné, inviter à corriger manuellement |
| Champ `cooklang` vide ou absent | Afficher un message d'erreur et permettre une re-tentative ou une saisie manuelle |
| Timeout / erreur réseau | Retry automatique x2, puis message d'erreur avec option de saisie manuelle |
| Image illisible | Gemini retourne un texte d'explication — détecter l'absence de JSON et basculer en mode manuel |

---

## 7. Parsing et Rendu Cooklang

### Parsing

Utilisation du package Dart `cooklang` pour analyser le texte brut :

```dart
final recipe = CooklangRecipe.parse(rawCooklang);
// → recipe.ingredients : List<Ingredient>
// → recipe.steps : List<Step>
// → recipe.cookware : List<Cookware>
```

Le champ `ingredients_index` stocké en Firestore est dérivé du parsing :
```dart
final ingredients = recipe.ingredients
    .map((i) => i.name.toLowerCase().trim())
    .toList();
// Stocké dans recipes.ingredients_index pour la recherche Firestore
```

### Rendu Interactif

Le rendu Cooklang est construit en widgets Flutter :
- Chaque `Ingredient` est affiché avec sa quantité, unité et nom.
- Dans les instructions, les références aux ingrédients sont colorisées (chips inline).
- Les références au matériel sont différenciées visuellement.
- Les timers sont affichés avec une icône et peuvent déclencher un compte à rebours (V2).

---

## 8. Écran de Révision — Split View

### Layout

```
┌────────────────────────────────────────────────────────────┐
│  AppBar : [← Retour]  [Titre éditable]  [Brouillon] [✓ Valider] │
├───────────────────────────┬────────────────────────────────┤
│  ÉDITEUR COOKLANG (brut)  │  RENDU INTERACTIF             │
│                           │                                │
│  @oeufs{3}                │  Ingrédients                  │
│  @farine{200%g}           │  • 3 oeufs                   │
│  ...                      │  • 200g de farine             │
│                           │  ...                           │
│  Mélanger les             │  Instructions                  │
│  @oeufs{3} avec la        │  1. Mélanger les oeufs avec   │
│  @farine{200%g}           │     la farine...               │
│                           │                                │
│  [Saisie responsive]      │  [Lecture seule]               │
├───────────────────────────┴────────────────────────────────┤
│  [Tags] [Page] [Langue]  [📷 Voir scan original]           │
└────────────────────────────────────────────────────────────┘
```

- Sur **Mobile** : les deux panneaux sont scrollables en mode column (l'éditeur en haut, le rendu en dessous) ou en tabs.
- Sur **Web / Desktop** : les deux panneaux sont côte à côte (Row), divisés par un splitter redimensionnable.
- Le rendu se met à jour en temps réel à chaque modification du texte Cooklang (debounce 300ms).

---

## 9. Application Desktop (Windows / macOS)

### Spécificités

- Construite depuis la même codebase Flutter avec le target `flutter build windows` / `flutter build macos`.
- Fenêtre principale redimensionnable, minimum 900×600px.
- Pas d'accès caméra (module scan désactivé conditionnellement : `if (Platform.isAndroid || Platform.isIOS)`).
- Import de fichier image possible via `file_picker` (pour importer des scans déjà faits).
- Raccourcis clavier dans l'éditeur Cooklang (Ctrl+S pour sauvegarder, Ctrl+Z pour annuler).
- Écran de révision split view en mode horizontal natif (pas de tabs).

### Build Desktop

```bash
# Windows
flutter build windows --release

# macOS
flutter build macos --release
```

---

## 10. Application Web

### Spécificités

- Construite avec `flutter build web --release`.
- Hébergée via **Firebase Hosting**.
- Pas d'accès caméra (module scan désactivé).
- Import de fichier image via `file_picker` (web file input).
- Responsive : adapté aux largeurs > 768px (tablette/desktop). En dessous, affichage dégradé ou message d'invitation à utiliser le mobile.
- Le split view est rendu en `Row` avec splitter.
- Authentification Google gérée via le SDK Firebase JS (FlutterFire Web).

### Build Web

```bash
flutter build web --release --base-href /
firebase deploy --only hosting
```

---

## 11. Application Mobile (iOS / Android)

### Spécificités iOS

- `NSCameraUsageDescription` dans `Info.plist`
- `NSPhotoLibraryUsageDescription` dans `Info.plist`
- Google Sign-In configuré via `GoogleService-Info.plist`

### Spécificités Android

- Permissions `CAMERA` et `READ_MEDIA_IMAGES` dans `AndroidManifest.xml`
- Google Sign-In configuré via `google-services.json`
- SHA-1 et SHA-256 enregistrés dans la Firebase Console

### Build Mobile

```bash
# Android
flutter build apk --release
flutter build appbundle --release

# iOS
flutter build ipa --release
```

---

## 12. Architecture Flutter (Couches)

```
lib/
├── main.dart
├── firebase_options.dart          # Généré par FlutterFire CLI
├── core/
│   ├── providers/                 # Riverpod providers globaux
│   ├── router/                    # go_router configuration
│   ├── theme/                     # Thème Material 3
│   └── utils/                     # Helpers (platform, debounce, etc.)
├── features/
│   ├── auth/
│   │   ├── data/                  # AuthRepository (Firebase Auth)
│   │   ├── domain/                # User model, rôles
│   │   └── presentation/          # LoginScreen, UserManagementScreen
│   ├── books/
│   │   ├── data/                  # BooksRepository (Firestore)
│   │   ├── domain/                # Book model
│   │   └── presentation/          # BookListScreen, BookFormScreen
│   ├── recipes/
│   │   ├── data/                  # RecipesRepository, GeminiService, StorageService
│   │   ├── domain/                # Recipe model, CooklangParser wrapper
│   │   └── presentation/
│   │       ├── scan/              # ScanScreen (mobile only)
│   │       ├── review/            # SplitReviewScreen
│   │       ├── detail/            # RecipeDetailScreen
│   │       └── list/              # RecipeListScreen
│   ├── annotations/
│   │   ├── data/                  # AnnotationsRepository
│   │   ├── domain/                # Annotation model
│   │   └── presentation/          # AnnotationSection widget
│   └── admin/
│       └── presentation/          # AdminScreen, UserRoleScreen
└── shared/
    └── widgets/                   # Widgets réutilisables (CooklangRenderer, TagChip, etc.)
```

---

## 13. Roadmap Technique V2

| Fonctionnalité | Complexité | Technologie envisagée |
|---|---|---|
| Extraction auto d'illustrations dans les scans | Élevée | Gemini Vision bounding boxes + découpe image côté client |
| Mode hors-ligne | Moyenne | Firestore offline persistence + Hive pour le cache Cooklang |
| Export PDF d'une recette | Moyenne | `pdf` package Dart |
| Partage externe (lien public) | Faible | Firebase Dynamic Links ou URL personnalisée |
| Timer interactif depuis Cooklang | Faible | Flutter Timer + notifications locales |
| Liste de courses depuis recette | Faible | Extraction `ingredients_index` + UI dédiée |
