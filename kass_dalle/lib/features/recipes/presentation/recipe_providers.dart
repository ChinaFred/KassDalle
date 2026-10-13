import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../admin/data/nutrition_ingredients_repository.dart';
import '../../groups/presentation/group_providers.dart';
import '../data/original_text_repository.dart';
import '../data/plating_repository.dart';
import '../data/recipe_rating_repository.dart';
import '../data/recipe_repository.dart';
import '../data/scan_upload_service.dart';
import '../data/share_intent_source.dart';
import '../data/shopping_cart_repository.dart';
import '../data/storage_repository.dart';
import '../domain/original_text.dart';
import '../domain/plating_advice.dart';
import '../domain/storage_advice.dart';
import '../domain/family_ratings.dart';
import '../domain/recipe.dart';
import '../domain/recipe_rating.dart';
import '../domain/recipe_viewer.dart';
import '../domain/shopping_cart.dart';
import '../../auth/domain/user_profile.dart';
import '../../auth/presentation/auth_providers.dart';

final recipeRepositoryProvider = Provider<RecipeRepository>((ref) {
  return RecipeRepository();
});

final platingRepositoryProvider = Provider<PlatingRepository>((ref) {
  return PlatingRepository();
});

final storageRepositoryProvider = Provider<StorageRepository>((ref) {
  return StorageRepository();
});

/// Droit de déclencher un conseil ou un calcul écrit sur la recette créée par
/// `createdBy` — conservation, dressage, visuel d'étape, nutrition.
///
/// Le créateur ou un administrateur : miroir de `assertCanModifyRecipe` côté
/// Functions, qui refuse les autres comptes avant tout appel de modèle.
///
/// Jamais un lecteur : depuis la v0.23.47, il ne planifie plus, et
/// `suggestStorageAdviceFn` exige le rôle éditeur. La fiche lui montre le
/// conseil déjà stocké, ou rien.
///
/// Asynchrone : la décision attend le profil. Lu avant son chargement, un
/// provider synchrone répondait « non » au créateur lui-même, et le bandeau de
/// préparation lui annonçait un conseil réservé.
final canWriteRecipeAdviceProvider =
    FutureProvider<bool Function(String createdBy)>((ref) async {
      final user = await ref.watch(appUserProvider.future);
      return (createdBy) =>
          (user?.canEdit ?? false) && user!.canModifyRecipe(createdBy);
    });

/// Conseil de conservation déjà stocké sur la recette, ou null.
///
/// Lecture ponctuelle : le conseil ne change que sur une action explicite.
final storageAdviceProvider = FutureProvider.autoDispose
    .family<StorageAdvice?, String>((ref, recipeId) async {
      if (recipeId.isEmpty) return null;
      return ref.read(storageRepositoryProvider).read(recipeId);
    });

/// Conseil de dressage déjà stocké sur la recette, ou null.
///
/// Lecture ponctuelle et non un flux : le conseil ne change que sur une action
/// délibérée de l'utilisateur, qui invalide alors ce provider lui-même.
final platingAdviceProvider = FutureProvider.family<PlatingAdvice?, String>((
  ref,
  recipeId,
) {
  return ref.watch(platingRepositoryProvider).read(recipeId);
});

final nutritionIngredientsRepositoryProvider =
    Provider<NutritionIngredientsRepository>((ref) {
      return NutritionIngredientsRepository();
    });

/// Profils nutritionnels des seuls identifiants demandés.
///
/// Le paramètre est la liste des identifiants **triés et joints par `|`**, et
/// non une `List` : deux listes de même contenu ne sont pas égales en Dart, si
/// bien qu'une `family` prenant une liste rouvrirait un flux Firestore à chaque
/// reconstruction du widget. Une chaîne, elle, se compare par valeur.
///
/// Se construit avec [nutritionProfileIdsKey].
final nutritionIngredientsByIdProvider =
    StreamProvider.family<Map<String, NutritionIngredientDoc>, String>((
      ref,
      idsKey,
    ) {
      final ids = idsKey.split('|').where((id) => id.isNotEmpty);
      return ref.watch(nutritionIngredientsRepositoryProvider).watchByIds(ids);
    });

