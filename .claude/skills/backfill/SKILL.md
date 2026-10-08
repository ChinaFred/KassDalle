---
name: backfill
description: Écrire une opération ponctuelle sur un ensemble de documents Firestore de Kass'Dalle — semer un référentiel, reprendre un champ sur toutes les recettes, rattacher ce qui est orphelin, corriger une grille. À utiliser dès qu'un changement laisse des documents existants à mettre à jour, ou qu'un déploiement crée une donnée à semer. Le livrable est un callable admin réentrant et un bouton dans Admin › Backfills.
---

# Backfill

Toute écriture **une fois** sur un ensemble de documents est un backfill. Elle vit dans
**Admin › Backfills** (`admin_backfills_screen.dart`), jamais dans l'écran du référentiel
concerné, et jamais depuis la machine de développement : rien ne s'écrit dans Firestore de
production hors de l'application.

Exemples à recopier : `functions/src/callable/recipeRolesBackfillCallable.ts` (avec appel de
modèle, curseur, compte rendu relu par l'écran) et `shoppingBackfillCallable.ts` (sans modèle ;
il déclare pourtant les deux secrets, inutiles sans appel de modèle : ne pas les recopier).

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
  `completed`. Pour que l'écran le relise à l'ouverture, le passer en `lastReport` à
  `setBackfillCursor`, qui l'écrit à côté du curseur, puis le lire côté client par
  `lib/features/admin/data/backfill_reports_repository.dart`.
- **Document par document.** Une erreur sur un document est journalisée avec `logError` (id du
  document, contexte) et le traitement continue. Aucun `catch` silencieux.
- `logInfo` final avec le compte rendu, sous le `correlationId` de l'appel.
- S'il appelle un modèle : un poste de coût propre (`backfill_<nom>`), inscrit aux trois
  endroits — charger le skill `nouveau-poste-ia`.

Exporter `backfill<Nom>Fn` dans `functions/src/index.ts`, à côté des autres.

## 2. Le client

- **Repository** : une méthode dans `lib/features/admin/data/gcp_billing_repository.dart`, qui
  appelle `_callViaSdk('backfill<Nom>Fn', payload, timeout: const Duration(minutes: 9))` et
  rend le compte rendu typé (un modèle sous `features/admin/domain/` s'il est relu).
- **Écran** : un bouton dans `admin_backfills_screen.dart`, une méthode `_runBackfill…` qui :
  - ouvre une boîte de confirmation qui dit ce que fait l'opération, son coût (appels de
    modèle ou non, nombre de documents par passage) et qu'on peut la relancer ;
  - passe par `_runBackfill<T>(label:, feature: 'admin_backfill_<nom>', run:, format:)`, qui
    affiche la bannière de progression, le message de résultat, et remonte l'erreur à
    `ErrorReportService`.
- Le message de résultat est chiffré : créés, ignorés, en erreur, restants.

## 3. Documentation, dans le même commit

- `documentation/TechnicalRequirements.md` :
  - §3.13, le document `app_config/<nom>_backfill_checkpoint` s'il existe ;
  - §7.10, une ligne dans le tableau des reprises manuelles (fonction, rôle, ce qu'elle traite).
- `documentation/architecture.html` : une ligne dans le tableau des fonctions.
- `documentation/FunctionalRequirements.md` si le bouton change ce que voit l'administrateur.

## 4. Vérifier, puis le dire

Contrôles de la CI des deux côtés (voir la « Chaîne de travail » de `CLAUDE.md`). La réponse
à l'utilisateur dit **quel bouton lancer** après le déploiement, et combien de passages
attendre.

## Retrait

Un backfill passé au complet peut être retiré : supprimer le callable, son export, la méthode
du repository et le bouton. Laisser un commentaire daté dans `admin_backfills_screen.dart` qui
dit ce qu'il a fait. Mettre à jour §7.10 et `architecture.html`. Son poste de coût reste au
catalogue comptable et quitte `ROUTABLE_FEATURES`.
