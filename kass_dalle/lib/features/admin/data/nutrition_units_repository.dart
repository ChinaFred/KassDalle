import 'package:cloud_firestore/cloud_firestore.dart';

class NutritionUnitDoc {
  final String id;
  final String normalizedUnit;
  final String displayLabel;
  final List<String> aliases;
  final String measurementType;
  final double? gramsPerUnit;
  final double? volumeMlPerUnit;
  final String status;
  final String source;
  final int seenCount;

  const NutritionUnitDoc({
    required this.id,
    required this.normalizedUnit,
    required this.displayLabel,
    required this.aliases,
    required this.measurementType,
    required this.gramsPerUnit,
    required this.volumeMlPerUnit,
    required this.status,
    required this.source,
    required this.seenCount,
  });

  factory NutritionUnitDoc.fromFirestore(String id, Map<String, dynamic> data) {
    return NutritionUnitDoc(
      id: id,
      normalizedUnit: data['normalized_unit'] as String? ?? id,
      displayLabel: data['display_label'] as String? ?? '',
      aliases: List<String>.from(data['aliases'] as List? ?? const []),
      measurementType: data['measurement_type'] as String? ?? 'unknown',
      gramsPerUnit: (data['grams_per_unit'] as num?)?.toDouble(),
      volumeMlPerUnit: (data['volume_ml_per_unit'] as num?)?.toDouble(),
      status: data['status'] as String? ?? 'pending_review',
      source: data['source'] as String? ?? 'fallback_auto',
      seenCount: (data['seen_count'] as num?)?.round() ?? 0,
    );
  }
}

class NutritionUnitUpsertInput {
  final String normalizedUnit;
  final String displayLabel;
  final List<String> aliases;
  final String measurementType;
  final double? gramsPerUnit;
  final double? volumeMlPerUnit;
  final String status;
  final String source;

  const NutritionUnitUpsertInput({
    required this.normalizedUnit,
    required this.displayLabel,
    required this.aliases,
    required this.measurementType,
    required this.gramsPerUnit,
    required this.volumeMlPerUnit,
    required this.status,
    required this.source,
  });
}

class NutritionUnitsRepository {
  final FirebaseFirestore _firestore;

  NutritionUnitsRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('nutrition_units');

