import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/services/error_report_service.dart';
import '../../auth/domain/user_profile.dart';
import '../domain/family_group.dart';
import '../domain/member_email_search.dart';

class GroupRepository {
  final FirebaseFirestore _firestore;
  final FirebaseFunctions? _functionsOverride;
  final ErrorReportService _errorReportService;

  GroupRepository({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _functionsOverride = functions,
       // Le rapport d'erreur suit le Firestore du repository : en test, il
       // écrit dans le Firestore de test au lieu d'exiger l'App réelle.
       _errorReportService =
           errorReportService ?? ErrorReportService(firestore: firestore);

  /// Résolu au premier appel : les tests qui n'appellent aucune fonction
  /// construisent le repository sans application Firebase.
  FirebaseFunctions get _functions =>
      _functionsOverride ??
      FirebaseFunctions.instanceFor(region: 'europe-west1');

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('groups');

  // ── Lecture ─────────────────────────────────────────────────────────────────

  /// Groupes dont [uid] est membre, groupes en pause compris.
  ///
  /// Un groupe dont le propriétaire n'est plus éditeur est « en pause » : le
  /// serveur le pose dans `planning_reach/{uid}.masked_group_ids` (voir
  /// [watchMaskedGroupIds]). L'écran Groupes le liste toujours, marqué « En
  /// pause », pour que son propriétaire en retire des membres ou le supprime,
  /// et qu'un membre le quitte ; seul le planning le masque.
  Stream<List<FamilyGroup>> watchMyGroups(String uid) {
    return _col.where('member_ids', arrayContains: uid).snapshots().map((snap) {
      final list = snap.docs
          .map((d) => FamilyGroup.fromFirestore(d.id, d.data()))
          .toList();
      list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return list;
    });
  }

  /// Les groupes de [uid] en pause : `planning_reach/{uid}.masked_group_ids`.
  /// Document ou champ absent (portée antérieure au planning de groupe) :
  /// aucun. Une lecture en échec est signalée au rapport, puis transmise.
  Stream<Set<String>> watchMaskedGroupIds(String uid) =>
      _watchReachField(uid, 'masked_group_ids');

  /// Groupes qui invitent [uid] et attendent sa réponse, hors ceux en pause.
  ///
  /// Une invitation vers un groupe dont le propriétaire n'est plus éditeur
  /// est masquée à l'invité : le serveur la pose dans
  /// `planning_reach/{uid}.masked_invitation_ids`. Les deux lectures sont
  /// réunies : la liste n'est rendue qu'une fois les deux connues, pour
  /// qu'une invitation masquée n'apparaisse pas un instant. Une portée
  /// illisible ne masque rien : mieux vaut une invitation de trop qu'aucune.
  Stream<List<FamilyGroup>> watchMyInvitations(String uid) {
    final invitations = _col
        .where('invited_ids', arrayContains: uid)
        .snapshots()
        .map((snap) {
          final list = snap.docs
              .map((d) => FamilyGroup.fromFirestore(d.id, d.data()))
              .toList();
          list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          return list;
        });
    late final StreamController<List<FamilyGroup>> controller;
    StreamSubscription<List<FamilyGroup>>? invitationsSub;
    StreamSubscription<Set<String>>? maskedSub;
    List<FamilyGroup>? lastInvitations;
    Set<String>? lastMasked;
    void emit() {
      final g = lastInvitations, m = lastMasked;
      if (g == null || m == null) return;
      controller.add([
        for (final group in g)
          if (!m.contains(group.id)) group,
      ]);
    }

    controller = StreamController<List<FamilyGroup>>(
      onListen: () {
        invitationsSub = invitations.listen((g) {
          lastInvitations = g;
          emit();
        }, onError: controller.addError);
        maskedSub = _watchReachField(uid, 'masked_invitation_ids').listen(
          (m) {
            lastMasked = m;
            emit();
          },
          onError: (Object e, StackTrace st) {
            // Déjà signalée par `_watchReachField`.
            lastMasked = const {};
            emit();
          },
        );
      },
      onCancel: () async {
        await invitationsSub?.cancel();
        await maskedSub?.cancel();
      },
    );
    return controller.stream;
  }

  /// Une liste d'identifiants de `planning_reach/{uid}`. Une lecture en échec
  /// est signalée au rapport, puis transmise.
  Stream<Set<String>> _watchReachField(String uid, String field) {
    return _firestore
        .collection('planning_reach')
        .doc(uid)
        .snapshots()
        .map((doc) {
          final raw = doc.data()?[field];
          if (raw is! List) return <String>{};
          return raw.whereType<String>().toSet();
        })
        .handleError((Object e, StackTrace st) {
          unawaited(
            _errorReportService.reportError(
              feature: 'group_reach_field',
              error: e,
              stackTrace: st,
              context: {'uid': uid, 'field': field},
            ),
          );
          Error.throwWithStackTrace(e, st);
        });
  }

  /// Les autres comptes avec qui [uid] partage un groupe : `group_reach/{uid}`.
  ///
  /// C'est la liste que les règles Firestore relisent pour laisser lire un
  /// livre ou une recette partagé d'un autre compte. Le serveur la tient à
  /// jour à chaque écriture d'un groupe (`syncGroupReach`). Les requêtes du
  /// client partent de cette liste plutôt que des groupes eux-mêmes : juste
  /// après l'ajout d'un membre, les groupes le connaissent déjà et la portée
  /// pas encore, et une requête qui le nommerait serait refusée en entier.
  ///
  /// Document absent (aucun groupe, ou portée pas encore calculée) : vide.
  Stream<Set<String>> watchReach(String uid) {
    return _firestore.collection('group_reach').doc(uid).snapshots().map((doc) {
      final raw = doc.data()?['uids'];
      if (raw is! List) return <String>{};
      return raw.whereType<String>().where((id) => id != uid).toSet();
    });
  }

  // ── Écriture ─────────────────────────────────────────────────────────────────

  // Chaque écriture signale son échec puis le relance : l'écran a besoin de
  // l'erreur pour la dire à l'utilisateur, et le rapport garde la trace. Une
  // écriture de groupe qui échoue sans bruit laisse la liste inchangée, sans
  // rien pour distinguer le refus de la lenteur.

  /// Crée un nouveau groupe avec [ownerUid] comme seul membre.
  Future<String> createGroup(String name, String ownerUid) async {
    try {
      final ref = await _col.add({
        'name': name.trim(),
        'owner_id': ownerUid,
        'member_ids': [ownerUid],
        'created_at': Timestamp.fromDate(DateTime.now()),
      });
      return ref.id;
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'group_create',
        error: e,
        stackTrace: st,
        context: {'owner_id': ownerUid},
      );
      rethrow;
    }
  }

  /// Invite [uid] dans le groupe. Il n'en devient membre qu'en acceptant
  /// ([acceptInvitation]) : être membre ouvre la lecture de ses livres aux
  /// autres membres, et des leurs à lui. Les règles Firestore refusent qu'un
  /// propriétaire écrive directement `member_ids` pour y ajouter quelqu'un.
  Future<void> inviteMember(String groupId, String uid) => _write(
    'group_invite_member',
    {'group_id': groupId, 'member_uid': uid},
    () => _col.doc(groupId).update({
      'invited_ids': FieldValue.arrayUnion([uid]),
    }),
  );

  /// Retire l'invitation de [uid], qu'elle soit annulée par le propriétaire
  /// ou refusée par l'invité : l'écriture est la même.
  Future<void> withdrawInvitation(String groupId, String uid) => _write(
    'group_withdraw_invitation',
    {'group_id': groupId, 'member_uid': uid},
    () => _col.doc(groupId).update({
      'invited_ids': FieldValue.arrayRemove([uid]),
    }),
  );

  /// [uid] accepte l'invitation : il quitte les invités et entre dans les
  /// membres, en une seule écriture — la forme exacte qu'admet la règle.
  Future<void> acceptInvitation(String groupId, String uid) => _write(
    'group_accept_invitation',
    {'group_id': groupId, 'member_uid': uid},
    () => _col.doc(groupId).update({
      'member_ids': FieldValue.arrayUnion([uid]),
      'invited_ids': FieldValue.arrayRemove([uid]),
    }),
  );

  Future<void> _write(
    String feature,
    Map<String, Object?> context,
    Future<void> Function() write,
  ) async {
    try {
      await write();
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: feature,
        error: e,
        stackTrace: st,
        context: context,
      );
      rethrow;
    }
  }

