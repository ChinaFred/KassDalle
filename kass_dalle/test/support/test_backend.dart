import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/core/services/nutrition_units_reference.dart';
import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/admin/data/nutrition_ingredients_repository.dart';
import 'package:kass_dalle/features/annotations/data/annotation_repository.dart';
import 'package:kass_dalle/features/annotations/presentation/annotation_providers.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/books/domain/book.dart';
import 'package:kass_dalle/features/books/data/book_repository.dart';
import 'package:kass_dalle/features/books/presentation/book_providers.dart';
import 'package:kass_dalle/features/groups/domain/family_group.dart';
import 'package:kass_dalle/features/groups/presentation/group_providers.dart';
import 'package:kass_dalle/features/planning/data/planning_visibility_store.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/presentation/planning_providers.dart';
import 'package:kass_dalle/features/processing/domain/processing_job.dart';
import 'package:kass_dalle/features/processing/presentation/processing_providers.dart';
import 'package:kass_dalle/features/recipes/data/recipe_rating_repository.dart';
import 'package:kass_dalle/features/recipes/data/recipe_repository.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/presentation/recipe_providers.dart';

/// Décor de test partagé : un Firestore en mémoire, un utilisateur connecté,
/// et les overrides Riverpod qui branchent l'un sur l'autre.
///
/// Le parti pris est de **ne pas simuler les repositories**. Chacun accepte
/// déjà un `FirebaseFirestore` injecté ; on leur passe un
/// [FakeFirebaseFirestore] et c'est leur vrai code — requêtes, filtres, tris,
/// désérialisation — qui est rejoué. Un faux repository, lui, ne testerait que
/// la fidélité du faux.
///
/// Note d'implémentation : le type `Override` de Riverpod 3 n'est pas exporté
/// publiquement. [overrides] est donc un champ dont le type est **inféré**
/// depuis son initialiseur, jamais annoté. Un test qui a besoin d'overrides
/// supplémentaires construit son propre `ProviderScope` en étalant
/// `backend.overrides` dans le littéral — l'inférence y fonctionne aussi.
class TestBackend {
  final FakeFirebaseFirestore firestore;
  final AppUser user;

  final RecipeRepository recipes;
  final BookRepository books;
  final AnnotationRepository annotations;
  final RecipeRatingRepository ratings;
  final NutritionIngredientsRepository nutrition;
  final NutritionUnitsReference units;

  /// Mes repas planifiés, rendus par `plannedMealsProvider`.
  final List<PlannedMeal> plannedMeals;

  /// Mes groupes familiaux, rendus par `myGroupsProvider`.
  final List<FamilyGroup> groups;

  late final overrides = [
    // `appUserProvider` est remplacé directement plutôt que reconstruit depuis
    // un faux FirebaseAuth : c'est la frontière que les écrans lisent, et la
    // seule qui compte pour eux.
    appUserProvider.overrideWith((ref) => Stream.value(user)),
    recipeRepositoryProvider.overrideWithValue(recipes),
    bookRepositoryProvider.overrideWithValue(books),
    annotationRepositoryProvider.overrideWithValue(annotations),
    recipeRatingRepositoryProvider.overrideWithValue(ratings),
    nutritionIngredientsRepositoryProvider.overrideWithValue(nutrition),
    nutritionUnitsReferenceProvider.overrideWithValue(units),
    // Le planning construit son repository avec `FirebaseFirestore.instance`
    // en dur, sans passer par un provider injectable : un écran de planning
    // testé le prend donc null, ce qui est son cas « pas de compte ».
    planningRepositoryProvider.overrideWithValue(null),
    // Les groupes ne sont pas le sujet des parcours testés : un ensemble vide
    // évite d'ouvrir des flux Firestore sans rapport.
    groupMemberIdsProvider.overrideWith(
      (ref) => const AsyncValue.data(<String>{}),
    ),
    myInvitationsProvider.overrideWith(
      (ref) => Stream.value(const <FamilyGroup>[]),
    ),
    // Le planning et la file de traitement lisent Firestore par des chemins qui
    // leur sont propres ; on les neutralise pour isoler l'écran testé.
    plannedMealsProvider.overrideWith((ref) => Stream.value(plannedMeals)),
    // Les plannings affichés se mémorisent sur l'appareil : une mémoire
    // remplace les préférences, absentes des tests.
    planningVisibilityStoreProvider.overrideWithValue(
      InMemoryPlanningVisibilityStore(),
    ),
    myGroupsProvider.overrideWith((ref) => Stream.value(groups)),
    processingJobsProvider.overrideWith(
      (ref) => Stream.value(const <ProcessingJob>[]),
    ),
  ];

