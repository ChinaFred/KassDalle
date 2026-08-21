# Spécifications Techniques — Kass'dalle
## Livre de Cuisine Digital (Flutter + Firebase)

> Version : 2.2 — 2 Juin 2026

## Spécification technique — Modération des images

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
  Storage, rend l'URL de téléchargement, supprime la source.
- **`utils/uploadSecurity.ts` — `scanUpload()`** juge le contenant : taille, extension,
  type MIME, signature binaire, EICAR. Il ne regarde pas l'image.
- **`scans/{uid}/`** est déjà en `allow write: if false` : la promotion serveur est un
  schéma qui existe et qui marche. La modération le généralise, elle ne l'invente pas.

### 2. Les quatre écritures directes à faire passer par la quarantaine

| Chemin publié | Écrit aujourd'hui par | Règle actuelle |
|---|---|---|
| `covers/{bookId}/cover.jpg` | `book_repository.dart:160` | `canWriteSharedImages()` |
| `recipes/{recipeId}/…` | `recipe_repository.uploadRecipePhoto():610` | `canWriteSharedImages()` |
| `illustrations/{uid}/…` | `recipe_repository.uploadIllustration():595`, `draft_review_service.dart:207,229` | `isOwner(uid)` |
| `users/{uid}/free_recipe_cover_*.jpg` | `auth_repository.dart:212` | `isOwner(uid)` |

`book_repository._uploadAssetCover():176` écrit aussi dans `covers/`, mais depuis un asset
du bundle : c'est notre propre image, elle n'a rien à faire dans une file de modération.
La promotion serveur doit donc accepter une origine « asset » qui court-circuite l'analyse
— sans quoi chaque création de livre remplira la file.

**Cible** : ces quatre chemins passent en `allow write: if false`, comme `scans/`. Le
client écrit dans `quarantine/{uid}/`, appelle la fonction de promotion avec la
**destination voulue**, et reçoit soit l'URL publiée, soit un état d'attente.

C'est le lot le plus coûteux et le seul qui touche du code partout. Il est aussi le seul
qui ait une valeur propre : livré seul, sans aucune analyse, il ferme les portes et ne
change rien pour l'utilisateur.

### 3. Firestore — `image_moderation/{moderationId}`

| Champ | Type | Rôle |
|---|---|---|
| `status` | `string` | `approved` / `rejected` / `manual_review` / `pending` |
| `uid` | `string` | qui a envoyé |
| `quarantine_path` | `string` | où le fichier attend |
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

**`moderateAndPromote.ts` est le seul module qui décide si une image devient visible.**
Il vivait dans le callable, où seul un client pouvait l'emprunter — le pipeline
d'import, lui, écrivait ses découpes en direct avec l'Admin SDK, donc hors
quarantaine et hors verdict. L'extraire est ce qui permet aux deux appelants de
prendre le même chemin. Un second chemin de publication serait, tôt ou tard, un
chemin sans verdict.

Deux refus y sont des **erreurs typées** et non des verdicts : `ImageFormatRejected`
et `QuarantineFileMissing`. Le callable les rend au client en `HttpsError` ; le
pipeline écarte la découpe et poursuit l'import. C'est la raison pour laquelle le
cœur ne lève pas de `HttpsError` lui-même — il ne sait pas qui l'appelle.

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
froid payé partout. **Ne pas le repasser en import statique.**

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

- **`moderateAndPromoteImageFn`** (callable) — `{ quarantinePath, targetKind, ownerId }`.
  Vérifie que le chemin appartient à l'appelant, télécharge, `scanUpload()` (le format
  d'abord : inutile d'envoyer un exécutable renommé à un moteur d'analyse), puis
  `analyse()` → `decideModeration()` → écriture du document → promotion si `approved`.
  Rend `{ status, url?, reason }`.
- **`reviewModeratedImageFn`** (callable, `isAdmin`) — `{ moderationId, decision, note }`.
  Promeut ou marque refusée, écrit `reviewed_by` / `reviewed_at`, journalise.
- **`retryPendingModerationFn`** (callable, `isAdmin`) — relance les `pending` restés en
  panne de moteur. Un état qui ne se relance pas est une fuite.
- **Le poste `_batch`** — un scan promeut douze illustrations d'un coup. Le groupage est un
  poste à part entière (`image_moderation_batch`), comme ailleurs dans le projet : c'est le
  seul moyen de vérifier que le groupage fait son office.
- **`recipeProcessor`** (Cloud Tasks) emprunte le même cœur pour les illustrations qu'il
  découpe dans un scan. Trois filtres **locaux** (`gemini/illustrationQuality.ts`) écartent
  d'abord ce qui n'est manifestement pas une photographie — moins de 120 px de côté ou
  moins de 1,5 % de la page, rapport de forme au-delà de 4:1, ou presque blanc **et** sans
  couleur. Les deux conditions du dernier sont exigées ensemble : une photographie en noir
  et blanc a une chroma nulle, mais jamais une luminance moyenne de papier.
- **La vignette WebP n'est pas remodérée** : c'est la même image, réduite, et le verdict
  vient d'être rendu sur son contenu. La repasser au moteur doublerait la facture pour la
  même réponse.
- **Une page qui rend plusieurs recettes est modérée une fois, puis copiée.** Chaque recette
  au-delà de la première reçoit sa propre copie Storage (`copyPublishedImages`), pour qu'elle
  en soit réellement propriétaire — deux recettes désignant le même objet est une panne qui
  n'attend que la première suppression réelle du fichier. La copie est faite côté serveur et
  conserve les métadonnées de la décision ; un échec de copie retombe sur l'adresse partagée,
  journalisé.
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

`storage.rules` ouvre `rejected/` en lecture au seul `isAdmin()` — un nouvel
helper, distinct de `canWriteSharedImages()` : ce dossier contient précisément ce
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

- **`features/moderation/`** — `data/image_moderation_repository.dart`,
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

Déclaré dans `firestore.indexes.json`, déployé par `deploy.ps1` avec les règles. Le même
index sert les quatre filtres d'état, avec ou sans fenêtre de temps. Le badge n'en a pas
besoin : une égalité seule, sans tri, tient sur l'index automatique.

### 13. Tests

| Quoi | Où |
|---|---|
| Règles de décision, ordre compris | `functions/src/tests/moderationDecision.test.ts` + fixture |
| Violence + contexte culinaire → approuvée, sans file | même fixture, cas nommé |
| Sexuel explicite → refusée quel que soit le contexte | même fixture |
| Projection des cinq paliers Vision sur `0..1` | `functions/src/tests/visionSignals.test.ts` |
| Moteur en panne → `pending`, jamais publié | test de `moderateAndPromoteImage` |
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

### Mise à jour release (18/08/2026 — v0.20.28)

#### Maintien de l'écran allumé sur la fiche recette

- **`wakelock_plus: ^1.3.3`** (nouveau) — version retenue par la résolution : à partir de 1.6.1, wakelock_plus réclame `package_info_plus ^10.1.0` quand le projet est en `^8.0.0`. Monter l'un impose de monter l'autre — un autre chantier. Couvre Android, iOS, web et Windows ; aucune permission Android (le plugin pose `FLAG_KEEP_SCREEN_ON` sur la fenêtre, pas un `WakeLock` système).
- **`core/services/screen_wakelock.dart`** (nouveau) : `ScreenWakelock` avec `acquire()` / `release()` / `refresh()` et une instance partagée `ScreenWakelock.instance`. Le maintien est **compté**, pas booléen : deux écrans superposés le demandent chacun, et le verrou ne tombe qu'au dernier `release()`. Une libération de trop ne descend pas sous zéro — sinon la prochaine prise n'appliquerait rien.
- **`refresh()` existe parce que le verrou est révocable** : navigateurs et Android le relâchent au passage en arrière-plan sans le rendre. Sans reprise au `resume`, un appel téléphonique suffisait à éteindre l'écran pour le reste de la lecture.
- **`WakelockToggle` injectable** — `Future<void> Function({required bool enable})`, par défaut `WakelockPlus.toggle` : le comptage se vérifie sans plugin ni binding.
- **`mixin KeepScreenAwake<T extends StatefulWidget> on State<T>`** : `acquire()` en `initState`, `release()` en `dispose`, `AppLifecycleListener(onResume:)` pour la reprise. Mixé sur `_RecipeDetailScreenState` (`recipe_detail_screen.dart`), après `SingleTickerProviderStateMixin`.
- **Le maintien couvre toute la fiche, pas le seul `_mobileKitchenMode`** : les ingrédients, la nutrition et les commentaires se lisent aussi les mains occupées.
- **L'échec de plateforme est remonté une fois par session** (`reportUnexpectedError`, poste `screenWakelock.apply`, contexte `enable` + `holders`). Un refus vient de la plateforme — API absente, onglet en fond, navigateur qui refuse — et se reproduirait à chaque ouverture de recette : cent rapports identiques n'apprennent rien de plus que le premier et noient les autres. Ce n'est pas un `catch` silencieux, c'est un `catch` qui ne se répète pas.
- **Le client desktop Windows n'est pas concerné par la limite App Check** : le maintien ne passe par aucun appel serveur.
- **Tests** : `test/screen_wakelock_test.dart` — première prise seule appliquée, verrou conservé tant qu'un détenteur reste, libération excédentaire ignorée, reprise après arrière-plan, `refresh()` sans détenteur sans effet.

### Mise à jour release (17/08/2026 — v0.20.11)

#### Le conseil de conservation quitte le CookLang

