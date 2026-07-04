# Plan de migration UI - Page detail recette (isofonctionnelle)

## Objectif
Migrer vers une UI plus intuitive sans perte de fonctionnalite.

## Strategie
1. Conserver tous les services/repos/providers existants.
2. Limiter les changements a la couche presentation.
3. Introduire une V2 derriere un feature flag avant bascule globale.
4. Verifier la parite fonctionnelle avant suppression de la V1.

## Phases
1. Baseline
- Verrouiller la liste des fonctionnalites existantes.
- Ajouter les tests manquants pour les flux critiques.

2. Coexistence
- Implementer `RecipeDetailScreenV2`.
- Router selon feature flag (`recipe_detail_v2_enabled`).

3. Validation de parite
- Executer la matrice de controle isofonctionnel.
- Verifier les permissions par role (`admin`, `editor`, `reader`).
- Verifier les contextes: recette libre, recette de livre, proprietaire, non proprietaire.

4. Rollout progressif
- Activer V2 pour un sous-ensemble d'utilisateurs.
- Surveiller erreurs runtime et regressions UX.

5. Bascule
- Activer V2 pour tous.
- Conserver rollback rapide pendant la fenetre de stabilisation.

6. Nettoyage
- Retirer V1 uniquement apres stabilisation confirmee.

## Verification obligatoire
- Navigation reader (fleches, swipe, bottom bar, progress)
- Actions AppBar (source, copy, detach, edit, export, delete)
- Meta recette (portions, temps)
- Illustrations (ajout, suppression, galerie)
- Ingrédients / preparation Cooklang
- Liste de courses (replace/merge/checklist/Keep)
- Planning calendar
- Notes personnelles
- Annotations (create/edit/delete + badges)
- Regles de droits

## Outils de controle
- Script presence fonctionnelle: `tools/check-recipe-detail-isofunctionality.ps1`
- Analyse statique Flutter: `flutter analyze`
- Tests cibles UI recette: `flutter test`
