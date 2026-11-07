# Kass'Dalle — Proposition UX : atelier repas conversationnel

Proposition de `ux-designer` du 1er novembre 2026, pour le cadrage
`SPEC-atelier-repas.md`. Rien n'est implémenté : ce document attend la validation de
l'utilisateur avant la première ligne de code. Les numéros de ligne cités sont ceux du
dépôt au 1er novembre 2026.

Le besoin, du point de vue de la personne qui tient le téléphone : « je discute d'un repas
complet avec l'IA, je vois le menu se construire à côté, et quand il me plaît, les plats
nouveaux deviennent des brouillons dans mon livre ».

---

## 1. Parcours

### Depuis Explorer (palier 1)

**Où se place le cinquième bouton.**

- Grand écran : dans la rangée `Wrap` des actions (`search_screen.dart:899-940`), en
  `OutlinedButton.icon`, juste après « Imaginer 3 recettes » et avant « Chercher sur le
  web ». Les deux actions de création de l'IA sont côte à côte ; le web et l'import restent
  en fin de rangée. Visible seulement si `canEdit`, comme « Imaginer 3 recettes ».
- Téléphone : la barre du bas garde ses deux boutons (`_BottomActions`,
  `search_screen.dart:1337-1420`) ; un troisième la ferait passer sur trois lignes à 150 %
  de texte. Le bouton entre dans la feuille « Aller plus loin » (`_openGoFurther`,
  `search_screen.dart:621-678`), en deuxième `ListTile`, après « Imaginer 3 recettes », sous
  `if (canEdit)` : titre « Composer un repas avec l'IA », sous-titre « Discutez d'un menu
  complet. Les plats retenus deviennent des brouillons à relire. ».
