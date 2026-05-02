import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
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
  final GoogleSignIn? _googleSignIn;

  AuthRepository({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    GoogleSignIn? googleSignIn,
  }) : _auth = auth ?? FirebaseAuth.instance,
       _firestore = firestore ?? FirebaseFirestore.instance,
       _googleSignIn = kIsWeb ? null : (googleSignIn ?? GoogleSignIn());

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<AppUser?> signInWithGoogle() async {
    final User? user;

    if (kIsWeb) {
      final provider = GoogleAuthProvider();
      if (kDebugMode && _devAutoLogin && _devBypassEmail.isNotEmpty) {
        provider.setCustomParameters({'login_hint': _devBypassEmail});
      }
      final userCredential = await _auth.signInWithPopup(provider);
      user = userCredential.user;
    } else {
      final googleSignIn = _googleSignIn;
      if (googleSignIn == null) return null;

      // Tentative de connexion silencieuse avec timeout
      GoogleSignInAccount? silentUser;
      try {
        silentUser = await googleSignIn.signInSilently().timeout(
          const Duration(seconds: 5),
          onTimeout: () => null,
        );
      } catch (e) {
        debugPrint('Silent sign-in failed: $e');
      }

      GoogleSignInAccount? googleUser;
      try {
        googleUser = silentUser ?? await googleSignIn.signIn();
      } on PlatformException catch (e) {
        if (e.code == 'sign_in_failed' && (e.message ?? '').contains('10')) {
          throw StateError(
            'Google Sign-In Android refuse cette signature d\'application. '
            'Ajoutez la SHA1 release 60:4C:DB:D0:98:A5:52:D9:25:FE:48:BD:75:6B:1E:A9:80:12:29:F3 '
            'dans Firebase pour le package dev.kassbi.kass_dalle, puis retéléchargez google-services.json.',
          );
        }
        rethrow;
      }
      if (googleUser == null) return null;

      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
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
      if (_googleSignIn != null) _googleSignIn.signOut(),
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
        // Utilisateur existant : mettre à jour last_seen_at uniquement
        transaction.update(userRef, {'last_seen_at': now});
        final data = userSnap.data()!;
        data['last_seen_at'] = Timestamp.fromDate(now);
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
}
