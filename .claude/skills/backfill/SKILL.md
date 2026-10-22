---
name: backfill
description: Écrire une opération ponctuelle ou récurrente sur un ensemble de documents Firestore de Kass'Dalle — semer un référentiel, reprendre un champ sur toutes les recettes, rattacher ce qui est orphelin, corriger une grille. À utiliser dès qu'un changement laisse des documents existants à mettre à jour, ou qu'un déploiement crée une donnée à semer. Le livrable est un callable admin réentrant, classé ponctuel ou récurrent dans les deux registres, et sa tuile dans Admin › Backfills.
---

# Backfill

Toute écriture **une fois** sur un ensemble de documents est un backfill. Elle vit dans
**Admin › Backfills** (`admin_backfills_screen.dart`), jamais dans l'écran du référentiel
concerné, et jamais depuis la machine de développement : rien ne s'écrit dans Firestore de
production hors de l'application.

## 0. Classer : ponctuel ou récurrent — obligatoire

Avant d'écrire, décider de la nature du backfill, et l'inscrire **aux deux registres**, même
clé (`snake_case`, stable) :

- `functions/src/backfills/registry.ts` (`BACKFILLS`) — `{ key, kind, title, usesAi }` ;
- `lib/features/admin/domain/backfill_registry.dart` (`kBackfillRegistry`) — `key`, `kind`,
  `title`, `description` (une phrase), `usesAi`, `passLimit` (ce qu'un passage traite au plus,
  cité dans l'encadré de coût). Ajouter l'icône dans `_BackfillCardState._icons`.
- `kass_dalle/test-fixtures/backfill_schedule.json`, section `registry` : la clé, la nature et
  `uses_ai`, dans l'ordre. Les deux suites vérifient que les registres la suivent (logique
  dupliquée, voir `CLAUDE.md`).

Si le backfill écrit les mêmes documents qu'un autre, l'ajouter à `LOCK_GROUPS`
(`backfills/registry.ts`) : l'un refuse de partir pendant que l'autre tourne.

| Nature | Quand | Ce que l'écran en fait |
|---|---|---|
| `ponctuel` | il reprend un fonds antérieur à une règle ou à un champ ; une fois passé, le flux courant (déclencheur, import) tient les nouveaux documents à jour | section « Ponctuels à lancer », puis « Ponctuels terminés » quand un passage finit sans reste (posé par le serveur) ou quand l'admin le marque. **Ne se programme pas** |
| `recurrent` | chaque nouvelle recette ou nouvel ingrédient lui redonne du travail | section « Récurrents », date du dernier passage, bouton « Programmer » (jours + heure de Paris), lancé par `scheduledBackfills` |

Un ponctuel **n'est terminé automatiquement** que si `summarize` rend `complete: true`,
`remaining: 0` et `toReview: 0` (`shouldAutoMarkDone`, `backfills/schedule.ts`). Un reste
inconnu (`remaining: null`, décompte impossible) n'est pas un reste nul.

