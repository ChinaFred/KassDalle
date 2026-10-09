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

  final segments = uri.pathSegments;
  final host = uri.host.toLowerCase();

  if (uri.scheme == 'https' && host == _downloadHost && !uri.hasPort) {
    return _isDownloadPath(segments, accepted);
  }
  if (uri.scheme == 'https' && host == _publicHost && !uri.hasPort) {
    return segments.length >= 2 &&
        accepted.contains(segments.first) &&
        segments.skip(1).every((s) => s.isNotEmpty);
  }
  if (allowEmulator &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      _emulatorHosts.contains(host)) {
    return _isDownloadPath(segments, accepted);
  }
  return false;
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
/// de l'objet étant encodé en un seul.
bool _isDownloadPath(List<String> segments, Set<String> buckets) {
  return segments.length == 5 &&
      segments[0] == 'v0' &&
      segments[1] == 'b' &&
      buckets.contains(segments[2]) &&
      segments[3] == 'o' &&
      segments[4].isNotEmpty;
}
