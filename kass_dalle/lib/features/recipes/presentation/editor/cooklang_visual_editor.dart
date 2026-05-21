import 'package:flutter/material.dart';
import 'cooklang_block_model.dart';
import 'cooklang_chip_widgets.dart';

// ── Colors (consistent with syntax controller) ────────────────────────────────
const _kIngredientColor = Color(0xFF1565C0);
const _kUtensilColor = Color(0xFFE64A19);
const _kTimerColor = Color(0xFF6A1B9A);
const _kSectionColor = Color(0xFF3949AB);
const _kCommentColor = Color(0xFF6A9955);
const _kMetaColor = Color(0xFF9E9E9E);

// ══════════════════════════════════════════════════════════════════════════════
// CooklangVisualEditor
// ══════════════════════════════════════════════════════════════════════════════

/// WYSIWYG visual editor for a CookLang recipe.
///
/// Reads from and writes back to [ctrl] (the shared source-of-truth).
/// Displays a list of [EditorBlock] widgets:
///   - Configuration fields (>> metadata) as FormFields at the top
///   - Section, paragraph, bullet, comment blocks with inline chips
///
/// When [enabled] is false, all blocks are read-only.
class CooklangVisualEditor extends StatefulWidget {
  final TextEditingController ctrl;
  final bool enabled;

  const CooklangVisualEditor({
    super.key,
    required this.ctrl,
    this.enabled = true,
  });

  @override
  State<CooklangVisualEditor> createState() => _CooklangVisualEditorState();
}

class _CooklangVisualEditorState extends State<CooklangVisualEditor> {
  late List<EditorBlock> _blocks;

  /// Index of the block currently being edited inline (-1 = none).
  int _editingIndex = -1;
  final _inlineCtrl = TextEditingController();
  final _inlineFocus = FocusNode();

