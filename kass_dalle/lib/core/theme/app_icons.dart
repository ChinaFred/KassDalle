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
}
