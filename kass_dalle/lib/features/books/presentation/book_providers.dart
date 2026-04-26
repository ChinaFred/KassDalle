import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/book_repository.dart';
import '../domain/book.dart';
import '../../auth/presentation/auth_providers.dart';

final bookRepositoryProvider = Provider<BookRepository>((ref) {
  return BookRepository();
});

/// Livres dont l'utilisateur connecté est propriétaire.
final myBooksProvider = StreamProvider<List<Book>>((ref) {
  final uid = ref.watch(appUserProvider).valueOrNull?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(bookRepositoryProvider).watchMyBooks(uid);
});

/// Livres partagés avec l'utilisateur connecté.
final sharedBooksProvider = StreamProvider<List<Book>>((ref) {
  final uid = ref.watch(appUserProvider).valueOrNull?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(bookRepositoryProvider).watchSharedBooks(uid);
});

/// Tous les livres accessibles : propriétaire + partagés.
final accessibleBooksProvider = Provider<AsyncValue<List<Book>>>((ref) {
  final mine = ref.watch(myBooksProvider);
  final shared = ref.watch(sharedBooksProvider);

  if (mine.isLoading || shared.isLoading) return const AsyncValue.loading();
  if (mine.hasError) return AsyncValue.error(mine.error!, mine.stackTrace!);
  if (shared.hasError)
    return AsyncValue.error(shared.error!, shared.stackTrace!);

  final all = <Book>[...mine.valueOrNull ?? [], ...shared.valueOrNull ?? []];
  // Déduplique au cas où (admin peut avoir les deux)
  final seen = <String>{};
  final deduped = all.where((b) => seen.add(b.id)).toList();
  return AsyncValue.data(deduped);
});

/// Tous les livres (admin uniquement).
final allBooksProvider = StreamProvider<List<Book>>((ref) {
  return ref.watch(bookRepositoryProvider).watchAllBooks();
});
