import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:markdown/markdown.dart' as md;
import 'cooklang_block_model.dart';
import 'markdown_visual_editor.dart';

// ══════════════════════════════════════════════════════════════════════════════
// MarkdownEditor
// ══════════════════════════════════════════════════════════════════════════════

/// Éditeur Markdown riche pour les pages non-recette.
///
/// Fournit :
/// - Un basculeur Éditeur ↔ Aperçu (comme [HybridRecipeEditor])
/// - Une barre d'outils de mise en forme (H1, H2, H3, B, I, listes, citation,
///   code, image)
/// - Un champ de texte brut Markdown
/// - Un aperçu rendu par [Markdown] (flutter_markdown_plus)
/// - L'insertion d'images depuis la galerie ou parmi les photos déjà attachées
class MarkdownEditor extends StatefulWidget {
  /// Contrôleur source-de-vérité (même convention que [HybridRecipeEditor]).
  final TextEditingController ctrl;

  /// Active ou désactive la saisie (identique au paramètre `enabled`
  /// de [HybridRecipeEditor]).
  final bool enabled;

  /// URLs des illustrations déjà attachées à la page — affichées dans le
  /// sélecteur d'images pour insertion rapide.
  final List<String> illustrationUrls;

  /// Callback pour uploader une image depuis la galerie → retourne l'URL
  /// publique Firebase Storage.
  final Future<String?> Function(Uint8List bytes, String fileName)?
  onUploadImage;

  const MarkdownEditor({
    super.key,
    required this.ctrl,
    this.enabled = true,
    this.illustrationUrls = const [],
    this.onUploadImage,
  });

  @override
  State<MarkdownEditor> createState() => _MarkdownEditorState();
}

enum _MdMode { visual, text, preview }

class _MarkdownEditorState extends State<MarkdownEditor> {
  _MdMode _mode = _MdMode.visual;
  final FocusNode _focusNode = FocusNode();
  final MdVisualEditorController _visualCtrl = MdVisualEditorController();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  // ── Helpers d'insertion ────────────────────────────────────────────────────