Exemples à recopier : `functions/src/callable/recipeRolesBackfillCallable.ts` (avec appel de
modèle, curseur, compte rendu relu par l'écran) et `shoppingBackfillCallable.ts` (sans modèle).

## 1. Le callable — `kass_dalle/functions/src/callable/<nom>BackfillCallable.ts`

La fonction exportée s'appelle `backfill<Nom>Fn` (`backfillRecipeRolesFn`, `backfillShoppingFn`).

- `onCall` avec `region: REGION`, `timeoutSeconds: 540`, `maxInstances: MAX_CALLABLE_INSTANCES`,
  les `cors` de la production, et `secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY]` s'il appelle
  un modèle.
- `const ctx = await requireAdmin(req, FEATURE)` en première ligne.
- **Réentrant.** Un document déjà traité est sauté (sauf option `force`). Relancer ne refait
  rien et ne facture rien de plus.
- **Borné trois fois** : par le délai (`maxMinutes`, marge `DEADLINE_MARGIN_MS` pour écrire le
  curseur), par un nombre de documents par appel, et par trois échecs de suite, qui signalent
  une panne plutôt qu'un document difficile.
- **Point de reprise.** `getBackfillCursor` / `setBackfillCursor` (`_backfillCursor.ts`) dans
  `app_config/<nom>_backfill_checkpoint`. Le curseur revient à `null` quand la collection est
  parcourue en entier. Lire les arguments avec `parseBoolean`, jamais `=== true`.
- **Compte rendu chiffré** rendu par la fonction : examinés, traités, déjà à jour, échoués,
  restants, et les drapeaux `stoppedByDeadline` / `stoppedByBudget` / `stoppedByErrors` /
  `completed`. Il n'est plus écrit à côté du curseur : `runBackfillPass` le recopie, entier, dans
  `app_config/backfill_run_<clé>.last_report`, que l'écran lit en continu
  (`backfill_status_repository.dart`).
- **Verrou et état — `runBackfillFromCallable`** (`backfills/runner.ts`). Après `requireAdmin`,
  le callable rend `runBackfillFromCallable({ key, ctx, appVersion: req.data?.appVersion, run,
  summarize })`. Il pose le verrou par backfill (un second passage reçoit
  `failed-precondition`, que l'écran reconnaît), écrit statut, origine, date, compte rendu,
  pose `termine_*` pour un ponctuel passé sans reste et ajoute `termineAuto` à la réponse.
  `summarize(response)` rend un `PassSummary` : `{ complete, remaining, toReview,
  spendCapHit }`. Accepter `appVersion?: string` dans la requête.
- **Récurrent : sortir la passe.** La passe vit dans une fonction exportée appelable sans
  `req`, `run<Nom>Pass(ctx, options)` avec `options.deadlineMs` absolu, à côté de
  `summarize<Nom>` (exemples : `runRecipeRolesPass`, `runShoppingPass`). Le callable et
  `scheduledBackfills` appellent la même. La brancher dans `scheduledPassFor`
  (`scheduled/backfillSchedule.ts`), avec ses bornes par passage, et, si elle appelle un
  modèle, son poste dans `BUDGET_FEATURES` : le plafond quotidien est consulté avant le
  passage et relu s'il s'arrête avant la fin, au nom de `programme_par_uid`.
- **Liste à revoir — obligatoire.** Chaque élément non traité (erreur, sans réponse du
  modèle, incomplet) s'ajoute à un `BackfillReview` (`_backfillReview.ts`) avec
  `{ kind, id, label, reason }`, `reason` en français simple (« Pas de réponse de l'IA »,
  « Recette incomplète : beurre, farine non examinés »). La réponse porte
  `aRevoir: review.toJSON()` (100 entrées au plus, `total` compté au-delà), recopié dans le
  `last_report` de l'état du backfill par `runBackfillPass`. Un compteur d'erreurs sans noms ne suffit pas : l'admin doit
  pouvoir ouvrir chaque élément.
- **Document par document.** Une erreur sur un document est journalisée avec `logError` (id du
  document, contexte) et le traitement continue. Aucun `catch` silencieux.
- `logInfo` final avec le compte rendu, sous le `correlationId` de l'appel.
- S'il appelle un modèle : un poste de coût propre (`backfill_<nom>`), inscrit aux trois
  endroits — charger le skill `nouveau-poste-ia`.

Exporter `backfill<Nom>Fn` dans `functions/src/index.ts`, à côté des autres.

## 2. Le client

- **Repository** : une méthode dans `lib/features/admin/data/gcp_billing_repository.dart`, qui
  appelle `_callViaSdk('backfill<Nom>Fn', payload, timeout: const Duration(minutes: 9))`, avec
  `'appVersion': kAppVersion` dans le payload, et rend le compte rendu typé (un modèle sous
  `features/admin/domain/` s'il est relu) ou `BackfillCounts`.
- **Écran** : rien à poser à la main hors des registres. Dans `admin_backfills_screen.dart` :
  - `_confirmText` : ce que fait l'opération, son coût (appels de modèle ou non, nombre de
    documents par passage) et qu'on peut la relancer ;
  - `_runPass` : un `case` qui appelle le repository et met en forme le message chiffré
    (créés, ignorés, en erreur, restants), la liste `failures` et `termineAuto` ;
  - `backfillReportSummary` (`backfill_status.dart`) : le résumé chiffré de la tuile, lu
    dans `last_report` (« 38 traitées, 0 restante »).
  La tuile, la bannière, le lien « Voir les N à revoir », le verrou côté écran, le menu ⋮ des
  ponctuels et la programmation des récurrents viennent seuls du registre.

## 2 bis. Programmation d'un récurrent

L'admin règle jours (ISO, lundi = 1) et heure de Paris depuis l'écran ; `setBackfillScheduleFn`
écrit l'entrée dans `app_config/backfill_schedules` avec `programme_par_uid` (l'admin, imputé
au plafond). La tâche `scheduledBackfills` tourne toutes les heures : un récurrent est échu au
jour et à l'heure programmés, ou en reprise d'un passage programmé incomplet (heure suivante,
sauf arrêt par plafond : prochain créneau). Seule la nutrition a un défaut sans réglage
(`defaultSchedule` au registre, tous les jours à 5 h). La tâche l'applique et l'écrit dans
`app_config/backfill_schedules` au premier tick qui ne le trouve pas ; d'ici là, l'écran
l'affiche « (par défaut) » et l'éditeur en part. Un nouveau récurrent n'a pas de défaut, sauf
décision explicite : `defaultSchedule` dans les deux registres et dans la section `registry`
de la fixture.

Un passage programmé part au nom de son auteur, s'il est encore administrateur (sinon : erreur
« L'auteur de la programmation n'est plus administrateur. », plus de reprise), et sous le
plafond de **base**, sans le multiplicateur du compte (`runWithBaseBudgetCap`). La nutrition
fait exception : imputée au propriétaire de chaque recette, multiplicateurs compris.
`app_config/backfill_schedules` et `backfill_run_*` ne s'écrivent que par le serveur : les
règles Firestore refusent l'écriture client, administrateur compris.

