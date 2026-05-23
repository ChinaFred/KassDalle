import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'cooklang_block_model.dart';
import 'cooklang_chip_widgets.dart';

// ── Colors (consistent with syntax controller) ────────────────────────────────
const _kIngredientColor = Color(0xFF1565C0);
const _kUtensilColor = Color(0xFFE64A19);
const _kTimerColor = Color(0xFF6A1B9A);
const _kSectionColor = Color(0xFF3949AB);
const _kCommentColor = Color(0xFF6A9955);
const _kMetaColor = Color(0xFF9E9E9E);
const _kImageColor = Color(0xFF00838F); // teal 700

/// Clés de métadonnées gérées automatiquement (IA/scan) — masquées dans
/// l'éditeur visuel pour ne pas encombrer l'UI utilisateur.
const _kHiddenMetaKeys = {'page', 'dish_types', 'page_type'};

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

  /// URLs des illustrations détectées (depuis l'onglet photos) — proposées dans
  /// le picker image de la toolbar.
  final List<String> illustrationUrls;

  /// Callback pour uploader une image depuis la galerie.
  /// Reçoit les bytes et le nom du fichier, retourne l'URL Firebase Storage.
  /// Si null, le bouton galerie n'est pas affiché dans le picker.
  final Future<String?> Function(Uint8List bytes, String fileName)?
  onUploadImage;

  const CooklangVisualEditor({
    super.key,
    required this.ctrl,
    this.enabled = true,
    this.illustrationUrls = const [],
    this.onUploadImage,
  });

  @override
  State<CooklangVisualEditor> createState() => _CooklangVisualEditorState();
}

class _CooklangVisualEditorState extends State<CooklangVisualEditor> {
  late List<EditorBlock> _blocks;

  /// Index of the block currently being edited inline (-1 = none).
  int _editingIndex = -1;

  /// Dernière position d'édition — persiste après que _editingIndex est remis
  /// à -1 par la perte de focus, pour savoir où insérer l'image.
  int _lastEditedIndex = -1;

  /// Dernière position du curseur dans le champ inline — sauvegardée à la
  /// perte de focus pour permettre l'insertion au bon endroit.
  int _lastCursorOffset = -1;
  final _inlineCtrl = TextEditingController();
  final _inlineFocus = FocusNode();