  TestBackend._(
    this.firestore,
    this.user, {
    this.plannedMeals = const [],
    this.groups = const [],
  }) : recipes = RecipeRepository(firestore: firestore),
       books = BookRepository(firestore: firestore),
       annotations = AnnotationRepository(firestore: firestore),
       ratings = RecipeRatingRepository(firestore: firestore),
       nutrition = NutritionIngredientsRepository(firestore: firestore),
       units = NutritionUnitsReference(firestore: firestore);

  factory TestBackend({
    AppUser? user,
    List<PlannedMeal> plannedMeals = const [],
    List<FamilyGroup> groups = const [],
  }) => TestBackend._(
    FakeFirebaseFirestore(),
    user ?? testUser(),
    plannedMeals: plannedMeals,
    groups: groups,
  );

  // ── Semis ──────────────────────────────────────────────────────────────────

  Future<void> seedBook(Book book) =>
      firestore.collection('books').doc(book.id).set(book.toFirestore());

  Future<void> seedRecipe(Recipe recipe) =>
      firestore.collection('recipes').doc(recipe.id).set(recipe.toFirestore());
}

// ── Fabriques ────────────────────────────────────────────────────────────────

AppUser testUser({
  String uid = 'uid-test',
  UserRole role = UserRole.editor,
  bool isRevoked = false,
}) {
  return AppUser(
    uid: uid,
    email: 'cuisinier@example.test',
    displayName: 'Cuisinier',
    role: role,
    createdAt: DateTime.utc(2026, 1, 1),
    lastSeenAt: DateTime.utc(2026, 8, 1),
    isRevoked: isRevoked,
  );
}

Book testBook({
  String id = 'book-1',
  String titre = 'Les classiques',
  String createdBy = 'uid-test',
  BookReviewStatus reviewStatus = BookReviewStatus.validated,
  List<String> tags = const [],
  bool isPrivate = false,
  DateTime? updatedAt,
}) {
  return Book(
    id: id,
    titre: titre,
    auteur: 'Anonyme',
    langue: 'fr',
    tags: tags,
    reviewStatus: reviewStatus,
    createdBy: createdBy,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: updatedAt ?? DateTime.utc(2026, 6, 1),
    isPrivate: isPrivate,
  );
}

Recipe testRecipe({
  String id = 'recipe-1',
  String titre = 'Tarte aux poireaux',
  String? bookId,
  int? pageNumber,
  String createdBy = 'uid-test',
  ReviewStatus reviewStatus = ReviewStatus.validated,
  bool isPrivate = false,
  PageType pageType = PageType.recipe,
  String rawCooklang = '>> portions: 4\nMélanger la @farine{200%g}.',
  List<RecipeIngredient> ingredients = const [],
  DateTime? updatedAt,
}) {
  return Recipe(
    id: id,
    titre: titre,
    bookId: bookId,
    pageNumber: pageNumber,
    langue: 'fr',
    rawCooklang: rawCooklang,
    imageUrls: const [],
    reviewStatus: reviewStatus,
    isPrivate: isPrivate,
    tags: const RecipeTags(),
    ingredientsIndex: const ['farine'],
    ingredients: ingredients,
    pageType: pageType,
    createdBy: createdBy,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: updatedAt ?? DateTime.utc(2026, 6, 1),
  );
}

// ── Montage d'un écran ───────────────────────────────────────────────────────

/// Monte un écran seul, hors routeur.
///
/// Les parcours testés vérifient ce que l'écran **affiche** selon l'état de ses
/// données ; la navigation est le travail de `app_router.dart`, qui a ses
/// propres redirections et se teste autrement.
Future<void> pumpScreen(
  WidgetTester tester,
  Widget screen, {
  required TestBackend backend,
  Size surface = const Size(1400, 1000),
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      retry: appProviderRetry,
      overrides: backend.overrides,
      child: MaterialApp(locale: const Locale('fr'), home: screen),
    ),
  );
}
