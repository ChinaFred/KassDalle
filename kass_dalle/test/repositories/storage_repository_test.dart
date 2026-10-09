import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/core/services/gemini_service.dart';
import 'package:kass_dalle/features/recipes/data/storage_repository.dart';
import 'package:kass_dalle/features/recipes/domain/storage_advice.dart';

/// Faux moteur : compte les appels au lieu de joindre `suggestStorageAdviceFn`.
class _CountingGemini extends GeminiService {
  int calls = 0;

  @override
  Future<Map<String, dynamic>> suggestStorageAdvice({
    required String recipeId,
  }) async {
    calls++;
    return {'resume': 'Produit', 'provider': 'google', 'model': 'm'};
  }
}

/// `ensure` ne demande un conseil qu'au créateur de la recette ou à un
/// administrateur : `suggestStorageAdviceFn` refuse les autres (faille 5 de
/// l'audit, v0.23.9). Un conseil déjà enregistré reste lu par tous.
void main() {
  late FakeFirebaseFirestore firestore;
  late _CountingGemini gemini;
  late StorageRepository repo;

  setUp(() {
    firestore = FakeFirebaseFirestore();
    gemini = _CountingGemini();
    repo = StorageRepository(
      firestore: firestore,
      geminiService: gemini,
      errorReportService: ErrorReportService(firestore: firestore),
    );
  });

  bool onlyAuthor(String createdBy) => createdBy == 'auteur';

  test('conseil enregistré : relu par tous, sans appel', () async {
    await firestore.collection('recipes').doc('r').set({
      'created_by': 'auteur',
      'storage_advice': {'resume': 'Stocké'},
    });
    final lookup = await repo.ensure(recipeId: 'r', canGenerate: (_) => false);
    expect((lookup as StorageAdviceAvailable).advice.resume, 'Stocké');
    expect(gemini.calls, 0);
  });

  test('conseil absent, appelant autorisé : un appel', () async {
    await firestore.collection('recipes').doc('r').set({
      'created_by': 'auteur',
    });
    final lookup = await repo.ensure(recipeId: 'r', canGenerate: onlyAuthor);
    expect((lookup as StorageAdviceAvailable).advice.resume, 'Produit');
    expect(gemini.calls, 1);
  });

  test(
    'conseil absent, appelant non autorisé : réservé, aucun appel',
    () async {
      await firestore.collection('recipes').doc('r').set({
        'created_by': 'autre',
      });
      final lookup = await repo.ensure(recipeId: 'r', canGenerate: onlyAuthor);
      expect(lookup, isA<StorageAdviceReserved>());
      expect(gemini.calls, 0);
    },
  );

  test('created_by absent : transmis vide à la décision', () async {
    await firestore.collection('recipes').doc('r').set({'titre': 'x'});
    String? seen;
    await repo.ensure(
      recipeId: 'r',
      canGenerate: (createdBy) {
        seen = createdBy;
        return false;
      },
    );
    expect(seen, '');
    expect(gemini.calls, 0);
  });

  test('recette absente : introuvable, pas « réservé »', () async {
    final lookup = await repo.ensure(
      recipeId: 'absente',
      canGenerate: (_) => false,
    );
    expect(lookup, isA<StorageAdviceRecipeMissing>());
    expect(gemini.calls, 0);
  });
}