- **`storage_text.dart` ne sait plus qu'effacer.** `buildStorageSection()` et `applyStorageSection()` sont supprimés ; restent `hasStorageSection()` et `removeStorageSection()`, qui servent au nettoyage de l'existant. Le conseil n'est plus persisté que dans `recipes/{id}.storage_advice`.
- **`hasStorageSection()` cherche le titre** au lieu de comparer les longueurs avant/après retrait. `removeStorageSection()` supprimant aussi les lignes vides finales, l'ancienne implémentation répondait vrai pour toute recette terminée par un saut de ligne — ce qui, branchée au nettoyage automatique, aurait déclenché une écriture Firestore sur presque chaque recette ouverte. Cas verrouillé dans `test/storage_text_test.dart`.
- **`StorageRepository`** : `applyToRecipe()` remplacé par `stripSection({recipeId, rawCooklang})`, qui n'écrit que si la section est présente et rend un booléen. `ensure({recipeId})` perd son rappel `loadRawCooklang` et se réduit à `read() ?? generate()`.
- **`recipe_detail_screen.dart` — `_stripLegacyStorageSection()`** : nettoyage opportuniste, une fois par recette et par session (`_strippedStorageIds`), conditionné à `canEdit` — un lecteur n'a pas le droit d'écrire et l'échec n'apprendrait rien. `updated_at` reste intact.
- **`batch_planning_screen._generateStorageAdvice()`** ne réécrit plus le CookLang ni ne recopie de recette dans `_slots` ; il produit et affiche.
- **`MealPrepBanner`** perd son paramètre `rawCooklang`.

### Mise à jour release (17/08/2026 — v0.20.10)

#### Contexte de préparation à l'avance porté par l'adresse de la recette

- **`features/planning/domain/meal_prep_context.dart`** (nouveau) : `MealPrepContext { prepDate, mealDate }`, avec `daysAhead`, `mode`, `isAhead` et `instruction` délégués à `meal_storage_rules.dart`. Sérialisation `toQueryParameters()` / `fromQueryParameters()` sous les clés `prep` et `meal`, au format `YYYY-MM-DD`. Une date illisible rend `null` : la fiche s'ouvre sans contexte plutôt qu'avec une date devinée.
- **Aucun stockage.** Le contexte n'est écrit ni sur `recipes/{id}`, ni sous `users/{uid}` : il suit la même voie que `portions`, en paramètre d'adresse, et meurt avec l'écran. Une recette est partagée et peut être planifiée à deux dates par deux membres du groupe.
- **`planning_screen.dart` — `_recipeLocationFor()`** construit désormais l'URL via `Uri(path:, queryParameters:)` et y joint `prep`/`meal` quand `meal.prepDate != null`.
- **`app_router.dart`** relit le contexte sur la route `/recipes/:recipeId` et le passe à `RecipeDetailScreen.prepContext`, propagé à `PrepareTab` (desktop) et `MobileUnifiedBody` (mobile) via le `topContent` de `CooklangPreview`.
- **`features/planning/presentation/meal_prep_banner.dart`** (nouveau) : `MealPrepBanner`, affiché uniquement si `prepContext.isAhead`. Partie haute calculée (`mealStorageInstruction`), partie basse produite par l'IA et dépliable. Trois états : chargement, panne (message + « Réessayer », la consigne calculée restant affichée), conseil disponible.
- **`StorageRepository.ensure({recipeId, loadRawCooklang})`** (nouveau) : `read` → `generate` si absent → `applyToRecipe` en best-effort avec `reportError('storage_advice_ensure_apply')`. `loadRawCooklang` est un rappel paresseux, appelé seulement quand il y a une section à recopier — relire la recette pour un conseil déjà stocké serait une lecture Firestore pour rien. `planning_screen._showStorageAdvice()` et le bandeau appellent tous deux cette méthode : la séquence n'existe plus qu'une fois.
- **`features/planning/presentation/storage_advice_details.dart`** (nouveau) : `StorageAdviceDetails` extrait de `storage_advice_sheet.dart`, partagé par la feuille du planning et le bandeau. Deux rendus divergents du même conseil auraient été une divergence invisible.
- **Aucun nouveau poste de coût** : le bandeau appelle `suggestStorageAdviceFn`, poste `storage_advice` déjà routable (`ROUTABLE_FEATURES`) et déjà au catalogue comptable.
- **Tests** : `test/meal_prep_context_test.dart` — aller-retour par les paramètres d'adresse, refus des dates partielles ou illisibles, franchissement de la limite réfrigérateur/congélateur.

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

##### Poids du couple ingrédient / unité

La même maladie touche une famille entière d'unités : `branche`, `brin`, `tige`,
`feuille`, `bouquet`, `filet`, `noisette`, `zeste`, `tranche`, `poignee`,
`morceau`, `gousse` (`INGREDIENT_DEPENDENT_UNITS`). Aucune n'a de poids propre —
une branche de thym pèse 1 g, une branche de céleri 60 — et la table intégrée
n'en donnait qu'une moyenne : `branche: 15 g`, soit 60 g pour quatre branches de
thym, soixante fois le poids réel.

Le référentiel d'ingrédients porte donc `grams_per_unit: { branche: 1 }`, indexé
par unité canonique. L'ordre de résolution, tenu par une seule fonction partagée
et asservi par `unit_to_grams.json` :

1. `grams_per_unit[unité]` de l'**ingrédient** — le poids du couple ;
2. `grams_per_piece` de l'ingrédient, quand l'unité est « pièce » ou absente ;
3. `volume_ml_per_unit` × densité, pour un volume ;
4. `grams_per_unit` du référentiel d'**unités**, pour un poids ;
5. la table intégrée, en dernier recours.

Le poste d'IA `estimate_unit_couple_weights` alimente le niveau 1 à la
normalisation, en ne demandant que les couples encore inconnus.

##### Ingrédients non consommés

`nutrition_ingredients.not_consumed` marque ce qui appartient à la recette mais
pas au repas : bain de friture, foin ou sarment de fumage, lit de gros sel,
marinade jetée. Un litre d'huile de friture apporte 8280 kcal — compté comme le
reste, il rend le total de la recette inutilisable.

##### Huile absorbée à la friture

Écarter le bain est juste, mais incomplet : ce qu'on y plonge en ressort plus
gras. Un poulet pané au panko absorbe environ 10 % de son poids en huile — sur
600 g, 55 g de lipides et 500 kcal que la recette ne déclarait nulle part. La
couverture affichait « complet » et le plat mentait de 40 % sur ses lipides.

Le taux n'appartient pas au bain. La quantité d'huile écrite dans une recette
est arbitraire (« 1 L pour la friture ») : en garder un pourcentage ferait
dépendre le résultat de la façon dont l'auteur a rédigé sa ligne. Le taux
appartient à l'**aliment frit** ; le bain déclaré sert de **plafond** — on
n'absorbe pas plus d'huile qu'il n'y en a — et de source de profil, puisque
c'est lui qui dit quelle huile est employée. À défaut, une huile végétale
générique (900 kcal, 100 g de lipides, 13 g de saturés pour 100 g).

Reste à savoir *ce qui* est frit : la liste d'ingrédients ne le dit pas — dans
un poulet pané, le poulet, la farine, l'œuf et la chapelure passent au bain, la
salade servie à côté non. Seul le texte de la recette le dit, d'où le poste
`estimate_fry_absorption`, qui rend les indices des ingrédients frits et le
pourcentage absorbé (borné à 30 %).

L'appel n'est demandé que si `looksFried()` — déterministe, gratuit,
`fryAbsorption.test.ts` — repère un signe de friture dans `raw_cooklang` ou dans
les noms d'ingrédients. La recherche se fait par mots entiers : « frit » en
sous-chaîne attrape « frittata », qui est une omelette. Une panure seule ne
déclenche rien, le four existe.

Le verdict vit dans le snapshot (`fry_verdict`, `fry_signature`) et se réutilise
tant que la liste d'ingrédients et le texte n'ont pas changé. Il est stocké
**séparément de son résultat** (`absorbed_oil`) : un poids d'ingrédient qui
devient connu entre deux calculs doit produire de l'huile sans redemander le
verdict.

L'huile absorbée entre dans les totaux **et dans le poids total** — elle est
mangée, donc elle pèse dans le dénominateur des valeurs pour 100 g. Elle
n'entre pas dans la couverture : ce n'est pas un ingrédient. L'écran la montre
comme une ligne dérivée, en italique et marquée « estimée », qui dit son taux et
le poids frit dont il découle ; le tableau, qui refait ses totaux depuis les
lignes, la compte comme le serveur — sans quoi son TOTAL contredirait les
calories par portion affichées juste au-dessus.

Elle se range **sous le bain dont elle sort** (`↳ dont absorbée`), reconnu par
`source_name`, et ne tombe en fin de tableau que si la recette ne liste aucun
corps gras écarté. Les deux lignes se lisent alors comme une seule idée : on
jette le litre, on mange les 55 g.

##### Quantité de repli des matières grasses de cuisson

« Huile pour graisser le fond du plat » n'a pas de quantité et n'en aura jamais :
c'est un geste, pas une pesée. Sans quantité, l'ingrédient sort du calcul — une
centaine de kilocalories manquantes que rien ne signale.

