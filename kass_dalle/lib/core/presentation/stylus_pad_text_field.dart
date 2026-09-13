import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Scribe;

import '../services/error_report_service.dart';
import '../theme/app_icon_size.dart';

/// Dit si l'appareil convertit l'écriture au stylet en texte.
typedef StylusHandwritingProbe = Future<bool> Function();

/// Sonde par défaut.
///
/// Android 14 (API 34) répond par `Scribe.isFeatureAvailable` : `false` sous
/// Android 13, et `false` aussi quand « S Pen vers texte » est désactivé dans
/// les réglages Samsung. L'iPad écrit au Pencil depuis iOS 14 sans qu'on
/// puisse l'interroger : on répond `true`, et un iPhone ne produit aucun
/// événement de stylet. Sur le web et les bureaux, aucun clavier ne convertit
/// l'écriture dans un champ Flutter : jamais de pavé.
Future<bool> defaultStylusHandwritingProbe() {
  if (kIsWeb) return Future<bool>.value(false);
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => Scribe.isFeatureAvailable(),
    TargetPlatform.iOS => Future<bool>.value(true),
    _ => Future<bool>.value(false),
  };
}

/// Un champ de texte libre qui ouvre un grand pavé d'écriture quand un stylet
/// le touche.
///
/// Un champ Flutter n'est pas une vue Android : le survol du S Pen n'y fait
/// jamais apparaître l'icône d'écriture manuscrite de Samsung. Depuis
/// Android 14, Flutter démarre en revanche l'écriture système dès qu'un stylet
/// se pose sur un champ qui a le clavier, et l'écriture se fait alors dans le
/// champ : quatre lignes de haut sur une tablette. Ce widget détecte la pose
/// du stylet et ouvre un panneau bas dont le champ partage le même contrôleur
/// et occupe l'écran au-dessus du clavier.
///
/// Le champ d'origine a `stylusHandwritingEnabled: false` : le stylet y place
/// le curseur comme un doigt, et n'y démarre pas une session d'écriture que
/// l'ouverture du pavé interromprait au premier trait.
///
/// Sans stylet, c'est un `TextField` ordinaire : mêmes paramètres, même rendu.
class StylusPadTextField extends StatefulWidget {
  const StylusPadTextField({
    super.key,
    required this.controller,
    this.decoration = const InputDecoration(),
    this.maxLines = 1,
    this.minLines,
    this.autofocus = false,
    this.enabled = true,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.padTitle,
    this.handwritingProbe = defaultStylusHandwritingProbe,
    this.errorReportService,
  });

  final TextEditingController controller;
  final InputDecoration decoration;
  final int? maxLines;
  final int? minLines;
  final bool autofocus;
  final bool enabled;
  final TextInputAction? textInputAction;

  /// Appelé pour une saisie dans le champ comme dans le pavé.
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Titre du pavé. À défaut, le `labelText` de la décoration, puis
  /// [defaultPadTitle].
  final String? padTitle;

  /// Dit si l'appareil convertit l'écriture ; injectable pour les tests.
  final StylusHandwritingProbe handwritingProbe;

  final ErrorReportService? errorReportService;

  /// Titre de repli du pavé.
  static const String defaultPadTitle = 'Écriture au stylet';

  /// Clé du champ du pavé, pour les tests.
  static const Key padFieldKey = ValueKey<String>('stylus_pad_field');

  @override
  State<StylusPadTextField> createState() => _StylusPadTextFieldState();
}

class _StylusPadTextFieldState extends State<StylusPadTextField> {
  late final ErrorReportService _errors =
      widget.errorReportService ?? ErrorReportService();

  /// Vrai entre la pose du stylet et la fermeture du pavé : une deuxième
  /// pose pendant la sonde n'ouvre pas un deuxième pavé.
  bool _opening = false;

  String get _padTitle =>
      widget.padTitle ??
      widget.decoration.labelText ??
      StylusPadTextField.defaultPadTitle;

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.stylus) return;
    if (!widget.enabled || _opening) return;
    unawaited(_openPad());
  }

  Future<void> _openPad() async {
    _opening = true;
    try {
      final bool available;
      try {
        available = await widget.handwritingProbe();
      } catch (error, stackTrace) {
        await _errors.reportError(
          feature: 'stylus_pad_probe',
          error: error,
          stackTrace: stackTrace,
          context: {'platform': defaultTargetPlatform.name, 'web': kIsWeb},
        );
        return;
      }
      if (!available || !mounted) return;
      await showStylusHandwritingPad(
        context,
        controller: widget.controller,
        title: _padTitle,
        hintText: widget.decoration.hintText,
        onChanged: widget.onChanged,
      );
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      child: TextField(
        controller: widget.controller,
        decoration: widget.decoration,
        maxLines: widget.maxLines,
        minLines: widget.minLines,
        autofocus: widget.autofocus,
        enabled: widget.enabled,
        textInputAction: widget.textInputAction,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        stylusHandwritingEnabled: false,
      ),
    );
  }
}

/// Ouvre le pavé d'écriture au stylet sur [controller].
///
/// Le champ du pavé a le focus dès l'ouverture : c'est la condition pour que
/// le premier trait de stylet démarre l'écriture système.
Future<void> showStylusHandwritingPad(
  BuildContext context, {
  required TextEditingController controller,
  required String title,
  String? hintText,
  ValueChanged<String>? onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    // Toute la largeur : le thème Material 3 borne un panneau à 640 px, et
    // une ligne d'écriture manuscrite veut la largeur de la tablette.
    constraints: const BoxConstraints(),
    builder: (context) => _StylusHandwritingPad(
      controller: controller,
      title: title,
      hintText: hintText,
      onChanged: onChanged,
    ),
  );
}

class _StylusHandwritingPad extends StatelessWidget {
  const _StylusHandwritingPad({
    required this.controller,
    required this.title,
    this.hintText,
    this.onChanged,
  });

  final TextEditingController controller;
  final String title;
  final String? hintText;
  final ValueChanged<String>? onChanged;

  static const double _minHeight = 220;

  /// Part de l'écran prise quand le clavier est replié.
  static const double _screenShare = 0.7;

  /// Marge gardée au-dessus du pavé : la poignée, et un peu de l'écran dessous.
  static const double _topMargin = 72;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final screen = media.size.height;
    // Tout l'espace au-dessus du clavier quand il est déployé, 70 % de
    // l'écran quand l'écriture système l'a replié.
    final height = math.max(
      _minHeight,
      math.min(
        screen * _screenShare,
        screen - keyboard - media.padding.top - _topMargin,
      ),
    );
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.draw_outlined,
                    size: AppIconSize.medium,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Terminé'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: TextField(
                  key: StylusPadTextField.padFieldKey,
                  controller: controller,
                  autofocus: true,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  textAlignVertical: TextAlignVertical.top,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontSize: 20,
                    height: 1.6,
                  ),
                  decoration: InputDecoration(
                    hintText: hintText,
                    border: const OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                  onChanged: onChanged,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