  /// True while a block split (Enter key) is in progress — prevents the
  /// focus-lost handler from committing/closing the inline editor.
  bool _splitting = false;

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
    if (_splitting) return;
    if (!_inlineFocus.hasFocus && _editingIndex >= 0) {
      _lastCursorOffset = _inlineCtrl.selection.isValid
          ? _inlineCtrl.selection.baseOffset
          : _inlineCtrl.text.length;
      _commitInlineEdit();
    }
  }

  void _startInlineEdit(int index) {
    if (!widget.enabled) return;
    setState(() {
      _editingIndex = index;
      _lastEditedIndex = index;
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

  void _cancelInlineEdit() {
    if (_editingIndex < 0) return;
    // Discard changes — _blocks[_editingIndex].rawLine is already the saved version.
    setState(() {
      _editingIndex = -1;
    });
  }

  /// Called when the user presses Enter inside an inline edit row.
  /// Splits the block at [index]: [before] stays, [after] (and any extra
  /// newlines from a paste) become new blocks. The last new block is
  /// immediately focused for editing.
  void _splitBlockAtEnter(int index, String before, String after) {
    _splitting = true;
    final allLines = [before, ...after.split('\n')];
    final newBlocks = allLines.map(parseLine).toList();
    final lastIdx = index + newBlocks.length - 1;
    setState(() {
      _blocks.replaceRange(index, index + 1, newBlocks);
      _editingIndex = lastIdx;
      _inlineCtrl.text = newBlocks.last.rawLine;
    });
    _commitToSource();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _splitting = false;
      if (mounted) _inlineFocus.requestFocus();
    });
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

  Future<void> _confirmDeleteBlock(int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer cette ligne ?'),
        content: const Text('Cette action est irréversible.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) _deleteBlock(index);
  }

  void _reorderBlocks(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    setState(() {
      final block = _blocks.removeAt(oldIndex);
      _blocks.insert(newIndex, block);
    });
    _commitToSource();
  }

  void _addBlockAfter(int index, EditorBlock block) {
    setState(() => _blocks.insert(index + 1, block));
    _commitToSource();
    // Auto-start editing the new block (not for image/blank blocks — they
    // have their own dedicated widget, no inline text editor).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (block.type != BlockType.blank && block.type != BlockType.image) {
        _startInlineEdit(index + 1);
      }
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

  /// Always add a new block after the current position.
  /// Used for block-level elements (section, bullet, conseil, note secrète)
  /// that must never be inserted inline.
  void _addNewBlock(String raw) {
    final insertIdx = (_editingIndex >= 0 ? _editingIndex : _lastEditedIndex)
        .clamp(-1, _blocks.length - 1);
    if (_editingIndex >= 0) _commitInlineEdit();
    _addBlockAfter(insertIdx, parseLine(raw));
  }

  /// Insert CookLang text at cursor in the currently edited block,
  /// or at the last edited block position if no block is being edited.
  void _insertAtCursor(String text) {
    final parsed = parseLine(text);
    // Full-line blocks (image) are always inserted as a new block.
    if (parsed.type == BlockType.image) {
      final insertAfter = _editingIndex >= 0
          ? _editingIndex
          : (_lastEditedIndex >= 0 && _lastEditedIndex < _blocks.length
                ? _lastEditedIndex
                : (_blocks.isNotEmpty ? _blocks.length - 1 : -1));
      _addBlockAfter(insertAfter, parsed);
      return;
    }
    if (_editingIndex >= 0) {
      // Currently editing — insert at cursor position.
      final sel = _inlineCtrl.selection;
      final current = _inlineCtrl.text;
      final insertPos = sel.isValid ? sel.baseOffset : current.length;
      _inlineCtrl.text =
          current.substring(0, insertPos) + text + current.substring(insertPos);
      _inlineCtrl.selection = TextSelection.collapsed(
        offset: insertPos + text.length,
      );
      return;
    }
    // No active inline editor — determine insert target.
    final insertIdx = _lastEditedIndex >= 0 && _lastEditedIndex < _blocks.length
        ? _lastEditedIndex
        : (_blocks.isNotEmpty ? _blocks.length - 1 : -1);
    // For inline tokens (parsed as paragraph), merge into the last edited
    // paragraph/bullet/continuation block at the saved cursor position.
    final lastBlock = insertIdx >= 0 ? _blocks[insertIdx] : null;
    final canInsertInline =
        parsed.type == BlockType.paragraph &&
        lastBlock != null &&
        (lastBlock.type == BlockType.paragraph ||
            lastBlock.type == BlockType.bullet ||
            lastBlock.type == BlockType.continuation ||
            lastBlock.type == BlockType.blank ||
            lastBlock.type == BlockType.comment);
    if (canInsertInline) {
      final current = _blocks[insertIdx].rawLine;
      final insertPos =
          _lastCursorOffset >= 0 && _lastCursorOffset <= current.length
          ? _lastCursorOffset
          : current.length;
      final newRaw =
          current.substring(0, insertPos) + text + current.substring(insertPos);
      final newBlock = parseLine(newRaw);
      final newCursor = insertPos + text.length;
      setState(() {
        _blocks[insertIdx] = newBlock;
        _editingIndex = insertIdx;
        _lastEditedIndex = insertIdx;
        _inlineCtrl.text = newRaw;
        _inlineCtrl.selection = TextSelection.collapsed(offset: newCursor);
      });
      _commitToSource();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _inlineFocus.requestFocus();
      });
    } else {
      _addBlockAfter(insertIdx, parsed);
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
          textInputAction: TextInputAction.done,
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) Navigator.pop(ctx, v.trim());
          },
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

  Future<void> _insertImage() async {
    // _editingIndex est déjà -1 ici : la perte de focus (tap sur toolbar)
    // a déjà appelé _commitInlineEdit. On utilise _lastEditedIndex.
    final insertAfter =
        _lastEditedIndex >= 0 && _lastEditedIndex < _blocks.length
        ? _lastEditedIndex
        : (_blocks.isNotEmpty ? _blocks.length - 1 : -1);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ImageInsertSheet(
        illustrationUrls: widget.illustrationUrls,
        onUploadImage: widget.onUploadImage,
        onInsert: (raw) {
          if (!mounted) return;
          final parsed = parseLine(raw);
          if (parsed.type == BlockType.image) {
            final actualIndex = insertAfter.clamp(-1, _blocks.length - 1);
            _addBlockAfter(actualIndex, parsed);
          }
        },
      ),
    );
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
            child: ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              buildDefaultDragHandles: false,
              itemCount: _blocks.length,
              itemBuilder: (ctx, i) {
                return KeyedSubtree(
                  key: ValueKey(i),
                  child: _buildBlockWidget(ctx, i),
                );
              },
              onReorder: widget.enabled ? _reorderBlocks : (_, _) {},
            ),
          ),
        ),
      ],
    );
  }

  // ── Toolbar ───────────────────────────────────────────────────────────────

  Widget _buildToolbar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _ToolbarButton(
              icon: Icons.eco_outlined,
              tooltip: 'Ingrédient',
              bgColor: cs.primaryContainer,
              iconColor: cs.onPrimaryContainer,
              onTap: _insertIngredient,
            ),
            _ToolbarButton(
              icon: Icons.kitchen_outlined,
              tooltip: 'Ustensile',
              bgColor: cs.tertiaryContainer,
              iconColor: cs.onTertiaryContainer,
              onTap: _insertUtensil,
            ),
            _ToolbarButton(
              icon: Icons.timer_outlined,
              tooltip: 'Minuteur',
              bgColor: cs.secondaryContainer,
              iconColor: cs.onSecondaryContainer,
              onTap: _insertTimer,
            ),
            const _ToolbarDivider(),
            _ToolbarButton(
              icon: Icons.title,
              tooltip: 'Section',
              bgColor: cs.surfaceContainerHighest,
              iconColor: cs.onSurface,
              onTap: () => _addNewBlock('== '),
            ),
            _ToolbarButton(
              icon: Icons.tips_and_updates_outlined,
              tooltip: 'Conseil',
              bgColor: cs.surfaceContainerHighest,
              iconColor: cs.secondary,
              onTap: () => _addNewBlock('> '),
            ),
            _ToolbarButton(
              icon: Icons.lock_outline,
              tooltip: 'Note secrète',
              bgColor: cs.surfaceContainerHighest,
              iconColor: cs.onSurfaceVariant,
              onTap: () => _addNewBlock('-- '),
            ),
            _ToolbarButton(
              icon: Icons.format_list_bulleted,
              tooltip: 'Liste',
              bgColor: cs.surfaceContainerHighest,
              iconColor: cs.onSurface,
              onTap: () => _addNewBlock('- '),
            ),
            const _ToolbarDivider(),
            _ToolbarButton(
              icon: Icons.image_outlined,
              tooltip: 'Image',
              bgColor: cs.surfaceContainerHighest,
              iconColor: cs.onSurface,
              onTap: _insertImage,
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
        onCancel: _cancelInlineEdit,
      );
    }

    switch (block.type) {
      case BlockType.metadata:
        // Masquer les clés gérées automatiquement (page, dish_types, page_type)
        if (_kHiddenMetaKeys.contains(block.metaKey?.toLowerCase())) {
          return const SizedBox.shrink();
        }
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
          index: index,
          enabled: widget.enabled,
          onTap: () => _startInlineEdit(index),
          onDelete: () => _confirmDeleteBlock(index),
        );
      case BlockType.comment:
        return _CommentBlockWidget(
          block: block,
          index: index,
          enabled: widget.enabled,
          onTap: () => _startInlineEdit(index),
          onDelete: () => _confirmDeleteBlock(index),
          onSegmentChanged: (segIdx, updated) =>
              _updateSegmentInBlock(index, segIdx, updated),
          onSegmentDeleted: (segIdx) => _deleteSegmentInBlock(index, segIdx),
        );
      case BlockType.bullet:
      case BlockType.paragraph:
        return _ParagraphBlockWidget(
          block: block,
          blockIndex: index,
          enabled: widget.enabled,
          onTap: () => _startInlineEdit(index),
          onDelete: () => _confirmDeleteBlock(index),
          onSegmentChanged: (segIdx, updated) =>
              _updateSegmentInBlock(index, segIdx, updated),
          onSegmentDeleted: (segIdx) => _deleteSegmentInBlock(index, segIdx),
        );
      case BlockType.continuation:
        return Container(
          margin: const EdgeInsets.only(left: 20),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: const Color(0xFF607D8B).withAlpha(120),
                width: 2,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: _ParagraphBlockWidget(
              block: block,
              blockIndex: index,
              enabled: widget.enabled,
              onTap: () => _startInlineEdit(index),
              onDelete: () => _confirmDeleteBlock(index),
              onSegmentChanged: (segIdx, updated) =>
                  _updateSegmentInBlock(index, segIdx, updated),
              onSegmentDeleted: (segIdx) =>
                  _deleteSegmentInBlock(index, segIdx),
            ),
          ),
        );
      case BlockType.image:
        return _ImageBlockWidget(
          block: block,
          index: index,
          enabled: widget.enabled,
          onPositionChanged: (pos) =>
              _updateBlock(index, block.withImagePosition(pos)),
          onWidthChanged: (w) => _updateBlock(index, block.withImageWidth(w)),
          onDelete: () => _confirmDeleteBlock(index),
        );
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Block sub-widgets
// ══════════════════════════════════════════════════════════════════════════════

