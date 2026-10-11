import 'dart:async';

import 'package:flutter/services.dart';

import '../../../core/services/error_report_service.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/utils/platform_utils.dart';

/// Les textes reçus par « Partager vers Kass'Dalle » (Android).
///
/// Le filtre d'intention `ACTION_SEND` `text/plain` de `AndroidManifest.xml`
/// fait apparaître l'application dans la feuille de partage du système.
/// `MainActivity` lit le texte partagé (`EXTRA_TEXT`, à défaut
/// `EXTRA_SUBJECT`) et le rend par le canal [channelName], sans paquet tiers :
///
/// - `getInitialSharedText` rend le partage en attente — celui qui a ouvert
///   l'application, ou un partage arrivé avant que Dart n'écoute — puis
///   l'efface côté natif ; `null` s'il n'y en a pas ;
/// - `onSharedText` est appelé par le natif quand un partage arrive pendant
///   que l'application tourne.
///
/// Partout ailleurs qu'Android, le flux est vide : iOS, le web et Windows ne
/// reçoivent pas de partage.
class ShareIntentSource {
  ShareIntentSource({
    MethodChannel? channel,
    ErrorReportService? errorReportService,
    bool? enabled,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _errorReportService = errorReportService ?? ErrorReportService(),
       _enabled = enabled ?? PlatformUtils.isAndroidApp;

  /// Nom du canal, le même que `SHARE_CHANNEL` dans `MainActivity.kt`.
  static const channelName = 'dev.kassbi.kass_dalle/share';

  final MethodChannel _channel;
  final ErrorReportService _errorReportService;
  final bool _enabled;

  /// Le texte de chaque partage reçu : d'abord celui du démarrage, puis les
  /// suivants. Un partage reçu sans texte lisible émet une chaîne vide.
  Stream<String> sharedTexts() {
    if (!_enabled) return const Stream.empty();
    late final StreamController<String> controller;
    controller = StreamController<String>(
      onListen: () {
        _channel.setMethodCallHandler((call) async {
          if (call.method != 'onSharedText') {
            throw MissingPluginException('Méthode inconnue : ${call.method}');
          }
          _emit(controller, call.arguments);
          return null;
        });
        unawaited(_readInitial(controller));
      },
      onCancel: () => _channel.setMethodCallHandler(null),
    );
    return controller.stream;
  }

  Future<void> _readInitial(StreamController<String> controller) async {
    try {
      final text = await _channel.invokeMethod<String>('getInitialSharedText');
      if (text != null) _emit(controller, text);
    } catch (error, stackTrace) {
      // `_readInitial` ne tourne que si `_enabled` (Android) : là,
      // `MainActivity` doit répondre. Un `MissingPluginException` y signale
      // une panne du code natif (canal renommé, activité non enregistrée), et
      // se remonte comme toute autre erreur.
      _report(error, stackTrace, 'initial');
    }
  }

  void _emit(StreamController<String> controller, Object? text) {
    if (controller.isClosed) return;
    // Un partage reçu sans texte lisible émet une chaîne vide : l'écran dit
    // « Ce partage ne contient pas d'adresse web. » plutôt que rien.
    controller.add(text is String ? text.trim() : '');
  }

  /// Remontée par le service injecté ; [reportUnexpectedError] garde la
  /// console en dernier recours si l'écriture du rapport échoue.
  void _report(Object error, StackTrace stackTrace, String source) {
    reportUnexpectedError(
      feature: 'shareIntent.receive',
      error: error,
      stackTrace: stackTrace,
      context: {'source': source},
      service: _errorReportService,
    );
  }
}
