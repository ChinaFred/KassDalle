# Kass'Dalle — Étude : interface et recettes en FR / EN / DE / NL

> Statut : étude, aucun code écrit. Reprise prévue plus tard. ·
> Auteur : session principale, avec les avis de `architecte`, `securite` et `ux-designer` ·
> 22 novembre 2026
> Ce document garde la réflexion et les décisions déjà prises par l'utilisateur. Il ne vaut
> ni cadrage validé ni ADR. Les chiffres sont des comptages faits sur `master` au commit
> `44c2ca0` ; les estimations de sessions sont des ordres de grandeur.

---

## 1. Demande et décisions déjà prises

Demande : « étudier la possibilité d'introduire une gestion multilangue pour les UI, pour les
textes affichés mais aussi pour les goûts, ustensiles, etc. Quel est le coût et quel est le
risque ? »

Décisions de l'utilisateur (22 novembre 2026) :

1. Langues visées : **français, anglais, allemand, néerlandais**.
2. Les membres **importeront des recettes écrites en anglais, allemand et néerlandais**. La
   reconnaissance (chantier 3) se fait donc dans les trois langues, et la recette n'est pas
   seulement traduite en français à l'import.

Question en suspens au moment de l'arrêt : le rattachement des ingrédients étrangers au
référentiel nutrition (§6). Recommandation de la session et de l'architecte : option (a).

## 2. État actuel

- `kass_dalle/lib/main.dart:111-112` impose `Locale('fr')` comme seule langue.
  `flutter_localizations` et `intl` sont dans `pubspec.yaml`, aucun fichier ARB n'existe.
  `initializeDateFormatting('fr')` est appelé dans `main.dart:28`.
- `lib/` : 416 fichiers Dart, 145 000 lignes, environ 7 700 chaînes françaises en dur, dont
  954 `Text('…')` directs.
- 37 `DateFormat`, dont 26 avec `'fr'` en dur ; une vingtaine de `toStringAsFixed` qui
  affichent un point décimal.
- Serveur : 241 `HttpsError` avec un message français destiné au membre ; une vingtaine de
  fichiers de `functions/src/gemini/` portent des prompts rédigés en français qui demandent
  une sortie en français.
- L'import par URL traduit déjà en français toute recette étrangère
  (`functions/src/pipeline/urlImport.ts`, poste `recipe_translation`). Un livre porte
  `langue`, écrit en dur à `"fr"` (`urlImport.ts:432`, `recipe_picker_sheet.dart:98`).

## 3. Les quatre chantiers

### 3.1 Textes de l'interface

Extraire les chaînes dans des ARB (`gen_l10n`), réécrire pluriels et accords en ICU, rendre
les dates et nombres dépendants de la langue, remplacer les messages serveur par un code
stable (`details.reason`) que le client traduit.

- Coût facturé : aucun. Environ 23 000 traductions (7 700 × 3), produites par une session et
  relues par une personne qui parle chaque langue.
- Effort : 10 à 20 sessions, une feature par lot. Coût durable : chaque nouvel écran fournit
  ses textes dans les quatre langues.
- Risque : moyen. Tests de widgets qui cherchent un texte français ; débordements en
  allemand (20 à 35 % plus long) ; un oubli laisse du français, sans erreur.

### 3.2 Vocabulaires à clés

Allergènes (`test-fixtures/allergens.json`, 14 clés), styles (18), rôles de repas et
`contains` (`meal_roles.json`). Les données stockent déjà une clé ; seuls les libellés sont à
traduire. Coût et risque faibles. La fixture partagée Dart ↔ TypeScript suit, car le serveur
cite ces libellés dans ses prompts. Le serveur refuse un libellé traduit rendu à la place
d'une clé (`gemini/mealRole.ts`, `nutrition/allergens.ts`).

### 3.3 Reconnaissance en EN, DE, NL (choisie par l'utilisateur)

Ce qui existe en français et se refait par langue, en Dart et en TypeScript :

