import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_report_service.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/services/gemini_providers.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../auth/domain/user_profile.dart';
import '../data/planning_refusals_repository.dart';
import '../data/planning_visibility_store.dart';
import '../services/planning_ai_service.dart';
import '../../books/data/book_repository.dart';
import '../../groups/domain/family_group.dart';
import '../../groups/presentation/group_providers.dart';
import '../../recipes/data/recipe_repository.dart';
import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/recipe_filter.dart';
import '../domain/meal_choice_source.dart';
import '../domain/meal_component.dart';
import '../domain/planned_meal.dart';
import '../domain/planning_preferences.dart';
import '../domain/planning_reach.dart';
import '../domain/planning_refusals.dart';
import '../domain/planning_target.dart';
import '../domain/planning_visibility.dart';
import '../domain/recipe_search_scope.dart';

// ── Repository ─────────────────────────────────────────────────────────────────

class PlanningRepository {
  final FirebaseFirestore _db;
  final String _uid;
  final ErrorReportService _errorReportService;

  PlanningRepository(
    this._db,
    this._uid, {
    ErrorReportService? errorReportService,
  }) : _errorReportService =
           errorReportService ?? ErrorReportService(firestore: _db);

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection('planned_meals');

  /// Identifiant de l'utilisateur courant.
  String get uid => _uid;

  DocumentReference<Map<String, dynamic>> get _prefsDoc =>
      _db.collection('planning_config').doc(_uid);

  /// Périmètre choisi dans « Où chercher des recettes ? » — une préférence de
  /// lecteur, comme le rangement de la bibliothèque (`book_order`) : la
  /// bibliothèque est partagée, chacun y cherche à sa façon.
  DocumentReference<Map<String, dynamic>> get _recipeSearchScopeDoc => _db
      .collection('users')
      .doc(_uid)
      .collection('preferences')
      .doc('recipe_search_scope');

  // ── Repas planifiés ─────────────────────────────────────────────────────────

  /// Profondeur d'historique affichée dans le planning.
  ///
  /// Sans borne, l'écran recharge la totalité des repas jamais planifiés à
  /// chaque ouverture — une facture de lectures qui ne fait que croître.
  static const historyWindow = Duration(days: 90);

  /// Stream des repas du planning personnel de l'utilisateur, triés par date.
  ///
  /// La requête `uid == moi` rend aussi les repas des groupes dont il est le
  /// propriétaire (il en est le cuisinier) : ils sont écartés ici, ils
  /// appartiennent au planning du groupe ([watchGroupMeals]). Le titulaire
  /// garde la requête `uid == moi`, sans filtre sur `group_id` : un repas
  /// antérieur que le backfill n'aurait pas encore marqué `group_id: null`
  /// lui reste visible.
  Stream<List<PlannedMeal>> watchMeals() => _watchPersonalMealsOf(_uid);

