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
import '../../domain/detected_page.dart';
import '../../domain/detected_region.dart';
import '../widgets/experiment_step.dart';
import '../widgets/regions_overlay.dart';

/// Expérience : ce qu'on peut faire d'une image importée.
///
/// Rien n'est enregistré. L'image, la page redressée et les zones vivent en
/// mémoire, et disparaissent avec l'écran.
///
/// Deux appels de modèle, imputés aux postes `sandbox_detect_page` et
/// `sandbox_detect_regions`. Le premier a d'abord été tenté sans modèle, par
/// deux méthodes successives, et les deux ont rendu la serviette posée sous le
/// livre plutôt que le livre : voir l'en-tête de `sandbox_image_ops.dart`.
///
/// L'écran progresse par étapes empilées. Chacune n'apparaît que si la
/// précédente a abouti, et se valide seule avant qu'on écrive la suivante.
class SandboxImageImportScreen extends StatefulWidget {
  const SandboxImageImportScreen({super.key});

  @override
  State<SandboxImageImportScreen> createState() =>
      _SandboxImageImportScreenState();
}

/// Où en est le cadrage de la page.
enum _PageStatus {
  /// Rien d'importé.
  idle,

  /// Le modèle cherche la page.
  running,

  /// Page cadrée et redressée.
  straightened,

  /// La page occupe déjà tout le cadre — un scan à plat. Redresser n'aurait
  /// rien changé, et aurait coûté un rééchantillonnage.
  alreadyStraight,

  /// Aucune page exploitable. On s'arrête là.
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

  // ── Étape 2 : la page cadrée puis redressée ───────────────────────────────
  _PageStatus _pageStatus = _PageStatus.idle;
  DetectedPage? _detectedPage;
  Uint8List? _page;
  int? _pageWidth;
  int? _pageHeight;

  /// Pourquoi le cadrage a échoué, quand il a échoué.
  String? _pageFailure;

  // ── Étape 3 : les zones détectées ─────────────────────────────────────────
  List<DetectedRegion>? _regions;
  bool _detecting = false;
  String? _detectMessage;

  bool get _hasImage => _original != null;
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
            if (_hasImage) _buildPageStep(context),
            // Étape 3 conditionnée à une page redressée, et non à une image
            // importée : sans redressement, le modèle lirait une page en
            // trapèze et rendrait des cadres qui ne recouperaient rien.
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

  // ── Étape 2 : cadrer la page, puis la redresser ───────────────────────────

