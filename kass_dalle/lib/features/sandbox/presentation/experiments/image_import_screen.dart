import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/presentation/image_enhancer_processing.dart';
import '../../../../core/services/error_report_service.dart';
import '../../../../core/utils/platform_utils.dart';
import '../../../../core/widgets/readable_width.dart';
import '../../data/sandbox_functions.dart';
import '../../data/sandbox_image_ops.dart';
import '../../data/sandbox_snap.dart';
import '../../domain/detected_page.dart';
import '../../domain/detected_region.dart';
import '../../domain/sandbox_engine.dart';
import '../../domain/sandbox_model_choice.dart';
import '../widgets/experiment_step.dart';
import '../widgets/regions_overlay.dart';
import '../widgets/sandbox_model_picker.dart';

/// Expérience : ce qu'on peut faire d'une image importée.
///
/// Rien n'est enregistré. L'image, la page redressée et les zones vivent en
/// mémoire, et disparaissent avec l'écran.
///
/// Deux appels de modèle, imputés aux postes `sandbox_detect_page` et
/// `sandbox_detect_regions`. Le cadrage a d'abord été tenté sans modèle, par
/// deux méthodes successives, et les deux ont rendu la serviette posée sous le
/// livre plutôt que le livre : voir l'en-tête de `sandbox_image_ops.dart`.
///
/// L'écran progresse par étapes empilées. Chacune n'apparaît que si la
/// précédente a abouti, et se valide seule avant qu'on écrive la suivante.
/// Chacune se rejoue seule, aussi : le recalage se refait sans redemander son
/// cadrage au modèle.
class SandboxImageImportScreen extends StatefulWidget {
  const SandboxImageImportScreen({super.key});

  @override
  State<SandboxImageImportScreen> createState() =>
      _SandboxImageImportScreenState();
}

/// Étape 2 : le modèle a-t-il trouvé la page ?
enum _FrameStatus { idle, running, done, failed }

/// Étape 3 : le cadre a-t-il été recalé, et la page redressée ?
enum _StraightenStatus {
  idle,
  running,

  /// Page redressée par homographie.
  straightened,

  /// La page occupe déjà tout le cadre — un scan à plat. Redresser n'aurait
  /// rien changé, et aurait coûté un rééchantillonnage.
  alreadyStraight,

  failed,
}

class _SandboxImageImportScreenState extends State<SandboxImageImportScreen> {
  final ImagePicker _imagePicker = ImagePicker();
  final ErrorReportService _errorReportService = ErrorReportService();
  final SandboxFunctions _sandbox = SandboxFunctions();

  // ── Étape 1 : l'image importée ────────────────────────────────────────────
  Uint8List? _original;
  String? _filename;
  int? _originalWidth;
  int? _originalHeight;
  bool _busy = false;
  String? _sourceMessage;

  /// L'outil qui a réellement fourni l'image.
  String? _sourceTool;

  /// L'orientation EXIF a été appliquée dans les pixels.
  bool _uprightApplied = false;

  // ── Étape 2 : le cadrage du modèle ────────────────────────────────────────
  _FrameStatus _frameStatus = _FrameStatus.idle;
  DetectedPage? _detectedPage;
  String? _frameFailure;

  /// Le modèle imposé au cadrage, `null` pour suivre Admin → Moteur d'IA.
  SandboxModelChoice? _frameModel;

  /// Idem pour la détection des zones. Les deux postes se règlent séparément :
  /// cadrer une page et lire son contenu ne demandent pas le même soin.
  SandboxModelChoice? _regionsModel;

  @override
  void initState() {
    super.initState();
    _restoreModelChoices();
  }

  Future<void> _restoreModelChoices() async {
    final frame = await SandboxModelPicker.restore(_frameFeature);
    final regions = await SandboxModelPicker.restore(_regionsFeature);
    if (!mounted) return;
    setState(() {
      _frameModel = frame;
      _regionsModel = regions;
    });
  }

  static const _frameFeature = 'sandbox_detect_page';
  static const _regionsFeature = 'sandbox_detect_regions';

