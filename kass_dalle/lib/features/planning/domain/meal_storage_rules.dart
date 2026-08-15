/// Règles de conservation d'un plat préparé à l'avance.
///
/// Ces règles décident du **mode** de conservation à partir du seul délai entre
/// la préparation et le repas. Elles sont volontairement déterministes et
/// tenues hors du modèle : un plat gardé trop longtemps au réfrigérateur ne
/// lève aucune erreur et n'a pas mauvais goût — il rend malade. Ce n'est pas
/// une décision qu'on délègue à une génération de texte.
///
/// Le modèle intervient ensuite, pour dire ce qui est propre à CE plat :
/// contenant, méthode de réchauffage, signes d'alerte. Le mode, lui, se calcule.
///
/// Dupliquées côté serveur dans `functions/src/gemini/storageAdvice.ts`, sous
/// fixture partagée `test-fixtures/meal_storage_rules.json`.
library;

/// Mode de conservation entre la préparation et le repas.
enum MealStorageMode {
  /// Préparé et mangé le jour même : pas de conservation prolongée.
  sameDay,

  /// Réfrigérateur, dans la limite de [kMaxFridgeDays] jours.
  fridge,

  /// Congélateur : au-delà de ce que le réfrigérateur tient sans risque.
  freezer,
}

/// Durée maximale au réfrigérateur pour un plat cuisiné maison, en jours.
///
/// Trois jours est la limite prudente retenue pour un plat cuisiné conservé au
/// froid dès son refroidissement. Certains aliments descendent plus bas — riz
/// cuit, poisson, viande hachée — et c'est au modèle de le signaler pour le
/// plat concerné : la règle générique ne peut que se tromper vers le haut.
const int kMaxFridgeDays = 3;

/// Délai maximal avant la mise au froid, en heures.
const int kMaxCoolingHours = 2;

/// Mode de conservation pour un plat préparé [daysAhead] jours avant le repas.
///
/// Un délai négatif — un jour de préparation postérieur au repas — est traité
/// comme le jour même : c'est une incohérence de saisie, pas une consigne.
MealStorageMode mealStorageMode(int daysAhead) {
  if (daysAhead <= 0) return MealStorageMode.sameDay;
  if (daysAhead <= kMaxFridgeDays) return MealStorageMode.fridge;
  return MealStorageMode.freezer;
}

/// Libellé court du mode, pour une puce d'écran.
String mealStorageLabel(MealStorageMode mode) => switch (mode) {
  MealStorageMode.sameDay => 'Préparé le jour même',
  MealStorageMode.fridge => 'Réfrigérateur',
  MealStorageMode.freezer => 'Congélateur',
};

/// Consigne complète pour un plat préparé [daysAhead] jours à l'avance.
String mealStorageInstruction(int daysAhead) {
  final mode = mealStorageMode(daysAhead);
  final jours = daysAhead > 1 ? '$daysAhead jours' : '1 jour';
  return switch (mode) {
    MealStorageMode.sameDay => 'Préparé et servi le jour même.',
    MealStorageMode.fridge =>
      'À garder $jours au réfrigérateur (4 °C), mis au froid '
          'dans les $kMaxCoolingHours heures suivant la cuisson.',
    MealStorageMode.freezer =>
      'À congeler : $jours d\'avance dépassent les $kMaxFridgeDays jours '
          'que tient un plat cuisiné au réfrigérateur.',
  };
}

/// Nombre de jours entre la préparation et le repas.
///
/// Compté en jours calendaires : préparer le dimanche pour le mercredi fait
/// trois jours, quelle que soit l'heure des deux repas.
int mealStorageDaysAhead({
  required DateTime prepDate,
  required DateTime mealDate,
}) {
  final from = DateTime.utc(prepDate.year, prepDate.month, prepDate.day);
  final to = DateTime.utc(mealDate.year, mealDate.month, mealDate.day);
  return to.difference(from).inDays;
}
