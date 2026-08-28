import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../../core/services/error_report_service.dart';
import '../../moderation/data/image_moderation_service.dart';
import '../domain/app_user.dart';

const _devAutoLogin = bool.fromEnvironment(
  'DEV_AUTO_LOGIN',
  defaultValue: true,
);
const _devBypassEmail = String.fromEnvironment(
  'DEV_BYPASS_EMAIL',
  defaultValue: 'china.fred.75@gmail.com',
);

class AuthRepository {
  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final ErrorReportService _errorReportService;

  AuthRepository({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
  }) : _auth = auth ?? FirebaseAuth.instance,
       _firestore = firestore ?? FirebaseFirestore.instance,
       _errorReportService = errorReportService ?? ErrorReportService();

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<AppUser?> signInWithGoogle() async {
    final User? user;

    if (kIsWeb) {
      final provider = GoogleAuthProvider();
      if (kDebugMode && _devAutoLogin && _devBypassEmail.isNotEmpty) {
        provider.setCustomParameters({'login_hint': _devBypassEmail});
      }
      try {
        final userCredential = await _auth.signInWithPopup(provider);
        user = userCredential.user;
      } on FirebaseAuthException catch (e, st) {
        final shouldFallbackToRedirect =
            e.code == 'network-request-failed' ||
            e.code == 'popup-blocked' ||
            e.code == 'popup-closed-by-user' ||
            e.code == 'internal-error';

        if (!shouldFallbackToRedirect) {
          await _errorReportService.reportError(
            feature: 'auth_web_sign_in_popup',
            error: e,
            stackTrace: st,
            context: {
              'step': 'signInWithPopup',
              'code': e.code,
              'message': e.message,
            },
          );
          rethrow;
        }

        // Fallback robuste web: redirect fonctionne mieux que popup selon
        // navigateurs/extensions/réseaux (cookies tiers, bloqueurs, proxy).
        await _auth.signInWithRedirect(provider);
        return null;
      }
    } else {
      // Tentative de connexion silencieuse
      GoogleSignInAccount? googleUser;
      try {
        final future = GoogleSignIn.instance.attemptLightweightAuthentication();
        if (future != null) {
          googleUser = await future.timeout(
            const Duration(seconds: 5),
            onTimeout: () => null,
          );
        }
      } catch (e) {
        debugPrint('Lightweight sign-in failed: $e');
        await _errorReportService.reportError(
          feature: 'auth_lightweight_sign_in',
          error: e,
          context: {
            'step': 'attemptLightweightAuthentication',
            'platform': kIsWeb ? 'web' : 'native',
          },
        );
      }

      // Si la connexion silencieuse a échoué, connexion interactive
      if (googleUser == null) {
        try {
          googleUser = await GoogleSignIn.instance.authenticate();
        } on GoogleSignInException catch (e) {
          if (e.code == GoogleSignInExceptionCode.canceled) {
            return null;
          }
          rethrow;
        }
      }

      final googleAuth = googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );

      final userCredential = await _auth.signInWithCredential(credential);
      user = userCredential.user;
    }