`defaultQuantityForMissing` applique donc, à la normalisation et **hors de toute
dépendance à l'IA**, une quantité de repli : 1 c.à.s. pour les huiles et corps
gras, 1 noisette pour le beurre et la margarine. La valeur est écrite dans la
recette (elle apparaît donc dans la liste d'ingrédients), pas seulement dans le
calcul.

La liste est délibérément courte. Une absence de quantité a souvent un sens : un
« poulet » listé sans quantité peut être l'intitulé d'une pièce dont la découpe
est chiffrée plus bas, et lui inventer un poids fausserait la recette entière.
Le repli ne couvre que les matières grasses de fond de plat ; `defaultQuantities.test.ts`
garde cette frontière dans les deux sens.

##### Lignes qui reprennent un ingrédient déjà listé

Une recette qui achète 1,5 kg de côte puis en dresse « 4 tranches de viande »
décrit le même aliment à deux stades ; le calcul additionnait les deux et
doublait les apports. Le prompt d'extraction interdit désormais ce double
balisage — un aliment acheté n'est chiffré qu'une fois, ses reprises s'écrivent
en texte plain — mais cela ne répare pas les recettes déjà importées.

Le poste `detect_duplicate_ingredients` lit la liste complète et désigne les
lignes qui en reprennent une autre. La reconnaissance demande de comprendre le
texte : « viande » et « côte de freygaard » n'ont aucun mot commun, tandis que
« beurre pour la pâte » et « beurre pour la poêle » se ressemblent beaucoup sans
être un doublon. Deux garde-fous encadrent la réponse : une ligne ne peut pas se
reprendre elle-même, et une recette dont plus de la moitié des lignes seraient
des reprises fait rejeter la réponse entière.

Le verdict vit dans le snapshot (`duplicate_ingredients`, `duplicate_indices`)
avec la **signature** de la liste qui l'a produit : un recalcul sur une liste
inchangée réutilise le verdict sans rappeler l'IA. Rien n'est écrit sur
`recipes.ingredients` — une reprise n'est pas une propriété de l'ingrédient,
elle n'existe que dans cette recette-ci.

Ces ingrédients sortent des totaux, du poids total **et du dénominateur de
couverture** : les compter comme manquants ferait passer pour incomplète une
recette qui ne l'est pas. Ils restent listés dans
`nutrition.not_consumed_ingredients` et s'affichent dans le tableau, atténués et
marqués — un ingrédient qui disparaît sans explication est précisément ce que ce
tableau doit éviter. Le poste `detect_not_consumed` renseigne le champ une seule
fois par ingrédient, et le doute profite au calcul (`true` par défaut).

##### Contrat ingrédient (recette)

Un ingrédient de `recipes.ingredients` porte **ce que la recette dit**, et rien d'autre :

- `name`, `qty`, `unit` (l'unité telle qu'écrite / affichée)
- `category?` — la section CookLang (`== Pour la pâte ==`) dont il relève
- `note?` — ce que la ligne du livre dit **en plus** de la quantité

**Une ligne du livre peut nommer DEUX ingrédients.** « 2 cuil. à café de moutarde à
l'ancienne mélangée à 2 cuil. à café de miel » est un achat de moutarde **et** un achat de
miel. La règle « une ligne, une entrée » obligeait à en choisir un, et le second sortait de
la liste de courses comme du calcul nutritionnel sans qu'aucune erreur ne soit levée. Deux
entrées portent alors la même ligne en `brut`, et le lien entre elles vit dans la `note`.
Le contrôle vérifie donc une **couverture**, pas une égalité — et il compte les occurrences :
« 1 bouquet d'aneth » présent dans deux sections demande deux entrées, sans quoi la fusion
que ce contrôle traque passerait inaperçue.

**La note se CALCULE quand le modèle la laisse vide** — `nutrition/ingredientNote.ts`,
`noteFromRawLine`. Constater son absence ne suffisait pas : « avec la peau mais écaillée »
est écrit dans le livre et doit finir dans la recette. C'est ce que la ligne dit **après**
avoir nommé l'aliment et sa quantité — une soustraction, pas un jugement. La proposition du
modèle reste prioritaire quand il en fait une : il sait reformuler un lien (« mélangée au
miel ») là où la soustraction rend une bribe. Deux choix décident du résultat : on prend ce
qui **suit** le dernier élément identifié et non ce qui reste après découpage — recoller les
morceaux rendait « 1 de avec la peau mais écaillée », les trous du milieu se refermant sur
des articles orphelins ; et la ponctuation n'est retirée qu'aux bords, pour que « cuil. à
café » garde son point. Contrainte inverse, testée mot à mot : **chaque mot rendu vient de la
ligne**. Une note inventée serait pire que pas de note, parce qu'on la croirait.

**`note` n'est pas un commentaire, c'est la moitié de la ligne.** « 1 filet de
saumon de 1,8 kg avec la peau mais écaillée » se sépare en une quantité, qui se
compte, et une précision, qui se lit. Cette précision ne vivait nulle part :
aucune accolade CookLang ne peut la porter, et le modèle réécrivait la phrase du
livre pour la caser — c'est l'un des mécanismes par lesquels une recette
s'écartait de son original. La transcription la sépare à la source ; elle est
transportée sans être interprétée, ni par la normalisation, ni par le
redimensionnement (« avec la peau mais écaillée » reste vrai pour deux parts
comme pour douze), ni par l'éditeur, qui ne propose délibérément pas de champ
pour elle — la retoucher dans un formulaire de quantités inviterait à la
réécrire.

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
| 1. Avant l'écriture | `normalizeRecipeReferentialsCore` | résout unités et identités, et enrichit ce que la recette ne dit pas : poids d'une pièce, poids d'un couple ingrédient/unité, ingrédients non consommés. Ne touche ni au texte, ni à `nutrition`. La singularisation des unités et la complétion des quantités en sont parties : la passe 2 de l'extraction lit la liste du livre, où l'unité et la quantité **sont écrites** — les deviner reviendrait à ignorer ce qu'on a sous les yeux. |
| 2. L'écriture | client ou `recipeProcessor` | écrit la recette normalisée |
| 3. Après l'écriture | `onRecipeWritten` | enrichit **poids d'unités et `per100g`**, puis calcule `nutrition` et `shopping_products` |

###### Un enrichissement, un seul propriétaire

Deux passes vivaient des deux côtés : `enrichUnknownUnitsWithAI` et
`enrichUnknownIngredientsWithAI`. La justification tenait sur le papier — ces
fonctions ne traitent que les entrées **dépourvues** de valeur, donc le second
passage ne trouve rien à faire.

Elle est fausse dès qu'on regarde l'horloge. À l'import, `recipeProcessor`
écrivait la recette **puis** la normalisait ; l'écriture réveillait
`onRecipeWritten`, qui partait en parallèle. Les deux lisent le référentiel au même instant, y trouvent le
même vide, et posent au modèle la même question. Le second n'arrive pas après le
premier : il arrive **avec** lui. Résultat : chaque unité et chaque ingrédient
inconnu payés deux fois, et un journal où la même passe apparaît en double sans
qu'on puisse dire laquelle a servi.

Les deux passes appartiennent désormais au **déclencheur, et à lui seul**. C'est
le bon propriétaire pour deux raisons : il part sur **toutes** les écritures de
recette — import, saisie manuelle, modification — là où la normalisation n'est
qu'un chemin parmi d'autres ; et c'est lui qui a besoin de ces valeurs,
immédiatement après, pour convertir les quantités et calculer la nutrition.
Enrichir ailleurs, c'est enrichir trop tôt ou deux fois.

La nutrition reste juste dès le premier affichage : le déclencheur enrichit et
calcule dans la même exécution, dans cet ordre.

**`recipes.nutrition_stale`** est un vestige de ce découpage. La normalisation le
levait quand elle venait de remplir des `per100g` **sans que les ingrédients de
la recette aient bougé** — le seul cas que la garde du déclencheur ne voit pas
seule, puisque tous les ingrédients ont alors leurs valeurs. Elle n'enrichit
plus, donc plus personne ne lève ce drapeau. Le déclencheur continue de le
**lire** et de l'éteindre après recalcul, pour les recettes qui le portaient
encore au moment du changement — y compris sur le chemin « recette sans
ingrédients », faute de quoi ce déclencheur, qui réécrit la recette et se
réveille lui-même, tournerait sans fin.

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
- **`GeminiPricing`** : map `feature → $/1M tokens` (input/output). Tarification images (`enhance_illustration`) : 0,0336 $/image (`gemini-3.1-flash-lite-image`, dit Nano Banana 2 Lite ; 0,04 $ sur `gemini-2.5-flash-image` jusqu'au 15/08/2026, entrée conservée pour relire les mois antérieurs).
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
  - `_auth.ts` : helpers `requireAuth(req)`, `requireEditor(req)`, `requireAdmin(req)`. `requireAuth` tranche sur le claim `role` du jeton et ne lit `users/{uid}` que s'il n'en porte pas ; les deux autres lisent toujours le document, car une révocation ne s'attend pas. La décision est portée par `accessDenial()`, pure et testée (`tests/authGuards.test.ts`). Les trois appellent aussi `assertAppCheck()` : c'est le seul endroit où l'attestation peut être exigée sans risquer d'oublier une callable.
  - Toutes les entrées HTTPS portent `maxInstances: MAX_CALLABLE_INSTANCES` (10, dans `config.ts`). Sans plafond, une boucle ouvre jusqu'à cent instances, chacune servant quatre-vingts requêtes concurrentes vers Gemini ou Anthropic. Ce plafond borne le parallélisme, jamais le total dépensé.
  - `security/appCheckPolicy.ts` : mode d'attestation lu dans `app_config/app_check_policy` (cache mémoire d'une minute), et décision pure `appCheckVerdict(mode, attested)`. Les fonctions gardent délibérément `enforceAppCheck` **non activé** : l'option se décide au déploiement, alors qu'un refus à tort doit se rouvrir en une minute. `req.app` non nul signifie jeton présent **et** valide — un jeton absent et un jeton invalide se présentent de la même façon et se traitent pareil.
  - `_logger.ts` : wrapper `@google-cloud/logging` avec labels `{module, correlation_id, job_id, user_id}` et payload JSON structuré.
  - `callable/*Callable.ts` : callables clients (createScanJobFn, queryLogsFn, relaunchDeadLetterFn, deleteDeadLetterFn, geminiProxyFn, etc.).
  - `pipeline/recipeProcessor.ts` : handler Cloud Tasks principal (download Storage → transcription → balisage → contrôle de fidélité → normalisation → **une seule** écriture Firestore).
  - **Les coordonnées d'une boîte ne supposent plus un moteur.** Le repère `[y_min, x_min, y_max, x_max]` sur mille est la convention **native de Google** ; le prompt se contentait de l'énoncer (« entiers 0-1000 »), ce qui suffit à un modèle qui l'a apprise et à aucun autre. Basculer les cinq postes de détection sur Claude les rendait muets. Réserver le poste à Gemini aurait été la mauvaise réponse : un moteur ne doit pas être privilégié par un détail de format resté implicite. Le prompt **décrit** désormais le repère (haut = 0, bas = 1000, verticale d'abord, deux exemples) et porte les **dimensions réelles de l'image** ; `normalizeBox(vals, w, h)` accepte les trois unités qu'un modèle emploie spontanément — millièmes, 0-1, et **pixels** ramenés avec les dimensions, la verticale rapportée à la hauteur. Sans dimensions, on **borne** au lieu de deviner : un facteur imaginaire donnerait une découpe précise et fausse, une découpe bornée se fait écarter par le contrôle de qualité, ce qui se voit. Limite assumée et testée : **sous mille, pixels et millièmes sont indiscernables** — aucune heuristique ne peut trancher, c'est le prompt qui porte le reste.
  - **La détection d'illustrations ne ment plus par omission.** Son `catch` était vide et rendait un tableau de boîtes : un refus du modèle, un plafond de dépense, un délai dépassé, une réponse illisible ou un format de coordonnées inconnu se présentaient tous comme « aucune photographie détectée ». La règle la plus stricte du projet, prise en défaut là où elle comptait le plus — une page sans photo et un appel en échec demandent des réactions opposées. L'erreur remonte désormais, la réponse brute est journalisée avec son moteur, et l'échec est absorbé **page par page** pour ne pas perdre les découpes déjà obtenues. Piste que cela rend vérifiable : le repère `[y_min, x_min, y_max, x_max]` sur mille est une convention **Google** ; un autre moteur ne la connaît pas et répond à côté sans lever d'erreur — une réponse non vide sans boîte exploitable est signalée comme telle, moteur nommé.
  - **`recipes.illustration_report`** `{detectees, retenues, publiees, pagesEnEchec}` suit la recette et s'affiche à la relecture. Trois situations, trois phrases, trois réactions : rien repéré (ajouter à la main), repérées puis toutes écartées (filtres ou modération), détection en échec (réessayer). Rien n'est dit quand une photo a été publiée : elle se voit.
  - **Les illustrations sont REDRESSÉES, pas seulement découpées** — `gemini/perspective.ts`. Une page photographiée à main levée est un trapèze : un cadre rectangulaire, aussi serré soit-il, garde deux coins de papier et de table. Le détecteur rend donc les **quatre coins** de chaque photographie (`DetectedQuad`, ordre haut-gauche → haut-droit → bas-droit → bas-gauche, en 0-1000), et `warpQuadrilateral` applique l'homographie qui les ramène sur un rectangle : normalisation de Hartley, système 8×8 par élimination de Gauss, interpolation bilinéaire — le même algorithme que l'atelier manuel (`image_enhancer_processing.dart`), porté côté serveur pour que la chaîne automatique rende ce que l'outil manuel rendait. Sharp redimensionne, tourne et découpe, mais ne projette pas : la boucle est en clair, 122 ms pour une photo de douze mégapixels. Une zone **déjà droite** (`isNearlyRectangular`) est découpée sans être redressée — la transformation ne changerait rien de visible et ré-échantillonnerait pour rien. `readQuad` accepte les deux formes de réponse, quatre coins ou boîte englobante : un modèle rend parfois la seconde par habitude, et la refuser perdrait une photo correctement repérée pour une question de forme. Deux détails qui séparent une image juste d'une image nette et fausse : l'**ordre des coins** décide quel côté sera le haut, et les dimensions de sortie prennent la **moyenne géométrique** des bords opposés — en perspective le bord proche est plus long que le lointain, retenir le maximum étirerait l'image.
  - **Orientation EXIF : redresser AVANT de détecter.** `uprightImage(bytes)` (`gemini/detector.ts`) applique l'orientation EXIF et efface l'étiquette ; le buffer redressé sert ensuite à la détection **et** au découpage. Un modèle de vision reçoit l'image telle qu'elle s'affiche — le décodeur applique l'EXIF — et rend ses coordonnées dans ce repère ; Sharp découpe la grille de pixels stockée. Pour une photo de téléphone prise en portrait, les deux repères sont tournés de 90° : on demandait le plat, on obtenait un bout de table. Rien ne le signalait, la découpe étant techniquement valide (taille, rapport de forme) — elle passait les filtres puis se faisait refuser à la modération, ou pire, se publiait. C'est aussi l'explication du « toutes les photos rejetées » : un bout de table est clair et uniforme, donc écarté comme page blanche.
  - **Les étapes affichées décrivent ce qui SE PASSE.** `current_step` : `import` → `gemini_call` (lecture de la page) → `parse` → `design` (illustrations) → `tagging` → `normalize` → `save` → `done`. `save` couvrait autrefois le balisage, le contrôle de fidélité et la normalisation des référentiels — jusqu'à sept minutes sous un mot qui en promet une seconde. Le calcul nutritionnel n'y figure délibérément pas : il a lieu après l'écriture, sur une recette déjà consultable.
  - **Chaîne d'extraction en deux passes** — `gemini/transcription.ts`, `gemini/tagging.ts`, `gemini/fidelity.ts`, prompts dans `gemini/promptsExtraction.ts`.
    - **Passe 1, `transcribePage`** (poste `transcription_page`) : un appel rend le **type** de la page et son contenu **recopié** en JSON — sections d'ingrédients (une ligne du livre = une ligne, entière), sections d'étapes (phrase par phrase), notes typées. Aucune balise, aucune décision de placement. Elle remplace `classify_page` + `scan_extraction` + `document_extraction`. Une réponse illisible **lève** : le repli optimiste d'avant supposait « recipe » et fabriquait une recette vide qu'il fallait ensuite retrouver dans les brouillons.
    - **Passe 2, `tagAndNormalize`** (poste `recipe_tagging`) : texte seul, jamais d'image. Rend le CookLang balisé, la liste normalisée (`nom`, `qte`, `unite`, `note`, `section`) et les tags — ces derniers coûtaient un appel à eux seuls.
    - **`checkFidelity`** : pure, testée, **sans appel de modèle**. Sept contrôles, tous mécaniques :

      | Contrôle | Ce qu'il attrape | Niveau |
      |---|---|---|
      | `ingredients_compte` | une ligne du livre sans ingrédient correspondant | rupture |
      | `etapes_compte` | un résumé — au-delà de 20 % d'écart | rupture si moins |
      | `texte_perdu` | une clause disparue **à décompte égal** | rupture sous 55 % |
      | `sections_titres` | « Pour la sauce à l'aneth et à la moutarde » raccourci | avertissement |
      | `notes_perdues` | une astuce que rien d'autre ne porte | avertissement |
      | `precision_perdue` | des mots de la ligne du livre qui ne sont ni dans le nom, ni dans l'unité, ni dans la note | avertissement |
      | `ingredient_invente` | « aneth frais » devenu « aneth en poudre » | avertissement |
      | `section_non_transcrite` et ses deux voisins | ce que la **passe 1** a perdu | avertissement |

      Une *rupture* écarte le balisage : `verbatimCooklang` rend le texte de la passe 1, non balisé — mieux vaut exact et non balisé que balisé et faux. Un *avertissement* laisse passer. Le verdict est écrit sur la recette (`fidelity_level`, `fidelity_findings`), affiché par `FidelityBanner` **sur le seul écran de relecture d'un brouillon**, et effacé à la validation.
    - **Le chapeau de la recette** — « Une méthode scandinave pour fumer le saumon dans le sel… » — a son propre champ, `introduction`. Il tombait sous la consigne de ne pas recopier les en-têtes de page : la distinction manquait, alors qu'un titre courant se répète de page en page tandis que ce paragraphe n'appartient qu'à cette recette. Il est transmis au balisage, écrit en note **avant la première étape** parce que le livre le met en premier, et compté dans le texte confronté au balisage — sans quoi son oubli ne produirait aucun signal.
    - **L'erreur de LECTURE est d'une autre nature, et aucun contrôle ne peut la prouver.** « peau en dessous » lu « peu profonde en dessous » rend une phrase impeccable : décompte intact, couverture des mots parfaite, tout concorde — avec le mauvais mot. Les sept contrôles comparent la passe 2 à la passe 1 ; quand la passe 1 a mal lu, **elle est la référence corrompue**. Le seul moyen de la démasquer serait de relire l'image, donc un appel de plus. Trois leviers, aucun infaillible : la capture des pages de recette passe à `imageQuality: 100` (elle était à 92 quand les couvertures, qui se lisent de loin, étaient à 100 — les artefacts JPEG s'installent d'abord sur les petits caractères) ; le prompt interdit de « réparer » un mot mal lu en expression plus courante, avec ce contre-exemple exact ; et la transcription déclare ses `lectures_incertaines`, remontées sur la recette. Un doute affiché se vérifie en dix secondes.
    - **`checkTranscriptionInventory`** ferme le seul trou que les autres ne pouvaient pas voir. Tous comparent la passe 2 à la passe 1 ; aucun ne voit ce que la **passe 1** a perdu — une page dont la première section n'aurait jamais été recopiée produit une chaîne cohérente de bout en bout. La passe 1 déclare donc son inventaire (titres de groupe vus, nombre de lignes, nombre d'étapes) **avant** de recopier, et le code compare l'annonce au résultat. Le verdict reste un avertissement : cette déclaration vient du modèle lui-même, et s'y fier pour jeter son travail reviendrait à lui demander de s'auto-condamner.
    - **Comparer deux textes que le balisage rend méconnaissables.** `stripCooklangTags` retire la syntaxe en **gardant le contenu des accolades** : la première version le jetait, et accusait un balisage fidèle d'avoir perdu un tiers de la page — les quantités quittent légitimement la phrase pour entrer dans les accolades. `significantWords` ne retient que les mots d'au moins quatre lettres et écarte une liste fermée de nombres écrits en lettres et de mesures abrégées (« deux cuillères à café » → « 2 c. à café » : trois mots sur quatre changent sans que rien ne soit perdu). Les seuils — 70 % pour l'alerte, 55 % pour la rupture — se placent dans l'écart mesuré entre une perte légitime (~15 %) et une amputation réelle (>70 %). Une accusation à tort finit par se faire ignorer, ce qui coûte plus cher que de ne rien vérifier.
    - **Pourquoi deux passes.** L'ancien prompt demandait de transcrire fidèlement *et* de restructurer en CookLang. La règle « la liste d'ingrédients ne se transcrit jamais, chaque ingrédient apparaît une seule fois à sa première mention dans les étapes » obligeait le modèle à **décider** où placer chaque ingrédient — donc à fusionner, déplacer, abréger — et rendait la précision d'une ligne (« avec la peau mais écaillée ») impossible à porter, ce qui poussait à réécrire la phrase du livre.
  - `nutrition/shoppingDerivation.ts` : `deriveShoppingProducts`, pure et testée. Le regroupement en produits d'achat ne coûte plus d'appel : il demandait un jugement tant que la liste était reconstituée depuis les balises des étapes, où le même aliment apparaissait sous plusieurs orthographes. La liste venant du livre, regrouper est devenu une addition. Deux unités incompatibles restent **deux lignes** — additionner supposerait un taux de conversion, et un taux inventé produit une quantité fausse présentée comme exacte.
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

