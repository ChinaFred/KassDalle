import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_version.dart';
import '../services/app_update_service.dart';
import '../services/error_report_service.dart';
import '../theme/app_icon_size.dart';

/// Ouvre la fenêtre de mise à jour de l'application Android.
///
/// Elle mène l'utilisateur jusqu'à l'écran d'installation du système sans lui
/// faire quitter Kass'Dalle : autorisation, téléchargement, installation.
/// Auparavant, le bouton ouvrait le navigateur et l'utilisateur devait
/// retrouver le fichier téléchargé, puis autoriser Chrome à installer des
/// applications. Ce chemin reste en repli quand l'installation directe échoue.
Future<void> showAppUpdateDialog(
  BuildContext context, {
  required AppUpdateInfo info,
  required AppUpdateService service,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AppUpdateDialog(info: info, service: service),
  );
}

enum _Stage { offer, permission, downloading, installing, failed }

class AppUpdateDialog extends StatefulWidget {
  final AppUpdateInfo info;
  final AppUpdateService service;

  const AppUpdateDialog({super.key, required this.info, required this.service});

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  final ErrorReportService _errorReportService = ErrorReportService();

  _Stage _stage = _Stage.offer;
  ApkDownload? _download;
  int _received = 0;
  int? _total;
  String _failure = '';

  @override
  void dispose() {
    _download?.cancel();
    super.dispose();
  }

  bool get _busy => _stage == _Stage.downloading || _stage == _Stage.installing;

  @override
  Widget build(BuildContext context) {
    // Pendant le téléchargement, le retour système fermerait la fenêtre en
    // laissant la requête tourner pour rien. Le bouton « Annuler » est le seul
    // chemin de sortie, et il arrête aussi le transfert.
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        icon: const Icon(Icons.system_update_outlined, size: AppIconSize.large),
        title: Text(_title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _content(context),
        ),
        actions: _actions(context),
      ),
    );
  }

  String get _title => switch (_stage) {
    _Stage.permission => 'Autorisation nécessaire',
    _Stage.downloading => 'Téléchargement',
    _Stage.installing => 'Installation',
    _Stage.failed => 'Mise à jour interrompue',
    _Stage.offer => 'Mise à jour disponible',
  };

  List<Widget> _content(BuildContext context) {
    switch (_stage) {
      case _Stage.offer:
        final size = widget.info.sizeBytes;
        return [
          Text(
            'La version ${widget.info.latestVersion} est disponible.\n'
            'Vous utilisez actuellement la version $kAppVersion.',
          ),
          if (size != null) ...[
            const SizedBox(height: 8),
            Text(
              'Téléchargement de ${_formatBytes(size)}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ];

      case _Stage.permission:
        return const [
          Text(
            "Android demande votre accord pour que Kass'Dalle installe des "
            'mises à jour.',
          ),
          SizedBox(height: 8),
          Text(
            "Ouvrez les réglages, activez « Autoriser cette source », puis "
            'revenez ici.',
          ),
        ];

      case _Stage.downloading:
        final total = _total;
        final ratio = total != null && total > 0 ? _received / total : null;
        return [
          LinearProgressIndicator(value: ratio),
          const SizedBox(height: 12),
          Text(
            total != null
                ? '${_formatBytes(_received)} sur ${_formatBytes(total)}'
                : _formatBytes(_received),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ];

      case _Stage.installing:
        return const [
          Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Expanded(child: Text("Ouverture de l'installateur…")),
            ],
          ),
        ];

      case _Stage.failed:
        return [
          Text(_failure),
          const SizedBox(height: 8),
          Text(
            "Vous pouvez télécharger l'APK depuis le navigateur et l'ouvrir "
            'vous-même.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ];
    }
  }

  List<Widget> _actions(BuildContext context) {
    switch (_stage) {
      case _Stage.offer:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Plus tard'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.download_outlined),
            label: const Text('Mettre à jour'),
            onPressed: _start,
          ),
        ];

      case _Stage.permission:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Plus tard'),
          ),
          TextButton(
            onPressed: _openSettings,
            child: const Text('Ouvrir les réglages'),
          ),
          FilledButton(onPressed: _start, child: const Text("J'ai autorisé")),
        ];

      case _Stage.downloading:
        return [TextButton(onPressed: _cancel, child: const Text('Annuler'))];

      case _Stage.installing:
        return const [];

      case _Stage.failed:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Fermer'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.open_in_new),
            label: const Text('Ouvrir dans le navigateur'),
            onPressed: _openInBrowser,
          ),
        ];
    }
  }

  /// Demande l'autorisation avant de télécharger, et non l'inverse : 90 Mo
  /// transférés pour se voir refuser l'installation ensuite seraient perdus.
  Future<void> _start() async {
    final allowed = await widget.service.installer.canRequestInstall();
    if (!mounted) return;
    if (!allowed) {
      setState(() => _stage = _Stage.permission);
      return;
    }

    final handle = ApkDownload();
    setState(() {
      _stage = _Stage.downloading;
      _download = handle;
      _received = 0;
      _total = widget.info.sizeBytes;
    });

    final path = await widget.service.download(
      widget.info,
      handle: handle,
      onProgress: (received, total) {
        if (!mounted) return;
        setState(() {
          _received = received;
          _total = total;
        });
      },
    );

    if (!mounted) return;

    if (path == null) {
      // Une annulation est un choix, pas une panne : on revient à la
      // proposition sans afficher d'erreur.
      setState(() {
        _stage = handle.isCancelled ? _Stage.offer : _Stage.failed;
        if (!handle.isCancelled) {
          _failure = "Le téléchargement de la mise à jour n'a pas abouti.";
        }
        _download = null;
      });
      return;
    }

    setState(() {
      _stage = _Stage.installing;
      _download = null;
    });

    final launched = await widget.service.installer.installApk(path);
    if (!mounted) return;

    if (!launched) {
      setState(() {
        _stage = _Stage.failed;
        _failure = "L'installateur du système n'a pas pu s'ouvrir.";
      });
      return;
    }

    // L'écran d'installation d'Android est passé devant : la fenêtre n'a plus
    // rien à dire.
    Navigator.of(context).pop();
  }

  void _cancel() {
    _download?.cancel();
    setState(() {
      _stage = _Stage.offer;
      _download = null;
    });
  }

  Future<void> _openSettings() async {
    final opened = await widget.service.installer.openInstallSettings();
    if (!mounted || opened) return;
    setState(() {
      _stage = _Stage.failed;
      _failure =
          "L'écran d'autorisation des sources inconnues n'a pas pu s'ouvrir.";
    });
  }

  Future<void> _openInBrowser() async {
    try {
      await launchUrl(
        Uri.parse(widget.info.apkUrl),
        mode: LaunchMode.externalApplication,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e, st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'app_update_download',
          error: e,
          stackTrace: st,
          context: {'apk_url': widget.info.apkUrl, 'fallback': 'browser'},
        ),
      );
    }
  }
}

String _formatBytes(int bytes) {
  const mb = 1024 * 1024;
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} Mo';
  return '${(bytes / 1024).toStringAsFixed(0)} Ko';
}
