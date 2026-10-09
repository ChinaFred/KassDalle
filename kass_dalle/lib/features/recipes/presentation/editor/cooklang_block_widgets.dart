import 'package:flutter/material.dart';
import 'cooklang_block_model.dart';
import 'cooklang_chip_widgets.dart';
import 'cooklang_editor_colors.dart';
import '../../../../core/theme/app_icon_size.dart';
import '../../../../core/widgets/app_network_image.dart';

class CooklangInlineEditRow extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onDone;
  final VoidCallback onCancel;

  const CooklangInlineEditRow({
    super.key,
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
            icon: const Icon(
              Icons.check_circle_outline,
              size: AppIconSize.small,
            ),
            color: Theme.of(context).colorScheme.primary,
            tooltip: 'Valider',
            onPressed: onDone,
          ),
          IconButton(
            icon: const Icon(Icons.close, size: AppIconSize.small),
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
class CooklangMetadataBlock extends StatefulWidget {
  final EditorBlock block;
  final bool enabled;
  final void Function(String key, String value) onChanged;

  const CooklangMetadataBlock({
    super.key,
    required this.block,
    required this.enabled,
    required this.onChanged,
  });

  @override
  State<CooklangMetadataBlock> createState() => _CooklangMetadataBlockState();
}

class _CooklangMetadataBlockState extends State<CooklangMetadataBlock> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.block.metaValue ?? '');
  }

  @override
  void didUpdateWidget(CooklangMetadataBlock old) {
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
                color: kCooklangMetaColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: _ctrl,
              enabled: widget.enabled,
              style: TextStyle(fontSize: 13, color: kCooklangMetaColor),
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
                    color: kCooklangMetaColor.withValues(alpha: 0.4),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(
                    color: kCooklangMetaColor.withValues(alpha: 0.3),
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
class CooklangSectionBlock extends StatelessWidget {
  final EditorBlock block;
  final int index;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const CooklangSectionBlock({
    super.key,
    required this.block,
    required this.index,
    required this.enabled,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return CooklangBlockRow(
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
class CooklangCommentBlock extends StatelessWidget {
  final EditorBlock block;
  final int index;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final void Function(int segIdx, LineSegment updated)? onSegmentChanged;
  final void Function(int segIdx)? onSegmentDeleted;

  const CooklangCommentBlock({
    super.key,
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

    return CooklangBlockRow(
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
              size: AppIconSize.inline,
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
class CooklangParagraphBlock extends StatelessWidget {
  final EditorBlock block;
  final int blockIndex;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final void Function(int segIdx, LineSegment updated) onSegmentChanged;
  final void Function(int segIdx) onSegmentDeleted;

  const CooklangParagraphBlock({
    super.key,
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

    return CooklangBlockRow(
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
class CooklangBlockRow extends StatelessWidget {
  final int index;
  final Widget child;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const CooklangBlockRow({
    super.key,
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
                  size: AppIconSize.inline,
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
            icon: const Icon(Icons.delete_outline, size: AppIconSize.inline),
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
class CooklangImageBlock extends StatelessWidget {
  final EditorBlock block;
  final int index;
  final bool enabled;
  final void Function(ImagePosition) onPositionChanged;
  final void Function(int?) onWidthChanged;
  final VoidCallback onDelete;

  const CooklangImageBlock({
    super.key,
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

    return CooklangBlockRow(
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
                  child: AppNetworkImage(
                    imageUrl: url,
                    width: 64,
                    height: 48,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => Container(
                      width: 64,
                      height: 48,
                      color: kCooklangImageColor.withValues(alpha: 0.1),
                      child: const Icon(
                        Icons.broken_image_outlined,
                        color: kCooklangImageColor,
                        size: AppIconSize.small,
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
                          selectedColor: kCooklangImageColor.withValues(
                            alpha: 0.15,
                          ),
                          onSelected: (_) => onPositionChanged(p),
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                        );
                      }).toList(),
                    ),
                  )
                else
                  Text(
                    switch (pos) {
                      ImagePosition.left => '← Gauche',
                      ImagePosition.right => 'Droite →',
                      ImagePosition.after => '↓ Après',
                    },
                    style: const TextStyle(
                      fontSize: 12,
                      color: kCooklangImageColor,
                    ),
                  ),
              ],
            ),
            // Chips de largeur (uniquement pour gauche/droite)
            if (enabled && isFloat) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                children: [5, 10, 20, 25, 30, 35, 40, 50].map((pct) {
                  return ChoiceChip(
                    label: Text('$pct%', style: const TextStyle(fontSize: 10)),
                    selected: currentWidth == pct,
                    selectedColor: kCooklangImageColor.withValues(alpha: 0.15),
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
