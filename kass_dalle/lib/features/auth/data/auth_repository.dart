import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../../core/services/error_report_service.dart';
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
  })
    : _auth = auth ?? FirebaseAuth.instance,
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
        final shouldFallbackToRedirect = e.code == 'network-request-failed' ||
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
  /// Si c'est le premier utilisateur enregistré, le rôle est admin.
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

      // Nouvel utilisateur : déterminer le rôle
      final usersCount = await _firestore.collection('users').count().get();
      final role = (usersCount.count ?? 0) == 0
          ? UserRole.admin
          : UserRole.reader;

      final newUser = AppUser(
        uid: firebaseUser.uid,
        email: firebaseUser.email ?? '',
        displayName: firebaseUser.displayName ?? 'Utilisateur',
        photoUrl: firebaseUser.photoURL,
        role: role,
        createdAt: now,
        lastSeenAt: now,
        isRevoked: false,
      );

      transaction.set(userRef, newUser.toFirestore());
      return newUser;
    });
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
    final ts = DateTime.now().millisecondsSinceEpoch;
    final path = 'users/$uid/free_recipe_cover_$ts.jpg';
    final ref = storage.ref().child(path);
    final snapshot = await ref.putData(
      Uint8List.fromList(bytes),
      SettableMetadata(contentType: 'image/jpeg'),
    );
    final newUrl = await snapshot.ref.getDownloadURL();

    if (oldUrl != null && oldUrl.isNotEmpty) {
      try {
        await storage.refFromURL(oldUrl).delete();
      } catch (e, st) {
        await _errorReportService.reportError(
          feature: 'auth_delete_old_free_recipe_cover',
          error: e,
          stackTrace: st,
          context: {
            'uid': uid,
            'old_url': oldUrl,
          },
        );
      }
    }

    await updateFreeRecipeCoverUrl(uid, newUrl);
    return newUrl;
  }
}
