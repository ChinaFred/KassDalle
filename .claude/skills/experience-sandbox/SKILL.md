---
name: experience-sandbox
description: Ajouter, faire avancer ou retirer une expérience du bac à sable de Kass'Dalle (Admin › Bac à sable). À utiliser dès qu'une demande parle d'essayer, de prototyper ou d'expérimenter une fonctionnalité avant de l'écrire dans l'application, ou de porter une expérience validée dans sa feature.
---

# Expérience du bac à sable

Les règles complètes sont dans la section « Bac à sable » de `CLAUDE.md`. Ce skill donne
l'ordre des gestes.

## 0. Avant la première ligne : où tournera le code une fois porté ?

Dire, et faire valider, si le code finira **sur l'appareil** (Dart) ou **dans les Functions**
(TypeScript). N'employer que des bibliothèques disponibles là-bas. Exemple à ne pas refaire :
le paquet Dart `image` a imposé que l'extraction d'illustrations reste côté client.

## 1. Ajouter une expérience — tout sous `sandbox/`

Le bac à sable ne modifie jamais le code de l'application. Il peut l'importer et l'appeler.
Pour changer un comportement existant, **copier** le code sous `features/sandbox/` et modifier
la copie.

1. `kass_dalle/lib/features/sandbox/presentation/sandbox_registry.dart` : une entrée
   `Experiment(id:, title:, subtitle:, icon:, builder:)` dans `kExperiments`. L'`id` apparaît
   dans l'URL `/admin/sandbox/<id>` et ne change plus ensuite.
2. `kass_dalle/lib/features/sandbox/presentation/experiments/<nom>_screen.dart` : l'écran.
3. Si l'expérience appelle le serveur : un `case "<id>.<étape>"` dans le `switch` de
   `kass_dalle/functions/src/sandbox/callable.ts`, et la logique dans
   `functions/src/sandbox/<nom>.ts`. Pas de nouvelle fonction exportée : `sandboxFn` reste le
   seul point d'entrée. Chaque `case` appelle `requireAdmin`.
4. Côté client, les appels passent par `SandboxFunctions` (`sandbox/data/sandbox_functions.dart`).

Ni route, ni tuile de menu, ni export dans `index.ts` : les quatre points d'accrochage
(`app_router.dart`, `admin_hub_screen.dart`, l'export de `sandboxFn`, la règle de `CLAUDE.md`)
existent déjà et ne se touchent pas.

Seule exception hors de `sandbox/` : l'inscription d'un poste de coût (section 2), qui touche
`aiRoutingCallable.ts` et `feature_catalog.dart`, comme le prévoit `CLAUDE.md`.

## 2. Un appel de modèle coûte de l'argent réel

Chaque étape qui appelle un modèle a son poste `sandbox_<étape>`, inscrit aux trois endroits
sous le groupe « Bac à sable » : charger le skill `nouveau-poste-ia`. Le `ctx.feature` de
l'appel porte ce poste.

## 3. Règles qui ne changent pas

- **Rien n'est enregistré** : ni Firestore, ni Storage sur un chemin de production. Tout
  reste en mémoire.
- **Aucun `catch` silencieux** : `ErrorReportService`, `feature` préfixée `sandbox.` côté
  Dart ; `logError` côté serveur.
- **Étapes empilées** : chaque bloc de l'écran n'apparaît que si le précédent a abouti. Valider
  un palier avant d'écrire le suivant.
- **Hors release** : rien dans `FunctionalRequirements.md`.

## 4. Porter une expérience validée

Une expérience validée ne se branche pas : elle se **réécrit** dans sa feature, avec tests,
gestion d'erreur et documentation, en suivant la « Chaîne de travail ».

- Prompts, seuils et constantes se recopient **à l'identique**.
- Un calcul qui doit exister des deux côtés rejoint le tableau « Logique dupliquée » avec sa
  fixture : charger le skill `logique-dupliquee`.
- Les postes `sandbox_*` deviennent des postes de production (nouvelles clés). Les anciens
  restent au catalogue comptable et quittent `ROUTABLE_FEATURES`.
- Puis **supprimer** l'expérience : entrée du registre, écran, `case` et fichiers serveur.
