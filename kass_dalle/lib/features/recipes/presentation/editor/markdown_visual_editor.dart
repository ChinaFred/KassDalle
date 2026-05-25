import 'package:flutter/material.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Block model
// ══════════════════════════════════════════════════════════════════════════════

enum _BType {
  h1,
  h2,
  h3,
  bullet,
  numbered,
  blockquote,
  blank,
  paragraph,
  image,
}

class _Block {
  final _BType type;
  final String raw;
  const _Block(this.type, this.raw);
}

_Block _parseLine(String line) {
  if (RegExp(r'^!\[.*\]\(.+\)').hasMatch(line.trim()))
    return _Block(_BType.image, line.trim());
  if (line.startsWith('### ')) return _Block(_BType.h3, line);
  if (line.startsWith('## ')) return _Block(_BType.h2, line);
  if (line.startsWith('# ')) return _Block(_BType.h1, line);
  if (line.startsWith('- ') || line.startsWith('* ')) {
    return _Block(_BType.bullet, line);
  }
  if (RegExp(r'^\d+\.\s').hasMatch(line)) return _Block(_BType.numbered, line);
  if (line.startsWith('> ')) return _Block(_BType.blockquote, line);
  if (line.trim().isEmpty) return _Block(_BType.blank, line);
  return _Block(_BType.paragraph, line);
}

List<_Block> _parseAll(String text) =>
    text.split('\n').map(_parseLine).toList();

// ══════════════════════════════════════════════════════════════════════════════
// Inline span parser  (**bold**, *italic*, `code`, <u>souligné</u>)
// ══════════════════════════════════════════════════════════════════════════════

List<InlineSpan> _inlineSpans(String text, TextStyle base, Color codeBg) {
  if (text.isEmpty) return [TextSpan(text: '', style: base)];
  final regex = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*|`(.+?)`|<u>(.+?)<\/u>');
  final spans = <InlineSpan>[];
  int last = 0;

  for (final m in regex.allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start), style: base));
    }
    if (m.group(1) != null) {
      spans.add(
        TextSpan(
          text: m.group(1),
          style: base.copyWith(fontWeight: FontWeight.bold),
        ),
      );
    } else if (m.group(2) != null) {
      spans.add(
        TextSpan(
          text: m.group(2),
          style: base.copyWith(fontStyle: FontStyle.italic),
        ),
      );
    } else if (m.group(3) != null) {
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: codeBg,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              m.group(3)!,
              style: base.copyWith(
                fontFamily: 'monospace',
                fontSize: (base.fontSize ?? 14) * 0.9,
              ),
            ),
          ),
        ),
      );
    } else if (m.group(4) != null) {
      spans.add(
        TextSpan(
          text: m.group(4),
          style: base.copyWith(decoration: TextDecoration.underline),
        ),
      );
    }
    last = m.end;
  }
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last), style: base));
  }
  if (spans.isEmpty) spans.add(TextSpan(text: text, style: base));
  return spans;
}

// ══════════════════════════════════════════════════════════════════════════════
// MdVisualEditorController
// ══════════════════════════════════════════════════════════════════════════════

/// Contrôleur externe pour piloter [MdVisualEditor] depuis un widget parent.
///
/// Permet à la barre d'outils de [MarkdownEditor] d'insérer du contenu dans
/// la ligne actuellement éditée plutôt qu'en fin de document.
class MdVisualEditorController {
  _MdVisualEditorState? _state;

  /// Vrai si un bloc est actuellement en cours d'édition inline.
  bool get hasActiveEdit => (_state?._editingIndex ?? -1) >= 0;

  /// Entoure la sélection (ou insère à la position du curseur) dans
  /// l'éditeur inline actif avec [before] … [after].
  void wrapAtInlineCursor(String before, {String after = ''}) =>
      _state?.wrapAtInlineCursor(before, after: after);

  /// Ajoute [prefix] au début du texte dans l'éditeur inline actif
  /// (remplace tout préfixe structurel existant : #, -, 1., >).
  void prependToInlineLine(String prefix) =>
      _state?.prependToInlineLine(prefix);

  /// Valide l'édition inline en cours (si elle existe), en écrivant
  /// le contenu du champ inline dans la source principale.
  /// À appeler avant toute insertion externe dans le contrôleur.
  void commitActiveEdit() => _state?._commitEdit();
}

// ══════════════════════════════════════════════════════════════════════════════
// MdVisualEditor
// ══════════════════════════════════════════════════════════════════════════════

/// Éditeur visuel bloc-par-bloc pour le contenu Markdown.
///
/// Chaque ligne du texte source est rendue comme un bloc stylisé
/// (titre, bullet, citation, paragraphe avec gras/italique/code inline).
/// Un tap sur un bloc ouvre l'éditeur inline brut (syntaxe Markdown visible).
/// Identique au pattern du [CooklangVisualEditor].
class MdVisualEditor extends StatefulWidget {
  final TextEditingController ctrl;
  final bool enabled;
  final MdVisualEditorController? controller;