- Icône : `Icons.restaurant_menu` (le menu, un objet, comme le globe pour le web et le lien
  pour l'import). Pas `auto_awesome` : « Imaginer 3 recettes » le porte déjà à côté. Pas le
  robot : il marque ce que l'IA a écrit (FR §6), et il servira dans la conversation.
- Un Reader ne voit ni le bouton ni la ligne de la feuille. Rien de grisé.

**Le texte du champ.** Le texte tapé dans « Titre, ingrédient, envie… » est posé dans le
champ de l'atelier comme premier message, non envoyé. C'est le mécanisme de
`recipe_picker_sheet.dart:144-149` (`initialPrompt: _query.trim()`) repris par
`MealIdeasSheet`. L'utilisateur le relit, le complète, puis appuie sur Envoyer : rien ne part
tout seul (FR §5.5, « Aucune ne part toute seule »). Le champ d'Explorer garde son texte au
retour.

**Le périmètre.** Les recettes retenues par les filtres, sans le texte, comme le corpus de
« Chercher avec l'IA » (`aiCorpusSize`, `search_screen.dart:788-795`). Le texte est une
demande, pas un filtre. Point à trancher n° 7.

**Ouverture.** Route `/search/meal-workshop?q=<texte>` sous `AppRoutes.search`
(`app_router.dart:541-544`), dans le `ShellRoute` : le rail et la barre du bas restent, le
shell borne la largeur à 1 200 px (`app_shell.dart:184-186`), l'écran ne pose pas
`ReadableWidth`. La route est enveloppée dans `EditorOnlyGate`
(`features/auth/presentation/editor_only_gate.dart:15`) : `appBarTitle` « Atelier repas »,
`lockedTitle` « Composition réservée aux éditeurs », `fallbackLocation: AppRoutes.search`,
`fallbackLabel` « Retour à Explorer ». L'écran lit une fois, à l'ouverture,
`exploreCorpusProvider` et `explorePreferencesProvider` (`search_providers.dart:52, 83`),
construit les résumés par `buildRecipeSummary` (`search_providers.dart:156`) et fige la
liste en mémoire. Un changement de filtres dans Explorer n'a plus d'effet (P1-3). Cette
lecture est préférée à un `extra` : un `extra` rend la route inatteignable par un lien et
donc la garde du Reader sans objet, et une page web rafraîchie tomberait sur Explorer sans
explication. Point n° 8.

**Les tours.**

1. L'utilisateur écrit (1 500 caractères au plus, compteur), appuie sur Envoyer.
2. Le champ se désactive, son texte reste visible. Dans la liste, une ligne « L'IA
   compose… » avec le robot et un indicateur.
3. Réponse reçue : le texte du champ devient une bulle à droite, le champ se vide et se
   réactive ; la réponse de l'IA s'affiche à gauche, marquée du robot ; le panneau « Menu en
   cours » se redessine, les services changés à ce tour portent une pastille « Modifié ».
4. Sous le champ : « Tour 3 sur 20 · Il vous reste 27 tours aujourd'hui. ».
5. Échec : le champ se réactive avec le texte, une ligne d'erreur s'ajoute à la liste
   (voir §3), avec « Réessayer » quand c'est permis.

**Le figement.**

1. « Figer le repas » (pied du panneau Menu ; sur téléphone, pied de la feuille Menu). Actif
   dès qu'un service porte un titre sans `recipe_id` (P1-10).
2. Boîte « Figer le repas » : première ligne « 3 plats seront rédigés par l'IA, un appel
   chacun. 1 recette existante reste liée telle quelle. » ; section « Livre des brouillons »
   avec deux `RadioListTile` : « Mes créations Kass'Dalle ✨ » (coché) et « Mes recettes
   libres » ; section « Titres déjà dans votre bibliothèque », présente seulement en cas de
   doublon (P1-15), une ligne par doublon : « « Blanquette de veau » existe dans Le Grand
   Livre » et un `SegmentedButton` « Lier la recette existante | Rédiger quand même » (rien
   de présélectionné ; « Figer » reste inactif tant qu'un doublon n'a pas sa réponse, et une
   ligne le dit : « Choisissez pour chaque doublon. »). Boutons « Annuler » / « Figer ».
   C'est la boîte de confirmation d'une action en masse, modèle Admin › Backfills : elle dit
   combien d'appels partent.
3. Le panneau Menu passe en mode figement : le champ de conversation se ferme (« Figement
   en cours… »), chaque service à rédiger affiche son état, dans l'ordre : « Rédaction… »,
   puis « Brouillon créé · Ouvrir », « Non rédigée — Réessayer », « Non rédigée. L'IA n'a
   pas rendu de recette. », « Non rédigée — plafond atteint ». Une recette liée devenue
   illisible : « Recette plus accessible » avec « Rédiger à la place » / « Retirer du
   menu » (P1-14).
4. Fin : `showSuccessSnackBar('3 brouillons créés dans « Mes créations Kass'Dalle ✨ ».')` ;
   chaque brouillon porte « Brouillon créé · Ouvrir » sur la ligne de son service
   (`/drafts/<id>`, comme `generated_recipe_screen.dart:139`), et le pied du panneau dit
   « 3 brouillons créés · 1 recette liée ». Au palier 2, « Poser dans le planning » s'ajoute
   dans le pied du panneau, à la place de « Figer le repas » (§8).
5. Après un figement, le champ reste fermé : la ligne « Repas figé. » et un bouton
   « Nouvelle conversation » (même périmètre, menu vide). Un brouillon créé ne se défait pas
   par un tour de conversation ; mêler des services « Brouillon créé » et des services que
   l'IA peut encore changer dans le même panneau est une source d'erreurs à éviter.
   Point n° 5.

**Le retour.** Flèche, geste, barre du bas, menu latéral, déconnexion : `LeaveGuard`
(`leave_guard.dart`, posé et rendu comme dans `generated_recipe_screen.dart:68-84`) plus
`PopScope`. Avec au moins un tour et aucun brouillon : « Quitter sans enregistrer ? » / « Le
menu et la conversation seront perdus. » / « Rester » « Quitter ». Avec des brouillons créés
et des services non rédigés : « 2 plats ne sont pas rédigés. Quitter sans enregistrer ? ».
Tout rédigé, ou aucun tour : sortie libre. Retour sur Explorer tel qu'on l'a laissé.

### Palier 0, depuis Admin → Bac à sable

Retiré en v0.24.76 : l'atelier est porté dans Explorer (palier 1, §1). Cette section
décrit l'état du palier 0 tel qu'il a existé dans le bac à sable (v0.24.72 à v0.24.75).

Administration → Bac à sable (`sandbox_hub_screen.dart`) → carte « Atelier repas » (entrée
dans `sandbox_registry.dart:10`, icône `Icons.restaurant_menu`, sous-titre « Converser pour
composer un menu. Le JSON du menu et le coût de chaque tour sont lisibles. Rien n'est
enregistré. ») → l'écran de l'expérience sous `presentation/experiments/`. Même écran que
le palier 1, moins « Figer le repas », plus une zone « Mesures » (§6). Le périmètre est
« Mes recettes » + « Ma famille » de l'administrateur, sans filtres ; la ligne de tête dit
« Périmètre : N recettes · M garnitures ». L'appel passe par
`SandboxFunctions.call('meal_workshop.turn', …)` (`sandbox_functions.dart:49`).

---

## 2. Disposition par taille d'écran

Seuil unique : `PlatformUtils.wideBreakpoint` (800, `platform_utils.dart:56`). Largeur du
panneau Menu : `PlatformUtils.sidePanelWidth` (320, `platform_utils.dart:74`). Aucun nombre
en dur dans l'écran.

### Téléphone (une colonne)

```
+----------------------------------+
| <-  Atelier repas                |
+----------------------------------+
| (i) Perimetre : 124 recettes     |   ligne grise, une fois, en tete de liste
|                                  |
|        +-----------------------+ |
|        | Un diner de dimanche  | |   bulle utilisateur, a droite
|        | pour 6, du poisson    | |   (primaryContainer)
|        +-----------------------+ |
| [IA] Je vous propose un veloute  |   bulle IA, a gauche, robot
|      de potimarron, puis un bar  |   (surfaceContainerHigh)
|      roti...                     |
|      Menu mis a jour - 3 services|   ligne secondaire, ouvre la feuille
|                                  |
|      [IA] L'IA compose...        |   pendant un tour (liveRegion)
+----------------------------------+
| Menu - 3 services - 6 parts    > |   bandeau resume, ouvre la feuille Menu
+----------------------------------+
| +--------------------------+ +--+|
| | Votre message...         | |> ||   champ (1 a 5 lignes) + Envoyer
| +--------------------------+ +--+|
| Tour 1 sur 20 - 29 tours   0/1500|   aide a gauche, compteur a droite
+----------------------------------+
|  Biblio   Explorer  Planning ... |   barre du shell
+----------------------------------+
```

- La liste des messages prend la hauteur restante et défile jusqu'au dernier message à
  chaque réponse.
- Le bandeau résumé et le champ sont collés au bas du corps : ils montent avec le clavier,
  rien ne passe dessous. Le bandeau dit ce qui a changé au dernier tour quand c'est le cas :
  « Menu · 4 services · modifié : Dessert ».
- Un appui sur le bandeau, ou sur « Menu mis à jour » sous une bulle, ouvre la **feuille
  Menu** (`showModalBottomSheet`, `isScrollControlled`, pleine hauteur, `useSafeArea`,
  poignée) :

```
+----------------------------------+
|            ----                  |
| Menu en cours          [6 parts] |   titre + bouton parts (dialogue 1-99)
|----------------------------------|
| Entree                           |
| Veloute de potimarron            |
| [A rediger]                      |
| [IA] Ouvre sur du chaud et du    |   le pourquoi, robot + italique
|      doux avant un plat sale     |
|                                  |
| Plat                   [Modifie] |
| Blanquette de veau               |
| Le Grand Livre - recette pour 6, |   recette liee : livre + ecart de parts
| menu pour 6                      |   la ligne s'ouvre (fiche)
|    Riz - 70 g par part           |   garniture
|    Carottes glacees              |   texte libre
|                                  |
| Dessert                          |
| Tarte aux poires                 |
| [Recette inconnue : a rediger]   |   identifiant hors perimetre
|----------------------------------|
| 2 plats a rediger - 1 recette    |
| liee                             |
| [       Figer le repas        ]  |   pied fixe, SafeArea
+----------------------------------+
```

- Le clavier est fermé quand la feuille est ouverte. Échap et le geste la ferment (Flutter,
  `DismissIntent`).
- Le mode figement se déroule dans cette feuille ; elle ne se ferme pas d'un appui hors
  d'elle pendant les appels (`isDismissible: false`, modèle `meal_ideas_sheet.dart:26-28`).

### Tablette et ordinateur (deux colonnes, au-delà de 800)

```
+-----------------------------------------------------------------------------+
| <-  Atelier repas                                                           |
+--------------------------------------------------+--------------------------+
| (i) Perimetre : 124 recettes                     | Menu en cours   [6 parts]|
|                                                  |                          |
|                    +---------------------------+ | Entree                   |
|                    | Un diner de dimanche...   | | Veloute de potimarron    |
|                    +---------------------------+ | [A rediger]              |
| [IA] Je vous propose un veloute de potimarron,   | [IA] Ouvre sur du chaud  |
|      puis un bar roti...                         |                          |
|      Menu mis a jour - 3 services                | Plat            [Modifie]|
|                                                  | Blanquette de veau       |
|                                                  | Le Grand Livre - pour 6  |
|                                                  |    Riz - 70 g par part   |
|                                                  |    Carottes glacees      |
|                                                  |                          |
|                                                  | Dessert                  |
|                                                  | Tarte aux poires         |
|                                                  | [Recette inconnue :      |
|                                                  |  a rediger]              |
|                                                  |--------------------------|
| +------------------------------------+ [Envoyer] | 2 plats a rediger -      |
| | Votre message...                   |           | 1 recette liee           |
| +------------------------------------+   0/1500  | [   Figer le repas    ]  |
| Tour 1 sur 20 - Il vous reste 29 tours aujourd'hui                          |
+--------------------------------------------------+--------------------------+
        <- conversation : le reste ->                <- 320 px (sidePanelWidth) ->
```

- Colonne centrée à 1 200 px par le shell, comme Explorer. Entre 800 et 1 000 px, la
  conversation garde au moins 480 px (`narrowContentBreakpoint`).
- Le panneau Menu défile seul ; son pied (compte, « Figer le repas ») est fixe.
- Ce qui change avec le téléphone : le bandeau résumé et la feuille disparaissent, le
  panneau est toujours visible ; le champ a le focus à l'ouverture ; les lignes de recette
  liée réagissent au survol (curseur main, fond `surfaceContainerHighest`).

### Détail des zones (les deux tailles)

**Liste des messages.** Bulle utilisateur : `primaryContainer` / `onPrimaryContainer`,
alignée à droite, largeur bornée à 80 % de la colonne. Bulle IA : `Icons.smart_toy_outlined`
en `AppIconSize.small`, couleur `primary`, `semanticLabel` « Réponse de l'IA » ; texte en
`SelectableText` brut, sans Markdown ni lien (P1-18) ; au-delà de 1 500 caractères, replié
avec « Lire la suite » / « Réduire ». Sous la bulle, en `bodySmall` `onSurfaceVariant` :
« Menu mis à jour · 3 services », ou « Menu inchangé » quand le JSON est identique au tour
précédent (le cas « Poulet ou poisson ? » du cadrage). Un message système (périmètre,
erreur, plafond) est une carte pleine largeur, jamais une bulle.

**Champ de saisie.** `StylusPadTextField` (`core/presentation/stylus_pad_text_field.dart:49`,
celui des autres champs libres), `minLines: 1`, `maxLines: 5`, `maxLength: 1500` avec le
compteur Flutter « 123/1500 » (convention du formulaire de ticket,
`ticket_form_screen.dart:507`), `hintText` « ex : un dîner pour 6, du poisson, un dessert
aux fruits ». Bouton `IconButton.filled` `Icons.send_rounded`, tooltip « Envoyer », 48 px,
inactif si le champ est vide, pendant un tour, à 20 tours, à 0 tour restant, pendant le
chargement du contexte. Clavier : `TextInputAction.send`, Entrée envoie, Maj+Entrée saute
une ligne (même barre que « Modifier la recette », `generated_recipe_screen.dart:568-601`).
Point n° 4. Autofocus sur grand écran ; sur téléphone seulement si le champ est vide (règle
de `advanced_dish_search_screen.dart:232`). Sous le champ, `helperText` : avant le premier
tour « Périmètre : 124 recettes · 20 tours au plus par conversation. » ; ensuite « Tour 3
sur 20 · Il vous reste 27 tours aujourd'hui. ».

**Panneau « Menu en cours ».**

- En-tête : titre `titleMedium` et, à droite, un `OutlinedButton` « 6 parts » (tooltip
  « Nombre de parts du menu ») qui ouvre `showPortionsInputDialog`
  (`portions_input_dialog.dart:113`, titre « Nombre de parts », 1 à 99, `unit: 'parts'`),
  le même dialogue que « Changer les parts » du planning (`planning_screen.dart:1065-1072`).
  La valeur part au tour suivant ; elle ne modifie aucune recette.
- Une ligne par service, dans l'ordre rendu, bâtie sur le style de
  `meal_composer.dart:1304-1323` : icône du type par `courseRoleIcon`
  (`meal_course_style.dart:7`), type en `labelLarge` couleur `primary` (« Entrée »,
  « Plat », « Sorbet », « Fromage », « Dessert », ou le `course_label` d'un service
  « Autre » : « Trou normand »), titre en `bodyLarge`, puis :
  - **recette existante liée** : `Icons.menu_book_outlined` inline + « Le Grand Livre ·
    recette pour 6, menu pour 4 » (écart affiché seulement s'il existe) ; la ligne s'ouvre
    sur la fiche (`push('/recipes/<id>')`), c'est le seul lien de l'écran (P1-18) ;
  - **plat nouveau** : puce « À rédiger » (`Icons.edit_note`, `secondaryContainer`) ;
  - **identifiant non reconnu** (`unknown_recipe_id`) : puce « Recette inconnue : à
    rédiger » en `tertiaryContainer` / `onTertiaryContainer`, tooltip « L'IA a cité une
    recette absente du périmètre. Le plat sera rédigé. » ;
  - description en `bodySmall` `onSurfaceVariant` quand elle existe ;
  - le pourquoi : robot inline `primary` + texte italique `bodySmall`, exactement la ligne
    « raison » de `SearchResultTile` (`search_widgets.dart:146-170`) ;
  - sous un plat, les accompagnements en retrait de 16 px (modèle
    `planning_widgets.dart:520-529`) : garniture `Icons.rice_bowl_outlined` + « Riz · 70 g
    par part » (`MealComponent.quantityLabel` quand la garniture est connue) ; recette
    `Icons.menu_book_outlined`, ouvrable ; texte libre sans icône. Un septième
    accompagnement n'arrive jamais : le serveur tronque.
  - puce « Modifié » (`secondaryContainer`) sur les services dont titre, rôle, recette ou
    accompagnements ont changé au dernier tour ; retirée au tour suivant. C'est aussi
    l'outil de mesure du palier 0 (« un service non visé a changé »).
- Pied : « 2 plats à rédiger · 1 recette liée » ; « Menu limité à 10 services. » si
  `truncated` ; `FilledButton` « Figer le repas » (`Icons.save_outlined`) ; sous un bouton
  inactif, la raison en `bodySmall` : « Le menu est vide. » ou « Rien à rédiger : toutes les
  recettes existent déjà. ».
- Aucune image dans le panneau : pas de vignette de recette, pas d'image extérieure.

---

## 3. États

| Situation | Ce que voit l'utilisateur | Composant |
|---|---|---|
| Ouverture, menu vide | Conversation : première carte « Périmètre : 124 recettes » ; liste vide avec `AppEmptyState(icon: Icons.forum_outlined, title: 'Dites ce que vous voulez manger', message: 'Pour qui, quand, avec quelles envies ou contraintes. L'IA répond et pose un premier menu dans « Menu en cours ». Chaque message envoyé est un appel à l'IA.')`. Champ pré-rempli du texte d'Explorer, non envoyé. Panneau : `AppEmptyState(icon: Icons.restaurant_menu, title: 'Pas encore de menu', message: 'Le premier menu s'affichera ici après votre premier message.')`. Pas de message d'accueil de l'IA : il coûterait un tour. | `app_states.dart` |
| Contexte en chargement (préférences, garnitures) | Champ actif ; Envoyer inactif ; aide « Préparation de l'atelier… ». Durée attendue : moins de deux secondes. | — |
| Contexte en erreur | Carte `AppErrorState(compact: true, title: 'Atelier non prêt', onRetry)` dans la liste. Pas d'envoi dégradé : un tour sans les préférences du foyer contredirait ses contraintes sans le dire. | `AppErrorState` |
| Périmètre à 0 recette | Carte d'information en tête de liste (`secondaryContainer`, `Icons.info_outline`) : « Aucune recette de la bibliothèque dans le périmètre : l'IA ne proposera que des plats nouveaux. » Aide sous le champ : « Périmètre : aucune recette ». Envoyer reste actif (P1-4). | modèle `_PickBanner`, `search_screen.dart:997` |
| Tour en cours | Champ inactif, texte conservé ; Envoyer inactif ; ligne « L'IA compose… » avec robot et `CircularProgressIndicator` 16 px, `Semantics(liveRegion: true)` ; panneau inchangé. Le bouton parts et « Figer » sont inactifs le temps du tour. | — |
| Réponse illisible | Carte d'erreur dans la liste : « Réponse illisible, menu inchangé. L'IA n'a pas rendu de réponse lisible. » avec « Réessayer » (renvoie le texte resté dans le champ). Menu du tour précédent conservé. Aide : le compteur de tours a décompté (le tour a été facturé). | `AppErrorState(compact: true)` |
| Réseau perdu pendant un tour | Carte : « Réponse non reçue. Connexion perdue. » avec « Réessayer ». Texte toujours dans le champ. Tour non compté. | `failureMessage('Réponse non reçue', e)`, `error_message.dart:237` |
| 20 tours atteints | Champ et Envoyer inactifs ; aide : « Conversation terminée : 20 tours. Figez le repas, ou ouvrez une nouvelle conversation. » Bouton texte « Nouvelle conversation » sous l'aide. Menu et « Figer le repas » disponibles. | — |
| 30 tours du jour atteints | Même forme ; aide : « Vous avez fait vos 30 tours d'aujourd'hui. Le compteur repart demain. » Pas de « Réessayer ». Menu et « Figer le repas » disponibles (le figement n'est pas compté dans les 30). | modèle `remainingSearchesLine`, `web_search.dart:213` |
| Budget d'IA du jour atteint, sur un tour | Carte sans « Réessayer » : « Réponse non reçue. Limite d'utilisation de l'IA atteinte pour aujourd'hui. Réessayez demain, ou demandez à un administrateur de relever la limite. » (préfixe + message du serveur, `aiBudgetRefusalMessage`). | `failureMessage` |
| Budget atteint pendant un figement | Services restants : « Non rédigée — plafond atteint » ; aucun autre appel ; `showErrorSnackBar('Recette non rédigée. Limite d'utilisation de l'IA atteinte pour aujourd'hui. …')`. Les brouillons déjà créés restent. | `showFailureSnackBar` |
| Menu vide au figement | « Figer le repas » inactif + « Le menu est vide. » | — |
| Rien à rédiger | Inactif + « Rien à rédiger : toutes les recettes existent déjà. » (palier 2 : « Poser dans le planning » prend la place) | — |
| Figement en cours | Champ fermé : « Figement en cours… » ; ligne par service : « Rédaction… » (indicateur), puis « Brouillon créé · Ouvrir » ; les autres services attendent avec « En attente ». La feuille Menu (téléphone) ne se ferme pas d'un appui hors d'elle. | — |
| Échec partiel | « Non rédigée — Réessayer » (réseau, serveur) ; « Non rédigée. L'IA n'a pas rendu de recette. » avec « Réessayer » ; « Recette plus accessible » + « Rédiger à la place » / « Retirer du repas ». Un service « Brouillon créé » n'est jamais rejoué. | — |
| Figement terminé | `showSuccessSnackBar('3 brouillons créés dans « Mes créations Kass'Dalle ✨ ».')` ; « Brouillon créé · Ouvrir » sur chaque ligne de service (`Icons.edit_note`) et « 3 brouillons créés · 1 recette liée » dans le pied du panneau ; ligne « Repas figé. » à la place du champ + « Nouvelle conversation ». | `context_extensions.dart` |
| Quitter | « Quitter sans enregistrer ? » / « Le menu et la conversation seront perdus. » / « Rester » (TextButton) « Quitter » (FilledButton). Variante : « 2 plats ne sont pas rédigés. Quitter sans enregistrer ? ». | `leave_guard.dart`, `generated_recipe_screen.dart:159-179` |
| Reader par un lien | « Composition réservée aux éditeurs » / « Composer un repas avec l'IA est réservé aux éditeurs et aux administrateurs. Demandez à un administrateur de vous nommer éditeur. » / « Retour à Explorer ». | `EditorOnlyGate` |
| Refus `permission-denied` en cours de session (rôle retiré) | Carte sans « Réessayer » : « Réponse non reçue. L'IA est réservée aux éditeurs. » | `aiEditorOnlyRefusal`, `error_message.dart:259` |

---

## 4. Libellés

| Endroit | Texte |
|---|---|
| Bouton d'Explorer (rangée et feuille) | « Composer un repas avec l'IA » |
| Sous-titre dans « Aller plus loin » | « Discutez d'un menu complet. Les plats retenus deviennent des brouillons à relire. » |
| Titre de l'écran | « Atelier repas » |
| Carte de tête | « Périmètre : 124 recettes » / « Aucune recette de la bibliothèque dans le périmètre : l'IA ne proposera que des plats nouveaux. » |
| État vide conversation | « Dites ce que vous voulez manger » + message ci-dessus |
| Hint du champ | « ex : un dîner pour 6, du poisson, un dessert aux fruits » |
| Bouton | « Envoyer » (tooltip) |
| Aide sous le champ | « Périmètre : 124 recettes · 20 tours au plus par conversation. » puis « Tour 3 sur 20 · Il vous reste 27 tours aujourd'hui. » ; « Il vous reste 1 tour aujourd'hui. » au singulier |
| Pendant un tour | « L'IA compose… » |
| Sous une bulle IA | « Menu mis à jour · 3 services » / « Menu inchangé » ; « Lire la suite » / « Réduire » |
| Panneau | « Menu en cours » ; « 6 parts » ; dialogue « Nombre de parts » ; « Pas encore de menu » |
| Types de service | « Entrée », « Plat », « Sorbet », « Fromage », « Dessert », « Autre » ou son libellé (`MealComponentRole.label`, `meal_component.dart:43`) |
| Puces | « À rédiger » ; « Recette inconnue : à rédiger » ; « Modifié » |
| Recette liée | « Le Grand Livre · recette pour 6, menu pour 4 » |
| Pied du panneau | « 2 plats à rédiger · 1 recette liée » ; « Menu limité à 10 services. » ; « Figer le repas » ; « Le menu est vide. » ; « Rien à rédiger : toutes les recettes existent déjà. » |
| Boîte de figement | titre « Figer le repas » ; « 3 plats seront rédigés par l'IA, un appel chacun. 1 recette existante reste liée telle quelle. » ; « Livre des brouillons » ; « Mes créations Kass'Dalle ✨ » / « Mes recettes libres » ; « Titres déjà dans votre bibliothèque » ; « Lier la recette existante » / « Rédiger quand même » ; « Choisissez pour chaque doublon. » ; « Annuler » / « Figer » |
| Lignes de figement | « En attente » ; « Rédaction… » ; « Brouillon créé » + « Ouvrir » ; « Non rédigée — Réessayer » ; « Non rédigée. L'IA n'a pas rendu de recette. » ; « Non rédigée — plafond atteint » ; « Recette plus accessible » + « Rédiger à la place » / « Retirer du repas » |
| Fin de figement | « 3 brouillons créés dans « Mes créations Kass'Dalle ✨ ». » ; « Brouillons créés » ; « Repas figé. » ; « Nouvelle conversation » |
| Erreurs | « Réponse non reçue. Connexion perdue. » ; « Réponse illisible, menu inchangé. L'IA n'a pas rendu de réponse lisible. » ; « Réponse non reçue. Limite d'utilisation de l'IA atteinte pour aujourd'hui. … » ; « Recette non rédigée. … » ; « Réessayer » |
| Plafonds | « Conversation terminée : 20 tours. Figez le repas, ou ouvrez une nouvelle conversation. » ; « Vous avez fait vos 30 tours d'aujourd'hui. Le compteur repart demain. » |
| Sortie | « Quitter sans enregistrer ? » ; « Le menu et la conversation seront perdus. » ; « 2 plats ne sont pas rédigés. Quitter sans enregistrer ? » ; « Rester » / « Quitter » |
| Reader | « Composition réservée aux éditeurs » ; « Retour à Explorer » |

Aucun mot technique (JSON, callable, feature) hors du palier 0.

---

## 5. Conventions à respecter (chemins)

- Thème : couleurs du `ColorScheme` seulement (`core/theme/app_theme.dart`) ; tailles
  `AppIconSize` (`core/theme/app_icon_size.dart`) ; pas de valeur en dur.
- États : `AppLoadingState`, `AppEmptyState`, `AppErrorState(compact: true, onRetry)`
  (`core/widgets/app_states.dart`). Succès et échec par `showSuccessSnackBar` /
  `showFailureSnackBar` (`core/utils/context_extensions.dart`), jamais un message neutre.
- Largeur : posée par le shell (`core/presentation/app_shell.dart:184-186`, liste
  `wantsFullWidth` 205-216). L'écran ne pose pas `ReadableWidth`. Note pour le portage :
  `image_import_screen.dart:209` le pose lui-même sous `/admin/sandbox`, que le shell borne
  déjà ; le nouvel écran du bac à sable ne doit pas recopier ce doublon.
- Seuils : `PlatformUtils.wideBreakpoint`, `sidePanelWidth`, `narrowContentBreakpoint`
  (`core/utils/platform_utils.dart`).
- Deux icônes, deux sens (FR §6) : `Icons.smart_toy_outlined` sur chaque bulle de l'IA et
  sur chaque « pourquoi » du menu ; aucune étoile dans l'écran ; le bouton d'entrée porte
  `restaurant_menu`.
- Rôles : bouton et ligne masqués au Reader (`canEdit`), jamais grisés ; garde de route
  `EditorOnlyGate` (`features/auth/presentation/editor_only_gate.dart`) ; refus serveur
  affiché par `aiEditorOnlyRefusal`.
- Coût visible : rien ne part à la frappe ni au défilement ; chaque tour part d'un appui
  sur Envoyer ou d'Entrée dans le champ ; le figement s'annonce dans une boîte qui compte
  les appels ; le nombre de tours restants est sous le champ.
- Travail non perdu : `LeaveGuard` + `PopScope` (`core/presentation/leave_guard.dart`,
  câblage de `generated_recipe_screen.dart:68-84, 462-470`) ; « Retirer du repas » ne demande
  pas de confirmation ; « Nouvelle conversation » en demande une tant que les 20 tours ne sont pas atteints (v0.24.75, §7) ;
  « Quitter » en demande une.
- Données partagées : le nombre de parts vit dans le menu en mémoire et part au prompt ; une
  recette liée n'est ni copiée ni modifiée ; l'écart « recette pour 6, menu pour 4 » est
  affiché, pas écrit.
- Accessibilité : cibles 48 px (Envoyer, parts, lignes de service, « Ouvrir ») ; tooltip ou
  `semanticLabel` sur chaque icône seule ; `liveRegion` sur « L'IA compose… » et sur les
  erreurs ; ordre de tabulation champ → Envoyer → parts → services → Figer ; texte à 200 % :
  les bulles s'étirent, le pied du panneau empile compte et bouton, la barre d'Explorer
  garde sa règle `stacked` (`search_screen.dart:1364`).
- Champ : `StylusPadTextField` (`core/presentation/stylus_pad_text_field.dart`) pour le
  stylet sur tablette. Pas d'`AppShortcuts` : aucun Ctrl+S (figer coûte de l'argent ; une
  boîte confirme déjà). Échap ferme boîtes et feuilles par Flutter.
- Pas d'image : ni vignette, ni image extérieure.
- Bac à sable : `ErrorReportService` avec feature `sandbox.mealWorkshop.*` ;
  `SandboxModelPicker` (`features/sandbox/presentation/widgets/sandbox_model_picker.dart`) ;
  `SandboxFunctions.call` (`features/sandbox/data/sandbox_functions.dart:49`) ; entrée dans
  `sandbox_registry.dart`.

---

## 6. Palier 0 et palier 1 : ce qui diffère

Le palier 0 est l'écran du palier 1 avec une troisième zone « Mesures ». Les deux zones
principales, leurs libellés et leurs états sont ceux décrits plus haut, pour que le portage
soit une réécriture à l'identique de la disposition.

1. **Accès** : carte du bac à sable, pas Explorer ; périmètre « Mes recettes » + « Ma
   famille » de l'admin, sans filtres ; pas de `EditorOnlyGate` (le routeur garde déjà
   `/admin`, `app_router.dart:225`).
