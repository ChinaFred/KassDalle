import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/book_repository.dart';
import '../domain/book.dart';
import '../domain/book_order.dart';
import '../domain/library_origin.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../groups/presentation/group_providers.dart';

final bookRepositoryProvider = Provider<BookRepository>((ref) {
  return BookRepository();
});

/// Livres dont l'utilisateur connecté est propriétaire.
final myBooksProvider = StreamProvider<List<Book>>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(bookRepositoryProvider).watchMyBooks(uid);
});

/// Livres validés des membres des groupes familiaux (hors utilisateur courant).
final groupMemberBooksProvider = StreamProvider<List<Book>>((ref) {
  final memberIds = ref.watch(groupMemberIdsProvider).value;
  if (memberIds == null || memberIds.isEmpty) return Stream.value([]);
  return ref
      .watch(bookRepositoryProvider)
      .watchValidatedBooksByOwners(memberIds.toList());
});

/// Tous les livres accessibles : les miens et ceux de mes groupes.
///
/// Une troisième source figurait ici — les livres qu'on m'aurait partagés
/// nominativement. Aucun écran n'écrivait jamais ce partage : le flux rendait
/// une liste vide en toute circonstance, et son état de chargement retardait
/// pourtant l'affichage des deux autres.
final accessibleBooksProvider = Provider<AsyncValue<List<Book>>>((ref) {
  final mine = ref.watch(myBooksProvider);
  final group = ref.watch(groupMemberBooksProvider);

  if (mine.isLoading) {
    return const AsyncValue.loading();
  }
  if (mine.hasError) {
    return AsyncValue.error(mine.error!, mine.stackTrace!);
  }

  final all = <Book>[...mine.value ?? [], ...group.value ?? []];
  final seen = <String>{};
  final deduped = all.where((b) => seen.add(b.id)).toList();
  return AsyncValue.data(deduped);
});

/// Tous les livres (admin uniquement).
final allBooksProvider = StreamProvider<List<Book>>((ref) {
  return ref.watch(bookRepositoryProvider).watchAllBooks();
});

/// Brouillons livre a valider (proprietaire uniquement).
final draftBooksProvider = StreamProvider<List<Book>>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(bookRepositoryProvider).watchDraftBooks(uid);
});

final draftBooksCountProvider = Provider<int>((ref) {
  return ref.watch(draftBooksProvider).value?.length ?? 0;
});

/// Récupère un livre par son id (lecture unique, mis en cache par Riverpod).
final bookByIdProvider = FutureProvider.autoDispose.family<Book?, String>((
  ref,
  bookId,
) {
  return ref.read(bookRepositoryProvider).getBook(bookId);
});

/// ID du livre "Mes recettes libres" de l'utilisateur connecté.
final libresBookProvider = FutureProvider<({String id, String titre})?>((
  ref,
) async {
  final user = ref.watch(appUserProvider).value;
  if (user == null) return null;
  final displayName = user.displayName;
  return ref
      .read(bookRepositoryProvider)
      .findOrCreateLibresBook(user.uid, displayName);
});

/// ID du livre "Mes Recettes Secrètes" de l'utilisateur connecté.
final secretesBookProvider = FutureProvider<({String id, String titre})?>((
  ref,
) async {
  final user = ref.watch(appUserProvider).value;
  if (user == null) return null;
  final displayName = user.displayName;
  return ref
      .read(bookRepositoryProvider)
      .findOrCreateSecretesBook(user.uid, displayName);
});

/// D'où vient le livre tenu par [ownerUid], en une phrase prête à afficher.
///
/// Rend `null` tant que le profil du propriétaire n'est pas chargé, ou si le
/// lecteur n'a pas le droit de le lire : les rôles `reader` ne voient que leur
/// propre document utilisateur. Une phrase absente vaut mieux qu'un « au
/// travers de … » sans nom.
final libraryOriginProvider = Provider.autoDispose.family<String?, String>((
  ref,
  ownerUid,
) {
  if (ownerUid.isEmpty) return null;
  final myUid = ref.watch(appUserProvider).value?.uid;
  if (myUid != null && myUid == ownerUid) {
    return libraryOriginLabel(
      isMine: true,
      ownerName: null,
      groupNames: const [],
    );
  }
  final owner = ref.watch(userByUidProvider(ownerUid)).value;
  return libraryOriginLabel(
    isMine: false,
    ownerName: owner?.displayedName,
    groupNames: ref.watch(sharedGroupNamesProvider(ownerUid)),
  );
});

/// Ordre d'affichage choisi par l'utilisateur, en identifiants de livres.
final bookOrderProvider = StreamProvider<List<String>>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(bookRepositoryProvider).watchBookOrder(uid);
});

/// Mes livres, rangés comme je les ai rangés.
///
/// L'ordre ne conditionne jamais l'affichage : tant qu'il n'est pas chargé —
/// ou s'il ne l'est jamais — la bibliothèque sort dans son ordre naturel.
final myBooksOrderedProvider = Provider<AsyncValue<List<Book>>>((ref) {
  final order = ref.watch(bookOrderProvider).value ?? const <String>[];
  return ref
      .watch(myBooksProvider)
      .whenData((books) => applyBookOrder(books, order));
});

/// Les livres où l'utilisateur peut ranger une recette : les siens, rangés
/// comme il les a rangés ; un administrateur y ajoute ceux des autres.
///
/// Décision de l'utilisateur (v0.23.8) : on ne range une recette que dans ses
/// propres livres, l'administrateur partout. Les règles Firestore et le
/// pipeline d'import le refusent de toute façon ; le sélecteur ne propose pas
/// un choix qui échouerait à l'enregistrement.
final targetBooksProvider = Provider<AsyncValue<List<Book>>>((ref) {
  final mine = ref.watch(myBooksOrderedProvider);
  if (!ref.watch(isAdminProvider)) return mine;
  final others = ref.watch(allBooksProvider).value ?? const <Book>[];
  // Les livres système des autres (« Mes recettes libres » de chacun…)
  // portent tous le même titre : les proposer donnait une liste de doublons
  // indiscernables. Le nom du propriétaire n'est pas ajouté au titre : le
  // sélecteur rend ce titre, qui s'écrit dans `book_titre` de la recette.
  return mine.whenData((books) {
    final ids = {for (final b in books) b.id};
    return [
      ...books,
      ...others.where((b) => !ids.contains(b.id) && !b.isSystemBook),
    ];
  });
});