  /// Insère [before] (+ [after] si fourni) autour de la sélection
  /// ou à la position du curseur.
  void _wrapSelection(String before, {String after = ''}) {
    final ctrl = widget.ctrl;
    final sel = ctrl.selection;
    final text = ctrl.text;

    if (!sel.isValid || sel.isCollapsed) {
      // Pas de sélection : insère `before + placeholder + after`
      final placeholder = after.isNotEmpty ? 'texte' : '';
      final insertion = before + placeholder + after;
      final pos = sel.isValid ? sel.start : text.length;
      final newText = text.substring(0, pos) + insertion + text.substring(pos);
      ctrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: pos + before.length,
          extentOffset: pos + before.length + placeholder.length,
        ),
      );
    } else {
      // Sélection : entoure le texte sélectionné
      final selected = text.substring(sel.start, sel.end);
      final suffix = after.isNotEmpty ? after : before;
      final newText =
          text.substring(0, sel.start) +
          before +
          selected +
          suffix +
          text.substring(sel.end);
      ctrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: sel.start + before.length,
          extentOffset: sel.start + before.length + selected.length,
        ),
      );
    }
    _focusNode.requestFocus();
  }

  /// Ajoute un préfixe [prefix] au début de la ligne courante.
  void _prependToLine(String prefix) {
    final ctrl = widget.ctrl;
    final text = ctrl.text;
    final sel = ctrl.selection;
    final pos = sel.isValid ? sel.start : text.length;
    final lineStart = text.lastIndexOf('\n', pos > 0 ? pos - 1 : 0) + 1;
    final newText =
        text.substring(0, lineStart) + prefix + text.substring(lineStart);
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: pos + prefix.length),
    );
    _focusNode.requestFocus();
  }

  /// Ouvre le sélecteur d'images Markdown.
  void _showImageSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _MdImageInsertSheet(
        illustrationUrls: widget.illustrationUrls,
        onUploadImage: widget.onUploadImage,
        onInsert: (raw) {
          final ctrl = widget.ctrl;
          final sel = ctrl.selection;
          final text = ctrl.text;
          final pos = sel.isValid ? sel.start : text.length;
          final newText = text.substring(0, pos) + raw + text.substring(pos);
          ctrl.value = TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(offset: pos + raw.length),
          );
        },
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        Expanded(
          child: switch (_mode) {
            _MdMode.visual => _buildVisualMode(context),
            _MdMode.text => _buildTextMode(context),
            _MdMode.preview => _MarkdownPreview(ctrl: widget.ctrl),
          },
        ),
      ],
    );
  }

  // ── Header (toggle icônes) ──────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    Widget modeBtn(IconData icon, String tip, _MdMode m) {
      final selected = _mode == m;
      return Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _mode = m),
          child: Container(
            width: 32,
            height: 32,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: selected ? cs.primaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              size: 17,
              color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          const Spacer(),
          modeBtn(Icons.view_agenda_outlined, 'Visuel', _MdMode.visual),
          modeBtn(Icons.code, 'Texte brut', _MdMode.text),
          modeBtn(Icons.visibility_outlined, 'Aperçu', _MdMode.preview),
        ],
      ),
    );
  }

  // ── Toolbar partagée ─────────────────────────────────────────────────────────

  Widget _buildToolbar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            _MdTextButton(
              text: 'H1',
              tooltip: 'Titre 1  (# …)',
              onTap: () => _prependToLine('# '),
            ),
            _MdTextButton(
              text: 'H2',
              tooltip: 'Titre 2  (## …)',
              onTap: () => _prependToLine('## '),
            ),
            _MdTextButton(
              text: 'H3',
              tooltip: 'Titre 3  (### …)',
              onTap: () => _prependToLine('### '),
            ),
            _MdToolbarDivider(),
            _MdIconButton(
              icon: Icons.format_bold,
              tooltip: 'Gras  (**texte**)',
              onTap: () => _wrapSelection('**', after: '**'),
            ),
            _MdIconButton(
              icon: Icons.format_italic,
              tooltip: 'Italique  (*texte*)',
              onTap: () => _wrapSelection('*', after: '*'),
            ),
            _MdTextButton(
              text: 'U',
              tooltip: 'Souligné  (<u>texte</u>)',
              textDecoration: TextDecoration.underline,
              onTap: () => _wrapSelection('<u>', after: '</u>'),
            ),
            _MdToolbarDivider(),
            _MdIconButton(
              icon: Icons.format_list_bulleted,
              tooltip: 'Liste à puces  (- …)',
              onTap: () => _prependToLine('- '),
            ),
            _MdIconButton(
              icon: Icons.format_list_numbered,
              tooltip: 'Liste numérotée  (1. …)',
              onTap: () => _prependToLine('1. '),
            ),
            _MdIconButton(
              icon: Icons.format_quote,
              tooltip: 'Citation  (> …)',
              onTap: () => _prependToLine('> '),
            ),
            _MdIconButton(
              icon: Icons.code_outlined,
              tooltip: 'Code en ligne  (`texte`)',
              onTap: () => _wrapSelection('`', after: '`'),
            ),
            _MdToolbarDivider(),
            _MdIconButton(
              icon: Icons.image_outlined,
              tooltip: 'Insérer une image',
              onTap: _showImageSheet,
              color: const Color(0xFF0288D1),
            ),
          ],
        ),
      ),
    );
  }

  // ── Champ texte brut (réutilisé dans visuel et texte) ────────────────────────

  Widget _buildEditorField() {
    return TextField(
      controller: widget.ctrl,
      focusNode: _focusNode,
      enabled: widget.enabled,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 13,
        height: 1.5,
        color: Colors.black87,
      ),
      decoration: const InputDecoration(
        border: OutlineInputBorder(borderRadius: BorderRadius.zero),
        contentPadding: EdgeInsets.all(12),
        fillColor: Colors.white,
        filled: true,
        hintText:
            '# Titre de la section\n\n'
            'Écris ton contenu ici en Markdown…\n\n'
            '**gras**, *italique*, `code`\n\n'
            '- élément de liste',
      ),
    );
  }

  /// En mode visuel, les boutons de la toolbar opèrent sur la ligne
  /// actuellement éditée (si disponible) ou ajoutent un nouveau bloc en fin
  /// de document.
  void _appendNewBlockLine(String lineContent) {
    final ctrl = widget.ctrl;
    final text = ctrl.text;
    final newText = text.isEmpty
        ? lineContent
        : (text.endsWith('\n') ? '$text$lineContent' : '$text\n$lineContent');
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
  }

  /// Applique un préfixe : si un bloc est en édition inline → y opère ;
  /// sinon → appende un nouveau bloc en fin.
  void _visualPrepend(String prefix) {
    if (_visualCtrl.hasActiveEdit) {
      _visualCtrl.prependToInlineLine(prefix);
    } else {
      _appendNewBlockLine(prefix);
    }
  }

  /// Applique un wrap (bold/italic/code) : si un bloc est en édition inline
  /// → y opère ; sinon → appende un nouveau bloc avec placeholder.
  void _visualWrap(
    String before, {
    String after = '',
    String placeholder = '',
  }) {
    if (_visualCtrl.hasActiveEdit) {
      _visualCtrl.wrapAtInlineCursor(before, after: after);
    } else {
      final content = placeholder.isNotEmpty
          ? '$before$placeholder${after.isNotEmpty ? after : before}'
          : before;
      _appendNewBlockLine(content);
    }
  }

  Widget _buildVisualMode(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.enabled)
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  _MdTextButton(
                    text: 'H1',
                    tooltip: 'Titre 1  (# …)',
                    onTap: () => _visualPrepend('# '),
                  ),
                  _MdTextButton(
                    text: 'H2',
                    tooltip: 'Titre 2  (## …)',
                    onTap: () => _visualPrepend('## '),
                  ),
                  _MdTextButton(
                    text: 'H3',
                    tooltip: 'Titre 3  (### …)',
                    onTap: () => _visualPrepend('### '),
                  ),
                  _MdToolbarDivider(),
                  _MdIconButton(
                    icon: Icons.format_bold,
                    tooltip: 'Gras  (**texte**)',
                    onTap: () =>
                        _visualWrap('**', after: '**', placeholder: 'gras'),
                  ),
                  _MdIconButton(
                    icon: Icons.format_italic,
                    tooltip: 'Italique  (*texte*)',
                    onTap: () =>
                        _visualWrap('*', after: '*', placeholder: 'italique'),
                  ),
                  _MdTextButton(
                    text: 'U',
                    tooltip: 'Souligné  (<u>texte</u>)',
                    textDecoration: TextDecoration.underline,
                    onTap: () => _visualWrap(
                      '<u>',
                      after: '</u>',
                      placeholder: 'souligné',
                    ),
                  ),
                  _MdToolbarDivider(),
                  _MdIconButton(
                    icon: Icons.format_list_bulleted,
                    tooltip: 'Liste à puces  (- …)',
                    onTap: () => _visualPrepend('- '),
                  ),
                  _MdIconButton(
                    icon: Icons.format_list_numbered,
                    tooltip: 'Liste numérotée  (1. …)',
                    onTap: () => _visualPrepend('1. '),
                  ),
                  _MdIconButton(
                    icon: Icons.format_quote,
                    tooltip: 'Citation  (> …)',
                    onTap: () => _visualPrepend('> '),
                  ),
                  _MdIconButton(
                    icon: Icons.code_outlined,
                    tooltip: 'Code en ligne  (`texte`)',
                    onTap: () =>
                        _visualWrap('`', after: '`', placeholder: 'code'),
                  ),
                  _MdToolbarDivider(),
                  _MdIconButton(
                    icon: Icons.image_outlined,
                    tooltip: 'Insérer une image',
                    onTap: _showImageSheet,
                    color: const Color(0xFF0288D1),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: MdVisualEditor(
            ctrl: widget.ctrl,
            enabled: widget.enabled,
            controller: _visualCtrl,
          ),
        ),
      ],
    );
  }

  // ── Mode texte brut : toolbar + champ monospace ──────────────────────────────

  Widget _buildTextMode(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.enabled) _buildToolbar(context),
          Expanded(child: _buildEditorField()),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Aperçu Markdown (écoute le contrôleur pour se rafraîchir)