/// Clé stable pour [nutritionIngredientsByIdProvider].
String nutritionProfileIdsKey(Iterable<String> ids) {
  final unique = <String>{
    for (final id in ids)
      if (id.trim().isNotEmpty) id.trim(),
  }.toList()..sort();
  return unique.join('|');
}

class RecipePortionOverrideRef {
  final String uid;
  final String recipeId;

  const RecipePortionOverrideRef({required this.uid, required this.recipeId});
}

/// Celui qui lit, pour construire des requêtes que les règles Firestore
/// peuvent prouver (voir [RecipeViewer]). `null` tant que le compte n'est pas
/// chargé.
///
/// La portée des groupes n'attend pas d'être chargée : tant qu'elle ne l'est
/// pas, le lecteur ne voit que ses propres recettes, puis celles de ses
/// groupes s'ajoutent.
final recipeViewerProvider = Provider<RecipeViewer?>((ref) {
  final user = ref.watch(appUserProvider).value;
  if (user == null) return null;
  final peers = ref.watch(groupMemberIdsProvider).value ?? const <String>{};
  return RecipeViewer.of(user, peers: peers);
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
  final viewer = ref.watch(recipeViewerProvider);
  if (viewer == null) return const Stream.empty();
  return ref.watch(recipeRepositoryProvider).watchByBook(bookId, viewer);
});

