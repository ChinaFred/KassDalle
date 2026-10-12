import '../../admin/domain/email_invitation.dart' show looksLikeEmail;
import '../../auth/domain/user_profile.dart';

// Recherche d'un membre à inviter par son adresse exacte.
//
// Les adresses ne se lisent pas depuis le client (`users/{uid}` est réservé à
// son titulaire et à l'administrateur) : la recherche passe par la callable
// `findMemberByEmailFn`, réservée au propriétaire du groupe et plafonnée à
// trente recherches par jour. Elle ne rend que l'identifiant et les noms
// publics du compte trouvé, jamais l'adresse.

/// Vrai si la saisie est en train de devenir une adresse : la recherche par
/// nom s'arrête dès le `@`, un nom n'en contient pas.
bool isEmailLikeQuery(String query) => query.contains('@');

/// Vrai si la saisie a la forme d'une adresse complète : la recherche par
/// adresse peut partir. Même contrôle que l'invitation par e-mail.
bool isCompleteEmailQuery(String query) =>
    isEmailLikeQuery(query) && looksLikeEmail(query);

/// Le plafond quotidien est atteint : le serveur refuse jusqu'au lendemain.
class MemberSearchLimitReached implements Exception {
  const MemberSearchLimitReached();

  static const message = 'Trop de recherches aujourd\'hui. Réessayez demain.';

  @override
  String toString() => message;
}

/// Le compte rendu par `findMemberByEmailFn`, ou `null` si aucun compte
/// approuvé ne porte cette adresse.
///
/// Une réponse mal formée (pas d'`uid`) se lit comme « aucun compte » : on
/// ne propose pas d'inviter un identifiant illisible.
UserProfile? memberFromSearchResponse(Map<String, dynamic> data) {
  if (data['found'] != true) return null;
  final uid = data['uid'];
  if (uid is! String || uid.trim().isEmpty) return null;
  final name = data['displayName'];
  final preferred = data['preferredName'];
  return UserProfile(
    uid: uid,
    displayName: name is String ? name : '',
    preferredName: preferred is String ? preferred : null,
  );
}
