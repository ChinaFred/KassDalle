import 'package:flutter/material.dart';
import 'cooklang_editor_colors.dart';
import 'package:flutter/services.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/theme/app_icon_size.dart';

/// Standalone help page explaining the Cooklang + Markdown syntax.
///
/// Can be pushed as a full route or wrapped in a BottomSheet / Dialog.
/// Pass [asPage] = false to render without a Scaffold (for embedding).
class CooklangHelpPage extends StatelessWidget {
  final bool asPage;
  const CooklangHelpPage({super.key, this.asPage = true});

  @override
  Widget build(BuildContext context) {
    final content = _HelpContent();
    if (!asPage) return content;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Guide de rédaction'),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Fermer',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
      body: content,
    );
  }

  /// Show as a DraggableScrollableSheet bottom-sheet.
  static Future<void> showAsSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 1.0,
        builder: (ctx, ctrl) => Column(
          children: [
            // Drag handle
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.outline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Text(
                    '📖 Guide de rédaction',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Fermer le guide',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _HelpContent(scrollController: ctrl)),
          ],
        ),
      ),
    );
  }
}

// ── Content widget ─────────────────────────────────────────────────────────────

class _HelpContent extends StatelessWidget {
  final ScrollController? scrollController;
  const _HelpContent({this.scrollController});

  @override
  Widget build(BuildContext context) {
    final p = CooklangPalette.ofContext(context);
    final cs = Theme.of(context).colorScheme;
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.all(20),
      children: [
        // ── Introduction ──────────────────────────────────────────────────
        _Intro(),
        const SizedBox(height: 24),

        // ── 1. Ingrédients ────────────────────────────────────────────────
        _SectionTitle(
          number: '1',
          title: 'Les Ingrédients',
          icon: '🥬',
          color: p.ingredient,
        ),
        const SizedBox(height: 10),
        const Text(
          'Pour ajouter un ingrédient, commencez par le symbole @.',
          style: TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 12),
        _RuleRow(
          raw: '@farine',
          hint: 'Un seul mot (s\'arrête au premier espace)',
          chipLabel: 'farine',
          chipColor: p.ingredient,
          chipIcon: '🥬',
        ),
        _RuleRow(
          raw: '@sucre vanillé{}',
          hint: 'Plusieurs mots : accolades vides',
          chipLabel: 'sucre vanillé',
          chipColor: p.ingredient,
          chipIcon: '🥬',
        ),
        _RuleRow(
          raw: '@lait{500%ml}',
          hint: 'Quantité et unité : @nom{qté%unité}',
          chipLabel: 'lait 500 ml',
          chipColor: p.ingredient,
          chipIcon: '🥬',
        ),
        _RuleRow(
          raw: '@œufs{3}',
          hint: 'Quantité seule (sans unité)',
          chipLabel: 'œufs 3',
          chipColor: p.ingredient,
          chipIcon: '🥬',
        ),
        const SizedBox(height: 24),

        // ── 2. Ustensiles ─────────────────────────────────────────────────
        _SectionTitle(
          number: '2',
          title: 'Les Ustensiles',
          icon: '🍳',
          color: p.utensil,
        ),
        const SizedBox(height: 10),
        const Text(
          'Pour répertorier le matériel, utilisez le symbole #.',
          style: TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 12),
        _RuleRow(
          raw: '#mixeur',
          hint: 'Un seul mot',
          chipLabel: 'mixeur',
          chipColor: p.utensil,
          chipIcon: '🍳',
        ),
        _RuleRow(
          raw: '#moule à cake{}',
          hint: 'Plusieurs mots : accolades vides',
          chipLabel: 'moule à cake',
          chipColor: p.utensil,
          chipIcon: '🍳',
        ),
        const SizedBox(height: 24),

        // ── 3. Minuteurs ──────────────────────────────────────────────────
        _SectionTitle(
          number: '3',
          title: 'Les Durées et Minuteurs',
          icon: '⏱',
          color: p.timer,
        ),
        const SizedBox(height: 10),
        const Text(
          'Pour marquer une durée, utilisez le symbole ~. Elle est mise en '
          'évidence dans l\'étape et reprise dans l\'export PDF.',
          style: TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 12),
        _RuleRow(
          raw: '~{30%minutes}',
          hint: 'Minuteur simple : ~{durée%unité}',
          chipLabel: '30 minutes',
          chipColor: p.timer,
          chipIcon: '⏱',
        ),
        _RuleRow(
          raw: '~pétrissage{10%minutes}',
          hint: 'Minuteur nommé : ~nom{durée%unité}',
          chipLabel: 'pétrissage 10 minutes',
          chipColor: p.timer,
          chipIcon: '⏱',
        ),
        const SizedBox(height: 24),

        // ── 4. Sections ───────────────────────────────────────────────────
        _SectionTitle(
          number: '4',
          title: 'Organiser avec des Sections',
          icon: '📌',
          color: p.section,
        ),
        const SizedBox(height: 10),
        const Text(
          'Pour structurer votre recette en plusieurs parties, utilisez ## suivi d\'un espace.',
          style: TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 12),
        _CodeBlock(code: '## Préparation de la pâte\n## Cuisson et dressage'),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: cs.tertiaryContainer,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: cs.tertiary),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('⚠️ ', style: TextStyle(fontSize: 15)),
              Expanded(
                child: Text(
                  'N\'oubliez pas l\'espace après ##. '
                  'Sans espace, l\'application pense que vous parlez d\'un ustensile !',
                  style: TextStyle(fontSize: 13, color: cs.onTertiaryContainer),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // ── 5. Formatage Markdown ─────────────────────────────────────────
        _SectionTitle(
          number: '5',
          title: 'Mise en forme du texte (Markdown)',
          icon: '✍️',
          color: p.continuation,
        ),
        const SizedBox(height: 10),
        _RuleRow(
          raw: '**Mélanger vigoureusement**',
          hint: 'Gras : entourez de **deux étoiles**',
          chipLabel: null,
          preview: Text(
            'Mélanger vigoureusement',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          chipColor: p.continuation,
          chipIcon: null,
        ),
        _RuleRow(
          raw: '*Servir préchauffé*',
          hint: 'Italique : entourez d\'*une étoile*',
          chipLabel: null,
          preview: Text(
            'Servir préchauffé',
            style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 13),
          ),
          chipColor: p.continuation,
          chipIcon: null,
        ),
        _RuleRow(
          raw: '- Ma remarque',
          hint: 'Liste : commencez par "- " (tiret espace)',
          chipLabel: null,
          preview: Row(
            children: [
              const Text(
                '• ',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              ),
              const Text('Ma remarque', style: TextStyle(fontSize: 13)),
            ],
          ),
          chipColor: p.continuation,
          chipIcon: null,
        ),
        const SizedBox(height: 24),

        // ── 6. Commentaires ───────────────────────────────────────────────
        _SectionTitle(
          number: '6',
          title: 'Notes secrètes (Commentaires)',
          icon: '💬',
          color: p.comment,
        ),
        const SizedBox(height: 10),
        const Text(
          'Pour écrire une note privée qui n\'apparaît pas en mode lecture, '
          'commencez la ligne par deux tirets :',
          style: TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 12),
        _RuleRow(
          raw: '-- Recette de grand-mère, sept. 2024',
          hint: 'Visible uniquement en mode édition',
          chipLabel: null,
          preview: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: p.comment.withValues(alpha: 0.08),
              border: Border(left: BorderSide(color: p.comment, width: 3)),
            ),
            child: Text(
              '💬 Recette de grand-mère, sept. 2024',
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: p.comment,
              ),
            ),
          ),
          chipColor: p.comment,
          chipIcon: null,
        ),
        const SizedBox(height: 24),

