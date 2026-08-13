import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/gemini_providers.dart';
import '../../auth/presentation/auth_providers.dart';
import '../services/planning_ai_service.dart';
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

  /// Stream des repas planifiés de l'utilisateur, triés par date.
  Stream<List<PlannedMeal>> watchMeals() {
    return _col
        .where('uid', isEqualTo: _uid)
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

  /// Sauvegarde les préférences de planning.
  Future<void> savePreferences(PlanningPreferences prefs) async {
    await _prefsDoc.set(prefs.toFirestore());
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

final planningAiServiceProvider = Provider<PlanningAiService>((ref) {
  return PlanningAiService(ref.watch(geminiServiceProvider));
});
