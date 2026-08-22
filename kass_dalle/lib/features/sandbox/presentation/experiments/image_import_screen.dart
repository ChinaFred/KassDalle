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
import '../../domain/detected_region.dart';
import '../widgets/experiment_step.dart';
import '../widgets/regions_overlay.dart';

/// Expérience : ce qu'on peut faire d'une image importée.
///
/// Rien n'est enregistré. L'image, la page redressée et les zones vivent en
/// mémoire, et disparaissent avec l'écran. Seule la détection des zones
/// consomme un appel de modèle, imputé au poste `sandbox_detect_regions`.
///
/// L'écran progresse par étapes empilées. Chacune n'apparaît que si la
/// précédente a abouti, et se valide seule avant qu'on écrive la suivante.
class SandboxImageImportScreen extends StatefulWidget {
  const SandboxImageImportScreen({super.key});

  @override
  State<SandboxImageImportScreen> createState() =>
      _SandboxImageImportScreenState();
}

/// Où en est le redressement de la page.
enum _PageStatus {
  /// Rien d'importé.
  idle,

  /// Coins cherchés, page en cours de redressement.
  running,

  /// Page redressée : les quatre coins trouvés n'étaient pas ceux de l'image.
  straightened,

  /// Les coins trouvés sont ceux de l'image — un scan à plat. Redresser
  /// n'aurait rien changé, et aurait coûté un rééchantillonnage.
  alreadyStraight,

  /// Aucun coin exploitable. On s'arrête là.
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

  // ── Étape 2 : la page redressée ───────────────────────────────────────────
  _PageStatus _pageStatus = _PageStatus.idle;
  Uint8List? _page;
  int? _pageWidth;
  int? _pageHeight;

  /// Les coins trouvés, en fraction de l'image d'origine.
  List<Offset>? _pageQuad;

  /// Laquelle des deux méthodes a abouti — « le fond » ou « les bords ».
  String _detectionMethod = '';

  /// Part de l'image couverte par le quadrilatère trouvé.
  double _coverage = 0;

  /// Pourquoi la détection a échoué, quand elle a échoué.
  String? _straightenFailure;

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
            if (_hasImage) _buildStraightenStep(context),
            // Étape 3 conditionnée à une page redressée, et non à une image
            // importée : sans redressement, le modèle lit une page en trapèze
            // et rend des cadres qui ne recouperont rien.
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

  // ── Étape 2 : redresser la page ───────────────────────────────────────────