## 3. Documentation, dans le même commit

- `documentation/TechnicalRequirements.md` :
  - §3.13, le document `app_config/<nom>_backfill_checkpoint` s'il existe, et la clé du
    registre dans la liste des backfills ;
  - §7.10, une ligne dans le tableau des reprises manuelles (fonction, rôle, ce qu'elle traite),
    et pour un récurrent ses bornes par passage programmé.
- `documentation/architecture.html` : une ligne dans le tableau des fonctions.
- `documentation/FunctionalRequirements.md` si le bouton change ce que voit l'administrateur.

## 4. Vérifier, puis le dire

Contrôles de la CI des deux côtés (voir la « Chaîne de travail » de `CLAUDE.md`). La réponse
à l'utilisateur dit **quel bouton lancer** après le déploiement, et combien de passages
attendre.

## Retrait

**D'abord, demander la liste.** Une session ne voit pas l'écran de production. Avant tout
retrait, demander à l'utilisateur le texte de **Admin › Backfills › Ponctuels terminés ›
« Copier la liste »** : une ligne par ponctuel terminé, au format
`clé — titre — terminé le JJ/MM/AAAA en vX.Y.Z — automatique | marqué à la main — dernier
compte rendu : … — à revoir : N`. Ne retirer que les clés qui y figurent. Un ponctuel
« marqué à la main », ou dont la ligne dit « à revoir » supérieur à 0, se signale à
l'utilisateur avant le retrait : son travail n'est peut-être pas fini. Sans ce texte, ne rien
retirer.

Un **ponctuel terminé** (section « Ponctuels terminés », mention « à retirer du code ») sort
du code une fois son travail fait en production : supprimer le callable, son export, la méthode
du repository, son entrée dans **les deux registres**, son `case` dans `_runPass` et
`_confirmText`, son résumé dans `backfillReportSummary` et son icône. Laisser un commentaire daté
dans `admin_backfills_screen.dart` qui dit ce qu'il a fait. Mettre à jour §3.13, §7.10 et
`architecture.html`. Le document `app_config/backfill_run_<clé>` reste en base, plus rien ne le
lit. Son poste de coût reste au catalogue comptable et quitte `ROUTABLE_FEATURES` ; son libellé
de journal reste.

Avant de supprimer une fonction exportée par le callable, la chercher par son nom côté
Functions et côté Dart, tests exclus : une logique partagée avec un déclencheur ou l'import
reste (exemple : `titleKeyUpdate`, que `onRecipeWritten` appelle encore), une fonction que
seul le callable appelait part avec lui (exemple : `refreshTicketAnalyses`, v0.24.33).
Compléter le commentaire « Retirés en … » de `registry.ts` et de `backfill_registry.dart`,
et ajouter les clés au tableau ci-dessous, dans le même commit.

Un récurrent ne se retire pas ainsi : il se déprogramme, ou change de nature par décision
explicite (puis suit la règle du ponctuel).

## Backfills retirés

Ce qui a tourné en production puis quitté le code. Une session qui cherche pourquoi un champ
existe sur les documents anciens, ou ce que contient un `app_config/backfill_run_<clé>`
resté en base, commence ici. Le détail de chaque passage est dans le `CHANGELOG.md` de la
version d'ajout.

| Clé | Titre | Callable | Terminé en production | Retiré en |
|---|---|---|---|---|
| — | Reprendre la confidentialité des livres | `backfillBookPrivacyFn` | — | v0.23.14 |
| — | — | `backfillUserProfilesFn`, `backfillGroupReachFn` | — | v0.23.23 |
| `recipe_protein` | Protéine et féculent des plats | `backfillRecipeProteinFn` | — | v0.23.52 |
| `estimated_times` | Durées estimées | `backfillEstimatedTimesFn` | — | v0.23.52 |
| `planning_defaults` | Contraintes de variété par défaut | `backfillPlanningDefaultsFn` | — | v0.23.52 |
| `system_books` | Livres système des comptes | `backfillSystemBooksFn` | le 13/10/2026, v0.23.51 | v0.24.33 |
| `group_planning_reach` | Portée des groupes et des plannings | `backfillGroupPlanningReachFn` | le 13/10/2026, v0.23.58 | v0.24.33 |
| `ticket_analyses` | Analyses des tickets | `backfillTicketAnalysesFn` | le 14/10/2026, v0.23.63 | v0.24.33 |
| `ticket_delivered_pr` | PR des tickets livrés | `backfillTicketDeliveredPrFn` | le 17/10/2026, v0.23.99 | v0.24.33 |
| `recipe_title_keys` | Clé de titre des recettes | `backfillTitleKeysFn` | le 17/10/2026, v0.23.97 | v0.24.33 |
| `invitation_group_owner` | Propriétaire du groupe des invitations | `backfillInvitationGroupOwnerFn` | le 19/10/2026, v0.24.14 | v0.24.33 |
| `illustration_folders` | Dossiers des illustrations | `backfillIllustrationFoldersFn` | le 21/10/2026, v0.24.36 | v0.24.37 |
| `illustration_folders_move` | Ranger les illustrations | `backfillIllustrationFoldersMoveFn` | le 21/10/2026, v0.24.36 | v0.24.37 |
| `move_meals_to_group` | Déplacer mes repas vers un groupe | `backfillMoveMealsToGroupFn` | — (réutilisable, jamais terminé ; dernier passage le 14/10/2026) | v0.24.44 |
| `default_units` | Semer les unités standard | `backfillDefaultUnitsFn` | le 21/10/2026, v0.24.41 | v0.24.51 |
| `users_schema_check` | Contrôler les comptes | `backfillUsersSchemaCheckFn` | le 22/10/2026, v0.24.46 | v0.24.51 |

Un tiret signale une information que le dépôt ne garde pas. Les autres opérations retirées
avant le registre (v0.23.45), sans version de retrait connue, sont décrites dans le
commentaire de fin de `admin_backfills_screen.dart`.
