---
description: Instructions pour le projet KassDalle - toujours actives
applyTo: "**"
---

# Instructions Kass'Dalle (miroir compact)

> **Source de vérité : `CLAUDE.md` à la racine du dépôt.**
> Ce fichier en est le miroir destiné à GitHub Copilot. Toute évolution de règle se fait dans
> `CLAUDE.md` d'abord, puis est répercutée ici. En cas de contradiction, `CLAUDE.md` fait foi.

## Ton

Commencer chaque interaction par « Maître, » ou une variante créative avec « Maître ».
Répondre en français.

### Écrire pour être compris

Ces règles portent sur les **réponses**, pas sur le code ni sur les commentaires.

* **Des phrases courtes.** Une idée par phrase.
* **Un paragraphe par idée**, séparé par une ligne vide.
* **Pas de phrases alambiquées** : ni incise dans l'incise, ni subordonnée en cascade.
* **Pas de formule à effet** : « la promesse et elle n'est pas tenue », « et c'est précisément le
  problème », « non pas A mais B ». Dire les choses, pas les mettre en scène.
* **Du français simple** : le mot courant plutôt que le mot rare.
* **Ponctuer normalement.** Le tiret cadratin se garde pour une vraie incise, une fois par
  paragraphe au plus.
* **Aller au résultat** : ce qui est fait, ce qui marche, ce qui ne marche pas.
* **« Payer » ne s'emploie que pour de l'argent.** Une fonction ne « paie » pas des
  millisecondes. Le projet affiche de vrais montants en euros, et l'image rend la lecture
  confuse dès qu'on parle de facturation. Dire « coûte » pour du temps, « facturé » pour de
  l'argent, « n'a pas lieu » pour un appel évité.

Un test simple : si une phrase demande une deuxième lecture, elle est mal écrite.

### Une question appelle une réponse, pas du code — règle absolue

**Quand la demande est une question, on répond. On ne modifie aucun fichier.**

* « Pourquoi… », « est-ce que… », « n'a-t-on pas… », « a-t-on encore besoin de… », « qu'as-tu
  fait… » : toutes appellent une phrase, pas un commit.
* Interdit : lire une question, y voir un défaut, et partir écrire du code. La réponse se noie
  alors dans des travaux que personne n'a demandés, et il faut défaire pour discuter.
* Quand la réponse appelle un changement, on le **décrit** — ce qu'on toucherait, ce que ça casse,
  ce que ça coûte — et on attend le feu vert.
* Un doute sur la nature de la demande se traite comme une question.

## Le projet

Livre de cuisine digital familial. Un seul projet Flutter (`kass_dalle/`) sert Android, iOS, Web et
Windows desktop. Backend Firebase (Auth Google, Firestore, Storage, Hosting) + Cloud Functions
Node 22 / TypeScript. L'IA (Google Gemini) n'est **jamais** appelée depuis le client : tout passe
par les Functions, la clé vit dans Secret Manager.

Projet Firebase : `kassdale-6d948`. État : Riverpod. Navigation : go_router.
Recettes au format CookLang. Rôles : `admin`, `editor`, `reader`.

## Bonnes pratiques code — aucun `catch` silencieux

C'est la règle la plus stricte du projet.

* **TypeScript (Functions)** : appeler `logError(...)` depuis `../logging` — y compris pour les
  erreurs best-effort, avant de retourner un résultat dégradé. À défaut, `console.error`.
* **Dart/Flutter** : dans les repositories et services, utiliser
  `_errorReportService.reportError(feature:, error:, stackTrace:, context:)`
  (injecté par constructeur, `ErrorReportService()` par défaut).
  **`debugPrint` seul ne suffit pas** : il est invisible dans les rapports d'erreurs en production.
* Un `catch (_) {}` ou un `.catch(() => undefined)` est interdit sans justification écrite.

## Redimensionner ne modifie jamais l'originale (règle absolue)

Une recette est partagée : plusieurs membres l'adaptent en même temps, chacun pour un
nombre de parts différent. Adapter n'écrit **jamais** dans la recette d'origine.

* **Dérivée** (préférée) : ne stocker que le contexte (`base_portions`, `target_portions`)
  et recalculer à l'affichage — ce que fait le planning.
* **Copie attachée** : si l'adaptation dépasse l'échelle, une copie possédée par son
  porteur (le repas planifié), invisible dans les livres et la recherche.
* **Copie volante** : redimensionnement ponctuel, en mémoire, non persisté.

Un état propre à un utilisateur (parts, nutrition recalculée, courses) vit sous
`users/{uid}/…`, jamais dans le document commun. Une violation est silencieuse :
chacun écrase le résultat de l'autre sans qu'aucune erreur ne soit levée.

