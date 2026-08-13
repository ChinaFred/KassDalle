import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'cooklang_block_model.dart';
import 'cooklang_block_widgets.dart';
import 'cooklang_editor_colors.dart';
import 'cooklang_insert_sheets.dart';
import 'cooklang_toolbar.dart';

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
  final bool _splitting = false;

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

  /// Callback de [ReorderableListView.onReorderItem] : [newIndex] est déjà
  /// ajusté pour le bloc retiré, pas de décrément manuel.
  void _reorderBlocks(int oldIndex, int newIndex) {
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
      builder: (_) => CooklangIngredientInsertSheet(),
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
            Icon(Icons.kitchen_outlined, color: kCooklangUtensilColor),
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
            style: FilledButton.styleFrom(
              backgroundColor: kCooklangUtensilColor,
            ),
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
      builder: (_) => CooklangTimerInsertSheet(),
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
      builder: (_) => CooklangImageInsertSheet(
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
              onReorderItem: widget.enabled ? _reorderBlocks : (_, _) {},
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
            CooklangToolbarButton(
              icon: Icons.eco_outlined,
              tooltip: 'Ingrédient',
              bgColor: cs.primaryContainer,
              iconColor: cs.onPrimaryContainer,
              onTap: _insertIngredient,
            ),
            CooklangToolbarButton(
              icon: Icons.kitchen_outlined,
              tooltip: 'Ustensile',
              bgColor: cs.tertiaryContainer,
              iconColor: cs.onTertiaryContainer,
              onTap: _insertUtensil,
            ),
            CooklangToolbarButton(
              icon: Icons.timer_outlined,
              tooltip: 'Minuteur',
              bgColor: cs.secondaryContainer,
              iconColor: cs.onSecondaryContainer,
              onTap: _insertTimer,
            ),
            const CooklangToolbarDivider(),
            CooklangToolbarButton(
              icon: Icons.title,
              tooltip: 'Section',
              bgColor: cs.surfaceContainerHighest,
              iconColor: cs.onSurface,
              onTap: () => _addNewBlock('== '),
            ),
            CooklangToolbarButton(
              icon: Icons.tips_and_updates_outlined,
              tooltip: 'Conseil',
              bgColor: cs.surfaceContainerHighest,
              iconColor: cs.secondary,
              onTap: () => _addNewBlock('> '),
            ),
            CooklangToolbarButton(
              icon: Icons.lock_outline,
              tooltip: 'Note secrète',
              bgColor: cs.surfaceContainerHighest,
              iconColor: cs.onSurfaceVariant,
              onTap: () => _addNewBlock('-- '),
            ),
            CooklangToolbarButton(
              icon: Icons.format_list_bulleted,
              tooltip: 'Liste',
              bgColor: cs.surfaceContainerHighest,
              iconColor: cs.onSurface,
              onTap: () => _addNewBlock('- '),
            ),
            const CooklangToolbarDivider(),
            CooklangToolbarButton(
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
      return CooklangInlineEditRow(
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
        return CooklangMetadataBlock(
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
        return CooklangSectionBlock(
          block: block,
          index: index,
          enabled: widget.enabled,
          onTap: () => _startInlineEdit(index),
          onDelete: () => _confirmDeleteBlock(index),
        );
      case BlockType.comment:
        return CooklangCommentBlock(
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
        return CooklangParagraphBlock(
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
            child: CooklangParagraphBlock(
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
        return CooklangImageBlock(
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
