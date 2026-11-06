# Kass'Dalle — Spec : atelier repas conversationnel dans Explorer

> Statut : palier 0 livré dans le bac à sable (v0.24.72, v0.24.75) ; palier 1 validé le
> 6 novembre 2026 avec la proposition d'écran, en cours d'implémentation ; palier 2 à venir ·
> Auteur : business-analyst-culinaire · 1er novembre 2026, mis à jour le 6 novembre 2026
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
- **US-6 Poser dans le planning** (palier 2). Après avoir figé, je pose le repas à une date :
  un repas planifié naît avec ses services, pour le nombre de parts du menu.
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

| # | Critère | Vérification |
|---|---|---|
| P2-1 | Après un figement, « Poser dans le planning » apparaît. Il exige un service `plat` dans le menu : sans plat, le bouton est inactif et une ligne dit « Un repas planifié a besoin d'un plat. ». | test de widget |
| P2-2 | Le bouton ouvre le choix d'une date (calendrier de « Replanifier » : date du jour à deux ans). L'heure est celle du jour de semaine dans les préférences du planning. | essai |
| P2-3 | Le repas créé est le repas de l'utilisateur (planning personnel), `recipe_id` = le plat principal (brouillon créé ou recette existante liée), `recipe_titre`, `target_portions` = parts du menu, `base_portions` = parts de la recette principale, `meal_kind: menu` dès qu'un autre service existe, `components` écrits par `MealComposition.toComponents` : entrée, accompagnements du plat (`MealComponent.staple` pour une garniture, `MealComponent.free` pour un texte, `MealComponent.recipe` pour une recette), sorbet, fromage, dessert, services « Autre » avec `course_label`. | test unitaire sur la conversion menu → `components` ; repas ouvert dans le planning |
| P2-4 | La recette d'origine n'est jamais modifiée : les parts du menu vivent sur le repas planifié (`target_portions`), les quantités sont recalculées à l'affichage (`planningScaleRecipeForMeal`). | relecture ; règle « Redimensionner ne modifie jamais l'originale » |
| P2-5 | Un repas déjà présent à cette date n'est pas écrasé : la boîte le dit et propose une autre date ou « Ajouter quand même » (deux repas le même jour sont admis par le planning). | essai |
| P2-6 | Le planning d'un groupe n'est pas une cible en palier 2 (question ouverte §9). | — |

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
| Palier 2 | `planned_meals/{id}` : `uid`, `recipe_id`, `recipe_titre`, `base_portions`, `target_portions`, `meal_kind`, `components` | client (dépôt du planning, existant) | le propriétaire ; ses groupes en lecture seule selon ses partages | l'état propre à une personne vit sur le repas planifié, le couple (personne, date) |

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
| **2 — planning** | « Poser dans le planning », repas personnel avec `components`, parts du menu sur le repas | dépend du palier 1 et de `MealComposition`, déjà en place ; faible effort une fois les brouillons créés |

Hors périmètre, à confirmer :

- image du menu ou des plats (un poste d'IA image de plus ; les brouillons passent par le
  parcours d'illustration existant une fois validés) ;
- export PDF du menu (l'export PDF existant porte sur une recette ou un livre) ;
- partage du menu au groupe (le repas planifié du palier 2 se partage déjà par les réglages
  du planning ; rien de plus) ;
- conversation à plusieurs (plusieurs membres dans le même atelier) ;
- conservation de la conversation (§6) ;
- planning d'un groupe comme cible du palier 2 (question ouverte) ;
- accompagnement rédigé en recette (§4 : un accompagnement reste texte, garniture ou
  recette existante) ;
- doublon de titre hors du périmètre figé.

---

## 9. Questions ouvertes — réponses du 6 novembre 2026

Les cinq questions posées le 1er novembre ont reçu leur réponse de l'utilisateur le
6 novembre 2026, avec la validation du palier 1. La question d'origine est gardée, suivie de
la réponse.

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

---

## 10. Documents à mettre à jour, par palier

Mini-plan, à valider avec le cadrage. Rien n'est modifié avant le « oui ».

| Palier | Documents | Ce qui change |
|---|---|---|
| 0 | `TechnicalRequirements.md` (poste d'IA, routage) ; `CHANGELOG.md` | le poste `sandbox_meal_workshop_turn` ; §13.3 ne change pas (le contrat du bac à sable est inchangé) |
| 1 | `FunctionalRequirements.md` §3.2 (ligne Editor et Reader), §5.5 (tableau des actions, paragraphe « Composer un repas avec l'IA », disposition), §6 (lignes « Création de recette réservée », « Recette conçue par l'IA en brouillon », « Explorer filtre sans IA », « Toute recette a un livre » : deux livres au choix pour l'atelier), §7 Livré et « Reste à faire » (« Poser le repas de l'atelier dans le planning ») ; `cas-d-utilisation.html` (tableau des rôles, cas Editor/Admin « Composer un repas avec l'IA », « Figer le repas », légende de « Constituer la bibliothèque ») | business-analyst-culinaire, avec le livrable validé — **fait le 6 nov. 2026** |
| 1 | `TechnicalRequirements.md` §3 (champ `ai_source`, collection `meal_workshop_daily`), §4 (règles de la collection), §13.1 (route), callables et prompts ; `architecture.html` (tableau des fonctions, des collections) ; `diagramme-de-classes.html` ; `diagrammes-de-sequence.html` (tour, figement) ; `CHANGELOG.md` | developpement-tech-couts, avec le code |
| 2 | `FunctionalRequirements.md` §5.8 (« Poser dans le planning » depuis l'atelier) ; `cas-d-utilisation.html` ; `diagrammes-de-sequence.html` ; `CHANGELOG.md` | idem |
