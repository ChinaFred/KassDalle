import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/services/usage_providers.dart';
import '../../books/presentation/book_providers.dart';
import '../../groups/presentation/group_providers.dart';
import '../../processing/presentation/processing_providers.dart';
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
  final uid = ref.watch(appUserProvider).valueOrNull?.uid;
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

/// Recettes libres validées de l'utilisateur connecté.
final unattachedRecipesProvider = StreamProvider<List<Recipe>>((ref) {
  final uid = ref.watch(appUserProvider).valueOrNull?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(recipeRepositoryProvider).watchUnattached(uid);
});

/// Recettes libres validées des membres des groupes (hors utilisateur courant).
final groupMemberUnattachedRecipesProvider = StreamProvider<List<Recipe>>((
  ref,
) {
  final memberIds = ref.watch(groupMemberIdsProvider).valueOrNull;
  if (memberIds == null || memberIds.isEmpty) return Stream.value([]);
  return ref
      .watch(recipeRepositoryProvider)
      .watchUnattachedByOwners(memberIds.toList());
});

/// Détail d'une recette.
final recipeDetailProvider = FutureProvider.family<Recipe?, String>((
  ref,
  recipeId,
) {
  return ref.watch(recipeRepositoryProvider).getRecipe(recipeId);
});

/// Nombre de brouillons en attente (pour le badge nav).
final draftsCountProvider = Provider<int>((ref) {
  return ref.watch(draftsProvider).valueOrNull?.length ?? 0;
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
  final uid = ref.watch(appUserProvider).valueOrNull?.uid;
  if (uid == null) return const Stream.empty();
  return ref
      .watch(recipeRepositoryProvider)
      .watchDraftsUnattached(uid)
      .map((list) => list.length);
});

/// Notifier du scan upload.
final scanUploadProvider = StateNotifierProvider<ScanUploadNotifier, ScanState>(
  (ref) {
    return ScanUploadNotifier(
      ref.watch(recipeRepositoryProvider),
      ref.watch(bookRepositoryProvider),
      ref.watch(processingJobRepositoryProvider),
      FirebaseStorage.instance,
      FirebaseAuth.instance,
      ref.watch(usageTrackerProvider),
    );
  },
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
  final uid = ref.watch(appUserProvider).valueOrNull?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(recipeRatingRepositoryProvider).watch(uid, recipeId);
});
