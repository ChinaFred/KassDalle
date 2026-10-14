import 'package:cloud_firestore/cloud_firestore.dart';

/// Un ticket envoyé par un membre : bug, évolution, nouvelle fonctionnalité
/// ou question.
///
/// Document `tickets/{ticketId}`, écrit par les Cloud Functions seules
/// (`submitTicket`, webhook GitHub, tâche horaire). Le client n'y écrit qu'un
/// champ, `seen_by_author_at`, quand l'auteur ouvre le détail.
///
/// Les champs illisibles d'un document ancien ou mal formé prennent une valeur
/// neutre : une liste de tickets ne doit pas tomber pour un seul document.
class Ticket {
  final String id;
  final TicketType type;
  final String title;
  final String description;

  /// Modèle de route go_router (`/recipes/:recipeId`), `autre` ou `inconnu`.
  /// Jamais une adresse réelle.
  final String screen;

  final String appVersion;

  /// `android`, `ios`, `web` ou `windows`.
  final String platform;

  /// `tickets/{uid}/{ticketId}/screenshot.png` ou `.jpg`, ou `null`.
  final String? screenshotPath;

  final String authorUid;

  /// `null` tant que l'horodatage serveur n'est pas revenu.
  final DateTime? createdAt;
  final DateTime? updatedAt;

  final TicketStatus status;

  /// Statut tel qu'écrit dans le document. Diffère de [TicketStatus.value]
  /// quand le document porte une valeur que cette version ne connaît pas.
  final String rawStatus;

  final int? githubIssueNumber;
  final String? githubUrl;
  final int sendAttempts;
  final String? lastSendError;

  /// Réponse de l'administrateur (Question) ou motif (refus).
  final String? replyText;

  final DateTime? statusChangedAt;
  final DateTime? seenByAuthorAt;

  const Ticket({
    required this.id,
    required this.type,
    required this.title,
    required this.description,
    required this.screen,
    required this.appVersion,
    required this.platform,
    required this.screenshotPath,
    required this.authorUid,
    required this.createdAt,
    required this.updatedAt,
    required this.status,
    required this.rawStatus,
    required this.githubIssueNumber,
    required this.githubUrl,
    required this.sendAttempts,
    required this.lastSendError,
    required this.replyText,
    required this.statusChangedAt,
    required this.seenByAuthorAt,
  });

  factory Ticket.fromMap(String id, Map<String, dynamic> data) {
    String str(Object? v) => v is String ? v : '';
    String? optStr(Object? v) => v is String && v.isNotEmpty ? v : null;
    int? optInt(Object? v) => v is num ? v.toInt() : null;

    final rawStatus = str(data['status']);
    return Ticket(
      id: id,
      type: TicketType.fromValue(data['type']) ?? TicketType.bug,
      title: str(data['title']),
      description: str(data['description']),
      screen: str(data['screen']),
      appVersion: str(data['app_version']),
      platform: str(data['platform']),
      screenshotPath: optStr(data['screenshot_path']),
      authorUid: str(data['author_uid']),
      createdAt: parseTicketDate(data['created_at']),
      updatedAt: parseTicketDate(data['updated_at']),
      // Un statut inconnu de cette version s'affiche comme « Reçu » : le
      // ticket existe côté serveur, rien ne permet d'en dire plus.
      status: TicketStatus.fromValue(rawStatus) ?? TicketStatus.received,
      rawStatus: rawStatus,
      githubIssueNumber: optInt(data['github_issue_number']),
      githubUrl: optStr(data['github_url']),
      sendAttempts: optInt(data['send_attempts']) ?? 0,
      lastSendError: optStr(data['last_send_error']),
      replyText: optStr(data['reply_text']),
      statusChangedAt: parseTicketDate(data['status_changed_at']),
      seenByAuthorAt: parseTicketDate(data['seen_by_author_at']),
    );
  }

  /// Fin du parcours : Livré, Refusé ou Répondu.
  bool get isFinal => status.isFinal;

