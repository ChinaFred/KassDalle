---
name: logique-dupliquee
description: Corriger ou étendre une logique métier qui existe en double en Dart et en TypeScript dans Kass'Dalle — parseur CookLang, parsing de quantité, conversion en grammes, noms d'ingrédients, grille tarifaire, regroupement des courses, rôles de repas, seuils d'hygiène, redressement de page. À utiliser dès qu'un fichier listé dans le tableau « Logique dupliquée Dart ↔ TypeScript » de CLAUDE.md doit changer, ou avant d'écrire une logique qui pourrait exister des deux côtés.
---

# Logique dupliquée Dart ↔ TypeScript

Les fixtures de `kass_dalle/test-fixtures/*.json` sont rejouées par les deux suites. Corriger
un seul côté fait échouer la CI de l'autre. L'ordre ci-dessous évite ce cycle.

## 0. Faut-il vraiment deux côtés ?

Avant d'ajouter une logique au tableau de `CLAUDE.md`, vérifier que **les deux** côtés en ont
un besoin propre : le client pour afficher ou travailler hors ligne, le serveur pour décider
sans lui. Sinon, l'écrire d'un seul côté. `meal_storage_rules` en est l'exemple : la décision
réfrigérateur/congélateur n'existe que côté client, le serveur ne reprend que deux seuils.

Si la logique dépend d'une donnée (prix, taux), déplacer la donnée dans Firestore et ne garder
en double que le calcul. Jamais de valeur de repli figée dans le code.

## 1. Trouver les fichiers

Le tableau « Logique dupliquée » de `CLAUDE.md` donne, pour chaque fixture, le fichier Dart et
le fichier TypeScript. Les suites qui la rejouent :

| Fixture | Test Dart (`kass_dalle/test/`) | Test TypeScript (`functions/src/tests/`) |
|---|---|---|
| `cooklang_parsing.json` | `cooklang_parser_test.dart` | `sharedFixtures.test.ts` |
| `quantity_parsing.json` | `nutrition_quantity_converter_test.dart` | `sharedFixtures.test.ts` |
| `unit_to_grams.json` | `nutrition_quantity_converter_test.dart` | `sharedFixtures.test.ts`, `usualPortion.test.ts` (section `usual_portion`) |
| `ingredient_names.json` | `ingredient_name_test.dart` | `sharedFixtures.test.ts` |
| `ai_pricing.json` | `ai_pricing_test.dart` | `sharedFixtures.test.ts` |
| `page_homography.json` | `page_homography_test.dart` | `sharedFixtures.test.ts` |
| `meal_roles.json` | `meal_role_test.dart` | `mealRole.test.ts` |
| `meal_storage_rules.json` | `meal_storage_rules_test.dart` | `mealStorageRules.test.ts` |
| `shopping_products.json` | `shopping_products_test.dart` | `shoppingProducts.test.ts` |
| `planning_slot_rules.json` | `planning_refusals_test.dart` (constantes et prédicat d'activité de la mémoire des refus) | `planningSlotRules.test.ts` |
| `image_moderation_rules.json` | — (serveur seul) | `moderationDecision.test.ts` |

Vérifier la table avec `grep -rln "<fixture>.json" kass_dalle/test kass_dalle/functions/src/tests`
si un fichier a bougé.

## 2. Écrire le cas dans la fixture d'abord

Ajouter le cas qui reproduit le bug, ou qui décrit le nouveau comportement, dans la section
`cases` (ou la section dédiée) de la fixture. Garder le format des cas voisins. Lancer les
deux suites : elles doivent **échouer** toutes les deux sur ce cas. Un cas qui passe déjà ne
prouve rien.

```bash
cd kass_dalle && flutter test test/<test_dart>.dart
cd kass_dalle/functions && npm test
```

## 3. Corriger les deux côtés, dans le même commit

Même algorithme, mêmes noms de fonctions quand c'est possible. Ne pas « améliorer » un côté au
passage : tout écart non voulu devient une divergence.

Un écart assumé entre les deux côtés vit dans la section `divergences` de `unit_to_grams.json`,
avec sa raison. Le réduire est un objectif ; ne pas en ajouter un pour faire passer la CI.

## 4. Vérifier

```bash
cd kass_dalle && flutter analyze && dart format --output=none --set-exit-if-changed lib test && flutter test
cd kass_dalle/functions && npm run lint && npm run format:check && npm test
```

## 5. Le dire

Le message de commit et la réponse nomment la fixture, le cas ajouté et les deux fichiers
modifiés. `relecteur-regles` contrôle ce point (contrôle 3) : un fichier du tableau modifié
d'un seul côté est une anomalie.
