import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/services/usage_providers.dart';
import '../data/recipe_repository.dart';
import '../data/scan_upload_service.dart';
import '../domain/recipe.dart';
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

/// Recettes validées sans livre (recettes libres).
final unattachedRecipesProvider = StreamProvider<List<Recipe>>((ref) {
  final uid = ref.watch(appUserProvider).valueOrNull?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(recipeRepositoryProvider).watchUnattached(uid);
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

/// Notifier du scan upload.
final scanUploadProvider = StateNotifierProvider<ScanUploadNotifier, ScanState>(
  (ref) {
    return ScanUploadNotifier(
      ref.watch(recipeRepositoryProvider),
      FirebaseStorage.instance,
      FirebaseAuth.instance,
      ref.watch(usageTrackerProvider),
    );
  },
);