  /// Le ticket a atteint une fin que son auteur n'a pas encore vue : source
  /// du point de notification sur la puce du compte.
  ///
  /// Sans `status_changed_at`, une lecture déjà enregistrée suffit : rien ne
  /// dit que le statut a bougé depuis.
  bool get hasUnseenUpdate {
    if (!isFinal) return false;
    final seen = seenByAuthorAt;
    if (seen == null) return true;
    final changed = statusChangedAt;
    return changed != null && seen.isBefore(changed);
  }

  /// Envoi à GitHub abandonné par la tâche horaire : au-delà de
  /// [kTicketMaxSendAttempts] essais sans numéro d'Issue.
  bool get isInAnomaly =>
      githubIssueNumber == null && sendAttempts >= kTicketMaxSendAttempts;

  /// Ticket toujours en « Envoi en cours » plus d'une heure après sa création.
  bool isLate(DateTime now) {
    if (status != TicketStatus.sending) return false;
    final created = createdAt;
    if (created == null) return false;
    return now.difference(created) > const Duration(hours: 1);
  }
}

/// Au-delà de ce nombre d'essais sans Issue, la tâche horaire ne renvoie plus
/// le ticket : il passe « en anomalie » dans Admin › Tickets des membres.
/// Même valeur que le serveur (`ticketsSyncSchedule`).
const kTicketMaxSendAttempts = 10;

DateTime? parseTicketDate(Object? raw) {
  if (raw is Timestamp) return raw.toDate();
  if (raw is DateTime) return raw;
  return null;
}

/// Les quatre types de ticket. [value] est la valeur stockée et envoyée à
/// `submitTicket`.
enum TicketType {
  bug('bug', 'Bug'),
  evolution('evolution', 'Évolution'),
  feature('feature', 'Nouvelle fonctionnalité'),
  question('question', 'Question');

  const TicketType(this.value, this.label);

  final String value;
  final String label;

  static TicketType? fromValue(Object? value) {
    for (final t in values) {
      if (t.value == value) return t;
    }
    return null;
  }

  /// Gabarit affiché dans la description vide, propre au type.
  String get descriptionHint => switch (this) {
    TicketType.bug =>
      'Ce que vous faisiez : …\n'
          'Ce qui s\'est passé : …\n'
          'Ce que vous attendiez : …',
    TicketType.evolution =>
      'Ce qui existe aujourd\'hui : …\n'
          'Ce que vous aimeriez changer : …\n'
          'Pourquoi ce serait utile : …',
    TicketType.feature =>
      'Ce que vous aimeriez pouvoir faire : …\n'
          'Dans quelle situation (en cuisine, en préparant la semaine…) : …\n'
          'Comment vous faites aujourd\'hui : …',
    TicketType.question =>
      'Votre question : …\n'
          'Ce que vous avez déjà essayé : …',
  };
}

/// Les statuts d'un ticket, dans l'ordre du parcours. `refused` et `answered`
/// sont des fins alternatives.
enum TicketStatus {
  sending('sending', 'Envoi en cours'),
  received('received', 'Reçu'),
  analyzed('analyzed', 'Analysé'),
  validated('validated', 'Validé'),
  inProgress('in_progress', 'En cours'),
  delivered('delivered', 'Livré'),
  refused('refused', 'Refusé'),
  answered('answered', 'Répondu');

  const TicketStatus(this.value, this.label);

  final String value;
  final String label;

  static TicketStatus? fromValue(Object? value) {
    for (final s in values) {
      if (s.value == value) return s;
    }
    return null;
  }

  bool get isFinal =>
      this == TicketStatus.delivered ||
      this == TicketStatus.refused ||
      this == TicketStatus.answered;

