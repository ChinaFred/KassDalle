import 'dart:typed_data';
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

  /// Widget d'aperçu à afficher en mode [_EditorMode.preview].
  /// Si null, l'onglet Aperçu n'est pas affiché dans le toggle.
  final Widget? previewWidget;

  /// URLs des illustrations détectées — transmises au [CooklangVisualEditor]
  /// pour le picker image.
  final List<String> illustrationUrls;

  /// When non-null, an AI action button is shown in the header row.
  final VoidCallback? onProcessWithAI;

  /// Corrige l orthographe de la prose seule, sans toucher aux balises.
  ///
  /// Action distincte de [onProcessWithAI] : celle-ci reecrit le document
  /// entier, celle-la ne touche qu au texte entre les jetons.
  final VoidCallback? onPolishProse;

  /// Tooltip affiché au survol du bouton IA.
  final String aiTooltip;

  /// Shows a progress indicator on the AI button when true.
  final bool aiProcessing;

  /// Correction orthographique en cours.
  final bool prosePolishing;

  /// Callback pour uploader une image depuis la galerie dans l'éditeur visuel.
  /// Transmis à [CooklangVisualEditor] → [_ImageInsertSheet].
  final Future<String?> Function(Uint8List bytes, String fileName)?
  onUploadImage;

  const HybridRecipeEditor({
    super.key,
    required this.ctrl,
    required this.enabled,
    this.showHelp = false,
    this.previewWidget,
    this.illustrationUrls = const [],
    this.onProcessWithAI,
    this.onPolishProse,
    this.aiTooltip = 'Ameliorer la recette avec l\'IA',
    this.aiProcessing = false,
    this.prosePolishing = false,
    this.onUploadImage,
  });

  @override
  State<HybridRecipeEditor> createState() => _HybridRecipeEditorState();
}

enum _EditorMode { text, visual, preview }

// Clés de métadonnées masquées en mode texte (gérées automatiquement par l'IA)
const _kHiddenMetaPrefixes = ['>> page:', '>> dish_types:', '>> page_type:'];

String _filterHiddenMeta(String text) {
  return text
      .split('\n')
      .where(
        (line) => !_kHiddenMetaPrefixes.any(
          (p) => line.trimLeft().toLowerCase().startsWith(p.toLowerCase()),
        ),
      )
      .join('\n');
}

List<String> _extractHiddenMetaLines(String text) {
  return text
      .split('\n')
      .where(
        (line) => _kHiddenMetaPrefixes.any(
          (p) => line.trimLeft().toLowerCase().startsWith(p.toLowerCase()),
        ),
      )
      .toList();
}

String _reinjectHiddenMeta(String filteredText, String fullText) {
  final hidden = _extractHiddenMetaLines(fullText);
  if (hidden.isEmpty) return filteredText;
  // Réinjecte les lignes cachées au début du texte
  final prefix = hidden.join('\n');
  return '$prefix\n$filteredText';
}

class _HybridRecipeEditorState extends State<HybridRecipeEditor> {
  _EditorMode _mode = _EditorMode.visual;
  late final CooklangSyntaxController _syntaxCtrl;

  @override
  void initState() {
    super.initState();
    // Le syntax controller affiche le texte filtré (sans les métas cachées).
    _syntaxCtrl = CooklangSyntaxController()
      ..text = _filterHiddenMeta(widget.ctrl.text);
    _syntaxCtrl.addListener(_onSyntaxCtrlChanged);
    widget.ctrl.addListener(_onSourceCtrlChanged);
  }