2. **Pas de « Figer le repas »** : le pied du panneau garde le compte « 2 plats à rédiger ·
   1 recette liée » et une ligne « Rien n'est enregistré : bac à sable. ». Pas de bouton
   grisé.
3. **Zone « Mesures »** : à droite sous le panneau Menu (grand écran), ou troisième écran de
   la feuille (téléphone, `SegmentedButton` « Menu | Mesures » en tête de feuille).
   Contenu : `SandboxModelPicker` (poste `sandbox_meal_workshop_turn`) ; « Contexte envoyé :
   48 200 caractères · ≈ 12 000 jetons d'entrée » ; sous chaque bulle IA, une ligne
   `bodySmall` monospace « 0,0123 $ · 11 240 → 420 jetons · 4,1 s · Gemini 2.5 Flash » et
   un `ExpansionTile` « Réponse brute » avec le JSON contrôlé en `SelectableText` monospace
   et, en dessous, les champs de contrôle du serveur (`inventedIds`, `truncated`, services
   écartés) ; tableau récapitulatif des tours (n°, coût, jetons, durée, identifiants
   inventés) avec « Copier le tableau » pour le compte rendu d'une page du cadrage.
4. **Plafonds** : 20 tours et 1 500 caractères côté écran et serveur ; pas de compteur des
   30 tours du jour (poste admin, budget du jour seul) : l'aide dit « Tour 3 sur 20 ».