    if (user == null) return null;
    return _upsertUser(user);
  }

  Future<void> signOut() async {
    await Future.wait([
      _auth.signOut(),
      if (!kIsWeb) GoogleSignIn.instance.signOut(),
    ]);
  }

  Future<AppUser?> getAppUser(String uid) async {
    final doc = await _firestore.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    return AppUser.fromFirestore(doc.data()!);
  }

  Stream<AppUser?> watchAppUser(String uid) {
    return _firestore
        .collection('users')
        .doc(uid)
        .snapshots()
        .map((doc) => doc.exists ? AppUser.fromFirestore(doc.data()!) : null);
  }

  /// Crée ou met à jour le profil utilisateur dans Firestore.
  ///
  /// Un compte neuf naît **en attente**, et rien ici ne peut en décider
  /// autrement. Le rôle était auparavant choisi de ce côté-ci : l'application
  /// comptait la collection `users` et s'attribuait `admin` si elle la trouvait
  /// vide. Comme les règles ne contraignaient aucun champ à la création,
  /// l'astuce n'était même pas nécessaire — il suffisait d'écrire soi-même
  /// `role: "admin"` dans son propre document, hors application, pour devenir
  /// administrateur. Le rôle est désormais imposé par les règles à la création
  /// et ne change plus que par la main d'un administrateur ; le tout premier
  /// est amorcé côté serveur par `enforceFounderRole`.
  Future<AppUser> _upsertUser(User firebaseUser) async {
    final userRef = _firestore.collection('users').doc(firebaseUser.uid);
    final now = DateTime.now();

    return _firestore.runTransaction<AppUser>((transaction) async {
      final userSnap = await transaction.get(userRef);

      if (userSnap.exists) {
        // Utilisateur existant : mettre à jour last_seen_at et photo de profil
        final updates = <String, dynamic>{
          'last_seen_at': Timestamp.fromDate(now),
        };
        if (firebaseUser.photoURL != null) {
          updates['photo_url'] = firebaseUser.photoURL;
        }
        if (firebaseUser.displayName != null) {
          updates['display_name'] = firebaseUser.displayName;
        }
        transaction.update(userRef, updates);
        final data = userSnap.data()!..addAll(updates);
        return AppUser.fromFirestore(data);
      }

      // Nouvel utilisateur : en attente, sans exception.
      //
      // L'adresse est celle du compte Google et non un champ libre : les règles
      // exigent qu'elle soit égale à celle du jeton, faute de quoi la création
      // est refusée. C'est ce qui empêche un compte de se réclamer d'une autre
      // identité que la sienne.
      final newUser = AppUser(
        uid: firebaseUser.uid,
        email: firebaseUser.email ?? '',
        displayName: firebaseUser.displayName ?? 'Utilisateur',
        photoUrl: firebaseUser.photoURL,
        role: UserRole.pending,
        createdAt: now,
        lastSeenAt: now,
        isRevoked: false,
      );

      transaction.set(userRef, newUser.toFirestore());
      return newUser;
    });
  }

  /// Enregistre le nom préféré de [uid], ou l'efface si [name] est vide.
  ///
  /// Effacer rend le compte à son prénom Google : c'est la valeur par défaut,
  /// et la stocker en dur figerait le jour où le compte Google change de nom.
  ///
  /// Un administrateur peut écrire pour un autre ; chacun peut écrire pour
  /// soi. Les règles Firestore posent les deux, et refusent tout le reste.
  Future<void> updatePreferredName(String uid, String? name) async {
    final trimmed = name?.trim() ?? '';
    try {
      await _firestore.collection('users').doc(uid).update({
        'preferred_name': trimmed.isEmpty ? null : trimmed,
      });
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'auth_update_preferred_name',
        error: e,
        stackTrace: st,
        context: {'uid': uid},
      );
      rethrow;
    }
  }

  /// Met à jour l'URL de couverture "Recette libre" de l'utilisateur.
  Future<void> updateFreeRecipeCoverUrl(String uid, String url) async {
    await _firestore.collection('users').doc(uid).update({
      'free_recipe_cover_url': url,
    });
  }

  /// Upload une nouvelle couverture "Recette libre" vers Firebase Storage,
  /// supprime l'ancienne et met à jour Firestore.
  /// Retourne le nouvel URL de download.
  Future<String> uploadFreeRecipeCover(
    String uid,
    List<int> bytes, {
    String? oldUrl,
  }) async {
    final storage = FirebaseStorage.instance;
    // `users/` est fermé en écriture : la couverture passe par la quarantaine
    // et la modération, comme toute image vue par la famille.
    final newUrl = await ImageModerationService().publish(
      PendingImage(
        bytes: Uint8List.fromList(bytes),
        filename: 'free_recipe_cover.jpg',
        contentType: 'image/jpeg',
        target: ModerationTarget.freeRecipeCover,
      ),
    );

    if (oldUrl != null && oldUrl.isNotEmpty) {
      try {
        await storage.refFromURL(oldUrl).delete();
      } catch (e, st) {
        await _errorReportService.reportError(
          feature: 'auth_delete_old_free_recipe_cover',
          error: e,
          stackTrace: st,
          context: {'uid': uid, 'old_url': oldUrl},
        );
      }
    }

    await updateFreeRecipeCoverUrl(uid, newUrl);
    return newUrl;
  }
}
