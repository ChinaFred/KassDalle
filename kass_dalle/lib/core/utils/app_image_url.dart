import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../firebase_options.dart';

/// Les images que l'application accepte d'afficher.
///
/// Décision de l'utilisateur (v0.23.13) : l'application n'affiche que ses
/// propres images. Une URL d'image vient souvent d'une donnée qu'un membre a
/// pu écrire — `image_urls`, `thumbnail_urls`, `url_couverture`, une image
/// citée dans le CookLang, un visuel de dressage. Charger une URL d'un autre
/// hôte révélait à ce serveur l'adresse IP et l'heure de lecture de chaque
/// lecteur, et affichait un contenu que la modération n'a jamais vu.
///
/// Sont acceptées les seules URL du bucket Storage du projet (et de son ancien
/// bucket par défaut, `kassdale-6d948.appspot.com`) :
///
/// - `https://firebasestorage.googleapis.com/v0/b/<bucket>/o/<chemin>` — ce
///   que rendent `getDownloadURL`, côté client comme côté Functions ;
/// - `https://storage.googleapis.com/<bucket>/<chemin>` — l'URL publique d'un
///   objet ;
/// - l'émulateur Storage (`localhost`, `127.0.0.1`, `10.0.2.2`, chemin
///   `/v0/b/<bucket>/o/…`), en mode debug seulement.
///
/// Le bucket ne suffit pas (ticket #154). Un membre téléverse sous
/// `quarantine/{uid}/…` ou `tickets/{uid}/…`, dossiers qu'il lit et que la
/// modération n'a pas encore vus ; la réponse de l'envoi lui donne une URL de
/// téléchargement à jeton, qui passe outre les règles Storage. Écrite dans
/// `image_urls`, elle montrait l'image à toute la famille sans modération.
/// Le chemin de l'objet est donc décodé — le segment encodé après `/o/`, ou
/// les segments qui suivent le bucket — et doit commencer par l'un des
/// dossiers publiés de [kPublishedImagePrefixes], que seul le serveur écrit.
/// Un chemin vide, un segment vide, `.` ou `..`, une barre oblique inverse,
/// un caractère de contrôle ou un encodage illisible sont refusés, comme côté
/// serveur (`isWellFormedObjectPath`, `functions/src/utils/storagePath.ts`).
///
/// Aucun écran n'affiche par URL une image non modérée : la modération
/// (`admin_moderation_screen.dart`) et la capture d'un ticket
/// (`TicketRepository`) lisent `quarantine/`, `rejected/` et `tickets/` par
/// leur chemin, avec les droits de celui qui consulte (`getData`).
///
/// Les assets embarqués (`assets/…`) ne sont pas des URL : ils s'affichent par
/// `Image.asset` et ne passent pas par ce filtre.
///
/// La photo de profil Google (`photo_url`, `googleusercontent.com`) n'y passe
/// pas non plus : elle reste affichée telle quelle (décision de l'utilisateur).
///
/// Pur et testé (`test/app_image_url_test.dart`).
bool isAppImageUrl(
  String? url, {
  Set<String>? buckets,
  bool allowEmulator = kDebugMode,
}) {
  if (url == null) return false;
  final trimmed = url.trim();
  if (trimmed.isEmpty) return false;
  final accepted = buckets ?? kAppStorageBuckets;
  if (accepted.isEmpty) return false;

  // Une URL illisible est un refus : rien n'est chargé et l'appelant affiche
  // son image de repli.
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return false;
  if (!uri.hasScheme || uri.host.isEmpty) return false;
  // Une URL avec identifiants (`https://x@hôte/…`) n'est pas une URL de
  // téléchargement Storage.
  if (uri.userInfo.isNotEmpty) return false;

  // Segments encodés, décodés un à un : `uri.pathSegments` lève une
  // exception sur un encodage UTF-8 invalide.
  final raw = uri.path.split('/');
  if (raw.isEmpty || raw.first.isNotEmpty) return false;
  final segments = raw.skip(1).toList();
  final host = uri.host.toLowerCase();

  final String? objectPath;
  if (uri.scheme == 'https' && host == _downloadHost && !uri.hasPort) {
    objectPath = _downloadObjectPath(segments, accepted);
  } else if (uri.scheme == 'https' && host == _publicHost && !uri.hasPort) {
    objectPath = _publicObjectPath(segments, accepted);
  } else if (allowEmulator &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      _emulatorHosts.contains(host)) {
    objectPath = _downloadObjectPath(segments, accepted);
  } else {
    objectPath = null;
  }
  return objectPath != null && isPublishedImagePath(objectPath);
}

/// Les dossiers Storage dont une image s'affiche : écrits par le serveur
/// seul (`storage.rules`, `allow write: if false`), après la modération pour
/// ce qu'un membre envoie (`moderateAndPromote`) ou au départ d'un scan
/// contrôlé (`scanAndPromoteUploadFn`, découpes et images générées).
///
/// - `covers/` — couvertures de livres ;
/// - `scans/` — pages et fichiers promus d'un import ;
/// - `illustrations/` — découpes, images générées, illustrations modérées ;
/// - `recipes/` — illustrations modérées d'une recette ;
/// - `users/` — couverture « Recette libre » d'un compte.
///
/// Exclus : `quarantine/` (envoi non encore modéré), `rejected/` (refusé),
/// `tickets/` (capture privée d'un ticket).
const kPublishedImagePrefixes = <String>[
  'covers/',
  'scans/',
  'illustrations/',
  'recipes/',
  'users/',
];