/// Toutes les pages validées d'un livre (recettes + pages non-recettes),
/// triées par numéro de page.
final allPagesByBookProvider = StreamProvider.family<List<Recipe>, String>((
  ref,
  bookId,
) {
  final viewer = ref.watch(recipeViewerProvider);
  if (viewer == null) return const Stream.empty();
  return ref
      .watch(recipeRepositoryProvider)
      .watchAllPagesByBook(bookId, viewer);
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
  final viewer = ref.watch(recipeViewerProvider);
  if (viewer == null) return const Stream.empty();
  final uid = viewer.uid;
  final repo = ref.watch(recipeRepositoryProvider);

  final ctrl = StreamController<List<Recipe>>();
  List<Recipe> byBook = [];
  List<Recipe> unattached = [];

  void push() {
    final merged = [...byBook, ...unattached];
    merged.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    ctrl.add(merged);
  }

  final sub1 = repo.watchByBook(bookId, viewer).listen((r) {
    byBook = r;
    push();
  }, onError: ctrl.addError);
  final sub2 = repo.watchUnattached(uid).listen((r) {
    unattached = r;
    push();
  }, onError: ctrl.addError);

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
///
/// Un lecteur ne relit pas les brouillons des autres (`firestore.rules`) :
/// pour lui la requête serait refusée en entier, la liste est vide.
final groupMemberDraftsProvider = StreamProvider<List<Recipe>>((ref) {
  if (!(ref.watch(recipeViewerProvider)?.canEdit ?? false)) {
    return Stream.value(const <Recipe>[]);
  }
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

final recipePortionsOverrideProvider =
    StreamProvider.family<int?, RecipePortionOverrideRef>((ref, input) {
      return ref
          .watch(recipeRepositoryProvider)
          .watchPortionsOverride(input.uid, input.recipeId);
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
  final viewer = ref.watch(recipeViewerProvider);
  if (viewer == null) return const Stream.empty();
  // Seuls les brouillons que le lecteur peut valider : un éditeur relit les
  // brouillons partagés des autres, mais ne les valide pas.
  return ref
      .watch(recipeRepositoryProvider)
      .watchDraftsByBook(bookId, viewer)
      .map(
        (list) => list
            .where((r) => viewer.isAdmin || r.createdBy == viewer.uid)
            .length,
      );
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
final recipeByIdProvider = FutureProvider.autoDispose.family<Recipe?, String>((
  ref,
  id,
) async {
  return ref.watch(recipeRepositoryProvider).getById(id);
});

final originalTextRepositoryProvider = Provider<OriginalTextRepository>(
  (_) => OriginalTextRepository(),
);

/// Texte d'origine d'une recette traduite, lu à l'ouverture de la vue qui
/// l'affiche et pas avant : la recette est lue dans toutes les listes, ce
/// texte seulement à la demande.
final originalTextProvider = FutureProvider.autoDispose
    .family<OriginalText?, String>((ref, recipeId) {
      return ref.watch(originalTextRepositoryProvider).read(recipeId);
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

/// Toutes les notes posées sur une recette, tous comptes confondus. Brut :
/// passer par [familyRatingsProvider] pour l'affichage.
final recipeRatingsProvider = StreamProvider.autoDispose
    .family<List<RecipeRating>, String>((ref, recipeId) {
      return ref
          .watch(recipeRatingRepositoryProvider)
          .watchAllForRecipe(recipeId);
    });

/// Notes de la famille sur une recette : ma note et celles des membres de
/// mes groupes.
///
/// En chargement tant que les notes, les groupes ou un profil de noteur ne
/// sont pas lus : une moyenne provisoire changerait sous les yeux. Un profil
/// absent écarte la note (compte supprimé) ; un profil illisible la garde
/// sous [UserProfile.fallbackName], pour qu'une coupure réseau ne fasse pas
/// baisser la moyenne.
final familyRatingsProvider = Provider.autoDispose
    .family<AsyncValue<FamilyRatings>, String>((ref, recipeId) {
      final ratingsAsync = ref.watch(recipeRatingsProvider(recipeId));
      final membersAsync = ref.watch(groupMemberIdsProvider);
      final myUid = ref.watch(appUserProvider).value?.uid;

      if (ratingsAsync.hasError) {
        return AsyncValue.error(ratingsAsync.error!, ratingsAsync.stackTrace!);
      }
      if (membersAsync.hasError) {
        return AsyncValue.error(membersAsync.error!, membersAsync.stackTrace!);
      }
      final ratings = ratingsAsync.value;
      final memberIds = membersAsync.value;
      if (ratings == null || memberIds == null) {
        return const AsyncValue.loading();
      }

      final names = <String, String?>{};
      for (final r in ratings) {
        if (r.userId == myUid || !memberIds.contains(r.userId)) continue;
        final profile = ref.watch(userProfileProvider(r.userId));
        if (profile.hasError) {
          names[r.userId] = UserProfile.fallbackName;
        } else if (!profile.hasValue) {
          return const AsyncValue.loading();
        } else {
          names[r.userId] = profile.value?.displayedName;
        }
      }

      return AsyncValue.data(
        FamilyRatings.from(
          ratings: ratings,
          myUid: myUid,
          memberIds: memberIds,
          nameOf: (uid) => names[uid],
        ),
      );
    });

// ── « Partager vers Kass'Dalle » (Android) ───────────────────────────────────

final shareIntentSourceProvider = Provider<ShareIntentSource>(
  (ref) => ShareIntentSource(),
);

/// Le dernier texte partagé vers l'application et pas encore traité.
///
/// Écouté dès le démarrage (`KassDalleApp`) : un partage qui ouvre
/// l'application avant la connexion attend ici que la session s'ouvre, puis
/// le shell le traite (`SharedLinkImportHost`).
final pendingSharedTextProvider =
    NotifierProvider<PendingSharedTextNotifier, String?>(
      PendingSharedTextNotifier.new,
    );

class PendingSharedTextNotifier extends Notifier<String?> {
  @override
  String? build() {
    final subscription = ref
        .watch(shareIntentSourceProvider)
        .sharedTexts()
        .listen((text) => state = text);
    ref.onDispose(subscription.cancel);
    return null;
  }

  /// Rend le texte en attente et le retire : un partage ne se traite qu'une
  /// fois.
  String? take() {
    final text = state;
    state = null;
    return text;
  }
}

// ── Panier de courses ─────────────────────────────────────────────────────────

final shoppingCartRepositoryProvider = Provider<ShoppingCartRepository>(
  (_) => ShoppingCartRepository(),
);

/// Le panier de courses du compte connecté, en direct : le même sur tous ses
/// appareils. À la première lecture sur un appareil, l'ancienne liste locale
/// est reprise si le panier est vide (`migrateLocalList`).
final myShoppingCartProvider = StreamProvider.autoDispose<ShoppingCart>((ref) {
  final uid = ref.watch(appUserProvider.select((u) => u.value?.uid));
  if (uid == null) return Stream.value(ShoppingCart.empty);
  return ref.watch(shoppingCartRepositoryProvider).watchAfterMigration(uid);
});