##### Plafond de dépense d'IA

`app_config/ai_budget_policy` borne ce qu'un compte peut dépenser en une journée.

| Champ | Type | Effet |
|---|---|---|
| `daily_cost_eur_per_user` | `number` | Plafond quotidien en **euros**, par compte. `0` désactive ce critère |
| `daily_calls_per_user` | `number` | Plafond quotidien d'appels, par compte. `0` désactive ce critère |
| `monthly_alert_eur` | `number` | Seuil d'alerte mensuel en euros, tous comptes confondus. `0` = aucune alerte |
| `enabled` | `bool` | Coupe les deux plafonds sans les effacer. Absent vaut `true` |

**Pourquoi deux plafonds.** Le plafond monétaire dépend de deux données qui
peuvent manquer : la **grille tarifaire** — le projet refuse alors de chiffrer,
les appels partent en `pricing_unavailable` — et le **taux de change**, sans
lequel une dépense stockée en dollars ne se compare à aucun plafond en euros.
Dans les deux cas, un plafond uniquement monétaire s'ouvrirait en grand pendant
l'incident. Le plafond en nombre d'appels ne dépend ni d'un prix ni d'un taux.

**La monnaie.** Le plafond se règle en euros ; le coût d'un appel est calculé et
stocké en dollars, comme le facturent les fournisseurs. La conversion se fait au
moment de la comparaison, avec `app_config/currency_rate.usd_to_account_rate` —
jamais avec une constante. Sans taux, `budgetDenial` ignore le critère monétaire,
l'écran affiche des dollars plutôt qu'une conversion inventée, et un WARNING dit
que seul le compteur d'appels protège.

