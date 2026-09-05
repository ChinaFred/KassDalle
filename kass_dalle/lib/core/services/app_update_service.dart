import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../app_version.dart';
import 'apk_file_store_stub.dart'
    if (dart.library.io) 'apk_file_store_io.dart'
    as apk_store;
import 'app_installer.dart';
import 'error_report_service.dart';

const _kHostingUrl = 'https://kassdale-6d948.web.app';

/// URL publique de l'APK Android hébergé sur Firebase Hosting.
const kApkDownloadUrl = '$_kHostingUrl/app-release.apk';

/// Manifeste de l'APK réellement publié.
///
/// Ce n'est pas `version.json`, qui décrit le bundle web. Les deux divergent
/// dès qu'un déploiement ne reconstruit pas l'APK : `deploy.ps1 -WebOnly` met
/// le web à jour et laisse l'APK en place. Lire `version.json` faisait alors
/// annoncer une version que le téléchargement ne rendait pas — l'utilisateur
/// installait, restait en dessous, et la fenêtre revenait à chaque lancement.
///
/// `apk_release.json` n'est écrit qu'au moment où l'APK est construit et copié.
/// Il décrit donc toujours le fichier servi à côté de lui.
const _kApkManifestUrl = '$_kHostingUrl/apk_release.json';

class AppUpdateInfo {
  final String latestVersion;
  final String buildNumber;
  final String apkUrl;

  /// Taille annoncée par le manifeste, en octets. Sert à afficher un poids
  /// avant le téléchargement et à vérifier que le fichier reçu est complet.
  final int? sizeBytes;

  const AppUpdateInfo({
    required this.latestVersion,
    required this.apkUrl,
    this.buildNumber = '',
    this.sizeBytes,
  });
}

/// Suivi d'un téléchargement en cours : le seul moyen de l'interrompre.
class ApkDownload {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}

/// Mise à jour de l'application Android hors magasin : vérifier, télécharger,
/// installer.
///
/// Le web se met à jour au rechargement, iOS n'autorise rien de tel : les deux
/// obtiennent null de [check] et n'ont pas à s'en préoccuper.
class AppUpdateService {
  final http.Client _client;
  final ErrorReportService _errorReportService;
  final AppInstaller _installer;

  AppUpdateService({
    http.Client? client,
    ErrorReportService? errorReportService,
    AppInstaller? installer,
  }) : _client = client ?? http.Client(),
       _errorReportService = errorReportService ?? ErrorReportService(),
       _installer = installer ?? AppInstaller();

  AppInstaller get installer => _installer;

