import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kass_dalle/core/app_version.dart';
import 'package:kass_dalle/core/services/app_installer.dart';
import 'package:kass_dalle/core/services/app_update_service.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';

/// Les rapports d'erreur passent par Firestore et Auth : hors application, ils
/// ne sont pas joignables. On garde la trace des appels pour vérifier que rien
/// n'échoue en silence.
class _RecordingErrorReportService extends ErrorReportService {
  final List<String> features = [];

  @override
  Future<String> reportError({
    String? userId,
    String? jobId,
    required String feature,
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic> context = const {},
  }) async {
    features.add(feature);
    return 'test';
  }
}

class _FakeInstaller extends AppInstaller {
  final String? dir;
  final bool supported;

  _FakeInstaller({this.dir, this.supported = true})
    : super(errorReportService: _RecordingErrorReportService());

  @override
  bool get isSupported => supported;

  @override
  Future<String?> downloadDir() async => dir;
}

http.StreamedResponse _streamed(
  List<List<int>> chunks, {
  int status = 200,
  int? contentLength,
}) {
  return http.StreamedResponse(
    Stream.fromIterable(chunks),
    status,
    contentLength:
        contentLength ??
        chunks.fold<int>(0, (sum, chunk) => sum + chunk.length),
  );
}

void main() {
  setUp(() {
    kAppVersion = '0.22.36';
    kAppBuildNumber = '271';
  });

  group('isNewerVersion', () {
    test('une version supérieure est plus récente', () {
      expect(
        isNewerVersion(serverVersion: '0.22.37', currentVersion: '0.22.36'),
        isTrue,
      );
      expect(
        isNewerVersion(serverVersion: '0.23.0', currentVersion: '0.22.99'),
        isTrue,
      );
      expect(
        isNewerVersion(serverVersion: '1.0.0', currentVersion: '0.99.99'),
        isTrue,
      );
    });

    test('une version inférieure ou égale ne l est pas', () {
      expect(
        isNewerVersion(serverVersion: '0.22.35', currentVersion: '0.22.36'),
        isFalse,
      );
      expect(
        isNewerVersion(serverVersion: '0.22.36', currentVersion: '0.22.36'),
        isFalse,
      );
    });

    test('un segment manquant vaut zéro', () {
      expect(
        isNewerVersion(serverVersion: '0.23', currentVersion: '0.22.36'),
        isTrue,
      );
      expect(
        isNewerVersion(serverVersion: '0.22', currentVersion: '0.22.1'),
        isFalse,
      );
    });

    test('à version égale, le build départage', () {
      // Un APK reconstruit sans bump de `version:` : même nom, build supérieur.
      expect(
        isNewerVersion(
          serverVersion: '0.22.36',
          currentVersion: '0.22.36',
          serverBuild: '272',
          currentBuild: '271',
        ),
        isTrue,
      );
      expect(
        isNewerVersion(
          serverVersion: '0.22.36',
          currentVersion: '0.22.36',
          serverBuild: '271',
          currentBuild: '271',
        ),
        isFalse,
      );
    });

    test('un build illisible ne déclenche aucune mise à jour', () {
      expect(
        isNewerVersion(
          serverVersion: '0.22.36',
          currentVersion: '0.22.36',
          serverBuild: '',
          currentBuild: '271',
        ),
        isFalse,
      );
    });

    test('la version prime sur le build', () {
      // Un manifeste plus ancien avec un build plus grand reste plus ancien.
      expect(
        isNewerVersion(
          serverVersion: '0.22.35',
          currentVersion: '0.22.36',
          serverBuild: '999',
          currentBuild: '271',
        ),
        isFalse,
      );
    });
  });

  group('check', () {
    test('un manifeste plus récent décrit l APK à télécharger', () async {
      final service = AppUpdateService(
        installer: _FakeInstaller(),
        errorReportService: _RecordingErrorReportService(),
        client: MockClient((request) async {
          expect(request.url.path, '/apk_release.json');
          return http.Response(
            '{"version":"0.22.37","build_number":"272",'
            '"file":"app-release.apk","size_bytes":89825251}',
            200,
          );
        }),
      );

      final info = await service.check();

      expect(info, isNotNull);
      expect(info!.latestVersion, '0.22.37');
      expect(info.buildNumber, '272');
      expect(info.sizeBytes, 89825251);
      expect(info.apkUrl, endsWith('/app-release.apk'));
    });

    test('la version installée ne se propose pas à elle-même', () async {
      final service = AppUpdateService(
        installer: _FakeInstaller(),
        errorReportService: _RecordingErrorReportService(),
        client: MockClient((_) async {
          return http.Response(
            '{"version":"0.22.36","build_number":"271"}',
            200,
          );
        }),
      );

      expect(await service.check(), isNull);
    });

    test('sans manifeste, aucune mise à jour n est proposée', () async {
      // Pas de repli sur `version.json` : il décrit le bundle web, et le lire
      // annoncerait une version que le téléchargement ne rend pas.
      final errors = _RecordingErrorReportService();
      final visited = <String>[];
      final service = AppUpdateService(
        installer: _FakeInstaller(),
        errorReportService: errors,
        client: MockClient((request) async {
          visited.add(request.url.path);
          return http.Response('Not Found', 404);
        }),
      );

      expect(await service.check(), isNull);
      expect(visited, ['/apk_release.json']);
      expect(visited, isNot(contains('/version.json')));
    });

    test('un manifeste illisible est signalé, pas ignoré', () async {
      final errors = _RecordingErrorReportService();
      final service = AppUpdateService(
        installer: _FakeInstaller(),
        errorReportService: errors,
        client: MockClient((_) async => http.Response('pas du json', 200)),
      );

      expect(await service.check(), isNull);
      expect(errors.features, contains('check_for_app_update'));
    });

    test('hors Android, rien n est demandé au réseau', () async {
      var calls = 0;
      final service = AppUpdateService(
        installer: _FakeInstaller(supported: false),
        errorReportService: _RecordingErrorReportService(),
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );

      expect(await service.check(), isNull);
      expect(calls, 0);
    });
  });

  group('download', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('kd_update_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    AppUpdateInfo info({int? size}) => AppUpdateInfo(
      latestVersion: '0.22.37',
      apkUrl: 'https://kassdale-6d948.web.app/app-release.apk',
      sizeBytes: size,
    );

    test('l APK est écrit et la progression suivie', () async {
      final service = AppUpdateService(
        installer: _FakeInstaller(dir: tmp.path),
        errorReportService: _RecordingErrorReportService(),
        client: MockClient.streaming((_, _) async {
          return _streamed([
            Uint8List.fromList(List.filled(500, 7)),
            Uint8List.fromList(List.filled(500, 7)),
          ]);
        }),
      );

      final progress = <int>[];
      final path = await service.download(
        info(size: 1000),
        onProgress: (received, _) => progress.add(received),
      );

      expect(path, isNotNull);
      expect(File(path!).lengthSync(), 1000);
      expect(progress, [500, 1000]);
    });

    test('un APK tronqué est refusé et effacé', () async {
      final errors = _RecordingErrorReportService();
      final service = AppUpdateService(
        installer: _FakeInstaller(dir: tmp.path),
        errorReportService: errors,
        client: MockClient.streaming((_, _) async {
          // 400 octets annoncés, 200 envoyés.
          return _streamed([
            Uint8List.fromList(List.filled(200, 7)),
          ], contentLength: 400);
        }),
      );

      expect(await service.download(info()), isNull);
      expect(errors.features, contains('app_update_download'));
      expect(tmp.listSync(), isEmpty);
    });

    test('une réponse en erreur ne laisse pas de fichier', () async {
      final errors = _RecordingErrorReportService();
      final service = AppUpdateService(
        installer: _FakeInstaller(dir: tmp.path),
        errorReportService: errors,
        client: MockClient.streaming((_, _) async {
          return http.StreamedResponse(const Stream.empty(), 404);
        }),
      );

      expect(await service.download(info()), isNull);
      expect(errors.features, contains('app_update_download'));
      expect(tmp.listSync(), isEmpty);
    });

    test(
      'une annulation efface le fichier partiel sans lever d erreur',
      () async {
        final errors = _RecordingErrorReportService();
        final handle = ApkDownload();
        final service = AppUpdateService(
          installer: _FakeInstaller(dir: tmp.path),
          errorReportService: errors,
          client: MockClient.streaming((_, _) async {
            return _streamed([
              Uint8List.fromList(List.filled(500, 7)),
              Uint8List.fromList(List.filled(500, 7)),
            ]);
          }),
        );

        final path = await service.download(
          info(size: 1000),
          handle: handle,
          onProgress: (_, _) => handle.cancel(),
        );

        expect(path, isNull);
        expect(tmp.listSync(), isEmpty);
        // Annuler est un choix de l'utilisateur, pas une panne à rapporter.
        expect(errors.features, isEmpty);
      },
    );

    test('sans dossier de téléchargement, rien n est tenté', () async {
      final service = AppUpdateService(
        installer: _FakeInstaller(dir: null),
        errorReportService: _RecordingErrorReportService(),
        client: MockClient.streaming((_, _) async {
          fail('aucune requête ne doit partir');
        }),
      );

      expect(await service.download(info()), isNull);
    });
  });
}
