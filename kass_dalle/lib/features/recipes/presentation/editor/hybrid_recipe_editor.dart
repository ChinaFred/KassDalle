import 'package:flutter/material.dart';
import 'cooklang_syntax_controller.dart';
import 'cooklang_visual_editor.dart';
import 'cooklang_help_page.dart';

// ══════════════════════════════════════════════════════════════════════════════
// HybridRecipeEditor
// ══════════════════════════════════════════════════════════════════════════════

/// Unified hybrid recipe editor (WYSIWYG ↔ raw CookLang text).
///
/// Drop-in replacement for [RecipeCooklangEditor]. Accepts the same
/// [ctrl] source-of-truth [TextEditingController] and exposes the same
/// [enabled], [showHelp], [onProcessWithAI] and [aiProcessing] surface.
///
/// The toggle bar at the top lets the user switch between:
///   - [_EditorMode.text]   : monospace TextField with live syntax highlighting
///   - [_EditorMode.visual] : WYSIWYG block-based editor with chips
///
/// Switching modes is instant and lossless — both modes share [ctrl].
class HybridRecipeEditor extends StatefulWidget {
  final TextEditingController ctrl;
  final bool enabled;
  final bool showHelp;

  /// When non-null, an AI action button is shown in the header row.
  final VoidCallback? onProcessWithAI;

  /// Shows a progress indicator on the AI button when true.
  final bool aiProcessing;

  const HybridRecipeEditor({
    super.key,
    required this.ctrl,
    required this.enabled,
    this.showHelp = false,
    this.onProcessWithAI,
    this.aiProcessing = false,
  });

  @override
  State<HybridRecipeEditor> createState() => _HybridRecipeEditorState();
}

enum _EditorMode { text, visual }

class _HybridRecipeEditorState extends State<HybridRecipeEditor> {
  _EditorMode _mode = _EditorMode.visual;
  late final CooklangSyntaxController _syntaxCtrl;

  @override
  void initState() {
    super.initState();
    // The syntax controller mirrors widget.ctrl — they share the same text.
    _syntaxCtrl = CooklangSyntaxController()..text = widget.ctrl.text;
    _syntaxCtrl.addListener(_onSyntaxCtrlChanged);
    widget.ctrl.addListener(_onSourceCtrlChanged);
  }

  @override
  void didUpdateWidget(HybridRecipeEditor old) {
    super.didUpdateWidget(old);
    if (old.ctrl != widget.ctrl) {
      old.ctrl.removeListener(_onSourceCtrlChanged);
      widget.ctrl.addListener(_onSourceCtrlChanged);
      if (_syntaxCtrl.text != widget.ctrl.text) {
        _syncingFromSource = true;
        _syntaxCtrl.text = widget.ctrl.text;
        _syncingFromSource = false;
      }
    }
  }

  @override
  void dispose() {
    _syntaxCtrl.removeListener(_onSyntaxCtrlChanged);
    widget.ctrl.removeListener(_onSourceCtrlChanged);
    _syntaxCtrl.dispose();
    super.dispose();
  }

  // ── Two-way sync between the syntax controller and the source controller ──

  bool _syncingFromSource = false;
  bool _syncingFromSyntax = false;

  void _onSyntaxCtrlChanged() {
    if (_syncingFromSource) return;
    if (_syntaxCtrl.text == widget.ctrl.text) return;
    _syncingFromSyntax = true;
    widget.ctrl.text = _syntaxCtrl.text;
    _syncingFromSyntax = false;
  }

  void _onSourceCtrlChanged() {
    if (_syncingFromSyntax) return;
    if (widget.ctrl.text == _syntaxCtrl.text) return;
    _syncingFromSource = true;
    _syntaxCtrl.text = widget.ctrl.text;
    _syncingFromSource = false;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        Expanded(
          child: _mode == _EditorMode.text
              ? _buildTextMode()
              : _buildVisualMode(),
        ),
      ],
    );
  }

  // ── Header bar ────────────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          // ── Mode toggle ──────────────────────────────────────────────────
          _ModeToggle(
            mode: _mode,
            onChanged: (m) => setState(() => _mode = m),
          ),
          const SizedBox(width: 8),

          // ── Help button ──────────────────────────────────────────────────
          if (widget.showHelp)
            IconButton(
              icon: const Icon(Icons.help_outline, size: 18),
              tooltip: 'Guide de rédaction Cooklang',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              onPressed: () => CooklangHelpPage.showAsSheet(context),
            ),

          const Spacer(),

          // ── AI button ────────────────────────────────────────────────────
          if (widget.onProcessWithAI != null)
            FilledButton.icon(
              onPressed: (widget.enabled && !widget.aiProcessing)
                  ? widget.onProcessWithAI
                  : null,
              icon: widget.aiProcessing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome, size: 16),
              label: const Text('IA'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                textStyle: const TextStyle(fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }

  // ── Text mode ─────────────────────────────────────────────────────────────

  Widget _buildTextMode() {
    return TextField(
      controller: _syntaxCtrl,
      enabled: widget.enabled,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      decoration: InputDecoration(
        hintText: widget.showHelp
            ? '>> titre: Ma recette\n'
                '>> portions: 4\n\n'
                '## Préparation\n'
                'Dans un #bol, mélanger @farine{200%g}…'
            : 'Contenu CookLang…',
        alignLabelWithHint: widget.showHelp,
        border: const OutlineInputBorder(borderRadius: BorderRadius.zero),
        contentPadding: const EdgeInsets.all(12),
      ),
    );
  }

  // ── Visual mode ───────────────────────────────────────────────────────────

  Widget _buildVisualMode() {
    return CooklangVisualEditor(
      ctrl: widget.ctrl,
      enabled: widget.enabled,
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// _ModeToggle
// ══════════════════════════════════════════════════════════════════════════════

class _ModeToggle extends StatelessWidget {
  final _EditorMode mode;
  final ValueChanged<_EditorMode> onChanged;

  const _ModeToggle({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<_EditorMode>(
      segments: const [
        ButtonSegment(
          value: _EditorMode.visual,
          label: Text('Visuel'),
          icon: Icon(Icons.auto_awesome_outlined, size: 15),
        ),
        ButtonSegment(
          value: _EditorMode.text,
          label: Text('Texte'),
          icon: Icon(Icons.code, size: 15),
        ),
      ],
      selected: {mode},
      onSelectionChanged: (s) => onChanged(s.first),
      style: SegmentedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
        textStyle: const TextStyle(fontSize: 12),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
