# Kass'Dalle — Spec : atelier repas conversationnel dans Explorer

> Statut : palier 0 livré dans le bac à sable (v0.24.72, v0.24.75) ; palier 1 validé le
> 6 novembre 2026 et livré en v0.24.76 ; palier 2 cadré et validé le 7 novembre 2026, livré
> en v0.24.78. Sur grand écran, « Composer un repas » est rangé dans le menu « Créer avec
> l'IA » d'Explorer depuis la v0.24.80 ; l'écran sur téléphone (clavier ouvert, grand texte)
> est corrigé en v0.24.81. Première mesure des coûts en production le 7 novembre 2026 (§3,
> « Mesures en production ») ·
> Auteur : business-analyst-culinaire · 1er novembre 2026, mis à jour le 7 novembre 2026
> Ce document décrit le **quoi** et le **pourquoi**. Le parcours et la disposition des écrans
> reviennent à `ux-designer` ; l'implémentation à `developpement-tech-couts`.
> Le palier 0 vit dans le bac à sable et n'entre ni dans `FunctionalRequirements.md` ni dans
> `cas-d-utilisation.html`. Le palier 1 y est décrit depuis le 6 novembre 2026 (§10).

Les décisions du 1er novembre 2026 (cinquième action d'Explorer, écran en deux zones, JSON du
menu à chaque tour, une recette par plat figé, choix du livre, 30 tours par jour, trois
paliers) sont acquises. Elles sont reprises ici telles quelles, sans être rouvertes.

---

## 1. Intention

Le besoin, dans les mots de l'utilisateur : « J'aime bien discuter de repas avec une IA et
échanger sur les accords possibles. Cet aspect-là je ne le retrouve pas dans Explorer. »

Aujourd'hui, l'application compte quatre postes d'IA qui touchent à l'idée d'un repas. Tous
répondent **en un coup** et n'ont **aucune mémoire** d'un appel à l'autre :

| Action | Fichier | Ce qu'elle rend | Historique |
|---|---|---|---|
| « Chercher avec l'IA » (Explorer) | `functions/src/gemini/search.ts`, poste `search` | des identifiants de recettes existantes classés, une raison par recette | aucun |
| « Imaginer 3 recettes » (Explorer) | `search_providers.dart`, `AiIdeasNotifier` | trois recettes rédigées, par trois angles figés (« Fidèle », « Rapide », « Créative »), en parallèle | aucun |
| « Générer avec l'IA » (sélecteur du planning) | `functions/src/gemini/mealIdeas.ts`, poste `planning_meal_ideas` | trois idées (titre, phrase, durées) ; la relance transporte au plus 15 titres à ne pas reprendre | les titres seuls, pas la discussion |
| Conception d'une recette (planning) | `functions/src/gemini/planning.ts`, `generateRecipeConcept`, poste `planning_concept` | une recette CookLang pour un plat demandé ou pour un créneau | aucun |

Aucune ne tient l'état d'un **menu** — entrée, plat, accompagnements, fromage, dessert — d'un
échange au suivant. Aucune ne permet « remplace le dessert » ou « et avec du poisson à la
place ? ». L'atelier repas ajoute cette mémoire : une conversation bornée, et un menu
structuré que le modèle met à jour à chaque tour.

Valeur pour la famille : composer un repas complet en discutant des accords, puiser dans la
bibliothèque quand une recette existe déjà, et garder le résultat sous la forme que
l'application connaît — des recettes en brouillon, puis un repas planifié avec ses services.

Hors besoin : l'atelier ne remplace ni « Chercher avec l'IA » (classer l'existant), ni
« Imaginer 3 recettes » (trois rédactions d'un seul plat), ni le planning (une semaine
entière). Il s'arrête à **un repas**.

---

## 2. User stories

### Editor et Admin

- **US-1 Ouvrir l'atelier.** Depuis Explorer, j'ouvre « Composer un repas avec l'IA ». Le
  périmètre est celui que mes filtres retiennent à ce moment-là. L'écran me dit combien de
  recettes de la bibliothèque le modèle connaît pour cette conversation.
- **US-2 Discuter.** J'écris ce que j'ai envie de manger, pour qui, avec quelles contraintes.
  Le modèle répond en texte et pose un premier menu dans le panneau « Menu en cours ».
- **US-3 Affiner.** Je demande « remplace le dessert », « sans gluten pour l'entrée »,
  « poulet ou poisson ? ». Le texte répond ; le menu se redessine. Rien d'autre ne change
  dans le menu que ce que j'ai demandé.
- **US-4 Puiser dans la bibliothèque.** Quand une recette du périmètre convient, le modèle la
  cite par son identifiant et le panneau l'affiche comme recette existante (titre, livre).
  Un plat qui n'existe pas est marqué « à rédiger ».
- **US-5 Figer.** J'appuie sur « Figer le repas ». Je choisis le livre : « Mes créations
  Kass'Dalle ✨ » (par défaut) ou « Mes recettes libres ». Chaque plat à rédiger devient un
  brouillon à relire ; chaque recette existante reste liée, sans copie. Je vois la liste des
  brouillons créés et je peux ouvrir chacun.
- **US-6 Poser dans le planning** (palier 2). Après avoir figé, je pose le repas à une date,
  dans mon planning ou dans celui d'un groupe que je possède (§9.5) : un repas planifié naît
  avec ses services, pour le nombre de parts du menu, sans appel d'IA. Je peux le poser à
  une seconde date ; chaque pose est un repas de plus, qui pointe les mêmes brouillons.
- **US-7 Savoir ce que ça coûte.** Sous le champ, je lis le nombre de tours qu'il me reste
  aujourd'hui. Plafond atteint, je garde le menu et je peux encore le figer.
- **US-8 Quitter sans perdre par surprise.** Si je quitte avec une conversation en cours et
  rien de figé, l'application me demande « Quitter sans enregistrer ? ».

### Admin seul

- **US-9 Régler le prompt** (palier 0). Depuis Admin → Bac à sable, j'ouvre l'expérience
  « Atelier repas », je converse, je lis le JSON brut du menu rendu à chaque tour et le coût
  du tour. Rien n'est écrit.
- **US-10 Suivre la dépense.** Dans Admin → Comptabilité, les deux postes de l'atelier
  s'affichent sous leur libellé, dans leur groupe, et non sous une clé technique dans
  « Autres ».

### Reader : ce qu'il ne voit pas, et pourquoi

Le Reader ne voit pas « Composer un repas avec l'IA », ni sur téléphone (barre du bas,
« Aller plus loin ») ni sur grand écran. Deux raisons, toutes deux déjà posées dans
`FunctionalRequirements.md` §3.2 :

1. **Il ne crée aucune recette.** La sortie de l'atelier est une recette en brouillon ; « ni
   recette conçue par l'IA (Explorer, planning) » lui est fermé.
2. **Chaque tour est un appel facturé.** « Chercher avec l'IA » et « Imaginer 3 recettes »
   lui sont déjà masqués pour cette raison ; seule « Chercher sur le web » lui reste ouverte,
   par décision de l'administrateur. L'atelier suit la règle générale, pas l'exception.

Le serveur refuse l'appel d'un Reader (`requireEditor`), comme pour `searchRecipesFn`. Un
Reader qui ouvrirait la route par un lien lit « Composition réservée aux éditeurs » et
« Retour à Explorer » — même forme que « Modification réservée aux éditeurs ».

---

## 3. Critères d'acceptation par palier

### Palier 0 — bac à sable (Admin → Bac à sable)

Ce palier ne livre rien à l'utilisateur. Il règle le prompt et mesure. Il respecte la section
« Bac à sable » de `CLAUDE.md` : une entrée dans `sandbox_registry.dart`, un écran sous
`features/sandbox/presentation/experiments/`, un `case` dans le `switch` de `sandboxFn`
(`functions/src/sandbox/callable.ts`). Aucun autre fichier de l'application n'est modifié.

Portabilité : le code tourne dans les Functions (TypeScript) pour l'appel de modèle et le
contrôle de la réponse, dans Flutter pour l'écran. C'est l'architecture des paliers 1 et 2.
Rien à porter.

