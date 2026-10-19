import 'dart:typed_data';

import '../../admin/domain/backfill_status.dart' show parisWallTime;
import 'ticket.dart';
import 'ticket_answer.dart' show ticketTextContainsEmail;

/// Règles du formulaire « Signaler ou proposer », sans Flutter ni Firebase.
///
/// Les bornes sont celles que `submitTicket` vérifie (`_inputBounds.ts`) : le
/// client les applique pour dire la faute sous le champ, le serveur reste
/// seul juge.

const kTicketTitleMinLength = 5;
const kTicketTitleMaxLength = 100;
const kTicketDescriptionMaxLength = 2000;

/// Taille maximale d'une capture, celle que `storage.rules` accepte.
const kTicketScreenshotMaxBytes = 5 * 1024 * 1024;

/// Faute d'un titre ou d'une description qui contient une adresse e-mail :
/// le ticket devient une Issue d'un dépôt public. `submitTicket` refuse aussi
/// (`details.reason` `contains_email`).
const kTicketFormEmailMessage =
    "Retirez l'adresse e-mail : le ticket est publié sur un site public.";

/// À partir de ce reste, le formulaire annonce les envois du jour.
const kTicketRemainingNoticeThreshold = 2;

/// Les fautes du formulaire, une par champ ; `null` quand le champ convient.
class TicketFormErrors {
  final String? type;
  final String? title;
  final String? description;

  const TicketFormErrors({this.type, this.title, this.description});

  bool get isValid => type == null && title == null && description == null;
}

/// Contrôle des champs, à l'appui sur « Envoyer ».
TicketFormErrors validateTicketForm({
  required TicketType? type,
  required String title,
  required String description,
}) {
  final t = title.trim();
  final d = description.trim();
  return TicketFormErrors(
    type: type == null ? 'Choisissez le type de ticket.' : null,
    title: t.length < kTicketTitleMinLength
        ? 'Le titre doit faire au moins $kTicketTitleMinLength caractères.'
        : t.length > kTicketTitleMaxLength
        ? 'Le titre ne doit pas dépasser $kTicketTitleMaxLength caractères.'
        : ticketTextContainsEmail(t)
        ? kTicketFormEmailMessage
        : null,
    description: d.isEmpty
        ? 'Décrivez votre demande.'
        : d.length > kTicketDescriptionMaxLength
        ? 'La description ne doit pas dépasser '
              '$kTicketDescriptionMaxLength caractères.'
        : ticketTextContainsEmail(d)
        ? kTicketFormEmailMessage
        : null,
  );
}

/// Une capture prête à partir : ses octets, son extension et son type MIME.
class TicketScreenshot {
  final Uint8List bytes;

  /// `png` ou `jpg`, l'extension du chemin Storage.
  final String extension;

  /// `image/png` ou `image/jpeg`.
  final String contentType;

  const TicketScreenshot({
    required this.bytes,
    required this.extension,
    required this.contentType,
  });
}

/// Une capture lue, ou la faute qui l'écarte.
typedef TicketScreenshotCheck = ({TicketScreenshot? screenshot, String? error});

/// Vérifie une image choisie : PNG ou JPEG (lu dans les premiers octets, pas
/// dans le nom du fichier), au plus [kTicketScreenshotMaxBytes].
TicketScreenshotCheck checkTicketScreenshot(Uint8List bytes) {
  final isPng =
      bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47;
  final isJpeg =
      bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF;
  if (!isPng && !isJpeg) {
    return (
      screenshot: null,
      error: 'Seules les images PNG ou JPEG sont acceptées.',
    );
  }
  if (bytes.length > kTicketScreenshotMaxBytes) {
    return (
      screenshot: null,
      error: 'Cette image dépasse 5 Mo. Choisissez une image plus légère.',
    );
  }
  return (
    screenshot: TicketScreenshot(
      bytes: bytes,
      extension: isPng ? 'png' : 'jpg',
      contentType: isPng ? 'image/png' : 'image/jpeg',
    ),
    error: null,
  );
}

/// Chemin Storage de la capture d'un ticket (contrat avec `storage.rules` et
/// `attachTicketScreenshot`).
String ticketScreenshotPath({
  required String uid,
  required String ticketId,
  required String extension,
}) => 'tickets/$uid/$ticketId/screenshot.$extension';

// ── Plafond du jour ─────────────────────────────────────────────────────────

/// Le jour calendaire de Paris de [instant], « 20261013 » : le jour du
/// plafond, celui du serveur.
String parisDayKey(DateTime instant) {
  final p = parisWallTime(instant);
  return '${p.year.toString().padLeft(4, '0')}'
      '${p.month.toString().padLeft(2, '0')}'
      '${p.day.toString().padLeft(2, '0')}';
}

/// Le reste annoncé par le dernier `submitTicket` (`remaining_today`), et le
/// jour de Paris où il a été rendu.
typedef TicketServerRemaining = ({String day, int remaining});