// ══════════════════════════════════════════════════════════════════════════════

class _MarkdownPreview extends StatelessWidget {
  final TextEditingController ctrl;

  const _MarkdownPreview({required this.ctrl});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: ctrl,
      builder: (context, value, _) {
        final text = value.text;
        if (text.trim().isEmpty) {
          return const Center(
            child: Text(
              'Aucun contenu à afficher',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          );
        }
        return Markdown(
          data: text,
          selectable: true,
          padding: const EdgeInsets.all(16),
          extensionSet: md.ExtensionSet.gitHubFlavored,
          builders: {'u': _UnderlineBuilder()},
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
            h1: Theme.of(context).textTheme.headlineMedium,
            h2: Theme.of(context).textTheme.headlineSmall,
            h3: Theme.of(context).textTheme.titleLarge,
            p: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.6),
          ),
          imageBuilder: (uri, title, alt) {
            // Parse alt: "left|30", "right|25", "after" ou vide
            final altStr = (alt ?? '').trim().toLowerCase();
            final pipeIdx = altStr.indexOf('|');
            final pos = pipeIdx >= 0
                ? altStr.substring(0, pipeIdx).trim()
                : altStr;
            final widthStr = pipeIdx >= 0
                ? altStr.substring(pipeIdx + 1).trim()
                : null;
            final widthPct =
                (widthStr != null ? double.tryParse(widthStr) : null) ??
                (pos == 'after' || pos.isEmpty ? 100.0 : 30.0);

            final img = ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                uri.toString(),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  height: 80,
                  color: Colors.grey.shade200,
                  child: const Center(child: Icon(Icons.broken_image_outlined)),
                ),
              ),
            );

            if (pos == 'left' || pos == 'right') {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Align(
                  alignment: pos == 'left'
                      ? Alignment.centerLeft
                      : Alignment.centerRight,
                  child: FractionallySizedBox(
                    widthFactor: widthPct / 100,
                    child: img,
                  ),
                ),
              );
            }
            // after / vide : centré avec largeur explicite (ou pleine largeur si 100%)
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: widthPct < 100
                  ? Center(
                      child: FractionallySizedBox(
                        widthFactor: widthPct / 100,
                        child: img,
                      ),
                    )
                  : img,
            );
          },
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Sélecteur d'images Markdown
// ══════════════════════════════════════════════════════════════════════════════

