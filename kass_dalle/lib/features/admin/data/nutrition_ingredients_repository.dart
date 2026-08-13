import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_report_service.dart';

class NutritionIngredientDoc {
  final String id;
  final String source;

  /// `estimated_ai`, `estimation_failed`, `verified`, `pending`…
  final String qualityStatus;
  final Map<String, double> per100g;

  /// Poids d'UNE pièce de cet ingrédient, quand le référentiel le connaît.
  ///
  /// Le poids d'une pièce appartient à l'ingrédient — une échalote et un
  /// concombre ne pèsent pas la même chose — et non à l'unité « pièce ».
  final double? gramsPerPiece;

  const NutritionIngredientDoc({
    required this.id,
    required this.source,
    required this.qualityStatus,
    required this.per100g,
    this.gramsPerPiece,
  });

  /// Vrai quand les valeurs viennent d'une estimation IA plutôt que d'une
  /// source vérifiée.
  ///
  /// L'estimation est délibérée : sans elle, l'ingrédient sortirait du calcul
  /// nutritionnel sans laisser de trace. Elle doit en revanche s'annoncer — un
  /// chiffre estimé affiché comme un chiffre mesuré est un mensonge par
  /// omission.
  bool get isAiEstimated =>
      qualityStatus == 'estimated_ai' ||
      source == 'gemini_estimated' ||
      source == 'ai_estimation';

  /// Le profil porte-t-il au moins une valeur exploitable ?
  ///
  /// Un `per100g` rempli de zéros n'est pas un profil : il n'apporte rien au
  /// calcul. Le serveur l'écarte déjà (`normalizeNutrients` ne retient que les
  /// valeurs strictement positives) ; sans ce test, l'app compterait comme
  /// connu un ingrédient que le serveur compte comme manquant.
  bool get hasUsableValues => per100g.values.any((value) => value > 0);

  factory NutritionIngredientDoc.fromFirestore(
    String id,
    Map<String, dynamic> data,
  ) {
    final rawPer100g = data['per100g'];
    final per100g = <String, double>{};
    if (rawPer100g is Map) {
      rawPer100g.forEach((key, value) {
        if (key is String && value is num) {
          per100g[key] = value.toDouble();
        }
      });
    }

    final rawGramsPerPiece = data['grams_per_piece'];

    return NutritionIngredientDoc(
      id: id,
      source: data['source'] as String? ?? '',
      qualityStatus: data['quality_status'] as String? ?? '',
      per100g: per100g,
      gramsPerPiece: rawGramsPerPiece is num && rawGramsPerPiece > 0
          ? rawGramsPerPiece.toDouble()
          : null,
    );
  }
}

class NutritionIngredientsRepository {
  final FirebaseFirestore _firestore;
  final ErrorReportService _errorReportService;

  /// Nombre maximal de valeurs acceptées par Firestore dans un `whereIn`.
  static const int _whereInLimit = 30;

  NutritionIngredientsRepository({
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _errorReportService = errorReportService ?? ErrorReportService();

  /// Profils des seuls ingrédients demandés, indexés par identifiant.
  ///
  /// L'affichage d'une recette chargeait jusqu'ici **tout** le référentiel
  /// (`watchAll`), trié par identifiant et plafonné à 1000 documents. Deux
  /// conséquences : un coût de lecture sans rapport avec les huit ingrédients
  /// réellement affichés, et — dès que le référentiel a dépassé le plafond —
  /// des ingrédients de fin d'alphabet (vin, vinaigre, yaourt) affichés « sans
  /// valeur » alors que le serveur, lui, les trouvait et les comptait dans la
  /// couverture. Deux chiffres contradictoires sur le même écran.
  ///
  /// Firestore limite `whereIn` à 30 valeurs : au-delà, la lecture se fait en
  /// plusieurs requêtes dont les résultats sont fusionnés. Le flux n'émet
  /// qu'une fois chaque requête arrivée, pour ne pas afficher une recette à
  /// moitié documentée puis la voir se compléter sous les yeux du lecteur.
  Stream<Map<String, NutritionIngredientDoc>> watchByIds(Iterable<String> ids) {
    final unique =
        <String>{
          for (final id in ids)
            if (id.trim().isNotEmpty) id.trim(),
        }.toList()..sort();
    if (unique.isEmpty) {
      return Stream.value(const <String, NutritionIngredientDoc>{});
    }

    final chunks = <List<String>>[];
    for (var start = 0; start < unique.length; start += _whereInLimit) {
      final end = start + _whereInLimit;
      chunks.add(
        unique.sublist(start, end > unique.length ? unique.length : end),
      );
    }

    final latest = List<List<NutritionIngredientDoc>>.filled(
      chunks.length,
      const [],
    );
    final received = List<bool>.filled(chunks.length, false);
    final subscriptions =
        <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];
    late final StreamController<Map<String, NutritionIngredientDoc>> controller;

    void emit() {
      if (received.contains(false)) return;
      controller.add({
        for (final docs in latest)
          for (final doc in docs) doc.id: doc,
      });
    }

    controller = StreamController<Map<String, NutritionIngredientDoc>>(
      onListen: () {
        for (var index = 0; index < chunks.length; index++) {
          final chunk = chunks[index];
          final position = index;
          subscriptions.add(
            _firestore
                .collection('nutrition_ingredients')
                .where(FieldPath.documentId, whereIn: chunk)
                .snapshots()
                .listen(
                  (snap) {
                    latest[position] = snap.docs
                        .map(
                          (d) => NutritionIngredientDoc.fromFirestore(
                            d.id,
                            d.data(),
                          ),
                        )
                        .toList(growable: false);
                    received[position] = true;
                    emit();
                  },
                  onError: (Object error, StackTrace stackTrace) {
                    _errorReportService.reportError(
                      feature: 'nutritionIngredients.watchByIds',
                      error: error,
                      stackTrace: stackTrace,
                      context: {'ids': chunk},
                    );
                    controller.addError(error, stackTrace);
                  },
                ),
          );
        }
      },
      onCancel: () async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        subscriptions.clear();
      },
    );

    return controller.stream;
  }

  /// Référentiel complet — réservé à l'écran d'administration qui le liste.
  ///
  /// Ne pas l'utiliser pour afficher une recette : voir [watchByIds].
  Stream<List<NutritionIngredientDoc>> watchAll({int limit = 1000}) {
    final size = limit < 1 ? 1 : (limit > 3000 ? 3000 : limit);
    return _firestore
        .collection('nutrition_ingredients')
        .orderBy(FieldPath.documentId)
        .limit(size)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => NutritionIngredientDoc.fromFirestore(d.id, d.data()))
              .toList(growable: false),
        );
  }
}