  Widget _buildStraightenStep(BuildContext context) {
    final theme = Theme.of(context);
    final quad = _pageQuad;

    final (String status, IconData icon, Color color) = switch (_pageStatus) {
      _PageStatus.running => (
        'Recherche des quatre coins…',
        Icons.hourglass_empty,
        theme.colorScheme.onSurfaceVariant,
      ),
      _PageStatus.straightened => (
        'Page redressée — coins trouvés par $_detectionMethod, sur '
            '${(_coverage * 100).round()} % de l\'image.',
        Icons.crop_free,
        theme.colorScheme.primary,
      ),
      _PageStatus.alreadyStraight => (
        'Page déjà droite — coins trouvés par $_detectionMethod, et ce sont '
            'ceux de l\'image. Redresser n\'aurait rien changé, sinon adoucir '
            'les pixels.',
        Icons.check_circle_outline,
        theme.colorScheme.primary,
      ),
      _PageStatus.failed => (
        _straightenFailure ?? 'Coins introuvables.',
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
      title: 'Redresser la page',
      subtitle:
          'Automatique, et sans modèle : le fond d\'abord, les bords ensuite, '
          'puis une homographie pour la perspective.',
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
            const SizedBox(height: 12),
            _buildImageWithQuads(
              context,
              bytes: _original!,
              width: _originalWidth,
              height: _originalHeight,
              maxHeight: 260,
            ),
          ],
          if (quad != null && _pageStatus != _PageStatus.failed) ...[
            const SizedBox(height: 16),
            Text('Ce qui a été trouvé', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            _buildImageWithQuads(
              context,
              bytes: _original!,
              width: _originalWidth,
              height: _originalHeight,
              quads: [quad],
              numbered: false,
              maxHeight: 220,
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
              maxHeight: 260,
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
            onPressed: _pageStatus == _PageStatus.running ? null : _straighten,
            icon: const Icon(Icons.refresh),
            label: const Text('Refaire le redressement'),
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

  /// Mesure l'image, l'installe, puis enchaîne sur le redressement.
  Future<void> _load(Uint8List bytes, String filename) async {
    final size = await _measure(bytes, filename);

    if (!mounted) return;
    setState(() {
      _original = bytes;
      _filename = filename;
      _originalWidth = size?.width;
      _originalHeight = size?.height;
      _sourceMessage = null;
      _resetPage();
    });

    await _straighten();
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

  // ── Étape 2 : le redressement ─────────────────────────────────────────────

  /// Cherche les quatre coins de la page et corrige sa perspective.
  ///
  /// Un échec arrête tout : le reste de la chaîne suppose une page à plat.
  /// Continuer sur une image en trapèze produirait des cadres de travers, et
  /// ferait passer pour une faiblesse du modèle ce qui est un défaut d'entrée.
  Future<void> _straighten() async {
    final bytes = _original;
    if (bytes == null) return;

    setState(() {
      _pageStatus = _PageStatus.running;
      _page = null;
      _pageWidth = null;
      _pageHeight = null;
      _pageQuad = null;
      _detectionMethod = '';
      _coverage = 0;
      _straightenFailure = null;
      _regions = null;
      _detectMessage = null;
    });

    SandboxCornersResult corners;
    try {
      corners = await compute(
        sandboxDetectCornersIsolate,
        SandboxCornersParams(bytes: bytes),
      );
    } catch (error, stackTrace) {
      _errorReportService.reportError(
        feature: 'sandbox.imageImport.detectCorners',
        error: error,
        stackTrace: stackTrace,
        context: {'bytes': bytes.lengthInBytes},
      );
      if (!mounted) return;
      setState(() {
        _pageStatus = _PageStatus.failed;
        _straightenFailure = 'Détection des coins impossible : $error';
      });
      return;
    }

    final cornersFlat = corners.cornersFlat;
    if (cornersFlat == null) {
      if (!mounted) return;
      setState(() {
        _pageStatus = _PageStatus.failed;
        _straightenFailure = corners.failure ?? 'Coins introuvables.';
      });
      return;
    }

    final quad = <Offset>[
      for (var i = 0; i < 4; i++)
        Offset(cornersFlat[i * 2], cornersFlat[i * 2 + 1]),
    ];

    Uint8List page = bytes;
    _PageStatus status;
    if (_isNearlyFullFrame(cornersFlat)) {
      status = _PageStatus.alreadyStraight;
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
        status = _PageStatus.straightened;
      } catch (error, stackTrace) {
        _errorReportService.reportError(
          feature: 'sandbox.imageImport.warp',
          error: error,
          stackTrace: stackTrace,
          context: {'corners': cornersFlat.toString()},
        );
        if (!mounted) return;
        setState(() {
          _pageQuad = quad;
          _detectionMethod = corners.method;
          _coverage = corners.coverage;
          _pageStatus = _PageStatus.failed;
          _straightenFailure = 'Redressement impossible : $error';
        });
        return;
      }
    }

    final size = await _measure(page, _filename ?? 'page');

    if (!mounted) return;
    setState(() {
      _page = page;
      _pageWidth = size?.width;
      _pageHeight = size?.height;
      _pageQuad = quad;
      _detectionMethod = corners.method;
      _coverage = corners.coverage;
      _pageStatus = status;
    });
  }

  /// Les quatre coins trouvés sont-ils ceux de l'image ?
  ///
  /// Sur un scan à plat, la détection rend le cadre entier. Redresser
  /// reviendrait alors à rééchantillonner chaque pixel pour rien — et un
  /// rééchantillonnage coûte de la netteté.
  bool _isNearlyFullFrame(List<double> cornersFlat) {
    const tolerance = 0.015;
    const expected = [0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0];
    for (var i = 0; i < expected.length; i++) {
      if ((cornersFlat[i] - expected[i]).abs() > tolerance) return false;
    }
    return true;
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
    _page = null;
    _pageWidth = null;
    _pageHeight = null;
    _pageQuad = null;
    _detectionMethod = '';
    _coverage = 0;
    _straightenFailure = null;
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
