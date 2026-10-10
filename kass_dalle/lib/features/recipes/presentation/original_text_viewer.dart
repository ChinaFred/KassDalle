import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icon_size.dart';
import '../../../core/utils/language_names.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/app_states.dart';
import '../domain/original_text.dart';
import '../domain/recipe.dart';
import 'detail/recipe_text_zoom.dart';
import 'recipe_providers.dart';

/// Texte d'une recette traduite, tel qu'il était écrit sur la page.
///
/// Rien de ce fichier n'apparaît sur une recette non traduite : chaque widget
/// public rend un espace vide quand [Recipe.isTranslated] est faux.

/// Ouvre le texte d'origine : une feuille sur téléphone, une fenêtre sur grand
/// écran. Le texte suit le zoom de lecture de la recette.
Future<void> showOriginalText(BuildContext context, Recipe recipe) {
  final langue = recipe.langueOrigine ?? '';
  final wide = MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
          child: RecipeTextZoomArea(
            child: OriginalTextView(
              recipeId: recipe.id,
              langue: langue,
              onClose: () => Navigator.of(ctx).pop(),
              hasSourceFile: (recipe.sourceFileUrl ?? '').isNotEmpty,
            ),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => FractionallySizedBox(
      heightFactor: 0.9,
      child: RecipeTextZoomArea(
        child: OriginalTextView(
          recipeId: recipe.id,
          langue: langue,
          onClose: () => Navigator.of(ctx).pop(),
          hasSourceFile: (recipe.sourceFileUrl ?? '').isNotEmpty,
        ),
      ),
    ),
  );
}

/// Icône « Voir le texte d'origine » de la barre d'actions.
class OriginalTextButton extends StatelessWidget {
  const OriginalTextButton({
    super.key,
    required this.recipe,
    this.compact = false,
    this.onPressed,
  });

  final Recipe recipe;

  /// Présentation resserrée de la barre d'actions sur téléphone.
  final bool compact;

  /// Remplace l'ouverture de la vue — le panneau latéral de la relecture.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (!recipe.isTranslated) return const SizedBox.shrink();
    final name = languageName(recipe.langueOrigine!);
    return IconButton(
      tooltip: name == null
          ? "Voir le texte d'origine"
          : "Voir le texte d'origine ($name)",
      icon: const Icon(Icons.translate),
      onPressed: onPressed ?? () => showOriginalText(context, recipe),
      iconSize: compact ? 22 : null,
      padding: compact ? EdgeInsets.zero : null,
      visualDensity: compact ? VisualDensity.compact : null,
      constraints: compact
          ? const BoxConstraints(minWidth: 36, minHeight: 36)
          : null,
    );
  }
}

/// Mention « Traduit de l'anglais », qui ouvre le texte d'origine.
///
/// Elle dit aussi au lecteur que les mesures ont été converties : la recette
/// qu'il lit n'est pas celle de la page.
class TranslatedFromLabel extends StatelessWidget {
  const TranslatedFromLabel({
    super.key,
    required this.recipe,
    this.onTap,
    this.minTapHeight = 0,
  });

  final Recipe recipe;

  /// Remplace l'ouverture de la vue — le panneau latéral de la relecture.
  final VoidCallback? onTap;

  /// Hauteur minimale de la cible tactile. 36 dans la rangée d'actions du
  /// téléphone, où la mention est le seul accès et voisine des icônes de
  /// 36 px ; 0 dans une ligne de titre, dont la hauteur est comptée.
  final double minTapHeight;

  @override
  Widget build(BuildContext context) {
    if (!recipe.isTranslated) return const SizedBox.shrink();
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final name = languageName(recipe.langueOrigine!);
    final action = name == null
        ? "Voir le texte d'origine"
        : "Voir le texte d'origine ($name)";
    return Tooltip(
      message: action,
      child: Semantics(
        button: true,
        label: action,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap ?? () => showOriginalText(context, recipe),
          borderRadius: BorderRadius.circular(4),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minTapHeight),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.translate, size: AppIconSize.badge, color: color),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    translatedFromLabel(recipe.langueOrigine!),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: color),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Le contenu de la vue : en-tête, puis le texte lu dans
/// `recipes/{id}/origine/texte`, chargé à l'ouverture.
class OriginalTextView extends ConsumerWidget {
  const OriginalTextView({
    super.key,
    required this.recipeId,
    required this.langue,
    this.onClose,
    this.hasSourceFile = false,
  });

  final String recipeId;
  final String langue;
  final VoidCallback? onClose;

  /// Vrai quand le document original reste consultable : l'état « absent » le dit.
  final bool hasSourceFile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(originalTextProvider(recipeId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  "Texte d'origine, avant traduction",
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (onClose != null) CloseButton(onPressed: onClose),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '${_capitalized(inLanguageLabel(langue))}, tel qu\'écrit sur la '
            'page. Ce texte ne suit pas les modifications de la recette.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: async.when(
            loading: () =>
                const AppLoadingState(label: "Chargement du texte d'origine…"),
            error: (e, _) => AppErrorState(
              error: e,
              compact: true,
              onRetry: () => ref.invalidate(originalTextProvider(recipeId)),
            ),
            data: (text) => text == null
                ? AppEmptyState(
                    icon: Icons.translate,
                    title: "Texte d'origine indisponible",
                    message:
                        'Cette recette a été traduite, mais son texte '
                        "d'origine n'a pas été conservé."
                        '${hasSourceFile ? ' Le document original reste consultable avec l\'icône Document original.' : ''}',
                  )
                : _OriginalTextBody(text: text),
          ),
        ),
      ],
    );
  }

  static String _capitalized(String text) =>
      text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
}

class _OriginalTextBody extends StatelessWidget {
  const _OriginalTextBody({required this.text});

  final OriginalText text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // La langue de la page choisit les glyphes (chinois, japonais) et le sens
    // d'écriture (arabe, hébreu).
    final locale = Locale(text.langue.isEmpty ? 'und' : text.langue);
    final heading = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w600,
    );
    final children = <Widget>[
      if (text.titre.isNotEmpty)
        Text(text.titre, style: theme.textTheme.titleLarge, locale: locale),
      if (text.introduction != null) ...[
        const SizedBox(height: 12),
        Text(text.introduction!, locale: locale),
      ],
      for (final section in text.ingredientSections) ...[
        const SizedBox(height: 16),
        if (section.titre.isNotEmpty)
          Text(section.titre, style: heading, locale: locale),
        for (final line in section.lignes)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('• $line', locale: locale),
          ),
      ],
      for (final section in text.stepSections) ...[
        const SizedBox(height: 16),
        if (section.titre.isNotEmpty)
          Text(section.titre, style: heading, locale: locale),
        for (var i = 0; i < section.lignes.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('${i + 1}. ${section.lignes[i]}', locale: locale),
          ),
      ],
      for (final note in text.notes) ...[
        const SizedBox(height: 16),
        if (note.genre.isNotEmpty)
          Text(note.genre, style: heading, locale: locale),
        Text(note.texte, locale: locale),
      ],
    ];
    return SelectionArea(
      child: Directionality(
        textDirection: isRightToLeft(text.langue)
            ? TextDirection.rtl
            : TextDirection.ltr,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: children,
        ),
      ),
    );
  }
}