  /// Stream des repas d'un autre compte qui partage son planning avec
  /// l'utilisateur, en lecture seule.
  ///
  /// Un flux par planning, filtré sur `uid == ownerUid` et `group_id ==
  /// null` : les règles Firestore vérifient la première égalité contre
  /// `planning_reach/{moi}`, et n'ouvrent par le partage personnel que les
  /// repas personnels. Sans le second filtre, la requête serait refusée en
  /// entier ; les repas des groupes du propriétaire ne se lisent que par
  /// les membres de ces groupes, dans le planning du groupe. Une requête `in`
  /// sur plusieurs comptes serait refusée en entier dès qu'un seul cesse de
  /// partager ; ici, seul son flux tombe en erreur.
  ///
  /// L'erreur est remontée au rapport puis transmise : l'écran l'affiche
  /// sous le nom du planning, sans masquer les autres.
  Stream<List<PlannedMeal>> watchSharedMeals(String ownerUid) {
    return _mealsOf(
      _col.where('uid', isEqualTo: ownerUid).where('group_id', isEqualTo: null),
    ).handleError((Object e, StackTrace st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'planning_shared_meals',
          error: e,
          stackTrace: st,
          context: {'uid': _uid, 'owner_uid': ownerUid},
        ),
      );
      Error.throwWithStackTrace(e, st);
    });
  }

  /// Stream des repas du planning du groupe [groupId], triés par date : le
  /// propriétaire [ownerUid] les écrit, chaque membre les lit.
  ///
  /// Filtré sur `group_id == groupId` et `uid == ownerUid` : les règles
  /// Firestore vérifient le groupe contre `planning_reach/{moi}.group_ids`, et
  /// que `uid` est le propriétaire actuel du groupe. Un groupe supprimé puis
  /// recréé sous le même identifiant par un autre compte n'ouvre donc pas les
  /// repas de l'ancien. Un flux par groupe : l'erreur de l'un ne masque pas
  /// les autres. L'erreur est remontée au rapport puis transmise.
  Stream<List<PlannedMeal>> watchGroupMeals(String groupId, String ownerUid) {
    return _mealsOf(
      _col
          .where('group_id', isEqualTo: groupId)
          .where('uid', isEqualTo: ownerUid),
    ).handleError((Object e, StackTrace st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'planning_group_meals',
          error: e,
          stackTrace: st,
          context: {'uid': _uid, 'group_id': groupId, 'owner_uid': ownerUid},
        ),
      );
      Error.throwWithStackTrace(e, st);
    });
  }

  Stream<List<PlannedMeal>> _watchPersonalMealsOf(String ownerUid) =>
      _mealsOf(_col.where('uid', isEqualTo: ownerUid)).map(
        (meals) => [
          for (final m in meals)
            if (!m.isGroupMeal) m,
        ],
      );

  Stream<List<PlannedMeal>> _mealsOf(Query<Map<String, dynamic>> query) {
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day).subtract(historyWindow);
    return query
        .where('planned_at', isGreaterThanOrEqualTo: Timestamp.fromDate(from))
        .orderBy('planned_at')
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => PlannedMeal.fromFirestore(d.id, d.data()))
              .toList(),
        );
  }

  // ── Plannings partagés et plannings de groupe ───────────────────────────────

  /// Ce que l'utilisateur peut lire des plannings d'autrui :
  /// `planning_reach/{uid}`, tenu par le serveur seul (voir [PlanningReach]).
  ///
  /// Document absent (aucun partage, ou pas encore calculé) : vide. Jamais
  /// l'utilisateur lui-même dans les comptes.
  Stream<PlanningReach> watchPlanningReach() {
    return _db
        .collection('planning_reach')
        .doc(_uid)
        .snapshots()
        .map((doc) => PlanningReach.fromMap(doc.data(), _uid))
        .handleError((Object e, StackTrace st) {
          unawaited(
            _errorReportService.reportError(
              feature: 'planning_reach',
              error: e,
              stackTrace: st,
              context: {'uid': _uid},
            ),
          );
          Error.throwWithStackTrace(e, st);
        });
  }

  /// Parmi [ids], les recettes que l'utilisateur peut lire, par lots de 30.
  ///
  /// Sert au planning partagé : le repas d'un autre membre peut pointer une
  /// recette privée, un brouillon, un livre non partagé, ou une recette
  /// supprimée. On ne l'ouvre pas, on l'affiche par son titre avec
  /// « Recette non partagée ». Un lot refusé par les règles se relit recette
  /// par recette. Les refus sont attendus mais pas tus : un seul rapport par
  /// lot (`planning.shared_recipe_denied`), avec leur nombre et la première
  /// recette refusée. Toute autre erreur est relancée.
  Future<Set<String>> readableRecipeIds(Iterable<String> ids) async {
    final unique = ids.where((id) => id.isNotEmpty).toSet().toList();
    final readable = <String>{};
    for (var i = 0; i < unique.length; i += 30) {
      final chunk = unique.sublist(i, (i + 30).clamp(0, unique.length));
      try {
        final snap = await _db
            .collection('recipes')
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        readable.addAll(snap.docs.map((d) => d.id));
      } on FirebaseException catch (e, st) {
        if (e.code != 'permission-denied') rethrow;
        final denied = <String>[];
        for (final id in chunk) {
          try {
            final doc = await _db.collection('recipes').doc(id).get();
            if (doc.exists) readable.add(id);
          } on FirebaseException catch (refusal) {
            if (refusal.code != 'permission-denied') rethrow;
            denied.add(id);
          }
        }
        unawaited(
          _errorReportService.reportError(
            feature: 'planning.shared_recipe_denied',
            error: e,
            stackTrace: st,
            context: {
              'uid': _uid,
              'batch_size': chunk.length,
              'denied_count': denied.length,
              if (denied.isNotEmpty) 'first_denied_recipe_id': denied.first,
            },
          ),
        );
      }
    }
    return readable;
  }

  /// Ajoute un repas planifié.
  Future<void> addMeal(PlannedMeal meal) async {
    await _col.add(meal.toFirestore());
  }

  /// Enregistre un lot de repas planifiés (batch planning) et rend leurs
  /// identifiants, dans l'ordre reçu.
  ///
  /// Un repas dont [PlannedMeal.id] est renseigné est **réécrit** sous cet
  /// identifiant ; les autres reçoivent un nouveau document. C'est ce qui
  /// permet à un créneau déjà enregistré depuis son icône calendrier d'être
  /// mis à jour à la validation du cycle, au lieu d'être créé une seconde fois.
  Future<List<String>> saveMeals(List<PlannedMeal> meals) async {
    final batch = _db.batch();
    final ids = <String>[];
    for (final meal in meals) {
      final doc = meal.id.isEmpty ? _col.doc() : _col.doc(meal.id);
      batch.set(doc, meal.toFirestore());
      ids.add(doc.id);
    }
    await batch.commit();
    return ids;
  }

  /// Supprime un repas planifié.
  Future<void> deleteMeal(String id) async {
    await _col.doc(id).delete();
  }

  /// Repas déjà planifiés entre [from] et [to], journées entières incluses,
  /// dans le planning personnel, ou dans celui du groupe [groupId].
  ///
  /// Sert à savoir ce qu'un nouveau cycle recouvre : sans cette lecture, valider
  /// un planning empile deux repas sur le même créneau sans le dire. Chaque
  /// planning ne voit que ses repas : un repas de groupe n'occupe pas le
  /// créneau du planning personnel, ni l'inverse.
  Future<List<PlannedMeal>> getMealsBetween({
    required DateTime from,
    required DateTime to,
    String? groupId,
  }) async {
    if (groupId != null) {
      // Seul le propriétaire planifie pour son groupe : ses repas.
      return _mealsBetween(
        _col
            .where('group_id', isEqualTo: groupId)
            .where('uid', isEqualTo: _uid),
        from: from,
        to: to,
      );
    }
    final meals = await getCookedMealsBetween(from: from, to: to);
    return [
      for (final m in meals)
        if (!m.isGroupMeal) m,
    ];
  }

  /// Tous les repas que l'utilisateur cuisine entre [from] et [to] : ceux de
  /// son planning personnel et ceux des groupes dont il est le propriétaire.
  ///
  /// Sert la fenêtre de variété : un plat servi à la famille mardi compte
  /// pour le planning personnel de son cuisinier, et l'inverse — le serveur
  /// lit de même l'historique sur `uid` (`readServedHistory`).
  Future<List<PlannedMeal>> getCookedMealsBetween({
    required DateTime from,
    required DateTime to,
  }) => _mealsBetween(
    _col.where('uid', isEqualTo: _uid),
    from: from,
    to: to,
  );

  Future<List<PlannedMeal>> _mealsBetween(
    Query<Map<String, dynamic>> query, {
    required DateTime from,
    required DateTime to,
  }) async {
    final start = DateTime(from.year, from.month, from.day);
    final end = DateTime(to.year, to.month, to.day, 23, 59, 59, 999);
    final snap = await query
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
    String? dismissRecipeId,
    List<MealComponent>? components,
    MealChoiceSource? choiceSource,
    String? justification,
    bool clearChoice = false,
  }) async {
    final why = justification?.trim() ?? '';
    final payload = <String, dynamic>{
      'recipe_id': recipeId,
      'recipe_titre': recipeTitre,
      'duration_minutes': durationMinutes,
      'prep_minutes': ?prepMinutes,
      'cook_minutes': ?cookMinutes,
      'base_portions': ?basePortions,
      'target_portions': ?targetPortions,
      // Les composants suivent le plat : changer de recette, c'est recomposer
      // le repas. `null` laisse ceux en place ; une liste vide les retire.
      if (components != null)
        'components': [for (final c in components) c.toMap()],
      // L'origine et les faits suivent le plat : un autre plat, une autre
      // origine. Sans origine fournie, ni l'une ni les autres ne changent.
      if (choiceSource != null) 'choice_source': choiceSource.value,
      if (choiceSource != null)
        'justification': why.isEmpty ? FieldValue.delete() : why,
    };
    // La recette remplacée reste écartée de ce repas : le prochain
    // « Suggérer » ne la verra pas dans ses candidats.
    if (dismissRecipeId != null) {
      payload['dismissed_recipe_ids'] = FieldValue.arrayUnion([
        dismissRecipeId,
      ]);
    }
    // Un repas vidé de sa recette perd aussi son origine et ses faits.
    if (clearChoice) {
      payload['choice_source'] = FieldValue.delete();
      payload['justification'] = FieldValue.delete();
    }
    if (clearPortions) {
      payload['base_portions'] = FieldValue.delete();
      payload['target_portions'] = FieldValue.delete();
    }
    await _col.doc(id).update(payload);
  }

  /// Remplace les composants d'un repas planifié — accompagnements ajoutés,
  /// retirés ou choisis à la main, sans toucher au plat ni à sa recette.
  Future<void> updateMealComponents(
    String id,
    List<MealComponent> components,
  ) async {
    await _col.doc(id).update({
      'components': components.isEmpty
          ? FieldValue.delete()
          : [for (final c in components) c.toMap()],
    });
  }

  /// Met à jour l'heure d'un repas planifié existant.
  Future<void> updateMealTime(String id, DateTime newTime) async {
    await _col.doc(id).update({'planned_at': Timestamp.fromDate(newTime)});
  }

  /// Déplace un repas planifié vers une autre date, en gardant son heure.
  ///
  /// Le jour de préparation ([PlannedMeal.prepDate]) suit le même décalage
  /// que [PlannedMeal.plannedAt] : reporter un repas d'une semaine reporte sa
  /// préparation d'autant, sinon la conservation calculée redeviendrait fausse.
  Future<void> rescheduleMeal(PlannedMeal meal, DateTime newDate) async {
    final newPlannedAt = DateTime(
      newDate.year,
      newDate.month,
      newDate.day,
      meal.plannedAt.hour,
      meal.plannedAt.minute,
    );
    final payload = <String, dynamic>{
      'planned_at': Timestamp.fromDate(newPlannedAt),
    };
    final prep = meal.prepDate;
    if (prep != null) {
      final oldDay = DateTime(
        meal.plannedAt.year,
        meal.plannedAt.month,
        meal.plannedAt.day,
      );
      final newDay = DateTime(newDate.year, newDate.month, newDate.day);
      payload['prep_date'] = Timestamp.fromDate(
        prep.add(newDay.difference(oldDay)),
      );
    }
    await _col.doc(meal.id).update(payload);
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

  /// Lecture ponctuelle du dernier périmètre choisi, pour l'ouverture de
  /// l'écran de génération. `null` tant que rien n'a jamais été enregistré —
  /// l'appelant se rabat alors sur ses recettes validées, l'ensemble de la
  /// bibliothèque accessible.
  Future<RecipeSearchScope?> loadRecipeSearchScope() async {
    final snap = await _recipeSearchScopeDoc.get();
    final data = snap.data();
    return data == null ? null : RecipeSearchScope.fromMap(data);
  }

  /// Enregistre le périmètre choisi, pour qu'il survive à la fermeture de
  /// l'écran comme à une reconnexion sur un autre appareil.
  Future<void> saveRecipeSearchScope(RecipeSearchScope scope) async {
    await _recipeSearchScopeDoc.set({
      ...scope.toMap(),
      'updated_at': Timestamp.now(),
    });
  }

  /// Récupère les recettes correspondant aux [ids] donnés, par lots de 30.
  ///
  /// Un repas planifié peut pointer sur un brouillon ou une recette de la
  /// famille : les résoudre par identifiant évite qu'ils disparaissent
  /// silencieusement de la liste de courses.
  ///
  /// Une recette devenue illisible — rendue privée par son créateur depuis
  /// qu'on l'a planifiée — fait refuser le lot entier par les règles
  /// Firestore. Le lot se relit alors recette par recette : celles qu'on voit
  /// encore restent, les autres sont écartées et signalées au rapport
  /// d'erreurs, sans vider toute la liste de courses.
  Future<List<Recipe>> getRecipesByIds(List<String> ids) async {
    final unique = ids.where((id) => id.isNotEmpty).toSet().toList();
    if (unique.isEmpty) return [];
    final out = <Recipe>[];
    for (var i = 0; i < unique.length; i += 30) {
      final chunk = unique.sublist(i, (i + 30).clamp(0, unique.length));
      try {
        final snap = await _db
            .collection('recipes')
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        out.addAll(snap.docs.map((d) => Recipe.fromFirestore(d.id, d.data())));
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied') rethrow;
        out.addAll(await _getReadableOneByOne(chunk));
      }
    }
    return out;
  }

  Future<List<Recipe>> _getReadableOneByOne(List<String> ids) async {
    final out = <Recipe>[];
    final refused = <String>[];
    for (final id in ids) {
      try {
        final doc = await _db.collection('recipes').doc(id).get();
        final data = doc.data();
        if (data != null) out.add(Recipe.fromFirestore(doc.id, data));
      } on FirebaseException catch (e, st) {
        if (e.code != 'permission-denied') rethrow;
        refused.add(id);
        if (refused.length == 1) {
          unawaited(
            _errorReportService.reportError(
              feature: 'planning_recipes_by_ids',
              error: e,
              stackTrace: st,
              context: {'uid': _uid, 'first_refused_recipe_id': id},
            ),
          );
        }
      }
    }
    return out;
  }

  // ── Recettes disponibles ────────────────────────────────────────────────────

  /// Récupère toutes les recettes validées de l'utilisateur pour la sélection
  /// et la génération AI.
  ///
  /// Pages de type recette seulement, ici comme dans les deux autres corpus :
  /// une technique validée n'est pas un plat, et elle se retrouvait proposée
  /// pour un mardi soir — voir [pickableRecipes].
  Future<List<Recipe>> getValidatedRecipes() async {
    final snap = await _db
        .collection('recipes')
        .where('created_by', isEqualTo: _uid)
        .where('review_status', isEqualTo: 'validated')
        .orderBy('titre')
        .get();
    return pickableRecipes(
      snap.docs.map((d) => Recipe.fromFirestore(d.id, d.data())),
    );
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
    return pickableRecipes(list);
  }

  /// Récupère les recettes validées des membres de la famille (hors utilisateur courant).
  ///
  /// Les recettes des livres privés en sont écartées : elles ne nous
  /// appartiennent pas. Sans ce filtre, le générateur de menus proposait les
  /// recettes secrètes des autres membres — et les faisait ensuite figurer au
  /// planning, sous leur titre.
  Future<List<Recipe>> getFamilyValidatedRecipes(List<String> memberIds) async {
    if (memberIds.isEmpty) return [];
    final limited = memberIds.take(30).toList();
    final snap = await _db
        .collection('recipes')
        .where('created_by', whereIn: limited)
        .where('review_status', isEqualTo: 'validated')
        .where('is_private', isEqualTo: false)
        .get();
    return pickableRecipes(
      snap.docs.map((d) => Recipe.fromFirestore(d.id, d.data())),
    );
  }

  /// Enregistre une recette conçue par l'IA en brouillon dans « Mes créations
  /// Kass'Dalle » et retourne son ID.
  ///
  /// Toujours en brouillon, quel que soit le geste (« Conception IA » de
  /// Nouveau planning, « Concevoir avec l'IA », « Générer avec l'IA » du
  /// sélecteur) : une recette rédigée par l'IA se relit avant de rejoindre la
  /// bibliothèque. Un repas planifié lit un brouillon comme une recette
  /// validée (`getRecipesByIds`).
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
      // La liste structurée et les parts suivent : sans elles, la relecture
      // ouvrait un onglet Ingrédients vide sous un texte qui en comptait
      // quinze, et la fiche s'ouvrait sans nombre de parts.
      ingredients: recipe.ingredients,
      portions: recipe.portions,
      origin: RecipeOrigin.ai,
      createdBy: _uid,
      createdAt: now,
      updatedAt: now,
      bookId: book.id,
      bookTitre: book.titre,
    );
    final ref = await _db
        .collection('recipes')
        .add(
          withBookPrivacy(
            draft.toFirestore(),
            await privacyOfBook(_db, book.id),
          ),
        );
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

