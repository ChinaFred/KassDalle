import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../groups/presentation/group_providers.dart';
import '../data/recipe_rating_repository.dart';
import '../data/recipe_repository.dart';
import '../data/scan_upload_service.dart';
import '../domain/recipe.dart';
import '../domain/recipe_rating.dart';
import '../../auth/presentation/auth_providers.dart';

final recipeRepositoryProvider = Provider<RecipeRepository>((ref) {
  return RecipeRepository();
});

/// Brouillons de l'utilisateur connecté (draft + inReview).
final draftsProvider = StreamProvider<List<Recipe>>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(recipeRepositoryProvider).watchDrafts(uid);
});

/// Recettes validées d'un livre.
final recipesByBookProvider = StreamProvider.family<List<Recipe>, String>((
  ref,
  bookId,
) {
  return ref.watch(recipeRepositoryProvider).watchByBook(bookId);
});

/// Toutes les pages validées d'un livre (recettes + pages non-recettes),
/// triées par numéro de page.
final allPagesByBookProvider = StreamProvider.family<List<Recipe>, String>((
  ref,
  bookId,
) {
  return ref.watch(recipeRepositoryProvider).watchAllPagesByBook(bookId);
});

/// Recettes libres validées de l'utilisateur connecté.
final unattachedRecipesProvider = StreamProvider<List<Recipe>>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(recipeRepositoryProvider).watchUnattached(uid);
});

/// Stream combiné pour le livre "Mes recettes libres" :
/// recettes attachées au livre + recettes sans livre (nouvelles recettes libres).
final libresRecipesProvider = StreamProvider.family<List<Recipe>, String>((
  ref,
  bookId,
) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  final repo = ref.watch(recipeRepositoryProvider);

  final ctrl = StreamController<List<Recipe>>();
  List<Recipe> byBook = [];
  List<Recipe> unattached = [];

  void push() {
    final merged = [...byBook, ...unattached];
    merged.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    ctrl.add(merged);
  }

  final sub1 = repo.watchByBook(bookId).listen(
    (r) {
      byBook = r;
      push();
    },
    onError: ctrl.addError,
  );
  final sub2 = repo.watchUnattached(uid).listen(
    (r) {
      unattached = r;
      push();
    },
    onError: ctrl.addError,
  );

  ref.onDispose(() {
    sub1.cancel();
    sub2.cancel();
    ctrl.close();
  });

  return ctrl.stream;
});

/// Recettes libres validées des membres des groupes (hors utilisateur courant).
final groupMemberUnattachedRecipesProvider = StreamProvider<List<Recipe>>((
  ref,
) {
  final memberIds = ref.watch(groupMemberIdsProvider).value;
  if (memberIds == null || memberIds.isEmpty) return Stream.value([]);
  return ref
      .watch(recipeRepositoryProvider)
      .watchUnattachedByOwners(memberIds.toList());
});

/// Brouillons des membres du groupe familial (hors utilisateur courant).
final groupMemberDraftsProvider = StreamProvider<List<Recipe>>((ref) {
  final memberIds = ref.watch(groupMemberIdsProvider).value;
  if (memberIds == null || memberIds.isEmpty) return Stream.value([]);
  return ref
      .watch(recipeRepositoryProvider)
      .watchDraftsByOwners(memberIds.toList());
});

/// Détail d'une recette — stream temps réel (se met à jour automatiquement).
final recipeDetailProvider = StreamProvider.family<Recipe?, String>((
  ref,
  recipeId,
) {
  return ref.watch(recipeRepositoryProvider).watchRecipe(recipeId);
});

/// Nombre de brouillons en attente (pour le badge nav).
final draftsCountProvider = Provider<int>((ref) {
  return ref.watch(draftsProvider).value?.length ?? 0;
});

/// Tous les brouillons — admin uniquement.
final allDraftsProvider = StreamProvider<List<Recipe>>((ref) {
  return ref.watch(recipeRepositoryProvider).watchAllDrafts();
});

/// Brouillons d'un livre donné (pour le badge "à valider" dans RecipeListScreen).
final draftsByBookCountProvider = StreamProvider.family<int, String>((
  ref,
  bookId,
) {
  return ref
      .watch(recipeRepositoryProvider)
      .watchDraftsByBook(bookId)
      .map((list) => list.length);
});

/// Brouillons sans livre de l'utilisateur (pour le badge dans recettes libres).
final draftsUnattachedCountProvider = StreamProvider<int>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref
      .watch(recipeRepositoryProvider)
      .watchDraftsUnattached(uid)
      .map((list) => list.length);
});

/// Récupère une recette ou page par son ID.
final recipeByIdProvider = FutureProvider.family<Recipe?, String>((
  ref,
  id,
) async {
  return ref.watch(recipeRepositoryProvider).getById(id);
});

/// Notifier du scan upload.
final scanUploadProvider = NotifierProvider<ScanUploadNotifier, ScanState>(
  ScanUploadNotifier.new,
);

// ── Notes personnelles ────────────────────────────────────────────────────────

final recipeRatingRepositoryProvider = Provider<RecipeRatingRepository>(
  (_) => RecipeRatingRepository(),
);

/// Note personnelle de l'utilisateur connecté pour une recette donnée.
final myRatingProvider = StreamProvider.family<RecipeRating?, String>((
  ref,
  recipeId,
) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(recipeRatingRepositoryProvider).watch(uid, recipeId);
});
