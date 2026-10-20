import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../../core/services/error_report_service.dart';
import '../../moderation/data/image_moderation_service.dart';
import '../domain/app_user.dart';
import '../domain/user_profile.dart';

const _devAutoLogin = bool.fromEnvironment(
  'DEV_AUTO_LOGIN',
  defaultValue: true,
);
const _devBypassEmail = String.fromEnvironment(
  'DEV_BYPASS_EMAIL',
  defaultValue: 'china.fred.75@gmail.com',
);

/// Renouvellements du jeton tentés avant d'émettre le document, quand ses
/// claims sont en retard : deux, à [kTokenAlignDelay] d'intervalle, soit
/// moins de 3 s d'attente.
const kTokenAlignQuickAttempts = 2;

/// Renouvellements tentés en tout, attente avant émission comprise. Ceux qui
/// restent se font après l'émission, sans bloquer l'écran.
const kTokenAlignAttempts = 8;

/// Attente entre deux renouvellements.
const kTokenAlignDelay = Duration(milliseconds: 1500);

/// Vrai si les claims du jeton sont en retard sur le document [user], d'une
/// façon qui fait refuser par les règles ce que le document permet :
///  - le jeton dit révoqué, le document ne l'est plus (les règles croient le
///    jeton quand il confirme une révocation) ;
///  - le jeton porte un rôle autre que celui, nommé, du document (les règles
///    lisent le rôle du jeton quand il en porte un).
/// Un document révoqué ou en attente ne demande rien : il n'ouvre rien, quel
/// que soit le jeton. Pure, testée.
bool tokenLagsBehind(Map<String, dynamic>? claims, AppUser user) {
  if (claims == null || user.isRevoked || user.isPending) return false;
  if (claims['revoked'] == true) return true;
  final role = claims['role'];
  return role is String && role.isNotEmpty && role != user.role.name;
}

/// Ce que l'alignement a donné avant l'émission du document.
enum TokenAlignStart {
  /// Le jeton suit le document : rien à faire.
  inStep,

  /// Le jeton a rattrapé le document pendant l'attente courte.
  aligned,

  /// Toujours en retard : la suite continue après l'émission.
  continuing,

  /// Déjà tenté pour ce compte et cet état pendant la session : rien n'est
  /// relancé (l'écart a été rapporté la première fois).
  alreadyTried,
}

/// Aligne les claims du jeton sur le document du compte, une fois par
/// session et par état (uid, rôle, révocation).
///
/// [start] attend au plus [kTokenAlignQuickAttempts] renouvellements, puis
/// rend la main ; s'il faut continuer, les renouvellements restants tournent
/// sans bloquer et appellent `onAligned` dès que le jeton suit. Au bout de
/// [kTokenAlignAttempts], l'écart est rapporté par `onGiveUp`. Pas de boucle :
/// un état déjà tenté n'est jamais relancé dans la session.
class TokenClaimsAligner {
  /// Lit les claims du jeton, renouvelé si [refresh].
  final Future<Map<String, dynamic>?> Function({required bool refresh})
  readClaims;
  final Duration delay;
  final int quickAttempts;
  final int totalAttempts;
  final Set<String> _tried = {};

  TokenClaimsAligner({
    required this.readClaims,
    this.delay = kTokenAlignDelay,
    this.quickAttempts = kTokenAlignQuickAttempts,
    this.totalAttempts = kTokenAlignAttempts,
  });

  static String stateKey(AppUser user) =>
      '${user.uid}|${user.role.name}|${user.isRevoked}';

  /// Une erreur de l'attente courte remonte à l'appelant ; une erreur de la
  /// suite, qui tourne après l'émission, passe par [onError].
  Future<TokenAlignStart> start(
    AppUser user, {
    required void Function() onAligned,
    required Future<void> Function(Map<String, dynamic>? claims) onGiveUp,
    required Future<void> Function(Object error, StackTrace stackTrace) onError,
  }) async {
    final claims = await readClaims(refresh: false);
    if (!tokenLagsBehind(claims, user)) return TokenAlignStart.inStep;
    if (!_tried.add(stateKey(user))) return TokenAlignStart.alreadyTried;
    final (quickOk, _) = await _refresh(user, quickAttempts, firstDelay: false);
    if (quickOk) {
      // Un état qui a fini par suivre peut être retenté plus tard (rôle
      // changé puis rendu) ; seul un écart qui persiste ne l'est plus.
      _tried.remove(stateKey(user));
      return TokenAlignStart.aligned;
    }
    unawaited(() async {
      try {
        final (ok, last) = await _refresh(
          user,
          totalAttempts - quickAttempts,
          firstDelay: true,
        );
        if (ok) {
          _tried.remove(stateKey(user));
          onAligned();
        } else {
          await onGiveUp(last);
        }
      } catch (e, st) {
        await onError(e, st);
      }
    }());
    return TokenAlignStart.continuing;
  }