| Élément | Taille actuelle | Par langue ajoutée |
|---|---|---|
| `utensils.json` | 50 noms, 40 cas | liste, articles, contenants, qualificatifs, pluriel |
| `quantity_parsing.json` | 26 cas | nombres en lettres, fractions, « demi » |
| `unit_to_grams.json` | 74 cas, 24 entrées de référentiel | unités locales ; cup, oz, lb, fl oz en anglais |
| `ingredient_names.json` | 34 cas | normalisation : ß, umlauts, pluriels irréguliers |
| `cooklang_parsing.json` | 23 durées, 5 alias de repos, 10 libellés de type de page | « Minuten », « uur », « hours »… |
| `shopping_products.json` | 19 familles d'unités | unités locales |
| référentiel `nutrition_ingredients` | identifiant = nom français normalisé, lu par 19 à 21 fichiers serveur | rattachement des noms étrangers (§6) |

- Effort : 15 à 25 sessions, plus une personne par langue pour écrire et relire les cas de
  fixture. Une règle fausse accompagnée de son test faux passe la CI.
- Coût facturé : enrichissement par IA (`nutrition/aiEnrichment.ts`) de chaque nom étranger
  non rattaché.
- Risques :
  - mots composés allemands et néerlandais (« Backpapier », « bakpapier ») : la règle
    actuelle mot par mot ne s'applique pas ;
  - pluriels irréguliers (« Ei » / « Eier », « -en » / « -s ») : `depluralizeToken` ne se
    généralise pas ; l'architecte propose une table de formes plutôt qu'une règle ;
  - unités impériales : une cup ou une oz dépendent de l'ingrédient ; sans densité, la
    quantité reste non convertie (pas de valeur de repli, section `divergences`) ;
  - normalisation : « ä » / « ae », « ß » / « ss », « Müsli » = « Muesli » ? Une décision
    différente entre Dart et TS casse l'identité d'un ingrédient sans erreur ;
  - faux amis entre langues : « chips » (frites en anglais britannique, chips en allemand),
    « room » (crème en néerlandais), « gift », « bio » ; la langue doit être connue par
    recette, jamais devinée mot à mot ;
  - erreurs muettes : un aliment rangé en ustensile ou une cup mal convertie fausse la
    nutrition et les courses sans message.

### 3.4 Textes générés par l'IA

