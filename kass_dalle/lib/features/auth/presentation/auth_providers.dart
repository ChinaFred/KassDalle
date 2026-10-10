import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../data/auth_repository.dart';
import '../data/user_profile_repository.dart';
import '../domain/app_user.dart';
import '../domain/user_profile.dart';

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

final userProfileRepositoryProvider = Provider<UserProfileRepository>((ref) {
  return UserProfileRepository();
});

/// Profil public d'un membre par son UID — son nom et sa couverture
/// « Recette libre », tels que les autres membres les voient.
///
/// Le compte courant se lit dans son propre document, en direct : un nom
/// préféré qu'il vient de changer s'affiche aussitôt, sans attendre que le
/// serveur recopie le profil. Les autres se lisent dans `user_profiles/{uid}`
/// (une lecture, gardée pour la session une fois réussie : la même personne
/// revient sur chaque carte de recette et chaque en-tête de bibliothèque) ;
/// `null` si le profil n'existe pas encore — l'écran affiche alors
/// [UserProfile.fallbackName]. Une lecture en échec n'est pas gardée : elle
/// sera retentée à la prochaine ouverture.
final userProfileProvider = FutureProvider.autoDispose
    .family<UserProfile?, String>((ref, uid) async {
      final myUid = ref.watch(appUserProvider.select((u) => u.value?.uid));
      if (myUid != null && myUid == uid) {
        final me = ref.watch(appUserProvider).value;
        return me == null ? null : UserProfile.fromAppUser(me);
      }
      final profile = await ref
          .read(userProfileRepositoryProvider)
          .getProfile(uid);
      ref.keepAlive();
      return profile;
    });

/// Le nom d'un membre à afficher : `null` pendant la lecture, le nom du
/// profil ensuite, ou [UserProfile.fallbackName] si le profil manque ou ne
/// se lit pas.
final memberNameProvider = Provider.autoDispose.family<String?, String>((
  ref,
  uid,
) {
  final profile = ref.watch(userProfileProvider(uid));
  if (profile.isLoading && !profile.hasValue) return null;
  return profile.value?.displayedName ?? UserProfile.fallbackName;
});

final canEditProvider = Provider<bool>((ref) {
  return ref.watch(appUserProvider).value?.canEdit ?? false;
});

final isAdminProvider = Provider<bool>((ref) {
  return ref.watch(appUserProvider).value?.isAdmin ?? false;
});
