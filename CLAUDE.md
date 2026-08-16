# CLAUDE.md — Kass'Dalle

**Source de vérité des instructions IA de ce dépôt.**

Le fichier `.github/instructions/instructions-ia.instructions.md` en est le miroir compact destiné
à GitHub Copilot. Toute évolution de règle se fait **ici d'abord**, puis est répercutée dans le
miroir. En cas de contradiction entre les deux, ce fichier fait foi.

## Ton

Commencer chaque réponse par « Maître», «Seigneur», «Kassbi», «Majesté»,... ou une variante créative.
Répondre en français.

## Le projet

Livre de cuisine digital familial. Un seul projet Flutter (`kass_dalle/`) sert Android, iOS, Web et
Windows desktop. Backend Firebase (Auth Google, Firestore, Storage, Hosting) + Cloud Functions
Node 22 / TypeScript. L'IA n'est **jamais** appelée depuis le client : tout passe par les Functions,
les clés vivent dans Secret Manager.

Deux fournisseurs d'inférence cohabitent : **Google Gemini** (historique, tous les postes) et
**Anthropic Claude** (activable poste par poste). Le choix se fait dans Firestore
(`app_config/ai_routing_policy`), piloté depuis Admin → Moteur d'IA, jamais par un déploiement.
`functions/src/ai/` porte le routage, la tarification et le client Claude ; `gemini/client.ts` et
`ai/anthropic.ts` sont les **seuls** fichiers autorisés à importer leur SDK respectif.

Projet Firebase : `kassdale-6d948` — https://kassdale-6d948.web.app

## Structure