Planning, atelier repas, courses, conservation : aujourd'hui en français, parfois stockés
dans des documents partagés. La langue est un état propre au lecteur (règle « Redimensionner
ne modifie jamais l'originale »). Voir §5 et §7.

## 4. Avis de l'architecte

Décisions à prendre avant le code, dans cet ordre :

1. Séparer la langue de l'interface (préférence du lecteur, sous `users/{uid}`) et la langue
   du contenu (propre à la recette).
2. Langue d'une recette : champ `lang` stocké, détecté à l'import puis confirmé ou corrigé
   par l'importateur. Au niveau de la recette, pas du livre : un livre web mélange les
   langues. Pas de détection à chaque lecture (appel ou heuristique en double).
3. Référentiel nutrition : option (a) (§6).
4. Sort de `recipe_translation` : le garder, en option à l'import. Deux modes : garder la
   langue d'origine (`lang: "de"`) ou traduire vers la langue de l'importateur, plus vers le
   français. Pas de traduction à la lecture pour chaque lecteur (poste récurrent et état du
   lecteur).
5. Textes IA : un texte stocké dans un document partagé est généré dans la langue de la
   recette, ou stocké par langue sous une clé ; un texte propre au lecteur (planning,
   courses) vit sous `users/{uid}` et suit sa langue. Chaque prompt reçoit la langue en
   paramètre explicite.
6. Seulement ensuite : outillage ARB et découpage de l'interface.

ADR : un ADR principal en sections, ou quatre ADR — langue de l'interface et du contenu
(champ `lang`) ; référentiel nutrition multilingue ; reconnaissance multilingue des fixtures
dupliquées ; politique de traduction à l'import et langue des textes IA. Kass'Dalle n'a pas
encore de `documentation/decisions/` : ce serait son premier ADR.

Lots proposés :

| Lot | Contenu |
|---|---|
| L0 | champ `lang` sur la recette, backfill `fr` des recettes existantes (Admin › Backfills) ; préférence de langue du lecteur ; codes d'erreur serveur stables |
| L1 | ARB et `gen_l10n`, interface française extraite sans changement visible ; le plus long, par feature |
| L2 | libellés EN/DE/NL de l'interface et des vocabulaires à clés (clés inchangées) |
| L3 | reconnaissance anglaise dans les fixtures, alias anglais du référentiel, cas de fixture d'abord |
| L4 | idem en allemand |
| L5 | idem en néerlandais |
| L6 | import sans traduction en option ; prompts IA paramétrés par la langue |

Commencer par l'anglais seul valide le modèle de données à moindre coût. Poser `lang` avant
L1 évite une seconde migration. Le bac à sable, les tickets et les prompts des Routines
restent en français : choix à écrire dans l'ADR.

## 5. Avis de la sécurité

- **Préférence de langue** : champ `locale` ajouté à la liste blanche des champs modifiables
  de `users/{uid}` (`firestore.rules`, l. 301-304), valeur dans `['fr','en','de','nl']`,
  jamais une chaîne libre. Tests `rules-tests/` : `locale: "xx"` refusé, `locale` d'un autre
  compte refusé, compte `pending` refusé.
- **Langue et callables** : le serveur relit `users/{uid}.locale` et n'accepte aucun argument
  de langue ; sinon liste fermée, `invalid-argument`. Le prompt reçoit une consigne fixe
  choisie par le serveur ; la valeur reçue n'y est jamais recopiée.
- **Codes d'erreur** : les 241 `HttpsError` passent à `details.reason` stable ; aucun message
  ne porte un texte de recette, un e-mail ou une réponse brute du fournisseur.
- **Alias du référentiel** : écrits par le serveur seul, rangés par langue, refusés s'ils
  sont déjà portés par un autre ingrédient, relus par l'admin. Un mauvais alias fausse la
  nutrition et les allergènes de toute la famille.
- **Coût multiplié par langue** : une traduction demandée par un lecteur sur un document
  partagé permet à n'importe quel compte de faire traduire tout le livre. Copie traduite par
  couple (document, langue), écrite par le serveur seul ; plafond de traductions par jour et
  par compte, en plus de `functions/src/ai/budget.ts` et `importBudget.ts` ; chaque poste
  nouveau aux trois endroits (`ctx.feature`, `ROUTABLE_FEATURES`, `feature_catalog.dart`).
- **Prompts multilingues** : un texte importé reste une donnée ; les tests de prompt couvrent
  une consigne cachée dans chaque langue.
- **Données partagées** : une traduction ne s'écrit jamais dans la recette d'origine. Une
  copie dérivée reprend la règle de lecture de l'originale, pour qu'une recette `is_private`
  ne fuie pas par elle.
- **Détection d'e-mail des tickets** : `EMAIL_PATTERN` (`functions/src/tickets/rules.ts`,
  l. 827-828) n'accepte que l'ASCII après `@`. Une adresse à domaine accentué
  (`max@exemplé.fr`) n'est pas détectée et partirait sur le dépôt public. Ce défaut existe
  déjà, indépendamment du multilingue : à corriger à part, avec des cas IDN, punycode et
  alphabet non latin dans `test-fixtures/ticket_answer_text.json`.

## 6. Référentiel nutrition : options

| Option | Effet | Coût | Risque |
|---|---|---|---|
| (a) un référentiel, alias par langue | fiches et identifiants actuels gardés | faible ; champ `aliases` déjà existant, déjà envoyé au modèle (`per100gEnrichment.ts:173`) | alias mal posé qui rattache à une mauvaise fiche |
| (b) un référentiel par langue | fiches indépendantes (`de:butter`) | quatre enrichissements facturés par ingrédient | valeurs nutritionnelles différentes selon la langue |
| (c) identifiants neutres | clé sans langue, nom par langue | migration des fiches, des 19 à 21 fichiers serveur et des références dans les recettes | migration, sans gain visible |

