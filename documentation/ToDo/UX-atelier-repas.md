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
   en pied du panneau, la carte « Brouillons créés » liste chaque brouillon avec « Ouvrir »
   (`/drafts/<id>`, comme `generated_recipe_screen.dart:139`). Au palier 2, « Poser dans le
   planning » s'ajoute sous cette carte.
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
| Échec partiel | « Non rédigée — Réessayer » (réseau, serveur) ; « Non rédigée. L'IA n'a pas rendu de recette. » avec « Réessayer » ; « Recette plus accessible » + « Rédiger à la place » / « Retirer du menu ». Un service « Brouillon créé » n'est jamais rejoué. | — |
| Figement terminé | `showSuccessSnackBar('3 brouillons créés dans « Mes créations Kass'Dalle ✨ ».')` ; carte « Brouillons créés » dans le pied du panneau, une ligne par brouillon (`Icons.edit_note`, titre, « Ouvrir ») ; ligne « Repas figé. » à la place du champ + « Nouvelle conversation ». | `context_extensions.dart` |
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
| Lignes de figement | « En attente » ; « Rédaction… » ; « Brouillon créé » + « Ouvrir » ; « Non rédigée — Réessayer » ; « Non rédigée. L'IA n'a pas rendu de recette. » ; « Non rédigée — plafond atteint » ; « Recette plus accessible » + « Rédiger à la place » / « Retirer du menu » |
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
  câblage de `generated_recipe_screen.dart:68-84, 462-470`) ; « Retirer du menu » ne demande
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