5. **Parts par défaut** : constante 4 au palier 0 ; au palier 1, la préférence
   `targetPortions` du planning quand elle est posée, sinon 4 (point n° 6).
6. **Erreurs** : le code renvoyé par `sandboxFn` s'affiche sous le message (l'admin lit les
   codes) ; au palier 1, `failureMessage` seul, « Détails » étant déjà réservé aux admins
   par `AppErrorState`.
7. **Garde de sortie** : conservée au palier 0 (vingt tours d'un scénario se perdent sinon
   d'un appui sur le rail) ; c'est du code de production importé, pas modifié.
8. **Documentation** : rien dans FR ni dans les cas d'utilisation au palier 0 ; le poste
   `sandbox_meal_workshop_turn` dans `TechnicalRequirements.md` et le `CHANGELOG.md`.

---

## 7. Choix Plat | Menu (v0.24.75)

Décision de l'utilisateur après les trois premiers tours réels : la personne compose un
**plat** et ses accompagnements, ou un **menu** complet. « Plat » par défaut, fixé pour la
durée d'une conversation, non persisté.

- **Commande** : `SegmentedButton<MealKind>` (`features/planning/domain/meal_kind.dart`),
  copie des segments de `meal_composer.dart` (`Icons.restaurant_outlined` /
  `Icons.restaurant_menu_outlined`, `showSelectedIcon: false`), tooltips « Un seul plat et
  ses accompagnements » / « Entrée, plat, fromage, dessert… ». En tête de la colonne
  conversation, avant la liste des messages, aligné à gauche, padding `fromLTRB(12, 8, 12,
  0)`. Inactif pendant un tour.
- **Sans conversation** : bascule libre ; le texte du champ reste ; la carte d'erreur d'un
  tour échoué disparaît ; titres et états vides changent.
- **Avec une conversation** : boîte « Passer en menu ? » / « Passer en plat ? », corps « La
  conversation et le plat en cours seront perdus. Rien n'était enregistré. » (ou « …le menu
  en cours… »), « Annuler » (`TextButton`) / « Passer en menu » (`FilledButton`), forme de
  `planning_screen.dart` (« Repasser en plat ? »). Confirmé : nouvelle conversation dans le
  nouveau mode, parts, modèle et mesures conservés, rang de conversation incrémenté, texte du
  champ conservé. Annulé : rien ne bouge.
