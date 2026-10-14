import 'package:flutter/material.dart';

/// Icônes partagées : une action, une icône, partout.
///
/// L'export vers Google Calendar en avait trois — une flèche d'envoi sur la
/// liste et dans la barre, un calendrier dans les menus, un événement sur les
/// créneaux du nouveau planning. Le même geste doit se reconnaître d'un écran
/// à l'autre. L'icône reste distincte de celle de l'onglet « Calendrier »
/// (`calendar_month_outlined`), qui sert à voir, pas à envoyer.
abstract final class AppIcons {
  static const calendarExport = Icons.event_available_outlined;

  // ── Tickets ─────────────────────────────────────────────────────────────
  //
  // Le menu du compte, la liste « Mes tickets », la tuile d'Administration et
  // les puces de statut emploient les mêmes icônes : un type ou un statut se
  // reconnaît d'un écran à l'autre.

  /// « Signaler ou proposer » : ouvrir le formulaire d'un ticket.
  static const ticketNew = Icons.feedback_outlined;

  /// « Mes tickets » et « Tickets des membres ».
  static const tickets = Icons.confirmation_number_outlined;

  /// « Tickets à traiter » (menu du compte, administrateur) et l'état vide
  /// du filtre « À traiter ».
  static const ticketsToProcess = Icons.inbox_outlined;

  static const ticketTypeBug = Icons.bug_report_outlined;
  static const ticketTypeEvolution = Icons.trending_up;
  static const ticketTypeFeature = Icons.lightbulb_outline;
  static const ticketTypeQuestion = Icons.help_outline;

  static const ticketStatusSending = Icons.schedule_send_outlined;
  static const ticketStatusReceived = Icons.mark_email_read_outlined;
  static const ticketStatusAnalyzed = Icons.manage_search;
  static const ticketStatusValidated = Icons.thumb_up_alt_outlined;
  static const ticketStatusInProgress = Icons.construction_outlined;
  static const ticketStatusDelivered = Icons.check_circle_outline;
  static const ticketStatusRefused = Icons.block;
  static const ticketStatusAnswered = Icons.question_answer_outlined;

  /// Ticket que le serveur n'arrive plus à transmettre à GitHub.
  static const ticketAnomaly = Icons.error_outline;
}