/// Ce que l'utilisateur peut lire des plannings d'autrui
/// (`planning_reach/{uid}`). Vide sans compte.
final planningReachProvider = StreamProvider.autoDispose<PlanningReach>((ref) {
  final repo = ref.watch(planningRepositoryProvider);
  if (repo == null) return Stream.value(PlanningReach.empty);
  return repo.watchPlanningReach();
});

/// Les repas d'un planning partagé avec l'utilisateur, un flux par
/// propriétaire : l'erreur de l'un ne masque pas les autres.
final sharedPlannedMealsProvider = StreamProvider.autoDispose
    .family<List<PlannedMeal>, String>((ref, ownerUid) {
      final repo = ref.watch(planningRepositoryProvider);
      if (repo == null) return Stream.value(const <PlannedMeal>[]);
      return repo.watchSharedMeals(ownerUid);
    });

/// Les repas du planning d'un groupe, un flux par groupe et par
/// propriétaire : l'erreur de l'un ne masque pas les autres.
final groupPlannedMealsProvider = StreamProvider.autoDispose
    .family<List<PlannedMeal>, ({String groupId, String ownerUid})>((ref, key) {
      final repo = ref.watch(planningRepositoryProvider);
      if (repo == null) return Stream.value(const <PlannedMeal>[]);
      return repo.watchGroupMeals(key.groupId, key.ownerUid);
    });