| # | Critère | Vérification |
|---|---|---|
| P0-1 | L'expérience n'est accessible qu'au rôle `admin` ; `sandboxFn` refuse tout autre compte avant l'aiguillage. | test existant de `requireAdmin` en tête du handler ; essai avec un compte Editor |
| P0-2 | Un poste `sandbox_meal_workshop_turn` est inscrit aux trois endroits (`ctx.feature`, `ROUTABLE_FEATURES`, `kFeatureCatalog` et `kFeatureProcess`), groupe « Bac à sable ». | `test/feature_catalog_test.dart` ; le poste apparaît dans Admin → Moteur d'IA et dans la comptabilité |
| P0-3 | L'écran a deux zones : la conversation, et le menu en cours redessiné depuis le JSON du dernier tour. Le JSON brut est lisible dans un volet « Réponse brute ». | revue d'écran |
| P0-4 | Le contexte envoyé est celui du palier 1 : résumés de recettes par `buildRecipeSummary` (`search_providers.dart`), garnitures de l'utilisateur, `globalConstraints` des préférences du planning. Le périmètre est « Mes recettes » + « Ma famille » de l'administrateur, sans filtres. Note v0.24.75 : copie `buildMealWorkshopSummary` (`features/sandbox/domain/workshop_recipe_summary.dart` : 6 ingrédients, `duree`, sans `livre` ni `statut`). | lecture du code ; nombre de recettes affiché sous le champ |
| P0-5 | Historique borné : 20 tours au plus, 1 500 caractères par message. Le 21e message est refusé par l'écran ; un message plus long est refusé par l'écran et par le serveur. | test unitaire côté serveur sur la lecture de l'entrée ; essai à l'écran |
| P0-6 | Le serveur contrôle le JSON rendu (§5) : rôle hors liste, identifiant hors corpus, plus de 10 services, plus de 6 accompagnements par plat → corrigé ou refusé, et compté. | tests unitaires sur `parseMenuState` (nom indicatif) avec des réponses forgées |
| P0-7 | Rien n'est écrit : ni Firestore, ni Storage. Seules les lignes `ai_usage` du poste existent. | relecture du diff ; aucune écriture dans `functions/src/sandbox/` |
| P0-8 | Chaque tour affiche son coût (`recordedCostUsd`) et la taille du contexte envoyé (caractères, jetons d'entrée). | revue d'écran |
| P0-9 | Aucun `catch` silencieux ; `ErrorReportService` avec feature préfixée `sandbox.`. | `relecteur-regles` |

**Ce que le palier 0 doit prouver avant qu'on écrive le palier 1.** Dix conversations
scénarisées par l'administrateur, chacune de 10 à 20 tours, sur un corpus d'au moins
100 recettes. Pour chaque question, la mesure et le seuil qui autorise le palier 1 :

| Question | Mesure | Seuil |
|---|---|---|
| Le modèle tient-il l'état du menu sur 20 tours ? | nombre de tours où un service non visé par la demande a changé (titre, rôle, accompagnement) | 0 changement non demandé sur au moins 9 conversations sur 10 |
| Cite-t-il une recette existante par son identifiant sans l'inventer ? | nombre d'identifiants hors corpus rendus, comptés par le contrôle serveur (P0-6) | moins de 1 identifiant inventé pour 100 tours ; tout identifiant inventé est neutralisé (recette_id → null) |
| Quand une recette du corpus convient, la cite-t-il plutôt que d'inventer un plat voisin ? | sur 10 demandes conçues pour qu'une recette du corpus réponde, nombre de fois où elle est citée | 8 sur 10 |
| « Remplace le dessert » | le dessert seul change ; les autres services sont identiques au tour précédent | 10 sur 10 |
| « Sans gluten pour l'entrée » | l'entrée change ou est confirmée ; sa description dit en quoi elle est sans gluten ; une recette existante dont `allergens.present` contient `gluten` n'est pas citée pour l'entrée | 9 sur 10 |
| « Poulet ou poisson ? » | le texte propose les deux avec un accord pour chacun ; le menu ne change pas tant que l'utilisateur n'a pas choisi | 9 sur 10 |
| Le JSON est-il lisible à chaque tour ? | tours refusés par le contrôle serveur | moins de 5 % des tours |
| Combien coûte un tour ? | coût moyen et maximal d'un tour, en dollars puis en euros, par taille de corpus (100, 200 recettes) et par longueur d'historique (tour 1, tour 10, tour 20) | chiffre posé dans ce document avant le palier 1 ; il décide si le corpus doit être plafonné (§7) |
| Le texte reste-t-il court ? | longueur moyenne de la réponse texte | moins de 1 200 caractères ; au-delà, le prompt se corrige |
| Le modèle respecte-t-il les préférences du foyer ? | sur 5 demandes qui contredisent `globalConstraints`, le texte le signale et la demande l'emporte (règle de `mealIdeas.ts`) | 5 sur 5 |

Les deux moteurs (Gemini, Claude) sont essayés, puisque le poste est routable. Le compte
rendu du palier 0 tient en une page : les dix lignes du tableau, chiffrées, et les
modifications du prompt qu'elles ont demandées.

### Palier 1 — Explorer : conversation, figer, choix du livre

> **Validé le 6 nov. 2026 avec la proposition d'écran (UX §8).** Les réponses du §9 (parts par
> défaut, périmètre à 0 recette, corpus non plafonné, doublon jamais lié d'office) font partie
> de la validation. Trois critères sont amendés par elle : P1-3 (résumé
> `buildMealWorkshopSummary`), P1-8 (compteur lu dès l'ouverture) et P1-16 (garde de sortie
> pendant et après un figement). Deux critères s'ajoutent : P1-20 (choix Plat | Menu, arrivé au
> palier 0 en v0.24.75) et P1-21 (parts par défaut du menu, §9.1).

Le code du bac à sable n'est pas branché : il est **réécrit** dans
`features/search/` (écran) et dans un module serveur dédié (nom indicatif
`functions/src/gemini/mealWorkshop.ts`, callables dans `functions/src/callable/`). Les
prompts, seuils et constantes réglés au palier 0 sont recopiés à l'identique. Le bloc
expérimental est supprimé de `sandbox_registry.dart` et de `sandboxFn`.