  Widget _buildPageStep(BuildContext context) {
    final theme = Theme.of(context);
    final page = _detectedPage;

    final (String status, IconData icon, Color color) = switch (_pageStatus) {
      _PageStatus.running => (
        'Le modèle cherche la page…',
        Icons.hourglass_empty,
        theme.colorScheme.onSurfaceVariant,
      ),
      _PageStatus.straightened => (
        '${page?.kind.label ?? 'Page'} cadrée sur '
            '${(page == null ? 0 : page.coverage * 100).round()} % de l\'image, '
            'puis redressée.',
        Icons.crop_free,
        theme.colorScheme.primary,
      ),
      _PageStatus.alreadyStraight => (
        '${page?.kind.label ?? 'Page'} occupant déjà tout le cadre. Redresser '
            'n\'aurait rien changé, sinon adoucir les pixels.',
        Icons.check_circle_outline,
        theme.colorScheme.primary,
      ),
      _PageStatus.failed => (
        _pageFailure ?? 'Aucune page trouvée.',
        Icons.error_outline,
        theme.colorScheme.error,
      ),
      _PageStatus.idle => (
        'En attente.',
        Icons.more_horiz,
        theme.disabledColor,
      ),
    };

    return ExperimentStep(
      index: 2,
      title: 'Cadrer et redresser la page',
      subtitle:
          'Le modèle dit où commence et où s\'arrête la page — pas le bureau, '
          'pas la serviette dessous. Le programme applique l\'homographie.',
      done: _hasPage,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(status, style: theme.textTheme.bodyMedium)),
            ],
          ),
          if (page != null && page.note.isNotEmpty) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: Text(
                '« ${page.note} » — confiance '
                '${(page.confidence * 100).round()} %',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          if (_pageStatus == _PageStatus.running) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (_pageStatus == _PageStatus.failed) ...[
            const SizedBox(height: 12),
            Text(
              'Le traitement s\'arrête ici : sans page à plat, la détection '
              'des zones travaillerait sur un trapèze et rendrait des cadres '
              'inexploitables.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (_pageStatus != _PageStatus.running) ...[
            const SizedBox(height: 16),
            Text(
              page == null ? 'Ce que le modèle a lu' : 'Le cadrage rendu',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
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
          if (_hasPage) ...[
            const SizedBox(height: 16),
            Text(
              _pageStatus == _PageStatus.straightened
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
            onPressed: _pageStatus == _PageStatus.running ? null : _framePage,
            icon: const Icon(Icons.refresh),
            label: const Text('Refaire le cadrage'),
          ),
        ],
      ),
    );
  }

  // ── Étape 3 : détecter les zones ──────────────────────────────────────────

  Widget _buildDetectStep(BuildContext context) {
    final theme = Theme.of(context);
    final regions = _regions;

    return ExperimentStep(
      index: 3,
      title: 'Détecter les zones',
      subtitle:
          'Le modèle lit la page redressée et rend les quatre coins de chaque '
          'photo, dessin, schéma ou bloc manuscrit.',
      done: _hasRegions,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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

  // ── Étape 4 : à écrire ────────────────────────────────────────────────────

  Widget _buildNextStep(BuildContext context) {
    final theme = Theme.of(context);

    return ExperimentStep(
      index: 4,
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
  /// C'est ce qui fait tomber les cadres rouges au bon endroit : le peintre
  /// reçoit une boîte qui est exactement celle de l'image, et ses coordonnées
  /// en fraction s'y appliquent sans correction.
  Widget _buildImageWithQuads(
    BuildContext context, {
    required Uint8List bytes,
    required int? width,
    required int? height,
    required double maxHeight,
    List<List<Offset>>? quads,
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
              numbered: numbered,
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(bytes, fit: BoxFit.fill),
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
    bool numbered = true,
  }) {
    final overlayReady =
        quads != null && quads.isNotEmpty && width != null && height != null;

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
      await _load(bytes, file.name);
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
      await _load(bytes, photo.name.isNotEmpty ? photo.name : 'photo.jpg');
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
  Future<void> _load(Uint8List bytes, String filename) async {
    Uint8List upright = bytes;
    int? width;
    int? height;
    try {
      final result = await compute(
        sandboxUprightIsolate,
        SandboxUprightParams(bytes: bytes),
      );
      upright = result.bytes;
      width = result.width;
      height = result.height;
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
      _sourceMessage = null;
      _resetPage();
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

  // ── Étape 2 : cadrage puis redressement ───────────────────────────────────

  /// Demande au modèle où est la page, puis corrige sa perspective.
  ///
  /// Un échec arrête tout : le reste de la chaîne suppose une page à plat.
  /// Continuer sur une image en trapèze produirait des cadres de travers, et
  /// ferait passer pour une faiblesse du modèle ce qui est un défaut d'entrée.
  Future<void> _framePage() async {
    final bytes = _original;
    if (bytes == null) return;

    setState(() {
      _pageStatus = _PageStatus.running;
      _detectedPage = null;
      _page = null;
      _pageWidth = null;
      _pageHeight = null;
      _pageFailure = null;
      _regions = null;
      _detectMessage = null;
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
        _pageStatus = _PageStatus.failed;
        _pageFailure = 'Cadrage impossible : $error';
      });
      return;
    }

    if (detected == null) {
      if (!mounted) return;
      setState(() {
        _pageStatus = _PageStatus.failed;
        _pageFailure =
            'Aucune page reconnue dans cette photo. Vérifier que la page est '
            'entièrement visible et lisible.';
      });
      return;
    }

    Uint8List page = bytes;
    _PageStatus status;
    if (detected.isFullFrame) {
      status = _PageStatus.alreadyStraight;
    } else {
      try {
        page = await compute(
          warpIsolate,
          WarpParams(
            imageBytes: bytes,
            cornersFlat: detected.cornersFlat,
            brightness: 1,
            contrast: 1,
            saturation: 1,
            sharpen: false,
          ),
        );
        status = _PageStatus.straightened;
      } catch (error, stackTrace) {
        _errorReportService.reportError(
          feature: 'sandbox.imageImport.warp',
          error: error,
          stackTrace: stackTrace,
          context: {'corners': detected.cornersFlat.toString()},
        );
        if (!mounted) return;
        setState(() {
          _detectedPage = detected;
          _pageStatus = _PageStatus.failed;
          _pageFailure = 'Redressement impossible : $error';
        });
        return;
      }
    }

    final size = await _measure(page, _filename ?? 'page');

    if (!mounted) return;
    setState(() {
      _detectedPage = detected;
      _page = page;
      _pageWidth = size?.width;
      _pageHeight = size?.height;
      _pageStatus = status;
    });
  }

  // ── Étape 3 : la détection ────────────────────────────────────────────────

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

  void _resetPage() {
    _detectedPage = null;
    _page = null;
    _pageWidth = null;
    _pageHeight = null;
    _pageFailure = null;
    _pageStatus = _PageStatus.idle;
    _regions = null;
    _detectMessage = null;
  }

  void _clear() {
    setState(() {
      _original = null;
      _filename = null;
      _originalWidth = null;
      _originalHeight = null;
      _sourceMessage = null;
      _resetPage();
    });
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() => _sourceMessage = message);
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes o';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} Ko';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} Mo';
}
