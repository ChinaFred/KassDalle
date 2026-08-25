import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/book_repository.dart';
import '../domain/book.dart';
import '../domain/book_order.dart';
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
