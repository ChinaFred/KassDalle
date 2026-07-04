# Matrice de parite isofonctionnelle - Page detail recette

## Statuts
- OK: present et valide
- TODO: non verifie
- KO: manquant ou regression

## Controle
| ID | Fonction | Emplacement actuel | Cible V2 | Statut | Preuve |
|---|---|---|---|---|---|
| RD-001 | Navigation reader viewport | RecipeDetailScreen | Header/zone navigation V2 | OK | presence code |
| RD-002 | Bottom bar precedent/suivant | RecipeDetailScreen | Barre navigation V2 | OK | presence code |
| RD-003 | Bouton annoter (FAB) | RecipeDetailScreen | Action principale V2 | OK | presence code |
| RD-004 | Affichage badges annotations | RecipeDetailAppBar | Header V2 | OK | presence code |
| RD-005 | Scroll vers section annotations | AppBar badge tap | Onglet Communaute | OK | presence code |
| RD-006 | Source viewer original | AppBar action | Onglet Sources | OK | presence code |
| RD-007 | Download source | Source viewer | Onglet Sources | OK | presence code |
| RD-008 | Copier comme brouillon | AppBar action | Onglet Sources | OK | presence code |
| RD-009 | Detacher du livre | AppBar action | Onglet Sources | OK | presence code |
| RD-010 | Modifier recette | AppBar action | Onglet Sources | OK | presence code |
| RD-011 | Export PDF | AppBar action | Action principale V2 | OK | presence code |
| RD-012 | Supprimer recette | AppBar action | Danger zone | OK | presence code |
| RD-013 | Controle portions | CooklangPreview | Bloc meta V2 | OK | presence code |
| RD-014 | Recalcul ingredients | CooklangPreview | Bloc ingredients V2 | OK | presence code |
| RD-015 | Temps prep/cuisson | CooklangPreview | Bloc meta V2 | OK | presence code |
| RD-016 | Miniatures illustrations | CooklangPreview | Bloc illustrations | OK | presence code |
| RD-017 | Ajout illustration | CooklangPreview | Bloc illustrations | OK | presence code |
| RD-018 | Suppression illustration | CooklangPreview | Bloc illustrations | OK | presence code |
| RD-019 | Galerie fullscreen | recipe_detail_illustrations | Bloc illustrations | OK | presence code |
| RD-020 | Ingrédients section | CooklangPreview | Onglet Preparer | OK | presence code |
| RD-021 | Preparation section | CooklangPreview | Onglet Preparer | OK | presence code |
| RD-022 | Categorisation tags | CooklangPreview | Onglet Preparer | OK | presence code |
| RD-023 | Liste de courses | shopping_list_sheet | Action ingredients | OK | presence code |
| RD-024 | Planning calendar | schedule_recipe_sheet | Action ingredients | OK | presence code |
| RD-025 | Ma note (editor) | recipe_rating_widget | Onglet Communaute | OK | presence code |
| RD-026 | Badge note compacte | recipe_rating_widget | Header V2 | OK | presence code |
| RD-027 | Liste annotations | recipe_detail_annotations | Onglet Communaute | OK | presence code |
| RD-028 | Ajouter annotation | AnnotationDialog | Onglet Communaute | OK | presence code |
| RD-029 | Editer annotation | AnnotationTile | Onglet Communaute | OK | presence code |
| RD-030 | Supprimer annotation | AnnotationTile | Onglet Communaute | OK | presence code |
| RD-031 | Couverture recette libre (owner) | AppBar | Header V2 | OK | presence code |
| RD-032 | Zoom couverture | RecipeDetailScreen | Header V2 | OK | presence code |

## Verification par role
| Role | Peut voir | Peut annoter | Peut noter | Peut editer | Peut supprimer |
|---|---|---|---|---|---|
| admin | oui | oui | oui | oui | oui |
| editor | oui | oui | oui | selon ownership/regles | selon ownership/regles |
| reader | oui | oui (si connecte) | oui (si connecte) | non | non |

## Verification par contexte
| Contexte | Points obligatoires |
|---|---|
| Recette de livre | navigation reader + liens livre + source |
| Recette libre | couverture libre + libelle recette libre |
| Proprietaire | edition + suppression + illustrations |
| Non proprietaire | copy as draft + owner label |
