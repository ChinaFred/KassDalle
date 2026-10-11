/// Durées estimées par l'IA pour une recette qui n'en donne pas.
///
/// Le serveur seul écrit le champ racine `estimated_times`
/// (`functions/src/triggers/recipeEstimatedTimes.ts`, déclencheur
/// `onRecipeWritten`, et le backfill « Durées estimées »). Le client le lit
/// pour l'affichage (« ≈ Prép. 20 min »), le filtre « Temps total » et le tri
/// « Plus rapides » d'Explorer. Une durée lue dans la recette — `tags` ou
/// métadonnée CookLang — garde toujours la priorité sur l'estimation.
library;

/// Les deux durées estimées, en minutes. `null` : pas d'estimation pour
/// cette durée (le modèle n'a pas su, ou la recette n'a pas de cuisson).
class RecipeEstimatedTimes {
  final int? prep;
  final int? cook;

  const RecipeEstimatedTimes({this.prep, this.cook});

  /// Lit le champ stocké. `null` quand il manque, qu'il est mal formé, qu'une
  /// estimation est encore en cours (`status: pending`), ou qu'aucune des
  /// deux durées n'a été estimée.
  static RecipeEstimatedTimes? fromMap(Object? raw) {
    if (raw is! Map) return null;
    if (raw['status'] != 'done') return null;
    final prep = _minutes(raw['prep']);
    final cook = _minutes(raw['cook']);
    if (prep == null && cook == null) return null;
    return RecipeEstimatedTimes(prep: prep, cook: cook);
  }

  static int? _minutes(Object? v) => v is num && v > 0 ? v.toInt() : null;
}