Avant de créer un porteur, vérifier que l'adaptation a besoin d'être **stockée** : une
valeur dérivable (calories par portion = `totaux / N`) se calcule à l'affichage. Si un
stockage est nécessaire, le porteur est l'objet qui porte déjà le contexte — le repas
planifié, couple (personne, date) — et non le profil, qui n'a pas de date.

## Bac à sable (règle absolue)

`kass_dalle/lib/features/sandbox/` est le terrain d'essai des fonctionnalités expérimentales
(Admin → Bac à sable, rôle `admin`).

* **Il ne modifie jamais le code de l'application.** Il le lit, l'importe et l'appelle. Il ne
  l'édite pas. Un comportement à changer se **copie** dans `features/sandbox/` : dériver oui,
  éditer non.
* Quatre accrochages font exception, une fois pour toutes : la route, l'entrée du menu Admin,
  l'export de `sandboxFn` dans `functions/src/index.ts`, et cette règle. Ajouter une expérience
  n'en touche aucun — une entrée dans `sandbox_registry.dart`, un écran sous
  `presentation/experiments/`, au besoin un `case` dans le `switch` de `sandboxFn`.
* Côté serveur : `functions/src/sandbox/`, **une seule** fonction déployée (`sandboxFn`,
  réservée aux administrateurs), qui aiguille sur un champ `experiment`.
* Un poste d'IA du bac à sable coûte de l'argent réel : il s'inscrit aux trois endroits
  habituels, sous le groupe « Bac à sable ».
* **Rien n'y est enregistré** : ni Firestore, ni Storage en production. Tout reste en mémoire.
* **Aucune release** ne le contient. Rien n'y est promis, ni documenté dans
  `FunctionalRequirements.md`. Une expérience peut disparaître sans migration.
* Une expérience validée ne se branche pas : elle est **réécrite** dans la feature concernée,
  et son bloc expérimental est supprimé.