  const MdVisualEditor({
    super.key,
    required this.ctrl,
    this.enabled = true,
    this.controller,
  });

  @override
  State<MdVisualEditor> createState() => _MdVisualEditorState();
}

class _MdVisualEditorState extends State<MdVisualEditor> {
  late List<_Block> _blocks;
  int _editingIndex = -1;
  final _inlineCtrl = TextEditingController();
  final _inlineFocus = FocusNode();
  bool _updatingFromBlocks = false;

  @override
  void initState() {
    super.initState();
    _parseFromSource();
    widget.ctrl.addListener(_onSourceChanged);
    _inlineFocus.addListener(_onFocusChanged);
    _inlineCtrl.addListener(_onInlineCtrlChanged);
    widget.controller?._state = this;
  }

  @override
  void didUpdateWidget(MdVisualEditor old) {
    super.didUpdateWidget(old);
    if (old.ctrl != widget.ctrl) {
      old.ctrl.removeListener(_onSourceChanged);
      widget.ctrl.addListener(_onSourceChanged);
      _parseFromSource();
    }
  }

  @override
  void dispose() {
    widget.controller?._state = null;
    widget.ctrl.removeListener(_onSourceChanged);
    _inlineCtrl.removeListener(_onInlineCtrlChanged);
    _inlineCtrl.dispose();
    _inlineFocus.dispose();
    super.dispose();
  }

  // ── Source sync ─────────────────────────────────────────────────────────────

  void _onSourceChanged() {
    if (_updatingFromBlocks) return;
    if (_editingIndex >= 0) return; // édition en cours — ne pas re-parser
    _parseFromSource();
  }

  void _parseFromSource() {
    setState(() => _blocks = _parseAll(widget.ctrl.text));
  }

  void _onFocusChanged() {
    // On ne commit PAS automatiquement sur perte de focus.
    // Cela permet à la toolbar de toujours trouver hasActiveEdit == true
    // lors d'un tap bouton (H1, Bold…) même si le TextField perd le focus.
    // Le commit se fait explicitement via ✓, Enter, ou _startEditing().
  }

  void _onInlineCtrlChanged() {
    if (_editingIndex < 0) return;
    final updatedBlocks = List<_Block>.from(_blocks);
    updatedBlocks[_editingIndex] = _parseLine(_inlineCtrl.text);
    _updatingFromBlocks = true;
    widget.ctrl.text = updatedBlocks.map((b) => b.raw).join('\n');
    _updatingFromBlocks = false;
  }

  // ── Edition inline ──────────────────────────────────────────────────────────

  void _startEditing(int index) {
    if (!widget.enabled) return;
    // Commit l'édition précédente avant d'en démarrer une nouvelle.
    if (_editingIndex >= 0 && _editingIndex != index) {
      _commitEdit();
    }
    setState(() {
      _editingIndex = index;
      _inlineCtrl.text = _blocks[index].raw;
      _inlineCtrl.selection = TextSelection.collapsed(
        offset: _inlineCtrl.text.length,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _inlineFocus.requestFocus(),
    );
  }

  void _commitEdit() {
    if (_editingIndex < 0) return;
    final idx = _editingIndex;
    final raw = _inlineCtrl.text;
    setState(() {
      _editingIndex = -1;
      _blocks[idx] = _parseLine(raw);
    });
    _writeToSource();
  }

  void _cancelEdit() {
    setState(() => _editingIndex = -1);
  }

  void _writeToSource() {
    _updatingFromBlocks = true;
    widget.ctrl.text = _blocks.map((b) => b.raw).join('\n');
    _updatingFromBlocks = false;
  }

  void _deleteBlock(int index) {
    setState(() {
      if (_editingIndex == index)
        _editingIndex = -1;
      else if (_editingIndex > index)
        _editingIndex--;
      _blocks.removeAt(index);
    });
    _writeToSource();
  }

  // ── Méthodes publiques (pilotées par MdVisualEditorController) ──────────────

  /// Entoure la sélection (ou insère à la position du curseur) dans
  /// l'éditeur inline actif avec [before] … [after].
  void wrapAtInlineCursor(String before, {String after = ''}) {
    if (_editingIndex < 0) return;
    final ctrl = _inlineCtrl;
    final sel = ctrl.selection;
    final text = ctrl.text;
    if (!sel.isValid || sel.isCollapsed) {
      final pos = sel.isValid ? sel.start : text.length;
      final placeholder = after.isNotEmpty ? 'texte' : '';
      final insertion = before + placeholder + after;
      ctrl.value = TextEditingValue(
        text: text.substring(0, pos) + insertion + text.substring(pos),
        selection: TextSelection(
          baseOffset: pos + before.length,
          extentOffset: pos + before.length + placeholder.length,
        ),
      );
    } else {
      final selected = text.substring(sel.start, sel.end);
      final suffix = after.isNotEmpty ? after : before;
      ctrl.value = TextEditingValue(
        text:
            text.substring(0, sel.start) +
            before +
            selected +
            suffix +
            text.substring(sel.end),
        selection: TextSelection(
          baseOffset: sel.start + before.length,
          extentOffset: sel.start + before.length + selected.length,
        ),
      );
    }
    _inlineFocus.requestFocus();
  }

  /// Remplace le préfixe structurel du texte inline actif par [prefix].
  /// Si aucun bloc n'est en cours d'édition, ne fait rien.
  void prependToInlineLine(String prefix) {
    if (_editingIndex < 0) return;
    final ctrl = _inlineCtrl;
    final text = ctrl.text;
    // Retire tout préfixe structurel existant (# ## ### - * 1. > etc.)
    final stripped = text.replaceFirst(
      RegExp(r'^#{1,3}\s+|^[-*]\s+|^\d+\.\s+|^>\s+'),
      '',
    );
    final newText = prefix + stripped;
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
    _inlineFocus.requestFocus();
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
      itemCount: _blocks.length + (widget.enabled ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (widget.enabled && i == _blocks.length)
          return _buildAddLineFooter(context);
        if (_editingIndex == i) return _buildInlineEditor(context, i);
        return _buildBlock(context, i);
      },
    );
  }

  Widget _buildAddLineFooter(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            if (_editingIndex >= 0) _commitEdit();
            setState(() => _blocks.add(const _Block(_BType.blank, '')));
            _writeToSource();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _startEditing(_blocks.length - 1);
            });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(color: cs.outlineVariant),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, size: 16, color: cs.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  'Ajouter une ligne',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Inline editor row (identique au style CooklangInlineEditRow) ────────────

