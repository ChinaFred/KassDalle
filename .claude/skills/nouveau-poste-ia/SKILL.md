---
name: nouveau-poste-ia
description: Inscrire un nouveau poste de coût IA (Gemini ou Claude) dans Kass'Dalle — imputation `ctx.feature`, routage `ROUTABLE_FEATURES`, catalogue comptable `kFeatureCatalog` et `kFeatureProcess`, dans le même commit. À utiliser dès qu'un appel `callModel` / `askJson` reçoit une nouvelle valeur de `feature`, qu'une variante `_batch` apparaît, ou qu'une expérience du bac à sable appelle un modèle.
---

# Nouveau poste d'IA

Un poste de coût vit à trois endroits. Un oubli ne lève aucune erreur et ne fausse
aucun montant : le coût est compté, mais il s'affiche sous sa clé technique, rangé
dans « Autres », ou ne peut plus basculer de fournisseur. Les trois modifications
partent dans le **même commit**.

## 0. Choisir la clé

- `snake_case`, en anglais, comme les clés existantes (`storage_advice`, `planning_meal_ideas`).
- Vérifier qu'elle n'existe pas déjà :
  `grep -rn "'<cle>'\|\"<cle>\"" kass_dalle/lib kass_dalle/functions/src`.
- Une variante groupée prend le suffixe `_batch` et devient un poste à part entière.
- Une expérience du bac à sable prend le préfixe `sandbox_`.

## 1. L'imputation — `ctx.feature`

Dans l'appel, côté Functions :

```ts
await callModel({ ctx: { ...ctx, feature: "<cle>" }, ... });
```

Même chose pour `askJson`. Une seule clé par appel : deux appels d'une même chaîne
qu'on veut arbitrer séparément portent deux clés.

## 2. Le routage — `ROUTABLE_FEATURES`

Fichier : `kass_dalle/functions/src/callable/aiRoutingCallable.ts`.

```ts
{ id: "<cle>", label: "<libellé lisible>", group: "<groupe de l'écran Moteur d'IA>" },
```

- Reprendre un `group` existant si le poste en relève (`Import`, `Bac à sable`, …).
- Si un seul fournisseur convient, renseigner `providers` **et** `lockedReason`.
  `setAiRoutingPolicyFn` refuse toute la politique si elle prête au poste un
  fournisseur hors de `providers`.
- Un poste de génération d'image ne va pas ici : il va dans `IMAGE_GENERATION_FEATURES`.

## 3. La lecture comptable — `feature_catalog.dart`

Fichier : `kass_dalle/lib/features/admin/data/feature_catalog.dart`. Deux tables :

```dart
// kFeatureProcess
'<cle>': '<processus existant>',

// kFeatureCatalog
'<cle>': FeatureInfo(label: '<libellé>', description: '<ce que fait l\'appel>'),
```

- Processus existants : `grep -o "': '[^']*'," kass_dalle/lib/features/admin/data/feature_catalog.dart | sort -u`.
- Le libellé est le même que dans `ROUTABLE_FEATURES`.

## 4. Vérifier

```bash
cd kass_dalle && flutter test test/feature_catalog_test.dart
cd kass_dalle/functions && npm run lint && npm run format:check && npm run build
```

`feature_catalog_test.dart` vérifie seulement la cohérence des deux tables Dart entre
elles. Rien ne compare le catalogue Dart à la liste TypeScript : relire les trois
emplacements à la main avant le commit.

## Retrait d'un poste

Un poste dont l'appel disparaît :

- **quitte** `ROUTABLE_FEATURES` : son sélecteur ne commanderait plus rien ;
- **reste** dans `kFeatureCatalog` et `kFeatureProcess` : les mois déjà
  comptabilisés doivent continuer à le nommer.