        // ── Métadonnées ────────────────────────────────────────────────────
        _SectionTitle(
          number: '7',
          title: 'Métadonnées de la recette',
          icon: '⚙️',
          color: p.meta,
        ),
        const SizedBox(height: 10),
        const Text(
          'Des informations structurées peuvent être ajoutées en tête de recette avec >>',
          style: TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 12),
        _CodeBlock(
          code:
              '>> titre: Crêpes bretonnes\n'
              '>> portions: 4\n'
              '>> source: Recettes de Bretagne\n'
              '>> prep_time: 10 min\n'
              '>> cook_time: 30 min',
        ),
        const SizedBox(height: 32),

        // ── 8. Images ───────────────────────────────────────────────
        _SectionTitle(
          number: '8',
          title: 'Insérer une Image',
          icon: '🖼️',
          color: p.image,
        ),
        const SizedBox(height: 10),
        const Text(
          'Pour insérer une image dans le corps de la recette, '
          'utilisez la syntaxe `![position](url)` sur sa propre ligne. '
          'La position détermine l’alignement de l’image.',
          style: TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 12),
        _RuleRow(
          raw: '![after](https://...)',
          hint: 'Image pleine largeur après l’étape',
          chipLabel: null,
          preview: Row(
            children: [
              Icon(
                Icons.image_outlined,
                size: AppIconSize.small,
                color: p.image,
              ),
              const SizedBox(width: 6),
              Text(
                'Image — pleine largeur',
                style: TextStyle(
                  fontSize: 12,
                  color: p.image,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
          chipColor: p.image,
        ),
        _RuleRow(
          raw: '![left](https://...)',
          hint: 'Image alignée à gauche (position=left)',
          chipLabel: null,
          preview: Row(
            children: [
              Icon(
                Icons.image_outlined,
                size: AppIconSize.small,
                color: p.image,
              ),
              const SizedBox(width: 6),
              Text(
                'Image — gauche',
                style: TextStyle(
                  fontSize: 12,
                  color: p.image,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
          chipColor: p.image,
        ),
        Container(
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: p.image.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.image.withValues(alpha: 0.3)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('💡 ', style: TextStyle(fontSize: 14)),
              Expanded(
                child: Text(
                  'En pratique, utilisez le bouton 🖼️ dans la barre d’outils '
                  'pour insérer une image depuis votre galerie — la syntaxe '
                  'est générée automatiquement.',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // ── 9. Continuation d’étape ─────────────────────────────────────
        _SectionTitle(
          number: '9',
          title: 'Continuation d’étape',
          icon: '↳',
          color: p.continuation,
        ),
        const SizedBox(height: 10),
        const Text(
          'Pour ajouter une ligne visuelle à la même étape numérotée '
          '(sans créer un nouveau numéro), commencez la ligne par `+ ` (plus espace).',
          style: TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 12),
        _RuleRow(
          raw: '+ La pâte doit être lisse et souple.',
          hint: 'Continuation de l’étape précédente (même numéro)',
          chipLabel: null,
          preview: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: p.continuation.withValues(alpha: 0.5),
                  width: 2,
                ),
              ),
            ),
            child: Text(
              '↳ La pâte doit être lisse et souple.',
              style: TextStyle(fontSize: 12, color: p.continuation),
            ),
          ),
          chipColor: p.continuation,
        ),
        const SizedBox(height: 8),
        _CodeBlock(
          code:
              'Pétrir la @pâte{} avec les mains pendant ~{10%minutes}.\n'
              '+ La pâte doit être lisse, souple et ne pas coller aux mains.\n'
              '+ Former une boule et laisser reposer à couvert.',
        ),
        Container(
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: p.continuation.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.continuation.withValues(alpha: 0.3)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('💡 ', style: TextStyle(fontSize: 14)),
              Expanded(
                child: Text(
                  'En prévisualisation, les lignes `+` apparaîssent rattachées '
                  'à la même étape numérotée, sur des lignes distinctes.',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),

        // ── Exemple complet ────────────────────────────────────────────────
        const Divider(),
        const SizedBox(height: 16),
        Text(
          '📝 Exemple complet',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        _FullExampleBlock(),
        const SizedBox(height: 32),
      ],
    );
  }
}

// ── Helper widgets ─────────────────────────────────────────────────────────────

class _Intro extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '📖 Guide de Rédaction : Cooklang & Markdown',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.primaryContainer.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Text(
            'Bienvenue dans l\'éditeur de recettes ! Notre application utilise un format '
            'qui sépare automatiquement vos ingrédients, vos ustensiles et vos temps de '
            'cuisson du reste du texte : les ingrédients alimentent la liste de courses '
            'et le calcul nutritionnel, les durées sont mises en évidence dans les '
            'étapes.\n\n'
            'Voici les quelques règles simples à connaître pour rédiger vos recettes comme un chef.',
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String number;
  final String title;
  final String icon;
  final Color color;

  const _SectionTitle({
    required this.number,
    required this.title,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Center(
            child: Text(
              number,
              style: TextStyle(
                color: Theme.of(context).colorScheme.surface,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '$icon $title',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _RuleRow extends StatelessWidget {
  final String raw;
  final String hint;
  final String? chipLabel;
  final String? chipIcon;
  final Color chipColor;
  final Widget? preview;

  const _RuleRow({
    required this.raw,
    required this.hint,
    required this.chipLabel,
    required this.chipColor,
    this.chipIcon,
    this.preview,
  });

  @override
  Widget build(BuildContext context) {
    final chipWidget =
        preview ??
        (chipLabel != null
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: chipColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: chipColor.withValues(alpha: 0.5)),
                ),
                child: Text(
                  '${chipIcon ?? ''} $chipLabel',
                  style: TextStyle(
                    color: chipColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            : const SizedBox.shrink());

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Raw code side
          Expanded(
            flex: 5,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                raw,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Color(0xFFCDCDCD),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(
              Icons.arrow_forward,
              size: AppIconSize.inline,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          // Preview side
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                chipWidget,
                if (hint.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      hint,
                      style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  final String code;
  const _CodeBlock({required this.code});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: code));
        context.showSuccessSnackBar('Copié dans le presse-papier');
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          code,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12.5,
            color: Color(0xFFCDCDCD),
            height: 1.6,
          ),
        ),
      ),
    );
  }
}

class _FullExampleBlock extends StatelessWidget {
  static const _example = '''>> servings: 4

## Préparation de la base
Dans un #saladier, mélanger @farine{250%g} avec @sucre{50%g}.
Ajouter @œufs{3} et mélanger **délicatement** pour éviter les grumeaux.
+ La pâte doit être homogène et sans grumeaux.

## Cuisson
Faire chauffer la #poêle à crêpes{}.
Laisser cuire la pâte environ ~{2%minutes} par crêpe.
+ Répéter l’opération jusqu’à épuisement de la pâte.

-- Astuce : Accompagner d'un filet de citron !''';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: SelectableText(
            _example,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12.5,
              color: Color(0xFFCDCDCD),
              height: 1.65,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '💡 Maintenez appuyé pour copier dans le presse-papier',
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
