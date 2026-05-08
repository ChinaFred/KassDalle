import 'package:flutter/material.dart';

/// Unified CookLang text editor used across recipe editing screens.
///
/// Set [showHelp] to true (draft review, manual create) to show a header with
/// the CookLang syntax tooltip. Leave false (validated recipe edit) for the
/// compact fullscreen variant.
///
/// Optionally provide [onProcessWithAI] to show an "IA" button in the header
/// row (used by the manual create screen to convert free text to CookLang).
class RecipeCooklangEditor extends StatelessWidget {
  final TextEditingController ctrl;
  final bool enabled;
  final bool showHelp;

  /// When non-null, an "IA" button is shown in the header row that calls this.
  final VoidCallback? onProcessWithAI;

  /// Shows a progress indicator on the AI button when true.
  final bool aiProcessing;

  const RecipeCooklangEditor({
    super.key,
    required this.ctrl,
    required this.enabled,
    this.showHelp = false,
    this.onProcessWithAI,
    this.aiProcessing = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!showHelp) {
      return TextField(
        controller: ctrl,
        enabled: enabled,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: const InputDecoration(
          hintText: 'Contenu CookLang…',
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.all(12),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('CookLang', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(width: 8),
            Tooltip(
              message:
                  'Format CookLang :\n'
                  '@ingredient{qté%unité}\n'
                  '#équipement{}\n'
                  '~{durée%unité}\n'
                  '>> clé: valeur',
              child: Icon(
                Icons.help_outline,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (onProcessWithAI != null) ...[
              const Spacer(),
              FilledButton.icon(
                onPressed: (enabled && !aiProcessing) ? onProcessWithAI : null,
                icon: aiProcessing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome, size: 16),
                label: const Text('Mettre en forme avec l\'IA'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TextField(
            controller: ctrl,
            enabled: enabled,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(
              hintText:
                  '>> titre: Ma recette\n'
                  '>> portions: 4\n\n'
                  'Mélangez @farine{200%g} et @oeufs{2}...',
              alignLabelWithHint: true,
            ),
          ),
        ),
      ],
    );
  }
}