  // Meta controllers (kept stable — not rebuilt on every parse)
  final _metaCtrls = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _parseFromSource();
    widget.ctrl.addListener(_onSourceChanged);
    _inlineFocus.addListener(_onInlineFocusChanged);
  }

  @override
  void didUpdateWidget(CooklangVisualEditor old) {
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
    for (final c in _metaCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ── Source synchronisation ────────────────────────────────────────────────

  bool _updatingFromBlocks = false;

  void _onSourceChanged() {
    if (_updatingFromBlocks) return; // ignore our own writes
    if (_editingIndex >= 0) return; // user is editing inline — don't re-parse
    _parseFromSource();
  }

  void _parseFromSource() {
    final blocks = parseCooklangBlocks(widget.ctrl.text);
    // Sync meta controllers
    for (final b in blocks) {
      if (b.type == BlockType.metadata && b.metaKey != null) {
        final key = b.metaKey!;
        if (!_metaCtrls.containsKey(key)) {
          _metaCtrls[key] = TextEditingController(text: b.metaValue ?? '');
        } else if (_metaCtrls[key]!.text != (b.metaValue ?? '')) {
          _metaCtrls[key]!.text = b.metaValue ?? '';
        }
      }
    }
    setState(() => _blocks = blocks);
  }

  void _commitToSource() {
    _updatingFromBlocks = true;
    widget.ctrl.text = blocksToSource(_blocks);
    _updatingFromBlocks = false;
  }

  // ── Inline editing ────────────────────────────────────────────────────────

  void _onInlineFocusChanged() {
    if (!_inlineFocus.hasFocus && _editingIndex >= 0) {
      _commitInlineEdit();
    }
  }

  void _startInlineEdit(int index) {
    if (!widget.enabled) return;
    setState(() {
      _editingIndex = index;
      _inlineCtrl.text = _blocks[index].rawLine;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _inlineFocus.requestFocus();
    });
  }

  void _commitInlineEdit() {
    if (_editingIndex < 0) return;
    final raw = _inlineCtrl.text;
    final updated = parseLine(raw);
    setState(() {
      _blocks[_editingIndex] = updated;
      _editingIndex = -1;
    });
    _commitToSource();
  }

  // ── Block mutations ───────────────────────────────────────────────────────

  void _updateBlock(int index, EditorBlock updated) {
    setState(() => _blocks[index] = updated);
    _commitToSource();
  }

  void _deleteBlock(int index) {
    setState(() => _blocks.removeAt(index));
    _commitToSource();
  }

  void _addBlockAfter(int index, EditorBlock block) {
    setState(() => _blocks.insert(index + 1, block));
    _commitToSource();
    // Auto-start editing the new block
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (block.type != BlockType.blank) _startInlineEdit(index + 1);
    });
  }

  void _updateSegmentInBlock(int blockIdx, int segIdx, LineSegment updated) {
    final block = _blocks[blockIdx];
    final segs = List<LineSegment>.from(block.segments ?? []);
    segs[segIdx] = updated;
    _updateBlock(blockIdx, block.withSegments(segs));
  }

  void _deleteSegmentInBlock(int blockIdx, int segIdx) {
    final block = _blocks[blockIdx];
    final segs = List<LineSegment>.from(block.segments ?? []);
    segs.removeAt(segIdx);
    _updateBlock(blockIdx, block.withSegments(segs));
  }

  // ── Meta field sync ───────────────────────────────────────────────────────

  void _onMetaChanged(int index, String key, String value) {
    _updateBlock(index, EditorBlock.metadata('>> $key: $value', key, value));
  }

  // ── Insert from toolbar ───────────────────────────────────────────────────

  /// Insert CookLang text at cursor in the currently edited block,
  /// or append a new block if no block is being edited.
  void _insertAtCursor(String text) {
    if (_editingIndex >= 0) {
      final sel = _inlineCtrl.selection;
      final current = _inlineCtrl.text;
      final insertPos = sel.isValid ? sel.baseOffset : current.length;
      _inlineCtrl.text =
          current.substring(0, insertPos) + text + current.substring(insertPos);
      _inlineCtrl.selection = TextSelection.collapsed(
        offset: insertPos + text.length,
      );
    } else {
      // Find last non-blank block and append after it
      final insertAfter = _blocks.isNotEmpty ? _blocks.length - 1 : -1;
      _addBlockAfter(insertAfter, parseLine(text));
    }
  }

  Future<void> _insertIngredient() async {
    final result = await showModalBottomSheet<IngredientSegment>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _IngredientInsertSheet(),
    );
    if (result != null) _insertAtCursor(result.raw);
  }

  Future<void> _insertUtensil() async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.kitchen_outlined, color: _kUtensilColor),
            SizedBox(width: 8),
            Text('Ajouter un ustensile'),
          ],
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nom',
            hintText: 'ex: poêle à crêpes',
            border: OutlineInputBorder(),
            prefixText: '#',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: _kUtensilColor),
            child: const Text('Insérer'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (result != null && result.isNotEmpty) {
      _insertAtCursor(UtensilSegment.buildRaw(result));
    }
  }

  Future<void> _insertTimer() async {
    final result = await showModalBottomSheet<TimerSegment>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TimerInsertSheet(),
    );
    if (result != null) _insertAtCursor(result.raw);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── Toolbar ───────────────────────────────────────────────────────
        if (widget.enabled) _buildToolbar(context),

        // ── Block list ────────────────────────────────────────────────────
        Expanded(
          child: Container(
            color: Colors.white,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: _blocks.length + 1, // +1 for the "add block" row
              itemBuilder: (ctx, i) {
                if (i == _blocks.length) {
                  return _buildAddBlockRow(i);
                }
                return _buildBlockWidget(ctx, i);
              },
            ),
          ),
        ),
      ],
    );
  }

  // ── Toolbar ───────────────────────────────────────────────────────────────

  Widget _buildToolbar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _ToolbarButton(
              label: '@ Ingrédient',
              color: _kIngredientColor,
              onTap: _insertIngredient,
            ),
            _ToolbarButton(
              label: '# Ustensile',
              color: _kUtensilColor,
              onTap: _insertUtensil,
            ),
            _ToolbarButton(
              label: '~ Minuteur',
              color: _kTimerColor,
              onTap: _insertTimer,
            ),
            const SizedBox(width: 8),
            _ToolbarButton(
              label: '== Section',
              color: _kSectionColor,
              onTap: () => _insertAtCursor('== '),
            ),
            _ToolbarButton(
              label: '> Conseil',
              color: _kCommentColor,
              onTap: () => _insertAtCursor('> '),
            ),
            _ToolbarButton(
              label: '-- Note',
              color: _kCommentColor.withValues(alpha: 0.8),
              onTap: () => _insertAtCursor('-- '),
            ),
            _ToolbarButton(
              label: '- Liste',
              color: Colors.blueGrey,
              onTap: () => _insertAtCursor('- '),
            ),
          ],
        ),
      ),
    );
  }

  // ── Block widgets ─────────────────────────────────────────────────────────

  Widget _buildBlockWidget(BuildContext context, int index) {
    final block = _blocks[index];

    // Inline editing mode (raw text)
    if (_editingIndex == index) {
      return _InlineEditRow(
        controller: _inlineCtrl,
        focusNode: _inlineFocus,
        onDone: _commitInlineEdit,
        onDelete: () => _deleteBlock(index),
      );
    }

    switch (block.type) {
      case BlockType.metadata:
        return _MetadataBlockWidget(
          block: block,
          enabled: widget.enabled,
          onChanged: (key, value) => _onMetaChanged(index, key, value),
        );
      case BlockType.blank:
        return GestureDetector(
          onTap: widget.enabled ? () => _startInlineEdit(index) : null,
          child: const SizedBox(height: 14),
        );
      case BlockType.section:
        return _SectionBlockWidget(
          block: block,
          enabled: widget.enabled,
          onTap: () => _startInlineEdit(index),
          onDelete: () => _deleteBlock(index),
        );
      case BlockType.comment:
        return _CommentBlockWidget(
          block: block,
          enabled: widget.enabled,
          onTap: () => _startInlineEdit(index),
          onDelete: () => _deleteBlock(index),
        );
      case BlockType.bullet:
      case BlockType.paragraph:
        return _ParagraphBlockWidget(
          block: block,
          blockIndex: index,
          enabled: widget.enabled,
          onTap: () => _startInlineEdit(index),
          onDelete: () => _deleteBlock(index),
          onSegmentChanged: (segIdx, updated) =>
              _updateSegmentInBlock(index, segIdx, updated),
          onSegmentDeleted: (segIdx) => _deleteSegmentInBlock(index, segIdx),
        );
    }
  }

  Widget _buildAddBlockRow(int index) {
    if (!widget.enabled) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          _addBlockAfter(index - 1, EditorBlock.paragraph('', const []));
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(
              color: Colors.grey.withValues(alpha: 0.3),
              style: BorderStyle.solid,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, size: 16, color: Colors.grey.shade500),
                const SizedBox(width: 4),
                Text(
                  'Ajouter une ligne',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Block sub-widgets
// ══════════════════════════════════════════════════════════════════════════════

/// Row showing a raw TextField for inline editing.
class _InlineEditRow extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onDone;
  final VoidCallback onDelete;

  const _InlineEditRow({
    required this.controller,
    required this.focusNode,
    required this.onDone,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.primary),
        borderRadius: BorderRadius.circular(6),
        color: Theme.of(
          context,
        ).colorScheme.primaryContainer.withValues(alpha: 0.15),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              maxLines: null,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                hintText: 'Saisir le contenu…',
              ),
              onSubmitted: (_) => onDone(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.check_circle_outline, size: 20),
            color: Theme.of(context).colorScheme.primary,
            tooltip: 'Valider',
            onPressed: onDone,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            color: Theme.of(context).colorScheme.error,
            tooltip: 'Supprimer',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

/// Metadata block: `>> key: value`
class _MetadataBlockWidget extends StatefulWidget {
  final EditorBlock block;
  final bool enabled;
  final void Function(String key, String value) onChanged;

  const _MetadataBlockWidget({
    required this.block,
    required this.enabled,
    required this.onChanged,
  });

  @override
  State<_MetadataBlockWidget> createState() => _MetadataBlockWidgetState();
}

class _MetadataBlockWidgetState extends State<_MetadataBlockWidget> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.block.metaValue ?? '');
  }

  @override
  void didUpdateWidget(_MetadataBlockWidget old) {
    super.didUpdateWidget(old);
    if (old.block.metaValue != widget.block.metaValue) {
      final newVal = widget.block.metaValue ?? '';
      if (_ctrl.text != newVal) _ctrl.text = newVal;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final key = widget.block.metaKey ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              _localizeMetaKey(key),
              style: TextStyle(
                fontSize: 12,
                color: _kMetaColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: _ctrl,
              enabled: widget.enabled,
              style: TextStyle(fontSize: 13, color: _kMetaColor),
              decoration: InputDecoration(
                isDense: true,
                hintText: _hintForKey(key),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(
                    color: _kMetaColor.withValues(alpha: 0.4),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(
                    color: _kMetaColor.withValues(alpha: 0.3),
                  ),
                ),
              ),
              onChanged: (v) => widget.onChanged(key, v),
            ),
          ),
        ],
      ),
    );
  }

  String _localizeMetaKey(String key) => switch (key.toLowerCase()) {
    'titre' || 'title' => 'Titre',
    'source' => 'Source',
    'servings' || 'portions' => 'Portions',
    'prep_time' => 'Prép.',
    'cook_time' => 'Cuisson',
    _ => key,
  };

  String _hintForKey(String key) => switch (key.toLowerCase()) {
    'titre' || 'title' => 'Titre de la recette',
    'source' => 'URL ou nom du livre',
    'servings' || 'portions' => '4',
    'prep_time' => '20 min',
    'cook_time' => '30 min',
    _ => '',
  };
}

