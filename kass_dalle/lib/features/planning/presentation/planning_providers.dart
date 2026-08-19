import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/gemini_providers.dart';
import '../../auth/presentation/auth_providers.dart';
import '../services/planning_ai_service.dart';
import '../../books/data/book_repository.dart';
import '../../recipes/domain/recipe.dart';
import '../domain/planned_meal.dart';
import '../domain/planning_preferences.dart';

// ── Repository ─────────────────────────────────────────────────────────────────

class PlanningRepository {
  final FirebaseFirestore _db;
  final String _uid;

  PlanningRepository(this._db, this._uid);

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection('planned_meals');

  /// Identifiant de l'utilisateur courant.
  String get uid => _uid;

  DocumentReference<Map<String, dynamic>> get _prefsDoc =>
      _db.collection('planning_config').doc(_uid);

  // ── Repas planifiés ─────────────────────────────────────────────────────────

  /// Profondeur d'historique affichée dans le planning.
  ///
  /// Sans borne, l'écran recharge la totalité des repas jamais planifiés à
  /// chaque ouverture — une facture de lectures qui ne fait que croître.
  static const historyWindow = Duration(days: 90);

  /// Stream des repas planifiés de l'utilisateur, triés par date.
  Stream<List<PlannedMeal>> watchMeals() {
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day).subtract(historyWindow);
    return _col
        .where('uid', isEqualTo: _uid)
        .where('planned_at', isGreaterThanOrEqualTo: Timestamp.fromDate(from))
        .orderBy('planned_at')
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => PlannedMeal.fromFirestore(d.id, d.data()))
              .toList(),
        );
  }

  /// Ajoute un repas planifié.
  Future<void> addMeal(PlannedMeal meal) async {
    await _col.add(meal.toFirestore());
  }

  /// Ajoute un lot de repas planifiés (batch planning).
  Future<void> addMeals(List<PlannedMeal> meals) async {
    final batch = _db.batch();
    for (final meal in meals) {
      batch.set(_col.doc(), meal.toFirestore());
    }
    await batch.commit();
  }

  /// Supprime un repas planifié.
  Future<void> deleteMeal(String id) async {
    await _col.doc(id).delete();
  }

  /// Repas déjà planifiés entre [from] et [to], journées entières incluses.
  ///
  /// Sert à savoir ce qu'un nouveau cycle recouvre : sans cette lecture, valider
  /// un planning empile deux repas sur le même créneau sans le dire.
  Future<List<PlannedMeal>> getMealsBetween({
    required DateTime from,
    required DateTime to,
  }) async {
    final start = DateTime(from.year, from.month, from.day);
    final end = DateTime(to.year, to.month, to.day, 23, 59, 59, 999);
    final snap = await _col
        .where('uid', isEqualTo: _uid)
        .where('planned_at', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('planned_at', isLessThanOrEqualTo: Timestamp.fromDate(end))
        .get();
    return snap.docs
        .map((d) => PlannedMeal.fromFirestore(d.id, d.data()))
        .toList();
  }

  /// Supprime un lot de repas planifiés.
  Future<void> deleteMeals(List<String> ids) async {
    if (ids.isEmpty) return;
    final batch = _db.batch();
    for (final id in ids) {
      batch.delete(_col.doc(id));
    }
    await batch.commit();
  }

  /// Met à jour la recette d'un repas planifié existant.
  Future<void> updateMealRecipe(
    String id, {
    required String? recipeId,
    required String recipeTitre,
    required int durationMinutes,
    int? prepMinutes,
    int? cookMinutes,
    int? basePortions,
    int? targetPortions,
    bool clearPortions = false,
  }) async {
    final payload = <String, dynamic>{
      'recipe_id': recipeId,
      'recipe_titre': recipeTitre,
      'duration_minutes': durationMinutes,
      'prep_minutes': ?prepMinutes,
      'cook_minutes': ?cookMinutes,
      'base_portions': ?basePortions,
      'target_portions': ?targetPortions,
    };
    if (clearPortions) {
      payload['base_portions'] = FieldValue.delete();
      payload['target_portions'] = FieldValue.delete();
    }
    await _col.doc(id).update(payload);
  }

  /// Met à jour l'heure d'un repas planifié existant.
  Future<void> updateMealTime(String id, DateTime newTime) async {
    await _col.doc(id).update({'planned_at': Timestamp.fromDate(newTime)});
  }

  // ── Préférences de planning ─────────────────────────────────────────────────

  /// Stream des préférences de planning de l'utilisateur.
  Stream<PlanningPreferences> watchPreferences() {
    return _prefsDoc.snapshots().map(
      (snap) => snap.exists
          ? PlanningPreferences.fromFirestore(snap.data()!)
          : const PlanningPreferences(),
    );
  }

  /// Lecture ponctuelle des préférences, pour les écrans qui les éditent.
  ///
  /// Un `snapshots()` peut émettre d'abord un document absent venu du cache ;
  /// un écran d'édition qui se verrouille sur cette première valeur présente
  /// les défauts et les réenregistre par-dessus les vraies préférences.
  Future<PlanningPreferences> loadPreferences() async {
    final snap = await _prefsDoc.get();
    return snap.exists
        ? PlanningPreferences.fromFirestore(snap.data()!)
        : const PlanningPreferences();
  }

  /// Sauvegarde les préférences de planning.
  Future<void> savePreferences(PlanningPreferences prefs) async {
    await _prefsDoc.set(prefs.toFirestore(), SetOptions(merge: true));
  }

  /// Récupère les recettes correspondant aux [ids] donnés, par lots de 30.
  ///
  /// Un repas planifié peut pointer sur un brouillon ou une recette de la
  /// famille : les résoudre par identifiant évite qu'ils disparaissent
  /// silencieusement de la liste de courses.
  Future<List<Recipe>> getRecipesByIds(List<String> ids) async {
    final unique = ids.where((id) => id.isNotEmpty).toSet().toList();
    if (unique.isEmpty) return [];
    final out = <Recipe>[];
    for (var i = 0; i < unique.length; i += 30) {
      final chunk = unique.sublist(i, (i + 30).clamp(0, unique.length));
      final snap = await _db
          .collection('recipes')
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      out.addAll(snap.docs.map((d) => Recipe.fromFirestore(d.id, d.data())));
    }
    return out;
  }

  // ── Recettes disponibles ────────────────────────────────────────────────────

  /// Récupère toutes les recettes validées de l'utilisateur pour la sélection
  /// et la génération AI.
  Future<List<Recipe>> getValidatedRecipes() async {
    final snap = await _db
        .collection('recipes')
        .where('created_by', isEqualTo: _uid)
        .where('review_status', isEqualTo: 'validated')
        .orderBy('titre')
        .get();
    return snap.docs.map((d) => Recipe.fromFirestore(d.id, d.data())).toList();
  }

  /// Récupère les brouillons (draft + inReview) de l'utilisateur.
  Future<List<Recipe>> getMyDraftRecipes() async {
    final snap = await _db
        .collection('recipes')
        .where('created_by', isEqualTo: _uid)
        .where('review_status', whereIn: ['draft', 'inReview'])
        .get();
    final list = snap.docs
        .map((d) => Recipe.fromFirestore(d.id, d.data()))
        .toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  /// Récupère les recettes validées des membres de la famille (hors utilisateur courant).
  Future<List<Recipe>> getFamilyValidatedRecipes(List<String> memberIds) async {
    if (memberIds.isEmpty) return [];
    final limited = memberIds.take(30).toList();
    final snap = await _db
        .collection('recipes')
        .where('created_by', whereIn: limited)
        .where('review_status', isEqualTo: 'validated')
        .get();
    return snap.docs.map((d) => Recipe.fromFirestore(d.id, d.data())).toList();
  }

  /// Sauvegarde une recette générée par l'IA comme brouillon et retourne son ID.
  Future<String> saveAsDraft(Recipe recipe) async {
    final now = DateTime.now();
    // Une recette conçue par l'IA appartient à « Mes créations Kass'Dalle ».
    // Elle atterrissait sans livre, donc en recette libre : la bibliothèque ne
    // distinguait plus ce que la maison a inventé de ce qu'on y a soi-même
    // écrit, et le livre prévu pour ça restait vide.
    final book = await BookRepository().findOrCreateKassDalleBook(_uid);
    final draft = Recipe(
      id: '',
      titre: recipe.titre,
      langue: recipe.langue,
      rawCooklang: recipe.rawCooklang,
      draftCooklang: recipe.draftCooklang ?? recipe.rawCooklang,
      imageUrls: const [],
      reviewStatus: ReviewStatus.draft,
      tags: recipe.tags,
      ingredientsIndex: recipe.ingredientsIndex,
      createdBy: _uid,
      createdAt: now,
      updatedAt: now,
      bookId: book.id,
      bookTitre: book.titre,
    );
    final ref = await _db.collection('recipes').add(draft.toFirestore());
    return ref.id;
  }
}

// ── Providers ─────────────────────────────────────────────────────────────────

final planningRepositoryProvider = Provider<PlanningRepository?>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return null;
  return PlanningRepository(FirebaseFirestore.instance, uid);
});

final plannedMealsProvider = StreamProvider.autoDispose<List<PlannedMeal>>((
  ref,
) {
  final repo = ref.watch(planningRepositoryProvider);
  if (repo == null) return const Stream.empty();
  return repo.watchMeals();
});

final planningPreferencesProvider =
    StreamProvider.autoDispose<PlanningPreferences>((ref) {
      final repo = ref.watch(planningRepositoryProvider);
      if (repo == null) return Stream.value(const PlanningPreferences());
      return repo.watchPreferences();
    });

/// Préférences lues une seule fois, pour les écrans qui les éditent.
final planningPreferencesOnceProvider =
    FutureProvider.autoDispose<PlanningPreferences>((ref) async {
      final repo = ref.watch(planningRepositoryProvider);
      if (repo == null) return const PlanningPreferences();
      return repo.loadPreferences();
    });

final planningAiServiceProvider = Provider<PlanningAiService>((ref) {
  return PlanningAiService(ref.watch(geminiServiceProvider));
});