  @override
  void didUpdateWidget(HybridRecipeEditor old) {
    super.didUpdateWidget(old);
    if (old.ctrl != widget.ctrl) {
      old.ctrl.removeListener(_onSourceCtrlChanged);
      widget.ctrl.addListener(_onSourceCtrlChanged);
      final filtered = _filterHiddenMeta(widget.ctrl.text);
      if (_syntaxCtrl.text != filtered) {
        _syncingFromSource = true;
        _syntaxCtrl.text = filtered;
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
    // Réinjecte les lignes cachées avant d'écrire dans le source ctrl
    final fullText = _reinjectHiddenMeta(_syntaxCtrl.text, widget.ctrl.text);
    if (fullText == widget.ctrl.text) return;
    _syncingFromSyntax = true;
    widget.ctrl.text = fullText;
    _syncingFromSyntax = false;
  }

  void _onSourceCtrlChanged() {
    if (_syncingFromSyntax) return;
    // Affiche uniquement le texte filtré dans le mode texte
    final filtered = _filterHiddenMeta(widget.ctrl.text);
    if (filtered == _syntaxCtrl.text) return;
    _syncingFromSource = true;
    _syntaxCtrl.text = filtered;
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
          child: switch (_mode) {
            _EditorMode.text => _buildTextMode(),
            _EditorMode.visual => _buildVisualMode(),
            _EditorMode.preview => _buildPreviewMode(),
          },
        ),
      ],
    );
  }

  // ── Header bar ────────────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 480;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            children: [
              // ── AI button (left, prominent) ────────────────────────────────
              if (widget.onProcessWithAI != null)
                Tooltip(
                  message: widget.aiTooltip,
                  child: FilledButton(
                    onPressed: (widget.enabled && !widget.aiProcessing)
                        ? widget.onProcessWithAI
                        : null,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 10 : 12,
                        vertical: 4,
                      ),
                      minimumSize: const Size(36, 36),
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                    child: widget.aiProcessing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.auto_awesome, size: 16),
                              if (!compact) ...[
                                const SizedBox(width: 6),
                                const Text('IA'),
                              ],
                            ],
                          ),
                  ),
                ),

              // ── Orthographe de la prose ────────────────────────────────────
              if (widget.onPolishProse != null)
                IconButton(
                  icon: widget.prosePolishing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.spellcheck, size: 18),
                  tooltip:
                      'Corriger l\'orthographe du texte des étapes '
                      '(les balises ne sont pas touchées)',
                  visualDensity: VisualDensity.compact,
                  onPressed: (widget.enabled && !widget.prosePolishing)
                      ? widget.onPolishProse
                      : null,
                ),

              // ── Help button ──────────────────────────────────────────────────
              if (widget.showHelp)
                IconButton(
                  icon: const Icon(Icons.help_outline, size: 18),
                  tooltip: 'Guide de rédaction Cooklang',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  onPressed: () => CooklangHelpPage.showAsSheet(context),
                ),

              const Spacer(),

              // ── Mode toggle (right, discrete) ─────────────────────────────
              _ModeToggle(
                mode: _mode,
                hasPreview: widget.previewWidget != null,
                onChanged: (m) => setState(() => _mode = m),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Text mode ─────────────────────────────────────────────────────────────

  Widget _buildTextMode() {
    return Container(
      color: Colors.white,
      child: TextField(
        controller: _syntaxCtrl,
        enabled: widget.enabled,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          color: Colors.black87,
        ),
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
          fillColor: Colors.white,
          filled: true,
        ),
      ),
    );
  }

  // ── Visual mode ───────────────────────────────────────────────────────────

  Widget _buildVisualMode() {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: CooklangVisualEditor(
        ctrl: widget.ctrl,
        enabled: widget.enabled,
        illustrationUrls: widget.illustrationUrls,
        onUploadImage: widget.onUploadImage,
      ),
    );
  }

  // ── Preview mode ─────────────────────────────────────────────────────────────────────

  Widget _buildPreviewMode() {
    return widget.previewWidget ?? const SizedBox.shrink();
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// _ModeToggle
// ══════════════════════════════════════════════════════════════════════════════

class _ModeToggle extends StatelessWidget {
  final _EditorMode mode;
  final bool hasPreview;
  final ValueChanged<_EditorMode> onChanged;

  const _ModeToggle({
    required this.mode,
    required this.hasPreview,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget modeBtn(IconData icon, String tip, _EditorMode m) {
      final selected = mode == m;
      return Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => onChanged(m),
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

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        modeBtn(Icons.view_agenda_outlined, 'Visuel', _EditorMode.visual),
        modeBtn(Icons.code, 'Texte', _EditorMode.text),
        if (hasPreview)
          modeBtn(Icons.visibility_outlined, 'Aperçu', _EditorMode.preview),
      ],
    );
  }
}