- **« Nouvelle conversation »** : visible dès le premier tour (hors tour en cours), avec
  confirmation « Nouvelle conversation ? » / même corps / « Annuler » / « Nouvelle
  conversation » tant que les 20 tours ne sont pas atteints ; à 20 tours, sans confirmation.
- **Envoi** : le payload porte `kind` (`plat` ou `menu`).
- **Libellés en mode Plat** : panneau « Plat en cours » ; état vide de la conversation
  « Dites ce que vous voulez manger » / « Pour qui, quand, avec quelles envies ou
  contraintes. L'IA répond et pose un premier plat dans « Plat en cours ». Chaque message
  envoyé est un appel à l'IA. » ; état vide du panneau `Icons.restaurant_outlined`, « Pas
  encore de plat », « Le plat s'affichera ici après votre premier message. » ; tooltip du
  bouton parts « Nombre de parts » (les deux modes) ; bandeau téléphone « Plat · vide · 4
  parts » puis « Plat · [titre du plat] · 4 parts · modifié » ; sous une bulle de l'IA « Plat
  mis à jour » / « Plat inchangé » (sans compte de services) ; pied du panneau « Pas encore
  de plat. », « Plat limité à 2 services. » si tronqué, et « Plat seul : N services
  écartés. » quand le contrôle serveur a écarté des services d'un autre rôle ; hint du champ
  « ex : un plat de poisson pour 4 ce soir, avec un féculent » ; garde de sortie « Le plat et
  la conversation seront perdus. » ; carte d'un tour illisible « Réponse illisible, plat
  inchangé. » ; réponse vide « L'IA n'a rien écrit et le plat n'a pas changé. » / « L'IA n'a
  rien écrit : seul le plat a changé. » ; feuille téléphone : premier segment « Plat », second
  « Mesures ». Mode Menu : textes du §4 inchangés. Dans les deux modes, le message serveur
  d'une réponse illisible est neutre (« L'IA n'a pas rendu de réponse lisible. »), l'écart de
  parts sous une recette liée se lit « recette pour 6, repas pour 4 », et « Nouvelle
  conversation » reste visible mais inactif pendant un tour.
- **Mesures** : colonne « mode » (`plat` / `menu`) juste après « conv. », dans le tableau de
  l'écran et dans le texte tabulé copié ; colonne « cache » (jetons relus et écrits) après
  « jetons ».

---

## 8. Palier 2 — Poser dans le planning

