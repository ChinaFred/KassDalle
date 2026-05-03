import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../data/auth_repository.dart';
import '../domain/app_user.dart';

// Repository provider
final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository();
});

// Firebase auth state (User? brut Firebase)
final firebaseAuthStateProvider = StreamProvider<User?>((ref) {
  return ref.watch(authRepositoryProvider).authStateChanges;
});

// AppUser complet (avec rôle Firestore) — réactif
final appUserProvider = StreamProvider<AppUser?>((ref) {
  final authState = ref.watch(firebaseAuthStateProvider);
  return authState.when(
    data: (user) {
      if (user == null) return Stream.value(null);
      return ref.watch(authRepositoryProvider).watchAppUser(user.uid);
    },
    loading: () => Stream.value(null),
    error: (_, _) => Stream.value(null),
  );
});

// Helpers de commodité
final isAuthenticatedProvider = Provider<bool>((ref) {
  return ref.watch(appUserProvider).valueOrNull != null;
});

/// Profil d'un utilisateur par son UID (lecture unique, mis en cache).
final userByUidProvider = FutureProvider.family<AppUser?, String>((ref, uid) {
  return ref.read(authRepositoryProvider).getAppUser(uid);
});

final canEditProvider = Provider<bool>((ref) {
  return ref.watch(appUserProvider).valueOrNull?.canEdit ?? false;
});

final isAdminProvider = Provider<bool>((ref) {
  return ref.watch(appUserProvider).valueOrNull?.isAdmin ?? false;
});
