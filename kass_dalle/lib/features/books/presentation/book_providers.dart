import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/book_repository.dart';
import '../domain/book.dart';
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

/// Livres partagés avec l'utilisateur connecté.
final sharedBooksProvider = StreamProvider<List<Book>>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(bookRepositoryProvider).watchSharedBooks(uid);
});

/// Livres validés des membres des groupes familiaux (hors utilisateur courant).
final groupMemberBooksProvider = StreamProvider<List<Book>>((ref) {
  final memberIds = ref.watch(groupMemberIdsProvider).value;
  if (memberIds == null || memberIds.isEmpty) return Stream.value([]);
  return ref
      .watch(bookRepositoryProvider)
      .watchValidatedBooksByOwners(memberIds.toList());
});

/// Tous les livres accessibles : propriétaire + partagés + groupes.
final accessibleBooksProvider = Provider<AsyncValue<List<Book>>>((ref) {
  final mine = ref.watch(myBooksProvider);
  final shared = ref.watch(sharedBooksProvider);
  final group = ref.watch(groupMemberBooksProvider);

  if (mine.isLoading || shared.isLoading) {
    return const AsyncValue.loading();
  }
  if (mine.hasError) {
    return AsyncValue.error(mine.error!, mine.stackTrace!);
  }
  if (shared.hasError) {
    return AsyncValue.error(shared.error!, shared.stackTrace!);
  }

  final all = <Book>[
    ...mine.value ?? [],
    ...shared.value ?? [],
    ...group.value ?? [],
  ];
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
final bookByIdProvider = FutureProvider.family<Book?, String>((ref, bookId) {
  return ref.read(bookRepositoryProvider).getBook(bookId);
});
