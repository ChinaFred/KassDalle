import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

/// Envoi de la liste de courses vers **Google Tasks**, via l'API REST.
///
/// ── Pourquoi Tasks, et pas Keep ──────────────────────────────────────────────
///
/// L'envoi vers Keep se fait par le presse-papier : on copie du texte, et c'est
/// vous qui créez la note, la convertissez en cases à cocher et reconstruisez
/// les rayons. Ce n'est pas un défaut de notre code — **Keep n'a aucune API
/// publique d'écriture**, et coller du texte dans une note ne produit jamais
/// une liste cochable. La conversion manuelle est le seul chemin, et elle perd
/// la hiérarchie au passage : Keep fait une ligne par item, en-têtes de rayon
/// compris.
///
/// Tasks, lui, sait recevoir exactement ce qu'on veut lui donner : des tâches
/// **cochables**, et des **sous-tâches**. Un rayon devient une tâche parente,
/// chaque ingrédient une sous-tâche. Rien à convertir, rien à retaper.
///
/// Même mécanique d'autorisation que [CalendarService] — jeton OAuth par scope,
/// mis en cache pour éviter une fenêtre de consentement par appel.
class GoogleTasksService {
  static const _tasksScope = 'https://www.googleapis.com/auth/tasks';
  static const _base = 'https://tasks.googleapis.com/tasks/v1';

  static String? _cachedToken;
  static DateTime? _tokenExpiry;

  /// Jeton OAuth portant le scope Tasks.
  ///
  /// Mis en cache une cinquantaine de minutes : sans cela, une liste de trente
  /// articles ouvrirait trente demandes de consentement.
  static Future<String> _getToken() async {
    if (_cachedToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(
          _tokenExpiry!.subtract(const Duration(minutes: 5)),
        )) {
      return _cachedToken!;
    }

    String token;
    if (kIsWeb) {
      final provider = GoogleAuthProvider()..addScope(_tasksScope);
      final result = await FirebaseAuth.instance.signInWithPopup(provider);
      final t = (result.credential as OAuthCredential?)?.accessToken;
      if (t == null) throw Exception('Token Google non disponible');
      token = t;
    } else {
      final client = GoogleSignIn.instance.authorizationClient;
      final authz =
          await client.authorizationForScopes([_tasksScope]) ??
          await client.authorizeScopes([_tasksScope]);
      token = authz.accessToken;
    }

    _cachedToken = token;
    _tokenExpiry = DateTime.now().add(const Duration(minutes: 55));
    return token;
  }

  static Map<String, String> _headers(String token) => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json; charset=UTF-8',
  };

  /// Lit un message d'erreur exploitable, ou lève avec le code brut.
  ///
  /// L'API répond par un objet `error` détaillé : le donner tel quel évite
  /// l'écran « échec » qui n'apprend rien — un scope refusé et une API non
  /// activée ne se corrigent pas au même endroit.
  static Never _fail(String what, http.Response response) {
    String detail = '${response.statusCode}';
    try {
      final decoded =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final message = (decoded['error'] as Map?)?['message'];
      if (message is String && message.isNotEmpty) detail = message;
    } catch (_) {
      // Corps illisible : le code de statut reste la meilleure information.
    }
    throw Exception('$what : $detail');
  }

  /// Un rayon et ses articles, dans l'ordre d'affichage de la liste.
  static Future<int> createShoppingList({
    required String title,
    required List<({String category, List<String> items})> groups,
  }) async {
    final token = await _getToken();

    final listResponse = await http.post(
      Uri.parse('$_base/users/@me/lists'),
      headers: _headers(token),
      body: jsonEncode({'title': title}),
    );
    if (listResponse.statusCode != 200) {
      _fail('Création de la liste impossible', listResponse);
    }
    final listId =
        (jsonDecode(utf8.decode(listResponse.bodyBytes))
                as Map<String, dynamic>)['id']
            as String;

    var created = 0;
    String? previousParent;

    for (final group in groups) {
      if (group.items.isEmpty) continue;

      // `previous` conserve l'ordre : sans lui, chaque insertion se place en
      // tête et la liste ressort à l'envers — les rayons dans le désordre du
      // magasin, ce qui est précisément ce qu'on cherche à éviter.
      final parentId = await _insert(
        token: token,
        listId: listId,
        title: group.category,
        previous: previousParent,
      );
      previousParent = parentId;

      String? previousChild;
      for (final item in group.items) {
        previousChild = await _insert(
          token: token,
          listId: listId,
          title: item,
          parent: parentId,
          previous: previousChild,
        );
        created++;
      }
    }

    return created;
  }

  static Future<String> _insert({
    required String token,
    required String listId,
    required String title,
    String? parent,
    String? previous,
  }) async {
    final uri = Uri.parse(
      '$_base/lists/$listId/tasks',
    ).replace(queryParameters: {'parent': ?parent, 'previous': ?previous});
    final response = await http.post(
      uri,
      headers: _headers(token),
      body: jsonEncode({'title': title}),
    );
    if (response.statusCode != 200) {
      _fail('Ajout de « $title » impossible', response);
    }
    return (jsonDecode(utf8.decode(response.bodyBytes))
            as Map<String, dynamic>)['id']
        as String;
  }
}