| # | Critère | Vérification |
|---|---|---|
| P1-1 | Explorer porte une cinquième action, « Composer un repas avec l'IA », visible de l'Editor et de l'Admin, absente pour le Reader sur téléphone et sur grand écran. Le tableau des actions de FR §5.5 reçoit sa ligne : « Editor, Admin · un appel par tour, un par plat figé ». | test de widget par rôle ; FR mis à jour |
| P1-2 | L'action ouvre un écran dédié (route go_router à ajouter au §13.1 de `TechnicalRequirements.md`). Ouverte par un lien, la route refuse le Reader : « Composition réservée aux éditeurs », « Retour à Explorer ». | test de route |
| P1-3 | Le périmètre est figé à l'ouverture : les recettes que retiennent les filtres d'Explorer à ce moment, sans le filtre du texte, résumées par `buildMealWorkshopSummary` (6 ingrédients, durée « 35 min » / « ≈ 40 min » estimée / « inconnue », sans livre ni statut ; réécrit depuis `features/sandbox/domain/workshop_recipe_summary.dart`, pas `buildRecipeSummary`), gardées en mémoire pour la conversation. Le texte du champ d'Explorer arrive dans l'atelier sans être envoyé. L'écran affiche « Périmètre : N recettes ». Changer de filtres demande de quitter l'atelier. Une recette à durée inconnue n'est jamais proposée comme rapide. | essai : filtre changé dans Explorer après ouverture, N inchangé ; lecture du résumé envoyé |
| P1-4 | Avec 0 recette dans le périmètre, l'action reste active ; l'écran dit « Aucune recette de la bibliothèque dans le périmètre : l'IA ne proposera que des plats nouveaux. » (différence assumée avec « Chercher avec l'IA », inactif à 0 recette : l'atelier peut inventer, le classement ne peut pas). | essai |
| P1-5 | Deux postes nouveaux, inscrits aux trois endroits dans le même commit : `meal_workshop_turn` (groupe « Recherche », libellé « Atelier repas — tour de conversation ») et `meal_workshop_recipe` (groupe « Rédaction d'une recette », libellé « Atelier repas — recette d'un plat figé »). | `test/feature_catalog_test.dart` |
| P1-6 | Un tour = un appel. Le serveur reçoit l'historique (≤ 20 tours, ≤ 1 500 caractères par message de l'utilisateur), le menu en cours, les résumés du périmètre, les garnitures, `globalConstraints`, le nombre de parts du menu. Il rend le texte et le menu contrôlé (§5). Un message trop long ou un historique trop long est refusé en `invalid-argument`, sans appel de modèle. | tests unitaires sur la lecture de l'entrée ; `_inputBounds.ts` |
| P1-7 | Plafond : 30 tours par jour et par compte, multipliés par `budgetMultiplierFor` comme `webSearchLimit`. La place est réservée dans une transaction sur `meal_workshop_daily/{uid}_{AAAA-MM-JJ}` avant l'appel. Un tour qui échoue avant que le modèle ait répondu n'est pas compté ; un tour dont la réponse est illisible a été facturé : il compte. Refus : `resource-exhausted`, `reason: "meal_workshop_daily_quota"`, `limit`, `remaining: 0`. | tests de la callable ; `rules-tests` pour la collection (lecture : admin ou le compte ; écriture : serveur seul) |
| P1-8 | Sous le champ : « Il vous reste N tours aujourd'hui. » dès l'ouverture (6 nov. 2026 : le compteur est lu à l'ouverture, pas à la première réponse). À 0, le champ est fermé : « Vous avez fait vos 30 tours d'aujourd'hui. Le compteur repart demain. » Le menu reste affiché, « Figer le repas » reste disponible. | essai avec plafond abaissé en test |
| P1-9 | Le budget d'IA du jour (`ai/budget.ts`) s'applique à chaque appel, tour et recette. Refus : `resource-exhausted`, `reason: "ai_daily_budget"`, message `DAILY_LIMIT_MESSAGE`. L'écran préfixe par ce qui n'a pas eu lieu : « Réponse non reçue. » ou « Recette non rédigée. ». | essai avec plafond abaissé |
| P1-10 | « Figer le repas » est actif dès qu'au moins un service porte un titre sans `recipe_id`. Sinon, une ligne explique : « Le menu est vide. » ou « Rien à rédiger : toutes les recettes existent déjà. » | test de widget |
| P1-11 | Au figement, une boîte demande le livre : « Mes créations Kass'Dalle ✨ » coché par défaut, « Mes recettes libres ». Le choix vaut pour tous les brouillons de ce figement. Les deux livres système sont trouvés ou créés pour le compte par `findOrCreateKassDalleBook` et `findOrCreateLibresBook` (`features/books/data/book_repository.dart`, tous deux existants). | essai ; FR §6, lignes « Toute recette a un livre » et « Recette conçue par l'IA en brouillon », amendées |
| P1-12 | Pour chaque service à rédiger, un appel `meal_workshop_recipe` rédige le CookLang comme `generateRecipeConcept` (`buildConceptPrompt` avec `requestedDish` = titre + description du service, `globalConstraints`, `targetPortions` = parts du menu), puis le client crée le brouillon comme `saveGeneratedRecipe` : `review_status: draft`, `origin: ai`, `book_id` choisi, `created_by: uid`, `portions` du menu. Les accompagnements du plat sont passés dans la description du plat demandé (« Servir avec : riz, salade verte ») pour que la recette les mentionne ; ils ne deviennent pas des recettes. | test unitaire sur la construction de l'entrée ; brouillon ouvert et relu |
| P1-13 | Les appels de figement s'enchaînent service par service. Un échec n'annule pas les brouillons déjà créés ; la ligne du service dit « Brouillon créé », « Non rédigée — Réessayer » ou « Non rédigée. L'IA n'a pas rendu de recette. ». Un refus de plafond arrête la suite : les services restants passent « Non rédigée — plafond atteint ». | essai avec échec forcé |
| P1-14 | Une recette existante citée dans le menu n'est ni copiée ni modifiée. Au figement, elle est relue ; si elle n'est plus lisible (supprimée, devenue privée), la ligne dit « Recette plus accessible » et propose « Rédiger à la place » (un appel) ou « Retirer du repas ». | essai : recette passée en livre privé pendant la conversation |
| P1-15 | Doublon de titre : avant l'appel, si un service à rédiger porte le même titre (sans casse ni accents) qu'une recette du périmètre, la ligne propose « Lier la recette existante » ou « Rédiger quand même ». Aucun appel ne part avant la réponse. | test unitaire de la comparaison ; essai |
| P1-16 | Garde de sortie (amendé le 6 nov. 2026) : avec au moins un tour et rien de figé, quitter (retour, menu latéral, barre du bas, déconnexion) pose « Quitter sans enregistrer ? », « Rester » / « Quitter » (`leave_guard.dart`). Pendant un figement : « Figement en cours. Quitter ? » ; les brouillons déjà créés restent. Après un figement complet, l'écran se quitte librement. Après un figement partiel, les services non rédigés sont comptés dans la question : « 1 plat n'est pas rédigé. Quitter sans enregistrer ? ». | essai sur les quatre sorties, dans les quatre états |
| P1-17 | Rien n'est écrit en base avant le figement : aucun document de conversation, aucun brouillon. Les seules écritures d'un tour sont la ligne `ai_usage` et le compteur `meal_workshop_daily`. | relecture du diff ; `rules-tests` |
| P1-18 | Le texte de l'utilisateur n'est jamais journalisé : seule sa longueur part dans les journaux, comme `readWebSearchQuery`. Le texte du modèle s'affiche en texte brut ; un identifiant cité dans le texte n'est pas un lien. Seul le JSON contrôlé fait un lien vers une recette. | relecture ; `securite` |
| P1-19 | Fenêtre de sortie : après figement, on reste dans l'atelier, champ fermé, « Repas figé. », « Nouvelle conversation » ; chaque brouillon créé s'ouvre depuis sa ligne (« Brouillon créé · Ouvrir ») ; la conversation reste affichée jusqu'à la sortie de l'écran, puis disparaît. | essai |
| P1-20 | Choix « Plat \| Menu » en tête de la conversation, « Plat » par défaut, fixé pour une conversation : changer de mode en cours ouvre une nouvelle conversation après confirmation. Mode Plat : un seul service de rôle `plat` avec ses accompagnements (deux services `plat` au plus). Mode Menu : le repas complet, 10 services au plus (§5). « Figer le repas » est le seul libellé dans les deux modes. | test de widget ; test serveur sur le mode reçu |
| P1-21 | Parts par défaut du menu : celles du premier groupe familial actif de l'auteur (le plus ancien par date de création, groupes en pause exclus) — son réglage « Parts des groupes » s'il existe, sinon son nombre de membres ; sans groupe, 4. Modifiables par le bouton des parts (1 à 99). La boîte de figement les rappelle : « 3 plats seront rédigés par l'IA, pour 6 parts : un appel chacun. 1 recette existante reste liée telle quelle, avec ses propres parts. ». | test unitaire de la valeur par défaut (groupe avec réglage, sans réglage, en pause, aucun groupe) |

### Palier 2 — poser dans le planning

> **Cadré et validé le 7 nov. 2026.** Les critères P2-1 à P2-6 du 1er novembre sont
> remplacés par cette version. Les six décisions du jour sont au §9.5 à §9.9 : planning d'un
> groupe possédé admis, parts du menu sur le repas, plat principal sans recette posé par son
> titre, `choice_source: workshop`, pas d'agenda Google à la pose, « Voir le planning » par
> `/planning?date=AAAA-MM-JJ`.

Ce que « poser » fait : un repas planifié naît dans `planned_meals`, par le dépôt du planning
existant (`PlanningRepository.addMeal`, `planning_providers.dart`). Son plat principal est le
premier service `plat` du menu ; les autres services deviennent ses `components`, que le
planning lit comme un menu (`MealComposition`, `meal_composition.dart`). **Aucun appel d'IA**,
aucune écriture dans `recipes`. Le planning sait déjà lire un repas dont la recette est un
brouillon (`planning_screen.dart`, « un repas peut pointer sur un brouillon ») : ouverture de
la fiche, courses, « Changer les parts » et nutrition par portion marchent sans changement,
puisque les déclencheurs nutrition et allergènes tournent sur un brouillon comme sur une
recette validée. Un brouillon porte en plus, sur sa fiche, son état « à relire » ; le repas,
lui, ne le dit pas, comme pour une conception depuis le planning.

| # | Critère | Vérification |
|---|---|---|
| P2-1 | **Quand le bouton apparaît.** Dans le pied du panneau « Menu en cours », « Poser dans le planning » remplace « Figer le repas » dès qu'un figement est terminé (lignes de figement présentes, aucun appel en cours), complet ou partiel. Sans plat à rédiger et menu non vide (aujourd'hui « Rien à rédiger : toutes les recettes existent déjà. », `canFreeze` faux), « Poser dans le planning » prend la place de « Figer » dès le tour : l'appui relit d'abord chaque recette liée comme un figement sans plat à rédiger (P1-14, aucun appel), puis ouvre la boîte. Avant un figement, avec au moins un plat à rédiger, le bouton n'existe pas : on fige d'abord. | test de widget sur les trois états (avant figement, après, rien à rédiger) |
| P2-2 | **Ce qu'il exige.** Un service `plat` dans le menu : sans plat (mode Menu, entrée et dessert seuls, ou plat retiré par « Retirer du repas »), bouton inactif et ligne « Un repas planifié a besoin d'un plat. ». Aucune ligne « Recette plus accessible » sans réponse : bouton inactif et ligne « 1 recette plus accessible : rédigez à la place ou retirez-la du repas. » (accordée). | test de widget |
| P2-3 | **La boîte « Poser dans le planning ».** Une ligne « Planning » (« Mon planning » par défaut, ou un groupe possédé), affichée seulement si l'utilisateur possède un groupe, mêmes règles et même source que la feuille « Planifier » (`ownedPlanningGroups`, `planning_target.dart` ; §9.5). « Date » : calendrier d'aujourd'hui à deux ans, bornes de « Replanifier » (`planning_screen.dart`, `_rescheduleMeal`). « Heure de début » (même libellé que la feuille « Planifier ») : pré-remplie par l'heure du jour de semaine choisi (`PlanningPreferences.mealTimeFor`, comme un jour libre du planning), modifiable ; elle suit la date tant qu'elle n'a pas été changée à la main. « Parts : 6, parts du menu ». Un récapitulatif nomme les services posés et ce qui part en texte libre (P2-6). Bouton « Poser ». Disposition et libellés définitifs : `ux-designer`. | essai ; test unitaire de l'heure pré-remplie (jour réglé, jour sans réglage, heure changée à la main puis date changée) |
| P2-4 | **Le repas créé.** `uid` = moi ; `group_id` = le groupe choisi, sinon `null` (toujours écrit) ; `recipe_id` = la recette du premier service `plat` : le brouillon créé (`FreezeDraftCreated.draftId`) ou la recette liée relue (`FreezeLinked.recipeId`) ; `recipe_titre` = son titre ; `planned_at` = date et heure choisies ; `prep_minutes`, `cook_minutes`, `duration_minutes` lus des tags de cette recette, relue par identifiant à la pose (le figement ne garde que l'identifiant du brouillon) ; `base_portions` = les parts de cette recette (les parts du menu pour un brouillon, les siennes pour une recette liée) ; `target_portions` = les parts du menu, planning personnel comme planning de groupe (§9.6) ; `justification` = le `why` du plat principal (texte du modèle, 200 caractères au plus, contrôlé par le serveur au tour : même statut que la justification d'une conception) ; `choice_source` = `workshop` (§9.8) ; `meal_kind` = `effectiveMealKind(components)` : `plat` en mode Plat avec un seul service, `menu` dès qu'un autre service existe, second plat compris ; `created_at` = maintenant. Absents : `prep_date`, `dismissed_recipe_ids`, `relaxed_criteria`, `unmet_criteria` (l'atelier ne vérifie aucun critère du planning et ne prétend pas l'avoir fait). | test unitaire d'une fonction pure `WorkshopMenu` + lignes de figement → `PlannedMeal` (`features/search/domain/`, nom indicatif `meal_workshop_pose.dart`) ; repas ouvert dans le planning |
| P2-5 | **Les `components`**, écrits par `MealComposition.toComponents(mainTitle: recipe_titre)` : les services dans l'ordre du menu ; le plat principal par son marqueur (`{role: plat, id: 'main', label: titre}`) suivi de ses accompagnements ; chaque autre service en `MealComponent.recipe` (recette liée ou brouillon créé : `recipe_id`, `label` = titre) ou `MealComponent.free` (titre), avec le `role` du service, `course_label` pour un « Autre », `justification` = son `why` ; un second service `plat` devient un plat secondaire (`id` `p2`…) avec ses accompagnements (`side_of`). Accompagnements : `staple_id` connu du contexte (`stapleById`) → `MealComponent.staple` (garniture figée : part par personne, unité, produit de courses) ; `recipe_id` → `MealComponent.recipe` ; sinon `MealComponent.free(label)`. 70 composants au plus (10 services × 6 accompagnements), sous les 100 des règles. | test unitaire sur un menu complet (entrée liée, plat brouillon avec une garniture et un texte, plat secondaire avec un accompagnement, fromage texte, dessert brouillon, « Autre » avec libellé) ; `MealComposition.ofMeal` du repas écrit rend les mêmes services dans le même ordre |
| P2-6 | **Services sans recette.** Une ligne `FreezeFailed`, `FreezeNoRecipe`, `FreezeBudgetStopped`, `FreezeSaveFailed` ou `FreezePermissionDenied`, ou un brouillon créé puis introuvable à la relecture, est posée en **texte libre** sous son titre (`MealComponent.free`, `justification` = `why`), jamais exclue ni bloquante ; la boîte le dit : « 1 plat sans recette sera posé par son titre : Tarte aux poires. Vous pourrez lui choisir une recette depuis le planning (« Composer le menu »). ». Si c'est le plat principal (§9.7) : `recipe_id` `null`, `recipe_titre` = titre, `base_portions` absent, et la boîte dit « Le plat principal n'a pas de recette : le repas sera posé par son titre, sans courses ni nutrition. Vous pourrez le concevoir depuis le planning (« Concevoir avec l'IA »). ». | essai avec échec forcé ; test unitaire |
| P2-7 | **Jour déjà occupé.** Avant d'écrire, lecture des repas du planning visé ce jour-là (`getMealsBetween`, journée entière, `groupId` de la cible : un repas de groupe n'occupe pas le jour du planning personnel, ni l'inverse). S'il y en a : « Mar. 12 nov. a déjà un repas : Blanquette de veau, 19:30. » (heure en `HH:mm`, comme le planning et la feuille « Planifier ») avec « Choisir une autre date » et « Ajouter quand même » (deux repas le même jour sont admis par le planning). Rien n'est remplacé. | essai ; test unitaire sur la détection |
| P2-8 | **La recette d'origine n'est jamais modifiée.** Aucune écriture dans `recipes` ; les parts du menu vivent sur le repas (`target_portions`) ; quantités, nutrition par portion et courses sont recalculées à l'affichage (`planningScaleRecipeForMeal`, `portionsForComponents`). Une recette liée écrite pour 6, posée pour 4, s'affiche pour 4 depuis le repas et pour 6 depuis sa fiche. | relecture ; règle « Redimensionner ne modifie jamais l'originale » ; essai |
| P2-9 | **Planning de groupe** (§9.5, tranché). Cible possible seulement pour un groupe dont je suis le propriétaire et que je peux planifier (`ownedPlanningGroups`, `canPlan`) ; `uid` = moi, `group_id` = le groupe ; les règles `ownsMealGroup` refusent le reste (`rules-tests` existants). Parts = parts du menu (§9.6) ; quand `groupMealPortions` du jour choisi en dit un autre, la boîte ajoute « Famille Dupont cuisine d'habitude pour 4 ce jour-là. ». Ce que voient les membres du groupe : le titre de chaque service ; un brouillon d'un livre non privé s'ouvre pour un membre Editor ou Admin (relecture d'un brouillon partagé, `canReadRecipe`, `firestore.rules`), et s'affiche par son titre avec « Recette non partagée » pour un membre Reader, jusqu'à la validation du brouillon ; un brouillon d'un livre privé est « Recette non partagée » pour tous. `justification` et `choice_source` ne s'affichent pas sur un repas d'autrui (règle existante, FR §5.8). Le récapitulatif de la boîte le dit : « Les brouillons ne s'ouvrent pour les membres qu'une fois validés. ». | `rules-tests` existants ; essai avec un compte Reader et un compte Editor membres du groupe |
| P2-10 | **Après la pose.** Le pied du panneau dit « Posé le mar. 12 nov. dans Mon planning » (ou « dans Famille Dupont ») avec « Voir le planning », qui ouvre `/planning?date=AAAA-MM-JJ` — paramètre de route nouveau, proposé par `ux-designer` et retenu le 7 nov. 2026 : le planning s'ouvre sur la période qui contient ce jour, pour qu'un repas posé dans trois semaines soit visible à l'ouverture (carte de navigation §13.1 de `TechnicalRequirements.md`, par `developpement-tech-couts`) ; le bouton devient « Poser à une autre date » et reste actif : chaque pose crée un repas de plus, qui pointe les mêmes brouillons, sans appel d'IA ni nouveau brouillon. « Nouvelle conversation » inchangé. Après une pose, les lignes du panneau perdent « Réessayer », « Rédiger à la place » et « Retirer du repas » : aucun brouillon ne se crée plus après une pose, et une ligne non rédigée se lit « Non rédigée · posée en texte » (alignement `ux-designer`, 7 nov. 2026). Après une pose, l'écran se quitte librement, même après un figement partiel : ce qui compte est enregistré. | essai ; test de widget (actions des lignes et garde de sortie après pose) |
| P2-11 | **Erreurs.** Écriture refusée ou réseau perdu : « Repas non posé. Réessayez. », état inchangé, rapport d'erreurs (`mealWorkshop.pose`, contexte `group_id`), jamais de `catch` silencieux. Rôle retiré en cours de session : « Repas non posé. La planification est réservée aux éditeurs. ». Groupe plus possédé, en pause ou supprimé : « Repas non posé. Ce groupe ne vous est plus accessible. ». Un « Réessayer » rejoue la détection de P2-7, qui montre un repas écrit côté serveur malgré la coupure. Le bouton est inactif pendant l'écriture : pas de double pose par double appui. | essai avec règles refusées (émulateur) |
| P2-12 | **Agenda Google** (§9.9, tranché : non). La pose n'écrit que le planning. L'événement se pose ensuite depuis le repas, « Exporter vers Calendar », qui décrit déjà un menu (`mealCalendarDescription`). | — |
| P2-13 | **Coût.** Aucun appel d'IA, aucune ligne `ai_usage`, aucun compteur, aucun poste à inscrire. Une pose = une écriture `planned_meals`, plus deux lectures (les repas du jour pour P2-7, la recette principale pour P2-4). | relecture du diff |
| P2-14 | **`choice_source: workshop`** (§9.8) : valeur nouvelle de `MealChoiceSource` (`meal_choice_source.dart`), libellé « Composée avec l'IA », icône robot (`MealOriginLine.iconFor`), `countsAsRefusal` vrai comme `ai` et `concept` ; `fromValue` est déjà tolérant : une version antérieure lit `null`, n'affiche pas de ligne d'origine, et perd le champ si elle réécrit le document entier (comme à l'arrivée de `concept`). Le serveur ne lit pas `choice_source` : aucune fixture, aucune logique dupliquée. | test unitaire de `MealChoiceSource` ; test de `countsAsRefusal` |
| P2-15 | **KPI.** Repas posés = nombre de `planned_meals` où `choice_source == 'workshop'` sur la période, par planning personnel ou de groupe (`group_id`), rapporté aux conversations figées (§7). Requête à la main en v1 ; aucun champ de plus que la valeur de P2-14. | requête |