/// Row showing a raw TextField for inline editing.
/// When the user presses Enter, [onNewLine] is called with the text before
/// and after the cursor so the parent can split the block.
class _InlineEditRow extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onDone;
  final VoidCallback onCancel;

  const _InlineEditRow({
    required this.controller,
    required this.focusNode,
    required this.onDone,
    required this.onCancel,
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
              textInputAction: TextInputAction.done,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                hintText: 'Saisir le contenu…',
              ),
              onChanged: (value) {
                if (value.contains('\n')) {
                  // Enter key pressed: strip newline and validate.
                  final cleaned = value.replaceAll('\n', '');
                  controller.value = TextEditingValue(
                    text: cleaned,
                    selection: TextSelection.collapsed(offset: cleaned.length),
                  );
                  onDone();
                }
              },
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
            icon: const Icon(Icons.close, size: 20),
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            tooltip: 'Annuler',
            onPressed: onCancel,
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
  final int index;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _SectionBlockWidget({
    required this.block,
    required this.index,
    required this.enabled,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return _BlockRow(
      index: index,
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
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Comment block: `-- note`
class _CommentBlockWidget extends StatelessWidget {
  final EditorBlock block;
  final int index;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final void Function(int segIdx, LineSegment updated)? onSegmentChanged;
  final void Function(int segIdx)? onSegmentDeleted;

  const _CommentBlockWidget({
    required this.block,
    required this.index,
    required this.enabled,
    required this.onTap,
    required this.onDelete,
    this.onSegmentChanged,
    this.onSegmentDeleted,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isConseil = block.rawLine.trimLeft().startsWith('>');
    final segments = block.segments;

    Widget contentWidget;
    if (isConseil && segments != null && segments.isNotEmpty) {
      contentWidget = Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (int i = 0; i < segments.length; i++)
            _buildSegment(context, i, segments[i], theme, isConseil),
        ],
      );
    } else {
      contentWidget = Text(
        block.plainText ?? '',
        style: TextStyle(
          fontSize: 13,
          fontStyle: FontStyle.italic,
          color: isConseil
              ? theme.colorScheme.onSecondaryContainer
              : theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    return _BlockRow(
      index: index,
      enabled: enabled,
      onTap: onTap,
      onDelete: onDelete,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isConseil
              ? theme.colorScheme.secondaryContainer.withAlpha(120)
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isConseil
                ? theme.colorScheme.secondary.withAlpha(80)
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isConseil ? Icons.tips_and_updates_outlined : Icons.lock_outline,
              size: 14,
              color: isConseil
                  ? theme.colorScheme.secondary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(child: contentWidget),
          ],
        ),
      ),
    );
  }

  Widget _buildSegment(
    BuildContext context,
    int segIdx,
    LineSegment seg,
    ThemeData theme,
    bool isConseil,
  ) {
    final textStyle = TextStyle(
      fontSize: 13,
      fontStyle: FontStyle.italic,
      color: isConseil
          ? theme.colorScheme.onSecondaryContainer
          : theme.colorScheme.onSurfaceVariant,
    );
    return switch (seg) {
      TextSegment(:final text) => Text(text, style: textStyle),
      IngredientSegment() => IngredientChipWidget(
        segment: seg,
        enabled: enabled,
        onChanged: onSegmentChanged != null
            ? (updated) => onSegmentChanged!(segIdx, updated)
            : null,
        onDelete: (enabled && onSegmentDeleted != null)
            ? () => onSegmentDeleted!(segIdx)
            : null,
      ),
      UtensilSegment() => UtensilChipWidget(
        segment: seg,
        enabled: enabled,
        onChanged: onSegmentChanged != null
            ? (updated) => onSegmentChanged!(segIdx, updated)
            : null,
        onDelete: (enabled && onSegmentDeleted != null)
            ? () => onSegmentDeleted!(segIdx)
            : null,
      ),
      TimerSegment() => TimerChipWidget(
        segment: seg,
        enabled: enabled,
        onChanged: onSegmentChanged != null
            ? (updated) => onSegmentChanged!(segIdx, updated)
            : null,
        onDelete: (enabled && onSegmentDeleted != null)
            ? () => onSegmentDeleted!(segIdx)
            : null,
      ),
    };
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
      index: blockIndex,
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
  final int index;
  final Widget child;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _BlockRow({
    required this.index,
    required this.child,
    required this.enabled,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Drag handle (left)
        if (enabled)
          ReorderableDragStartListener(
            index: index,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Icon(
                  Icons.drag_indicator,
                  size: 16,
                  color: Colors.grey.shade300,
                ),
              ),
            ),
          ),
        // Content
        Expanded(
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(4),
            child: child,
          ),
        ),
        // Delete button (right)
        if (enabled)
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 16),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            color: Colors.grey.shade400,
            tooltip: 'Supprimer',
            onPressed: onDelete,
          ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Insert sheets (simplified versions for toolbar buttons)
// ══════════════════════════════════════════════════════════════════════════════

// ── Image block widget ─────────────────────────────────────────────────────────

/// Affiche un bloc image avec miniature, indicateur de position et bouton suppr.
class _ImageBlockWidget extends StatelessWidget {
  final EditorBlock block;
  final int index;
  final bool enabled;
  final void Function(ImagePosition) onPositionChanged;
  final void Function(int?) onWidthChanged;
  final VoidCallback onDelete;

  const _ImageBlockWidget({
    required this.block,
    required this.index,
    required this.enabled,
    required this.onPositionChanged,
    required this.onWidthChanged,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final url = block.imageUrl ?? '';
    final pos = block.imagePosition ?? ImagePosition.after;
    final isFloat = pos == ImagePosition.left || pos == ImagePosition.right;
    final currentWidth = block.imageWidthPercent ?? 30;

    return _BlockRow(
      index: index,
      enabled: enabled,
      onTap: () {}, // pas d'édition inline
      onDelete: onDelete,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Miniature
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network(
                    url,
                    width: 64,
                    height: 48,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 64,
                      height: 48,
                      color: _kImageColor.withValues(alpha: 0.1),
                      child: const Icon(
                        Icons.broken_image_outlined,
                        color: _kImageColor,
                        size: 20,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Chips de position
                if (enabled)
                  Expanded(
                    child: Wrap(
                      spacing: 4,
                      children: ImagePosition.values.map((p) {
                        final label = switch (p) {
                          ImagePosition.left => 'Gauche',
                          ImagePosition.right => 'Droite',
                          ImagePosition.after => 'Après',
                        };
                        return ChoiceChip(
                          label: Text(
                            label,
                            style: const TextStyle(fontSize: 11),
                          ),
                          selected: pos == p,
                          selectedColor: _kImageColor.withValues(alpha: 0.15),
                          onSelected: (_) => onPositionChanged(p),
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                        );
                      }).toList(),
                    ),
                  )
                else
                  Text(switch (pos) {
                    ImagePosition.left => '← Gauche',
                    ImagePosition.right => 'Droite →',
                    ImagePosition.after => '↓ Après',
                  }, style: const TextStyle(fontSize: 12, color: _kImageColor)),
              ],
            ),
            // Chips de largeur (uniquement pour gauche/droite)
            if (enabled && isFloat) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                children: [20, 25, 30, 35, 40, 50].map((pct) {
                  return ChoiceChip(
                    label: Text('$pct%', style: const TextStyle(fontSize: 10)),
                    selected: currentWidth == pct,
                    selectedColor: _kImageColor.withValues(alpha: 0.15),
                    onSelected: (_) => onWidthChanged(pct),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Sheet d'insertion d'image ──────────────────────────────────────────────────

class _ImageInsertSheet extends StatefulWidget {
  final List<String> illustrationUrls;
  final Future<String?> Function(Uint8List bytes, String fileName)?
  onUploadImage;
  final void Function(String raw) onInsert;
  const _ImageInsertSheet({
    required this.illustrationUrls,
    required this.onInsert,
    this.onUploadImage,
  });

  @override
  State<_ImageInsertSheet> createState() => _ImageInsertSheetState();
}

class _ImageInsertSheetState extends State<_ImageInsertSheet> {
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
    } catch (_) {
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
              const Icon(Icons.image_outlined, color: _kImageColor),
              const SizedBox(width: 8),
              Text(
                'Insérer une image',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: _kImageColor,
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
                          color: selected ? _kImageColor : Colors.transparent,
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
                  foregroundColor: _kImageColor,
                  side: const BorderSide(color: _kImageColor),
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
                    color: _kImageColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            Slider(
              value: _widthPercent.toDouble(),
              min: 15,
              max: 60,
              divisions: 9,
              activeColor: _kImageColor,
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
                style: FilledButton.styleFrom(backgroundColor: _kImageColor),
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

class _IngredientInsertSheet extends StatefulWidget {
  @override
  State<_IngredientInsertSheet> createState() => _IngredientInsertSheetState();
}

class _IngredientInsertSheetState extends State<_IngredientInsertSheet> {
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
  final IconData icon;
  final String tooltip;
  final Color bgColor;
  final Color iconColor;
  final VoidCallback onTap;

  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.bgColor,
    required this.iconColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 17, color: iconColor),
          ),
        ),
      ),
    );
  }
}

class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider();

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
