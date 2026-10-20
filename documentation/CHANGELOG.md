# Historique des versions — Kass'Dalle

Ce fichier reçoit les sections « Mise à jour release » qui vivaient dans
`FunctionalRequirements.md` et `TechnicalRequirements.md`. Ces deux documents décrivent
désormais **l'état actuel de l'application** et rien d'autre ; ce qui a changé d'une version
à l'autre se lit ici.

Les entrées sont classées de la plus récente à la plus ancienne. Chacune porte l'origine du
texte : `fonctionnel` pour ce que voit l'utilisateur, `technique` pour ce qui touche à
l'architecture, au schéma de données ou au déploiement.

**Rien n'a été réécrit.** Les sections ont été déplacées telles quelles, y compris les entrées
anciennes sans accents.

Depuis la v0.23.3, chaque version incrémentée reçoit son entrée dans le commit qui change
`version:` (voir `CLAUDE.md`, « Documentation à tenir à jour »). Les entrées de la v0.22.104 à
la v0.23.2 ont été écrites après coup, depuis l'historique git.

---

## 2026-10-20

### v0.24.31 — technique

Règles Firestore de `app_config`, lot 9 de l'audit #151 (ticket #162, point 4). Un
administrateur pouvait écrire directement tout document de `app_config` hors des quatre de
`isServerOnlyConfig`. Les écrans passent pourtant par une callable : une écriture directe
contournait sa validation (`readPolicyOrThrow`, garde-fou `enforce` d'App Check), sa trace
d'audit et App Check. `isServerOnlyConfig` couvre désormais `ai_pricing`,
`ai_routing_policy`, `ai_budget_policy`, `app_check_policy`, `nutrition_source_policy`,
`image_moderation`, `currency_rate`, `anthropic_costs`, et les points de reprise des
backfills (`*_checkpoint`, `backfill_cursor_*`). Aucun code client n'écrit ces documents ; il
les lit toujours. `tickets` et `usage` restent écrits par l'administrateur. Les tests des
règles vérifient le refus de `set`, `update` et `delete` sur chacun, la lecture
administrateur, et l'écriture de `app_config/tickets` ; le test qui visait
`app_config/nutrition_policy`, identifiant inexistant, vise `nutrition_source_policy`.

Pipeline d'import, lot 9 de l'audit #151 (ticket #163). Le pipeline relit le compte du
propriétaire d'un job à chaque tentative (`assertJobOwnerEditor`), avec la même décision que
`requireEditor`. Un compte révoqué, lecteur, en attente ou supprimé voit son job passer en
`error_code: owner_not_editor`, puis en dead letter, sans appel de modèle ; la file l'affiche sans
proposer « Relancer ». Les nouveaux essais de Cloud Tasks, les tranches d'un livre et les
relances de dead letter n'avaient aucun contrôle de rôle. `relaunchDeadLetterFn` valide son
identifiant et fait tenir la relance dans une transaction : une seule relance par dead letter,
la seconde reçoit « Ce job a déjà été relancé. ». Un `scanId` venu du client doit avoir la forme
`scan_<ms>_<suffixe>` (`isValidScanId`) ; il est écarté par `scanAndPromoteUploadFn` et remplacé
par `jobDispatcher` s'il est mal formé ou si son compteur `scan_spend` appartient à un autre
compte.

### v0.24.30 — technique

Règles Firestore des comptes et des groupes, lot 9 de l'audit #151 (ticket #162). Le rôle se
lit désormais sur le document `users/{uid}`, et le claim du jeton seulement si le document n'a
pas de champ `role` : un administrateur rétrogradé gardait le claim `admin` jusqu'au
renouvellement de son jeton (une heure au plus) et pouvait se renommer administrateur. Un
compte nommé accède aussi sans attendre son jeton. Storage reste lié au jeton, écart décrit au
§4 de `TechnicalRequirements.md`.

Le champ `uid` d'un document `users` est absent ou égal à l'uid du document, et ne change plus
après la création. L'écran Admin › Comptes lit l'uid sur l'identifiant du document
(`watchAllUsers`, et `watchAppUser` pour le compte connecté) : un compte en attente qui
portait l'uid d'un éditeur faisait révoquer l'éditeur par un clic sur sa propre ligne. Les
champs écrits sont listés (`hasOnly`) : création d'un compte (`AppUser.toFirestore`), mise à
jour par le titulaire, mise à jour par un administrateur (`role`, `is_revoked`,
`preferred_name`), création d'un groupe (`createGroup`). `photo_url` est bornée à 2048
caractères. Les types que lit `AppUser.fromFirestore` sont contrôlés : `created_at`,
`last_seen_at` (horodatages) et `display_name` (chaîne) sont obligatoires à la création, et
`last_seen_at`, `display_name`, `role` et `is_revoked` gardent leur type à la mise à jour. Un
compte en attente qui créait son document sans `created_at`, ou un titulaire qui posait
`last_seen_at: "x"`, faisait échouer Admin › Comptes pour tous les administrateurs.
`watchAllUsers` saute aussi un document illisible, le signale une fois
(`admin.watchAllUsers`) et affiche les autres comptes. 30 tests de règles ajoutés (personas
`demotedAdmin` et `promotedReader`), deux tests Dart sur `watchAllUsers`.

Imputation de l'huile absorbée, lot 9 de l'audit #151 (ticket #163). L'estimation de l'huile
absorbée à la friture (`estimate_fry_absorption`) est imputée au propriétaire de la recette
(`recipeBudgetUserId(created_by)`). Avant, elle tombait sur le compte `system`, dont le plafond
d'un seul membre (2 € et 400 appels par jour) servait à toute la famille. Un appel en échec ne
mémorise plus sa signature : `fry_signature` reste vide, et le verdict est redemandé au
prochain calcul, déclenché par une entrée modifiée ou par un recalcul manuel. Le rattrapage
nocturne ne le redemande pas : `catchUpDecision` ignore une recette dont `nutritionIsIncomplete`
est faux. Avant, la recette restait sans huile absorbée jusqu'à ce que son texte change.
L'écriture de ce champ ne relance pas `onRecipeWritten`, dont la garde ne lit que les entrées de
la recette.

### v0.24.29 — fonctionnel

Ranger des brouillons dans un livre en lot (ticket #197).

Dans « Brouillons & Traitements », la sélection propose une action « Ranger (N) » dès qu'un
brouillon est coché. Une feuille « Ranger dans un livre » demande le livre, annonce combien de
brouillons changent de livre, le numéro de page conservé et la confidentialité reprise du livre.
Les brouillons restent des brouillons. Un échec n'arrête pas les suivants. Avant, le livre ne se
changeait qu'un brouillon à la fois, dans l'écran de relecture. Aucune règle Firestore ne change.

### v0.24.28 — fonctionnel

Messages d'erreur de l'administration et de la modération, quatrième et dernier sous-lot du
lot 8 de l'audit #151 (tickets #170 et #171).

Un échec s'affiche en deux phrases, comme dans les recettes, le planning et les livres : ce
qui n'a pas eu lieu, puis la cause lisible. Exemples : « Politique de routage non enregistrée.
Connexion perdue. », « Tarif de « gemini-2.5-flash » non enregistré. Accès refusé. », « Plafonds non
enregistrés. », « Politique App Check non modifiée. », « Job non relancé. », « Entrée non
supprimée. », « Agrégats non reconstruits. », « Unité non créée. », « Garniture non mise à
jour. », « Produit acheté non enregistré. », « Allergènes non enregistrés. », « Rôle non
modifié. », « Accès non révoqué. », « Image non publiée. », « Image non refusée. »,
« Images non relancées. ». « Relancer les images sans verdict » s'affiche en succès quand
toutes les images ont reçu un verdict. Les invitations par e-mail passent de « Invitation non envoyée :
Connexion perdue » ou « Action impossible : … » à la même forme : « Invitation non envoyée. »,
« Invitation non renvoyée. », « Invitation non annulée. », « Lien non copié. ». Le texte technique de l'exception (« Erreur : [firebase_functions/
internal]… », « Enregistrement impossible : … ») n'apparaît plus ; il reste dans les rapports
d'erreurs.

Un message écrit par le serveur pour l'administrateur reste affiché, en seconde phrase, pour
les seuls codes dont le texte a été relu : « Image non publiée. Cette image n'attend pas de
décision. », « Politique App Check non modifiée. Cet appel n'est pas lui-même attesté… »,
« Job non relancé. Job original supprimé, relance impossible. », « « Rapide » non
enregistrée. Une configuration porte déjà le nom « Rapide ». ». Une erreur interne ou réseau
n'est jamais recopiée.

Les succès et les échecs qui s'affichaient sur fond neutre prennent leur couleur : « Image
publiée. », « Image refusée. », « Unité créée. », « Garniture supprimée. », « 12 mois
reconstruits ✓ » et le compte rendu de l'initialisation des unités en succès ; l'échec de la
reconstruction des agrégats, de « Relire ce mois chez Anthropic » et de la déduction d'un
identifiant de garniture (« Identifiant non déduit de ce nom. Saisissez-le à la main. ») en
erreur.

Le routage de l'IA, l'attestation de l'application et la politique nutrition affichent « Routage
non chargé », « Politique App Check non chargée » ou « Politique nutrition non chargée » avec
« Réessayer » et, pour l'administrateur, « Détails », au lieu du texte de l'exception. Leur
chargement, et celui du journal de modération, montre un libellé (« Chargement du
routage… »). L'encart « Tarifs en panne » dit la cause lisible (« Connexion perdue. »,
« Grille absente. ») ; l'encart de la dépense par utilisateur s'intitule « Dépenses non
chargées ». L'aperçu d'une image du journal de modération dit « Image non chargée. Accès
refusé. ». Une lecture refusée du rapport de coûts Anthropic n'affiche plus le corps de la
réponse : « Anthropic refuse la clé d'administration (HTTP 401). Vérifiez le secret
ANTHROPIC_ADMIN_KEY… », ou « Rapport de coûts Anthropic non lu (HTTP 500). Le détail est
dans Admin › Journaux… ».

Le journal de modération affiche « Journal de modération non chargé » quand sa lecture
échoue. La politique nutrition, la qualité des données et les indicateurs des référentiels
n'offrent plus « Réessayer » sur un refus de droits. Une liste d'unités vide renvoie à
« Nouvelle unité ».

Les listes vides des rapports d'erreurs, des unités, de la Dead Letter Queue, des comptes, des
garnitures, des ingrédients nutrition, de Cloud Logging et du journal de modération affichent
une icône, un titre et la suite à donner (« Aucun job en échec », « Aucune unité ne
correspond. Modifiez ou effacez la recherche. »…).

### v0.24.28 — technique

`test/error_text_guard_test.dart` lit les `.dart` de `lib/features/**/presentation` et de
`lib/core/presentation`. Il échoue si l'argument d'un `show…SnackBar(` ou d'un `…Text(`
interpole `$e`, `${e}`, `$error`, `${error}` ou `$_error`, ou appelle `e.toString()`. Sa liste
d'exceptions (fichier, motif, raison) est vide : après ce sous-lot, aucun appel ne relève de
la garde. Une exception qui ne sert plus fait échouer le test.

`adminFailureMessage` (`features/admin/presentation/admin_server_message.dart`) écrit l'échec
d'une action d'administration : le message de la callable pour une liste blanche de codes
passée par l'appelant, jamais `internal`, `unknown`, `unavailable` ni `deadline-exceeded`,
sinon `failureMessage`. Une `CallableFailure` y est lue par son code, et `readableError` la ramène au code de la
callable avant `AppErrorState`. `AiPricingUnavailable`
porte l'exception d'origine (`source`) pour que l'encart en tire un titre lisible. Les widgets
d'erreur privés de `app_check_screen.dart`, `nutrition_policy_screen.dart` et
`ai_routing_screen.dart` sont retirés au profit d'`AppErrorState`.

### v0.24.27 — technique

Le scan d'une couverture de livre passe dans sa propre file Cloud Tasks (ticket #193).
Cloud Tasks n'a pas de priorité : une couverture attendait derrière toutes les tranches d'un
import de livre. `jobDispatcher` choisit la fonction de file selon le type du job
(`taskQueueFunctionFor`) : `coverProcessor` pour `bookCoverScan`, `recipeProcessor` pour le
reste. Le traitement est partagé (`processJob`) : mêmes secrets, délai de 540 s et reprises.
`coverProcessor` garde 2 Gio de mémoire, traite 3 jobs en parallèle et 1 par seconde. Une tâche de couverture déjà dans
l'ancienne file au déploiement reste traitée par `recipeProcessor`. Aucun écran ne change.

### v0.24.26 — fonctionnel

Messages d'erreur des livres, des groupes, de l'Explorer, du compte et de l'atelier de
retouche, troisième sous-lot du lot 8 de l'audit #151 (tickets #170 et #171).

Un échec s'affiche en deux phrases, comme dans les recettes (v0.24.23) et le planning
(v0.24.24) : ce qui n'a pas eu lieu, puis la cause lisible. Exemples : « Livre non ajouté.
Connexion perdue. », « Groupe non créé. Accès refusé. », « Recette non améliorée. Limite du
jour atteinte. », « Nom préféré non enregistré. Connexion perdue. ». Le texte technique de
l'exception (« Erreur : [cloud_firestore/unavailable]… », « Création impossible :
Exception… ») n'apparaît plus ; il reste dans les rapports d'erreurs. Sont concernés le
formulaire, la liste et la validation des livres, les groupes (quitter, supprimer, créer,
renommer), la recette générée de l'Explorer et ses illustrations, les préférences, le nom
préféré, la déconnexion, l'export de mes livres et l'atelier de retouche (« Photo non
ouverte. Choisissez-en une autre. », « Correction non appliquée. », « Photo non envoyée. »,
« Photo non pivotée. »). Dans les groupes, l'acceptation et le refus d'une invitation, et
dans la gestion des membres, la recherche par nom, l'envoi et l'annulation d'une invitation
et le retrait d'un membre prennent la même forme (« Invitation non acceptée. », « Invitation
de Zoé non annulée. »…). « Image générée par l'IA ✓ », dans l'Explorer, prend la couleur
d'un succès ; « Lien non copié. » remplace « Impossible de copier le lien. » ; la validation
d'un livre dit « « Titre » validé », sans point d'exclamation ; une illustration sans
consigne demande « Décrivez ce que l'image doit montrer. ».

Une photo retenue par la modération n'affiche plus le motif écrit pour l'administrateur
(un tiret quand il est vide, ou une clé technique). Le membre lit « Photo non enregistrée. »
ou « Couverture non enregistrée. », puis « Elle a été refusée par la modération. » ou « Elle
attend la vérification d'un administrateur. Elle ne sera pas ajoutée d'elle-même. ». Ce message reste en erreur : une couverture
de livre ou une illustration de l'Explorer approuvée plus tard n'est pas rattachée d'elle-même
(seul l'import par lien pose `attach_on_approval`). Un format refusé dit « Format non pris en
charge : choisissez une photo JPEG ou PNG. », sans le nom du fichier. À la création d'un
livre, une couverture qui ne part pas n'est plus masquée par le succès : « Livre ajouté.
Couverture non enregistrée. Connexion perdue. », en erreur.

Une adresse qui ne mène à aucune page affiche « Page introuvable », une phrase
d'explication et « Retour à la bibliothèque », au lieu du message anglais du routeur.
L'écran « Profil et compte » affiche « Profil non chargé » et « Réessayer » quand la lecture
du profil échoue ; il restait jusqu'ici sur son indicateur de chargement. Un refus d'accès y
conseille de se déconnecter puis de se reconnecter.

Le dialogue « Nom préféré » libérait son champ de saisie pendant son animation de fermeture,
ce qui levait une erreur en mode debug. Le champ appartient maintenant au dialogue, qui le
libère à sa fermeture.

Le message d'erreur de la connexion, cité dans l'audit, avait déjà quitté le texte technique
en v0.24.20.

### v0.24.25 — fonctionnel

Le calcul de nutrition pèse maintenant « 1 noix de muscade », « 1 noix de beurre » et
« 3 blancs d'œufs » (ou « jaunes »). Ces lignes restaient sans poids : la couverture restait
partielle et le calcul semblait ne pas partir. Une noix de muscade compte 3 g, une noix de
beurre 10 g, un blanc d'œuf 30 g et un jaune 18 g. Une épice écrite avec un nombre mais sans
unité (« 1 muscade ») se lit en pincées. Une recette déjà calculée se corrige au prochain
recalcul de sa nutrition.

### v0.24.25 — technique

Ticket #190. `getKnownUnitMetadata` consulte une table de couples unité/ingrédient
(`UNIT_INGREDIENT_PROFILES`, `_unitIngredientProfiles` en Dart) : `noix` + muscade 3 g, `noix` +
beurre 10 g, `blanc` + œuf 30 g, `jaune` + œuf 18 g, pluriels compris. Ces trois unités
rejoignent `INGREDIENT_DEPENDENT_UNITS`. `resolveWeighingInput` lit en pincées la quantité d'un
assaisonnement sans unité ni poids à la pièce. Fixture `unit_to_grams.json` : neuf cas ajoutés,
rejoués par les deux suites. Aucun backfill. La reprise automatique de la nutrition ne reprend
pas les recettes dont `missing_weight` porte `unite_sans_poids` ou `comptage_sans_poids`
(`UNFIXABLE_BY_CATCH_UP`) : une recette déjà bloquée se recalcule depuis son écran ou à sa
prochaine modification.

### v0.24.24 — fonctionnel

Messages d'erreur du planning, deuxième sous-lot du lot 8 de l'audit #151 (tickets #170 et
#171, à suivre).

Un échec dans le planning s'affiche en deux phrases, comme dans les recettes depuis la
v0.24.23 : ce qui n'a pas eu lieu, puis la cause lisible. Exemples : « Repas non planifiés.
Connexion perdue. », « Préférences non enregistrées. Accès refusé. », « Idées non proposées.
Connexion perdue. ». Le texte technique de l'exception (« Erreur Calendar : Exception… »,
« L'IA n'a pas répondu : GeminiCallableException… ») n'apparaît plus ; il reste dans les
rapports d'erreurs. Sont concernés le nouveau planning, l'écran du planning, ses préférences,
« Générer avec l'IA » et « Mes garnitures ». Dans « Générer avec l'IA », seul le message de
plafond écrit par le serveur (`resource-exhausted`) reste affiché tel quel ; un autre code
n'affiche plus son texte, souvent en anglais sur mobile (« UNAVAILABLE »).

Les échecs de l'export vers Google Calendar, affichés jusqu'ici dans un message neutre,
prennent la couleur d'erreur. Un refus d'autorisation Google (fenêtre fermée, jeton absent)
s'affiche « Accès au calendrier non accordé. » suivi de la cause. Un export partiel compte ce
qui manque, accordé au nombre : « 2 repas sur 5 non exportés vers le calendrier. », « 1 repas
sur 2 non exporté vers le calendrier. », et « Repas non exportés vers le calendrier. » quand
aucun n'est parti. Le nouveau planning dit de même « 12 repas planifiés. 2 repas sur 5 non
ajoutés au calendrier. ». Aucun de ces messages ne propose « Réessayer » : un second envoi
doublerait dans l'agenda les événements déjà posés. Les succès s'accordent aussi (« 1 repas
exporté vers le calendrier ✓ », « 1 repas planifié »), et « Repas ajouté au calendrier ✓ »
prend la couleur d'un succès.

Les chargements en page entière des préférences du planning et du nouveau planning disent ce
qu'ils attendent (« Chargement de vos préférences… », « Chargement de vos groupes… »,
« Préparation des créneaux… ») ; ceux des préférences gardent la barre de titre de l'écran.

À l'import (correction de la v0.24.23), un échec du serveur n'affiche plus son texte que pour
trois codes dont les messages sont écrits en français pour l'utilisateur dans
`scanAndPromoteUploadFn` et `analyzeBookFileFn` : `resource-exhausted` (plafond, budget),
`failed-precondition` (fichier bloqué par le scan de sécurité, livre illisible) et
`permission-denied` (rôle, chemin refusé). Les autres codes affichent les deux phrases
habituelles : `invalid-argument` (« storagePath est requis. », un texte de développeur),
`unavailable` et `deadline-exceeded` (texte anglais du SDK sur mobile), `internal` et `unknown`.

### v0.24.23 — fonctionnel

Messages d'erreur des recettes, premier sous-lot du lot 8 de l'audit #151 (tickets #170 et
#171, à suivre).

Un échec dans les recettes, les brouillons et l'import s'affiche en deux phrases : ce qui n'a
pas eu lieu, puis la cause lisible. Exemples : « Photo non enregistrée. Connexion perdue. »,
« Recette non supprimée. Accès refusé. ». Le texte technique de l'exception (« Erreur
Storage : [firebase_storage/…] », « Erreur IA : GeminiCallableException… ») n'apparaît plus ;
il reste dans les rapports d'erreurs. 55 messages sont concernés : fiche, édition, création,
relecture d'un brouillon, illustrations, liste d'un livre, et les messages d'erreur de l'écran
d'import. Les échecs affichés jusqu'ici dans un message neutre prennent la couleur d'erreur,
et « Image générée par l'IA ✓ » celle d'un succès.

Sur une page d'erreur, le bouton « Détails », qui montre le texte technique, n'est plus
visible que d'un administrateur. Pour les autres membres, une erreur inattendue conseille :
« Si le problème persiste, signalez-le depuis le menu du compte. ».

Les chargements en page entière de l'édition d'une recette, de la relecture d'un brouillon et
de la file « Brouillons & Traitements » disent ce qu'ils attendent (« Chargement de la
recette… », « Chargement du brouillon… », « Suppression du brouillon… », « Chargement des
brouillons et imports… »). La colonne « Quantite » du détail nutritionnel s'écrit
« Quantité ». Un plafond atteint s'intitule « Limite du jour atteinte » au lieu de « Quota
atteint ». À l'import, une erreur technique du serveur ne s'affiche plus telle quelle : le
message dit ce qui n'a pas eu lieu (« Livre non vérifié. », « Page 3 non vérifiée. »).

### v0.24.23 — technique

Nouveau `failureMessage(what, error)` (`core/widgets/error_message.dart`) : « what. Titre de
`describeError`. », sans double point. `context.showFailureSnackBar(what, error)`
(`core/utils/context_extensions.dart`) l'affiche par `showErrorSnackBar`. `scan_upload_service.dart`
l'emploie pour `ScanState.errorMessage` ; `_scanErrorMessage` garde le message du serveur
d'une `GeminiCallableException` (scan de sécurité en `failed-precondition`, message non vide),
et l'analyse d'un livre garde le sien ; `_serverWrittenMessage` écarte les codes `internal` et
`unknown`, dont le message recopie le texte brut de l'exception côté serveur. `AppErrorState` devient un `ConsumerStatefulWidget` qui
lit `isAdminProvider` ; le conseil d'une erreur inattendue vit dans `kUnexpectedErrorAdvice`,
celui des membres dans `kReportProblemAdvice`. Chaque `catch` touché rapportait déjà par
`reportUnexpectedError` ou `ErrorReportService` ; le `debugPrint` doublon de
`draftReviewScreen.confirmDelete` est retiré, et les deux rapports de `recipe_list_widgets.dart`
passent de `recipeListWidgets.build` à `detachFromBook` et `deleteRecipe`. Tests : nouveau
`error_message_test.dart` (les cas de `describeError` y quittent `app_states_test.dart`, plus
`failureMessage`), « Détails » selon le rôle dans `app_states_test.dart`, message d'échec sans
texte technique dans `context_extensions_snackbar_test.dart`.

### v0.24.22 — fonctionnel

Thème sombre et cibles tactiles, suite de l'audit #151 (tickets #172 à #175).

Les éditeurs de recette suivent le thème sombre : fond foncé, texte clair, couleurs de syntaxe
(ingrédients, ustensiles, minuteurs…) éclaircies pour rester lisibles. Les boutons « Valider »
et « Insérer » des feuilles d'édition et d'insertion prennent la couleur du thème ; l'icône et le titre gardent celle du
jeton. Les pastilles de note passent aux couleurs du thème (8 à 10, 5 à 7, 0 à 4) et restent
lisibles en sombre. Les couleurs fixes vertes, orange, rouges et grises de l'administration
(référentiels, journaux, révocation), du bandeau de fidélité et du texte « Aucune annotation »
suivent aussi le thème.

Sur la fiche, la pastille de note et les pastilles d'annotations deviennent des cibles de
48 × 48 px, avec une infobulle lue par le lecteur d'écran (« Ma note : 8 sur 10. Modifier »,
« 2 remarques, 1 astuce. Voir les annotations »). Les annotations forment une seule cible.
Sur grand écran, ces pastilles se placent à droite du bloc titre et livre. Dans la liste d'un
livre et dans Explorer, les pastilles ne sont plus cliquables : un appui sur la ligne ouvre la
fiche, où la note se modifie, et le lecteur d'écran les lit avec la ligne. Dans l'éditeur, la
poignée et le bouton « Supprimer la ligne » passent à 48 px, et l'éditeur Markdown perd ses
deux poignées qui ne déplaçaient rien. Le bouton d'aide de l'éditeur, le bouton « Retirer »
d'une illustration et l'identifiant copiable des rapports d'erreurs passent aussi à 48 px.

### v0.24.22 — technique

`TappablePill` (`core/widgets/tappable_pill.dart`) remplace `AnnotBadge`, `DetailAnnotBadge`
et le `GestureDetector` de `RecipeRatingBadge`. `ratingColors` et `ratingBadgeLabel`
(`recipe_rating_colors.dart`) sont des fonctions pures, testées : contraste d'au moins 4,5:1
pour les notes 3, 6 et 9 dans les deux thèmes. `CooklangPalette.of(Brightness)`
(`cooklang_editor_colors.dart`) devient la seule source des couleurs de syntaxe : tons HCT 40
et 80 des couleurs d'origine, figés dans le code, sans dépendance directe à
`material_color_utilities`. Les copies de `cooklang_syntax_controller.dart` et
`cooklang_help_page.dart`, les constantes `kCooklang…Color`, la copie de `annotNoteColor` dans
`recipe_list_widgets.dart` et le paramètre `scrollToAnnotations` de
`buildReaderRecipeLocation` sont supprimés. Correction : `CooklangSyntaxController` levait
une `RangeError` quand un jeton `@`, `#` ou `~` ouvrait le texte. Nouveau test de garde
`feature_hardcoded_colors_test.dart` : `Colors.green`, `orange`, `red` et `grey` sont refusés
dans `lib/features/`, hors bac à sable.

### v0.24.21 — fonctionnel

« Compléter » et « Choisir » dans le planning ouvrent leur feuille dès l'appui. Elle affiche
« Lecture des recettes et des garnitures… » tant que la lecture n'est pas finie, et n'annonce
plus à tort « Aucune garniture ». Un échec de lecture s'affiche dans la feuille avec
« Réessayer », qui montre de nouveau le chargement pendant la relecture. Le champ de
recherche de la feuille porte le libellé « Rechercher ». La feuille d'accompagnement vide et
*Mes garnitures* vide renvoient au bouton « Ma garniture » au lieu de parler de backfills ;
un administrateur lit en plus où se tient la liste commune. Dans le retoucheur d'image, une
correction qui échoue n'envoie plus la photo d'origine : l'écran reste ouvert avec ses
réglages et propose « Réessayer ». Un envoi qui échoue se relance sans refaire la correction,
sauf accès refusé ou session expirée, et le message se ferme dès qu'un réglage change. Les
messages d'erreur ne montrent plus de texte technique. La fenêtre « Explication de l'IA » se
ferme par « Fermer ». (#176, #177, #179, #180)

### v0.24.20 — fonctionnel

Lot 4 de l'audit d'ergonomie (#151) : six tickets, #165 à #169 et #178.

- **Largeur des écrans (#165).** Sur grand écran, tout écran tient dans une colonne de
  1 200 px, administration comprise : Tickets des membres, Dépense par utilisateur et
  formulaires ne s'étirent plus sur toute la largeur. Seuls cinq tableaux la gardent :
  journaux, rapports d'erreurs, dead letters, création d'un planning, coûts mensuels.
- **Profil et compte (#166).** Libellés en français accentué (« Identité », « Nom du compte
  Google », « Adresse e-mail », « Activité du compte », « Se déconnecter »), rôle en toutes
  lettres (« Lecteur », « Éditeur »…), puces « Lecture », « Édition », « Administration ». La
  photo s'annonce « Photo du compte Google » au lieu de son adresse ; l'identifiant du compte
  n'est montré qu'à l'administrateur ; la ligne « Compte révoqué », toujours « Non » sur cet
  écran, est retirée. Un compte Google sans nom faisait planter le menu du compte, et avec
  lui toute l'application : l'initiale vient maintenant du nom affiché à la famille, avec
  repli sur l'adresse. Se déconnecter depuis l'écran ou le menu du compte demande d'abord à
  l'écran ouvert s'il peut être quitté.
- **Connexion (#167).** Une connexion qui échoue affiche un titre et un conseil, et non plus
  le texte technique (« Erreur de connexion: [firebase_auth/…] Exception… »). L'écran défile
  quand la hauteur manque ; le numéro de version est lisible, en couleur secondaire.
- **Formulaire de livre (#168).** Accents rétablis (« Français », « Éditeur », « Série »…).
  Quitter avec une saisie non enregistrée demande « Quitter sans enregistrer ? ». Un livre
  supprimé affiche « Livre introuvable » et « Retour à la bibliothèque » ; une lecture en
  échec propose « Réessayer ». Les erreurs s'affichent en une phrase courte.
- **Bibliothèque (#169).** L'écran vide dit quoi faire selon le rôle : ajouter un premier
  livre, rejoindre un groupe, ou attendre qu'un proche du groupe en ajoute un ; tirer pour
  rafraîchir y fonctionne. Un compte sans groupe
  voit sous « Mes livres » une carte qui l'envoie vers Groupes familiaux.
- **Explorer en mode choix (#178).** Ouvert depuis une suggestion du planning, son contenu
  tient dans la même colonne de 1 200 px que l'Explorer du menu.

### v0.24.20 — technique

`wantsFullWidth` (`app_shell.dart`) devient une liste fermée de routes, testée ; la
constante `AppRoutes.tokenUsage` (`/token-usage`), déclarée sans route ni appelant, est
supprimée avec sa mention dans la documentation. Nouveaux points partagés :
`userRoleLabel` et `AppUser.initial` (`app_user.dart`), `signOutGuarded`
(`leave_guard.dart`) ; le libellé du rôle en attente devient « En attente » aussi dans
l'administration. L'écran de connexion et `signOutGuarded` remontent leurs erreurs par
`errorReportServiceProvider`, ce qui les rend testables. Aucun changement de données, de
règles ni de Cloud Function. Nouveaux tests : `app_shell_full_width_test`,
`account_screen_test`, `login_screen_error_test`, `book_form_leave_test`,
`book_list_empty_state_test`, et un cas de largeur dans `search_pick_mode_test`.

### v0.24.19 — fonctionnel

Quatrième palier de la refonte plat / menu : les critères écrits en texte libre sont
vérifiés. Au clic sur « Planifier avec l'IA », Kass'Dalle traduit une fois les préférences
générales et les contraintes du jour qui ont changé : allergène exclu, protéine ou féculent
principal exclu ou souhaité, durée maximale, repas léger. Il vérifie ensuite lui-même ces
critères. Sous chaque champ s'affichent « Compris : sans porc · 30 min max », puis
« Transmis à l'IA, non vérifié : « pas trop gras » ». Une exclusion ne se relâche jamais :
un service sans candidat reste vide, avec « Dessert : à choisir. Aucun dessert sans fruits
à coque. » et « Choisir ». Une préférence se relâche et la carte le dit : « 1 h 10, au-delà
des 45 min demandées : peu d'autres choix ». Un avis compte les créneaux concernés et mène
au premier avec « Voir le premier ». Ces écarts restent ensuite sur le repas, dans sa ligne
d'origine ; choisir, remplacer ou retirer une entrée ou un dessert retire leurs écarts, et
« Autre suggestion » sur un repas du planning remplace les écarts du plat en gardant ceux de
l'entrée et du dessert. Le programme ne propose plus d'accompagnement qui contient un
allergène exclu ; choisi à la main, un accompagnement est signalé « contient : gluten », et
une recette dont les allergènes ne sont pas encore calculés « allergènes non vérifiés ». Les
garnitures reçoivent leurs allergènes majeurs, saisis à la main dans le référentiel et dans
*Mes garnitures* ; sans saisie, elles sont « allergènes non renseignés ». Une exclusion de
protéine ne porte que sur la protéine principale de la recette. Sur téléphone, l'icône d'IA
de Nouveau planning s'appelle « Planifier avec l'IA », comme le bouton du grand écran.

### v0.24.19 — technique

Nouveau poste d'IA `planning_constraints`, étape de `suggestMealPlanFn`, inscrit dans
`ROUTABLE_FEATURES` (Planning) et dans `kFeatureCatalog` / `kFeatureProcess`. Un appel
`askJson` au plus par génération, pour les seuls textes absents du cache
`users/{uid}/preferences/planning_constraints` (empreinte SHA-256, 40 entrées). La
traduction entre dans le plafond par génération : son coût plafond est estimé avant l'appel,
et elle n'a pas lieu s'il dépasse le plafond (les textes partent alors « non vérifiés ») ; son
coût enregistré, à défaut son estimation, est retiré du plafond laissé au choix des plats et
ajouté au `cost_usd` de la génération (`planningRunCost`, rappel `onCost` d'`askJson`).
Règles Firestore : le cache est écrit par le serveur seul et lu par son titulaire seul ; la
lecture de l'administrateur, ouverte sur les autres préférences, est fermée pour ce document,
qui recopie les textes de `planning_config`. Un test bloquant de `rules-tests` vérifie
l'écriture et la lecture. Coût estimé : 600 à 950 jetons d'entrée et 50 à 300 de sortie par
appel, quelques appels par mois et par compte. Nouvelle fixture partagée
`planning_criteria.json` (`planningCriteria.ts` ↔ `planning_criteria.dart`) : vocabulaire,
lecture, réunion, prédicat d'exclusion ; les préférences restent côté serveur. La
présélection ajoute les motifs de rejet `excluded`, `unverified` et `preference`. « Prépa
max » devient une préférence relâchée en dernier (`max_duration`). Les clés relâchables
gagnent `wanted_proteins`, `wanted_starches`, `light` et `max_duration`.
`planning_slot_rules.json` reçoit 17 cas et en voit un changer : le plat trop long revient,
avec l'écart affiché. La réponse gagne `unmet` (suggestions, candidats, listes) et
`constraintTranslations`. Le résumé de recette envoyé au serveur porte `allergens`. Nouveaux
champs : `planned_meals.unmet_criteria`, `meal_staples.allergens` et `allergens` dans les
retouches ; `updateMealComponents` peut réécrire `unmet_criteria`. Aucun backfill : un champ
absent vaut « aucun écart » ou « allergènes non renseignés ». Le diagramme de séquence des
critères vérifiés porte le numéro 51.

## 2026-10-19

### v0.24.18 — technique

Déploiement (#161) : la CLI Firebase du workflow « Déploiement » vient de
`kass_dalle/deploy-tools/`, version et dépendances verrouillées par son `package-lock.json`.
Elle s'installe par `npm ci --ignore-scripts` avant l'authentification Google Cloud :
plus aucune dépendance n'est résolue ni exécutée à l'installation avec le jeton du compte
de service.

Sécurité du web (#160) : la Content Security Policy, toujours en rapport seul, envoie ses
rapports à `/csp-report`, que Hosting réécrit vers la nouvelle fonction `cspReportFn`. Elle
journalise chaque violation (directive, origine bloquée, chemin du document), sans écriture
ni appel d'IA. La politique a été vérifiée sur le build réel en mode bloquant. Elle
admettait mal trois chargements, qui auraient empêché le démarrage : les scripts en ligne de
`index.html` et de FlutterFire (désormais autorisés par empreinte) et `canvaskit.wasm`
depuis `www.gstatic.com`. Elle admet aussi Google Identity Services, le chargeur de
connexion Google et les cadres de reCAPTCHA. Le passage en mode bloquant viendra après
lecture des rapports de production.

### v0.24.17 — fonctionnel

Un import de recette compte 21 pages au plus : la première et 20 pages supplémentaires.
Au-delà, la file « Pages en attente » reste intacte : son titre devient « Pages à analyser
(25 sur 21 au plus) », une ligne en rouge dit « Retirez 4 pages pour lancer l'analyse. », et
« Analyser » reste désactivé jusqu'à ce que la file revienne à 21 pages. Une session du
scanner du système rend 20 pages au plus et passe toujours ; deux sessions, ou une sélection
de plus de 21 fichiers (web, Windows), demandent maintenant de retirer des pages alors
qu'elles partaient avant (ticket #156). Un import de plus de 200 Mo au total est refusé par le
serveur ; le job passe en erreur avec un message qui donne le poids.

Le formulaire « Signaler ou proposer » refuse une adresse e-mail dans le titre ou la
description : « Retirez l'adresse e-mail : le ticket est publié sur un site public. », sous
le champ concerné. Le serveur (`submitTicket`) fait le même contrôle.

### v0.24.17 — technique

Cinq corrections de l'audit #151.

#155 — `sandboxFn` appelle `requireAdmin` une fois, avant l'aiguillage sur `experiment`. Un
appel non administrateur est refusé quel que soit `experiment`, absent ou inconnu compris ;
il recevait avant `invalid-argument` sans passer par la garde. Les trois expériences
reçoivent le contexte de la garde et gardent leur poste de coût. Test
`sandboxGuard.test.ts` (six cas).

#156 — `additional_file_urls` d'un job d'import compte 20 entrées au plus. La règle
`processing_jobs` refuse une liste plus longue ou d'un autre type, en création et en mise à
jour, administrateur compris (`additionalFileUrlsBounded`, cinq cas dans `rules-tests`). Le
processeur refuse le job avant tout téléchargement (`TooManyPagesError`, dead letter
`too_many_pages`, message lisible dans `error_message`) et télécharge les pages une à une au
lieu de `Promise.all` (`pipeline/jobPages.ts`). Le client désactive « Analyser » au-delà
(`kMaxAdditionalFileUrls`, `pagesOverLimit`), et `processPages` garde le même contrôle sans
vider la file. La borne vit à trois endroits ; un test Dart et un test Functions relisent
`firestore.rules` et échouent si les valeurs divergent. Le client ne posait aucune limite ;
20 est la taille d'une session du scanner du système. Test de widget
`scan_screen_page_limit_test.dart`.

Poids total d'un import : 200 Mo au plus pour une recette ou une couverture (page principale
et pages supplémentaires), lu sur les métadonnées Storage avant tout téléchargement
(`assertImportSizeWithin`, `MAX_IMPORT_TOTAL_BYTES`). Au-delà, ou si une taille est
illisible : `ImportTooLargeError`, dead letter `too_large` sans nouvel essai, message lisible
dans `error_message`, affiché par la file de travail. Un livre entier (`bookDocumentScan`)
garde sa borne d'envoi de 300 Mo (`MAX_BOOK_UPLOAD_SIZE_BYTES`) : la borne de 200 Mo aurait
refusé des livres admis à l'envoi.

`submitTicket` refuse une adresse e-mail dans le titre ou la description (`readTicketInput`,
`TICKET_EMAIL_MESSAGE`, `details.reason` `contains_email`), sur le texte saisi et sur le
texte publié. `refuseTicket` et `submitTicket` transmettent maintenant `details.reason`. Le
client valide avant l'envoi (`validateTicketForm`, `ticketTextContainsEmail`,
`kTicketFormEmailMessage`) ; la fixture `ticket_answer_text.json` couvre déjà la détection
et n'a pas changé.

#157 — la modération d'images n'accepte que JPEG et PNG, lus sur la signature des octets
(`moderationImageMime`). L'objet publié et `mime_type` portent le type détecté ; le
`contentType` envoyé par le client n'est plus lu, sort de `ModerationItem` et n'est plus
envoyé par `ImageModerationService`. `scanUpload` rendait pour un `.txt` le type déclaré :
un texte pouvait être publié sous `image/jpeg` par la modération, et promu sous
`image/jpeg` ou `application/pdf` par `scanAndPromoteUploadFn`. Un `.txt` doit maintenant se
déclarer `text/plain` ou sans type, et sort en type texte.
L'approbation manuelle exige un `mime_type` JPEG ou PNG ; la relance relit le type sur les
octets et laisse en attente, avec un `logError`, un fichier d'un autre format. Les parcours
du client n'envoient déjà que du JPEG ou du PNG (`canonicalImageType`), et l'import par lien
convertit en JPEG.

#158 — le texte publié sur GitHub par le module tickets (titre, description, motif de refus,
« Répondre », commentaire de clôture) passe par `neutralizeMarkup` avant les mentions et les
renvois : commentaires HTML retirés, une espace sans chasse après chaque `<`, entre `!` et
`[` et après le `://` des pièces jointes que GitHub intègre. Le texte lu ne change pas ; le
HTML, les images et les pièces jointes ne chargent plus rien. Les définitions de référence
(`[//]: # (…)`, `[x]: https://…`) reçoivent une espace sans chasse entre `]` et `:` et
s'affichent en texte ; l'ancien format de pièce jointe `github.com/<owner>/<repo>/assets/`
est traité comme `user-attachments`. Un motif, une réponse ou un commentaire fait d'un seul
commentaire HTML est refusé comme trop court. La recherche d'adresse e-mail porte sur le
texte saisi et sur le texte publié (`jean<!-- x -->@gmail.com` recollait une adresse), et
s'applique aussi au motif de refus. Le texte stocké
dans Firestore, que l'application affiche, reste celui du membre.

#159 — `consolidateShoppingList` (`gemini/shopping.ts`) journalise par `logError` une
réponse du modèle illisible avant de rendre une liste vide, avec le poste, le nombre
d'ingrédients et la longueur de la réponse, sans leur contenu.

### v0.24.16 — fonctionnel

Troisième palier de la refonte plat / menu : un repas du planning est un plat ou un menu.
L'éditeur du repas porte un choix « Plat | Menu » en tête. En passant en menu, le plat
devient le service « Plat » avec ses accompagnements, et le modèle « Entrée, plat, dessert »
s'applique d'office ; « Entrée et plat » et « Plat et dessert » le remplacent tant
qu'aucun service n'est rempli. Un menu compte dix services au plus : entrée, plat, sorbet,
fromage, dessert, ou « Autre… » avec un nom. Il peut avoir plusieurs plats, chacun avec
ses accompagnements, six au plus. Les services s'ajoutent, se déplacent (poignée,
« Monter », « Descendre »), changent de type et se retirent. Un service vide reste « à
choisir » ; le programme ne remplit ni le fromage ni le sorbet. Le contenu d'un service se
choisit parmi les garnitures et les recettes de son type, ou en texte libre. Sur la tuile,
un menu affiche « Menu · N services » puis une ligne par service. Le menu ⋮ propose
« Passer en menu » et « Repasser en plat ». Repasser en plat demande confirmation quand un
service est rempli, et « Annuler » rend le menu. « Remettre à blanc » ne vide que le plat
principal d'un menu. Dans Nouveau planning, les formats s'appellent « Menu : entrée, plat,
dessert », « Menu : entrée et plat » et « Menu : plat et dessert », comme dans les
préférences du planning, et « Composer le menu » sur un créneau garde la composition
jusqu'à « Valider ». Les recettes et les garnitures de tous les services entrent dans les
courses, et l'export Calendar les décrit dans l'ordre du menu ; un menu remis à blanc y
écrit « Plat : à choisir », comme sur la tuile. Sur la tuile d'un menu, chaque
accompagnement a sa ligne, s'ouvre d'un appui et porte « Recette non partagée » quand il le
faut. « Passer en menu » n'est proposé que pour un plat ou une recette non classée, et le
menu proposé à l'ouverture de l'éditeur ne compte pas comme une modification.

### v0.24.16 — technique

Nouveau champ `planned_meals.meal_kind` (`plat` | `menu`). Absent, il se déduit des
composants : un composant d'un autre rôle qu'accompagnement fait un menu. Aucun backfill.
`components[]` reçoit `id` (`main` pour le marqueur du plat principal, un identifiant court
pour un plat secondaire, cité par `side_of`) et `course_label` (service « Autre »). Le plat
principal reste dans `recipe_id` / `recipe_titre` ; sa place est marquée par
`{role: plat, id: main, label: <titre>}`, dont le libellé suit le titre
(`withMainMarkerTitle`) pour qu'une version antérieure affiche « Plat : … ». Le domaine
`MealComposition` (`meal_composition.dart`) lit et réécrit la liste en services ordonnés et
porte les opérations et les bornes (10 services, 6 accompagnements par plat). L'éditeur
rend un `MealComposerResult`. `SidePickerSheet` choisit aussi le contenu d'un service
(`courseCandidatesFor`). Nouveau planning garde une composition éditée par créneau et écrit
`meal_kind` à la validation. Le prompt `planning` ne change pas : aucun poste d'IA, aucune
Cloud Function ni règle Firestore modifiés. `TestBackend` reçoit l'option `planningWrites`.

### v0.24.15 — technique

Après le déploiement : lancer *Admin › Backfills › Dossiers des illustrations* une fois. Si la
liste « À revoir » est vide, une version suivante limitera l'affichage des illustrations
d'une recette à `illustrations/` et `recipes/` (ticket #154).

Le champ `allergens` d'une recette s'écrit par le serveur seul. Les règles Firestore le
refusent à la création et à la mise à jour, créateur et administrateur compris
(`serverOnlyComputedFields`). Le client ne l'écrivait déjà jamais, mais rien n'empêchait une
écriture faite hors de l'application de poser une liste inventée, affichée sur la fiche. Une
mise à jour d'un autre champ passe toujours. Huit cas dans `rules-tests`.

Nouveau backfill ponctuel « Dossiers des illustrations » (`illustration_folders`,
`backfillIllustrationFoldersFn`), suite de l'audit #151. Contrôle en lecture seule, sans
appel d'IA : il liste dans « À revoir » les recettes dont une URL de `image_urls` ou de
`thumbnail_urls` n'est pas sous `illustrations/` ou `recipes/` du bucket, avec le dossier
trouvé, sans URL ni chemin complet. Il ne modifie aucune recette. `storageObjectPathOf`
prend une option `silent` pour ne pas journaliser la référence refusée.

Nouveau skill `steward` (`.claude/skills/steward/SKILL.md`) : suivre une PR jusqu'à sa fusion
et son déploiement — fusion de `master` sans rebase, collision de version, job rouge par job,
qui fusionne quoi, CI du commit de fusion, suivi du « Déploiement ». Une PR qui modifie ce
skill attend un « fusionne » explicite. Cité dans `CLAUDE.md` et `handbook-reseau-agents.md`.

### v0.24.14 — technique

Trois corrections de sécurité (tickets #152, #153 et #154).

#152. Une invitation par e-mail porte maintenant `group_owner_id`, l'uid du propriétaire de
son groupe, écrit par `manageInvitationFn` à la création et au renvoi. La règle Firestore de
`invitations` compare ce champ au lecteur non administrateur, au lieu de lire le groupe
courant. Avant, un groupe supprimé puis recréé sous le même identifiant par un autre éditeur
lui ouvrait les invitations restées en base, adresses comprises. La feuille du groupe filtre
sur `group_id` et `group_owner_id` (deux égalités, sans index composite). Les invitations
existantes n'ont pas le champ : seul un administrateur les lit, et le propriétaire ne les voit
plus dans la feuille du groupe tant que le backfill ponctuel « Propriétaire du groupe des
invitations » (`backfillInvitationGroupOwnerFn`) n'est pas passé. Il recopie le propriétaire
du groupe courant quand le groupe existe et que l'auteur de l'invitation en est le
propriétaire ; sinon il n'écrit rien et liste l'invitation « À revoir ». À l'acceptation
(`applyEmailInvitation`, `applyRevokedInvitation`), le groupe relu n'est rejoint que si son
`owner_id` vaut `group_owner_id` (`invitationGroupOf`) : un groupe recréé par un autre éditeur
ne reçoit plus l'invité sans son accord. Sinon, ou si l'invitation n'a pas le champ, le rôle
s'applique sans le groupe (`group_missing: true`). Le renvoi pose `group_owner_id` seulement
s'il manque et que l'auteur de l'invitation est le propriétaire relu, et refuse
`group_changed` sinon, ou s'il diffère du propriétaire relu. Le test `OPEN_FLAW`
de `rules-tests` est devenu bloquant.

#153. Écrire sous `users/{uid}/preferences` et `users/{uid}/nutrition_portion_overrides`
demande un compte nommé et non révoqué (`isApproved()`), en plus d'en être le titulaire.
`preferences` n'accepte en création et modification que les six identifiants que le client
écrit (`book_order`, `explore_filters`, `meal_staples`, `planning_refusals`,
`planning_visibility`, `recipe_search_scope`). La lecture reste au titulaire.

#154. `isAppImageUrl` décode le chemin de l'objet Storage et n'accepte que les dossiers
écrits par le serveur (`covers/`, `scans/`, `illustrations/`, `recipes/`, `users/`). Un
membre pouvait écrire dans `image_urls` l'URL à jeton d'un fichier de `quarantine/` ou de
`tickets/`, et la famille voyait l'image sans modération. Un chemin vide, avec `..`, `.`,
un segment vide ou un encodage illisible est refusé. Aucun écran n'affiche par URL une image
non modérée : la modération et les captures de ticket les lisent par leur chemin.

Après le déploiement : lancer *Admin › Backfills › Propriétaire du groupe des invitations*
une fois, au plus tôt. Une invitation antérieure acceptée avant ce passage donne le rôle sans le
groupe.

### v0.24.13 — fonctionnel

Deuxième palier de la refonte plat / menu du planning : un repas dit ce qui manque à son
plat. Sous les accompagnements d'un repas s'affiche « Il manque : légume » avec
« Compléter », ou « Apports du plat inconnus » pour une recette non classée. Le menu ⋮
d'un plat ouvre « Composer le repas », qui remplace « Ajouter un accompagnement ».
L'éditeur montre la recette, ce qu'elle apporte, ce qui manque ou « Plat complet », jusqu'à
six accompagnements, et une suggestion par besoin choisie sans IA. Il n'écrit qu'à
« Enregistrer ». Un accompagnement en texte libre peut indiquer qu'il apporte un féculent ou
un légume. Retirer un accompagnement depuis la tuile se défait par « Annuler ». Ce qu'une
recette apporte se corrige dans son panneau par trois pastilles, et l'IA ne revient plus sur
une correction. Nouveau planning garde tous les accompagnements d'un plat, dit ce qui
manque, et signale quand Kass'Dalle a relâché un critère (« Déjà servi dans ce cycle, faute
d'autre choix ») ; ce constat reste ensuite sur le repas. La feuille « Planifier » d'un
plat propose son accompagnement.

### v0.24.13 — technique

Nouveaux champs `tags.contains_manual` (recettes), `components[].provides` et
`relaxed_criteria` (`planned_meals`), sans backfill : un champ absent vaut sa valeur par
défaut. `containsPatch` (`gemini/mealRole.ts`) empêche `syncRecipeMealRole` et
`backfillRecipeRolesFn`, même en mode `force`, de réécrire un `contains` corrigé à la main ;
le client applique la même règle à « Suggérer les tags » (`mealContainsAfterSuggestion`).
La fixture `meal_roles.json` reçoit les sections `contains` et `contains_manual_cases`.
`chooseSide` est retiré au profit de `chooseSides` partout ; nouveau `dishSideStatus` (ce qui
manque au plat, accompagnements compris) ; `mergeSlotComponents` prend une liste
d'accompagnements ; `replaceMainSides` range les nouveaux accompagnements avant le dessert
sur les repas anciens. Le client lit `relaxed` des listes classées, que le serveur envoyait
déjà. Nouveau widget partagé `meal_composer.dart`. Le planning lit par lots de 30 les
recettes de ses propres repas de la période pour connaître leur `contains`.

### v0.24.12 — technique

Un agent ou un skill que Claude Code ne peut pas charger est maintenant signalé.
`.github/scripts/check-agents.mjs` lit l'en-tête YAML de chaque `.claude/agents/*.md` et
`.claude/skills/*/SKILL.md` avec js-yaml, exige `name` et `description`, compare `name` au nom
du fichier, et vérifie que chaque agent et skill cité dans `CLAUDE.md` existe. Le job Functions
de la CI le lance et échoue sur une anomalie : la fusion de la PR #71, qui a retiré
`ux-designer` et `securite` de toutes les sessions du 14 au 19 octobre, aurait été bloquée.
`session-start.sh` le lance aussi, sur le poste comme dans le cloud, et affiche un
avertissement sans bloquer. `CLAUDE.md` (« Agents ») demande à la session de signaler un agent
absent et de s'arrêter, sans le remplacer ni sauter la relecture. `js-yaml` devient une
dépendance de développement directe des Functions (4.3.1 → 4.3.2) ; il n'était présent qu'à
travers ESLint.

### v0.24.11 — fonctionnel

Dans le planning, « Changer la recette », « Autre suggestion » et une recette conçue par
l'IA ne retirent plus l'entrée ni le dessert du repas : seul l'accompagnement du plat est
recomposé. Un accompagnement ajouté à la main se range avant le dessert, et non plus en fin
de repas.

### v0.24.11 — technique

Premier palier de la refonte plat / menu du planning : la lecture d'un repas planifié
conserve ce qu'elle ne connaît pas. Avant, un rôle de composant inconnu se lisait
`accompagnement` et se réécrivait ainsi, et Nouveau planning réécrivait le document entier
avec trois composants au plus. Un téléphone pas encore à jour aurait changé un « fromage »
en accompagnement et effacé la deuxième entrée d'un menu. `MealComponentRole` reçoit `plat`,
`sorbet`, `fromage` et `autre`. Un rôle inconnu se lit `autre` et se réécrit tel quel, comme
les champs inconnus d'un composant et du repas. Changer le plat d'un repas ne retire plus
l'entrée ni le dessert : seuls les accompagnements du plat principal sont recomposés. Un
accompagnement ajouté se range avant le premier sorbet, fromage ou dessert. Ce palier doit
être installé sur les téléphones avant le palier « menu ».

### v0.24.10 — technique

Les agents `ux-designer` et `securite` n'étaient chargés dans aucune session. La valeur de
`description:` de leur en-tête YAML n'était pas entre guillemets et contenait « Lecture
seule : il … ». Un deux-points suivi d'une espace y ouvre une nouvelle clé : js-yaml rejette
l'en-tête (« bad indentation of a mapping entry »), et Claude Code écarte l'agent sans
message d'erreur. Les deux descriptions sont maintenant entre guillemets doubles, texte
inchangé ; les six en-têtes se lisent avec js-yaml. Le handbook (§5.1) note la règle.

### v0.24.9 — fonctionnel

Le choix d'un accompagnement accepte un texte libre et trouve mieux les recettes. Quand
aucune garniture ni recette ne porte le nom tapé, la ligne « Ajouter « Frites maison » »
le pose tel quel ; il s'affiche dans le repas, sans quantité, et n'entre pas dans les
courses. La recherche compare mot à mot, sans tenir compte du pluriel ni de l'ordre :
« pommes dauphines » ne trouvait pas la recette « Pommes dauphine ». « Ajouter un
accompagnement » dans le planning propose aussi les recettes d'accompagnement des autres
membres de la famille (hors livres privés), comme le faisait déjà « Nouveau planning ».

### v0.24.9 — technique

Un composant de repas peut n'avoir ni `recipe_id` ni `staple_id` : `MealComponent.free`,
`label` seul. Aucune règle Firestore ni Function ne lit `components`, et l'export Calendar
et la liste de courses lisaient déjà ce cas sans erreur. `SidePickerResult` porte le texte
libre et rend le composant par `toComponent`.

## 2026-10-18

### v0.24.8 — fonctionnel

Le choix d'un accompagnement se filtre. La feuille listait toutes les garnitures et recettes d'accompagnement les unes sous les autres, et il fallait faire défiler pour trouver la bonne. Elle porte maintenant un champ de recherche par nom, insensible aux accents, et une rangée de pastilles par famille (Féculent, Légume, Salade et crudités, Recettes…), limitée aux familles présentes. Les deux filtres se combinent. La hauteur de la feuille ne change plus pendant la saisie. Valable dans « Nouveau planning » et pour « Ajouter un accompagnement ».

### v0.24.7 — fonctionnel

« Chercher avec l'IA » suit mieux la demande. Une recherche « des frites et du poulet »
remontait un poulet servi sur du riz et, plus bas, du porc et du bœuf, parce que le prompt
demandait d'être généreux et de tenir compte des notes dans la sélection. Le modèle reçoit
maintenant le rôle de chaque recette dans un repas, sa protéine et son féculent principaux,
et il écarte une recette qui contredit la demande (autre protéine, autre féculent déjà
intégré). La note ne sert plus qu'à départager deux recettes aussi pertinentes ; une recette
non notée compte 7/10. La raison affichée dit ce que la recette réunit et ce qui manque.

### v0.24.6 — technique

Admin › Tickets, sur le web : la fiche d'un ticket qui peut être validé restait grise.
Depuis la v0.24.4, la ligne d'information au-dessus des boutons est choisie par une
chaîne de `? :` qui mêle un tuple constant (plafond de lancements atteint) et `null`.
dart2js (Dart 3.12.2) supprime alors le test `if (info != null)` qui suit, et le build
de la fiche lève « Null check operator used on a null value » quand aucune ligne n'est à
afficher. Android, compilé en natif, n'était pas touché. Le test est remplacé par un
motif (`if (info case (final infoIcon, final infoText))`), que dart2js conserve : le
`main.dart.js` produit vérifie le type de la valeur avant de la lire.

### v0.24.5 — fonctionnel

Suggestions des membres : un bouton « Chercher » à côté de « Planifier ce jour-là » (ticket
#142). Il ouvre l'Explorer en mode choix, champ pré-rempli du titre de la suggestion et
recherche lancée, sous un bandeau « Recette pour <jour>, <groupe> ». Un appui sur une recette
la rend à la fenêtre ; un calendrier propose le jour de la suggestion ou un autre (d'aujourd'hui
à 60 jours) et le repas est posé dans le planning du groupe, aux parts du groupe, avec
« Annuler ». Les filtres changés dans ce mode restent en mémoire et ne touchent pas les filtres
habituels (`explorePickPreferencesProvider`). Un brouillon, ou une idée de l'IA enregistrée
depuis « Imaginer 3 recettes », est posé en texte libre, avec la mention « Cette idée est
enregistrée dans vos brouillons. ». La suggestion n'est pas modifiée. Aucun paquet ne change.
Tests : `test/search_pick_mode_test.dart`, `test/widgets/meal_suggestions_test.dart`.

### v0.24.4 — fonctionnel

Fiche d'un ticket (Admin › Tickets des membres) : sur un ticket Analysé, un bouton « Valider et
lancer le développement » s'ajoute à « Valider » (ticket #144). Il devient le bouton principal ;
« Valider » passe en bouton tonal. Une seule confirmation annonce la validation puis le
lancement et rappelle les lancements restants du jour. Si la validation est refusée, rien n'est
lancé. Si le lancement échoue, le ticket reste Validé et le message le dit : « Ticket validé,
développement non lancé : … ». Le bouton est désactivé quand le plafond du jour est atteint.

### v0.24.3 — fonctionnel

Suggérer un plat : un bouton « Recherche avancée » à côté du champ « Quel plat ? » ouvre un
écran dédié (ticket #141). Il cherche sans accents ni casse dans le titre, les étiquettes et
les ingrédients principaux (« pates » trouve « Pâtes carbonara », « tomate » trouve les
recettes qui en contiennent), affiche « contient : … » pour un ingrédient trouvé, et reprend
les filtres de l'Explorer (type de plat, cuisine, temps, difficulté, thème, allergènes…).
Toucher un résultat revient à l'écran avec la recette choisie ; sans résultat, le texte se
garde comme nom libre. Le champ principal garde son filtre par titre et le nom libre. Aucun
appel d'IA. Le sélecteur de recettes du planning n'est pas modifié.

### v0.24.3 — technique

Nouvel écran `AdvancedDishSearchScreen` (`planning/presentation/`), route fille
`/planning/suggest/search`. Il réutilise `applyRecipeFilter` et `ExploreFilterPanel` sans
toucher à `SearchScreen`. `ExploreFilterPanel` reçoit deux paramètres optionnels,
`showSourcesAndSort` et `hiddenDimensions`, par défaut sans effet sur l'Explorer. Les filtres
vivent dans l'état de l'écran, hors de `explorePreferencesProvider`. Test :
`test/advanced_dish_search_screen_test.dart`. Aucun paquet ne change.

### v0.24.2 — fonctionnel

Fiche d'un ticket (Admin › Tickets des membres) : les messages de succès ne masquent plus
la barre de décision (ticket #143). « Valider », « Refuser », « Clore » et « Relancer
l'envoi » n'affichent plus de SnackBar de succès. La puce de statut de la fiche clignote
trois fois (opacité 1 → 0,35, environ 1,2 s) quand le statut change, puis reste fixe. Elle
ne clignote ni à l'ouverture, ni quand on passe d'un ticket à un autre, ni avec les
animations réduites ; un lecteur d'écran annonce le nouveau statut. « Lien copié. » et les
messages d'erreur restent inchangés. `TicketStatusChip` (`ticket_widgets.dart`) reçoit le
paramètre `blinkOnChange`, actif sur la fiche seulement. Aucun paquet ne change. Test :
`test/features/tickets/ticket_status_chip_test.dart`.

## 2026-10-17

### v0.24.1 — fonctionnel

Planning par lot : un cycle qui franchit le changement d'heure du 25 octobre 2026 affiche
les bons jours (ticket #139, « 2x dimanche, pas le jeudi »). Les dates du cycle se
calculaient avec `Duration(days: i)`, soit `i × 24 h` : après le passage à l'heure d'hiver,
la date tombait à 23 h la veille, le dimanche apparaissait deux fois et le dernier jour
disparaissait. Le serveur recevait ces dates et appliquait deux fois les contraintes du
dimanche. `cycleDatesFrom` (`planning_preferences.dart`) construit désormais chaque jour par
`DateTime(année, mois, jour + i)`, comme `_addDay` de `batch_planning_screen.dart`
(« ajouter un jour » et détection d'un jour manquant). Aucune donnée stockée n'est touchée.
Test : `test/planning_cycle_dates_test.dart`.

### v0.24.0 — fonctionnel

Planning : deux plats principaux de même protéine ne se suivent plus quand un autre
candidat existe (ticket #137, deux jours de poulet d'affilée). `validateModelChoices`
(`gemini/planning.ts`) refuse le choix du modèle dont la protéine connue est celle de la
veille ou du lendemain, comptée par date. Avant, seule la protéine du créneau traité juste
avant servait de repli, et l'ordre de traitement (créneaux non envoyés d'abord) n'est pas
l'ordre des jours. Le refus s'ajoute à `rejected_choices`. Sans candidat libre d'une autre
protéine, le créneau reste rempli par le premier candidat libre. Aucune modification Dart, aucun nouveau poste d'IA.
Une recette sans tag `main_protein` ni indice dans les types de plat reste « inconnue » et
n'est pas détectée.

### v0.23.100 — fonctionnel

Brouillons : un doublon est maintenant visible. Chaque brouillon doublon affiche une pastille « Doublon possible » sous sa ligne, sur toute la largeur, puis le détail sur deux lignes au plus (« Doublon possible de « Rouget » (p. 3) » quand le serveur l'a marqué). Le serveur ne marquait que le brouillon écrit en second : le plus ancien de deux brouillons « Rouget » d'un même livre n'affichait rien. La file rapproche désormais deux brouillons du même livre de même titre et leur donne à chacun la pastille, avec « Même titre : « Rouget » (p. 3) ». Pas de rapprochement sans livre, ni quand les deux pages sont connues et différentes. La validation en lot ne change pas : elle écarte les seuls brouillons marqués par le serveur. Un doublon avec une recette déjà validée reste signalé par la seule marque du serveur. Ticket #132.

### v0.23.100 — technique

`Recipe.titreKey` lit `titre_key` (lecture seule, absent de `toFirestore`). `draftTitleTwins` (`features/recipes/domain/draft_title_twins.dart`) compare les clés déjà posées par le serveur, sans normaliser de titre : aucune logique dupliquée Dart ↔ TypeScript, aucune fixture. `QueueDraftTile` reçoit `twins` de `work_queue_screen.dart` et affiche `_DuplicateBadge`. Aucune Function, règle, donnée ni dépendance ne change. Le backfill « Clé de titre des recettes » doit être terminé pour que les recettes anciennes soient rapprochées.

### v0.23.99 — fonctionnel

Menu du compte : nouvelle entrée « Nouveautés ». Elle ouvre un écran qui liste les six dernières versions de l'application, de la plus récente à la plus ancienne, avec leur numéro, leur date et ce qu'elles changent. Une pastille « Installée » repère la version de l'application. Si la liste ne se charge pas, l'écran affiche « Impossible d'afficher les nouveautés. » et un bouton « Réessayer ». Demandé par le ticket #131.

### v0.23.99 — technique

`.github/scripts/changelog-recent.mjs` extrait du `CHANGELOG.md` les six dernières versions qui ont une entrée « fonctionnel » et écrit `kass_dalle/assets/changelog_recent.json`, déclaré comme asset dans `pubspec.yaml`. Il échoue s'il trouve moins de six versions. Son test (`changelog-recent.test.mjs`) et la génération tournent dans le job Flutter de `ci.yml` ; `deploy.yml` régénère le fichier avant le build web, et l'APK l'embarque. La copie versionnée sert aux builds locaux et aux tests ; `deploy.ps1` embarque cette copie. Écran `core/presentation/changelog_screen.dart`, service `core/services/changelog_service.dart` (erreur remontée par `ErrorReportService`, feature `changelog.load`), route `/changelog`, nom d'écran « Nouveautés » ajouté à `kTicketScreenNames`. Aucun paquet ni `pubspec.lock` modifié.

### v0.23.98 — fonctionnel

Admin › Tickets des membres : nouvelle décision « Clore », pour un ticket Reçu, Analysé, Validé ou En cours, de tout type. L'administrateur écrit un commentaire (5 à 4 000 caractères, sans adresse e-mail) ; il est publié sur GitHub en « Réponse : … », l'Issue est fermée et le ticket passe à « Clos ». Le membre lit le commentaire dans « Mes tickets » (« Ce ticket est clos. », « L'administrateur vous a répondu ci-dessous. »). « Clore » est masqué pendant une livraison de ce ticket. Un ticket Clos est final : plus de validation, de refus, de réponse ni de lancement. Le filtre de statut de l'administrateur gagne la puce « Clos » (neuf statuts). Le type « Question » n'est plus proposé à la création d'un ticket (« Bug », présélectionné, « Évolution », « Nouvelle fonctionnalité ») et le serveur le refuse ; les tickets Question déjà créés restent lisibles et filtrables. L'état vide de « Mes tickets » dit « Un bug, une idée ? Envoyez-les à l'administrateur. ». Les versions installées avant celle-ci ne connaissent pas le statut Clos et affichent « Reçu » pour un ticket clos, jusqu'à leur mise à jour.

### v0.23.98 — technique

Callable `closeTicket` (`tickets/decisions.ts`, `closeTicketDecision`), calquée sur `refuseTicket` : bail `decision_lease_until`, refus pendant une livraison de ce ticket (`launchRunState` livraison ou verrou `delivery_running` sur ce ticket), commentaire publié sauf s'il l'est déjà (`sameReply`), étiquette `statut:clos` puis `closeIssueCompleted` (`github.ts`), écriture de `closed` et `reply_text`. Échecs : `close_published_close_failed` (`aborted`), `ticket_not_updated` (`internal`), `issue_closed`. Nouveau statut final `closed` dans `TICKET_STATUSES`, `FINAL_STATUSES` et `STATUS_RANK` ; `statusFromIssue` lit une Issue fermée portant `statut:clos` comme `closed`, quelle que soit la raison de fermeture. `closePrecondition` et `ticketDecisions.canClose` (`rules.ts`), `ticketCanClose` et `AdminTicketDecisions.canClose` (`ticket.dart`) : logique dupliquée Dart ↔ TypeScript, cas ajoutés d'abord à `ticket_decisions.json` (`can_close` par ligne de `cases`, lignes `closed`, section `close_cases`, `close_partial_reason`). `readCloseComment` réutilise les contrôles de `readAnswerText` (champ `comment`). `CREATABLE_TICKET_TYPES` (serveur) et `creatableTicketTypes` (client) séparent les types créables des types connus : `submitTicket` refuse `question`. Aucune règle Firestore ni Storage ne change ; deux tests s'ajoutent dans `rules-tests` (ticket `closed` lu par son auteur et l'administrateur seulement, non modifiable par l'auteur). Étiquette `statut:clos` créée par GitHub à sa première pose : sa couleur se donne à la main. Documents mis à jour : FunctionalRequirements (§5.13, §8.5), TechnicalRequirements, cas d'utilisation, architecture, diagrammes de séquence et de classes, handbook. Le tableau « Logique dupliquée » de `CLAUDE.md` (ligne `ticket_decisions.json`) cite « Clore », `close_cases`, `closePrecondition`, `ticketCanClose` et les deux constantes de l'échec partiel ; le module Tickets n'y mentionne plus la création d'une question. Aucun backfill, aucun poste d'IA, aucune nouvelle dépendance.

### v0.23.97 — fonctionnel

Doublons à l'import. Un scan de page dont la recette a le même titre qu'une recette du livre (brouillon ou validée), ou qu'un import du même livre encore en cours, s'arrête après la transcription au statut « Doublon possible ». Deux numéros de page connus et différents écartent le doublon. La file des brouillons montre la recette existante en lien, et propose « Ce n'est pas un doublon » (le traitement reprend sans refaire la transcription) ou « Supprimer ». L'import d'un livre entier marque les recettes déjà présentes comme brouillons « Doublon possible » ; la validation en lot les saute, la relecture permet de les valider. À l'import d'un fichier en nouveau livre, un livre déjà dans la bibliothèque (même titre et auteur compatible, ou même fichier) est signalé, avec « Importer dans ce livre » ou « Créer un nouveau livre quand même ». Après le déploiement, lancer une fois Admin › Backfills › « Clé de titre des recettes » pour que les recettes existantes servent de référence.

### v0.23.97 — technique

Détection sans appel de modèle (`pipeline/duplicateDetection.ts`) : `titre_key` sur les recettes (posé à l'import, recalculé par `onRecipeWritten`, repris par le backfill ponctuel `recipe_title_keys`, `backfillTitleKeysFn`), `titre_keys` / `titre_key_pages` / `titre_key_titres` / `duplicate_checked` sur les jobs, deux index composites. Nouveau statut de job `duplicate` avec `duplicates`, `pending_items`, reprise par `duplicate_override` écrit par le client. `duplicate_of` sur les brouillons d'un import de livre, effaçable seulement. `books.source_file_sha256` et `existingBook` dans la réponse d'`analyzeBookFileFn`. Règles : création de job sans champ serveur et en file, relance limitée à `queued`/`error`, reprise et suppression d'un job `duplicate` par son propriétaire éditeur. Une écriture qui ne change que `titre_key` ne relance aucun traitement de `onRecipeWritten`.

### v0.23.96 — fonctionnel

#### Signaler ou proposer (`/tickets/new`)

- Le type « Bug » est sélectionné à l'ouverture du formulaire, avec son aide de description.
  Le membre peut en choisir un autre avant l'envoi. Demandé par le ticket #127 : la plupart des
  tickets sont des bugs, et le choix du type était une étape de plus.
- Le message « Choisissez le type de ticket. » n'apparaît plus dans le parcours normal ;
  `validateTicketForm` garde ce contrôle.

### v0.23.95 — fonctionnel

Admin › Tickets des membres : le filtre « À traiter » et son compteur incluent les tickets En cours dont la pull request est prête à livrer, quand « Livrer » est offert. Ils n'apparaissaient que sous « Tous ». Un ticket En cours sans PR prête, ou dont la livraison est en cours, reste exclu. Demande du ticket #123.

### v0.23.95 — technique

`isTicketAwaitingDelivery` (`ticket.dart`) : PR prête côté serveur, historique des lancements lu, `canDeliver` vrai. `adminAwaitingDeliveryIdsProvider` lit `ticketDeliveryProvider` et `ticketLaunchesProvider` des seuls tickets En cours ; `adminActionTicketIdsProvider` l'ajoute à la requête par statut. Le compteur, la pastille du compte et `filterAdminTickets` (`awaitingDeliveryIds`) le lisent. `kAdminTicketToProcessStatuses` ne change pas. Aucun changement de donnée, de règle ni de Function.

### v0.23.94 — fonctionnel

Suggérer un plat : la suggestion s'ouvre en page entière, plus en feuille ni en boîte de dialogue. Le champ principal est « Quel plat ? » : un nom tapé (« des frites ») suffit à envoyer, sans choisir de recette. Les recettes correspondantes s'affichent dessous, dans le même écran, titres privés des livres de la famille compris. Le mot facultatif est un champ à part. Quand « Envoyer la suggestion » est inactif, une phrase dit pourquoi. Quitter avec une saisie demande confirmation. Demande du ticket #121.

### v0.23.94 — technique

`SuggestMealSheet` (`suggest_meal_sheet.dart`) devient `SuggestMealScreen` (`suggest_meal_screen.dart`) ; `showSuggestMealSheet` devient `openSuggestMeal`, qui pousse la route `AppRoutes.suggestMeal` (`/planning/suggest`) avec `SuggestMealArgs` en `extra` et attend le prénom du propriétaire. Sans `extra`, la route redirige vers `/planning`. La liste de recettes est intégrée à l'écran (`filterPickerRecipes`, `suggestableRecipesProvider` et `suggestablePrivateTitlesProvider`) : `RecipePickerSheet` n'est plus utilisé par la suggestion. L'écran pose un `LeaveGuard` (`leaveGuardProvider`) pour que la navigation du bas et le menu latéral demandent la même confirmation que le retour ; `/planning/suggest` reçoit son libellé dans `ticket_screens.dart`. Aucune donnée, règle ni Cloud Function ne change. Tests : `test/widgets/meal_suggestions_test.dart` passe par un `GoRouter`, et `test/suggest_meal_screen_test.dart`.

### v0.23.93 — fonctionnel

Tickets : une analyse qui pose une question n'empêche plus de répondre. Quand la session d'analyse
publie une analyse ou des « compléments » sur l'Issue, la ligne « Analyse en cours depuis … » disparaît
tout de suite au lieu de durer une heure. « Répondre » est alors offert, et « Lancer l'analyse »
devient « Relancer l'analyse ». Demande du ticket #119.

### v0.23.93 — technique

`launchRunState` (`rules.ts`) et `ticketLaunchRunState` (`ticket_launch.dart`) reçoivent la date de la
dernière analyse (`analysisPublishedAtMs`, `analysisPublishedAt`) : une analyse strictement postérieure
au lancement termine un lancement d'analyse avant son échéance. Appelée par `launchTicketAnalysis`,
`answerTicketAnalysis` et `adminTicketDecisions`. Cas ajoutés à `ticket_decisions.json`
(`launch_runs.analysis_published_at`), rejoués côté Dart et TypeScript.

### v0.23.92 — fonctionnel

Suggérer un plat : le sélecteur propose aussi les recettes validées des livres privés des membres
de vos groupes, en titre seul (nom du livre et cadenas, sans image ni ingrédients). Le destinataire
d'une suggestion sans accès à la recette n'en voit que le titre. L'auteur ne peut pas refuser
l'affichage du titre. Un membre sans groupe en commun n'en voit rien. Demande du ticket #117.

### v0.23.92 — technique

Nouvelle Cloud Function `listFamilyPrivateTitlesFn` (`callable/privateTitlesCallable.ts`,
`gemini/privateTitles.ts`) : lit `group_reach` puis les recettes privées validées, et ne rend que
`{id, titre, bookTitre, createdBy}`. Règles Firestore inchangées. Côté client,
`PrivateTitlesRepository`, `suggestablePrivateTitlesProvider` et `PrivateRecipeTitle`
(recette creuse). Tests : `privateTitles.test.ts`, `private_recipe_title_test.dart`. Aucune
dépendance modifiée.

### v0.23.91 — fonctionnel

Groupes : la gestion des membres d'un groupe n'est plus une feuille qui monte du bas, mais une page à part entière, à l'adresse `/groups/<groupe>`. Elle a sa barre d'application (nom du groupe, flèche « Retour aux groupes »), son lien direct et un contenu centré sur 640 px au plus sur grand écran. Recherche, invitation, annulation et retrait fonctionnent comme avant, avec les mêmes droits. Un groupe inconnu ou quitté affiche « Groupe introuvable ». Demande du ticket #116.

### v0.23.91 — technique

`_ManageMembersSheet` devient `GroupMembersScreen` (`group_members_screen.dart`), reçoit `groupId` et relit le groupe par `groupByIdProvider`. Route `AppRoutes.groupMembers` (`/groups/:groupId`) dans `app_router.dart` ; `GroupsScreen` y mène par `context.push`. Aucun changement de données, de règle ni de Function.

## 2026-10-16

### v0.23.90 — fonctionnel

Groupes : la feuille d'un groupe liste maintenant les invitations par e-mail en attente (personnes
sans compte, par exemple les enfants), avec l'adresse, le rôle et « Invitation envoyée par e-mail »
ou « Envoi échoué ». Le compteur « Invitations en attente (n) » et la ligne de la tuile comptent les
deux sortes d'invitation. Seul le propriétaire du groupe les voit ; l'annulation et le renvoi restent
dans Admin › Invitations. Si la lecture échoue, une ligne « Invitations par e-mail indisponibles »
propose de réessayer. Demande du ticket #113.

### v0.23.90 — technique

`firestore.rules` : la lecture de `invitations/{id}` s'ouvre au propriétaire du groupe désigné par
`group_id`, en plus de l'administrateur (un `get` du groupe par document lu). Une requête sans filtre
sur `group_id` reste refusée à un non-admin. Nouveau `InvitationsRepository.watchGroupInvitations`
(filtre `group_id`, tri côté client, pas d'index), `groupEmailInvitationsProvider` et
`pendingEmailInvitations`. Tests dans `rules-tests` et `pending_email_invitations_test.dart`.
Limite connue, test `todo` dans `rules-tests` : un éditeur qui recrée sous le même identifiant un groupe
supprimé lit les invitations restées en attente sur l'ancien groupe. Une correction passe par un
champ `group_owner_id` écrit par le serveur dans l'invitation, avec un backfill.

### v0.23.89 — fonctionnel

Écran de démarrage : la ligne fixe « Un jaune d'œuf » disparaît. Une phrase d'ambiance la
remplace sous la date, en italique, tirée au lancement selon la même tranche horaire que la
formule d'accueil. Matin : « Un bon petit-déjeuner t'attend. », « Qu'est-ce qu'on mijote
aujourd'hui ? », « Le carnet de recettes est ouvert. ». Après-midi : « Une idée pour ce
soir ? », « Le temps de préparer quelque chose de bon. », « Un goûter, peut-être ? ». Soir :
« À table, bientôt ! », « Le planning de la semaine t'attend. », « Une dernière recette avant la
nuit ? ». La durée de l'écran et sa fermeture ne changent pas. Demande du ticket #112.

### v0.23.88 — fonctionnel

Écran de démarrage : une ligne fixe « Un jaune d'œuf » s'affiche sous la date et l'heure, en
italique, à chaque lancement. Elle apparaît avec la formule d'accueil, jamais pendant
l'indicateur de chargement. La durée de l'écran et sa fermeture ne changent pas. Demande du
ticket #110.

### v0.23.87 — fonctionnel

Écran de démarrage : la formule d'accueil dépend de l'heure locale de l'appareil. De 5 h à
11 h 59 : « Bonjour », « Belle matinée », « Bien réveillé ? ». De 12 h à 17 h 59 : « Bon
après-midi », « Content de te revoir », « Les casseroles t'attendent ». De 18 h à 4 h 59 :
« Bonsoir », « Bonne soirée », « C'est l'heure du dîner ? ». Une variante est tirée au
lancement. Une seconde ligne affiche la date et l'heure du lancement en français. Sans
profil lu, la formule s'affiche sans prénom. Demande du ticket #108.

### v0.23.86 — technique

Déploiement : tous les déploiements depuis la v0.23.81 ont échoué à l'étape « Construire
l'APK ». Le web, les Functions et l'APK en ligne sont restés en v0.23.80. L'ajout de
`firebase_messaging` (v0.23.81) a fait monter `firebase_core` à 4.15.0, qui a déplacé
`customAuthDomain` de `FlutterFirebaseCorePlugin` vers `FlutterFirebasePlugin`.
`firebase_auth` 6.5.7 lisait encore l'ancien emplacement et ne compilait plus en Java.
`firebase_auth` passe à 6.7.0, avec `cloud_functions` 6.5.0, `firebase_storage` 13.6.0 et
`firebase_app_check` 0.4.8, et leurs paquets `_platform_interface` et `_web`.

La CI ne compilait que le web, et cette erreur ne s'y voyait pas. Un job « Android —
compilation » est ajouté à `ci.yml` : quand le diff touche `pubspec.yaml`, `pubspec.lock` ou
`android/`, il compile l'APK release, signé par une clé jetable générée dans le job,
en 45 minutes au plus.

`CLAUDE.md` gagne la règle « Une dépendance se compile pour Android avant de partir » : lire
le diff de `pubspec.lock` et nommer chaque paquet monté dans le `CHANGELOG.md`, monter la
famille FlutterFire ensemble, compiler l'APK avant le push (sur le PC) ou attendre le job
Android vert (en session cloud), et traiter un échec de « Construire l'APK » comme une CI
rouge. `relecteur-regles` la vérifie (contrôle 15) ; l'étape 2 de la « Chaîne de travail »
cite `flutter build apk --release`.

### v0.23.85 — fonctionnel

Administrateur : la puce du compte compte les invitations de groupe et les tickets à traiter.
Ses propres tickets non lus n'y entrent plus et « Mes tickets » n'a plus de pastille pour lui,
car ce ne sont pas des actions à entreprendre. Les autres rôles ne changent pas. Ticket #100.

## 2026-10-15

### v0.23.84 — fonctionnel

Tickets (ticket #105) : un ticket En cours dont la pull request vient d'être ouverte affiche
« CI en cours » dans la liste d'Admin › Tickets, puis « PR prête » quand la CI est verte. Avant,
l'état n'apparaissait qu'après le passage de la tâche horaire.

### v0.23.84 — technique

Le webhook GitHub relit aussi la livraison sur les événements `workflow_run` `requested` et
`in_progress` du workflow « CI », plus seulement `completed`. `ci_status` est écrit dès le
départ du run (`deliveryRefreshFromEvent`). Le coût est une relecture GitHub de plus par run.

### v0.23.83 — fonctionnel

Ticket #101 : « Répondre » est disponible sur un ticket Reçu, avant « Lancer l'analyse ».
L'administrateur ajoute une précision, publiée sur l'Issue en « ## Précisions de
l'administrateur ». Le ticket reste Reçu, l'étiquette `statut:à-analyser` aussi, et rien n'est
lancé. Plusieurs réponses se suivent. « Répondre » est masqué pendant une analyse en cours.
La session d'analyse lit ces précisions : sans analyse précédente, elle lit toutes celles de
l'Issue. Le texte de la Routine d'analyse (hors dépôt) est à mettre à jour de la même façon.

### v0.23.83 — technique

`answerPrecondition` et `ticketCanReply` (TypeScript et Dart) acceptent le statut `received`
sans exiger d'analyse. `answerTicketDecision` ne remet pas le ticket à Reçu dans ce cas
(`answerReset` seulement pour Analysé et Validé). Sur un ticket Reçu, les étiquettes de
l'Issue ne changent pas. Le refus pendant un lancement
porte aussi sur l'analyse d'un ticket Reçu. Fixture `ticket_decisions.json` (`reply_cases`)
étendue. Aucune règle Firestore ni Storage ne change.

### v0.23.82 — fonctionnel

Tickets (ticket #97) : la ligne de livraison indique la version de l'application qui livre le
ticket, par exemple « Livré en v0.23.80 par la PR #97 ». Elle s'affiche sur la fiche Admin ›
Tickets et sur « Mes tickets ». Sans version lisible, le texte reste « Livré par la PR #N ».

### v0.23.82 — technique

Nouveau champ `delivered_version` sur `tickets/{id}`, écrit par `recordDeliveredPr` avec la PR :
la ligne `version:` de `kass_dalle/pubspec.yaml` au commit de fusion, sans numéro de build
(`pubspecVersionName`, `pubspecVersionAtCommit`). Un échec de lecture est journalisé et
n'empêche pas d'écrire la PR. Le champ est effacé quand le ticket quitte `delivered`. La reprise
horaire et le backfill `ticket_delivered_pr` relisent aussi les tickets livrés sans version.
Aucune règle Firestore ne change ; un cas de `rules-tests` vérifie que l'auteur ne l'écrit pas.

### v0.23.81 — fonctionnel

Ticket #96 : les administrateurs reçoivent une notification Android « Nouvelle version
disponible » quand un nouvel APK est publié, au plus 10 minutes après. Un toucher sur la
notification ouvre la fenêtre de mise à jour. Les éditeurs et les lecteurs ne reçoivent rien.
Android 13 et plus demande l'autorisation une seule fois, après la connexion d'un
administrateur. Aucun réglage dans l'application : les notifications se coupent dans Android.
Un administrateur reçoit la première notification après avoir installé cette version.

### v0.23.81 — technique

Nouvelle tâche planifiée `releaseNotificationSchedule` (toutes les 10 minutes) : lit
`apk_release.json`, réserve le couple version + build dans `app_config/apk_notification`
(écriture serveur seule) par une transaction, puis envoie par FCM aux appareils
`users/{uid}/devices/{token}` des comptes `admin` non révoqués, rôle relu à l'envoi. Les jetons
périmés sont supprimés. Règle Firestore `devices` : écriture par le titulaire administrateur,
forme bornée, aucune lecture client ; 13 tests ajoutés dans `rules-tests/`. Client :
dépendance `firebase_messaging`, permission `POST_NOTIFICATIONS`, `PushRegistrationService`.
`deploy.yml` et `.github/` ne changent pas.

### v0.23.80 — fonctionnel

Admin › Tickets (ticket #92) : la liste montre les états intermédiaires. Après « Lancer
l'analyse », « Lancer le développement » ou « Livrer », la ligne du ticket porte une puce
« Analyse en cours », « Développement en cours » ou « Livraison en cours », puis « Relance
possible » quand l'échéance passe sans changement de statut. La règle est celle de la fiche
(`adminTicketDecisions`) : une écoute de l'historique des lancements par ligne Reçu, Validé ou
En cours, côté administrateur seulement. Aucun changement de schéma, de règle ni de Function.

### v0.23.79 — fonctionnel

Les pastilles de tickets affichent un nombre. La puce du compte (barre du haut) porte une pastille chiffrée à la place du point : invitations de groupe en attente plus tickets distincts à lire ou, pour l'administrateur, à traiter (`99+` au-delà de 99). « Mes tickets » reçoit une pastille pour tout ticket dont le statut a changé depuis sa dernière ouverture, y compris Analysé, Validé et En cours, et plus seulement pour Répondu, Refusé ou Livré ; « Envoi en cours » est exclu. L'entrée du menu s'écrit « Tickets à traiter », sans le nombre entre parenthèses : il reste sur la pastille de l'icône. Ticket #90.

### v0.23.78 — fonctionnel

Un ticket livré indique la PR qui l'a livré : « Livré par la PR #N », avec un lien vers GitHub,
dans la fiche du membre (Mes tickets) et dans Admin › Tickets, où le bouton « Ouvrir la PR #N »
reste disponible après la fusion. Un ticket fermé à la main, sans PR, n'affiche rien de plus.
Les tickets déjà livrés se reprennent par Admin › Backfills, « PR des tickets livrés » (ticket #91).

### v0.23.78 — technique

Deux champs sur `tickets/{id}` : `delivered_pr_number` et `delivered_pr_url`, écrits par les
Functions seules (les règles Firestore ne changent pas ; un test de `rules-tests/` vérifie que
l'auteur ne peut pas les écrire). `recordDeliveredPr` lit le commit de fermeture de l'Issue
(`/issues/{n}/events`) puis les PR de ce commit (`/commits/{sha}/pulls`) et retient la dernière PR
fusionnée de confiance qui ferme l'Issue. Appelé par le webhook (`issues` `closed`), par
`resyncTicket` et par `ticketsSyncSchedule` (tickets livrés depuis moins de trois jours sans
numéro). Les champs sont effacés quand le ticket quitte `delivered`. Nouveau backfill ponctuel
`ticket_delivered_pr` (`backfillTicketDeliveredPrFn`), ajouté aux deux registres et à la fixture
`backfill_schedule.json`. Aucun poste d'IA.

### v0.23.77 — fonctionnel

Admin › Tickets : le bloc « Réponse de l'administrateur » (et « Motif du refus ») était illisible, texte clair sur fond bleu clair. Il prend maintenant un fond neutre, une bordure fine et le texte `onSurface`, avec un contraste d'au moins 4,5:1 en mode clair et en mode sombre. Dans le bloc « Votre réponse » et les analyses, le gras, l'italique, le code, les liens, les titres de niveau 4 à 6 et les tableaux suivent la couleur du reste du texte. Un test de widget vérifie le contraste dans les deux modes.

### v0.23.76 — fonctionnel

Admin › Tickets : le filtre « À traiter » et la pastille du menu comptent aussi les tickets
Validés. Un ticket validé attend une réponse à une question de l'analyse ou le lancement du
développement : il restait hors du filtre. Il en sort au passage En cours, Terminé ou Refusé
(ticket #80).

### v0.23.76 — technique

`kAdminTicketToProcessStatuses` (`ticket.dart`) passe de deux à trois statuts. Le compteur
reste un `whereIn` sur le champ `status` : pas de nouvel index, pas de backfill, pas de
changement de règles.

### v0.23.75 — fonctionnel

Admin › Tickets : un ticket En cours offre « Livrer ». Quand sa pull request est prête (une
seule PR de la session, CI verte), la fiche affiche « PR #57 prête — CI verte
le … » et le bouton « Livrer ». Une session Claude Code met alors la PR à jour avec `master`,
la fusionne et suit le déploiement ; appuyer sur « Livrer » vaut accord de fusion. Sinon, une
seule ligne dit ce qui manque : plusieurs PR, CI en échec ou en cours, aucune PR
prête, ou livraison d'un autre ticket en cours (une seule à la fois, avec « Ouvrir le ticket
#K »). Une PR qui modifie `.github/`, `.claude/`, `deploy.ps1`, `firebase.json`, ou un fichier
nommé `CLAUDE.md`, `CLAUDE.local.md` ou `.mcp.json` où qu'il soit, est refusée sans décompte : elle se fusionne à la main. La fiche ajoute « Ouvrir la PR #M » et
une section « Livraison (N) » avec les comptes rendus de la session (« Blocage du … »,
« Livraison terminée le … ») ; après un blocage ou trois heures sans fusion, « Relancer la
livraison ». La liste porte une puce « PR prête ». Une livraison compte comme un lancement
dans le plafond du jour. Rien ne change pour les membres.

### v0.23.75 — technique

Nouvelle callable `launchTicketDelivery` (routine de développement, texte `livraison #N`,
mêmes secrets, aucun nouveau jeton). Contrôles avant tout comptage : PR éligible unique,
fichiers sensibles (`GET /pulls/{n}/files`, `delivery_sensitive_files`), dernier run « CI »
vert relu, verrou global `app_config/tickets_status.delivery_running`. Nouveau sous-document
`tickets/{id}/admin/delivery` (état « PR prête » et comptes rendus `## Livraison — …`), écrit
par le webhook (`pull_request` élargi, nouvel événement `workflow_run`), la tâche horaire et
le lancement ; aucune règle Firestore nouvelle (joker `admin/{doc}`), sept tests de règles
ajoutés. Logique dupliquée : `ticket_decisions.json` gagne `can_deliver`, les cas
`livraison` de `launch_runs` (fin par blocage), les sections `launch_actions` et
`delivery_lock`, et `delivery_sensitive_reason` ; corrigée des deux côtés (`rules.ts`,
`ticket.dart`, `ticket_launch.dart`, `ticket_delivery.dart`). Réglages GitHub faits à la main :
permission « Actions : Read-only » sur le jeton « KassDalle ticket », événement « Workflow
runs » du webhook. Reste à faire après le déploiement : recoller le prompt de la routine de
développement (aiguillage `developpement` / `livraison`). `CLAUDE.md` : règles de
`livraison #N`, et l'appui sur « Livrer » vaut « fusionne ». Après la relecture `securite` :
fichiers sensibles élargis à tout `CLAUDE.md`, `CLAUDE.local.md` et `.mcp.json` ; PR éligible
seulement si son corps ne ferme que l'Issue du ticket ; le webhook ne relit la livraison que
pour une PR du mainteneur dont la tête est dans le dépôt, cinq Issues au plus par événement,
liste des PR lue une fois ; un 403 de limite secondaire n'est plus classé « jeton refusé » ;
prompt de livraison avec un point L0 (entrées non fiables), une fusion au sha poussé après un
second contrôle des fichiers, et une durée bornée à 2 h 30. Un conflit signalé par GitHub
(`mergeable`) n'éteint plus « PR prête » : le champ n'est plus lu ni stocké, et la session
résout `version:` et le CHANGELOG ou publie un blocage.

### v0.23.74 — fonctionnel

Admin › Tickets : un ticket En cours dont la pull request est fermée sans être fusionnée
revient au statut de ses étiquettes, Validé en général, dans l'heure qui suit. Il restait
auparavant En cours sans limite, avec « Refuser » pour seule action.

### v0.23.74 — technique

`nextTicketStatus` (`tickets/rules.ts`) prend un troisième paramètre `noOpenClosingPr`. Vrai,
il ramène un ticket `in_progress` au statut tiré des étiquettes. `applyGithubUpdate` le passe
quand `openClosingPr` vaut `false`, ce que seul `resyncTicket` (tâche horaire, PR relues dans
la chronologie de l'Issue) écrit. Une chronologie tronquée (plus de cinq pages) laisse
`openClosingPr` indéfini : pas de recul, puisque des tiers peuvent la remplir. Une PR dont le
dépôt manque dans l'événement de chronologie est écartée. Les événements d'Issue du webhook ne
connaissent pas les PR et ne font toujours pas reculer `in_progress`.

### v0.23.73 — fonctionnel

Les plannings affichés se retrouvent sur tous les appareils (ticket #79). La sélection du
sélecteur « Plannings affichés » n'était mémorisée que sur l'appareil : un autre téléphone, le
web ou une réinstallation repartaient du défaut du rôle. Elle est maintenant enregistrée sous
le compte du membre. Une sélection déjà faite sur un appareil est reprise et envoyée à la
première ouverture.

### v0.23.73 — technique

Nouveau document `users/{uid}/preferences/planning_visibility` (`editor`, `reader`,
`updated_at`), avec la règle `isPlanningVisibility` (100 entrées au plus par liste) et ses
tests dans `rules-tests`. `FirestorePlanningVisibilityStore` remplace
`SharedPreferencesPlanningVisibilityStore` comme implémentation par défaut de
`PlanningVisibilityStore` ; les `SharedPreferences` restent en copie locale hors ligne et pour
la reprise de l'ancienne sélection. Aucune Cloud Function ni logique dupliquée touchée.

### v0.23.72 — fonctionnel

Un écran de démarrage affiche « Bonjour {prénom} » à chaque lancement de l'application, pendant 5 secondes ou jusqu'à un appui (ticket #78). Le prénom est le nom préféré du compte, sinon le prénom Google. Sans profil lu au bout de 10 secondes, ou pour un compte non connecté, l'écran affiche « Bonjour » seul. L'écran est un calque au-dessus du routeur (`SplashGreeting`, `lib/core/presentation/`) : aucune route ajoutée, aucune donnée écrite.

### v0.23.71 — fonctionnel

Admin › Gestion des utilisateurs › Comptes : les invitations par e-mail en attente
apparaissent après les comptes, sous « Invités, pas encore connectés (N) ». Chaque ligne
montre l'adresse seule et « Invité, pas encore connecté », ou « Envoi échoué ». Une adresse
qui a déjà un compte n'y figure pas. Appuyer sur la ligne ouvre l'onglet Invitations, qui
garde les actions (renvoyer, annuler). Le compteur « Comptes (N) » ne compte que les comptes.
Ticket #68.

### v0.23.70 — fonctionnel

Admin › Tickets : le compte fondateur peut lancer 50 sessions Claude Code par jour (analyse
et développement confondus), au lieu de 10. Les autres administrateurs gardent le plafond
réglé dans `app_config/tickets.launches_per_day`. Les lancements du fondateur comptent dans
le même compteur du jour. Le compteur et la boîte de lancement affichent « sur 50 » pour lui.

### v0.23.70 — technique

`launchLimitFor` (`tickets/rules.ts`) relève le plafond à `FOUNDER_LAUNCHES_PER_DAY` (50)
quand le compte qui lance est le fondateur, reconnu par `founderUid()` comme pour le
multiplicateur du budget d'IA. Jumeau Dart `ticketLaunchLimitFor`, appliqué par
`ticketLaunchesPerDayProvider` avec `AppUser.isFounder` (affichage seul). Les deux sont
verrouillés par la section `launch_limits` de `ticket_decisions.json`.

### v0.23.69 — technique

Le déploiement automatique n'utilise plus de clé de compte de service. La clé JSON de
`github-deploy`, sans expiration et stockée dans le secret GitHub `FIREBASE_SERVICE_ACCOUNT`,
ouvrait les secrets de Secret Manager et la base à quiconque l'aurait récupérée. `deploy.yml`
s'authentifie désormais par Workload Identity Federation : le job échange son jeton OIDC
contre un accès d'une heure, que Google n'accorde qu'au dépôt `ChinaFred/KassDalle`
(identifiant numérique), sur `master`, dans l'environnement `production`. La clé et le secret
ont été supprimés après le premier déploiement réussi par la nouvelle voie.

Deux réglages de Google Cloud accompagnent ce changement : `Service Account User` n'est plus
accordé à `github-deploy` sur tout le projet, seulement sur le compte d'exécution des
fonctions et sur le compte App Engine par défaut, que la CLI Firebase exige ; la base
Firestore `(default)` refuse désormais d'être supprimée.

### v0.23.68 — fonctionnel

Admin › Tickets : un ticket validé dont la dernière analyse pose des questions est « bloqué ».
« Relancer le développement » disparaît, la fiche dit que l'analyse attend une réponse, et le
serveur refuse ce lancement sans le décompter. Le nouveau bouton « Répondre » publie la réponse
sur l'Issue (`## Précisions de l'administrateur`), retire la validation et remet le ticket à
Reçu ; l'administrateur relance l'analyse, qui cite les précisions, puis revalide. Une réponse
qui contient une adresse e-mail est refusée, dans l'application et sur le serveur.

### v0.23.68 — technique

Nouvelle callable `answerTicketAnalysis`. `admin/analysis` porte `validated_at` (dernier « validé »
du mainteneur, lu sur `/issues/{n}/events`, jamais reculé tant que l'étiquette est posée),
`answer_comment_ids` et la nature `reply` / `unverified_reply` des entrées ; `tickets/{id}` porte
`answer_reset_at`, qui fait ignorer les webhooks en retard après une réponse. La session de
développement ne lit plus que la dernière analyse ; la session d'analyse lit et cite les précisions.
Logique dupliquée : sections `reply_cases`, `awaiting_reply` et coupure `status_changed_at` dans
`ticket_decisions.json`, nouvelle fixture `ticket_answer_text.json`. Les deux prompts des routines
sont à recopier sur claude.ai.

### v0.23.67 — technique

Nouveau document `documentation/handbook-reseau-agents.md`. Il décrit pas à pas comment
reproduire dans un autre projet le réseau d'agents de Kass'Dalle : installation de Claude Code,
squelette de `CLAUDE.md`, format des agents et des skills, hooks, sessions cloud, chaîne de
travail, réglages GitHub (CI, ruleset, environnement `production`), compte de service Google
Cloud, tickets et Routines. Une section décrit la variante d'exploitation sur AWS EKS : rôle
de déploiement par OIDC, ECR, chart Helm, External Secrets, workflow de déploiement.

`CLAUDE.md` ajoute une ligne au tableau « Chaque changement met à jour ses documents » : un
agent, un skill, un hook, `CLAUDE.md`, une Routine ou un réglage manuel de GitHub, Google Cloud
ou claude.ai met à jour le handbook dans le même commit. Aucun code de l'application ne change.

### v0.23.66 — fonctionnel

Admin › Tickets affiche le numéro de l'Issue GitHub : « #N · auteur · date » dans la liste,
« Issue #N » sur la fiche, et dans la boîte « Lancer le développement ». Il fait le lien avec
les sessions de claude.ai/code, qui citent ce numéro.

Pendant l'envoi d'un lancement, « Annuler » devient « Fermer » et reste actif. Fermer ne coupe
pas l'appel : le résultat s'affiche ensuite en message, refus compris. Aucune session lancée ne
peut être arrêtée depuis l'application ; la section Lancements renvoie à claude.ai/code. Un
lancement en cours ne grise plus les boutons d'un autre ticket sur grand écran.

## 2026-10-14

### v0.23.65 — technique

Le job de déploiement de `deploy.yml` tourne dans l'environnement GitHub `production`,
réservé à `master`. Les cinq secrets du déploiement (compte de service Firebase et clé de
signature de l'APK) doivent y être déplacés depuis les secrets du dépôt. Une session lancée
depuis Admin › Tickets pousse sur des branches `claude/…` à partir du texte d'un ticket
public : un workflow ajouté sur une telle branche ne lit plus ces secrets. Seul le prompt de la
routine l'interdisait jusqu'ici. La procédure est dans `TechnicalRequirements.md`,
« Déploiement automatique », avec deux réglages du dépôt qui la complètent (ruleset sur
`master`, jeton des workflows en lecture seule) et le risque accepté : une session de routine
qui fusionnerait une pull request par l'API déclencherait le déploiement.

### v0.23.64 — fonctionnel

Admin › Tickets des membres lance une session Claude Code sur un ticket (ticket #73, lot B).
Sur un ticket Reçu, « Lancer l'analyse » : la session lit l'Issue et publie son analyse sur
GitHub. Sur un ticket Validé, « Lancer le développement » : la session écrit le code et ouvre
une pull request, sans rien fusionner. Une confirmation annonce les lancements restants du
jour (10 pour toute la famille) et rappelle que la session est facturée sur l'abonnement
Claude de l'administrateur, hors du suivi des coûts de l'application.

Un lancement du même type ne repart pas tant que le précédent n'a rien changé au ticket :
1 h pour une analyse, 3 h pour un développement. La barre affiche alors « Analyse en cours
depuis hh:mm » ; passé ce délai, le bouton devient « Relancer ». La nouvelle section
« Lancements » de la fiche donne le résultat et le lien de chaque session ; l'auteur du ticket
ne la voit pas. L'écran affiche « Lancements de sessions : N ce mois-ci · R aujourd'hui sur
10 », et un bandeau quand le jeton d'une routine est refusé. Les bandeaux s'affichent aussi
sur la fiche au téléphone. À 200 % sur un petit écran, la barre de décision suit la fiche en
fin de défilement au lieu de la masquer.

### v0.23.64 — technique

Deux callables admin, `launchTicketAnalysis` et `launchTicketDevelopment`
(`tickets/launch.ts`), appellent l'API des Routines Claude Code par `fetch`
(`tickets/routine.ts`, aucun SDK) : un seul appel, 30 s, corps exact `{"text": "analyse #N"}`
ou `{"text": "developpement #N"}` contrôlé par une expression régulière, aucune relance,
redirection refusée (`redirect: "error"`) pour que le jeton ne parte pas ailleurs. Une réponse
500, 503 ou tout 5xx compte comme un résultat inconnu, comme un délai dépassé : le lancement
est compté et bloque 1 h ou 3 h, et la fiche dit « Claude ne répond pas. Vérifiez sur
claude.ai/code avant de relancer. ». Elles
réutilisent le bail `decision_lease_until` des décisions (`claimDecision`, désormais exporté),
relisent l'Issue avant de lancer, et écrivent une entrée `unknown` dans
`tickets/{id}/admin/launches` avant l'appel : une fonction coupée pendant l'appel laisse une
trace qui bloque comme un succès. Le plafond se compte dans `ticket_quotas/launch_{AAAAMMJJ}` ;
`app_config/tickets_status` reçoit `launches_today`, `launches_month` et
`routine_invalid_since` ; `app_config/tickets.launches_per_day` est borné à 50, au-delà le
réglage est refusé comme illisible. Quatre secrets nouveaux, `TICKETS_ROUTINE_ANALYSIS_ID`,
`TICKETS_ROUTINE_ANALYSIS_TOKEN`, `TICKETS_ROUTINE_DEV_ID` et `TICKETS_ROUTINE_DEV_TOKEN`,
doivent exister dans Secret Manager avant la fusion (une valeur vide suffit). Aucun appel de
modèle facturé au projet : pas de poste d'IA.

Logique dupliquée : `ticket_decisions.json` couvre les deux lancements (cases
`can_launch_analysis`, `can_launch_development`), la règle « en cours » (section
`launch_runs`) et le plafond par défaut ; `rules.ts` (`launchPrecondition`, `launchRunState`)
et `ticket.dart` / `ticket_launch.dart` (`adminTicketDecisions`, `ticketLaunchRunState`) la
rejouent. `ticketsTokenInvalidSinceProvider` est remplacé par `ticketsStatusProvider`. Les
règles Firestore ne changent pas ; `rules-tests` vérifie que l'auteur ne lit pas
`admin/launches`. CLAUDE.md, section « Tickets », reçoit le point « Session lancée depuis
l'application », et TechnicalRequirements.md la procédure de création des deux routines et
leurs prompts. Le prompt de développement exige un `validé` posé après la dernière analyse
retenue (sinon « ## Analyse — compléments », revalidation nécessaire) et ne compte que les
pull requests ouvertes depuis le dépôt lui-même. La fiche se redessine à l'échéance d'un
lancement en cours pour proposer « Relancer » ; la hauteur sous laquelle la barre de décision
suit la fiche devient `PlatformUtils.pinnedActionBarMinHeight`.

### v0.23.63 — technique

GitHub affiche le code d'un fichier HTML, pas la page. Les liens vers les quatre documents
HTML de `documentation/` dans `README.md` et `documentation/README.md` pointent désormais
sur leur page rendue par raw.githack.com, depuis `master`, avec le fichier du dépôt en lien
« source ». `CLAUDE.md` en fait une règle (« Documentation à tenir à jour »), et
`relecteur-regles` la vérifie au contrôle 10.

### v0.23.62 — fonctionnel

Admin › Tickets des membres permet de valider et de refuser un ticket sans passer par GitHub
(ticket #73, lot A). « Valider » n'existe que pour un ticket Analysé qui n'est pas une
Question. « Refuser » vaut pour un ticket Reçu, Analysé, Validé ou En cours : le motif, 5 à
2 000 caractères, est publié sur GitHub et le membre le lit sous « Motif du refus ». Les
boutons sont dans une barre fixée en bas de la fiche, et un bouton qui ne s'applique pas est
masqué.

La fiche affiche aussi les analyses de l'administrateur publiées sur l'Issue (« ## Analyse… »),
en Markdown, dix au plus. L'écran s'ouvre sur le filtre « À traiter » (tickets Reçus ou
Analysés), depuis la tuile d'Administration et depuis la nouvelle entrée « Tickets à traiter
(N) » du menu du compte. Leur nombre allume le point de la puce du compte de l'administrateur.

Admin › Backfills gagne le ponctuel « Analyses des tickets », qui relève les analyses déjà
publiées. À lancer une fois après le déploiement.

### v0.23.62 — technique

Deux callables administrateur, `validateTicket` et `refuseTicket` (`tickets/decisions.ts`) :
étiquette `validé`, ou commentaire « Réponse : motif » puis fermeture `not_planned`, et
écriture du statut sans attendre le webhook. Le refus prend un bail `decision_lease_until` de
deux minutes, partagé avec la validation, et ne republie pas un motif déjà publié après un
échec partiel, signalé par `reply_published_close_failed`. La validation n'écrit `validated`
que si le ticket est encore `analyzed`. Les conditions des deux décisions et la valeur de
l'échec partiel sont en double entre le client et le serveur : nouvelle fixture
`test-fixtures/ticket_decisions.json`, rejouée par les deux suites. `tickets/github.ts` gagne trois appels REST (étiquette,
commentaire, fermeture), toujours sans SDK.

Nouveau sous-document `tickets/{id}/admin/analysis` (`analyses`, `checked_at`), écrit par le
serveur seul et lu par l'administrateur seul (règle Firestore et six tests d'émulateur). Il est
réécrit par le webhook à chaque commentaire du mainteneur, `deleted` compris, par la tâche
horaire depuis les commentaires qu'elle lit déjà, et après chaque décision. Le webhook monte
désormais `GITHUB_TICKETS_TOKEN` pour relire les commentaires. Backfill ponctuel
`ticket_analyses` (`backfillTicketAnalysesFn`) ajouté aux deux registres et à la fixture
`backfill_schedule.json`. Aucun appel d'IA, aucun poste de coût.

## 2026-10-13

### v0.23.61 — fonctionnel

Admin › Backfills propose « Déplacer mes repas vers un groupe ». La tuile demande d'abord le
groupe, parmi les groupes actifs dont l'administrateur est propriétaire, et une période de
62 jours au plus, puis confirme (« Déplacer vos repas du … au … vers « … » ? »). Les repas
de « Mon planning » de la période passent dans le planning du groupe et quittent le planning
personnel. La recette, la date, les parts et les événements d'agenda déjà exportés ne
changent pas. Un repas déjà dans un groupe est laissé tel quel, et relancer ne refait rien.
La reprise sert pour d'autres périodes : elle reste parmi les ponctuels à lancer, sans
« Marquer comme terminé » dans son menu. Avec un seul groupe possible, il est déjà choisi.

### v0.23.61 — technique

Nouveau callable `backfillMoveMealsToGroupFn` (`requireAdmin`, `runBackfillFromCallable`),
backfill ponctuel `move_meals_to_group` inscrit aux deux registres et à la fixture
`backfill_schedule.json` (`uses_ai: false`, sans programmation). L'entrée
`{ groupId, fromDay, toDay, startAt, endAt }` est validée : identifiant sûr, jours
`AAAA-MM-JJ`, 62 jours au plus, bornes calculées dans le fuseau de l'appareil et à moins de
quatorze heures des jours annoncés. Le serveur vérifie que l'appelant est `owner_id` du
groupe, sélectionne ses repas (`uid ==` appelant, `planned_at` dans la période, `group_id` nul
ou absent) et pose `group_id`, un repas à la fois, dans une transaction qui relit le groupe
(présent, `owner_id` = appelant) et le repas (toujours personnel) ; un groupe supprimé ou
cédé pendant le passage l'arrête (`groupeIndisponible`). Il n'écrit ni `uid`, ni les parts,
ni les recettes. Le compte rendu, lisible par tout administrateur dans
`app_config/backfill_run_move_meals_to_group`, ne porte que des identifiants et des jours :
ni nom de groupe, ni titre de recette. La passe rend un reste inconnu (`remaining: null`) :
un outil réutilisable n'est jamais marqué terminé tout seul, et le menu ⋮ de sa tuile ne le
propose pas (`reusable`). `group_planning_reach` et `move_meals_to_group` partagent leur
verrou (`LOCK_GROUPS`) : tous deux écrivent `planned_meals.group_id`. Aucune
règle Firestore ne change : `group_id` reste figé côté client, l'Admin SDK passe outre.

### v0.23.60 — fonctionnel

#### Les messages en bas d'écran se ferment de nouveau (ticket #69)

Depuis Flutter 3.29, un message en bas d'écran qui porte un bouton (« Voir », « Annuler »,
« Réessayer », « Ouvrir »…) restait affiché tant qu'on n'agissait pas : sa durée était ignorée
et rien ne permettait de le fermer. Un tel message reste maintenant 8 secondes, le temps de
lire puis d'atteindre le bouton, et une croix le ferme plus tôt. Avec un lecteur d'écran
actif (TalkBack, VoiceOver), il reste jusqu'à ce qu'on agisse ou qu'on le ferme. Le libellé
du bouton prend la couleur du texte, plus lisible sur les fonds de succès et d'erreur. Seize
messages sont concernés : ticket envoyé, planning, liste de courses, fiche recette,
brouillons, import par URL, recette générée.

### v0.23.59 — fonctionnel

Admin › Backfills dit mieux ce qui reste à faire dans les backfills récurrents.

« Reprendre la nutrition » n'affiche plus « Terminé » quand des recettes reprises restent
incomplètes. Le résumé donne les recettes encore incomplètes, et non plus « 0 restante ». Il
ajoute, s'il y en a, les recettes laissées faute de temps, sans reprise possible, et
abandonnées après cinq reprises.

La liste « à revoir » de la nutrition donne la cause. Elle sépare les lignes impossibles à
peser (quantité illisible, pas de poids à la pièce, unité sans poids) des ingrédients sans
valeurs pour 100 g. Un calcul en échec cite sa raison. Les recettes abandonnées et celles
qu'aucun appel ne peut compléter y figurent aussi.

Le passage programmé ne reprend plus une recette sans reprise possible : il ne lui manque que des
lignes impossibles à peser, ou des ingrédients que l'IA a manqués trois fois. Après la
correction d'un poids dans un référentiel, le passage manuel la reprend.

« Enrichir unités et ingrédients », « Allergènes » et « Rôle des recettes » ne redemandent
plus à l'IA un élément qui a échoué trois fois. Il apparaît « Plus redemandé à l'IA après 3 échecs » dans la
liste « à revoir ». La confirmation propose une case « Réessayer aussi les éléments exclus
après 3 échecs ». L'enrichissement à l'écriture d'une recette et le rattrapage de la nutrition
ne redemandent plus non plus un ingrédient ou une unité exclus, et le classement du rôle à
l'écriture ne redemande plus une recette exclue. Une recette exclue dont on modifie le titre,
les ingrédients ou les étapes est de nouveau classée, et son compteur d'échecs repart à zéro.

Un passage qui a tout parcouru mais laisse des échecs s'affiche « Incomplet », avec « N
éléments en échec, nouvel essai demain à 05:00 » quand une programmation est active, et « N
éléments en échec. Relancez pour réessayer. » sinon. Il ne repart pas l'heure suivante.

« Recalculer les produits d'achat », « Allergènes » et « Rôle des recettes » lisent le type
de page dans le CookLang quand le champ manque. Une page non-recette n'est plus listée à
revoir.

### v0.23.59 — technique

`PassSummary` gagne `unresolved` : les éléments traités et restés en échec, non exclus.
`passStatus` ne rend `termine` que si `unresolved` vaut 0. `repriseDueAfter` ne change pas :
seul un parcours inachevé déclenche la reprise horaire. Le runner écrit `echecs_restants`
dans `app_config/backfill_run_<clé>`.

L'instantané `nutrition` gagne `missing_weight` (`{name, cause}`) et `missing_profile`.
`missing_ingredients` reste l'union des deux. `catchUpDecision` remplace
`needsNutritionCatchUp`, supprimée, et rend `reprendre`, `ignorer`, `abandonnee` ou
`non_reprenable`. L'instantané porte aussi `missing_profile_excluded` : les ingrédients sans
valeurs dont le référentiel porte `enrichment_failure_count` ≥ 3. Une recette qui n'attend
plus que des lignes impossibles à peser et de tels ingrédients est sans reprise possible
(`nothingLeftToAsk`).

`ENRICHMENT_RETRY_AFTER_MS` passe de 24 h à 20 h, la valeur de `MIN_SNAPSHOT_AGE_MS`. Avec
24 h, le passage quotidien de 5 h trouvait la marque d'essai de la veille encore fraîche un
jour sur deux. La reprise avait lieu sans appel et consommait une tentative. Ce délai vaut
aussi à l'écriture d'une recette : une question sans réponse y est reposée après 20 h.

Mémoire des échecs (`backfills/failureMemory.ts`) : `ai_weight_failure_count`,
`enrichment_failure_count`, `allergens_failure_count` et `allergens_attempt_at`,
`meal_role_failure_count` et `meal_role_attempt_at`. Exclusion à 3, levée par `retryExcluded`.
`enrichUnknownIngredientsWithAI` et `enrichUnknownUnitsWithAI` respectent l'exclusion
(`ingredientEnrichmentAllowed`, `unitWeightRequestAllowed`) ; seule la phase 1 du backfill
passe `retryExcluded`. `syncRecipeMealRole` ne demande plus le rôle d'une recette exclue, ni
pour une écriture qui ne change que `meal_role_failure_count` et `meal_role_attempt_at`
(`mealRoleCallAllowed`) : chaque échec du backfill coûtait un second appel au déclencheur.
Une écriture qui change `titre`, `draft_cooklang` ou `raw_cooklang` lève l'exclusion et remet
`meal_role_failure_count` à 0 avant l'appel (`mealRoleContentChanged`,
`mealRoleFailureResetNeeded`).
L'examen des allergènes à l'écriture d'une recette (`allergens_auto`) écarte aussi un
ingrédient à trois échecs : il ne le redemande plus à chaque écriture.

Règles Firestore : `nutrition_catch_up_attempts`, `meal_role_failure_count` et
`meal_role_attempt_at` deviennent serveur seul sur `recipes` (`serverOnlyRetryFields`), à la
création comme à la mise à jour, administrateur compris. Aucune écriture du client ne les
recopie. Tests bloquants dans `rules-tests`. Aucun poste d'IA nouveau. Les champs se créent au
premier échec : aucun backfill à lancer.

`shoppingBackfillCallable`, `recipeRolesBackfillCallable` et `allergensBackfillCallable`
lisent le type de page par `resolvePageType`.

### v0.23.58 — fonctionnel

Les membres d'un groupe suggèrent des plats au propriétaire. Tout membre d'un groupe actif
autre que son propriétaire, lecteur compris, ouvre « Suggérer un plat » sur un jour
d'aujourd'hui ou à venir du planning du groupe, ou « Suggérer pour un planning de groupe »
depuis une fiche recette : une recette qu'il lit ou un nom libre, et un mot facultatif. Une
recette privée se suggère par son titre : le propriétaire le lit, sans ouvrir la fiche. Cinq
suggestions au plus par membre, par groupe et par jour. L'auteur voit sa suggestion sous les
repas du groupe et la retire ; il ne voit pas celles des autres. Le propriétaire lit le nombre
de suggestions des jours à venir sur le bouton « Suggestions des membres », un repère
« 2 suggestions » sur le jour, et une fenêtre qui les range par jour, avec « Planifier ce
jour-là ». Pas de statut : le propriétaire planifie lui-même ce qu'il retient, et « Au
planning » s'affiche quand le planning du groupe reprend déjà le plat. Rien n'est purgé ; un
groupe supprimé emporte ses suggestions, un membre qui sort emporte les siennes. Pas de
notification, aucun appel d'IA.

Après relecture : on suggère d'aujourd'hui à 59 jours après ; une recette que le
propriétaire lit s'affiche sous son titre actuel ; les messages de la fenêtre des
suggestions (« Repas planifié… », « Suggestion retirée. », avec « Annuler ») s'affichent
dans la fenêtre ; un repère sur un jour passé ouvre la fenêtre sur ce jour, jours passés
dépliés ; un membre sans repas sur la période garde la liste des jours pour suggérer ;
« Reçues (n) » et « Envoyées (n) » comptent les jours à venir ; « Voir les plus anciennes »
vient directement sans jour passé, et dit « Aucune suggestion plus ancienne. » ; une
erreur de lecture des recettes se dit dans la feuille.

### v0.23.58 — technique

Nouvelle collection `meal_suggestions` (`group_id`, `group_owner_id` dénormalisé et vérifié
contre le groupe, `author_uid`, `day` en `AAAA-MM-JJ`, `recipe_id` + `recipe_titre` copié ou
`free_title`, `note`, `created_at` du serveur). Règles : création par un membre d'un groupe
actif (`planning_reach.group_ids` et `member_ids`), pas le propriétaire, forme fermée et
bornée ; lecture et suppression par l'auteur ou le propriétaire ; aucune mise à jour. Tests
dans `rules-tests/test/mealSuggestions.test.mjs`. Quatre index composites (`group_owner_id` ou
`author_uid`, avec `day`). `syncGroupReach` supprime les suggestions d'un groupe supprimé et
celles d'un membre sorti (`deleteGroupSuggestions`, `deleteMemberSuggestions`,
`departedMembers`, `groupMeals.ts`), journalisées par `logError` en cas d'échec et rejouées.
Côté client : `MealSuggestionRepository`, `meal_suggestion.dart`, la feuille
`suggest_meal_sheet.dart`, la fenêtre `meal_suggestions_window.dart` ; `addMeal` rend
l'identifiant du repas (pour « Annuler ») et `RecipePickerSheet` reçoit `initialQuery`.
Aucune migration : la collection est neuve.

Revue sécurité : le volume est borné par les règles. L'identifiant d'une suggestion est
imposé, `{group_id}_{auteur}_{day}_{0..4}` (`suggestionIds`), ce qui tient le plafond de cinq
par auteur, groupe et jour côté serveur ; `day` doit être une date réelle, de la veille à
J+60 (`isSuggestionDay`). Les flux du client ont une borne haute et une limite de 500.
`PlanningRepository.readableRecipeTitles` rend le titre actuel des recettes lisibles.
`suggest()` signale aussi au rapport un brouillon invalide.

### v0.23.57 — fonctionnel

#### Signaler ou proposer : les tickets de la famille

Le menu du compte gagne « Signaler ou proposer » et « Mes tickets ». Un membre approuvé
signale un bug, propose une évolution ou une nouvelle fonctionnalité, ou pose une question.
Une capture est facultative. Le ticket devient une Issue du dépôt GitHub, qui est public :
seuls le titre, la description, le type, la version, la plateforme et l'écran (sans
identifiant) y partent ; le nom, l'email et la capture restent dans l'application. « Mes
tickets » suit le statut (Reçu, Analysé, Validé, En cours, Livré, Refusé, Répondu) et affiche
la réponse de l'administrateur ; un point sur la puce du compte signale un changement. Plafond :
5 tickets par jour et par membre, 30 pour la famille. Admin › Tickets des membres liste tous
les tickets, leur auteur et leur capture, signale un jeton GitHub invalide et relance un envoi
en anomalie.

### v0.23.57 — technique

#### Tickets : callables, webhook GitHub et reprise horaire

`submitTicket`, `attachTicketScreenshot` et `retryTicketSend` (callables),
`githubTicketWebhook` (HTTPS, signature HMAC vérifiée) et `ticketsSyncSchedule` (horaire).
Collections `tickets` et `ticket_quotas`, documents `app_config/tickets` et
`app_config/tickets_status`, captures sous `tickets/{uid}/{ticketId}/`. Deux secrets à créer
avant le déploiement : `GITHUB_TICKETS_TOKEN` et `GITHUB_WEBHOOK_SECRET`. Aucun appel d'IA.
`CLAUDE.md` reçoit une section « Tickets » : analyse en commentaire, traitement des seules
Issues `validé`, texte d'un ticket traité comme une entrée non fiable.

### v0.23.56 — fonctionnel

Un planning est désormais personnel, ou celui d'un groupe familial. Le propriétaire du
groupe, éditeur ou administrateur, y planifie seul : « Nouveau planning » demande « Planifier
pour… » dès qu'il possède un groupe, un jour libre propose « Rien de prévu pour Famille
Dupont », et la feuille « Planifier » d'une recette porte une ligne « Planning ». Tous les
membres du groupe lisent son planning, lecteurs compris, marqué de l'icône et du nom du
groupe ; un invité ne le lit pas. Les suggestions de repas par les membres ne font pas partie
de cette version. Un repas de groupe se met aux courses comme les autres, et le décompte d'un
ajout nomme le groupe. Un lecteur ne supprime plus ses anciens repas : il les relit et les
ajoute à ses courses. Un groupe dont le propriétaire n'est plus éditeur est mis en pause pour
tous ses membres, sans rien effacer : son planning est masqué, ses livres ne sont plus partagés
par lui, et ses invitations en attente sont masquées aux invités. L'écran Groupes le liste
marqué « En pause » : son propriétaire y retire un membre, annule une invitation ou le
supprime, un membre le quitte. Dans le planning, le propriétaire lit « Votre groupe … est en
pause. », un membre « Le groupe … est en pause » avec le nom de son propriétaire, et un membre
de plusieurs groupes en pause les lit tous nommés ; tout revient s'il redevient éditeur. Dans
« Partager mon planning », un groupe en pause reste cochable, et dit que les repas seront
visibles quand il reprendra. Un planning personnel partagé ne montre plus les repas des groupes de
son propriétaire. La feuille « Planifier » d'une recette enregistre le repas avant de poser
l'événement (« Ajouter au planning et à l'agenda ») et nomme le planning visé. Le titre d'une
recette privée planifiée pour un groupe se lit sur le repas ; la recette reste fermée.

Après le déploiement, un administrateur lance **Admin › Backfills › « Portée des groupes et
des plannings »**, et le relance tant qu'il indique « incomplet ». Jusqu'à ce passage, les
membres des groupes existants ne lisent pas le planning de leur groupe, et les plannings
personnels partagés n'affichent aucun repas antérieur.

### v0.23.56 — technique

`planned_meals` reçoit `group_id` (`null` pour un repas personnel, toujours écrit par le
client) ; seul le propriétaire du groupe écrit un repas qui le porte (`ownsMealGroup`), le
champ est figé, et la suppression d'un repas exige `isEditor()`. `planning_reach` reçoit
`group_ids` (groupes actifs dont le compte est membre, lus par les règles) et
`masked_group_ids` (groupes dont le propriétaire ne planifie plus). Le partage personnel ne
lit que `group_id == null` : la règle porte `resource.data.group_id == null`, car la forme
`.get('group_id', null)` laissait une requête `uid ==` sans filtre ramener les repas de
groupe. La lecture d'un repas de groupe exige aussi que son `uid` soit le propriétaire actuel
du groupe (`get(groups/{group_id}).owner_id`) : un groupe recréé sous le même identifiant par
un autre compte n'ouvre pas les repas de l'ancien ; le client filtre donc `group_id` et `uid`.
Un index composite `uid` + `group_id` + `planned_at` sert le planning partagé et celui d'un
groupe. Un groupe masqué sort aussi de `group_reach` : les livres qu'il ouvrait cessent
d'être lisibles, sans vérification de plus dans les règles des livres. `planning_reach` reçoit
aussi `masked_invitation_ids` (invitations vers un groupe en pause, masquées par le client),
recalculé pour les invités ajoutés ou retirés (`invitationsToResync`) et pour ceux des groupes
d'un compte dont le rôle change. `planning_config.group_portions` (parts par défaut de chaque
groupe possédé) est borné à 50 entrées par `isPlanningConfig`.
`syncPlanningReachOnRole` passe dans `triggers/plannerRole.ts` et recalcule les membres des
groupes possédés ; `syncGroupReach` supprime les repas d'un groupe supprimé
(`deleteGroupMeals`). `suggestMealPlanFn` accepte `groupId`, vérifie que l'appelant est
propriétaire du groupe et l'écrit dans `planning_runs.group_id` ; aucun poste d'IA de plus.
Nouveau backfill ponctuel `group_planning_reach` (`backfillGroupPlanningReachFn`) : il
recalcule les deux portées de chaque membre et de chaque invité de groupe, puis pose `group_id: null` sur les
repas antérieurs depuis un point de reprise (4 000 par passage). `showAdaptiveSheet`
(`core/presentation/adaptive_sheet.dart`) sert la feuille « Planifier pour… » et l'éditeur
de programmation des backfills.

### v0.23.55 — fonctionnel

La liste de courses devient un panier personnel, le même sur tous les appareils : « Mes
courses », dans la barre du planning, avec le nombre d'articles à acheter. Elle n'expire plus
d'un jour à l'autre. Chaque repas d'un planning affiché propose « Ajouter aux courses », y
compris les repas partagés par un autre membre, et « Ajouter la période aux courses » prend
les repas à venir de tous les plannings affichés. Un lecteur y a droit comme un éditeur : les
produits vont toujours dans le panier de celui qui les ajoute. Quand le panier n'est pas vide,
une boîte propose « Ajouter » (l'ancien « Enrichir ») ou « Remplacer », avec « Annuler » après
un remplacement. La feuille « Mes courses » retire les articles cochés ou vide la liste, sur
confirmation. Une recette sous cadenas dans une période s'annonce « Recette non partagée » ;
ses ingrédients ne sont pas comptés. Sur la fiche recette, le bouton devient « Ajouter aux
courses » et alimente le même panier.

### v0.23.55 — technique

Le panier quitte `SharedPreferences` pour `users/{uid}/shopping/current` : une carte
d'articles (300 au plus) indexée par la clé produit, pour qu'une case cochée n'écrive que son
champ et parte hors ligne. Ajouter et Remplacer passent par une transaction. Au premier
lancement, une liste locale `sl_items_{uid}` est reprise si le panier est vide, puis effacée.
`firestore.rules` : bloc `users/{uid}/shopping/{docId}`, `current` seulement, titulaire
approuvé seul (l'administrateur n'y a pas accès), forme vérifiée par `isShoppingCart`. Les
quantités suivent les parts du repas (`planningScaleRecipeForMeal`) sans écrire dans la
recette. Tests : `rules-tests/test/shopping.test.mjs`, `shopping_cart_test.dart`,
`shopping_cart_widgets_test.dart`.

### v0.23.54 — fonctionnel

Seuls un éditeur et un administrateur créent un groupe familial. Un lecteur rejoint le
groupe d'un proche sur invitation : le bouton « Créer un groupe » ne lui est plus proposé,
et son écran vide dit « Vous rejoignez un groupe sur invitation d'un proche ». Jusqu'ici
tout compte nommé ouvrait un groupe, y invitait qui il voulait et lisait les livres de ceux
qui acceptaient, alors que le rôle lecteur n'ouvre rien d'autre que la lecture.

Un lecteur propriétaire d'un groupe créé avant cette version n'y invite plus personne et ne
le renomme plus : la recherche et « Renommer » lui sont masqués, et la feuille des membres
dit « Seul un éditeur invite de nouveaux membres et renomme le groupe. ». Il garde ce qui
réduit son groupe : annuler une invitation en attente, retirer un membre, supprimer le
groupe. Les membres de ce groupe restent membres, acceptent ou refusent une invitation et
quittent le groupe comme avant. Le menu d'un groupe affiche « Gérer les membres » au
propriétaire et « Voir les membres » aux autres membres. Les règles laissent un administrateur gérer tout groupe ; l'écran ne lui offre ces gestes que sur ses propres groupes.

### v0.23.54 — technique

`firestore.rules`, collection `groups` : la création exige `isEditor()`. `isManagement()`
(renommer, inviter) exige `isEditor()` en plus de la propriété ; un administrateur passe
toujours. Une nouvelle écriture `isShrinking()` laisse le propriétaire, quel que soit son
rôle, ne faire que réduire son groupe : `invited_ids` et `member_ids` ne perdent que des
comptes, le propriétaire reste membre, le nom ne change pas. Acceptation, refus, sortie et
suppression par le propriétaire ne changent pas. La callable `findMemberByEmailFn` passe de
`requireAuth` à `requireEditor`, pour refuser la recherche par adresse au lecteur
propriétaire d'un ancien groupe, que la règle empêche déjà d'inviter. `rules-tests` : le
groupe `g1` des données de test appartient désormais à l'éditeur, un groupe `g-reader`
représente un groupe de lecteur créé avant la v0.23.54, et une suite « groupes — rôle
éditeur requis » couvre création, gestion, réduction, suppression, sortie et acceptation
selon le rôle. Aucune donnée à reprendre : les groupes existants restent tels quels.

### v0.23.53 — fonctionnel

Préférences reçoit une section « Apparence » : le thème se choisit entre « Appareil », « Clair »
et « Sombre ». « Appareil » reste le défaut et suit le mode du téléphone, de l'ordinateur ou du
navigateur, comme avant. Le choix s'applique tout de suite et se mémorise sur l'appareil
(`SharedPreferences`, clé `theme_mode`), pas dans le compte : chaque appareil garde le sien. La
section reste utilisable quand les préférences du compte ne se chargent pas.

### v0.23.52 — technique

Trois backfills ponctuels sortent du code. Ils ont été menés au bout et marqués terminés en
production : « Protéine et féculent des plats » (`backfillRecipeProteinFn`), « Durées
estimées » (`backfillEstimatedTimesFn`) et « Contraintes de variété par défaut »
(`backfillPlanningDefaultsFn`).

Les trois callables, leurs méthodes de `GcpBillingRepository`, leurs tuiles et
`RecipeProteinBackfillReport` sont supprimés. Les clés `recipe_protein`, `estimated_times` et
`planning_defaults` quittent les deux registres et la fixture `backfill_schedule.json`. Code
devenu mort, supprimé aussi : `suggestMainProteinStarch`, `hasBothMainIngredients` et
`MAIN_INGREDIENTS_CHECKED_FIELD`.

Les postes `backfill_recipe_protein` et `backfill_time_estimate_batch` quittent
`ROUTABLE_FEATURES` et restent au catalogue comptable. Les documents
`app_config/backfill_run_<clé>` et les points de reprise restent en base. Plus rien ne les
lit, et l'écran ignore une clé absente du registre.

L'aide sous les listes « Protéine principale » et « Féculent principal » disait « il sera
proposé par l'IA ». Plus aucun traitement automatique ne la redemande pour une recette déjà
classée : elle dit maintenant « « Suggérer les tags » peut le proposer ».

Le déclencheur `onRecipeWritten` continue d'estimer les durées et de classer les recettes
neuves. Un compte sans contraintes enregistrées lit toujours `kDefaultGlobalConstraints`.

## 2026-10-12

### v0.23.51 — fonctionnel

Un administrateur peut inviter par e-mail une personne dont il a révoqué l'accès. Son compte
reste révoqué jusqu'à ce qu'elle se reconnecte avec le compte Google de l'adresse invitée : son
accès est alors rétabli avec le rôle choisi, et l'invitation au groupe l'attend dans Groupes
familiaux, à accepter. L'écran « accès révoqué » le dit et ouvre le choix du compte Google. Dans
Groupes familiaux, le propriétaire d'un groupe peut aussi chercher une personne par son adresse
e-mail complète : le compte trouvé s'affiche par son nom, jamais par son adresse, dans la limite
de dix recherches par jour.

### v0.23.51 — technique

Nouveau déclencheur `applyRevokedInvitation` (onUpdate `users/{uid}`) : à la reconnexion d'un
compte révoqué (`last_seen_at` changé), il relit dans une transaction l'adresse Auth vérifiée,
l'invitation de retour qui vise ce compte (`target: "revoked"`, `target_uid`), l'invitant et le
groupe, puis rétablit le compte, pose le rôle et l'ajoute à `invited_ids`. `syncUserClaims`
annule les invitations de retour devenues sans objet quand un compte est rétabli à la main. Le
client aligne son jeton sur le document après un changement de rôle ou de révocation
(`TokenClaimsAligner`), et la connexion web par redirection enregistre enfin le compte
(`getRedirectResult`). Nouvelle callable `findMemberByEmailFn` : adresse exacte, propriétaire du
groupe seul, réponse sans adresse, compteur `member_email_search_daily` (10 par jour, alerte à
la cinquième recherche vide, TTL), fermé aux clients.

### v0.23.50 — fonctionnel

Tout compte approuvé a ses quatre livres système : « Mes créations Kass'Dalle », « Mes recettes
libres », « Mes Recettes Secrètes » et « Mes recettes du web ». Jusqu'ici, ils n'étaient créés
qu'à l'ouverture de la bibliothèque par un éditeur ou un administrateur : les lecteurs n'en avaient
aucun. Ils sont désormais créés à l'approbation du compte, ou à l'acceptation d'une invitation par e-mail, lecteurs compris. Pour les comptes déjà
approuvés, une nouvelle reprise *Admin › Backfills › Livres système des comptes* crée ceux qui
manquent. Un livre déjà présent, même renommé, n'est pas recréé. Aucun appel d'IA.

### v0.23.50 — technique

`books/systemBooks.ts` (`ensureSystemBooksFor`) crée les livres système absents d'un compte,
reconnus à leur tag. Les trois livres créés par le client reprennent ses champs ; « Mes recettes
du web » passe par `findOrCreateWebBook`. Deux appelants : `syncUserClaims`, quand le compte
reçoit l'accès (`gainsAccess` : approbation, invitation par e-mail acceptée, levée d'une révocation), et le backfill ponctuel
`backfillSystemBooksFn` (`callable/systemBooksBackfillCallable.ts`, clé `system_books`) pour les
comptes existants. La couverture reste vide : l'écran affiche l'image du livre système, et le
client la dépose à la prochaine ouverture de la bibliothèque par leur propriétaire, s'il est
éditeur ou administrateur ; pour un lecteur, `url_couverture` reste vide.

Les trois livres créés par le client et par le serveur prennent un identifiant fixe,
`kassdalle_{uid}`, `libres_{uid}` et `secretes_{uid}` : à l'approbation d'un éditeur, le
déclencheur et l'application peuvent tourner en même temps, et un livre système en double ne se
supprime pas. Le serveur et le client créent en transaction et ne réécrivent jamais un livre
existant. `firestore.rules` réserve ces identifiants au compte qu'ils nomment, et laisse un éditeur
lire son propre identifiant encore absent, lecture qu'exige la transaction du client. Tests : `tests/systemBooksBackfill.test.ts`,
`tests/authGuards.test.ts`, `rules-tests/test/firestore.test.mjs`.

### v0.23.49 — fonctionnel

Admin › Gestion des utilisateurs gagne un onglet « Invitations » et un bouton « Inviter par
e-mail ». L'admin saisit une adresse, choisit un groupe dont il est membre et un rôle (Lecteur
ou Éditeur), relit un message prérempli, puis envoie. L'e-mail porte le lien vers l'application
et le lien de l'APK Android. À la première connexion Google sous cette adresse, le compte reçoit
le rôle et entre dans le groupe sans attendre d'approbation. Une invitation vaut 30 jours, se
renvoie ou s'annule depuis la liste. Une adresse qui a déjà un compte est refusée : elle garde
le parcours actuel (rôle dans l'onglet Comptes, invitation de groupe à accepter).

### v0.23.49 — technique

Nouvelle callable `manageInvitationFn` (création, renvoi, annulation ; 20 envois par admin et
par jour) qui envoie par SMTP Gmail avec `nodemailer`, chargé par `await import()`. Deux
secrets, `GMAIL_SENDER` et `GMAIL_APP_PASSWORD`, doivent exister dans Secret Manager avant le
déploiement. Nouveau déclencheur `applyEmailInvitation` à la création de `users/{uid}` : il lit
l'adresse vérifiée du compte Auth, relit l'invitant et le document dans une transaction, pose
le rôle et ajoute le compte au groupe. Collections `invitations` et `invitation_sends_daily`,
lisibles par un admin, écrites par le serveur seul. `syncUserClaims` relit `users/{uid}` avant
d'écrire les claims, pour qu'une exécution en retard ne remette pas `pending`, et traite un
document disparu comme une suppression. La création d'un compte exige désormais
`email_verified`. Le statut effectif d'une invitation rejoint la logique dupliquée, avec la
fixture `email_invitation_status.json`.

### v0.23.48 — fonctionnel

La modération d'images compte désormais dans le plafond quotidien d'IA du compte : une image
analysée vaut un appel, et son coût s'ajoute à la dépense du jour. Plafond atteint, l'image
n'est pas publiée et l'écran affiche « Quota atteint — Le service a atteint sa limite pour
aujourd'hui. Réessayez plus tard. », le message de tout `resource-exhausted` ; une photo de page importée par
lien est laissée de côté et la recette est créée sans elle. La relance des images en attente
par l'administrateur n'est pas concernée.

### v0.23.48 — technique

Cinq corrections issues de l'audit `securite`.

- **Cloud Vision dans le plafond quotidien.** `moderateAndPromote` réserve une place par image
  analysée (`withDailyBudget`), au coût de l'analyse lu dans la grille tarifaire
  (`visionAnalysisCostUsd`, nouvelle option `estimateUsd` de `reserveDailyBudget`). Un compte
  pouvait rappeler `moderateAndPromoteImagesFn` en boucle sur sa quarantaine, chaque appel
  déclenchant une analyse facturée. Refus : `resource-exhausted`. Chaque analyse est
  enregistrée par `recordUsage` dès qu'elle est faite, avant que sa place soit rendue
  (`analyseAndRecord`) : une ligne `ai_usage` par image au lieu d'une par lot, et un lot ne
  dépasse plus le plafond de ses analyses en cours. `retryPendingModerationFn` (admin) reste
  hors plafond ; `recordUsage` accepte `dailyCalls` pour qu'elle compte une image pour un
  appel.
- **`normalizeRecipeReferentialsFn`** écrit dans `nutrition_ingredients` : réservée à
  l'éditeur, et au lecteur créateur de la recette `recipeId`
  (`assertCanNormalizeReferentials`). `requireEditor` seul aurait cassé l'enregistrement
  d'une recette par son lecteur créateur, que les règles permettent.
- **`free_recipe_cover_url`** : les règles n'admettent que `null` ou une adresse de
  téléchargement exacte de la modération, `users%2F{uid du document}%2Ffree_recipe_cover_{n}.{jpg|jpeg|png|webp}`
  dans le bucket du projet, 500 caractères au plus (`coverUrlOk`) : ni `..`, ni `%2E`, ni
  `%25`. `publicCoverUrl` applique la même forme à la recopie dans `user_profiles`.
- **`error_reports`** : liste fermée des neuf champs, `user_id` égal à l'appelant, longueurs
  bornées (`isErrorReport`). `context` devient une chaîne JSON, seule forme mesurable par
  une règle ; le client tronque chaque champ à la moitié de la borne. Un contexte illisible
  à la lecture est remonté une fois par rapport (`error_report.parse`). Les rapports anciens
  (contexte en carte) se relisent toujours. Un client antérieur à cette version, qui écrit
  encore une carte, voit ses rapports refusés jusqu'à sa mise à jour.
- **Fondateur** : `isFounder()` exige `email_verified` et une connexion Google ;
  `isFounderAccount` applique le même contrôle dans `enforceFounderRole` et pour le
  multiplicateur de plafond (`founderUid`).

### v0.23.47 — fonctionnel

Le lecteur ne planifie plus : ni repas, ni cycle, ni préférences du planning, ni garnitures,
ni liste des ingrédients du planning, ni conseil de conservation. Ces gestes lui sont masqués,
et `/planning/batch`, `/planning/config` et `/planning/staples` le renvoient au planning avec
« Planification réservée aux éditeurs ». Ses repas antérieurs restent visibles et
supprimables : « Mon planning » reste dans son sélecteur tant qu'il lui reste un repas, décoché
par défaut.

Un éditeur ou un administrateur partage son planning depuis « Préférences du planning »,
section « Partager mon planning » : une case par groupe familial dont il est membre, rien de
coché par défaut. Les membres des groupes cochés voient ses repas en lecture seule, sans ses
courses ni ses préférences. Le partage n'est pas réciproque. Il est suspendu quand le
propriétaire n'est plus éditeur, et reprend s'il le redevient.

L'écran du planning affiche « Plannings affichés » : un bouton-puce sous la barre sur un
téléphone, une carte au-dessus du calendrier sur grand écran. Le lecteur voit par défaut tous
les plannings partagés avec lui, l'éditeur son planning seul ; l'appareil mémorise les
changements. Chaque repas d'autrui porte le prénom de son propriétaire, sans menu, sans heure
modifiable et sans ligne d'origine du choix. Une recette que le lecteur ne peut pas lire
s'affiche par son titre avec « Recette non partagée », sur le planning comme sur une fiche
ouverte par lien. L'écran de réglages s'appelle partout « Préférences du planning ».

### v0.23.47 — technique

Nouvelle collection `planning_reach/{uid}` (`uids`, `updated_at`) : les propriétaires dont
`uid` lit le planning, écrite par le serveur seul (`triggers/planningReach.ts`). Elle est
recalculée par `syncGroupReach` (composition d'un groupe), par le nouveau déclencheur
`syncPlanningReachOnConfig` (`planning_config/{uid}.shared_group_ids`) et par le nouveau
déclencheur `syncPlanningReachOnRole` (rôle ou révocation du propriétaire, `retry: true`).
`membersOf` et `sameReach` passent dans `triggers/groupMembers.ts`. Les champs d'un repas
partagé (`justification`, `choice_source`, `dismissed_recipe_ids`) sont lisibles par
l'audience ; le client ne les affiche pas, ce qui n'est pas une protection (décision
provisoire). Nouveau champ
`planning_config.shared_group_ids` (`List<String>`, 50 au plus). Aucun backfill : sans
`shared_group_ids` rien n'est partagé.

`firestore.rules` : `planned_meals` se lit aussi par un compte nommé dont `planning_reach`
contient le propriétaire (`canReadPlanningOf`) ; création et modification exigent
`isEditor()`, la suppression reste au propriétaire. `planning_config` s'écrit par un éditeur
pour lui-même ; `planning_reach` ne s'écrit par aucun client. `suggestMealPlanFn`,
`suggestStorageAdviceFn` et `consolidateShoppingListFn` passent de `requireAuth` à
`requireEditor`. Le client ouvre un flux Firestore par planning affiché (`uid == propriétaire`),
jamais une requête `in`, et résout la lisibilité des recettes des repas d'autrui par une
lecture groupée. 17 tests de règles ajoutés, 4 réécrits ; tests Functions du calcul de la
portée ; tests Dart du sélecteur, de la redirection et de l'écran.

### v0.23.46 — technique

#### Sauvegardes : état daté et région de restauration

`TechnicalRequirements.md` dit maintenant que les sauvegardes de Firestore sont actives depuis
le 11 octobre 2026, avec une première sauvegarde prête le 12, et que le versionnage de Storage
l'est depuis le 12. La commande de restauration nomme la région `eur3` au lieu d'un
paramètre à deviner. Le fichier `lifecycle.json` se crée dans `$env:TEMP`, plus dans le dépôt.

### v0.23.45 — fonctionnel

Admin › Backfills range ses neuf reprises en trois sections : « Récurrents », « Ponctuels à
lancer » et « Ponctuels terminés ». Chaque tuile affiche l'état de son dernier passage, lu en
direct : terminé, incomplet, en erreur, en cours. Un backfill récurrent se programme depuis
l'écran, par jours et heure de Paris ; un passage incomplet reprend l'heure suivante, jusqu'à
la fin ou jusqu'au plafond de dépense. « Reprendre la nutrition » passe toujours tous les jours
à 5 h, réglable désormais. Un ponctuel passé sans reste est marqué terminé et descend en bas ;
l'administrateur peut aussi le marquer ou le remettre à lancer par le menu ⋮. Lancer un
backfill ne bloque plus l'écran, et deux passages du même backfill ne tournent jamais ensemble.

### v0.23.45 — technique

Chaque backfill est classé dans deux registres, `functions/src/backfills/registry.ts` et
`backfill_registry.dart`. `runBackfillPass` (`backfills/runner.ts`) pose un verrou par backfill
et écrit l'état dans `app_config/backfill_run_<clé>` : statut, origine, compte rendu complet,
`termine_*` pour un ponctuel. Le compte rendu ne s'écrit plus à côté du curseur
(`setBackfillCursor` perd `lastReport`) ; `backfill_reports_repository.dart` et ses deux
providers sont remplacés par `backfill_status_repository.dart`. La tâche `scheduledNutritionCatchUp`
est retirée et remplacée par `scheduledBackfills`, horaire, qui lance les récurrents échus
d'après `app_config/backfill_schedules` ; le défaut de la nutrition (5 h, 20 recettes, bornes
de patience) vit dans les deux registres (`defaultSchedule`), la tâche l'écrit au premier tick,
et l'écran l'affiche « (par défaut) » d'ici là. La passe de
chaque récurrent sort de son callable pour être appelée aussi par la tâche ; en reprise,
l'enrichissement des référentiels saute la phase des unités. Un passage programmé qui appelle
un modèle est imputé au plafond **de base** de l'administrateur qui l'a programmé, sans le
multiplicateur du compte (`runWithBaseBudgetCap`), et ne part pas si cet auteur n'est plus
administrateur ; la nutrition reste imputée au propriétaire de chaque recette.
L'enrichissement des référentiels et la réparation du sel partagent un verrou. Les règles
Firestore refusent l'écriture client sur `app_config/backfill_schedules` et
`app_config/backfill_run_*`, administrateur compris (tests dans `rules-tests`). La fixture
`backfill_schedule.json` verrouille le registre et la lecture stricte d'une programmation des
deux côtés ; l'échéance du verrou est écrite par le serveur (`en_cours_expire_le`). Deux callables admin s'ajoutent, `setBackfillScheduleFn` et `setBackfillDoneFn`. Les
callables existants gardent nom et contrat ; leur réponse gagne `termineAuto`, leur requête
`appVersion`, et un passage déjà en cours renvoie `failed-precondition`. `backfillShoppingFn`
ne déclare plus les deux secrets d'IA, qu'il n'utilisait pas.

### v0.23.44 — technique

La CI ne se rejoue plus en entier sur le push qui fusionne une PR. Un job « Déjà testé en
PR » compare l'arbre du commit poussé à celui de la tête de la PR, vérifie que cette tête
contient la `master` d'avant le push et qu'une CI de PR a réussi dessus. Les jobs Flutter,
Functions et Règles sont alors sautés ; seul le contrôle de version tourne. Sur les cent
dernières exécutions, ces jobs en double représentaient environ 400 minutes Actions
facturées sur 1 450. Le dépôt reçoit aussi un fichier `LICENSE` propriétaire : code
consultable, tous droits réservés, en vue d'un passage du dépôt en public.

### v0.23.43 — fonctionnel

La fiche d'une recette importée depuis un lien affiche l'auteur de la recette, quand la page
le nomme dans ses données structurées : une ligne « Par Marie Dupont » au-dessus du lien
« Source : <site> ». Elle ne s'affiche pas quand l'auteur annoncé est le site lui-même. La copie d'une recette importée garde son auteur. Les recettes importées
avant cette version n'ont pas d'auteur : il faudrait relire chaque page pour le retrouver.

### v0.23.43 — technique

L'import par lien lit deux champs de plus dans le JSON-LD `schema.org/Recipe`, sans appel de
modèle : `author` devient `source_author`, et `nutrition` devient `source_nutrition` (calories,
protéines, glucides, lipides par portion, portions du site, empreinte des ingrédients écrits).
À chaque calcul de la nutrition, `computeAndPersistRecipeNutrition` compare ses valeurs par
portion à celles du site et écrit `source_nutrition_check`. Un écart au-delà d'un facteur 2 est
journalisé en `WARNING` : il signale une conversion d'unité fausse, un ingrédient manquant ou un
`per100g` faux dans le référentiel. La comparaison s'arrête dès que les ingrédients changent, et
n'a pas lieu sous le seuil de couverture partielle. Les règles Firestore traitent
`source_author` comme `source_site`, et réservent `source_nutrition` et
`source_nutrition_check` au serveur. `recipeCategory` n'est pas lu : les tags restent ceux du
balisage.

### v0.23.42 — fonctionnel

« Chercher sur le web » donne la priorité aux recettes en français : Gemini cherche en
français, et les pages rédigées en français passent en tête, l'anglais ne venant qu'en
complément. Le badge « Import direct », qui ouvrait la page au lieu de l'importer, est retiré :
chaque carte n'a plus qu'un bouton « Importer ». Sur Android et iOS, une page — et « Voir sur
Google » — s'ouvre dans un navigateur intégré, au-dessus de l'application. Au retour, la liste
garde sa position : le bandeau d'import qui apparaît se place sous la liste au lieu de
s'insérer en tête et de tout décaler (136 px en test), tient sur une ligne sur téléphone, se
masque quand le clavier est ouvert ou quand il laisserait moins de 120 px à la liste, et la
carte ouverte est ramenée en vue si le bandeau la couvre.

### v0.23.42 — technique

Le serveur relève la langue de chaque page lue (`inLanguage` du JSON-LD, `<html lang>`,
`og:locale`, sinon un indice d'adresse) et trie les résultats de façon stable avant la coupe à
huit : français, langue inconnue, autre langue. La clé de `web_search_cache` passe en version 2
(`sha256("v2:" + requête)`) : les entrées produites avec l'ancien prompt ne sont plus servies,
et la règle d'expiration les efface sous 7 jours ; pendant ce délai, une requête déjà en cache
rappelle le modèle une fois. Le client ouvre les pages par `openWebPage`
(`LaunchMode.inAppBrowserView` sur Android et iOS, avec la requête `CustomTabsService` dans
`AndroidManifest.xml`). Le champ `directImport` reste rendu et journalisé par le serveur, le
client ne le lit plus.

### v0.23.41 — fonctionnel

Explorer affiche les pages de recettes trouvées sur le web, sans quitter l'application. Le
bouton « Chercher sur le web » remplace « Chercher sur Google » et lance une recherche par
appui, jamais à la frappe. Jusqu'à 8 pages s'affichent dans une section « Sur le web » : titre,
site, extrait, et le badge « Import direct » quand la page décrit sa recette de façon
structurée. Tous les rôles peuvent chercher et ouvrir une page dans le navigateur ; l'éditeur
et l'administrateur peuvent aussi l'importer. Vidéos et réseaux sociaux (YouTube, TikTok,
Instagram, Facebook, Pinterest) sont exclus. Chaque compte a 50 recherches par jour ; une
recherche déjà faite par quelqu'un dans les 7 derniers jours est servie sans décompte. Les
cartes affichent une icône et aucune image venue des sites, pour ne pas transmettre l'adresse
IP du lecteur ni afficher une image non modérée. Le bloc de suggestions de Google s'affiche
tel quel, comme l'exigent ses conditions. « Voir sur Google » reste disponible.

### v0.23.41 — technique

Nouvelle callable `searchWebRecipesFn` : Gemini avec l'outil `googleSearch`, liens de Google
résolus jusqu'à l'adresse réelle par `safeFetch`, pages lues pour le titre, l'extrait et le
badge schema.org. Nouveau poste `web_recipe_search`, verrouillé sur Gemini. La grille
tarifaire gagne un prix par appel ancré (`grounded_search_per_unit`, semé à 0,035 $, à
revérifier contre la facture), et les jetons du résultat de recherche sont comptés en entrée ;
la fixture `ai_pricing.json` couvre ces cas des deux côtés. Deux collections serveur :
`web_search_daily` (compteur, lisible par son titulaire) et `web_search_cache` (7 jours, TTL
déclaré dans `firestore.indexes.json`, aucun accès client). La place du jour est rendue
seulement si l'appel au modèle échoue. Nouveaux paquets : `webview_flutter` (Android, iOS,
macOS) et `webview_windows` (Windows, build non vérifié par la CI) ; iframe sans script sur le
web. `describeError` lit désormais le code de `GeminiCallableException`.

## 2026-10-11

### v0.23.40 — technique

Le SDK Gemini des Functions passe de `@google/generative-ai` 0.21 à `@google/genai` 2.28.
L'ancien SDK n'expose pas l'outil `googleSearch`, nécessaire aux résultats web d'Explorer.
Aucun comportement ne change : mêmes modèles, mêmes prompts, même lecture des jetons, mêmes
réessais. `gemini/client.ts` reste le seul fichier qui l'importe, et le charge par
`await import()` au premier appel (environ 100 ms) au lieu du démarrage. L'hôte de l'API est
figé dans le code, pour que les variables `GOOGLE_GEMINI_BASE_URL` ou
`GOOGLE_GENAI_USE_VERTEXAI` ne détournent pas la clé. Le délai d'un appel annule désormais la
requête HTTP : la connexion est fermée et la réponse n'est plus attendue. Un délai dépassé
dont la durée contient « 429 » n'est plus classé en dépassement de quota. La recherche Google et la lecture du
grounding sont préparées dans `client.ts`, sans aucun poste qui s'en serve.

### v0.23.39 — fonctionnel

#### Explorer : une recherche par texte qui filtre vraiment, import après Google

Un mot tapé ne correspond plus qu'au début d'un mot de la recette : « bla » ne trouve plus
« sablé ». Les petits ingrédients (sel, poivre, épices, huile, beurre, vinaigre, eau,
herbes, sucre, farine, ail, oignon) ne sont cherchés que dans les titres. Les résultats se
rangent en trois groupes : « Dans le titre », « Par cuisine, type ou thème », puis « Dans
les ingrédients principaux », replié quand les premiers ont des résultats, avec la ligne
« Avec : … » qui dit l'ingrédient trouvé.

« Demander à l'IA » devient « Chercher avec l'IA ». Le bouton de retouche d'une recette
imaginée devient « Envoyer à l'IA ».

Au retour d'une recherche Google, un éditeur voit « Vous avez trouvé une recette ?
Importez-la. ». Sur Android et Windows, le lien copié est proposé tout de suite. Sur
Android, « Partager vers Kass'Dalle » depuis le navigateur ouvre la boîte d'import avec
l'adresse remplie ; un lecteur voit « Import réservé aux éditeurs ».

### v0.23.39 — technique

#### Recherche par sections, canal de partage Android

`matchRecipeQuery` et `RecipeQuerySection` remplacent `matchesRecipeQuery` : début de mot,
liste de petits ingrédients propre à la recherche (côté Dart seul, `isSeasoning` lu sans
être modifié), sections dans `RecipeFilterOutcome`. Le partage Android passe par un
`intent-filter` `ACTION_SEND` `text/plain` et le canal `dev.kassbi.kass_dalle/share` de
`MainActivity`, sans dépendance Gradle ; `SharedLinkImportHost` attend que le compte soit
chargé avant de traiter le lien. `showUrlImportDialog` reçoit `initialUrl`.

### v0.23.38 — fonctionnel

#### Durées estimées par l'IA

Une recette à qui il manque la durée de préparation ou de cuisson reçoit une estimation de
l'IA. La fiche l'affiche « ≈ Prép. 20 min », avec la mention « Durées estimées par l'IA,
absentes de la recette d'origine. ». Explorer affiche « ≈ 45 min, estimé ». Une durée lue
dans la recette, dans ses champs ou dans son texte, passe toujours avant l'estimation.

Le filtre « Temps total » et le tri « Plus rapides » d'Explorer comptent les durées
estimées, sauf si l'interrupteur « Compter les durées estimées » est décoché. Explorer lit
aussi les durées écrites seulement dans le texte de la recette.

Le backfill « Durées estimées » d'Admin › Backfills estime les recettes existantes, 160 par
passage. À relancer tant que le compte rendu affiche « incomplet ».

### v0.23.38 — technique

#### Champ estimated_times, postes time_estimate

Le champ racine `estimated_times` (`status`, `fingerprint`, `prep`, `cook`) est écrit par
le serveur seul, depuis `onRecipeWritten` et `backfillEstimatedTimesFn`. Les règles le
refusent à tout client. L'empreinte couvre le titre et le texte sans les lignes `>>` : une
recette inchangée n'est jamais réestimée, et une réservation empêche deux appels
simultanés. Deux postes d'IA : `time_estimate` et `backfill_time_estimate_batch` (lots de 8
recettes d'un même auteur). Le backfill pose un verrou daté contre deux passages
simultanés. La lecture des durées d'une recette (champs, puis métadonnées CookLang) est
partagée par la fixture `cooklang_parsing.json`.

### v0.23.37 — fonctionnel

#### Backfills : la liste des éléments à revoir

Un backfill disait seulement « en erreur=17 ». Il ne disait pas lesquels. Désormais, s'il
reste des éléments à revoir, un lien « Voir les N à revoir » s'affiche sous le compte rendu.
La liste donne une ligne par ingrédient, unité, recette ou compte, avec la raison : « Pas de
réponse de l'IA », « Recette incomplète : beurre, farine non examinés »… Un appui ouvre
l'ingrédient dans le référentiel ou la fiche de la recette. Le bouton « Copier la liste » la
copie en texte. Les huit backfills d'Admin › Backfills sont concernés.

### v0.23.37 — technique

#### Backfills : champ `aRevoir` dans chaque réponse

Chaque callable de backfill renvoie `aRevoir` (`{ items, total }`), construit par
`BackfillReview` (`callable/_backfillReview.ts`) : 100 entrées au plus, dans l'ordre de
traitement, et un total compté au-delà. La liste est recopiée dans `last_report` pour les
backfills qui en écrivent un. L'examen des allergènes journalise par `logWarn` les noms des
ingrédients restés sans réponse du modèle. Le skill `backfill` et `CLAUDE.md` imposent la
liste aux backfills futurs.

### v0.23.36 — fonctionnel

#### Le fil d'icônes garde ses icônes pendant une traduction

Pendant la traduction d'une recette écrite dans une autre langue, la ligne de la file de
travail perdait toutes ses icônes et n'affichait plus que « Traduction de la recette par
l'IA… ». L'étape `translate` n'avait pas de jalon dans le fil. Le fil d'une recette traduite
porte maintenant un jalon « Traduction » : avant « Analyse » pour un scan, après « Analyse »
pour un import par lien. Il reste affiché jusqu'à la fin de l'import. Une recette française
garde le fil d'avant.

Le fil d'un import par lien gagne aussi le jalon « Analyse » : le serveur écrit cette étape,
et la ligne perdait ses icônes pendant ce temps.

### v0.23.36 — technique

Nouveau champ `processing_jobs.translated` (`Boolean?`), posé à `true` par le serveur dans la
même écriture que `current_step: "translate"` et jamais retiré. Aucune écriture
supplémentaire. Le client le lit pour ajouter le jalon (`trailFor(type, translated:)`).

### v0.23.35 — fonctionnel

#### Explorer : filtrer sans IA, demander à l'IA sur un bouton

Explorer affiche la liste des recettes dès l'ouverture. Le champ « Titre, ingrédient,
envie… » filtre sur l'appareil à chaque frappe, sans appel d'IA. Quatorze filtres
s'ajoutent, avec le nombre de recettes derrière chaque valeur : type de plat, temps total,
cuisine, rôle dans le repas, protéine, féculent, difficulté, thème, sans l'ingrédient,
sans allergène, livre, auteur, note minimale et calories par portion. Une recette sans la
donnée filtrée est écartée, et l'écran dit combien. Le tri et les filtres sont gardés
d'une visite à l'autre.

« Demander à l'IA » et « Imaginer 3 recettes » ne partent que sur un bouton.
« Chercher sur Google » n'appelle plus l'IA. Les recettes imaginées par l'IA, dans
Explorer comme dans le planning, s'enregistrent en brouillon. Quitter avec des idées non
enregistrées demande confirmation.

Le lecteur ne crée plus de recette : ni saisie, ni copie, ni création par l'IA, ni
import. Il garde la liste, les filtres et Google, et modifie ses recettes existantes.

Le livre « Mes recettes du web » est créé avec les autres livres système, à l'ouverture
de la bibliothèque, au lieu d'attendre le premier import par lien.

### v0.23.35 — technique

#### Filtre partagé, préférences d'Explorer et création réservée

`RecipePickerFilter` du planning devient `RecipeFilter` dans `features/recipes/domain/`,
partagé par Explorer et le sélecteur du planning. Les préférences d'Explorer vivent sous
`users/{uid}/preferences/explore_filters`, de forme bornée par les règles. La règle de
création de `recipes` passe à `isEditor()`. `searchRecipesFn`, `generateRecipeFn`,
`extractRecipeFromTextFn`, `generateRecipeConceptFn` et `suggestMealIdeasFn` passent en
`requireEditor`. `generateWebSearchQueryFn` est retirée ; le poste `web_search_query` sort
du routage et reste au catalogue. Nouvelle callable `ensureWebBookFn` ; les règles
refusent au client tout livre `web…_`, et le repli serveur s'écrit sous `web2_{uid}`.

### v0.23.34 — fonctionnel

#### Couverture de « Mes recettes du web »

Le livre « Mes recettes du web » reçoit sa couverture, l'image `FromTheWeb.png`. Le serveur
crée ce livre sans couverture au premier import par lien. L'application la pose à l'ouverture
suivante de la bibliothèque, comme pour les trois autres livres système. En attendant, la
liste affiche déjà cette image.

### v0.23.34 — technique

#### Versions des fichiers de Storage, empreinte de la nouvelle couverture

`TechnicalRequirements.md` décrit le versionnage du bucket Storage : une version remplacée ou
supprimée reste récupérable 30 jours, puis une règle de cycle de vie la supprime. Les sauvegardes
de Firestore ne couvraient pas les photos ni les scans. La section donne les commandes `gcloud`
à lancer une fois depuis le PC, et la récupération d'un fichier.

L'empreinte SHA-256 de `FromTheWeb.png` rejoint `BUNDLED_ASSET_SHA256` (`moderation/origin.ts`) :
la couverture passe la modération comme les trois autres images livrées avec l'application.

### v0.23.33 — fonctionnel

#### Importer une recette depuis un lien

Un éditeur ou un administrateur colle l'adresse d'une page de recette. Le bouton se
trouve dans Explorer (icône lien), dans Import et dans la saisie manuelle. L'import part
en tâche de fond dans « Brouillons & Traitements ». La recette arrive en brouillon dans
un nouveau livre système privé, « Mes recettes du web », avec la photo de la page après
modération et le texte de la page comme document original. La fiche affiche
« Source : <site> » en lien, et l'adresse complète copiable.

Avant l'envoi, l'écran vérifie l'adresse, le doublon dans ses propres recettes et le
plafond de 10 imports par lien et par jour (multiplié pour le fondateur). Les échecs
s'affichent sur la tuile du traitement avec leurs actions : ouvrir la page, coller le
texte, ou relancer, deux fois au plus.

C'est le premier lot de la refonte d'Explorer.

### v0.23.33 — technique

#### Pipeline d'import par lien

Deux callables, `importRecipeFromUrlFn` et `getUrlImportQuotaFn`, et un type de job
`recipeUrlImport`. La page est lue par `functions/src/web/safeFetch.ts` : DNS filtré au
moment de la connexion, 3 redirections revérifiées, 10 s, 3 Mo après décompression. Le
serveur lit d'abord le JSON-LD schema.org/Recipe sans modèle (borné à 60 000 caractères,
200 ingrédients et 150 étapes), puis le balise en CookLang ; sans JSON-LD, le texte de la
page passe par la chaîne du texte collé. Deux postes d'IA : `url_import` et
`url_import_fallback`.

Nouveaux champs `source_url` et `source_site` sur la recette, immuables, recopiés
seulement par une copie lisible. Nouvelle collection `url_import_daily`. Les règles
refusent au client la création d'un job `recipeUrlImport` et d'un livre `web_…`, et
bornent la relance d'un import par lien à deux. La modération rattache désormais une
photo approuvée à sa recette (`attach_on_approval`).

### v0.23.32 — fonctionnel

#### Allergènes d'une recette

La fiche d'une recette montre ses allergènes sous la liste des ingrédients. Ce sont les
14 allergènes de l'annexe II du règlement INCO. Chaque allergène a sa pastille, et un appui
dessus montre les ingrédients en cause. Le bloc dit « Aucun allergène majeur détecté »
seulement si tous les ingrédients ont été examinés. Sinon, il dit que l'analyse est
incomplète. Un avertissement est toujours visible : « Liste indicative établie par IA. Elle
ne remplace pas la lecture des emballages. »

Dans Admin › Référentiels › Ingrédients nutrition, l'admin voit les allergènes de chaque
ingrédient et les corrige avec 14 cases à cocher. Le nouveau backfill « Allergènes »
d'Admin › Backfills examine les ingrédients pas encore examinés, puis recalcule toutes les
recettes. Le filtre « sans allergène » d'Explorer viendra dans une prochaine version.

### v0.23.32 — technique

#### Allergènes : examen par ingrédient, union sur la recette

Le modèle examine les allergènes une fois par ingrédient du référentiel. Les ingrédients
sont envoyés par lots de 40, avec un schéma JSON fermé et une règle de prudence : en cas de
doute, l'allergène est signalé. Le résultat est écrit dans `nutrition_ingredients`
(`allergens`, `allergens_source`, `allergens_at`). Le modèle ne remplace jamais une valeur
déjà posée, en particulier une correction de l'admin. La recette reçoit un champ racine
`allergens` (`present`, `complete`, `by_ingredient`, `computed_at`), calculé par
`onRecipeWritten` sans appel de modèle. Ce champ ne fait pas partie de l'empreinte des
entrées du déclencheur, donc son écriture ne relance aucun calcul.

Deux postes d'IA sont ajoutés : `allergens_auto` (ingrédients neufs, à l'écriture d'une
recette) et `backfill_allergens`, avec la fonction `backfillAllergensFn`. La règle Firestore
de `nutrition_ingredients` permet à l'admin d'écrire les trois champs d'allergènes. Les
clés et leurs libellés sont partagés par la fixture `allergens.json`.

### v0.23.31 — technique

#### Sauvegardes planifiées de Firestore

Aucune sauvegarde de la base n'existait : une suppression ou un backfill erroné ne se
défaisait pas. `TechnicalRequirements.md` décrit maintenant deux sauvegardes planifiées
gérées par Google Cloud, quotidienne gardée 7 jours et hebdomadaire gardée 14 semaines,
les commandes `gcloud` qui les créent depuis le PC, et la procédure de restauration dans
une base neuve puis de report dans `(default)`. Aucun code ne change.

### v0.23.30 — fonctionnel

#### Nouveau planning : panneau, grille et cartes repliables

Sur grand écran, l'écran « Nouveau planning » montre un panneau de 320 px à gauche. Il contient
le cycle, les consignes du cycle (8 lignes visibles) et les boutons « Planifier avec l'IA » et
« Valider », toujours à portée. Les créneaux occupent le reste de la largeur en colonnes de
560 px au plus : trois colonnes sur un écran de 2 000 px. Sur téléphone, les consignes se
replient en une ligne « Consignes du cycle · N règles ».

Chaque créneau est une carte. Elle montre le jour, l'heure, le plat, puis une ligne de résumé :
parts, durée, accompagnement, format. Le reste se range sous « Détails » : contraintes du jour,
composants, conservation, origine du choix, redimensionnement s'il a eu lieu. Ce pli s'ouvre de
lui-même quand le créneau porte un avertissement (entrée ou dessert à choisir, plat à préparer
un autre jour). « Autre suggestion » reste visible ; les autres actions passent dans un menu ⋮,
aussi ouvert par un clic droit. L'heure est un bouton de 48 px.

« Contrainte locale du cycle » devient « Consignes du cycle ». Ctrl+S valide le planning, et
quitter l'écran avec des repas non validés demande confirmation.

### v0.23.29 — fonctionnel

#### Bibliothèque : exporter tous mes livres en PDF, un fichier par livre

Une icône PDF dans la barre de la Bibliothèque exporte en une opération tous les
livres dont l'utilisateur est le créateur. Chaque livre donne son propre PDF, au
même format que l'export d'un livre, et les PDF sont réunis dans un seul fichier
`Bibliotheque_AAAA-MM-JJ.zip`. Un ZIP évite une rafale de téléchargements dans le
navigateur et une feuille de partage par livre sur mobile. Les livres sans page validée sont
ignorés, un livre en échec n'arrête pas les autres, et le compte rendu donne les
nombres de livres exportés, sans page validée et en erreur.

### v0.23.28 — fonctionnel

#### Planning : variété des cuisines et des protéines dans la présélection

La présélection des plats tient compte de la cuisine. Chaque recette est rangée dans une
famille d'après ses étiquettes de cuisine : asiatique, indienne, orientale, Amériques,
africaine, italienne, européenne ou française. Un plat d'une famille étrangère déjà prévue dans
le cycle a deux fois moins de chances d'être tiré, et quatre fois moins à la troisième.
La cuisine française n'est jamais pénalisée, ce qui lui donne l'avantage sur la semaine. Une
recette sans étiquette de cuisine ne l'est pas non plus.

Jusqu'ici, seul le modèle d'IA lisait la cuisine, dans les préférences générales. Rien ne
garantissait qu'une semaine ne compte pas quatre plats asiatiques. La règle est verrouillée par
`planning_slot_rules.json` (sections `cuisine_of` et `cuisine_repeats`, constante
`cuisine_repeat_factor`).

La protéine de la veille et du lendemain compte aussi. Un plat dont la protéine est celle d'un
jour voisin a deux fois moins de chances d'être tiré. Jusqu'ici, la pénalité de protéine ne
comptait que les repas posés avant la génération. Deux poissons pouvaient donc se suivre, comme
le cabillaud du vendredi et le fish and chips du samedi. Sections `protein_neighbour` et
constante `protein_neighbour_factor` de la même fixture.

#### Règles de variété par défaut dans les préférences du planning

Un compte qui n'a jamais réglé ses préférences de planning reçoit des contraintes globales par
défaut : alterner les protéines, les féculents et les cuisines d'un jour à l'autre, avec une
majorité de cuisine française. Le texte se modifie dans Paramètres du planning.

Le bouton Admin › Backfills › « Contraintes de variété par défaut » pose ce texte sur les comptes
existants, hors de celui qui le lance. Des contraintes vides le reçoivent. Des contraintes déjà
écrites le reçoivent à la suite, sans rien effacer. Nouvelle fonction
`backfillPlanningDefaultsFn`, sans appel de modèle.

### v0.23.27 — fonctionnel

#### Planning : calendrier du lundi au dimanche et période libre

Le calendrier du planning revient à une grille habituelle, du lundi au dimanche. La période
choisie y est surlignée d'une bande continue. Une semaine du vendredi au jeudi occupe la fin
d'une ligne et le début de la suivante. Le jour courant reste entouré.

Un appui sur un jour choisit toujours la semaine du cycle qui le contient. Une période libre se
choisit par un appui long sur le premier jour, puis un appui sur le dernier, ou par « Choisir
des dates… ». Exemples : du vendredi au mercredi, ou deux semaines à partir d'un lundi. Une
période libre dure 31 jours au plus. Elle n'est pas retenue : chaque ouverture revient à la
semaine en cours. La liste des jours et la liste de courses suivent la période choisie.
« Nouveau planning » reste calé sur le prochain cycle.

Replié sur téléphone, le calendrier montre les lignes qui contiennent la période : deux lignes
pour une semaine du vendredi au jeudi, contre une seule en v0.23.26.

## 2026-10-10

### v0.23.26 — fonctionnel

#### Planning : un calendrier qui choisit la semaine

Les onglets « Liste » et « Calendrier » sont fusionnés en un seul écran. Le calendrier est en
haut, et les sept jours de la semaine choisie s'affichent en dessous. La barre de puces
« Sem. du … » et la puce « Tout » sont retirées.

Les colonnes du calendrier partent du jour de démarrage du cycle, réglé dans Configuration du
planning : « V S D L M M J » pour un cycle du vendredi. Une ligne de la grille est une semaine
de planning, et un appui sur n'importe quel jour du mois choisit toute sa semaine.

Sur un téléphone, le calendrier s'ouvre replié : un en-tête et le bandeau des sept jours, soit
environ 110 px au lieu de 360. Un appui sur l'en-tête déplie le mois. Les flèches et un balayage
du bandeau changent de semaine. Le bouton « Nouveau planning » se réduit à son icône quand on fait
défiler la liste et se masque pendant qu'on descend : il couvrait le menu des repas. Sur grand
écran, le mois reste affiché à gauche et le bouton passe dans la barre de l'écran.

Les cases du calendrier passent à 48 px, contre 37 px avant. La liste de courses couvre la
semaine affichée. « Rien de prévu » et « Choisir une recette » passent l'un sous l'autre quand
la largeur manque.

### v0.23.25 — fonctionnel

#### Protéine et féculent corrigeables à la main

Le formulaire d'une recette (relecture d'un import, correction, création) montre deux listes
sous « Rôle dans un repas » : « Protéine principale » et « Féculent principal ». Elles
n'apparaissent que pour un plat ou un accompagnement. « Suggérer les tags » les remplit.

Un choix à la main remplace la valeur proposée par l'IA, et aucun traitement automatique ne la
remplace ensuite. « Non renseigné » retire la valeur : le backfill « Protéine et féculent des
plats » la propose à nouveau. Passer la recette en entrée, dessert ou snack retire les deux
valeurs.

Côté serveur, ce backfill ne pose plus son marqueur sans appel que si la protéine **et** le
féculent sont présents (`hasBothMainIngredients`). Avant, une protéine seule suffisait, et un
féculent remis à « Non renseigné » n'aurait jamais été reproposé. `validateDraft` efface champ
par champ ce que le formulaire retire (`mainIngredientsFromForm`).

### v0.23.24 — fonctionnel

#### Protéine et féculent des plats, lus par le planning

Chaque plat et chaque accompagnement porte maintenant sa protéine principale (bœuf, porc,
volaille, agneau, poisson, fruits de mer, œuf, végétarien, légumineuses) et son féculent
principal (pâtes, riz, pommes de terre, semoule, pain, sans féculent). La fiche les affiche dans
« Catégorisation ». Une entrée, un dessert ou un snack n'en reçoit pas.

Le même appel de modèle que le rôle dans un repas les pose : import d'une page, « Suggérer
les tags », classement d'une recette écrite sans rôle. Aucun appel de plus ; le prompt grossit
d'environ 400 jetons. Une réponse hors liste est lue comme « non renseigné ».

Le planning lit la protéine dans ce champ d'abord, puis dans les types de plat. La
justification d'une proposition cite cette protéine. Un plat dont le féculent est celui de la
veille ou du lendemain pèse moitié moins au tirage : deux soirs de riz de suite deviennent
plus rares, sans être interdits.

**À faire après le déploiement, une fois :** Admin › Backfills › « Protéine et féculent des
plats ». La reprise traite les plats et accompagnements classés avant cette version, quarante
par passage, un appel de modèle par recette (poste `backfill_recipe_protein`). Relancer tant
que le compte rendu indique « incomplet ». Une recette examinée n'est plus requestionnée,
même si la réponse était hors liste (« veau ») ; seule une recette sans réponse est reprise.
Elle n'écrit que les valeurs absentes, et ne modifie ni le rôle, ni les apports, ni les types
de plat.

Côté technique : champs `tags.main_protein` et `tags.main_starch` (`String?`), marqueur
`tags.main_ingredients_checked_at` (`Timestamp?`), callable
`backfillRecipeProteinFn` (admin, point de reprise
`app_config/recipe_protein_backfill_checkpoint`), fixtures `meal_roles.json` (vocabulaires)
et `planning_slot_rules.json` (lecture de la protéine, féculent, facteur 0,5). Les tables d'alias du rôle, des apports,
de la protéine et du féculent ne se lisent plus que sur leurs propres clés : une réponse
« constructor » était lue comme un rôle. Pas encore de
correction manuelle de ces deux valeurs dans le panneau de métadonnées.

### v0.23.23 — technique

#### Deux backfills retirés : profils publics et portée des groupes

`backfillUserProfilesFn` (v0.23.14) et `backfillGroupReachFn` (v0.23.19) ont été lancés en
production : les profils publics existent, et la portée des groupes est calculée. Les deux
callables, leurs boutons d'Admin › Backfills (« Créer les profils publics », « Calculer la
portée des groupes ») et les méthodes `backfillUserProfiles` et `backfillGroupReach` de
`GcpBillingRepository` disparaissent, avec le test de `groupsByMember`, qui ne servait qu'au
second. Les déclencheurs `syncUserClaims` et `syncGroupReach` continuent de tenir profils et
portée à jour pour chaque compte et chaque groupe écrits.

Les libellés de journal `user_profiles_backfill` et `group_reach_backfill` restent, pour lire
les anciens journaux. Les documents `app_config/user_profiles_backfill_checkpoint` et
`app_config/group_reach_backfill_checkpoint` restent en base ; plus rien ne les écrit ni ne les
lit. Le workflow de déploiement supprime les deux functions en ligne (`--force`).

Risque accepté, écrit dans `TechnicalRequirements.md` (§3.5 bis) : sans backfill, une panne de
`syncGroupReach` de plus de 7 jours laisserait une portée périmée sans outil pour la recalculer.

### v0.23.22 — fonctionnel

#### Planning : un plat écarté revient moins souvent pendant 21 jours

Une recette proposée par l'IA ou par Kass'Dalle, puis écartée par « Autre suggestion »,
« Changer la recette » ou « Tout régénérer », compte comme un refus. La génération suivante la
propose moins souvent pendant 21 jours : son poids est divisé par deux, et par quatre à partir
de trois refus. Elle n'est jamais exclue, et sa justification dit « refusée récemment ».

Les refus vivent sous le compte, dans `users/{uid}/preferences/planning_refusals`, et jamais
dans la recette partagée : un refus d'un membre ne change rien pour les autres. Dans Nouveau
planning, ils s'enregistrent à la validation du cycle ; un cycle abandonné n'en laisse aucun.
« Réessayer avec l'IA » après une panne et « Remettre à blanc » ne comptent pas.

Préférences du planning affiche « Plats refusés récemment » et le bouton « Oublier mes
refus ». Les règles Firestore bornent la forme du document (300 entrées au plus), et un test
d'émulateur vérifie qu'un compte ne lit ni n'écrit les refus d'un autre. Un refus daté de
plus d'un jour dans le futur est ignoré. La durée de 21 jours, le plafond de 300 entrées et le
prédicat d'activité d'un refus sont rejoués des deux côtés par `planning_slot_rules.json`.

### v0.23.21 — technique

#### Planning : plafond de génération tenu sous des conceptions parallèles

Deux points faibles relevés par la relecture sécurité de la v0.23.18, tous deux bornés par le
plafond du jour de chaque compte.

**Conceptions parallèles.** La transaction de `reservePlanningConcept` comptait la conception
mais pas son coût : le coût réel n'arrivait qu'après l'appel. Des conceptions lancées en même
temps sur une génération voyaient le même `cost_usd`, et le plafond en euros pouvait être
dépassé d'une estimation par conception. L'estimation est désormais réservée dans la même
transaction (`reserved_usd`), et `addPlanningRunCost` la libère en ajoutant le coût réel. Une
conception en échec garde sa réservation : le plafond devient plus strict, jamais plus large.

**Conceptions ouvertes par une génération.** `concepts_max` valait toujours
`concepts_per_generation`, même pour une génération qui avait rempli tous ses créneaux. Il est
désormais borné par le nombre de créneaux restés vides (`conceptsAllowance`), et
`conceptsRemaining` dans la réponse suit la même valeur. Un compte qui enchaîne des générations
avec des créneaux vides obtient encore des conceptions automatiques à chaque fois, comme il peut
lancer « Concevoir avec l'IA » à la main : les deux chemins restent bornés par le plafond du
jour, ce que `TechnicalRequirements.md` dit maintenant.

Fixture `planning_slot_rules.json` : deux cas de réservation, une section `concepts_allowance`.

### v0.23.20 — technique

#### Contrôle de version : deux titres permis, garde-fous signalés

`check-version.sh` accepte deux entrées pour une même version dans ce fichier, une
« — fonctionnel » et une « — technique », ajoutées dans le même commit. Il refuse une version
sans entrée, un titre d'un autre type, deux titres du même type, et deux titres ajoutés par
des commits distincts. Ces deux derniers cas signalent deux livraisons au même numéro. `relecteur-regles` reçoit un
contrôle 14 : tout diff qui touche `check-version.sh`, `ci.yml` ou `deploy.yml` est signalé
en tête de son rapport, et l'utilisateur décide avant la fusion.
### v0.23.19 — fonctionnel

#### Groupes familiaux : on ne lit que ce que partagent les membres de ses groupes, et on n'entre dans un groupe qu'en acceptant une invitation

**Ce que voit l'utilisateur.** Le propriétaire d'un groupe n'ajoute plus un membre : il
l'invite (« Inviter dans le groupe »), et peut annuler l'invitation tant qu'elle attend.
L'invité voit « Invitations reçues » en tête de l'écran Groupes, et un badge sur son compte.
Il accepte, après une confirmation qui dit que les membres verront ses livres et recettes non
privés et lui les leurs, ou il refuse. « Quitter le groupe » marche : la règle Firestore le
refusait. La bibliothèque, la recherche et le planning montrent les mêmes livres qu'avant.

**Ce qui change pour la sécurité.** Le cloisonnement par groupe n'existait que côté client.
`canReadRecipe` et la lecture des livres acceptaient toute recette ou tout livre non privé
pour tout compte nommé : un compte hors de mes groupes lisait mes recettes, leurs notes et
leurs annotations par une requête Firestore directe. Les règles vérifient maintenant que le
créateur partage un groupe avec le lecteur (`sharesGroupWith`), par une lecture de
`group_reach/{lecteur}`, une nouvelle collection écrite par le serveur seul. Le déclencheur
`syncGroupReach` la recalcule à chaque écriture d'un groupe. Un membre sorti d'un groupe ne lit
plus ses livres, et le groupe ne lit plus les siens. La relecture des brouillons partagés par un
éditeur est limitée de la même façon, sur décision de l'utilisateur. L'administrateur lit tout.
Les invitations ferment le contournement : ajouter un inconnu à son propre groupe suffisait
pour lire ses livres.

**Côté client.** Les requêtes sur les livres et recettes des autres portent `created_by in` les
comptes de la portée (`RecipeViewer.groupPeers`), par lots de 30, de 15 pour les brouillons :
sans ce filtre, Firestore refuse une requête que les règles ne peuvent plus prouver.

**À lancer après le déploiement : Admin › Backfills › « Calculer la portée des groupes »**
(`backfillGroupReachFn`), un passage. Jusque-là, personne ne voit les livres de sa famille.

### v0.23.18 — fonctionnel

#### Planning : le serveur choisit les candidats, « Autre suggestion » sans IA, coût borné

**Ce que voit l'utilisateur.** Chaque repas proposé porte une ligne d'origine : « Choisie par
l'IA », « Choisie par Kass'Dalle », « Conçue par l'IA » ou « Choisie par vous », suivie de faits
vérifiables (« volaille · 35 min, sous les 40 min du mardi · pas servie ces 3 derniers mois »).
Les phrases génériques de repli ont disparu, et le robot ne précède plus un choix fait à la main.
« Autre suggestion » (icône de rotation), sur un créneau de Nouveau planning comme dans le menu
d'un repas du planning (ex-« Suggestion IA »), prend la recette suivante sans appel d'IA.
« Proposer une recette » fait de même sur un créneau vide. Quand la liste est épuisée, l'écran
propose « Choisir une recette » ou « Concevoir avec l'IA ». Si l'IA ne répond pas, Kass'Dalle
remplit le planning selon les contraintes, un bandeau le dit et propose « Réessayer avec l'IA ».
Une génération qui coûterait plus de 0,50 € n'appelle pas l'IA et le dit. Deux recettes au plus
sont conçues automatiquement par génération ; l'écran dit combien de créneaux restent vides.
Une recette notée 3/10 ou moins n'est plus proposée ; une recette notée 8 ou plus l'est plus
souvent. Le menu dit « Tout régénérer ».

**Ce qui change dans le code.** `suggestMealPlanFn` présélectionne les candidats de chaque
créneau (`gemini/planning.ts` : filtres durs, note de fraîcheur sur 90 jours de repas, note
personnelle de l'appelant, tirage pondéré, trois protéines en tête de liste) et n'envoie plus
que cinq plats par créneau au modèle, dans un prompt compact. Un choix du modèle hors liste est
remplacé par le code et compté. Le redimensionnement se calcule. Nouveau mode `code` (sans
appel de modèle), nouveaux champs `slotDismissed`, `runId`, `rankedCandidates`, `modelStatus`,
`notice`, `conceptsRemaining`. `maxTokens` : 4 000 pour `planning`, 6 000 pour
`planning_concept`. Nouvelle sous-collection `users/{uid}/planning_runs` (serveur seul, TTL
180 jours), nouveau document de réglages `app_config/planning_policy` (valeurs par défaut dans
le code), nouveau champ `planned_meals.choice_source`. La fixture `planning_slot_rules.json`
verrouille la présélection.

**Coûts.** Le prompt passe d'environ 25 000 à environ 5 000 jetons d'entrée pour 400
recettes. « Autre suggestion » n'enregistre plus aucune ligne `ai_usage`. Les lignes du
planning et des conceptions d'une génération portent `entity_type: planning_run` et
`entity_id`. Aucun poste d'IA nouveau. Le plafond du jour atteint pendant une génération ne
renvoie plus d'erreur : le code remplit, rien n'est facturé.

**Après déploiement.** La politique TTL de `planning_runs.expires_at` s'active avec le
déploiement des index Firestore. Aucun backfill : un repas antérieur n'a pas de ligne
d'origine.

### v0.23.17 — technique

#### Un numéro de version par livraison

Le PC pousse sur `master` pendant que des sessions cloud préparent leurs PR. Deux livraisons
qui passaient toutes deux de 0.23.14 à 0.23.15 fusionnaient sans conflit dans `pubspec.yaml`,
et le second déploiement conservait l'APK en ligne : ses changements n'arrivaient pas sur
Android. Le script `.github/scripts/check-version.sh` vérifie trois points : une version
changée dépasse celle de `master`, aucun autre commit de l'historique n'a introduit le même
numéro, et ce fichier n'a qu'une entrée pour elle. Il tourne dans un nouveau job de la CI,
« Version — numéro libre », qui bloque le déploiement s'il échoue. `CLAUDE.md` demande de le
lancer à la main avant chaque push depuis le PC et avant chaque fusion de PR, après avoir
intégré `origin/master`. Un `.gitattributes` garde les scripts `*.sh` en fins de ligne LF,
pour que le `bash` de Git for Windows les lise.

### v0.23.16 — fonctionnel

#### Traduction des recettes étrangères à l'import

**Ce que voit l'utilisateur.** Une recette importée dans une autre langue arrive en français,
mesures converties en métrique. La fiche porte la mention « Traduit de l'anglais » (ou de la
langue lue ; « Traduit d'une autre langue » hors d'une table d'une trentaine de langues) : sous
le titre sur grand écran, dans la rangée d'actions sur téléphone. La mention ouvre la vue
« Texte d'origine, avant traduction » ; sur grand écran, l'icône « Voir le texte d'origine
(anglais) » aussi. La vue est une feuille à 90 % de la hauteur sur téléphone, une fenêtre de
640 px sur grand écran. Elle suit le zoom de lecture, son texte se sélectionne, s'écrit de
droite à gauche pour l'arabe, l'hébreu et le persan, et emploie les glyphes de sa langue. Elle
affiche un état de chargement, un état d'erreur, et « Texte d'origine indisponible » quand le
document manque. À la relecture d'un brouillon traduit, la même mention s'affiche, et sur grand
écran un panneau de 360 px (« Afficher / Masquer le texte d'origine ») se place à côté de
l'éditeur, à partir d'une fenêtre de 1 150 px de large. Tout lecteur de la recette voit la mention et le texte d'origine. Une recette non
traduite ne change pas. Pendant l'import, la file affiche « Traduction de la recette par
l'IA… », sans icône de plus dans la rangée d'étapes.

**Texte collé.** « Mettre en forme avec l'IA » traduit aussi un texte étranger et l'annonce :
« Traduit de l'anglais, mesures converties. Le texte collé reste consultable comme document
original. » L'original n'est pas stocké une seconde fois : le texte collé reste le fichier
source.

**Transcription.** `TRANSCRIPTION_PROMPT` rend `langue` (ISO 639-1) pour chaque recette, lue sur
les étapes ; dans le doute, `fr`. La transcription recopie dans la langue de la page et ne
traduit rien. Une page française ne coûte aucun appel de plus.

**Nouveau poste d'IA `recipe_translation`** (`functions/src/gemini/translation.ts`), groupe
Import, processus « Numérisation d'un livre », inscrit dans `ROUTABLE_FEATURES`,
`kFeatureCatalog` et `kFeatureProcess`. Appelé seulement quand la langue n'est pas `fr`, sur le
JSON transcrit, sans image. Il traduit en français et convertit les mesures : solides en
grammes, liquides en millilitres, °F en °C arrondis à 5, inch en cm, valeurs US par défaut, UK
si la source est britannique ; un ingrédient sans équivalent garde son nom, suivi d'un
équivalent entre parenthèses. `translationShapeMismatches` vérifie sans appel que la
traduction garde les nombres de groupes, de lignes, d'étapes et de notes, et qu'aucun texte
n'est vidé (titre, introduction, titre de groupe, ligne, étape, note ; les durées ne sont pas
contrôlées). Sinon le job échoue (« Traduction impossible : … ») et reste relançable.

**Pipeline.** `recipeProcessor` gagne l'étape `translate`, entre `gemini_call` et `parse` dans
`STEP_ORDER`. Pour un livre entier, le plafond de l'import est vérifié avant chaque traduction.
Le point de reprise est réécrit après chaque recette traduite : une relance ne retraduit pas. Balisage,
contrôle de fidélité, tags et nutrition travaillent sur la traduction. Une page qui n'est pas
une recette n'est pas traduite.

**Firestore.** Champ `langue_origine` (ISO 639-1) sur `recipes/{id}`, posé seulement sur une
recette traduite, jamais écrit par le client. Sous-document `recipes/{id}/origine/texte` :
`langue`, `titre`, `introduction`, `portions`, `temps_preparation`, `temps_cuisson`,
`temps_repos`, `sections_ingredients[{titre, lignes[]}]`, `sections_etapes[{titre, etapes[]}]`,
`notes[{genre, texte}]`, `created_at`. Il est écrit dans le même lot que la recette, et
`onRecipeWritten` le supprime avec elle. Règle : lecture si `isApproved()` et
`canReadRecipe(recipeDoc(recipeId))`, écriture interdite, administrateur compris. Le texte
d'origine n'est pas indexé par la recherche. Aucun backfill : une recette existante n'a pas de
`langue_origine` et reste « écrite en français ».

**Client.** `Recipe.langueOrigine` et `isTranslated` ; `toFirestore` omet le champ, une copie ne
le reprend pas. `OriginalText`, `OriginalTextRepository` (`ErrorReportService`, feature
`recipes.originalText.read`), `originalTextProvider`, `original_text_viewer.dart`, et la table
`core/utils/language_names.dart`.

**CSP.** `https://fonts.gstatic.com` rejoint `font-src` et `connect-src` de la
`Content-Security-Policy-Report-Only` : CanvasKit y télécharge les polices de secours du
japonais, de l'arabe et des autres écritures que ses polices embarquées ne couvrent pas.

**Tests.** Cinq tests de règles sur `origine/texte` : 326 tests attendus, dont 258 Firestore.
Ils n'ont pas tourné sur le PC (Java absent) ; la CI les rejoue. Côté Functions,
`recipeTranslation.test.ts` ; côté Dart, `original_text_test.dart`.

**Pas encore essayé sur un vrai livre.** Un test en direct avec un livre anglais est prévu.

**Hors périmètre.** Traduire vers une autre langue que le français ; retraduire une recette
existante ; forcer une traduction ; traduire une page qui n'est pas une recette (technique, note
d'ingrédient).

### v0.23.15 — fonctionnel

#### Fiche recette : les notes de la famille

**Ce que voit l'utilisateur.** Sous « Ma note », une ligne repliée « Famille : 7 / 10 · 2 notes »
donne la moyenne et le nombre de notes. Dépliée, elle liste chaque membre avec son nom, la date
et sa note. Seules comptent les notes des membres qui partagent un groupe avec moi, plus la
mienne. Un membre sorti de mes groupes ou dont le compte est supprimé disparaît de la liste et de
la moyenne. Au moment de noter, un rappel dit que la note est visible des membres qui ont accès à
la recette. Le planning ne tient toujours compte que de ma note.

**Technique.** `RecipeRatingRepository.watchAllForRecipe` lit les notes par
`where recipe_id ==`. La règle existante prouve cette requête ; deux tests de `rules-tests` le
vérifient. Le filtre par groupe et la moyenne sont calculés côté client (`FamilyRatings`), rien
n'est stocké.

**Règle.** `recipe_ratings` exige désormais une note bien formée à la création comme à la
modification : `rating` entier de 0 à 10, `updated_at` en `timestamp`, aucun champ en plus. Tous
les membres décodent maintenant les notes d'une recette : un compte pouvait écrire `rating: "x"`
et faire échouer l'affichage chez tous. Une note illisible déjà en base est rapportée et écartée
côté client. La création exige l'identifiant `{uid}_{recipeId}` : un compte pouvait créer
plusieurs notes sous d'autres identifiants et peser plusieurs fois dans la moyenne. Un compte
révoqué ne modifie ni ne supprime plus sa note. Neuf tests de règles couvrent ces cas.

**Corrections.** Un échec d'enregistrement ou de suppression d'une note s'affiche désormais
(message d'erreur) et est rapporté par `ErrorReportService` ; il passait inaperçu. Le libellé
« Communaute » prend son accent. Le bouton « Supprimer » de la note prend la couleur d'erreur du
thème.

### v0.23.14 — fonctionnel

#### Profils publics : le compte d'un membre ne se lit plus que par lui et par un administrateur

**Ce que voit l'utilisateur.** Un lecteur voit désormais le nom des autres membres sur les
recettes, les brouillons et les sections de la bibliothèque. La recherche de membres d'un groupe
se fait par nom seulement (« Rechercher un membre par son nom… ») : la recherche par adresse
e-mail et l'adresse affichée sous chaque membre disparaissent. Une recherche sans résultat le dit,
et rappelle qu'un compte en attente n'apparaît qu'une fois validé. La liste des membres affiche,
comme la recherche, le nom Google complet quand il diffère du nom affiché. « Retirer du groupe »
demande confirmation, avec le nom du membre. Un nom préféré compte au plus 60 caractères.

**Règle.** `users/{uid}` ne se lit plus que par son titulaire et par un administrateur. Un
éditeur lisait le document de tous les comptes — adresse, rôle, révocation — pour afficher un
prénom. Le dernier test `todo` des règles (« un éditeur ne lit pas le document d'un autre »)
devient bloquant : 310 tests, aucun `todo`.

**Nouvelle collection `user_profiles/{uid}`.** Elle porte `display_name`, `preferred_name`,
`free_recipe_cover_url` et `updated_at`, jamais l'adresse ni le rôle. Elle se lit par tout
compte nommé et ne s'écrit que côté serveur. Un compte en attente n'a pas de profil ; un compte
révoqué garde le sien. Le déclencheur existant `syncUserClaims` la tient à jour à chaque
écriture sur `users/{uid}`, sans second déclencheur : il relit le profil et ne le réécrit que
s'il diffère.

**Client.** Les écrans qui affichent le nom d'un autre membre lisent ce profil :
`userByUidProvider` est remplacé par `userProfileProvider` et `memberNameProvider` (file de
travail, relecture d'un brouillon, détail et liste des recettes, bibliothèque, membres d'un
groupe). Le compte courant continue de lire son propre document. Un lecteur voit désormais ces
noms ; il ne les voyait pas, faute de droit sur `users/`. La recherche de membres d'un groupe
interroge `user_profiles`, **par nom seulement** : la recherche par adresse e-mail et l'adresse
affichée sous chaque membre disparaissent. Admin › Gestion des utilisateurs garde la lecture
complète.

**Un seul nom de remplacement : « Membre ».** « Utilisateur » disparaît : un compte sans nom
Google s'affiche « Membre » pour les autres, et sous la partie locale de son adresse pour
lui-même. Un compte neuf sans nom Google enregistre un `display_name` vide au lieu de
« Utilisateur ». Là où « Membre » ferait une phrase vide, l'écran écrit « Livres d'un membre »
ou « Recettes libres d'un membre », et la phrase d'origine d'un livre partagé se tait. Le filtre
par compte de la file de travail, réservé à l'administrateur, affiche le nom et l'adresse de
chaque compte. Un profil lu avec succès est gardé pour la session.

**Noms bornés à 60 caractères.** `display_name` et `preferred_name` sont recopiés dans un profil
que toute la famille lit : les règles de `users/{uid}` refusent désormais plus de 60 caractères
à la création et à la modification de ces champs (un document ancien au nom plus long reste
modifiable tant qu'on ne touche pas au nom). Le client coupe le nom Google à 60 caractères avant
d'écrire, le champ « Nom préféré » est limité à 60, et le serveur coupe aussi à la recopie
(`publicProfileFrom`). Onze tests de règles de plus : 321 tests, aucun `todo`. La limite se compte en unités UTF-16, comme `string.size()` dans les règles : un emoji y vaut 2 ; le client et le serveur coupent de la même façon, sans couper un caractère en deux.

**Code mort retiré.** `isAuthenticatedProvider`, `draftBooksCountProvider`, `libresBookProvider`
et `secretesBookProvider` n'avaient plus aucun appelant.

**À faire juste après le déploiement : Admin › Backfills › « Créer les profils publics »**
(`backfillUserProfilesFn`). Sans appel d'IA, 2 000 comptes par passage : un seul passage
suffit. Tant qu'il n'a pas tourné, le nom d'un membre dont le compte n'a pas été écrit depuis le
déploiement s'affiche « Membre ». Une connexion Google, un nom préféré ou une couverture changés
recréent aussi le profil du compte concerné, mais une session reste ouverte des semaines sans
nouvelle connexion : le backfill reste nécessaire.

**backfillBookPrivacyFn retiré : lancé en production, son travail est fait.** La callable, son
test, la méthode `backfillBookPrivacy` de `GcpBillingRepository` et le bouton « Reprendre la
confidentialité des livres » d'Admin › Backfills disparaissent. Le libellé de journal
`book_privacy_backfill` reste, pour lire les anciens journaux. Le document
`app_config/book_privacy_backfill_checkpoint` reste en base ; plus rien ne l'écrit ni ne le lit.

## 2026-10-09

### v0.23.13 — fonctionnel

#### Plafond d'import en euros, tags système hors du formulaire, images de l'application seules

**Plafond maximal d'un import de livre : 4 € par tranche.** Il valait 2 $ par tranche. Le
maximum est désormais fixé en euros (`MAX_IMPORT_BUDGET_PER_WINDOW_EUR`) et converti en
dollars au moment du calcul avec le taux de la facture (`app_config/currency_rate`), arrondi au
centime inférieur, sans dépasser 8 $ par tranche. Sans taux, ou avec un taux hors des bornes de
la réconciliation (0,1 à 10), aucun taux n'est inventé : le maximum vaut 4 $ par tranche, plus
bas que 4 € tant qu'un dollar vaut moins qu'un euro, et `runBookImport` le journalise. L'écran
de confirmation reçoit ce maximum, le maximum par tranche et le taux qui a servi : il fait
saisir le plafond en euros quand le taux est connu (en dollars sinon), l'envoie en dollars,
affiche le maximum sous le champ et refuse un plafond plus haut ; le plafond proposé ne le
dépasse plus. Avant, un montant plus haut était ramené au maximum sans que l'écran le dise.

**Tags système.** Le formulaire d'un livre refuse un tag qui commence par « __ » : taper
`__libres`, `__kassdale_ia` ou `__secretes` faisait d'un livre ordinaire un livre système, que
plus personne ne pouvait supprimer. Les règles Firestore ne changent pas.

**Images.** L'application n'affiche que les images de son propre stockage. `isAppImageUrl`
accepte les URL du bucket du projet et de son ancien bucket `appspot.com`
(`firebasestorage.googleapis.com/v0/b/<bucket>/o/…`, `storage.googleapis.com/<bucket>/…`) et
l'émulateur en debug ; `AppNetworkImage` remplace `CachedNetworkImage` et `Image.network` dans
vingt fichiers d'écran, et affiche l'image de repli de l'écran pour toute autre URL, ou un repli
neutre (icône d'image cassée). Une vignette refusée n'ouvre pas de visionneuse. L'export PDF,
l'atelier de retouche et l'extraction d'illustrations ne téléchargent plus une image d'un autre
bucket ou d'un autre hôte : `refFromURL` les acceptait. La photo de profil Google reste
affichée : exception décidée par l'utilisateur.

### v0.23.12 — technique

#### Failles faibles de l'audit sécurité : règles, plafond d'import, révocation, archives, CI

**Règles Firestore.** Douze des treize tests `todo` de `rules-tests` deviennent bloquants. Un
livre système garde son tag à toute mise à jour (`keepsSystemTags`) : retirer le tag puis
supprimer le livre contournait la garde. `owner_id` d'un groupe et `uid` d'un repas planifié
sont figés. Un compte en attente ou révoqué ne crée ni ne modifie de repas planifié et n'écrit
plus `planning_config` ; il relit et supprime toujours ses données. Un compte révoqué n'écrit
plus de rapport d'erreur ; un compte en attente, et un compte neuf sans document, en écrivent
encore. Sur `app_config/usage`, chaque compteur écrit par le client reste un entier positif qui
ne recule pas (`countsUp`). Un éditeur ne lit plus les jobs d'import d'autrui : aucun écran ne
s'en servait. Vingt tests vérifient que les cas légitimes passent toujours. 297 tests, 296
actifs, 1 `todo`.

Le `todo` restant — un éditeur lit le document `users/{uid}` d'autrui — reste ouvert : la file
de travail, la relecture d'un brouillon, le détail d'une recette et la recherche de membres
d'un groupe affichent un nom lu dans ce document.

**Plafond d'un import de livre.** Le plafond fixé par le client (`budget_limit_usd`) est borné
côté serveur à 2 $ par tranche (`effectiveImportLimitUsd`) ; la valeur du client ne peut que
réduire ce maximum, et un job sans plafond le reçoit. Le `scan_id` d'un import de livre est
désormais tiré par `jobDispatcher`, et celui d'un autre job est remplacé s'il désigne le
compteur d'un autre compte : un éditeur qui reprenait le `scan_id` d'autrui relevait son
plafond et y imputait ses dépenses. `setImportCeiling` et `raiseImportCeiling` refusent un
`scan_spend` posé au nom d'un autre compte.

**Révocation.** `syncUserClaims` révoque les jetons de rafraîchissement d'un compte qui perd
l'accès : passage à révoqué, rôle sorti de reader/editor/admin, document supprimé.
`requireAuth` relit le document à chaque appel, et ce document fait foi pour le rôle ; un
document absent ou un rôle `pending` est refusé. Un compte révoqué, remis en attente ou
supprimé gardait jusqu'à une heure l'accès aux callables d'IA.

**Archives DOCX et EPUB.** `utils/boundedZip.ts` lit ces archives avec trois bornes vérifiées
pendant le dépliage : 10 000 entrées, 50 Mo par entrée, 200 Mo cumulés. Le nombre d'entrées
est contrôlé avant le chargement par JSZip, en comptant les occurrences de la signature d'en-tête
central (`50 4B 01 02`) dans tout le fichier. Chaque entrée que JSZip construit commence par
cette signature : ce compte majore toujours le sien, sans se fier à l'enregistrement de fin
d'archive (EOCD, ZIP64), qui se falsifie. Une bombe zip lève `ZipLimitError` au lieu de faire tomber la fonction
par manque de mémoire, et le job part en dead letter sans nouvelle tentative : un DOCX joint à
un import de recette finit en `archive_limit_exceeded` ; un livre EPUB ou Word finit en
`book_file_unreadable`, parce que `openBookFile` transforme l'erreur en `BookFileError`.

**CI.** Les actions de `ci.yml` et `deploy.yml` sont épinglées par SHA de commit, version en
commentaire ; `deploy.yml` extrait le dépôt sans garder le jeton (`persist-credentials: false`).
Les deux workflows avaient déjà `permissions: contents: read`.

**Laissés en l'état, documentés.** La CSP reste en rapport seul, sans destination de rapport :
le projet n'a pas de point de collecte. Les URL d'image écrites par le client ne sont pas
contrôlées par les règles (une règle ne parcourt ni une liste ni le texte CookLang) ; le
serveur ne télécharge aucune de ces URL. Les analyses Vision de la modération restent hors
plafond d'IA, par décision.

### v0.23.11 — technique

#### Bornes larges sur les entrées envoyées aux modèles, et relevé de leur taille

Les callables recopiaient dans le prompt ce que le client envoyait, sans limite de taille :
un texte de plusieurs millions de caractères partait tel quel chez Gemini ou Anthropic et
se facturait au jeton. Un utilitaire unique, `callable/_inputBounds.ts`, borne désormais
chaque champ client de seize callables avant tout appel de modèle et toute réservation de
budget : 200 000 caractères pour un texte collé, 100 000 pour une recette, 5 000 pour une
consigne ou une requête, 500 éléments par liste (5 000 pour la bibliothèque de recettes
envoyée à la recherche et au planning), 8 Mo décodés pour une couverture, 20 Mo pour une page.
Au-delà, la callable répond `invalid-argument` avec le champ et la limite ; rien n'est
tronqué.

Ces seize callables et `suggestMealIdeasFn`, qui gardait déjà ses propres bornes,
journalisent à chaque appel la taille de chaque champ, sans son contenu, sous le message
« Taille des entrées IA » (`INFO`, ou `WARNING` pour un refus). Ce relevé servira à
resserrer les bornes poste par poste. Une image base64 mal formée est désormais refusée :
`Buffer.from` ignorait les caractères invalides et envoyait au modèle une image tronquée.

La relecture sécurité a relevé deux champs recopiés dans un prompt sans contrôle :
`currentPortions` (affinage) et `batchCookingDay` (planning). Ils exigent désormais un
nombre, de 0 à 1 000 pour le premier, un entier de 1 à 7 pour le second. La cause est
corrigée aussi : l'affinage, la recherche, le planning et la conception de recette
transmettaient au générateur l'objet du client entier. Ils transmettent maintenant un objet
construit à partir des seuls champs validés (`callable/_aiInputReaders.ts`), et un champ
ajouté par le client n'atteint plus aucun prompt.
Détail : `TechnicalRequirements.md`, section 7.8 bis.

### v0.23.10 — technique

#### Trois failles moyennes de l'audit de sécurité corrigées

**Faille 6 — lecture d'un fichier arbitraire du bucket.** Le serveur téléchargeait le chemin
Storage posé par le client (`file_url` et `additional_file_urls` d'un job d'import, URL d'une
illustration à améliorer, visuel de dressage précédent stocké sur la recette). Un éditeur
pouvait lui faire lire `rejected/…` ou la quarantaine d'un autre compte, puis l'envoyer au
modèle. Le nouveau module `utils/storagePath.ts` extrait le chemin (chemin nu, `gs://`, URL
`firebasestorage.googleapis.com` du bucket par défaut), refuse les segments `..`, et n'admet
que les dossiers du flux : `scans/{created_by}/` pour le pipeline d'import, `illustrations/`
et `recipes/` pour une image publiée. Un job refusé part en dead letter dès la première
tentative avec `failure_reason: forbidden_source_path` ; une callable répond
`permission-denied` et laisse un `WARNING` avec le compte et le chemin. Les trois contrôles de
préfixe existants (`scanAndPromoteUploadFn`, `analyzeBookFileFn`,
`moderateAndPromoteImagesFn`) refusent aussi un chemin mal formé.

Deux effets visibles. Un ancien job en échec dont le fichier n'est pas sous `scans/{uid}/` ne
peut plus être relancé : il repart en dead letter avec `forbidden_source_path`. Une ancienne
image rangée hors de `illustrations/` et `recipes/` ne peut plus être améliorée, ni servir de
base au visuel de dressage suivant.

**Faille 7 — protection du fondateur contournable.** Un administrateur pouvait changer
l'adresse du document du fondateur, puis son rôle ou le supprimer. `email` est désormais
immuable dans `users/{uid}` pour tous les comptes, administrateur compris. Le test de règles
correspondant devient bloquant, huit tests s'ajoutent.

**Faille 8 — plafond journalier dépassé par rafale.** Le plafond lisait la dépense avant
l'appel et l'enregistrait après : des appels simultanés passaient tous. Chaque appel réserve
maintenant sa place dans `ai_daily_spend` par transaction : il compte pour un appel et pour le
coût moyen d'un appel chiffré du jour, sans prix écrit dans le code. La réservation est retirée
à la fin de l'appel et expire après quinze minutes. Les appels lancés par un utilisateur
(callables) sont limités à dix en cours par compte (×100 pour le fondateur) ; au-delà, attente
de vingt secondes puis refus `concurrency`. Le pipeline d'import, les déclencheurs et les tâches
planifiées réservent leur place mais ne sont jamais limités en simultanéité : un import de
livre légitime ne peut pas échouer pour cette raison. L'origine de l'appel est posée par les
gardes des callables (`ai/callOrigin.ts`). L'amélioration d'illustration, jusque-là hors
plafond, y entre.

### v0.23.9 — fonctionnel

#### Conseils et calculs IA réservés au créateur de la recette

Faille 5 de l'audit de sécurité du 2026-10-09. Le conseil de dressage, le conseil de
conservation, le visuel d'une étape de dressage et le recalcul de nutrition s'enregistrent sur
la recette partagée, par le serveur. N'importe quel compte pouvait les déclencher sur la
recette d'un autre membre : l'appel était facturé, le résultat précédent écrasé, et
l'instruction libre d'un tiers stockée dans le conseil de dressage.

- **Serveur.** `suggestPlatingFn`, `suggestStorageAdviceFn`, `generatePlatingImageFn` et
  `computeRecipeNutritionFn` refusent en `permission-denied` tout compte qui n'est ni le
  créateur de la recette ni un administrateur, avant tout appel de modèle
  (`assertCanModifyRecipe`, décision pure `recipeWriteDenial` testée). Ce contrôle remplace
  `assertCanReadRecipe` (v0.23.8), retiré : écrire implique lire. Une recette absente répond
  `not-found`. Les déclencheurs automatiques (`onRecipeWritten`, rattrapage nutrition) ne
  changent pas.
- **Écrans.** Les boutons « Demander un dressage sur mesure », « Régénérer » et
  « Calculer » / « Recalculer » n'apparaissent plus qu'au créateur et à un administrateur.
  Les conseils et la nutrition enregistrés restent affichés à tous. Sans rien d'enregistré,
  une ligne de texte dit qui peut le demander. Les visuels d'étape exigent en plus le rôle
  éditeur : un lecteur créateur de sa recette ne voit plus de bouton de visuel que le serveur
  refusait, et une ligne le lui dit. Le libellé « Regénérer » devient « Régénérer ».
- **Conservation.** Le conseil n'est plus demandé automatiquement (bandeau de préparation,
  planning, batch) pour la recette d'un autre membre ; il est relu s'il existe. Sinon :
  « Pas encore de conseil de réchauffage pour ce plat : son créateur peut le demander. ». Le
  batch retient la recette après le premier refus et remplace le bouton du créneau par ce
  texte. Le droit attend le chargement du profil, pour ne pas refuser le créateur lui-même.
  Une recette supprimée affiche « Recette introuvable. ».

### v0.23.8 — technique

#### Confidentialité, propriété et modération imposées par le serveur

L'audit de sécurité du 2026-10-09 relevait trois failles élevées et une moyenne. Les quatre
sont corrigées ; leurs tests de règles ne sont plus `todo` et deviennent bloquants.

- **Contenu privé** (`firestore.rules`). Un livre ou une recette privé ne se lit que par son
  créateur et par un administrateur, éditeurs compris. Les annotations et les notes suivent
  la recette, par `get()` : on en lit et on en pose sur toute recette qu'on voit. La
  confidentialité ne vivait que dans les requêtes du client ; un compte qui interrogeait
  Firestore directement lisait tout. Un document n'est partagé que s'il porte
  `is_private == false` : une lecture par `get('is_private', false)` laissait passer une liste
  sans filtre, l'émulateur l'a montré.
- **Propriété** (`firestore.rules`, écrans). Un livre ou une recette ne se modifie et ne se
  supprime que par son créateur ou un administrateur, éditeur compris. `created_by` vaut
  l'appelant à la création et ne change plus, administrateur compris. Les écrans masquent les
  gestes d'édition sur le contenu d'autrui (fiche recette, page de livre, liste d'un livre).
- **Dépense hors plafond** (`ai/budget.ts`, déclencheurs). Un lecteur vidait `created_by` de
  sa recette et faisait tourner les déclencheurs nutrition sans plafond. Une recette sans
  propriétaire s'impute désormais à `system_recipe_without_owner` (plafond commun), et un
  appel sans uid à `system_unattributed`, plafonné cent fois plus haut au lieu de passer sans
  contrôle. Ces deux comptes apparaissent sous leur clé dans les coûts et les plafonds.
- **Modération contournée** (`moderationCallables.ts`, `moderation/origin.ts`). Le client
  déclarait `origin: "ai"` ou `"asset"` et l'image était publiée sans analyse. `ai` venant
  d'un client est ignoré ; `asset` n'est retenu que sur l'empreinte SHA-256 d'une couverture
  livrée. Une illustration retouchée sur l'appareil est donc analysée et facturée comme une
  autre image (poste `image_moderation`).
- **Couverture d'autrui** (`moderation/promote.ts`). Couverture de livre et illustration de
  recette ne se publient que sur le document de l'appelant, ou par un administrateur,
  contrôlé avant toute analyse facturée.
- **Storage** : `isActive()` traite l'absence du claim `revoked` comme un compte actif, comme
  son commentaire le disait. L'écart relevé par la suite de tests est fermé.
- **Requêtes du client** : `RecipeRepository` scinde une requête par livre ou par statut en
  « partagées » et « les miennes » (`RecipeViewer`), les livres de la famille filtrent
  `is_private == false`, et le planning relit recette par recette un lot refusé. Les tests de
  règles rejouent ces requêtes.

Corrections après relecture (sécurité, interface) :

- **Confidentialité suivant le livre** (`firestore.rules`, client). Une recette créée ou
  déplacée dans un livre privé avec `is_private: false` restait lisible jusqu'au passage du
  déclencheur. La règle exige désormais la confidentialité du livre à toute écriture qui pose
  ou change `book_id` ou `is_private`, et le client l'écrit depuis le livre (`privacyOfBook`).
- **Version analysée = version publiée** (`moderation/promote.ts`). La génération Storage lue
  avant l'analyse est épinglée : réécrire le fichier de quarantaine ensuite fait échouer la
  promotion. `ownerId` contenant « / » est refusé.
- **Storage** : lister `scans/{uid}/` est réservé au propriétaire et à l'admin, lister
  `recipes/{recipeId}/` à l'admin. Lire un fichier par son adresse reste ouvert.
- **Livre supprimé** : son créateur ne supprime ou ne détache que ses recettes ; la boîte
  annonce les pages des autres membres conservées, et `onBookWritten` les détache à la
  suppression — elles deviennent des recettes libres de leurs auteurs, sans `book_id` orphelin.
- **Écrans** : brouillons d'autrui sans « Valider », « Supprimer » ni sélection dans la file ;
  badge « Recettes à valider » limité à ce qu'on peut valider ; actions recette par recette
  dans un livre ; export PDF d'un livre ouvert à tout lecteur par une icône directe ; écran de
  modification du contenu d'autrui ouvert par un lien remplacé par « Seul le créateur peut
  modifier… » ; message clair quand le compte n'est pas encore chargé.

Troisième passe :

- **Page détachée d'un livre privé** : elle restait publique après le détachement (par le
  serveur à la suppression du livre, ou par « Détacher les recettes »). Une recette sans livre
  garde désormais sa confidentialité, le serveur écrit `is_private: true` en détachant les
  pages d'un livre privé, et une recette libre privée n'est plus rangée dans « Mes recettes
  libres ».
- **Recette privée lue par une callable** : conseil de dressage, conseil de conservation,
  visuel d'une étape et calcul de nutrition refusent la recette privée d'un autre, avant tout
  appel de modèle (`assertCanReadRecipe`). Qui peut écrire un conseil reste à décider.
- **Modération** : un document antérieur à l'épinglage n'est plus approuvé si le fichier a
  changé depuis l'analyse ; il repasse en attente.
- **Storage** : `covers/`, `illustrations/{uid}` et `users/{uid}` ne se listent que par un
  admin ; le test « un compte en attente ne liste pas un dossier publié » devient bloquant.
- **`book_id` avec « / »** refusé par les règles, signalé par le serveur.
- **Écrans** : boîte de suppression d'un livre ouverte aussitôt, décompte « au moins N », jamais
  « vos » pour un admin sur le livre d'un autre, message d'échec en clair ; export PDF dans
  « Plus d'options », ouvert à tout lecteur ; lignes d'autrui grisées en mode sélection et
  menu absent quand il n'a rien à proposer ; écrans d'édition avec chargement et erreur de
  compte distincts du refus ; relecture d'un brouillon alignée sur la file pour l'admin.

Quatrième passe :

- **On ne range une recette que dans ses propres livres** (décision de l'utilisateur, option
  A) ; l'administrateur partout. Les règles l'exigent à la création et à tout changement de
  livre (le livre doit exister) ; le pipeline d'import le vérifie avant d'écrire hors règles
  (`assertJobTargetBook`) ; le sélecteur de livre ne propose que les livres de l'utilisateur,
  tous pour un administrateur. Les pages déjà rangées chez un autre y restent, sans migration.
- **Recette libre privée** : enregistrer ou valider une recette sans livre ne réécrit plus sa
  confidentialité ; elle ne redevient pas publique.
- **Modération** : un ancien document jugé inchangé est promu en épinglant la génération lue
  à la vérification.
- **Suppression d'un livre par un administrateur** : la question et le message disent « pour
  tous leurs auteurs », y compris sur son propre livre ; la ligne du décompte est réservée
  pendant la recherche.

Cinquième passe :

- Enregistrer une page rangée dans le livre privé d'un autre ne relit plus ce livre (lecture
  refusée) : le livre n'est lu qu'à un changement de livre.
- `book_id` doit être nul ou une chaîne.
- Sélecteur de livre : le livre d'origine d'une page rangée chez un autre reste en tête, avec
  « Livre d'un autre membre. Choisir un de vos livres y déplace la recette. » ; pour un
  administrateur, les livres système des autres sont masqués.
- Import : un lien vers le livre d'un autre n'est plus verrouillé, le choix est effacé ;
  « Ce scan sera ajouté au livre : … » affiche le titre, jamais l'identifiant. Un refus du
  serveur part en dead letter avec `failure_reason: foreign_book`.
- Boîte de suppression d'un livre : hauteur stable pendant le décompte, bouton « Supprimer
  aussi » en couleur d'erreur lisible.

Tests des règles : 269, dont 255 actifs et 14 `todo` (hors périmètre).

**À lancer après le déploiement : Admin › Backfills › « Reprendre la confidentialité des
livres »** (un passage, sans appel d'IA). La reprise « Reprendre la confidentialité » de
l'automne avait posé `is_private` sur les recettes, pas sur les livres ; les règles ne
laissant lire le livre d'un autre que s'il porte `is_private == false`, un livre sans le champ
disparaîtrait de la bibliothèque familiale jusqu'à ce passage.

### v0.23.7 — technique

#### Une suite de tests pour les règles Firestore et Storage

Aucun test ne rejouait `firestore.rules` ni `storage.rules`. Une règle modifiée partait en
production sur la seule foi d'une relecture.

- Nouveau paquet `kass_dalle/rules-tests/`, séparé de `functions/` : son `npm test` lance les
  émulateurs Firestore et Storage sur le projet fictif `demo-kassdalle` et rejoue les règles
  du dépôt avec `@firebase/rules-unit-testing`. `firebase-tools` y est épinglé à 15.32.1,
  comme dans `deploy.yml`. Java 21 est requis.
- 192 tests, rôle par rôle (admin, éditeur, lecteur, en attente, révoqué, sans claim,
  fondateur, anonyme) : 161 décrivent le comportement actuel et doivent passer ; 31 sont
  marqués `todo` et décrivent l'attendu corrigé. 30 couvrent une faille encore ouverte de
  l'audit du 2026-10-09, dont la décision de propriété : un document privé n'est lu que par son
  créateur et l'administrateur, et chacun ne modifie que ses recettes et ses livres. Un `todo`
  qui échoue ne fait pas échouer la suite ; la correction d'une faille retire son `todo`.
- Écart constaté contre l'émulateur : `isActive()` (`storage.rules`) refuse la lecture
  Storage à un jeton qui ne porte aucun claim, alors que son commentaire le dit traité comme
  actif. La clé `revoked` absente fait lever une erreur à la comparaison, et l'erreur vaut
  refus. Le test correspondant est marqué `todo` jusqu'à la correction de la règle.
- `.claude/hooks/session-start.sh` installe aussi les dépendances de `rules-tests/`, et
  avertit sans échouer quand Java manque.
- CI : nouveau job « Règles — émulateur ». Le déploiement exige une CI entièrement verte,
  donc une règle qui casse un test bloque la mise en production. Le workflow `ci.yml` n'a plus
  que le droit `contents: read`.
- `CLAUDE.md` et l'agent `securite` : une règle corrigée s'accompagne de son test dans la
  suite, et le `todo` de la faille corrigée disparaît.

### v0.23.6 — technique

#### Un agent de sécurité dans la chaîne de travail

La faille de l'import par un lecteur (corrigée en v0.23.5) existait depuis des semaines. Un
audit de documentation l'a trouvée ; aucun agent de relecture ne cherchait les failles.

- Nouvel agent `securite`, en lecture seule. Il relit un diff qui touche les règles Firestore
  ou Storage, une Cloud Function, l'authentification et les rôles, `firebase.json` ou
  `.github/`. Il cherche les droits par rôle, le coût abusif d'IA, les données privées, les
  entrées non fiables et les secrets, avec pour chaque constat un chemin réaliste.
- `CLAUDE.md` : l'étape 3 de la chaîne de travail l'appelle pour ces diffs, ainsi que pour
  `deploy.ps1` et les écrans qui masquent une action selon le rôle. Une règle Firestore ou
  Storage corrigée s'accompagnera d'un test de règles quand la suite existera ; d'ici là,
  l'agent décrit le cas de test attendu.
- `developpement-tech-couts` et `product-owner-release` citent cette relecture.
- `CLAUDE.md`, « Une question appelle une réponse » : la réponse se termine par le constat,
  une proposition au besoin, et l'attente d'un « oui » explicite avant toute écriture.

### v0.23.5 — fonctionnel

#### L'import est réservé aux éditeurs

Importer une recette ou un livre (`/scan`) lance des appels d'IA facturés. C'était réservé à
l'éditeur et à l'admin dans les documents, mais les règles Firestore laissaient un lecteur
créer son `processing_job`, et donc lancer le pipeline. `firestore.rules` exige maintenant
`isEditor()` pour créer un job, toujours à son propre nom. La relance d'un job, qui le remet
en file et relance le pipeline, exige aussi ce droit. Un propriétaire qui n'est plus éditeur
ne peut écrire que l'annulation exacte (`status: 'error'`, `cancel_requested: true`).

Côté écran, un lecteur ne voit plus les boutons « Importer » et « Relancer » de la file des
brouillons, ni l'action « Nouveau scan » après la suppression d'un scan source. S'il ouvre
`/scan` par un lien, l'écran lui dit que l'import est réservé aux éditeurs, au lieu du
formulaire, avec un bouton « Retour à la bibliothèque ». Sa file des brouillons vide lui dit
d'où viennent les brouillons et comment voir ceux de sa famille. Joindre un fichier source à
sa propre recette reste permis.

L'écran des garnitures simples, vide, renvoyait à un backfill « Semer les garnitures
simples » qui n'existe plus. Il invite maintenant à en ajouter une avec « Nouvelle
garniture ».

### v0.23.4 — technique

#### Chaque changement met à jour ses documents

`CLAUDE.md` demandait de tenir les diagrammes à jour, sans dire lesquels pour quel
changement. Aucun agent n'avait la charge des cas d'utilisation, et `developpement-tech-couts`
n'avait aucune consigne sur la documentation. Résultat : `cas-d-utilisation.html` datait du
29 août, `diagramme-de-classes.html` du 13 septembre, `diagrammes-de-sequence.html` du
27 septembre.

- `CLAUDE.md` : un tableau associe chaque catégorie de changement (écran, route, Cloud
  Function, flux, modèle Firestore, règles, prompt, logique dupliquée, déploiement, version) aux
  documents à mettre à jour dans le même commit. Un élément retiré du code sort aussi des
  documents, sauf du changelog. Un simple libellé n'appelle aucun document, et le bac à sable
  reste hors de `FunctionalRequirements.md` et des cas d'utilisation. Pour une release
  complète, `CLAUDE.md` et `product-owner-release` renvoient à ce tableau.
- `relecteur-regles` : le contrôle 10 applique ce tableau et vérifie les noms des diagrammes
  Mermaid contre le code.
- `developpement-tech-couts` : la documentation fait partie de son livrable.
- `business-analyst-culinaire` : il tient aussi `cas-d-utilisation.html`, avec son livrable
  de cadrage. Sans cadrage, `developpement-tech-couts` écrit tous les documents.

#### Rattrapage : 70 écarts corrigés entre le code et la documentation

Un audit a comparé le code aux six documents et relevé 71 écarts : 22 faux, 40 manquants,
9 obsolètes. 70 sont corrigés. Le dernier attend la PR de code qui réservera l'import aux
éditeurs et aux admins : `TechnicalRequirements.md` (§13.1) et `cas-d-utilisation.html`
décrivent cette décision et disent que les règles permettent encore l'import à un lecteur.
Le dépôt en quarantaine reste ouvert au lecteur, qui y dépose les images de ses recettes.

- `TechnicalRequirements.md` : diagnostic de qualité des données, 44 routes, redirection
  `?next=`, règles Firestore et Storage alignées sur les fichiers, `plating_advice` décrit
  comme un champ, modération et découpes d'illustrations, arbres des sources, CI, fixtures.
- `FunctionalRequirements.md` : rôle de repas posé à l'écriture, Admin › Backfills, accueil
  Admin, « Replanifier », retour après connexion, import d'un livre entier.
- `cas-d-utilisation.html` : 15 cas ajoutés (qualité des données, garnitures, livre entier,
  planning…). La liste de courses et l'ajustement des portions n'appellent plus l'IA dans
  les diagrammes, comme dans le code.
- `architecture.html` : 58 fonctions, section « Le déploiement », gardes et mémoire corrigées,
  tableau de la logique dupliquée.
- `diagramme-de-classes.html` : classes du planning, de la qualité des données et des rôles de
  repas ; le diagramme « Planifier » ne s'affichait pas, à cause d'un « ; » dans une étiquette.
- `diagrammes-de-sequence.html` : séquences 06 et 15 réécrites, six séquences ajoutées (25 à
  30). Deux diagrammes qui ne s'affichaient pas sont réparés. Les 31 blocs Mermaid passent le
  parseur.

### v0.23.3 — technique

#### Le déploiement libère de la place sur le disque du runner

Les trois échecs du workflow à « Revérifier l'APK en ligne » (v0.23.1 et v0.23.2) avaient une
cause commune : le runner a planté sur `No space left on device`. SDK Flutter, caches Gradle,
build de l'APK et build web remplissaient son disque.

- Nouvelle étape « Libérer de la place sur le disque », en tête du job : suppression d'outils
  préinstallés inutiles au déploiement (.NET, GHC, Swift, Boost, CodeQL, images Docker…).
- `build-apk.sh` supprime `build/app` une fois l'APK copié dans `build/web`.
- La seconde lecture ne télécharge que le manifeste, plus l'APK.
- `runner-resources.sh` est retiré : ses annotations ne sont publiées qu'à la fin du job, et
  un runner qui plante ne les envoie pas.

#### Le changelog redevient une étape de chaque version

Aucune entrée n'avait été écrite de la v0.22.104 à la v0.23.2 : ni `CLAUDE.md`, ni les agents,
ni les skills ne demandaient de tenir ce fichier. Les entrées de ces douze versions ont été
rédigées après coup, depuis l'historique git.

- `CLAUDE.md` : l'étape « Versionner » de la chaîne de travail et les deux séquences de
  déploiement demandent l'entrée du changelog dans le même commit que la version. La section
  « Documentation à tenir à jour » décrit son format.
- `relecteur-regles` : nouveau contrôle 11. Une version incrémentée sans entrée est une
  anomalie. Les contrôles « Artefacts de build » et « Outillage » deviennent 12 et 13.
- `product-owner-release` : ses deux séquences de déploiement demandent l'entrée du
  changelog, et la checklist go/no-go vérifie que chaque version de la release a la sienne.

### v0.23.2 — technique

#### Délais sur la lecture de l'APK en ligne, démons Gradle arrêtés

Le workflow de la v0.23.1 s'est arrêté deux fois à « Revérifier l'APK en ligne », après le
build de l'APK et le déploiement des Functions : la première tentative au bout de 4 s sans
journal, la seconde bloquée 13 min, puis annulée. La cause n'est pas établie.

- `build-apk.sh` arrête les démons Gradle et Kotlin après le build et attend leur sortie.
- `runner-resources.sh` publie la mémoire disponible et le disque libre en annotation du run,
  après le build et dans une étape à part avant la seconde lecture de l'APK.
- `keep-online-apk.sh` : `curl --max-time`. Les étapes APK ont un `timeout-minutes`.

La v0.23.1 n'a jamais été publiée sur le web ni en APK : la v0.23.2 lui succède directement.

## 2026-10-08

### v0.23.1 — technique

#### Sur le PC aussi, on déploie par un push sur `master`

Le workflow GitHub « Déploiement » devient le chemin normal, sur le PC comme depuis une session
cloud. `deploy.ps1` reste l'outil de secours.

- `deploy.ps1` lance la CLI Firebase avec `--non-interactive`. Sa sortie part dans un journal :
  une question de la CLI, ici sur la suppression de `backfillAiPricingFn`, attendait une
  réponse que personne ne voyait.
- Le workflow ne saute plus que les commits signés `Deploy-Source: deploy.ps1`. Le filtre sur
  le préfixe `deploy:` aurait sauté un commit poussé à la main avec ce préfixe.
- Le rôle Cloud Tasks Admin, requis depuis la v0.22.109, manquait encore au compte de
  service `github-deploy` : le premier déploiement de la v0.23.1 a échoué sur
  `cloudtasks.queues.get` (403) pour la file de `recipeProcessor`. Le rôle a été posé le
  8 octobre au soir, et la relance a déployé les Functions.

### v0.23.0 — fonctionnel

Version déployée depuis le PC par `deploy.ps1`.

- **Rôle d'une recette dans un repas, à l'écriture.** Le déclencheur `onRecipeWritten` pose
  `tags.meal_role` sur toute recette écrite sans ce champ : création manuelle sans clic
  « Suggérer », recette de l'Explorer IA, copie d'une recette non classée. Nouveau poste de
  coût `inline_meal_role_classification`, inscrit aux trois endroits.
- **Backfills retirés** : correction de la grille tarifaire (`backfillAiPricingFn`),
  rattachement des recettes sans livre, semis des garnitures simples. Le domaine
  `meal_staple` et ses tests sont supprimés.
- **Storage** : la lecture des images partagées revient à `isActive()`. L'essai du 5 octobre,
  qui l'alignait sur le jeton approuvé, avait coupé l'accès au fondateur le temps que son
  jeton porte le claim de rôle.
- **CSP** (`firebase.json`, en rapport seul) : `https://www.google.com` autorisé en script et
  en cadre.

### v0.22.111 — technique

#### APK signé construit par le workflow quand la version change

Le workflow « Déploiement » construit un nouvel APK signé quand la version de `pubspec.yaml`
dépasse celle de l'APK en ligne, et conserve sinon celui qui est en ligne. La clé de signature
est posée en secrets GitHub (`ANDROID_*`). L'APK en ligne est vérifié avant les Functions, puis
revérifié juste avant le hosting.

### v0.22.110 — technique

#### Agents : trois skills, et un agent `ux-designer`

Skills `logique-dupliquee`, `backfill` et `experience-sandbox`, à côté de `nouveau-poste-ia`.
Nouvel agent `ux-designer`, en lecture seule : proposition d'un parcours avant le code, revue
des écrans après. Les agents d'origine suivent la chaîne de travail.

### v0.22.109 — technique

#### Relance ciblée des Functions en échec

`firebase-deploy.sh` et `deploy.ps1` relancent les seules fonctions nommées en échec par la CLI
(`--only functions:<nom>`). Une relance complète sautait `recipeProcessor` comme « inchangée »
et annonçait un succès alors que sa file Cloud Tasks avait échoué.

Le compte de service `github-deploy` a besoin du rôle Cloud Tasks Admin : la CLI lit et met à
jour la file de `recipeProcessor` (`cloudtasks.queues.get`, `cloudtasks.queues.update`).

### v0.22.108 — technique

#### Chaîne de travail des agents, hook de formatage, miroirs Copilot retirés

`CLAUDE.md` décrit la chaîne de travail : cadrage, implémentation, relecture obligatoire par
`relecteur-regles`, version, PR, déploiement. Hook `format-on-edit.mjs` : `dart format` ou
Prettier après chaque écriture. Les miroirs Copilot (`.github/agents/`, `.github/instructions/`) sont retirés :
`CLAUDE.md` est la seule source des instructions.

### v0.22.107 — technique

#### Déploiement automatique par GitHub Actions

`.github/workflows/deploy.yml` déploie les Functions, le web et les règles après une CI verte
sur `master`. Il vérifie que le commit est encore la tête de `master`, et ne redéploie pas un
commit de `deploy.ps1`. Compte de service `github-deploy`, clé en secret
`FIREBASE_SERVICE_ACCOUNT`.

Moteur d'IA, dans la même version : `backfill_shopping_aliases` quitte `ROUTABLE_FEATURES`, et
`withoutRetiredFeatures` retire de la politique affichée les seuls postes absents de
`ROUTABLE_FEATURES`. Sans ce filtre, `setAiRoutingPolicyFn` refusait d'enregistrer une
politique qui contenait encore un poste retiré.

Premiers éléments du réseau d'agents, dans la même version : hook `session-start.sh` (Flutter
et dépendances dans une session cloud), agent `relecteur-regles` et skill `nouveau-poste-ia`.

## 2026-10-05

### v0.22.106 — technique

Version déployée depuis le PC par `deploy.ps1`. CSP (en rapport seul) : `'wasm-unsafe-eval'` en
script, `https://*.googleapis.com` en image, `https://*.cloudfunctions.net` en connexion.

### v0.22.105 — technique

Version déployée depuis le PC par `deploy.ps1`.

- **Règles Firestore** : un membre approuvé ne crée une annotation qu'à son propre `uid`, et un
  groupe qu'avec lui-même pour seul membre et propriétaire. Le document `usage` n'accepte que
  `storage_bytes`, `updated_at` et le compteur de scans du mois courant ou précédent.
- **Règles Storage** : la lecture des images partagées exige un jeton approuvé (revenu en
  arrière en v0.23.0).
- **En-têtes web** : `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, et une
  CSP en rapport seul.
- **Backfills retirés** : confidentialité des recettes (`backfillRecipePrivacyFn`) et mode
  « produit acheté des ingrédients » du backfill des courses.
- `sharp` passe de 0.33 à 0.35.

### v0.22.104 — fonctionnel

#### Qualité des données (Admin › Monitoring)

Diagnostic en lecture seule des référentiels nutrition : produit d'achat manquant, nutrition
incomplète ou en échec, sel invraisemblable (plus de 100 g pour 100 g), unités de mesure non
confirmées. Compteurs exhaustifs, et un échantillon cliquable qui ouvre l'écran du référentiel
concerné, recherche préremplie.

### v0.22.103 — technique

#### Un backfill restait inappelable depuis sa création, faute de permission Cloud Run

« Reprendre la confidentialité » échouait en pur réseau (« Failed to fetch ») dès le premier
essai — jamais lancée avant, aucun point de reprise en base. Sa politique IAM Cloud Run
n'accordait `run.invoker` à personne, alors que toute fonction `onCall` sœur l'accorde à
`allUsers` (la vraie autorisation reste `requireAdmin`, à l'intérieur de la fonction) : la
requête `OPTIONS` de préflight recevait un `403` en zéro seconde, avant même d'atteindre le
code. Comme son code n'avait jamais changé depuis son premier déploiement, chaque
`deploy.ps1` la passait en « Skipped — No changes detected » et ne reconciliait jamais cette
politique.

Vérifié par comparaison directe des politiques IAM Cloud Run (`backfillAiPricingFn` : `allUsers`
→ `run.invoker` ; `backfillRecipePrivacyFn` : aucune liaison). Corrigé en forçant un
redéploiement réel — un commentaire qui documente l'incident, pas une commande d'infrastructure
à la main.

Le même passage a mesuré l'arriéré réel de cinq backfills, contre leur dernier compte rendu
affiché plutôt que leur présomption : 11 recettes sans `is_private`, 309 ingrédients sans
`shopping_product`, 13 recettes sans rôle de repas, et « Reprendre le sel des ingrédients »
jamais lancée une seule fois. Aucun n'est aussi définitivement terminé que la correction de la
grille tarifaire — les référentiels qu'ils corrigent grossissent à chaque import, le travail ne
se vide jamais pour de bon.

- `callable/privacyBackfillCallable.ts` : commentaire daté, sans changement de comportement.

## 2026-09-28

### v0.22.102 — fonctionnel

#### Valider en lot n'exclut plus silencieusement les brouillons à réserve de fidélité

La validation groupée (Brouillons & Traitements) laissait de côté, sans recours, tout brouillon
portant une réserve de fidélité — l'unique façon de le valider était de le rouvrir un par un
depuis l'écran de relecture. Sur un lot de plusieurs dizaines de brouillons, ça obligeait à
cliquer autant de fois que de réserves, pour des recettes que personne n'allait relire de toute
façon.

Le geste change : le dialogue de confirmation **avertit** — combien portent une réserve, et que
l'IA a un doute sur la fidélité de la copie — mais n'empêche plus de continuer. Confirmer valide
tout le lot, réserve comprise, exactement comme une validation individuelle l'aurait fait. Le
bouton annonce désormais ce compte complet (`Valider (N)`), pas seulement la part sans réserve.

Un brouillon sans contenu reste exclu dans tous les cas : il n'y a rien à publier, avertir n'y
changerait rien. La relecture individuelle, elle, continue d'exclure la réserve — un geste sur un
seul brouillon n'a pas la même raison d'être pressé qu'un lot de cinquante.

- `work_queue_batch.dart` : `DraftValidationPlan.validatableInBatch`, `notValidatedNote` et
  `validationSummary` prennent `reserveIncluded`.
- `work_queue_screen.dart` : `_validateDrafts` inclut la réserve en lot, après confirmation.

### v0.22.101 — technique

#### Les deux plus gros prompts Claude se mettent en cache

`TRANSCRIPTION_PROMPT` (~2 900 jetons, `transcription_page`) et `TAGGING_PROMPT` (~3 250
jetons, `recipe_tagging`) sont les deux plus gros prompts du projet, sur les deux postes les
plus appelés — jamais mis en cache jusqu'ici, ce que le code documentait lui-même sans jamais
le faire. Un fragment relu depuis le cache Anthropic coûte un dixième du tarif d'entrée : de
quoi économiser environ 90 % sur cette partie du prompt, à chaque appel après le premier
d'une fenêtre de cinq minutes.

`textPart(texte, { cache: true })` marque le fragment à mettre en cache ;
`toAnthropicContent` pose `cache_control: { type: "ephemeral" }` sur le bloc correspondant.
Chaque prompt a demandé un geste différent, pas la même correction :

- **Transcription** : le prompt statique passait en DERNIER dans le message, l'image de la
  page en premier — jamais de cache possible, l'image change à chaque appel et divergeait
  avant même d'atteindre le prompt. Il passe désormais en tête.
- **Balisage** : le prompt statique était déjà en tête, mais fondu avec la transcription de la
  recette dans une seule chaîne de caractères. Anthropic met en cache un bloc ENTIER, jamais un
  fragment d'une chaîne : il fallait séparer les deux en deux `textPart`, pas les réordonner.

- `ai/types.ts` : `ModelPart.cache`, option de `textPart`.
- `ai/anthropic.ts` : `toAnthropicContent` (exporté) pose `cache_control`.
- `gemini/transcription.ts`, `gemini/tagging.ts` : `TRANSCRIPTION_PROMPT` et `TAGGING_PROMPT`
  marqués, réordonné pour le premier, séparé pour le second.
- `tests/anthropicPromptCache.test.ts` — nouveau.

### v0.22.100 — technique

#### Le chemin à points ne suffisait pas : `set()` ne le lit pas comme `update()`

Le corrigé de v0.22.99 posait les bons chemins (`anthropic_models.transcription_page`) mais par
`docRef.set(writeData, {merge: true})` — et `set()`, même en fusion, ne résout pas une clé à
points comme un chemin vers un champ imbriqué : il la prend pour un nom de champ littéral. Le
poste ne bougeait toujours pas, cette fois parce que l'écriture posait un champ superflu au lieu
d'atteindre `anthropic_models.transcription_page`.

Seul `update()` réserve la notation à points à cet usage. `setAiRoutingPolicyFn` et l'action
`update` des préconfigurations appellent désormais `update()`, jamais `set()` — sans risque
d'y trouver un document absent : le premier existe toujours (`getAiRoutingPolicy()` le sème dès
sa première lecture), le second vient d'être vérifié par `requirePreset`.

- `callable/aiRoutingCallable.ts` : `docRef.update(writeData)` / `ref.update(writeData)`, à la
  place de `set(..., {merge: true})`.

### v0.22.99 — technique

#### Cause trouvée : `set(..., {merge: true})` ne fusionne pas une carte par poste

Le journal de v0.22.98 a tranché en un essai : le client envoyait le bon brouillon —
`anthropic_models` reçu par le serveur ne portait déjà plus `transcription_page` — et la
validation le laissait tel quel. La disparition avait donc lieu à l'écriture Firestore elle-même.

`set(champ, {merge: true})`, quand `champ` est fourni comme un objet entier, ne supprime pas les
clés absentes de ce nouvel objet : elles survivent telles quelles dans le document. Redonner la
carte `anthropic_models` sans `transcription_page` ne l'efface donc pas — c'est le mécanisme
inverse de ce que documentait, à tort, le commentaire retiré cette version-ci.

Le corrigé : chaque clé s'écrit désormais par son propre chemin à points
(`anthropic_models.transcription_page`), jamais la carte entière — la seule forme que Firestore
résout sans ambiguïté, y compris pour la supprimer (`FieldValue.delete()` posé sur le chemin
exact d'une clé retirée du brouillon). Écrire à la fois le champ entier et un chemin à l'intérieur
de ce champ dans le même appel serait par ailleurs refusé par Firestore.

Même défaut, même corrigé sur « Mettre à jour » une préconfiguration enregistrée : la carte
`policy.anthropic_models` d'une configuration existante avait le même problème, un niveau plus
bas. Le journal temporaire de v0.22.98 est retiré, la cause n'a plus besoin d'être observée.

- `callable/aiRoutingCallable.ts` : `applyMapDiff`, appliqué aux quatre cartes par poste
  (`features`, `anthropic_models`, `anthropic_efforts`, `thinking_budgets`) dans
  `setAiRoutingPolicyFn` et dans l'action `update` des préconfigurations.
- `tests/aiRoutingPolicyWrite.test.ts` — nouveau.

### v0.22.98 — technique

#### Journal temporaire : un modèle Claude effacé par poste ne ressort pas de la grille

Retirer l'exception de `transcription_page` dans Admin → Moteur d'IA (retour au modèle par
défaut) affiche « enregistré », un nouvel horodatage s'écrit dans `app_config/ai_routing_policy`,
et pourtant `anthropic_models.transcription_page` garde sa valeur d'avant. Le mécanisme
d'écriture (`setAiRoutingPolicyFn`, remplacement complet de la carte, pas une fusion clé par
clé) et la lecture du brouillon (`_ModelPicker`, `_setModelFor`) ont été relus sans y trouver de
défaut : cause encore ouverte.

`setAiRoutingPolicyFn` journalise désormais, à chaque enregistrement, les modèles et efforts
reçus du client en face de ceux retenus après validation — de quoi trancher entre un brouillon
qui n'a pas changé et une validation qui réintroduit une clé. Journal temporaire, à retirer une
fois la cause connue.

- `callable/aiRoutingCallable.ts` : `logInfo` dans `setAiRoutingPolicyFn`.

### v0.22.97 — technique

#### Le bouton Enregistrer de Moteur d'IA était hors champ

Ajouter `anthropicEfforts` (v0.22.95) a manqué la comparaison `_dirty` de l'écran : ne
changer QUE des efforts de réflexion laissait le drapeau à faux, la barre d'enregistrement ne
s'affichait pas, et `PopScope` laissait quitter l'écran sans prévenir. Un cas réel l'a montré :
vingt-sept efforts posés à la main, aucun bouton visible, rien enregistré — la configuration
avait fini dans une préconfiguration nommée (« Enregistrer sous… ») au lieu du routage en
vigueur, faute de trouver le bon bouton.

Deux corrections :

- `_dirty` compare désormais aussi `anthropicEfforts`, comme il le fait déjà pour le modèle et
  le plafond de raisonnement par poste.
- Une icône « Enregistrer » rejoint le bandeau du haut, toujours visible, en plus de la barre du
  bas qui vit en fin d'un formulaire de plus de quarante postes — et se confondait au premier
  coup d'œil avec « Enregistrer sous… », qui range une préconfiguration à part sans toucher au
  routage en vigueur.

- `ai_routing_screen.dart` : `_dirty` (comparaison `anthropicEfforts`), icône dans
  `appBar.actions`.

### v0.22.96 — technique

#### Un backfill corrige la grille tarifaire, au lieu d'une saisie à la main

Le tarif de Sonnet 5 restait faux dans `app_config/ai_pricing` (3 $ / 15 $ au lieu de
2 $ / 10 $) parce que la seule façon de le corriger était une saisie manuelle depuis
Admin → Tarifs — une valeur tapée à la main, sans trace de sa source, dans le seul endroit
du projet où un nombre de facturation s'écrit ainsi.

`PRICING_CORRECTIONS` (`ai/pricing.ts`) porte désormais la valeur vérifiée, documentée avec sa
source. `backfillAiPricingFn`, exposé dans **Admin → Backfills → « Corriger les tarifs »**,
l'applique à la grille en vigueur : un modèle déjà au bon tarif ressort « déjà correct », les
autres sont corrigés et comptés. Aucun appel d'IA, un seul document Firestore, réentrant par
construction — relancer après une première correction ne trouve plus rien à corriger.

Une correction de tarif rejoint ainsi la règle générale du projet : une écriture ponctuelle sur
des données passe par Admin › Backfills, jamais par une saisie ad hoc ni par un script lancé
depuis la machine de développement.

- `ai/pricing.ts` : `PRICING_CORRECTIONS`, `pricingNeedsCorrection`.
- `callable/aiPricingBackfillCallable.ts` : `backfillAiPricingFn`.
- Client : `GcpBillingRepository.backfillAiPricing`, tuile « Corriger les tarifs » dans
  `AdminBackfillsScreen`.

### v0.22.95 — technique

#### L'effort de réflexion Claude se règle depuis Admin, poste par poste

Le modèle Claude se choisissait déjà par poste depuis Admin → Moteur d'IA, sans déploiement ;
l'effort de réflexion, lui, restait une constante de code (`TAGGING_EFFORT`, l'« high » de
`transcription.ts`). Une mesure sur la lecture de page (27-28 septembre 2026, voir plus bas) a
montré que ce levier mérite le même geste : `app_config/ai_routing_policy` porte désormais
`anthropic_efforts` (par poste), résolu par `resolveAnthropicEffort` et appliqué dans
`callModel` avant l'appel. Absent d'un poste, celui-ci garde l'effort que son propre code
demande — il n'y a pas de repli commun sensé entre la lecture d'une page et un rappel de
calories. L'écran affiche le sélecteur à côté de celui du modèle, avec une puce « Réglage du
code » qui efface l'exception plutôt que de la pointer vers une valeur partagée.

- `ai/router.ts` : `AiRoutingPolicy.anthropicEfforts`, `resolveAnthropicEffort`, branchement
  dans `callProvider`.
- `ai/routingPresets.ts` : validation, lecture et écriture du nouveau champ dans les
  configurations enregistrées.
- `callable/aiRoutingCallable.ts` : `ANTHROPIC_EFFORT_CHOICES` exposé à l'écran.
- Client : `AiRoutingPolicy.anthropicEfforts` (Dart), `_EffortPicker`, et une ligne de plus
  dans `AiRoutingDiff` — un chargement de configuration qui changerait l'effort d'un poste le
  dit, comme il le fait déjà pour le modèle.

#### Lecture de page : décision prise, Sonnet 5 remplace Opus 5

Sur les 6 pages mesurées (voir § 6 de `TechnicalRequirements.md`), les deux erreurs trouvées —
une lettre insérée par Sonnet 5 dans un titre à lettrine décorative, un désaccord de comptage
par candidat sur deux autres pages — ont été jugées mineures et sans effet sur la
compréhension de la recette. `transcription_page` passe donc à Sonnet 5, effort `high`
inchangé. **C'est un réglage d'Admin → Moteur d'IA (`anthropic_models`), pas un déploiement** :
aucun changement de code ne l'accompagne, il reste à le poser depuis l'écran.

#### Rappel : la grille tarifaire de Sonnet 5 est encore fausse en production

`app_config/ai_pricing` porte toujours 3 $ / 15 $ pour `claude-sonnet-5` ; le tarif réel,
vérifié le 26 septembre 2026 contre la page officielle et contre le rapport de coûts
d'Anthropic, est 2 $ / 10 $ (voir v0.22.94 et la mémoire du projet). Basculer
`transcription_page` sur Sonnet 5 sans corriger ce prix ferait mentir le reporting de coûts
sur un poste dont le volume augmente. La v0.22.96, ci-dessus, livre le backfill qui corrige
ce tarif en un clic.

## 2026-09-27

### v0.22.94 — technique

#### Balisage d'une recette : effort de réflexion réduit

Suite à v0.22.93 (voir plus bas), l'effort de réflexion du balisage (`recipe_tagging`) passe de
`high` à `low`. Mesuré le 26 septembre 2026 sur 33 recettes d'un même livre, rejouées aux deux
efforts : même contrôle de fidélité (`checkFidelity`), aucune rupture de plus, 0,118 $ l'appel
contre 0,298 $, et 0 réponse coupée au plafond sur 33 (contre 40 sur 75 à `high`).

Ce qui se perd, mesuré sur les mêmes 33 recettes : dans les étapes, `low` remplit environ 27 % de
quantités en moins (21 recettes sur 27). Sans conséquence tant que la liste d'ingrédients — qui ne
varie pas avec cet effort — porte déjà le nombre, ce qui est le cas ordinaire. Le risque accepté
est le cas où l'étape est la seule source du nombre, la liste ne le portant pas : rejoué deux fois
sur la même recette (une pincée de sel de mer, quatre fois dans les étapes, absente de la liste),
`low` l'a perdu les deux fois. Un ingrédient d'assaisonnement sans dose indiquée, dans les recettes
où le livre ne la donne qu'en passant, est le compromis retenu.

- `gemini/tagging.ts` : `TAGGING_EFFORT` passe à `low`. `TAGGING_RETRY_EFFORT` valant déjà `low`,
  `taggingEfforts()` ne tente plus qu'un seul effort par balisage — il n'y a rien de plus bas où
  retomber si la réponse est coupée, mais le risque de coupure recule avec l'effort.
- Ce réglage s'applique à toutes les recettes scannées, livre ou page seule, pas seulement à
  l'import qui a servi de mesure.

## 2026-09-26

### v0.22.93 — fonctionnel

#### Import d'un livre : un plafond de dépense, et une relance qui ne relit plus la page

L'import du livre de Jamie Oliver a coûté 59,89 $ affichés, avec 77 tranches, 37 recettes créées et
6 tranches en erreur. 31,54 $ (53 %) ont été facturés pour des appels dont le résultat a été écarté :
40 balisages sur 75 se sont arrêtés au plafond de sortie sans rien rendre de lisible, et chaque échec
rejouait le job depuis le début, transcription comprise.

- **Le plafond de l'import se fixe avant son départ.** L'écran de confirmation propose un montant en
  dollars — l'estimation plus la moitié, ou 0,50 $ par import sans estimation — avec son équivalent
  en euros. Le bouton « Lancer l'import » reste grisé sans montant supérieur à zéro. Quand le plafond
  est atteint, les imports restants s'arrêtent avec « Plafond de cet import atteint ». Relancer une
  tranche depuis la file relève le plafond d'un palier de la même taille.
- **La relance ne relit plus la page.** La transcription réussie est gardée sur le traitement : un
  balisage qui échoue, puis se rejoue, ne refait plus l'appel le plus cher.
- **Un balisage coupé est refait une fois avec moins de réflexion**, au lieu d'être rejoué trois fois
  à l'identique.
- **L'estimation de coût d'un livre se mesure sur les livres déjà importés**, par tranche. Elle
  comptait le livre entier comme un seul scan, et aurait annoncé un coût multiplié par le nombre de
  tranches au livre suivant.

Non modifié : l'effort de réflexion du balisage reste à `high`. Le passer à `medium` demande une
mesure du taux d'avertissements de fidélité sur les mêmes transcriptions.

### v0.22.93 — technique

- `ai/importBudget.ts` (nouveau) : `scan_spend/{scanId}` porte le compteur du scan (`recordUsage` y
  ajoute chaque appel qui a un `scanId`) et le plafond (`limit_usd`, `step_usd`). `runBookImport` le
  pose depuis `budget_limit_usd` sans jamais le baisser ; `recipeProcessor` le relit avant le premier
  appel de chaque tranche de livre (`assertWithinImportBudget`) ; `jobDispatcher` le relève à
  `cost_usd + step_usd` quand une tranche revient en `queued` et que le plafond est atteint. La
  nutrition calculée plus tard sur ces recettes n'est pas contrôlée. Règle Firestore : lecture admin,
  écriture serveur seul.
- `pipeline/transcriptionCheckpoint.ts` (nouveau) : la transcription est écrite sur le job
  (`transcription_checkpoint`, chaîne JSON, 300 000 caractères au plus) et relue par la tentative
  suivante ; effacée quand le job aboutit. Illisible, elle est journalisée et la page est transcrite
  de nouveau.
- `gemini/tagging.ts` : `runTaggingAttempts` refait le balisage à `low` quand `stop_reason` vaut
  `max_tokens` ; coupé aux deux efforts, `TaggingTruncatedError` envoie le job en dead letter
  `tagging_truncated` sans nouvelle tentative Cloud Tasks.
- `books/importEstimate.ts` : `referenceCostPerWindow` (somme des coûts sur somme des tranches des 3
  derniers livres) remplace la moyenne des pages scannées quand un livre existe ; les tranches
  (`book_window`) sont exclues de la moyenne des pages, lue sur 300 jobs au lieu de 80.
  `analyzeBookFileFn` rend aussi `referenceKind` et `suggestedBudgetUsd`.
- Client : `ProcessingJob.budgetLimitUsd` (`budget_limit_usd`), `confirmBookImport({required
  budgetLimitUsd})`, champ « Plafond de cet import » dans `_BookConfirmationCard`
  (`parseBudgetInput`, `formatBudgetInput`).
- `ai/pricing.ts` et `ai_pricing.json` : commentaires corrigés. Sonnet 5 vaut 2 $ / 10 $ en
  permanence (page des tarifs d'Anthropic ; rapport de coûts du 26 septembre relu contre les jetons
  de `ai_usage`). La grille en vigueur, dans Firestore, portait 3 $ / 15 $ : elle se corrige depuis
  Admin → Moteur d'IA, puis Admin → Coûts → « Reconstruire les agrégats » avec « Rechiffrer aussi
  les appels ».

### v0.22.92 — fonctionnel

#### Valider ou supprimer des brouillons par lot

La file « Brouillons & Traitements » a un bouton « Sélectionner » dans la barre du haut. Il
fait apparaître une case sur chaque ligne, sans appui long. Une barre en bas propose « Valider »,
« Relancer » et « Supprimer », avec le nombre d'éléments que chaque action touche. Une sélection
qui mêle brouillons et traitements garde les trois actions, chacune sur sa part.

Un lot avance avec une barre de progression. Un brouillon qui échoue n'arrête pas les suivants :
le compte rendu dit combien ont réussi et combien ont échoué. Un brouillon avec une réserve de
fidélité, ou sans contenu, n'est pas validé en lot : valider efface la réserve, et personne n'a
relu la page. Le compte rendu les nomme, et l'écran de relecture les valide un par un.

### v0.22.92 — technique

- `work_queue_batch.dart` (nouveau) : `planDraftValidation` répartit les brouillons cochés entre
  validés, réserve de fidélité et sans contenu ; `draftContent` ne remplace plus l'import par une
  copie de travail vide (valider écrit ce texte dans `raw_cooklang`) ; libellés des comptes rendus.
- `WorkQueueScreen` : mode sélection explicite (`_selectionMode`), actions lues sur les seuls
  éléments à l'écran (une clé cochée dont la ligne a disparu, ou dont la section est repliée, n'est
  jamais traitée), `_runBatch` séquentiel avec `reportUnexpectedError` par élément en échec. Les
  actions « Valider » et « Supprimer » d'une ligne passent par les mêmes chemins : elles
  signalent maintenant leurs erreurs, et « Valider » applique la règle de la réserve de fidélité.
- Une section gardée repliée depuis un autre filtre ne cache plus la liste quand la vue n'a plus
  d'en-tête pour la rouvrir.
- Tests : `work_queue_batch_test.dart` (logique) et `parcours/file_brouillons_selection_test.dart`
  (l'écran, sur Firestore en mémoire).

### v0.22.91 — fonctionnel

#### Un ingrédient écrit sans quantité (« roquette », « parmesan pour râper dessus ») est compté

Une ligne sans nombre ni unité sortait du calcul : la garniture et le fromage ne comptaient
ni dans les calories ni dans le poids. Une IA estime maintenant, une fois par ingrédient, la
quantité qu'une recette pour quatre personnes en emploie d'ordinaire. La ligne s'affiche
avec la mention « portion usuelle (30 g, estimée par l'IA) ». Les recettes déjà importées
l'obtiennent par la reprise de la nutrition (*Admin › Backfills*). Un assaisonnement garde sa
pincée, et une quantité ou une unité écrite garde son poids.

### v0.22.91 — technique

- `IngredientWeightOverride.usualPortionGrams` et `resolveWeighingInput(…, usualPortionGrams)`,
  cinquième cas de la règle « quantité absente », des deux côtés. Fixture partagée :
  section `usual_portion` de `unit_to_grams.json`.
- `estimateUsualPortionsWithAI` (`nutrition/aiEnrichment.ts`), appelée par `syncRecipeNutrition`
  avant le calcul. Poste `estimate_usual_portions`, inscrit dans `ROUTABLE_FEATURES`,
  `kFeatureCatalog` et `kFeatureProcess`. Champs de la fiche : voir § 3.10 de
  `TechnicalRequirements.md`.
- `NutritionContributionRow.usualPortion` et `nutritionAssumedUnitPhrase` : le tableau, le
  PDF et l'infobulle disent le poids et la source. La légende des quantités supposées parle
  d'une « quantité usuelle » dès qu'autre chose qu'une pincée s'y mêle.
- Aucun écran n'édite `usual_portion_g` : une correction se fait aujourd'hui dans la console
  Firestore.

### v0.22.90 — technique

- Prompt d'import (`promptsExtraction.ts`, passe de balisage) : quand une ligne nomme deux
  aliments et ne donne qu'un poids ou un volume, ce chiffre est celui du mélange. Il se
  répartit en parts égales, une par entrée, la taille du sachet restant dans la note. Deux
  entrées portant chacune le poids complet compteraient le double de l'achat. La règle
  n'agit qu'à l'import : une recette déjà importée garde ses quantités.

### v0.22.89 — fonctionnel

#### « Brin de basilic » se lit un brin

Un nombre absent devant « brin », « branche », « bouquet », « feuille » ou « gousse » vaut 1.
La ligne se pèse (2 g pour un brin de basilic) et s'affiche avec la mention « un brin ». Avant,
elle restait sans poids et sortait du calcul.

### v0.22.89 — technique

- `IMPLIED_ONE_UNITS` (TypeScript) et `_impliedOneUnits` (Dart), troisième cas de
  `resolveWeighingInput`. Sous-ensemble de `INGREDIENT_DEPENDENT_UNITS` : « pièce », « tranche »,
  « morceau » et « poignée » n'en font pas partie.
- La légende du tableau nutrition dit « à la pincée » quand toutes les quantités supposées sont
  des pincées, et « pour une quantité usuelle » sinon.

### v0.22.88 — fonctionnel

#### Quitter l'import d'un livre en cours d'envoi demande confirmation

Quitter l'écran d'import pendant l'envoi, le contrôle ou la lecture d'un livre — ou pendant
que le livre lu attend le feu vert — ouvre une boîte avec « Continuer » et « Annuler
l'import ». Le blocage couvre le retour, le menu de navigation (barre du bas et menu latéral)
et Ctrl+K. « Annuler l'import » coupe l'envoi en cours et supprime le fichier déjà arrivé.
Auparavant, quitter l'écran laissait l'envoi se poursuivre sans écran, et revenir remettait
tout à zéro. Le retour du navigateur web n'est pas couvert.

### v0.22.88 — technique

- `core/presentation/leave_guard.dart` : `leaveGuardProvider` et `goGuarded`. Un écran pose un
  garde de sortie ; `AppShell` le consulte avant chaque `context.go` de navigation.
  `PopScope` ne voit que le retour, pas ces appels.
- `ScanUploadNotifier` : `_bookAttempt` invalide une préparation abandonnée, qui s'arrête à
  sa prochaine étape et supprime ce qu'elle avait envoyé ; `_bookUpload.cancel()` coupe
  l'envoi. `reset()` et `cancelBookImport()` passent par `_abandonBook()`.
- `ScanScreen` : le retour au premier plan après une boîte de dialogue ne remet plus l'écran
  à zéro quand un livre est en préparation.
- `analyzeBookFileFn` : `discard` accepte aussi `quarantine/{uid}/livres/`, pour un livre
  abandonné avant la fin du contrôle.
- Tests : `leave_guard_test.dart`, `scan_screen_leave_test.dart`.

### v0.22.87 — technique

- `FOUNDER_DAILY_BUDGET_MULTIPLIER` passe de 10 à 100 (`ai/budget.ts`). Avec les plafonds par
  défaut (2 € et 400 appels par compte et par jour), le compte fondateur dispose de 200 € et
  40 000 appels par jour. Le multiplicateur porte sur les deux plafonds, et l'écran Admin › Coûts
  l'affiche tel que la fonction le rend (`×100`). Les autres comptes ne changent pas.

### v0.22.86 — fonctionnel

#### Ajouter un livre à partir d'un PDF ou d'un EPUB

La feuille « Ajouter un livre » propose une troisième voie : « Ajouter à partir d'un PDF ou
d'un EPUB ». Le fichier peut peser jusqu'à 300 Mo (PDF, EPUB ou Word). Avant tout import,
l'écran montre ce que le serveur a lu — nombre de pages ou de caractères, nombre d'imports
que le livre va créer — et un coût estimé, mesuré sur les 15 derniers imports de
l'utilisateur. Sans assez d'imports passés pour le mesurer, l'écran le dit et n'affiche
aucun montant. Rien n'est facturé avant « Lancer l'import ».

Le livre est créé depuis le fichier : un EPUB donne titre, auteur, éditeur, année, langue,
ISBN, description et couverture sans appel d'IA ; un PDF est lu par l'IA sur sa première
page. Le contenu est découpé en tranches, et les recettes arrivent une à une dans les
brouillons, rattachées au livre. « Importer un livre complet », dans le menu d'un livre
existant, suit le même chemin : il ne traitait auparavant tout le fichier que comme une seule
page.

### v0.22.86 — technique

- `bookDocumentScan` n'est plus une page : `recipeProcessor` l'aiguille sur `runBookImport`
  (`pipeline/bookImport.ts`), qui crée le livre puis un job `recipeScan` par tranche. Champs
  nouveaux sur `processing_jobs` : `parent_job_id`, `book_window`, `windows_total`,
  `windows_created`. Détail en § 3.4 de `TechnicalRequirements.md`.
- `books/bookFile.ts` : lecture PDF (`pdf-lib`, ajouté aux dépendances, chargé à la demande),
  EPUB (`jszip`, OPF et XHTML) et Word ; fenêtres de 3 pages + 1 de contexte, ou de 6 000
  caractères + 1 500. `bookWindowPreamble` dit au modèle quelles pages lui appartiennent.
- `analyzeBookFileFn` : lecture avant import et suppression d'un livre abandonné.
  `books/importEstimate.ts` : moyenne par scan des lignes `ai_usage`, sans repli figé.
- `scanAndPromoteUploadFn` : sous `quarantine/{uid}/livres/`, plafond de 300 Mo, contrôle en
  flux (`scanUploadHead`, `streamContainsEicar`). `storage.rules` : bloc `livres/`. Une archive
  ZIP est admise sous `.docx` et `.epub`.
- `attachmentPart` : un `text/plain` part comme texte, donc lisible par Claude ; il partait
  en document et retombait sur Gemini.
- `recipeProcessor` : mémoire portée à 2 GiB ; un `BookFileError` part en dead letter sans
  nouvelle tentative ; le comptage d'illustrations est sauté pour une tranche de livre.
- Tests : `bookFile.test.ts`, `bookImport.test.ts`, `book_import_analysis_test.dart`.

---

## 2026-09-13

### v0.22.67 — fonctionnel

#### Le format du repas : entrée, dessert, repas léger

Chaque jour de la semaine porte un format de repas dans les préférences du planning, à
côté de l'heure et des parts : plat seul (le défaut), plat et dessert, entrée et plat,
entrée, plat et dessert, ou repas léger. Un jour qui n'a rien réglé suit le plat seul et
ne stocke rien. Dans le nouveau planning, chaque créneau peut prendre un autre format le
temps du cycle, et le résumé du créneau le dit.

Quand le format le demande, l'entrée et le dessert arrivent avec le plat, du même appel
de planning, parmi les recettes classées entrée ou dessert — une fois chacune dans le
cycle. Le créneau les montre sous le plat, avec l'accompagnement, et chacun se change ou
se retire d'un appui ; le sélecteur ne propose que les recettes du bon rôle. Un repas
léger accepte une entrée, un snack ou un petit plat, sans dessert. Les composants
partent avec le repas validé et dans l'événement Google Calendar.

Un mot « dessert » écrit dans une contrainte en langage naturel n'ouvrait un créneau de
dessert que si le modèle le lisait ainsi. Il ne compte plus : seul le format du jour
décide.

### v0.22.67 — technique

- `planning_config/{uid}.daily_constraints[jour].meal_format` : `plat` | `plat_dessert` |
  `entree_plat` | `entree_plat_dessert` | `leger`, absent = plat seul. Côté client
  `MealFormat` (`features/planning/domain/meal_format.dart`), porté par `DayConstraint`.
- `suggestMealPlanFn` reçoit `mealFormat` par contrainte et `mealRole` par recette. Le
  prompt sépare plats, entrées, desserts et en-cas (`partitionByRole`), annonce le
  format de chaque créneau (`mealFormatOf`) et attend `starter_id` / `dessert_id` à côté
  de `recipe_id`. La relecture rejette une entrée ou un dessert que le format ne demande
  pas, du mauvais rôle, ou déjà servi dans le cycle ; un plat de rôle entrée ou snack
  n'est accepté qu'en repas léger. La détection d'un mot « dessert » dans les
  contraintes est retirée ; `isDessertBag` ne sert plus qu'aux recettes non classées.
- `planning_slot_rules.json` : sections `meal_format` et `planning_role` ; la section
  `asks_for_dessert` est retirée. `test/meal_format_test.dart` côté Dart.
- `planned_meals.components` reçoit l'entrée et le dessert (`role: entree` / `dessert`)
  quand le format du créneau les demande ; l'export calendrier les reprend.

### v0.22.66 — fonctionnel

#### Le rôle dans un repas se voit et se corrige

La fiche d'une recette affiche son rôle dans sa section Catégorisation : « Rôle dans un
repas : Plat », après Cuisine et Type de plat. Le résumé de la liste des recettes ne change
pas, et l'export PDF reprend la même section.

Le panneau de métadonnées propose ce rôle dans une liste à cinq valeurs — Plat,
Accompagnement, Entrée, Dessert, Snack — plus « Non classé ». La liste est là dans les trois
écrans qui partagent ce panneau : la relecture d'un import, la correction d'une recette et la
création à la main, qui reçoit au passage Cuisine et Type de plat. « Suggérer les tags » pose
sa réponse dans la liste, et on la change d'un appui. « Non classé » retire le rôle et ce qui
en dépend ; la reprise « Rôle des recettes » le redemandera au modèle.

Valider un import gardait déjà le rôle posé par le balisage. Il conservait mal le temps de
repos : la relecture le montrait, la validation écrivait `null` par-dessus. Le formulaire de
relecture enregistre désormais ses tags par le même chemin que la correction, temps de
repos compris.

### v0.22.66 — technique

- `features/recipes/domain/meal_role.dart` : `kMealRoles`, `mealRoleLabel`. Les valeurs
  restent décidées par `gemini/mealRole.ts` ; `test-fixtures/meal_roles.json` verrouille
  l'égalité des deux listes (`test/meal_role_test.dart`, `tests/mealRole.test.ts`), ligne
  ajoutée au tableau « Logique dupliquée » de `CLAUDE.md` et de son miroir.
- `buildRecipeTagSections` ajoute la section « Rôle dans un repas » en dernier.
- `RecipeMetaPanel` : `mealRole` et `onMealRoleChanged` ; `DropdownButtonFormField` sur
  `initialValue`, qui suit la valeur du parent (`didUpdateWidget` du SDK), chaîne vide pour
  « Non classé », valeur hors liste proposée telle quelle plutôt que de faire échouer
  l'assertion du menu.
- `RecipeFormMixin` : `selectedMealRole` initialisé depuis la recette, `setMealRole`,
  `aiClassifiedInSession` à la place de `suggestedMealRole`. `buildTagsFromForm` reconstruit
  sans les trois champs quand le rôle est retiré.
- `RecipeRepository.validateDraft(clearMealRole:)` : `FieldValue.delete()` sur
  `tags.meal_role`, `tags.contains`, `tags.suggested_sides`, seulement si l'objet relu n'en
  porte pas. `DraftReviewScreen` passe `buildTagsFromForm(recipe.tags)` au lieu d'un
  `RecipeTags` construit à la main sans `restTime`.
- `DraftReviewFormData` : `selectedMealRole`, `onMealRoleChanged`, passés aux trois
  dispositions du panneau.

### v0.22.65 — fonctionnel

#### Une idée retenue devient une recette

Dans « Générer avec l'IA », appuyer sur une idée rédige sa recette complète — même
rédaction que « Conception IA » de Nouveau planning — et l'enregistre **validée** dans
« Mes créations Kass'Dalle ✨ ». Le repas pointe vers cette recette : la fiche s'ouvre d'un
appui, les ingrédients entrent dans les courses, l'accompagnement se compose.

En v0.22.63, l'idée se posait en repas libre : un titre, deux durées, et rien à ouvrir. La
feuille affiche « Rédaction de … » pendant l'écriture, jusqu'à une minute, et ne se ferme
pas d'un geste pendant ce temps. Un appel de plus par idée retenue, sur le poste
« Concept de recette (planning) ».

### v0.22.65 — technique

- `gemini/planning.ts` : `RecipeConceptInput.requestedDish` (titre, description), facultatif.
  Présent, le prompt ouvre sur une section « plat demandé » et ordonne d'écrire cette
  recette sous ce titre ; absent, rien ne change pour « Conception IA ».
- `PlanningRepository.saveGenerated(recipe, reviewStatus:)` ; `saveAsDraft` y délègue avec
  `draft`. Le sélecteur enregistre en `validated`, dans le livre Kass'Dalle, origine `ai`.
- `MealIdeaConceiver` (`meal_idea.dart`) ; `MealIdeasSheet` reçoit `conceive`, rend une
  `Recipe`, bloque la fermeture pendant la rédaction (`PopScope`, `isDismissible`).
  `RecipePickerSheet.onConceiveIdea` ; `_conceiveMealIdea` dans `planning_screen.dart`,
  cadré par les contraintes du jour du repas.
- `test/meal_ideas_sheet_test.dart` : deux tests de plus, rédaction réussie et rédaction
  en échec signalée sous `mealIdeasSheet.conceive`.

### v0.22.64 — fonctionnel

#### Le backfill des rôles dit ce qu'il reste à classer

Le compte rendu d'un backfill s'affiche sous la barre de titre, en dehors de la liste. Il
s'insérait en tête d'une liste qu'on avait fait défiler jusqu'à la dernière tuile, et trois
passages du rôle des recettes ont été lancés sans que leur résultat soit lu.

Le résultat du passage « Rôle des recettes dans un repas » commence par le chiffre attendu :
« Reste à classer : 212 recettes. », compté sur toute la collection et non sur les quarante du
passage. Ce compte rendu reste lisible sous la tuile — « Dernier passage le 13/09/26 12:20 :
40 classées, 0 en échec. Reste à classer : 212 recettes. » — et dans la fenêtre de
confirmation, même après avoir quitté l'écran pendant le traitement.

### v0.22.64 — technique

- `backfillRecipeRolesFn` rend `restantes` : total des pages, moins celles dont
  `tags.meal_role` est renseigné (`!= null` — l'import écrit `null` quand la passe 2 n'a pas
  su), moins celles dont `page_type` vaut autre chose que `recipe`. Trois agrégats `count()`,
  aucun document lu. `null` quand le décompte échoue, et l'erreur est journalisée ; jamais un
  zéro à la place.
- La fonction écrit son compte rendu à côté du curseur : `last_report` dans
  `app_config/recipe_roles_backfill_checkpoint`, avec `finished_at`. `setBackfillCursor`
  reçoit un `lastReport` optionnel. Le client le lit en continu (`BackfillReportsRepository`,
  `recipeRolesBackfillReportProvider`).
- `GcpBillingRepository.backfillRecipeRoles` rend un `RecipeRolesBackfillReport` au lieu d'une
  table de compteurs ; les phrases du compte rendu vivent sur ce type, et
  `test/recipe_roles_backfill_report_test.dart` les couvre.

### v0.22.63 — fonctionnel

#### « Générer avec l'IA » dans le sélecteur du planning

Sous « Saisir un nom libre », une nouvelle entrée : on écrit ce qu'on a envie de manger
— « un plat léger sans viande, prêt en 30 min » — et l'IA rend trois idées de repas, chacune
avec une phrase et des durées estimées. Ce qui est déjà tapé dans la recherche sert de
première consigne.

**Trois idées, et la consigne qu'on retouche.** On modifie la consigne et on relance :
les idées déjà affichées ne reviennent pas, quelle que soit la relance. L'idée retenue se pose
comme un repas libre, avec ses durées, exactement comme un nom saisi à la main. Aucune
recette n'est créée, rien n'est écrit dans les livres. Les préférences générales du planning
accompagnent la consigne.

Un appel par consigne ou relance, compté sous « Idées de repas (planning) » et routable
depuis Admin › Moteur d'IA.

### v0.22.63 — technique

- `functions/src/gemini/mealIdeas.ts` : `suggestMealIdeas` par `askJson` avec schéma de
  sortie, poste `planning_meal_ideas`, 45 s, 2 000 jetons. `buildMealIdeasPrompt` porte la
  consigne, les préférences et les titres déjà rendus, sans exemple rempli ; `parseMealIdeas`
  rend au plus trois idées sans doublon de titre, ou `null`. `tests/mealIdeas.test.ts`.
- `suggestMealIdeasFn` (`callable/geminiCallables.ts`) : consigne bornée à 600 caractères,
  quinze titres précédents au plus, préférences à 2 000 caractères.
- Poste inscrit aux trois endroits : `ctx.feature`, `ROUTABLE_FEATURES` (groupe Planning),
  `feature_catalog.dart` (« Planning et courses »).
- Client : `MealIdea` (`planning/domain/meal_idea.dart`) et son `toFreeRecipe()` — même
  forme que la saisie libre, durées en plus ; `GeminiService.suggestMealIdeas` ;
  `PlanningAiService.suggestMealIdeas` ; `MealIdeasSheet`
  (`planning/presentation/meal_ideas_sheet.dart`), champ stylet, titres cumulés à chaque
  relance. `RecipePickerSheet` reçoit un `onGenerateIdeas` facultatif : sans lui, rien ne
  change — la composition d'un cycle ne le passe pas encore.
- `test/meal_ideas_sheet_test.dart` : cinq tests, dont la relance qui cite tout ce qui a
  déjà été affiché et le générateur en échec signalé sous `mealIdeasSheet.generate`.

### v0.22.62 — fonctionnel

#### Un repas, c'est un plat et son accompagnement

Troisième palier de « un repas n'est pas une recette ». La blanquette arrive avec son riz.

**Le programme compose, le modèle ne choisit rien.** Quand le plat retenu n'apporte pas de
féculent ou de légume, un accompagnement lui est posé : d'abord parmi les accompagnements
classiques que le modèle a reconnus une fois pour toutes sur la recette, en préférant une
recette d'accompagnement du corpus quand elle existe — les frites maison plutôt que les frites
surgelées —, sinon une garniture de la famille qui manque, par rang. Le même accompagnement ne
revient pas deux jours de suite quand un autre est possible, ni deux fois dans le cycle tant
qu'il en reste. Un plat complet, une entrée, un dessert, une recette non classée ne reçoivent
rien.

**Dans « Nouveau planning »**, chaque créneau montre son accompagnement, la raison en infobulle
(« le plat n'apporte pas de féculent : riz, accompagnement classique »), et un appui le change
ou le retire ; un choix fait à la main n'est plus recalculé tant que le plat ne change pas.
Dans le planning, « Changer la recette », « Suggestion IA » et la pose d'une recette sur un jour
libre recomposent l'accompagnement de la même façon ; « Remettre à blanc » le retire.

**La liste montre le repas entier** — « Accompagnement : Riz · 70 g par part » sous le plat —,
**la liste de courses compte les garnitures** pour les parts du repas, sous leur produit de
courses, fondues dans la ligne d'une recette qui demande le même produit, et **l'événement
Google Calendar** porte l'accompagnement et sa quantité, avec le lien de la fiche quand c'est
une recette.

### v0.22.62 — technique

- `planned_meals` reçoit `components` : une liste de composants (rôle, recette ou garniture
  **figée** avec sa part par personne, justification). Le plat reste dans `recipe_id`.
  Modèle dans `meal_component.dart`, testé par `test/meal_component_test.dart`.
- Le choix vit dans `side_chooser.dart` — ce qui manque au plat (`sideNeedsFor`), les
  candidats (`sideCandidatesFrom`), l'appariement d'un nom suggéré à une garniture ou une
  recette (`sideNameMatches`), le choix avec rotation (`chooseSide`) — logique pure, testée
  par `test/side_chooser_test.dart`. Aucun appel de modèle.
- `planningAggregateProducts` accepte des produits hors recette (`extras`), testés par
  `test/planning_shopping_aggregate_test.dart` ; `buildCalendarDescription` reçoit les
  composants et les parts ; `updateMealRecipe` écrit ou retire les composants avec le plat.

### v0.22.61 — fonctionnel

#### Le stylet ouvre un pavé d'écriture

Sur une tablette Samsung, le survol du S Pen ne fait jamais apparaître le pavé d'écriture
dans un champ de l'application : ce pavé ne s'ouvre que sur les champs natifs d'Android, et
un champ Flutter n'en est pas un. Depuis Android 14, l'écriture au stylet fonctionne en
revanche directement dans un champ qui a le clavier, mais dans quatre lignes de haut.

**Un stylet posé sur un champ de texte libre ouvre un panneau bas** : un grand champ, toute
la largeur de l'écran et tout l'espace au-dessus du clavier, où l'écriture système convertit
les traits en texte. Le champ du panneau et celui de l'écran sont le même texte ; le bouton
*Terminé* referme le panneau. Un doigt n'ouvre rien : le champ reste un champ ordinaire.

Champs concernés : l'annotation d'une recette, la description d'un livre, les contraintes du
planning (globales, du cycle, par jour), les instructions d'amélioration d'un brouillon, le
texte d'une image à générer (brouillon et recette générée), la modification d'une recette
générée et l'envie culinaire de la recherche. L'éditeur de recette n'en fait pas partie.

Le panneau ne s'ouvre que là où le système convertit l'écriture : Android 14 et plus avec un
clavier compatible, et l'iPad. Sous Android 13, sur le web et sur Windows, le stylet se
comporte comme un doigt.

### v0.22.61 — technique

- `core/presentation/stylus_pad_text_field.dart` : `StylusPadTextField`, un `TextField` sous
  un `Listener`. Une pose de `PointerDeviceKind.stylus` interroge `Scribe.isFeatureAvailable`
  (Android) puis ouvre `showStylusHandwritingPad`, un `showModalBottomSheet` pleine largeur
  dont le champ partage le contrôleur et reçoit le même `onChanged`. Le champ d'origine a
  `stylusHandwritingEnabled: false` : il ne démarre pas une session d'écriture que
  l'ouverture du pavé interromprait au premier trait.
- La sonde répond `false` sur le web et les bureaux sans appeler le canal `flutter/scribe`,
  `true` sur iOS. Une sonde qui échoue est signalée sous `stylus_pad_probe` et n'ouvre rien.
- Deux `TextFormField` sans `validator` (description du livre, contraintes globales du
  planning) deviennent des `TextField` : aucun formulaire ne les lisait.
- `test/stylus_pad_text_field_test.dart` : neuf tests de widget, dont le canal Scribe simulé.

### v0.22.59 — fonctionnel

#### Chaque recette apprend son rôle dans un repas

Deuxième palier de « un repas n'est pas une recette ». Avant de composer un plat et son
accompagnement, il faut savoir ce qu'est chaque recette : ce que ne disaient pas les types
de plat, qui mélangent la protéine et la structure.

**Trois champs par recette**, reconnus une fois par le modèle : le rôle dans un repas — plat,
accompagnement, entrée, dessert, snack —, ce que la recette apporte déjà — protéine, féculent,
légume — et, pour un plat à qui il manque l'un des deux derniers, deux ou trois accompagnements
classiques. L'import les pose dans la même passe que le balisage ; le bouton « Suggérer les
tags » de l'éditeur les pose sur une recette saisie à la main ; la reprise *Admin › Backfills ›
Rôle des recettes dans un repas* classe l'existant, quarante recettes par passage, avec reprise
sur point de contrôle. Une recette « pas sûre » reste sans rôle plutôt que mal classée. Aucun
écran ne montre encore ces champs : ils attendent le palier suivant.

**Le semis des garnitures simples a rejoint Admin › Backfills**, avec les autres écritures
ponctuelles. L'écran du référentiel montre et corrige ; il ne sème plus.

### v0.22.59 — technique

- `tags` reçoit `meal_role`, `contains`, `suggested_sides` et `roles_tagged_at`. Les valeurs
  admises, le texte demandé au modèle et la lecture de sa réponse vivent dans
  `functions/src/gemini/mealRole.ts`, seul endroit qui les décide ; `tests/mealRole.test.ts`
  verrouille la lecture. La passe 2 de l'import (`TAGGING_PROMPT`, `parseTagged`) et le tagueur
  (`suggestRecipeTags`, `suggestMealRole`) partagent ce texte.
- Nouvelle callable `backfillRecipeRolesFn`, poste `backfill_recipe_roles` inscrit aux trois
  endroits, curseur `app_config/recipe_roles_backfill_checkpoint`, arrêt après trois échecs
  de suite.
- Côté client, `RecipeTags` porte les trois champs et ne les écrit que si le rôle est connu ;
  `validateDraft` écrit `tags` champ par champ pour ne pas effacer un rôle posé par l'import
  ou le backfill (`test/recipe_tags_roles_test.dart`).

## 2026-09-12

### v0.22.58 — fonctionnel

#### Le planning regarde ce qu'on a déjà mangé

Premier palier de la réflexion « un repas n'est pas une recette » : avant de composer des
repas à plusieurs composants, le planning apprend à lire son propre historique.

**Fenêtre de variété.** Un plat servi dans les N semaines qui précèdent le cycle n'est pas
reproposé, N de 0 à 4 dans les préférences de planification, 2 par défaut. Le retrait se fait
avant l'appel, dans la liste des candidats : une recette absente de la liste ne peut pas être
choisie, quoi que dise la consigne. Le serveur retire du plus récent au plus ancien et
s'arrête dès qu'il resterait moins de recettes que de créneaux ; ce qu'il a dû garder est
nommé au modèle, à ne prendre qu'en dernier recours. Les derniers repas servis lui sont aussi
donnés pour enchaîner sans répéter la protéine ni le féculent de la veille. Le message de fin
dit combien de plats récents ont été écartés. Vaut pour le cycle entier, pour un créneau isolé
et pour « Changer la recette » dans le planning.

**Reprendre une semaine passée.** Une icône d'historique dans « Nouveau planning » liste les
semaines qui portent des repas, chacune avec ses plats. La semaine choisie remplit les créneaux
vides, jour de semaine pour jour de semaine, sans appel à l'IA. Un créneau rempli reste tel
quel, une recette déjà posée n'est pas reposée, une recette disparue est comptée et dite.

**Garnitures simples.** Riz, pâtes, salade verte, yaourt : ce qui accompagne un plat sans avoir
de recette, avec la part par personne. Un référentiel de base de vingt-cinq entrées, tenu dans
*Admin › Référentiels › Garnitures simples* et semé d'un bouton qui n'écrase jamais une valeur
corrigée ; une copie par personne dans *Préférences › Mes garnitures* — une quantité à sa main,
une garniture masquée, une garniture à soi — qui ne change rien pour les autres. Ce référentiel
ne sert encore à rien dans les repas : il prépare le palier suivant, la composition d'un plat et
de son accompagnement.

### v0.22.58 — technique

- `planning_config` reçoit `variety_window_weeks` ; `suggestMealPlanFn` accepte
  `recentlyServed` et rend `excludedRecentIds` avec ses suggestions. La règle de retrait,
  `applyRecentlyServed` dans `gemini/planning.ts`, est verrouillée par la section
  `recently_served` de `planning_slot_rules.json` — serveur seul.
- Côté client, `planning_history.dart` (fenêtre) et `week_replay.dart` (reprise) sont de la
  logique pure, testée dans `test/planning_history_test.dart` et `test/week_replay_test.dart`.
- Nouvelle collection `meal_staples/{id}` — lecture pour tout compte nommé, écriture admin — et
  nouveau document `users/{uid}/preferences/meal_staples` pour les retouches, chaque entrée
  remplacée en entier à l'écriture. Modèle et fusion dans `meal_staple.dart`, testés dans
  `test/meal_staples_test.dart`. Deux routes de plus : `/admin/meal-staples` et
  `/planning/staples`.

### v0.22.57 — fonctionnel

#### Deux poivrons rouges et deux poivrons verts ne font plus deux poivrons

Un livre disait « 2 poivrons rouges » puis « 2 poivrons verts ». Le balisage rendait deux
entrées du même nom « poivron », deux pièces chacune, la couleur en note. La lecture de la
recette fusionnait les entrées de même nom et n'en gardait qu'une : la fiche affichait deux
poivrons sur quatre, et la liste de courses aussi.

Deux corrections. Le prompt de balisage dit maintenant que la couleur, la variété et l'espèce
font partie du nom — « poivron rouge », « oignon rouge », « lentilles corail », « sucre
roux » — parce que ce sont d'autres produits à l'achat et d'autres entrées du référentiel
nutritionnel ; la préparation, elle, reste en note. Et la lecture d'une recette ne fusionne
plus deux entrées de même nom quand chacune porte une note et que les notes diffèrent : deux
lignes du livre restent deux lignes. Une entrée sans note reste un doublon de celle qui en
porte une, comme avant.

Les recettes déjà importées ne changent pas. Une seule d'entre elles porte une couleur en
note (« Ceviche », poivron « vert ») ; elle se corrige dans l'éditeur.

### v0.22.56 — fonctionnel

#### Le texte de la recette se zoome sur la tablette

Posée sur le plan de travail, la tablette se lit à un mètre, et la fiche était trop petite ;
tenue en main, elle se lisait bien. Deux boutons dans la barre de la fiche, réduire et agrandir,
zooment l'onglet *Préparer* — ingrédients, étapes, puces — par paliers : 100, 125, 150, 175 et
200 %. Le zoom s'ajoute à la taille de police du système, il ne la remplace pas. Le réglage est
mémorisé sur l'appareil, pas dans le compte : il dépend de l'écran et de la distance de lecture,
pas de la personne.

Les boutons n'existent que sur l'APK Android en présentation étendue. Le téléphone garde la fiche
telle quelle, le web et le bureau aussi.

#### Les étapes ignoraient la taille de police du système

Le texte des étapes était rendu par `RichText`, dont l'échelle de police est fixe par défaut. Le
réglage « Taille de police » d'Android agrandissait les puces d'ingrédients et laissait les étapes
à leur taille. Les étapes suivent maintenant le même réglage que le reste de la fiche, et le zoom
ci-dessus.

## 2026-09-05

### v0.22.44 — fonctionnel

#### Le titre d une recette était rogné par le haut

La barre déclarait au Scaffold une hauteur de 56 pixels et en construisait 114 : deux lignes de
titre et une rangée d actions. Le Scaffold ne réservait que ce qu on lui annonçait, et la barre
était coupée par le haut — « Brownies » amputé de sa moitié supérieure, la flèche de retour avec
lui.

La hauteur est maintenant calculée une seule fois, par une fonction que l appelant interroge avant
de construire la barre. Elle suit l échelle de police du système : à grande échelle, deux lignes de
titre demandent plus de 72 pixels.

#### La note rejoint le titre

L étoile et la note décrivent la recette, elles ne sont pas des actions. Elles étaient sur la
rangée du bas, avec les icônes ; elles sont maintenant à droite du titre, avec les pastilles
d annotation.

### v0.22.43 — fonctionnel

#### La loupe se décalait près des bords, là où on pose les coins

La fenêtre prélevée autour du point visé sort de l image quand ce point approche d un bord.
Flutter étirait alors la seule partie valide sur toute la surface de la loupe : le point visé
n était plus au centre, et la croix désignait un pixel qui n était pas celui qu elle montrait.

Le décalage grandissait à mesure qu on approchait du bord — jusqu à la moitié du rayon dans un
coin. C est exactement là qu on pose les coins d un document.

La destination est maintenant rognée dans la même proportion que la source. Le fond noir apparaît
là où l image s arrête, et la croix reste sur le point qui sera retenu.

### v0.22.42 — fonctionnel

#### La suite des étapes prend une ligne à elle

Elle vivait dans la colonne du sous-titre de la tuile, que `ListTile` réduit à ce que les boutons
de droite lui laissent : le libellé s'y coupait — « Lecture de la page par … ».

Elle est maintenant posée sous la tuile, sur toute la largeur de la carte, et le texte peut passer
à la ligne.

#### La loupe grossissait neuf fois au lieu de deux

`LoupePainter` prélevait une fenêtre exprimée en pixels **logiques** dans une image mesurée en
pixels **d'image**. La conversion manquait.

Sur une photo de 1756 px affichée sur 380, la loupe prélevait 70 pixels d'image et les étalait sur
140 pixels d'écran : un grossissement d'environ neuf, au lieu des deux demandés. Le viseur
désignait le bon point, mais ce qu'on voyait autour ne ressemblait plus à ce que le doigt
survolait — d'où l'impression d'un décalage.

#### La barre du bas n'a plus de libellés

Ils avaient été affichés parce que cinq icônes muettes se distinguent mal. Mais les cinq mots se
partagent la largeur de l'écran, et à l'échelle de police du système « Bibliothèque » se coupait en
deux, la barre montant sur deux lignes en rognant le contenu.

La v0.22.40 avait borné l'échelle de police pour l'empêcher ; les mots restaient. Ils partent. Le
nom de chaque destination reste accessible par un appui long.

### v0.22.41 — fonctionnel

#### « Traitement IA en cours » annonçait une IA qui ne tournait pas

Ouvrir l'atelier de retouche affichait ce message. Enregistrer un recadrage aussi. Aucun des deux
n'appelle un modèle : le premier télécharge une image depuis Storage, le second l'envoie.

Le recadrage passe bien par la fonction de modération, mais une image marquée comme venant de
notre propre traitement y est approuvée **sans analyse et sans facturation** — `moderateAndPromote.ts`,
`if (item.origin !== "user")`. Cloud Vision n'est pas appelé.

La cause : un seul drapeau commandait ce voile pour cinq opérations de l'écran de relecture, et
cinq autres de l'écran d'édition. Deux seulement appellent un modèle — le raffinement du texte et
la recherche de photos sur la page. Le titre et le message avaient été écrits pour celles-là, et
les huit autres les héritaient.

Chaque opération annonce désormais ce qu'elle fait : « Chargement de la photo… », « Chargement du
scan… », « Enregistrement de la photo… », « Recherche des photos par l'IA… », ou le message
d'origine pour le raffinement.

Annoncer une IA qui ne tourne pas fait suspecter un coût là où il n'y en a pas, et rend le message
suspect quand elle tourne vraiment.

### v0.22.40 — fonctionnel

#### Le titre d'un traitement ne se lit plus une lettre par ligne

La puce d'état et l'heure occupaient la droite de la tuile. `ListTile` leur accorde d'abord toute
la largeur qu'elles demandent, puis laisse le reste au titre : sur un téléphone étroit, et dès que
la police du système est agrandie, il n'en restait qu'un caractère. « Scan recette • CHOCOLAT » se
lisait verticalement, et le libellé de l'étape en cours avec lui.

Les deux descendent sous le titre. À droite ne restent que les boutons d'action, dont la largeur
est connue d'avance.

#### « Bibliothèque » ne se coupe plus en deux dans la barre du bas

Les cinq libellés se partagent la largeur de l'écran. À l'échelle de police choisie par
l'utilisateur, le plus long passait à la ligne et se coupait au milieu d'un mot.

L'échelle est bornée pour cette barre, et pour elle seule : c'est une rangée de cinq cases fixes,
pas du texte à lire. Le reste de l'application garde le réglage du système.

### v0.22.39 — fonctionnel

#### La barre d'une recette tient sur deux lignes, et le menu « … » disparaît

Sur téléphone, le titre partageait la barre avec la note, les pastilles d'annotation, le document
source et un menu « … ». Il lui restait de quoi afficher « Gâteau au … ».

Les actions descendent d'un cran, sur une seconde ligne. Le titre dispose alors de toute la
largeur, sur deux lignes au besoin.

Le menu « … » disparaît avec elles. Il cachait huit actions derrière un geste et un temps
d'attente ; les mêmes icônes, posées à plat, se désignent directement : annotations, retouche par
l'IA, copie en brouillon, changement de couverture, détachement du livre, modification, export PDF,
suppression. Chacune garde son infobulle.

Les icônes sont serrées — vingt-deux pixels dans une touche de trente-six — pour que la dizaine
tienne sur une ligne de téléphone. En dessous, la cible deviendrait trop petite pour le doigt. La
ligne défile horizontalement en dernier recours, quand une police agrandie les déborde : rien ne
disparaît.

### v0.22.38 — fonctionnel

#### La progression d'un traitement tient sur deux lignes

La rangée d'icônes et le mot de l'étape en cours partageaient une ligne. Trop de choses côte à
côte : on ne lisait ni les unes ni l'autre.

Les icônes ont maintenant leur ligne. En dessous, l'icône de l'étape en cours et son libellé
complet — « Lecture de la page par l'IA… » plutôt que « Lecture ».

### v0.22.37 — fonctionnel

#### Le scanner du système prend aussi les pages de recette

La v0.22.35 l'avait branché sur les couvertures de livre. Il sert maintenant aussi au scan des
pages, sur mobile uniquement.

Une session accepte jusqu'à vingt pages. On photographie une recette de six pages d'affilée, sans
revenir à l'écran entre deux, et chaque page arrive cadrée et redressée. Avant, la caméra rendait
une page par aller-retour.

Les pages rejoignent le lot en attente, comme celles prises une à une ou choisies dans un fichier.
Le bouton « Analyser » les envoie ensemble, inchangé. Le rang de chaque page est écrit dans son nom
(`page_<horodatage>_01.jpg`) pour que `comparePageNames` range un lot qui mêle photos et fichiers.
Le bouton « Ajouter une page » passe par le même chemin.

Sur le web, rien ne change : ces API n'existent pas dans un navigateur.

#### `-WebOnly` a été retiré

Tout déploiement embarque désormais l'APK. Le script s'arrête si on lui passe ce paramètre, au lieu
de publier un site sans binaire.

C'est une conséquence de la mise à jour dans l'application : elle lit le manifeste posé à côté de
l'APK pour savoir si une version existe. Un déploiement web seul lui annonce une version que le
téléchargement ne rend pas.

Le refus plutôt que la construction silencieuse de l'APK : un script qui fait plus que ce qu'on lui
demande est aussi difficile à comprendre qu'un script qui en fait moins.

`CLAUDE.md`, son miroir Copilot et `TechnicalRequirements.md` ne le proposent plus.
`-ResumeHostingOnly` reste : il reprend une mise en ligne interrompue sans rejouer les builds.

#### L'application Android se met à jour sans passer par le navigateur

La fenêtre « Mise à jour disponible » ouvrait Chrome. Il fallait ensuite retrouver le fichier
téléchargé, l'ouvrir, et autoriser Chrome à installer des applications. Trois gestes hors de
l'application, pour un utilisateur qui venait de dire oui.

Le parcours tient maintenant dans la fenêtre : autorisation, téléchargement avec sa barre de
progression et son bouton d'annulation, puis l'écran d'installation d'Android. L'autorisation
est demandée **avant** le transfert — se la voir refuser après quatre-vingt-dix mégaoctets les
perdrait.

L'écran de confirmation du système reste obligatoire, et l'autorisation « installer des
applications inconnues » se donne désormais à Kass'Dalle plutôt qu'à Chrome. L'installation
silencieuse n'existe pas hors Play Store.

Quand l'installation directe échoue, la fenêtre propose le téléchargement par le navigateur :
l'ancien chemin devient le repli.

Un téléchargement interrompu ne laisse rien derrière lui, et un fichier plus court que la
taille annoncée est effacé sans être ouvert — un APK tronqué échoue à l'installation sans
dire pourquoi.

### v0.22.37 — technique

#### Le manifeste de l'APK est distinct de celui du web

L'application lisait `version.json` pour savoir si une mise à jour existait. Ce fichier décrit
le bundle web, et les deux divergent dès qu'un déploiement ne reconstruit pas l'APK :
`deploy.ps1 -WebOnly` met le web à jour et laisse le binaire en place. La version annoncée
n'était alors pas celle du fichier téléchargé — l'utilisateur installait, restait en dessous,
et la fenêtre revenait à chaque lancement.

`apk_release.json` est écrit au moment où l'APK est compilé et copié : `version`,
`build_number`, `file`, `size_bytes`, `built_at`. Il décrit toujours le fichier servi à côté
de lui. Aucun repli sur `version.json` quand il manque : ce serait reproduire le défaut qu'il
corrige, et sans manifeste aucune mise à jour n'est proposée.

À version égale, le numéro de build départage — un APK reconstruit sans changement de
`version:` porte le même nom de version et un build supérieur.

#### `-WebOnly` ne supprime plus l'APK de la mise en ligne

Un déploiement hosting remplace tout le contenu de `build/web`. Sans APK recopié, le lien de
téléchargement du site partait en 404 ; avec un APK survivant, c'était l'ancien binaire publié
sous le numéro de version du web.

`Publish-ApkPayload` s'exécute avant chaque déploiement. Elle restaure la paire APK +
manifeste depuis `Release/mobile` quand le build n'a pas été rejoué, et ne publie ni l'un ni
l'autre quand il n'y a rien à restaurer. La paire se restaure **ensemble** : associer un
manifeste à un binaire qui n'est pas le sien annoncerait une version fausse.

En fin de course, le script nomme la version d'APK réellement en ligne dès qu'elle diffère de
celle du web. Un écart après un `-WebOnly` est normal ; il devient un problème quand personne
ne le voit.

#### Le canal d'installation

`REQUEST_INSTALL_PACKAGES` et un FileProvider d'autorité `${applicationId}.updateprovider`
rejoignent le manifeste Android — `.fileprovider` serait entré en conflit avec ceux
d'`image_picker`, de `printing` et de `cunning_document_scanner`. Le seul chemin exposé est
`cache/updates/`, vidé avant chaque transfert.

`MainActivity.kt` porte le canal `dev.kassbi.kass_dalle/app_installer` : dossier de
téléchargement, lecture de l'autorisation, ouverture du réglage système, ouverture de
l'installateur. Le téléchargement reste en Dart, où la progression s'affiche. Sur toute autre
plateforme, `AppInstaller` répond « non » sans lever d'erreur : l'appelant n'a pas à connaître
la plateforme.

L'écriture du fichier passe par un import conditionnel (`apk_file_store_io.dart` /
`apk_file_store_stub.dart`) : `dart:io` n'existe pas sur le web, et `app_shell.dart` est
compilé pour les deux.

`test/app_update_service_test.dart` couvre la comparaison de versions, la lecture du
manifeste, l'absence de repli, la progression, le fichier tronqué et l'annulation. Ce dernier
cas a trouvé un défaut : l'exception d'annulation traverse `addStream` puis la fermeture du
fichier et ressort parfois enveloppée, si bien que se fier à son type laissait un APK à moitié
écrit dans le cache. L'annulation se lit maintenant sur le suivi du téléchargement.

Une dernière chose, et elle ne se voyait pas : `deploy.ps1` n'a pas de BOM, PowerShell 5.1 le
lit alors en ANSI, et l'octet `0x94` d'un tiret cadratin y devient un guillemet fermant. Un
tiret dans une chaîne coupait le script en deux au chargement.

### v0.22.36 — fonctionnel

#### La suite des états d'un traitement se lit en icônes

Sous le titre d'un traitement en cours, l'étape s'affichait en toutes lettres : « Lecture de la
page par l'IA… ». Sur un téléphone étroit, et dès que la police du système est agrandie, cette
phrase se coupait une lettre par ligne et poussait la tuile sur une demi-page.

Elle laisse la place à un fil de jalons : une icône par étape, celles déjà passées allumées,
celles à venir éteintes, et un mot pour l'étape courante — « Lecture », « Balisage ». Le libellé
complet reste en infobulle.

Les icônes disent plus que la phrase. Elles montrent **où l'on en est dans la suite** et combien il
reste ; la phrase ne disait que l'instant.

#### Le fil montre les étapes réellement traversées

Une couverture de livre en traverse **trois** — envoi, lecture, écriture — et une page de recette
**sept**, avec l'analyse, la recherche de photos, le balisage et l'enrichissement des ingrédients.
Les séquences viennent des branchements de `pipeline/recipeProcessor.ts`, pas d'une liste
plausible : afficher sept jalons pour une couverture promettrait un travail qui n'a pas lieu, et
le fil resterait bloqué aux deux tiers.

C'est un miroir du serveur, et rien ne relie les deux à l'exécution : une étape ajoutée là-bas ne
lève aucune erreur ici, elle fait seulement mentir le fil.
`test/processing_trail_test.dart` fige les deux séquences, pour qu'on doive venir les
relire.

Quand `current_step` ne correspond à aucun jalon — le client y écrit parfois un libellé en clair
pendant un scan — le texte reprend sa place plutôt qu'un fil qui désignerait la mauvaise case.

### v0.22.35 — fonctionnel

#### Le scanner du système prend le relais sur mobile

La détection de cadre écrite ces derniers jours ne rivalisera pas avec celle d'un téléphone, et il
n'y a aucune raison qu'elle essaie là où le système fait le travail.

Trois différences, et aucune n'est un meilleur seuil. Le scanner du système fait tourner un
**modèle entraîné** sur des centaines de milliers de photos de documents, là où nous appliquons des
règles posées à la main. Il travaille sur le **flux vidéo** — trente images par seconde, et seul ce
qui reste stable d'une image à l'autre est retenu, la main qui bouge fournissant des angles et des
lumières supplémentaires ; nous travaillons sur une seule prise. Et il s'exécute sur le
**processeur dédié**, en quelques millisecondes.

Le scan d'une couverture ouvre donc ML Kit Document Scanner sur Android et VisionKit sur iOS, par
`cunning_document_scanner`. L'image revient cadrée et redressée : elle part directement en file,
sans atelier de retouche. L'APK gagne trois cents kilo-octets — le modèle est fourni par les
services Google Play, rien n'est embarqué.

#### Sur le web, le cadre dit qu'il est une suggestion

Aucune de ces API n'existe dans un navigateur. L'heuristique reste, et elle s'annonce : « Cadre
suggéré — vérifiez les coins et corrigez-les » quand elle a trouvé quelque chose, « Aucun cadre
reconnu — placez les quatre coins » sinon.

Un cadrage automatique qui a l'air d'un résultat, alors qu'il n'a rien trouvé, fait perdre plus de
temps qu'un point de départ annoncé pour tel.

#### Au passage

La détection tournait déjà **sur l'appareil**, jamais sur le serveur : `compute` sur les octets
locaux, aucun appel réseau. Ce qui se ressentait comme une latence était la boucle Dart sur douze
mégapixels — 2 963 ms mesurées — et, sur le web, le fait que `compute` n'y ouvre aucun isolate et
tourne donc sur le fil principal.

### v0.22.34 — fonctionnel

#### La bande extérieure ne décrit pas toujours UN fond

Une deuxième photo a montré la limite de l'hypothèse « les bords montrent la table ». Livre posé
sur le même bois, mais un objet noir à gauche et un canapé sombre à droite : la médiane de la
bande sort à 62,65,63 — le sombre — et le bois, à 110 de ce faux fond, passe pour du document.
53 % de l'image marquée, un cadre qui entoure le livre plus une large marge.

La cohérence de la bande se mesure : la part de ses pixels serrés autour de leur médiane. 81 % sur
la première photo, 33 % sur la seconde. En dessous de 55 %, la couleur ne dit plus rien de fiable
et **on ne s'en sert pas**. La texture, elle, reste vraie : une table est lisse, un canapé aussi,
un objet noir aussi — une couverture imprimée non.

Le seuil de texture suit la même mesure : filtré par la couleur quand elle est fiable, pris sur
toute la bande au 75e centile sinon.

L'ouverture morphologique passe de 2 à 3. Mesurée à 4, elle réparait la seconde photo et
détruisait la première — le rectangle partait en diagonale. C'est le genre d'arbitrage qu'une
seule image ne permet pas de voir.

#### Un recalage sur les bords, essayé et retiré

Glisser chaque côté du rectangle le long de sa normale et garder la position au gradient le plus
fort. Mesuré sur les deux photos : les côtés partaient vers les contours **intérieurs** de la
couverture — le bord d'une assiette, la bande du titre, plus francs que la frontière
carton/table — et le cadre entrait dans le livre. Restreint à cinq pour cent et conditionné à un
gain d'un quart, il rognait encore cinq pour cent du livre sans rien corriger ailleurs.

Le code est parti, la mesure reste en commentaire : c'est une piste à ne pas reprendre telle
quelle.

#### Où en est la détection

Sur la première photo, le cadre tient le livre. Sur la seconde, il déborde encore en bas, sur un
jean sombre et texturé que le seuil de texture seul ne distingue pas d'une couverture.

### v0.22.33 — fonctionnel

#### La détection du cadre, réglée sur la photo qui échouait

Sept versions ont été déployées sans jamais tourner sur la photo en cause : les tests fabriquaient
la scène, donc ils passaient. Un banc d'essai lit maintenant un fichier déposé dans
, exécute la détection dessus et écrit une image de contrôle. Le réglage
s'est fait en quelques minutes au lieu d'un déploiement par hypothèse.

Ce que la photo a montré : **la couleur ne peut pas séparer le livre de la table**. Le bois est à
132,101,54 et la couverture contient une planche en bois et des bruns dorés de la même teinte. Un
seuil de couleur les garde ensemble, et le livre ressort en morceaux — 6 % de l'image au lieu de
50 %.

La détection mesure donc deux choses sur la bande extérieure, et prend leur union :

- la **couleur** du fond, comme avant ;
- sa **texture**, l'écart-type local de luminance sur une fenêtre de neuf pixels, calculé par
  images intégrales. Une table est lisse, une couverture imprimée ne l'est pas.

Un pixel appartient au document s'il est loin du fond par la couleur **ou** plus texturé que lui.
Aucune des deux mesures ne suffit seule : la bande du titre et l'assiette blanche sont lisses,
autant que la table.

Trois corrections ont suivi, chacune mesurée :

- **Le modèle du fond se raffine.** La bande longeait un ordinateur noir sur toute sa hauteur
  gauche — la moitié de ses pixels. La dispersion brute sortait à 171, un seuil qui laissait passer
  le livre entier. Seuls les pixels de bande proches de la médiane servent maintenant à mesurer la
  dispersion.
- **La texture du fond se mesure sur les pixels qui SONT le fond.** Prise sur toute la bande, elle
  sortait à 31 au lieu de 19 : la frontière ordinateur/table est un bord franc, donc très texturé.
  La couleur filtre, la texture complète.
- **Les trous se bouchent.** L'assiette blanche est lisse et pâle : ni la texture ni la couleur ne
  la distinguent de la table. Mais le fond ne peut pas l'atteindre depuis le bord de l'image, et
  c'est ce qui la trahit.

Enfin, la bande qui sert de modèle est forcée au fond : l'y marquer comme document serait se
contredire, et cela empêche la tache de sortir par le bord pour emporter le bois au-delà.

Mesure finale sur la photo : tache 43 % de l'image, rectangle 67 %, coins à 0,086 / 0,225 →
0,938 / 0,871. Le cadre tient le livre.

### v0.22.32 — fonctionnel

#### Les bandes noires de la photo détournaient le modèle du fond

La détection du cadre rendait un faux positif : elle entourait la table entière, livre compris.

Le diagnostic posé en v0.22.31 l'a dit en une ligne. Le fond modélisé sortait à **21,23,24** —
du noir — au lieu du bois de la table. La photo porte des bandes noires en haut et en bas ; la
bande extérieure de six pour cent où l'on échantillonne le fond en contenait assez pour que sa
médiane bascule. Le bois devenait alors « pas le fond » autant que le livre : 56 % de l'image
marquée, une tache de 58 %, un rectangle de 77 % allant de 0 à 0,997 en largeur.

Ces bandes ne font pas partie de la scène. Elles sont maintenant retirées avant tout le reste, et
les coins trouvés repassent dans le repère de la photo entière.

Une bande est une suite de lignes ou de colonnes **sombres**, franchement unies, et éloignées du
centre de l'image. La première version demandait seulement « unie et différente du centre » : la
table claire répondait à la définition, et le rognage mangeait le fond qu'il devait préserver.
Quatre tests l'ont dit avant le déploiement. Une bordure de capteur est noire ; une table ne
l'est pas. Le rognage reste borné à 30 % par côté — au-delà, ce n'est plus une bordure.

### v0.22.31 — technique

#### La détection du cadre dit où elle s'arrête

Le cadre restait à sa position par défaut, et rien ne disait pourquoi : tache trop petite, fond
mal modélisé, ou rien trouvé du tout ? Trois séances de diagnostic sont parties sur des
hypothèses plausibles faute de ces nombres.

`detectQuadInImage` rend désormais son chemin avec son résultat : couleur médiane du fond, écart
médian, seuil retenu, part de l'image marquée, aire de la plus grande tache, aire du rectangle,
et le point de sortie exact — `aucune_tache`, `aire_tache_hors_bornes`, `contour_trop_court`,
`rectangle_introuvable`, `aire_rect_hors_bornes` ou `quadrilatere`.

Le diagnostic est **transporté** et non remonté sur place : la détection tourne dans un isolat, où
aucun service de l'application n'existe. C'est l'écran qui écrit le rapport
(`imageEnhancerScreen.detection`), en y ajoutant le verdict du contrôle à 35 % qu'il repasse.

### v0.22.30 — fonctionnel

#### La détection du cadre sépare une région au lieu de traquer un contour

Dans l'atelier, la puce « Cadre » posait un rectangle qui n'avait rien à voir avec le livre.

L'ancienne méthode calculait un gradient de Sobel, puis balayait depuis le centre de l'image
jusqu'au premier bord franc rencontré. Elle supposait un intérieur uniforme — une page de texte.
Une couverture de livre est une photographie : ses contours internes, le bord d'une assiette, un
cartouche, sont bien plus marqués que la frontière carton/table, qui sépare deux beiges clairs à
un pixel d'écart après réduction à 512 px. Le balayage s'arrêtait donc à l'intérieur, ou, quand le
seuil écartait tout, filait jusqu'au cadre de la photo et rendait l'image entière. Les quatre
validations mesurées donnaient des coins à 1,8 %, 2,6 %, 14,6 % et 19,5 % des bords : jamais sur
le livre.

La nouvelle méthode part de ce qui est réellement simple dans la scène : **le fond est uniforme et
il occupe les bords**. Elle en prend la couleur médiane sur la bande extérieure, mesure son bruit
pour en déduire un seuil, marque tout ce qui s'en écarte, nettoie par fermeture puis ouverture
morphologiques, garde la plus grande tache connexe et lui ajuste le rectangle tourné d'aire
minimale.

L'intérieur du livre n'a plus aucune influence : photographie chargée ou page blanche, il est
simplement « pas la table ». La fermeture rattache les aplats clairs — l'assiette blanche qui
égarait l'ancienne méthode. Et la réduction à 512 px devient inoffensive : un bord d'un pixel de
large ne se détecte pas, une tache de deux cent mille pixels si.

Quand la scène ne porte pas de document identifiable, la détection ne rend rien et les coins par
défaut restent. C'est plus honnête qu'un cadre qui a l'air détecté.

`test/document_detection_test.dart` fabrique la scène plutôt que de la photographier : table
claire veinée, livre sombre à une position connue, avec son aplat clair. Cinq cas, dont le livre
posé de travers et la table vide.

Les six fonctions du détecteur au gradient ont été retirées avec lui.

### v0.22.29 — technique

#### L'atelier ne compresse plus qu'une fois, pour le stockage

La photo arrivait en qualité 100, volontairement : « c'est du TEXTE qu'on photographie ». Puis
l'atelier la recompressait trois fois avant de la rendre.

| Étape | Ce qu'elle faisait |
|---|---|
| Remise d'aplomb | réencodage en 95 quand l'orientation le demandait |
| Chaque quart de tour | encodage en 97, puis réencodage natif en 90 |
| Redressement | réduction à 2048 px, encodage en 97 |
| Compression finale | réencodage natif en 88 |

Trois générations JPEG au minimum, et un redimensionnement définitif : une photo de 3000 × 4000
partait au stockage en 1536 × 2048. C'est cette image-là que le modèle lit ensuite pour créer le
livre. Chaque génération abîme d'abord les petits caractères — ce qu'un titre de couverture donne
précisément à lire.

Il ne reste qu'un encodage, en qualité 95, à la validation. Le codec natif et sa passe à 88 ont
disparu ; une rotation n'encode plus qu'une fois.

#### La remise d'aplomb ne coûte plus un décodage entier

Elle décodait le JPEG complet pour appliquer l'orientation EXIF, puis le réencodait. Sur la
dernière mesure : 2 980 ms des 8 987 ms d'ouverture, pour une photo qui n'avait rien à redresser.

La détection, la rotation et le redressement décodent l'image de toute façon. Ils appliquent
maintenant l'orientation eux-mêmes, au passage, sur ce décodage-là. Un drapeau suit ce qui reste à
appliquer : dès qu'une opération produit de nouveaux octets, ils sortent du paquet `image`, déjà
d'aplomb et sans bloc EXIF.

#### Le plafond de travail passe de 2048 à 4000 px

C'est la borne que le serveur avait déjà mesurée pour l'extraction d'une page, dans
`gemini/perspective.ts` : « une double page redressée dans une image bornée à 2048 px sort autour
de 650 px de large, et son corps de texte y mesure cinq pixels de haut ». Une photo de téléphone
en 3000 × 4000 passe désormais sans réduction.

La garde reste, à 4000 : la boucle de redressement parcourt chaque pixel de sortie en Dart pur, et
sur le web elle n'a aucun isolate où se réfugier. La validation remonte sa durée (`rendu_ms`).

### v0.22.28 — fonctionnel

#### Les coins détectés atterrissaient à côté de la page

Dans l'atelier de retouche, activer « Cadre » posait les quatre poignées n'importe où. La
détection tournait pourtant, et rendait des coordonnées justes — dans un repère qui n'était pas
celui de l'image affichée.

Une photo de téléphone existe en deux versions. Celle que Flutter **affiche** honore l'orientation
EXIF. Celle que le paquet `image` **décode** l'ignore. Pour une photo prise en portrait, les deux
sont tournées d'un quart de tour l'une par rapport à l'autre. La détection des coins et le
redressement de perspective travaillent tous deux sur la seconde ; l'écran pose leur résultat sur
la première.

Le serveur avait été corrigé en août — « l'image est redressée une fois, puis sert à la détection
ET au découpage ». L'atelier de retouche n'avait pas suivi.

Les pixels portent maintenant eux-mêmes leur orientation, remise d'aplomb une seule fois à
l'ouverture, avant l'affichage comme avant les analyses. Toute la chaîne parle du même repère.

La décision porte sur la **valeur EXIF**, pas sur les dimensions : quatre des huit orientations —
miroir horizontal, demi-tour et leurs combinaisons — ne changent ni la largeur ni la hauteur. Les
reconnaître à leurs dimensions revenait à les laisser passer, et un demi-tour non appliqué met les
coins à l'exact opposé de la page. Une image déjà debout n'est pas réencodée : ce serait une
génération de JPEG, donc de la netteté, pour rien.

`test/image_upright_test.dart` couvre les cinq cas. La validation remonte désormais
`orientation_redressee`, et l'ouverture chronomètre cette étape avec les autres.

### v0.22.27 — fonctionnel

#### La bibliothèque affichait l'ancienne couverture d'un livre modifié

Une couverture remplacée était bien enregistrée — nouveau fichier dans Storage, nouvelle URL dans
Firestore — et la bibliothèque continuait d'afficher l'ancienne.

La grille de la bibliothèque garde une copie locale des livres, pour qu'un glissement en cours ne
soit pas coupé par une mise à jour du flux. Elle ne renouvelait cette copie que sur un changement
d'**ordre**, comparé identifiant par identifiant. Un livre modifié à la même place ne changeait
donc rien : la grille gardait sa copie et réaffichait l'ancienne valeur.

Le défaut ne touchait pas que les couvertures. Un titre corrigé, un auteur, un livre validé : rien
n'apparaissait tant que l'ordre ne bougeait pas.

La comparaison porte maintenant sur les instances (`identical`). Chaque instantané Firestore
reconstruit ses `Book`, alors qu'un simple rebuild du parent rend les mêmes objets : la
distinction est exacte et ne coûte rien. Comparer champ par champ aurait demandé d'énumérer les
vingt champs du modèle, et d'y penser à chaque champ ajouté.

Un test le vérifie, et il échoue sans le correctif.

### v0.22.26 — fonctionnel

#### Le bandeau de mise en file d'une couverture disparaît

« Scan de couverture ajouté… » se posait au bas de l'écran pendant deux secondes, là où le doigt
revient pour passer à la suite. Il fallait l'attendre ou viser à côté.

C'est le raisonnement déjà tenu pour la page de recette, appliqué à la couverture : l'écran dit
déjà que l'import est parti, la file des traitements en cours est affichée en permanence, et le
livre apparaît dans la bibliothèque de lui-même. Un message qui recouvre le geste suivant coûte
plus qu'il n'apprend.

Le document de livre garde le sien : il rattache des recettes à un livre déjà choisi, et personne
ne l'enchaîne.

### v0.22.25 — technique

#### `1 << 32` vaut zéro sur le web : plus aucun scan ne partait

Depuis la v0.22.21, aucun import ne partait depuis le navigateur — ni couverture de livre, ni
page de recette, ni document. Le bouton « Appliquer » de l'atelier de retouche refermait l'écran
et rien ne se passait.

La mise en file d'un scan tire un identifiant : `Random().nextInt(1 << 32)`. dart2js compile les
opérateurs de bits sur des entiers 32 bits. `1 << 32` vaut 4 294 967 296 sur la machine virtuelle
et **0** dans un navigateur, et `nextInt(0)` lève `RangeError` — dès la première ligne, avant le
moindre envoi.

Trois raisons pour lesquelles la panne est restée invisible deux versions :

- l'exception remontait jusqu'à la remise du résultat de l'atelier, que rien n'entourait ;
- l'application native n'était pas touchée, le calcul y étant juste ;
- aucun test ne pouvait la voir : ils tournent tous sur la machine virtuelle.

La borne s'écrit maintenant en littéral, `0x100000000`, qui vaut la même chose des deux côtés.
La remise du résultat attrape et remonte (`imageEnhancerScreen.deliverResult`). Et
`test/web_int_semantics_test.dart` refuse tout décalage de 32 bits ou plus dans `lib/` : une
suite qui ne s'exécute pas dans un navigateur ne peut pas mesurer la différence, elle peut
seulement interdire la construction.

Le diagnostic vient des traces posées en v0.22.24 : l'atelier appliquait bien le recadrage
(5,2 Mo en entrée, 321 Ko en sortie), il se rouvrait sur la photo d'origine sept millisecondes
plus tard, et `scanUpload.coverQueued` n'apparaissait jamais. La mise en file n'était donc jamais
atteinte.

### v0.22.24 — technique

#### Le recadrage d'une couverture, tracé de bout en bout

Le recadrage d'une couverture de livre ressort sans effet : l'image revient non modifiée, et
aucune erreur n'est levée. Trois causes possibles, qu'aucune trace ne distinguait — le cadre
n'était pas armé, le résultat s'est perdu entre l'écran et Storage, ou l'atelier s'est rouvert
sur la photo d'origine.

Trois remontées suivent maintenant la chaîne :

- `scanUpload.enhancerOpened` — l'atelier s'ouvre. Dit par quelle voie (transition ou filet), le
  rang de l'ouverture, et si l'image est la même que la précédente.
- `imageEnhancerScreen.applied` — la validation. Dit si le cadre était armé, de combien les coins
  s'écartent du cadre entier, les réglages de lumière et de détails, et les tailles en octets à
  l'entrée comme à la sortie.
- `scanUpload.coverQueued` — la mise en file. Dit ce qui part réellement dans Storage.

Deux tailles qui divergent entre la deuxième et la troisième, et le résultat s'est perdu en
route. Un cadre non armé, et l'atelier n'avait rien à appliquer.

#### L'état oubliait de lâcher la photo d'origine

`ScanState.copyWith` recopiait `pendingImageBytes` à chaque changement d'état, sans jamais
l'effacer. La photo d'origine restait donc dans l'état bien après son traitement, et tout retour
en attente d'amélioration rouvrait l'atelier sur elle — pas sur le résultat du recadrage.
`copyWith` accepte désormais `clearPendingImage`, et la mise en file l'utilise.

#### deploy.ps1 s'arrêtait sur un avis npm

Le déploiement de la v0.22.23 s'est arrêté juste avant les functions : `npm` avait écrit un avis
de mise à jour sur stderr, et `$ErrorActionPreference = "Stop"` transforme toute écriture sur
stderr par un exécutable natif en erreur terminante — comportement de PowerShell 5.1. Le web et
l'APK étaient construits, rien n'était en ligne, et le message ne parlait que de `firebase.ps1`.

`Invoke-FirebaseCli` bascule en `Continue` le temps de l'appel. Les quatre appels à la CLI
passent par lui. Ce qui décide du succès ne change pas : le code de sortie et la ligne
« Deploy complete! ».

---

## 2026-08-30

### v0.22.23 — technique

#### L'import d'une couverture restait sur son indicateur

L'écran de scan passe la photo en attente d'amélioration, puis l'atelier de retouche s'ouvre
par-dessus. Il ne s'ouvrait que sur la **transition** vers cet état, écoutée par `ref.listen`.

`ref.listen` ne délivre jamais la valeur en place au moment où il s'enregistre. Quand l'image
passait en attente alors que l'écran n'était pas monté — un retour de caméra qui recrée l'arbre
sur Chrome Android, un onglet restauré — l'écran se montait, s'abonnait, et n'entendait plus
rien. L'indicateur tournait indéfiniment, aucun code ne levait quoi que ce soit, et la seule
trace de l'incident était une capture d'écran.

L'atelier s'ouvre désormais depuis l'**état courant**, à chaque build. Une transition manquée se
rattrape à la frame suivante.

#### Trois trous de journalisation comblés

Le diagnostic a coûté une session entière faute de trace. Trois remontées ont été ajoutées :

- `scanUpload.enhancementReopened` — l'atelier a été ouvert par le filet, donc la transition a
  été manquée. C'est le log qui manquait pour nommer la panne ci-dessus.
- `imageEnhancerScreen.slowOpen` — l'ouverture a dépassé huit secondes. Le rapport porte la durée
  de chacune des trois étapes (décodage, analyse des couleurs, détection du cadre), la taille de
  l'image, ses dimensions et la plateforme. Sur le web, `compute` n'ouvre aucun isolate et ces
  analyses tournent sur le fil principal : c'est cette mesure qui dira si le coût est là.
- `imageEnhancerScreen.loadImage` — le chargement de l'image n'avait aucun `catch`. Une image
  illisible laissait l'atelier sur son indicateur, sans un mot. Elle ferme maintenant l'atelier.

L'image s'affiche aussi avant les deux analyses, qui s'enchaînent au lieu de partir ensemble. Et
le libellé « Améliorez l'image… » — qui s'adressait à l'utilisateur alors que rien n'était encore
ouvert — devient « Ouverture de l'atelier… », l'atelier nommant ensuite son étape en cours.

### v0.22.22 — fonctionnel

#### Les réglages du moteur d'IA s'enregistrent sous un nom

*Admin › Moteur d'IA* pilote sept réglages, dont trois par poste : le moteur, le modèle
Claude et le plafond de raisonnement de chacun des quarante-trois postes. Revenir à un état
antérieur demandait de refaire les bascules de mémoire, ce qui ne rend jamais le même état.

Un bandeau « Configurations » en tête d'écran enregistre l'ensemble sous un nom. Cinq gestes :
charger, mettre à jour, renommer, supprimer, enregistrer sous. « Enregistrer sous » avec un nom
déjà pris propose d'écraser cette configuration ; deux homonymes sont refusés.

**Charger n'écrit rien.** L'écart s'affiche d'abord — « Moteur par défaut : Gemini → Claude »,
« 9 postes passent à Claude », « 3 postes servis par Claude changent de modèle » — puis le
formulaire est rempli. C'est la barre d'enregistrement qui décide, comme avant. Un chargement ne
doit pas pouvoir déplacer quarante-trois postes sans que personne l'ait lu.

**Le chargement est un remplacement, pas une fusion.** Un poste que la configuration ne nomme
pas repart au moteur par défaut. Une fusion rendrait le résultat dépendant de ce qui était en
place avant, et deux essais successifs ne seraient plus comparables — le seul usage de cet écran.

La configuration **« Haute performance »** est créée au premier affichage à partir du réglage
déjà en place. Sans elle, essayer autre chose demanderait de penser d'abord à enregistrer l'état
courant, et personne n'y penserait avant de l'avoir perdu.

### v0.22.22 — technique

#### Une configuration vieillit, et reste chargeable

La liste des postes routables perd des entrées à chaque version : huit sont déjà parties avec le
code qui les appelait. Une configuration écrite en juillet qui nomme un poste disparu reste
chargeable — le poste est écarté et la raison remonte à l'écran. La refuser en bloc laisserait un
état ancien inatteignable sans dire lequel des quarante-trois postes bloque.

Une même fonction juge les deux cas, `readRoutingPolicy` (`ai/routingPresets.ts`), sur deux
modes : `reject` pour ce que l'écran écrit, `drop` pour la relecture d'une configuration. Sans
ce partage, une configuration s'enregistrerait valide et se chargerait invalide.

Nouvelle collection `ai_routing_presets`, lecture administrateur et écriture serveur seule. Une
seule fonction déployée de plus, `aiRoutingPresetsFn`, aiguillée sur un champ `action`.

Un défaut corrigé au passage : la détection des modifications en attente ignorait les plafonds de
raisonnement par poste. Une configuration qui n'en changeait qu'un se chargeait sans faire
apparaître la barre d'enregistrement, et le réglage était perdu au retour.

---

## 2026-08-29

### v0.22.17 — technique

#### Release complète : web, APK, Windows

Rien de neuf pour l'utilisateur. Le desktop Windows est rebuild et déposé dans
`Release/desktop`, et la documentation rattrape les deux versions précédentes : la règle
d'alignement des vignettes au chapitre 3, l'icône adaptative au chapitre 12, la version des
deux `README.md`, qui annonçaient encore la 0.21.103.

### v0.22.16 — technique

#### L'icône Android perdait sa transparence et affichait un liseré blanc

`assets/Icon.png` a un fond transparent. Les cinq `ic_launcher.png` produits étaient en RGB,
sans canal alpha : `flutter_launcher_icons` n'avait que `image_path`, il ne fabriquait donc que
l'icône ancienne, carrée, et aplatissait la transparence sur du blanc. Le lanceur d'Android 8
et au-delà posait ensuite son masque rond sur ce carré blanc, et ce qui dépassait du médaillon
faisait le liseré.

`adaptive_icon_background: "#6B7B3A"` — l'olive du thème — et
`adaptive_icon_foreground: "assets/Icon.png"` créent l'icône adaptative :
`mipmap-anydpi-v26/ic_launcher.xml`, `values/colors.xml`, et les cinq couches
`drawable-*dpi/ic_launcher_foreground.png`. Les `ic_launcher.png` sont désormais en RGBA. Le
fond d'une icône adaptative est toujours dessiné : il ne pouvait pas rester transparent.

`remove_alpha_ios: true` complète le lot. La transparence conservée pour Android avait
introduit un canal alpha dans les vingt et une icônes iOS, ce que l'App Store refuse.

L'icône ne change sur un téléphone qu'à la réinstallation de l'APK.

### v0.22.15 — fonctionnel

#### La première photo d'un brouillon prenait l'apparence d'une autre

Après un passage à l'atelier de retouche, la première vignette de l'onglet Photos affichait une
autre photo que la sienne. L'illustration n'était pas modifiée : c'est l'affichage qui mentait.

L'onglet lit `thumbnail_urls[i]` pour la photo `i`. Quand les deux listes n'ont pas la même
longueur, il n'y a pas une vignette manquante à la fin : tout est décalé. Les écrans
empilaient la vignette d'une photo ajoutée sur une liste de vignettes vide, qui atterrissait
donc en position 0. Trois recettes de la base sont dans cet état — deux photos, une vignette,
celle de la seconde.

`RecipeRepository.alignThumbnails` tranche à l'écriture : longueurs différentes, ce sont les
URLs pleine résolution qui sont écrites, parce que rien ne dit plus à quelle photo chaque
vignette appartient. Les sept appelants partent de cette liste alignée. Côté lecture, l'onglet
n'utilise les vignettes que si elles sont aussi nombreuses que les photos, ce qui rend leur bon
affichage aux trois recettes déjà écrites sans migration.

### v0.22.14 — fonctionnel

#### Les photos d'une recette avaient la taille d'une icône

Les illustrations d'une recette s'affichaient en vignettes de 48 pixels, posées dans le bandeau
de l'onglet « Préparer », entre la puce des portions et celle du temps de cuisson. À cette taille
une photo de plat ne se distingue pas d'une icône, et rien n'annonçait qu'il y en avait.

Un onglet **Photos** s'ajoute après « Communauté », sur grand écran. Il montre les illustrations
en grille, chacune ouvrable en plein écran, avec le compte en tête. Un éditeur y ajoute une photo
et supprime celles qui ne servent plus, sans passer par le bandeau. Les vignettes du bandeau
restent en place ; mobile, qui n'a pas d'onglets, garde le même affichage qu'avant.

Au passage : le raccourci « aller aux annotations » ouvrait l'onglet « Dressage ». Il visait
l'index 2 alors que « Communauté » est le quatrième onglet.

## 2026-08-28

### v0.22.11 — fonctionnel

#### Un livre ne disait pas de quelle bibliothèque il venait

La bibliothèque réunit les livres de tous les membres du groupe familial. Une fois le livre ouvert,
plus rien ne le rappelait. Le nom du propriétaire tenait entre parenthèses derrière le titre, et il
n'y tenait pas longtemps : un titre un peu long le poussait dehors. Rien ne disait par quel groupe
le livre arrivait.

L'écran du livre porte maintenant une ligne sous son titre. Elle se lit : Issu du groupe familial
« Les Kassbi », au travers de Fred. Un livre à soi affiche Ma bibliothèque. Sans groupe partagé —
le cas d'un administrateur qui ouvre le livre d'un membre — la ligne se réduit à Bibliothèque de
Fred. Sans nom lisible, elle disparaît : une phrase qui désigne un vide n'apprend rien.

La même mention figure dans « À propos », en face du champ « Bibliothèque ». Elle y voisine avec
« Auteur », qui reste celui du livre imprimé — les deux se confondaient jusqu'ici.

#### Chacun choisit le nom sous lequel la famille le voit

Les comptes Google portent des noms d'état civil. Dans une famille, ils partagent souvent le nom :
« Livres de Frédéric Kassbi » et « Livres de Marie Kassbi » ne se distinguent qu'au deuxième mot.

Un **nom préféré** s'ajoute au compte. Il vaut par défaut le prénom du compte Google — le premier
mot du nom affiché — et se règle depuis **Profil et compte** pour soi, ou depuis **Admin → Gestion
des utilisateurs** pour n'importe qui. Le laisser vide rend le compte à son prénom : la valeur par
défaut n'est jamais écrite en base, elle se recalcule à chaque lecture, faute de quoi elle
cesserait de suivre le compte Google.

C'est ce nom qui identifie les bibliothèques : en-têtes « Livres de… » et « Recettes libres de… »,
ligne d'origine du livre, propriétaire d'une recette, file de travail, membres d'un groupe. Le nom
Google reste visible dans les écrans de compte, où c'est l'identité qui compte.

## 2026-08-25

### v0.22.9 — fonctionnel

#### L'export PDF ne demandait que pour les photos

Le dialogue d'export posait une seule question : « Inclure les photos ». Les remarques, les astuces
et les corrections écrites par la famille n'étaient ni proposées, ni imprimées. Elles restaient à
l'écran, et la feuille posée sur le plan de travail ne les portait pas — alors qu'une astuce vaut
justement au moment où l'on cuisine.

Le dialogue demande maintenant pour chacune, et seulement pour ce qui existe. Une recette avec une
photo, deux astuces et une correction annonce ses quatre éléments et propose quatre interrupteurs.
Une recette sans astuce n'affiche pas de case « Inclure les astuces » : un réglage sans objet laisse
croire qu'il manque quelque chose au document. Une recette qui ne porte rien de plus n'ouvre pas de
dialogue du tout.

Chaque choix est retenu pour la fois suivante, mais seulement pour les catégories réellement
proposées : une case absente d'un export ne doit pas effacer le choix fait sur un autre.

Dans le document, les annotations retenues arrivent après la préparation et avant les photos,
groupées en trois sections — Remarques, Astuces, Corrections — chacune avec le nom de son auteur.

#### La note personnelle s'imprime à côté du titre

La note attribuée par celui qui imprime apparaît en haut de la page, étoile et chiffre, dans un
badge à côté du titre. C'est sa note à lui, pas une moyenne. Le dénominateur est écrit : à l'écran,
« ★ 8 » se comprend parce que le sélecteur est à portée de doigt ; sur une feuille, rien ne dit si
l'échelle va à cinq ou à dix.

#### Un défaut trouvé au passage

Le premier test qui compose réellement le document a révélé que l'en-tête portait depuis toujours
une décoration interdite : un liseré à gauche et des coins arrondis à la fois, ce que le moteur PDF
refuse. Le contrôle ne se déclenchait pas dans l'application publiée — il est retiré du binaire de
production — et la bordure était simplement dessinée de travers. Le rayon a été supprimé.

### v0.22.8 — fonctionnel

#### Coller un texte et scanner une page donnent enfin le même résultat

Les deux chemins ne se ressemblaient pas. L'import d'un scan déroulait trois étapes : le modèle
recopie la page, un second appel balise ce qui a été recopié, et du code compare les deux sans
rien coûter. Le bouton « IA » sur un texte collé tenait en un seul appel, avec un prompt qui
demandait de lire et de baliser en même temps — exactement ce que l'import avait cessé de faire.

**La liste d'ingrédients se dissolvait dans les étapes.** Le prompt du texte libre ne rendait que
du CookLang, où les ingrédients vivent à l'intérieur des phrases. « 2 gousses d'ail dégermées »
donnait un ingrédient, une quantité, une unité — et « dégermées » n'avait nulle part où aller. La
liste affichée était ensuite reconstruite en relisant les balises : sans la précision, sans la
ligne d'origine, sans la section d'où elle venait.

**Rien n'était vérifié.** Pas d'inventaire annoncé avant de recopier, pas de mots signalés comme
douteux, pas de contrôle de fidélité, pas de repli. Une étape résumée ou deux ingrédients fondus
partaient en base sans que personne le sache.

**Trois informations n'étaient même pas demandées** : le temps de repos, les types de plat et les
cuisines. Les champs existaient, l'écran savait les afficher, le prompt ne les réclamait pas.

Le texte collé emprunte désormais la même chaîne que la page scannée. Il en revient avec la liste
d'ingrédients normalisée — précision et ligne d'origine comprises —, les tags, le temps de repos,
et la réserve de fidélité affichée sur le brouillon quand le contrôle a quelque chose à dire. Un
texte qui contient deux recettes le dit : la première est reprise, et l'écran l'annonce plutôt que
de laisser découvrir l'absence de la seconde.

Deux détails au passage. Les durées entrent dans les champs en minutes — « 20 min » recopié tel
quel n'y tenait pas, et la recette partait sans temps de préparation. Et les métadonnées gérées par
le formulaire quittent l'éditeur, comme sur un brouillon : sans cela, une correction de
l'utilisateur restait sans effet, écrasée à la relecture par la ligne venue de l'IA.

Le traitement coûte deux appels au lieu d'un. Le poste comptable ne change pas de nom.

### v0.22.7 — fonctionnel

#### Quatre appels de détection sur cinq ne servaient plus

L'écran Moteur d'IA affichait cinq postes sous « Illustrations — détection ». Ils sortaient tous du
même bouton : « Extraire les illustrations », dans la relecture de brouillon et dans l'édition. Les
compteurs de `ai_usage_monthly` ont dit ce que chacun rendait.

**Le repli « photo principale » ne partait plus.** Il ne sert que si la détection principale ne rend
rien, ce qui n'est plus arrivé depuis juillet : cinq appels en quatre mois, zéro sur les deux
derniers. Retiré, avec la Cloud Function qui le portait.

**La cascade de subdivision dépensait trois appels pour rien.** Quand le modèle rendait deux à
quatre zones dont une dépassait le quart de la page, trois appels supplémentaires cherchaient une
grille de vignettes qu'il aurait fusionnée. Sur quatre mois : partie 109 fois, aboutie 3 fois à la
première approche et 13 fois à la deuxième. Le reste allait jusqu'au dernier repli, dont le résultat
était jeté s'il ne rendait pas plus d'une zone. Le prompt de détection demande déjà une boîte par
vignette ; le lui redemander trois fois ne le lui apprend pas. Une détection coûte désormais un
appel.

**Le redressement était calculé, facturé, puis jeté.** Le serveur corrige la perspective de chaque
zone — une page photographiée à main levée est un trapèze — et renvoyait les découpes redressées. Le
client ne lisait que les boîtes et refaisait la découpe lui-même, au rectangle : chaque illustration
gardait ses deux coins de papier et de table. Il prend maintenant les découpes du serveur, qui
écarte au passage ce qui n'est manifestement pas une photographie.

Les quatre postes retirés restent au catalogue comptable : les mois déjà facturés doivent continuer
de les nommer.

## 2026-08-23

### v0.21.104 — fonctionnel

#### Trois promesses retirées

Un audit d'expérience a relevé trois endroits où l'application annonçait ce qu'elle ne fait pas.
Aucun ne levait d'erreur — c'est ce qui les rendait coûteux : le texte s'affiche, il rassure, il est
faux. Les trois sont retirés plutôt que réparés.

**Le minuteur n'était pas un minuteur.** L'aide CookLang disait « Pour créer un minuteur interactif,
utilisez le symbole ~ ». Le jeton `~{30%minutes}` est en réalité une étiquette : il met la durée en
évidence dans l'étape et la reprend dans l'export PDF, il ne décompte rien. L'aide le dit maintenant
ainsi. La syntaxe, elle, ne bouge pas.

**La lecture hors ligne n'était vraie qu'à moitié.** « Connexion perdue » ajoutait « les recettes
déjà consultées restent lisibles hors ligne ». La persistance Firestore est active par défaut sur
Android natif et désactivée par défaut sur le web — la plateforme la plus utilisée, et la seule dont
dispose un iPhone. La phrase était donc fausse une fois sur deux, et fausse précisément au moment où
la panne survient. Le message se limite désormais à ce qu'il sait : vérifier la connexion, réessayer.

**Le mode cuisine faisait l'inverse de ce qu'il promettait.** L'interrupteur agrandissait le texte de
10 % — en *remplaçant* l'échelle du système au lieu de la multiplier. Quelqu'un ayant réglé son
téléphone à 150 % tombait donc à 110 % en l'activant : le mode cuisine rapetissait le texte de qui en
avait le plus besoin. Il masquait par ailleurs la barre de lecture, le bouton d'annotation et les
boutons d'illustration sans l'annoncer, et s'oubliait à chaque ouverture de recette. Il est supprimé.
La fiche garde tout ce qu'il masquait, et l'écran reste allumé comme avant — le maintien n'a jamais
dépendu de lui.

### v0.21.103 — fonctionnel

#### Le message de mise en file gênait le doigt

« Scan recette ajouté à la file de traitement » se posait au-dessus du bouton **Analyser**, juste où
le doigt revient pour enchaîner la page suivante. Il fallait attendre qu'il s'efface, ou viser à
côté. Une seconde perdue à chaque page.

Il est retiré. L'écran dit déjà la même chose sans rien recouvrir : les imports en vol s'affichent
en liste, la file des pages en attente se vide sous les yeux, et une puce compte les traitements en
cours.

Les deux autres messages restent — la couverture de livre et le document entier. Ils n'annoncent pas
« c'est parti » mais **ce qui va se passer**, et ces imports ne s'enchaînent pas.

### v0.21.102 — fonctionnel

#### Une recette dit maintenant son temps de repos

Marinade, réfrigération, levée, repos de pâte : le temps où **rien ne se fait**. Il est lu à
l'import, affiché sur la fiche, modifiable dans l'éditeur, imprimé dans le PDF.

Un seul champ pour toutes ces attentes. Un livre écrit « laisser mariner une nuit au frais » sans
dire si c'est du repos ou de la réfrigération.

**C'est au planning qu'il sert le plus.** Une recette qui demande quatre heures au frais se commence
la veille — l'IA de planification le sait maintenant, alors que rien ne le disait avant d'ouvrir la
recette le jour même.

Il ne s'ajoute pas au temps de préparation, et c'est voulu : douze heures de marinade additionnées à
la préparation donneraient une recette qui a l'air impraticable.

#### Les durées étaient mal lues

« 55 min, plus 4 h de réfrigération » devenait **3 300 minutes** de préparation. « 30 min de
chauffe » en donnait 1 800. Le programme prenait le premier nombre et le multipliait par soixante
dès qu'il voyait un `h` n'importe où dans la phrase, y compris au milieu d'un mot.

Il lit maintenant le premier nombre et l'unité qui le suit. « 4 h 55 » vaut 295 minutes,
« une nuit » vaut douze heures, « 2 jours » vaut deux jours.

#### Le minuteur « 1 à 2 minutes » s'affichait en morceaux

Une durée en fourchette apparaissait comme « 1-~{2 min » suivi d'une accolade. Elle s'affiche
maintenant d'un seul tenant, et se lit « 1 à 2 min » plutôt que « 1-2 min ».

#### Les durées du planning étaient perdues

Une recette créée par la planification de repas sortait sans temps de préparation ni de cuisson.
Elle les écrivait sous un nom que le reste de l'application ne reconnaissait pas.

### v0.21.102 — technique

#### Une durée sur deux était mal lue

`parseTimeToMinutes` prenait le **premier nombre**, puis multipliait par soixante dès qu'un `h`
traînait **quelque part** dans la chaîne. « 55 min, plus 4 h de réfrigération » rendait
**3 300 minutes**. « 30 min de chauffe » en rendait 1 800, parce que « chauffe » porte un `h`.
Aucune erreur levée, un chiffre absurde affiché comme un temps de préparation.

La règle est maintenant : **le premier nombre, l'unité qui le suit immédiatement, et rien
d'autre**. Ce qui suit la première durée n'appartient pas à ce champ — c'est une autre durée, et
elle a le sien. Unités reconnues : heures, jours, nuits (douze heures), minutes, secondes
(arrondies à la minute, jamais zéro). Un nombre nu se lit en minutes.

Nouvelle section `durations` dans `test-fixtures/cooklang_parsing.json` — 23 cas, rejoués par les
deux suites. La fonction est exportée des deux côtés pour ça.

#### Le temps de repos

Un champ, `rest_time`, pour **toutes** les attentes : marinade, réfrigération, levée, repos de
pâte. Un seul et non un par sorte — un livre écrit « laisser mariner une nuit au frais » sans dire
si c'est du repos ou de la réfrigération, et deux champs qui se confondent se remplissent mal tous
les deux.

Séparé de `prep_time` parce qu'on ne le passe pas à cuisiner. C'est aussi la seule des trois durées
qui change la **date** de préparation plutôt que la durée du geste : quatre heures au frais veulent
dire « commencer la veille », et c'est ce que le planning avait besoin de savoir.

| Couche | Ce qui a changé |
|---|---|
| Modèle | `RecipeTags.restTime`, écrit **inconditionnellement** — une clé absente ne pourrait plus effacer une valeur |
| Parseurs | trois alias, `temps_repos` → `rest_time` → `repos`, dans le **même ordre** des deux côtés |
| Fixture | `restTime` sur les cinq cas de recette + section `restTimeAliases` qui fige la **priorité** |
| Prompts | schéma de la passe 1, prose de recherche, rendu pour la passe 2, métadonnée CookLang, raffinage |
| Affichage | puce « Repos » dans `CooklangMetaRow`, ligne dans l'export PDF |
| Édition | champ dans `RecipeMetaPanel`, contrôleur dans le mixin, six appelants |
| Planning | attribut « 12 h de repos AVANT de servir » dans le prompt |

**Aucune migration** : `data['rest_time'] as int?` rend `null` sur les documents existants.

#### Trois défauts trouvés en chemin

**Le raffinage comptait la marinade deux fois.** `refiner.ts` disait au modèle « prep_time = durée
totale AVANT cuisson (épluchage, découpe, **marinade**, etc.) ». Ajouter `rest_time` sans retirer ce
mot aurait fait compter douze heures aux deux endroits. La règle est réécrite : `prep_time` est le
temps de **main à la pâte**, le temps où rien ne se fait a son propre champ.

**Le planning écrivait des clés que personne ne lit.** `planning.ts` demandait au modèle
`>> prepTime:` et `>> cookTime:` en camelCase ; les parseurs lisent `temps_preparation`,
`temps_préparation`, `prep_time`. Les brouillons du planning sortaient donc **sans durées**, depuis
toujours, sans qu'aucune erreur ne le dise.

**La puce de durée de la fiche recette ne lisait qu'un alias sur trois.** Elle testait
`meta['prep_time']` quand le prompt écrit `>> temps_préparation:` : elle ne s'affichait jamais sur
une recette importée. `_dureeDepuisMeta` lit maintenant les mêmes alias que le parseur, dans le même
ordre.

#### Le minuteur `~{1-2%minutes}` s'affichait en deux morceaux

`cooklangNormalizeStepTimers` enveloppe les durées écrites en texte brut. Pour savoir s'il était
déjà dans un jeton, il ne regardait que le **caractère précédent** — dans `~{1-2%minutes}`, c'est un
tiret, qui passait la garde. Il produisait `~{1-~{2%minutes}}`, et l'étape affichait une puce
« 1-~{2 min » suivie d'une accolade orpheline.

Le texte est désormais **découpé sur les jetons existants**, et seuls les morceaux entre eux sont
normalisés. Une garde de position ne peut pas dire « je suis dans des accolades » ; un découpage,
si.

Et la fourchette se lit : `formatTimerRange` écrit « 1 à 2 » là où le livre imprime « 1-2 ». Un
tiret entre deux nombres se lit « moins » avant de se lire « à ».

**Tests** : `test/timer_display_test.dart`, seize cas.

### v0.21.101 — technique

#### Le reporting de coûts était figé depuis cinq jours

`recordUsage` écrivait ses compteurs avec des **clés pointées** :

```ts
.set({ [`by_user.${uid}.cost_usd`]: FieldValue.increment(x) }, { merge: true })
```

`set()` du SDK Admin ne lit pas les points comme un chemin. Il a donc créé un champ **dont le nom
contient des points**, à côté de la carte `by_user` que les écrans lisent. Les deux ont grandi dans
le même document sans jamais se rencontrer : 618 champs plats qui suivaient chaque appel, et des
cartes figées au dernier passage de `rebuildAiUsageMonthlyFn`.

Constat au 23/08 sur `ai_usage_monthly/2026-08` :

| | Coût | Appels |
|---|---|---|
| Carte imbriquée `by_user` (lue par les écrans) | 5,11 € | 1 041 |
| Champs plats `by_user.…` (réalité) | 32,14 € | 2 354 |
| `total_cost_usd` du même document | 38,66 € | 3 928 |

`rebuilt_at` valait le 18/08 à 10:02. Aucune erreur nulle part : les trois chiffres étaient
sincères, ils ne parlaient pas de la même chose. Le total du mois, lui, restait juste —
`total_cost_usd` n'a pas de point dans son nom.

**La correction.** `buildMonthlyAggregate()` (`ai/usage.ts`) construit des cartes imbriquées.
`FieldValue.increment` fonctionne à n'importe quelle profondeur du moment que le chemin est fait
d'objets. La fonction est **pure et exportée** pour la seule raison qui compte : la forme est ce qui
s'est cassé, et une forme se teste sans base de données.

**La réparation des mois passés** ne demande aucun code : `rebuildAiUsageMonthlyFn` écrit avec un
`set()` **sans fusion**, qui remplace le document entier. Les 618 champs plats disparaissent d'
eux-mêmes. Bouton « Reconstruire les agrégats », Admin → Coûts.

**Tests** : `functions/src/tests/usageAggregate.test.ts`, six cas. Le premier interdit le point dans
une clé **brute** — et non dans un chemin aplati, où un point est indiscernable de l'imbrication.
C'est précisément la confusion qui a produit le défaut, et un test qui la reproduit ne prouve rien.

`costsCallable` lit les mêmes cartes : tout le reporting par poste était figé de la même façon, et
la même reconstruction le répare.

#### Le tableau des dépenses se filtre et se trie

Écran Admin → Dépense par utilisateur. Un filtre libre sur les noms — de compte **et** de poste : un
compte est gardé s'il correspond lui-même ou si un de ses postes correspond, et seuls les postes qui
correspondent s'affichent alors. Trois tris — coût, appels, nom — appliqués aux deux niveaux, avec
inversion du sens. Décroissant par défaut : la première question posée à ce tableau est
« qu'est-ce qui coûte le plus ».

**Pas de tri par date, et ce n'est pas un oubli.** Une ligne de ce tableau est un compte ou un
poste, agrégé sur toute la période ; aucune n'a de date propre. La date se choisit au-dessus, par
les puces de période. Le jour où l'agrégat rendra une ligne par mois, le tri aura un sens.

Le contrôleur du champ de filtre vit dans l'état de l'écran, pas dans le widget : construit dans
`build`, il serait recréé à chaque frappe et le champ perdrait le focus après chaque lettre.

### v0.21.100 — technique

#### « (sans titre) » n'était pas un titre, et s'affichait comme tel

`renderTranscriptionForTagging` (`gemini/tagging.ts`) écrivait
`-- section : (sans titre)` pour signaler une section anonyme au modèle. Le prompt lui demande
par ailleurs de reprendre les titres de section **caractère pour caractère**. Il a obéi : des
recettes portent une section réellement nommée « (sans titre) », affichée dans le livre, dans
l'éditeur d'ingrédients et dans la liste normalisée.

Même famille que l'exemple rempli dans un prompt — tout ce qui ressemble à une valeur finit
recopié. Le marqueur devient `-- section --` : il marque une frontière, il ne propose plus rien
à reprendre.

**Deux garde-fous**, parce que le modèle peut produire un titre vide sans qu'on lui en souffle un.
`nettoyerTitreSection` vide six libellés qui ne nomment rien — `(sans titre)`, `sans titre`,
`(aucun)`, `aucun`, `-`, `—`. `nettoyerSectionsCooklang` retire du CookLang les lignes
`== … ==` dont le titre en fait partie ; une ligne qui commence par `==` sans être un en-tête est
laissée intacte.

**Les recettes déjà importées sont réparées à la lecture, pas en base.**
`RecipeIngredient.normalizeIngredientCategory` (`features/recipes/domain/recipe.dart`) rend `null`
pour ces mêmes libellés, et `RecipeIngredient.fromMap` l'applique. `cooklang_preview_model.dart`
fait de même pour les en-têtes `== … ==`. Rien à migrer, et rien à perdre si une migration se
passait mal.

**Tests** : `functions/src/tests/pageIllustrations.test.ts` (neuf cas, dont un en-tête qui
disparaît, un vrai titre qui reste, et une ligne `==` au milieu d'une phrase qu'on ne touche pas)
et `test/recipe_model_test.dart` (dix cas, dont la réparation d'un document Firestore existant).

### v0.21.99 — fonctionnel

#### L'écran ne reste allumé que sur le téléphone Android

La fiche recette empêche l'écran de s'éteindre pendant qu'on cuisine. Ce maintien est désormais
**réservé à l'application Android**.

C'est là qu'il sert : le téléphone posé sur le plan de travail, les mains dans la pâte. Sur un
navigateur ou sur le client Windows, l'écran se comporte de nouveau comme celui de n'importe quelle
page.

Sur le web, la fonction ne marchait de toute façon pas : elle échouait à chaque ouverture de
recette et remplissait les rapports d'erreurs sans jamais tenir l'écran allumé.

### v0.21.99 — technique

#### Le maintien de l'écran est réservé à l'APK Android

`PlatformUtils.isAndroidApp` (nouveau) : `!kIsWeb && Platform.isAndroid`. L'ordre compte —
`dart:io` n'existe pas sur le web, et `Platform.isAndroid` y lèverait ; le `&&` court-circuite
avant d'y toucher. Même construction que `isMobile`. Distinct de `Platform.isAndroid` seul, qui
répond vrai depuis un navigateur Android.

`ScreenWakelock` prend un second paramètre injecté, `supported`, dont le défaut est
`PlatformUtils.isAndroidApp`. Le garde est placé dans **`acquire()`** et non dans `_apply()` :
hors Android le compteur ne bouge pas, donc `release()` et `refresh()` deviennent inertes
d'eux-mêmes. Une seule ligne décide.

**Injectable comme le basculement, et pour la même raison.** Sous `flutter test`, la plateforme
hôte est Windows : un test écrit en dur aurait éteint le verrou dans tous les tests, qui seraient
passés au vert sans plus rien vérifier. Les cinq cas existants passent `supported: true`, un
sixième vérifie qu'avec `supported: false` la plateforme n'est jamais sollicitée.

**Ce n'est pas une limite technique mais un choix.** Le plugin sait tenir l'écran sur Windows et,
en principe, dans un navigateur. La fonctionnalité vise le téléphone posé sur le plan de travail.

**Le web y était en plus cassé.** Son implémentation n'entrait pas dans le bundle : le fichier
d'enregistrement des plugins web (`.dart_tool/flutter_build/…/web_plugin_registrant.dart`) date du
17/08, la veille de l'ajout de `wakelock_plus`, et n'a jamais été régénéré. `main.dart.js` ne
contient aucune trace de `assets/no_sleep.js`, seulement le nom du canal natif
`dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle`. Chaque ouverture de
recette envoyait donc l'appel vers un canal sans destinataire, d'où un `PlatformException`
`channel-error` par session.

Ce garde éteint la cause. **Le dossier de compilation reste périmé** : le prochain plugin web
ajouté tombera dans le même trou, en silence. À corriger le jour où un plugin web s'ajoute.

`wakelock_plus` reste dans `pubspec.yaml` — une dépendance Flutter n'est pas déclarable par
plateforme. Elle n'est simplement plus appelée hors Android.

### v0.21.98 — technique

#### Le balisage rendait parfois une réponse vide

`TAGGING_MAX_TOKENS` passe de **24 000 à 36 000** (`gemini/tagging.ts`).

Sur un import réel, Claude Sonnet 5 a dépensé les 24 000 jetons **en réflexion** et n'a pas écrit
un caractère : `stop_reason` à `max_tokens`, `outputTokens` à 24 000 exactement, texte de longueur
zéro. Le message d'erreur qui en découlait — « tagAndNormalize: réponse illisible », causé par
`JSON.parse("")` — décrivait le symptôme et non la cause.

La reprise Cloud Tasks a sauvé l'import, mais de justesse : 21 693 jetons au second essai, dont
environ 20 000 de réflexion pour 1 700 de réponse. Le plafond était donc dépassé une fois sur deux
sur cette recette.

**36 000 est un palier d'essai, pas une certitude.** La réflexion est en mode `adaptive` : elle
choisit sa longueur, et rien ne dit encore si elle grandit avec le budget qu'on lui laisse. Si un
appel cale de nouveau, le levier n'est pas le plafond mais la réflexion elle-même —
`thinking: { type: "enabled", budget_tokens: N }` garantit alors `max_tokens - N` à la réponse. Le
SDK impose `budget_tokens ≥ 1024` et strictement inférieur à `max_tokens`.

**Le plafond borne, il ne réserve pas.** Une réponse courte se facture courte. Ce qui suit le
plafond, c'est le prix d'un échec : 0,47 € à 36 000 contre 0,32 € à 24 000, pour rien dans les deux
cas. À comparer aux 0,11 € de toute la chaîne d'illustrations d'une page.

**La transcription reste à 24 000** : ses appels observés plafonnent à 6 450 jetons de sortie, soit
un quart de son budget.

**Deux manques constatés au passage, non corrigés à ce stade.** Une réponse vide n'est pas traitée
comme une erreur par `callAnthropic` : le routeur ne bascule donc pas sur Gemini, qui aurait su
répondre. Et le budget de réflexion réglable dans Admin → Moteur d'IA n'est passé qu'au client
Gemini (`router.ts`, `resolveThinkingBudget`) : le curseur existe et ne fait rien pour Claude.

### v0.21.97 — fonctionnel

#### Un import peut rapporter les photos de la page

L'écran d'import porte une case **« Extraire les illustrations »**. Cochée, l'import repère les
photographies et les dessins imprimés sur la page, les découpe, et les attache à la recette. Il
faut pour cela redresser la page, la remettre à l'endroit, et distinguer une photographie du texte
qui l'entoure — l'application le fait maintenant seule.

**L'import ne se met pas en attente.** La case part avec le fichier, le traitement se fait en
arrière-plan, et l'écran redevient disponible aussitôt. On peut enchaîner dix pages sans attendre
la première.

**Une page de texte s'arrête tout de suite.** L'application regarde d'abord si la page porte quelque
chose à prendre. Quand elle n'en porte pas — une page de recette sur deux — elle ne fait rien de
plus. Décochée, la case laisse l'import exactement comme avant : les photographies sont comptées
pour la relecture, aucune n'est extraite, et l'atelier manuel reste là pour les prendre à la main.

**Le compte est donné même quand l'extraction rate.** L'écran de relecture continue d'annoncer
« trois photos repérées sur cette page » et de renvoyer vers l'atelier manuel. C'est précisément le
moment où ce chiffre sert : sans lui, une recette partirait sans image et rien ne dirait qu'il y en
avait à prendre.

#### Préférences, dans le menu

Le menu du compte compte une entrée de plus : **Profil et compte · Préférences · Groupes familiaux ·
Se déconnecter**.

**Préférences** rassemble les réglages du compte : l'extraction des illustrations par défaut, et les
préférences de planification — qui étaient enterrées dans l'écran de profil. Un réglage qu'on ne
trouve pas est un réglage qui n'existe pas.

Le réglage des illustrations est un **défaut**, pas un verrou. L'écran d'import s'ouvre dessus, et la
case s'y change import par import sans que ce choix remonte au profil. Elle garde sa valeur d'un
import au suivant, et retombe sur le défaut quand on revient sur l'écran.

### v0.21.97 — technique

#### Extraction des illustrations d'une page importée

La chaîne mise au point dans le bac à sable (Admin → Bac à sable → Importation d'image) est portée
dans l'import de livre. Elle est **facultative** et **asynchrone** : cochée à l'import, elle
s'exécute dans `recipeProcessor`, et l'écran d'import est rendu dès la mise en file — enchaîner dix
pages n'attend jamais la fin du traitement de la première.

**Le module — `functions/src/illustrations/`**

| Fichier | Rôle |
|---|---|
| `prompts.ts` | Les cinq prompts, **copiés** du bac à sable, mot pour mot |
| `sheet.ts` | La planche 2×2 des quatre orientations, composée avec Sharp |
| `extract.ts` | La chaîne, de la photo brute aux découpes |
| `ledger.ts` | Le journal en bloc : une ligne par étape, avec son coût, puis le total |
| `store.ts` | Publication sous `illustrations/{uid}/` et bilan de relecture |

**Ce qui part au modèle, et non seulement le prompt.** Les quatre textes de `prompts.ts` sont
copiés du bac à sable au caractère près. Le message envoyé, lui, ne l'était pas : le bac à sable
préfixe aux prompts de cadrage et de zones la ligne « L'image mesure X pixels de large et Y de
haut. », et « Ce gros plan mesure … » pour la passe des coins. Le portage l'avait perdue, alors
que le prompt des coins demande toujours de placer les sommets « au pixel près ». `sizeHeader()`
la reconstruit à l'identique, et `test/pageIllustrations.test.ts` verrouille la phrase.
L'orientation n'a jamais eu d'en-tête, des deux côtés : on y demande de reconnaître une vignette,
pas de mesurer.

**Le côté long envoyé au modèle est de 2048 px**, la valeur avec laquelle la chaîne a été mise au
point. Le portage l'avait ramené à 1600 sans raison.

**Les six étapes**

1. **Pré-contrôle** (`page_illustrations_precheck`) — un appel sur la photo brute : cette page
   porte-t-elle une photographie, un dessin, un schéma ? Non → la chaîne s'arrête, et les trois
   postes suivants n'ont pas lieu. Le cas est fréquent : une page de recette sur deux ne porte
   aucune image. C'est le seul poste dont on peut dire s'il rapporte plus qu'il ne coûte, et c'est
   pour ça qu'il est compté à part.
2. **Cadrage** (`page_illustrations_frame`, un à deux appels) — une **boîte droite** d'abord, puis
   les **quatre coins** sur un gros plan de cette boîte (marge de 25 %). Deux questions et non une :
   un modèle encadre bien et place mal des sommets libres. Sous 60 % de confiance, la passe des
   coins est rejouée une fois et la réponse la mieux assumée gagne — les cadrages justes s'annoncent
   au-dessus de 80 %, celui qui ne l'était pas à 42 %, donc une page facile ne repasse jamais par là.
3. **Mise à plat** — `warpQuadrilateral` (`gemini/perspective.ts`), plafond porté à **4000 px** par
   son nouvel argument `options`. Chiffre mesuré : à 2048 px, une double page sort à 650 px de large
   et son corps de texte à cinq pixels de haut ; l'étape 4 n'y lit plus rien. Les coins subissent
   d'abord une homothétie de **+2 %** — un liseré de décor ne gêne personne, un bord de photo rogné
   est perdu. `isFullFrame` **saute cette étape** quand le cadre couvre déjà toute l'image, à
   quinze millièmes près : un scan à plat ou une capture d'écran n'a rien à redresser, et
   ré-échantillonner chaque pixel lui coûterait de la netteté pour rien.
4. **Remise à l'endroit** (`page_illustrations_orientation`) — le programme compose une **planche
   2×2** des quatre rotations, marquées A/B/C/D, et demande « dans laquelle sais-tu lire ». La
   question précédente — « de combien de degrés tourner cette page » — recevait « zéro » à 98 % de
   confiance devant une page couchée. Le programme applique le quart de tour ; le serveur ne connaît
   même pas les degrés, il rend une lettre. Les glyphes sont des matrices 5 × 7 agrandies, et non du
   texte rendu : le conteneur des Cloud Functions n'a aucune police installée.
5. **Zones** (`page_illustrations_regions`) — des rectangles droits, la page étant déjà à plat et à
   l'endroit. **Une zone = une photographie** : deux photos qui se touchent bord à bord valent deux
   zones, une grande scène continue en vaut une. Le champ `bounded_by` est obligatoire et rend la
   coupure vérifiable — un modèle qui scinde à tort une photo ne sait pas nommer ce qui sépare les
   deux moitiés.
6. **Découpe** — un simple recadrage sur la page pleine résolution. Rien n'est ré-échantillonné :
   chaque pixel gardé est celui d'origine.

**Le coût, en euros, en un bloc**

`IllustrationLedger` écrit **une ligne par étape**, au fil de l'eau, toutes sous le même
`correlationId` (`<corrélation du job>_p<numéro de page>`) et ordonnées par `stepIndex`. La ligne de
clôture porte `stepIndex: 0` — elle se trie donc en tête — et donne le **total** du bloc, le nombre
d'illustrations, le nombre d'appels et la durée. Chaque ligne porte `costEur`, `costUsd`, les jetons
et l'`observed` du modèle.

Aucun montant n'est inventé. Sans taux de change (`app_config/currency_rate`), la ligne affiche des
**dollars** ; sans tarif pour le modèle, elle affiche « montant inconnu » et le total compte les
étapes non chiffrées. Un coût manquant se voit, un coût faux ne se voit pas.

**Le branchement — `pipeline/recipeProcessor.ts`, étape `design`**

Deux chemins qui ne se cumulent jamais. **Coché** : la chaîne complète, jusqu'à cinq appels par page,
et des images attachées à la recette. **Décoché** : `countPageImages`, un appel de **pré-contrôle**
par page, qui compte les images sans rien extraire.

Ce second chemin appelait d'abord `detectIllustrationRegions` et n'en gardait que `boxes.length`.
Deux prompts posaient donc la même question — « cette page porte-t-elle des images, et combien » —,
et celui-là était le plus lourd : il décrit un repère de coordonnées, des règles de cadrage et un
format de boîte dont l'appelant ne faisait rien. Le pré-contrôle le remplace, et
`detectIllustrationRegions` garde son vrai rôle : rendre des **boîtes à découper** pour l'atelier
manuel (`detectAndCropIllustrationsFn`), qui, lui, en a besoin. Le poste `detect_illustrations` sort
donc du pipeline et ne sert plus que la callable.

**Et il est seul.** Quatre autres postes vivaient dans `gemini/detector.ts` : `detect_main_photo`,
un repli qui ne partait plus depuis juillet, et la cascade `detect_grid_dims` →
`detect_illustrations_crop` → `detect_illustrations_grid`, qui cherchait une grille de vignettes
fusionnée dès que le modèle rendait deux à quatre zones dont une dépassait le quart de la page. Les
compteurs mensuels ont tranché : cascade partie 109 fois en quatre mois, aboutie 3 fois à la
première approche et 13 fois à la deuxième, le reste allant jusqu'au repli dont le résultat était
jeté s'il ne rendait pas plus d'une zone. Les quatre sont retirés du code et de `ROUTABLE_FEATURES`,
et **restent** au catalogue comptable.

La callable renvoie désormais les **découpes**, pas les boîtes. Elle redresse la perspective
(`warpQuadrilateral`) puis passe par `cropAndSelectIllustrations`, dont les trois filtres locaux
écartent ce qui n'est pas une photographie. Le client lisait les boîtes et refaisait la découpe au
rectangle avec le paquet Dart `image` : le redressement était calculé, facturé, puis jeté, et chaque
illustration gardait ses deux coins de papier et de table.

**`illustration_report.detectees` dit ce que la page PORTE, jamais ce qu'on en a tiré.** Les zones
repérées à l'étape 5 quand la chaîne est allée au bout, le compte du pré-contrôle quand elle s'est
arrêtée avant. C'est ce qui permet au bandeau de relecture de rester utile après un échec : « trois
photos repérées, à extraire à la main » est exactement ce qu'il faut dire à ce moment-là. Un compte
absent ou aberrant sur une page qui porte des images vaut 1 — zéro ferait dire au bandeau qu'il n'y
a rien à prendre.

`illustration_report` prend enfin des valeurs non nulles sur `retenues` et `publiees` : depuis le
retrait de l'ancienne extraction automatique, `image_urls` était rempli d'une liste déclarée et
jamais alimentée.

**Le bac à sable reste en place, et diverge**

`functions/src/sandbox/` porte toujours sa version. Les prompts ont été **copiés**, pas partagés :
partagés, un essai raté du bac à sable changerait le comportement de la production. L'écran de
l'expérience porte une bannière qui le dit, et le sous-titre du registre aussi — l'erreur à empêcher
est de régler un seuil ici et de croire que l'application en profite.

**Trois endroits, comme tout poste d'IA** : `ctx.feature` de l'appel, `ROUTABLE_FEATURES`
(`callable/aiRoutingCallable.ts`, groupe « Extraction des illustrations d'une page »), et `feature_catalog.dart`
(`kFeatureProcess` + `kFeatureCatalog`, processus « Illustrations d'une page »).

## 2026-08-22

### v0.21.60 — fonctionnel

#### L'atelier s'ouvrait sur un outil déjà choisi

« Cadre » était sélectionné dès l'ouverture. Le premier geste possible était donc de cliquer sur une puce déjà active, qui ne faisait rien.

L'écran s'ouvre maintenant sans panneau. L'image d'abord, les outils quand on les demande.

#### « Cadre » arme le recadrage

La puce ouvrait un panneau, qui offrait un bouton « Recadrer ». Deux clics pour un geste. Et le premier ne montrait rien, puisque la puce était déjà sélectionnée.

La puce arme maintenant le cadre directement. La désélectionner l'abandonne : le même geste, dans l'autre sens.

Le bouton « Recadrer » reste dans le mode recadrage seul, qui n'a pas de puces. Là, c'est lui qui arme.

#### La coche gênait l'icône

Les puces affichaient une coche à la sélection, par-dessus leur propre icône. Deux signes pour la même information, et le plus utile des deux caché.

La coche est retirée. Le fond coloré suffit à dire ce qui est actif.

### v0.21.59 — fonctionnel

#### Le bas de l'onglet Photos était hors d'atteinte

Sur téléphone, l'état vide dépasse la hauteur disponible : icône, titre, deux lignes de texte et deux boutons. Le bas passait sous la barre de navigation, et rien ne défilait.

Les boutons existaient et étaient cliquables. Ils n'étaient simplement pas atteignables.

Le bloc est maintenant dans un `SingleChildScrollView`, avec un `ConstrainedBox(minHeight)` qui garde le centrage quand la place suffit.

#### « Cadrez-les vous-même » sans dire par où

Le message annonçait trois photos sur la page et invitait à les cadrer soi-même. Mais « Ajouter » ouvre la galerie du téléphone, pas le scan du livre. Une consigne sans porte.

Un bouton **Cadrer depuis le scan** ouvre l'atelier de retouche directement sur la page scannée. Il apparaît dans la barre d'actions et, sur l'état vide, en action principale — devant « Ajouter une photo », puisque c'est là que sont les photos annoncées.

Le chemin existait déjà dans le code. Son bouton était parti avec l'extraction automatique, alors que ce n'est pas la même chose : l'extraction décidait du cadrage, celui-ci le laisse à qui regarde la page.

Le bouton ne s'affiche pas si le scan est un PDF : l'atelier ne l'ouvrirait pas, et le clic échouerait sans rien dire.

## 2026-08-21

### v0.21.58 — fonctionnel

#### La note se corrige

Elle était transportée sans être modifiable. Le motif : elle vient du livre, la retoucher inviterait à la réécrire.

Le motif était faux. La note ne vient pas du livre. Elle est **déduite** de la ligne du livre, par un découpage qui se trompe. « concassées » pour des grains de coriandre, « mélangée » sans son complément. Une valeur devinée qu'on ne peut pas corriger est pire qu'un champ vide.

L'éditeur d'ingrédients porte donc une ligne de plus sous chaque ingrédient. Sans bordure, en italique : c'est une légende, pas un champ de formulaire. Elle est toujours visible, même vide — cet écran sert à confronter la recette à la page, et ce qui doit se corriger doit d'abord se voir.

La flèche à gauche porte la ligne du livre en infobulle. De quoi vérifier la précision sans rouvrir le livre.

#### Les astérisques disparaissent

La note se lisait en renvoi, à la façon des livres de cuisine : un astérisque sur la puce, la note en bas du groupe. Trois défauts à l'usage.

Les marqueurs s'empilent — `*`, `**`, `***`, `****` — et deviennent illisibles au quatrième. Ils repartent de zéro à chaque section, si bien qu'un même astérisque désigne deux choses sur la même page. Et lire la recette demande un aller-retour entre la puce et le bas du bloc, pour quatre mots.

Les notes sont courtes. « concassés », « hachées », « avec la peau ». Elles tiennent sous le libellé, dans la puce, en plus petit et en italique.

Le bloc « À savoir sur les ingrédients » est retiré. Il répétait ce que la puce dit maintenant.

### v0.21.57 — fonctionnel

#### « à 3 » n'est pas une précision du livre

Le miel portait une note : `à 3`. Reste de « 2 à 3 cuil. à café de miel », un intervalle dont le parseur n'a gardé que la borne basse — le modèle a rendu la queue comme précision. Elle ne précise rien, et une note qui ne dit rien fait douter de celles qui disent quelque chose.

Une note doit désormais porter **au moins un mot de trois lettres**, sinon elle est écartée avant même le calcul de repli. Le seuil est d'un mot et non de deux : « concassés », « hachées », « dégermées » tiennent en un mot et disent l'essentiel. C'est le calcul — plus exigeant parce qu'il devine — qui en réclame deux.

#### Ce que la moutarde et le miel ne rendront pas

Le livre écrit une seule ligne : « 2 cuil. à café de moutarde à l'ancienne mélangée à 2 à 3 cuil. à café de miel ». La transcription en fait **deux entrées** — et c'est juste, ce sont deux ingrédients, deux quantités, deux entrées de courses. Mais la relation entre eux se coupe au découpage : la moutarde garde « mélangée », le miel ne garde rien.

Ce n'est pas un défaut d'affichage, et aucune règle de lecture ne le répare : l'information n'existe plus dans la ligne rattachée. La rendre demanderait que la transcription conserve la ligne entière **en plus** des deux entrées. C'est identifié, ce n'est pas fait.

### v0.21.56 — fonctionnel

#### La note était écrite, et jetée à l'ouverture

Trois versions à la chercher dans l'import, dans le prompt, dans le balisage. Elle y était. Le document `recipes/2XPkj61VmU4l07Xeh99k` porte les seize ingrédients, seize `source` et six `note` :

```
filet de saumon  1.8 kg   note: "avec la peau, mais écaillée"
grains de poivre 1.5 c.s. note: "concassés"
moutarde         2   c.c. note: "mélangée"
```

Elle se perdait au dernier mètre. `_dedupeStructuredIngredients`, appelée par `Recipe.fromFirestore`, **reconstruit** chaque ingrédient pour n'en garder que la version rognée — et recopiait quatre champs sur six. `note` et `source` tombaient là, entre Firestore et l'écran, sans erreur et sans trace.

D'où le bloc « À savoir » invisible : la liste qu'il consulte n'avait plus rien à dire. Et d'où la ligne de constat qui annonçait *« 0 avec une précision du livre »* — elle lisait le même objet amputé. Cette ligne a fait son travail : la question était insoluble en raisonnement, elle s'est tranchée d'un chiffre. Elle est retirée.

La leçon dépasse ce cas : **une recopie champ par champ est une liste qui vieillit mal**. Tout champ ajouté au modèle et oublié dans une de ces reconstructions disparaît en silence. `test/recipe_model_test.dart` verrouille la traversée.

#### Une consigne n'est pas une alerte

Le bandeau portait un triangle orange sur « 3 photos repérées — à extraire à la main ». Le contrôle n'avait pourtant **rien** à redire du texte : c'était une consigne, présentée comme une faute de lecture. Elle s'affiche désormais en bleu, sous une icône de photothèque, titrée « Photos de cette page ». Confondre les deux apprend à ignorer les vraies alertes.

### v0.21.55 — fonctionnel

#### Le bandeau prenait toute la place

Il s'ouvrait en grand, au motif qu'une réserve qu'il faut aller chercher n'est pas une réserve. C'était juste tant qu'il tenait en trois lignes. Il porte depuis le compte des photos, l'état de la donnée, cinq constats et leurs puces : déplié, il occupait l'écran entier **avant qu'on ait vu un ingrédient**.

Il part maintenant replié, et son titre porte le signal : *« Écart constaté avec la page du livre · 4 points »*. Le nombre décide si l'on ouvre — « écart constaté » seul ne distingue pas un titre de section raccourci, qu'on peut ignorer, d'une recette amputée.

#### Un reproche à tort de moins

> • miel (ingrédient 10) : cuil, melangee

Faux positif. Le miel est nommé en **fin** de sa ligne — « 2 cuil. à café de moutarde à l'ancienne mélangée à 2 cuil. à café de miel » — et les mots réclamés appartiennent à la moutarde, qui les porte déjà dans sa propre note.

Le contrôle comparait **tous** les mots de la ligne. Il ne regarde plus que ce qui **suit** l'ingrédient, exactement comme la déduction de la note : les deux partagent désormais la même fonction, et ne peuvent plus diverger. Un reproche à tort finit par faire ignorer le bandeau entier — y compris les constats qui comptent.

### v0.21.54 — fonctionnel

#### La donnée se lit à l'écran, au lieu de se raisonner

Trois versions passées à chercher pourquoi une note ne s'affichait pas, **sans jamais pouvoir dire si elle existait**. Le code l'écrit — on peut le lire ligne à ligne — mais personne ne pouvait le constater depuis l'application, et un raisonnement qu'on ne peut pas confronter à la donnée finit par tourner en rond.

Le bandeau de relecture porte désormais une ligne de constat :

> *Sur 12 ingrédients : 2 avec une précision du livre, 12 avec la ligne d'origine.*

Si elle annonce zéro, la chaîne d'import est en cause. Si elle annonce deux et qu'on ne voit rien, c'est l'affichage. Une question tranchée d'un coup d'œil, au lieu d'un aller-retour.

#### « À savoir sur les ingrédients »

Ce que le livre dit en plus des quantités est rassemblé sous la liste, dans un bloc à part :

> **Filet de saumon** avec la peau mais écaillée
> **Moutarde à l'ancienne** mélangée à 2 cuil. à café de miel

La quantité se compte, la précision se lit — et elle se lit **avant** d'aller acheter, pas au milieu de la recette. Le discriminant est sans ambiguïté : un ingrédient dont le champ `note` n'est pas vide. Rien n'est déduit à l'affichage, rien n'est demandé à un modèle — la note a été calculée à l'import, depuis la ligne du livre.

Le bloc disparaît quand aucun ingrédient n'en porte : une rubrique vide occupe la place et apprend à ne plus regarder.

### v0.21.53 — fonctionnel

#### « Extraction des illustrations » annonçait un travail supprimé

L'étape s'affichait encore sous ce nom alors que l'extraction avait été retirée. Vérification faite, **aucune extraction ne subsistait** : la liste d'images de l'import est une constante vide, et tout ce qui la suivait tournait à vide. C'était l'étiquette qui mentait — mais une étiquette qui annonce un travail supprimé fait attendre un résultat qui ne viendra pas, et c'est une raison suffisante de douter du reste.

Elle dit maintenant ce qui se passe : **« Recherche de photos sur la page… »**.

#### Et le code qui la faisait croire est parti

Trois morceaux tournaient encore à vide, et le prochain lecteur y aurait vu la preuve qu'une extraction se produit :

- la **copie des illustrations** pour la seconde recette d'une même page — un soin réel tant que deux recettes ne pouvaient pas partager un objet Storage sans que la suppression de l'une vide l'autre, sans objet depuis que l'import ne publie rien ;
- la mise en quarantaine et la génération de vignettes, déjà retirées ;
- les imports qui les servaient.

Du code mort n'est pas neutre quand il raconte une histoire fausse.

### v0.21.52 — fonctionnel

#### La note manquait parce qu'elle était demandée au modèle

Trois versions à chercher au mauvais endroit. La cause est une erreur de conception, et elle tient en une phrase : **la ligne du livre était demandée au modèle.**

La note se déduit de cette ligne — c'est ce que la page dit après avoir nommé l'aliment et sa quantité. Mais le champ qui la portait, `brut`, faisait partie de ce que la passe de balisage devait **recopier dans sa réponse**. Quand elle ne le faisait pas — et elle ne le faisait pas toujours — la ligne était perdue, la note ne pouvait plus s'en déduire, et l'écran n'avait rien à montrer. Aucune erreur, aucun signal : un champ vide, indistinguable d'une ligne qui ne disait rien.

**Or cette ligne, nous l'avons déjà : c'est la transcription.** La demander au modèle était l'erreur. Elle est désormais rattachée par le code, et la note calculée ensuite.

Deux précautions, parce qu'un rattachement faux serait pire que l'absence :

- **Le rang est vérifié avant d'être cru.** Des comptes égaux ne prouvent pas l'alignement : une ligne qui nomme deux aliments et une autre que le modèle a fondue donnent le même total sans le même ordre. L'aliment doit se retrouver dans la ligne qu'on s'apprête à lui attribuer — sans quoi la moutarde héritait de la ligne du sel, avec une note plausible et personne pour s'en douter.
- **Un nom que deux lignes réclament ne s'attache à aucune.** « Aneth » pour le saumon et « aneth » pour la sauce ne se départagent pas par le nom seul. Une note attachée au mauvais ingrédient serait pire qu'aucune note, parce qu'on la croirait.

La note proposée par le modèle reste prioritaire quand il en fait une : il sait reformuler un lien — « mélangée au miel » — là où la soustraction rend une bribe. Mais son silence ne fait plus perdre le texte.

### v0.21.51 — fonctionnel

#### Le modèle Claude se choisit poste par poste

Le **fournisseur** se choisissait poste par poste ; le **modèle**, non. Basculer un poste sur Claude imposait donc le même modèle à tous les autres — le mauvais grain, parce que les postes n'ont pas les mêmes exigences.

Transcrire une page de livre demande de la précision et se paie à la page. Estimer les calories d'une carotte est un rappel de connaissances, répété quinze fois par recette. Un seul modèle pour les deux, c'était soit payer Opus pour la carotte, soit lire le livre avec Haiku.

**Admin → Moteur d'IA** propose désormais, sous chaque poste routé vers Claude, le choix entre **Opus 5**, **Sonnet 5** et **Haiku 4.5** — avec, sous le sélecteur, ce à quoi chacun sert. Le choix ne se devine pas depuis un identifiant technique, et le mauvais choix ne se voit ni dans un sens ni dans l'autre : un modèle trop petit rend une page abîmée qui a l'air correcte, un modèle trop grand rend une facture qui a l'air normale.

Trois décisions dans le détail :

- **Le sélecteur n'apparaît que sous un poste effectivement routé vers Claude.** L'afficher inactif ailleurs ferait croire qu'il manque un réglage, alors qu'il manque une bascule.
- **Un poste réglé sur le modèle par défaut n'écrit rien.** Garder l'exception figerait ce poste le jour où le défaut change, sans que personne s'en souvienne. Le défaut porte d'ailleurs la mention « défaut » : la différence entre *ce poste suit le réglage général* et *ce poste a choisi la même chose* compte le jour où le général bouge.
- **Seuls les modèles de la grille tarifaire sont acceptés**, à l'écriture comme à l'écran. Un identifiant hors grille se facturerait sans montant et gonflerait `total_unpriced_calls` — un coût invisible, exactement ce que ce projet refuse. Un test le vérifie modèle par modèle.

### v0.21.50 — fonctionnel

#### La ligne du livre suit l'ingrédient jusqu'en base

Trois tours de recherche pour la même note : d'abord dans l'affichage, puis dans le modèle, puis dans la persistance. À chaque fois, la même impasse — **une note vide était indistinguable d'une ligne qui ne disait rien de plus.**

La ligne du livre est désormais stockée avec l'ingrédient (`source`). Elle n'est pas calculée, elle est la pièce à conviction : la note s'en déduit, et quand la note manque, c'est elle qui dit si le livre avait quelque chose à ajouter.

Conséquence immédiate à l'écran : **l'éditeur affiche la note si elle existe, la ligne du livre sinon.** Il ne peut plus rien y avoir de vide sans qu'on sache pourquoi.

#### « Extraire » quitte l'onglet Photos

Les deux boutons appelaient la même détection que le pipeline d'import, avec les mêmes résultats : un cadrage qui rend le bureau avec le plat. Un bouton qui ne tient pas sa promesse coûte plus qu'il ne rend — on le presse, on attend, on jette.

L'import dit combien de photos la page porte ; « Ajouter » et l'atelier de retouche font le reste, en dix secondes et sans surprise.

#### Deux réparations d'écran

- **Le conseil renvoyait vers « Raffiner », qui n'existe pas.** La fonction s'appelle « Améliorer » et ne fait que de la mise en forme CookLang : elle ne relance ni la lecture de la page ni le balisage. Envoyer quelqu'un vers un bouton qui ne répare pas ce qu'on lui reproche, c'est lui faire perdre son temps deux fois. Le bandeau dit maintenant : *corrigez à la main ci-dessous, en confrontant à la page du livre.*
- **Sur mobile, les dernières actions de l'onglet Photos sortaient de l'écran.** Elles existaient, elles étaient cliquables, elles n'étaient simplement pas visibles — la pire des trois situations, parce qu'on ne cherche pas ce qu'on ne soupçonne pas. Elles passent à la ligne.

### v0.21.49 — fonctionnel

#### Deux écrans qui se contredisaient sur le même scan

Le bandeau annonçait « 5 photos repérées », l'onglet Photos affichait « Aucune photo détectée ». Deux affirmations contraires, sur la même page.

Ils ne parlaient pas de la même chose : l'onglet constatait qu'aucune image n'était **attachée**, et en concluait qu'il n'y en avait pas à prendre. Depuis le retrait de l'extraction automatique, les deux n'ont plus rien à voir — l'import **repère**, il n'attache plus. L'onglet lit maintenant le même compte que le bandeau, et dit quoi faire : *le scan en contient, cadrez-les vous-même depuis l'original*.

#### Deux faux positifs dans les écarts

- **« Conseil du chef » signalé comme section manquante alors qu'il était là.** L'inventaire du modèle appelle « section » tout ce qui porte un intertitre sur la page — y compris ce qui est transcrit comme une **note**. Ne comparer qu'aux sections faisait passer chaque note pour une section perdue : un reproche à tort, sur ce qui était précisément présent.
- **« SAUCE À L'ANETH ET À LA MOUTARDE » signalée comme titre raccourci.** Un livre groupe souvent ses **ingrédients** sous un intertitre sans que la méthode, elle, ait une partie séparée. Exiger ce titre dans le texte balisé reprochait au balisage une section que la page ne porte pas dans ses étapes — un faux positif systématique sur toute recette dont la liste est plus découpée que la méthode. Seules les sections d'**étapes** sont désormais attendues.

Un reproche à tort coûte plus cher qu'une absence de contrôle : il apprend à ne plus lire le bandeau.

#### Et la note, enfin : elle est bien produite

Vérifiée de bout en bout sur les cas réels — « 2 cuil. à café de moutarde à l'ancienne mélangée à 2 cuil. à café de miel » donne bien *mélangée à 2 cuil. à café de miel*, et « 1 filet de saumon de 1,8 kg avec la peau mais écaillée » donne *avec la peau mais écaillée*. Le journal d'enregistrement compte désormais **combien d'ingrédients portent une note** : cherchée deux fois au mauvais endroit — dans l'affichage, puis dans le modèle — faute de savoir si elle existait.

### v0.21.48 — fonctionnel

#### Pourquoi votre recette est repartie sans balise

Le bandeau disait tout. La page portait **une** ligne : « 2 cuil. à café de moutarde à l'ancienne mélangée à 2 cuil. à café de miel ». La transcription l'a **coupée en deux** — ingrédient 9 et ingrédient 10 — tandis que le balisage a gardé la ligne **entière** dans son champ d'origine.

Aucune des deux moitiés n'était égale à l'ensemble. Le rapprochement, qui exigeait l'égalité, a conclu que les deux lignes n'avaient pas d'ingrédient correspondant. Verdict : rupture, et tout le balisage jeté — alors que les deux ingrédients étaient bel et bien là.

Deux défauts, deux corrections :

- **Le rapprochement tolère la coupure et la fusion.** Une ligne est couverte dès qu'une entrée la contient, ou qu'elle la contient.
- **Et il ne rompt plus.** Ce contrôle rapproche des **chaînes de caractères** : il constate une correspondance manquante, pas une perte de contenu. La perte réelle est prouvée par un autre — celui qui compare les mots de la page à ceux du texte balisé. C'est lui qui a le droit de jeter, parce qu'il démontre. Le premier signale, et laisse relire.

#### L'extraction automatique des images est retirée

Elle enchaînait détection, découpage, trois filtres de qualité, correction de perspective, modération Cloud Vision et publication — et rendait des images que personne ne gardait. Chaque maillon a été corrigé tour à tour : l'orientation EXIF, le seuil de subdivision, le cadrage, le repère de coordonnées, l'homographie. Le résultat restait en deçà de ce qu'un recadrage à la main donne en dix secondes.

**Ce qui reste vaut, lui, son appel : savoir qu'il y a une photo.** Sans cette ligne, une recette part sans image et rien ne dit qu'il y en avait une à prendre. L'écran de relecture l'annonce :

> *2 photos repérées sur cette page — à extraire à la main depuis l'onglet Photos.*

Et quand la détection elle-même échoue, elle le dit — c'est une autre situation, qui appelle une autre réaction.

L'atelier de retouche manuel, qui n'a jamais démérité, fait le reste. Le pipeline d'import perd au passage le découpage, les filtres, la modération de découpes et la génération de vignettes : moins de code, moins d'appels, et une promesse qu'on tient.

### v0.21.47 — fonctionnel

#### Un constat dit toujours OÙ regarder

Une seule ligne portait sa position — « peau en dessous **(étape 1)** » — et c'est celle qui servait. Un écart sans emplacement oblige à relire la page entière pour le retrouver, et une vérification coûteuse ne se fait pas. C'est devenu la règle, partout :

| Constat | Ce qu'il dit maintenant |
|---|---|
| Ligne d'ingrédient perdue | « 1 bouquet d'aneth » (ingrédient 3, Pour le saumon) — 1 sur 2 attendue(s) |
| Précision perdue | filet de saumon (ingrédient 1, Pour le saumon) : peau, écaillée |
| Note perdue | Le conseil du chef — « Se conserve trois jours au frais. » |
| Écart d'étapes | Pour le saumon : 3 étape(s) sur la page — section par section |
| Mot mal lu | le modèle doit désormais terminer chaque doute par sa position : *(étape 3)*, *(ingrédient 2)*, *(titre de section)*… |

#### Et les accents reviennent

Le titre de section s'affichait sous sa forme **comparable** — « sauce a l aneth et a la moutarde », qu'on lit comme une faute de frappe et non comme le titre du livre. Cette forme est mise à plat pour que « POUR LA SAUCE » et « Pour la sauce » se reconnaissent : elle sert à **comparer**, jamais à afficher. Le message rend maintenant le titre tel que le livre l'écrit.

### v0.21.46 — fonctionnel

#### La note d'un ingrédient ne dépend plus du modèle : elle se calcule

Constater qu'une précision manquait ne suffisait pas. « Avec la peau mais écaillée » est écrit dans le livre, et devait finir dans la recette — signaler son absence, c'était s'accommoder de la perte.

**Or elle se calcule.** C'est ce que la ligne dit après avoir nommé l'aliment et sa quantité : une soustraction, pas un jugement, et une soustraction ne se demande pas à un modèle.

| Ligne du livre | Ingrédient | Note déduite |
|---|---|---|
| 1 filet de saumon de 1,8 kg avec la peau mais écaillée | filet de saumon | avec la peau mais écaillée |
| 2 cuil. à café de moutarde à l'ancienne mélangée à 2 cuil. à café de miel | moutarde à l'ancienne | mélangée à 2 cuil. à café de miel |
| 250 g de porc haché | porc haché | *(aucune, et c'est le cas normal)* |

**Ce que la fonction ne fait pas : inventer.** Chaque mot rendu vient de la ligne, dans son ordre — un test le vérifie mot à mot. Une note inventée serait pire que pas de note, parce qu'on la croirait.

**La proposition du modèle reste prioritaire** quand il en fait une : il sait reformuler un lien — « mélangée au miel » — là où la soustraction rend une bribe. Mais son silence ne fait plus perdre le texte.

Deux détails qui décident du résultat : on prend ce qui **suit** le dernier élément identifié, et non ce qui reste après découpage — recoller les morceaux rendait « 1 de avec la peau mais écaillée », les trous du milieu se refermant sur des articles orphelins. Et la ponctuation n'est retirée qu'aux bords : « cuil. à café » garde son point, parce qu'une note se lit comme le livre l'écrit.

### v0.21.45 — fonctionnel

#### Les illustrations sont redressées, pas seulement découpées

Une page de livre photographiée à main levée n'est pas un rectangle, c'est un **trapèze**. Un cadre rectangulaire, aussi serré soit-il, garde forcément deux coins de papier et de table : c'est une limite de la forme, qu'aucun prompt ne lève. Seule une projection l'efface.

- **Le détecteur rend désormais les quatre coins** de chaque photographie — haut-gauche, haut-droit, bas-droit, bas-gauche — et non un rectangle englobant. La consigne est explicite : *ne redresse rien toi-même, donne les coins tels que tu les VOIS, de travers s'ils le sont ; c'est le programme qui redressera.*
- **La correction de perspective vit maintenant côté serveur** (`gemini/perspective.ts`) : le même algorithme que l'atelier de retouche manuel — normalisation de Hartley, résolution du système 8×8, interpolation bilinéaire. La chaîne automatique rend enfin ce que l'outil manuel rendait.
- **Pourquoi une homographie et pas une rotation** : une rotation redresse l'inclinaison mais laisse la déformation en trapèze, celle qui vient de photographier une page depuis un angle. Les deux bords opposés n'ont alors pas la même longueur, et seule une projection les égalise.
- **Une zone déjà droite n'est pas redressée** — un scan à plat, une capture d'écran. La transformation ne changerait rien de visible, et le découpage préserve la netteté d'origine sans ré-échantillonner.
- **Les deux formes de réponse sont acceptées** : quatre coins, ou une boîte convertie en son rectangle. Un modèle rend parfois la boîte englobante par habitude, et la refuser reviendrait à perdre une photo correctement repérée pour une question de forme.
- **Le coût mesuré** : 122 ms pour une photo de téléphone de douze mégapixels. La boucle est en clair — Sharp redimensionne, tourne et découpe, mais ne projette pas.

Deux détails qui font la différence entre une image juste et une image nette mais fausse : l'**ordre des coins** décide quel côté sera le haut (deux coins intervertis donnent un résultat impeccable et retourné), et les dimensions de sortie prennent la **moyenne géométrique** des bords opposés — retenir le plus grand étirerait l'image dans un sens.

### v0.21.44 — fonctionnel

#### Le détecteur croyait regarder une page ; il regarde une photo de page

La détection fonctionne enfin — et la découpe rendait le bureau et le clavier avec la photo. Le prompt disait « cette image de livre », et le modèle cadrait en conséquence : large, comme on cadre une page.

Or ce qu'il reçoit est **une photo de page** : le livre a été posé sur un bureau et photographié à main levée. Autour de la page il y a du décor — le plateau de la table, un clavier, une souris, une ombre, souvent la page d'en face — et le livre est de travers, ses bords non parallèles à ceux de l'image.

Le prompt le dit maintenant, et énumère ce qui doit rester dehors : pas un centimètre de bureau, pas la marge blanche du papier, pas la page voisine, pas la reliure. Avec la conséquence, qui est le vrai argument : **une boîte trop large est inutilisable, puisqu'elle sera publiée telle quelle, décor compris.** Et un repère de vraisemblance : sur une photo de page prise à main levée, la photographie imprimée occupe rarement plus des deux tiers du cadre — une boîte qui couvre presque tout est presque toujours fausse.

**Ce qui reste à faire, et qui n'est pas fait :** redresser la perspective. Une page photographiée de biais est un trapèze ; un cadre rectangulaire, aussi serré soit-il, garde deux coins de papier. Le corriger demande les quatre coins de la photographie et une transformation homographique — l'outil manuel « Améliorer » le fait déjà, la chaîne automatique non.

### v0.21.43 — fonctionnel

#### La note d'ingrédient : arrêter de deviner, la rendre constatable

La note ne s'affichait toujours pas — et la bonne question n'était pas « où l'afficher » mais **« est-elle produite ? »**. Le chemin de données était vérifié de bout en bout : le modèle ne la remplissait tout simplement pas.

- **Un contrôle mécanique le dit maintenant.** Pour chaque ingrédient, les mots de la ligne du livre sont confrontés à ceux du nom, de l'unité et de la note. Ce qui reste n'est allé nulle part : « 1 filet de saumon de 1,8 kg avec la peau mais écaillée » sans note laisse « peau », « écaillée » orphelins — et rien ne le signalait, puisque la ligne compte pour une, le nom est correct et la quantité aussi. Seuil à **deux mots** : un mot isolé est presque toujours un article, et le bruit fait ignorer le signal.
- **La règle du prompt était formulée à l'envers.** Elle insistait sur « n'invente jamais une note », et le modèle jouait la sécurité en la laissant vide. Elle est désormais positive et donne une méthode : *tu as écrit la quantité, l'unité et le nom — relis la ligne, et tout ce qui reste va dans la note*. Avec les trois cas, dont celui où il ne reste rien, qui est fréquent et normal.
- **Et la note occupe sa propre ligne** dans l'éditeur, avec sa marge et sa flèche de renvoi. Glissée dans l'interligne, elle passait inaperçue au milieu des champs bordés.

### v0.21.42 — fonctionnel

#### La détection d'images marche avec les deux moteurs

Les cinq postes de détection étaient passés sur Claude, et ne rendaient plus rien. La cause n'est pas le moteur : **le repère `[y_min, x_min, y_max, x_max]` sur mille est la convention native de Google**, et le prompt se contentait de l'énoncer — « entiers 0-1000 ». Cela suffit à un modèle qui l'a apprise, pas à un autre.

La réponse facile aurait été de réserver ce poste à Gemini. Elle était mauvaise : un moteur ne doit pas être privilégié par un détail de format resté implicite.

- **Le prompt décrit le repère au lieu de l'énoncer** : haut = 0, bas = 1000, gauche = 0, droite = 1000, la verticale d'abord, avec deux exemples — une demi-page à droite, une pleine page. Et il porte les **dimensions réelles de l'image**, pour que le modèle sache ce qu'il regarde.
- **La lecture accepte les trois unités** qu'un modèle peut spontanément employer : millièmes, valeurs entre 0 et 1, et **pixels** — ces derniers ramenés avec les dimensions, en respectant que la verticale se rapporte à la hauteur. Intervertir les deux axes produit un rectangle plausible et faux, donc invisible.
- **Sans dimensions, on borne au lieu de deviner.** Un facteur imaginaire donnerait une découpe précise et fausse ; une découpe bornée sera écartée par le contrôle de qualité, ce qui se voit.
- **Une limite, nommée plutôt que masquée** : sous mille, pixels et millièmes sont indiscernables — aucune heuristique ne peut trancher. C'est précisément pourquoi le prompt décrit le repère et donne les dimensions. Le code fait ce qu'il peut ; le prompt fait le reste. Un test le dit noir sur blanc.
- **Situer des rectangles demande du soin** : la détection passe en effort élevé, comme la transcription. Le réglage par défaut venait de la chaîne nutrition, où deviner des calories ne réclame aucun raisonnement.
- **Le repli « photo principale » ne se tait plus** non plus : il ne sert que si la détection principale n'a rien rendu, et l'échec des deux ensemble est justement ce qu'il faut pouvoir constater.

### v0.21.41 — fonctionnel

#### « Aucune photo détectée » cachait un `catch` vide

En cherchant pourquoi une page riche en photographies n'en rendait aucune, la vraie cause est apparue — et ce n'était pas la détection : **le code avalait l'erreur.**

```
} catch {
  return [];
}
```

Un refus du modèle, un plafond de dépense atteint, un délai dépassé, une réponse illisible, un format de coordonnées inconnu : tout se présentait à l'identique, sous la forme « aucune photographie détectée ». C'est la règle la plus stricte de ce projet, prise en défaut à l'endroit exact où elle comptait — **impossible de distinguer une page sans photo d'un appel qui a échoué**, alors que les deux demandent des réactions opposées.

- **L'erreur est journalisée et remonte.** La réponse brute du détecteur l'est aussi, avec son moteur et son modèle.
- **Une piste que cela rend enfin vérifiable** : le repère `[y_min, x_min, y_max, x_max]` sur mille est une convention **Google**. Un autre moteur ne la connaît pas et répond à côté, sans lever d'erreur. Une réponse non vide qui ne donne aucune boîte exploitable est désormais signalée comme telle, moteur nommé — si le poste `detect_illustrations` a basculé sur Claude, cela se verra au premier scan.
- **Une page qui échoue n'emporte plus les autres** : l'échec est absorbé page par page, sans quoi la panne de la seconde ferait perdre les découpes de la première.

#### Et l'écran le dit, au lieu de laisser deviner

Le bilan suit la recette et s'affiche à la relecture, avec la réaction qui convient :

| Ce qui s'est passé | Ce que l'écran dit |
|---|---|
| rien repéré | « Aucune photo repérée sur cette page. Si le livre en porte une, ajoutez-la à la main. » |
| repérées puis toutes écartées | « 3 photo(s) repérée(s), aucune retenue — trop petite, mal découpée, ou refusée à la modération. » |
| la détection a échoué | « La recherche a échoué sur 2 page(s). Ce n'est pas la page qui est en cause : réessayez. » |
| au moins une publiée | rien — elle se voit, l'annoncer serait du bruit |

### v0.21.40 — fonctionnel

#### La réserve se lit en puces, et se replie

- **Sept mots mal lus concaténés dans une phrase forment un pavé qu'on ne relit pas** — et une alerte qu'on ne relit pas ne sert à rien. Chaque constat porte désormais ses éléments à part, rendus en liste à puces.
- **Le bandeau se replie d'un chevron.** Il occupe le haut de l'écran de relecture, et l'on vient d'abord y relire la recette. Ouvert au premier affichage : une réserve qu'il faut aller chercher n'est pas une réserve.
- Les brouillons importés avant ce changement portent l'ancien format — une simple liste de phrases — et restent lisibles.

#### La note d'un ingrédient se voit enfin

« Mélangée au miel » existait bien en base, mais nulle part à l'écran.

- **Dans l'éditeur** : en italique sous le nom qu'elle précise. Elle ne se saisit toujours pas — la mettre dans un champ inviterait à la réécrire, et l'entrer dans le nom la ferait passer au référentiel des ingrédients et à la liste de courses.
- **Dans la recette** : un astérisque sur la pastille, et le renvoi sous le groupe — la convention des livres de cuisine eux-mêmes. La glisser sous chaque pastille cassait l'alignement : les puces cessaient de former des lignes régulières dès qu'une seule portait une note.

#### Une pleine page n'est pas une grille

La détection tentait encore de découper une photo pleine page en cases, et les tranches tombaient sur la nappe et le coin de bureau qui entourent le livre photographié.

**La subdivision ne s'applique plus quand le modèle n'a vu qu'une seule zone.** Il a compté une photo : on le croit. Une grille, il en voit les cases du premier coup — c'est précisément ce que son prompt lui demande. Chercher des cases dans une pleine page, c'est en trouver.

### v0.21.39 — fonctionnel

#### Le découpage des illustrations tombait à côté — l'orientation

**Le défaut, et il explique presque tout.** Un modèle de vision reçoit l'image telle qu'elle **s'affiche** : le décodeur applique l'orientation EXIF. Il rend donc des coordonnées dans ce repère-là. Sharp, lui, découpe la grille de pixels **stockée**. Pour une photo prise en portrait avec un capteur paysage — le cas de tout téléphone — les deux repères sont tournés de quatre-vingt-dix degrés l'un par rapport à l'autre.

On demandait le plat, on obtenait un bout de bureau. Et rien ne le signalait, parce que la découpe était techniquement valide : bonne taille, bon rapport de forme. Elle passait les filtres, puis se faisait refuser à la modération — d'où le « toutes les photos ont été rejetées », qui n'était pas un excès de sévérité mais la conséquence : **un bout de table est clair et uniforme, donc écarté comme page blanche.**

L'image est désormais redressée **une fois**, puis sert à la détection ET au découpage : les deux repères ne peuvent plus diverger. Corrigé dans le pipeline d'import comme dans l'extraction manuelle.

#### « Enregistrement » ne dure plus sept minutes

L'étiquette couvrait le balisage par l'IA, le contrôle de fidélité, la normalisation des référentiels et l'écriture. Un mot qui promet une seconde posé sur sept minutes, sans aucun moyen de savoir ce qui tournait.

Les étapes disent maintenant ce qui se passe : **Lecture de la page par l'IA**, **Extraction des illustrations**, **Balisage de la recette par l'IA**, **Enrichissement des ingrédients par l'IA**, puis **Enregistrement** — la dernière, et la plus brève.

Le calcul nutritionnel n'y figure pas volontairement : il a lieu **après** l'écriture, sur une recette déjà consultable. L'annoncer comme une étape laisserait croire qu'il faut l'attendre.

#### Atelier de retouche

- **Le cadre de recadrage s'imposait d'emblée.** Venu simplement pivoter une photo, on repartait avec un recadrage qu'on n'avait pas demandé — et rien ne le disait, puisque le cadre couvrait toute l'image et paraissait inoffensif. Il faut désormais l'**armer** par un bouton ; tant qu'il ne l'est pas, la validation n'applique que ce qui a été touché.
- **Le bouton de validation ne promet plus « Recadrer »** mais « Appliquer » : il valide ce qui a été fait, quoi que ce soit.
- **Les panneaux portent des icônes** : cadre, lumière, détails, presets.

### v0.21.38 — fonctionnel

#### La réserve de fidélité appartient au brouillon

- **Elle s'affichait sur la recette elle-même.** C'est un outil de **relecture** : il sert à décider si la recette est fidèle au livre, pas à cuisiner. Le bandeau vit désormais dans l'écran de relecture d'un brouillon, et nulle part ailleurs.
- **Et il disparaît à la validation.** La réserve a fait son office : elle a dit où regarder, quelqu'un a regardé et a tranché — c'est le sens même de valider. La rappeler ensuite reviendrait à contester cette décision chaque fois que le plat s'ouvre, et une alerte qui ne s'éteint jamais cesse d'être lue, y compris sur les brouillons où elle compte.
- **La réserve est levée, pas seulement masquée.** `validateDraft` efface `fidelity_level` et `fidelity_findings`. Les garder en base reviendrait à conserver un doute que plus personne ne peut lever, et à rouvrir le débat au premier écran qui déciderait de l'afficher.

#### Le chapeau de la recette se perdait

« Une méthode scandinave pour fumer le saumon dans le sel… » : beaucoup de recettes s'ouvrent par un paragraphe qui dit d'où vient le plat et pourquoi il vaut la peine.

- **Il tombait sous la consigne de ne pas recopier les en-têtes de page.** La distinction manquait : un titre courant ou un folio se répètent de page en page et ne parlent pas du plat ; le chapeau n'appartient qu'à cette recette.
- **Il a désormais son champ**, transcrit mot pour mot, transmis au balisage, et écrit en note **avant la première étape** — parce que le livre le met en premier. Dans le doute, la consigne est de le recopier : une phrase de trop se supprime en un geste, une phrase perdue ne se retrouve pas.
- **Et sa perte est constatée** : il compte dans le texte confronté au balisage. Sans cela, un chapeau oublié disparaîtrait comme avant — aucune étape en moins, aucun ingrédient en moins, aucun signal.

## 2026-08-20

### v0.21.37 — fonctionnel

#### Une ligne du livre peut nommer deux ingrédients

- **« 2 cuil. à café de moutarde à l'ancienne mélangée à 2 cuil. à café de miel » : le miel disparaissait.** Ma règle disait « une ligne du livre, une entrée — ni plus, ni moins ». Elle est fausse : cette ligne, c'est deux aliments, deux quantités, **deux achats**. La règle du compte exact obligeait à en choisir un, et le miel sortait de la liste de courses comme du calcul nutritionnel, sans un mot.
- **Deux entrées, et le lien vit dans la note** — « mélangée au miel », « mélangé à la moutarde à l'ancienne ». C'est exactement à cela que sert ce champ.
- **Le contrôle vérifie désormais une couverture, pas une égalité.** Aucune ligne ne peut rester orpheline ; deux entrées pour une ligne sont légitimes. Et il **compte les occurrences** : « 1 bouquet d'aneth » figurant dans deux sections, c'est deux achats — se contenter de vérifier que la ligne « existe quelque part » laisserait passer leur fusion, celle-là même que ce contrôle existe pour attraper.

#### Une légende de photo n'est ni une étape ni un conseil

« Gravlax (en haut) et gravlax à la betterave et à la moutarde » décrit l'image, pas le plat à faire. C'est du **mobilier de page**, au même titre qu'un folio ou un titre courant — et cela rejoint la liste de ce qu'on ne recopie pas.

#### L'en-tête du brouillon coupait sa dernière ligne

La barre gardait la hauteur d'une barre à une ligne — cinquante-six pixels — pour un titre qui en compte de deux à quatre : le titre, la pastille « Brouillon », le livre et sa page, le propriétaire. La hauteur se calcule maintenant sur ce qui est réellement affiché. Une valeur fixe généreuse ne vaudrait pas mieux : elle laisserait un vide sous les brouillons courts.

#### Les illustrations : un défaut trouvé, et de quoi trancher

- **Toute boîte dépassant 8 % de la page était soupçonnée d'être une grille** et découpée en morceaux. C'est la taille d'une photographie ordinaire dans un livre de cuisine : presque chaque photo réelle passait à la découpe, et une pleine page ressortait en tranches. Le seuil passe à **un quart de page** — la taille à laquelle les vraies grilles d'étapes se présentent.
- **Le prompt était écrit pour les grilles d'étapes seulement.** Il nomme maintenant les trois cas, en commençant par le plus fréquent : une grande photo demi-page ou pleine page (**une** boîte, pas quatre), une photo en bandeau, et seulement ensuite la grille.
- **Et surtout, on saura enfin où elles se perdent.** Une page revenait « sans illustration » sans qu'on puisse dire si le modèle n'avait rien vu, si les filtres avaient tout écarté, ou si la modération avait refusé — trois causes, trois corrections opposées, aucune trace pour choisir. Un décompte des quatre étapes est journalisé : détectées, retenues par les filtres, publiées après modération, avec les raisons des refus. C'est ce chiffre qui dira si ces appels valent leur prix.

### v0.21.36 — fonctionnel

#### Le modèle transcrivait en mode économique

« Avant modifications cela fonctionnait » était le renseignement décisif. Il ne s'agissait ni de la qualité de la photo, ni du prompt : **Claude transcrivait avec `effort: "low"`**.

- **Ce réglage était figé pour tout le monde**, avec une justification qui ne vaut que pour la nutrition : estimer les calories d'un ingrédient est un rappel de connaissances, pas un problème de raisonnement, et les jetons de réflexion se facturent au tarif de sortie. C'était juste — là.
- **Transcrire une page de livre est l'exact contraire.** Il faut suivre une mise en page, rattacher « en poudre » au bon ingrédient, ne pas résumer « les grains de poivre et les graines de coriandre » en « les épices ». Un modèle pressé fait précisément cela : il rend une phrase élégante et fausse.
- **Et la panne n'est apparue qu'en v0.21.33.** Jusque-là Claude échouait sur la transcription — le défaut de streaming — et Gemini prenait le relais. En réparant l'appel, on a confié la lecture à un moteur réglé pour aller vite. Le correctif précédent a révélé celui-ci.
- **Le soin se choisit désormais par poste.** `low` reste le défaut ; transcription et balisage passent à `high`. Côté Gemini, le levier équivalent existait déjà et se règle depuis Admin → Moteur d'IA (budget de réflexion par poste).

Deux abrègements silencieux sont par ailleurs nommés dans le prompt, avec leurs contre-exemples réels : **l'énumération résumée** (« les épices » fait disparaître deux ingrédients de la liste de courses) et **le qualificatif recollé au mauvais mot** (« en poudre » portait sur les épices, pas sur l'aneth, qui est frais). Un mot déplacé d'un cran change l'ingrédient.

**Sur la photo : il n'y a plus rien à gagner.** La capture est déjà à `imageQuality: 100` — aucune recompression — et aucune réduction de taille n'est appliquée : c'est la résolution complète du capteur qui part. Au-delà, le format ne propose rien de plus.

### v0.21.35 — fonctionnel

#### « peau en dessous » lu « peu profonde en dessous » : la panne que rien ne pouvait prouver

Un scan a rendu « étalez sur une plaque ou une assiette **peu profonde** en dessous » là où le livre écrit « une assiette, **peau** en dessous ». Ce n'est pas un défaut de restructuration : c'est une erreur de **lecture**, et elle appartient à une classe que tout l'appareil de contrôle ne pouvait pas voir.

**Pourquoi aucun contrôle ne l'attrape.** Les sept vérifications comparent la passe 2 à la passe 1. Quand la passe 1 a mal lu, **elle est la référence corrompue** : la phrase rendue est impeccable, le décompte des étapes intact, la couverture des mots parfaite. Tout concorde, avec le mauvais mot. Le seul moyen de le prouver serait de relire l'image — un appel de plus.

Trois corrections, du plus concret au plus honnête :

- **La qualité de capture était à l'envers.** Les couvertures de livre étaient photographiées à qualité 100, les **pages de recette** à 92. Une couverture se lit de loin, une page de recette se lit au mot près — et les artefacts JPEG s'installent d'abord sur les petits caractères. C'est ainsi qu'un « peau » devient un « peu ». Les pages passent à 100, sans recompression.
- **Le modèle ne doit plus « réparer » un mot qu'il lit mal.** C'est le second temps de la panne : ayant lu « peu », il complète en « peu profonde » — une expression plus courante, qui a l'air juste. Le prompt porte désormais l'interdiction et ce contre-exemple exact : écris ce que tu VOIS, même si le résultat te paraît étrange.
- **Et quand un doute subsiste, il est affiché.** La transcription déclare ses `lectures_incertaines`, qui remontent sur la recette. Ce n'est pas une garantie — un modèle sûr de lui ne signalera rien — mais un doute affiché se vérifie en dix secondes, là où le même doute tu se découvre en ratant le plat.

### v0.21.34 — fonctionnel

#### Le contrôle de fidélité voyait trois choses ; il en voit sept

Un premier scan a montré ce que le contrôle ne pouvait pas attraper : une section entière absente, un ingrédient devenu un autre produit, une clause disparue d'une étape. Trois défauts, trois angles morts.

- **Le trou principal : le contrôle comparait la passe 2 à la passe 1.** Il était donc aveugle à ce que la **passe 1** avait perdu. Une page dont la première section n'aurait jamais été recopiée produit une chaîne parfaitement cohérente de bout en bout — et personne ne s'en aperçoit avant de rouvrir le livre. La passe 1 **déclare maintenant son inventaire** avant de recopier : les titres de groupe qu'elle voit, le nombre de lignes d'ingrédients, le nombre d'étapes. Le code compare l'annonce au résultat. Un modèle qui déclare trois sections et en rend deux est pris en défaut par sa propre déclaration. Aucun appel de plus.
- **Le décompte des étapes ne dit rien de leur contenu.** « la moutarde mélangée à deux cuillères à café de miel » réduite à « la moutarde » ne change pas le nombre de lignes, et fait disparaître un ingrédient de la recette comme des courses. Les mots porteurs de sens de la transcription sont désormais confrontés à ceux du texte balisé.
- **Un ingrédient que sa propre ligne dément est nommé.** « 4 cuil. à soupe d'aneth frais » ne peut pas donner « aneth en poudre » : ce n'est pas une reformulation, c'est un autre produit, qui ne s'achète pas au même rayon et ne pèse pas la même chose. Chaque mot du nom doit figurer dans la ligne du livre, conservée à cette fin.
- **Une note perdue est signalée.** Rien d'autre ne la porte : ni les étapes, ni les ingrédients. Une « Astuce » que le balisage oublie disparaissait sans laisser de trace — et c'est souvent la seule phrase du livre qui dit comment réussir le plat.

**Sur les seuils, une leçon.** La première version de la comparaison de texte jetait le contenu des accolades — et accusait un balisage parfaitement fidèle d'avoir perdu un tiers de la page, parce que les quantités quittent légitimement la phrase pour y entrer. Les accolades sont conservées, les nombres écrits en lettres et les mesures abrégées écartés du comptage. Une accusation à tort finit par se faire ignorer, ce qui coûte plus cher que de ne rien vérifier.

### v0.21.33 — fonctionnel

#### Claude n'échoue plus sur la transcription

- **« Streaming is required for operations that may take longer than 10 minutes »** n'était pas une durée constatée. Le SDK Anthropic refuse un appel non-streamé dès que `max_tokens` dépasse **128 000 / 6 ≈ 21 333** : au-delà, il estime que la réponse *pourrait* demander plus de dix minutes, et lève avant même d'envoyer quoi que ce soit.
- La transcription d'une page en réclame **24 000** — pour ne pas tronquer un JSON verbeux. Elle échouait donc **systématiquement** sur Claude, et se repliait sur Gemini à chaque import. Le repli fonctionnait ; il masquait la panne.
- **Baisser le plafond aurait été la mauvaise réponse** : `max_tokens` ne réserve rien, il borne. Le réduire n'aurait pas accéléré l'appel, il aurait tronqué les pages longues. Les réponses Claude sont donc **streamées**, comme le SDK le demande ; `finalMessage()` rend exactement l'objet attendu, jetons et `stop_reason` compris.

#### Les journaux du déclencheur d'écriture

- **« Premier calcul » ne disait pas de quoi.** Nutrition ? courses ? les deux ? Les précisions nomment maintenant le travail : « Nutrition et courses à calculer », « Ingrédients modifiés », « Rien à recalculer ». Elles sont traduites, accents compris — « Ingredients modifies » se lisait comme une faute.
- **Deux réveils sur trois ne disaient rien et le disaient longuement.** Ce déclencheur se réveille lui-même en écrivant les courses, puis la nutrition : trois groupes de journaux par recette, dont deux pour constater qu'il n'y a rien à faire — chacun traînant douze mille caractères de recette, parce que la trace du texte était posée **avant** la garde. Elle est passée après : un journal qui répète le texte pour dire qu'il ne s'est rien passé rend illisibles ceux qui parlent.

### v0.21.32 — fonctionnel

#### Le déploiement ne rate plus sa première tentative

- **Ce n'était pas une panne du code, c'était une attente trop courte.** Avant de déployer, la CLI charge le bundle dans un processus à part pour savoir quelles fonctions il déclare. Ce chargement a **dix secondes** par défaut — et la première tentative les dépassait à chaque déploiement, invariablement suivie d'une relance qui, elle, passait. La différence entre les deux n'est pas le code : ce sont les cinquante fichiers que `tsc` vient de réécrire, encore froids sur le disque.
- **Le budget de découverte passe à deux minutes** (`FUNCTIONS_DISCOVERY_TIMEOUT`). Un échec systématique qu'on rattrape par une relance finit par masquer le jour où l'échec est réel.
- **Et le bundle s'allège vraiment**, pour ne plus frôler la limite : **547 ms → 328 ms**, quatre dixièmes de moins. Trois SDK lourds ne se chargent plus au démarrage mais au premier usage — Cloud Logging côté écriture (gRPC et protobuf, le plus coûteux du lot), Cloud Logging côté lecture, et BigQuery, qui ne sert qu'aux écrans de comptabilité. Même règle que le SDK Vision : ce qu'on ne charge pas au démarrage ne ralentit ni le déploiement ni le premier appel des autres fonctions.

#### Un écart avec le livre se voit maintenant sur la recette

- **Le contrôle de fidélité écrivait son verdict et personne ne le lisait.** C'est exactement le défaut que ce projet traque ailleurs : une donnée produite et jamais affichée finit par mentir sans que quiconque s'en aperçoive.
- **Un bandeau le dit, à l'endroit où l'on relit la recette.** En cas de **rupture** : « Texte du livre conservé, sans balise » — la recette est exacte, mais ses ingrédients et ustensiles ne sont pas mis en évidence, et l'on sait enfin pourquoi les puces manquent. En cas d'**avertissement** : le constat, et le balisage est conservé.
- **Dans les deux cas, la réponse est écrite** : relancer « Raffiner » depuis l'éditeur, ou corriger à la main.

### v0.21.31 — fonctionnel

#### La chaîne d'extraction est refaite : deux passes, et la fidélité est vérifiée

**Le défaut.** Le prompt de scan demandait deux travaux incompatibles dans un seul appel — transcrire fidèlement *et* restructurer en CookLang — et perdait le premier au profit du second. Une règle faisait tout le dégât : « la liste d'ingrédients ne se transcrit jamais, chaque ingrédient apparaît une seule fois, à sa première mention dans les étapes ». Elle oblige le modèle à **décider** où placer chaque ingrédient, donc à fusionner des phrases, à en déplacer, à en abréger. Et rien ne vérifiait le résultat : cent cinquante lignes de prompt demandaient la fidélité, aucune ligne de code ne la constatait.

**Passe 1 — transcription.** Un appel rend le type de la page *et* son contenu recopié, en JSON : sections d'ingrédients (une ligne du livre = une ligne), sections d'étapes (phrase par phrase), notes typées (astuce, conseil du chef, variante, conservation). Aucune balise, aucune décision de placement. Elle remplace à elle seule `classify_page`, `scan_extraction` et `document_extraction`.

**Passe 2 — balisage et normalisation.** Elle ne voit jamais l'image : elle travaille sur ce que la passe 1 a recopié. Elle rend le CookLang balisé, la liste normalisée, et les tags — ces derniers coûtaient un appel à eux seuls.

**Le contrôle de fidélité, sans un appel de plus.** Autant d'ingrédients que de lignes dans le livre ? autant d'étapes qu'à la transcription ? titres de section entiers ? Une **rupture** — ingrédients fusionnés, étapes disparues — écarte le balisage et retombe sur le texte verbatim : mieux vaut une recette exacte et non balisée qu'une recette balisée et fausse. Un **avertissement** — un titre raccourci, un ingrédient de trop — se journalise et laisse passer. L'écart est écrit sur la recette elle-même, pas seulement dans les journaux d'un import déjà oublié.

**La note explicative d'un ingrédient.** « 1 filet de saumon de 1,8 kg avec la peau mais écaillée » devient un ingrédient de 1,8 kg **et** une note « avec la peau mais écaillée ». La quantité se compte, la précision se lit. Elle ne vivait nulle part : aucune accolade ne pouvait la porter, et le modèle réécrivait la phrase du livre pour la caser. Elle survit au redimensionnement et à l'édition des quantités.

**Une seule écriture de la recette.** La normalisation contre les référentiels a lieu **avant** l'écriture, sur un identifiant réservé. Le déclencheur d'écriture ne part donc qu'une fois, et le texte de la recette n'est plus jamais retouché après la passe 2.

**Cinq passes d'IA disparaissent**, toutes devenues sans objet :

| Passe | Pourquoi elle disparaît |
|---|---|
| `classify_page` | champ de la passe 1 |
| `suggest_tags` | champ de la passe 2 |
| singularisation des unités | la passe 2 écrit l'unité au singulier |
| complétion des quantités | la passe 2 lit la liste du livre, où la quantité est écrite |
| détection de doublons | elle rattrapait les doublons créés par le balisage inline ; une entrée par ligne de livre, il n'y a plus rien à dédoublonner |
| consolidation des courses | regrouper est devenu une addition — et une addition ne se demande pas à un modèle |

**Le décompte**, pour une page à quinze ingrédients neufs : de **14–23 appels** à **4–8**, et **3** sur un référentiel mûr (transcription, balisage, illustrations).

### v0.21.30 — fonctionnel

#### Un import, un titre — et le calcul ne se fait plus deux fois

- **« Mise en file du traitement » nommait le couloir, pas le voyage.** Le fil s'appelait `disp`, du nom du déclencheur qui l'ouvre — mais il est **transmis** au processeur, qui journalise dessous l'extraction, la normalisation et l'enregistrement. La partie « importation » n'était donc pas absente : elle était rangée sous un titre qui ne la nommait pas. Le fil s'appelle désormais **Import d'une recette**, du début à la fin.
- **Ce déclencheur part à chaque écriture du job** — `queued`, `processing`, `done` — et n'a presque jamais rien à faire. Chacun de ces constats ouvrait son propre fil : trois groupes d'un message pour un import mis en file une seule fois. Ils se rattachent maintenant au fil que le job porte déjà.
- **La recette n'est plus calculée deux fois.** L'import écrit la recette dès l'extraction — pour que le brouillon soit consultable tout de suite — puis normalise et réécrit la liste d'ingrédients. Le déclencheur d'écriture partait donc **deux fois** : une première sur les ingrédients bruts (courses consolidées, nutrition calculée, doublons détectés par IA), une seconde sur les ingrédients normalisés, qui jetait tout le travail de la première. D'où les `refreshShoppingProducts` et `detectDuplicateIngredientsWithAI` en double.
- **Un drapeau `nutrition_hold`** posé à la création demande au déclencheur d'attendre la liste définitive. Il est retiré dans tous les cas, succès **comme échec** de la normalisation : c'est ce retrait qui déclenche le calcul, une fois. Sans cette précaution, une normalisation ratée aurait laissé la recette sans nutrition à jamais, en silence.
- **« Après écriture d'une recette » dit maintenant laquelle** : `— Ingredients modifies`, `— Premier calcul`, `— Sans changement`. On voit d'un coup d'œil quel réveil a travaillé et lequel n'a fait que constater.
- **La détection de doublons montre ce qu'elle lit.** Elle ne journalisait qu'un verdict — « 2 reprises sur 14 lignes » — sans dire sur quoi, et sous un fil à elle. Elle rejoint le fil du traitement et trace la liste soumise. Précision utile : cette passe ne voit pas la recette, elle ne voit que la **liste** ; c'est donc la liste qui est tracée, et non le texte, qui laisserait croire qu'elle en dispose.
- **Les journaux se paginent.** L'écran n'affichait qu'une page et rien ne le disait : au-delà, les entrées manquaient en silence, et un import bavard semblait s'arrêter en chemin. Un pied de liste annonce désormais le nombre d'entrées lues, dit si la suite existe, et la charge sur demande.

### v0.21.29 — fonctionnel

#### Les journaux disent enfin quel travail ils racontent

- **Un groupe titré « generate » ou « call » ne nomme rien.** L'écran regroupait correctement — toutes les entrées d'un même traitement ensemble — mais titrait le groupe avec le nom que le code s'était donné.
- **« call » était pire qu'obscur : c'était le nom par défaut.** Toute fonction appelable qui n'en choisissait pas un s'appelait ainsi. Quatre ou cinq groupes « call » n'étaient donc pas quatre exécutions d'un même travail, mais **quatre travaux différents et anonymes** — lecture de la grille tarifaire, calcul nutritionnel, consultation des journaux, normalisation. Dix-sept fonctions nomment désormais leur traitement, et un test échoue si l'une d'elles l'oublie.
- **Chaque nom technique est traduit en français à l'affichage** : « Génération d'une recette par l'IA », « Mise en file du traitement », « Poids des unités inconnues ». La traduction vit côté écran, pas côté serveur : l'identifiant doit rester stable et filtrable — c'est lui qu'on colle pour isoler un traitement — un libellé peut changer sans rien casser. Une racine inconnue est rendue telle quelle : un nom technique reste cherchable, « traitement inconnu » ne l'est pas.
- **Pourquoi trois ou quatre « generate ».** Ce n'est pas une boucle : l'écran Explorer lance **trois** générations indépendantes — Fidèle, Rapide, Créative — puis en relance une quand deux propositions se ressemblent trop. Trois ou quatre appels, donc trois ou quatre fils, donc autant de groupes. Ils portent maintenant leur variante : « Génération d'une recette par l'IA — Creative ».
- **Un traitement peut désormais se qualifier** par une précision après un deux-points (`generation_recette:creative`), que l'écran affiche après le libellé. C'est ce qui rend lisibles plusieurs départs simultanés d'un même travail.
- **Deux fils qui se perdaient sont rebranchés** : la normalisation demandée à la *sauvegarde* d'une recette et le calcul nutritionnel à la demande jetaient le fil reçu et en fabriquaient un par passe interne.
- **Nouveau diagramme de séquence** — `documentation/diagrammes-de-sequence.html`, section 11 : naissance d'un fil, propagation, regroupement et nommage à l'écran.

## 2026-08-19

### v0.21.28 — fonctionnel

#### Le double enrichissement est supprimé

- **Deux chemins posaient au modèle exactement la même question, au même instant.** `enrichUnknownUnitsWithAI` — le poids d'une unité inconnue — et `enrichUnknownIngredientsWithAI` — les valeurs pour 100 g d'un ingrédient — vivaient à la fois dans la normalisation et dans le déclencheur `onRecipeWritten`.
- **La justification écrite tenait sur le papier, pas à l'horloge.** Ces fonctions ne traitent que ce qui n'a pas encore de valeur, donc le second passage était censé ne rien trouver à faire. Sauf qu'à l'import il n'y a pas de « second » : l'écriture de la recette réveille le déclencheur, la normalisation part en parallèle, et les deux lisent le référentiel au même moment, également vide. Chaque unité et chaque ingrédient inconnu étaient payés deux fois.
- **Le déclencheur les garde, seul.** Il part sur *toutes* les écritures de recette — import, saisie manuelle, modification — là où la normalisation n'est qu'un chemin parmi d'autres ; et c'est lui qui a besoin de ces valeurs, quelques lignes plus bas, pour convertir les quantités et calculer la nutrition. Enrichir ailleurs, c'est enrichir trop tôt ou deux fois.
- **La nutrition reste juste dès le premier affichage**, puisque enrichissement et calcul se suivent dans la même exécution.
- **Ce que la normalisation continue de faire** : résoudre unités et identités, estimer le poids d'une pièce, celui d'un couple ingrédient/unité, repérer les ingrédients qui ne finissent pas dans l'assiette, compléter les quantités manquantes. Quatre passes au lieu de six, aucune en double.
- **Effet visible dans les journaux** : la même passe n'apparaît plus deux fois sous un même import. Ce qui reste en double y est délibéré et documenté — la relance insistante sur une unité revenue sans poids.

### v0.21.27 — fonctionnel

#### Un import produisait huit journaux sans lien entre eux

- **Chaque passe d'enrichissement fabriquait son propre identifiant de traitement** — « enrich-units-… », « enrich-ing-… », « piece-weights-… », « complete-qty-… » et quatre autres. Un seul scan produisait donc huit groupes de journaux, sans lien entre eux ni avec le job qui les avait déclenchés. Suivre un import de bout en bout était impossible, ce qui donnait à juste titre l'impression d'un traitement hors de contrôle.
- **Le fil reçu prime désormais sur celui qu'on fabrique.** L'import passe le sien à la normalisation, qui le passe aux enrichissements ; le déclencheur passe le sien de la même façon. Un identifiant, un scan.
- **Le déclencheur trace enfin le texte de la recette à son entrée.** Ses journaux ne portaient que des compteurs — treize ingrédients, douze références mises à jour — et pas une ligne de recette : impossible de dire si le texte arrivait déjà abîmé ou s'il l'était plus loin. Ce traitement ne touchant pas au texte, ce qu'on lit à son seuil est exactement ce que l'étape précédente a produit.
- **Et le plafond d'appels expliquait le reste.** Les répétitions observées ne sont pas une boucle : ce sont deux chemins qui font le même travail — la normalisation pendant l'import, puis le déclencheur à l'écriture — et une relance délibérée quand une unité revient sans poids. Elles se lisent maintenant sous le même fil, et se comptent.

### v0.21.25 — fonctionnel

#### On voit enfin ce que le modèle répond

- **Les journaux disaient qu'un appel avait eu lieu, jamais ce qu'il avait produit.** Poste, moteur, jetons, durée — tout, sauf le texte. Quand une recette s'écarte du livre, ces journaux-là prouvent que l'appel a réussi ; ils ne disent pas quelle étape a interprété.
- **Chaque texte est désormais tracé à sa sortie**, sous le même identifiant de corrélation que l'import : la réponse de classification, le texte d'extraction tel quel, le texte finalement écrit en base, et l'avant / après de chaque retouche demandée à la main (polissage, raffinement). Les entrées d'un même scan se lisent dans l'ordre, et l'on voit le texte évoluer d'un traitement au suivant — ou ne pas évoluer, ce qui est souvent l'information qu'on cherche.
- **Un seul endroit décide de ce qu'on garde** : douze mille caractères, de quoi couvrir une page de livre entière ; au-delà le texte est coupé, et l'entrée le dit plutôt que de laisser croire à une réponse courte.
- **Le plafond d'IA du compte fondateur passe de cinq à dix fois le plafond commun.** Il est **par compte et par jour** : personne d'autre n'était bloqué. Mettre au point l'extraction demande de rescanner la même page des dizaines de fois, et la coupure tombait au milieu d'une session d'essais — le seul moment où l'on a besoin d'appeler beaucoup, et le seul où être coupé ne protège de rien.
- **Le diagramme de séquence de l'import** montre maintenant chaque appel de modèle, chaque trace de texte, et le fait que la normalisation n'écrit plus que la liste d'ingrédients.

### v0.21.24 — fonctionnel

#### Le texte de la recette appartient au livre, plus personne ne le réécrit

- **La normalisation des référentiels réécrivait la recette**, automatiquement, à chaque import et à chaque enregistrement. Ce n'était ni le polissage ni le raffinement — ceux-là ne partent que sur un bouton. C'était un traitement que rien n'annonçait, et qui écrasait le texte dès qu'un seul ingrédient ou une seule unité avait été renommé, c'est-à-dire presque toujours.
- **Trois façons de faire dire au livre ce qu'il n'a pas écrit** : le nom de l'auteur remplacé DANS ses phrases par le nom canonique du référentiel ; des quantités estimées par l'IA insérées là où le livre n'en donnait aucune ; un titre de section remplacé par une catégorie calculée — « Pour la sauce à l'aneth et à la moutarde » perdant la moitié de son nom.
- **Son travail est la LISTE, pas la prose.** Les noms canoniques et les quantités complétées vivent dans la liste d'ingrédients résolue, celle qui nourrit la nutrition et les courses. C'est là qu'ils servent. Le texte, lui, reste celui du livre.
- **Une centaine de lignes disparaissent avec la réécriture** — elles relisaient le référentiel une seconde fois, par ingrédient, pour produire un texte que plus personne ne doit produire.
- **Ce qu'on perd, et c'est assumé** : une quantité absente du livre reste absente du texte affiché, tout en étant présente dans la liste. Et une catégorie créée depuis l'éditeur n'est plus recopiée dans le CookLang. L'honnêteté du texte passe avant le confort de l'affichage.

### v0.21.23 — fonctionnel

#### La transcription fidèle avait pris la liste d'ingrédients pour du texte

- **Trois symptômes, une seule cause.** La règle « transcris tout, ne retire rien » de la version précédente ne disait pas sur QUOI elle portait. Le modèle s'est mis à transcrire aussi la **liste d'ingrédients** du livre — et comme une autre règle interdit de baliser deux fois le même aliment, il a cessé de les baliser dans les étapes. D'où les ingrédients en double ou en triple, le bloc incompréhensible en fin de recette, et les ingrédients absents du texte des étapes.
- **La règle porte désormais sur les ÉTAPES, explicitement.** Une page a deux parties : une liste et une méthode. La liste ne se transcrit jamais — elle sert à connaître les quantités. Les étapes se transcrivent mot pour mot, et c'est **dans elles** que chaque ingrédient est balisé, une seule fois.
- **Un ingrédient listé mais utilisé dans aucune étape** reçoit une ligne unique en fin de section — « Prévoir également … » — au lieu de laisser le modèle improviser un bloc.
- **Les titres de section étaient raccourcis parce que le prompt l'enseignait.** Son exemple de référence montrait « POUR LA SAUCE DE TREMPAGE » rendu en « == Pour la sauce == » : le modèle a appris à couper. « Pour la sauce à l'aneth et à la moutarde » devenait « sauce à la moutarde ». L'exemple est corrigé, et le nom d'une section se recopie maintenant mot pour mot — raccourcir un titre, c'est perdre l'ingrédient qui distingue cette sauce de toutes les autres.
- **Six questions de vérification** ferment le prompt au lieu de trois : les trois premières sur la fidélité des étapes, les trois nouvelles sur les ingrédients balisés, les doublons, et les titres de section entiers.

### v0.21.22 — fonctionnel

#### L'extraction transcrit le livre, elle ne le réécrit plus

- **Une étape de sept phrases en rendait deux.** Le livre fait blanchir la poitrine à l'eau, la rince, la découpe, l'égoutte, glace les oignons au beurre et au sucre jusqu'à évaporation ; l'extraction rendait « faites revenir la poitrine dans une poêle, ajoutez les oignons et le sucre ». Ce n'est pas une recette plus propre, c'est une **recette fausse** : elle ne donne pas le plat du livre.
- **La consigne de fidélité existait, mais elle demandait « aussi proche que possible »** — une formulation qui autorise la dérive, noyée sous cent cinquante lignes de règles de mise en forme que le modèle, lui, applique à la lettre. Elle devient un contrat vérifiable : phrase par phrase, étape par étape, même nombre d'étapes que le livre, aucune méthode de cuisson remplacée.
- **Le seul changement autorisé sur le texte du livre est l'ajout des balises.** Rien à retirer, rien à fusionner, rien à raccourcir.
- **Un contre-exemple, tiré du cas réel**, montre la sortie interdite à côté de la sortie attendue — le prompt en utilisait déjà pour les balises, pas pour la fidélité.
- **Trois questions avant de répondre** : autant d'étapes que le livre ? toutes les phrases de la plus longue ? chaque geste figure-t-il dans le livre ? Placées en toute fin, là où la consigne pèse le plus.

### v0.21.21 — fonctionnel

#### Un import marchait sur les pieds du suivant, et une vinaigrette volait la vedette au plat

- **Régression de la v0.21.20, corrigée.** Depuis que l'écran reste disponible pendant l'envoi, la file des pages était partagée entre l'import qui part et celui qu'on prépare : les pages ajoutées ensuite s'empilaient derrière celles déjà en vol, et le vidage de fin d'envoi — qui arrive après le contrôle de sécurité — les effaçait sans un mot. Les pages quittent maintenant la file **au départ** de leur import ; celles qui restent appartiennent au suivant, et rien ne les touche.
- **Une sous-préparation n'est plus prise pour une recette.** Une vinaigrette, une sauce, une marinade, une pâte ou une garniture qui sert le plat de la page en fait **partie** : elle reste dans le même bloc, sous une section. Le prompt définissait ce qu'est une recette — des étapes, des verbes d'action — et une vinaigrette coche ces cases. Rien ne disait qu'elle appartient au plat.
- **Et surtout : interdiction d'extraire la sauce en oubliant le plat.** C'est ce qui s'était produit — la vinaigrette enregistrée comme recette, le ceviche nulle part. Le titre du bloc est désormais celui du plat servi, jamais celui de sa sauce, et dans le doute une seule recette : deux ne se justifient que si la page présente visiblement deux plats.

### v0.21.20 — fonctionnel

#### L'envoi d'un scan ne confisque plus l'écran

- **« Analyser » faisait disparaître les boutons** le temps de l'envoi et du contrôle de sécurité, puis les rendait. Quelques secondes, mais elles interdisaient de préparer l'import suivant — alors que le vrai travail, l'extraction, se fait déjà en file sans bloquer personne.
- **L'écran revient immédiatement à sa position de départ**, et l'envoi se poursuit **sous** les boutons : une ligne par envoi, avec son nom de fichier, sa phase et sa progression. On peut enchaîner les imports sans attendre.
- **Plusieurs envois peuvent voler ensemble** : chacun a sa ligne. Un envoi en vol survit à toute remise à zéro de l'écran — l'effacer afficherait un écran au repos pendant que des octets montent encore.
- **L'annonce « mis en file » suit le job, plus le statut de l'écran.** Un import peut désormais aboutir alors que l'écran prépare déjà le suivant : c'est le job qui vient d'entrer en file qui mérite le message, pas un état d'écran qui n'a pas bougé.
- **Et le succès n'efface plus ce qu'on préparait** : les pages empilées pour l'import suivant restaient effacées sous les doigts quand le précédent aboutissait.

### v0.21.19 — fonctionnel

#### Les recettes déjà orphelines rentrent au bercail

- **Le rattachement tournait déjà, à chaque ouverture de la bibliothèque** — et sans rien dire. Un traitement automatique et muet ne se vérifie pas : on ne sait ni s'il a tourné, ni combien il a déplacé. Il est désormais lançable à la main depuis *Admin › Backfills*, et rend un compte.
- **Il lui manquait la moitié des orphelines.** Il cherchait les recettes dont le champ `book_id` est **absent** ; une recette écrite avec un champ **vide** n'est pas la même chose pour Firestore, et lui échappait — pour toujours, tout en s'affichant exactement comme les autres. Les deux formes d'absence sont maintenant cherchées.
- **L'échec cesse d'être silencieux.** La migration avalait son erreur et rendait la main comme si tout allait bien. Elle la laisse remonter à celui qui l'a demandée ; l'exécution automatique, elle, reste tolérante — ouvrir la bibliothèque ne doit pas échouer parce qu'une recette n'a pas pu être rattachée.

### v0.21.18 — fonctionnel

#### Toute recette a un livre — et les livres système ne se suppriment pas

- **Les recettes conçues par l'IA pour le planning atterrissaient sans livre**, donc en recette libre. Elles rejoignent « Mes créations Kass'Dalle », comme celles de la recherche : la bibliothèque distingue de nouveau ce que la maison a inventé de ce qu'on y a soi-même écrit, et le livre prévu pour ça cesse d'être vide à côté de ses propres recettes.
- **Une recette sans livre n'existe plus.** Le choix « Aucun livre » disparaît des formulaires : sans choix, la recette rejoint « Mes recettes libres ». La règle est posée à l'entonnoir de création, dans le repository — un défaut appliqué à un seul écran n'est pas une règle, c'est une habitude. Elle vaut donc aussi pour une copie de recette d'un proche et pour un import de scan.
- **Pour l'import, le livre est résolu côté client** et voyage avec le job. Le serveur reçoit un livre et n'a pas à savoir qu'il existe des livres système : c'est ce qui évite d'écrire une seconde fois, en TypeScript, la logique qui trouve ou crée ce livre.
- **Les livres système se renomment, jamais ne se suppriment.** Le menu masquait déjà « Supprimer », mais une règle qui ne vit que dans un menu est à un appel de distance d'être enfreinte : le refus est maintenant dans le repository **et** dans les Security Rules, la seule barrière qu'un client ne peut pas contourner. Renommer reste possible — c'est le tag interne qui identifie le livre, pas son titre.
- **L'import d'un livre entier garde son « Aucun livre »** : il en crée un, le laisser vide y a un sens.

### v0.21.17 — fonctionnel

#### Sept conceptions aveugles les unes aux autres — et quatre autres manques du planning

- **« Je veux de la variété » donnait six poulets et deux tajines.** Quand l'IA *conçoit* les plats d'un cycle, elle est appelée **une fois par créneau** — et chaque appel ne voyait que son jour. Sept fois la même question, sept fois le même réflexe : une contrainte de variété que chaque appel respectait pourtant, isolément. Chaque conception reçoit désormais la liste de ce qui est déjà prévu, et doit s'en distinguer par la protéine, le féculent **et** le style de cuisine. Le garde-fou serveur ne voyait rien non plus : il dédoublonnait par identifiant de recette, or sept recettes inventées sont sept identifiants différents.
- **Le « pourquoi ce plat, ce jour-là » survit maintenant à la validation.** Il était écrit à chaque suggestion, affiché pendant la planification, puis jeté au moment d'enregistrer — l'écran qu'on relit ensuite n'en gardait rien. Il appartient au **repas** et non à la recette : il parle de cette date, de la contrainte de ce jour et de la variété du cycle ; écrit sur la recette, il aurait menti au prochain qui la planifie.
- **Un plat cuisiné à l'avance arrive avec sa consigne de conservation.** Le conseil — comment le garder, comment le réchauffer — ne se produisait qu'à la demande, d'un bouton que rien n'invitait à presser. Il est désormais produit à la validation, pour les seuls repas qui ont un jour de préparation, et une seule fois par recette.
- **L'historique du planning se consulte enfin.** Rien n'effaçait les repas passés : c'est leur *lecture* qui s'arrêtait à quatre-vingt-dix jours, la borne du flux temps réel — sans elle, l'écran relit à chaque ouverture la totalité des repas jamais planifiés. Le calendrier remonte maintenant jusqu'à deux ans, en lisant un mois à la demande, une seule fois par mois visité.
- **Une icône pour ce que la machine a produit, une autre pour l'action de le demander.** Le petit robot marque un contenu écrit par l'IA — une raison de recherche, une valeur nutritionnelle estimée, une recette conçue, le pourquoi d'un repas. Les étoiles et la baguette restent des **verbes** : générer, suggérer, affiner. Les deux se confondaient, et l'on ne savait plus si une étoile annonçait un bouton ou un constat.

### v0.21.16 — fonctionnel

#### Une heure de repas par jour, et un libellé qui cesse d’être coupé

- **Chaque jour peut avoir son heure.** Le samedi à midi, le vendredi à 20 h : le planning ne connaissait qu'une heure unique, appliquée aux sept jours. L'heure du jour s'ouvre dans la contrainte quotidienne, à côté du temps de préparation et des parts.
- **Changer l'heure globale ramène tous les jours à elle**, et l'écran le dit avant de le faire — « remet les 2 jour(s) personnalisé(s) à cette heure ». Sans cette remise à zéro, régler l'heure par défaut n'aurait plus d'effet visible dès qu'un seul jour aurait été personnalisé, et il faudrait deviner lesquels des sept résistent.
- **Un jour qui suit le défaut ne stocke rien.** Recopier l'heure globale sur les sept jours aurait figé sept valeurs que plus rien ne ramènerait ensemble. Le résumé du jour n'affiche l'heure que si elle lui est propre, et une flèche de retour n'apparaît que là où il y a quelque chose à annuler.
- **Le planning obéit à ces heures** : un créneau prend l'heure de son jour de semaine, y compris un jour ajouté après coup ou comblé au milieu du cycle.
- **Le libellé « Temps de préparation max (min) » n'est plus coupé en deux.** Le champ bordé fait flotter son libellé au-dessus de sa bordure ; le bloc n'avait aucune marge haute, et l'en-tête du jour le tranchait net.

### v0.21.15 — fonctionnel

#### Planifier une semaine pose enfin la même question que planifier un jour

- **Le bouton global ignorait les sources.** Générer un créneau isolé demandait où chercher — mes recettes validées, mes brouillons, celles de la famille, et faut-il inventer si rien ne convient. Générer le cycle entier ne demandait rien et cherchait toujours dans les seules recettes validées. Deux comportements pour une même action, dont un que rien à l'écran n'annonçait.
- **La même feuille est désormais posée dans les deux cas**, par le même widget : c'est le même choix, il n'avait aucune raison d'avoir deux versions.
- **La question vient avant tout effacement.** *Tout regénérer* vidait l'écran d'abord ; annuler la feuille laissait donc un écran vide, sans le moindre moyen de revenir en arrière.
- **« Conception IA (si aucun résultat) » est honorée pour le cycle**, et pas seulement pour un jour : chaque créneau que rien n'a pu remplir reçoit une recette inventée, enregistrée en brouillon pour exister ailleurs que dans l'écran. Une case cochée qui ne fait rien est pire qu'une case absente.
- **Un cycle sans la moindre suggestion le dit** au lieu d'annoncer un succès devant un écran resté vide.

### v0.21.14 — fonctionnel

#### L'action principale du planning cesse de se cacher dans une baguette

- **Sur grand écran, une icône dans un coin de la barre de titre n'apprend rien.** C'était pourtant l'action principale de l'écran *Nouveau planning* : sans elle, les créneaux restent vides et il n'y a rien à valider. Elle devient un bouton nommé — *Planifier avec l'IA* — posé là où se prennent les décisions de cet écran, juste au-dessus de *Valider le planning*.
- **Le bouton annonce ce qui reste à faire** : « 3 créneaux vides ». Quand tout est rempli, il ne compte plus rien — un zéro affiché n'aiderait personne.
- **Sur mobile, la baguette reste** : la barre basse y porte déjà le bouton de validation, et un second bouton pleine largeur mangerait la liste des créneaux, qui est ce qu'on vient lire.
- **Les deux façons de générer restent distinctes**, quel que soit l'écran : compléter les créneaux vides, ou tout regénérer. La seconde efface le travail déjà fait à l'écran — ce choix ne doit pas se faire par mégarde, et il ne se fait donc pas d'un simple appui.
- **Pendant la génération, le bouton le dit** au lieu de disparaître.

### v0.21.13 — fonctionnel

#### Deux recettes sur une page ne se partagent plus une seule photo

- **Elles pointaient le même fichier.** Une page de livre qui porte deux recettes leur donnait les mêmes illustrations — non pas deux images identiques, mais **un seul objet** désigné deux fois. Rien ne casse aujourd'hui, parce que supprimer une illustration se contente d'oublier son adresse ; mais la première ligne de code qui supprimera vraiment le fichier viderait l'image de l'autre recette, sans erreur, sans coupable, et c'est l'ordre des suppressions qui déciderait laquelle perd sa photo.
- **Chaque recette au-delà de la première reçoit désormais sa copie**, faite côté serveur — aucun octet ne transite, et les métadonnées de la décision de modération suivent l'objet.
- **Un seul verdict pour toutes les copies** : c'est la même image, jugée une fois. La repasser au moteur doublerait la facture pour la même réponse.
- **Si la copie échoue, la recette garde l'adresse partagée** plutôt que de perdre sa photo, et l'échec est journalisé. Un partage est un risque futur ; une illustration manquante est une perte immédiate.

### v0.21.12 — fonctionnel

#### Les photos découpées dans un scan passent enfin devant la modération

- **Le pipeline d'import publiait sans verdict.** Il découpait les photographies d'une page de livre et les écrivait en direct dans le dossier publié, avec les droits de l'Admin SDK : ni règles Storage, ni quarantaine, ni Cloud Vision. Nous venions de fermer les quatre portes clientes ; celle-ci restait ouverte, et c'est pourtant la même chose qui y passe — une photo choisie par une personne.
- **Un seul chemin, désormais, pour les deux appelants.** Le cœur de la modération a quitté le callable pour un module que le client et le pipeline empruntent tous les deux. Un second chemin de publication serait, tôt ou tard, un chemin sans verdict.
- **Une découpe refusée n'apparaît pas dans la recette**, et une découpe laissée en attente non plus — moteur injoignable, on ne publie pas. Le journal dit combien et pourquoi.
- **Trois filtres locaux écartent ce qui n'est pas une photographie**, avant même la modération : moins de 120 pixels de côté ou moins de 1,5 % de la page, rapport de forme au-delà de 4:1, ou presque blanc **et** sans couleur — du papier, ou du texte sur du papier. Les boîtes viennent d'un modèle, pas d'un détecteur géométrique : une boîte fantaisiste produisait jusqu'ici une bande de texte, téléversée comme photo du plat et conservée pour toujours.
- **Les deux conditions du dernier filtre sont exigées ensemble**, et c'est délibéré : une photographie en noir et blanc a bien une couleur nulle, mais jamais une luminance moyenne de papier. Un filtre qui l'aurait jetée aurait coûté plus qu'il ne rapporte.
- **Toutes les pages sont examinées.** Le texte d'un scan multi-pages était lu en entier ; ses photographies, elles, ne l'étaient que sur la première page — une recette étalée sur trois pages perdait les photos des deux suivantes, sans un mot. Chaque page coûte une détection : c'est le prix de ne pas les perdre.

### v0.21.11 — fonctionnel

#### Le calendrier tenait l'écran entier, il tient maintenant dans une bande

- **Les cases faisaient deux cents pixels de côté.** La grille s'étirait sur toute la largeur disponible : sur un écran de bureau, une seule semaine occupait la moitié de la page et le détail du jour se trouvait hors champ. Une grille qu'on doit faire défiler pour voir le mois n'est plus un calendrier, c'est une liste très aérée.
- **Une bande, trois mois** : le mois courant au centre, le précédent et le suivant à ses côtés en plus petit. Un mois de contexte de chaque côté, c'est ce qu'on regarde en préparant une fin de mois ou un début de vacances.
- **La bande occupe le tiers haut de l'écran, l'agenda du jour occupe le reste.** Le calendrier est un repère, le détail est ce qu'on lit.
- **La taille d'une case se déduit des deux contraintes** — la hauteur reçue et la largeur qui reste une fois les flèches posées — jamais d'une seule. Ne regarder que la largeur donnait les cases géantes ; ne regarder que la hauteur faisait déborder le téléphone de seize pixels.
- **Sous une certaine largeur, seul le mois central reste.** Les flèches mènent toujours aux autres.
- **Choisir un jour dans un mois latéral ne fait plus sauter la bande** : le regard vient d'y aller, la recentrer le perdrait.

### v0.21.10 — fonctionnel

#### Le planning se lit aussi au mois

- **Un second onglet, *Calendrier*, à côté de la liste** — qui, elle, ne bouge pas. Une liste chronologique répond à « qu'est-ce qu'on mange bientôt » ; elle ne répond pas à « à quoi ressemble le mois », question qu'on se pose en préparant des courses ou un week-end. Deux questions, deux lectures, les mêmes repas.
- **Les jours porteurs de repas sont surlignés**, avec une pastille par repas. Trois au plus par case : au-delà, un « +2 » dit qu'il y a plus sans prétendre le montrer — une ligne de sept points dans une case de quarante pixels ne se compte pas.
- **Un appui ouvre l'agenda du jour, sous la grille**, avec les mêmes actions que dans la liste : changer la recette, vider le créneau, l'heure, l'export calendrier, le conseil de conservation. Aucune feuille modale : on choisit un jour et on lit, sans quitter l'écran.
- **Les jours de préparation comptent aussi.** Un plat cuisiné le mardi pour le jeudi marque le mardi d'une pastille creuse et se retrouve dans l'agenda de ce jour-là, sous « À préparer ce jour-là ». Une grille qui ne montrerait que les jours de service mentirait sur la charge réelle de la semaine.
- **Les pastilles ne rejouent aucune règle.** Elles se lisent entièrement dans des champs stockés — la recette est là ou non, la date de préparation est là ou non. Colorier midi et soir aurait demandé de ramener côté client les règles de créneau, que le serveur porte seul depuis qu'elles ont quitté le client.
- **Aucun document créé, aucune requête nouvelle** : la vue range par jour les repas déjà chargés. Un mois est une position de lecture, pas une donnée du planning.
- **La flèche vers le passé s'arrête où s'arrête l'historique** — quatre-vingt-dix jours, la borne du stream. Sans ce refus, un mois vide faute de chargement se lirait comme un mois sans repas.

### v0.21.9 — fonctionnel

#### Les outils d'amorçage quittent la maison

- **Trois entrées n'existaient que pour un travail déjà fait** : l'amorçage des rôles dans les jetons, l'audit des identifiants du référentiel d'ingrédients, et le versement de la table des poids à la pièce. Chacune a tourné, a rendu son compte, et n'avait plus d'appelant. Elles restaient déployées, gardées `admin`, à portée d'un clic — et un outil qui fusionne des documents du référentiel ne demande qu'à être relancé par distraction.
- **Une fonction déployée est une surface, pas un souvenir.** Ce qu'elles ont réparé est dans les données, pas dans le code : le garder revenait à conserver l'échafaudage après la façade.
- **L'écran *Admin › Backfills* ne propose plus que ce qui sert encore** — les KPIs du référentiel et l'enrichissement des unités et ingrédients, qui, eux, ont un usage régulier.
- **Une troisième opération y est entrée : *Reprendre la nutrition*.** Un passage automatique recalcule chaque nuit à 5 h les recettes dont la nutrition manque, a échoué, ou reste incomplète. Il s'impose deux garde-fous : vingt heures entre deux tentatives sur la même recette, et cinq essais au plus. Le bouton lève les deux — il sert juste après une correction de référentiel, quand on veut voir l'effet sans attendre le lendemain. Il rend un compte : combien complétées, combien encore incomplètes, combien laissées pour la prochaine passe, et s'il s'est arrêté sur le plafond de dépense.
- La documentation qui les nommait a suivi dans le même commit : une doc qui décrit une fonction disparue envoie chercher une porte qui n'existe plus.

### v0.21.8 — fonctionnel

#### Un filtre textuel sur le poste

- **Un champ de recherche au-dessus du tableau** ne garde que les postes dont le libellé contient ce qu'on tape. Insensible à la casse **et aux accents** : « generation » trouve « Génération de recette ». Personne ne tape les accents dans un filtre, et l'exiger transformerait l'aide en obstacle.
- **Le total sous le tableau n'additionne que ce qui est affiché**, et le dit : « Total filtré », avec le nombre de lignes retenues. Laisser le total de la période sous une liste filtrée afficherait une somme que les lignes au-dessus ne font pas — un chiffre faux qu'on ne remarque jamais, parce qu'il reste plausible.
- **Le chiffre en tête d'écran, lui, ne bouge pas.** C'est le coût de la période, sa référence ; un filtre de lecture ne réécrit pas ce qu'on a dépensé.
- **Sans correspondance, le champ reste affiché** avec un message qui nomme la recherche. C'est lui qu'il faut corriger : le masquer enfermerait dans le vide qu'on cherche à quitter.
- Une croix efface le filtre d'un geste.

### v0.21.7 — fonctionnel

#### Le tableau des coûts d'IA se trie par ses en-têtes

- **Chaque colonne est cliquable** : poste, appels, coût unitaire, total, pour Claude, pour Gemini et pour l'ensemble. Un second clic inverse le sens. Par défaut, le plus cher en tête — c'est la question qu'on se pose en ouvrant cet écran.
- **Une colonne vide reste en bas, dans les deux sens.** Un poste qui n'a jamais appelé Claude affiche « — », et « — » ne veut pas dire zéro : il n'a pas de coût unitaire, il n'en a aucun. Le trier comme un zéro l'aurait placé en tête d'un tri croissant, c'est-à-dire présenté comme le moins cher — exactement le contraire de la vérité.
- **Les égalités se départagent par le libellé.** Deux postes au même montant gardaient sinon un ordre arbitraire, qui changeait à chaque rafraîchissement de l'écran.
- **La ligne de total reste en bas**, quel que soit le tri : c'est une somme, pas une ligne comme les autres.
- Le tri survit au passage de « Par poste » à « Par processus » : on change d'axe de lecture, pas de question.

## 2026-08-18

### v0.20.28 — fonctionnel

#### L'écran ne s'éteint plus pendant qu'on cuisine

- **Une recette ouverte garde l'écran allumé.** On cuisine les mains occupées, farineuses ou mouillées : la fiche restait affichée sans qu'on la touche, l'écran s'éteignait au milieu d'une étape, et c'est le seul moment où on ne peut pas le rallumer.
- **Le maintien vaut pour toute la fiche**, pas seulement pour le mode cuisine : on lit aussi les ingrédients, la nutrition et les commentaires sans toucher l'appareil.
- **Il s'arrête en quittant la recette** — et pas avant. Deux recettes ouvertes l'une sur l'autre le demandent chacune ; refermer celle du dessus n'éteint pas l'écran de celle qui reste.
- **Revenir d'un appel ou d'un autre onglet le rétablit** : navigateurs et Android relâchent ce verrou dès que l'application passe en fond, sans jamais le rendre d'eux-mêmes.
- Android, iOS, web et Windows. Si la plateforme refuse — un navigateur peut le faire — la recette s'affiche normalement, l'écran s'éteint comme avant, et le refus est remonté une fois.

### v0.20.28 — technique

#### Maintien de l'écran allumé sur la fiche recette

- **`wakelock_plus: ^1.3.3`** (nouveau) — version retenue par la résolution : à partir de 1.6.1, wakelock_plus réclame `package_info_plus ^10.1.0` quand le projet est en `^8.0.0`. Monter l'un impose de monter l'autre — un autre chantier. Couvre Android, iOS, web et Windows ; aucune permission Android (le plugin pose `FLAG_KEEP_SCREEN_ON` sur la fenêtre, pas un `WakeLock` système).
- **`core/services/screen_wakelock.dart`** (nouveau) : `ScreenWakelock` avec `acquire()` / `release()` / `refresh()` et une instance partagée `ScreenWakelock.instance`. Le maintien est **compté**, pas booléen : deux écrans superposés le demandent chacun, et le verrou ne tombe qu'au dernier `release()`. Une libération de trop ne descend pas sous zéro — sinon la prochaine prise n'appliquerait rien.
- **`refresh()` existe parce que le verrou est révocable** : navigateurs et Android le relâchent au passage en arrière-plan sans le rendre. Sans reprise au `resume`, un appel téléphonique suffisait à éteindre l'écran pour le reste de la lecture.
- **`WakelockToggle` injectable** — `Future<void> Function({required bool enable})`, par défaut `WakelockPlus.toggle` : le comptage se vérifie sans plugin ni binding.
- **`mixin KeepScreenAwake<T extends StatefulWidget> on State<T>`** : `acquire()` en `initState`, `release()` en `dispose`, `AppLifecycleListener(onResume:)` pour la reprise. Mixé sur `_RecipeDetailScreenState` (`recipe_detail_screen.dart`), après `SingleTickerProviderStateMixin`.
- **Le maintien couvre toute la fiche, pas le seul `_mobileKitchenMode`** : les ingrédients, la nutrition et les commentaires se lisent aussi les mains occupées.
- **L'échec de plateforme est remonté une fois par session** (`reportUnexpectedError`, poste `screenWakelock.apply`, contexte `enable` + `holders`). Un refus vient de la plateforme — API absente, onglet en fond, navigateur qui refuse — et se reproduirait à chaque ouverture de recette : cent rapports identiques n'apprennent rien de plus que le premier et noient les autres. Ce n'est pas un `catch` silencieux, c'est un `catch` qui ne se répète pas.
- **Le client desktop Windows n'est pas concerné par la limite App Check** : le maintien ne passe par aucun appel serveur.
- **Tests** : `test/screen_wakelock_test.dart` — première prise seule appliquée, verrou conservé tant qu'un détenteur reste, libération excédentaire ignorée, reprise après arrière-plan, `refresh()` sans détenteur sans effet.

### v0.20.27 — fonctionnel

#### L'envoi vers Tasks ouvre les tâches

- **Un onglet s'ouvre sur vos tâches** dès que la liste est partie — c'est là qu'on va ensuite. Sur mobile, l'application Google Tasks capte le lien si elle est installée.
- **Le bandeau garde un bouton « Ouvrir »**, parce qu'un navigateur peut refuser une ouverture qui ne suit pas immédiatement un geste : après une trentaine d'appels réseau, le lien n'est plus considéré comme déclenché par vous. Ce bouton-là, lui, l'est.
- Il n'existe pas d'adresse stable vers une liste précise — l'identifiant rendu par l'API n'est pas celui de l'interface. On ouvre donc les tâches, où la liste du jour figure en tête du sélecteur.

### v0.20.26 — fonctionnel

#### La liste de courses part dans Google Tasks, cochable et rangée

- **Keep n'a pas d'API d'écriture.** L'envoi passait donc par le presse-papier : à vous de créer la note, de la convertir en cases à cocher, et de refaire les rayons — que Keep aplatit en une ligne par article, en-têtes compris. Ce n'était pas un défaut de l'application, c'était la seule chose que Keep permet.
- **Google Tasks, lui, reçoit exactement ce qu'on veut lui donner** : un **rayon par tâche**, un **article par sous-tâche**, tout cochable. Une liste prête, sans une manipulation.
- **L'ordre des rayons est conservé** — celui de la liste, donc celui du magasin. Sans précaution, l'API place chaque insertion en tête et rend la liste à l'envers.
- **Seuls les articles non cochés partent** : ce qui est déjà dans le panier n'a rien à faire sur une liste de courses.
- **Le bouton Keep reste**, en second, pour qui vit dans Keep — et il dit maintenant franchement ce qu'il faudra faire à la main.
- L'autorisation suit la même mécanique que l'export vers Google Agenda : un consentement au premier envoi, puis un jeton gardé le temps de la session.

#### La correction orthographique par IA est retirée

- **Elle ne tenait pas ses promesses**, et une fonction qui échoue à chaque essai vaut moins que pas de fonction. Retirée entièrement : module, prompt, entrée HTTPS, bouton, et la fonction déployée elle-même — aucun code mort, ni dans le dépôt, ni dans le projet Firebase.
- **Le poste reste au catalogue des coûts**, marqué « retiré ». C'est la règle du projet : des appels ont été comptabilisés sous cette clé, et un mois déjà chiffré ne doit pas perdre le nom de ce qu'il a payé.
- Le défaut de lecture qui l'avait motivée — « les carotte » sur une fiche imprimée — est réglé autrement, par les badges du PDF.

### v0.20.25 — fonctionnel

#### Le PDF porte les mêmes badges que l'écran

- **Le PDF imprimait le CookLang débarrassé de sa syntaxe.** « Émincer finement le poivron, les carotte » : rien ne disait au lecteur que « carotte » n'était pas un mot de la phrase, mais une **référence structurée** reprise de la liste d'ingrédients. Deux gênes d'un coup — une faute d'accord apparente, et une syntaxe devenue invisible.
- **Les jetons sont désormais des badges**, comme les puces de l'application : ingrédients sur fond d'accent clair, matériel et minuteurs sur fond gris. « les ⟦2 carottes⟧ » se lit sans heurt, parce qu'un badge s'annonce comme une donnée et non comme un mot accordé.
- **Le badge porte la même chose que la puce** : la quantité accordée pour un ingrédient, le nom pour un ustensile, la durée en clair pour un minuteur — « 12 minutes », plus « 0:12:00 ».
- **Les notes aussi**, dans leur ton propre.

#### Et la correction de prose lit enfin la réponse du moteur

- **« Réponse pas exploitable » à chaque essai.** La passe appelait `JSON.parse` sur la réponse brute : un simple bloc de code Markdown suffisait à tout faire échouer. Elle passe désormais par `askJson`, le seul endroit du projet qui sait lire une réponse de modèle — enrobage, phrase d'introduction, virgule finale.
- **Les fragments sont numérotés dans la réponse**, et non plus attendus dans l'ordre : un modèle qui fusionnait deux fragments minuscules faisait abandonner toute la passe. Un fragment manquant ne coûte plus que lui-même.
- **Un abandon laisse une trace** dans les journaux, avec sa cause. Sans elle, « pas exploitable » restait un message d'écran sans explication.

C'est la réponse la moins coûteuse au problème d'accord : là où l'écran ne posait de question à personne, le papier en posait une — parce qu'il avait perdu la distinction entre le texte et les données. Le badge la lui rend.

### v0.20.24 — fonctionnel

#### Une correction orthographique qui ne peut pas casser une recette

Le rendu ne corrigera jamais une faute écrite **dans** le texte — « Chauffer l'poêle » est dans la recette, pas dans son affichage. D'où cette passe, et d'où sa forme.

- **Un nouveau bouton dans l'éditeur** (icône correcteur, à côté du bouton IA) : *Corriger l'orthographe du texte des étapes*.
- **Le modèle ne voit jamais la recette.** Il reçoit une liste numérotée de **fragments de texte** extraits d'entre les balises, et rend la même liste corrigée. Le réassemblage est mécanique : chaque `@ingrédient{}`, `#matériel{}`, `~minuteur{}`, chaque métadonnée `>>`, chaque en-tête de section et chaque image ressort **identique, octet pour octet**. La sûreté ne vient pas d'une consigne de prudence donnée au modèle, mais du fait qu'on ne lui met aucun balisage entre les mains.
- **Trois garde-fous, tous vérifiables.** Une liste d'une autre longueur est rejetée en bloc. Un fragment qui revient avec `@`, `#`, `~`, `{` ou `}` alors qu'il n'en avait pas est ignoré — le modèle a inventé une balise. Un fragment qui double ou disparaît est ignoré : une correction orthographique ne réécrit pas une phrase. Un fragment refusé garde sa version d'origine.
- **Rien n'est appliqué sans que vous l'ayez vu.** Une fenêtre montre les lignes concernées, avant et après, et vous appliquez ou non. Une correction automatique qu'on découvre à l'impression n'est plus une correction, c'est une surprise.
- **Une passe qui ne change rien le dit**, et une passe abandonnée aussi — plutôt qu'un succès silencieux qui laisserait croire la recette relue.

**Pourquoi ne pas avoir réutilisé la relecture existante** : `polishCooklang` réécrit le document entier, noms d'ingrédients compris. C'est utile sur un brouillon brut, et destructeur ensuite — le nom d'un ingrédient est son identité, celle dont dépendent la nutrition, la liste de courses, la recherche et les catégories. Et la correction ne tiendrait pas : la normalisation référentielle réécrit chaque balise depuis le référentiel au prochain enregistrement.

Le poste **Orthographe de la prose** apparaît dans les coûts et bascule entre Gemini et Claude depuis *Admin › Moteur d'IA*, comme tous les autres.

### v0.20.23 — fonctionnel

#### C'est l'article qui donne le nombre, et les minuteurs se lisent

- **« les carotte » survivait à la correction précédente.** Celle-ci accordait le nom d'après la quantité du jeton — or dans la prose, un ingrédient s'écrit le plus souvent **sans quantité** : `les @carotte{}`, la quantité vivant dans la liste. Sans quantité, pas d'accord. C'est désormais **l'article qui précède** qui commande : « les » met au pluriel, « le », « la », « l' » gardent le singulier, et un numéral compte comme un pluriel. C'est le signal que lit un humain — il tient dans les deux mots d'avant, et il est toujours là.
- **L'article l'emporte sur la quantité.** Une recette peut annoncer deux poivrons dans sa liste et n'en mettre qu'un dans une étape : c'est la phrase qui a raison.
- **Les minuteurs se lisent enfin dans le PDF** : « Cuire 12 minutes » au lieu de « Cuire 0:12:00 ». La valeur brute du jeton y était imprimée telle quelle, alors que l'application la met en forme depuis toujours. Le formatage a quitté la couche présentation pour que les deux s'en servent.

**Ce que le rendu ne corrigera jamais** : une faute d'écriture dans la prose libre. « Chauffer l'poêle » est dans le texte de la recette, pas dans son affichage — et choisir entre « le » et « la » demande un genre que l'application ne connaît pas. Cela se corrige à la main dans l'éditeur, ou par une passe d'IA limitée aux segments de texte **entre** les jetons.

### v0.20.22 — fonctionnel

#### Les ingrédients s'accordent enfin

Une fiche imprimée disait « 3 Cuillère à soupe sauce soja », « 1 pièces poivron », « 2 gousse ail », et dans une étape « Émincer finement le poivron, les carotte ». Aucune de ces lignes n'était une faute de l'IA : c'étaient des **identifiants affichés comme du texte**.

- **`Cuillère à soupe` est un libellé de référentiel**, écrit pour un tableau d'administration — majuscule et singulier. Dans une phrase, il se lit désormais « 3 cuillères à soupe **de** sauce soja ».
- **`carotte` est le nom canonique de l'ingrédient**, celui qui sert à l'appariement nutritionnel, à la liste de courses et à la recherche. Il s'accorde maintenant à l'affichage — « les carottes » — sans que rien ne change en base.
- **L'unité qui compte disparaît** : on écrit « 2 carottes », jamais « 2 pièces carotte ». C'est le nom qui porte le nombre.
- **La liaison est faite** : « 2 gousses **d'**ail », « 500 g **d'**émincé de bœuf », mais « 200 g **de** haricots verts » — le h aspiré ne s'élide pas.
- **Un symbole reste un symbole** : « 500 g », jamais « 500 gs ».
- **Le singulier tient jusqu'à deux**, comme en français : « 1,5 litre ». Une quantité illisible — « quelques » — laisse le singulier plutôt que de deviner.

**Rien n'est réécrit dans la recette.** Corriger le CookLang aurait cassé l'identité dont dépendent quatre chaînes — nutrition, courses, index de recherche, catégories — et aurait de toute façon été effacé au prochain enregistrement, puisque la normalisation référentielle réécrit chaque `@nom{}` à partir du référentiel. C'est **le rendu** qui a été corrigé : la fiche, les étapes, la liste de courses et l'export PDF partagent la même règle, et **toutes les recettes déjà en base sont corrigées d'un coup**, réimpression comprise.

Règles d'affichage, donc **client uniquement** : le serveur n'affiche rien, et en écrire un jumeau TypeScript n'ajouterait qu'une divergence possible.

### v0.20.21 — fonctionnel

#### La dépense par utilisateur a son écran, et le plafond passe en euros

- **Un écran à part**, *Admin › Dépense par utilisateur*, au lieu d'une carte posée en haut des coûts mensuels. Les deux questions ne se posent pas au même moment : les coûts mensuels disent **combien l'application coûte**, celui-ci dit **qui dépense, à quoi, et jusqu'où il peut aller**. La seconde a besoin de place — une ligne par compte, un détail par poste.
- **Le détail par service, compte par compte.** Chaque personne se déplie sur la liste de ses postes — scan, nutrition, dressage, planning — du plus cher au moins cher. Cette ventilation n'existait nulle part : l'agrégat mensuel savait dire le total d'un compte et le total d'un poste, jamais lequel des deux enfants fait tourner le générateur d'images.
- **Le même sélecteur de période que les deux autres onglets** — ce mois, 3, 6, 12 mois, depuis le début — et le même réglage : une période choisie ici se retrouve là-bas.
- **Les mois antérieurs n'ont pas ce détail** et l'écran le dit, plutôt que d'afficher un vide qui se lirait « rien dépensé ». Une reconstruction des agrégats les rattrape.
- **Le plafond se règle désormais en euros**, la monnaie du foyer, et non plus en dollars. Les fournisseurs facturant en dollars, la comparaison passe par le taux relevé sur la facture. **Sans taux, le plafond en euros ne s'applique pas** : le projet refuse d'inventer un taux, et c'est le plafond en nombre d'appels qui protège seul — l'écran l'annonce en clair, et le journal aussi.
- **Le compte fondateur dispose de cinq fois le plafond.** Règle écrite dans le code et non en base : elle dit que le propriétaire du projet est aussi celui qui l'éprouve — c'est lui qui importe des livres entiers et régénère des séries de visuels. La poser en base en ferait un privilège transmissible par n'importe quel administrateur. Le multiplicateur porte sur **les deux** plafonds, sans quoi le compteur d'appels bloquerait précisément celui qui a le droit d'en faire cinq fois plus. Et il reste un plafond : cinq fois plus haut, pas illimité.
- **L'identité du fondateur est lue dans Auth**, jamais dans le champ `email` du document utilisateur — qu'un administrateur peut écrire. Un privilège ne se fonde pas sur une donnée qu'un tiers peut poser.
- **L'alerte mensuelle est en euros** elle aussi, et se tait en le disant quand aucun taux ne permet de la calculer : un silence se lirait « rien à signaler ».

## 2026-08-17

### v0.20.20 — fonctionnel

#### La dépense d'IA a enfin un plafond

- **Le projet mesurait au centime sans jamais limiter.** Le contrôle d'accès dit *qui* appelle, l'attestation dit *quel programme* appelle ; aucun des deux ne dit **combien de fois**. Restaient entiers : un jeton égaré sur l'appareil d'un membre de la famille, un membre qui s'amuse, et surtout une boucle dans notre propre code — celle-là, aucune attestation ne l'arrêtera jamais.
- **Deux plafonds par compte et par jour**, et non un seul. Le plafond en dollars est le naturel ; mais quand la grille tarifaire est illisible, le projet refuse de chiffrer et les appels sont enregistrés **sans montant**. Un plafond uniquement monétaire s'ouvrirait donc en grand exactement pendant la panne où plus rien n'est chiffré. Le second plafond compte les **appels**, et ne dépend d'aucun prix. Le premier des deux atteint ferme la porte.
- **Le refus arrive avant la dépense**, aux deux seuls endroits d'où l'argent part : le routeur de texte — donc aussi tout ce que déclenche le pipeline d'import, que les gardes HTTPS ne voient pas — et la production d'image. Le message dit ce qui est atteint et quand cela se rouvre, sans jargon.
- **Un plafond atteint ne touche que ce compte.** Les autres continuent de cuisiner.
- **Un import coupé par le plafond ne se réessaie pas** : il part directement en dead letter, avec le motif, d'où un administrateur le relance demain — ou après avoir relevé la limite. Réessayer trois fois refait tout le travail qui précède l'appel d'IA pour se heurter au même mur.
- **Les réglages vivent dans Firestore**, pas dans le code : *Admin › Coûts* affiche ce que chaque compte a consommé aujourd'hui, la part de plafond déjà mangée, et permet de relever la limite en une minute — le jour où un import massif se fait couper au milieu, il ne faut pas attendre un déploiement. Un interrupteur coupe les deux plafonds sans les effacer.
- **Les défauts protègent avant tout réglage** : deux dollars et quatre cents appels par compte et par jour. Une soixantaine de visuels de dressage, des milliers d'appels de texte — personne ne les atteindra en cuisinant, une boucle les atteint en quelques secondes. C'est un défaut assumé : un plafond est une *décision*, pas une mesure, et l'absence de document ne doit pas vouloir dire « aucune limite ».
- **Une alerte mensuelle**, vérifiée chaque matin plutôt que le mois suivant : une alerte qui arrive après la facture n'est pas une alerte. Elle se déclenche une fois par mois au franchissement du seuil, et signale au passage combien d'appels sont restés sans montant — un mois traversé par une panne de grille paraîtrait sinon simplement économe.

### v0.20.19 — fonctionnel

#### L'interrupteur d'arrêt ne dépend plus de ce qu'il coupe

- **L'écran d'attestation passait lui-même par le contrôle d'attestation.** En mode *Exigé*, un client non attesté — le téléphone, le desktop — ne pouvait donc plus ni lire le mode ni le changer : il affichait « Politique illisible ». Tant qu'un autre client atteste, il reste une issue ; le jour où l'attestation refuse à tort — reCAPTCHA en panne, clé expirée —, *Exigé* devenait définitif pour tout le monde. La clé était enfermée dans la pièce.
- **Les deux postes qui lisent et écrivent le mode sont désormais exemptés**, en toutes circonstances. Ils exigent toujours le rôle administrateur, ne coûtent rien, et n'exposent qu'un mot parmi trois. L'appel reste journalisé : savoir qu'un client non attesté vient changer le mode a de la valeur.
- **Passer en *Exigé* reste impossible depuis un client non attesté.** L'exemption ouvre la marche arrière, pas la marche avant.

### v0.20.18 — fonctionnel

#### Trois portes de dépense refermées

- **Générer une illustration redevient un geste d'éditeur.** Le poste coûte 0,0336 $ l'image et se contentait d'un compte connecté, alors que le visuel de dressage exigeait déjà le rôle éditeur et que l'amélioration de photo est réservée aux administrateurs. Un lecteur pouvait donc dépenser en boucle ce que la même famille de postes lui refusait à côté. Le bouton disparaît aussi de l'onglet Illustrations pour qui n'est pas éditeur : proposer une action que le serveur refusera ne donne qu'un message d'erreur sans explication.
- **Chaque entrée HTTPS est plafonnée à dix instances simultanées.** Sans plafond, une boucle — la nôtre autant qu'une malveillante — ouvrait autant d'instances que le projet l'autorise, cent par défaut, chacune servant quatre-vingts requêtes qui partent toutes chez Gemini ou Anthropic. Dix tiennent largement une famille. Ce plafond borne le *parallélisme*, pas le total dépensé : le plafond par compte reste à écrire.
- **La quarantaine n'accepte plus que ce qu'un import produit** — photo, PDF, document Word, texte collé. Elle prenait n'importe quel fichier jusqu'à cinquante mégaoctets : le bucket servait d'hébergement gratuit à qui possédait un compte, et rien dans le suivi de stockage n'aurait distingué ces octets-là des recettes de la famille. Le fichier reste inspecté par le serveur avant d'être promu ; ce contrôle-ci évite seulement que le dépôt serve à autre chose.

### v0.20.17 — fonctionnel

#### La clé était dans le code, pas dans le déploiement

- **Le bundle web publié en v0.20.16 ne contenait pas la clé reCAPTCHA.** Le compilateur web incrémental n'avait pas repris la modification : `flutter build web` a rendu un `main.dart.js` antérieur à l'édition, sans le signaler, et le déploiement l'a publié. Le client ne pouvait donc produire aucun jeton — le serveur voyait `app: MISSING`, et l'écran d'attestation restait rouge sans raison apparente.
- **Le symptôme s'était pourtant laissé lire dans le binaire** : la constante de clé était absente du bundle, ainsi que toute trace du fournisseur reCAPTCHA. Une constante qui disparaît d'un build alors que le code qui l'entoure y figure signale que personne ne la lit — ici, que l'attestation n'était pas compilée du tout.
- **Le déploiement était sain, le build ne l'était pas.** `flutter clean` échouait lui-même sur un dossier verrouillé (`windows/flutter/ephemeral`) et laissait le cache de build intact : la reconstruction « réussissait » en 1,7 seconde sans rien recompiler. Il a fallu supprimer `build/web` et `.dart_tool/flutter_build` à la main.
- **Vérification retenue** : après un build, la présence de la clé dans `build/web/main.dart.js` se contrôle en une commande. Un bundle qui compile n'est pas un bundle à jour.

### v0.20.16 — fonctionnel

#### Le client web atteste pour de bon

- **La clé reCAPTCHA est posée.** Le mécanisme d'attestation était complet depuis la version précédente, mais inerte sur le web faute de clé de site : tous les appels partaient non attestés. Le client web produit désormais un jeton d'attestation à chaque appel.
- **La clé vit dans le code, et c'est correct.** Une clé de *site* s'affiche dans la page, comme celle de n'importe quel formulaire protégé par reCAPTCHA — la mettre en secret n'aurait rien caché, et aurait ajouté un `--dart-define` au déploiement pour une donnée que le navigateur reçoit de toute façon. La clé *secrète*, elle, n'existe pas dans ce mode : reCAPTCHA Enterprise n'en délivre pas.
- **Rien n'est encore exigé.** Le mode reste *Observation* : les journaux vont maintenant dire lesquels des clients attestent — web, Android, desktop — avant toute décision de refuser.

### v0.20.15 — fonctionnel

#### L'application s'atteste — App Check

- **Le contrôle d'accès savait qui appelle, pas quoi appelle.** Une Cloud Function callable est une URL HTTPS publique et devinable ; la seule chose qu'elle exigeait était un jeton d'identité, lequel s'obtient avec la clé web — publique par conception — ou se recopie depuis le navigateur d'un membre de la famille. L'application et une boucle dans un terminal étaient indiscernables côté serveur, et chaque appel part chez Gemini ou Anthropic. La liste d'origines CORS ne protège de rien ici : c'est une règle que les navigateurs s'imposent, et un script n'en a pas.
- **Le client atteste désormais son authenticité** : reCAPTCHA Enterprise sur le web, Play Integrity sur Android, DeviceCheck sur iOS. Le jeton d'attestation accompagne chaque appel, et les trois gardes des Cloud Functions le vérifient — donc les vingt-sept entrées d'un coup, administration comprise.
- **Trois modes, pilotés depuis *Admin › Attestation de l'application*, pas par un déploiement.** *Désactivé* ne vérifie rien ; *Observation* — le défaut — ne refuse rien mais journalise chaque appel non attesté, avec le poste et l'agent utilisateur ; *Exigé* refuse. Le silence des traces d'observation est la condition pour exiger : ce sont elles qui disent ce qu'on couperait. Une bascule prend effet en moins d'une minute, dans les deux sens — le jour où l'attestation refuse à tort, il faut rouvrir tout de suite, et un interrupteur qui demande un déploiement n'est pas un interrupteur.
- **L'écran refuse de vous verrouiller dehors.** Il affiche si l'appel qui l'a chargé était lui-même attesté, et le serveur rejette le passage en *Exigé* demandé depuis un client non attesté. C'est la leçon de la clé Anthropic : une bascule sans effet reste une énigme pour celui qui l'a demandée.
- **Le client Windows desktop n'atteste pas**, et le dit franchement : sa seule voie serait un jeton de débogage, c'est-à-dire un secret partagé dans un binaire distribué. Passer en *Exigé* le prive donc de l'IA. Cette limite ne se contourne pas par une exemption de plateforme — la plateforme est déclarée par le client, donc par un attaquant aussi.
- **Rien n'est encore exigé.** Le mode par défaut observe : un déploiement qui se mettrait à refuser des appels sans que personne l'ait demandé serait une panne, pas une sécurisation. L'attestation web attend par ailleurs sa clé reCAPTCHA, à créer dans la console Firebase.
- **Ce qu'App Check ne fait pas** : il vérifie *quel programme* appelle, jamais *combien de fois*. Un plafond de dépense par compte reste à faire, et c'est lui qui protégerait aussi de nos propres bugs.

### v0.20.14 — fonctionnel

#### Le rôle ne se choisit plus soi-même, et la bibliothèque a une porte

- **N'importe qui pouvait devenir administrateur.** Le rôle d'un compte neuf était décidé par l'application — elle comptait la collection `users` et s'attribuait `admin` si elle la trouvait vide — et les règles Firestore ne contrôlaient aucun champ à la création. Il suffisait donc de se connecter avec un compte Google et d'écrire soi-même son propre document avec `role: "admin"`, hors application, pour obtenir tous les droits : le déclencheur qui recopie le rôle dans le jeton faisait confiance au document. Les règles imposent désormais `pending` à la création, ainsi que l'adresse du jeton, et **seul un administrateur nomme**.
- **Le compte fondateur est le seul administrateur d'origine.** Un déclencheur serveur lui rend le rôle `admin` en vérifiant l'adresse du compte *Auth* — jamais celle inscrite dans le document, qu'un client a pu écrire. Il le rétablit aussi s'il est rabaissé ou révoqué, et les règles interdisent à quiconque d'autre de toucher à son rôle : un administrateur adoubé ne peut pas destituer celui qui l'a nommé.
- **Être connecté ne donne plus accès à rien.** Tout compte Google qui se connectait lisait aussitôt l'intégralité des livres et des recettes de la famille. Un compte neuf attend maintenant d'être nommé : il voit une salle d'attente qui affiche son adresse, et rien d'autre. L'écran se referme de lui-même dès l'approbation. L'écran d'administration met ces demandes en tête de liste, sous un bandeau qui les compte.
- **Révoquer un éditeur ou un administrateur ne faisait rien.** Le contrôle de révocation n'était appliqué qu'aux lecteurs : un éditeur révoqué continuait d'écrire livres, recettes et référentiels, et un administrateur révoqué gardait l'administration. La révocation vaut désormais pour tous les rôles, côté règles comme côté Cloud Functions.
- **Les vingt-sept entrées d'IA ne sont plus gardées par la seule présence d'un compte.** Elles dépensent de l'argent à chaque appel : un compte en attente ou révoqué les atteignait aussi bien qu'un membre de la famille. Chaque appel vérifie maintenant le rôle porté par le jeton, et relit le document quand le jeton n'en porte pas encore — une lecture Firestore vaut moins qu'un appel d'IA laissé passer.
- **Les lignes de coût d'IA ne peuvent plus être fabriquées par un client.** Seules les Cloud Functions les écrivent, mais la règle de création leur était ouverte : n'importe quel compte pouvait inscrire des dépenses imaginaires que la réconciliation mensuelle aurait présentées comme réelles. Un montant faux ne se voit pas.
- **Les dépôts de fichiers suivent la même règle.** Les règles Storage laissaient écrire tout jeton sans claim de rôle — précaution du temps de la migration, aujourd'hui périmée, et qui aurait suffi à un compte en attente pour déposer des images dans les dossiers partagés. Les envois exigent désormais un rôle explicite. Les *lectures*, elles, restent ouvertes à tout compte actif : les fermer ferait clignoter les images de qui n'a pas encore renouvelé son jeton, pour un gain nul.

### v0.20.13 — fonctionnel

#### Toutes les sections de la fiche se replient

- **Nutrition, Dressage et Communauté** portent désormais le même en-tête que Catégorisation, Ingrédients et Préparation : icône, titre, chevron, et un appui qui les replie. Elles étaient les seules à s'imposer en entier — sur un téléphone, quatre sections dépliées font un écran qu'on parcourt au pouce sans jamais retrouver la préparation.
- **Chacune s'ouvre dépliée**, comme les autres : replier reste un geste, jamais un état imposé à l'ouverture.
- **« Voir tout » de la section Communauté reste dans l'en-tête**, donc joignable même repliée.

### v0.20.12 — fonctionnel

#### L'affichage compact cesse d'être une version amoindrie

- **La recette d'abord, puis nutrition, dressage et communauté.** En affichage compact, la fiche s'ouvrait sur le détail nutritionnel — avant même les ingrédients — et le **dressage n'existait tout simplement pas** hors mode cuisine, où il prenait la place de la communauté. Les quatre sections sont désormais empilées dans l'ordre de lecture : la recette, puis Nutrition, Dressage et Communauté, chacune sous son titre, et **aucune ne dépend plus du mode cuisine**. C'est le même contenu que les quatre onglets du grand écran.
- **Le document original est de nouveau joignable.** Le bouton « Voir / télécharger l'original » vivait dans la barre du grand format ; sous 700 px de large, le scan d'où venait la recette n'apparaissait nulle part. Il est maintenant dans la barre compacte, comme sur la page de livre et sur le brouillon, qui l'avaient toujours gardé.
- **La couverture d'une recette libre se change depuis le menu.** Le geste n'existait que sur la vignette de la barre large, absente en compact : son propriétaire ne pouvait plus la remplacer. Une entrée de menu le permet, et annonce l'envoi en cours.
- **Les puces de note, de remarques, d'astuces et de corrections reviennent à côté du titre.** Elles disaient d'un coup d'œil ce que la recette avait accumulé ; en compact, il fallait ouvrir la feuille communauté pour le découvrir. Un appui sur une puce y mène toujours.

### v0.20.11 — fonctionnel

#### Le conseil de conservation ne s'écrit plus en double

- **La section en fin de recette disparaît.** Le conseil y était recopié sous « Conservation et réchauffage ». Depuis que le bandeau le montre là où la question se pose, cette copie n'apportait rien — et elle s'affichait mal : le rendu numérotait son titre et son résumé comme les étapes **6** et **7** de la préparation, à la suite de la vraie recette.
- **Il ne vit plus qu'à un seul endroit**, sur la recette, et se lit dans le bandeau et dans la feuille du planning. Deux copies d'un même conseil, c'était deux versions à tenir d'accord qu'une régénération pouvait faire diverger.
- **Les recettes qui portent encore la section s'en débarrassent seules**, à leur première ouverture par quelqu'un qui a le droit de les modifier. Une section « Conservation » que vous auriez écrite à la main n'est jamais touchée : seul le titre exact posé par l'application est reconnu.
- **Générer la conservation depuis la planification** ne modifie plus le texte de la recette : le conseil est produit, stocké, affiché, et c'est tout.

### v0.20.11 — technique

#### Le conseil de conservation quitte le CookLang

- **`storage_text.dart` ne sait plus qu'effacer.** `buildStorageSection()` et `applyStorageSection()` sont supprimés ; restent `hasStorageSection()` et `removeStorageSection()`, qui servent au nettoyage de l'existant. Le conseil n'est plus persisté que dans `recipes/{id}.storage_advice`.
- **`hasStorageSection()` cherche le titre** au lieu de comparer les longueurs avant/après retrait. `removeStorageSection()` supprimant aussi les lignes vides finales, l'ancienne implémentation répondait vrai pour toute recette terminée par un saut de ligne — ce qui, branchée au nettoyage automatique, aurait déclenché une écriture Firestore sur presque chaque recette ouverte. Cas verrouillé dans `test/storage_text_test.dart`.
- **`StorageRepository`** : `applyToRecipe()` remplacé par `stripSection({recipeId, rawCooklang})`, qui n'écrit que si la section est présente et rend un booléen. `ensure({recipeId})` perd son rappel `loadRawCooklang` et se réduit à `read() ?? generate()`.
- **`recipe_detail_screen.dart` — `_stripLegacyStorageSection()`** : nettoyage opportuniste, une fois par recette et par session (`_strippedStorageIds`), conditionné à `canEdit` — un lecteur n'a pas le droit d'écrire et l'échec n'apprendrait rien. `updated_at` reste intact.
- **`batch_planning_screen._generateStorageAdvice()`** ne réécrit plus le CookLang ni ne recopie de recette dans `_slots` ; il produit et affiche.
- **`MealPrepBanner`** perd son paramètre `rawCooklang`.

### v0.20.10 — fonctionnel

#### La recette d'un plat cuisiné à l'avance le dit dès son ouverture

- **Le contexte du repas suivait la recette à moitié.** Le planning marquait bien « Préparé le dimanche 23 · réfrigérateur », mais ouvrir la recette depuis ce créneau donnait la fiche ordinaire : ni refroidissement, ni durée de garde, ni réchauffage, ni ce qu'il faut garder pour le dernier moment. Toute la question de la conservation restait sur l'écran précédent, celui qu'on a justement quitté pour aller cuisiner.
- **Un bandeau ouvre désormais la fiche** quand elle vient d'un repas préparé un autre jour : le jour de préparation, le jour du repas, le mode imposé par le délai réel — réfrigérateur jusqu'à trois jours, congélateur au-delà — et la consigne complète. Cette partie est **calculée**, comme dans le planning : elle s'affiche même si l'IA ne répond pas.
- **Le conseil propre au plat se produit tout seul**, à la première ouverture depuis un tel créneau, et se déplie sous le bandeau : contenant, ce qui se dégrade en premier, congélation possible ou non, méthode et température de réchauffage, ce qu'il vaut mieux ajouter au dernier moment, signes qu'il ne faut plus le manger. Il n'était jusqu'ici accessible que par le menu d'un repas au planning.
- **Il ne se repaie jamais.** Le conseil décrit le plat et non le créneau : produit une fois, il sert à toutes les planifications de cette recette et à toutes ses lectures.
- **Rien n'est écrit sur la recette partagée.** Les deux dates voyagent dans l'adresse, exactement comme les portions du repas : la même recette ouverte depuis un livre, ou depuis le repas d'un autre membre de la famille prévu un autre jour, reste ce qu'elle est.
- **En panne d'IA, le bandeau le dit** et propose de réessayer, sans jamais remplacer le conseil manquant par un texte générique — la consigne calculée, elle, reste affichée.

### v0.20.10 — technique

#### Contexte de préparation à l'avance porté par l'adresse de la recette

- **`features/planning/domain/meal_prep_context.dart`** (nouveau) : `MealPrepContext { prepDate, mealDate }`, avec `daysAhead`, `mode`, `isAhead` et `instruction` délégués à `meal_storage_rules.dart`. Sérialisation `toQueryParameters()` / `fromQueryParameters()` sous les clés `prep` et `meal`, au format `YYYY-MM-DD`. Une date illisible rend `null` : la fiche s'ouvre sans contexte plutôt qu'avec une date devinée.
- **Aucun stockage.** Le contexte n'est écrit ni sur `recipes/{id}`, ni sous `users/{uid}` : il suit la même voie que `portions`, en paramètre d'adresse, et meurt avec l'écran. Une recette est partagée et peut être planifiée à deux dates par deux membres du groupe.
- **`planning_screen.dart` — `_recipeLocationFor()`** construit désormais l'URL via `Uri(path:, queryParameters:)` et y joint `prep`/`meal` quand `meal.prepDate != null`.
- **`app_router.dart`** relit le contexte sur la route `/recipes/:recipeId` et le passe à `RecipeDetailScreen.prepContext`, propagé à `PrepareTab` (desktop) et `MobileUnifiedBody` (mobile) via le `topContent` de `CooklangPreview`.
- **`features/planning/presentation/meal_prep_banner.dart`** (nouveau) : `MealPrepBanner`, affiché uniquement si `prepContext.isAhead`. Partie haute calculée (`mealStorageInstruction`), partie basse produite par l'IA et dépliable. Trois états : chargement, panne (message + « Réessayer », la consigne calculée restant affichée), conseil disponible.
- **`StorageRepository.ensure({recipeId, loadRawCooklang})`** (nouveau) : `read` → `generate` si absent → `applyToRecipe` en best-effort avec `reportError('storage_advice_ensure_apply')`. `loadRawCooklang` est un rappel paresseux, appelé seulement quand il y a une section à recopier — relire la recette pour un conseil déjà stocké serait une lecture Firestore pour rien. `planning_screen._showStorageAdvice()` et le bandeau appellent tous deux cette méthode : la séquence n'existe plus qu'une fois.
- **`features/planning/presentation/storage_advice_details.dart`** (nouveau) : `StorageAdviceDetails` extrait de `storage_advice_sheet.dart`, partagé par la feuille du planning et le bandeau. Deux rendus divergents du même conseil auraient été une divergence invisible.
- **Aucun nouveau poste de coût** : le bandeau appelle `suggestStorageAdviceFn`, poste `storage_advice` déjà routable (`ROUTABLE_FEATURES`) et déjà au catalogue comptable.
- **Tests** : `test/meal_prep_context_test.dart` — aller-retour par les paramètres d'adresse, refus des dates partielles ou illisibles, franchissement de la limite réfrigérateur/congélateur.

## 2026-08-15

### v0.20.7 — fonctionnel

#### Trois duplications de moins, et le dernier chiffre figé dans le code

- **Le taux de change n'a plus de valeur de secours.** Un `0.92` dormait dans le code, prêt à convertir des dollars en euros dès que le taux réel manquerait — le même défaut que les prix, appliqué à la devise. Il est supprimé. Sans taux relevé, les montants restent affichés **en dollars**, ce qui est vrai. C'était le dernier chiffre de facturation figé dans le code.
- **Le planning ne rejoue plus les règles du serveur.** Quand l'IA laissait un créneau vide, l'application le comblait elle-même en rejouant les règles de variété, de dessert et de jour de préparation. Ce filet coûtait la duplication entière de ces règles pour un service douteux : il **masquait** qu'aucune suggestion n'avait été rendue, et la recette qu'il choisissait s'affichait comme une décision de l'IA. Un créneau reste désormais vide — et le menu ✨ sait le compléter à la demande.
- **Le calcul du mois de facturation n'existe plus qu'une fois côté serveur.** Il vivait en quatre exemplaires : consommation, coûts Anthropic, agrégats mensuels, périodes de facturation. Quatre copies de trois lignes dont personne n'aurait remarqué la divergence — un mois décalé ne casse rien, il compare simplement deux périodes différentes et présente l'écart comme un fait.

### v0.20.6 — fonctionnel

#### Un prix faux ne vaut pas mieux qu'un prix absent

- **Plus aucun tarif de secours.** La version précédente affichait les prix livrés avec le code quand la grille était illisible. C'était un mauvais réflexe : un tarif périmé présenté comme le tarif réel produit un montant crédible et faux, exactement ce que le suivi des coûts existe pour empêcher. Désormais, une grille illisible affiche **« Tarifs en panne »**, avec un bouton pour réessayer, et aucun prix.
- **Les appels passés pendant une panne sont enregistrés sans montant.** Leurs jetons sont connus, leur coût ne l'est pas : ils sont comptés séparément plutôt qu'ajoutés à zéro. Un mois traversé par une panne affichait sinon un total plus bas — et parfaitement crédible.
- **La confirmation avant dépense le dit aussi.** Avant une série de visuels de dressage, si la grille est indisponible, l'écran annonce qu'il ne peut pas chiffrer plutôt que d'avancer un montant inventé.
- **La reconstruction des agrégats refuse de tourner** sans grille : elle réécrirait des montants déjà publiés à partir de rien.
- **Les prix ne sont plus écrits qu'à un seul endroit.** L'application ne porte plus aucune table de tarifs : elle lit celle du serveur. La table du code ne sert qu'une fois, à créer le document la première fois. C'était la dernière duplication de prix du projet, et la plus sournoise.

### v0.20.5 — fonctionnel

#### Les tarifs d'IA se corrigent sans redéployer

- **La grille tarifaire quitte le code.** Les prix des modèles vivaient en dur, en deux exemplaires — un côté application, un côté serveur. Corriger un tarif après un changement de fournisseur demandait un déploiement, et jusque-là le reporting chiffrait faux sans que rien ne le signale. La grille en vigueur est désormais un document Firestore, éditable depuis *Admin › Moteur d'IA*, comme le routage entre Gemini et Claude.
- **Un tarif modifié prend effet en moins d'une minute**, et ne chiffre que les appels à venir. Les montants déjà enregistrés restent figés au tarif qui avait cours au moment de l'appel : un historique de dépense ne se réécrit pas.
- **Les prix livrés avec le code deviennent le repli.** Table injoignable, document absent, modèle jamais renseigné : le calcul continue avec la valeur d'origine. Un coût tombé à zéro dans le silence serait pris pour une bonne nouvelle.
- **Une saisie invalide est refusée, jamais devinée.** Un tarif non numérique ou négatif fait rejeter l'entrée entière et écrire un avertissement dans les logs, avec le nom du modèle concerné. Retenir la moitié d'une entrée reviendrait à facturer l'autre moitié à zéro.
- **Une promotion sans date de fin lisible est ignorée** : sans borne, une remise devient un tarif permanent le jour où elle expire.
- **L'écran distingue ce qui a été modifié** de ce qui vient du code, et un bouton rend la main au tarif d'origine. On peut aussi ajouter un modèle absent de la grille — utile le jour où un fournisseur en sort un nouveau.
- **L'annonce de coût avant dépense lit la même grille** : la confirmation qui précède une série de visuels de dressage ne peut plus citer un ancien prix.

### v0.20.4 — fonctionnel

#### Vos portions n'écrasent plus celles des autres

- **Changer le nombre de parts réécrivait la recette de tout le monde.** Le recalcul nutritionnel écrivait son résultat sur le document de la recette, estampillé du nombre de parts de celui qui avait bougé le curseur en dernier. Sur une recette de famille, vous passiez à 8 parts, quelqu'un repassait à 2, et votre fiche affichait les valeurs pour 2. Aucune erreur, aucune alerte : la valeur changeait simplement de propriétaire.
- **Il n'y avait rien à déplacer, seulement à cesser d'écrire.** Sur tout le bloc nutritionnel — totaux, poids, couverture, fiabilité, ingrédients manquants, huile absorbée — **une seule valeur** dépendait du nombre de parts : la division des totaux. Elle se fait désormais à l'affichage, pour le contexte qui la demande : votre lecture, ou votre repas de mercredi prévu pour 8.
- **La recette ne porte plus que ce qui la décrit** : ses totaux, calculés à ses propres portions, vrais pour tous ses lecteurs. Votre choix de parts reste enregistré sous votre compte, comme avant.
- **Bouger le curseur ne coûte plus rien.** Chaque changement de portions déclenchait un appel de Cloud Function et une écriture. Il n'en déclenche plus aucun : l'affichage se met à jour instantanément, et le recalcul reste disponible à la demande quand le contenu de la recette a changé.
- **Les recettes déjà en base restent justes** sans migration : les valeurs affichées sont dérivées des totaux, qui n'ont jamais dépendu de personne.

### v0.20.3 — fonctionnel

#### Deux corrections signalées à l'usage

- **Valider un planning n'empile plus les repas.** Enregistrer un nouveau cycle ajoutait ses repas par-dessus ceux déjà planifiés sur les mêmes jours : le planning en affichait deux par créneau, sans rien dire. La validation regarde désormais ce que le cycle recouvre et propose de **remplacer** les repas existants ou de les **compléter** — le nombre de repas remplacés est annoncé.
- **« Tout regénérer » dit ce qu'il fait.** Le menu annonçait « efface les choix en cours », ce qui laissait croire qu'il effaçait le planning enregistré. Il vide les créneaux de l'écran, et le libellé le dit.
- **La conservation était introuvable.** Le bouton n'apparaissait que sur un créneau ayant un jour de préparation calculé — donc uniquement avec un jour de batch cooking configuré **et** un jour coché « Réchauffage ». Il s'affiche maintenant dès qu'une recette est posée sur un créneau : on décide souvent de garder un plat après avoir choisi la recette, pas avant.
- **Le conseil est accessible depuis le planning**, par le menu d'un repas — l'écran où l'on se trouve trois jours plus tard, au moment de réchauffer. Il s'ouvre dans une feuille qui distingue nettement la consigne **calculée** (délai réel, réfrigérateur ou congélateur) du conseil produit par l'IA.
- **Un conseil déjà produit n'est jamais repayé** : il est relu avant toute génération, des deux écrans.

### v0.20.2 — fonctionnel

#### On cuisine la quantité prévue, et on sait ce que devient le plat en attendant

- **La recette s'ouvre à l'échelle du repas.** Depuis le planning, une recette prévue pour 8 parts s'affichait avec ses portions d'origine : le nombre saisi ne servait qu'à la liste de courses et disparaissait au moment de cuisiner. La fiche s'ouvre désormais aux parts du repas, ingrédients recalculés. **Rien n'est écrit** : ni sur la recette, ni sur vos préférences de portions. Ajuster les parts depuis cette ouverture reste volant et ne devient pas votre réglage permanent pour cette recette.
- **Un plat préparé à l'avance dit comment il se garde.** Le planning affiche, pour chaque créneau préparé un autre jour, le délai réel et ce qu'il impose : réfrigérateur jusqu'à trois jours, congélateur au-delà. Cette consigne est **calculée, pas générée** — elle s'affiche toujours, sans le moindre appel d'IA, parce qu'un plat gardé trop longtemps au froid n'a pas mauvais goût et n'alerte personne.
- **Le jour de préparation ne se perd plus.** Il était calculé pendant la planification, affiché, puis oublié à l'enregistrement. Il est maintenant conservé avec le repas, et c'est lui qui porte toute la question de la conservation.
- **Un conseil propre au plat, à la demande** : contenant et conditionnement, ce qui se dégrade en premier, durée réelle quand elle est plus courte que la règle générale (riz cuit, poisson, viande hachée), congélation possible ou déconseillée et pourquoi, méthode et température de réchauffage, ce qu'il vaut mieux ajouter au dernier moment, et les signes qu'il ne faut plus le manger. Un bouton le produit depuis le créneau concerné.
- **Il s'écrit en conclusion de la recette**, sous une section « Conservation et réchauffage », à côté du dressage. Le relire trois jours plus tard ne demande donc pas de rouvrir le planning. Une seconde génération remplace la section au lieu de l'empiler.
- **Produit une fois, valable pour tous les repas.** Le conseil décrit le plat, pas un créneau : il donne le réfrigérateur *et* le congélateur d'un coup, et le planning retient la moitié qui s'applique. Replanifier la même recette ne le repaie pas.
- **Le poste « Conservation et réchauffage » apparaît dans les coûts** et peut basculer entre Gemini et Claude depuis *Admin › Moteur d'IA*, comme tous les autres.

### v0.20.1 — fonctionnel

#### Moteur d'IA : l'écran laissait croire que Claude retouchait les images

- **La famille « Illustrations » s'appelle désormais « Illustrations — détection ».** Ses cinq postes *lisent* une image — repérer la photo principale, délimiter les illustrations, mesurer une grille — et Claude les sert très bien. Sous l'ancien titre, les voir tous basculés sur Claude donnait à penser que la retouche d'image y était partie aussi.
- **Les trois postes qui produisent une image apparaissent enfin**, dans une section qui ne se bascule pas : illustration de recette, visuel de dressage, amélioration de photo. Ils affichent le moteur qui les sert — Nano Banana 2 Lite — sous forme de puce et non de commutateur, parce qu'il n'y a rien à choisir : aucun modèle Claude ne fabrique d'image. Leur absence pure et simple était l'incohérence, pas leur non-basculement.
- **Aucun troisième fournisseur n'a été ajouté.** Ces postes sont du Gemini, comme la colonne de gauche, sur un modèle différent de celui du texte — et leur coût se lit dans Comptabilité aux mêmes clés qu'avant.

### v0.20.0 — fonctionnel

#### Les images changent de moteur, et le compteur suit

- **Nano Banana 2 Lite remplace l'ancien modèle d'image.** Illustrations de recette, visuels de dressage et amélioration de photo passent de `gemini-2.5-flash-image` à `gemini-3.1-flash-lite-image` : **0,0336 $ l'image au lieu de 0,04 $**, et une génération annoncée autour de quatre secondes. Claude, pour mémoire, ne produit aucune image — la génération visuelle reste chez Google par nécessité, pas par habitude.
- **L'ancien tarif reste au catalogue.** Les mois déjà consommés portent l'ancien identifiant de modèle : le retirer aurait relu leur coût au tarif par défaut, c'est-à-dire images gratuites. Un historique de dépense ne se réécrit pas quand on change de fournisseur.
- **Le modèle facturé ne peut plus diverger du modèle appelé.** L'identifiant vivait en trois exemplaires : deux modules choisissaient le modèle appelé, un troisième choisissait le modèle *facturé*. Un oubli dans ce dernier aurait imputé la dépense à l'ancien tarif sans qu'aucun écran ne bronche. Il n'existe désormais qu'une seule déclaration.
- **L'écran des coûts annonce le bon prix avant de dépenser.** La confirmation qui précède une série de visuels de dressage chiffrait encore l'ancienne grille.

### v0.19.99 — fonctionnel

#### Planification : les contraintes que vous saisissiez n'arrivaient nulle part

- **La contrainte du jour, dans l'écran de planning, n'était jamais transmise.** Le champ « Contrainte spécifique » ne s'enregistrait qu'à la validation clavier — impossible sur un champ multiligne. « Repas léger, sport le soir » restait à l'écran et ne quittait jamais le téléphone. Les champs *Prépa max* et *Parts à préparer* se perdaient de la même façon dès qu'on cliquait ailleurs. Chaque frappe compte désormais.
- **« Parts à préparer » n'existait pas côté serveur.** Le nombre était bien enregistré et servait à mettre la liste de courses à l'échelle, mais l'IA ne le voyait pas : elle pouvait proposer une recette individuelle pour un dîner de huit. Le créneau annonce maintenant ses parts, et l'IA signale quand elle a dû redimensionner.
- **Une réponse illisible du modèle passait pour « aucune idée ».** Le serveur avalait l'erreur sans un mot ; l'application comblait alors tous les créneaux avec un « complément automatique », et l'on croyait à une IA qui choisit mal — alors qu'elle n'avait rien choisi du tout. Ces échecs sont désormais tracés, nommés, et visibles dans les logs.
- **La régénération globale n'écrase plus vos choix.** Elle envoyait au modèle vos sélections manuelles comme « à éviter », puis les remplaçait quand même. Le bouton ✨ propose maintenant **Compléter les créneaux vides** ou **Tout regénérer**, qui prévient qu'il efface.
- **Les contraintes redeviennent modifiables après une génération.** Elles se figeaient définitivement, sans moyen d'ajuster puis de relancer.
- **Un cycle de plus de sept jours ne s'écrase plus lui-même** : deux créneaux tombant le même jour de semaine gardent chacun leurs contraintes.
- **Le calendrier choisi est enfin utilisé partout.** Deux des trois chemins d'export écrivaient toujours dans l'agenda principal en ignorant le calendrier configuré, sa durée par défaut et l'heure de repas. L'événement retrouve aussi son intitulé « Préparer : … », réduit à une espace par un accident d'encodage.
- **La liste de courses ne perd plus de repas.** Elle ne connaissait que vos recettes validées : un repas planifié depuis un brouillon ou une recette de la famille en disparaissait sans un mot. Elle est aussi limitée aux repas à venir — elle listait jusqu'ici les courses de repas déjà mangés.
- **Vos préférences ne sont plus écrasées par les valeurs par défaut.** L'écran de configuration pouvait s'ouvrir sur un état vide venu du cache, puis réenregistrer ces défauts par-dessus vos vrais réglages.
- **Le cycle peut démarrer aujourd'hui.** Ouvrir l'écran un vendredi quand le cycle commence le vendredi proposait le vendredi suivant.
- **Le planning charge les 90 derniers jours** au lieu de la totalité de l'historique à chaque ouverture.

### v0.19.98 — fonctionnel

#### La chaîne nutrition dépensait sous des noms de code

- **Quinze postes de coût s'affichaient sous leur identifiant technique**, tous rangés dans « Autres » : `detect_not_consumed`, `estimate_piece_weights`, `nutrition_ingredients_enrichment_batch`… soit toute la chaîne nutritionnelle, c'est-à-dire les appels les plus fréquents de l'application — une seule écriture de recette peut en déclencher une dizaine. Le montant était juste ; il était simplement impossible de savoir ce qu'on payait. Ils forment désormais le processus **« Valeurs nutritionnelles »**, chaque poste portant son nom et sa description.
- **Deux autres postes rentrent dans le rang** : la relecture d'un document Markdown et l'illustration de recette, oubliées elles aussi.
- **Les variantes par lot se distinguent de leur version unitaire.** Un lot coûte bien moins qu'une série d'appels isolés : les confondre revenait à s'interdire de vérifier que le groupage sert à quelque chose.
- **La règle est écrite et testée** : un poste d'IA vit à trois endroits — l'appel, le routage, le catalogue de lecture — et s'ajoute aux trois dans le même commit. Aucun de ces oublis ne lève d'erreur, ce qui est précisément le problème.
- **Diagrammes à jour** : le diagramme de classes porte `RecipeAbsorbedOil`, et le diagramme de séquence du recalcul nutritionnel montre l'appel de friture et son garde-fou gratuit.

### v0.19.97 — fonctionnel

#### Le bain et ce qu'il laisse derrière lui se lisent ensemble

- **L'huile absorbée se range sous le bain dont elle sort**, en « ↳ dont absorbée », au lieu de fermer le tableau à dix lignes de distance. Le bain dit ce qu'on jette, la ligne en dessous dit ce qu'on garde : deux lignes, une seule idée. Reléguée en fin de liste, l'huile absorbée ressemblait à un ingrédient qu'on aurait oublié de ranger.
- **Elle ne ferme le tableau que si la recette ne nomme aucun bain** — huile absente de la liste, ou nommée autrement. Dans ce cas elle reprend son nom complet, puisqu'elle n'a plus de parent pour la présenter.

### v0.19.96 — fonctionnel

#### On ne mange pas le bain de friture, mais on mange ce qu'on y trempe

- **Un poulet pané frit déclarait les lipides d'un poulet pané cru.** Le bain de friture est écarté du calcul — un litre d'huile pèse 8280 kcal, le compter rendrait toute recette illisible — mais ce qu'on y plonge en ressort plus gras : environ 10 % de son poids en huile. Sur 600 g de poulet pané, ce sont **55 g de lipides et 500 kcal** que la recette n'annonçait nulle part, avec une couverture affichée « complète » et un bon score de fiabilité.
- **Le taux d'absorption suit l'aliment, pas le bain.** Garder un pourcentage de l'huile déclarée aurait fait dépendre le résultat de la rédaction de la ligne : « 1 L pour la friture » n'a aucun rapport avec ce qui est mangé. Le calcul part du poids des ingrédients frits, panure comprise, et se plafonne à l'huile que la recette met réellement dans la poêle.
- **Une ligne dérivée dit d'où viennent ces lipides** : « huile de tournesol absorbée · 55 g », en italique et marquée estimée, sous les ingrédients. Au survol, son taux et le poids frit dont il découle. Le bain garde sa mention « non consommé » : les deux lignes coexistent et racontent la vérité — on jette le litre, on mange les 55 g.
- **Seules les recettes qui sentent la friture paient un appel d'IA.** Un test gratuit sur le texte et les ingrédients sert de portier ; une panure seule ne déclenche rien, le four existe. Le verdict est conservé et n'est redemandé que si la recette change.

## 2026-08-14

### v0.19.93 — fonctionnel

#### Un total nommé, et un écart qui cesse de crier au loup

- **« Invoice » n'est pas le total de l'infrastructure**, malgré son nom : c'est une ligne de facturation Google comme les autres — taxes et ajustements de facture. L'arithmétique le montre : sur juillet, 3,65 € d'« Invoice » plus les autres services font les 3,96 € de la section. Un **« Total infrastructure »** en gras est donc ajouté en fin de liste : la somme méritait d'être nommée plutôt que devinée.
- **Un écart dont la cause est connue et irréparable n'est plus signalé en rouge.** Les mois clos avant le 14 août sont antérieurs au comptage des jetons de raisonnement : Gemini les facture, l'application ne les lisait pas, et aucune reconstruction ne fera apparaître une donnée qui n'a jamais été enregistrée. L'écran le dit en une phrase, au lieu de demander indéfiniment d'enquêter sur une cause déjà établie — et de noyer le jour où un vrai écart se produira.
- **Le mois d'août est signalé comme à cheval** : ses premiers appels ne portent pas le raisonnement, les derniers oui. L'écart s'y résorbera de lui-même en septembre.

### v0.19.92 — fonctionnel

#### L'écart affiché comparait deux instants différents

- **Un montant facturé est une photographie ; nos compteurs sont vivants.** Le relevé Anthropic est mis en cache six heures ; pendant ce temps, les appels continuent d'être comptés. L'écran soustrayait donc un total à jour d'un total périmé, et attribuait la différence à la grille tarifaire — alors qu'elle ne mesurait qu'un décalage d'horloge.
- **L'âge du relevé est désormais affiché** à côté du montant facturé : « relevé il y a 12 min ».
- **Au-delà de deux heures, l'écart n'est plus signalé en rouge** mais accompagné d'une phrase : les appels comptés depuis ne figurent pas dans le relevé, il faut relire le mois pour comparer deux chiffres du même instant.

### v0.19.91 — fonctionnel

#### La lecture Anthropic marche, et elle a immédiatement trouvé une erreur

- **Nous surestimions Claude de 50 %.** La confrontation à la vraie facture d'août — 0,80 € facturés contre 1,20 € estimés — l'a montrée en une lecture. La cause : **Claude Sonnet 5 bénéficie d'un tarif d'introduction** (2,00 / 10,00 au lieu de 3,00 / 15,00) jusqu'au 31 août 2026, que la grille ignorait volontairement — l'idée étant qu'une surestimation valait mieux qu'une sous-estimation. C'était une erreur de raisonnement : un écart de moitié rend le rapprochement inutilisable **dans les deux sens**, et masquerait un vrai défaut de comptage le jour où il s'en produirait un. Une marge de sécurité posée sur un instrument de mesure ne le sécurise pas, elle le casse.
- **La grille est désormais datée** : un tarif promotionnel s'applique tant qu'il court, le tarif plein reprend automatiquement le jour où il expire. Et un appel est facturé au tarif **du jour où il a eu lieu**, jamais à celui du jour où l'on relit le rapport.
- **Le message d'écart se lit dans les deux sens.** Il n'expliquait que le cas « le fournisseur facture plus que nous ne comptons » et envoyait chercher des jetons manquants là où il n'en manquait aucun. Il distingue maintenant la consommation invisible d'une grille trop chère.
- **« Rechiffrer aussi les appels »**, case à cocher de la reconstruction : applique la grille corrigée aux mois déjà enregistrés. C'est la seule façon de réparer août — et parce qu'elle réécrit des montants déjà publiés, elle reste un choix explicite, jamais coché d'avance.

### v0.19.90 — fonctionnel

#### La lecture Anthropic avance par tranches au lieu d'échouer en entier

- **Le blocage était une boucle fermée.** Douze mois faisaient douze requêtes d'un bloc ; l'échec empêchait d'écrire quoi que ce soit ; l'affichage suivant repartait donc de zéro et rallumait la limite de débit. Rien ne pouvait en sortir.
- **Ce qui est lu est désormais conservé**, même quand la lecture s'arrête en chemin. Chaque ouverture de l'écran relève **quatre mois**, **les plus récents d'abord** — le mois en cours étant le seul qu'on regarde vraiment. En trois ouvertures, l'année est complète.
- **Cinq minutes de pause après un refus.** Sans elle, chaque ouverture relançait la lecture et repoussait d'autant le retour à la normale : le remède entretenait la panne. Le bouton « Relire ce mois » passe outre.
- **Le message ne parle plus de panne** quand il n'y en a pas : « les mois sont relevés par tranches, ce qui est affiché est acquis, le reste se complètera ».

### v0.19.89 — fonctionnel

#### Anthropic : la vraie cause du refus, et un bouton pour vérifier un mois

- **Le 429 venait d'abord de la taille de page.** Le rapport de coûts d'Anthropic rend des **journées**, et une page en vaut **7 par défaut** — pour un maximum autorisé de **31**. Une année d'historique coûtait donc près de **soixante** requêtes là où elle en coûte désormais **treize**. Pire : notre garde-fou s'arrêtait à quarante pages, ce qui aurait tronqué la lecture sans le dire.
- **Anthropic recommande une interrogation par minute** en régime établi, et conseille explicitement de mettre les résultats en cache pour un tableau de bord. C'est exactement ce que fait désormais l'écran.
- **Un bouton « Relire ce mois chez Anthropic »**, placé dans le mois plutôt qu'en tête d'écran : c'est ce montant-là qu'on veut vérifier. Il ne relit **qu'un mois** — une requête, au lieu de treize pour l'année. Sans lui, un avoir ou une correction rétroactive resterait masqué par le cache indéfiniment.

### v0.19.88 — fonctionnel

#### La clé Anthropic fonctionnait : c'est l'écran qui demandait trop

- **Le « facturé par Anthropic : — » n'était pas un refus de clé, mais un `HTTP 429`** — limite de débit atteinte. L'API d'administration d'Anthropic rend des **journées** : afficher une année en demandait des dizaines de pages, à chaque ouverture de l'écran.
- **Les montants sont désormais mémorisés.** Un mois clos est lu une fois pour toutes — sa facture ne bougera plus. Seul le mois courant est redemandé, et au plus toutes les six heures. Ouvrir l'écran dix fois ne coûte plus dix lectures, mais zéro.
- **Un 429 n'est plus traité comme une panne** : c'est une demande d'attendre. L'appel patiente le temps indiqué par Anthropic et retente deux fois.
- **Un échec ne fait plus disparaître ce qu'on savait déjà.** Les montants du dernier relevé réussi restent affichés, signalés comme tels. Auparavant, une seconde de trop effaçait une facture de plusieurs euros.
- **Le message distingue enfin les trois cas** — clé absente (Secret Manager), clé refusée (console Anthropic), débit limité (rien à faire, sinon attendre) — parce qu'ils se règlent à trois endroits différents.

### v0.19.87 — fonctionnel

#### Un chiffre, un seul endroit

- **La ventilation par poste disparaît de l'écran mensuel.** Elle faisait doublon avec l'onglet « Par service IA », qui la donne en mieux — nombre d'appels et coût unitaire, moteur par moteur. Deux lectures du même chiffre dans deux formats différents finissent par diverger, et c'est toujours la plus pauvre qu'on lit en premier.
- **« Par service IA » a désormais son propre filtre de période**, avec les mêmes puces que l'écran mensuel (Ce mois / 3 / 6 / 12 mois / Depuis le début). Il fallait auparavant revenir sur l'autre onglet pour changer la période de celui-ci : le geste le plus fréquent était devenu le plus long. Deux onglets réglés sur la même profondeur se partagent toujours une seule lecture serveur.
- Le filtre reste affiché quand le tableau est vide — une période trop courte étant la première cause d'un tableau vide, la masquer enfermait dans l'écran qu'on cherchait à quitter.

### v0.19.86 — fonctionnel

#### L'écart se chiffre, se règle, et l'écran cesse de mentir par omission

- **L'écart est désormais chiffré en jetons, pas seulement en euros.** La facture Google indique 2 457 734 jetons de sortie pour août ; l'application en comptait 323 900. Les 2 133 834 manquants — du raisonnement — valent 4,67 €, pour un écart affiché de 4,62 €. **La cause explique la totalité de l'écart.** L'écran le dit maintenant lui-même, en rapprochant ses compteurs des lignes de la facture.
- **Un réglage pour le résorber** — *Admin → Moteur d'IA → Raisonnement de Gemini* : « le modèle décide » (défaut, inchangé), coupé, ou plafonné à 512 / 2 048 / 8 192 jetons. Le raisonnement représentait près de neuf dixièmes de la ligne la plus chère de la facture Gemini. Beaucoup de postes n'en ont aucun besoin — classer une page, deviner les dimensions d'une grille, proposer des tags ne demandent pas de délibération. Si l'API refuse le plafond, l'appel est rejoué sans lui : une facture plus lourde vaut mieux qu'un poste qui ne répond plus.
- **Claude dit enfin pourquoi il ne se confronte à rien.** « La clé n'est pas posée **ou** la lecture a échoué » laissait chercher du mauvais côté. L'écran distingue les deux et affiche l'erreur exacte renvoyée par Anthropic.
- **L'onglet « Contrôle Gemini » disparaît.** Il ne comparait que la part que Google facture : on y cherchait Claude et l'infrastructure sans les trouver, et un contrôle portant sur la moitié de la dépense se lit comme un contrôle sur la totalité. La confrontation à la facture vit dans « Mois par mois », où les deux moteurs ont la même forme et l'infrastructure sa section.

### v0.19.85 — fonctionnel

#### L'écart de facturation avait une cause, et ce n'était pas le tarif

- **Le suivi comptait 2,13 € là où Google facturait 17,06 €.** La cause n'est ni un tarif ni un arrondi : **Gemini 2.5 Flash réfléchit avant de répondre**, et ces jetons de réflexion sont facturés au prix de la sortie — huit fois l'entrée — sans jamais apparaître dans la réponse. Le backend ne lisait que les jetons du texte rendu. Sur un appel d'extraction ordinaire, le raisonnement représente plusieurs fois le texte produit : le coût affiché valait donc une fraction du coût réel. Aucune erreur nulle part, juste un chiffre plausible et faux.
- **Ils sont désormais comptés**, et affichés à part : chaque moteur montre ses jetons d'entrée, de sortie **et de raisonnement**. Un poste qui coûte cher parce qu'il fait beaucoup réfléchir ne se corrige pas comme un poste qui produit beaucoup.
- **Un appel échoué est un appel facturé.** Un dépassement de délai n'arrête pas le calcul chez le fournisseur, et le repli sur l'autre moteur en ajoute un second. Ces appels étaient invisibles ; ils apparaissent maintenant, et le nombre d'appels en échec est affiché sur le mois.
- **La facture Google est décomposée ligne par ligne** sous la section Gemini — jetons d'entrée, jetons de sortie, génération d'images — avec les quantités facturées. Un écart réduit à un seul nombre rouge ne se diagnostique pas ; en regard des lignes de la facture, il désigne le poste en cause.
- **L'onglet « Réconciliation » s'appelle « Contrôle Gemini »** et dit ce qu'il couvre. On y cherchait Claude et l'infrastructure sans les trouver : il ne compare que la part que Google facture. Claude, facturé par Anthropic, et l'infrastructure se lisent dans « Mois par mois », qui les confronte eux aussi à leur facture.

> Les mois passés resteront sous-estimés même après reconstruction : les jetons de raisonnement n'ont pas été enregistrés à l'époque, il n'y a rien à relire. L'écart se referme à partir de maintenant.

### v0.19.84 — fonctionnel

#### Coûts : des euros, deux moteurs à égalité, et le coût d'un appel

- **Tout est en euros, en notation européenne** : virgule pour les décimales, espace pour les milliers. La conversion utilise **le taux du mois concerné**, celui que Google a lui-même appliqué à sa facture — et non un cours du jour plaqué sur tout l'historique, qui donnerait pour l'an dernier un total que personne n'a payé. Les petits montants gardent quatre décimales : à deux, la plupart des appels d'IA s'afficheraient « 0,00 € ».
- **Trois blocs par mois : Claude, Gemini, infrastructure.** Gemini était jusqu'ici une ligne parmi les services Google, parce que c'est Google qui le facture. Il a désormais sa section, dans le même format que Claude — estimé par l'application, facturé par le fournisseur, écart en montant et en pourcentage. Deux moteurs présentés dans deux formats différents ne se comparent pas ; c'était pourtant la seule question qui compte au moment de basculer un poste de l'un vers l'autre.
- **Le total du mois retient le facturé quand il existe**, l'estimation seulement à défaut. Les deux ne sont jamais additionnés.
- **Un nouvel onglet « Par service IA »** : pour chaque poste — ou chaque processus, au choix — le **nombre d'appels**, le **coût unitaire** et le **total**, en trois colonnes distinctes : Claude, Gemini, et l'ensemble. Deux postes de même montant n'ont pas le même remède : l'un appelé mille fois pour trois fois rien se corrige en appelant moins, l'autre appelé trois fois pour un montant lourd en changeant de modèle. Le total seul ne les distingue pas.
- **L'estimation d'empreinte énergétique est de retour**, disparue avec l'ancien écran d'usage des tokens : nombre de jetons et énergie estimée (~0,001 Wh pour mille jetons) sur le total de la période, sur chaque mois, et sur chaque moteur. C'est un ordre de grandeur, pas une mesure — mais une consommation qu'aucun écran ne montre est une consommation qui ne baisse jamais.
- **Un écart entre estimé et facturé au-delà de 10 % est mis en évidence** au lieu de rester un chiffre parmi d'autres.

> Un mois d'août affichant « estimé 0,00 € » face à un montant facturé par Anthropic n'est pas un bug de tarification : ce sont des appels enregistrés avant la mise en place des agrégats mensuels. Le bouton **Reconstruire les agrégats** les rattrape depuis les lignes d'appel.

## 2026-08-13

### v0.19.83 — fonctionnel

#### Coûts : Anthropic entre dans le tableau, et l'historique s'ouvre

- **Où était Anthropic ? Nulle part, et pour une raison structurelle** : la facturation Google ne contient pas les appels Claude — Anthropic les facture directement. L'écran ne pouvait donc pas les montrer comme facturés, seulement estimés.
- **Le facturé Claude est désormais lu chez Anthropic** : chaque mois affiche l'estimation de l'application, le montant réellement facturé, et l'écart entre les deux. Un écart supérieur à un dollar est mis en évidence.
- **Cette lecture demande une clé d'administration Anthropic** (`sk-ant-admin…`), distincte de la clé d'inférence, à poser dans Secret Manager sous le nom `ANTHROPIC_ADMIN_KEY`. Sans elle, l'écran affiche l'estimation et dit franchement qu'elle n'est confrontée à rien — il n'invente pas un zéro.
- **Quatre profondeurs** : ce mois, 3 mois, 6 mois, 12 mois, et **depuis le début** — qui remonte au premier appel jamais enregistré.
- **Deux lectures** : par mois, ou par année repliée avec ses mois à l'intérieur.
- **Une répartition en tête d'écran** : ce que coûtent Gemini, Claude, les postes internes et l'infrastructure, sur toute la période choisie.
- **Une limite dite plutôt que masquée** : la facturation Google ne remonte que sur sa fenêtre d'export. « Depuis le début » couvre donc toute l'IA, mais l'infrastructure s'arrête là où l'export s'arrête — et l'écran le signale au lieu de laisser croire à une infrastructure gratuite.

### v0.19.82 — fonctionnel

#### Cloud Logging : un traitement porte le nom de son poste

- **Fini les groupes tous intitulés « call »** : chaque appel HTTPS fabriquait son identifiant de corrélation avec le même préfixe générique. L'écran regroupait donc correctement… une dizaine de traitements portant tous le même nom, ce qui obligeait à ouvrir chacun pour savoir de quoi il s'agissait.
- **Le nom du poste devient la racine de l'identifiant** : « Extraction depuis un texte libre », « Conseil de dressage », « Amélioration photo » se distinguent désormais au premier regard, et le filtre par identifiant exact isole un traitement précis.

### v0.19.81 — fonctionnel

#### Refonte du suivi des coûts : ce que coûte l'application, mois par mois

- **Un seul écran** — *Admin › Coûts de l'application* — remplace « Comptabilité » et « Usage des tokens IA ». Il montre les douze derniers mois, chacun dépliable : coût total, part IA et part infrastructure, ventilation par poste fonctionnel, par moteur, et par service Google.
- **Les totaux affichés sont enfin des totaux.** L'écran précédent lisait les mille derniers appels et présentait leur somme comme le total du mois. Au-delà de mille appels, il se trompait sans le dire. Les chiffres viennent désormais d'agrégats mensuels tenus à jour à chaque appel.
- **Un seul chiffrage.** Le coût d'un appel est fixé au moment où il a lieu, par la grille tarifaire du serveur. L'écran l'affiche, il ne le recalcule plus — deux grilles pour un même appel finissent toujours par diverger.
- **Plus aucun appel invisible.** Un appel dont le moteur ne renvoyait pas ses métadonnées n'était pas compté du tout, alors qu'il était bien facturé. Il l'est désormais, avec zéro jeton, et reste visible.
- **Le scan de sécurité n'est plus compté comme de l'IA Google.** Il apparaît sous le moteur « Interne », et sort du rapprochement avec la facturation Gemini.
- **La réconciliation dit la vérité en multi-moteur.** Elle sépare la part Gemini — la seule que Google facture et qu'on peut donc vérifier — de la part Claude, facturée par Anthropic, et le signale explicitement dans ses anomalies. Jusqu'ici, activer Claude creusait un écart artificiel présenté comme un fait.
- **Reconstruire les agrégats** : un bouton recalcule les mois affichés depuis les lignes d'appel. Il sert à rattraper l'historique antérieur au suivi mensuel, ou à réparer un mois dont les compteurs auraient dérivé. Aucun coût d'IA n'est engagé.

### v0.19.80 — fonctionnel

#### Le dressage retourne dans la recette

- **Intégrer à la recette** remplace le bouton de copie : le conseil s'écrit en fin de recette sous une section **Dressage**, visuels compris en images flottantes alternées.
- **Intégrer deux fois ne double rien** : la section précédente est remplacée, y compris ses visuels. Trois régénérations suivies de trois intégrations ne laissent qu'une seule section — celle du dernier conseil.
- **Avec une réserve annoncée** : si vous aviez retouché la section à la main, l'intégration suivante écrase vos modifications. Le dialogue de confirmation le dit explicitement avant d'écrire, et affiche le texte exact qui sera inséré.
- **Une section « Cuisson et dressage » écrite par vous n'est jamais touchée** : seule la section produite par l'IA, au titre exact, est reconnue.
- **Retirer le dressage de la recette** reste disponible dès qu'une section existe.

### v0.19.79 — fonctionnel

#### La bascule vers Claude s'appliquait à moitié

- **Onze postes ignoraient la configuration** : extraction depuis un scan ou un texte, relecture CookLang et Markdown, modification et génération de recette, recherche, couverture de livre, planning, courses, suggestion de tags, conseil de dressage. Choisir Claude — par poste ou par défaut — n'avait aucun effet sur eux : ils continuaient d'être servis par Gemini.
- **Pourquoi c'était invisible** : ces fonctions ne recevaient pas la clé Claude. Pour elles, la clé était donc « absente », situation dans laquelle le routeur sert l'autre moteur sans la signaler comme une panne — c'est le comportement voulu entre le déploiement du code et la création de la clé. Pendant ce temps, l'écran *Moteur d'IA* affirmait que la clé était présente, car il la reçoit, lui.
- **Ce qui change** : ces postes obéissent désormais à la configuration. Un basculement resté sans effet écrit maintenant un **avertissement** dans les logs, avec le nom du poste concerné : le silence est ce qui avait rendu cette panne indéchiffrable.
- **Le reporting de coûts reflétera la bascule** : jusqu'ici, la comptabilité était juste — elle mesurait bien du Gemini — mais elle mesurait un moteur que vous croyiez avoir quitté.

### v0.19.78 — fonctionnel

#### Les générations d'image rejoignent leur traitement dans les logs

- **Un visuel généré n'est plus orphelin** : la ligne de consommation d'une image portait un `correlation_id` nul, si bien qu'elle apparaissait sous « Hors traitement » dans l'écran Cloud Logging, à côté de l'appel qui l'avait pourtant provoquée. Elle est désormais rattachée à son traitement.
- **Le poste nomme le groupe** : le champ `feature` était rangé dans les données annexes du log au lieu du premier niveau — l'écran ne pouvait donc ni l'afficher en titre ni filtrer dessus. Corrigé pour toutes les générations d'image (visuels de dressage et illustrations de recette).
- La comptabilisation elle-même était juste : chaque image reste facturée 0,04 $ sur son poste (« Visuel de montage », « Génération d'image »), et le conseil de dressage au tarif du modèle qui a réellement répondu.

### v0.19.76 — fonctionnel

#### Dressage : une seule génération à la fois

- **Les autres actions sont suspendues pendant qu'un visuel se fabrique** : les boutons des autres étapes, *Regénérer* et *Réinitialiser les visuels* deviennent inertes jusqu'à la fin. Deux générations lancées de front produiraient deux assiettes concurrentes, et la série cesserait de raconter un montage.
- **Les boutons restent visibles, seulement grisés** : les faire disparaître laisserait croire que l'action n'existe pas. *Copier le texte* reste actif — c'est la seule action qui ne touche à rien.

### v0.19.75 — fonctionnel

#### Dressage : les visuels ne peuvent plus être produits dans le désordre

- **Illustrer une étape produit celles qui manquent avant elle** : chaque image se construit sur la précédente ; demander la troisième sans les deux premières donnait une assiette née de rien, sans rapport avec celles qu'on générait ensuite. Un clic sur l'étape 3 génère donc 1, 2 puis 3, dans l'ordre.
- **Le coût est annoncé avant** : quand plus d'un visuel est nécessaire, un dialogue indique combien seront créés et pour quel montant. Le tarif vient de la grille tarifaire du projet, pas d'un chiffre écrit à la main.
- **Seul le dernier visuel peut être refait** : reprendre une étape du milieu laisserait derrière elle des images descendant d'une assiette qui n'existe plus. Les étapes antérieures n'ont plus de bouton.
- **Réinitialiser les visuels** : un bouton en bas de l'onglet efface toute la série pour repartir d'une assiette vide. C'est la seule façon — et une façon explicite — de refaire une étape ancienne. Le conseil et son texte ne sont pas touchés.
- **Une série interrompue reprend où elle s'est arrêtée** : si une génération échoue au milieu, les visuels déjà produits sont conservés et le clic suivant comble le trou.

### v0.19.74 — fonctionnel

#### Dressage : tout se passe dans l'assiette

- **Plus rien à côté du contenant** : le modèle d'image posait spontanément la sauce dans une coupelle à côté de l'assiette, ajoutait une planche, débordait sur la table. Un guide de dressage montre ce qu'il y a *dans* l'assiette ; le reste est du décor de magazine, et il ment sur le geste à reproduire. La consigne est désormais explicite, à la génération comme à la description : un seul contenant, aucun ramequin annexe, une sauce d'accompagnement se pose en touche dans l'assiette.
- **Le visuel de résultat final est supprimé** : puisque chaque image part de la précédente et qu'on demande d'y ajouter quelque chose, un visuel « final » de plus ne pouvait qu'ajouter un objet — c'est ce qu'il faisait. La dernière étape du dressage **est** le résultat, et elle s'illustre comme les autres.

### v0.19.73 — fonctionnel

#### Le dressage a son propre texte

- **Il n'est plus recopié dans la recette** : le dressage n'est pas une étape de cuisson, c'est ce qu'on fait une fois la recette finie. Fondu dans les étapes, il allongeait la recette de gestes qu'on ne lit pas en cuisinant, et une régénération réécrivait un contenu que l'utilisateur avait pu retoucher. Il vit dans son onglet, avec ses visuels.
- **Copier le texte** : un bouton met le dressage complet — intention, contenant, gestes numérotés, pièges, finitions — dans le presse-papier, prêt à être collé ou envoyé.
- **Nettoyage des essais précédents** : sur une recette où le dressage avait été inséré, un bouton **Retirer le dressage de la recette** supprime la section. Une section « Cuisson et dressage » écrite à la main n'est jamais touchée.

### v0.19.72 — fonctionnel

#### Dressage : les visuels se construisent l'un sur l'autre

- **La matière est respectée** : le conseil décrit désormais la consistance de chaque élément (émulsion épaisse qui tient au ruban, purée mate, jus sirupeux), et le générateur d'image a consigne de la tenir. Une anchoïade montée à l'huile ressortait en bouillon : un modèle d'image livré à lui-même peint toutes les sauces en liquide clair.
- **Chaque visuel complète le précédent** : illustrer l'étape 2 part de l'image de l'étape 1 et n'y ajoute que le geste en cours, cadrage et lumière inchangés. Chaque étape était auparavant refabriquée de zéro, ce qui donnait quatre assiettes sans rapport au lieu d'un montage.
- **Toutes les étapes sont illustrables**, y compris les dernières — celles où le dressage se joue vraiment.
- **Le résultat dressé** : un bloc en bas de l'onglet génère le visuel du plat terminé, dans la continuité des étapes déjà illustrées. Il s'insère en pleine largeur à la fin de la section Dressage de la recette.
- **Les visuels accompagnent le texte** : l'image se place en regard du geste plutôt qu'en pleine largeur, et s'agrandit d'un clic. En pleine largeur, elle chassait la consigne hors de l'écran.

### v0.19.71 — fonctionnel

#### Onglet Dressage : un conseil de cette recette, pas du dressage en général

- **Ce qui disparaît** : l'onglet produisait ses conseils sur place, en cherchant des mots-clés dans les noms d'ingrédients. « Persil détecté » donnait « les herbes soulignent le mouvement du dressage ». C'était vrai de tous les plats, donc utile pour aucun.
- **Un conseil demandé, pas subi** : l'onglet s'ouvre sur un bouton **Demander un dressage sur mesure**, avec un champ libre pour le contexte de service (« assiettes creuses », « buffet froid », « à emporter »). Rien n'est appelé tant que l'utilisateur ne le décide pas.
- **Ce que le moteur rend** : le contenant conseillé et pourquoi, l'ordre des gestes de montage nommant les éléments réels de la recette, les pièges propres à ce plat (ce qui détrempe, ce qui fige, ce qui ternit), et ce qui se pose au dernier moment.
- **Refus du passe-partout** : une réponse dont les gestes ne citent aucun ingrédient de la recette est refusée et redemandée. Un conseil générique ne lève aucune erreur et s'affiche parfaitement — c'est pour cela qu'il est détecté à la production, pas à la lecture.
- **Visuels de montage** : sur les dressages complexes, le moteur propose jusqu'à trois étapes à illustrer. L'image montre l'assiette **en cours de montage**, pas le plat fini. Chaque visuel se génère à la demande, étape par étape, jamais en lot (0,0336 $ l'image). Réservé aux rôles éditeur et administrateur.
- **Intégration à la recette** : un éditeur peut recopier le conseil dans la recette elle-même, sous une section **Dressage**, visuels compris en images flottantes alternées. Un aperçu du texte exact précède l'écriture ; une seconde intégration remplace la précédente au lieu de l'empiler.
- **Un appel par recette** : le conseil est conservé sur la recette et profite à tous les lecteurs. Un bouton **Regénérer** permet de le refaire, en changeant éventuellement le contexte de service.
- **Moteur nommé, jamais déguisé** : le conseil affiche en pied de page le moteur qui a répondu (Claude ou Gemini) et son modèle. Le poste est basculable depuis *Admin › Moteur d'IA*, sans redéploiement.

## 2026-08-12

### v0.19.59 — fonctionnel

#### Écran « Cloud Logging » : le bruit passe en DEBUG

- **Instrumentation séparée des événements** : « Appel IA démarré », « prompt envoyé à Gemini » et « réponse brute Gemini » sont journalisés en **DEBUG** et non plus en INFO. Un import écrivait une cinquantaine de lignes dont une quinzaine seulement portait une information : l'ouverture d'un appel n'apprend rien que sa clôture ne dise, durée et jetons compris.
- **Chips de sévérité en seuils** : « INFO+ » affiche INFO, WARN et ERROR ; « WARN+ » affiche WARN et ERROR ; « ERROR » les erreurs seules ; « DEBUG seul » isole l'instrumentation ; « Tout » ne filtre rien. L'égalité stricte précédente était un piège — sélectionner INFO masquait les erreurs, c'est-à-dire précisément ce qu'on cherchait.
- **Filtre par défaut : INFO+**. Le détail technique reste à un clic.

### v0.19.58 — fonctionnel

#### Un traitement porte le nom du travail, pas celui d'un appel

- **Une écriture de recette = un traitement** : le recalcul des produits d'achat et la synchronisation nutrition tiraient chacun un identifiant de corrélation aléatoire. L'écran de logs y voyait deux traitements anonymes, sans lien entre eux ni avec l'écriture qui les avait déclenchés. Les deux partagent désormais le `correlationId` posé par `onRecipeWritten` et se lisent comme un seul bloc.
- **Titre du groupe** : le libellé vient d'abord de la racine du `correlationId`, qui nomme le traitement. Le poste (`feature`) n'est plus qu'un repli, et seulement pour les entrées dont l'identifiant est opaque : l'utiliser en titre faisait passer l'import d'une recette pour un « shopping_products_refresh », du nom du premier appel IA qu'il déclenchait.

### v0.19.57 — fonctionnel

#### File de travail : un import, une ligne

- **Le brouillon remplace son traitement dès qu'il existe** : la pipeline d'import publie le brouillon, puis poursuit plusieurs minutes de normalisation des référentiels en arrière-plan. Pendant cette phase, la file de travail affichait deux lignes pour un seul import — le traitement en cours et le brouillon qu'il venait de produire. Le traitement disparaît désormais de la file dès qu'il a créé un brouillon : c'est le brouillon que l'utilisateur ouvre, et lui seul reste affiché. Les jobs en **erreur** ou **rejetés** restent visibles même s'ils ont produit un brouillon, sans quoi la panne disparaîtrait de l'écran.

#### Écran admin « Cloud Logging » : lecture par traitement

- **Regroupement par traitement** : un chip « Par traitement » (activé par défaut) regroupe les entrées partageant un même `correlationId`. Un import, un backfill ou un enrichissement se lit alors comme un bloc unique — replié, avec son libellé, son nombre de messages et sa date — au lieu d'être dispersé dans le flux entre les messages des autres traitements.
- **Ordre de lecture inversé dans le groupe** : le flux global présente le plus récent en premier, mais un traitement se déroule dans le temps : ses messages sont donc affichés du plus ancien au plus récent.
- **Les échecs s'ouvrent d'eux-mêmes** : un groupe contenant au moins une entrée `ERROR` est déplié à l'affichage et porte l'icône et la couleur d'erreur ; un groupe contenant un `WARNING` porte la couleur d'avertissement.
- **Isoler un traitement** : un bouton entonnoir sur l'en-tête du groupe reporte son `correlationId` dans le filtre exact et relance la requête.
- **Libellé lisible** : le groupe s'intitule par le poste fonctionnel (`feature`) quand il est connu, sinon par le module, sinon par la racine du `correlationId` débarrassée de son horodatage. Les entrées sans corrélation sont réunies sous « Hors traitement ».
- Le chip peut être désactivé pour retrouver la liste plate d'origine.

## 2026-07-11

### v0.19.18 — fonctionnel

#### Gouvernance unifiée des unités ingrédients (éditeur + IA + scan)

- **Source de vérité unique** : la gestion des unités repose sur un référentiel central (`nutrition_units`). Toute unité d'ingrédient saisie, générée par IA ou extraite par scan doit être résolue par ce référentiel avant d'être exploitée pour la nutrition.

- **Règle métier prioritaire** : la composition recette doit d'abord **piocher dans la liste du référentiel**. La création d'une nouvelle unité n'est autorisée qu'en **fallback** si aucune correspondance n'existe après normalisation.

- **Normalisation stricte anti-doublons** : différentes écritures d'une même unité doivent converger vers une forme canonique unique. Exemple attendu : `CAC`, `cac`, `c.C`, `C.c`, `c.a.c` et `cuillère à café` doivent toutes référencer la même unité canonique (`c_a_c`).

- **Fallback contrôlé** : lorsqu'une unité légitime absente du référentiel apparaît (ex: `tige`), elle est ajoutée automatiquement en entrée `unknown/pending_review` et réutilisée ensuite telle quelle (pas de duplication proche).

- **Couverture multi-canaux obligatoire** : ces règles s'appliquent uniformément à :
  - l'éditeur manuel d'ingrédients,
  - la génération de recettes via Gemini,
  - l'extraction/scan OCR,
  - les flux de backfill/recompute nutrition.

- **Traçabilité de résolution** : chaque graphie d'unité rencontrée est conservée dans le référentiel `nutrition_units` (`aliases`, `status`, `source`), avec sa provenance. Elle n'est **pas** recopiée sur chaque ingrédient de chaque recette : une recette ne stocke que ce qu'elle dit (`name`, `qty`, `unit`, `category`), la résolution se recalcule à la demande.

- **Contrôle qualité opérationnel** : l'admin doit pouvoir visualiser les unités inconnues, valider/fusionner les alias, et suivre la baisse des ingrédients non convertibles en nutrition.

### v0.19.18 — technique

#### Spécification technique — Gouvernance des unités ingrédients

##### Objectif

- Éliminer les divergences d'unités entre saisie manuelle, génération Gemini et import d'une page scannée.
- Garantir une résolution canonique des unités avant tout calcul nutrition.
- Réduire drastiquement les lignes nutrition sans score dues aux unités non reconnues.

##### Référentiel d'unités (source de vérité)

- Collection Firestore : `nutrition_units`.
- Une unité canonique = un document unique (`normalized_unit`).
- Champs attendus :
  - `normalized_unit: string`
  - `display_label: string`
  - `aliases: string[]`
  - `measurement_type: "weight" | "volume" | "count" | "unknown"`
  - `grams_per_unit?: number`
  - `volume_ml_per_unit?: number`
  - `status: "known" | "unknown" | "pending_review" | "deprecated"`
  - `source: "builtin" | "fallback_auto" | "admin_validated"`
  - `seen_count: number`
  - `first_seen_at`, `last_seen_at`, `updated_at`

**`grams_per_unit` n'existe que sur une unité de POIDS.** Deux types d'unités
n'ont pas de poids intrinsèque et n'en portent donc jamais :

| Type | Ce qui est stocké | Ce qui fait le poids |
|---|---|---|
| `volume` | `volume_ml_per_unit` | `ml × densité(ingrédient)` |
| `count` (« pièce ») | rien | `grams_per_piece` de l'**ingrédient** |

La règle valait pour le volume depuis l'incident de la cuillère à soupe (une
recette à l'huile figeait 13,8 g sur `c_a_s`, imposés ensuite au miel et à
l'eau). Elle manquait pour le comptage, avec la même conséquence en pire : le
premier ingrédient croisé en pièces — inconnu de la table, donc 100 g par
défaut — figeait `grams_per_unit: 100` sur `piece`, et **tout** ce qui se
compte à la pièce pesait dès lors 100 g. Un blanc d'œuf au lieu de 30 g, trois
échalotes 300 g au lieu de 90.

Le champ est désormais supprimé du document à chaque passage sur une unité de
comptage : les référentiels déjà pollués se réparent seuls, sans backfill. Les
deux implémentations (`resolveUnitFactorToGrams`, Dart et TypeScript) ignorent
en outre un tel poids s'il subsiste, et les cas correspondants sont asservis
dans `unit_to_grams.json`.

##### Poids du couple ingrédient / unité

La même maladie touche une famille entière d'unités : `branche`, `brin`, `tige`,
`feuille`, `bouquet`, `filet`, `noisette`, `zeste`, `tranche`, `poignee`,
`morceau`, `gousse` (`INGREDIENT_DEPENDENT_UNITS`). Aucune n'a de poids propre —
une branche de thym pèse 1 g, une branche de céleri 60 — et la table intégrée
n'en donnait qu'une moyenne : `branche: 15 g`, soit 60 g pour quatre branches de
thym, soixante fois le poids réel.

Le référentiel d'ingrédients porte donc `grams_per_unit: { branche: 1 }`, indexé
par unité canonique. L'ordre de résolution, tenu par une seule fonction partagée
et asservi par `unit_to_grams.json` :

1. `grams_per_unit[unité]` de l'**ingrédient** — le poids du couple ;
2. `grams_per_piece` de l'ingrédient, quand l'unité est « pièce » ou absente ;
3. `volume_ml_per_unit` × densité, pour un volume ;
4. `grams_per_unit` du référentiel d'**unités**, pour un poids ;
5. la table intégrée, en dernier recours.

Le poste d'IA `estimate_unit_couple_weights` alimente le niveau 1 à la
normalisation, en ne demandant que les couples encore inconnus.

##### Quantité absente : les assaisonnements

« sel, poivre » en fin de liste d'ingrédients n'écrit ni nombre ni unité, et
« une pincée de sel » s'écrit le plus souvent « sel, pincée » — l'unité seule,
sans le « une ». Le poids valant `quantité × poids d'une unité`, ces lignes
rendaient `null` **avant même** qu'on regarde l'unité, alors que la pincée vaut
0,5 g dans la table comme dans le référentiel. Deux « ? » s'affichaient, la
couverture restait partielle et la vue pour 100 g était masquée, pour un
demi-gramme sans calories.

`resolveWeighingInput` (Dart et TypeScript, asservie par `unit_to_grams.json`)
rend la quantité et l'unité réellement pesées. Trois cas, et rien d'autre :

1. la quantité se lit — rendue telle quelle, unité inchangée ;
2. elle manque sur une petite mesure à poids fixe (`pincee`,
   `pointe_de_couteau`) — on lit 1 ;
3. elle manque **avec** l'unité, sur un assaisonnement connu
   (`SEASONING_MATCHERS`) — on lit une pincée.

Tout le reste rend `null`. Une quantité absente devant « g » ou « c. à c. » est
une donnée abîmée, pas une convention d'écriture : lui prêter un 1 inventerait
un poids là où la recette attendait un nombre.

Le cas 3 rend l'unité `pincee`, pas une constante en grammes : la surcharge du
référentiel Firestore suit, et corriger le poids d'une pincée depuis
Admin → Unités corrige les trois cas d'un coup.

`SEASONING_MATCHERS` ne contient que ce qui se dose réellement par pincée —
épices, herbes séchées, mélanges secs. Les herbes fraîches en bouquet (persil,
basilic, menthe, coriandre) en sont absentes : elles pèsent trente grammes, pas
un demi, et une approximation soixante fois trop basse ne vaut pas mieux qu'une
case vide, elle la déguise. Les motifs se comparent **mot entier** sur la forme
canonique : « selle d'agneau » ne pèse pas une pincée parce qu'elle commence par
« sel ».

Le déclencheur de synchronisation applique la même lecture pour sa validation
des quantités, sans quoi l'écran d'administration continuerait de dénoncer
« sel » comme une quantité abîmée alors que le calcul, lui, aboutit. Sur
l'écran de détail, une pastille et une entrée de légende nomment les lignes
comptées ainsi : un demi-gramme non expliqué se lit comme une donnée de la
recette.

Rien à relancer pour les recettes déjà calculées : le rattrapage de 5 h reprend
toute recette dont `missing_ingredients` n'est pas vide, et ces lignes en
sortent. La correction **économise** des appels — une pincée de sel suffisait à
faire revenir la recette toutes les nuits.

##### Sel et sodium : une grandeur, pas deux apports

Le schéma d'enrichissement `per100g` réclame `sodium_mg` **et** `salt_g`. Le
modèle répond les deux, cohérents entre eux — c'est la même chose dans deux
unités, 1 g de sel valant 393,4 mg de sodium. `normalizeNutrients` les
**additionnait** : la conversion du sel était ajoutée au sodium déjà fourni,
puis le sel était recalculé depuis ce sodium doublé.

Tout ingrédient salé du référentiel portait donc deux fois son sel réel. Le sel
de table était stocké à 200 g pour 100 g, la sauce soja à 11 186 mg de sodium au
lieu de 5 500, le lait à 88 au lieu de 44. 1 167 des 1 247 ingrédients du
référentiel portent du sodium. Une portion d'ailes de poulet annonçait 10,3 g de
sel — deux jours d'apport recommandé.

Rien ne se levait, et rien ne paraissait incohérent : la seconde formule
reconstruisait un `salt_g` parfaitement accordé au sodium faux. Le défaut ne se
voyait qu'en comparant à une table de composition extérieure.

Le doublement frappait deux fois : à l'écriture du référentiel, puis à chaque
lecture, `recipeNutrition` renormalisant un profil déjà normalisé. La règle qui
manquait est celle-là — **une normalisation doit être un point fixe** —, et
c'est le test qui la garde aujourd'hui.

La règle est désormais : le sodium fait foi quand il est fourni, c'est la mesure
des tables de composition ; le sel n'en est qu'une conversion, et ne sert de
source que s'il est seul. Deux écritures d'un même nutriment ne s'additionnent
jamais non plus (`sodium` et `sodium_mg`, `kcal` et `calories`) : la forme
canonique gagne, sinon la première rencontrée.

`functions/src/tests/nutrients.test.ts` couvre les deux règles, l'idempotence et
le rejet des valeurs nulles. Cette fonction n'avait aucun test : c'est par là que
le défaut est passé.

###### Réparer les données déjà écrites

Corriger le code n'y suffit pas : après coup, un profil doublé est
**indistinguable** d'un profil juste, puisque la formule fautive les rendait
cohérents dans les deux cas. Aucune règle ne peut les séparer, et diviser par
deux au hasard reviendrait à fausser les profils sains.

Seule une nouvelle estimation répare. `backfillEnrichReferentialsFn` reçoit donc
un mode `refreshSodium` (Admin → Backfills, « Reprendre le sel des
ingrédients ») : au lieu des profils vides, il reprend ceux qui portent du
sodium, remplace la carte `per100g` entière — `set(merge)` fusionnerait champ par
champ et laisserait survivre l'ancienne valeur —, et saute la phase des poids
d'unités, étrangère au problème. Curseur de reprise distinct, et poste de coût
distinct (`backfill_refresh_sodium_per100g`) : cette dépense est ponctuelle et
massive, la noyer dans le rattrapage courant aurait rendu son montant
introuvable.

##### Zéro certain contre valeur inconnue

Le référentiel n'enregistre que les valeurs strictement positives : un profil ne
liste pas ses zéros. L'écran de détail traduisait cette absence par « - », qui se
lit « on ne sait pas ». Le sel affichait ainsi sept tirets pour sept zéros
certains — il n'a ni calories, ni protéines, ni glucides —, alors que le total,
lui, les additionnait déjà comme des zéros.

Les métriques affichées partent maintenant de zéro pour tout profil retenu comme
utilisable, et le profil les remplit. Un tiret ne subsiste que là où il n'y a
vraiment aucun profil.

##### Ingrédients non consommés

`nutrition_ingredients.not_consumed` marque ce qui appartient à la recette mais
pas au repas : bain de friture, foin ou sarment de fumage, lit de gros sel,
marinade jetée. Un litre d'huile de friture apporte 8280 kcal — compté comme le
reste, il rend le total de la recette inutilisable.

##### Huile absorbée à la friture

Écarter le bain est juste, mais incomplet : ce qu'on y plonge en ressort plus
gras. Un poulet pané au panko absorbe environ 10 % de son poids en huile — sur
600 g, 55 g de lipides et 500 kcal que la recette ne déclarait nulle part. La
couverture affichait « complet » et le plat mentait de 40 % sur ses lipides.

Le taux n'appartient pas au bain. La quantité d'huile écrite dans une recette
est arbitraire (« 1 L pour la friture ») : en garder un pourcentage ferait
dépendre le résultat de la façon dont l'auteur a rédigé sa ligne. Le taux
appartient à l'**aliment frit** ; le bain déclaré sert de **plafond** — on
n'absorbe pas plus d'huile qu'il n'y en a — et de source de profil, puisque
c'est lui qui dit quelle huile est employée. À défaut, une huile végétale
générique (900 kcal, 100 g de lipides, 13 g de saturés pour 100 g).

Reste à savoir *ce qui* est frit : la liste d'ingrédients ne le dit pas — dans
un poulet pané, le poulet, la farine, l'œuf et la chapelure passent au bain, la
salade servie à côté non. Seul le texte de la recette le dit, d'où le poste
`estimate_fry_absorption`, qui rend les indices des ingrédients frits et le
pourcentage absorbé (borné à 30 %).

L'appel n'est demandé que si `looksFried()` — déterministe, gratuit,
`fryAbsorption.test.ts` — repère un signe de friture dans `raw_cooklang` ou dans
les noms d'ingrédients. La recherche se fait par mots entiers : « frit » en
sous-chaîne attrape « frittata », qui est une omelette. Une panure seule ne
déclenche rien, le four existe.

Le verdict vit dans le snapshot (`fry_verdict`, `fry_signature`) et se réutilise
tant que la liste d'ingrédients et le texte n'ont pas changé. Il est stocké
**séparément de son résultat** (`absorbed_oil`) : un poids d'ingrédient qui
devient connu entre deux calculs doit produire de l'huile sans redemander le
verdict.

L'huile absorbée entre dans les totaux **et dans le poids total** — elle est
mangée, donc elle pèse dans le dénominateur des valeurs pour 100 g. Elle
n'entre pas dans la couverture : ce n'est pas un ingrédient. L'écran la montre
comme une ligne dérivée, en italique et marquée « estimée », qui dit son taux et
le poids frit dont il découle ; le tableau, qui refait ses totaux depuis les
lignes, la compte comme le serveur — sans quoi son TOTAL contredirait les
calories par portion affichées juste au-dessus.

Elle se range **sous le bain dont elle sort** (`↳ dont absorbée`), reconnu par
`source_name`, et ne tombe en fin de tableau que si la recette ne liste aucun
corps gras écarté. Les deux lignes se lisent alors comme une seule idée : on
jette le litre, on mange les 55 g.

##### Quantité de repli des matières grasses de cuisson

« Huile pour graisser le fond du plat » n'a pas de quantité et n'en aura jamais :
c'est un geste, pas une pesée. Sans quantité, l'ingrédient sort du calcul — une
centaine de kilocalories manquantes que rien ne signale.

`defaultQuantityForMissing` applique donc, à la normalisation et **hors de toute
dépendance à l'IA**, une quantité de repli : 1 c.à.s. pour les huiles et corps
gras, 1 noisette pour le beurre et la margarine. La valeur est écrite dans la
recette (elle apparaît donc dans la liste d'ingrédients), pas seulement dans le
calcul.

La liste est délibérément courte. Une absence de quantité a souvent un sens : un
« poulet » listé sans quantité peut être l'intitulé d'une pièce dont la découpe
est chiffrée plus bas, et lui inventer un poids fausserait la recette entière.
Le repli ne couvre que les matières grasses de fond de plat ; `defaultQuantities.test.ts`
garde cette frontière dans les deux sens.

##### Lignes qui reprennent un ingrédient déjà listé

Une recette qui achète 1,5 kg de côte puis en dresse « 4 tranches de viande »
décrit le même aliment à deux stades ; le calcul additionnait les deux et
doublait les apports.

Un poste d'IA — `detect_duplicate_ingredients` — lisait la liste complète et
désignait les reprises. Il n'existe plus. Il rattrapait une conséquence du
balisage inline : tant que la liste du livre n'était jamais transcrite, chaque
ingrédient devait être balisé quelque part dans les étapes, et le même aliment
finissait déclaré deux fois. La transcription en deux passes recopie la liste du
livre telle quelle, et le prompt interdit le double balisage. La cause a
disparu, la rustine avec elle. Le poste reste au **catalogue comptable**, pour
que les mois déjà comptabilisés continuent de le nommer, mais il a quitté
`ROUTABLE_FEATURES` : plus aucun appel ne l'emprunte.

Les verdicts déjà écrits sont conservés et relus. Le snapshot garde
`duplicate_ingredients`, `duplicate_indices` et la **signature** de la liste qui
les a produits : une recette importée avant ce changement continue d'écarter ses
reprises, sans qu'aucun appel ne soit passé. Rien n'est écrit sur
`recipes.ingredients` — une reprise n'est pas une propriété de l'ingrédient,
elle n'existe que dans cette recette-ci.

Ces ingrédients sortent des totaux, du poids total **et du dénominateur de
couverture** : les compter comme manquants ferait passer pour incomplète une
recette qui ne l'est pas. Ils restent listés dans
`nutrition.not_consumed_ingredients` et s'affichent dans le tableau, atténués et
marqués — un ingrédient qui disparaît sans explication est précisément ce que ce
tableau doit éviter. Le poste `detect_not_consumed` renseigne le champ une seule
fois par ingrédient, et le doute profite au calcul (`true` par défaut).

##### Contrat ingrédient (recette)

Un ingrédient de `recipes.ingredients` porte **ce que la recette dit**, et rien d'autre :

- `name`, `qty`, `unit` (l'unité telle qu'écrite / affichée)
- `category?` — la section CookLang (`== Pour la pâte ==`) dont il relève
- `note?` — ce que la ligne du livre dit **en plus** de la quantité

**Une ligne du livre peut nommer DEUX ingrédients.** « 2 cuil. à café de moutarde à
l'ancienne mélangée à 2 cuil. à café de miel » est un achat de moutarde **et** un achat de
miel. La règle « une ligne, une entrée » obligeait à en choisir un, et le second sortait de
la liste de courses comme du calcul nutritionnel sans qu'aucune erreur ne soit levée. Deux
entrées portent alors la même ligne en `brut`, et le lien entre elles vit dans la `note`.
Le contrôle vérifie donc une **couverture**, pas une égalité — et il compte les occurrences :
« 1 bouquet d'aneth » présent dans deux sections demande deux entrées, sans quoi la fusion
que ce contrôle traque passerait inaperçue.

**La note se CALCULE quand le modèle la laisse vide** — `nutrition/ingredientNote.ts`,
`noteFromRawLine`. Constater son absence ne suffisait pas : « avec la peau mais écaillée »
est écrit dans le livre et doit finir dans la recette. C'est ce que la ligne dit **après**
avoir nommé l'aliment et sa quantité — une soustraction, pas un jugement. La proposition du
modèle reste prioritaire quand il en fait une : il sait reformuler un lien (« mélangée au
miel ») là où la soustraction rend une bribe. Deux choix décident du résultat : on prend ce
qui **suit** le dernier élément identifié et non ce qui reste après découpage — recoller les
morceaux rendait « 1 de avec la peau mais écaillée », les trous du milieu se refermant sur
des articles orphelins ; et la ponctuation n'est retirée qu'aux bords, pour que « cuil. à
café » garde son point. Contrainte inverse, testée mot à mot : **chaque mot rendu vient de la
ligne**. Une note inventée serait pire que pas de note, parce qu'on la croirait.

**`note` n'est pas un commentaire, c'est la moitié de la ligne.** « 1 filet de
saumon de 1,8 kg avec la peau mais écaillée » se sépare en une quantité, qui se
compte, et une précision, qui se lit. Cette précision ne vivait nulle part :
aucune accolade CookLang ne peut la porter, et le modèle réécrivait la phrase du
livre pour la caser — c'est l'un des mécanismes par lesquels une recette
s'écartait de son original. La transcription la sépare à la source ; elle est
transportée sans être interprétée, ni par la normalisation, ni par le
redimensionnement (« avec la peau mais écaillée » reste vrai pour deux parts
comme pour douze), ni par l'éditeur, qui ne propose délibérément pas de champ
pour elle — la retoucher dans un formulaire de quantités inviterait à la
réécrire.

**Aucune forme résolue n'est persistée sur la recette.** `unit_raw`,
`unit_canonical`, `unit_resolution_*` et l'identité référentielle
(`ingredient_ref_id`, `ingredient_ref_status`, `ingredient_canonical_name`,
`ingredient_resolution_*`) sont des intermédiaires de calcul : ils se
recalculent depuis `name` et `unit` partout où ils servent, de façon
déterministe. Les stocker créait un champ que plusieurs traitements se
disputaient et que personne ne relisait — la resynchronisation nutrition
effaçait ainsi la catégorie écrite par la normalisation quelques secondes plus
tôt.

La traçabilité de résolution vit dans `nutrition_units` — chaque graphie
observée y est enregistrée en `aliases`, avec `status` et `source` — et non
recopiée sur chaque ligne de chaque recette.

**Un seul écrivain pour `recipes.ingredients` : la normalisation référentiels.**
Les déclencheurs (nutrition, liste de courses) écrivent leurs propres champs
(`nutrition`, `nutrition_validation`, `shopping_products`) et n'y touchent pas.

**Et réciproquement : la normalisation ne calcule pas la nutrition.** Elle l'a
longtemps fait, ce qui produisait deux défauts d'un coup. Le contrat ci-dessus
n'était pas tenu — deux écrivains pour `nutrition` — et surtout le calcul
tombait au mauvais moment : à l'édition d'une recette, le client appelle la
normalisation **avant** d'écrire, or `computeAndPersistRecipeNutrition` relit le
document depuis Firestore. Elle calculait donc sur la version d'avant la
modification et posait sur la recette une nutrition périmée, que le déclencheur
remplaçait quelques secondes plus tard.

La séparation est donc :

| Étape | Qui | Ce qu'elle fait |
|---|---|---|
| 1. Avant l'écriture | `normalizeRecipeReferentialsCore` | résout unités et identités, et enrichit ce que la recette ne dit pas : poids d'une pièce, poids d'un couple ingrédient/unité, ingrédients non consommés. Ne touche ni au texte, ni à `nutrition`. La singularisation des unités et la complétion des quantités en sont parties : la passe 2 de l'extraction lit la liste du livre, où l'unité et la quantité **sont écrites** — les deviner reviendrait à ignorer ce qu'on a sous les yeux. |
| 2. L'écriture | client ou `recipeProcessor` | écrit la recette normalisée |
| 3. Après l'écriture | `onRecipeWritten` | enrichit **poids d'unités et `per100g`**, puis calcule `nutrition` et `shopping_products` |

###### Un enrichissement, un seul propriétaire

Deux passes vivaient des deux côtés : `enrichUnknownUnitsWithAI` et
`enrichUnknownIngredientsWithAI`. La justification tenait sur le papier — ces
fonctions ne traitent que les entrées **dépourvues** de valeur, donc le second
passage ne trouve rien à faire.

Elle est fausse dès qu'on regarde l'horloge. À l'import, `recipeProcessor`
écrivait la recette **puis** la normalisait ; l'écriture réveillait
`onRecipeWritten`, qui partait en parallèle. Les deux lisent le référentiel au même instant, y trouvent le
même vide, et posent au modèle la même question. Le second n'arrive pas après le
premier : il arrive **avec** lui. Résultat : chaque unité et chaque ingrédient
inconnu payés deux fois, et un journal où la même passe apparaît en double sans
qu'on puisse dire laquelle a servi.

Les deux passes appartiennent désormais au **déclencheur, et à lui seul**. C'est
le bon propriétaire pour deux raisons : il part sur **toutes** les écritures de
recette — import, saisie manuelle, modification — là où la normalisation n'est
qu'un chemin parmi d'autres ; et c'est lui qui a besoin de ces valeurs,
immédiatement après, pour convertir les quantités et calculer la nutrition.
Enrichir ailleurs, c'est enrichir trop tôt ou deux fois.

La nutrition reste juste dès le premier affichage : le déclencheur enrichit et
calcule dans la même exécution, dans cet ordre.

**`recipes.nutrition_stale` et `recipes.nutrition_enrichment_attempts` ont
disparu.** Ils bornaient les réveils que le déclencheur se provoquait à
lui-même. La garde porte désormais sur ses entrées — voir « La garde porte sur
les entrées, jamais sur la sortie » — les réveils n'ont plus lieu, et deux
champs de contrôle qui ne contrôlaient rien ont quitté le schéma.

##### Pipeline obligatoire de résolution unité

1. **Normalisation stricte**
  - lowercase, trim, suppression accents.
  - suppression ponctuation / séparateurs non significatifs.
  - uniformisation des graphies abrégées.

2. **Résolution référentiel**
  - lookup exact sur `normalized_unit` puis `aliases`.
  - mapping synonymes contrôlés (table canonique backend).

3. **Fallback contrôlé**
  - uniquement si échec des étapes précédentes.
  - création d'une entrée unique `unknown/pending_review` dans `nutrition_units`.
  - jamais de création de doublon proche d'une unité connue.

4. **Persist dans le référentiel, pas sur la recette**
  - écrire la graphie observée dans `nutrition_units.aliases`, avec `status` et `source`.
  - ne rien écrire de résolu sur `recipes.ingredients` (cf. contrat ingrédient).

##### Règles anti-doublons (exigence critique)

- Les variantes `CAC`, `cac`, `c.C`, `C.c`, `c.a.c`, `c à c`, `cuillère à café` doivent toutes converger vers `c_a_c`.
- Les variantes `CAS`, `c.a.s`, `c à s`, `cuillère à soupe` doivent toutes converger vers `c_a_s`.
- Une nouvelle entrée ne doit pas être créée si une unité canonique existante correspond déjà après normalisation.

##### Intégration par canal

- **Éditeur Flutter** : l'autocomplete unité doit être alimenté par `nutrition_units` et proposer en priorité les unités `known`.
- **Gemini génération** : le prompt doit imposer un catalogue d'unités canoniques ; la sortie doit rester soumise au pipeline backend de résolution.
- **Import d'une page scannée** : la sortie de la transcription doit passer par le même pipeline backend.
- **Backfill** : ré-analyse des unités historiques avec fusion/normalisation vers canoniques.

##### Administration

- Écran admin unités requis avec :
  - liste des unités `unknown/pending_review`,
  - actions de fusion alias -> canonique,
  - validation des conversions (`grams_per_unit`, `measurement_type`),
  - journal des résolutions.

##### Indicateurs/KPI de pilotage

- Taux d'ingrédients convertibles nutrition.
- Nombre de nouvelles unités fallback/jour.
- Nombre d'unités inconnues non traitées.
- Taux de lignes nutrition sans score par recette.

##### Critères d'acceptation

1. Même ingrédient/unité, quelle que soit la source (éditeur/Gemini/scan), se résout vers le même `normalized_unit` de `nutrition_units`.
2. Les variantes de `cuillère à café` ne créent pas de nouvelles unités.
3. Une unité réellement nouvelle (ex: `tige`) crée une seule entrée fallback réutilisable.
4. Le taux de lignes nutrition à `-` diminue après migration/backfill.

##### Plan de livraison recommandé

- **Lot 1 (backend)** : normalisation stricte + résolution référentiel + fallback contrôlé.
- **Lot 2 (Flutter)** : autocomplete dynamique sur référentiel + feedback de résolution.
- **Lot 3 (Gemini/scan)** : prompts contraints + post-traitement unifié.
- **Lot 4 (ops/admin)** : écran de revue unités + backfill historique + KPI.

## 2026-07-05

### v0.18.0 — fonctionnel

#### Stabilisation de release multi-plateforme

- **Version applicative harmonisée** : la version affichée dans la documentation produit et les supports d'installation est alignée sur **v0.18.0** pour éviter toute ambiguïté entre web, mobile et desktop.
- **Diffusion cohérente** : la release est préparée pour les trois canaux cibles (mobile Android/iOS, web et desktop Windows) avec le pipeline standard de déploiement.

### v0.18.0 — technique

#### Client Flutter — Version

- **`pubspec.yaml`** : version `0.18.0+1`.

#### Release engineering

- **Build desktop Windows** : génération en mode release (`flutter build windows --release`) pour alimenter le livrable desktop.
- **Déploiement unifié** : publication via le script racine `deploy.ps1` pour conserver un chemin de release unique et reproductible.

## 2026-07-04

### v0.17.0 — fonctionnel

#### Retouche image — expérience unifiée

- **Atelier de retouche unique** : les actions de retouche photo sont regroupées dans un seul écran « Atelier de retouche », avec un parcours cohérent au lieu d'actions dispersées (recadrage d'un côté, couleur de l'autre).
- **Panneaux orientés intention** : l'atelier expose des sections claires côté utilisateur : **Cadre**, **Lumière**, **Détails**, **Presets**.
- **Comparaison avant/après** : l'utilisateur peut comparer l'original et la retouche en appui long (ou via bascule) sans quitter l'écran.
- **Historique immédiat** : l'atelier propose **Annuler / Refaire** pour sécuriser les essais et réduire la peur de se tromper.
- **Presets intelligents** : des presets rapides sont proposés avec une recommandation automatique basée sur l'analyse locale de l'image (lisibilité, naturel, couleurs pop, doux).
- **Point d'entrée simplifié dans les galeries** : dans les onglets photos des écrans d'édition/révision, une seule action **Retoucher** remplace les boutons dispersés Crop/Couleur.

### v0.17.0 — technique

#### Client Flutter — Version

- **`pubspec.yaml`** : version `0.17.0+1`.

#### Retouche image — Atelier unifié

- **`lib/core/presentation/image_enhancer_screen.dart`** :
  - Nouveau mode `EnhancerMode.studio` (mode par défaut) en plus des modes compatibles `crop` et `color`.
  - UI restructurée en panneaux `Cadre`, `Lumière`, `Détails`, `Presets`.
  - Ajout d'un mode comparaison **avant/après** (appui long + toggle).
  - Ajout d'un historique local **undo/redo** basé sur snapshots d'état (image, coins, réglages).
  - Ajout des réglages `contrast` et `saturation` en plus de `brightness` et `sharpen`.

- **`lib/core/presentation/image_enhancer_processing.dart`** :
  - `WarpParams` étendu avec `contrast` et `saturation`.
  - Pipeline `warpIsolate` mis à jour pour appliquer `adjustColor(brightness, contrast, saturation)` avant netteté.
  - Ajout d'une analyse locale légère (`analyzeImageStatsIsolate`) pour suggérer un preset intelligent.

- **`lib/core/presentation/image_action_card.dart`** :
  - Simplification des actions en une entrée **Retoucher** ouvrant l'atelier unifié.

- **`lib/features/recipes/presentation/drafts/draft_review_widgets.dart`** :
  - Remplacement des actions séparées `onCrop` / `onColor` par une action unique `onEdit`.

- **`lib/features/recipes/presentation/drafts/draft_review_body.dart`**,
  **`lib/features/recipes/presentation/drafts/draft_review_screen.dart`**,
  **`lib/features/recipes/presentation/edit/recipe_edit_screen.dart`** :
  - Raccordement des boutons photos à `EnhancerMode.studio`.
  - Titre overlay harmonisé (« Atelier de retouche »).

## 2026-06-28

### v0.15.90 — fonctionnel

#### Traçabilité des fichiers rejetés par le scan de sécurité

- **Job au statut « Rejeté »** : lorsqu'un fichier importé (recette, couverture ou document de livre) est bloqué par le scan de sécurité, une entrée est désormais créée dans l'écran « Brouillons & Traitements » avec le statut **Rejeté** (badge rouge). Auparavant, le motif du blocage n'était affiché qu'éphémèrement à l'utilisateur et n'était conservé nulle part de consultable dans l'application.
- **Motif visible** : chaque entrée rejetée affiche le nom du fichier, son type et la **raison du rejet** retournée par le scan (incohérence de format, type non autorisé, signature antivirus, etc.). Le détail est consultable et copiable via un appui long.
- **Actions** : seule l'action **Supprimer** est proposée sur une entrée rejetée (pas de **Relancer**, car re-scanner le même fichier produirait le même rejet). Le fichier source reste en quarantaine et n'est pas exposé.

## 2026-06-02

### v0.15.31 — fonctionnel

#### Sécurité — Corrections de règles et nettoyage

- **Notes de recettes (`recipe_ratings`) — création restreinte** : la règle Firestore `allow create` sur la collection `recipe_ratings` exige désormais que le champ `user_id` du document créé corresponde à l'uid de l'utilisateur connecté (`request.resource.data.user_id == request.auth.uid`). Auparavant, un utilisateur authentifié pouvait créer une note avec l'identifiant d'un autre utilisateur.

- **CORS Cloud Functions restreint** : les fonctions HTTPS Callable (wrappers Gemini et admin) n'acceptent plus toutes les origines (`cors: true`) mais uniquement les domaines Firebase connus : `kassdale-6d948.web.app` et `kassdale-6d948.firebaseapp.com`.

#### Nettoyage — Code mort PWA retiré

- **Suppression du système d'installation PWA programmatique** : les fichiers `web_install.dart`, `web_install_web.dart` et `web_install_stub.dart` ont été supprimés. Ces fichiers exposaient `isPwaInstallAvailable()` et `triggerPwaInstall()` mais n'étaient importés nulle part dans l'UI. La capture de `window._pwaPrompt` dans `index.html` a également été retirée. Chrome gère nativement l'installation PWA via sa bannière `beforeinstallprompt` sans intervention Flutter.

### v0.15.31 — technique

#### Sécurité — Firestore Rules

- **`recipe_ratings` — `allow create` restreint** :
  ```
  allow create: if isAuthenticated() && request.resource.data.user_id == request.auth.uid;
  ```
  Avant : `allow create: if isAuthenticated();` — un utilisateur pouvait écrire un document avec le `user_id` d'un autre. Corrigé en ajoutant la vérification d'appartenance.

#### Sécurité — Cloud Functions CORS

- **`cors: true` → liste blanche** dans `geminiCallables.ts` et `deadLetterHandler.ts` :
  ```typescript
  const ALLOWED_ORIGINS = [
    "https://kassdale-6d948.web.app",
    "https://kassdale-6d948.firebaseapp.com",
  ];
  ```
  Les fonctions callable ne répondent plus qu'aux origines connues.

#### Nettoyage — PWA install programmatique supprimé

- **Fichiers supprimés** : `lib/core/utils/web_install.dart`, `web_install_web.dart`, `web_install_stub.dart`. Ces fichiers n'étaient référencés nulle part dans l'UI (jamais importés).

- **`web/index.html`** : suppression de `window._pwaPrompt` et du listener `beforeinstallprompt`. Le navigateur affiche nativement sa bannière d'installation sans capture JS supplémentaire. Le bloc service worker (skip-waiting, controllerchange, update) est conservé intact.

#### Client Flutter — Version

- **`pubspec.yaml`** : version `0.15.31+1`.
- **`lib/core/app_version.dart`** : `kAppVersion = '0.15.31'`.

## 2026-06-01

### v0.15.29 — fonctionnel

#### Distribution & Installation de l'application

- **Téléchargement de l'APK depuis le web (Android)** : sur la version web ouverte sur Android, un bandeau ou une vérification automatique au lancement détecte si une mise à jour est disponible. Le téléchargement de l'APK est déclenché via un lien direct servi par Firebase Hosting (`/app-release.apk`) avec les headers HTTP corrects (`Content-Type: application/vnd.android.package-archive`, `Content-Disposition: attachment; filename="kass-dalle.apk"`). Le fichier se télécharge directement dans le dossier Téléchargements du téléphone.

- **Installation PWA (Progressive Web App) native** : sur Chrome Android et Chrome Desktop, le mécanisme standard `beforeinstallprompt` du navigateur est utilisé. L'événement est capturé dans `index.html` **sans** appel à `preventDefault()`, ce qui laisse Chrome afficher sa propre bannière d'installation native. Aucune interface personnalisée n'est imposée — l'utilisateur voit la proposition d'installation standard du navigateur au moment opportun.

#### Export PDF

- **Export d'une recette en PDF imprimable** : depuis la fiche d'une recette validée, un bouton PDF (icône dans l'AppBar) permet d'exporter la recette au format PDF. L'export génère un document paginé avec : entête coloré (orange profond), titre, métadonnées (portions, difficulté, temps), liste des ingrédients, étapes numérotées, et optionnellement les photos de la recette. Un dialogue demande à l'utilisateur s'il souhaite inclure les images avant génération.

- **Positionnement des images dans le PDF** : les images sont positionnées selon leur marqueur dans le texte CookLang (`![left|40%](url)`, `![right|30%](url)`, `![after|80%](url)`). Le PDF respecte l'alignement gauche/droite/centré et le pourcentage de largeur déclaré dans le contenu.

- **Snackbar "Ouvrir" après export PDF sur mobile** : après génération et partage du PDF (via la share sheet système Android/iOS), un snackbar succès affiché pendant 8 secondes propose un bouton **OUVRIR** permettant de ré-ouvrir la share sheet avec le même document. Ce bouton n'apparaît que sur les plateformes mobiles natives (non-web) ; sur web, le PDF est déjà dans les Téléchargements du navigateur et aucun bouton supplémentaire n'est affiché.

#### Éditeur de recettes — Mode visuel (WYSIWYG)

- **Éditeur hybride CookLang** : l'éditeur de brouillon propose trois modes via des icônes de toggle : **Texte** (saisie CookLang brute avec coloration syntaxique), **Visuel** (édition bloc-par-bloc WYSIWYG), et **Aperçu** (rendu final de la recette). Le mode peut être changé à tout moment.

- **Édition bloc-par-bloc** : en mode visuel, chaque ligne ou section du CookLang est un bloc cliquable et éditable inline. Les types de blocs supportés : titre, ingrédient (`@nom{quantité}`), ustensile (`#outil{}`), section (`== Titre ==`), étape, conseil/note (`> texte`), commentaire (`-- texte`), image (`![pos|width](url)`).

- **Toolbar d'insertion** : une barre d'outils flottante permet d'insérer au curseur : section, étape, ingrédient, ustensile, conseil, liste, image (avec sélection depuis la galerie du brouillon). Chaque insertion se positionne précisément à la ligne active.

- **Réordonnancement par drag-and-drop** : les blocs peuvent être réordonnés par glisser-déposer dans l'éditeur visuel, modifiant directement l'ordre dans le CookLang sous-jacent.

- **Insertion d'images avec choix de position et largeur** : lors de l'insertion d'une image depuis la galerie, l'utilisateur choisit le positionnement (gauche / droite / après / pleine largeur) et la largeur en pourcentage (5 % à 80 %) via des `ChoiceChip`. Le tag CookLang correspondant est généré automatiquement.

- **Enter pour diviser un bloc** : dans l'éditeur visuel, appuyer sur Entrée dans un bloc le divise en deux blocs distincts. Un bouton de suppression de ligne (icône corbeille) est disponible sur chaque bloc.

#### Éditeur Markdown — Pages non-recette

- **Éditeur Markdown riche** : les pages non-recette (techniques culinaires, méthodes, notes) disposent d'un éditeur Markdown dédié avec toolbar : titres (H1/H2/H3), gras, italique, souligné, listes à puces, insertion d'images avec position (gauche/droite/après) et largeur en %.

- **Sélecteur de type de page** : dans l'éditeur d'un brouillon, un sélecteur permet de qualifier le type de contenu : recette structurée, page de technique, méthode, note ou autre. Ce choix influe sur le rendu affiché (vue recette CookLang vs aperçu Markdown), les champs du formulaire visibles, et le comportement du prompt IA.

- **Aperçu Markdown intégré** : un onglet Aperçu affiche le contenu Markdown rendu typographiquement avec les illustrations intercalées à leurs positions déclarées.

#### Bibliothèque de livres

- **Effet 3D sur les couvertures** : les vignettes de couverture de livres affichent un effet livre 3D avec ombres portées, tranche simulée et vernis. Ce rendu est appliqué à la liste des livres et à l'écran de détail.

- **Livres système avec couvertures par défaut** : les livres système (KassDalle, Recettes libres) disposent de couvertures illustrées par des assets locaux. Si aucune couverture personnalisée n'est définie, l'asset par défaut est utilisé.

- **Filtre de contenu dans un livre** : dans l'écran d'un livre, un `SegmentedButton` permet de filtrer l'affichage : Tout / Recettes / Autre (pages non-recette). Ce filtre remplace l'ancien bouton cyclique.

- **Sélection multiple** : un appui long sur un livre ou une recette libre active le mode sélection multiple. L'AppBar contextuelle propose "Tout sélectionner" et "Supprimer" (avec confirmation). La sélection est limitée aux éléments de l'utilisateur connecté.

#### Planning des repas — Améliorations

- **Préférences planning accessibles depuis le profil** : les préférences de planning (nombre de repas, contraintes, heures) sont accessibles depuis l'écran Profil en plus de l'icône engrenage dans l'écran Planning.

- **Sections repliables dans les préférences** : les sections de configuration du planning (contraintes globales, contraintes par jour) sont repliables pour simplifier l'interface.

- **Justification IA des suggestions** : lors d'une suggestion IA de planning, chaque repas proposé affiche la justification du choix IA (pourquoi cette recette à ce moment).

- **Sélection des sources pour les suggestions** : lors du batch planning, l'utilisateur peut sélectionner quels livres ou sources doivent être utilisés par l'IA pour les suggestions.

#### Écran Explorer (Recherche & Création)

- **Refonte en écran Explorer** : l'écran de recherche est renommé « Explorer » et propose trois actions clairement distinctes : **Chercher** (recherche dans la base), **Créer** (génération IA d'une nouvelle recette), **Web** (recherche web). La saisie du texte et la validation par Enter déclenchent la recherche.

- **Tri par pertinence** : les résultats de recherche sont triés par score de pertinence décroissant.

- **Diff des modifications après raffinement IA** : après un raffinement IA d'une recette, un écran de diff affiche les modifications apportées (ajouts en vert, suppressions en rouge) permettant de valider ou annuler avant sauvegarde.

- **Sauvegarde directe d'une recette générée par IA** : depuis l'écran de génération IA, la sauvegarde d'une recette validée crée directement la recette sans passer par un brouillon intermédiaire, et navigue vers la fiche de la recette créée.

#### Pipeline image — Améliorations qualité

- **Traitement Sharp côté serveur** : avant l'envoi à Gemini pour l'extraction de couverture ou la détection d'illustrations, les images passent par un pré-traitement Sharp (deskew, CLAHE, normalisation des niveaux) côté Cloud Function pour améliorer la lisibilité des scans.

- **Compression mobile** : sur Android/iOS, `flutter_image_compress` est utilisé pour réduire la taille des photos avant upload, avec un plafond configurable. Les thumbnails sont générés au format WebP.

- **Quality gate Gemini** : avant d'envoyer une image à Gemini pour l'analyse, un score de qualité est calculé (netteté, luminosité, contraste). Si le score est insuffisant, un avertissement est affiché à l'utilisateur avant de continuer.

#### Comptabilité & Suivi IA

- **Page Comptabilité** : accessible depuis le menu Admin, cette page présente deux onglets : **GCP** (coûts Cloud Functions, Storage, Tasks issus de BigQuery) et **Gemini** (tableau croisé coûts Gemini par utilisateur × feature × période mensuelle). Chaque ligne du tableau Gemini affiche le nombre d'appels, le volume de tokens et le coût estimé en euros.

- **Suivi usage tokens par feature** : l'écran "Usage IA" affiche un tableau filtrable par période mensuelle, avec une colonne "Période" pour l'agrégation. Un bandeau résume la période active. Une estimation de l'énergie consommée (en Wh) est calculée à partir du nombre total de tokens.

- **Backfill historique améliorations images** : une Cloud Function `backfillEnhanceUsageFn` scanne le Storage et reconstruit les données d'usage des améliorations d'images manquantes. Un bouton "Reconstruire données images" est disponible dans la page Comptabilité (admin).

### v0.15.29 — technique

git 
#### Client Flutter — Version

- **`pubspec.yaml`** : version `0.15.29+1`.
- **`lib/core/app_version.dart`** : `kAppVersion = '0.15.29'`.

#### Export PDF (`lib/core/services/`)

- **`recipe_pdf_export.dart`** :
  - `exportRecipeToPdf(Recipe, {bool includeImages})` retourne désormais `Future<({Uint8List bytes, String filename})>` au lieu de `Future<void>`. Le téléchargement est toujours effectué en interne (appel à `downloadPdf`), mais les bytes et le nom de fichier sont retournés pour permettre une réouverture post-export.
  - `openPdf(Uint8List bytes, String filename)` : nouvelle fonction publique qui appelle `downloadPdf` — permet de ré-ouvrir le share sheet mobile depuis un snackbar.
  - Import conditionnel : `pdf_download_stub.dart` si (dart.library.html) → `pdf_download_web.dart`.
  - **Le dialogue d'export porte sur TOUT ce que la recette ajoute à sa méthode**, pas seulement sur les photos. `PdfExtraCounts.of(recipe, annotations)` compte les photos et les annotations **par type** ; le dialogue n'affiche un interrupteur que pour ce qui existe. Une case « Inclure les astuces » sur une recette qui n'en a aucune est un réglage sans objet, et laisse croire qu'il manque quelque chose au document. Quand la recette ne porte rien de plus, le dialogue n'apparaît pas : il ne sert qu'à trancher.
  - `PdfExportChoice` porte les quatre décisions et `keeps(AnnotationType)` fait le tri. Les préférences (`pdf_include_images`, `pdf_include_notes`, `pdf_include_tips`, `pdf_include_corrections`) ne sont écrites que pour les catégories **réellement proposées** : une case absente de ce dialogue-ci ne doit pas écraser le choix d'un autre export.
  - **Les annotations sont lues avant le dialogue, et un échec de lecture annule l'export.** Un PDF amputé de ses astuces sans que rien ne le dise est pire qu'un export refusé — c'est la même règle que le repli tarifaire : un manque se voit, une valeur fausse ne se voit pas.
  - **La note de celui qui imprime s'affiche à côté du titre** — sa note personnelle sur 10, pas une moyenne. Le dénominateur est écrit : à l'écran, « ★ 8 » se comprend parce que le sélecteur de note est à un doigt ; sur une feuille posée sur un plan de travail, rien ne dit si l'échelle va à cinq ou à dix.
  - **L'étoile est une `pw.Polygon` à dix points, pas un caractère.** Les polices du document sont les Helvetica intégrées au format PDF, qui s'arrêtent à Latin-1 : ★ (U+2605) n'y existe pas et sortirait en case vide. Embarquer une police pour un seul glyphe coûterait quelques centaines de kilo-octets par fichier ; le document reste entièrement hors-ligne.
  - `buildRecipePdfBytes` est **public** et séparé du téléchargement, pour que `test/pdf_export_extras_test.dart` compose vraiment le document. C'est ce test qui a révélé que l'en-tête portait depuis toujours une `BoxDecoration` interdite — un liseré gauche **et** un rayon de coin, que le paquet `pdf` refuse par assertion. Elle ne se voyait pas : les assertions sont retirées du binaire de production, où la bordure était simplement dessinée de travers. Le rayon a été retiré.

- **`pdf_download_stub.dart`** (mobile/desktop) : `downloadPdf` = `Printing.sharePdf(bytes: bytes, filename: filename)` — ouvre la share sheet système.
- **`pdf_download_web.dart`** (web) : crée un `Blob` → `<a href download>` → click → revoke URL.

#### Distribution APK — Firebase Hosting

- **`firebase.json`** — bloc `headers` pour l'APK :
  ```json
  {
    "source": "/app-release.apk",
    "headers": [
      { "key": "Content-Type", "value": "application/vnd.android.package-archive" },
      { "key": "Content-Disposition", "value": "attachment; filename=\"kass-dalle.apk\"" }
    ]
  }
  ```
  Ce bloc permet au navigateur Android de déclencher le téléchargement du fichier sans l'ouvrir en ligne.

#### Installation PWA — `web/index.html`

- L'événement `beforeinstallprompt` est **non intercepté** (`e.preventDefault()` absent) : Chrome affiche sa propre bannière d'installation native au moment qu'il juge opportun. Aucun code Flutter ne déclenche ni ne contrôle cette bannière. Les fichiers `web_install*.dart` ont été supprimés (code mort).

#### Mise à jour applicative (`lib/core/presentation/app_shell.dart`)

- `_checkForUpdate()` : sur la version web (`kIsWeb`), la vérification est court-circuitée (`return`) — Chrome gère nativement l'installation PWA. Sur Android natif, la fonction appelle `checkForAppUpdate()` et affiche un dialogue de mise à jour si une nouvelle version est disponible.

#### Snackbar PDF (`lib/features/recipes/presentation/detail/recipe_detail_screen.dart`)

- `_exportPdf()` : après `exportRecipeToPdf`, le snackbar succès (`duration: 8s`) affiche un `SnackBarAction(label: 'Ouvrir')` uniquement si `PlatformUtils.isMobile` (Android/iOS natif). L'action appelle `openPdf(result.bytes, result.filename)` pour ré-ouvrir la share sheet.

#### Éditeur visuel CookLang (`lib/features/recipes/presentation/`)

- **`cooklang_visual_editor.dart`** : éditeur bloc-par-bloc. Chaque bloc est une instance de `BlockType` (section, step, ingredient, utensil, note, image, comment, etc.). L'édition inline se fait via `TextField` focusés dynamiquement. Enter dans un bloc le divise. La sauvegarde écrit le CookLang reconstitué dans Firestore.

- **`hybrid_recipe_editor.dart`** : toggle 3 modes (Texte / Visuel / Aperçu) via `SegmentedButton` ou icônes. Le mode est persisté dans `SharedPreferences`.

#### Éditeur Markdown pages non-recette

- **`markdown_page_editor.dart`** (nouveau) : `TextField` multiligne avec toolbar (H1/H2/H3/B/I/U/liste/image). Insertion d'images depuis la galerie du brouillon avec sélection position+largeur via `AlertDialog` + `ChoiceChip`.

- **Sélecteur de type de page** : `PageType` enum (`recipe`, `technique`, `equipment`, `ingredientNote`, `other`) stocké dans le champ Firestore `page_type` sous sa forme à souligné (`ingredient_note`). Le prompt Gemini de classification utilise un pipeline en 2 appels : classify (chain-of-thought + reasoning) puis extract.
  - **Un seul mapping libellé → type**, `parsePageTypeLabel`, côté Dart comme côté TypeScript. Il accepte les trois graphies qui circulent réellement pour la note d'ingrédient : `ingredient_note` (Firestore), `ingredient note` (saisie) et `ingredientNote` (`PageType.name` côté Dart). Chacune n'était auparavant reconnue que par un lecteur sur deux, si bien que la même page changeait de type selon l'endroit où on la lisait. Cas partagés : `test-fixtures/cooklang_parsing.json`, clé `pageTypeLabels`.

#### Pipeline image — Client

- **`flutter_image_compress`** : ajouté dans `pubspec.yaml`. Utilisé dans `scan_upload_service.dart` pour compresser les photos avant upload (qualité configurable, format JPEG/WebP).
- **Thumbnails WebP** : les miniatures d'illustrations sont générées et stockées au format WebP dans Firebase Storage.
- **Quality gate** : score calculé localement (netteté via Laplacien simulé, luminosité moyenne) avant envoi à Gemini — seuil configurable dans `image_quality_checker.dart`.

#### Bibliothèque de livres

- **Effet 3D couvertures** : `BookCoverWidget` applique `BoxDecoration` avec `BoxShadow` multiple (ombre portée + ombre de tranche) et un overlay gradient pour simuler le vernis. Rendu via `ClipRRect` + `Stack`.
- **Assets par défaut** (`assets/covers/`) : images locales pour les livres système utilisées si `coverUrl` est null.

#### Comptabilité (`lib/features/admin/`)

- **`billing_screen.dart`** : deux onglets via `TabBar`. Onglet GCP : appel Cloud Function `getGcpCostsFn` (BigQuery). Onglet Gemini : `StreamProvider` sur `ai_usage` Firestore, agrégation par `uid+feature+month`, `DataTable` avec tri, total dynamique en bas.
- **`GeminiPricing`** : map `feature → $/1M tokens` (input/output). Tarification images (`enhance_illustration`) : 0,0336 $/image (`gemini-3.1-flash-lite-image`, dit Nano Banana 2 Lite ; 0,04 $ sur `gemini-2.5-flash-image` jusqu'au 15/08/2026, entrée conservée pour relire les mois antérieurs).
- **`backfillEnhanceUsageFn`** : Cloud Function HTTPS callable (admin) qui scanne `gs://kassdale-6d948.appspot.com/illustrations/` et backfille les documents manquants dans `ai_usage`.

#### Gestion du cache web — `firebase.json`

- Règle `headers` consolidée :
  - `index.html` + `flutter_service_worker.js` : `Cache-Control: no-cache, no-store, must-revalidate` + `Pragma: no-cache` + `Expires: 0`.
  - `canvaskit/**` : `Cache-Control: public, max-age=31536000, immutable`.
  - `app-release.apk` : `Content-Type: application/vnd.android.package-archive` + `Content-Disposition: attachment`.
  - **Ne jamais utiliser** `**/*.@(js|css|wasm)` avec cache long — le glob attrape `flutter_service_worker.js` et crée un conflit de headers `immutable` bloquant les mises à jour.

## 2026-05-18

### v0.13.62 — fonctionnel

- **Architecture serveur pour le traitement IA** : tous les appels Gemini (extraction de recettes, raffinement, recherche, suggestion de planning, génération de recette, polissage Cooklang, extraction de couverture, détection d'illustrations, etc.) sont désormais exécutés côté serveur via des Cloud Functions. La clé API Gemini n'est plus présente sur les clients (web, mobile, desktop) ; elle est stockée dans Google Secret Manager. Conséquences fonctionnelles : les imports volumineux (PDF multi-pages, scans de livres) ne dépendent plus de la connexion du téléphone — l'utilisateur peut fermer l'app, le traitement continue.

- **File d'attente avec traitement parallèle** : les imports de recettes et de couvertures de livres sont mis en file d'attente Cloud Tasks (5 jobs en parallèle, 2 par seconde, 3 tentatives en cas d'échec transitoire). Le statut du job (queued → processing → done/error) est suivi en temps réel sur le mobile via le panneau d'imports. Si un job échoue 3 fois, il est déplacé dans une "Dead Letter Queue" (DLQ) accessible aux administrateurs.

- **Écran admin "Dead Letter Queue"** : accessible depuis l'écran Administration (icône problème). Liste les jobs ayant échoué après 3 tentatives, plus récents d'abord. Pour chaque entrée : raison de l'échec, date, nombre de tentatives, dernier message d'erreur (sélectionnable + copiable), identifiants original_job_id / user_id / correlation_id / file_path / queue_name (avec bouton copier). Deux actions par entrée (avec confirmation) : **Relancer** (recrée un job neuf dans la file ; l'entrée DLQ est marquée comme relancée et conserve l'historique avec le nouveau jobId) et **Supprimer** (suppression définitive). Une entrée déjà relancée affiche l'icône "replay" verte et le bouton Relancer est désactivé.

- **Écran admin "Cloud Logging"** : accessible depuis l'écran Administration (icône terminal). Permet de filtrer les logs structurés du pipeline IA :
  - **Sévérité** (chips) : Tous / INFO / WARN / ERROR / DEBUG.
  - **Fenêtre temporelle** (déroulant) : 15 min / 1 h / 6 h / 24 h / 7 j.
  - **Recherche libre** dans le message.
  - **Filtres exacts** par correlationId, jobId, userId.
  - Chaque entrée est dépliable : labels avec bouton copier par valeur + payload JSON complet en monospace sélectionnable.
  - Affichage avec icône et couleur selon la sévérité, badges pour le module et les identifiants.

- **Suppression de la clé Gemini côté client** : les builds web/mobile/desktop ne nécessitent plus l'argument `--dart-define=GEMINI_API_KEY=...`. Toute fonctionnalité IA passe désormais par les Cloud Functions authentifiées.

### v0.13.62 — technique

#### Backend Cloud Functions (Node 20, TypeScript, 2nd gen, région `europe-west1`)

- **Structure `kass_dalle/functions/src/`** :
  - `index.ts` : exporte 15 fonctions (callables + handlers Cloud Tasks).
  - `config.ts` : constantes `REGION`, `PROJECT_ID`, `LOG_NAME = "kass-dalle-pipeline"`, `QUEUE_NAME = "recipe-processing-queue"`, `GEMINI_SECRET = "GEMINI_API_KEY"`.
  - `_auth.ts` : helpers `requireAuth(req)`, `requireEditor(req)`, `requireAdmin(req)`. `requireAuth` tranche sur le claim `role` du jeton et ne lit `users/{uid}` que s'il n'en porte pas ; les deux autres lisent toujours le document, car une révocation ne s'attend pas. La décision est portée par `accessDenial()`, pure et testée (`tests/authGuards.test.ts`). Les trois appellent aussi `assertAppCheck()` : c'est le seul endroit où l'attestation peut être exigée sans risquer d'oublier une callable.
  - Toutes les entrées HTTPS portent `maxInstances: MAX_CALLABLE_INSTANCES` (10, dans `config.ts`). Sans plafond, une boucle ouvre jusqu'à cent instances, chacune servant quatre-vingts requêtes concurrentes vers Gemini ou Anthropic. Ce plafond borne le parallélisme, jamais le total dépensé.
  - `security/appCheckPolicy.ts` : mode d'attestation lu dans `app_config/app_check_policy` (cache mémoire d'une minute), et décision pure `appCheckVerdict(mode, attested)`. Les fonctions gardent délibérément `enforceAppCheck` **non activé** : l'option se décide au déploiement, alors qu'un refus à tort doit se rouvrir en une minute. `req.app` non nul signifie jeton présent **et** valide — un jeton absent et un jeton invalide se présentent de la même façon et se traitent pareil.
  - `_logger.ts` : wrapper `@google-cloud/logging` avec labels `{module, correlation_id, job_id, user_id}` et payload JSON structuré.
  - `callable/*Callable.ts` : callables clients (createScanJobFn, queryLogsFn, relaunchDeadLetterFn, deleteDeadLetterFn, geminiProxyFn, etc.).
  - `pipeline/recipeProcessor.ts` : handler Cloud Tasks principal (download Storage → transcription → balisage → contrôle de fidélité → normalisation → **une seule** écriture Firestore).
  - **Les coordonnées d'une boîte ne supposent plus un moteur.** Le repère `[y_min, x_min, y_max, x_max]` sur mille est la convention **native de Google** ; le prompt se contentait de l'énoncer (« entiers 0-1000 »), ce qui suffit à un modèle qui l'a apprise et à aucun autre. Basculer les cinq postes de détection sur Claude les rendait muets. Réserver le poste à Gemini aurait été la mauvaise réponse : un moteur ne doit pas être privilégié par un détail de format resté implicite. Le prompt **décrit** désormais le repère (haut = 0, bas = 1000, verticale d'abord, deux exemples) et porte les **dimensions réelles de l'image** ; `normalizeBox(vals, w, h)` accepte les trois unités qu'un modèle emploie spontanément — millièmes, 0-1, et **pixels** ramenés avec les dimensions, la verticale rapportée à la hauteur. Sans dimensions, on **borne** au lieu de deviner : un facteur imaginaire donnerait une découpe précise et fausse, une découpe bornée se fait écarter par le contrôle de qualité, ce qui se voit. Limite assumée et testée : **sous mille, pixels et millièmes sont indiscernables** — aucune heuristique ne peut trancher, c'est le prompt qui porte le reste.
  - **La détection d'illustrations ne ment plus par omission.** Son `catch` était vide et rendait un tableau de boîtes : un refus du modèle, un plafond de dépense, un délai dépassé, une réponse illisible ou un format de coordonnées inconnu se présentaient tous comme « aucune photographie détectée ». La règle la plus stricte du projet, prise en défaut là où elle comptait le plus — une page sans photo et un appel en échec demandent des réactions opposées. L'erreur remonte désormais, la réponse brute est journalisée avec son moteur, et l'échec est absorbé **page par page** pour ne pas perdre les découpes déjà obtenues. Piste que cela rend vérifiable : le repère `[y_min, x_min, y_max, x_max]` sur mille est une convention **Google** ; un autre moteur ne la connaît pas et répond à côté sans lever d'erreur — une réponse non vide sans boîte exploitable est signalée comme telle, moteur nommé.
  - **`recipes.illustration_report`** `{detectees, retenues, publiees, pagesEnEchec}` suit la recette et s'affiche à la relecture. Trois situations, trois phrases, trois réactions : rien repéré (ajouter à la main), repérées puis toutes écartées (filtres ou modération), détection en échec (réessayer). Rien n'est dit quand une photo a été publiée : elle se voit.
  - **Les illustrations sont REDRESSÉES, pas seulement découpées** — `gemini/perspective.ts`. Une page photographiée à main levée est un trapèze : un cadre rectangulaire, aussi serré soit-il, garde deux coins de papier et de table. Le détecteur rend donc les **quatre coins** de chaque photographie (`DetectedQuad`, ordre haut-gauche → haut-droit → bas-droit → bas-gauche, en 0-1000), et `warpQuadrilateral` applique l'homographie qui les ramène sur un rectangle : normalisation de Hartley, système 8×8 par élimination de Gauss, interpolation bilinéaire — le même algorithme que l'atelier manuel (`image_enhancer_processing.dart`), porté côté serveur pour que la chaîne automatique rende ce que l'outil manuel rendait. Sharp redimensionne, tourne et découpe, mais ne projette pas : la boucle est en clair, 122 ms pour une photo de douze mégapixels. Une zone **déjà droite** (`isNearlyRectangular`) est découpée sans être redressée — la transformation ne changerait rien de visible et ré-échantillonnerait pour rien. `readQuad` accepte les deux formes de réponse, quatre coins ou boîte englobante : un modèle rend parfois la seconde par habitude, et la refuser perdrait une photo correctement repérée pour une question de forme. Deux détails qui séparent une image juste d'une image nette et fausse : l'**ordre des coins** décide quel côté sera le haut, et les dimensions de sortie prennent la **moyenne géométrique** des bords opposés — en perspective le bord proche est plus long que le lointain, retenir le maximum étirerait l'image.
  - **Orientation EXIF : redresser AVANT de détecter.** `uprightImage(bytes)` (`gemini/detector.ts`) applique l'orientation EXIF et efface l'étiquette ; le buffer redressé sert ensuite à la détection **et** au découpage. Un modèle de vision reçoit l'image telle qu'elle s'affiche — le décodeur applique l'EXIF — et rend ses coordonnées dans ce repère ; Sharp découpe la grille de pixels stockée. Pour une photo de téléphone prise en portrait, les deux repères sont tournés de 90° : on demandait le plat, on obtenait un bout de table. Rien ne le signalait, la découpe étant techniquement valide (taille, rapport de forme) — elle passait les filtres puis se faisait refuser à la modération, ou pire, se publiait. C'est aussi l'explication du « toutes les photos rejetées » : un bout de table est clair et uniforme, donc écarté comme page blanche.
  - **Les étapes affichées décrivent ce qui SE PASSE.** `current_step` : `import` → `gemini_call` (lecture de la page) → `parse` → `design` (illustrations) → `tagging` → `normalize` → `save` → `done`. `save` couvrait autrefois le balisage, le contrôle de fidélité et la normalisation des référentiels — jusqu'à sept minutes sous un mot qui en promet une seconde. Le calcul nutritionnel n'y figure délibérément pas : il a lieu après l'écriture, sur une recette déjà consultable.
  - **Chaîne d'extraction en deux passes** — `gemini/transcription.ts`, `gemini/tagging.ts`, `gemini/fidelity.ts`, prompts dans `gemini/promptsExtraction.ts`.
    - **Passe 1, `transcribePage`** (poste `transcription_page`) : un appel rend le **type** de la page et son contenu **recopié** en JSON — sections d'ingrédients (une ligne du livre = une ligne, entière), sections d'étapes (phrase par phrase), notes typées. Aucune balise, aucune décision de placement. Elle remplace `classify_page` + `scan_extraction` + `document_extraction`. Une réponse illisible **lève** : le repli optimiste d'avant supposait « recipe » et fabriquait une recette vide qu'il fallait ensuite retrouver dans les brouillons.
    - **Passe 2, `tagAndNormalize`** (poste `recipe_tagging`) : texte seul, jamais d'image. Rend le CookLang balisé, la liste normalisée (`nom`, `qte`, `unite`, `note`, `section`) et les tags — ces derniers coûtaient un appel à eux seuls.
    - **`checkFidelity`** : pure, testée, **sans appel de modèle**. Sept contrôles, tous mécaniques :

      | Contrôle | Ce qu'il attrape | Niveau |
      |---|---|---|
      | `ingredients_compte` | une ligne du livre sans ingrédient correspondant | rupture |
      | `etapes_compte` | un résumé — au-delà de 20 % d'écart | rupture si moins |
      | `texte_perdu` | une clause disparue **à décompte égal** | rupture sous 55 % |
      | `sections_titres` | « Pour la sauce à l'aneth et à la moutarde » raccourci | avertissement |
      | `notes_perdues` | une astuce que rien d'autre ne porte | avertissement |
      | `precision_perdue` | des mots de la ligne du livre qui ne sont ni dans le nom, ni dans l'unité, ni dans la note | avertissement |
      | `ingredient_invente` | « aneth frais » devenu « aneth en poudre » | avertissement |
      | `section_non_transcrite` et ses deux voisins | ce que la **passe 1** a perdu | avertissement |

      Une *rupture* écarte le balisage : `verbatimCooklang` rend le texte de la passe 1, non balisé — mieux vaut exact et non balisé que balisé et faux. Un *avertissement* laisse passer. Le verdict est écrit sur la recette (`fidelity_level`, `fidelity_findings`), affiché par `FidelityBanner` **sur le seul écran de relecture d'un brouillon**, et effacé à la validation.
    - **Le chapeau de la recette** — « Une méthode scandinave pour fumer le saumon dans le sel… » — a son propre champ, `introduction`. Il tombait sous la consigne de ne pas recopier les en-têtes de page : la distinction manquait, alors qu'un titre courant se répète de page en page tandis que ce paragraphe n'appartient qu'à cette recette. Il est transmis au balisage, écrit en note **avant la première étape** parce que le livre le met en premier, et compté dans le texte confronté au balisage — sans quoi son oubli ne produirait aucun signal.
    - **L'erreur de LECTURE est d'une autre nature, et aucun contrôle ne peut la prouver.** « peau en dessous » lu « peu profonde en dessous » rend une phrase impeccable : décompte intact, couverture des mots parfaite, tout concorde — avec le mauvais mot. Les sept contrôles comparent la passe 2 à la passe 1 ; quand la passe 1 a mal lu, **elle est la référence corrompue**. Le seul moyen de la démasquer serait de relire l'image, donc un appel de plus. Trois leviers, aucun infaillible : la capture des pages de recette passe à `imageQuality: 100` (elle était à 92 quand les couvertures, qui se lisent de loin, étaient à 100 — les artefacts JPEG s'installent d'abord sur les petits caractères) ; le prompt interdit de « réparer » un mot mal lu en expression plus courante, avec ce contre-exemple exact ; et la transcription déclare ses `lectures_incertaines`, remontées sur la recette. Un doute affiché se vérifie en dix secondes.
    - **`checkTranscriptionInventory`** ferme le seul trou que les autres ne pouvaient pas voir. Tous comparent la passe 2 à la passe 1 ; aucun ne voit ce que la **passe 1** a perdu — une page dont la première section n'aurait jamais été recopiée produit une chaîne cohérente de bout en bout. La passe 1 déclare donc son inventaire (titres de groupe vus, nombre de lignes, nombre d'étapes) **avant** de recopier, et le code compare l'annonce au résultat. Le verdict reste un avertissement : cette déclaration vient du modèle lui-même, et s'y fier pour jeter son travail reviendrait à lui demander de s'auto-condamner.
    - **Comparer deux textes que le balisage rend méconnaissables.** `stripCooklangTags` retire la syntaxe en **gardant le contenu des accolades** : la première version le jetait, et accusait un balisage fidèle d'avoir perdu un tiers de la page — les quantités quittent légitimement la phrase pour entrer dans les accolades. `significantWords` ne retient que les mots d'au moins quatre lettres et écarte une liste fermée de nombres écrits en lettres et de mesures abrégées (« deux cuillères à café » → « 2 c. à café » : trois mots sur quatre changent sans que rien ne soit perdu). Les seuils — 70 % pour l'alerte, 55 % pour la rupture — se placent dans l'écart mesuré entre une perte légitime (~15 %) et une amputation réelle (>70 %). Une accusation à tort finit par se faire ignorer, ce qui coûte plus cher que de ne rien vérifier.
    - **Pourquoi deux passes.** L'ancien prompt demandait de transcrire fidèlement *et* de restructurer en CookLang. La règle « la liste d'ingrédients ne se transcrit jamais, chaque ingrédient apparaît une seule fois à sa première mention dans les étapes » obligeait le modèle à **décider** où placer chaque ingrédient — donc à fusionner, déplacer, abréger — et rendait la précision d'une ligne (« avec la peau mais écaillée ») impossible à porter, ce qui poussait à réécrire la phrase du livre.
    - **Pourquoi un appel de modèle et pas une bibliothèque OCR.** La page est **lue** par un appel de modèle, jamais par une reconnaissance de caractères locale. Un OCR rend un flux de caractères et des boîtes : il ignore que le bloc de gauche est la liste d'ingrédients et que l'encadré du bas est « Le conseil du chef ». Sur une page de livre de cuisine — deux colonnes, un encadré, des titres de groupe en petites capitales — il **devine** l'ordre de lecture, et se trompe souvent. Il faudrait ensuite un appel de modèle pour reconstruire la structure à partir de ce flux : on n'aurait pas retiré l'IA, on lui aurait retiré la **mise en page**, qui est précisément ce qui lui dit ce qu'elle lit. La passe 1 rend en un appel ce qu'un OCR ne rend jamais : le type de la page, les groupes et leurs titres, les notes typées.
      - **Le témoin extérieur — étudié le 2026-08-29, abandonné.** L'OCR bat le modèle sur un point, et c'est le seul que la chaîne ne sait pas contrôler : il ne réécrit jamais. D'où la tentation de s'en servir non pour lire la page, mais pour **témoigner** contre l'erreur de lecture décrite plus haut — chercher chaque mot porteur de la transcription dans le flux OCR, et signaler l'inverse, un mot imprimé que la transcription ne porte nulle part. Trois raisons de ne pas le faire.
      - **L'alerte serait sans issue.** `checkFidelity` a une action : une rupture retombe sur `verbatimCooklang`, exact et non balisé. Un texte OCR n'a pas de structure et ne reconstruit aucune section ; il ne saurait que dire « va revérifier ». Un avertissement de plus, sur un import que l'utilisateur croyait fini.
      - **Le bruit coûterait plus cher que le contrôle.** La comparaison devrait être ensembliste et non séquentielle — l'OCR se trompe d'ordre dès qu'il y a deux colonnes —, tolérante (Levenshtein, sans accents), avec un seuil de fausse alerte à tenir. Sur une page mate déjà redressée par `perspective.ts` et passée en niveaux de gris par `sharp`, Tesseract lit correctement ; sur un titre fantaisie, du texte posé sur une photo, une page glacée avec reflet, il rend de la bouillie — et chaque bouillie devient une fausse alerte. Même raison que les seuils du tableau ci-dessus : une accusation à tort finit par se faire ignorer, ce qui coûte plus que de ne rien vérifier.
      - **La taille du trou n'a jamais été mesurée.** `checkTranscriptionInventory` tourne déjà en production et ses codes de constat partent dans les journaux. Les compter ne coûte **rien** et tranche la question. Tant que ce comptage n'est pas fait, embarquer un WASM dans le bundle, un fichier de langue, des secondes de CPU par page et un seuil à régler achète une complexité certaine contre un gain supposé.
      - **Ce qui aurait été employé, pour mémoire.** En Node 22, seul `tesseract.js` (Tesseract 5 compilé en WASM, pur JavaScript) tient : `node-tesseract-ocr` appelle un exécutable système absent du runtime Cloud Functions, et les portages Paddle ou EasyOCR sont natifs. Il se chargerait en `await import()` mémorisé, comme Vision et BigQuery, et `fra.traineddata` devrait voyager dans le bundle — sinon chaque démarrage à froid irait le chercher sur un CDN. Cloud Vision n'est pas une réponse à la question posée : c'est un **modèle hébergé** facturé à l'unité, donc le même témoin sans issue, augmenté d'un coût par page.
    - **Le texte collé emprunte la même chaîne** — `gemini/extractor.ts`, `extractRecipeFromTextFn`. Coller un texte puis appuyer sur « IA » tenait en **un appel** : un prompt demandait de lire et de baliser en même temps, et rendait du CookLang sans liste d'ingrédients. C'est le défaut que les deux passes avaient supprimé côté scan, resté intact ici. La liste collée se dissolvait dans les étapes, « 2 gousses d'ail dégermées » y perdait « dégermées » — aucune accolade ne porte une précision — la liste stockée était reconstituée côté client en relisant les balises `@` (ni `note`, ni `source`, ni section d'origine), et rien n'était vérifié : ni inventaire, ni lectures incertaines, ni `checkFidelity`, ni repli. Trois métadonnées n'étaient même pas demandées au modèle : `temps_repos`, `dish_types`, les cuisines.
    - **Passe 1 pour un texte, `transcribeText`** (poste `text_extraction`, inchangé) : **le même prompt que la page**, précédé de `TEXT_TRANSCRIPTION_PREAMBLE`. Écrire un second prompt aurait mis en double les règles qui font la valeur du premier — recopier sans réécrire, garder les sections, séparer les notes des étapes, débusquer le temps de repos, ne pas réparer un mot douteux — et la première amélioration n'aurait profité qu'à un seul des deux chemins. Le préambule pose la correspondance une fois (« lis *la page* comme *le texte reçu* ») et nomme les deux seules différences : `page` vaut null, et le mobilier à ignorer n'est plus un folio mais une barre de navigation, un « Imprimer la recette », des avis de lecteurs. Un test compare le prompt de scan avant et après : il est **inchangé au caractère près**.
    - **Passe 2 et fidélité, sans une ligne de plus.** `tagAndNormalize` n'a jamais vu l'image : elle travaille sur une transcription, et une transcription venue d'un texte est de la même forme. `checkFidelity` compare la passe 2 à la passe 1 — les huit contrôles s'appliquent tels quels, sans appel de modèle. Le texte collé rend donc désormais ce qu'un scan rend : CookLang balisé, liste normalisée avec `note` et `source`, cuisines, types de plat, et la réserve de fidélité affichée par `FidelityBanner` sur le brouillon. Elle n'est pas écrite quand l'utilisateur clique « Créer et valider » : valider, c'est justement trancher.
    - **Le poste de coût ne change pas de nom.** La passe 1 reste `text_extraction`, la passe 2 s'impute sur `recipe_tagging` comme celle d'un scan — c'est le même prompt, le même travail, et lui donner un second nom aurait coupé en deux une ligne comptable qui mesure une seule chose. Le coût passe d'un appel à deux ; le compte de `text_extraction` dit combien de fois le chemin a servi.
  - `nutrition/shoppingDerivation.ts` : `deriveShoppingProducts`, pure et testée. Le regroupement en produits d'achat ne coûte plus d'appel : il demandait un jugement tant que la liste était reconstituée depuis les balises des étapes, où le même aliment apparaissait sous plusieurs orthographes. La liste venant du livre, regrouper est devenu une addition. Deux unités incompatibles restent **deux lignes** — additionner supposerait un taux de conversion, et un taux inventé produit une quantité fausse présentée comme exacte.
  - `pipeline/dlq.ts` : sur 3e échec, écrit dans `dead_letters` (Admin SDK, bypass règles).
  - `triggers/recipeWritten.ts` : **déclencheur unique** sur `recipes/{recipeId}`.
  - `scheduled/aiReconciliationSchedule.ts` : réconciliation comptable mensuelle (Cloud Scheduler).
  - `scheduled/nutritionCatchUpSchedule.ts` : rattrapage quotidien des recettes dont la nutrition manque ou reste incomplète (Cloud Scheduler).
  - `billing/periods.ts` : périodes `YYYY-MM`, module pur et testé.

##### Politique de calcul nutritionnel

`app_config/nutrition_source_policy` porte les seuils qui décident de **ce que
l'utilisateur voit** sur l'onglet Nutrition d'une recette. Le document n'est pas
obligatoire : `getNutritionSourcePolicy()` retombe sur `DEFAULT_NUTRITION_POLICY`.

| Réglage | Défaut | Effet observable |
|---|---|---|
| `quality_policy.minCoverageForPartial` | 0,7 | En dessous, le détail est remplacé par « Trop peu d'ingrédients ont un poids connu pour que le calcul soit représentatif » |
| `quality_policy.minCoverageForPer100g` | 0,9 | En dessous, les valeurs **pour 100 g sont masquées** |
| `quality_policy.kcalConsistencyWarnDeltaPct` | 0,15 | Au-delà de cet écart entre kcal annoncées et kcal recalculées depuis les macros, avertissement d'incohérence du référentiel |
| `fallback_policy` | `strict` | Comportement quand aucune donnée n'est trouvée |
| `source_priority` | validé‑utilisateur → interne → externe → IA | Quelle origine gagne quand un ingrédient en a plusieurs |

Les trois seuils entrent aussi dans le **score de qualité A/B/C** de la recette.

**Écran** : *Admin › Référentiels › Politique nutrition*. Les trois seuils s'y
règlent au curseur, présentés par leur effet et non par leur nom technique.
`source_priority` y est en lecture seule : le modifier demande de comprendre la
chaîne d'enrichissement, pas de bouger un curseur.

**Les bornes sont garanties côté serveur**, pas dans le formulaire :
`setNutritionSourcePolicyFn` refuse une valeur hors de [0, 1], un
`kcalConsistencyWarnDeltaPct` nul (il sert de dénominateur au score) et un
`minCoverageForPer100g` inférieur à `minCoverageForPartial` — cette dernière
combinaison ferait afficher un détail pour 100 g sur une recette que l'app
déclare par ailleurs trop incomplète pour être représentative.

Ces réglages ont longtemps été inertes : le mécanisme de lecture existait, mais
aucun écran n'appelait le callable d'écriture, si bien que seules les valeurs
par défaut avaient jamais servi.

##### Plafond de dépense d'IA

`app_config/ai_budget_policy` borne ce qu'un compte peut dépenser en une journée.

| Champ | Type | Effet |
|---|---|---|
| `daily_cost_eur_per_user` | `number` | Plafond quotidien en **euros**, par compte. `0` désactive ce critère |
| `daily_calls_per_user` | `number` | Plafond quotidien d'appels, par compte. `0` désactive ce critère |
| `monthly_alert_eur` | `number` | Seuil d'alerte mensuel en euros, tous comptes confondus. `0` = aucune alerte |
| `enabled` | `bool` | Coupe les deux plafonds sans les effacer. Absent vaut `true` |

**Pourquoi deux plafonds.** Le plafond monétaire dépend de deux données qui
peuvent manquer : la **grille tarifaire** — le projet refuse alors de chiffrer,
les appels partent en `pricing_unavailable` — et le **taux de change**, sans
lequel une dépense stockée en dollars ne se compare à aucun plafond en euros.
Dans les deux cas, un plafond uniquement monétaire s'ouvrirait en grand pendant
l'incident. Le plafond en nombre d'appels ne dépend ni d'un prix ni d'un taux.

**La monnaie.** Le plafond se règle en euros ; le coût d'un appel est calculé et
stocké en dollars, comme le facturent les fournisseurs. La conversion se fait au
moment de la comparaison, avec `app_config/currency_rate.usd_to_account_rate` —
jamais avec une constante. Sans taux, `budgetDenial` ignore le critère monétaire,
l'écran affiche des dollars plutôt qu'une conversion inventée, et un WARNING dit
que seul le compteur d'appels protège.

**Le compte fondateur a cinq fois le plafond** (`FOUNDER_DAILY_BUDGET_MULTIPLIER`),
sur les deux critères — n'agir que sur l'argent laisserait le compteur d'appels
bloquer précisément celui qui a le droit d'en faire cinq fois plus. Constante de
code et non réglage de base : en base, tout administrateur pourrait s'octroyer le
privilège. L'identifiant du fondateur est résolu par `getAuth().getUserByEmail`,
mis en cache une heure, et **jamais** lu dans le champ `email` du document
utilisateur, qu'un administrateur peut écrire.

**Pourquoi un défaut dans le code**, alors que le projet interdit les valeurs de
repli figées : cette interdiction porte sur les *mesures* — prix, taux de change
—, où une constante produit un montant faux présenté comme vrai. Un plafond est
une **décision**. Sans défaut, l'absence de document signifierait « aucune
limite », c'est-à-dire la situation qu'on corrige.

**Compteur** : `ai_daily_spend/{uid}_{AAAA-MM-JJ}` (`cost_usd`, `calls`,
`unpriced_calls`), incrémenté par `recordUsage` au moment où le coût est connu.
Un document par jour : la remise à zéro n'a besoin d'aucune tâche planifiée,
puisque le lendemain écrit ailleurs. Lecture réservée à l'administrateur et au
compte concerné, écriture fermée au client — ouverte, elle laisserait remettre
son propre compteur à zéro.

**Points d'application** — `assertWithinDailyBudget` est appelée à deux endroits,
et deux seulement, parce que ce sont les deux d'où l'argent part :

| Où | Ce que ça couvre |
|---|---|
| `callModel` (`ai/router.ts`) | tout le texte, Gemini comme Claude, callables **et pipeline asynchrone** |
| `runImageModel` (`gemini/imageGenerator.ts`) | les trois postes qui produisent une image, qui ne passent pas par `callModel` |

Placé dans les gardes HTTPS, le contrôle aurait laissé passer tout ce que Cloud
Tasks déclenche — c'est-à-dire l'import, le plus gros consommateur.

Le contrôle porte sur le **déjà-dépensé** : le coût exact n'est connu qu'après la
réponse. Un appel peut donc dépasser légèrement la limite, jamais la doubler.

`BudgetExceededError` se traduit en `resource-exhausted` côté callable — ni une
panne ni un défaut de droits — et fait partir un job d'import **directement** en
dead letter, sans réessai : le plafond ne se rouvrira pas dans les minutes qui
viennent, et chaque tentative refait tout le travail qui précède l'appel d'IA.

**Alerte** : `scheduledAiBudgetAlert` tourne tous les jours à 7 h (Europe/Paris),
compare le cumul du mois en cours (`ai_usage_monthly/{période}.total_cost_usd`)
au seuil, et n'écrit qu'une fois par mois — le drapeau vit dans
`app_config/ai_budget_alert`, posé **après** l'alerte pour qu'un échec la fasse
retenter le lendemain plutôt que de la perdre.

##### Politique d'attestation App Check

`app_config/app_check_policy` décide **ce qu'on fait d'un appel non attesté**. Un
seul champ :

| Champ | Type | Effet |
|---|---|---|
| `mode` | `"off"` \| `"monitor"` \| `"enforce"` | `off` ne vérifie rien ; `monitor` (défaut, y compris document absent ou illisible) laisse passer et journalise en `WARNING` avec le poste et l'agent utilisateur ; `enforce` refuse |

**Écran** : *Admin › Attestation de l'application*. Il affiche si l'appel qui l'a
chargé était lui-même attesté, et `setAppCheckPolicyFn` **refuse** `enforce`
demandé depuis un appel non attesté — sans quoi l'administrateur se verrouillerait
dehors, et la famille avec lui.

Trois précisions qui expliquent la forme de ce document :

- **Pourquoi pas `enforceAppCheck: true`** sur les callables : cette option se
  décide au déploiement. Un refus à tort — clé mal posée, client resté en
  arrière, fournisseur en panne — doit se rouvrir en une minute.
- **Pourquoi un mode « observation »** : c'est le seul moyen de savoir *ce qu'on
  couperait* avant de couper. Tant qu'il arrive des appels non attestés, leurs
  traces nomment le client concerné.
- **Pourquoi aucune exemption de plateforme**, alors que le client Windows ne
  sait pas attester : la plateforme est déclarée par le client, donc par un
  attaquant aussi. Une exemption « desktop » serait ouverte à tout le monde.

Côté client, `core/services/app_check.dart` active l'attestation quand la
plateforme a un vrai fournisseur (web, Android, iOS, macOS) et s'abstient
sinon — sans jamais relancer : une attestation impossible ne doit pas empêcher
l'application de démarrer, c'est la politique serveur qui décide des
conséquences. La clé de site reCAPTCHA (`kAppCheckRecaptchaSiteKey`) est
publique par nature et vit donc dans le code ; **vide, l'attestation web n'est
pas activée**.

##### Politique de routage entre fournisseurs d'IA

`app_config/ai_routing_policy` décide **quel moteur sert quel poste**. Le
document n'est pas obligatoire : `getAiRoutingPolicy()` retombe sur
`DEFAULT_AI_ROUTING_POLICY`, c'est-à-dire Gemini partout — le code déployé ne
change donc aucun comportement tant que personne n'a écrit la politique.

| Champ | Type | Effet |
|---|---|---|
| `default_provider` | `"gemini"` \| `"anthropic"` | Moteur des postes sans choix explicite |
| `features` | `Map<String, provider>` | Choix par poste ; la clé est celle du reporting de coûts |
| `anthropic_model` | `String` | Modèle Claude servi quand le routage désigne Anthropic (défaut `claude-sonnet-5`) |
| `fallback_enabled` | `bool` | Repli sur l'autre moteur en cas d'échec **technique** ; une réponse déclinée pour raison de sûreté n'est jamais rejouée ailleurs |

**Écran** : *Admin › Moteur d'IA*. Les postes proposés viennent du serveur
(`ROUTABLE_FEATURES`) et ne sont pas dupliqués côté client : une bascule vers un
poste que le backend ignore ne produirait aucune erreur — elle ne routerait
simplement rien. Ils y sont groupés par famille (Import, Illustrations,
Rédaction, Recherche, Planning, Courses, Nutrition), chaque famille et l'écran
entier basculant d'un geste.

**Tout appel de texte ou de lecture d'image passe par `callModel`** : import et
classification de page, extraction de document, couverture de livre, détection
d'illustrations, rédaction et relecture, tags, recherche, planning, courses et
toute la chaîne nutrition. Les deux seuls appels non routables sont ceux qui
**produisent** une image (`enhance_illustration`,
`generate_recipe_illustration`) — Claude n'en fabrique pas.

La liste des postes n'est donc pas décorative : elle est exactement l'ensemble
des `feature` passées à `callModel`. Elle a un temps promis six bascules alors
qu'une seule était câblée, et une bascule sans effet se diagnostique très mal —
elle ressemble à une panne du moteur.

Deux garde-fous complètent le routage :

- **Format de pièce jointe.** Claude lit les images JPEG/PNG/GIF/WebP et les
  PDF ; il refuse le DOCX et les formats exotiques que Gemini accepte. Un poste
  routé vers Claude avec un tel fichier part directement chez Gemini, sans
  consommer un appel voué à l'échec ni écrire une erreur qui ressemblerait à une
  panne.
- **Poste littéral.** Chaque fonction impose son propre nom de poste au lieu de
  reprendre celui de l'appelant. Un poste dont le nom varie selon le point
  d'entrée ne peut être ni basculé ni comparé — et son coût se disperse sur
  plusieurs lignes du reporting.

**Garanties côté serveur** : `setAiRoutingPolicyFn` refuse un fournisseur
inconnu, un poste hors catalogue et un modèle vide. Et surtout, `resolveProvider`
sert avec Gemini tout poste routé vers Claude tant que la clé n'est pas posée :
l'absence de secret ne prive jamais l'utilisateur du service. L'écran affiche
explicitement cet état plutôt que de laisser croire à une bascule effective.

Le fournisseur et le modèle réellement utilisés sont écrits sur chaque ligne de
`ai_usage` (`provider`, `model`) et le coût est estimé au tarif de **ce**
modèle : sans cela, un appel Claude serait facturé au tarif Gemini sans qu'aucun
écran ne s'en aperçoive.

##### Réconciliation comptable des coûts IA

Répond à une question qu'on ne se pose pas spontanément : *le suivi de coûts
dit-il la vérité ?* Une erreur de tarification ne lève aucune exception — elle
produit un chiffre plausible. Seule la confrontation à la facture la révèle.

Pour un mois donné, `runAiReconciliation` compare :

- **l'estimé traçable** — somme des `estimated_cost_usd` de `ai_usage`, calculés
  appel par appel avec la grille tarifaire (`gemini/pricing.ts`), **en dollars** ;
- **le facturé réel** — requête BigQuery sur `billing_export`, filtrée sur
  Vertex AI, Generative Language, le service **Gemini API** et les SKU Gemini,
  hors assistance de console (*Code Assist*, *Gemini for Google Cloud*).

**La devise n'est pas le dollar.** La colonne `cost` de l'export est libellée
dans la devise du **compte de facturation** — l'euro pour ce projet. La comparer
telle quelle à une grille tarifaire en dollars additionne deux monnaies et
produit un écart faux, sans que rien n'échoue. Les deux requêtes divisent donc
`cost` par `currency_conversion_rate` — le taux que Google a lui-même appliqué à
la ligne — et conservent en parallèle le montant d'origine :

| Champ | Sens |
|---|---|
| `billed_ia_usd` | facturé converti en dollars, seule forme comparable à l'estimé |
| `billed_ia_native` | le chiffre de la facture, tel qu'il apparaît dans le Tableau des coûts |
| `billing_currency` | devise du compte (`EUR`) ; absent = rapport d'avant cette prise en compte, à recalculer |

Une ligne dépourvue de taux de change manque au total en dollars sans rien
casser : elle est comptée, journalisée par `logError` et remontée en anomalie.

**Le taux de change se relève avec les coûts.** Il n'existe plus de taux figé
dans le code : `refreshCurrencyRate` calcule, sur la même période, la moyenne du
taux pondérée par le coût — `SUM(cost) / SUM(cost / currency_conversion_rate)` —
et l'écrit dans `app_config/currency_rate` (`usd_to_account_rate`, `currency`,
`source_period`, `updated_at`). Un taux vieillit exactement au rythme des coûts
qu'il convertit : le rafraîchir ailleurs serait une occasion de l'oublier.

`validateCurrencyRate` (`billing/currencyRate.ts`, testé) refuse un taux hors de
`[0.1, 10]`, sans devise, ou absent : le taux précédent reste alors en vigueur et
le motif du refus part dans `logError`. Un taux aberrant accepté ne casserait
rien — il changerait silencieusement l'échelle de tous les montants en euros.

Côté client, `CurrencyRateRepository` lit ce document ; `GeminiPricing.usdToEurFallback`
(0,92) ne sert plus que tant qu'aucune réconciliation n'a eu lieu, et l'onglet
*Réconciliation* affiche alors explicitement qu'il convertit avec un repli.
Les coûts GCP en euros ne sont plus convertis du tout : le compte facturant en
euros, `costNative` **est** le montant de la facture.

Le résultat part dans `ai_reconciliation_monthly/{YYYY-MM}` : `delta_usd`,
`unattributed_usd`, ventilation `by_feature`, et `anomalies` en clair.

| Déclenchement | Quand | Période |
|---|---|---|
| `scheduledAiReconciliation` (Cloud Scheduler) | le 4 de chaque mois, 6 h Europe/Paris | le **mois écoulé** |
| `generateAiReconciliationMonthlyFn` (bouton admin) | à la demande | la période choisie |

Les deux passent par le **même traitement**. Le rapport porte sur le mois écoulé
et non sur le mois courant : l'export de facturation GCP se consolide avec
quelques jours de retard, et un mois partiel produirait un écart qui ne dit rien.

Le champ `billing_query_failed` distingue « Google n'a rien facturé » de « on
n'a pas pu savoir ». Sans lui, une requête BigQuery en échec produisait un
rapport affirmant un montant facturé nul, donc un écart négatif spectaculaire
présenté comme un fait.

**Écran** : onglet *Réconciliation* de l'écran Comptabilité.

##### Le catalogue des postes — la liste qu'il ne faut pas oublier

Un poste de coût existe à **trois** endroits, et rien ne relie les trois :

| Où | Fichier | Ce qui casse s'il manque |
|---|---|---|
| L'appel | `ctx.feature` du `callModel` | rien — le coût est bien enregistré |
| Le routage | `ROUTABLE_FEATURES` (`callable/aiRoutingCallable.ts`) | le poste ne peut pas être basculé vers Claude depuis Admin → Moteur d'IA |
| La lecture | `kFeatureCatalog` / `kFeatureProcess` (`features/admin/data/feature_catalog.dart`) | le poste s'affiche sous sa **clé technique**, rangé dans « Autres » |

Aucun de ces oublis ne lève d'erreur ni ne fausse un montant : le coût est
compté, il est seulement illisible. C'est exactement le mode de panne de la
tarification — le chiffre s'affiche, et il ment par omission de sens.

L'oubli s'est produit en grand : **toute la chaîne nutrition** — quinze postes,
dont les plus fréquents de l'application, puisqu'une seule écriture de recette
peut interroger le moteur une dizaine de fois — vivait dans « Autres » sous des
identifiants techniques, aux côtés de `polish_markdown` et
`generate_recipe_illustration`.

**Règle** : un nouveau poste s'ajoute aux trois endroits dans le même commit.
Les variantes `_batch` sont des postes à part entière et se distinguent de leur
version unitaire — c'est le seul moyen de vérifier que le groupage fait son
office. Un poste disparu du code **reste** au catalogue : les mois déjà
comptabilisés continuent de le nommer.

##### Un seul importeur, un seul déclencheur par recette

**L'import se fait entièrement côté backend.** Le client envoie le fichier dans
`quarantine/`, crée un `processing_jobs/{id}` en `queued`, puis n'écoute plus
que le statut. `jobDispatcher` réagit à l'**entrée** en `queued` — création
comme relance — et enfile la tâche Cloud Tasks.

Le client portait auparavant un second pipeline d'import complet, utilisé par la
seule relance : le même fichier pouvait donner deux recettes différentes selon
qu'il avait été importé ou relancé. Ce pipeline client est supprimé. Relancer,
c'est désormais remettre le job en `queued` ; annuler, c'est poser
`cancel_requested: true`, que `recipeProcessor` relit avant chaque tentative —
le statut seul ne suffisait pas, le traitement backend l'écrasait en fin de
course.

**Un seul déclencheur écoute `recipes/{recipeId}` : `onRecipeWritten`.** Il
évalue les gardes communes (suppression, type de page, empreinte des entrées)
puis lance ensemble `refreshShoppingProducts` et `syncRecipeNutrition`,
indépendants l'un de l'autre. Deux déclencheurs distincts écoutaient ce
document, chacun le réécrivant en fin de traitement, donc chacun réveillant
l'autre : une sauvegarde de recette coûtait quatre invocations de fonctions
512 MiB au lieu d'une.

##### La garde porte sur les entrées, jamais sur la sortie

Ce déclencheur écrit dans la collection qu'il écoute : `shopping_products`
d'abord, les champs de validation ensuite, `nutrition` en dernier — après les
appels d'IA, donc jusqu'à plusieurs minutes plus tard. **Chacune de ces trois
écritures le réveille.**

Sa garde demandait « la nutrition existe-t-elle déjà ? ». Cette question est
fausse deux fois. Elle répond non pendant toute la durée du calcul : un écho
tombé dans cette fenêtre repartait pour une chaîne complète, écrivait à son
tour, et en réveillait d'autres — un éventail, pas une chaîne. Et elle répond
non pour toujours quand le calcul a échoué, puisque rien n'était alors écrit :
la recette devenait un générateur d'appels sans borne, à chacune de ses
écritures suivantes.

Le compteur `nutrition_enrichment_attempts` était censé borner cela. Il n'était
lu que dans la branche où la sortie existait déjà, c'est-à-dire jamais pendant
la salve. Mesure d'août : **499 réveils ont appelé le modèle pour 68 recettes**,
en 35 salves, dont une de 108 réveils en treize minutes.

La garde compare désormais les champs que le déclencheur **consomme** —
`ingredients`, `portions`, `page_type`, `raw_cooklang`
(`recipeTriggerInputsFingerprint`, `triggers/recipeIngredients.ts`). Une
écriture qui les laisse intacts ne peut pas changer le résultat : on rend la
main. Aucune sortie du déclencheur n'entre dans l'empreinte, donc aucun de ses
échos ne le relance. Une création n'a pas de `before` et passe toujours.
`recipeTriggerGuard.test.ts` verrouille le point : ajouter `nutrition` ou
`shopping_products` à un document ne doit pas changer son empreinte.

Trois conséquences.

**L'échec s'écrit.** `persistFailedNutritionSnapshot` pose un instantané
`coverage_state: "failed"` portant la raison. Sans lui, une recette dont le
calcul a échoué ressemble en tout point à une recette pas encore calculée.

**Une valeur que le modèle ne sait pas donner n'est pas redemandée avant
24 heures** (`ENRICHMENT_RETRY_AFTER_MS`). Une unité sans poids n'était marquée
nulle part : chaque recette l'employant la redemandait, deux fois — premier
essai puis relance —, à vie. Les ingrédients portaient déjà leur marque
`estimation_failed`, mais le filtre ne regardait que la présence des valeurs.

**Le rattrapage est devenu une tâche planifiée.** La garde supprime le
recalcul opportuniste qui vivait sur les réveils ; il fallait le remplacer, pas
seulement le retirer.

##### Reprendre est une décision — le planifié et le demandé

`scheduled/nutritionCatchUpSchedule.ts`, tous les jours à 5 h (Europe/Paris),
avant l'alerte de dépense de 7 h pour que sa consommation soit déjà comptée
quand elle regarde.

Il parcourt les 246 recettes — quelques centaines de lectures, négligeables —
et reprend celles que `needsNutritionCatchUp` désigne : aucun instantané, un
instantané `failed`, ou des `missing_ingredients`. Ce qui coûte, ce sont les
appels de modèle des recettes reprises, d'où un plafond sur celles-là seules
(`MAX_RECIPES_PER_RUN` = 20).

Trois bornes, et chacune ferme une porte :

| Borne | Valeur | Ce qu'elle empêche |
|---|---|---|
| `RECENT_WRITE_GRACE_MS` | 30 min | Reprendre une recette dont le déclencheur calcule encore — deux chaînes en parallèle, la salve réintroduite par l'autre bout |
| `MIN_SNAPSHOT_AGE_MS` | 20 h | Reprendre deux fois le même jour une recette que le passage d'hier a déjà tentée |
| `MAX_CATCH_UP_ATTEMPTS` | 5 | Payer chaque jour, indéfiniment, pour une recette qu'aucun rattrapage ne peut compléter |

Le compteur `recipes.nutrition_catch_up_attempts` porte la troisième.
`syncRecipeNutrition` le remet à zéro dès qu'un vrai changement d'entrée
relance le calcul : une liste modifiée mérite ses propres tentatives.

**Deux entrées, une seule passe.** `runNutritionCatchUp` porte la mécanique ;
`scheduled/nutritionCatchUpSchedule.ts` l'appelle tous les jours,
`callable/nutritionBackfillCallable.ts` à la demande d'un administrateur —
bouton « Reprendre la nutrition », écran Admin → Backfills.

La différence tient en un mot : `forced`. Un administrateur qui vient de
corriger un référentiel veut voir l'effet, pas l'attendre jusqu'au lendemain.
Les deux bornes de **patience** sautent donc — `MIN_SNAPSHOT_AGE_MS` et
`MAX_CATCH_UP_ATTEMPTS`. La borne de **prudence**, `RECENT_WRITE_GRACE_MS`, ne
saute jamais : elle ne protège pas d'une impatience, elle protège de la salve.
`nutritionCatchUp.test.ts` verrouille les trois cas.

Le backfill ne tient pas dans le délai d'une fonction. Il reprend donc sur
point de contrôle (`app_config/nutrition_catch_up_checkpoint`, mêmes helpers
que les autres backfills, désormais partagés dans `callable/_backfillCursor.ts`),
et le curseur ne revient au début que lorsqu'il ne reste **rien** : collection
entière parcourue *et* aucune candidate laissée en route. Le remettre dès la fin
du parcours ferait boucler un backfill qui a encore du travail.

Le plafond de dépense est consulté **avant** chaque recette, pas après : passé
le plafond, la chaîne échouerait recette après recette et chacune ressortirait
marquée « encore incomplète », ce qui est faux — elle n'a pas été tentée, elle a
été refusée. La réponse porte `stoppedByBudget`, et l'écran le dit.

Ce que le passage ne reprend pas est **compté et journalisé** (`reportees`) :
un plafond silencieux se lit comme « tout a été repris ».

Le balayage écrit sur les recettes qu'il reprend, donc il réveille
`onRecipeWritten` — qui rend la main aussitôt, aucune entrée n'ayant bougé.
C'est la garde sur les entrées qui rend ce balayage possible : sans elle, il
aurait relancé la salve à lui seul.

- **Cloud Tasks `recipe-processing-queue`** :
  - Région `europe-west1`, max-dispatches-per-second=2, max-concurrent-dispatches=5, max-attempts=3, min-backoff=10s, max-backoff=600s.
  - Création via `gcloud tasks queues create` ; auth des tâches : OIDC du SA `{projectNumber}-compute@developer.gserviceaccount.com`.

- **Secret Manager** :
  - Secret `GEMINI_API_KEY` (v1) lu par les fonctions via `defineSecret("GEMINI_API_KEY").value()`.
  - Accordé au SA runtime par défaut (`roles/secretmanager.secretAccessor`).
  - Secret `ANTHROPIC_API_KEY` — **à créer avant d'activer Claude**. Lu par
    `ai/anthropic.ts` via `process.env.ANTHROPIC_API_KEY`, et non via
    `defineSecret`, tant qu'il n'existe pas : un secret déclaré et attaché mais
    absent de Secret Manager fait échouer **tout** le déploiement, y compris les
    fonctions qui n'en ont pas besoin. Activation en deux gestes, dans cet ordre :

    ```powershell
    # 1. Créer le secret (la commande demande la valeur en entrée standard)
    firebase functions:secrets:set ANTHROPIC_API_KEY

    # 2. Attacher le secret aux fonctions qui appellent la chaîne nutrition,
    #    en ajoutant ANTHROPIC_API_KEY à leur liste `secrets: [...]` :
    #      - onRecipeWritten            (triggers/recipeWritten.ts)
    #      - normalizeRecipeReferentialsFn (callable/nutritionCallable.ts)
    #      - recipeProcessor            (pipeline/recipeProcessor.ts)
    #      - backfillEnrichReferentialsFn (callable/billingCallable.ts)
    #      - backfillNutritionFn        (callable/nutritionBackfillCallable.ts)
    #      - scheduledNutritionCatchUp  (scheduled/nutritionCatchUpSchedule.ts)
    ```

    Tant que l'étape 1 n'est pas faite, la politique de routage peut désigner
    Claude sans risque : le routeur constate l'absence de clé et sert avec
    Gemini, ce que l'écran Admin → Moteur d'IA affiche explicitement.

- **Artifact Registry** :
  - Policy de cleanup `1 day` sur l'image `gcr.io/kassdale-6d948/gcf-artifacts` (Container images des fonctions).

#### Firestore

- **Collection `processing_jobs/{jobId}`** :
  - Champs : `user_id`, `file_path`, `correlation_id`, `task_name`, `status` (queued|processing|done|error), `created_at`, `updated_at`, `attempt_count`, `last_error?`, `recipe_id?`, `result?`.
  - Règles : owner read ; write côté Admin SDK uniquement (`allow write: if false`).

- **Collection `dead_letters/{dlqId}`** :
  - Champs : `original_job_id`, `user_id`, `correlation_id`, `failure_reason`, `last_error`, `retry_count`, `file_path`, `failed_at` (Timestamp), `relaunched_at?`, `relaunched_by?`, `relaunched_into_job_id?`, `queue_name`.
  - Règles : `allow read: if isAdmin();` `allow write: if false;` (écriture Admin SDK via DLQ handler / callables relaunch/delete).
  - Aucun index composite requis (orderBy `failed_at desc` champ unique).

#### Client Flutter

- **`pubspec.yaml`** : `cloud_functions: ^6.1.2`. Version `0.13.62+1`.

- **`lib/core/app_version.dart`** : `kAppVersion = '0.13.62'`.

- **Suppression de la clé Gemini côté client** : `--dart-define=GEMINI_API_KEY` retiré de tous les builds et du script `deploy.ps1`. Sept fichiers nettoyés (constante `_geminiApiKey` et tests `isEmpty` supprimés) : `scan_upload_service.dart`, `search_providers.dart`, `planning_screen.dart`, `batch_planning_screen.dart`, `draft_review_screen.dart`, `recipe_create_screen.dart`, `recipe_edit_screen.dart`. Le `GeminiService` reçoit désormais une chaîne vide en clé — il n'est plus utilisé que comme façade de types ; les appels effectifs passent par `FirebaseFunctions.instanceFor(region: 'europe-west1').httpsCallable(...)`.

- **`lib/features/admin/domain/dead_letter.dart`** : modèle `DeadLetter` avec `fromDoc(DocumentSnapshot)` (parse Timestamp `failed_at`/`relaunched_at`), getter `isRelaunched => relaunchedAt != null`.

- **`lib/features/admin/data/dead_letter_repository.dart`** :
  - `watchAll({int limit = 200})` : `_db.collection('dead_letters').orderBy('failed_at', descending: true).limit(limit).snapshots()` → `Stream<List<DeadLetter>>`.
  - `relaunch(String dlqId)` : `httpsCallable('relaunchDeadLetterFn').call({'deadLetterId': dlqId})` → renvoie `data['newJobId'] as String`.
  - `delete(String dlqId)` : `httpsCallable('deleteDeadLetterFn').call({'deadLetterId': dlqId})`.

- **`lib/features/admin/presentation/dead_letters_screen.dart`** : `ConsumerWidget` avec `deadLettersStreamProvider = StreamProvider.autoDispose`. Liste d'`ExpansionTile` ; chaque ligne `_KeyValueRow` a un `IconButton(Icons.copy_outlined)`. Boutons d'action `Relancer` / `Supprimer` sous `AlertDialog` de confirmation. État relancé matérialisé par `Icons.replay` vert et bouton désactivé.

- **`lib/features/admin/domain/log_entry.dart`** : `LogEntry.fromMap(Map)` avec champs `timestamp` (String), `severity` (String), `labels` (Map<String,String>), `payload` (Map). Getter `message` lit `payload['message']`. Getter `timestampDate => DateTime.tryParse(timestamp)`.

- **`lib/features/admin/data/logs_repository.dart`** :
  - `query({int timeRangeMinutes = 60, int pageSize = 100, String? severity, String? correlationId, String? jobId, String? userId, String? freeText})` → appelle `httpsCallable('queryLogsFn', HttpsCallableOptions(timeout: Duration(seconds: 60)))`.
  - **`severity` est un seuil** côté `queryLogsFn` : `severity>=INFO|WARNING|ERROR`, sauf `DEBUG` qui reste une égalité stricte (`severity=DEBUG`) pour isoler l'instrumentation. `null` ⇒ aucun filtre. Défaut du `LogsFilter` : `'INFO'`.
  - Côté Functions, `logDebug()` (`logging.ts`) écrit en severity `DEBUG` : « Appel IA démarré » (`gemini/client.ts`), « prompt envoyé à Gemini » et « réponse brute Gemini » (`nutrition/aiEnrichment.ts`). Un import passe ainsi d'une cinquantaine de lignes à une quinzaine.

- **`lib/features/admin/presentation/logs_screen.dart`** :
  - `LogsFilter` immuable avec `_sentinel` pattern dans `copyWith` pour distinguer "ne pas toucher" de "set null".
  - `LogsFilterNotifier extends Notifier<LogsFilter>` (Riverpod 3 n'a plus `StateProvider`).
  - `logsFilterProvider = NotifierProvider<LogsFilterNotifier, LogsFilter>(LogsFilterNotifier.new)`.
  - `logsQueryProvider = FutureProvider.autoDispose<List<LogEntry>>` qui watch le filtre et le repo.
  - UI : `ChoiceChip` (Tous/INFO/WARN/ERROR/DEBUG), `DropdownButton` (15/60/360/1440/10080 min), `TextField` × 4 (freeText/corr/job/user), `FilterChip` "Par traitement" (état local `_groupByTreatment`, actif par défaut), bouton `FilledButton` "Filtrer".
  - Regroupement par traitement : `_groupByCorrelation(List<LogEntry>) → List<_TreatmentGroup>` indexe sur `labels['correlationId']` en conservant l'ordre d'apparition des groupes (le plus récent d'abord, comme le flux) et inverse les entrées à l'intérieur (déroulement chronologique). `_TreatmentGroup.label` retient **d'abord** la racine du `correlationId` — l'identifiant privé de son horodatage (`RegExp(r'[-_]\d{10,}([-_][a-z0-9]+)?$')`), `null` si l'identifiant est un UUID, donc opaque — puis, à défaut seulement, `labels['feature']`, puis `labels['moduleType']` ; clé vide ⇒ « Hors traitement ». `feature` est le poste d'imputation d'un appel IA, pas le nom d'un traitement : en faire le titre étiquetait un import de recette « shopping_products_refresh ». La racine obtenue est ensuite **traduite** par `logTreatmentName` (`features/admin/domain/log_treatment_label.dart`) : elle est écrite pour le code, pas pour un lecteur.
  - **Nommage d'un traitement.** `newCorrelationId(nom)` (`logging.ts`) fabrique `nom_horodatage_aléa` ; pour les callables c'est `requireAuth` / `requireAdmin` / `requireEditor` qui le pose, à partir du **nom passé en argument**. Ce paramètre valait `"call"` par défaut : toute fonction qui n'en choisissait pas un produisait un groupe intitulé « call », si bien que quatre groupes « call » représentaient quatre travaux différents et anonymes. Les dix-sept fonctions concernées nomment désormais leur traitement ; `test/log_treatment_label_test.dart` lit les sources TypeScript et échoue si un `requireX(req)` sans nom réapparaît, ou si un nom déclaré n'a pas sa traduction.
  - **Qualification.** `qualify(nom, détail)` (`logging.ts`) rend `nom:détail-en-slug`. Le deux-points est la frontière que l'écran connaît : ce qui précède nomme l'étape, ce qui suit dit *laquelle*. `generateRecipeFn` s'en sert pour la variante demandée — l'écran Explorer lance trois générations simultanées, plus une relance en cas de doublon, et les groupes se lisent « … — Fidele », « … — Rapide », « … — Creative » au lieu de trois titres identiques.
  - **Deux fils naissent hors callable.** `import_recette` est ouvert par `jobDispatcher` et **transmis** au payload Cloud Tasks : `recipeProcessor` ne fabrique le sien que si le payload n'en porte pas. Un import entier tient donc sous un seul titre — il s'appelait `disp`, du nom du déclencheur, et l'écran rangeait l'extraction et la normalisation sous « Mise en file du traitement ». Le dispatcher part par ailleurs à **chaque** écriture du job et n'a le plus souvent rien à faire ; ces constats se rattachent au `correlation_id` déjà porté par le document plutôt que d'ouvrir un fil chacun. `ecriture_recette` est ouvert par `onRecipeWritten`, qualifié par sa cause : `creation`, `ingredients-modifies`, `entrees-modifiees`. Il n'y a plus de cause « rien à recalculer » : depuis que la garde porte sur les entrées, le déclencheur ne se réveille plus pour rien.
  - **Pagination.** `queryLogsFn` accepte un `pageToken` et rend un `nextPageToken` (`autoPaginate: false` — sans quoi le client Cloud Logging suit les pages jusqu'à épuisement et ignore `pageSize`). Côté écran, `LogsQueryNotifier.loadMore()` concatène ; le pied de liste annonce le nombre d'entrées lues et dit si la suite existe. Une liste tronquée en silence se lit comme une liste complète.
  - **Traduction.** `kLogTreatmentLabels` associe chaque racine à un libellé français ; une racine inconnue est rendue **telle quelle**, jamais remplacée par un texte générique — un nom technique reste cherchable. La table vit côté client parce qu'elle ne sert qu'à l'affichage : l'identifiant, lui, doit rester stable et filtrable.
  - Côté Functions, `onRecipeWritten` pose un `newCorrelationId("recipe-written")` unique et le passe à `refreshShoppingProducts` et `syncRecipeNutrition` — qui tiraient auparavant chacun un `randomUUID()`, produisant deux traitements anonymes par écriture de recette. `_TreatmentTile` est un `ExpansionTile` avec `initiallyExpanded: group.hasError`, icône/couleur dérivées de `hasError`/`hasWarning`, et un `IconButton(Icons.filter_alt_outlined)` qui reporte le `correlationId` dans le filtre exact.
  - Entrée dépliable : icône+couleur selon sévérité (`Icons.error`/`warning`/`info`/`bug_report`), chips labels (module/corr/job) avec copie, `SelectableText` monospace pour JSON formaté via `JsonEncoder.withIndent('  ')`.

- **`lib/core/router/app_router.dart`** : routes `/dead-letters` et `/logs` ajoutées avec leurs `GoRoute`. Imports correspondants.

- **`lib/features/admin/presentation/admin_screen.dart`** : deux nouvelles tuiles `Card` cliquables — "Dead Letter Queue" (`Icons.report_problem_outlined`, `colorScheme.tertiary`) et "Cloud Logging" (`Icons.terminal`, `colorScheme.secondary`).

#### Permissions Cloud

- **SA runtime par défaut Cloud Functions** : `{projectNumber}-compute@developer.gserviceaccount.com` (rôle `roles/editor`) couvre `logging.logEntries.list` (utilisé par `queryLogsFn`), `cloudtasks.tasks.create` (utilisé par `createScanJobFn`), `datastore.documents.*` (Firestore via Admin SDK), `storage.objects.get`.
- **Secret accessor** : ajouté explicitement pour `GEMINI_API_KEY`.

## 2026-05-17

### v0.13.53 — fonctionnel

- **Images agrandissables dans l'Aperçu des pages non-recette** : les illustrations affichées dans l'onglet Aperçu d'une page non-recette sont limitées à 280 px de hauteur par défaut. Un tap sur l'image ou sur le bouton fullscreen (visible en bas à droite de chaque photo) permet d'agrandir l'image en pleine hauteur ou de la réduire. Chaque image garde son état agrandi/réduit indépendamment des autres.

- **Suivi de la version d'import (admin)** : lors de chaque import ou scan d'une recette ou page, la version de l'application est enregistrée dans le champ `import_version` du document Firestore de la recette. Dans l'écran de révision d'un brouillon, les administrateurs voient s'afficher en dessous de « Analysé le… » une ligne « Importé avec vX.Y.Z » (icône clé, texte italique). Ce champ est invisible pour les Editors et Readers. Les anciennes recettes importées avant cette version ne possèdent pas ce champ ; la ligne n'est alors pas affichée.

### v0.13.53 — technique

- **Nouveau champ `recipes.import_version`** :
  - Type : `String?`, clé Firestore : `import_version`.
  - Renseigné automatiquement avec `kAppVersion` lors de chaque création de brouillon dans `scan_upload_service.dart` (deux constructeurs `Recipe` : page non-recette et recette standard).
  - Absent sur les anciennes recettes → retourne `null` via `data['import_version'] as String?`.
  - Modèle `Recipe` (`lib/features/recipes/domain/recipe.dart`) : champ `final String? importVersion` ; sérialisé dans `toFirestore()` uniquement si non-null ; désérialisé dans `fromFirestore()` ; paramètre optionnel dans `copyWith`.

- **`recipe_meta_panel.dart` — affichage admin de la version d'import** :
  - Consomme `isAdminProvider` via `ref.watch(isAdminProvider)`.
  - Affiche un `Row` supplémentaire sous « Analysé le… » uniquement si `isAdmin && recipe.importVersion != null`.
  - Icône `Icons.build_outlined` (size 16) + texte `'Importé avec v${recipe!.importVersion}'` en `bodySmall`, couleur `onSurfaceVariant`, italique.

- **`draft_review_screen.dart` — images agrandissables dans l'Aperçu non-recette** :
  - Nouveau champ d'état `final Set<String> _expandedApercuImages = {}` sur `_DraftReviewScreenState`.
  - `buildPhoto(String photoUrl)` (fonction locale dans `_buildNonRecipeApercu`) : `Stack` contenant un `GestureDetector` global (tap = toggle expand), un `ConstrainedBox(maxHeight: 280)` si non-agrandi, un bouton `fullscreen`/`fullscreen_exit` positionné `Positioned(bottom: 6, right: isOwner ? 48 : 6)` (décalé pour ne pas masquer le bouton de suppression), et un bouton `delete_outline` `Positioned(top: 8, right: 8)` visible uniquement pour le propriétaire.

### v0.13.52 — fonctionnel

- **Extraction d'illustration depuis l'original** : dans l'onglet Photos d'un brouillon disposant d'un scan image source, un bouton « Depuis l'original » est affiché à côté du bouton « Ré-extraire ». Ce bouton télécharge le fichier source, ouvre l'outil d'amélioration d'image en mode recadrage et permet au propriétaire de sélectionner manuellement une zone du scan pour l'ajouter comme nouvelle illustration. Le résultat est ajouté à la liste des illustrations sans remplacer les existantes.

- **Suppression directe des illustrations** : l'icône poubelle est désormais visible en permanence sur chaque illustration dans l'onglet Photos, dans la prévisualisation Cooklang et dans l'Aperçu des pages non-recette. Un appui long n'est plus nécessaire. La suppression n'est disponible que pour le propriétaire du brouillon.

- **Icône poubelle unifiée** : l'icône de suppression de photo est harmonisée (`delete_outline`) sur l'ensemble de l'application, en remplacement de l'icône ✕ précédemment utilisée.

### v0.13.52 — technique

- **`draft_review_widgets.dart` — bouton « Depuis l'original »** :
  - `DraftIllustrationsTab` : nouveau paramètre `VoidCallback? onExtractFromOriginal`.
  - Affiché comme `TextButton.icon(Icons.crop_outlined, 'Depuis l\'original')` dans la barre d'actions de l'onglet (coté droit, après le bouton « Ré-extraire ») si `isOwner && onExtractFromOriginal != null && _isImageSource(sourceFileUrl)`.
  - Désactivé pendant `aiRefining || saving`.

- **`draft_review_screen.dart` — `_startExtractFromOriginal(Recipe)`** :
  - Télécharge le fichier source via `FirebaseStorage.instance.refFromURL(url).getData(20 * 1024 * 1024)`.
  - Initialise l'enhancer : `_enhancerBytes = bytes`, `_enhancingIndex = null` (null = ajout d'une nouvelle illustration, pas remplacement d'une existante), `_enhancerMode = EnhancerMode.crop`, `_showingIllEnhancer = true`.
  - `_onIllustrationEnhancerResult` : si `_enhancingIndex == null`, appelle `_addNewIllustration(resultBytes)` plutôt que de remplacer une illustration existante.
  - Branché sur `onExtractFromOriginal:` de chaque instance `DraftIllustrationsTab` (4 occurrences dans les différents layouts narrow/wide).

- **`cooklang_preview_helpers.dart` — suppression directe visible** :
  - `CooklangIllustrationThumb` : bouton `delete_outline` rendu toujours visible en overlay (plus de longpress) dès que `onDelete != null`. Icône `Icons.delete_outline` (remplace `Icons.close`).

- **`draft_review_widgets.dart` — `_IllustrationCard`** :
  - Icône suppression : `Icons.delete_outline` (remplace `Icons.close`).

### v0.13.51 — fonctionnel

- **Onglet « Aperçu » pour les pages non-recette** : les brouillons de type page de technique culinaire, méthode ou autre contenu textuel non structuré bénéficient d'un onglet « Aperçu » dédié. Cet onglet affiche le texte de la page formaté typographiquement (titres en gras, listes à puces, paragraphes) et intercale chaque illustration à sa position déclarée par un marqueur `[schéma : …]` dans le texte. Le propriétaire peut supprimer chaque illustration directement depuis cet onglet. Pour les brouillons de recettes structurées (avec ingrédients Cooklang), l'Aperçu existant basé sur le rendu Cooklang interactif est conservé.

### v0.13.51 — technique

- **`draft_review_screen.dart` — `_buildNonRecipeApercu(Recipe, {required bool isOwner})`** :
  - Nouvelle méthode de rendu pour les brouillons non-recette (pages textuelles avec illustrations intercalées).
  - Nettoyage syntaxe CookLang : regex `@([^{}]+)\{\}` → texte brut (retire les balises ingrédients).
  - Découpe le texte sur les marqueurs `[schéma : …]` (regex `\[schéma\s*:[^\]]*\]`) ; insère l'illustration correspondante par index `photoIndex++` entre chaque bloc texte.
  - Formatage textuel : lignes `#…` → `titleMedium` bold ; lignes `- …` ou `* …` → puce `• ` + texte ; lignes vides → `SizedBox(height: 8)` ; reste → `SelectableText` style `bodyMedium`.
  - Rendu dans `SingleChildScrollView > Padding(16) > Column`.
  - Affiché dans l'onglet « Aperçu » uniquement si la recette n'est pas une recette structurée Cooklang (détection basée sur l'absence d'ingrédients balisés `@`).

### v0.13.50 — fonctionnel

- **Correction de navigation après l'éditeur d'image** : fermer ou valider l'outil d'amélioration d'image (recadrage, correction de couleur) depuis un brouillon ramène désormais systématiquement à l'onglet Photos du brouillon, quelle que soit la façon dont l'outil a été ouvert.

- **Correction des icônes Material sur le web (build release)** : les icônes Material Design étaient absentes dans les builds web release en raison du tree-shaking Flutter. Tous les builds web utilisent désormais l'option `--no-tree-shake-icons` pour garantir l'affichage correct de l'ensemble des glyphes.

### v0.13.50 — technique

- **Correction navigation enhancer → onglet Photos** : `_onIllustrationEnhancerResult` réinitialise `_showingIllEnhancer = false` en retournant toujours le `Stack` principal (préserve le `DefaultTabController`). L'écran ne remplace plus son widget racine par l'enhancer, il l'affiche en overlay dans le `Stack`.

- **Build web `--no-tree-shake-icons`** : tous les builds web release intègrent désormais `--no-tree-shake-icons` pour éviter la suppression des glyphes Material par le compilateur Dart (`dart2js`). Commande standard : `flutter build web --release --no-tree-shake-icons`. La clé Gemini n'est plus passée au client : voir Secret Manager côté Cloud Functions.

## 2026-05-15

### v0.13.35 — fonctionnel

- **Refactoring interne (aucun changement fonctionnel)** : nettoyage global de la qualité de code. Toutes les API dépréciées (`withOpacity` → `withValues(alpha:)`) ont été mises à jour, les `debugPrint` retirés du code de production, les avertissements `use_build_context_synchronously` corrigés, et les règles du linter Dart strictement respectées. Résultat : analyse statique propre (0 warning, 0 erreur ; 2 infos inévitables liées à `dart:html` legacy). Aucun comportement visible n'est modifié.

### v0.13.35 — technique

- **Extraction `scan_state.dart`** (`lib/features/recipes/data/scan_state.dart`) :
  - `ScanStatus` (enum), `ScanIntent` (enum) et `ScanState` (classe immuable) extraits de `scan_upload_service.dart`.
  - `scan_upload_service.dart` expose `export 'scan_state.dart'` pour compatibilité des imports existants (zéro modification des consommateurs).

- **Extraction `cooklang_preview_helpers.dart`** (`lib/features/recipes/presentation/cooklang_preview_helpers.dart`) :
  - Contient tous les helpers réutilisables du widget CookLang : `CooklangIngredient`, `CooklangStepGroup`, `CooklangIllustrationThumb`, `cooklangFormatTimer()`, `cooklangFormatIngredient()`, `cooklangNormalizeStepTimers()`.
  - `cooklangFormatIngredient()` délègue l'accord à `core/utils/ingredient_display.dart`, partagé avec l'export PDF et la liste de courses : minuscule sur les libellés de référentiel, pluriel à partir de deux, liaison « de / d’ » avec l'exception des h aspirés, et disparition des unités qui comptent (« 2 carottes », pas « 2 pièces carotte »). **Règle d'affichage seulement** : le CookLang stocké n'est jamais réécrit, sous peine de casser l'identité dont dépendent nutrition, courses, index de recherche et catégories — et d'être effacé au prochain enregistrement par `rewriteCooklangWithReferentials`. Rendu client, donc **aucun jumeau TypeScript**.
  - Tous les noms ont été rendus publics (prefixe `_` retiré) pour être accessibles hors du fichier.
  - `cooklang_preview.dart` réduit de 877L à 728L ; `cached_network_image` importé uniquement dans le fichier helpers.

- **Extraction `batch_planning_widgets.dart`** (`lib/features/planning/presentation/batch_planning_widgets.dart`) :
  - `BatchSlotTile` (ex `_SlotTile`) : tuile StatelessWidget d'un créneau de planning. Paramètres : `index`, `date`, `recipe`, `prefs`, `slotTime`, `isGenerating`, `onAssign`, `onRemove`, `onDelete`, `onTimeChanged`, `onGenerateWithAI?`, `onExportToCalendar?`.
  - `BatchRecipePickerSheet` (ex `_RecipePickerSheet`) : bottom sheet de recherche de recette avec champ de filtre textuel, suggestion IA et saisie de repas libre.
  - `batch_planning_screen.dart` réduit de 785L à 488L.

- **Qualité de code** :
  - `withOpacity(x)` → `withValues(alpha: x)` : 7 occurrences dans 5 fichiers (`recipe_detail_widgets.dart`, `shopping_list_sheet.dart`, `draft_list_screen.dart`, `work_queue_widgets.dart`, `search_screen.dart`).
  - Suppression de tous les `debugPrint` en code de production (`recipe_detail_screen.dart`, `recipe_detail_widgets.dart`).
  - `use_build_context_synchronously` : ajout de `if (!context.mounted) return` dans `source_viewer.dart` ; capture de `ScaffoldMessenger` avant `await` dans `work_queue_screen.dart` ; utilisation de `this.context` après vérification `mounted` dans `recipe_list_screen.dart`.
  - Corrections linter : accolades curly-brace, dangling doc comments → commentaires normaux, null-aware map entries (`'key': ?value` au lieu de `?'key': value`), empty catches documentés, wildcards `(_, _)` conformes Dart 3.7.
  - Résultat `flutter analyze` : 0 error, 0 warning, 2 infos inévitables (`dart:html` legacy).

### v0.13.27 — fonctionnel

- **Batch planning hebdomadaire** : depuis l'écran Planning, un bouton "Nouveau planning" ouvre `BatchPlanningScreen`. L'écran génère automatiquement les créneaux du prochain cycle (ex : 7 jours) à partir des préférences configurées. Pour chaque créneau, l'utilisateur peut : laisser l'IA suggérer une recette (bouton ✨), choisir manuellement une recette (icône loupe → picker avec recherche textuelle + suggestion IA), saisir un repas libre (texte libre), ou laisser le créneau vide. Une suggestion IA globale génère d'un coup tout le planning en respectant les contraintes. L'heure de chaque repas est réglable indépendamment via un sélecteur. Un bouton "Enregistrer" ajoute tous les repas non-vides en lot dans Firestore.

- **Configuration du planning (Préférences)** : un écran dédié `PlanningConfigScreen` est accessible depuis l'icône engrenage de l'écran Planning. Il permet de configurer : le nombre de repas par cycle (défaut : 7), le jour de démarrage du cycle (Lundi–Dimanche), l'heure et les minutes par défaut des repas, les contraintes globales en langage naturel (ex : "Pas de poisson deux fois dans la semaine"), et les contraintes par jour de la semaine (durée max de préparation en minutes, flag "batch cooking / réchauffage", note libre). Le calendrier Google cible (parmi les calendriers du compte) peut également être sélectionné depuis cet écran.

- **Export calendrier global** : dans l'écran Planning, un bouton calendrier dans l'AppBar exporte en lot tous les repas visibles vers Google Calendar (calendrier configuré dans les préférences). Chaque repas est créé comme événement individuel. Un bouton calendrier est également disponible sur chaque tuile de repas pour un export individuel.

- **Heure repas cliquable** : dans l'écran Planning, l'heure affichée sur chaque repas est cliquable et ouvre un sélecteur d'heure pour modifier le créneau directement.

- **Changer / vider une recette depuis le planning** : un menu contextuel (kebab) sur chaque tuile de repas propose "Changer la recette" (ouvre le picker) et "Vider le créneau" (supprime la recette sans supprimer le créneau).

- **Liste de courses multi-recettes** : dans la liste de courses (bottom sheet), chaque ingrédient agrégé affiche en sous-titre la ou les recettes sources, permettant de savoir d'où provient chaque quantité.

- **Sélection multiple dans livres et recettes libres** : un appui long sur un livre ou une recette libre active le mode sélection multiple. L'AppBar contextuelle propose "Tout sélectionner" et "Supprimer" (avec confirmation). La sélection est limitée aux éléments de l'utilisateur connecté.

- **Affichage toutes les pages d'un livre** : dans l'écran "Recettes d'un livre", toutes les recettes (pages normales) sont désormais visibles par défaut, sans toggle. Le regroupement par sections reste disponible pour les membres du groupe.

- **Compteur d'énergie estimée (token usage)** : l'écran "Usage IA" affiche désormais une estimation de l'énergie consommée (en Wh) calculée à partir du nombre total de tokens, pour sensibiliser à l'empreinte énergétique des appels IA.

### v0.13.27 — technique

- **Collection Firestore `planning_config`** :
  - Document par utilisateur : `planning_config/{uid}`.
  - Schéma : `meals_per_cycle: int` (défaut 7), `cycle_start_day: int` (1=Lundi, 7=Dimanche), `batch_cooking_day: int?`, `daily_constraints: Map<String, Map>` (clé = weekday en string), `global_constraints: String`, `default_meal_hour: int`, `default_meal_minute: int`, `calendar_id: String` (identifiant du calendrier Google cible, défaut `'primary'`).
  - Chaque entrée de `daily_constraints` porte `max_prep_minutes`, `target_portions`, `is_batch_cooking`, `notes`, et **facultativement** `meal_hour` / `meal_minute`. Ces deux-là ne sont écrits que si le jour a son heure propre : une clé absente veut dire « comme les autres jours », là où un `null` stocké se confondrait avec minuit.
  - `mealTimeFor(weekday)` est le **seul** endroit qui répond à « à quelle heure mange-t-on ce jour-là » — la sienne s'il en a une, celle par défaut sinon. Deux écrans qui recalculeraient cette règle finiraient par ne plus dire la même heure.
  - `withDefaultMealTime(h, m)` change l'heure par défaut **et** rend tous les jours à elle. Sans cette remise à zéro, régler l'heure globale n'aurait plus d'effet visible dès qu'un seul jour aurait été personnalisé, et il faudrait deviner lesquels des sept résistent.
  - `DayConstraint` : `max_prep_minutes: int`, `is_batch_cooking: bool`, `notes: String`.

- **`PlanningPreferences`** (`lib/features/planning/domain/planning_preferences.dart`) :
  - `nextCycleDates()` : génère la liste des `DateTime` du prochain cycle à partir du `cycleStartDay` et `mealsPerCycle`.
  - `fromFirestore(Map)` / `toFirestore()`.
  - `copyWith(...)`.

- **`PlanningRepository`** — nouvelles méthodes :
  - `addMeals(List<PlannedMeal>)` : batch Firestore pour l'ajout groupé.
  - `updateMealRecipe(id, {recipeId, recipeTitre, durationMinutes, prepMinutes, cookMinutes})` : mise à jour de la recette assignée à un créneau.
  - `updateMealTime(id, DateTime)` : mise à jour de l'heure du créneau.
  - `watchPreferences()` : stream de `PlanningPreferences`.
  - `savePreferences(PlanningPreferences)` : upsert dans `planning_config/{uid}`.
  - `getValidatedRecipes()` : `Future<List<Recipe>>` — recettes validées de l'utilisateur.
  - Providers nouveaux : `planningPreferencesProvider` (`StreamProvider<PlanningPreferences>`).

- **`PlanningAiService`** (`lib/features/planning/services/planning_ai_service.dart`) :
  - Modèle : `gemini-2.5-flash`.
  - `suggestMealPlan({apiKey, recipes, slotDates, dailyConstraints, globalConstraints})` → `Future<List<Recipe?>>`.
  - Prompt structuré : liste des recettes disponibles (titre, temps prep/cuisson, tags), liste des créneaux avec leur jour de la semaine et contraintes, contraintes globales. Retourne un JSON `{ "slots": [{"index": i, "recipe_title": "..."}] }`. Parse chaque entrée en cherchant la recette correspondante par titre normalisé.
  - `suggestSingleSlot({...})` : variante pour un seul créneau.

- **`BatchPlanningScreen`** (`lib/features/planning/presentation/batch_planning_screen.dart`) :
  - Route `/batch-planning`.
  - `ConsumerStatefulWidget`. État : `_slots: Map<int, Recipe?>`, `_slotTimes: Map<int, TimeOfDay>`, `_slotDates: List<DateTime>`.
  - `_init()` : charge les recettes validées via `PlanningRepository.getValidatedRecipes()` et les préférences via `planningPreferencesProvider`.
  - `_applyPrefs(PlanningPreferences)` : initialise les créneaux avec `prefs.nextCycleDates()`.
  - Génération IA globale : appelle `PlanningAiService.suggestMealPlan()`, met à jour `_slots`.
  - Génération IA individuelle : appelle `PlanningAiService.suggestSingleSlot()` pour un créneau (`_generatingSlot` indique l'index en cours).
  - Picker recette : `RecipePickerDialog` avec filtre textuel et suggestion IA.
  - Sauvegarde : `PlanningRepository.addMeals()` avec tous les créneaux non-nuls.

- **`PlanningConfigScreen`** (`lib/features/planning/presentation/planning_config_screen.dart`) :
  - Route `/planning-config`.
  - Champs : `mealsPerCycle` (slider/champ), `cycleStartDay` (dropdown), `defaultMealHour`/`defaultMealMinute` (sélecteur heure), `globalConstraints` (TextField multilignes).
  - Pour chaque jour (Lundi–Dimanche) : `maxPrepMinutes` (TextField numérique), `isBatchCooking` (Switch), `notes` (TextField).
  - Sélection du calendrier Google : appelle `CalendarService.listCalendars(token)` → `DropdownButton` avec les calendriers disponibles (id + summary). Stocké dans `planningPreferences.calendarId`.
  - Sauvegarde : `PlanningRepository.savePreferences()`.

- **`CalendarService`** — évolutions :
  - `listCalendars(token)` : GET `https://www.googleapis.com/calendar/v3/users/me/calendarList` avec scope `calendar.readonly`. Retourne `List<{id, summary}>`.
  - `_getCalendarToken()` : cache le token en session (`static String? _cachedToken`) pour éviter les re-authentifications successives.
  - `createEvent(...)` : utilise `calendarId` depuis les préférences (défaut `'primary'`).
  - Durée des événements : toujours calculée depuis les préférences (`durationMinutes`) plutôt que depuis la recette seule.

- **`GoogleTasksService`** — envoi de la liste de courses dans Google Tasks :
  - scope `https://www.googleapis.com/auth/tasks`, même mécanique de jeton que `CalendarService` (cache de 55 min, popup web / `authorizationClient` mobile) ;
  - `createShoppingList(title, groups)` : POST `users/@me/lists` puis une insertion par rayon (`lists/{id}/tasks`) et une par article avec `?parent={rayon}`. Les sous-tâches donnent la hiérarchie, les cases à cocher sont natives ;
  - le paramètre `previous` conserve l'ordre : sans lui, chaque insertion se place en tête et la liste ressort à l'envers ;
  - seuls les articles **non cochés** sont envoyés.

  **Pourquoi pas Keep** : Keep n'expose aucune API d'écriture. L'export s'y fait par le presse-papier, et coller du texte dans une note ne produit jamais une liste cochable — la conversion est manuelle et aplatit les rayons. Le bouton Keep subsiste en action secondaire, en le disant.

- **`PlanningScreen`** — évolutions :
  - Agrégation d'ingrédients : `_normIngKey()` normalise les accents et pluriels. `_mergeQty()` additionne les quantités compatibles. La liste de courses agrégée (bottom sheet) affiche pour chaque ingrédient la liste des recettes sources.
  - `_MealTile` : heure cliquable (`onTap` sur `CircleAvatar`) → `showTimePicker` → `PlanningRepository.updateMealTime()`.
  - Bouton calendrier individuel sur `_MealTile` (hors kebab menu).
  - Bouton export global calendrier dans l'AppBar : boucle sur tous les repas visibles et crée un événement par repas.
  - Menu kebab `_MealTile` : "Changer la recette" → `RecipePickerDialog` puis `updateMealRecipe()` ; "Vider le créneau" → `updateMealRecipe()` avec `recipeId: null, recipeTitre: 'Repas libre'`.

- **`TokenUsageScreen`** — ajout énergie estimée :
  - Formule : `estimatedWh = totalTokens * 0.0000003` (estimation approximative basée sur consommation GPU).
  - `_SummaryBanner` : affiche le total tokens + l'estimation en Wh ou mWh selon l'ordre de grandeur.

- **Sélection multiple `BookListScreen` / `RecipeListScreen`** :
  - Long press active `_isSelecting = true` + `_selected.add(id)`.
  - AppBar contextuelle : count, `select_all`, `delete_outline` (confirmation rouge).
  - `_batchDelete()` : appelle `BookRepository.deleteBook()` / `RecipeRepository.deleteRecipe()` en parallèle pour les ids sélectionnés.

## 2026-05-14

### v0.13.5 — fonctionnel

- **Écran "Planning des repas"** : un nouvel écran est accessible depuis la barre de navigation principale (5e entrée, icône calendrier, entre Recherche et Brouillons). Il affiche la liste chronologique des repas planifiés de l'utilisateur connecté, groupés par date. Chaque repas affiche l'heure, le titre de la recette et la durée totale. Un appui sur un repas ouvre directement la fiche recette associée. Un bouton poubelle permet de supprimer un repas planifié après confirmation. Les repas passés sont affichés en mode atténué (opacité réduite). Si aucun repas n'est planifié, un écran vide avec message explicatif est affiché.
- **Sauvegarde locale en Firestore** : lors de chaque planification depuis la fiche recette (via le bottom sheet Google Calendar), le repas est désormais également sauvegardé dans Firestore (collection `planned_meals`) avec : identifiant utilisateur, identifiant et titre de la recette, date/heure planifiée, durée totale. Cette sauvegarde alimente l'écran Planning en temps réel via un stream Firestore.

### v0.13.5 — technique

- **Collection Firestore `planned_meals`** :
  - Schéma : `uid: String`, `recipe_id: String?`, `recipe_titre: String`, `planned_at: Timestamp`, `duration_minutes: int`, `created_at: Timestamp`.
  - Indexation Firestore : requête `where('uid', isEqualTo: uid).orderBy('planned_at')`.

- **`PlannedMeal`** (`lib/features/planning/domain/planned_meal.dart`) :
  - Modèle immuable avec `fromFirestore(String id, Map data)` et `toFirestore()`.
  - Champ `id` non inclus dans `toFirestore()` (géré par Firestore).

- **`PlanningRepository`** (`lib/features/planning/presentation/planning_providers.dart`) :
  - `watchMeals()` : stream de `List<PlannedMeal>` filtré par uid, ordonné par `planned_at` asc.
  - `addMeal(PlannedMeal)` : ajoute dans `planned_meals` (id auto-généré).
  - `deleteMeal(String id)` : supprime le document.
  - Provider `planningRepositoryProvider` : `Provider<PlanningRepository?>` — `null` si utilisateur non connecté.
  - Provider `plannedMealsProvider` : `StreamProvider.autoDispose<List<PlannedMeal>>`.

- **`PlanningScreen`** (`lib/features/planning/presentation/planning_screen.dart`) :
  - `ConsumerWidget` — route `/planning`.
  - Groupement des repas par journée (date sans heure) via `Map<DateTime, List<PlannedMeal>>`.
  - `_DayHeader` : affiche la date formatée (intl), "Aujourd'hui" si date du jour, couleur primaire si aujourd'hui, atténuée si passé.
  - `_MealTile` : `Card` avec `CircleAvatar` affichant l'heure, titre, durée, bouton poubelle. Opacité 0.6 si passé. `onTap` → `context.push('/recipes/${meal.recipeId}')` si `recipeId != null`.
  - Suppression : dialogue de confirmation avec `DateFormat('d MMMM à HH:mm', 'fr')`.

- **`schedule_recipe_sheet.dart`** — évolutions :
  - `_ScheduleSheet` devient `ConsumerStatefulWidget` / `_ScheduleSheetState extends ConsumerState`.
  - Nouveau paramètre `String? recipeId` dans `showScheduleRecipeSheet()` et `_ScheduleSheet`.
  - Après `CalendarService.createEvent()` réussi : lit `FirebaseAuth.instance.currentUser?.uid` puis `ref.read(planningRepositoryProvider)?.addMeal(PlannedMeal(...))`.

- **Route `/planning`** dans `app_router.dart` : `AppRoutes.planning = '/planning'`, builder `PlanningScreen`.
- **Navigation** dans `app_shell.dart` : entrée `_NavDestination(AppRoutes.planning, Icons.calendar_month_outlined, 'Planning')` insérée entre Recherche et Brouillons dans `_destinations()`.

## 2026-05-13

### v0.13.4 — fonctionnel

- **Bouton "Planifier" dans la fiche recette** : un bouton avec icône calendrier (`calendar_month_outlined`) apparaît dans l'en-tête de la section Ingrédients de la fiche recette, uniquement si la recette possède des ingrédients structurés. Il s'affiche côte à côte avec le bouton "Liste de courses" existant.
- **Bottom sheet de planification** : un appui sur le bouton Planifier ouvre un bottom sheet permettant de : choisir la date (sélecteur de date, par défaut aujourd'hui), choisir l'heure (sélecteur d'heure, par défaut 19h00), configurer le rappel en minutes (pré-rempli avec le temps de préparation de la recette). La durée est calculée automatiquement à partir des champs `prepTime` et `cookTime` de la recette. Un bouton "Ajouter à Google Calendar" déclenche la création de l'événement.
- **Intégration Google Calendar (API REST OAuth)** : la planification crée un événement "Préparer : [titre]" dans le calendrier Google principal de l'utilisateur, avec description contenant les ingrédients, les temps de préparation/cuisson et un rappel popup configurable. Sur web : OAuth via `FirebaseAuth.signInWithPopup` avec le scope `calendar.events`. Sur mobile/desktop : via `GoogleSignIn.instance.authorizationClient`.

- **Filtre par livre dans la page Brouillons** : dans l'écran "Brouillons", une barre de filtres défilable horizontalement apparaît lorsque les brouillons appartiennent à plusieurs livres différents. Les chips disponibles sont : "Tous" (vue par défaut), "Sans livre" (brouillons non rattachés à un livre), et un chip par livre distinct présent dans la liste. La barre est masquée si tous les brouillons appartiennent au même contexte (zéro ou un seul livre distinct). La sélection d'un chip filtre immédiatement la liste affichée.
- **Suppression d'un livre depuis la liste de ses recettes** : dans l'AppBar de l'écran "Recettes d'un livre", un bouton poubelle apparaît pour les Editors et Admins. Il déclenche un dialogue de confirmation à trois options : Annuler, "Détacher les recettes" (supprime le livre mais conserve toutes les recettes, qui deviennent des recettes libres), "Supprimer aussi les recettes" (supprime le livre ET toutes ses recettes de façon irréversible). Après suppression, l'utilisateur est redirigé vers l'écran d'accueil avec un message de confirmation.

### v0.13.4 — technique

- **`CalendarService`** (`lib/features/planning/services/calendar_service.dart`) :
  - Classe statique. Scope : `'https://www.googleapis.com/auth/calendar.events'`.
  - `_getCalendarToken()` : Web → `FirebaseAuth.signInWithPopup(GoogleAuthProvider()..addScope(scope))` → `OAuthCredential.accessToken`. Mobile/Desktop → `GoogleSignIn.instance.authorizationClient.authorizationForScopes()` puis `authorizeScopes()` si null.
  - `createEvent({titre, startTime, duration, description, reminderMinutes})` : POST `https://www.googleapis.com/calendar/v3/calendars/primary/events` avec header `Authorization: Bearer $token`. Corps JSON : `summary`, `description`, `start/end` en UTC ISO8601, `reminders.overrides` si `reminderMinutes > 0`. Lance `Exception` si statusCode ∉ {200, 201}.

- **`schedule_recipe_sheet.dart`** :
  - `showScheduleRecipeSheet(context, {titre, recipeId?, prepTimeMin, cookTimeMin, ingredients})`.
  - `_ScheduleSheet` — bottom sheet avec : sélecteur de date (`showDatePicker`, firstDate = aujourd'hui - 1j), sélecteur d'heure (`showTimePicker`), champ "Rappel" (TextField numérique, pré-rempli avec `prepTimeMin ?? 30`). Bouton "Ajouter à Google Calendar" → `_addToCalendar()`.
  - `_buildDescription()` : ligne préparation, ligne cuisson, section ingrédients avec `• nom (qty unité)`.

- **`CooklangPreview`** — ajout paramètre `VoidCallback? onSchedule` :
  - Dans `_buildSectionHeader(...)` de la section "Ingrédients" : `action:` devient une `Row` contenant `IconButton(calendar_month_outlined, 'Planifier')` + `IconButton(shopping_cart_outlined, 'Liste de courses')` si les callbacks respectifs sont non-null.

- **`recipe_detail_screen.dart`** : passe `onSchedule:` et `recipeId:` à `CooklangPreview` et `showScheduleRecipeSheet`.

- **Dépendances ajoutées** : `http: ^1.2.0` (POST Calendar API).

- **`DraftListScreen` — filtre par livre** :
  - Nouveau champ `String? _bookFilter` : `null` = tous, `''` = sans livre, sinon `bookId`.
  - Nouveau widget `_BookFilterBar` : barre horizontale de `FilterChip`s construite à partir des `bookId` distincts présents dans la liste `myDrafts`. Chips : "Tous" (selected si `_bookFilter == null`), "Sans livre" (selected si `_bookFilter == ''`), puis un chip par livre distinct (titre récupéré depuis `BookRepository`). Barre invisible si 0 ou 1 livre distinct. Placée au-dessus du `MaterialBanner` dans le `Column` body.
  - Logique de filtrage appliquée dans le callback `data:` : renomme `myDrafts` en `myDraftsAll`, puis produit `myDrafts` filtré selon `_bookFilter` : `null` → `myDraftsAll`, `''` → recettes sans `bookId`, sinon → recettes dont `bookId == _bookFilter`.
  - Appel `setState(() => _bookFilter = ...)` depuis les callbacks `onSelected` des chips.

- **`RecipeListScreen` — suppression de livre depuis la liste** :
  - Nouvelle méthode `Future<void> _confirmDeleteBook(BuildContext context)` sur `_RecipeListScreenState`.
  - Dialogue `AlertDialog` avec 3 actions : "Annuler", "Détacher les recettes" (`_DeleteBookMode.detach`), "Supprimer aussi les recettes" (`_DeleteBookMode.deleteAll`).
  - Mode `detach` : appelle `BookRepository.deleteBook(bookId, detachRecipes: true)` — met `bookId = null` sur toutes les recettes du livre avant de supprimer le document livre.
  - Mode `deleteAll` : appelle `BookRepository.deleteBook(bookId, detachRecipes: false)` — supprime le livre et toutes ses recettes (requête `where('book_id', isEqualTo: bookId)`).
  - `IconButton` avec `Icons.delete_outline` ajouté dans `actions` de l'AppBar, visible uniquement si `inBookContext && canEdit`.
  - Après suppression : `context.go('/')` + `ScaffoldMessenger.showSnackBar` avec message de confirmation.
  - `enum _DeleteBookMode { detach, deleteAll }` ajouté en bas du fichier.

### v0.12.85 — fonctionnel

- **Onglet "Photos" dans le brouillon** : un quatrième onglet "Photos" est disponible dans l'écran de révision des brouillons (`DraftReviewScreen`), visible pour tous. Il affiche les illustrations associées à la recette dans une grille. Le propriétaire peut supprimer individuellement chaque photo. Si la recette possède un fichier source image (scan), un bouton "Extraire les illustrations" (ou "Ré-extraire" si des illustrations existent déjà) permet de lancer l'extraction automatique via l'IA.
- **Bouton IA dans l'AppBar du brouillon** : le propriétaire d'un brouillon dispose d'un bouton ✨ ("Améliorer avec l'IA") dans l'AppBar de l'écran de révision. Un appui ouvre un dialogue permettant de saisir des instructions libres (ex : "Reformate en style Cooklang strict", "Corrige les quantités"). Si la recette a un scan image source, une case à cocher optionnelle "Extraire les illustrations" est proposée. L'IA raffine alors le CookLang + titre + ingrédients selon les instructions, et met à jour le brouillon en place.

### v0.12.85 — technique

- **`DraftReviewScreen` — onglet "Photos"** :
  - Nouveau widget `_IllustrationsTab` : affiche `recipe.imageUrls` dans une `GridView.builder` (crossAxisCount: 3).
  - `_IllustrationCard` : affiche l'image via `CachedNetworkImage` avec un `IconButton` de suppression (visible si `isOwner`). La suppression appelle `RecipeRepository.updateRecipeIllustrations()` pour retirer l'URL du tableau `image_urls`.
  - Bouton "Extraire les illustrations" / "Ré-extraire" : visible si `isOwner && recipe.sourceFileUrl != null && !sourceFileUrl.endsWith('.pdf')`. Appelle `_doExtractIllustrations()`.
  - `_doExtractIllustrations()` : télécharge le fichier source via `http.get(sourceFileUrl)`, appelle `GeminiService.detectIllustrationRegions(bytes, mimeType)`, découpe chaque bounding box avec `img.copyCrop`, uploade chaque crop sous `illustrations/{uid}/{timestamp}_ill_{i}.jpg`, puis appelle `RecipeRepository.updateRecipeIllustrations(recipeId, newUrls)`.
  - Onglet ajouté au `TabController` (index 3 en mode large, index 4 en mode étroit).

- **`DraftReviewScreen` — bouton IA dans AppBar** :
  - `IconButton` avec `Icons.auto_awesome` dans les `actions` de l'AppBar, visible uniquement si `isOwner`.
  - Pendant le raffinage (`_aiRefining == true`), remplacé par `CircularProgressIndicator`.
  - Appelle `_showRefineDialog(recipe)` : `AlertDialog` avec `TextField` (instructions libres) + `CheckboxListTile` "Extraire les illustrations" (visible si scan image disponible).
  - `_doRefine()` : appelle `GeminiService.refineRecipe(currentCooklang, instructions)`, met à jour `_cooklangCtrl.text`, titre et ingrédients dans le formulaire.
  - Si la case est cochée : `_doExtractIllustrations()` lancée en parallèle.
  - `isOwner` contrôle la visibilité : bouton IA, bouton supprimer, bouton valider (propriétaire) vs bouton copier (non propriétaire).

### v0.12.84 — fonctionnel

- **Suivi des tokens IA** : chaque appel Gemini (extraction de recette, détection d'illustrations, recherche, génération, raffinement, etc.) est enregistré dans Firestore sous la collection `ai_usage`. Chaque enregistrement contient : uid utilisateur, fonctionnalité (feature), nombre de tokens en entrée/sortie/total, modèle utilisé, et horodatage.
- **Page "Usage IA"** : accessible depuis le menu compte (icône graphique), elle affiche un tableau récapitulatif de la consommation de tokens, filtrable par fonctionnalité. Les Admins peuvent également filtrer par utilisateur et voir la consommation globale de tous les membres. La page affiche le total d'appels, tokens d'entrée, de sortie et total, agrégés par feature.
- **Suppression du cache** : un bouton "Vider le cache" est disponible dans les paramètres, permettant de forcer la recharge des données depuis Firestore.

### v0.12.84 — technique

- **Collection Firestore `ai_usage`** :
  - Schéma : `uid: String`, `feature: String`, `input_tokens: int`, `output_tokens: int`, `total_tokens: int`, `model: String`, `timestamp: Timestamp` (serverTimestamp).
  - `feature` values : `scan_extraction`, `detect_illustrations`, `search`, `generate`, `refine`, `book_scan`, `recipe_generation`, `chat_refine`.

- **`TokenUsageRepository`** :
  - `logUsage({uid, feature, inputTokens, outputTokens, totalTokens, model})` : ajoute un document dans `ai_usage` avec `FieldValue.serverTimestamp()`.
  - `watchByUser(uid)` : stream ordonné par `timestamp desc`, limit 500.
  - `watchAll()` : stream admin, limit 1000.
  - `static aggregate(records, {filterUid?})` : groupe par `(uid, feature)`, retourne `List<TokenUsageSummary>` triée par total décroissant.

- **`TokenUsageScreen`** :
  - Route `/usage` accessible depuis le menu compte (icône `bar_chart`).
  - `_SummaryBanner` : total appels, total tokens (entrée + sortie).
  - `_FiltersRow` : `DropdownButton` feature + (admin) `DropdownButton` utilisateur.
  - `_SummaryTable` : `DataTable` colonnes : fonctionnalité, appels, tokens entrée, tokens sortie, total. Tri par total décroissant. Formatage avec séparateur milliers.
  - Providers : `myTokenUsageProvider` (user), `allTokenUsageProvider` (admin).

- **Intégration dans `GeminiService`** : chaque appel Gemini (extraction, détection, recherche, génération, raffinement) appelle `TokenUsageRepository.logUsage()` avec les `usageMetadata.inputTokenCount` / `outputTokenCount` de la réponse.

### v0.12.83 — fonctionnel

- **Illustrations dans le brouillon** : les illustrations extraites par l'IA lors du scan (ou extraites manuellement depuis l'onglet Photos) sont stockées dans Firebase Storage sous `illustrations/{uid}/` et associées à la recette via le champ `image_urls`. Elles sont visibles dans l'onglet Photos du brouillon et persistent après validation.
- **Extraction IA depuis le scan** : depuis l'onglet Photos du brouillon, si la recette possède un scan image source, Gemini détecte automatiquement les zones de photographies culinaires dans l'image, découpe chaque région et l'uploade comme illustration séparée. Les illustrations existantes sont remplacées lors d'une ré-extraction.

### v0.12.74 — fonctionnel

- **Fusion "Brouillons & Traitements" en WorkQueue** : les anciens onglets séparés "Brouillons" et "Traitements" sont fusionnés en une seule vue unifiée `WorkQueueScreen`. Cette vue affiche, dans une liste chronologique, à la fois les jobs de traitement en cours/terminés/en erreur et les brouillons de recettes non validés. Trois modes de filtrage sont disponibles : "Mes éléments" (vue par défaut), "Famille" (éléments des membres du groupe), "Tous" (admin uniquement — tous les utilisateurs). En mode famille et admin, les éléments sont regroupés par propriétaire dans des sections rétractables. La sélection multiple reste disponible pour les actions groupées (valider, réessayer, supprimer).

### v0.12.74 — technique

- **`WorkQueueScreen`** (`lib/features/recipes/presentation/drafts/work_queue_screen.dart`) :
  - Remplace les anciens écrans `DraftListScreen` et `ProcessingJobsScreen` séparés.
  - Sealed class `_QueueItem` : `_JobItem(ProcessingJob)` et `_DraftItem(Recipe)` — modèle unifié pour la liste.
  - `_Section` : regroupe les items par owner uid, avec flag `isCollapsed`.
  - `_FilterMode` enum : `me`, `family`, `allUsers`.
  - `_buildSections()` : fusionne jobs et brouillons, trie par date décroissante, regroupe par owner si famille/admin.
  - `isVisible(ProcessingJob)` : un job `queued`/`processing` n'est affiché que **tant qu'il n'a produit aucun brouillon** (`createdRecipeIds.isEmpty`) — au-delà, le `_DraftItem` le représente et une seule ligne subsiste pour un import. Les statuts `error` et `rejected` restent visibles inconditionnellement, brouillon produit ou non.
  - **Sélection multiple** : `Set<String> _selected` avec clés `'j:{jobId}'` ou `'d:{recipeId}'`. Actions groupées : `_batchValidate()`, `_batchRetry()`, `_batchDelete()`.
  - **Providers utilisés** : `processingJobsProvider`, `draftsProvider`, `groupMemberDraftsProvider`, `allProcessingJobsProvider`, `allDraftsProvider`, `isAdminProvider`.
  - Route `/work-queue` (remplace `/drafts` et `/processing-jobs`).

## 2026-05-12

### v0.12.67 — fonctionnel

- **Détection automatique des coins de document** : à l'ouverture de l'écran de recadrage (amélioration d'image), les 4 coins de la page ou du livre visible sont automatiquement détectés par analyse de gradient (Sobel + régression PCA). Une barre de progression orange apparaît en haut de l'image pendant l'analyse (~0,5 s). L'utilisateur peut ensuite affiner manuellement chaque coin. Un bouton ⊕ permet de relancer la détection à tout moment. Si le document n'est pas détectable (fond homogène, faible contraste), les coins reviennent à la position par défaut.
- **Sélection multiple de brouillons** : dans la liste des brouillons, un appui long sur un brouillon active le mode de sélection multiple. L'AppBar contextuelle affiche le nombre de sélections, avec actions "tout sélectionner", "valider" (✓) et "supprimer" (🗑). La validation nécessite une confirmation par dialogue ; la suppression idem (bouton rouge). Le FAB est masqué en mode sélection. Les brouillons des autres membres du groupe restent non sélectionnables (lecture seule).
- **Correction de la déduplication d'ingrédients** : les apostrophes typographiques (' ') et les caractères accentués français (é, è, ê, à, ç, ù, ô, î, â, û) sont normalisés avant le calcul de la clé d'ingrédient, évitant les doublons comme "tronçon d'asperge" × 2 causés par des apostrophes Unicode différentes retournées par Gemini.

### v0.12.67 — technique

- **`ImageEnhancerScreen` — détection automatique des coins** : à l'ouverture, `_runAutoDetect()` est appelée automatiquement. Elle lance `compute(_detectCornersIsolate, _DetectParams)` dans un isolate Dart dédié. Algorithme en 8 étapes :
  1. Décodage et redimensionnement à max 512 px (`img.copyResize`).
  2. Conversion niveaux de gris (`img.grayscale`).
  3. Calcul de la magnitude du gradient Sobel 3×3 sur chaque pixel.
  4. Seuil adaptatif = 85e percentile des magnitudes (borné à [5%, 60%] du max).
  5. Scan depuis les 4 bords (marge 8%) : pour chaque colonne/ligne, premier pixel dépassant le seuil.
  6. Élimination des outliers (trim 10%–90% par coordonnée projetée).
  7. Régression PCA sur chaque nuage → 4 droites en forme générale `(px·x + py·y = r)`.
  8. Intersections (règle de Cramer) → 4 coins ; validation convexité.
  - Retourne `null` si < 10 points détectés sur un bord ou si quadrilatère non convexe → corners par défaut conservés.
  - Indicateur visuel : `LinearProgressIndicator` orange en haut de l'image + bouton ⊕ (`center_focus_strong_outlined`) pour relance manuelle.
  - Nouvelles classes/fonctions top-level : `_DetectParams`, `_detectCornersIsolate`, `_dcSobel`, `_dcTrim`, `_Line2D`, `_dcFitLine`, `_dcIntersect`, `_dcIsConvex`.
  - Nouveau flag d'état : `bool _detecting` dans `_ImageEnhancerScreenState`.

- **`DraftListScreen` — sélection batch** :
  - Nouveau champ `Set<String> _selected` sur l'état.
  - `get _isSelecting` : actif quand `_selected` non vide.
  - Long press sur `_DraftTile` → `_selected.add(id)` → rebuild AppBar.
  - AppBar contextuelle : bouton ✕ (cancel), count badge, `select_all` (tout sélectionner/désélectionner), `check_circle` (valider), `delete_outline` (supprimer).
  - Valider : dialogue de confirmation → `recipeRepo.validateDraft()` pour chaque id sélectionné en parallèle.
  - Supprimer : dialogue de confirmation (rouge) → `recipeRepo.deleteRecipe()`.
  - `_DraftTile` : paramètres `isSelected`, `isSelecting`, `onTap`, `onLongPress` ajoutés. En mode sélection, le leading affiche une `Checkbox` à la place de l'avatar.
  - FAB masqué pendant la sélection (`if (!_isSelecting) FloatingActionButton`).
  - Les brouillons des membres du groupe n'ont pas de callback `onLongPress` (non sélectionnables).

- **`GeminiService._ingredientKey()` / `Recipe._ingredientKey()`** : normalisation des apostrophes typographiques (`'`, `'` → `'`) et des caractères accentués français (é,è,ê→e ; à→a ; ç→c ; ù→u ; ô→o ; î→i ; â→a ; û→u) avant `toLowerCase()` et trimming des pluriels, pour éviter les doublons d'ingrédients dus aux variantes Unicode retournées par Gemini.

### 12/05/2026 — fonctionnel

- **Téléchargement du scan original** : un bouton de téléchargement est disponible à côté du bouton de prévisualisation dans l'en-tête de toute recette disposant d'un fichier source.
- **Scan multi-pages** : lors de l'import d'une recette, l'utilisateur arrive dans un mode "Pages en attente" plutôt qu'un déclenchement immédiat. Il peut accumuler autant de pages qu'il souhaite (via fichier ou caméra), puis lancer l'analyse de toutes les pages en un seul appel Gemini multi-part.
- **Extraction automatique d'illustrations** : pour les scans image (JPEG/PNG), Gemini détecte automatiquement les zones de photographies culinaires. Chaque zone est découpée et uploadée sur Firebase Storage (`illustrations/`), puis associée à la recette créée.
- **Progression détaillée** : dans l'écran "Traitements", le job affiche l'étape courante ("Extraction du texte…", "Extraction des illustrations…") en italique pendant le traitement.
- **Texte collé conservé comme source** : lorsqu'un utilisateur colle un texte dans l'écran "Nouvelle recette" et le met en forme avec l'IA, le texte original est automatiquement uploadé sur Firebase Storage (`scans/`) et attaché à la recette comme fichier source (`sourceFileUrl`). Le bouton de téléchargement de l'original est alors disponible sur la fiche recette, exactement comme pour un scan.

### 12/05/2026 — technique

- **`ProcessingJob`** : ajout de deux champs :
  - `additional_file_urls: List<String>` — URLs Firebase Storage des pages supplémentaires (scan multi-pages).
  - `current_step: String?` — étape courante du traitement ("Extraction du texte…", "Extraction des illustrations…") affichée dans `ProcessingJobsScreen`.
- **`GeminiService.extractRecipes(bytes, mimeType, {additionalPages})`** : signature étendue pour envoyer plusieurs pages en un seul appel `Content.multi([DataPart, ..., TextPart])`.
- **`GeminiService.detectIllustrationRegions(bytes, mimeType)`** : nouvelle méthode — détecte les bounding boxes de photographies culinaires dans une image de recette. Retourne `List<[yMin, xMin, yMax, xMax]>` en coordonnées 0-1000. Utilise `image: ^4.8.0` pour le découpage (`img.copyCrop`).
- **`ScanStatus.pendingFiles`** : nouvel état d'accumulation multi-pages. L'utilisateur accède à cet état après la première sélection d'image pour recette. `isRunning` ne l'inclut pas (l'utilisateur est en contrôle).
- **`ScanState.pendingPageNames: List<String>`** : noms des fichiers en attente, pour affichage dans `ScanScreen`.
- **`ScanUploadNotifier.addPage()`** / **`addPageFromCamera()`** / **`processPages()`** : nouvelles méthodes pour le mode multi-pages.
- **`RecipeRepository.updateRecipeIllustrations(recipeId, imageUrls)`** : met à jour le champ `image_urls` d'une recette après extraction des illustrations.
- **`source_viewer.dart`** : bouton téléchargement ajouté (`url_launcher: ^6.3.1`) à côté du bouton prévisualisation.
- **`RecipeCreateScreen`** : lors d'un traitement IA ("Mettre en forme avec l'IA"), le texte original collé est uploadé sur Firebase Storage (`scans/{uid}/texte_colle_{ts}.txt`) et attaché comme `sourceFileUrl`/`sourceFileName` lors de la sauvegarde.

## 2026-05-08

### 08/05/2026 — fonctionnel

- **Copie cross-utilisateur de recettes/brouillons** : un utilisateur peut copier la recette validée ou le brouillon d'un membre de son groupe dans sa propre collection. La copie d'une recette validée est immédiatement disponible dans les recettes, sans validation nécessaire. La copie d'un brouillon crée un brouillon dans ses brouillons, à valider. La redirection est automatique vers la copie créée.
- **Affichage de l'origine** (auteur + livre) : dans l'AppBar de l'écran brouillon (DraftReviewScreen) et de l'écran détail recette, le nom de l'auteur (icône 👤) et le titre du livre source sont affichés sous le titre si la recette n'appartient pas à l'utilisateur connecté.
- **Protection des validations** : seul le propriétaire d'un brouillon peut le valider ou le supprimer (garde UI + vérification côté dépôt avant écriture). Un non-propriétaire voit uniquement le bouton "Copier".
- **Brouillons des membres du groupe** : l'écran Brouillons propose un toggle 👥 pour afficher les brouillons des membres du groupe, organisés par sections collapsibles par membre.
- **Cover automatique "Mes créations Kass'Dalle ✨"** : le livre IA est créé automatiquement au premier scan. Sa couverture est générée programmatiquement (dart:ui) et uploadée sur Firebase Storage. La migration silencieuse est déclenchée à l'ouverture de la bibliothèque.

### 08/05/2026 — technique

- **`RecipeRepository.copyRecipeAsDraft({recipe, newOwnerUid})`** : crée une copie d'une recette ou d'un brouillon pour un autre utilisateur. Si la recette source est `validated`, la copie est également `validated` et le contenu provient de `rawCooklang`. Si la source est un brouillon, la copie est `draft` et le contenu provient de `draftCooklang ?? rawCooklang`. Les images ne sont pas copiées (`imageUrls: []`), le livre source n'est pas hérité (`bookId: null`).
- **`RecipeRepository.watchDraftsByOwners(List<String> ownerIds)`** : stream de brouillons (`draft` + `inReview`) pour une liste de propriétaires, filtré côté client.
- **`RecipeRepository.validateDraft()`** : vérification d'appartenance avant écriture — lit `created_by` depuis Firestore et lève `StateError` si le caller n'est pas le propriétaire.
- **`groupMemberDraftsProvider`** (Riverpod `StreamProvider`) : stream des brouillons des membres du groupe via `watchDraftsByOwners(memberIds)`.
- **`DraftReviewScreen`** : refactorisé en `ConsumerStatefulWidget`. Toggle 👥 dans l'AppBar pour afficher les brouillons des membres du groupe, organisés par sections collapsibles par membre (`_MemberSectionHeader`). Affichage auteur (icône 👤 + nom) et livre source dans l'AppBar pour les recettes d'autrui. Bouton "Copier" (📋) visible uniquement si non-propriétaire ; boutons Valider/Supprimer uniquement si propriétaire.
- **`RecipeDetailScreen`** : bouton "Copier" (📋) dans l'AppBar pour les recettes d'autrui. Dialogue de confirmation, puis redirection automatique vers la copie.
- **`KassDalleCoverGenerator`** (`lib/core/utils/kassdale_cover_generator.dart`) : génère une image PNG 600×800 avec `dart:ui` (gradient sombre, étoiles, sparkles, texte centré). Utilisé par `BookRepository._uploadGeneratedCover()`.
- **`BookRepository.findOrCreateKassDalleBook(uid)`** : retrouve ou crée le livre IA (`tag __kassdale_ia`), déclenche `_uploadGeneratedCover` si la couverture est absente.
- **`BookRepository.ensureKassDalleBookHasCover(uid)`** : migration silencieuse appelée dans `initState` de `BookListScreen`.

## 2026-05-03

### 03/05/2026 — fonctionnel

- Groupes familiaux : chaque utilisateur gère ses propres livres et recettes. Un utilisateur peut créer un groupe familial, y inviter d'autres membres (recherche par nom/email). Une fois dans un groupe, les livres et recettes validés des autres membres sont visibles par sections dans la bibliothèque et dans les recettes libres.
- Bibliothèque : sections "Mes livres" + "Livres de [membre]" avec toggles par section. Chaque section affiche une grille de livres.
- Recettes libres : sections "Mes recettes" + "Recettes de [membre]" avec toggles par section.
- Brouillons : visibles uniquement pour l'utilisateur connecté (inchangé).
- Traitements (admin) : l'admin voit tous les traitements de tous les utilisateurs avec filtre par utilisateur et affichage du propriétaire sur chaque tuile.
- Téléchargement APK : bouton "Télécharger l'APK Android" dans le menu compte, visible uniquement sur web/desktop. Pointe vers la dernière version intégrée au déploiement Firebase Hosting.
- Déploiement web : l'APK est désormais inclus dans chaque déploiement Firebase Hosting (`app-release.apk` servi sur le même domaine).

### 03/05/2026 — technique

- Ajout de la collection Firestore `groups` pour les groupes familiaux multi-utilisateurs.
- Nouveau domaine `FamilyGroup` (id, name, ownerId, memberIds, createdAt) + `GroupRepository` (watchMyGroups, createGroup, addMember, removeMember, renameGroup, deleteGroup, searchUsers).
- Providers Riverpod : `myGroupsProvider`, `groupMemberIdsProvider`, `visibleUserIdsProvider` pour le calcul de visibilité cross-utilisateur.
- `BookRepository.watchValidatedBooksByOwners(List<String>)` + `RecipeRepository.watchUnattachedByOwners(List<String>)` : requêtes `whereIn created_by` avec filtrage client-side pour éviter les index composites.
- `book_providers` : `groupMemberBooksProvider`, `accessibleBooksProvider` (union mes livres + livres des membres).
- `recipe_providers` : `groupMemberUnattachedRecipesProvider`.
- `BookListScreen` et `RecipeListScreen` convertis en `ConsumerStatefulWidget` avec sections par propriétaire et toggles.
- `ProcessingJobRepository.watchAll()` + `allProcessingJobsProvider` + `adminJobUserFilterProvider` + `filteredAdminJobsProvider`.
- `ProcessingJobsScreen` : vue admin avec filtre utilisateur (dropdown) et affichage du propriétaire sur chaque tuile `_JobTile` (ConsumerWidget).
- `GroupsScreen` : gestion complète des groupes (créer, renommer, supprimer, inviter/retirer membres via recherche temps réel).
- Route `/groups` ajoutée dans `AppRouter`. Accès depuis le menu compte.
- `app_shell.dart` : bouton "Télécharger l'APK Android" dans le menu compte (visible uniquement web/desktop), pointe vers `/app-release.apk` sur Firebase Hosting.
- L'APK est désormais inclus dans chaque déploiement Firebase Hosting.

## 2026-05-02

### 02/05/2026 — fonctionnel

- Ajout d'un mode de scan multi-intentions : recettes, couverture de livre, livre complet.
- Creation de brouillons livre a partir d'une photo de page de garde avec validation explicite.
- Ajout d'un traitement asynchrone en file d'attente : plusieurs imports peuvent etre lances sans attendre la fin du precedent.
- Ajout d'une page "Etat des traitements" pour suivre les scans en cours, termines et en erreur.
- Rattachement automatique des recettes extraites d'un document complet au livre cible, y compris en statut brouillon.
- Ajout/edition des champs structures en brouillon recette : portions, difficulte, temps preparation/cuisson, ingredients structures.
- Ajout/edition des champs structures en brouillon livre : sous-titre, editeur, serie, ISBN, description, tags.

### 02/05/2026 — technique

- Ajout d'un pipeline de traitements asynchrones avec collection Firestore `processing_jobs`.
- Refactor du scan pour supporter trois intentions : `recipeScan`, `bookCoverScan`, `bookDocumentScan`.
- Ajout de la creation de brouillons livre via extraction Gemini sur page de garde.
- Ajout d'un ecran de suivi des jobs de traitement et d'un indicateur de jobs actifs dans l'UI Brouillons.
- Extension du schema `books` (statut de revue, metadonnees structurees, source IA).
- Extension du flux de validation recette pour accepter les editions de champs structures (tags/temps/portions/ingredients).

## 2026-05-01

### 01/05/2026 — fonctionnel

- Activation complete du parcours Android Google Sign-In (certificats debug/release et configuration Firebase Android).
- Ajout d'un profil utilisateur detaille (role, permissions, identite, activite, deconnexion).
- Ajout d'un visualiseur de source recette (image zoomable ou ouverture externe PDF/DOCX).
- Stabilisation du flux d'import scan (correction d'un crash Riverpod lors de la fermeture d'ecran).
- Uniformisation des icones applicatives a partir de l'asset `assets/icon.jpg` pour Android, iOS, Web, Windows et macOS.

---

### 01/05/2026 — technique

- Signature Android release activee via `android/key.properties` et `signingConfigs.release`.
- Configuration Firebase Android mise a jour avec `google-services.json` incluant les clients OAuth Android.
- Build targets validates pour release: Windows (`flutter build windows --release`), Web (`flutter build web --release --base-href /`), Android (`flutter build apk --release`).
- Pipeline d'icones automatise via `flutter_launcher_icons` depuis `assets/icon.jpg` pour Android, iOS, Web, Windows et macOS.
- Correctif de cycle de vie Flutter/Riverpod sur l'ecran de scan (suppression d'un acces `ref` apres `dispose`).

---