  /// Retire [uid] du groupe.
  Future<void> removeMember(String groupId, String uid) async {
    try {
      await _col.doc(groupId).update({
        'member_ids': FieldValue.arrayRemove([uid]),
      });
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'group_remove_member',
        error: e,
        stackTrace: st,
        context: {'group_id': groupId, 'member_uid': uid},
      );
      rethrow;
    }
  }

  /// Renomme le groupe.
  Future<void> renameGroup(String groupId, String newName) async {
    try {
      await _col.doc(groupId).update({'name': newName.trim()});
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'group_rename',
        error: e,
        stackTrace: st,
        context: {'group_id': groupId},
      );
      rethrow;
    }
  }

  /// Supprime le groupe.
  Future<void> deleteGroup(String groupId) async {
    try {
      await _col.doc(groupId).delete();
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'group_delete',
        error: e,
        stackTrace: st,
        context: {'group_id': groupId},
      );
      rethrow;
    }
  }

  // ── Recherche d'utilisateurs ─────────────────────────────────────────────────

  /// Recherche des membres à inviter, par nom (filtrage côté client).
  ///
  /// Lit les profils publics (`user_profiles`), pas `users` : le document d'un
  /// compte, adresse comprise, ne se lit plus que par son titulaire et par un
  /// administrateur (v0.23.14). La recherche par adresse passe par le
  /// serveur ([findMemberByEmail]). Un compte en attente n'a pas de profil, et
  /// n'apparaît donc pas.
  /// Plafonné à 200 profils : une famille en compte quelques dizaines.
  Future<List<UserProfile>> searchUsers(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    try {
      final snap = await _firestore
          .collection('user_profiles')
          .limit(200)
          .get();
      return snap.docs
          .map((d) => UserProfile.fromFirestore(d.id, d.data()))
          .where(
            (p) =>
                p.displayName.toLowerCase().contains(q) ||
                p.displayedName.toLowerCase().contains(q),
          )
          .toList();
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'group_search_users',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  /// Le compte dont l'adresse est exactement [email], pour l'inviter dans
  /// [groupId] ; `null` si aucun compte approuvé ne la porte.
  ///
  /// Passe par `findMemberByEmailFn` : le serveur vérifie que l'appelant est
  /// éditeur ou administrateur et propriétaire du groupe, compte la recherche (dix par jour) et ne rend
  /// que l'identifiant et les noms publics. Plafond atteint :
  /// [MemberSearchLimitReached] ; groupe supprimé ou appelant qui n'en est
  /// plus propriétaire : [MemberSearchRefused], avec le message du serveur.
  /// Toute erreur est signalée sans l'adresse.
  Future<UserProfile?> findMemberByEmail(String groupId, String email) async {
    try {
      final raw = await _functions
          .httpsCallable('findMemberByEmailFn')
          .call<Map<String, dynamic>>({
            'groupId': groupId,
            'email': email.trim(),
          });
      return memberFromSearchResponse(Map<String, dynamic>.from(raw.data));
    } on FirebaseFunctionsException catch (e, st) {
      final limit = e.code == 'resource-exhausted';
      await _errorReportService.reportError(
        feature: 'group_search_email',
        error: e,
        stackTrace: st,
        context: {
          'group_id': groupId,
          'outcome': limit ? 'daily_limit' : e.code,
        },
      );
      if (limit) throw const MemberSearchLimitReached();
      final refusal = memberSearchRefusalMessage(e.code, e.message);
      if (refusal != null) throw MemberSearchRefused(refusal);
      rethrow;
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'group_search_email',
        error: e,
        stackTrace: st,
        context: {'group_id': groupId},
      );
      rethrow;
    }
  }
}
