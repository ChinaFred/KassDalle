/// Le rôle d'une recette dans un repas, côté client.
///
/// Les valeurs sont décidées par `functions/src/gemini/mealRole.ts`
/// (`MEAL_ROLES`) : c'est lui qui lit la réponse du modèle et ne garde que
/// celles-là. Le client en a besoin pour deux choses que le serveur ne fait
/// pas : afficher le rôle en français, et le proposer dans une liste où
/// l'utilisateur choisit — relecture d'un import, correction, création.
/// `test-fixtures/meal_roles.json` verrouille l'égalité des deux listes.
library;

/// Même ordre que `MEAL_ROLES` côté serveur.
const kMealRoles = ['plat', 'accompagnement', 'entree', 'dessert', 'snack'];

/// Libellé affiché. Une valeur inconnue s'affiche telle quelle plutôt que de
/// disparaître : on voit ce que la base contient.
String mealRoleLabel(String role) => switch (role) {
  'plat' => 'Plat',
  'accompagnement' => 'Accompagnement',
  'entree' => 'Entrée',
  'dessert' => 'Dessert',
  'snack' => 'Snack',
  _ => role,
};