/// Les groupes où l'utilisateur planifie : ceux dont il est le propriétaire,
/// non masqués, s'il est éditeur ou administrateur. Triés par nom.
///
/// En chargement ou en erreur tant que ses groupes ne sont pas lus : « Nouveau
/// planning » et la feuille « Planifier » attendent de savoir s'ils proposent
/// « Planifier pour… ».
final ownedPlanningGroupsProvider =
    Provider.autoDispose<AsyncValue<List<FamilyGroup>>>((ref) {
      final me = ref.watch(appUserProvider).value;
      if (me == null) return const AsyncData([]);
      final groups = ref.watch(myGroupsProvider);
      final reach = ref.watch(planningReachProvider).value;
      return groups.whenData(
        (list) => ownedPlanningGroups(
          groups: list,
          myUid: me.uid,
          canPlan: me.canEdit,
          reach: reach,
        ),
      );
    });

// ── Plannings affichés ────────────────────────────────────────────────────────

final planningVisibilityStoreProvider = Provider<PlanningVisibilityStore>(
  (_) => const SharedPreferencesPlanningVisibilityStore(),
);

/// Le rapporteur d'erreurs de la mémoire des bascules, remplaçable dans les
/// tests : `ErrorReportService` lit `FirebaseAuth.instance`.
final planningVisibilityErrorReportProvider = Provider<ErrorReportService>(
  (_) => ErrorReportService(),
);