### Mesures en production

Le relevé se fait sur demande (« relevé atelier »), en lecture seule, depuis la racine du
dépôt :

```bash
node tools/workshop-cost-report.mjs                     # tout l'historique
node tools/workshop-cost-report.mjs --since 2026-11-07  # à partir d'un jour (UTC)
node tools/workshop-cost-report.mjs --sandbox           # ajoute sandbox_meal_workshop_turn
```

Prérequis : le CLI Firebase installé globalement et connecté (`firebase login`). Le script
lit les lignes `ai_usage` des postes `meal_workshop_turn` et `meal_workshop_recipe`, et écrit
un relevé Markdown : coût par poste et modèle, premiers tours et tours suivants, conversations,
plats rédigés. Il n'écrit rien et n'affiche ni uid, ni texte, ni titre. Détail :
`TechnicalRequirements.md`, « Relevé des coûts de l'Atelier repas ». Chaque relevé ajoute une
ligne au tableau, la plus récente en bas. Un « premier tour » écrit le cache de prompt ; un
« tour suivant » le relit.

| Relevé | Période | Modèle | Tours | Coût des tours | Premiers tours | Tours suivants | Part des premiers tours | Préfixe en cache | Conversations | Plats rédigés |
|---|---|---|---|---|---|---|---|---|---|---|
| 7 nov. 2026 | 6-7 nov. 2026 | Claude Sonnet 5 | 22 | 1,48 $ | 4, à 0,254 $ | 18, à 0,026 $ en moyenne (0,024 à 0,030 $) | 69 % (1,02 $) | 99 921 jetons | 5 ; 4,4 tours en moyenne (2 à 9) ; 0,296 $ en moyenne, 0,468 $ au plus | 0 |

Constats du 7 novembre 2026 :

- Le cache fonctionne. Un tour suivant lit 99 921 jetons en cache et coûte 0,026 $ en
  moyenne, pour un ordre de grandeur attendu d'environ 0,02 $. Un premier tour écrit ces
  99 921 jetons et coûte 0,254 $, autant qu'un tour sans cache du bac à sable (0,26 $,
  v0.24.75).
