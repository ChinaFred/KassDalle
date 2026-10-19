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

/// Protéine principale d'un plat ou d'un accompagnement (`tags.main_protein`).
/// Même ordre que `MAIN_PROTEINS` côté serveur, qui seul lit la réponse du
/// modèle ; le client ne fait que l'afficher.
const kMainProteins = [
  'boeuf',
  'porc',
  'volaille',
  'agneau',
  'poisson',
  'fruits_de_mer',
  'oeuf',
  'vegetarien',
  'legumineuses',
];

/// Féculent principal (`tags.main_starch`). Même ordre que `MAIN_STARCHES`.
const kMainStarches = [
  'pates',
  'riz',
  'pommes_de_terre',
  'semoule',
  'pain',
  'aucun',
];

/// Seuls ces rôles portent une protéine et un féculent principaux.
const kRolesWithMainIngredients = ['plat', 'accompagnement'];

/// Libellé d'une protéine. Une valeur inconnue s'affiche telle quelle.
String mainProteinLabel(String protein) => switch (protein) {
  'boeuf' => 'Bœuf',
  'porc' => 'Porc',
  'volaille' => 'Volaille',
  'agneau' => 'Agneau',
  'poisson' => 'Poisson',
  'fruits_de_mer' => 'Fruits de mer',
  'oeuf' => 'Œuf',
  'vegetarien' => 'Végétarien',
  'legumineuses' => 'Légumineuses',
  _ => protein,
};

/// Libellé d'un féculent. Une valeur inconnue s'affiche telle quelle.
String mainStarchLabel(String starch) => switch (starch) {
  'pates' => 'Pâtes',
  'riz' => 'Riz',
  'pommes_de_terre' => 'Pommes de terre',
  'semoule' => 'Semoule',
  'pain' => 'Pain',
  'aucun' => 'Sans féculent',
  _ => starch,
};

/// Ce que la recette apporte déjà (`tags.contains`). Même ordre que
/// `MEAL_COMPONENTS` côté serveur, qui seul lit la réponse du modèle ; le
/// client les propose en pastilles dans « Catégorisation » et les affiche sur
/// la fiche (« Apporte : Protéine, Légume »).
const kMealContains = ['proteine', 'feculent', 'legume'];

/// Libellé d'un apport. Une valeur inconnue s'affiche telle quelle.
String mealContainsLabel(String value) => switch (value) {
  'proteine' => 'Protéine',
  'feculent' => 'Féculent',
  'legume' => 'Légume',
  _ => value,
};

/// [contains] rangé dans l'ordre de [kMealContains], une fois chacun ; les
/// valeurs inconnues suivent, dans leur ordre.
List<String> orderedMealContains(Iterable<String> contains) {
  final set = contains.toSet();
  return [
    for (final c in kMealContains)
      if (set.contains(c)) c,
    for (final c in set)
      if (!kMealContains.contains(c)) c,
  ];
}

/// Ce que la recette apporte une fois le féculent principal choisi : un
/// féculent coche « Féculent », « Sans féculent » (`aucun`) le décoche,
/// « Non renseigné » (`null`) ne change rien.
List<String> mealContainsWithStarch(List<String> contains, String? starch) {
  if (starch == null || starch.isEmpty) return contains;
  final set = contains.toSet();
  if (starch == 'aucun') {
    set.remove('feculent');
  } else {
    set.add('feculent');
  }
  return orderedMealContains(set);
}

/// Ce que vaut `contains` après une suggestion du modèle : [suggested], sauf
/// si la recette a été corrigée à la main ([manual]) — [current] reste alors.
/// Même règle que `containsPatch` côté serveur (`contains_manual_cases` de
/// `test-fixtures/meal_roles.json`).
List<String> mealContainsAfterSuggestion({
  required bool manual,
  required List<String> current,
  required List<String> suggested,
}) => manual ? current : suggested;