class _MdImageInsertSheet extends StatefulWidget {
  final List<String> illustrationUrls;
  final Future<String?> Function(Uint8List bytes, String fileName)?
  onUploadImage;
  final void Function(String raw) onInsert;

  const _MdImageInsertSheet({
    required this.illustrationUrls,
    required this.onInsert,
    this.onUploadImage,
  });

  @override
  State<_MdImageInsertSheet> createState() => _MdImageInsertSheetState();
}

class _MdImageInsertSheetState extends State<_MdImageInsertSheet> {
  String? _selectedUrl;
  bool _uploading = false;
  ImagePosition _position = ImagePosition.after;
  int _widthPercent = 30;

  void _confirm() {
    final url = _selectedUrl;
    if (url == null || url.isEmpty) return;
    final raw = '![${_position.name}|$_widthPercent]($url)';
    Navigator.pop(context);
    widget.onInsert(raw);
  }

  Future<void> _pickFromGallery() async {
    if (widget.onUploadImage == null) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (picked == null) return;
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
    } catch (_) {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const accentColor = Color(0xFF0288D1);
    final theme = Theme.of(context);

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
          // Titre
          Row(
            children: [
              const Icon(Icons.image_outlined, color: accentColor),
              const SizedBox(width: 8),
              Text(
                'Insérer une image',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: accentColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Photos déjà attachées
          if (widget.illustrationUrls.isNotEmpty) ...[
            Text('Photos de la page', style: theme.textTheme.labelMedium),
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
                    onTap: () =>
                        setState(() => _selectedUrl = selected ? null : url),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: selected ? accentColor : Colors.transparent,
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

          // Galerie
          if (widget.onUploadImage != null) ...[
            Text('Depuis la galerie', style: theme.textTheme.labelMedium),
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
                    (_selectedUrl != null &&
                        !widget.illustrationUrls.contains(_selectedUrl))
                    ? const Text('Photo sélectionnée ✓')
                    : const Text('Choisir une photo'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: accentColor,
                  side: const BorderSide(color: accentColor),
                ),
              ),
            const SizedBox(height: 16),
          ],

          // Position
          Text('Position', style: theme.textTheme.labelMedium),
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
          // Largeur (toujours visible — valeurs prédéfinies)
          const SizedBox(height: 12),
          Text("Largeur de l'image", style: theme.textTheme.labelMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [5, 10, 20, 30, 40, 50, 60].map((w) {
              final sel = _widthPercent == w;
              return ChoiceChip(
                label: Text('$w%'),
                selected: sel,
                onSelected: (_) => setState(() => _widthPercent = w),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                selectedColor: accentColor.withValues(alpha: 0.15),
                checkmarkColor: accentColor,
                side: BorderSide(
                  color: sel ? accentColor : Colors.grey.shade400,
                ),
                labelStyle: TextStyle(
                  fontSize: 12,
                  color: sel ? accentColor : null,
                  fontWeight: sel ? FontWeight.bold : null,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          // Boutons
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
                style: FilledButton.styleFrom(backgroundColor: accentColor),
                child: const Text('Insérer'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Builder souligné pour flutter_markdown_plus
// ══════════════════════════════════════════════════════════════════════════════

class _UnderlineBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    return Text(
      element.textContent,
      style: (parentStyle ?? const TextStyle()).merge(
        const TextStyle(decoration: TextDecoration.underline),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Toolbar widgets
// ══════════════════════════════════════════════════════════════════════════════

class _MdTextButton extends StatelessWidget {
  final String text;
  final String tooltip;
  final VoidCallback onTap;
  final TextDecoration? textDecoration;

  const _MdTextButton({
    required this.text,
    required this.tooltip,
    required this.onTap,
    this.textDecoration,
  });

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: color,
              decoration: textDecoration,
              decorationColor: color,
              decorationThickness: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}

class _MdIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  const _MdIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(icon, size: 18, color: iconColor),
        ),
      ),
    );
  }
}

class _MdToolbarDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: VerticalDivider(
        indent: 6,
        endIndent: 6,
        width: 12,
        color: Theme.of(context).dividerColor,
      ),
    );
  }
}