- Les premiers tours font 69 % du coût des tours : 1,02 $ sur 1,48 $, pour 4 tours sur 22.
- L'historique pèse peu. Dans la conversation de 9 tours, l'entrée hors cache passe de
  103 jetons au tour 1 à 1 602 au tour 9 ; le tour coûte 0,026 à 0,030 $ de bout en bout. Sur
  toutes les conversations, l'entrée hors cache du premier tour va de 84 à 141 jetons.
- Un cache d'une heure n'aurait rien changé. Les 3 premiers tours précédés d'un autre tour
  l'étaient de 1 h 16 au moins. La seule conversation ouverte moins de 5 min après une autre
  (6 nov., 2 min après la précédente) a relu son cache dès son premier tour : 5 conversations pour
  4 écritures du cache. Aucune conversation n'a réécrit le cache en cours de route.
- Aucun plat rédigé (`meal_workshop_recipe`) à cette date : le coût d'un figement reste à
  mesurer.
- Le nombre de recettes envoyées n'est pas enregistré dans `ai_usage`. Le préfixe en cache
  (99 921 jetons) en tient lieu ; le périmètre Explorer comptait 664 recettes ce jour-là.

Décision du 7 novembre 2026, sur ce relevé : aucun plafond du corpus (§9, question 3).

---

## 4. Cas limites

| Situation | Comportement attendu | Qui décide |
|---|---|---|
| Réponse du modèle illisible ou JSON hors schéma | `logError` avec `responsePreview` tronqué à 500 caractères (modèle de `generateRecipeConcept`). Le serveur rend une erreur « L'IA n'a pas rendu de réponse lisible. » (v0.24.75 ; « …de menu lisible. » auparavant). L'écran garde le menu du tour précédent, ne l'écrase jamais par un état partiel, laisse le message dans le champ avec « Réessayer ». Le tour a été facturé et compte dans les 30. | serveur, puis écran |
| Identifiant de recette inventé (hors du corpus envoyé) | Le serveur met `recipe_id` à `null`, garde le titre comme plat à rédiger, et marque le service `unknown_recipe_id: true`. L'écran affiche « Recette inconnue : à rédiger ». L'événement est compté (journal `logInfo`, champ `inventedIds`) : c'est la mesure du palier 0. | serveur |
| Identifiant d'une recette privée d'un autre membre | Impossible par construction : Explorer écarte du périmètre et de l'envoi à l'IA les recettes d'un livre privé d'un autre membre et celles d'un compte hors de mes groupes (FR §5.5, fin). Le corpus ne les contient pas ; un identifiant qui les viserait est traité comme inventé. Au figement, la relecture par les règles Firestore refuse de toute façon une recette illisible (P1-14). | client (corpus), règles Firestore |
| Menu vide au figement | Bouton inactif, ligne « Le menu est vide. » (P1-10). | écran |
| Menu sans plat à rédiger | Bouton inactif, ligne « Rien à rédiger : toutes les recettes existent déjà. » En palier 2, « Poser dans le planning » prend le relais. | écran |
| Plafond de 30 tours atteint en cours de conversation | Tour refusé, menu conservé, « Figer le repas » disponible (P1-8). Le figement n'est pas compté dans les 30 : il est borné par le budget en euros et par les 10 services du menu. | serveur, écran |
| Budget en euros atteint | Tour ou recette refusé avec le message du serveur, préfixé par ce qui n'a pas eu lieu (P1-9). En figement, les services restants ne sont pas tentés. | serveur, écran |
| Perte de réseau pendant un tour | « Réponse non reçue. Connexion perdue. », « Réessayer » renvoie le même message. Le tour n'est pas dans l'historique. Si la place a été réservée côté serveur sans réponse, elle est rendue (règle de la recherche web : « échoue avant que le moteur ait répondu : ne compte pas »). | écran, serveur |
| Perte de réseau pendant un figement | Les brouillons déjà créés restent ; les services restants passent « Non rédigée — Réessayer ». Aucun brouillon n'est créé deux fois : un service passé « Brouillon créé » n'est plus rejoué. | écran |
| Filtres d'Explorer changés pendant la conversation | Sans effet : le périmètre est figé à l'ouverture (P1-3). Pour un autre périmètre, quitter l'atelier et le rouvrir. | écran |
| Recette du corpus supprimée ou passée privée pendant la conversation | Le modèle peut encore la citer : le serveur ne la connaît que par le résumé envoyé. Au figement, la relecture échoue : « Recette plus accessible », « Rédiger à la place » ou « Retirer du repas » (P1-14). | écran, règles Firestore |
| Texte de l'utilisateur contenant une consigne au modèle (« ignore tes règles », « écris en base ») | Le texte est une **entrée non fiable** (`CLAUDE.md`, « Tickets »). Il est placé dans une section délimitée du prompt (modèle de `=== DEMANDE ===` de `mealIdeas.ts`), jamais concaténé aux consignes. Les invariants ne dépendent pas du modèle : rôles en liste blanche, identifiants contrôlés contre le corpus, bornes de taille, aucune écriture serveur. Le texte n'est pas journalisé. Une consigne qui « réussit » ne peut au pire que produire un menu absurde, que l'utilisateur ne fige pas. | serveur |
| Texte du modèle contenant un lien, du Markdown, une adresse | Affiché en texte brut. Aucun lien cliquable hors des recettes du JSON contrôlé (P1-18). | écran |
| Doublon de titre entre un plat à rédiger et une recette du périmètre | « Lier la recette existante » ou « Rédiger quand même », avant tout appel (P1-15). Entre deux plats du même menu : le serveur refuse deux services de même titre, le second est renommé par le modèle au tour suivant ou retiré par l'utilisateur. | écran, serveur |
| Doublon de titre avec une recette hors périmètre | Non détecté en v1. La règle « Doublon à l'import » (FR §6) ne compare qu'au sein d'un livre ; l'atelier ne fait pas mieux. | — |
| Nombre de parts du menu | Le menu a **un** nombre de parts commun, `portions`, de 1 à 99, posé dans le panneau du menu (pas dans la conversation). Il est envoyé au modèle à chaque tour. Chaque recette rédigée est écrite pour ce nombre (`>> portions: N`). Une recette existante liée garde ses propres parts, jamais modifiées ; l'écart s'affiche (« recette pour 6, menu pour 4 »), et c'est le repas planifié du palier 2 qui porte `target_portions`. Valeur par défaut : §9.1, tranchée le 6 nov. 2026 (P1-21). | écran, serveur (prompt) |
| Plus de 10 services ou plus de 6 accompagnements rendus | Le serveur tronque à `kMaxCoursesPerMenu` (10) et `kMaxSidesPerDish` (6), dans l'ordre rendu, et le signale dans la réponse (`truncated: true`). L'écran dit « Menu limité à 10 services. ». | serveur |
| Deux services `plat` | Admis : le planning connaît un plat principal et des plats secondaires (`MealComposition`, identifiants `p2`, `p3`…). Le premier `plat` est le principal ; au palier 2, c'est lui qui porte `recipe_id`. | serveur, écran |
| Un accompagnement qui mériterait une recette (« gratin dauphinois ») | En v1, un accompagnement est un texte, une garniture ou une recette existante ; jamais une recette à rédiger. L'utilisateur demande au modèle d'en faire un service `plat` secondaire s'il veut sa recette. Le prompt le dit. | prompt, serveur |
| Garniture citée hors du référentiel de l'utilisateur (`staple_id` inconnu) | `staple_id` mis à `null`, le libellé reste en texte libre. | serveur |
| Fermeture de l'application en pleine conversation | La conversation est perdue : rien n'est conservé entre deux sessions (§6). | — |
| Le même compte ouvre l'atelier sur deux appareils | Deux conversations indépendantes, un seul compteur de tours. Aucun conflit : rien n'est écrit avant le figement. | — |

**Cas limites du palier 2** (7 nov. 2026) :

| Situation | Comportement attendu | Qui décide |
|---|---|---|
| Menu sans service `plat` au moment de poser (mode Menu : entrée et dessert seuls ; plat retiré par « Retirer du repas ») | « Poser » inactif, ligne « Un repas planifié a besoin d'un plat. » (P2-2). | écran |
| Plat principal sans recette (non rédigé, plafond, brouillon non enregistré, brouillon supprimé avant la pose) | Posé par son titre : `recipe_id` `null`, `recipe_titre` = titre, sans `base_portions`. La boîte le dit. Depuis le planning, « Concevoir avec l'IA » ou « Changer la recette » lui donnent une recette ensuite (§9.7). | écran |
| Service non rédigé, hors plat principal | Texte libre sous son titre, avec son `why` en `justification`. Remplaçable ensuite par « Composer le menu » du planning (P2-6). | écran |
| Recette liée devenue illisible (« Recette plus accessible ») | « Poser » inactif tant que la ligne n'a pas de réponse : « Rédiger à la place » (un appel) ou « Retirer du repas » (P2-2). Un `recipe_id` que son propre auteur ne peut pas lire n'entre pas dans un repas. | écran |
| Garniture citée (`staple_id`) retirée du référentiel entre le tour et la pose | `stapleById` ne la trouve plus : texte libre sous son libellé, sans quantité ni produit de courses. | écran |
| Recette liée dont les parts diffèrent du menu | `base_portions` = parts de la recette, `target_portions` = parts du menu ; recalcul à l'affichage ; la recette ne change pas (P2-8). | écran |
| Mode Plat, un seul service | `meal_kind: plat`, `components` = accompagnements seuls : la même forme qu'un repas posé depuis la feuille « Planifier ». | écran |
| Deux services `plat` | Le premier est le plat principal (`recipe_id`), le second un plat secondaire (`id` `p2`, accompagnements en `side_of: p2`) ; le repas est un menu, même en mode Plat. | écran |
| Même menu posé deux fois | Deux repas qui pointent les mêmes brouillons. Le même jour, P2-7 prévient d'abord. | écran |
| Pose pendant une coupure réseau | « Repas non posé. Réessayez. » ; le retry rejoue P2-7 : un repas écrit côté serveur malgré la coupure apparaît comme « déjà présent » au lieu d'être doublé en silence. | écran |
| Double appui sur « Poser » | Bouton inactif pendant l'écriture (P2-11). | écran |
| Rôle retiré en cours de session | Les règles refusent (`isEditor`) : « Repas non posé. La planification est réservée aux éditeurs. ». | règles Firestore, écran |
| Groupe choisi devenu inaccessible entre l'ouverture de la boîte et la pose (rétrogradé, groupe supprimé) | Les règles refusent (`ownsMealGroup`) : « Repas non posé. Ce groupe ne vous est plus accessible. ». | règles Firestore, écran |
| Repas de groupe et brouillons | Un membre Editor ou Admin ouvre le brouillon d'un livre non privé (relecture d'un brouillon partagé) ; un membre Reader voit le titre et « Recette non partagée » jusqu'à la validation ; un livre privé ferme le brouillon à tous les membres (P2-9). | règles Firestore |
| Brouillon validé ou modifié après la pose | Le repas pointe toujours le même identifiant : la fiche ouverte depuis le repas montre la recette telle qu'elle est maintenant, pour les parts du repas. Rien à faire. | — |
| Brouillon supprimé après la pose | Comme toute recette supprimée d'un repas : titre gardé sur le repas, fiche introuvable, courses sans ses ingrédients (comportement existant du planning). | — |
| Parts du menu changées après le figement, avant la pose | Impossible : le bouton des parts est inactif dès qu'un figement a eu lieu (`meal_workshop_screen.dart`, `_frozen`). Les parts du repas sont celles du figement, pour lesquelles les brouillons ont été écrits. « Changer les parts » reste possible sur le repas posé. | écran |