/// Les plannings basculés par rapport au défaut du rôle, lus sur l'appareil.
/// Vide tant que rien n'est lu, et quand rien ne peut l'être.
final planningVisibilityProvider =
    AsyncNotifierProvider.autoDispose<PlanningVisibilityNotifier, Set<String>>(
      PlanningVisibilityNotifier.new,
    );

class PlanningVisibilityNotifier extends AsyncNotifier<Set<String>> {
  ({String uid, bool canPlan})? _account;

  @override
  Future<Set<String>> build() async {
    final account = ref.watch(
      appUserProvider.select((user) {
        final u = user.value;
        return u == null ? null : (uid: u.uid, canPlan: u.canEdit);
      }),
    );
    _account = account;
    if (account == null) return <String>{};
    try {
      return await ref
          .read(planningVisibilityStoreProvider)
          .load(uid: account.uid, canPlan: account.canPlan);
    } catch (e, st) {
      reportUnexpectedError(
        feature: 'planning_visibility_load',
        error: e,
        stackTrace: st,
        userId: account.uid,
        service: ref.read(planningVisibilityErrorReportProvider),
      );
      return <String>{};
    }
  }

  /// Affiche ou masque le planning [ownerUid]. L'écran suit tout de suite ;
  /// un échec de la mémorisation ne reprend pas ce qui est affiché, le choix
  /// sera seulement oublié à la prochaine ouverture.
  Future<void> toggle(String ownerUid) async {
    final account = _account;
    if (account == null) return;
    final next = togglePlanning(state.value ?? const {}, ownerUid);
    state = AsyncData(next);
    try {
      await ref
          .read(planningVisibilityStoreProvider)
          .save(next, uid: account.uid, canPlan: account.canPlan);
    } catch (e, st) {
      reportUnexpectedError(
        feature: 'planning_visibility_save',
        error: e,
        stackTrace: st,
        userId: account.uid,
        context: {'owner_uid': ownerUid},
        service: ref.read(planningVisibilityErrorReportProvider),
      );
    }
  }
}