  Stream<List<NutritionUnitDoc>> watchAll({int limit = 1000}) {
    final size = limit < 1 ? 1 : (limit > 4000 ? 4000 : limit);
    return _col
        .orderBy(FieldPath.documentId)
        .limit(size)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => NutritionUnitDoc.fromFirestore(d.id, d.data()))
              .toList(growable: false),
        );
  }

  Future<void> create(NutritionUnitUpsertInput input) async {
    final now = FieldValue.serverTimestamp();
    await _col.doc(input.normalizedUnit).set({
      'normalized_unit': input.normalizedUnit,
      'display_label': input.displayLabel,
      'aliases': input.aliases,
      'measurement_type': input.measurementType,
      'grams_per_unit': input.gramsPerUnit,
      'volume_ml_per_unit': input.volumeMlPerUnit,
      'status': input.status,
      'source': input.source,
      'seen_count': 0,
      'first_seen_at': now,
      'last_seen_at': now,
      'updated_at': now,
      'created_at': now,
    });
  }

  Future<void> update(String docId, NutritionUnitUpsertInput input) async {
    await _col.doc(docId).update({
      'display_label': input.displayLabel,
      'aliases': input.aliases,
      'measurement_type': input.measurementType,
      'grams_per_unit': input.gramsPerUnit,
      'volume_ml_per_unit': input.volumeMlPerUnit,
      'status': input.status,
      'source': input.source,
      'updated_at': FieldValue.serverTimestamp(),
    });
  }

  Future<void> delete(String docId) async {
    await _col.doc(docId).delete();
  }

  /// Insère les unités standard françaises (ne remplace PAS les docs existants).
  ///
  /// Ces valeurs matérialisent dans le référentiel la table de repli intégrée à
  /// [NutritionQuantityConverter], elle-même vérifiée par les fixtures
  /// partagées avec le backend. Toute correction se fait donc des deux côtés.
  ///
  /// Règle de modèle : une unité de VOLUME ne porte QUE son volume. Les grammes
  /// dépendent de la densité de l'ingrédient et sont calculés à l'usage — y
  /// stocker un poids reviendrait à imposer la densité d'un seul ingrédient à
  /// tous les autres.
  Future<({int created, int patched})> seedDefaultUnits() async {
    final defaults = [
      // ── Poids ────────────────────────────────────────────────────────────────
      _def(
        'g',
        'Gramme',
        ['gramme', 'grammes', 'gr'],
        'weight',
        gramsPerUnit: 1,
      ),
      _def(
        'kg',
        'Kilogramme',
        ['kilogramme', 'kilogrammes'],
        'weight',
        gramsPerUnit: 1000,
      ),
      _def(
        'mg',
        'Milligramme',
        ['milligramme', 'milligrammes'],
        'weight',
        gramsPerUnit: 0.001,
      ),
      // ── Petites mesures à poids fixe ─────────────────────────────────────────
      _def(
        'pincee',
        'Pincée',
        ['pincee', 'pincees', 'pinch'],
        'weight',
        gramsPerUnit: 0.5,
      ),
      _def(
        'pointe_de_couteau',
        'Pointe de couteau',
        ['pointe', 'pointe de couteau'],
        'weight',
        gramsPerUnit: 1,
      ),
      // ── Unités botaniques ────────────────────────────────────────────────────
      _def('brin', 'Brin', ['brins', 'sprig'], 'weight', gramsPerUnit: 2),
      _def('filet', 'Filet', ['filets', 'drizzle'], 'weight', gramsPerUnit: 5),
      _def(
        'bouquet',
        'Bouquet',
        ['bouquets', 'bunch'],
        'weight',
        gramsPerUnit: 30,
      ),
      _def(
        'feuille',
        'Feuille',
        ['feuilles', 'leaf'],
        'weight',
        gramsPerUnit: 1,
      ),
      _def('branche', 'Branche', ['branches'], 'weight', gramsPerUnit: 15),
      _def('tige', 'Tige', ['tiges', 'stem'], 'weight', gramsPerUnit: 3),
      _def(
        'noisette',
        'Noisette',
        ['noisettes', 'knob'],
        'weight',
        gramsPerUnit: 5,
      ),
      _def('zeste', 'Zeste', ['zestes'], 'weight', gramsPerUnit: 3),
      // ── Volumes de base ──────────────────────────────────────────────────────
      _def(
        'ml',
        'Millilitre',
        ['millilitre', 'millilitres'],
        'volume',
        volumeMl: 1,
      ),
      _def(
        'cl',
        'Centilitre',
        ['centilitre', 'centilitres'],
        'volume',
        volumeMl: 10,
      ),
      _def(
        'dl',
        'Décilitre',
        ['decilitre', 'decilitres'],
        'volume',
        volumeMl: 100,
      ),
      _def(
        'l',
        'Litre',
        ['litre', 'litres', 'liter'],
        'volume',
        volumeMl: 1000,
      ),
      // ── Cuillères ────────────────────────────────────────────────────────────
      _def(
        'c_a_c',
        'Cuillère à café',
        ['cc', 'cac', 'tsp', 'c.a.c', 'c. à c.'],
        'volume',
        volumeMl: 5,
      ),
      _def(
        'c_a_the',
        'Cuillère à thé',
        ['cuillere a the', 'c. à t.'],
        'volume',
        volumeMl: 5,
      ),
      _def(
        'c_a_d',
        'Cuillère à dessert',
        ['cad', 'c.a.d', 'c. à d.'],
        'volume',
        volumeMl: 10,
      ),
      _def(
        'c_a_s',
        'Cuillère à soupe',
        ['cs', 'cas', 'tbsp', 'c.a.s', 'c. à s.'],
        'volume',
        volumeMl: 15,
      ),
      // ── Verres / tasses / contenants ─────────────────────────────────────────
      _def(
        'verre',
        'Verre moyen',
        ['verres', 'verre_standard'],
        'volume',
        volumeMl: 200,
      ),
      _def(
        'grand_verre',
        'Grand verre à moutarde',
        ['grand_verre', 'verre_200'],
        'volume',
        volumeMl: 200,
      ),
      _def(
        'verre_vin',
        'Verre à vin',
        ['verre_a_vin', 'verre vin'],
        'volume',
        volumeMl: 120,
      ),
      _def(
        'tasse',
        'Tasse',
        ['tasses', 'cup', 'cups'],
        'volume',
        volumeMl: 240,
      ),
      _def(
        'tasse_a_cafe',
        'Tasse à café',
        ['tasses_a_cafe'],
        'volume',
        volumeMl: 70,
      ),
      _def(
        'tasse_metrique',
        'Tasse métrique',
        ['tasses_metriques'],
        'volume',
        volumeMl: 250,
      ),
      _def('bol', 'Bol de cuisine', ['bols'], 'volume', volumeMl: 350),
      _def(
        'quart_de_litre',
        'Quart de litre',
        ['1/4 l', 'quart_l', '25cl'],
        'volume',
        volumeMl: 250,
      ),
      _def(
        'demi_litre',
        'Demi-litre',
        ['1/2 l', 'demi_l', '50cl'],
        'volume',
        volumeMl: 500,
      ),
      // ── Mesures anglo-saxonnes ───────────────────────────────────────────────
      _def(
        'fl_oz',
        'Once liquide américaine',
        ['fl oz', 'fl. oz.'],
        'volume',
        volumeMl: 29.5,
      ),
      _def(
        'uk_fl_oz',
        'Once liquide impériale',
        ['uk fl oz'],
        'volume',
        volumeMl: 28.4,
      ),
      _def(
        'pinte_americaine',
        'Pinte américaine',
        ['pt us', 'pt (US)'],
        'volume',
        volumeMl: 473,
      ),
      _def(
        'pinte_imperiale',
        'Pinte impériale',
        ['pt uk', 'pt (UK)'],
        'volume',
        volumeMl: 568,
      ),
      _def(
        'quart_americain',
        'Quart américain',
        ['qt us', 'qt (US)'],
        'volume',
        volumeMl: 946,
      ),
      _def(
        'gallon_americain',
        'Gallon américain',
        ['gal us', 'gal (US)'],
        'volume',
        volumeMl: 3785,
      ),
      _def('chopine', 'Chopine', ['choppe'], 'volume', volumeMl: 480),
      // ── Très petits volumes ──────────────────────────────────────────────────
      _def('larme', 'Larme', ['larmes'], 'volume', volumeMl: 0.05),
      _def('goutte', 'Goutte', ['gouttes', 'drop'], 'volume', volumeMl: 0.05),
      // ── Comptage ─────────────────────────────────────────────────────────────
      _def('piece', 'Pièce / Unité', [
        'unité',
        'unite',
        'pcs',
        'pce',
        'un',
      ], 'count'),
    ];

    int created = 0;
    int patched = 0;
    final now = FieldValue.serverTimestamp();
    for (final d in defaults) {
      final ref = _col.doc(d.normalizedUnit);
      final snap = await ref.get();
      if (!snap.exists) {
        // Création complète
        await ref.set({
          'normalized_unit': d.normalizedUnit,
          'display_label': d.displayLabel,
          'aliases': d.aliases,
          'measurement_type': d.measurementType,
          'grams_per_unit': d.gramsPerUnit,
          'volume_ml_per_unit': d.volumeMlPerUnit,
          'status': 'known',
          'source': 'builtin',
          'seen_count': 0,
          'first_seen_at': now,
          'last_seen_at': now,
          'updated_at': now,
          'created_at': now,
        });
        created++;
      } else {
        // Enrichissement si les conversions manquent
        final data = snap.data() as Map<String, dynamic>;
        final missingGrams =
            data['grams_per_unit'] == null && d.gramsPerUnit != null;
        final missingVolume =
            data['volume_ml_per_unit'] == null && d.volumeMlPerUnit != null;
        final missingLabel =
            (data['display_label'] as String? ?? '').isEmpty &&
            d.displayLabel.isNotEmpty;
        final missingType =
            (data['measurement_type'] as String? ?? '') == 'unknown' &&
            d.measurementType != 'unknown';
        if (missingGrams || missingVolume || missingLabel || missingType) {
          final patch = <String, dynamic>{'updated_at': now};
          if (missingGrams) patch['grams_per_unit'] = d.gramsPerUnit;
          if (missingVolume) patch['volume_ml_per_unit'] = d.volumeMlPerUnit;
          if (missingLabel) patch['display_label'] = d.displayLabel;
          if (missingType) patch['measurement_type'] = d.measurementType;
          // Garantir le statut known et la source builtin pour les canoniques
          if ((data['status'] as String? ?? '') != 'known') {
            patch['status'] = 'known';
          }
          if ((data['source'] as String? ?? '') == 'fallback_auto') {
            patch['source'] = 'builtin';
          }
          await ref.update(patch);
          patched++;
        }
      }
    }
    return (created: created, patched: patched);
  }

  // type de retour du seed
  static ({int created, int patched}) seedResult(int c, int p) =>
      (created: c, patched: p);

  static NutritionUnitUpsertInput _def(
    String id,
    String label,
    List<String> aliases,
    String type, {
    double? gramsPerUnit,
    double? volumeMl,
  }) => NutritionUnitUpsertInput(
    normalizedUnit: id,
    displayLabel: label,
    aliases: aliases,
    measurementType: type,
    gramsPerUnit: gramsPerUnit,
    volumeMlPerUnit: volumeMl,
    status: 'known',
    source: 'builtin',
  );
}