---

## 5. Règles de contenu : le menu en cours

Le menu est l'objet que le modèle rend à chaque tour et que l'écran redessine. Le serveur le
lit en **liste blanche** (modèle de `readCriteriaByWeekday` : une clé inconnue est ignorée,
une valeur hors liste est écartée) avant de le rendre au client.

```json
{
  "portions": 4,
  "courses": [
    {
      "role": "entree",
      "course_label": null,
      "title": "Velouté de potimarron",
      "description": "Doux et lisse, une pointe de noisette torréfiée.",
      "recipe_id": null,
      "why": "Ouvre sur du chaud et du doux avant un plat salé.",
      "sides": []
    },
    {
      "role": "plat",
      "course_label": null,
      "title": "Blanquette de veau",
      "description": null,
      "recipe_id": "aB3…",
      "why": "Déjà dans votre bibliothèque, notée 9/10.",
      "sides": [
        { "label": "Riz", "staple_id": "riz", "recipe_id": null },
        { "label": "Carottes glacées", "staple_id": null, "recipe_id": null }
      ]
    }
  ]
}
```

| Champ | Règle | Source de la règle |
|---|---|---|
| `portions` | entier de 1 à 99 ; recopié de la valeur posée par l'utilisateur, le modèle ne le change pas | « Changer les parts » du planning (1 à 99) |
| `courses` | 0 à 10 éléments, dans l'ordre du service | `kMaxCoursesPerMenu` (`meal_composition.dart`) |
| `role` | `entree`, `plat`, `sorbet`, `fromage`, `dessert`, `autre` ; rien d'autre | `kCourseRoles` (`meal_composition.dart`) ; `accompagnement` n'est pas un service |
| `course_label` | pour `autre` seulement ; 30 caractères au plus ; espaces réduits | `kCourseLabelMaxChars`, `courseLabelFrom` |
| `title` | 1 à 60 caractères, en français, sans point final ; obligatoire quand `recipe_id` est `null` ; quand `recipe_id` est posé, le serveur remplace le titre par celui du résumé envoyé | règle de titre de `mealIdeas.ts` |
| `description` | 200 caractères au plus ; `null` admis | borne nouvelle |
| `recipe_id` | identifiant présent dans les résumés envoyés à ce tour, sinon `null` et `unknown_recipe_id: true` | §4 |
| `why` | 200 caractères au plus ; la raison de l'accord, lue par une personne ; devient `justification` du composant au palier 2 | `MealComponent.justification` |
| `sides` | pour `role: plat` seulement ; 0 à 6 ; vidé pour les autres rôles | `kMaxSidesPerDish` (`side_chooser.dart`) |
| `sides[].label` | 1 à 60 caractères | — |
| `sides[].staple_id` | identifiant d'une garniture de l'utilisateur envoyée au tour, sinon `null` | `meal_staple.dart` |
| `sides[].recipe_id` | comme `recipe_id` d'un service ; un accompagnement n'est jamais une recette à rédiger | §4 |
| Deux services de même titre | refusé ; le second est écarté et signalé | §4 |

Le texte de la réponse (`assistant_text`) est borné par `maxTokens` du poste ; au-delà de
1 500 caractères, l'écran le replie sous « Lire la suite ». Le texte ne porte aucune
instruction pour l'écran : le menu seul fait foi.

**Ce que le modèle reçoit à chaque tour**, dans des sections délimitées :

1. consignes fixes (rôle de cuisinier de famille, format, règles ci-dessus) ;
2. `=== PRÉFÉRENCES GÉNÉRALES DU FOYER ===` : `globalConstraints` (`planning_preferences.dart`) ;
3. `=== RECETTES DE LA BIBLIOTHÈQUE ===` : les résumés `buildMealWorkshopSummary` du
   périmètre (identifiant, titre, 6 ingrédients, thèmes, cuisines, difficulté, rôle,
   protéine, féculent, note, durée ; sans livre ni statut — P1-3) ;
4. `=== GARNITURES DISPONIBLES ===` : identifiant, nom, famille (`StapleCategory`) ;
5. `=== MENU EN COURS ===` : le JSON du tour précédent, ou vide ;
6. `=== CONVERSATION ===` : les tours précédents, chacun marqué de son auteur ;
7. `=== DEMANDE ===` : le message du tour.