  /// Retourne les informations de la version publiée si elle est plus récente
  /// que celle installée, null sinon.
  ///
  /// Pas de repli sur `version.json` quand le manifeste est absent : ce serait
  /// reproduire le défaut qu'il corrige. Sans manifeste, aucune mise à jour
  /// n'est proposée.
  Future<AppUpdateInfo?> check() async {
    if (!_installer.isSupported) return null;

    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final res = await _client
          .get(
            Uri.parse('$_kApkManifestUrl?t=$ts'),
            headers: {'Cache-Control': 'no-cache'},
          )
          .timeout(const Duration(seconds: 8));

      if (res.statusCode != 200) return null;

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final latest = json['version'];
      if (latest is! String || latest.isEmpty) return null;

      final build = json['build_number'];
      final buildNumber = build is String
          ? build
          : (build is num ? build.toString() : '');

      final newer = isNewerVersion(
        serverVersion: latest,
        serverBuild: buildNumber,
        currentVersion: kAppVersion,
        currentBuild: kAppBuildNumber,
      );
      if (!newer) return null;

      final file = json['file'];
      final size = json['size_bytes'];

      return AppUpdateInfo(
        latestVersion: latest,
        buildNumber: buildNumber,
        apkUrl: file is String && file.isNotEmpty
            ? '$_kHostingUrl/$file'
            : kApkDownloadUrl,
        sizeBytes: size is num ? size.toInt() : null,
      );
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'check_for_app_update',
        error: e,
        stackTrace: st,
        context: {'manifest': _kApkManifestUrl},
      );
      return null;
    }
  }

  /// Télécharge l'APK dans le dossier que le système réserve aux mises à jour
  /// et retourne son chemin, ou null si le téléchargement a échoué ou a été
  /// annulé.
  ///
  /// [onProgress] reçoit les octets reçus et le total attendu — ce dernier est
  /// null tant que ni l'en-tête ni le manifeste ne l'annoncent.
  Future<String?> download(
    AppUpdateInfo info, {
    ApkDownload? handle,
    void Function(int received, int? total)? onProgress,
  }) async {
    if (!_installer.isSupported) return null;

    final dir = await _installer.downloadDir();
    if (dir == null) return null;

    final path = '$dir/kass-dalle-${info.latestVersion}.apk';

    try {
      // Un APK par version, et un seul à la fois : la version précédente n'a
      // plus d'usage une fois installée, et elle occupe 90 Mo de cache.
      await apk_store.clearDirectory(dir);

      final request = http.Request('GET', Uri.parse(info.apkUrl));
      final response = await _client.send(request);

      if (response.statusCode != 200) {
        await _errorReportService.reportError(
          feature: 'app_update_download',
          error: 'HTTP ${response.statusCode} sur ${info.apkUrl}',
          stackTrace: StackTrace.current,
          context: {'apk_url': info.apkUrl, 'version': info.latestVersion},
        );
        return null;
      }

      final total = response.contentLength ?? info.sizeBytes;
      var received = 0;

      final chunks = response.stream.map((chunk) {
        if (handle != null && handle.isCancelled) {
          throw const _DownloadCancelled();
        }
        received += chunk.length;
        onProgress?.call(received, total);
        return chunk;
      });

      await apk_store.writeChunks(path, chunks);

      // Un APK tronqué s'installe en échouant, sans dire pourquoi. Mieux vaut
      // refuser de l'ouvrir.
      final written = await apk_store.fileSize(path);
      if (total != null && written != total) {
        await _discardPartialFile(dir);
        await _errorReportService.reportError(
          feature: 'app_update_download',
          error: 'APK incomplet : $written octets reçus sur $total attendus',
          stackTrace: StackTrace.current,
          context: {'apk_url': info.apkUrl, 'version': info.latestVersion},
        );
        return null;
      }

      return path;
    } catch (e, st) {
      // L'annulation se lit sur le suivi, pas sur le type de l'exception :
      // `_DownloadCancelled` traverse `addStream` puis la fermeture du fichier,
      // et ressort parfois enveloppée. Se fier au type laissait un APK à moitié
      // écrit dans le cache après un « Annuler ».
      final cancelled = handle != null && handle.isCancelled;
      await _discardPartialFile(dir);
      if (cancelled) return null;

      await _errorReportService.reportError(
        feature: 'app_update_download',
        error: e,
        stackTrace: st,
        context: {'apk_url': info.apkUrl, 'version': info.latestVersion},
      );
      return null;
    }
  }

  /// Efface le fichier laissé par un téléchargement qui n'a pas abouti.
  ///
  /// Un échec de nettoyage ne change rien pour l'utilisateur — le prochain
  /// téléchargement vide le dossier avant d'écrire — mais 90 Mo bloqués dans le
  /// cache méritent d'être signalés.
  Future<void> _discardPartialFile(String dir) async {
    try {
      await apk_store.clearDirectory(dir);
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'app_update_download',
        error: e,
        stackTrace: st,
        context: {'phase': 'nettoyage', 'dir': dir},
      );
    }
  }
}

/// Vrai si la version publiée est plus récente que celle installée.
///
/// La version prime. À version égale, le numéro de build départage : un APK
/// reconstruit sans changement de `version:` porte le même nom de version et un
/// build supérieur, et sans cette comparaison il passerait pour identique.
@visibleForTesting
bool isNewerVersion({
  required String serverVersion,
  required String currentVersion,
  String serverBuild = '',
  String currentBuild = '',
}) {
  final comparison = _compareVersions(serverVersion, currentVersion);
  if (comparison != 0) return comparison > 0;

  final s = int.tryParse(serverBuild.trim());
  final c = int.tryParse(currentBuild.trim());
  if (s == null || c == null) return false;
  return s > c;
}

/// Retourne un nombre positif si [a] est plus récent que [b], négatif si
/// l'inverse, zéro pour deux fois la même version.
int _compareVersions(String a, String b) {
  final va = _parseVersion(a);
  final vb = _parseVersion(b);
  final len = va.length > vb.length ? va.length : vb.length;
  for (var i = 0; i < len; i++) {
    final x = i < va.length ? va[i] : 0;
    final y = i < vb.length ? vb[i] : 0;
    if (x != y) return x - y;
  }
  return 0;
}

List<int> _parseVersion(String v) {
  return v
      .split('.')
      .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();
}