/// Les envois qui restent aujourd'hui au membre, ou `null` quand rien ne
/// permet de le dire.
///
/// Première source : le plafond `per_member_per_day` lu dans
/// `app_config/tickets`, moins les tickets du membre créés depuis minuit,
/// heure de Paris. Un ticket dont l'horodatage serveur n'est pas encore
/// revenu compte pour aujourd'hui. Seconde source, quand le plafond ne se lit
/// pas : `remaining_today` du dernier envoi, s'il date du même jour.
int? remainingTicketsToday({
  required int? perMemberPerDay,
  required Iterable<Ticket> myTickets,
  required DateTime now,
  TicketServerRemaining? lastServerRemaining,
}) {
  final today = parisDayKey(now);
  if (perMemberPerDay != null) {
    final sentToday = myTickets.where((t) {
      final created = t.createdAt;
      return created == null || parisDayKey(created) == today;
    }).length;
    final remaining = perMemberPerDay - sentToday;
    return remaining < 0 ? 0 : remaining;
  }
  if (lastServerRemaining != null && lastServerRemaining.day == today) {
    return lastServerRemaining.remaining < 0
        ? 0
        : lastServerRemaining.remaining;
  }
  return null;
}

/// Annonce du plafond atteint : plus aucun envoi possible aujourd'hui.
const kTicketLimitReachedNotice =
    'Vous avez atteint le nombre de tickets permis aujourd\'hui. '
    'Réessayez demain.';

/// « Il vous reste N envoi(s) aujourd'hui », quand il en reste
/// [kTicketRemainingNoticeThreshold] ou moins ; [kTicketLimitReachedNotice]
/// quand il n'en reste aucun ; `null` sinon.
String? remainingTicketsNotice(int? remaining) {
  if (remaining == null || remaining > kTicketRemainingNoticeThreshold) {
    return null;
  }
  if (remaining <= 0) return kTicketLimitReachedNotice;
  final plural = remaining > 1 ? 's' : '';
  return 'Il vous reste $remaining envoi$plural aujourd\'hui';
}

// ── Résultat et refus de `submitTicket` ─────────────────────────────────────

/// Ce que rend un envoi réussi.
class TicketSubmitResult {
  final String ticketId;

  /// `received` si l'Issue a été créée tout de suite, `sending` sinon.
  final TicketStatus status;

  /// `null` pour l'administrateur, qui n'a pas de plafond.
  final int? remainingToday;

  /// Vrai quand une capture devait partir et n'a pas pu être jointe. Le
  /// ticket, lui, est envoyé.
  final bool screenshotFailed;

  const TicketSubmitResult({
    required this.ticketId,
    required this.status,
    required this.remainingToday,
    this.screenshotFailed = false,
  });

  TicketSubmitResult withScreenshotFailed() => TicketSubmitResult(
    ticketId: ticketId,
    status: status,
    remainingToday: remainingToday,
    screenshotFailed: true,
  );

  /// Lit la sortie de `submitTicket`. Lève [FormatException] sans `ticketId`.
  factory TicketSubmitResult.fromMap(Map<String, dynamic> data) {
    final id = data['ticketId'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('submitTicket : ticketId absent');
    }
    final remaining = data['remaining_today'];
    return TicketSubmitResult(
      ticketId: id,
      status: TicketStatus.fromValue(data['status']) ?? TicketStatus.sending,
      remainingToday: remaining is num ? remaining.toInt() : null,
    );
  }
}

/// Un envoi refusé ou impossible, tel que l'écran le dit.
sealed class TicketSubmitError implements Exception {
  const TicketSubmitError();

  /// Le message de l'écran.
  String get message;
}

/// Plafond du membre atteint (`details.reason == "member_daily_limit"`).
class TicketMemberLimitReached extends TicketSubmitError {
  final int? limit;
  const TicketMemberLimitReached(this.limit);

  @override
  String get message => limit == null
      ? 'Vous avez atteint le nombre de tickets permis aujourd\'hui, '
            'réessayez demain.'
      : 'Vous avez envoyé $limit tickets aujourd\'hui, réessayez demain.';
}

/// Plafond de la famille atteint (`details.reason == "global_daily_limit"`).
class TicketGlobalLimitReached extends TicketSubmitError {
  const TicketGlobalLimitReached();

  @override
  String get message =>
      'Trop de tickets ont été envoyés aujourd\'hui par la famille. '
      'Réessayez demain.';
}

/// Le ticket n'a pas atteint le serveur.
class TicketNetworkError extends TicketSubmitError {
  const TicketNetworkError();

  @override
  String get message =>
      'Le ticket n\'est pas parti. Vérifiez la connexion, puis appuyez sur '
      'Envoyer.';
}

/// Tout autre refus du serveur : bornes, compte non approuvé ou révoqué,
/// panne. [detail] est le message du serveur, s'il en a un.
class TicketRefused extends TicketSubmitError {
  final String code;
  final String detail;
  const TicketRefused(this.code, this.detail);

  @override
  String get message => switch (code) {
    'permission-denied' =>
      'Votre compte ne permet pas d\'envoyer un ticket. Demandez à un '
          'administrateur de vérifier votre accès.',
    _ =>
      detail.isEmpty
          ? 'Le ticket n\'est pas parti. Réessayez dans un instant.'
          : 'Le ticket n\'est pas parti : $detail',
  };
}

/// Traduit l'erreur d'un appel `submitTicket` : [code] sous la forme du SDK
/// (`resource-exhausted`), [details] tel que rendu par le serveur.
TicketSubmitError ticketSubmitErrorFrom({
  required String code,
  required String message,
  required Object? details,
}) {
  final reason = details is Map ? details['reason'] : null;
  if (code == 'resource-exhausted') {
    if (reason == 'global_daily_limit') return const TicketGlobalLimitReached();
    final limit = details is Map ? details['limit'] : null;
    return TicketMemberLimitReached(limit is num ? limit.toInt() : null);
  }
  if (code == 'unavailable' || code == 'deadline-exceeded') {
    return const TicketNetworkError();
  }
  return TicketRefused(code, message.trim());
}
