import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'cooklang_block_model.dart';
import 'cooklang_editor_colors.dart';
import '../../../../core/services/error_reporting.dart';

class CooklangImageInsertSheet extends StatefulWidget {
  final List<String> illustrationUrls;
  final Future<String?> Function(Uint8List bytes, String fileName)?
  onUploadImage;
  final void Function(String raw) onInsert;
  const CooklangImageInsertSheet({super.key, 
    required this.illustrationUrls,
    required this.onInsert,
    this.onUploadImage,
  });

  @override
  State<CooklangImageInsertSheet> createState() =>
      _CooklangImageInsertSheetState();
}

class _CooklangImageInsertSheetState extends State<CooklangImageInsertSheet> {
  ImagePosition _position = ImagePosition.after;
  String? _selectedUrl;
  bool _uploading = false;
  int _widthPercent = 30;

  void _confirm() {
    final url = _selectedUrl;
    if (url == null || url.isEmpty) return;
    final isFloat =
        _position == ImagePosition.left || _position == ImagePosition.right;
    final widthPart = isFloat ? '|$_widthPercent' : '';
    final raw = '![${_position.name}$widthPart]($url)';
    Navigator.pop(context);
    widget.onInsert(raw);
  }

  Future<void> _pickFromGallery() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (picked == null) return;
    if (widget.onUploadImage == null) return;
    setState(() => _uploading = true);
    try {
      final bytes = await picked.readAsBytes();
      final fileName = picked.name.isNotEmpty ? picked.name : 'image.jpg';
      final url = await widget.onUploadImage!(bytes, fileName);
      if (url != null && mounted) {
        setState(() {
          _selectedUrl = url;
          _uploading = false;
        });
      } else if (mounted) {
        setState(() => _uploading = false);
      }
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'cooklangInsertSheets.pickFromGallery',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.image_outlined, color: kCooklangImageColor),
              const SizedBox(width: 8),
              Text(
                'Insérer une image',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: kCooklangImageColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Photos de la recette
          if (widget.illustrationUrls.isNotEmpty) ...[
            Text(
              'Photos de la recette',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 80,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: widget.illustrationUrls.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final url = widget.illustrationUrls[i];
                  final selected = _selectedUrl == url;
                  return GestureDetector(
                    onTap: () => setState(() {
                      _selectedUrl = selected ? null : url;
                    }),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: selected
                              ? kCooklangImageColor
                              : Colors.transparent,
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.network(
                          url,
                          width: 80,
                          height: 80,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            width: 80,
                            height: 80,
                            color: Colors.grey.shade200,
                            child: const Icon(Icons.broken_image_outlined),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
          ],
          // Bouton galerie
          if (widget.onUploadImage != null) ...[
            Text(
              'Depuis la galerie',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 8),
            if (_uploading)
              const SizedBox(
                height: 44,
                child: Center(child: CircularProgressIndicator()),
              )
            else
              OutlinedButton.icon(
                onPressed: _pickFromGallery,
                icon: const Icon(Icons.photo_library_outlined),
                label:
                    _selectedUrl != null &&
                        !widget.illustrationUrls.contains(_selectedUrl)
                    ? const Text('Photo sélectionnée ✓')
                    : const Text('Choisir une photo'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: kCooklangImageColor,
                  side: const BorderSide(color: kCooklangImageColor),
                ),
              ),
            const SizedBox(height: 16),
          ],
          // Position
          Text('Position', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 8),
          SegmentedButton<ImagePosition>(
            segments: const [
              ButtonSegment(value: ImagePosition.left, label: Text('← Gauche')),
              ButtonSegment(value: ImagePosition.after, label: Text('↓ Après')),
              ButtonSegment(
                value: ImagePosition.right,
                label: Text('Droite →'),
              ),
            ],
            selected: {_position},
            onSelectionChanged: (s) => setState(() => _position = s.first),
            style: SegmentedButton.styleFrom(
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
          // Largeur (uniquement pour gauche/droite)
          if (_position == ImagePosition.left ||
              _position == ImagePosition.right) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "Largeur de l'image",
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                Text(
                  '$_widthPercent%',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: kCooklangImageColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            Slider(
              value: _widthPercent.toDouble(),
              min: 5,
              max: 60,
              divisions: 11,
              activeColor: kCooklangImageColor,
              label: '$_widthPercent%',
              onChanged: (v) => setState(() => _widthPercent = v.round()),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Annuler'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: (_selectedUrl != null && _selectedUrl!.isNotEmpty)
                    ? _confirm
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: kCooklangImageColor,
                ),
                child: const Text('Insérer'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Legacy insert sheets ───────────────────────────────────────────────────────

class CooklangIngredientInsertSheet extends StatefulWidget {
  const CooklangIngredientInsertSheet({super.key});

  @override
  State<CooklangIngredientInsertSheet> createState() =>
      _CooklangIngredientInsertSheetState();
}

class _CooklangIngredientInsertSheetState
    extends State<CooklangIngredientInsertSheet> {
  final _name = TextEditingController();
  final _qty = TextEditingController();
  final _unit = TextEditingController();

  void _confirm(BuildContext context) {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final seg = IngredientSegment(
      name: name,
      qty: _qty.text.trim(),
      unit: _unit.text.trim(),
      raw: IngredientSegment.buildRaw(
        name,
        _qty.text.trim(),
        _unit.text.trim(),
      ),
    );
    Navigator.pop(context, seg);
  }

  @override
  void dispose() {
    _name.dispose();
    _qty.dispose();
    _unit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.eco_outlined, color: kCooklangIngredientColor),
              const SizedBox(width: 8),
              Text(
                'Ajouter un ingrédient',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: kCooklangIngredientColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Nom *',
              hintText: 'ex: farine',
              border: OutlineInputBorder(),
              prefixText: '@',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _qty,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Quantité',
                    hintText: '250',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _unit,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _confirm(context),
                  decoration: const InputDecoration(
                    labelText: 'Unité',
                    hintText: 'g, ml…',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Annuler'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _confirm(context),
                style: FilledButton.styleFrom(
                  backgroundColor: kCooklangIngredientColor,
                ),
                child: const Text('Insérer'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class CooklangTimerInsertSheet extends StatefulWidget {
  const CooklangTimerInsertSheet({super.key});

  @override
  State<CooklangTimerInsertSheet> createState() =>
      _CooklangTimerInsertSheetState();
}

class _CooklangTimerInsertSheetState extends State<CooklangTimerInsertSheet> {
  final _name = TextEditingController();
  final _qty = TextEditingController();
  String _unit = 'minutes';

  void _confirm(BuildContext context) {
    final qty = _qty.text.trim();
    if (qty.isEmpty) return;
    final seg = TimerSegment(
      name: _name.text.trim(),
      qty: qty,
      unit: _unit,
      raw: TimerSegment.buildRaw(_name.text.trim(), qty, _unit),
    );
    Navigator.pop(context, seg);
  }

  @override
  void dispose() {
    _name.dispose();
    _qty.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.timer_outlined, color: kCooklangTimerColor),
              const SizedBox(width: 8),
              Text(
                'Ajouter un minuteur',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: kCooklangTimerColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Nom (optionnel)',
              hintText: 'ex: repos, pétrissage…',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _qty,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _confirm(context),
                  decoration: const InputDecoration(
                    labelText: 'Durée *',
                    hintText: '30',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _unit,
                  decoration: const InputDecoration(
                    labelText: 'Unité',
                    border: OutlineInputBorder(),
                  ),
                  items: const ['secondes', 'minutes', 'heures']
                      .map((u) => DropdownMenuItem(value: u, child: Text(u)))
                      .toList(),
                  onChanged: (v) => setState(() => _unit = v ?? 'minutes'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Annuler'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _confirm(context),
                style: FilledButton.styleFrom(
                  backgroundColor: kCooklangTimerColor,
                ),
                child: const Text('Insérer'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Toolbar button ─────────────────────────────────────────────────────────────
