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

## Cache web (règle absolue)

Dans `kass_dalle/firebase.json` :

* **Jamais** de `**/*.@(js|css|wasm)` en cache long `immutable`. Seul `canvaskit/**` peut l'être.
* `index.html`, `flutter_service_worker.js`, `flutter_bootstrap.js`, `flutter.js`, `main.dart.js`
  et `version.json` restent en `no-cache, no-store, must-revalidate` (+ `Pragma: no-cache` et
  `Expires: 0` pour `index.html` et le service worker).

## Documentation fonctionnelle

* Fichier cible : `FunctionalRequirements.md` (racine).
* Décrire l'intention et le contexte de l'application.
* Décrire les parties de l'application et chaque fonctionnalité avec un niveau de détail
  exploitable par un humain ou une IA.
* Couvrir mobile (iOS/Android), web et desktop.
* Décrire les rôles `admin`, `editor`, `reader` et les règles d'accès.

## Documentation technique

* Fichier cible : `TechnicalRequirements.md` (racine).
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
* Release complète : mettre à jour `FunctionalRequirements.md`, `TechnicalRequirements.md`,
  `README.md` (racine et `kass_dalle/README.md`), builder le desktop
  (`flutter build windows --release`), exécuter `./deploy.ps1`, puis copier desktop dans
  `Release/desktop`.

## Intégration continue

* `.github/workflows/ci.yml` rejoue à chaque push : côté Flutter `pub get`,
  `flutter analyze` (strict), `flutter test`, `flutter build web --release` ;
  côté Functions `npm ci`, `npm run lint`, `npm run build`, `npm test`.
* Erreurs, warnings **et infos** sont bloquants côté Flutter — le code part de
  zéro diagnostic. ESLint applique la règle cardinale côté TypeScript :
  `no-empty` (`allowEmptyCatch: false`) et `caughtErrors: "all"`.
* Ne jamais rendre la CI verte en désactivant une règle : corriger le code.

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