  /// Phrase du détail, côté membre. `null` pour « Répondu » : le détail
  /// montre alors l'encadré « Réponse de l'administrateur ».
  String? get memberSentence => switch (this) {
    TicketStatus.sending =>
      'Votre ticket est enregistré. Il sera transmis dans quelques minutes.',
    TicketStatus.received => 'L\'administrateur a reçu votre ticket.',
    TicketStatus.analyzed => 'Votre ticket a été lu et étudié.',
    TicketStatus.validated => 'Votre demande sera traitée.',
    TicketStatus.inProgress => 'Le travail a commencé.',
    TicketStatus.delivered =>
      'C\'est fait. Mettez l\'application à jour pour en profiter.',
    TicketStatus.refused => 'Cette demande ne sera pas traitée.',
    TicketStatus.answered => null,
  };
}

/// Phrase ajoutée sous « Envoi en cours » quand l'envoi dépasse une heure.
const kTicketLateSentence =
    'La transmission prend du retard. L\'administrateur est prévenu.';

/// Les étapes de la frise du détail, de la première à la dernière.
///
/// Le parcours principal va de l'envoi à la livraison. Un refus ou une
/// réponse le quitte après la réception : le document ne garde pas
/// l'historique des étiquettes, et la frise ne montre pas d'étape que rien ne
/// prouve.
List<TicketStatus> ticketTimeline(TicketStatus status) {
  if (status == TicketStatus.refused || status == TicketStatus.answered) {
    return [TicketStatus.sending, TicketStatus.received, status];
  }
  return const [
    TicketStatus.sending,
    TicketStatus.received,
    TicketStatus.analyzed,
    TicketStatus.validated,
    TicketStatus.inProgress,
    TicketStatus.delivered,
  ];
}

/// Libellé d'une plateforme stockée.
String ticketPlatformLabel(String platform) => switch (platform) {
  'android' => 'Android',
  'ios' => 'iOS',
  'web' => 'Web',
  'windows' => 'Windows',
  _ => platform.isEmpty ? 'Plateforme inconnue' : platform,
};

String _two(int n) => n.toString().padLeft(2, '0');

/// « 13/10/26 », heure locale.
String formatTicketDate(DateTime date) {
  final d = date.toLocal();
  return '${_two(d.day)}/${_two(d.month)}/${_two(d.year % 100)}';
}

/// « 13/10/26 à 14:05 », heure locale.
String formatTicketDateTime(DateTime date) {
  final d = date.toLocal();
  return '${formatTicketDate(d)} à ${_two(d.hour)}:${_two(d.minute)}';
}

/// Filtre de statut de l'écran d'administration : `null` pour « Tous »,
/// [kAdminTicketTodoFilter] pour « À traiter », [kAdminTicketAnomalyFilter]
/// pour « En anomalie », sinon un statut.
const kAdminTicketAnomalyFilter = 'anomaly';

/// Filtre « À traiter » : tickets Reçus ou Analysés, qui attendent une
/// décision de l'administrateur. Même ensemble que le compteur de la pastille
/// ([kAdminTicketToProcessStatuses]).
const kAdminTicketTodoFilter = 'todo';

/// Statuts comptés « à traiter » : la requête du compteur et le filtre.
const kAdminTicketToProcessStatuses = [
  TicketStatus.received,
  TicketStatus.analyzed,
];

/// Vrai pour un ticket qui attend une décision : Reçu ou Analysé, statut
/// connu de cette version (un statut inconnu s'affiche « Reçu » sans l'être).
bool isTicketToProcess(Ticket t) =>
    t.rawStatus == t.status.value &&
    kAdminTicketToProcessStatuses.contains(t.status);

/// Applique les deux filtres de l'écran d'administration.
List<Ticket> filterAdminTickets(
  List<Ticket> tickets, {
  required String? status,
  required TicketType? type,
}) {
  return tickets.where((t) {
    if (type != null && t.type != type) return false;
    if (status == null) return true;
    if (status == kAdminTicketAnomalyFilter) return t.isInAnomaly;
    if (status == kAdminTicketTodoFilter) return isTicketToProcess(t);
    return t.status.value == status;
  }).toList();
}