/// Une entrée du sélecteur « Plannings affichés » : un planning personnel, ou
/// le planning d'un groupe.
class PlanningOwnerOption {
  /// La clé du planning : l'identifiant du compte pour un planning
  /// personnel, [groupPlanningKey] pour un planning de groupe.
  final String uid;

  /// Le prénom du propriétaire, ou « Membre » ; non utilisé pour le sien.
  /// Pour un planning de groupe : le nom du groupe.
  final String name;
  final bool isMine;
  final bool shown;

  /// Le groupe, pour un planning de groupe ; `null` sinon.
  final String? groupId;

  /// Le propriétaire du groupe, pour un planning de groupe.
  final String? groupOwnerId;

  /// Prénom du propriétaire du groupe, « vous » si c'est l'utilisateur.
  final String? organizer;

  /// L'utilisateur est le propriétaire du groupe : il y planifie.
  final bool isOrganizer;

  const PlanningOwnerOption({
    required this.uid,
    required this.name,
    required this.isMine,
    required this.shown,
    this.groupId,
    this.groupOwnerId,
    this.organizer,
    this.isOrganizer = false,
  });

  bool get isGroup => groupId != null;

  /// La clé du flux de ce planning de groupe.
  ({String groupId, String ownerUid}) get groupKey =>
      (groupId: groupId!, ownerUid: groupOwnerId!);