  Widget _buildInlineEditor(BuildContext context, int i) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.primary),
        borderRadius: BorderRadius.circular(6),
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.15),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inlineCtrl,
              focusNode: _inlineFocus,
              maxLines: null,
              textInputAction: TextInputAction.done,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                hintText: 'Saisir le contenu Markdown…',
              ),
              onChanged: (value) {
                // Enter sans Shift → valider
                if (value.contains('\n')) {
                  final cleaned = value.replaceAll('\n', '');
                  _inlineCtrl.value = TextEditingValue(
                    text: cleaned,
                    selection: TextSelection.collapsed(offset: cleaned.length),
                  );
                  _commitEdit();
                }
              },
              onSubmitted: (_) => _commitEdit(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.check_circle_outline, size: 20),
            color: theme.colorScheme.primary,
            tooltip: 'Valider',
            onPressed: _commitEdit,
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            color: theme.colorScheme.onSurfaceVariant,
            tooltip: 'Annuler',
            onPressed: _cancelEdit,
          ),
        ],
      ),
    );
  }

  // ── Block renderers ─────────────────────────────────────────────────────────

  Widget _buildBlock(BuildContext context, int i) {
    final block = _blocks[i];
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final codeBg = cs.surfaceContainerHighest;
    final bodyStyle = theme.textTheme.bodyMedium!.copyWith(color: cs.onSurface);

    // Ligne vide : zone cliquable fine + bouton supprimer
    if (block.type == _BType.blank) {
      return Row(
        children: [
          if (widget.enabled)
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 4),
              child: Icon(
                Icons.drag_indicator,
                size: 14,
                color: cs.onSurfaceVariant.withValues(alpha: 0.3),
              ),
            ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _startEditing(i),
              child: Container(height: 20, color: Colors.transparent),
            ),
          ),
          if (widget.enabled)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 16),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              color: Colors.grey.shade400,
              tooltip: 'Supprimer',
              onPressed: () => _deleteBlock(i),
            ),
        ],
      );
    }

    EdgeInsets padding;
    Widget content;

    switch (block.type) {
      // ── Titres ─────────────────────────────────────────────────────────────
      case _BType.h1:
        final text = block.raw.replaceFirst(RegExp(r'^#+\s+'), '');
        padding = const EdgeInsets.only(top: 14, bottom: 4);
        content = Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 3,
              height: 22,
              color: cs.primary,
              margin: const EdgeInsets.only(right: 8),
            ),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: cs.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );

      case _BType.h2:
        final text = block.raw.replaceFirst(RegExp(r'^#+\s+'), '');
        padding = const EdgeInsets.only(top: 10, bottom: 3);
        content = Text(
          text,
          style: theme.textTheme.titleLarge?.copyWith(
            color: cs.primary,
            fontWeight: FontWeight.bold,
          ),
        );

      case _BType.h3:
        final text = block.raw.replaceFirst(RegExp(r'^#+\s+'), '');
        padding = const EdgeInsets.only(top: 8, bottom: 2);
        content = Text(
          text,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        );

      // ── Liste à puces ───────────────────────────────────────────────────────
      case _BType.bullet:
        final text = block.raw.replaceFirst(RegExp(r'^[-*]\s+'), '');
        padding = const EdgeInsets.symmetric(vertical: 3);
        content = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 8),
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cs.primary,
                ),
              ),
            ),
            Expanded(
              child: RichText(
                text: TextSpan(children: _inlineSpans(text, bodyStyle, codeBg)),
              ),
            ),
          ],
        );

      // ── Liste numérotée ─────────────────────────────────────────────────────
      case _BType.numbered:
        final match = RegExp(r'^(\d+)\.\s+(.*)').firstMatch(block.raw);
        final num = match?.group(1) ?? '1';
        final text = match?.group(2) ?? block.raw;
        padding = const EdgeInsets.symmetric(vertical: 3);
        content = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                '$num.',
                style: bodyStyle.copyWith(
                  color: cs.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Expanded(
              child: RichText(
                text: TextSpan(children: _inlineSpans(text, bodyStyle, codeBg)),
              ),
            ),
          ],
        );

      // ── Citation ────────────────────────────────────────────────────────────
      case _BType.blockquote:
        final text = block.raw.replaceFirst(RegExp(r'^>\s?'), '');
        padding = const EdgeInsets.symmetric(vertical: 4);
        content = Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: cs.primary, width: 3)),
            color: cs.primaryContainer.withValues(alpha: 0.2),
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(4),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: RichText(
            text: TextSpan(
              children: _inlineSpans(
                text,
                bodyStyle.copyWith(fontStyle: FontStyle.italic),
                codeBg,
              ),
            ),
          ),
        );

      // ── Paragraphe (inline formatting) ──────────────────────────────────────
      case _BType.paragraph:
        padding = const EdgeInsets.symmetric(vertical: 3);
        content = RichText(
          text: TextSpan(children: _inlineSpans(block.raw, bodyStyle, codeBg)),
        );

      // ── Image ────────────────────────────────────────────────────────────────
      case _BType.image:
        final imgMatch = RegExp(
          r'^!\[([^\]]*)\]\(([^)]+)\)$',
        ).firstMatch(block.raw.trim());
        padding = const EdgeInsets.symmetric(vertical: 6);
        if (imgMatch != null) {
          final alt = imgMatch.group(1) ?? '';
          final url = imgMatch.group(2) ?? '';
          final altLower = alt.toLowerCase();
          final pipeIdx = altLower.indexOf('|');
          final imgPos = pipeIdx >= 0
              ? altLower.substring(0, pipeIdx).trim()
              : altLower;
          final wStr = pipeIdx >= 0
              ? altLower.substring(pipeIdx + 1).trim()
              : null;
          final wPct =
              (wStr != null ? double.tryParse(wStr) : null) ??
              (imgPos == 'after' || imgPos.isEmpty ? 100.0 : 30.0);
          final imgWidget = ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.network(
              url,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.high,
              errorBuilder: (_, _, _) => Container(
                height: 60,
                color: cs.surfaceContainerHighest,
                child: const Center(child: Icon(Icons.broken_image_outlined)),
              ),
            ),
          );
          if (imgPos == 'left') {
            content = Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: wPct / 100,
                child: imgWidget,
              ),
            );
          } else if (imgPos == 'right') {
            content = Align(
              alignment: Alignment.centerRight,
              child: FractionallySizedBox(
                widthFactor: wPct / 100,
                child: imgWidget,
              ),
            );
          } else {
            content = wPct < 100
                ? Center(
                    child: FractionallySizedBox(
                      widthFactor: wPct / 100,
                      child: imgWidget,
                    ),
                  )
                : imgWidget;
          }
        } else {
          content = RichText(
            text: TextSpan(
              children: _inlineSpans(block.raw, bodyStyle, codeBg),
            ),
          );
        }

      case _BType.blank:
        // Déjà géré plus haut
        padding = EdgeInsets.zero;
        content = const SizedBox.shrink();
    }

    return Padding(
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: padding.top,
        bottom: padding.bottom,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (widget.enabled)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(
                Icons.drag_indicator,
                size: 14,
                color: cs.onSurfaceVariant.withValues(alpha: 0.3),
              ),
            ),
          // Seule la zone de contenu est cliquable pour éditer.
          // Le bouton supprimer est un sibling indépendant, sans GestureDetector commun.
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _startEditing(i),
              child: content,
            ),
          ),
          if (widget.enabled)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 16),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              color: Colors.grey.shade400,
              tooltip: 'Supprimer',
              onPressed: () => _deleteBlock(i),
            ),
        ],
      ),
    );
  }
}