**Le compte fondateur a cinq fois le plafond** (`FOUNDER_DAILY_BUDGET_MULTIPLIER`),
sur les deux critères — n'agir que sur l'argent laisserait le compteur d'appels
bloquer précisément celui qui a le droit d'en faire cinq fois plus. Constante de
code et non réglage de base : en base, tout administrateur pourrait s'octroyer le
privilège. L'identifiant du fondateur est résolu par `getAuth().getUserByEmail`,
mis en cache une heure, et **jamais** lu dans le champ `email` du document
utilisateur, qu'un administrateur peut écrire.

**Pourquoi un défaut dans le code**, alors que le projet interdit les valeurs de
repli figées : cette interdiction porte sur les *mesures* — prix, taux de change
—, où une constante produit un montant faux présenté comme vrai. Un plafond est
une **décision**. Sans défaut, l'absence de document signifierait « aucune
limite », c'est-à-dire la situation qu'on corrige.

**Compteur** : `ai_daily_spend/{uid}_{AAAA-MM-JJ}` (`cost_usd`, `calls`,
`unpriced_calls`), incrémenté par `recordUsage` au moment où le coût est connu.
Un document par jour : la remise à zéro n'a besoin d'aucune tâche planifiée,
puisque le lendemain écrit ailleurs. Lecture réservée à l'administrateur et au
compte concerné, écriture fermée au client — ouverte, elle laisserait remettre
son propre compteur à zéro.

**Points d'application** — `assertWithinDailyBudget` est appelée à deux endroits,
et deux seulement, parce que ce sont les deux d'où l'argent part :

| Où | Ce que ça couvre |
|---|---|
| `callModel` (`ai/router.ts`) | tout le texte, Gemini comme Claude, callables **et pipeline asynchrone** |
| `runImageModel` (`gemini/imageGenerator.ts`) | les trois postes qui produisent une image, qui ne passent pas par `callModel` |

Placé dans les gardes HTTPS, le contrôle aurait laissé passer tout ce que Cloud
Tasks déclenche — c'est-à-dire l'import, le plus gros consommateur.

Le contrôle porte sur le **déjà-dépensé** : le coût exact n'est connu qu'après la
réponse. Un appel peut donc dépasser légèrement la limite, jamais la doubler.

`BudgetExceededError` se traduit en `resource-exhausted` côté callable — ni une
panne ni un défaut de droits — et fait partir un job d'import **directement** en
dead letter, sans réessai : le plafond ne se rouvrira pas dans les minutes qui
viennent, et chaque tentative refait tout le travail qui précède l'appel d'IA.

**Alerte** : `scheduledAiBudgetAlert` tourne tous les jours à 7 h (Europe/Paris),
compare le cumul du mois en cours (`ai_usage_monthly/{période}.total_cost_usd`)
au seuil, et n'écrit qu'une fois par mois — le drapeau vit dans
`app_config/ai_budget_alert`, posé **après** l'alerte pour qu'un échec la fasse
retenter le lendemain plutôt que de la perdre.

##### Politique d'attestation App Check

`app_config/app_check_policy` décide **ce qu'on fait d'un appel non attesté**. Un
seul champ :

| Champ | Type | Effet |
|---|---|---|
| `mode` | `"off"` \| `"monitor"` \| `"enforce"` | `off` ne vérifie rien ; `monitor` (défaut, y compris document absent ou illisible) laisse passer et journalise en `WARNING` avec le poste et l'agent utilisateur ; `enforce` refuse |

**Écran** : *Admin › Attestation de l'application*. Il affiche si l'appel qui l'a
chargé était lui-même attesté, et `setAppCheckPolicyFn` **refuse** `enforce`
demandé depuis un appel non attesté — sans quoi l'administrateur se verrouillerait
dehors, et la famille avec lui.

Trois précisions qui expliquent la forme de ce document :

- **Pourquoi pas `enforceAppCheck: true`** sur les callables : cette option se
  décide au déploiement. Un refus à tort — clé mal posée, client resté en
  arrière, fournisseur en panne — doit se rouvrir en une minute.
- **Pourquoi un mode « observation »** : c'est le seul moyen de savoir *ce qu'on
  couperait* avant de couper. Tant qu'il arrive des appels non attestés, leurs
  traces nomment le client concerné.
- **Pourquoi aucune exemption de plateforme**, alors que le client Windows ne
  sait pas attester : la plateforme est déclarée par le client, donc par un
  attaquant aussi. Une exemption « desktop » serait ouverte à tout le monde.

Côté client, `core/services/app_check.dart` active l'attestation quand la
plateforme a un vrai fournisseur (web, Android, iOS, macOS) et s'abstient
sinon — sans jamais relancer : une attestation impossible ne doit pas empêcher
l'application de démarrer, c'est la politique serveur qui décide des
conséquences. La clé de site reCAPTCHA (`kAppCheckRecaptchaSiteKey`) est
publique par nature et vit donc dans le code ; **vide, l'attestation web n'est
pas activée**.

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

##### Le catalogue des postes — la liste qu'il ne faut pas oublier

Un poste de coût existe à **trois** endroits, et rien ne relie les trois :

| Où | Fichier | Ce qui casse s'il manque |
|---|---|---|
| L'appel | `ctx.feature` du `callModel` | rien — le coût est bien enregistré |
| Le routage | `ROUTABLE_FEATURES` (`callable/aiRoutingCallable.ts`) | le poste ne peut pas être basculé vers Claude depuis Admin → Moteur d'IA |
| La lecture | `kFeatureCatalog` / `kFeatureProcess` (`features/admin/data/feature_catalog.dart`) | le poste s'affiche sous sa **clé technique**, rangé dans « Autres » |

Aucun de ces oublis ne lève d'erreur ni ne fausse un montant : le coût est
compté, il est seulement illisible. C'est exactement le mode de panne de la
tarification — le chiffre s'affiche, et il ment par omission de sens.

L'oubli s'est produit en grand : **toute la chaîne nutrition** — quinze postes,
dont les plus fréquents de l'application, puisqu'une seule écriture de recette
peut interroger le moteur une dizaine de fois — vivait dans « Autres » sous des
identifiants techniques, aux côtés de `polish_markdown` et
`generate_recipe_illustration`.