  /// « Mon planning », « Planning de Marie », « Famille Dupont ».
  String get title => isGroup
      ? name
      : isMine
      ? 'Mon planning'
      : 'Planning de $name';

  /// « Planning du groupe · organisé par Marie » ; rien pour un planning
  /// personnel.
  String? get subtitle =>
      isGroup ? 'Planning du groupe · organisé par ${organizer ?? ''}' : null;

  /// « Moi », « Marie », « Famille Dupont » : le libellé court du bouton-puce.
  String get shortName => isMine ? 'Moi' : name;
}

/// Les entrées du sélecteur, dans l'ordre : « Mon planning », puis les
/// plannings partagés par ordre alphabétique des prénoms, puis les plannings
/// de groupe lisibles par ordre alphabétique des noms de groupe.
///
/// « Mon planning » n'est offert au lecteur que s'il lui reste au moins un
/// repas : il ne planifie plus, il garde ses repas antérieurs. Un planning de
/// groupe est offert à chaque membre, propriétaire compris, tant que le
/// serveur l'ouvre (`planning_reach.group_ids`), et coché par défaut.
final planningOwnerOptionsProvider =
    Provider.autoDispose<AsyncValue<List<PlanningOwnerOption>>>((ref) {
      final me = ref.watch(appUserProvider).value;
      if (me == null) return const AsyncData([]);
      final canPlan = me.canEdit;
      final toggled = ref.watch(planningVisibilityProvider);
      final myMeals = ref.watch(plannedMealsProvider);
      final reach = ref.watch(planningReachProvider);
      final groups = ref.watch(myGroupsProvider);
      if (!toggled.hasValue) return const AsyncLoading();
      // Le lecteur attend de savoir s'il lui reste des repas, ce qu'on
      // partage avec lui et de quels groupes il est membre ; l'éditeur voit
      // les siens sans attendre.
      if (!canPlan && (!myMeals.hasValue && !myMeals.hasError)) {
        return const AsyncLoading();
      }
      if (!canPlan && (!reach.hasValue && !reach.hasError)) {
        return const AsyncLoading();
      }
      if (!canPlan && (!groups.hasValue && !groups.hasError)) {
        return const AsyncLoading();
      }
      final offerMine = canPlan || (myMeals.value?.isNotEmpty ?? false);
      final names = <String, String>{
        for (final uid in reach.value?.uids ?? const <String>{})
          uid: ref.watch(memberNameProvider(uid)) ?? UserProfile.fallbackName,
      };
      final others = names.keys.toList()
        ..sort((a, b) {
          final byName = names[a]!.toLowerCase().compareTo(
            names[b]!.toLowerCase(),
          );
          return byName != 0 ? byName : a.compareTo(b);
        });
      final readableGroups =
          [
            for (final g in groups.value ?? const <FamilyGroup>[])
              if (reach.value?.readsGroup(g.id) ?? false) g,
          ]..sort((a, b) {
            final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
            return byName != 0 ? byName : a.id.compareTo(b.id);
          });
      final groupKeys = [
        for (final g in readableGroups) groupPlanningKey(g.id),
      ];
      final available = [if (offerMine) me.uid, ...others, ...groupKeys];
      final shown = displayedPlannings(
        available: available,
        myUid: me.uid,
        canPlan: canPlan,
        toggled: toggled.value!,
      ).toSet();
      return AsyncData([
        for (final uid in [if (offerMine) me.uid, ...others])
          PlanningOwnerOption(
            uid: uid,
            name: uid == me.uid ? 'Vous' : names[uid]!,
            isMine: uid == me.uid,
            shown: shown.contains(uid),
          ),
        for (final g in readableGroups)
          PlanningOwnerOption(
            uid: groupPlanningKey(g.id),
            name: g.name,
            isMine: false,
            shown: shown.contains(groupPlanningKey(g.id)),
            groupId: g.id,
            groupOwnerId: g.ownerId,
            isOrganizer: g.ownerId == me.uid,
            organizer: g.ownerId == me.uid
                ? 'vous'
                : ref.watch(memberNameProvider(g.ownerId)) ??
                      UserProfile.fallbackName,
          ),
      ]);
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

// ── Mémoire des refus ─────────────────────────────────────────────────────────

final planningRefusalsRepositoryProvider = Provider<PlanningRefusalsRepository>(
  (ref) => PlanningRefusalsRepository(),
);

/// Nombre de plats refusés ces [kRefusalPenaltyDays] derniers jours, pour
/// Préférences du planning. Lu une fois ; invalidé après « Oublier mes
/// refus ».
final planningActiveRefusalsProvider = FutureProvider.autoDispose<int>((
  ref,
) async {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return 0;
  final repo = ref.watch(planningRefusalsRepositoryProvider);
  try {
    final refusals = await repo.load(uid);
    return refusals.activeCount(repo.now());
  } catch (e, stackTrace) {
    // L'écran dit « Liste des refus illisible » ; le rapport garde la cause.
    reportUnexpectedError(
      feature: 'planning.loadRefusals',
      error: e,
      stackTrace: stackTrace,
      userId: uid,
    );
    rethrow;
  }
});
