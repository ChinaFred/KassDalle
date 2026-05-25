import 'package:flutter/material.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Block model
// ══════════════════════════════════════════════════════════════════════════════

enum _BType { h1, h2, h3, bullet, numbered, blockquote, blank, paragraph }

class _Block {
  final _BType type;
  final String raw;
  const _Block(this.type, this.raw);
}

_Block _parseLine(String line) {
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

List<_Block> _parseAll(String text) => text.split('\n').map(_parseLine).toList();

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
      spans.add(TextSpan(
        text: m.group(1),
        style: base.copyWith(fontWeight: FontWeight.bold),
      ));
    } else if (m.group(2) != null) {
      spans.add(TextSpan(
        text: m.group(2),
        style: base.copyWith(fontStyle: FontStyle.italic),
      ));
    } else if (m.group(3) != null) {
      spans.add(WidgetSpan(
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
      ));
    } else if (m.group(4) != null) {
      spans.add(TextSpan(
        text: m.group(4),
        style: base.copyWith(decoration: TextDecoration.underline),
      ));
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

  const MdVisualEditor({super.key, required this.ctrl, this.enabled = true});

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
    widget.ctrl.removeListener(_onSourceChanged);
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
    if (!_inlineFocus.hasFocus && _editingIndex >= 0) {
      _commitEdit();
    }
  }

  // ── Edition inline ──────────────────────────────────────────────────────────

  void _startEditing(int index) {
    if (!widget.enabled) return;
    setState(() {
      _editingIndex = index;
      _inlineCtrl.text = _blocks[index].raw;
      _inlineCtrl.selection =
          TextSelection.collapsed(offset: _inlineCtrl.text.length);
    });
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _inlineFocus.requestFocus());
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

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 64),
      itemCount: _blocks.length,
      itemBuilder: (ctx, i) {
        if (_editingIndex == i) return _buildInlineEditor(context, i);
        return _buildBlock(context, i);
      },
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
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                hintText: 'Saisir le contenu Markdown…',
              ),
              onChanged: (value) {
                // Enter sans Shift → valider
                if (value.contains('\n')) {
                  final cleaned = value.replaceAll('\n', '');
                  _inlineCtrl.value = TextEditingValue(
                    text: cleaned,
                    selection:
                        TextSelection.collapsed(offset: cleaned.length),
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

    // Ligne vide : zone cliquable fine
    if (block.type == _BType.blank) {
      return GestureDetector(
        onTap: () => _startEditing(i),
        child: Container(
          height: 16,
          color: Colors.transparent,
        ),
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
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.bold),
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
                text: TextSpan(
                    children: _inlineSpans(text, bodyStyle, codeBg)),
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
                text: TextSpan(
                    children: _inlineSpans(text, bodyStyle, codeBg)),
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
          text: TextSpan(
              children: _inlineSpans(block.raw, bodyStyle, codeBg)),
        );

      case _BType.blank:
        // Déjà géré plus haut
        padding = EdgeInsets.zero;
        content = const SizedBox.shrink();
    }

    return GestureDetector(
      onTap: () => _startEditing(i),
      child: Padding(
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
            Expanded(child: content),
          ],
        ),
      ),
    );
  }
}
