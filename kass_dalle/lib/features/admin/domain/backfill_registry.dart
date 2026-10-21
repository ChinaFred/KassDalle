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
///
/// Retirés en v0.23.52, une fois terminés en production : `recipe_protein`,
/// `estimated_times` et `planning_defaults`. Retirés en v0.24.33 :
/// `system_books`, `group_planning_reach`, `ticket_analyses`,
/// `ticket_delivered_pr`, `recipe_title_keys` et `invitation_group_owner`.
/// Retirés en v0.24.37 : `illustration_folders` et `illustration_folders_move`.
/// Leurs documents `app_config/backfill_run_<clé>` restent en base ; l'écran
/// ignore une clé absente de ce registre.
library;

enum BackfillKind { ponctuel, recurrent }

/// Clés stables, identiques côté serveur.
abstract final class BackfillKeys {
  static const nutrition = 'nutrition';
  static const enrichReferentials = 'enrich_referentials';
  static const allergens = 'allergens';
  static const recipeRoles = 'recipe_roles';
  static const shoppingProducts = 'shopping_products';
  static const refreshSodium = 'refresh_sodium';
  static const moveMealsToGroup = 'move_meals_to_group';
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

  /// Programmation appliquée par le serveur tant que
  /// `app_config/backfill_schedules` ne dit rien de ce backfill ; `null` sans
  /// défaut. Même valeur que `defaultSchedule` de
  /// `functions/src/backfills/registry.ts` (fixture `backfill_schedule.json`).
  final BackfillDefaultSchedule? defaultSchedule;

  /// Ponctuel paramétré, réutilisable avec d'autres paramètres : le serveur
  /// ne le marque jamais terminé, et le menu ⋮ ne propose pas de le faire.
  /// Propre au client : le serveur l'obtient en rendant un reste inconnu.
  final bool reusable;

  const BackfillDefinition({
    required this.key,
    required this.kind,
    required this.title,
    required this.description,
    required this.usesAi,
    required this.passLimit,
    this.defaultSchedule,
    this.reusable = false,
  });

  bool get isRecurrent => kind == BackfillKind.recurrent;
}

/// Jours ISO (lundi = 1) et heure de Paris d'une programmation par défaut.
class BackfillDefaultSchedule {
  final List<int> days;
  final int hour;

  const BackfillDefaultSchedule({required this.days, required this.hour});
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
    // Remplace l'ancienne tâche `scheduledNutritionCatchUp` (5 h chaque jour).
    defaultSchedule: BackfillDefaultSchedule(
      days: [1, 2, 3, 4, 5, 6, 7],
      hour: 5,
    ),
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
    key: BackfillKeys.refreshSodium,
    kind: BackfillKind.ponctuel,
    title: 'Reprendre le sel des ingrédients',
    description: 'Corrige le sel compté deux fois dans les ingrédients salés.',
    usesAi: true,
    passLimit: 'Chaque passage travaille au plus huit minutes.',
  ),

  // Paramétré (groupe, période) et réutilisable : le serveur ne le marque
  // jamais terminé tout seul, son reste n'est pas compté.
  BackfillDefinition(
    key: BackfillKeys.moveMealsToGroup,
    kind: BackfillKind.ponctuel,
    title: 'Déplacer mes repas vers un groupe',
    description:
        'Fait passer vos repas de « Mon planning », sur une période, dans le '
        'planning d\'un groupe dont vous êtes propriétaire.',
    usesAi: false,
    passLimit:
        'Chaque passage couvre 62 jours au plus et déplace au plus 500 repas.',
    reusable: true,
  ),
];

/// La définition d'une clé, ou `null`.
BackfillDefinition? backfillDefinition(String key) {
  for (final def in kBackfillRegistry) {
    if (def.key == key) return def;
  }
  return null;
}
