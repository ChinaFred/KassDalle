---
description: Instructions pour le projet KassDalle - toujours actives
applyTo: "**"
---

Instructions KassDalle (version compacte)
Commence toute interaction par "Maître," ou une salutation + " Maitre" ou "bien entendu Maître" ou sois créatif. 
Documentation fonctionnelle
* Fichier cible: `FunctionalRequirements.md` (le créer à la racine s'il n'existe pas).
* Décrire l'intention et le contexte de l'application.
* Décrire les parties de l'application et chaque fonctionnalité avec un niveau de détail exploitable par un humain ou une IA.
* Couvrir mobile (iOS/Android), web et desktop.
* Décrire les rôles `admin`, `editor`, `reader` et les règles d'accès.

Documentation technique
* Fichier cible: `TechnicalRequirements.md` (le créer à la racine s'il n'existe pas).
* Décrire l'architecture générale, Firebase backend, puis desktop/web/mobile.
* Inclure le schéma Firestore complet (champs + types).
* Inclure les règles Firebase Security (Firestore + Storage).
* Inclure le prompt Gemini structuré et la gestion de la réponse JSON.

Commit
* Faire un commit qui résume les derniers ajouts puis `git push`.
* Ne jamais utiliser `mcp_gitkraken_gitlens_commit_composer`.

Déploiement et release
* Toujours utiliser le script racine `deploy.ps1` (ne pas régénérer les commandes de build/deploy à la main).
* Déployer: `./deploy.ps1` (ou `./deploy.ps1 -WebOnly` si web uniquement).
* Créer la release: mettre à jour docs + README (racine et `kass_dalle/README.md`), builder desktop (`flutter build windows --release`), exécuter `./deploy.ps1`, puis copier desktop dans `Release/desktop`.
* Après un travail demandé: résumer en français, augmenter la version dans `pubspec.yaml`, exécuter `./deploy.ps1`, puis annoncer la version déployée (ex: `Déployé en v0.14.48`).
* Guide détaillé de déploiement disponible dans `kassdalle-deploy.prompt.md`.

Cache web (règle absolue)
* Dans `firebase.json`, ne jamais utiliser `**/*.@(js|css|wasm)` en cache long `immutable`.
* Seul `canvaskit/**` peut être en cache immutable.
* `flutter_service_worker.js` et `index.html` doivent rester en `no-cache, no-store, must-revalidate` + `Pragma: no-cache` + `Expires: 0`.

Commandes longues
* Ne jamais rendre la main pendant une commande longue.
* Attendre la fin complète et donner le résultat final dans la même réponse.
* En cas d'échec, diagnostiquer et corriger avant de répondre.

Bonnes pratiques code
* Aucun `catch` ne doit rester sans logging. Toujours loguer l'erreur (en TypeScript: `logError(...)` ou `console.error`; en Dart: `debugPrint(...)` minimum). Un `catch` silencieux est interdit.
* En TypeScript Firebase Functions, les erreurs best-effort doivent appeler `logError` depuis `../logging` avant de retourner un résultat dégradé.
* En Dart/Flutter : utiliser `_errorReportService.reportError(feature, error, stackTrace, context)` dans les repositories et services (injecté par constructeur, `ErrorReportService()` par défaut). `debugPrint` seul est insuffisant en production car invisible dans les rapports d'erreurs.