* **Une expérience se choisit portable.** Avant la première ligne, dire où tournera le code
  une fois porté — appareil ou Functions — et n'employer que des technologies disponibles
  là-bas. Une bibliothèque qui n'existe que d'un côté impose l'architecture de la feature
  (le paquet Dart `image` n'a pas d'équivalent en Node : le choisir décidait que
  l'extraction resterait côté client, donc synchrone).
* Quand un portage est inévitable : prompts, seuils et constantes se recopient à
  l'identique ; le calcul rejoint « Logique dupliquée Dart ↔ TypeScript » avec sa fixture.
* Une expérience progresse par **étapes empilées** : un bloc n'apparaît que si le précédent a
  abouti.
* **Aucun `catch` silencieux**, ici non plus : `ErrorReportService`, feature préfixée `sandbox.`.

## Cache web (règle absolue)

Dans `kass_dalle/firebase.json` :

* **Jamais** de `**/*.@(js|css|wasm)` en cache long `immutable`. Seul `canvaskit/**` peut l'être.
* `index.html`, `flutter_service_worker.js`, `flutter_bootstrap.js`, `flutter.js`, `main.dart.js`
  et `version.json` restent en `no-cache, no-store, must-revalidate` (+ `Pragma: no-cache` et
  `Expires: 0` pour `index.html` et le service worker).

## Documentation

Toute la documentation vit dans `documentation/` (sommaire : `documentation/README.md`).
Les diagrammes (architecture, classes, cas d'utilisation, séquences) sont des pages HTML
autonomes avec des blocs Mermaid : `documentation/architecture.html`,
`documentation/diagramme-de-classes.html`, `documentation/cas-d-utilisation.html`,
`documentation/diagrammes-de-sequence.html`. Un changement de modèle, de route, de Cloud
Function ou de flux met à jour le diagramme correspondant dans le même commit.

## Documentation fonctionnelle

* Fichier cible : `documentation/FunctionalRequirements.md`.
* Décrire l'intention et le contexte de l'application.
* Décrire les parties de l'application et chaque fonctionnalité avec un niveau de détail
  exploitable par un humain ou une IA.
* Couvrir mobile (iOS/Android), web et desktop.
* Décrire les rôles `admin`, `editor`, `reader` et les règles d'accès.

## Documentation technique

* Fichier cible : `documentation/TechnicalRequirements.md`.
* Décrire l'architecture générale, Firebase backend, puis desktop/web/mobile.
* Inclure le schéma Firestore complet (champs + types).
* Inclure les règles Firebase Security (Firestore + Storage).
* Inclure le prompt Gemini structuré et la gestion de la réponse JSON.

## Déploiement et release

* Toujours utiliser le script racine `deploy.ps1` (ne pas régénérer les commandes de build/deploy
  à la main).
* Déployer : `./deploy.ps1` (ou `./deploy.ps1 -WebOnly` si web uniquement).
* Après un travail demandé : résumer en français, incrémenter `version:` dans
  `kass_dalle/pubspec.yaml`, exécuter `./deploy.ps1`, puis annoncer la version déployée
  (ex. `Déployé en v0.19.37`).
* Release complète : mettre à jour `documentation/FunctionalRequirements.md`,
  `documentation/TechnicalRequirements.md`,
  `README.md` (racine et `kass_dalle/README.md`), builder le desktop
  (`flutter build windows --release`), exécuter `./deploy.ps1`, puis copier desktop dans
  `Release/desktop`.

## Intégration continue

* `.github/workflows/ci.yml` rejoue à chaque push : côté Flutter `pub get`,
  `flutter analyze` (strict), `dart format` vérifié, `flutter test`,
  `flutter build web --release` ;
  côté Functions `npm ci`, `npm run lint`, `npm run format:check` (Prettier),
  `npm run build`, `npm test`.
* Le format est vérifié des deux côtés, pas seulement recommandé : un dépôt à
  moitié formaté fait qu'un `dart format` ou un `prettier` lancé sur un fichier
  en reformate dix autres, et noie chaque diff.
* Erreurs, warnings **et infos** sont bloquants côté Flutter — le code part de
  zéro diagnostic. ESLint applique la règle cardinale côté TypeScript :
  `no-empty` (`allowEmptyCatch: false`) et `caughtErrors: "all"`.
* Ne jamais rendre la CI verte en désactivant une règle : corriger le code.

## Logique dupliquée Dart ↔ TypeScript

Quatre logiques métier existent en double, plus deux résidus, asservies par les fixtures
`kass_dalle/test-fixtures/`, rejouées par **les deux** suites (`kass_dalle/test/*_test.dart`
et `functions/src/tests/`) :

| Fixture | Logique |
|---|---|
| `cooklang_parsing.json` | parseur CookLang, index de recherche, libellés de type de page |
| `quantity_parsing.json` | parsing de quantité |
| `unit_to_grams.json` | conversion d'unités en grammes |
| `ingredient_names.json` | identité d'un ingrédient dans le référentiel |
| `ai_pricing.json` | résolution d’un modèle et coût d’un appel — les prix vivent dans `app_config/ai_pricing`, plus aucun en double |
| `planning_slot_rules.json` | dessert, nature du créneau, jour de préparation — **serveur seul**, le client ne les rejoue plus |
| `meal_storage_rules.json` | seuils d'hygiène — constantes seules, la décision n'existe que côté client |
| `page_homography.json` | redressement d'une page : taille de sortie et homographie. Le client redresse à la main dans l'atelier, le serveur redresse tout seul à l'import |

* **La duplication est un coût, pas une méthode.** Ne dupliquer que si les deux
  côtés ont un besoin propre — le client pour afficher ou travailler hors ligne,
  le serveur pour décider sans lui. Écrire le jumeau « par symétrie » ajoute une
  divergence possible sans rien rendre.
* Corriger un bug d'un seul côté fait échouer la CI de l'autre.
* Ajouter le cas dans la fixture **avant** de corriger.
* Les écarts assumés vivent dans la fixture concernée, datés et justifiés :
  les réduire est un objectif, les ignorer ne l'est pas.
* **Aucune valeur de repli figée dans le code** — ni prix, ni taux de change. Une
  constante appliquée à la place de la donnée réelle produit un montant périmé
  présenté comme exact. Sans donnée : afficher la panne, ou l'unité d'origine.

## Un poste d'IA vit à trois endroits

Un nouveau poste de coût s'ajoute aux trois dans le **même commit** :

| Où | Quoi | Ce qui casse s'il manque |
|---|---|---|
| `ctx.feature` de l'appel | l'imputation | rien |
| `ROUTABLE_FEATURES` (`callable/aiRoutingCallable.ts`) | le routage | le poste ne peut plus basculer vers Claude |
| `feature_catalog.dart` (`kFeatureCatalog` **et** `kFeatureProcess`) | la lecture | le poste s'affiche sous sa clé technique, dans « Autres » |

Aucun oubli ne lève d'erreur : le coût reste compté, il devient seulement
illisible. Les variantes `_batch` sont des postes à part entière. Un poste
retiré du code reste au catalogue — les mois déjà comptabilisés le nomment.

## Git

* Faire un commit qui résume les derniers ajouts puis `git push`.
* Ne jamais utiliser `mcp_gitkraken_gitlens_commit_composer`.
* **Aucun artefact de build ne doit être versionné** : `build/`, `Release/`, `.dart_tool/`,
  `node_modules/` sont ignorés.

## Agents

Trois agents spécialisés, définis dans `.claude/agents/` (Claude Code) et `.github/agents/`
(Copilot) : `business-analyst-culinaire`, `developpement-tech-couts`, `product-owner-release`.
Aucun agent ne déclenche `deploy.ps1` de sa propre initiative.

## Commandes longues

* Ne jamais rendre la main pendant une commande longue.
* Attendre la fin complète et donner le résultat final dans la même réponse.
* En cas d'échec, diagnostiquer et corriger avant de répondre.