/// Vrai quand [path] (chemin d'objet décodé) est bien formé et commence par
/// un dossier de [kPublishedImagePrefixes], avec au moins un nom après lui.
bool isPublishedImagePath(String path) {
  if (!_isWellFormedObjectPath(path)) return false;
  return kPublishedImagePrefixes.any(
    (prefix) => path.startsWith(prefix) && path.length > prefix.length,
  );
}

/// Une image refusée par [isAppImageUrl] : elle n'est ni affichée, ni
/// téléchargée.
///
/// Passée à `errorWidget` par `AppNetworkImage` à la place d'une erreur de
/// chargement, pour que chaque écran affiche son image de repli. Levée par
/// [requireAppImageUrl] avant un téléchargement : rien ne part sur le réseau.
class ForeignImageUrl implements Exception {
  const ForeignImageUrl(this.url);

  final String url;

  /// Le message à montrer à l'utilisateur.
  String get message =>
      'Cette image ne vient pas de Kass\'Dalle : elle n\'est pas téléchargée.';

  @override
  String toString() => 'Image hors du stockage de l\'application : $url';
}

/// Lève [ForeignImageUrl] si [url] n'est pas une image de l'application.
///
/// À appeler avant tout téléchargement d'une image par le client
/// (`refFromURL(...).getData`, `http.get`).
void requireAppImageUrl(String url) {
  if (!isAppImageUrl(url)) throw ForeignImageUrl(url);
}

/// Le bucket Storage du projet, le même sur toutes les plateformes.
final String kAppStorageBucket = DefaultFirebaseOptions.web.storageBucket ?? '';

/// L'ancien bucket par défaut du même projet. Des documents anciens peuvent
/// encore y pointer : ses images restent les nôtres.
const kLegacyAppStorageBucket = 'kassdale-6d948.appspot.com';

/// Les buckets dont les images s'affichent.
final Set<String> kAppStorageBuckets = {
  if (kAppStorageBucket.isNotEmpty) kAppStorageBucket,
  kLegacyAppStorageBucket,
};

const _downloadHost = 'firebasestorage.googleapis.com';
const _publicHost = 'storage.googleapis.com';
const _emulatorHosts = {'localhost', '127.0.0.1', '10.0.2.2'};

/// `/v0/b/<bucket>/o/<chemin encodé>` : cinq segments exactement, le chemin
/// de l'objet étant encodé en un seul. Rend le chemin décodé, ou `null`.
String? _downloadObjectPath(List<String> segments, Set<String> buckets) {
  if (segments.length != 5 ||
      segments[0] != 'v0' ||
      segments[1] != 'b' ||
      segments[3] != 'o' ||
      segments[4].isEmpty) {
    return null;
  }
  final bucket = _decodeSegment(segments[2]);
  if (bucket == null || !buckets.contains(bucket)) return null;
  return _decodeSegment(segments[4]);
}

/// `/<bucket>/<chemin>` : le chemin de l'objet est fait des segments qui
/// suivent le bucket, chacun décodé. Rend le chemin, ou `null`.
String? _publicObjectPath(List<String> segments, Set<String> buckets) {
  if (segments.length < 2) return null;
  final bucket = _decodeSegment(segments.first);
  if (bucket == null || !buckets.contains(bucket)) return null;
  final parts = <String>[];
  for (final s in segments.skip(1)) {
    final decoded = _decodeSegment(s);
    if (decoded == null) return null;
    parts.add(decoded);
  }
  return parts.join('/');
}

/// Décode un segment de chemin encodé (`%2F` → `/`), ou `null` si
/// l'encodage est illisible : échappement tronqué ou non hexadécimal,
/// caractère hors ASCII laissé brut, octets qui ne forment pas de l'UTF-8.
/// Sans exception : un refus, pas une erreur.
String? _decodeSegment(String raw) {
  final bytes = <int>[];
  for (var i = 0; i < raw.length; i++) {
    final c = raw.codeUnitAt(i);
    if (c > 0x7f) return null;
    if (c != 0x25) {
      bytes.add(c);
      continue;
    }
    if (i + 2 >= raw.length) return null;
    final hex = raw.substring(i + 1, i + 3);
    if (!_hexPair.hasMatch(hex)) return null;
    bytes.add(int.parse(hex, radix: 16));
    i += 2;
  }
  final text = const Utf8Decoder(allowMalformed: true).convert(bytes);
  return text.contains('\uFFFD') ? null : text;
}

final _hexPair = RegExp(r'^[0-9A-Fa-f]{2}$');

/// Même contrôle que `isWellFormedObjectPath` côté serveur : pas de chemin
/// vide ni de plus de 1 024 caractères, pas de segment vide, `.` ou `..`,
/// pas de barre oblique inverse ni de caractère de contrôle.
bool _isWellFormedObjectPath(String path) {
  if (path.isEmpty || path.length > 1024) return false;
  if (_forbiddenPathChars.hasMatch(path)) return false;
  return path.split('/').every((s) => s.isNotEmpty && s != '.' && s != '..');
}

final _forbiddenPathChars = RegExp(r'[\x00-\x1f\x7f\\]');