Proposition de `ux-designer` du 7 novembre 2026, alignée sur les critères P2-1 à P2-15 de
`SPEC-atelier-repas.md` (§3, « Palier 2 ») et sur les réponses de l'utilisateur du 7 novembre
(planning d'un groupe possédé admis, parts du menu, plat principal sans recette posé par son
titre, `choice_source: workshop`, pas d'agenda à la pose, panneau sans action après la pose).
Les numéros de ligne cités sont ceux du dépôt au 7 novembre 2026 (v0.24.77).

Le besoin, du point de vue de la personne qui tient le téléphone : « mon repas est figé,
je choisis le jour et il entre dans mon planning, ou dans celui de ma famille, avec tous
ses services et pour le nombre de parts que j'ai dit ».

### 8.1 Où et quand (P2-1, P2-2)

Le pied du panneau « Menu en cours » (`_buildMenuFooter`,
`kass_dalle/lib/features/search/presentation/meal_workshop/meal_workshop_screen.dart:1356-1431`)
porte après un figement le compte « 3 brouillons créés · 1 recette liée » (`freezeFooterLine`,
`meal_workshop_freeze.dart:236-238`) et plus aucun bouton : le bloc « Figer le repas » n'est
construit que si `_freezeLines == null` (lignes 1408-1425). « Poser dans le planning » prend
cette place. Il n'y a pas de carte « Brouillons créés » : chaque brouillon est sur la ligne
de son service (`WorkshopFreezeLine`, `meal_workshop_widgets.dart:700-713`).

| Moment | Ce que voit l'utilisateur |
|---|---|
| Avant un figement, au moins un plat à rédiger | Pas de bouton « Poser » : « Figer le repas », comme au palier 1 |
| Figement en cours (`_freezing`) | Pas de bouton : le compte seul ; les lignes disent « Rédaction… » |
| Figement terminé, complet ou partiel, au moins un service `plat`, aucune ligne « Recette plus accessible » sans réponse | `FilledButton.icon` « Poser dans le planning » (`AppIcons.calendarExport`), actif, sous le compte |
| Figement terminé, aucun service `plat` (mode Menu : entrée et dessert seuls ; ou plat retiré) | Bouton inactif + « Un repas planifié a besoin d'un plat. » en `bodySmall`, comme « Le menu est vide. » |
| Figement terminé, une ligne « Recette plus accessible » sans réponse | Bouton inactif + « 1 recette plus accessible : rédigez à la place ou retirez-la du repas. » (« 2 recettes plus accessibles : rédigez à la place ou retirez-les du repas. ») |
| Rien à rédiger (menu non vide, `canFreeze` faux, aujourd'hui « Rien à rédiger : toutes les recettes existent déjà. », lignes 1381-1383) | « Poser dans le planning » à la place de « Figer », actif si un `plat` existe ; sous lui, `bodySmall` « Rien à rédiger : les recettes seront liées telles quelles. ». Un appui relit chaque recette liée comme un figement sans plat à rédiger (`_startFreeze` avec `toWriteCount == 0`, lignes 584-608 : aucun appel, aucun livre, aucun compte rendu ; le champ se ferme, « Repas figé. »), puis ouvre la boîte. Si une recette n'est plus lisible, la boîte ne s'ouvre pas : la ligne dit « Recette plus accessible » + « Rédiger à la place » / « Retirer du repas » (P1-14), et le bouton reste, inactif avec la ligne ci-dessus |

Le Reader n'atteint pas l'écran (`EditorOnlyGate`). Rien de plus n'est masqué.

### 8.2 Parcours (P2-3, P2-7, P2-11)

1. Appui sur « Poser dans le planning ». Téléphone, depuis la feuille Menu : la feuille se
   ferme, la boîte s'ouvre (mécanisme de `_requestFreeze(fromSheet: true)`,
   `meal_workshop_screen.dart:547-550`, sans réouverture verrouillée). Grand écran : boîte
   centrée par-dessus les deux colonnes.
2. La boîte « Poser dans le planning » (§8.3) s'ouvre sur aujourd'hui, à l'heure du jour de
   semaine (`PlanningPreferences.mealTimeFor`, `planning_preferences.dart:345-351`, celle
   d'un jour libre, `planning_screen.dart:2963`). Elle lit la recette du plat principal par
   son identifiant (parts, durées, P2-4 ; et pour dire si un brouillon est introuvable,
   P2-6) et les repas du planning visé ce jour-là (`getMealsBetween(from: jour, to: jour,
   groupId)`, `planning_providers.dart:313-333`, P2-7).
3. La personne change le planning, la date (calendrier de « Replanifier » : aujourd'hui à
   aujourd'hui + 730 jours, `planning_screen.dart:895-900`), l'heure. Chaque nouvelle date
   relance la lecture du jour ; l'heure suit le jour de semaine tant qu'elle n'a pas été
   changée à la main. Le jour occupé s'annonce dans la boîte dès le choix de la date.
4. Appui sur « Poser » (« Ajouter quand même » si le jour est occupé). Bouton inactif le
   temps de l'écriture (`PlanningRepository.addMeal`) : pas de double pose. Aucun appel
   d'IA, aucune écriture dans `recipes`, rien dans l'agenda (P2-12, P2-13).
5. Succès : la boîte se ferme, `showSuccessSnackBar`, le pied passe en « Posé le … » (§8.5).
   Échec : la boîte reste ouverte, `showErrorSnackBar` (§8.7) ; « Poser » rejoue d'abord la
   lecture du jour (P2-11) : un repas écrit côté serveur malgré une coupure apparaît comme
   « déjà un repas » au lieu d'être doublé.

### 8.3 La boîte « Poser dans le planning » (P2-3, P2-6, P2-7, P2-9)

Ouverte par `showAdaptiveSheet(context, maxWidth: 480, child: …)`
(`core/presentation/adaptive_sheet.dart:16-44`) : feuille du bas sur téléphone, boîte de
480 px au plus sur grand écran, comme « Planifier pour… » (`planning_target_sheet.dart:41-46`).
Même forme de lignes que la feuille « Planifier » (`schedule_recipe_sheet.dart`).

```
+----------------------------------------+
| [cal]  Poser dans le planning          |   titre, Icons.calendar_month_outlined
|----------------------------------------|
| Menu · 4 services                      |   récapitulatif, bodyMedium puis bodySmall
|   Entrée   Velouté de potimarron       |
|            · brouillon                 |
|   Plat     Blanquette de veau          |
|            · Le Grand Livre            |
|            · Riz, Carottes glacées     |   accompagnements du plat
|   Fromage  Comté · sans recette        |
|   Dessert  Tarte aux poires · brouillon|
| 1 plat sans recette sera posé par son  |   seulement s'il y en a (P2-6)
| titre : Comté. Vous pourrez lui        |
| choisir une recette depuis le planning |
| (« Composer le menu »).                |
| Les brouillons ne s'ouvrent pour les   |   seulement : cible = groupe et au moins
| membres qu'une fois validés.           |   un brouillon (P2-9)
|----------------------------------------|
| [grp] Planning          Mon planning  >|   seulement si un groupe est possédé
| [ev]  Date          mar. 12 nov. 2026 >|
| [hr]  Heure de début           19:30  >|
| [pp]  Parts          6, parts du menu  |   ligne d'information, sans chevron
|       Famille Dupont cuisine           |   seulement si groupMealPortions diffère
|       d'habitude pour 4 ce jour-là.    |   (P2-9)
| (i) Mar. 12 nov. a déjà un repas :     |   seulement si le jour est occupé (P2-7)
|     Blanquette de veau, 19:30.         |   Icons.info_outline, secondaryContainer
|     [Choisir une autre date]           |
|                                        |
|                  [Annuler]  [Poser]    |   OverflowBar ; à 200 %, « Poser » au-dessus d'« Annuler »
+----------------------------------------+
```

- **Récapitulatif.** « Menu · 4 services » (mode Plat : « Plat · Blanquette de veau »). Une
  ligne par service dans l'ordre du menu : type (`WorkshopCourse.typeLabel`), titre, puis
  « · brouillon » (`FreezeDraftCreated`), « · Le Grand Livre » (`FreezeLinked`,
  `recipe.bookTitre`) ou « · sans recette » (§8.4) ; sous un plat, ses accompagnements
  (`sides.map(label).join(', ')`). Aucune action : le panneau derrière porte les « Ouvrir ».
- **Plat sans recette** (P2-6) : « 1 plat sans recette sera posé par son titre : Comté.
  Vous pourrez lui choisir une recette depuis le planning (« Composer le menu »). » ;
  pluriel : « 2 plats sans recette seront posés par leur titre : Comté, Tarte aux poires.
  Vous pourrez leur choisir une recette depuis le planning (« Composer le menu »). ». Si
  c'est le plat principal : « Le plat principal n'a pas de recette : le repas sera posé
  par son titre, sans courses ni nutrition. Vous pourrez le concevoir depuis le planning
  (« Concevoir avec l'IA »). », en premier.
- **Planning** (P2-3, P2-9) : la ligne de `schedule_recipe_sheet.dart:509-544` telle quelle,
  `PopupMenuButton<PlanningTarget>`, tooltip « Choisir le planning », « Mon planning » puis
  chaque groupe possédé avec « Planning du groupe · 4 membres » (`PlanningTarget.title` /
  `subtitle`, `planning_target.dart:41-48`, `ownedPlanningGroupsProvider`). Présente
  seulement si l'utilisateur possède un groupe. Changer de planning relance la lecture du
  jour : un repas de groupe n'occupe pas le jour du planning personnel, ni l'inverse.
- **Date** : `_PickerRow` « Date », `showDatePicker(initialDate: aujourd'hui, firstDate:
  aujourd'hui, lastDate: aujourd'hui + 730 j)`, valeur « mar. 12 nov. 2026 » (`_formatDate`,
  `schedule_recipe_sheet.dart:449-466`).
- **Heure de début** : `_PickerRow` « Heure de début », `showTimePicker`, valeur
  `mealTimeFor(date.weekday)` tant que la personne n'a pas choisi, puis son choix ;
  `TimeOfDay.format(context)`.
- **Parts** : `_InfoRow` « Parts » / « 6, parts du menu » (P2-3). Pas de chevron : les
  parts sont celles du figement, le bouton des parts est inactif depuis (`_frozen`). Sous
  elle, pour un groupe dont `groupMealPortions` du jour choisi diffère : « Famille Dupont
  cuisine d'habitude pour 4 ce jour-là. » (P2-9). Ajout `ux` sous la même ligne, quand une
  recette liée est le plat principal et que ses parts diffèrent : « Recette pour 4 : les
  quantités seront recalculées pour ce repas, la recette ne change pas. » (P2-8 dit à la
  personne).
- **Jour occupé** (P2-7) : carte `secondaryContainer`, `Icons.info_outline`,
  `Semantics(liveRegion: true)` : « Mar. 12 nov. a déjà un repas : Blanquette de veau,
  19:30. » (deux repas et plus : « … : Blanquette de veau, 19:30 et 1 autre repas. ») ;
  `TextButton` « Choisir une autre date » (ouvre le calendrier) ; le bouton principal
  devient « Ajouter quand même ». Rien n'est remplacé. Lecture du jour en échec :
  `bodySmall` « Ce jour n'a pas pu être vérifié. », bouton « Poser » inchangé.
- **Boutons** : `OverflowBar` aligné à droite, « Annuler » (`TextButton`) et « Poser »
  (`FilledButton.icon`, `AppIcons.calendarExport`). Pendant l'écriture : indicateur dans le
  bouton, lignes inactives, `PopScope(canPop: false)` : ni glisser, ni Échap, ni appui hors
  de la boîte.
- **Cibles** : chaque `_PickerRow` reçoit `minHeight: 48` (celui de
  `schedule_recipe_sheet.dart:661-662` fait 10 px de marge autour d'une ligne de texte,
  soit 40 à 44 px — à ne pas recopier tel quel).
- **Ordre de focus** : Planning → Date → Heure de début → « Choisir une autre date » (si
  présent) → Annuler → Poser. Focus initial sur Date sur grand écran ; aucun sur téléphone
  (aucun champ de texte : le clavier ne s'ouvre jamais). Entrée active la ligne qui a le
  focus ; Échap ferme hors écriture (Flutter, `DismissIntent`).
- **Lecteur d'écran** : titre en `Semantics(header: true)` ; chaque ligne lue « Date,
  mardi 12 novembre 2026, bouton » (`InkWell` + `Semantics(button: true)`) ; la ligne
  « Parts » lue comme texte ; la carte du jour occupé et les phrases « sans recette » en
  `liveRegion` ; le bouton principal annonce son libellé courant.

### 8.4 Services sans recette (P2-2, P2-6)

Une ligne `FreezeFailed`, `FreezeNoRecipe`, `FreezeBudgetStopped`, `FreezeSaveFailed`,
`FreezePermissionDenied` (`meal_workshop_freeze.dart:166-197`), ou un brouillon créé puis
introuvable à la relecture, est posée **en texte libre** sous son titre
(`MealComponent.free(title, role: …, justification: why)`, `meal_component.dart:220-230`) :
jamais exclue, jamais bloquante. Le planning connaît cette forme (« nom libre »), et
« Composer le menu » lui donne une recette plus tard. Plat principal : `recipe_id` nul,
`recipe_titre` = titre, `base_portions` absent ; le repas n'a ni courses ni nutrition tant
qu'il n'a pas de recette, et « Concevoir avec l'IA » existe dans le planning.

`FreezeLinkedUnreadable` ne suit pas cette règle : tant que la personne n'a pas répondu
« Rédiger à la place » ou « Retirer du repas », « Poser » est inactif avec la ligne de §8.1
(P2-2). Une recette liée illisible n'est pas un plat que l'IA a rédigé : on ne la pose pas
en texte à sa place sans le lui demander.

Le récapitulatif marque chaque service concerné « · sans recette » et la phrase de P2-6 le
nomme. Le retour est à une touche : « Annuler », puis « Réessayer » sur la ligne.

Les accompagnements et les services autres que le plat principal ne sont pas relus par la
boîte : écrits `MealComponent.recipe` (identifiant + titre du menu), `MealComponent.staple`
(`stapleById` du contexte) ou `MealComponent.free` (P2-5). Seule la recette du plat
principal est lue.

### 8.5 Après la pose (P2-10)

```
| 3 brouillons créés · 1 recette liée          |
| Posé le mar. 12 nov. dans Mon planning       |   bodyMedium, liveRegion
| [Voir le planning]                           |   TextButton
| [        Poser à une autre date            ] |   OutlinedButton.icon, calendarExport
```

- « Posé le mar. 12 nov. dans Mon planning » / « Posé le mar. 12 nov. dans Famille
  Dupont ». Plusieurs poses : une ligne par pose, dans l'ordre.
- « Voir le planning » : `context.push('/planning?date=2026-11-12')`, le planning s'ouvre
  sur la période qui contient ce jour. Paramètre à ajouter : `/planning` ne lit que
  `reserve` (`app_router.dart:622-626`, `PlanningScreen({showReservedNotice})`,
  `planning_screen.dart:86`). Route modifiée → §13.1 de `TechnicalRequirements.md`.
- « Poser à une autre date » : rouvre la boîte, même contenu, sur la date du jour ; chaque
  pose crée un repas de plus qui pointe les mêmes brouillons, sans appel d'IA. Le même jour,
  P2-7 prévient d'abord.
- **Le panneau est figé pour de bon** : après la pose, les lignes perdent « Réessayer »,
  « Rédiger à la place » et « Retirer du repas » ; une ligne non rédigée se lit « Non
  rédigée · posée en texte ». Sans cela, un « Réessayer » créerait un brouillon que le
  repas posé ne référence pas, et personne ne le verrait.
- Bandeau du téléphone (`_buildSummaryBanner`, `meal_workshop_screen.dart:1069-1075`) :
  suffixe « · posé » à la place de « · figé ».
- Barre du champ (`meal_workshop_screen.dart:1142-1163`) : « Repas figé. » et « Nouvelle
  conversation » inchangés ; « Nouvelle conversation » ne demande plus de confirmation après
  une pose, même après un figement partiel.
- Garde de sortie (`_canLeaveFreely`, `meal_workshop_screen.dart:227-231`) : libre après
  une pose, même après un figement partiel (P2-10).
- Dans le planning, le repas porte la ligne d'origine « Composée avec l'IA » avec l'icône
  robot (`MealOriginLine.iconFor`, `batch_planning_widgets.dart:1787`, `choice_source:
  workshop`, P2-14) et, dessous, le `why` du plat principal en justification. Sur un repas
  d'autrui, ni l'une ni l'autre (règle existante, FR §5.8).

### 8.6 Disposition par taille d'écran

Seuil : `PlatformUtils.wideBreakpoint` (800), celui de `showAdaptiveSheet`. Aucun nombre
en dur dans l'écran ; le 480 est l'argument `maxWidth`, comme `planning_target_sheet.dart:44`.

**Téléphone.** Le bouton est dans le pied fixe de la feuille Menu (`_WorkshopSheet`,
`meal_workshop_screen.dart:1475-1516`, `footer()`), sous le compte. Appui : la feuille Menu
se ferme, la boîte s'ouvre en feuille du bas (`isScrollControlled`, `useSafeArea`, sans poignée ni glisser : « Annuler », retour ou appui hors de la feuille la ferment),
hauteur de son contenu, `SingleChildScrollView`. Aucun champ de texte : le clavier ne
s'ouvre jamais, rien ne passe dessous. Après la pose, le message s'affiche sur l'écran
(aucune feuille ouverte) ; le bandeau dit « · posé » ; un appui rouvre la feuille Menu avec
le pied de §8.5.

**Tablette et ordinateur (≥ 800).** Le bouton est dans le pied fixe du panneau de droite
(320 px). Appui : `Dialog` centré, 480 px au plus, contenu défilant, par-dessus les deux
colonnes. Survol : curseur main sur les `_PickerRow` ; focus visible (Material 3) ; Échap
ferme hors écriture ; pas d'`AppShortcuts` (rien ne coûte, et la boîte est elle-même la
confirmation). Après la pose, le pied du panneau reste visible à côté de la conversation.

**Ce qui change entre les deux** : le cadre (feuille du bas / boîte 480), la fermeture de
la feuille Menu avant la boîte sur téléphone, le focus initial (Date sur grand écran).

**À 200 % de texte** : les lignes du récapitulatif passent sur deux lignes ; la valeur d'un
`_PickerRow` se coupe en ellipse (`maxLines: 1`, comme « Planifier ») sauf la date, qui
tient en 16 caractères ; l'`OverflowBar` empile « Poser » au-dessus d'« Annuler »
(`overflowDirection: VerticalDirection.up`) ; le pied du
panneau empile le compte, « Posé le … », « Voir le planning » et le bouton.

### 8.7 États

| Situation | Ce que voit l'utilisateur | Composant |
|---|---|---|
| Avant figement, plat à rédiger | « Figer le repas » ; pas de « Poser » | pied du panneau |
| Figement en cours | Compte seul, pas de bouton | pied du panneau |
| Figé, aucun service `plat` | « Poser dans le planning » inactif + « Un repas planifié a besoin d'un plat. » | pied du panneau |
| Figé, « Recette plus accessible » sans réponse | Inactif + « 1 recette plus accessible : rédigez à la place ou retirez-la du repas. » | pied du panneau |
| Figé, au moins un `plat` | Bouton actif sous « 3 brouillons créés · 1 recette liée » | pied du panneau |
| Rien à rédiger | Bouton actif + « Rien à rédiger : les recettes seront liées telles quelles. » ; un appui = relecture sans appel puis boîte, sans compte rendu du figement (ni « Repas figé : … » ni autre snack avant la boîte) | `_startFreeze(report: false)` |
| Boîte : lecture de la recette du plat | Récapitulatif affiché ; « Poser » inactif ; `bodySmall` « Lecture de la recette… » sous le récapitulatif | — |
| Boîte : lecture en échec (réseau) | Ligne `error` « La recette du plat n'a pas pu être lue. » + « Réessayer » ; « Poser » inactif | `AppErrorState(compact: true, onRetry)` |
| Boîte : brouillon introuvable | Phrase de P2-6 (« … sera posé par son titre … ») ; « Poser » actif ; `recipe_id` nul ou `MealComponent.free` | — |
| Boîte : jour libre | Rien de plus ; bouton « Poser » | — |
| Boîte : jour occupé | « Mar. 12 nov. a déjà un repas : Blanquette de veau, 19:30. » + « Choisir une autre date » ; bouton « Ajouter quand même » | carte `secondaryContainer`, `liveRegion` |
| Boîte : lecture du jour en échec | « Ce jour n'a pas pu être vérifié. » ; bouton inchangé | `bodySmall` |
| Boîte : cible groupe, parts du jour différentes | « Famille Dupont cuisine d'habitude pour 4 ce jour-là. » sous « Parts » | P2-9 |
| Boîte : cible groupe, au moins un brouillon | « Les brouillons ne s'ouvrent pour les membres qu'une fois validés. » sous le récapitulatif | P2-9 |
| Écriture en cours | Indicateur dans le bouton, lignes inactives, boîte non fermable | `PopScope(canPop: false)` |
| Succès | Boîte fermée ; `showSuccessSnackBar('Posé le mar. 12 nov. dans Mon planning.')` / `'… dans Famille Dupont.'` ; pied de §8.5 | `context_extensions.dart` |
| Écriture refusée, réseau perdu | Boîte ouverte, lignes réactivées ; `showErrorSnackBar('Repas non posé. Réessayez.')`, et le même texte dans la boîte, juste au-dessus des boutons (`bodySmall` couleur `error`, `liveRegion`), effacé au prochain appui sur « Poser » et au changement de date ou de planning — sur téléphone, le snack passe sous la feuille ; rapport `mealWorkshop.pose` avec `group_id` ; « Poser » rejoue la lecture du jour | P2-11 |
| Rôle retiré en cours de session | `showErrorSnackBar('Repas non posé. La planification est réservée aux éditeurs.')`, et le même texte dans la boîte | règles `isEditor` |
| Groupe plus possédé, en pause, supprimé | `showErrorSnackBar('Repas non posé. Ce groupe ne vous est plus accessible.')`, et le même texte dans la boîte | règles `ownsMealGroup` |
| Après la pose | « Posé le mar. 12 nov. dans Mon planning » + « Voir le planning » + « Poser à une autre date » ; lignes du panneau sans action (« Non rédigée · posée en texte ») ; bandeau « · posé » ; sortie libre | §8.5 |
| Quitter pendant l'écriture | Impossible depuis la boîte ; rail et barre du bas sous la route modale | — |

### 8.8 Libellés

| Endroit | Texte |
|---|---|
| Pied du panneau, bouton | « Poser dans le planning » ; après une pose « Poser à une autre date » |
| Raisons sous le bouton | « Un repas planifié a besoin d'un plat. » ; « 1 recette plus accessible : rédigez à la place ou retirez-la du repas. » ; « Rien à rédiger : les recettes seront liées telles quelles. » |
| Titre de la boîte | « Poser dans le planning » |
| Récapitulatif | « Menu · 4 services » / « Plat · Blanquette de veau » ; « · brouillon » ; « · Le Grand Livre » ; « · sans recette » ; « 1 plat sans recette sera posé par son titre : Comté. Vous pourrez lui choisir une recette depuis le planning (« Composer le menu »). » ; « Le plat principal n'a pas de recette : le repas sera posé par son titre, sans courses ni nutrition. Vous pourrez le concevoir depuis le planning (« Concevoir avec l'IA »). » ; « Les brouillons ne s'ouvrent pour les membres qu'une fois validés. » ; « Lecture de la recette… » ; « La recette du plat n'a pas pu être lue. » + « Réessayer » |
| Lignes | « Planning » (« Mon planning » / « Famille Dupont » · « Planning du groupe · 4 membres ») ; « Date » ; « Heure de début » ; « Parts » / « 6, parts du menu » ; « Famille Dupont cuisine d'habitude pour 4 ce jour-là. » ; « Recette pour 4 : les quantités seront recalculées pour ce repas, la recette ne change pas. » |
| Jour occupé | « Mar. 12 nov. a déjà un repas : Blanquette de veau, 19:30. » ; « Choisir une autre date » ; « Ajouter quand même » ; « Ce jour n'a pas pu être vérifié. » |
| Boutons de la boîte | « Annuler » ; « Poser » ; « Ajouter quand même » |
| Messages | « Posé le mar. 12 nov. dans Mon planning. » ; « Posé le mar. 12 nov. dans Famille Dupont. » ; « Repas non posé. Réessayez. » ; « Repas non posé. La planification est réservée aux éditeurs. » ; « Repas non posé. Ce groupe ne vous est plus accessible. » |
| Après la pose | « Posé le mar. 12 nov. dans Mon planning » ; « Posé le mar. 12 nov. dans Famille Dupont » ; « Voir le planning » ; « Poser à une autre date » ; « Non rédigée · posée en texte » ; bandeau « · posé » |
| Dans le planning | « Composée avec l'IA » (icône robot) + le `why` du plat principal |

Aucun mot technique. « Poser » est le verbe de l'atelier (US-6), du bouton du panneau au
message de succès ; « Ajouter quand même » reprend le verbe du planning pour un second repas
le même jour (P2-7).

### 8.9 Composants réutilisés

- `core/presentation/adaptive_sheet.dart` (`showAdaptiveSheet`, `maxWidth: 480`).
- `features/planning/presentation/schedule_recipe_sheet.dart` : `_PickerRow`, `_InfoRow`,
  ligne « Planning » (`PopupMenuButton<PlanningTarget>`), `_formatDate`. À extraire en
  widgets partagés plutôt qu'à copier.
- `features/planning/domain/planning_target.dart` (`PlanningTarget`, `groupMealPortions`
  pour la phrase de P2-9) ; `group_providers.dart` (`ownedPlanningGroupsProvider`).
- `features/planning/presentation/planning_providers.dart` : `addMeal`,
  `getMealsBetween(from, to, groupId)`, `planningPreferencesProvider`.
- `features/planning/domain/planning_preferences.dart` (`mealTimeFor`) ;
  `meal_composition.dart` (`toComponents`, `effectiveMealKind`) ; `meal_component.dart`
  (`MealComponent.staple/recipe/free`) ; `meal_choice_source.dart` (valeur `workshop`).
- `features/planning/presentation/batch_planning_widgets.dart` (`MealOriginLine.iconFor`).
- `core/widgets/app_states.dart` (`AppErrorState(compact: true, onRetry)`) ;
  `core/utils/context_extensions.dart` ; `core/theme/app_icons.dart` (`calendarExport`) ;
  `core/utils/platform_utils.dart` (`wideBreakpoint`, par `showAdaptiveSheet`).
- `features/search/presentation/meal_workshop/` : `_buildMenuFooter`, `_WorkshopSheet`,
  `_buildSummaryBanner`, `_canLeaveFreely`, `_startFreeze` (figement sans plat à rédiger).

**Hors périmètre, vu en lisant « Planifier »** (`schedule_recipe_sheet.dart`) : son
calendrier s'arrête à 365 jours (ligne 255) quand « Replanifier » va à 730 ; son heure par
défaut est `defaultMealHour` (lignes 127-129), pas `mealTimeFor(weekday)` ; ses `_PickerRow`
font moins de 48 px. Trois écarts à corriger un jour, pas dans ce palier.

## Points tranchés par recommandation, à confirmer

1. **Icône du bouton** : `Icons.restaurant_menu` (le menu, objet) plutôt que
   `Icons.forum_outlined` (la conversation). Le résultat est un menu ; la conversation est
   le moyen.
2. **Titre de l'écran** : « Atelier repas » plutôt que « Composer un repas avec l'IA ».
   Court, tient à 200 %. L'alternative répète le bouton mot pour mot.
3. **Téléphone** : bandeau résumé + feuille Menu plutôt que deux onglets « Conversation |
   Menu ». Avec des onglets, « remplace le dessert » demande deux appuis pour voir le
   dessert changer ; le bandeau le dit sur place et la feuille s'ouvre d'un appui.
4. **Entrée envoie** (Maj+Entrée saute une ligne), comme la barre « Modifier la recette »
   de l'écran d'une proposition, plutôt que Ctrl+Entrée. Alternative prudente : Entrée saute
   une ligne, Ctrl/Cmd+Entrée envoie, et le bouton reste.
5. **Après un figement** : fermer le champ et proposer « Nouvelle conversation » plutôt que
   laisser discuter. Un brouillon créé ne se défait pas par un tour. Continuer à discuter
   demanderait de définir ce que devient la ligne « Brouillon créé » quand l'IA change le
   plat.
6. **Parts par défaut** : `targetPortions` des préférences du planning quand elle est posée
   (`planning_preferences.dart:28`), sinon 4 ; constante 4 au palier 0. Réponse à la
   question ouverte §9.1 du cadrage.
7. **Périmètre** : les filtres sans le texte, comme « Chercher avec l'IA », plutôt que
   filtres plus texte. Le texte est la première consigne ; en faire aussi un filtre
   réduirait le corpus à ce que l'utilisateur a déjà nommé.
8. **Route** : `/search/meal-workshop?q=…` qui relit corpus et préférences à l'ouverture,
   plutôt qu'un `extra` avec les résumés. Avec `extra`, la garde « Composition réservée aux
   éditeurs » n'est jamais atteignable, et un rafraîchissement web ramène sur Explorer sans
   un mot.
9. **Panneau Menu à droite** plutôt qu'à gauche comme les filtres d'Explorer. Les filtres
   sont une entrée, posée avant la liste ; le menu est une sortie, posée après la
   conversation.
10. **Doublon de titre** : réglé dans la boîte « Figer le repas », avant tout appel, plutôt
    que ligne par ligne pendant le figement. Tout ce qui coûte est annoncé et tranché dans
    une seule boîte ; le figement se déroule ensuite sans question. Réponse à la question
    ouverte §9.4 du cadrage.