  /// Jusqu'à [attempts] renouvellements espacés de [delay]. Rend `true` dès
  /// que le jeton suit, avec les derniers claims lus.
  Future<(bool, Map<String, dynamic>?)> _refresh(
    AppUser user,
    int attempts, {
    required bool firstDelay,
  }) async {
    Map<String, dynamic>? claims;
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0 || firstDelay) await Future<void>.delayed(delay);
      claims = await readClaims(refresh: true);
      if (!tokenLagsBehind(claims, user)) return (true, claims);
    }
    return (false, claims);
  }
}

class AuthRepository {
  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final ErrorReportService _errorReportService;
  late final TokenClaimsAligner _aligner = TokenClaimsAligner(
    readClaims: _readClaims,
  );

  AuthRepository({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
  }) : _auth = auth ?? FirebaseAuth.instance,
       _firestore = firestore ?? FirebaseFirestore.instance,
       _errorReportService = errorReportService ?? ErrorReportService();

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Connexion Google.
  ///
  /// [forceAccountChooser] ouvre toujours le choix du compte : sur le web,
  /// `prompt: select_account` est passé à Google ; sur mobile et desktop, la
  /// connexion silencieuse (qui reprendrait le dernier compte) est sautée et
  /// la connexion interactive s'ouvre directement.
  Future<AppUser?> signInWithGoogle({bool forceAccountChooser = false}) async {
    final User? user;

    if (kIsWeb) {
      final provider = GoogleAuthProvider();
      final parameters = <String, String>{
        if (kDebugMode && _devAutoLogin && _devBypassEmail.isNotEmpty)
          'login_hint': _devBypassEmail,
        if (forceAccountChooser) 'prompt': 'select_account',
      };
      if (parameters.isNotEmpty) provider.setCustomParameters(parameters);
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
        // La page se recharge : la connexion se termine au démarrage suivant
        // (`completeRedirectSignIn`, appelée par `main.dart`).
        await _auth.signInWithRedirect(provider);
        return null;
      }
    } else {
      // Tentative de connexion silencieuse, sauf si le choix du compte est
      // demandé : elle reprendrait le dernier compte sans le montrer.
      GoogleSignInAccount? googleUser;
      if (!forceAccountChooser) {
        try {
          final future = GoogleSignIn.instance
              .attemptLightweightAuthentication();
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

  /// Web : termine une connexion commencée par `signInWithRedirect` (repli
  /// de [signInWithGoogle] quand la fenêtre surgissante échoue).
  ///
  /// La page est rechargée au retour de Google : sans cet appel au démarrage,
  /// la session existe mais [_upsertUser] n'a pas tourné. Un compte neuf n'a
  /// alors pas de document `users/{uid}` (rien d'autre ne le crée) et reste
  /// sur l'écran de connexion ; un compte existant n'écrit pas `last_seen_at`,
  /// dont dépend le retour d'un compte révoqué invité par e-mail. Sans
  /// redirection en cours, `getRedirectResult` rend un résultat vide et rien
  /// n'est écrit. Hors web : rien.
  Future<AppUser?> completeRedirectSignIn() async {
    if (!kIsWeb) return null;
    try {
      final result = await _auth.getRedirectResult();
      final user = result.user;
      if (user == null) return null;
      return await _upsertUser(user);
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'auth_web_redirect_result',
        error: e,
        stackTrace: st,
        context: {'step': 'getRedirectResult'},
      );
      return null;
    }
  }

  /// Nouvelle connexion d'un compte révoqué, depuis l'écran de révocation.
  ///
  /// Le choix du compte s'ouvre toujours (`forceAccountChooser`) : sur le
  /// web, `prompt: select_account`, sans quoi Google reconnecte en un clic le
  /// compte révoqué ; sur mobile et desktop, sans connexion silencieuse. Sur
  /// mobile et desktop, la session en cours est d'abord fermée : ses jetons
  /// ont été invalidés à la révocation. Sur le web, aucune attente avant la
  /// fenêtre Google : elle la ferait bloquer par le navigateur (geste
  /// utilisateur perdu). La connexion passe par [signInWithGoogle], donc par
  /// [_upsertUser],
  /// qui écrit `last_seen_at` : c'est cette écriture qui réveille
  /// `applyRevokedInvitation`.
  Future<AppUser?> signInAgainAfterRevocation() async {
    if (kIsWeb) return signInWithGoogle(forceAccountChooser: true);
    try {
      await signOut();
    } catch (e, st) {
      // La connexion qui suit remplace la session de toute façon.
      await _errorReportService.reportError(
        feature: 'auth_sign_out_before_sign_in',
        error: e,
        stackTrace: st,
        context: {'step': 'signOut'},
      );
    }
    return signInWithGoogle(forceAccountChooser: true);
  }

  Future<void> signOut() async {
    await Future.wait([
      _auth.signOut(),
      if (!kIsWeb) GoogleSignIn.instance.signOut(),
    ]);
  }

  /// Le compte [uid] en temps réel.
  ///
  /// Les claims du jeton sont posés par `syncUserClaims` quelques secondes
  /// après l'écriture du document. Un compte rétabli à sa reconnexion par une
  /// invitation par e-mail (`applyRevokedInvitation`) garde sinon, jusqu'à
  /// une heure, un jeton dont le claim `revoked` vaut encore `true`, et les
  /// règles lui refusent tout alors que l'écran de révocation s'est fermé.
  ///
  /// Une version du document dont le jeton est en retard attend au plus deux
  /// renouvellements (moins de 3 s) avant d'être émise : sans cette attente,
  /// l'accueil ouvert par le routeur démarre ses lectures avec l'ancien jeton,
  /// et les listes qui échouent ne repartent pas seules. Si le jeton n'a pas
  /// suivi, le document est émis quand même, l'alignement continue sans
  /// bloquer, et le document est émis une seconde fois quand le jeton suit :
  /// les écrans qui lisent le compte se reconstruisent et relancent leurs
  /// lectures. Une fois par session et par état ([TokenClaimsAligner]).
  Stream<AppUser?> watchAppUser(String uid) {
    late final StreamController<AppUser?> controller;
    StreamSubscription<AppUser?>? sub;
    AppUser? latest;
    controller = StreamController<AppUser?>(
      onListen: () {
        sub = _firestore
            .collection('users')
            .doc(uid)
            .snapshots()
            .map(
              // L'uid vient de l'identifiant du document, pas du champ
              // `uid` écrit par le client (ticket #162).
              (doc) => doc.exists
                  ? AppUser.fromFirestore({...doc.data()!, 'uid': doc.id})
                  : null,
            )
            .asyncMap((user) async {
              if (user != null) {
                await _alignTokenWith(
                  user,
                  onAligned: () {
                    final now = latest;
                    if (controller.isClosed || now == null) return;
                    if (TokenClaimsAligner.stateKey(now) !=
                        TokenClaimsAligner.stateKey(user)) {
                      return;
                    }
                    // Nouvelle instance : le provider ne notifie pas une
                    // valeur égale à la précédente.
                    controller.add(now.copyWith());
                  },
                );
              }
              return user;
            })
            .listen(
              (user) {
                latest = user;
                controller.add(user);
              },
              onError: controller.addError,
              onDone: controller.close,
            );
      },
      onCancel: () async {
        await sub?.cancel();
      },
    );
    return controller.stream;
  }

  Future<Map<String, dynamic>?> _readClaims({required bool refresh}) async {
    final current = _auth.currentUser;
    if (current == null) return null;
    return (await current.getIdTokenResult(refresh)).claims;
  }

  /// Aligne le jeton sur [user] ([TokenClaimsAligner]). Un échec de lecture
  /// du jeton, ou un écart qui persiste, est rapporté ; le document est émis
  /// dans tous les cas.
  Future<void> _alignTokenWith(
    AppUser user, {
    required void Function() onAligned,
  }) async {
    final current = _auth.currentUser;
    if (current == null || current.uid != user.uid) return;
    try {
      await _aligner.start(
        user,
        onAligned: onAligned,
        onGiveUp: (claims) => _errorReportService.reportError(
          feature: 'auth_token_claims_lag',
          error: StateError('Claims du jeton toujours en retard sur le compte'),
          context: {
            'uid': user.uid,
            'doc_role': user.role.name,
            'doc_revoked': user.isRevoked,
            'claim_role': claims?['role'],
            'claim_revoked': claims?['revoked'],
          },
        ),
        onError: (e, st) => _errorReportService.reportError(
          feature: 'auth_token_claims_lag',
          error: e,
          stackTrace: st,
          context: {'uid': user.uid, 'step': 'getIdTokenResult (suite)'},
        ),
      );
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'auth_token_claims_lag',
        error: e,
        stackTrace: st,
        context: {'uid': user.uid, 'step': 'getIdTokenResult'},
      );
    }
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
          // Les règles refusent un nom de plus de 60 caractères.
          updates['display_name'] = UserProfile.truncateName(
            firebaseUser.displayName!,
          );
        }
        transaction.update(userRef, updates);
        final data = userSnap.data()!
          ..addAll(updates)
          ..['uid'] = userSnap.id;
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
        // Sans nom Google, un nom vide : l'affichage se rabat sur l'adresse
        // pour le titulaire et sur « Membre » pour les autres, au lieu de
        // recopier un faux nom « Utilisateur » dans le profil public.
        displayName: UserProfile.truncateName(firebaseUser.displayName ?? ''),
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
    final trimmed = UserProfile.truncateName(name?.trim() ?? '').trim();
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
