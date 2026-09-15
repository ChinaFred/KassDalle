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

  /// Poids d'UNE unité de cet ingrédient, par unité canonique.
  ///
  /// `{ branche: 1, brin: 0.5 }` pour le thym. Même raison que ci-dessus, pour
  /// les unités qui ne sont pas « pièce » : une branche de céleri en pèse 60.
  final Map<String, double> gramsPerUnit;

  /// Vrai quand cet ingrédient ne finit pas dans l'assiette.
  ///
  /// Bain de friture, foin de fumage, gros sel de cuisson : présents dans la
  /// recette, absents du repas. Les compter faussait le total d'un ordre de
  /// grandeur — un litre d'huile de friture pèse 8280 kcal à lui seul.
  final bool notConsumed;

  /// Le produit qu'on achète pour cet ingrédient, sur la liste de courses.
  ///
  /// `null` : jamais examiné. Vide : le nom est déjà le produit. Renseigné :
  /// « beurre » pour « beurre fondu », « œuf » pour « jaune d'œuf ». Posé par
  /// le backfill « Produit acheté des ingrédients », corrigé à la main depuis
  /// l'écran du référentiel. Lu par le serveur quand il compose les produits
  /// d'achat d'une recette.
  final String? shoppingProduct;

  const NutritionIngredientDoc({
    required this.id,
    required this.source,
    required this.qualityStatus,
    required this.per100g,
    this.gramsPerPiece,
    this.gramsPerUnit = const {},
    this.notConsumed = false,
    this.shoppingProduct,
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

    final rawGramsPerUnit = data['grams_per_unit'];
    final gramsPerUnit = <String, double>{};
    if (rawGramsPerUnit is Map) {
      rawGramsPerUnit.forEach((key, value) {
        if (key is String && value is num && value > 0) {
          gramsPerUnit[key] = value.toDouble();
        }
      });
    }

    return NutritionIngredientDoc(
      id: id,
      source: data['source'] as String? ?? '',
      qualityStatus: data['quality_status'] as String? ?? '',
      per100g: per100g,
      gramsPerPiece: rawGramsPerPiece is num && rawGramsPerPiece > 0
          ? rawGramsPerPiece.toDouble()
          : null,
      gramsPerUnit: gramsPerUnit,
      notConsumed: data['not_consumed'] == true,
      shoppingProduct: data['shopping_product'] is String
          ? data['shopping_product'] as String
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
    final unique = <String>{
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

  /// Pose le produit acheté d'un ingrédient.
  ///
  /// Seule écriture du référentiel ouverte au client : à un administrateur,
  /// sur ces champs et eux seuls (règles Firestore). Vide = le nom est déjà
  /// le produit. Les recettes existantes ne le reprennent qu'au backfill
  /// « Recalculer les produits d'achat », ou à leur prochaine écriture.
  Future<void> setShoppingProduct(String id, String value) async {
    try {
      await _firestore.collection('nutrition_ingredients').doc(id).update({
        'shopping_product': value.trim(),
        'shopping_product_source': 'admin',
        'updated_at': FieldValue.serverTimestamp(),
      });
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'nutritionIngredients.setShoppingProduct',
        error: error,
        stackTrace: stackTrace,
        context: {'id': id, 'value': value},
      );
      rethrow;
    }
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