Les sections 3 et 4 sont les plus coûteuses et ne changent pas d'un tour à l'autre. Si le
palier 0 mesure un coût par tour trop élevé, deux options, à trancher sur chiffres : plafonner
le corpus envoyé (par exemple 200 recettes, les mieux notées d'abord), ou activer la mise en
cache du préfixe du prompt chez le fournisseur qui l'offre. Tranché le 6 nov. 2026 (§9.3) :
pas de plafond du corpus au palier 1, le cache de prompt (v0.24.75) répond au coût.

---

## 6. Ce qui s'écrit, où, et pour qui

| Moment | Document | Écrit par | Lu par | Règle de `CLAUDE.md` |
|---|---|---|---|---|
| Chaque tour | `ai_usage/{auto}` : poste `meal_workshop_turn`, `entity_type: "meal_workshop"`, `entity_id` = identifiant de conversation tiré par le client (UUID) | serveur (`recordUsage`, existant) | admin (comptabilité) | « Un poste d'IA vit à trois endroits » |
| Chaque tour | `meal_workshop_daily/{uid}_{AAAA-MM-JJ}` : `count`, `limit` | serveur seul, en transaction | admin, ou le compte concerné | même règle que `web_search_daily` ; `firestore.rules` + `rules-tests` |
| Figement, par plat | `ai_usage/{auto}` : poste `meal_workshop_recipe`, même `entity_id` | serveur | admin | idem |
| Figement, par plat | `recipes/{id}` : brouillon, `review_status: draft`, `origin: ai`, `book_id` du livre choisi, `created_by: uid`, `portions` du menu, `ai_source: "meal_workshop"` (champ nouveau, voir §7) | client (`createRecipe`, comme `saveGeneratedRecipe`) | le propriétaire ; les membres de ses groupes si le livre n'est pas privé, comme tout brouillon | « Toute recette a un livre » (assouplie : deux livres au choix) ; « Recette conçue par l'IA en brouillon » |
| Figement | la recette existante liée | **personne** : ni copie, ni champ | — | « Redimensionner ne modifie jamais l'originale » |
| Palier 2, chaque pose | `planned_meals/{id}` : `uid`, `group_id` (`null` ou le groupe possédé choisi), `recipe_id`, `recipe_titre`, `planned_at`, durées, `base_portions`, `target_portions`, `justification` (`why` du plat principal), `choice_source: workshop`, `meal_kind`, `components` (P2-4, P2-5) | client (`PlanningRepository.addMeal`, existant) | le propriétaire ; les membres de ses groupes en lecture seule selon ses partages, ou les membres du groupe pour un repas de groupe | l'état propre à une personne vit sur le repas planifié, le couple (personne, date) ; aucune écriture dans `recipes` |

Ce qui ne s'écrit **jamais** : la conversation, le menu en cours, le périmètre figé, les
réponses du modèle. Ils vivent en mémoire de l'écran et disparaissent avec lui.

Aucune donnée existante n'est à reprendre : pas de backfill. Le champ `ai_source` est posé à
la création des nouveaux brouillons seulement ; les recettes antérieures n'en ont pas, et
aucun écran ne l'exige.

### La conversation n'est pas conservée entre deux sessions — proposition : NON en v1

1. **Le livrable durable existe déjà.** Ce que l'utilisateur veut garder, il le fige : les
   brouillons et, au palier 2, le repas planifié. La conversation est l'outil, pas le
   résultat. « Imaginer 3 recettes » suit la même logique : les propositions non enregistrées
   disparaissent avec l'écran (FR §5.5).
2. **Conserver une conversation est un état propre à l'utilisateur**, donc un document sous
   `users/{uid}/…`, avec un schéma, des règles Firestore, des tests de règles, une durée de
   conservation à décider, et du texte libre qui peut contenir des données personnelles
   (prénoms, allergies). C'est un chantier à part, qu'aucun usage mesuré ne justifie encore.
3. **La reprise est bornée de toute façon** : 20 tours. Une conversation reprise le lendemain
   repartirait avec la même limite ; le gain est mince.
4. **Mesurer d'abord.** Le KPI « conversations ouvertes puis abandonnées sans figement » (§7)
   dira si des conversations se perdent. S'il dépasse ce qu'on tolère, on rouvre la question,
   avec un chiffre.

---

## 7. Coûts et KPIs

### Coûts

Deux postes facturés, inscrits au catalogue, routables Gemini ou Claude :

| Poste | Quand | Ordre de grandeur de l'entrée | Mesuré par |
|---|---|---|---|
| `meal_workshop_turn` | chaque tour | corpus : environ 80 à 120 jetons par recette résumée (100 recettes ≈ 10 000 jetons) ; historique : jusqu'à 20 × 1 500 caractères ≈ 8 000 jetons au 20e tour ; consignes et garnitures : moins de 2 000 jetons | palier 0, P0-8 |
| `meal_workshop_recipe` | chaque plat figé | celle de `planning_concept` aujourd'hui, lisible dans `ai_usage_monthly.by_feature.planning_concept` | existant |

Les ordres de grandeur en jetons sont des estimations à confirmer au palier 0 ; aucun montant
n'est avancé ici : la grille vit dans `app_config/ai_pricing` et le palier 0 lit le coût réel
de chaque appel. Le coût d'un tour croît avec le corpus et avec la longueur de l'historique :
le 20e tour coûte plus que le premier.

Plafonds : 30 tours par jour et par compte (×100 pour le fondateur, comme la recherche web) ;
budget en euros et en appels du jour (`ai_budget_policy`, 2 € et 400 appels par défaut).
Un figement de 10 services à rédiger, cas extrême, fait 10 appels `meal_workshop_recipe`.

### KPIs

| KPI | Mesurable avec `ai_usage` tel quel | Ce qu'il faut ajouter |
|---|---|---|
| Conversations ouvertes | oui : nombre d'`entity_id` distincts du poste `meal_workshop_turn` sur la période | rien, si le client pose `entity_id` à chaque tour (`usageMeta`, existant) |
| Tours par conversation | oui : lignes `meal_workshop_turn` par `entity_id` ; moyenne, médiane, part des conversations à 20 tours | rien |
| Part des conversations figées | oui : `entity_id` ayant au moins une ligne `meal_workshop_recipe` ÷ `entity_id` ayant au moins une ligne `meal_workshop_turn` | rien ; les conversations figées sans plat à rédiger (recettes existantes seules) ne sont pas vues : accepté en v1 |
| Plats figés par conversation | oui : lignes `meal_workshop_recipe` par `entity_id` | rien |
| Conversations abandonnées | dérivé : conversations sans ligne `meal_workshop_recipe` | rien ; c'est le chiffre qui rouvrira ou non la conservation (§6) |
| Part des plats figés ensuite validés (brouillon → recette) | **non** : `ai_usage` ne sait pas ce que devient le brouillon | un champ `ai_source: "meal_workshop"` sur la recette (schéma §3 de `TechnicalRequirements.md`, `diagramme-de-classes.html`) ; le KPI se lit alors par une requête `recipes` où `ai_source == "meal_workshop"`, par `review_status`. Sans écran dédié en v1 : requête à la main ou ligne dans Admin → Qualité des données, à décider |
| Coût moyen par conversation | oui : somme de `estimated_cost_usd` des deux postes par `entity_id` | rien ; les appels sans montant (`total_unpriced_calls`) sont comptés à part, jamais estimés |
| Repas posés dans le planning (palier 2) | **non** : poser n'appelle pas l'IA, aucune ligne `ai_usage` | la valeur `workshop` de `choice_source` (P2-14) ; le KPI se lit par une requête `planned_meals` où `choice_source == "workshop"`, par mois et par `group_id`, rapportée aux conversations figées. Sans cette valeur, les repas de l'atelier se confondraient avec les conceptions du planning (`concept`) ou les choix à la main (`manual`) |
| Identifiants inventés par le modèle | non | un compteur dans le journal (`logInfo`, `inventedIds`) ; au palier 0, il suffit ; en production, une ligne agrégée par jour si le chiffre inquiète |
| Tours refusés (JSON illisible, plafond, budget) | partiellement : un refus de plafond ou de budget n'a pas de ligne `ai_usage` | les journaux `logError` / `logInfo` existants, filtrés par poste |

L'écran de comptabilité (Admin → Comptabilité) montre déjà, par poste, le nombre d'appels et
le coût du mois : les deux postes y apparaissent dès le palier 0 (sous « Bac à sable »), puis
le palier 1 (sous « Recherche » et « Rédaction d'une recette »). Les KPIs par `entity_id`
demandent une lecture de `ai_usage` qui n'a pas d'écran aujourd'hui : requête à la main en
v1.

---

## 8. Priorisation

| Palier | Contenu | Pourquoi là |
|---|---|---|
| **0 — bac à sable** | conversation, panneau du menu, JSON contrôlé par le serveur, un poste `sandbox_meal_workshop_turn`, aucune écriture, mesures du §3 | le prompt et la tenue de l'état du menu sont le risque principal ; on le lève avant d'écrire un écran de production |
| **1 — Explorer** | cinquième action, écran dédié, périmètre figé, plafond 30 tours, budget, deux postes de production, « Figer le repas », choix du livre, doublon de titre, garde de sortie, champ `ai_source` | c'est la valeur promise : le repas devient des recettes Kass'Dalle |
| **2 — planning** | « Poser dans le planning », repas personnel ou de groupe possédé (§9.5) avec `components`, parts du menu sur le repas, `choice_source: workshop`, aucun appel d'IA | dépend du palier 1 et de `MealComposition`, déjà en place ; faible effort une fois les brouillons créés : une fonction pure menu → repas, une boîte, une écriture par le dépôt existant |

Hors périmètre, à confirmer :

- image du menu ou des plats (un poste d'IA image de plus ; les brouillons passent par le
  parcours d'illustration existant une fois validés) ;
- export PDF du menu (l'export PDF existant porte sur une recette ou un livre) ;
- partage du menu au groupe (le repas planifié du palier 2 se partage déjà par les réglages
  du planning ; rien de plus) ;
- conversation à plusieurs (plusieurs membres dans le même atelier) ;
- conservation de la conversation (§6) ;
- planning d'un groupe comme cible du palier 2 : **dans** le périmètre depuis le 7 nov. 2026
  (§9.5, P2-9) ;
- agenda Google à la pose (§9.9, tranché : non, l'export existe sur le repas) ;
- accompagnement rédigé en recette (§4 : un accompagnement reste texte, garniture ou
  recette existante) ;
- doublon de titre hors du périmètre figé.

---

## 9. Questions ouvertes — réponses des 6 et 7 novembre 2026

Les cinq questions posées le 1er novembre ont reçu leur réponse de l'utilisateur le
6 novembre 2026, avec la validation du palier 1 ; la cinquième, restée ouverte, a reçu la
sienne le 7 novembre avec le palier 2. Les questions 6 à 9 sont celles du palier 2, posées
et tranchées le 7 novembre 2026. La question d'origine est gardée, suivie de la proposition
et de la réponse.

1. **Parts par défaut du menu.** 4 ? Ou les parts du jour de semaine courant dans les
   préférences du planning (« parts prévues ce jour-là », FR §5.8) ? La seconde demande de
   lire les préférences à l'ouverture ; la première est une constante.
   **Réponse (6 nov. 2026)** : ni l'une ni l'autre. Les parts par défaut sont celles du
   premier groupe familial actif de l'auteur — le plus ancien par date de création, groupes
   en pause exclus — : le réglage « Parts des groupes » de ce groupe s'il existe, sinon son
   nombre de membres. Sans groupe, 4. Modifiables par le bouton des parts. Critère P1-21.
2. **Périmètre à 0 recette.** L'action reste active avec un avertissement (P1-4) : d'accord,
   ou inactive comme « Chercher avec l'IA » ?
   **Réponse (6 nov. 2026)** : l'action reste active. L'écran dit « Aucune recette de la
   bibliothèque dans le périmètre : l'IA ne proposera que des plats nouveaux. ». P1-4
   inchangé.
3. **Plafond du corpus envoyé.** Faut-il décider dès maintenant un maximum de recettes
   envoyées par tour (par exemple 200, les mieux notées d'abord), ou attendre la mesure du
   palier 0 ? Proposition : attendre la mesure.
   **Réponse (6 nov. 2026)** : aucun plafond du corpus au palier 1. Le cache de prompt
   (v0.24.75) répond au coût des sections fixes ; le résumé est déjà réduit à 6 ingrédients
   (P1-3). Un plafond se rediscutera sur une mesure du coût par tour en production.
   **Réponse (7 nov. 2026)** : aucun plafond, toutes les recettes du périmètre. Décidé sur la
   mesure en production du §3 (« Mesures en production »).
4. **Doublon de titre** (P1-15) : la question « Lier ou rédiger » convient-elle, ou faut-il
   lier d'office quand le titre est identique ?
   **Réponse (6 nov. 2026)** : jamais lier d'office. Pour chaque titre déjà présent dans la
   bibliothèque de l'utilisateur, la boîte de figement propose « Lier la recette existante »
   ou « Rédiger quand même », rien n'est présélectionné, et « Figer » reste inactif tant
   qu'un doublon est sans réponse. P1-15 inchangé.
5. **Palier 2 et planning de groupe.** Un propriétaire de groupe peut-il poser le repas dans
   le planning du groupe, ou seulement dans le sien ? Proposition : le sien seul en palier 2,
   le groupe plus tard s'il est demandé.
   **Réponse (6 nov. 2026)** : non tranché. La question reste ouverte pour le cadrage du
   palier 2 ; elle ne bloque pas le palier 1. P2-6 inchangé.
   **Proposition (7 nov. 2026)** : admettre le planning d'un groupe possédé, par la même
   ligne « Planning » que la feuille « Planifier » d'une recette (`schedule_recipe_sheet.dart`,
   `ownedPlanningGroups`), affichée seulement à qui possède un groupe. Trois raisons. Le
   planning de groupe existe déjà avec ses règles (`ownsMealGroup`), ses tests et ses trois
   entrées (FR §5.8, « Planning d'un groupe ») : l'atelier en devient la quatrième, sans
   règle nouvelle. Les parts par défaut du menu sont déjà celles du premier groupe actif
   (P1-21) : un repas composé « pour la famille » qui ne pourrait pas aller dans le planning
   de la famille serait une promesse à moitié tenue. Le coût est une ligne de plus dans la
   boîte. Ce qui change pour les membres est dit dans P2-9 : un brouillon ne s'ouvre pour un
   membre Reader qu'une fois validé (« Recette non partagée » avant), un membre Editor le
   relit. Si l'utilisateur préfère le planning personnel seul, P2-9 tombe et la ligne
   « Planning » n'apparaît pas ; rien d'autre ne change.
   **Réponse (7 nov. 2026)** : oui. Le planning personnel et le planning d'un groupe possédé
   sont les deux cibles, par la ligne « Planning » conditionnelle. P2-3 et P2-9 s'appliquent.

   Les questions 6 à 9 sont celles du palier 2, posées et tranchées le 7 novembre 2026.

6. **Parts d'un repas de groupe posé depuis l'atelier.** Les parts du menu (choisies dans
   l'atelier, et pour lesquelles les brouillons ont été écrits), ou la règle du planning de
   groupe, `groupMealPortions` (« Parts à préparer » du jour, sinon parts du groupe) ?
   **Proposition (7 nov. 2026)** : les parts du menu, pour le planning personnel comme pour
   un groupe. C'est la valeur la plus précise, posée par la personne pour ce repas-là, et la
   règle du planning de groupe dit elle-même que « la valeur la plus précise gagne »
   (`planning_target.dart`). Les brouillons ont été écrits pour ce nombre ; une recette liée
   est recalculée à l'affichage. Quand la règle du jour en dit un autre, la boîte l'affiche
   (« Famille Dupont cuisine d'habitude pour 4 ce jour-là. »), et « Changer les parts » reste
   possible sur le repas. FR §5.8 dira que l'atelier est l'exception à « Les trois entrées
   d'un repas de groupe ».
   **Réponse (7 nov. 2026)** : les parts du menu, avec la phrase quand `groupMealPortions` du
   jour diffère. P2-4 et P2-9 inchangés.
7. **Plat principal sans recette.** Quand le premier service `plat` n'a pas de brouillon
   (rédaction échouée, plafond atteint), « Poser » est-il bloqué, ou le repas est-il posé par
   son titre ?
   **Proposition (7 nov. 2026)** : posé par son titre, `recipe_id` `null`, et la boîte le dit
   (P2-6). Bloquer forcerait un « Réessayer » qui peut échouer encore (budget du jour), et la
   conversation n'est pas conservée : le menu serait perdu. Posé par son titre, il garde sa
   structure dans le planning, où « Concevoir avec l'IA » et « Changer la recette » existent
   déjà pour lui donner une recette le lendemain. Un repas sans recette n'apporte ni courses
   ni nutrition tant qu'il n'en a pas : la boîte le dit en une phrase.
   **Réponse (7 nov. 2026)** : posé par son titre, `recipe_id` nul, la boîte prévient. P2-6
   inchangé.
8. **Valeur de `choice_source`.** Réutiliser `concept` (« Conçue par l'IA ») ou `ai`
   (« Choisie par l'IA »), ou ajouter `workshop` ?
   **Proposition (7 nov. 2026)** : ajouter `workshop`, libellé « Composée avec l'IA ». Les
   valeurs existantes mentent dans un cas sur deux : un plat principal lié à une recette de
   la bibliothèque n'est pas « conçu » par l'IA, et un brouillon rédigé n'est pas « choisi
   parmi des candidats ». La valeur nouvelle est aussi le seul KPI possible sans champ de
   plus (§7). Coût : une entrée d'enum et son libellé côté client, une ligne au §3.7 du
   `TechnicalRequirements.md` et au diagramme de classes ; le serveur ne lit pas ce champ.
   Lecture tolérante déjà en place : une version antérieure n'affiche pas de ligne d'origine
   sur ce repas, et perd le champ si elle réécrit le document entier (même comportement qu'à
   l'arrivée de `concept`). Écarter une recette posée par l'atelier compte comme un refus
   (`countsAsRefusal`), comme pour `ai` et `concept`.
   **Réponse (7 nov. 2026)** : `workshop`, libellé « Composée avec l'IA ». P2-14 inchangé.
9. **Agenda Google à la pose.** Comme la feuille « Planifier » (« Ajouter au planning et à
   l'agenda »), ou le planning seul ?
   **Proposition (7 nov. 2026)** : le planning seul. L'atelier est déjà un écran à états
   (tours, figement, lignes à réessayer) ; une demande d'autorisation Google et un second
   message d'échec au milieu de la pose ajoutent un cas de panne pour un geste que le repas
   offre déjà (« Exporter vers Calendar », avec la description d'un menu). Un jour libre du
   planning fait de même : il pose sans agenda. Si l'utilisateur tient à la parité avec la
   feuille « Planifier », P2-12 reprend sa séquence : planning d'abord, agenda ensuite,
   message en deux phrases en cas d'échec de l'agenda.
   **Réponse (7 nov. 2026)** : pas d'agenda Google à la pose ; P2-12 confirmé. Décidé dans
   la même validation, sur proposition de `ux-designer` : « Voir le planning » ouvre
   `/planning?date=AAAA-MM-JJ`, paramètre de route nouveau, pour que le repas posé soit
   visible à l'ouverture quelle que soit sa date (P2-10).

---

## 10. Documents à mettre à jour, par palier

Mini-plan, à valider avec le cadrage. Rien n'est modifié avant le « oui ».

| Palier | Documents | Ce qui change |
|---|---|---|
| 0 | `TechnicalRequirements.md` (poste d'IA, routage) ; `CHANGELOG.md` | le poste `sandbox_meal_workshop_turn` ; §13.3 ne change pas (le contrat du bac à sable est inchangé) |
| 1 | `FunctionalRequirements.md` §3.2 (ligne Editor et Reader), §5.5 (tableau des actions, paragraphe « Composer un repas avec l'IA », disposition), §6 (lignes « Création de recette réservée », « Recette conçue par l'IA en brouillon », « Explorer filtre sans IA », « Toute recette a un livre » : deux livres au choix pour l'atelier), §7 Livré et « Reste à faire » (« Poser le repas de l'atelier dans le planning ») ; `cas-d-utilisation.html` (tableau des rôles, cas Editor/Admin « Composer un repas avec l'IA », « Figer le repas », légende de « Constituer la bibliothèque ») | business-analyst-culinaire, avec le livrable validé — **fait le 6 nov. 2026** |
| 1 | `TechnicalRequirements.md` §3 (champ `ai_source`, collection `meal_workshop_daily`), §4 (règles de la collection), §13.1 (route), callables et prompts ; `architecture.html` (tableau des fonctions, des collections) ; `diagramme-de-classes.html` ; `diagrammes-de-sequence.html` (tour, figement) ; `CHANGELOG.md` | developpement-tech-couts, avec le code |
| 2 | `FunctionalRequirements.md` §3.2 (ligne Editor : « pose le repas de l'atelier dans son planning ou celui d'un groupe possédé »), §5.5 (paragraphe « Composer un repas avec l'IA » : puce « Poser dans le planning » — quand le bouton apparaît, la boîte, texte libre pour un service sans recette, « Poser à une autre date », « Voir le planning »), §5.8 (« Planning d'un groupe » : quatrième entrée et exception des parts, §9.6 ; « Chaque plat dit d'où il vient » : « Composée avec l'IA » ; « Une recette privée planifiée pour un groupe » : le brouillon, même règle), §7 (ligne « Poser le repas de l'atelier dans le planning » retirée du « Reste à faire », puce « Atelier repas » du « Livré » complétée) ; `cas-d-utilisation.html` (nœud « Poser dans le planning » sous « Figer le repas », relié au planning du groupe ; lignes du tableau des rôles ; légendes d'Explorer et de « Planifier pour mon groupe ») | business-analyst-culinaire, avec le livrable validé — **fait le 7 nov. 2026** |
| 2 | `TechnicalRequirements.md` §3.7 (valeur `workshop` de `choice_source` ; `justification` = `why` du plat principal, texte du modèle contrôlé au tour, comme une conception ; `components[].justification` = `why` des services ; aucune règle Firestore ne change), §13.1 (paramètre `date` de la route `/planning`) ; `diagramme-de-classes.html` (`MealChoiceSource.workshop`) ; `diagrammes-de-sequence.html` §52 (troisième partie : la pose, client seul, `getMealsBetween` puis `addMeal`) ; `CHANGELOG.md`. Rien dans `architecture.html` (aucune fonction, aucune collection nouvelle) ni dans le tableau « Logique dupliquée » (le serveur ne lit pas `choice_source`) ; `meal_workshop_rules.json` inchangée | developpement-tech-couts, avec le code |
