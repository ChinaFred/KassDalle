# CLAUDE.md — Kass'Dalle

**Source de vérité des instructions IA de ce dépôt.**

Le fichier `.github/instructions/instructions-ia.instructions.md` en est le miroir compact destiné
à GitHub Copilot. Toute évolution de règle se fait **ici d'abord**, puis est répercutée dans le
miroir. En cas de contradiction entre les deux, ce fichier fait foi.

## Ton

Commencer chaque réponse par « Maître, » (ou une variante créative avec « Maître »).
Répondre en français.

## Le projet

Livre de cuisine digital familial. Un seul projet Flutter (`kass_dalle/`) sert Android, iOS, Web et
Windows desktop. Backend Firebase (Auth Google, Firestore, Storage, Hosting) + Cloud Functions
Node 22 / TypeScript. L'IA (Google Gemini) n'est **jamais** appelée depuis le client : tout passe par
les Functions, la clé vit dans Secret Manager.

Projet Firebase : `kassdale-6d948` — https://kassdale-6d948.web.app

## Structure

```
kass_dalle/lib/
├── core/        # services transverses, router, thème, providers, app_version
└── features/    # admin, annotations, auth, books, groups, planning, processing, recipes, search
                 # chaque feature en couches data/ domain/ presentation/
kass_dalle/functions/src/
├── callable/    # entrées HTTPS callable (gemini, nutrition, billing, logs)
├── gemini/      # extractor, refiner, tagger, enhancer, imageGenerator, planning, shopping, pricing
├── nutrition/   # per100g, conversions de quantités, référentiel d'unités
├── pipeline/    # jobDispatcher, recipeProcessor, deadLetterHandler (Cloud Tasks)
└── triggers/    # Firestore triggers
```

État : Riverpod. Navigation : go_router. Recettes stockées au format CookLang.
Rôles : `admin`, `editor`, `reader`.

## Règles de code

**Aucun `catch` silencieux.** C'est la règle la plus stricte du projet.

- TypeScript (Functions) : appeler `logError(...)` depuis `../logging` — y compris pour les erreurs
  best-effort, avant de retourner un résultat dégradé. À défaut, `console.error`.
- Dart/Flutter : dans les repositories et services, utiliser
  `_errorReportService.reportError(feature:, error:, stackTrace:, context:)`
  (injecté par constructeur, `ErrorReportService()` par défaut).
  `debugPrint` seul ne suffit pas : il est invisible dans les rapports d'erreurs en production.

## Cache web — règle absolue

Dans `kass_dalle/firebase.json` :

- **Jamais** de `**/*.@(js|css|wasm)` en `immutable`. Seul `canvaskit/**` peut l'être.
- `index.html`, `flutter_service_worker.js`, `flutter_bootstrap.js`, `flutter.js`, `main.dart.js`
  et `version.json` restent en `no-cache, no-store, must-revalidate` (+ `Pragma: no-cache` et
  `Expires: 0` pour `index.html` et le service worker).

Un cache long sur ces fichiers laisse les utilisateurs bloqués sur une ancienne version.

## Déploiement

Toujours passer par le script racine `deploy.ps1`. Ne jamais reconstituer les commandes de
build/deploy à la main.

```powershell
./deploy.ps1              # web + APK Android + functions + hosting/firestore/storage + Release/ + git push
./deploy.ps1 -WebOnly     # web uniquement
./deploy.ps1 -Message "…" # message de commit personnalisé
./deploy.ps1 -SkipGit
./deploy.ps1 -ResumeHostingOnly
```

Le script synchronise `lib/core/app_version.dart` depuis `pubspec.yaml`, mais **ne bump pas la
version**. Séquence après un travail demandé :

1. résumer le travail en français ;
2. incrémenter `version:` dans `kass_dalle/pubspec.yaml` ;
3. exécuter `./deploy.ps1` ;
4. annoncer la version déployée (ex. `Déployé en v0.19.37`).

Pour une release complète : mettre aussi à jour `FunctionalRequirements.md`,
`TechnicalRequirements.md`, `README.md` (racine et `kass_dalle/README.md`), builder le desktop
(`flutter build windows --release`), puis copier dans `Release/desktop`.

## Documentation à tenir à jour

- `FunctionalRequirements.md` — intention, parcours, modules, rôles et règles d'accès, couverture
  mobile / web / desktop.
- `TechnicalRequirements.md` — architecture, schéma Firestore complet (champs + types), Firebase
  Security Rules (Firestore + Storage), prompt Gemini structuré et traitement de la réponse JSON.

## Commandes utiles

```powershell
cd kass_dalle
flutter analyze
flutter test
flutter run -d chrome

cd kass_dalle/functions
npm run build     # tsc
npm run lint
npm run serve     # émulateurs functions + firestore + storage + auth
npm run logs
```

## Agents

Trois agents spécialisés vivent dans `.claude/agents/` (format Claude Code) et
`.github/agents/` (format Copilot — miroir) :

| Agent | Quand l'utiliser |
|---|---|
| `business-analyst-culinaire` | cadrage fonctionnel, user stories, priorisation, KPIs |
| `developpement-tech-couts` | implémentation, correction de bug, traçabilité des coûts Gemini |
| `product-owner-release` | scope de release, décision go/no-go, plan de livraison |

Aucun agent ne déclenche `deploy.ps1` : le déploiement reste une décision utilisateur explicite.

## Git

Faire un commit qui résume les ajouts, puis `git push`.
Ne jamais utiliser `mcp_gitkraken_gitlens_commit_composer`.

**Aucun artefact de build ne doit être versionné.** `Release/` est intégralement ignoré
(`build/`, `Release/`, `.dart_tool/`, `node_modules/`). Un dépôt qui grossit de plusieurs Mo par
release est un dépôt cassé.

## Commandes longues

Ne pas rendre la main pendant une commande longue : attendre la fin complète et donner le résultat
final dans la même réponse. En cas d'échec, diagnostiquer et corriger avant de répondre.
