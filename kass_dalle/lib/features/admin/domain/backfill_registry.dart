/// Registre des backfills d'Admin › Backfills, côté client.
///
/// Pendant de `functions/src/backfills/registry.ts` : mêmes clés, même
/// classement. Un backfill ajouté à l'écran s'ajoute aux deux.
///
/// - **ponctuel** : reprend un fonds antérieur à une règle ou à un champ. Une
///   fois passé sans reste, il est marqué terminé et descend en bas de
///   l'écran, en attendant d'être retiré du code. Il ne se programme pas.
/// - **récurrent** : a du travail à chaque nouvelle recette ou à chaque
///   nouvel ingrédient. Il garde la date de son dernier passage et se
///   programme (jours + heure de Paris).
library;

enum BackfillKind { ponctuel, recurrent }

/// Clés stables, identiques côté serveur.
abstract final class BackfillKeys {
  static const nutrition = 'nutrition';
  static const enrichReferentials = 'enrich_referentials';
  static const allergens = 'allergens';
  static const recipeRoles = 'recipe_roles';
  static const shoppingProducts = 'shopping_products';
  static const recipeProtein = 'recipe_protein';
  static const estimatedTimes = 'estimated_times';
  static const refreshSodium = 'refresh_sodium';
  static const planningDefaults = 'planning_defaults';
}

class BackfillDefinition {
  final String key;
  final BackfillKind kind;
  final String title;

  /// Une phrase : ce que fait le passage.
  final String description;

  /// Le passage appelle-t-il un modèle, donc est-il facturé ?
  final bool usesAi;

  /// Ce qu'un passage traite au plus, cité dans l'encadré de coût.
  final String passLimit;

  const BackfillDefinition({
    required this.key,
    required this.kind,
    required this.title,
    required this.description,
    required this.usesAi,
    required this.passLimit,
  });

  bool get isRecurrent => kind == BackfillKind.recurrent;
}

/// Ordre fixe de l'écran : les récurrents, puis les ponctuels.
const List<BackfillDefinition> kBackfillRegistry = [
  BackfillDefinition(
    key: BackfillKeys.nutrition,
    kind: BackfillKind.recurrent,
    title: 'Reprendre la nutrition',
    description:
        'Recalcule les recettes dont la nutrition manque ou reste incomplète.',
    usesAi: true,
    passLimit:
        'Chaque passage programmé reprend au plus 20 recettes ; un passage '
        'lancé à la main, 40.',
  ),
  BackfillDefinition(
    key: BackfillKeys.enrichReferentials,
    kind: BackfillKind.recurrent,
    title: 'Enrichir unités et ingrédients',
    description:
        'Estime le poids des unités et la nutrition des ingrédients qui en '
        'manquent. Reprend où il s\'était arrêté.',
    usesAi: true,
    passLimit: 'Chaque passage travaille au plus huit minutes.',
  ),
  BackfillDefinition(
    key: BackfillKeys.allergens,
    kind: BackfillKind.recurrent,
    title: 'Allergènes des ingrédients et des recettes',
    description:
        'Examine les ingrédients sans allergènes, puis recalcule ceux des '
        'recettes.',
    usesAi: true,
    passLimit:
        'Chaque passage examine au plus 400 ingrédients, puis recalcule au '
        'plus 500 recettes.',
  ),
  BackfillDefinition(
    key: BackfillKeys.recipeRoles,
    kind: BackfillKind.recurrent,
    title: 'Rôle des recettes dans un repas',
    description:
        'Classe les recettes non classées : plat, accompagnement, entrée, '
        'dessert ou snack.',
    usesAi: true,
    passLimit: 'Chaque passage traite au plus 40 recettes.',
  ),
  BackfillDefinition(
    key: BackfillKeys.shoppingProducts,
    kind: BackfillKind.recurrent,
    title: 'Recalculer les produits d\'achat',
    description:
        'Refait la liste de courses de toutes les recettes avec la règle du '
        'jour.',
    usesAi: false,
    passLimit: 'Chaque passage recalcule au plus 500 recettes.',
  ),
  BackfillDefinition(
    key: BackfillKeys.recipeProtein,
    kind: BackfillKind.ponctuel,
    title: 'Protéine et féculent des plats',
    description:
        'Pose la protéine et le féculent principaux des plats qui n\'en ont '
        'pas.',
    usesAi: true,
    passLimit: 'Chaque passage traite au plus 40 recettes.',
  ),
  BackfillDefinition(
    key: BackfillKeys.estimatedTimes,
    kind: BackfillKind.ponctuel,
    title: 'Durées estimées',
    description:
        'Estime la préparation et la cuisson des recettes qui n\'en donnent '
        'pas.',
    usesAi: true,
    passLimit: 'Chaque passage traite au plus 160 recettes.',
  ),
  BackfillDefinition(
    key: BackfillKeys.refreshSodium,
    kind: BackfillKind.ponctuel,
    title: 'Reprendre le sel des ingrédients',
    description: 'Corrige le sel compté deux fois dans les ingrédients salés.',
    usesAi: true,
    passLimit: 'Chaque passage travaille au plus huit minutes.',
  ),
  BackfillDefinition(
    key: BackfillKeys.planningDefaults,
    kind: BackfillKind.ponctuel,
    title: 'Contraintes de variété par défaut',
    description:
        'Pose les règles de variété du planning sur les autres comptes, sans '
        'rien effacer.',
    usesAi: false,
    passLimit: 'Chaque passage traite au plus 500 comptes.',
  ),
];

/// La définition d'une clé, ou `null`.
BackfillDefinition? backfillDefinition(String key) {
  for (final def in kBackfillRegistry) {
    if (def.key == key) return def;
  }
  return null;
}
