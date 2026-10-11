/// Allergènes majeurs — les quatorze de l'annexe II du règlement INCO
/// (UE n° 1169/2011), dans l'ordre du règlement.
///
/// Les clés sont décidées par le serveur (`functions/src/nutrition/allergens.ts`),
/// qui seul lit la réponse du modèle et calcule le champ `allergens` d'une
/// recette. Le client les reprend pour l'affichage sur la fiche recette et la
/// correction dans Admin › Référentiels › Ingrédients. La fixture
/// `test-fixtures/allergens.json` verrouille les deux listes.
library;

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

/// Les quatorze clés, dans l'ordre du règlement.
const List<String> kAllergenKeys = [
  'gluten',
  'crustaces',
  'oeuf',
  'poisson',
  'arachide',
  'soja',
  'lait',
  'fruits_a_coque',
  'celeri',
  'moutarde',
  'sesame',
  'sulfites',
  'lupin',
  'mollusques',
];

/// Libellés affichés.
const Map<String, String> kAllergenLabels = {
  'gluten': 'Gluten',
  'crustaces': 'Crustacés',
  'oeuf': 'Œuf',
  'poisson': 'Poisson',
  'arachide': 'Arachide',
  'soja': 'Soja',
  'lait': 'Lait',
  'fruits_a_coque': 'Fruits à coque',
  'celeri': 'Céleri',
  'moutarde': 'Moutarde',
  'sesame': 'Sésame',
  'sulfites': 'Sulfites',
  'lupin': 'Lupin',
  'mollusques': 'Mollusques',
};

/// Libellé d'une clé ; une clé inconnue s'affiche telle quelle.
String allergenLabel(String key) => kAllergenLabels[key] ?? key;

/// Clés triées dans l'ordre du règlement, sans doublon. Une clé inconnue
/// est gardée, en fin de liste : elle s'affiche en clair plutôt que de
/// disparaître.
List<String> sortAllergenKeys(Iterable<String> keys) {
  final wanted = keys.toSet();
  return [
    ...kAllergenKeys.where(wanted.contains),
    ...wanted.where((k) => !kAllergenKeys.contains(k)),
  ];
}

/// Le champ `allergens` d'une recette, écrit par le serveur seul.
///
/// Le client le lit et ne l'écrit jamais : `Recipe.toFirestore` l'omet, et
/// une mise à jour partielle le laisse en place.
class RecipeAllergens {
  /// Clés présentes, dans l'ordre du règlement.
  final List<String> present;

  /// Faux si un ingrédient n'a pas encore été examiné, ou si la recette n'a
  /// aucun ingrédient.
  final bool complete;

  /// Pour chaque clé, les noms d'ingrédients en cause.
  final Map<String, List<String>> byIngredient;

  final DateTime? computedAt;

  const RecipeAllergens({
    required this.present,
    required this.complete,
    this.byIngredient = const {},
    this.computedAt,
  });

  /// `null` quand le champ est absent ou n'est pas un objet.
  static RecipeAllergens? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final present = raw['present'] is List
        ? sortAllergenKeys((raw['present'] as List).whereType<String>())
        : const <String>[];
    final byRaw = raw['by_ingredient'];
    final byIngredient = <String, List<String>>{};
    if (byRaw is Map) {
      for (final entry in byRaw.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! List) continue;
        byIngredient[key] = value.whereType<String>().toList(growable: false);
      }
    }
    final at = raw['computed_at'];
    final computedAt = at is Timestamp
        ? at.toDate()
        : at is DateTime
        ? at
        : null;
    return RecipeAllergens(
      present: present,
      complete: raw['complete'] == true,
      byIngredient: byIngredient,
      computedAt: computedAt,
    );
  }

  /// Ingrédients en cause pour [key], vide s'ils ne sont pas précisés.
  List<String> ingredientsFor(String key) => byIngredient[key] ?? const [];
}