/// Section block: `## Title`
class _SectionBlockWidget extends StatelessWidget {
  final EditorBlock block;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _SectionBlockWidget({
    required this.block,
    required this.enabled,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return _BlockRow(
      enabled: enabled,
      onTap: onTap,
      onDelete: onDelete,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          block.plainText ?? '',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
            color: _kSectionColor,
          ),
        ),
      ),
    );
  }
}

/// Comment block: `-- note`
class _CommentBlockWidget extends StatelessWidget {
  final EditorBlock block;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _CommentBlockWidget({
    required this.block,
    required this.enabled,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return _BlockRow(
      enabled: enabled,
      onTap: onTap,
      onDelete: onDelete,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: _kCommentColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border(left: BorderSide(color: _kCommentColor, width: 3)),
        ),
        child: Text(
          '${block.rawLine.trimLeft().startsWith('>') ? '💡' : '💬'} ${block.plainText ?? ''}',
          style: TextStyle(
            fontSize: 13,
            fontStyle: FontStyle.italic,
            color: block.rawLine.trimLeft().startsWith('>')
                ? const Color(0xFF795548) // brown - conseil
                : _kCommentColor, // green - note privée
          ),
        ),
      ),
    );
  }
}

/// Paragraph or bullet block with inline chips.
class _ParagraphBlockWidget extends StatelessWidget {
  final EditorBlock block;
  final int blockIndex;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final void Function(int segIdx, LineSegment updated) onSegmentChanged;
  final void Function(int segIdx) onSegmentDeleted;