**Règle** : un nouveau poste s'ajoute aux trois endroits dans le même commit.
Les variantes `_batch` sont des postes à part entière et se distinguent de leur
version unitaire — c'est le seul moyen de vérifier que le groupage fait son
office. Un poste disparu du code **reste** au catalogue : les mois déjà
comptabilisés continuent de le nommer.

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
  - Regroupement par traitement : `_groupByCorrelation(List<LogEntry>) → List<_TreatmentGroup>` indexe sur `labels['correlationId']` en conservant l'ordre d'apparition des groupes (le plus récent d'abord, comme le flux) et inverse les entrées à l'intérieur (déroulement chronologique). `_TreatmentGroup.label` retient **d'abord** la racine du `correlationId` — l'identifiant privé de son horodatage (`RegExp(r'[-_]\d{10,}([-_][a-z0-9]+)?$')`), `null` si l'identifiant est un UUID, donc opaque — puis, à défaut seulement, `labels['feature']`, puis `labels['moduleType']` ; clé vide ⇒ « Hors traitement ». `feature` est le poste d'imputation d'un appel IA, pas le nom d'un traitement : en faire le titre étiquetait un import de recette « shopping_products_refresh ». La racine obtenue est ensuite **traduite** par `logTreatmentName` (`features/admin/domain/log_treatment_label.dart`) : elle est écrite pour le code, pas pour un lecteur.
  - **Nommage d'un traitement.** `newCorrelationId(nom)` (`logging.ts`) fabrique `nom_horodatage_aléa` ; pour les callables c'est `requireAuth` / `requireAdmin` / `requireEditor` qui le pose, à partir du **nom passé en argument**. Ce paramètre valait `"call"` par défaut : toute fonction qui n'en choisissait pas un produisait un groupe intitulé « call », si bien que quatre groupes « call » représentaient quatre travaux différents et anonymes. Les dix-sept fonctions concernées nomment désormais leur traitement ; `test/log_treatment_label_test.dart` lit les sources TypeScript et échoue si un `requireX(req)` sans nom réapparaît, ou si un nom déclaré n'a pas sa traduction.
  - **Qualification.** `qualify(nom, détail)` (`logging.ts`) rend `nom:détail-en-slug`. Le deux-points est la frontière que l'écran connaît : ce qui précède nomme l'étape, ce qui suit dit *laquelle*. `generateRecipeFn` s'en sert pour la variante demandée — l'écran Explorer lance trois générations simultanées, plus une relance en cas de doublon, et les groupes se lisent « … — Fidele », « … — Rapide », « … — Creative » au lieu de trois titres identiques.
  - **Deux fils naissent hors callable.** `import_recette` est ouvert par `jobDispatcher` et **transmis** au payload Cloud Tasks : `recipeProcessor` ne fabrique le sien que si le payload n'en porte pas. Un import entier tient donc sous un seul titre — il s'appelait `disp`, du nom du déclencheur, et l'écran rangeait l'extraction et la normalisation sous « Mise en file du traitement ». Le dispatcher part par ailleurs à **chaque** écriture du job et n'a le plus souvent rien à faire ; ces constats se rattachent au `correlation_id` déjà porté par le document plutôt que d'ouvrir un fil chacun. `ecriture_recette` est ouvert par `onRecipeWritten`, qualifié par sa cause : `ingredients-modifies`, `premier-calcul`, `sans-changement`.
  - **Pagination.** `queryLogsFn` accepte un `pageToken` et rend un `nextPageToken` (`autoPaginate: false` — sans quoi le client Cloud Logging suit les pages jusqu'à épuisement et ignore `pageSize`). Côté écran, `LogsQueryNotifier.loadMore()` concatène ; le pied de liste annonce le nombre d'entrées lues et dit si la suite existe. Une liste tronquée en silence se lit comme une liste complète.
  - **Traduction.** `kLogTreatmentLabels` associe chaque racine à un libellé français ; une racine inconnue est rendue **telle quelle**, jamais remplacée par un texte générique — un nom technique reste cherchable. La table vit côté client parce qu'elle ne sert qu'à l'affichage : l'identifiant, lui, doit rester stable et filtrable.
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
  - `cooklangFormatIngredient()` délègue l'accord à `core/utils/ingredient_display.dart`, partagé avec l'export PDF et la liste de courses : minuscule sur les libellés de référentiel, pluriel à partir de deux, liaison « de / d’ » avec l'exception des h aspirés, et disparition des unités qui comptent (« 2 carottes », pas « 2 pièces carotte »). **Règle d'affichage seulement** : le CookLang stocké n'est jamais réécrit, sous peine de casser l'identité dont dépendent nutrition, courses, index de recherche et catégories — et d'être effacé au prochain enregistrement par `rewriteCooklangWithReferentials`. Rendu client, donc **aucun jumeau TypeScript**.
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
  - Chaque entrée de `daily_constraints` porte `max_prep_minutes`, `target_portions`, `is_batch_cooking`, `notes`, et **facultativement** `meal_hour` / `meal_minute`. Ces deux-là ne sont écrits que si le jour a son heure propre : une clé absente veut dire « comme les autres jours », là où un `null` stocké se confondrait avec minuit.
  - `mealTimeFor(weekday)` est le **seul** endroit qui répond à « à quelle heure mange-t-on ce jour-là » — la sienne s'il en a une, celle par défaut sinon. Deux écrans qui recalculeraient cette règle finiraient par ne plus dire la même heure.
  - `withDefaultMealTime(h, m)` change l'heure par défaut **et** rend tous les jours à elle. Sans cette remise à zéro, régler l'heure globale n'aurait plus d'effet visible dès qu'un seul jour aurait été personnalisé, et il faudrait deviner lesquels des sept résistent.
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

- **`GoogleTasksService`** — envoi de la liste de courses dans Google Tasks :
  - scope `https://www.googleapis.com/auth/tasks`, même mécanique de jeton que `CalendarService` (cache de 55 min, popup web / `authorizationClient` mobile) ;
  - `createShoppingList(title, groups)` : POST `users/@me/lists` puis une insertion par rayon (`lists/{id}/tasks`) et une par article avec `?parent={rayon}`. Les sous-tâches donnent la hiérarchie, les cases à cocher sont natives ;
  - le paramètre `previous` conserve l'ordre : sans lui, chaque insertion se place en tête et la liste ressort à l'envers ;
  - seuls les articles **non cochés** sont envoyés.

  **Pourquoi pas Keep** : Keep n'expose aucune API d'écriture. L'export s'y fait par le presse-papier, et coller du texte dans une note ne produit jamais une liste cochable — la conversion est manuelle et aplatit les rayons. Le bouton Keep subsiste en action secondaire, en le disant.

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

**Le soin se choisit par poste.** `ModelCallContext.effort` (`low` par défaut) pilote
`output_config.effort` chez Claude. Ce réglage était figé à `low` pour tous les postes, avec
une justification qui ne vaut que pour la nutrition — estimer les calories d'un ingrédient
est un rappel de connaissances, pas un problème de raisonnement, et les jetons de réflexion
se facturent au tarif de sortie. Transcrire une page de livre est l'exact contraire :
`transcription_page` et `recipe_tagging` demandent `high`. La panne n'était visible que
depuis la réparation du streaming : jusque-là Claude échouait sur la transcription et Gemini
prenait le relais, si bien que réparer l'appel a confié la lecture à un moteur réglé pour
aller vite. Côté Gemini, le levier équivalent existe depuis l'origine et se règle sans
déploiement — `thinking_budgets` par poste dans `app_config/ai_routing_policy`.

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
| Images et archives | `sharp` ^0.33.5, `jszip` ^3.10.1 |

---

## 3. Schéma de Données Firestore

### Vue d'ensemble

```
firestore/
├── users/{uid}/
│   ├── nutrition_portion_overrides/{recipeId}     ← état propre à UN lecteur
│   └── preferences/{prefId}                       ← book_order : rangement de la bibliothèque
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
├── plating_advice/{recipeId}/
├── image_moderation/{moderationId}/
├── ai_usage/{id}/                                 ← une ligne par appel
├── ai_usage_monthly/{AAAA-MM}/
├── ai_daily_spend/{uid}_{AAAA-MM-JJ}/
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
| `display_name` | `String` | Nom d'affichage Google |
| `photo_url` | `String?` | URL de l'avatar Google |
| `role` | `String` | Enum : `admin` \| `editor` \| `reader` \| `pending` |
| `created_at` | `Timestamp` | Date de première connexion |
| `last_seen_at` | `Timestamp` | Date de dernière connexion active |
| `is_revoked` | `Boolean` | `true` si l'accès a été révoqué par un Admin |

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
| `ingredients` | `List<Map>` | Liste structurée `{name, qty, unit, category?, note?}` — cf. « Contrat ingrédient ». `note` porte ce que la ligne du livre dit en plus de la quantité (« avec la peau mais écaillée ») : la quantité se compte, la précision se lit |
| `page_type` | `String?` | `recipe` \| `technique` \| `equipment` \| `ingredient_note` \| `other`. **Écrit uniquement s'il vaut autre chose que `recipe`** ; à défaut, les lecteurs se rabattent sur `>> page_type:` dans `raw_cooklang` |
| `shopping_products` | `List<Map>` | Produits d'achat consolidés `{name, qty, unit}`, écrits par `onRecipeWritten`. Absent tant qu'aucun calcul n'a eu lieu |
| `nutrition` | `Map?` | Snapshot nutritionnel calculé côté backend (totaux, par portion, per100g, qualité, ingrédients manquants, huile absorbée à la friture) |
| `nutrition_validation` | `Map?` | Diagnostic de la dernière synchronisation nutrition (état, quantités invalides, unités inconnues) |
| `fidelity_level` | `string?` | `avertissement` ou `rupture` — verdict du contrôle de fidélité entre la transcription et le balisage. Absent quand tout concorde. Affiché par `FidelityBanner` sur le seul écran de **relecture d'un brouillon**, jamais sur la recette : c'est un outil pour décider, pas pour cuisiner. **Effacé par `validateDraft`** — valider, c'est avoir relu et tranché ; garder le doute reviendrait à le conserver sans que personne puisse plus le lever, et à rouvrir le débat au premier écran qui l'afficherait |
| `fidelity_findings` | `List<Map>?` | Ce qui a été constaté : `{message, items?}`. Les éléments vivent à part de la phrase parce qu’ils s’affichent en **liste à puces** — sept mots mal lus concaténés forment un pavé qu’on ne relit pas, et une alerte qu’on ne relit pas ne sert à rien. `FidelityFinding.listFrom` lit aussi l’ancien format (liste de chaînes) |
| `nutrition_stale` | `bool?` | Vestige : plus personne ne le lève depuis que l’enrichissement `per100g` appartient au seul `onRecipeWritten`. Toujours lu puis éteint par ce déclencheur, pour les recettes qui le portaient encore. Jamais écrit ni lu par le client |
| `nutrition_enrichment_attempts` | `int?` | Passages d'enrichissement consommés pour la liste d'ingrédients courante (3 au plus). Remis à 1 dès que les ingrédients changent. Borne le rattrapage d'un ingrédient que l'IA n'arrive pas à estimer, sans laisser le déclencheur se relancer sans fin |
| `source_recipe_id` | `String?` | Recette d'origine quand ce document est une copie/amélioration. Nul pour un brouillon issu d'un scan |
| `import_version` | `String?` | Version de l'app utilisée lors de l'import (ex : `'0.13.53'`) |
| `plating_advice` | `Map?` | Conseil de dressage produit par l'IA à la demande. Écrit **uniquement** par `suggestPlatingFn` / `generatePlatingImageFn`. Absent tant que personne ne l'a demandé — cf. structure ci-dessous |

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
| `ai_usage_monthly/{AAAA-MM}` | agrégat mensuel : `by_feature` (avec `by_provider` imbriqué — `calls`, `cost_usd`, `input_tokens`, `output_tokens`), `by_provider`, `by_model`, `by_user`, totaux | l'écran des coûts |

**La grille tarifaire est datée.** Claude Sonnet 5 bénéficie d'un tarif
d'introduction (2,00 / 10,00 au lieu de 3,00 / 15,00) jusqu'au 31 août 2026.
La table portait volontairement le tarif plein, au motif qu'une surestimation
valait mieux qu'une sous-estimation. La facture d'août a montré l'erreur :
1,20 € estimés contre 0,80 € facturés, **50 % d'écart** — assez pour rendre le
rapprochement inexploitable, et pour masquer un vrai défaut de comptage le jour
où il s'en produirait un. Une marge de sécurité posée sur un instrument de
mesure ne le sécurise pas.

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
| `created_at` | `Timestamp` | Création |

---

### 3.8 Collection `planning_config`

Un document par utilisateur (`{uid}`), écrit depuis l'écran de configuration du planning.

| Champ | Type | Description |
|---|---|---|
| `meals_per_cycle` | `int` | Nombre de repas d'un cycle |
| `cycle_start_day` | `int` | Jour de démarrage (1 = lundi) |
| `batch_cooking_day` | `int?` | Jour de préparation groupée |
| `daily_constraints` | `Map<int, …>` | Par jour : temps de préparation maximum, parts visées, batch cooking, notes en langage naturel |
| `global_constraints` | `String` | Contraintes valables pour tout le cycle, en langage naturel |
| `default_meal_hour` · `default_meal_minute` | `int` | Heure par défaut d'un repas |
| `default_calendar_duration_minutes` | `int` | Durée par défaut d'un événement Google Calendar |
| `calendar_id` · `calendar_name` | `String` | Calendrier Google cible |

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
| `source` | `String` | D'où viennent les valeurs : résolution, estimation d'IA, correction humaine |
| `status` · `quality_status` | `String` | `proposed` \| `known` ; qualité `pending` tant que rien n'a été vérifié |
| `seen_count` | `int` | Nombre de rencontres — sert à prioriser l'enrichissement |
| `first_seen_at` · `last_seen_at` · `updated_at` | `Timestamp` | Traçabilité |

`nutrition_units/{unitId}` porte les mêmes champs de traçabilité, plus les alias observés,
des exemples d'ingrédients associés et un `grams_per_unit` — **jamais** posé sur une unité
de volume ni de comptage, où il n'aurait aucun sens.

> Le référentiel dépasse le millier de documents : toute lecture plafonnée coupe la fin de
> l'alphabet, et ressemble alors à un défaut d'enrichissement.

---

### 3.11 Comptabilité de l'IA

Cinq collections, écrites par `recordUsage` et par lui seul.

| Collection | Contenu |
|---|---|
| `ai_usage/{id}` | **Une ligne par appel** : `uid`, `feature`, `provider`, `model`, jetons d'entrée, de sortie, de réflexion, de cache (écriture et lecture), `image_output_count`, `estimated_cost_usd`, `status`, `cost_bucket`, `correlation_id`, `entity_type`, `entity_id`, `period`, `timestamp`. Un appel passé pendant une panne de grille porte en plus `pricing_unavailable: true` — c'est lui qui le rend retrouvable pour un rechiffrage |
| `token_usage/{uid}` | Agrégat par compte : total de jetons, coût, et le détail `features.{poste}` |
| `ai_usage_monthly/{AAAA-MM}` | Agrégat mensuel lu tel quel par l'écran des coûts : totaux, `total_unpriced_calls`, puis les ventilations `by_feature` (dont `by_provider` **dans** le poste, seule façon de juger une bascule), `by_provider`, `by_model` et `by_user` |
| `ai_daily_spend/{uid}_{AAAA-MM-JJ}` | Ce que le plafond relit avant chaque appel. Un document par jour : aucune remise à zéro à planifier |
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

---

### 3.14 Le reste

- `plating_advice/{recipeId}` : conseil de dressage propre à une recette, et les visuels
  d'étapes déjà produits.
- `image_moderation/{moderationId}` : décrit en tête de ce document, section *Spécification
  technique — Modération des images*.
- `users/{uid}/nutrition_portion_overrides/{recipeId}` : le nombre de portions choisi par
  **cet** utilisateur. Il vit sous lui, pas dans la recette — sans quoi chacun écraserait le
  choix de l'autre, silencieusement.
- `users/{uid}/preferences/book_order` : `book_ids`, la liste ordonnée des livres telle que
  **ce** lecteur a rangé sa bibliothèque au glisser-déposer, et `updated_at`. Même raison : un
  livre est vu par toute la famille, chacun le range où il veut. Les identifiants disparus sont
  ignorés à la lecture, les livres créés depuis se rangent à la fin.

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
      function targetIsFounder() {
        return resource.data.email.lower() == founderEmail();
      }

      allow read: if isAuthenticated() && (request.auth.uid == uid || isAdmin() || isEditor());

      // Le rôle et l'identité d'un compte neuf sont imposés, pas proposés.
      allow create: if isAuthenticated() && request.auth.uid == uid
                      && request.resource.data.role == 'pending'
                      && request.resource.data.is_revoked == false
                      && request.resource.data.email == request.auth.token.email;

      // Un administrateur nomme et révoque — sauf le fondateur, que lui seul
      // peut destituer.
      allow update: if (isAdmin() && (!touchesAuthority() || !targetIsFounder() || isFounder()))
                      || (isAuthenticated() && request.auth.uid == uid
                          && !touchesAuthority()
                          && request.resource.data.email == resource.data.email);

      allow delete: if isAdmin() && !targetIsFounder();
    }

    // Collection books
    match /books/{bookId} {
      // Les trois livres système se reconnaissent à leur tag interne. Ils se
      // renomment, mais ne se suppriment pas : ce sont les destinations par
      // défaut des recettes sans livre et des créations de l'IA. Les perdre
      // laisserait la règle « toute recette a un livre » sans issue.
      function isSystemBook(data) {
        return data.tags is list
          && data.tags.hasAny(['__libres', '__kassdale_ia', '__secretes']);
      }

      allow read: if isApproved();
      allow create, update: if isEditor();
      allow delete: if isEditor() && !isSystemBook(resource.data);
    }

    // Collection recipes
    match /recipes/{recipeId} {
      allow read: if isApproved() &&
        (resource.data.review_status == 'validated'
          || isEditor()
          || isOwner(resource.data.created_by));
      allow create: if isEditor() || (isApproved() && request.resource.data.created_by == request.auth.uid);
      allow update: if isEditor() || (isApproved() && isOwner(resource.data.created_by));
      allow delete: if isEditor() || (isApproved() && isOwner(resource.data.created_by));

      match /annotations/{annotationId} {
        allow read: if isApproved();
        allow create: if isApproved();
        allow update, delete: if isApproved() && (isOwner(resource.data.uid) || isAdmin());
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
| `users/{uid}/nutrition_portion_overrides` | propriétaire ou admin | propriétaire ou admin |
| `users/{uid}/preferences` | propriétaire ou admin | propriétaire ou admin |
| `recipe_ratings` | `isApproved()` | l'auteur de la note, ou admin |
| `groups` | membres du groupe | le propriétaire, ou admin |
| `processing_jobs` | éditeur ou propriétaire du job | création par le propriétaire ; le propriétaire ne peut ensuite toucher qu'aux champs de relance et d'annulation |
| `planned_meals` · `planning_config` | le propriétaire seul | le propriétaire seul |
| `error_reports` | admin, ou l'auteur du rapport | création par l'auteur ; modification et purge par l'admin |
| `app_config` | admin — plus la politique nutrition, ouverte à tout compte nommé | admin |
| `nutrition_ingredients` | `isApproved()` | **serveur seul** |
| `nutrition_units` | `isApproved()` | admin |
| `image_moderation` | admin, ou celui qui a envoyé l'image | **serveur seul** — une décision de modération que le client peut écrire n'est pas une décision |
| `ai_usage` · `ai_daily_spend` | admin, ou le compte concerné | **serveur seul** — un client pouvait autrefois y inscrire des dépenses imaginaires que la réconciliation aurait présentées comme réelles |
| `dead_letters` · `ai_reconciliation_monthly` | admin | **serveur seul** |

Toutes les lectures partagées passent par `isApproved()` : être connecté ne donne accès à rien.

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
    // ne doit verrouiller personne dehors.
    function isActive() {
      return isAuthenticated() && request.auth.token.revoked != true;
    }

    // Écriture dans les dossiers partagés : éditeurs et administrateurs.
    function canWriteSharedImages() {
      return isActive() && request.auth.token.role in ['editor', 'admin'];
    }

    // Le sas d'entrée, côté fichiers. Ne concerne que l'écriture : fermer aussi
    // la lecture ferait clignoter les images de qui n'a pas renouvelé son jeton,
    // pour un gain nul (les URL ne se devinent pas).
    function isApprovedToken() {
      return isActive() && request.auth.token.role in ['reader', 'editor', 'admin'];
    }

    function isOwner(uid) { return isAuthenticated() && request.auth.uid == uid; }

    function isImageUnder(maxBytes) {
      return request.resource.size < maxBytes
        && request.resource.contentType.matches('image/.*');
    }

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
      allow read: if isActive();
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

    match /scans/{uid}/{allPaths=**} {
      allow read: if isActive();
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
      allow read: if isActive();
      allow write: if false;
    }

    match /recipes/{recipeId}/{allPaths=**} {
      allow read: if isActive();
      allow write: if false;
    }

    match /users/{uid}/{allPaths=**} {
      allow read: if isActive();
      allow write: if false;
    }
  }
}
```

> `canWriteSharedImages()` subsiste dans le fichier de règles alors qu'aucun chemin ne
> l'appelle plus : les six dossiers publiés sont désormais fermés en écriture. Elle décrit
> l'autorisation qu'il faudrait si l'un d'eux rouvrait — ce qui n'arrivera pas sans une
> décision explicite sur la modération.

**Un refus Storage ne dit jamais lequel de ses contrôles a mordu.** Sur `quarantine/`, un
`[firebase_storage/unauthorized]` peut vouloir dire quatre choses : le chemin n'appartient
pas à l'appelant, son jeton ne porte pas encore de rôle (compte `pending`, ou jeton émis
avant la propagation — une heure au plus), le fichier dépasse 50 Mo, ou son type MIME n'est
pas dans la liste. C'est pourquoi le rapport d'erreur du client porte `sizeBytes`,
`storagePath` et `mimeType` : sans eux, les quatre causes sont indiscernables.

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
ctx.feature ──▶ callModel ──┬─▶ app_config/ai_routing_policy   (quel moteur ?)
                            ├─▶ assertWithinDailyBudget        (le compte peut-il ?)
                            ├─▶ Gemini | Claude
                            └─▶ recordUsage                    (appel, moteur, modèle, coût)
```

Un poste routé vers Claude mais servi par Gemini faute de clé montée émet un `WARNING` :
c'est le silence de ce cas qui avait rendu une panne indéchiffrable. **Toute fonction qui
appelle `callModel` doit déclarer les deux secrets** — un secret non déclaré n'est pas monté
dans `process.env`, et le repli est alors silencieux.

### L'extraction, en deux temps

`gemini/extractor.ts` classifie d'abord la page, puis n'extrait que si elle contient une
recette. Le modèle rend du **CookLang**, pas du JSON : les métadonnées voyagent dans les
lignes `>>` du document lui-même (`titre`, `page`, `portions`, `difficulté`,
`temps_préparation`, `temps_cuisson`, `dish_types`), plusieurs recettes d'une même page sont
séparées par une ligne de tirets, et une page sans recette rend `NO_RECIPE`.

Les prompts vivent dans `functions/src/gemini/prompts.ts` et **ne sont pas recopiés ici** :
un prompt dupliqué dans la documentation diverge en une semaine. Ce qui est stable, et qui
mérite d'être écrit, ce sont les invariants qu'ils imposent :

- **Copie fidèle** : les étapes restent aussi proches que possible de l'original. Ne pas
  reformuler, ne pas résumer, n'inventer ni ingrédient ni quantité.
- **Une orthographe par aliment** dans toute la recette — sans quoi le même ingrédient
  compte deux fois dans l'index de recherche, la nutrition et la liste de courses.
- **Ustensile ou ingrédient**, jamais les deux : `#moule à tarte{}` contre `@moule{}`.
- **Accolades jamais vides quand la quantité est connue** ; vides quand la quantité n'est
  qu'un contexte (« pour la cuisson », « à volonté »).

### Les réponses JSON

Les autres postes — nutrition, planning, tags, dressage — demandent du JSON. Un seul module
décide comment le lire : `ai/askJson.ts`. Il cherche le premier `{` et le dernier `}` après
avoir retiré un éventuel bloc de code Markdown, parce que les modèles enrobent volontiers
leur réponse. Auparavant, cinq expressions régulières légèrement différentes coexistaient
dans un même fichier ; l'écart ne se voyait que le jour où le modèle ajoutait une phrase.

Une réponse illisible lève une `JsonAnswerError`, distincte d'un échec réseau : la première
ne se réessaie pas, la seconde oui.

### Gestion des erreurs

| Cas | Comportement |
|---|---|
| JSON malformé | `JsonAnswerError` avec la réponse brute journalisée ; pas de retry, le poste rend un résultat dégradé et le dit |
| `NO_RECIPE` ou extraction vide | Aucun brouillon créé ; le job se termine proprement plutôt que d'écrire une recette vide |
| Timeout / erreur réseau | Retry Cloud Tasks avec backoff 10 s → 300 s, trois tentatives, puis `dead_letters/` |
| Plafond de dépense atteint | Refus **avant** l'appel ; le job part directement en dead letter, sans réessayer — les trois tentatives referaient tout le travail qui précède pour heurter le même mur |
| Clé du fournisseur absente | Repli sur Gemini, avec un `WARNING` nommant le poste et le moteur attendu |
| Grille tarifaire illisible | L'appel a lieu, l'usage est enregistré **sans montant** et compté dans `total_unpriced_calls`. Jamais de prix de repli |

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

## 9. Application Desktop (Windows)

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

## 10. Application Web

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

Un cache long sur ces fichiers laisse les utilisateurs bloqués sur une ancienne version.

### Build et déploiement

Toujours par le script racine `deploy.ps1` — jamais en reconstituant les commandes à la main :
il synchronise `lib/core/app_version.dart` depuis `pubspec.yaml`, construit, déploie, copie
dans `Release/` et pousse le dépôt.

```powershell
./deploy.ps1              # web + APK + functions + hosting/firestore/storage + git push
./deploy.ps1 -WebOnly     # web uniquement
```

Deux pièges connus, tous deux silencieux :

- `flutter build web` peut publier un `main.dart.js` **antérieur** à l'édition sans le
  signaler, et `flutter clean` échoue parfois sur un dossier verrouillé. Vérifier qu'une
  constante attendue figure bien dans `build/web/main.dart.js` : un bundle qui compile n'est
  pas un bundle à jour.
- `deploy.ps1` peut annoncer un succès et sortir en code 0 alors que des Cloud Functions ont
  échoué. Chercher `Functions deploy had errors` dans le log **avant** d'annoncer quoi que ce
  soit — le second `Deploy complete!` est celui du hosting.

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

Chaque feature porte ses trois couches — `data/` (accès Firestore, Storage, callables),
`domain/` (modèles et règles), `presentation/` (écrans, widgets, providers Riverpod). Deux
features ajoutent un `services/` pour la logique qui ne tient dans aucune des trois.

```
lib/
├── main.dart
├── firebase_options.dart          # Généré par FlutterFire CLI
├── app_version.dart               # Synchronisé depuis pubspec.yaml par deploy.ps1
├── core/
│   ├── config/                    # Constantes d'environnement
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
    └── search/                    # Recherche, filtres, génération de recette
```

Côté Functions :

```
functions/src/
├── ai/            # types neutres, routeur, client Claude, tarification, budget, usage
├── billing/       # coûts GCP (BigQuery), réconciliation mensuelle
├── callable/      # entrées HTTPS callable + gardes (_auth.ts)
├── cooklang/      # parseur, jumeau TypeScript du parseur Dart
├── gemini/        # client Gemini et prompts par poste
├── moderation/    # décision pure, moteur Cloud Vision, promotion
├── nutrition/     # per100g, conversions, référentiels, huile de friture
├── pipeline/      # jobDispatcher, recipeProcessor, deadLetterHandler
├── scheduled/     # réconciliation mensuelle, alerte de budget
├── security/      # App Check
├── tests/         # node --test, fixtures partagées avec Dart
├── triggers/      # onRecipeWritten, syncUserClaims, enforceFounderRole
└── utils/         # sécurité d'upload, journalisation
```

---

## 13. Ce qui reste à construire

Le périmètre fonctionnel restant est décrit dans
`FunctionalRequirements.md` § 7. Vu du code :

| Chantier | Complexité | Ce que ça demande |
|---|---|---|
| Mode hors-ligne | Moyenne | `Settings(persistenceEnabled: true)` ne suffit pas — il faut décider ce qui reste lisible sans réseau (recettes validées, planning du jour) et ce qui doit échouer franchement (tout appel d'IA) |
| Partage externe (lien public) | Faible | Une route non authentifiée, donc une décision sur ce qu'un lien expose et pour combien de temps ; les Security Rules actuelles ne connaissent que des comptes nommés |
| Minuteur interactif depuis CookLang | Faible | Les durées sont déjà analysées (`timer_display.dart`) ; manquent un décompte et des notifications locales |
| Attestation du client Windows | — | Sans solution : la seule voie serait un jeton de débogage dans un binaire distribué. Le passage d'App Check en *exigé* prive donc le desktop de l'IA, et c'est documenté comme tel |
