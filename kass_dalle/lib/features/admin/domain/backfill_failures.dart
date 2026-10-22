/// Liste « à revoir » d'un backfill d'Admin › Backfills.
///
/// Chaque backfill renvoie `aRevoir: { items, total }` : les éléments qu'un
/// passage n'a pas pu traiter, nommés, chacun avec sa raison. La liste est
/// plafonnée à cent entrées côté serveur (`_backfillReview.ts`) ; `total`
/// compte au-delà. Elle vit dans la réponse du passage, sans stockage.
library;

/// Nature d'un élément à revoir. Une nature inconnue reste affichée, sans lien.
abstract final class BackfillFailureKind {
  static const ingredient = 'ingredient';
  static const unit = 'unit';
  static const recipe = 'recipe';

  /// Un repas planifié (`planned_meals`) : affiché sans lien.
  static const meal = 'meal';

  /// Un ticket de membre : ouvert dans Admin › Tickets des membres.
  static const ticket = 'ticket';

  /// Une invitation par e-mail : affichée sans lien.
  static const invitation = 'invitation';
}

/// Un élément à revoir : un ingrédient, une unité, une recette, un ticket…
class BackfillFailure {
  final String kind;
  final String id;
  final String label;
  final String reason;

  const BackfillFailure({
    required this.kind,
    required this.id,
    required this.label,
    required this.reason,
  });

  /// `null` quand l'entrée n'a pas d'identifiant lisible : elle ne désigne rien.
  static BackfillFailure? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.trim().isEmpty) return null;
    final kind = raw['kind'];
    final label = raw['label'];
    final reason = raw['reason'];
    return BackfillFailure(
      kind: kind is String ? kind : '',
      id: id.trim(),
      label: label is String && label.trim().isNotEmpty ? label.trim() : id,
      reason: reason is String ? reason.trim() : '',
    );
  }

  /// « nom — raison », la ligne copiée dans le presse-papiers.
  String get copyLine => reason.isEmpty ? label : '$label — $reason';
}

/// Les éléments à revoir d'un passage, et leur nombre total.
class BackfillFailures {
  final List<BackfillFailure> items;

  /// Éléments à revoir, y compris ceux que la liste plafonnée ne porte pas.
  final int total;

  const BackfillFailures({required this.items, required this.total});

  /// La liste ne porte pas tous les éléments comptés.
  bool get truncated => total > items.length;

  /// Lit `aRevoir`. Absent ou mal formé : `null`, et l'écran n'affiche rien
  /// de plus que les compteurs.
  static BackfillFailures? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final rawItems = raw['items'];
    final items = <BackfillFailure>[
      if (rawItems is List)
        for (final entry in rawItems) ?BackfillFailure.fromMap(entry),
    ];
    final rawTotal = raw['total'];
    final total = rawTotal is num ? rawTotal.toInt() : items.length;
    return BackfillFailures(
      items: List.unmodifiable(items),
      total: total < items.length ? items.length : total,
    );
  }
}

/// Compteurs d'un backfill qui n'a pas de compte rendu typé, et sa liste
/// « à revoir ». Les drapeaux valent 1 ou 0, comme avant.
class BackfillCounts {
  final Map<String, int> counts;
  final BackfillFailures? failures;

  const BackfillCounts({required this.counts, this.failures});

  /// Lit les compteurs numériques et booléens de la réponse, et `aRevoir`.
  factory BackfillCounts.fromMap(Map<String, dynamic> data) {
    final out = <String, int>{};
    for (final entry in data.entries) {
      final value = entry.value;
      if (value is num) {
        out[entry.key] = value.toInt();
      } else if (value is bool) {
        out[entry.key] = value ? 1 : 0;
      }
    }
    return BackfillCounts(
      counts: Map.unmodifiable(out),
      failures: BackfillFailures.fromMap(data['aRevoir']),
    );
  }

  int? operator [](String key) => counts[key];
}