  // ── Étape 3 : le recalage, puis le redressement ───────────────────────────
  _StraightenStatus _straightenStatus = _StraightenStatus.idle;

  /// Le cadre après recalage sur le bord réel, en fraction de l'image.
  List<Offset>? _snappedQuad;
  SandboxSnapResult? _snap;
  Uint8List? _page;
  int? _pageWidth;
  int? _pageHeight;
  String? _straightenFailure;

  // ── Étape 4 : les zones détectées ─────────────────────────────────────────
  List<DetectedRegion>? _regions;
  List<SandboxEngine> _regionEngines = const [];
  bool _detecting = false;
  String? _detectMessage;

  bool get _hasImage => _original != null;
  bool get _hasFrame => _detectedPage != null;
  bool get _hasPage =>
      _page != null && _pageWidth != null && _pageHeight != null;
  bool get _hasRegions => _regions != null && _regions!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Importation d\'image')),
      body: ReadableWidth(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _buildSourceStep(context),
            if (_hasImage) _buildFrameStep(context),
            if (_hasFrame) _buildStraightenStep(context),
            // Étape 4 conditionnée à une page redressée, et non à un cadrage :
            // sans redressement, le modèle lirait une page en trapèze et
            // rendrait des cadres qui ne recouperaient rien.
            if (_hasPage) _buildDetectStep(context),
            if (_hasRegions) _buildNextStep(context),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  // ── Étape 1 : la source ───────────────────────────────────────────────────

  Widget _buildSourceStep(BuildContext context) {
    final theme = Theme.of(context);

    return ExperimentStep(
      index: 1,
      title: 'Source',
      subtitle: _hasImage
          ? 'Image chargée en mémoire.'
          : 'Choisir un fichier, ou prendre une photo.',
      done: _hasImage,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_hasImage)
            _buildEngines(context, [
              SandboxEngine.local(
                stage: 'source',
                model: _sourceTool ?? 'inconnu',
              ),
              SandboxEngine.local(
                stage: 'orientation',
                model: _uprightApplied
                    ? 'image · bakeOrientation (appliquée)'
                    : 'image · bakeOrientation (rien à faire)',
              ),
            ]),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _pickFile,
                icon: const Icon(Icons.folder_open),
                label: Text(
                  _hasImage ? 'Choisir un autre fichier' : 'Choisir un fichier',
                ),
              ),
              if (PlatformUtils.isMobile)
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _takePhoto,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Prendre une photo'),
                ),
              if (_hasImage)
                TextButton.icon(
                  onPressed: _busy ? null : _clear,
                  icon: const Icon(Icons.close),
                  label: const Text('Retirer'),
                ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (_sourceMessage != null) ...[
            const SizedBox(height: 16),
            Text(
              _sourceMessage!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          if (_hasImage) ...[
            const SizedBox(height: 16),
            _buildOriginalSummary(context),
          ],
        ],
      ),
    );
  }

  Widget _buildOriginalSummary(BuildContext context) {
    final theme = Theme.of(context);
    final bytes = _original!;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tooltip(
          message: 'Voir en grand',
          child: InkWell(
            onTap: () => _showFullScreen(bytes),
            borderRadius: BorderRadius.circular(12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                bytes,
                width: 96,
                height: 96,
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _filename ?? 'image',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _originalWidth != null && _originalHeight != null
                    ? '$_originalWidth × $_originalHeight px'
                    : 'Dimensions inconnues',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                _formatBytes(bytes.lengthInBytes),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Étape 2 : le cadrage du modèle ────────────────────────────────────────

  Widget _buildFrameStep(BuildContext context) {
    final theme = Theme.of(context);
    final page = _detectedPage;

    final (String status, IconData icon, Color color) = switch (_frameStatus) {
      _FrameStatus.running => (
        'Le modèle cherche la page…',
        Icons.hourglass_empty,
        theme.colorScheme.onSurfaceVariant,
      ),
      _FrameStatus.done => (
        '${page?.kind.label ?? 'Page'} cadrée sur '
            '${(page == null ? 0 : page.coverage * 100).round()} % de l\'image.',
        Icons.crop_free,
        theme.colorScheme.primary,
      ),
      _FrameStatus.failed => (
        _frameFailure ?? 'Aucune page trouvée.',
        Icons.error_outline,
        theme.colorScheme.error,
      ),
      _FrameStatus.idle => (
        'En attente.',
        Icons.more_horiz,
        theme.disabledColor,
      ),
    };

    return ExperimentStep(
      index: 2,
      title: 'Cadrer la page',
      subtitle:
          'Le modèle dit où est la page — pas le bureau, pas la serviette '
          'dessous. Deux passes : la boîte, puis les coins sur un gros plan.',
      done: _hasFrame,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (page != null) _buildEngines(context, page.engines),
          SandboxModelPicker(
            featureKey: _frameFeature,
            value: _frameModel,
            enabled: _frameStatus != _FrameStatus.running,
            onChanged: (choice) => setState(() => _frameModel = choice),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(status, style: theme.textTheme.bodyMedium)),
            ],
          ),
          if (page != null && page.note.isNotEmpty)
            _buildAside(
              context,
              '« ${page.note} » — confiance '
              '${(page.confidence * 100).round()} %',
            ),
          if (page != null && page.fromBoxOnly)
            _buildAside(
              context,
              'Coins non affinés : la seconde passe n\'a rien rendu, le cadre '
              'reste la boîte droite de la première.',
              color: theme.colorScheme.tertiary,
            ),
          if (_frameStatus == _FrameStatus.running) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (_frameStatus == _FrameStatus.failed)
            _buildAside(
              context,
              'Le traitement s\'arrête ici : sans page repérée, il n\'y a rien '
              'à redresser.',
            ),
          if (_frameStatus != _FrameStatus.running) ...[
            const SizedBox(height: 16),
            _buildImageWithQuads(
              context,
              bytes: _original!,
              width: _originalWidth,
              height: _originalHeight,
              quads: page == null ? null : [page.corners],
              numbered: false,
              maxHeight: 300,
            ),
          ],
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _frameStatus == _FrameStatus.running ? null : _framePage,
            icon: const Icon(Icons.refresh),
            label: const Text('Refaire le cadrage'),
          ),
        ],
      ),
    );
  }

  // ── Étape 3 : recaler, puis redresser ─────────────────────────────────────

  Widget _buildStraightenStep(BuildContext context) {
    final theme = Theme.of(context);
    final page = _detectedPage;
    final snap = _snap;

    final (
      String status,
      IconData icon,
      Color color,
    ) = switch (_straightenStatus) {
      _StraightenStatus.running => (
        'Recalage du cadre sur le bord du papier…',
        Icons.hourglass_empty,
        theme.colorScheme.onSurfaceVariant,
      ),
      _StraightenStatus.straightened => (
        'Cadre recalé, puis page redressée par homographie.',
        Icons.straighten,
        theme.colorScheme.primary,
      ),
      _StraightenStatus.alreadyStraight => (
        'La page occupe déjà tout le cadre. Redresser n\'aurait rien '
            'changé, sinon adoucir les pixels.',
        Icons.check_circle_outline,
        theme.colorScheme.primary,
      ),
      _StraightenStatus.failed => (
        _straightenFailure ?? 'Redressement impossible.',
        Icons.error_outline,
        theme.colorScheme.error,
      ),
      _StraightenStatus.idle => (
        'En attente.',
        Icons.more_horiz,
        theme.disabledColor,
      ),
    };

    return ExperimentStep(
      index: 3,
      title: 'Recaler et redresser',
      subtitle:
          'Sans modèle : chaque côté glisse sur le bord réel du papier, puis '
          'l\'homographie met la page à plat.',
      done: _hasPage,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildEngines(context, const [
            SandboxEngine.local(
              stage: 'recalage',
              model: 'Sobel · moyenne signée × tenue',
            ),
            SandboxEngine.local(
              stage: 'redressement',
              model: 'homographie · warpIsolate',
            ),
          ]),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(status, style: theme.textTheme.bodyMedium)),
            ],
          ),
          if (snap != null)
            _buildAside(
              context,
              _snapSummary(snap),
              color: snap.applied ? theme.colorScheme.primary : null,
            ),
          if (_straightenStatus == _StraightenStatus.running) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (_snappedQuad != null) ...[
            const SizedBox(height: 16),
            Text(
              'Le cadre du modèle en blanc, le recalé en rouge',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            _buildImageWithQuads(
              context,
              bytes: _original!,
              width: _originalWidth,
              height: _originalHeight,
              quads: [_snappedQuad!],
              // Le cadre du modèle reste visible : c'est en voyant les deux
              // qu'on sait laquelle des deux étapes s'est trompée.
              secondaryQuads: page == null ? null : [page.corners],
              numbered: false,
              maxHeight: 300,
            ),
          ],
          if (_hasPage) ...[
            const SizedBox(height: 16),
            Text(
              _straightenStatus == _StraightenStatus.straightened
                  ? 'Page redressée'
                  : 'Page retenue',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            _buildImageWithQuads(
              context,
              bytes: _page!,
              width: _pageWidth,
              height: _pageHeight,
              maxHeight: 300,
            ),
            const SizedBox(height: 8),
            Text(
              '$_pageWidth × $_pageHeight px',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _straightenStatus == _StraightenStatus.running
                ? null
                : _snapAndStraighten,
            icon: const Icon(Icons.refresh),
            label: const Text('Refaire le recalage'),
          ),
        ],
      ),
    );
  }

  /// Ce qui a **réellement** fait le travail à cette étape.
  ///
  /// Relevé sur la réponse, jamais sur la configuration. Les deux diffèrent
  /// plus souvent qu'on ne croit : le repli automatique change de fournisseur
  /// en cours de route, et un poste sans choix explicite suit un défaut qu'on
  /// a oublié avoir posé. Afficher la configuration, ce serait afficher une
  /// intention, pas un fait.
  Widget _buildEngines(BuildContext context, List<SandboxEngine> engines) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: engines.isEmpty
            ? [
                _buildEngineChip(
                  context,
                  'Moteur inconnu — aucun appel abouti',
                  local: true,
                ),
              ]
            : [
                for (final engine in engines)
                  _buildEngineChip(
                    context,
                    engines.length > 1 || engine.isLocal
                        ? '${engine.stageLabel} · ${engine.model}'
                        : engine.model,
                    local: engine.isLocal,
                    fallback: engine.requested != null,
                    tooltip: engine.isLocal
                        ? 'Sur l\'appareil, sans réseau ni modèle'
                        : engine.requested != null
                        ? 'Repli : la politique demandait ${engine.requested}, '
                              'et c\'est ${engine.provider}/${engine.model} qui '
                              'a répondu. La raison est dans les journaux.'
                        : '${engine.providerLabel} — '
                              '${engine.provider}/${engine.model}',
                  ),
              ],
      ),
    );
  }

  Widget _buildEngineChip(
    BuildContext context,
    String label, {
    bool local = false,
    bool fallback = false,
    String? tooltip,
  }) {
    final theme = Theme.of(context);

    // Un repli se signale par la couleur : la pastille dit déjà quel moteur a
    // répondu, elle doit aussi dire que ce n'était pas celui demandé.
    final background = fallback
        ? theme.colorScheme.errorContainer
        : local
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.secondaryContainer;
    final foreground = fallback
        ? theme.colorScheme.onErrorContainer
        : local
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onSecondaryContainer;

    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            fallback
                ? Icons.swap_horiz
                : local
                ? Icons.handyman_outlined
                : Icons.auto_awesome,
            size: 14,
            color: foreground,
          ),
          const SizedBox(width: 6),
          Text(
            fallback ? '$label · repli' : label,
            style: theme.textTheme.labelMedium?.copyWith(color: foreground),
          ),
        ],
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
  }

  /// Une remarque en retrait, sous la ligne d'état.
  Widget _buildAside(BuildContext context, String text, {Color? color}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 28, top: 8),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: color ?? theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  // ── Étape 4 : détecter les zones ──────────────────────────────────────────

  Widget _buildDetectStep(BuildContext context) {
    final theme = Theme.of(context);
    final regions = _regions;

    return ExperimentStep(
      index: 4,
      title: 'Détecter les zones',
      subtitle:
          'Le modèle lit la page redressée et rend les quatre coins de chaque '
          'photo, dessin, schéma ou bloc manuscrit.',
      done: _hasRegions,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (regions != null) _buildEngines(context, _regionEngines),
          SandboxModelPicker(
            featureKey: _regionsFeature,
            value: _regionsModel,
            enabled: !_detecting,
            onChanged: (choice) => setState(() => _regionsModel = choice),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _detecting ? null : _detectRegions,
            icon: const Icon(Icons.search),
            label: Text(
              regions == null ? 'Détecter les zones' : 'Détecter à nouveau',
            ),
          ),
          if (_detecting) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (_detectMessage != null) ...[
            const SizedBox(height: 16),
            Text(
              _detectMessage!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          if (regions != null && regions.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildImageWithQuads(
              context,
              bytes: _page!,
              width: _pageWidth,
              height: _pageHeight,
              quads: regions.map((r) => r.corners).toList(growable: false),
              maxHeight: 440,
            ),
            const SizedBox(height: 12),
            Text(
              regions.length == 1
                  ? '1 zone détectée'
                  : '${regions.length} zones détectées',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            for (var index = 0; index < regions.length; index++)
              _buildRegionRow(context, index + 1, regions[index]),
          ],
        ],
      ),
    );
  }

  Widget _buildRegionRow(BuildContext context, int number, DetectedRegion r) {
    final theme = Theme.of(context);
    final bounds = r.bounds;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: SandboxQuadPainter.defaultColor,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$number',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.label.isEmpty
                      ? r.kind.label
                      : '${r.kind.label} — ${r.label}',
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  '${(bounds.width * 100).round()} % × '
                  '${(bounds.height * 100).round()} % de la page · '
                  'confiance ${(r.confidence * 100).round()} %',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Étape 5 : à écrire ────────────────────────────────────────────────────

  Widget _buildNextStep(BuildContext context) {
    final theme = Theme.of(context);

    return ExperimentStep(
      index: 5,
      title: 'Isoler les zones',
      subtitle: 'Ce que l\'on fera de chaque zone une fois repérée.',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 32),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'TO COME',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 2,
          ),
        ),
      ),
    );
  }

  // ── Une image, avec ou sans ses cadres ────────────────────────────────────

  /// L'image dans un cadre à son rapport exact.
  ///
  /// C'est ce qui fait tomber les cadres au bon endroit : le peintre reçoit une
  /// boîte qui est exactement celle de l'image, et ses coordonnées en fraction
  /// s'y appliquent sans correction.
  Widget _buildImageWithQuads(
    BuildContext context, {
    required Uint8List bytes,
    required int? width,
    required int? height,
    required double maxHeight,
    List<List<Offset>>? quads,
    List<List<Offset>>? secondaryQuads,
    bool numbered = true,
  }) {
    if (width == null || height == null || width <= 0 || height <= 0) {
      return Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Image.memory(bytes),
        ),
      );
    }

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: AspectRatio(
          aspectRatio: width / height,
          child: InkWell(
            onTap: () => _showFullScreen(
              bytes,
              width: width,
              height: height,
              quads: quads,
              secondaryQuads: secondaryQuads,
              numbered: numbered,
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(bytes, fit: BoxFit.fill),
                if (secondaryQuads != null && secondaryQuads.isNotEmpty)
                  CustomPaint(
                    painter: SandboxQuadPainter(
                      quads: secondaryQuads,
                      numbered: false,
                      color: SandboxQuadPainter.discardedColor,
                      strokeWidth: 2,
                    ),
                  ),
                if (quads != null && quads.isNotEmpty)
                  CustomPaint(
                    painter: SandboxQuadPainter(
                      quads: quads,
                      numbered: numbered,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showFullScreen(
    Uint8List bytes, {
    int? width,
    int? height,
    List<List<Offset>>? quads,
    List<List<Offset>>? secondaryQuads,
    bool numbered = true,
  }) {
    final hasQuads =
        (quads != null && quads.isNotEmpty) ||
        (secondaryQuads != null && secondaryQuads.isNotEmpty);
    final overlayReady = hasQuads && width != null && height != null;

    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 8,
                child: overlayReady
                    ? AspectRatio(
                        aspectRatio: width / height,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.memory(bytes, fit: BoxFit.fill),
                            if (secondaryQuads != null &&
                                secondaryQuads.isNotEmpty)
                              CustomPaint(
                                painter: SandboxQuadPainter(
                                  quads: secondaryQuads,
                                  numbered: false,
                                  color: SandboxQuadPainter.discardedColor,
                                  strokeWidth: 2,
                                ),
                              ),
                            if (quads != null && quads.isNotEmpty)
                              CustomPaint(
                                painter: SandboxQuadPainter(
                                  quads: quads,
                                  numbered: numbered,
                                ),
                              ),
                          ],
                        ),
                      )
                    : Image.memory(bytes),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                tooltip: 'Fermer',
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Chargement ────────────────────────────────────────────────────────────

  Future<void> _pickFile() async {
    setState(() {
      _busy = true;
      _sourceMessage = null;
    });
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (result == null) return;

      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null) {
        _fail('Fichier vide ou inaccessible.');
        return;
      }
      await _load(bytes, file.name, 'file_picker · FileType.image');
    } catch (error, stackTrace) {
      _errorReportService.reportError(
        feature: 'sandbox.imageImport.pickFile',
        error: error,
        stackTrace: stackTrace,
      );
      _fail('Impossible d\'ouvrir le fichier : $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _takePhoto() async {
    setState(() {
      _busy = true;
      _sourceMessage = null;
    });
    try {
      final photo = await _imagePicker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        imageQuality: 100,
      );
      if (photo == null) return;

      final bytes = await photo.readAsBytes();
      await _load(
        bytes,
        photo.name.isNotEmpty ? photo.name : 'photo.jpg',
        'image_picker · caméra arrière, qualité 100',
      );
    } catch (error, stackTrace) {
      _errorReportService.reportError(
        feature: 'sandbox.imageImport.takePhoto',
        error: error,
        stackTrace: stackTrace,
      );
      _fail('Impossible de prendre la photo : $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Remet l'image d'aplomb, l'installe, puis enchaîne sur le cadrage.
  ///
  /// L'orientation EXIF est appliquée dans les pixels dès l'import. Sans ça,
  /// Flutter affiche l'image debout pendant que le paquet `image` la décode
  /// couchée, et les coins rendus par le modèle s'appliquent au mauvais repère.
  Future<void> _load(Uint8List bytes, String filename, String tool) async {
    Uint8List upright = bytes;
    int? width;
    int? height;
    var rotated = false;
    try {
      final result = await compute(
        sandboxUprightIsolate,
        SandboxUprightParams(bytes: bytes),
      );
      upright = result.bytes;
      width = result.width;
      height = result.height;
      rotated = result.rotated;
    } catch (error, stackTrace) {
      _errorReportService.reportError(
        feature: 'sandbox.imageImport.upright',
        error: error,
        stackTrace: stackTrace,
        context: {'filename': filename, 'bytes': bytes.lengthInBytes},
      );
      final size = await _measure(bytes, filename);
      width = size?.width;
      height = size?.height;
    }

    if (!mounted) return;
    setState(() {
      _original = upright;
      _filename = filename;
      _originalWidth = width;
      _originalHeight = height;
      _sourceTool = tool;
      _uprightApplied = rotated;
      _sourceMessage = null;
      _resetFrame();
    });

    await _framePage();
  }

  /// Dimensions de l'image, `null` si elle ne se décode pas.
  ///
  /// L'image décodée est libérée aussitôt : on ne garde que ses deux nombres,
  /// pas le bitmap, qui pèse largeur × hauteur × 4 octets.
  Future<({int width, int height})?> _measure(
    Uint8List bytes,
    String filename,
  ) async {
    try {
      final ui.Image decoded = await decodeImageFromList(bytes);
      final size = (width: decoded.width, height: decoded.height);
      decoded.dispose();
      return size;
    } catch (error, stackTrace) {
      _errorReportService.reportError(
        feature: 'sandbox.imageImport.decode',
        error: error,
        stackTrace: stackTrace,
        context: {'filename': filename, 'bytes': bytes.lengthInBytes},
      );
      return null;
    }
  }

  // ── Étape 2 : le cadrage ──────────────────────────────────────────────────

  /// Demande au modèle où est la page, puis enchaîne sur le recalage.
  ///
  /// Un échec arrête tout : le reste de la chaîne suppose une page à plat.
  /// Continuer sur une image en trapèze produirait des cadres de travers, et
  /// ferait passer pour une faiblesse du modèle ce qui est un défaut d'entrée.
  Future<void> _framePage() async {
    final bytes = _original;
    if (bytes == null) return;

    setState(() {
      _frameStatus = _FrameStatus.running;
      _resetFrame();
    });

    DetectedPage? detected;
    try {
      final prepared = await compute(
        sandboxDownscaleIsolate,
        SandboxDownscaleParams(bytes: bytes, maxDimension: 2048),
      );

      final data = await _sandbox.call('image_import.detect_page', {
        'bytesBase64': base64Encode(prepared.bytes),
        'mimeType': 'image/jpeg',
        'widthPx': prepared.width,
        'heightPx': prepared.height,
        ..._modelPayload(_frameModel),
      });

      final raw = data['page'];
      if (raw is Map) {
        detected = DetectedPage.fromJson(Map<String, dynamic>.from(raw));
      }
    } catch (error, stackTrace) {
      _errorReportService.reportError(
        feature: 'sandbox.imageImport.detectPage',
        error: error,
        stackTrace: stackTrace,
        context: {'bytes': bytes.lengthInBytes},
      );
      if (!mounted) return;
      setState(() {
        _frameStatus = _FrameStatus.failed;
        _frameFailure = 'Cadrage impossible : $error';
      });
      return;
    }

    if (detected == null) {
      if (!mounted) return;
      setState(() {
        _frameStatus = _FrameStatus.failed;
        _frameFailure =
            'Aucune page reconnue dans cette photo. Vérifier que la page est '
            'entièrement visible et lisible.';
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _detectedPage = detected;
      _frameStatus = _FrameStatus.done;
    });

    await _snapAndStraighten();
  }

  // ── Étape 3 : recalage et redressement ────────────────────────────────────

  /// Resserre le cadre sur le bord réel du papier, puis met la page à plat.
  ///
  /// Se rejoue seul, sans redemander son cadrage au modèle : c'est ce qui rend
  /// l'étape réglable sans dépenser un appel à chaque essai.
  Future<void> _snapAndStraighten() async {
    final bytes = _original;
    final detected = _detectedPage;
    if (bytes == null || detected == null) return;

    setState(() {
      _straightenStatus = _StraightenStatus.running;
      _resetPage();
    });

    var cornersFlat = detected.cornersFlat;
    SandboxSnapResult? snap;
    try {
      final result = await compute(
        sandboxSnapQuadIsolate,
        SandboxSnapParams(bytes: bytes, cornersFlat: cornersFlat),
      );
      snap = result;
      if (result.applied) cornersFlat = result.cornersFlat;
    } catch (error, stackTrace) {
      // Le recalage est un confort : son échec laisse le cadre du modèle, il
      // n'arrête pas la chaîne. Mais il ne passe pas sous silence.
      _errorReportService.reportError(
        feature: 'sandbox.imageImport.snap',
        error: error,
        stackTrace: stackTrace,
      );
    }

    final snappedQuad = <Offset>[
      for (var i = 0; i < 4; i++)
        Offset(cornersFlat[i * 2], cornersFlat[i * 2 + 1]),
    ];

    Uint8List page = bytes;
    _StraightenStatus status;
    if (detected.isFullFrame) {
      status = _StraightenStatus.alreadyStraight;
    } else {
      try {
        page = await compute(
          warpIsolate,
          WarpParams(
            imageBytes: bytes,
            cornersFlat: cornersFlat,
            brightness: 1,
            contrast: 1,
            saturation: 1,
            sharpen: false,
          ),
        );
        status = _StraightenStatus.straightened;
      } catch (error, stackTrace) {
        _errorReportService.reportError(
          feature: 'sandbox.imageImport.warp',
          error: error,
          stackTrace: stackTrace,
          context: {'corners': cornersFlat.toString()},
        );
        if (!mounted) return;
        setState(() {
          _snappedQuad = snappedQuad;
          _snap = snap;
          _straightenStatus = _StraightenStatus.failed;
          _straightenFailure = 'Redressement impossible : $error';
        });
        return;
      }
    }

    final size = await _measure(page, _filename ?? 'page');

    if (!mounted) return;
    setState(() {
      _snappedQuad = snappedQuad;
      _snap = snap;
      _page = page;
      _pageWidth = size?.width;
      _pageHeight = size?.height;
      _straightenStatus = status;
    });
  }

  /// Ce qu'a donné le recalage, en une phrase.
  String _snapSummary(SandboxSnapResult snap) {
    if (snap.rejected != null) return snap.rejected!;
    if (snap.sidesSnapped == 0) {
      return 'Aucun bord assez franc pour recaler : le cadre du modèle est '
          'gardé tel quel.';
    }
    final shift = (snap.maxShift * 100).round();
    return 'Recalé sur le bord réel : ${snap.sidesSnapped} côté'
        '${snap.sidesSnapped > 1 ? 's' : ''} sur 4, le coin le plus déplacé a '
        'bougé de $shift % de la page.';
  }

  // ── Étape 4 : la détection ────────────────────────────────────────────────

  Future<void> _detectRegions() async {
    final page = _page;
    if (page == null) return;

    setState(() {
      _detecting = true;
      _detectMessage = null;
    });

    try {
      final prepared = await compute(
        sandboxDownscaleIsolate,
        SandboxDownscaleParams(bytes: page, maxDimension: 2048),
      );

      final data = await _sandbox.call('image_import.detect_regions', {
        'bytesBase64': base64Encode(prepared.bytes),
        'mimeType': 'image/jpeg',
        'widthPx': prepared.width,
        'heightPx': prepared.height,
        ..._modelPayload(_regionsModel),
      });

      final regions = <DetectedRegion>[];
      final raw = data['regions'];
      if (raw is List) {
        for (final entry in raw) {
          if (entry is! Map) continue;
          final region = DetectedRegion.fromJson(
            Map<String, dynamic>.from(entry),
          );
          if (region != null) regions.add(region);
        }
      }

      if (!mounted) return;
      setState(() {
        _regions = regions;
        _regionEngines = SandboxEngine.listFrom(data['engines']);
        _detectMessage = regions.isEmpty
            ? 'Aucune zone imagée trouvée sur cette page.'
            : null;
      });
    } catch (error, stackTrace) {
      _errorReportService.reportError(
        feature: 'sandbox.imageImport.detectRegions',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _detectMessage = 'Détection impossible : $error');
      }
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  // ── Remise à zéro ─────────────────────────────────────────────────────────

  /// Tout ce qui dépend du cadrage : donc tout, à partir de l'étape 2.
  void _resetFrame() {
    _detectedPage = null;
    _frameFailure = null;
    _resetPage();
  }

  /// Tout ce qui dépend du recalage, à partir de l'étape 3.
  void _resetPage() {
    _snappedQuad = null;
    _snap = null;
    _page = null;
    _pageWidth = null;
    _pageHeight = null;
    _straightenFailure = null;
    _straightenStatus = _StraightenStatus.idle;
    _regions = null;
    _regionEngines = const [];
    _detectMessage = null;
  }

  void _clear() {
    setState(() {
      _original = null;
      _filename = null;
      _originalWidth = null;
      _originalHeight = null;
      _sourceMessage = null;
      _frameStatus = _FrameStatus.idle;
      _resetFrame();
    });
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() => _sourceMessage = message);
  }
}

/// Le modèle choisi, ou rien du tout.
///
/// Rien du tout est un cas à part entière : le serveur suit alors la politique
/// de routage, exactement comme un poste de l'application.
Map<String, dynamic> _modelPayload(SandboxModelChoice? choice) => choice == null
    ? const {}
    : {'provider': choice.provider, 'model': choice.model};

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes o';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} Ko';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} Mo';
}