Recommandation (session et architecte) : **(a)**, à une condition : passer d'une liste plate
`aliases` à des alias par langue (`aliases_by_lang: {en: [...], de: [...]}`), résolus dans la
langue de la recette puis en repli sur le français. L'identifiant français devient une clé
technique que l'interface n'affiche plus telle quelle.

## 7. Avis de l'UX

- **Choix de la langue** : par défaut celle de l'appareil si elle est parmi les quatre, sinon
  le français. Menu du compte › « Langue », quatre options plus « Comme l'appareil », noms
  écrits dans leur langue (« Deutsch », « Nederlands »). Enregistré sous `users/{uid}`.
  L'écran de connexion suit l'appareil.
- **Recette dans une autre langue** : puce « EN » avec infobulle. La traduction part sur un
  bouton « Traduire », jamais à l'ouverture ; elle n'est jamais écrite dans la recette ; lien
  « Voir l'original ». Un cache de traduction ne se présente pas comme une modification.
  (À concilier avec l'architecte, qui préfère ne pas traduire à la lecture : §8.)
- **Mise en page** : `NavigationRail` de `core/presentation/app_shell.dart:162` en
  `labelType: all` (« Bibliothèque », « Brouillons ») ; environ 224 largeurs fixes dans
  `features/` ; `TabBar` défilants dans `recipe_detail_screen.dart`,
  `recipe_edit_screen.dart`, `recipe_create_screen.dart`, `admin_screen.dart`,
  `monthly_costs_screen.dart` ; libellés d'accessibilité construits à la main
  (`'$pending image(s) en attente'`, `app_shell.dart:587-696`) à passer en `plural` ICU.
- **Formats** : `DateFormat` et `NumberFormat` lisent la langue active ; unités métriques
  gardées ; unités de cuisine (« cuillère à soupe », `core/utils/ingredient_display.dart`)
  traduites par clé ; semaine commençant le lundi dans les quatre langues.
- **Revue** : chaque écran en allemand, texte à 200 %, téléphone de 360 px ; aucune chaîne
  française restante ; pluriels ICU ; vocabulaires affichés depuis leur clé ; `SnackBar` et
  erreurs traduits ; export PDF (`core/services/recipe_pdf_export.dart`) dans la langue du
  lecteur.
- **Écrans les plus exposés** : `planning_screen.dart`, `batch_planning_screen.dart`,
  `batch_planning_widgets.dart`, `meal_composer.dart`, `search_screen.dart`,
  `meal_workshop_screen.dart`, `recipe_detail_screen.dart`, `work_queue_widgets.dart`. Les
  écrans d'administration (`admin_tickets_screen.dart`, `ai_routing_screen.dart`) peuvent
  rester en français au début.

## 8. Questions ouvertes, à poser une par une à la reprise

1. Rattachement au référentiel nutrition : (a), (b) ou (c) ? Recommandation : (a) avec alias
   par langue.
2. À l'import, garder la langue d'origine par défaut, ou traduire par défaut vers la langue
   de l'importateur ?
3. Traduction à la lecture : l'UX propose un bouton « Traduire » sur la fiche, l'architecte
   préfère ne traduire qu'à l'import. Si le bouton est retenu : copie par couple (recette,
   langue) écrite par le serveur, plafond par compte (§5).
4. La recherche porte-t-elle sur toutes les langues, ou sur celle du lecteur ?
5. Un même plat dans deux langues : est-ce un doublon pour l'anti-doublon ?
6. Normalisation allemande : « ä » = « ae », « ß » = « ss », « Müsli » = « Muesli » ?
7. Périmètre resté en français : écrans d'administration, bac à sable, tickets, prompts des
   Routines ?
8. Qui relit les traductions et écrit les cas de fixture en allemand et en néerlandais ?

## 9. Reprise

1. Trancher les questions du §8, une par une.
2. Passer par le cadrage (`business-analyst-culinaire`) et `ux-designer` pour le choix de
   langue et l'affichage d'une recette étrangère.
3. Écrire l'ADR (ou les ADR) du §4 et créer `documentation/decisions/`.
4. Livrer par lots L0 à L6, l'anglais d'abord.
