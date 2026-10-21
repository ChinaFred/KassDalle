import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import '../../../core/services/google_access_token_cache.dart';

/// Service pour créer des événements dans Google Calendar via l'API REST.
///
/// Sur web : utilise [FirebaseAuth.signInWithPopup] avec le scope Calendar.
/// Sur mobile/desktop : utilise [GoogleSignIn.instance.requestScopes] puis
/// récupère l'access token OAuth de l'utilisateur connecté.
class CalendarService {
  static const _calendarScope =
      'https://www.googleapis.com/auth/calendar.events';

  /// Lecture de la seule liste des agendas (`CalendarList: list`), le seul
  /// appel de lecture du service. `calendar.readonly`, demandé jusque-là,
  /// ouvrait en plus la lecture des paramètres et des partages des agendas,
  /// dont l'application ne se sert pas. L'accès aux événements reste couvert
  /// par [_calendarScope] : l'application ne s'en sert que pour en créer.
  static const _calendarListScope =
      'https://www.googleapis.com/auth/calendar.calendarlist.readonly';

  // Cache du token pour éviter les popups OAuth répétées, lié au compte
  // Firebase qui l'a obtenu et vidé à la déconnexion
  // ([GoogleAccessTokenCache]). Invalidé 5 minutes avant expiration (tokens
  // Google ~1h). En mémoire seulement : un jeton obtenu par une version
  // précédente, avec d'autres portées, ne survit pas au redémarrage de
  // l'application ni au rechargement de la page qui installe la nouvelle
  // version.
  static final _tokenCache = GoogleAccessTokenCache();

  // ── Token ──────────────────────────────────────────────────────────────────

  /// Retourne un token OAuth avec les scopes Calendar events + liste des
  /// agendas.
  ///
  /// Le token est mis en cache pour toute la session (~55 min) afin d'éviter
  /// les popups OAuth répétées lors d'exports multiples.
  static Future<String> getToken() => _getCalendarToken();

  static Future<String> _getCalendarToken() async {
    // Réutiliser le token en cache s'il est encore valide, et du même compte.
    final cached = _tokenCache.read(FirebaseAuth.instance.currentUser?.uid);
    if (cached != null) return cached;

    String token;
    String? uid;
    if (kIsWeb) {
      // Sur web, Firebase gère l'OAuth — demander les deux scopes ensemble.
      final provider = GoogleAuthProvider()
        ..addScope(_calendarScope)
        ..addScope(_calendarListScope);
      final result = await FirebaseAuth.instance.signInWithPopup(provider);
      final t = (result.credential as OAuthCredential?)?.accessToken;
      if (t == null) throw Exception('Token Google non disponible');
      token = t;
      // La fenêtre peut connecter un autre compte Google que le précédent :
      // le jeton appartient au compte qu'elle rend.
      uid = result.user?.uid;
    } else {
      // Mobile / Desktop : demande les deux scopes via GoogleSignIn v7.
      // authorizationForScopes : silencieux (null si interaction requise).
      // authorizeScopes : interactif (affiche la demande de consentement).
      // L'uid est lu avant l'attente : si le compte change pendant la
      // demande, le jeton n'est pas gardé.
      final uidBefore = FirebaseAuth.instance.currentUser?.uid;
      final client = GoogleSignIn.instance.authorizationClient;
      final authz =
          await client.authorizationForScopes([
            _calendarScope,
            _calendarListScope,
          ]) ??
          await client.authorizeScopes([_calendarScope, _calendarListScope]);
      token = authz.accessToken;
      uid = FirebaseAuth.instance.currentUser?.uid == uidBefore
          ? uidBefore
          : null;
    }

    _tokenCache.store(uid, token);
    return token;
  }

  // ── Liste des calendriers ─────────────────────────────────────────────────

  /// Retourne la liste des calendriers du compte Google de l'utilisateur.
  ///
  /// Chaque entrée : `{'id': String, 'name': String, 'primary': bool}`.
  static Future<List<Map<String, dynamic>>> listCalendars() async {
    final token = await _getCalendarToken();
    final response = await http.get(
      Uri.parse('https://www.googleapis.com/calendar/v3/users/me/calendarList'),
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
        .map(
          (item) => {
            'id': item['id'] as String,
            'name': (item['summary'] as String?) ?? 'Sans nom',
            'primary': item['primary'] as bool? ?? false,
          },
        )
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
