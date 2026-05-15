import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

/// Service pour créer des événements dans Google Calendar via l'API REST.
///
/// Sur web : utilise [FirebaseAuth.signInWithPopup] avec le scope Calendar.
/// Sur mobile/desktop : utilise [GoogleSignIn.instance.requestScopes] puis
/// récupère l'access token OAuth de l'utilisateur connecté.
class CalendarService {
  static const _calendarScope =
      'https://www.googleapis.com/auth/calendar.events';

  // ── Token ──────────────────────────────────────────────────────────────────

  /// Retourne un token OAuth avec le scope Calendar.
  ///
  /// Expose publiquement pour permettre d'obtenir le token une seule fois
  /// avant une boucle de création d'événements multiples.
  static Future<String> getToken() => _getCalendarToken();

  static Future<String> _getCalendarToken() async {
    if (kIsWeb) {
      // Sur web, Firebase gère l'OAuth — on redemande avec le scope Calendar.
      final provider = GoogleAuthProvider()..addScope(_calendarScope);
      final result = await FirebaseAuth.instance.signInWithPopup(provider);
      final token = (result.credential as OAuthCredential?)?.accessToken;
      if (token == null) throw Exception('Token Google non disponible');
      return token;
    } else {
      // Mobile / Desktop : demande le scope Calendar via GoogleSignIn v7.
      // authorizationForScopes : silencieux (null si interaction requise).
      // authorizeScopes : interactif (affiche la demande de consentement).
      final client = GoogleSignIn.instance.authorizationClient;
      final authz = await client.authorizationForScopes([_calendarScope]) ??
          await client.authorizeScopes([_calendarScope]);
      return authz.accessToken;
    }
  }

  // ── Liste des calendriers ─────────────────────────────────────────────────

  /// Retourne la liste des calendriers du compte Google de l'utilisateur.
  ///
  /// Chaque entrée : `{'id': String, 'name': String, 'primary': bool}`.
  static Future<List<Map<String, dynamic>>> listCalendars() async {
    final token = await _getCalendarToken();
    final response = await http.get(
      Uri.parse(
          'https://www.googleapis.com/calendar/v3/users/me/calendarList'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      final decoded =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final message =
          (decoded['error'] as Map?)?['message'] ?? response.statusCode;
      throw Exception('Erreur liste calendriers : $message');
    }
    final data =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final items = (data['items'] as List).cast<Map<String, dynamic>>();
    return items
        .map((item) => {
              'id': item['id'] as String,
              'name': (item['summary'] as String?) ?? 'Sans nom',
              'primary': item['primary'] as bool? ?? false,
            })
        .toList();
  }

  // ── Création d'événement ───────────────────────────────────────────────────

  /// Crée un événement "Préparer : [titre]" dans le calendrier cible.
  ///
  /// [calendarId] : identifiant du calendrier cible (défaut "primary").
  /// [token] : token OAuth pré-obtenu (si null, un nouveau token est obtenu).
  ///   Passer un token pré-obtenu lors de créations multiples pour éviter
  ///   d'ouvrir plusieurs popups OAuth.
  static Future<void> createEvent({
    required String titre,
    required DateTime startTime,
    required Duration duration,
    required String description,
    required int reminderMinutes,
    String calendarId = 'primary',
    String? token,
  }) async {
    final t = token ?? await _getCalendarToken();
    final endTime = startTime.add(duration);
    final endpoint =
        'https://www.googleapis.com/calendar/v3/calendars/${Uri.encodeComponent(calendarId)}/events';

    final body = {
      'summary': 'Préparer : $titre',
      'description': description,
      'start': {
        'dateTime': startTime.toUtc().toIso8601String(),
        'timeZone': 'Europe/Paris',
      },
      'end': {
        'dateTime': endTime.toUtc().toIso8601String(),
        'timeZone': 'Europe/Paris',
      },
      'reminders': {
        'useDefault': false,
        'overrides': [
          if (reminderMinutes > 0)
            {'method': 'popup', 'minutes': reminderMinutes},
        ],
      },
    };

    final response = await http.post(
      Uri.parse(endpoint),
      headers: {
        'Authorization': 'Bearer $t',
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: jsonEncode(body),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      final decoded =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final message =
          (decoded['error'] as Map?)?['message'] ?? response.statusCode;
      throw Exception('Erreur Google Calendar : $message');
    }
  }
}
