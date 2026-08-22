import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/services/error_report_service.dart';
import '../../../../core/utils/platform_utils.dart';
import '../../../../core/widgets/readable_width.dart';
import '../widgets/experiment_step.dart';

/// Expérience : ce qu'on peut faire d'une image importée.
///
/// Tout reste en mémoire. Aucun envoi vers Storage, aucune écriture Firestore,
/// aucun appel d'IA : l'image quitte l'écran quand on le quitte.
///
/// L'écran progresse par étapes empilées. Chacune n'apparaît que si la
/// précédente a abouti, et se valide seule avant qu'on écrive la suivante.
class SandboxImageImportScreen extends StatefulWidget {
  const SandboxImageImportScreen({super.key});

  @override
  State<SandboxImageImportScreen> createState() =>
      _SandboxImageImportScreenState();
}

class _SandboxImageImportScreenState extends State<SandboxImageImportScreen> {
  final ImagePicker _imagePicker = ImagePicker();
  final ErrorReportService _errorReportService = ErrorReportService();

  Uint8List? _bytes;
  String? _filename;
  int? _width;
  int? _height;

  /// Une importation est en cours : les boutons se verrouillent ensemble.
  bool _busy = false;

  /// Message affiché à l'utilisateur. L'erreur elle-même part dans les
  /// rapports d'erreurs, comme partout ailleurs.
  String? _message;

  bool get _hasImage => _bytes != null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Importation d\'image')),
      body: ReadableWidth(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _buildSourceStep(context),
            if (_hasImage) _buildNextStep(context),
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
          if (_message != null) ...[
            const SizedBox(height: 16),
            Text(
              _message!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          if (_hasImage) ...[
            const SizedBox(height: 16),
            _buildPreview(context),
          ],
        ],
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final theme = Theme.of(context);
    final bytes = _bytes!;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // La vignette est un bouton : un tap ouvre l'image en grand.
        Tooltip(
          message: 'Voir en grand',
          child: InkWell(
            onTap: () => _showFullScreen(context),
            borderRadius: BorderRadius.circular(12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                bytes,
                width: 120,
                height: 120,
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
                _width != null && _height != null
                    ? '$_width × $_height px'
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
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => _showFullScreen(context),
                icon: const Icon(Icons.zoom_in),
                label: const Text('Voir en grand'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Étape 2 : à écrire ────────────────────────────────────────────────────

  Widget _buildNextStep(BuildContext context) {
    final theme = Theme.of(context);

    return ExperimentStep(
      index: 2,
      title: 'Étape suivante',
      subtitle: 'Ce que l\'on fera de l\'image une fois chargée.',
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

  // ── Plein écran ───────────────────────────────────────────────────────────

  void _showFullScreen(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return;

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
                child: Image.memory(bytes),
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
      _message = null;
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
      _message = null;
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

  /// Mesure l'image et l'installe dans l'état.
  ///
  /// L'image décodée est libérée aussitôt : on ne garde que ses deux nombres,
  /// pas le bitmap, qui pèse largeur × hauteur × 4 octets.
  Future<void> _load(Uint8List bytes, String filename) async {
    int? width;
    int? height;
    try {
      final ui.Image decoded = await decodeImageFromList(bytes);
      width = decoded.width;
      height = decoded.height;
      decoded.dispose();
    } catch (error, stackTrace) {
      // Les dimensions sont un confort d'affichage, pas la matière de
      // l'expérience : on garde l'image et on signale l'erreur.
      _errorReportService.reportError(
        feature: 'sandbox.imageImport.decode',
        error: error,
        stackTrace: stackTrace,
        context: {'filename': filename, 'bytes': bytes.lengthInBytes},
      );
    }

    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _filename = filename;
      _width = width;
      _height = height;
      _message = null;
    });
  }

  void _clear() {
    setState(() {
      _bytes = null;
      _filename = null;
      _width = null;
      _height = null;
      _message = null;
    });
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() => _message = message);
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes o';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} Ko';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} Mo';
}