```
kass_dalle/lib/
├── core/        # services transverses, router, thème, providers, app_version
└── features/    # admin, annotations, auth, books, groups, planning, processing, recipes, search
                 # chaque feature en couches data/ domain/ presentation/
kass_dalle/functions/src/
├── ai/          # routage multi-fournisseur, tarification, client Claude
├── callable/    # entrées HTTPS callable (gemini, nutrition, billing, logs, aiRouting)
├── gemini/      # extractor, refiner, tagger, enhancer, imageGenerator, planning, shopping
├── nutrition/   # per100g, conversions de quantités, référentiel d'unités, huile de friture
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

## Redimensionner ne modifie jamais l'originale — règle absolue

Une recette est un document partagé : plusieurs membres de la famille la lisent, la
planifient et la cuisinent en même temps, chacun pour un nombre de parts différent.
**Adapter une recette à un contexte n'écrit jamais dans la recette d'origine.**

Trois formes admises, par ordre de préférence :

1. **Dérivée** — ne rien stocker d'autre que le contexte (`base_portions`,
   `target_portions`) et recalculer les quantités à l'affichage. C'est ce que fait le
   planning (`planningScaleRecipeForMeal`). Rien ne peut dériver de l'originale, et
   rien n'encombre les livres. À privilégier tant que seule l'échelle change.
2. **Copie attachée** — quand l'adaptation dépasse l'échelle (étapes modifiées,
   ingrédient substitué), une copie rattachée à son porteur : le repas planifié la
   possède, elle disparaît avec lui, et elle **n'apparaît jamais dans les livres ni
   dans la recherche**.
3. **Copie volante** — pour un redimensionnement ponctuel non rattaché, une copie en
   mémoire, non persistée.

Un état propre à un utilisateur — parts choisies, nutrition recalculée pour ces parts,
liste de courses — vit **sous cet utilisateur** (`users/{uid}/…`), jamais dans le
document commun. Le symptôme d'une violation est silencieux : personne ne voit
d'erreur, chacun écrase simplement le résultat de l'autre à tour de rôle.

Avant de créer un porteur pour une adaptation, vérifier qu'elle a besoin d'être
**stockée**. Une valeur dérivable — les calories par portion valent `totaux / N` —
n'appartient à personne : elle se calcule dans le contexte qui l'affiche. C'est ainsi
que la nutrition a cessé d'écrire le choix d'un lecteur dans une recette partagée :
aucun nouveau document, un champ de moins.

Quand un stockage est réellement nécessaire, le porteur est **l'objet qui porte déjà
le contexte** — le repas planifié, qui est le couple (personne, date) — et non le
profil de l'utilisateur, qui n'a pas de date.

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

Pour une release complète : mettre aussi à jour `documentation/FunctionalRequirements.md`,
`documentation/TechnicalRequirements.md`, `README.md` (racine et `kass_dalle/README.md`), builder le
desktop (`flutter build windows --release`), puis copier dans `Release/desktop`.

## Documentation à tenir à jour

**Toute la documentation vit dans `documentation/`.** Rien à la racine, hormis `README.md` et
`CLAUDE.md`. `documentation/README.md` en est le sommaire.

- `documentation/FunctionalRequirements.md` — intention, parcours, modules, rôles et règles d'accès,
  couverture mobile / web / desktop.
- `documentation/TechnicalRequirements.md` — architecture, schéma Firestore complet (champs +
  types), Firebase Security Rules (Firestore + Storage), prompt Gemini structuré et traitement de la
  réponse JSON.
- `documentation/*.html` — documentation visuelle : architecture, diagramme de classes, cas
  d'utilisation, diagrammes de séquence. Diagrammes en **Mermaid** (` ```mermaid ` dans un
  `<pre class="mermaid">`), rendus nativement par les Artifacts claude.ai et via le CDN Mermaid
  quand le fichier est ouvert localement.

Quand un modèle de domaine, une Cloud Function, une route ou un flux change, mettre à jour le
diagramme correspondant dans le même commit — un diagramme faux coûte plus cher qu'un diagramme
absent.

## Commandes utiles

```powershell
cd kass_dalle
flutter analyze
flutter test
flutter run -d chrome

cd kass_dalle/functions
npm run build     # tsc
npm run lint
npm run format    # prettier (largeur 100, voir prettier.config.mjs)
npm test          # node --test sur les fixtures partagées avec Dart
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

## Intégration continue

`.github/workflows/ci.yml` rejoue à chaque push et chaque PR :

| Job | Étapes |
|---|---|
| Flutter | `pub get`, `flutter analyze` (strict), `dart format` vérifié, `pubspec.lock` à jour, `flutter test`, `flutter build web --release` |
| Functions | `npm ci`, `npm run lint` (ESLint 9 flat config), `npm run format:check` (Prettier), `npm run build` (tsc), `npm test` |

## Logique dupliquée Dart ↔ TypeScript

Quatre logiques métier existent en double, plus deux résidus : parseur CookLang
(dont l'index de recherche et les libellés de type de page), parsing de
quantité, conversion d'unités en grammes, normalisation des noms d'ingrédients.
S'y ajoutent l'arithmétique de la **grille tarifaire** — dont les prix, eux, ne
sont plus qu'à un endroit — et deux **seuils d'hygiène** du planning.
`kass_dalle/test-fixtures/*.json` sont rejouées par **les deux** suites
(`kass_dalle/test/*_test.dart` et `functions/src/tests/`).

| Fixture | Logique | Dart | TypeScript |
|---|---|---|---|
| `cooklang_parsing.json` | parseur, index, type de page | `core/services/cooklang_parser.dart` | `cooklang/parser.ts` |
| `quantity_parsing.json` | parsing de quantité | `core/utils/nutrition_quantity_converter.dart` | `nutrition/quantityConversion.ts` |
| `unit_to_grams.json` | conversion en grammes | idem | idem |
| `ingredient_names.json` | identité d'un ingrédient | `core/utils/ingredient_name.dart` | `nutrition/ingredientName.ts` |
| `ai_pricing.json` | résolution d'un modèle et coût d'un appel — **plus aucun prix en double** | `features/admin/data/ai_pricing.dart` | `ai/pricing.ts` |
| `planning_slot_rules.json` | dessert, nature du créneau, jour de préparation — **serveur seul** | — | `gemini/planning.ts` |
| `meal_storage_rules.json` | seuils d'hygiène (constantes seules) | `features/planning/domain/meal_storage_rules.dart` | `gemini/storageAdvice.ts` |

La tarification est le cas le plus sournois : un écart n'y casse aucun écran et
ne lève aucune erreur, il fait seulement mentir le reporting de coûts — le
chiffre continue de s'afficher. Les prix ont donc quitté le code pour Firestore
(`app_config/ai_pricing`, écran Admin → Moteur d'IA) : les deux côtés lisent le
même document, et **plus aucun tarif n'existe en double**. Ce qui reste ici, ce
sont les règles de lecture — résoudre un identifiant de modèle, décider si une
promotion court, multiplier des jetons par un prix — appliquées à une table
reçue en argument. C'est la sortie type d'une logique dupliquée : déplacer la
donnée là où les deux peuvent la lire, et ne garder en double que du calcul.

**Et pas de repli.** Une grille illisible ne se remplace pas par la table du
code : ce serait un prix périmé présenté comme exact. L'écran affiche « tarifs
en panne », et les appels passés pendant ce temps sont enregistrés **sans
montant**, comptés dans `total_unpriced_calls`. Un coût manquant se voit ; un
coût faux ne se voit pas. La table du serveur ne sert qu'à **semer** le document
au premier démarrage. Les règles de créneau sont de la même famille :
un désaccord laisse passer un dessert d'un côté, décale un jour de préparation
de l'autre, sans jamais lever d'erreur.

**La duplication est un coût, pas une méthode.** Avant d'ajouter une ligne à ce
tableau, chercher à ne pas la créer : la logique n'existe en double que si les
**deux** côtés en ont un besoin propre — le client pour afficher ou travailler
hors ligne, le serveur pour décider sans lui. Écrire le jumeau « par symétrie »
ajoute une divergence possible sans rien rendre. `meal_storage_rules` en est
l'exemple : la décision réfrigérateur/congélateur n'existe que côté client, qui
seul l'affiche ; le serveur ne reprend que les deux seuils cités dans son
prompt, et la fixture ne verrouille que ces nombres.

Les règles de créneau ont fait le chemin inverse et **quitté le client** : il
les rejouait pour combler les créneaux que le serveur laissait vides. Ce filet
coûtait la duplication entière des règles de variété, de dessert et de jour de
préparation, et rendait un service douteux — il masquait qu'aucune suggestion
n'avait été rendue, et une recette choisie par lui s'affichait comme une
décision de l'IA. Un créneau vide est plus honnête.

**Et pas de valeur de repli figée dans le code.** Ni les prix, ni le taux de
change : une constante appliquée à la place de la donnée réelle produit un
montant périmé présenté comme exact. Sans donnée, on affiche la panne (grille
tarifaire) ou l'unité d'origine (dollars, faute de taux) — jamais une valeur
plausible.

Corriger un bug d'un seul côté fait échouer la CI de l'autre. Ajouter le cas dans la
fixture **avant** de corriger. Les écarts assumés vivent dans la section `divergences`
de `unit_to_grams.json` : les réduire est un objectif, les ignorer ne l'est pas.

**Erreurs et warnings sont bloquants des deux côtés.** ESLint applique la règle
cardinale du projet : `no-empty` avec `allowEmptyCatch: false`, et `caughtErrors: "all"`
— un `catch` dont l'erreur n'est pas utilisée fait échouer la CI.

Ne jamais rendre la CI verte en désactivant une règle : corriger le code.

## Un poste d'IA vit à trois endroits

Même famille de panne que la tarification, et même silence. Un nouveau poste de
coût s'ajoute aux trois endroits dans le **même commit** :

| Où | Quoi | Ce qui casse s'il manque |
|---|---|---|
| `ctx.feature` de l'appel | l'imputation du coût | rien |
| `ROUTABLE_FEATURES` (`callable/aiRoutingCallable.ts`) | le routage Gemini / Claude | le poste ne peut plus basculer depuis Admin → Moteur d'IA |
| `feature_catalog.dart` — `kFeatureCatalog` **et** `kFeatureProcess` | la lecture comptable | le poste s'affiche sous sa clé technique, rangé dans « Autres » |

Aucun de ces oublis ne lève d'erreur ni ne fausse un montant : le coût est
compté, il devient seulement illisible. Toute la chaîne nutrition — quinze
postes, les plus fréquents de l'application — a vécu ainsi.

Les variantes `_batch` sont des postes à part entière : les distinguer de leur
version unitaire est le seul moyen de vérifier que le groupage fait son office.
Un poste retiré du code **reste** au catalogue, sinon les mois déjà
comptabilisés cessent de le nommer. `test/feature_catalog_test.dart` garde la
cohérence des deux tables entre elles.

## Git

Faire un commit qui résume les ajouts, puis `git push`.
Ne jamais utiliser `mcp_gitkraken_gitlens_commit_composer`.

**Aucun artefact de build ne doit être versionné.** `Release/` est intégralement ignoré
(`build/`, `Release/`, `.dart_tool/`, `node_modules/`). Un dépôt qui grossit de plusieurs Mo par
release est un dépôt cassé.

## Commandes longues

Ne pas rendre la main pendant une commande longue : attendre la fin complète et donner le résultat
final dans la même réponse. En cas d'échec, diagnostiquer et corriger avant de répondre.