/// Les décisions offertes à l'administrateur sur la fiche d'un ticket.
///
/// Le serveur refait le même contrôle (`validatePrecondition` et
/// `refusePrecondition`, `functions/src/tickets/rules.ts`) : un bouton
/// masqué ici n'est qu'un confort, jamais la protection. Logique dupliquée,
/// verrouillée par `test-fixtures/ticket_decisions.json`.
class AdminTicketDecisions {
  /// « Valider » : ticket Analysé, d'un autre type que Question, avec Issue.
  final bool canValidate;

  /// « Refuser » : ticket Reçu, Analysé, Validé ou En cours, avec Issue.
  final bool canRefuse;

  /// Ligne d'explication quand « Valider » est masqué pour une raison que
  /// l'administrateur doit connaître, ou `null`.
  final String? validateHint;

  const AdminTicketDecisions({
    required this.canValidate,
    required this.canRefuse,
    required this.validateHint,
  });

  bool get hasAction => canValidate || canRefuse;
}

const kTicketValidateAfterAnalysisHint =
    'Valider sera possible une fois le ticket analysé.';
const kTicketQuestionNoValidationHint =
    'Une question reçoit une réponse sur GitHub, pas une validation.';
const kTicketUnknownStatusHint =
    'Statut inconnu de cette version : mettez l\'application à jour pour '
    'décider.';

/// Les boutons de décision de [t]. Un statut inconnu de cette version (lu
/// « Reçu ») n'offre aucune décision.
AdminTicketDecisions adminTicketDecisions(Ticket t) {
  final known = t.rawStatus == t.status.value;
  final hasIssue = t.githubIssueNumber != null;
  final status = t.status;
  final canRefuse =
      known &&
      hasIssue &&
      (status == TicketStatus.received ||
          status == TicketStatus.analyzed ||
          status == TicketStatus.validated ||
          status == TicketStatus.inProgress);
  final canValidate =
      known &&
      hasIssue &&
      status == TicketStatus.analyzed &&
      t.type != TicketType.question;
  String? hint;
  if (!known && hasIssue) {
    hint = kTicketUnknownStatusHint;
  } else if (known && hasIssue) {
    final waiting =
        status == TicketStatus.received || status == TicketStatus.analyzed;
    if (t.type == TicketType.question && waiting) {
      hint = kTicketQuestionNoValidationHint;
    } else if (status == TicketStatus.received) {
      hint = kTicketValidateAfterAnalysisHint;
    }
  }
  return AdminTicketDecisions(
    canValidate: canValidate,
    canRefuse: canRefuse,
    validateHint: hint,
  );
}

/// Refus attendu de `validateTicket` ou `refuseTicket` : le message du
/// serveur s'affiche tel quel.
class TicketDecisionError implements Exception {
  final String message;

  /// Échec partiel d'un refus : le motif est publié sur GitHub, l'Issue n'est
  /// pas fermée. Le motif ne doit plus changer avant de réessayer.
  final bool partial;

  const TicketDecisionError(this.message, {this.partial = false});

  @override
  String toString() => message;
}

/// Raison serveur d'un échec partiel de refus (`REFUSAL_PARTIAL_REASON`),
/// verrouillée par `test-fixtures/ticket_decisions.json`.
const kTicketRefusalPartialReason = 'reply_published_close_failed';

/// L'erreur à montrer pour un refus de callable, ou `null` quand la réponse
/// ne vient pas des contrôles du serveur (pas de `details.reason` ni de
/// `details.field`) : l'écran affiche alors son message générique.
TicketDecisionError? ticketDecisionErrorFrom({
  required String message,
  required Object? details,
}) {
  if (details is! Map) return null;
  final reason = details['reason'];
  final field = details['field'];
  if (reason is! String && field is! String) return null;
  final text = message.trim();
  if (text.isEmpty) return null;
  return TicketDecisionError(
    text,
    partial: reason == kTicketRefusalPartialReason,
  );
}