  const _ParagraphBlockWidget({
    required this.block,
    required this.blockIndex,
    required this.enabled,
    required this.onTap,
    required this.onDelete,
    required this.onSegmentChanged,
    required this.onSegmentDeleted,
  });

  @override
  Widget build(BuildContext context) {
    final isBullet = block.type == BlockType.bullet;
    final segments = block.segments ?? const [];

    Widget content = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (isBullet)
          const Padding(
            padding: EdgeInsets.only(right: 6, top: 2),
            child: Text(
              '•',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ),
        for (int i = 0; i < segments.length; i++)
          _buildSegment(context, i, segments[i]),
      ],
    );

    return _BlockRow(
      enabled: enabled,
      onTap: onTap,
      onDelete: onDelete,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: content,
      ),
    );
  }

  Widget _buildSegment(BuildContext context, int segIdx, LineSegment seg) {
    return switch (seg) {
      TextSegment(:final text) => _buildRichText(text),
      IngredientSegment() => IngredientChipWidget(
        segment: seg,
        enabled: enabled,
        onChanged: (updated) => onSegmentChanged(segIdx, updated),
        onDelete: enabled ? () => onSegmentDeleted(segIdx) : null,
      ),
      UtensilSegment() => UtensilChipWidget(
        segment: seg,
        enabled: enabled,
        onChanged: (updated) => onSegmentChanged(segIdx, updated),
        onDelete: enabled ? () => onSegmentDeleted(segIdx) : null,
      ),
      TimerSegment() => TimerChipWidget(
        segment: seg,
        enabled: enabled,
        onChanged: (updated) => onSegmentChanged(segIdx, updated),
        onDelete: enabled ? () => onSegmentDeleted(segIdx) : null,
      ),
    };
  }

  /// Render plain text supporting **bold** and *italic* Markdown inline.
  Widget _buildRichText(String text) {
    if (text.isEmpty) return const SizedBox.shrink();

    // Split on bold (**…**) and italic (*…*) markers
    final spans = <InlineSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*');
    int cursor = 0;

    for (final m in re.allMatches(text)) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, m.start)));
      }
      if (m.group(1) != null) {
        // Bold
        spans.add(
          TextSpan(
            text: m.group(1),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        );
      } else if (m.group(2) != null) {
        // Italic
        spans.add(
          TextSpan(
            text: m.group(2),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      }
      cursor = m.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return RichText(
      text: TextSpan(
        style: const TextStyle(fontSize: 14, color: Color(0xFF212121)),
        children: spans,
      ),
    );
  }
}

/// Reusable block row with tap-to-edit and delete button.
class _BlockRow extends StatelessWidget {
  final Widget child;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _BlockRow({
    required this.child,
    required this.enabled,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(4),
            child: child,
          ),
        ),
        if (enabled)
          IconButton(
            icon: const Icon(Icons.drag_indicator, size: 16),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            color: Colors.grey.shade400,
            tooltip: 'Modifier / Supprimer',
            onPressed: onDelete,
          ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Insert sheets (simplified versions for toolbar buttons)
// ══════════════════════════════════════════════════════════════════════════════

class _IngredientInsertSheet extends StatefulWidget {
  @override
  State<_IngredientInsertSheet> createState() => _IngredientInsertSheetState();
}

class _IngredientInsertSheetState extends State<_IngredientInsertSheet> {
  final _name = TextEditingController();
  final _qty = TextEditingController();
  final _unit = TextEditingController();

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
              const Icon(Icons.eco_outlined, color: _kIngredientColor),
              const SizedBox(width: 8),
              Text(
                'Ajouter un ingrédient',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: _kIngredientColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
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
                onPressed: () {
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
                },
                style: FilledButton.styleFrom(
                  backgroundColor: _kIngredientColor,
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

class _TimerInsertSheet extends StatefulWidget {
  @override
  State<_TimerInsertSheet> createState() => _TimerInsertSheetState();
}

class _TimerInsertSheetState extends State<_TimerInsertSheet> {
  final _name = TextEditingController();
  final _qty = TextEditingController();
  String _unit = 'minutes';

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
              const Icon(Icons.timer_outlined, color: _kTimerColor),
              const SizedBox(width: 8),
              Text(
                'Ajouter un minuteur',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: _kTimerColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
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
                  value: _unit,
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
                onPressed: () {
                  final qty = _qty.text.trim();
                  if (qty.isEmpty) return;
                  final seg = TimerSegment(
                    name: _name.text.trim(),
                    qty: qty,
                    unit: _unit,
                    raw: TimerSegment.buildRaw(_name.text.trim(), qty, _unit),
                  );
                  Navigator.pop(context, seg);
                },
                style: FilledButton.styleFrom(backgroundColor: _kTimerColor),
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

class _ToolbarButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ToolbarButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
