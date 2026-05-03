import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// Écran réutilisable de recadrage et d'amélioration d'image.
///
/// Retourne via [Navigator.pop] les bytes JPEG de l'image améliorée,
/// ou `null` si l'utilisateur annule.
///
/// Usage :
/// ```dart
/// final result = await Navigator.of(context).push<Uint8List?>(
///   MaterialPageRoute(builder: (_) => ImageEnhancerScreen(imageBytes: bytes)),
/// );
/// ```
class ImageEnhancerScreen extends StatefulWidget {
  final Uint8List imageBytes;

  /// Titre affiché dans l'AppBar (ex. "Améliorer la couverture").
  final String title;

  const ImageEnhancerScreen({
    super.key,
    required this.imageBytes,
    this.title = 'Recadrer / améliorer',
  });

  @override
  State<ImageEnhancerScreen> createState() => _ImageEnhancerScreenState();
}

class _ImageEnhancerScreenState extends State<ImageEnhancerScreen> {
  final CropController _cropController = CropController();

  /// 0.5 = 50 % plus sombre · 1.0 = inchangé · 1.5 = 50 % plus lumineux.
  double _brightness = 1.0;
  bool _sharpen = false;
  bool _processing = false;

  // ── Actions ──────────────────────────────────────────────────────────────

  void _cancel() => Navigator.of(context).pop<Uint8List?>(null);

  Future<void> _confirm() async {
    setState(() => _processing = true);
    _cropController.crop();
  }

  Future<void> _onCropResult(CropResult result) async {
    if (result is CropFailure) {
      if (mounted) {
        setState(() => _processing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Erreur lors du recadrage.')),
        );
      }
      return;
    }

    Uint8List bytes = (result as CropSuccess).croppedImage;
    if (_brightness != 1.0 || _sharpen) {
      bytes = _applyAdjustments(bytes);
    }

    if (mounted) Navigator.of(context).pop<Uint8List?>(bytes);
  }

  /// Applique luminosité et/ou netteté sur les bytes JPEG fournis.
  Uint8List _applyAdjustments(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;

    img.Image result = decoded;

    if (_brightness != 1.0) {
      result = img.adjustColor(result, brightness: _brightness);
    }

    if (_sharpen) {
      // Kernel de renforcement de la netteté 3×3
      result = img.convolution(
        result,
        filter: [0, -1, 0, -1, 5, -1, 0, -1, 0],
        div: 1,
      );
    }

    return Uint8List.fromList(img.encodeJpg(result, quality: 92));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = ((_brightness - 1.0) * 100).round();
    final pctLabel = '${pct >= 0 ? '+' : ''}$pct%';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title),
        leadingWidth: 90,
        leading: TextButton(
          onPressed: _processing ? null : _cancel,
          child: const Text(
            'Annuler',
            style: TextStyle(color: Colors.white70),
          ),
        ),
        actions: [
          if (!_processing)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: _confirm,
                child: const Text('Confirmer'),
              ),
            ),
        ],
      ),
      body: _processing
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 16),
                  Text(
                    'Traitement en cours…',
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                // ── Zone de recadrage ─────────────────────────────────────
                Expanded(
                  child: Crop(
                    controller: _cropController,
                    image: widget.imageBytes,
                    onCropped: _onCropResult,
                    aspectRatio: null, // recadrage libre
                  ),
                ),

                // ── Contrôles luminosité / netteté ────────────────────────
                Container(
                  color: Colors.black87,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    children: [
                      // Luminosité
                      Row(
                        children: [
                          const Icon(
                            Icons.brightness_6_outlined,
                            color: Colors.white70,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Luminosité',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.white70,
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: _brightness,
                              min: 0.5,
                              max: 1.5,
                              divisions: 20,
                              onChanged: (v) =>
                                  setState(() => _brightness = v),
                            ),
                          ),
                          SizedBox(
                            width: 42,
                            child: Text(
                              pctLabel,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white54,
                              ),
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),

                      // Netteté
                      Row(
                        children: [
                          const Icon(
                            Icons.lens_blur_outlined,
                            color: Colors.white70,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Netteté',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.white70,
                            ),
                          ),
                          const Spacer(),
                          Switch(
                            value: _sharpen,
                            onChanged: (v) => setState(() => _sharpen = v),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
