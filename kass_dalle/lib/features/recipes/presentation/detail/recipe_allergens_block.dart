import 'package:flutter/material.dart';

import '../../../../core/theme/app_icon_size.dart';
import '../../../../core/utils/platform_utils.dart';
import '../../domain/allergens.dart';

/// Allergènes majeurs d'une recette, sous la liste des ingrédients de la fiche.
///
/// Lecture seule, même rendu pour tous les rôles. Le champ est calculé par le
/// serveur ; l'appelant ne pose ce bloc que quand il existe (champ absent :
/// rien du tout). Quatre états :
///  - complet, aucun allergène : « Aucun allergène majeur détecté. » ;
///  - complet, des allergènes : les pastilles seules ;
///  - incomplet, des allergènes : une ligne d'avertissement, puis les pastilles ;
///  - incomplet, aucun : la ligne d'avertissement qui le dit.
/// L'avertissement sur la nature indicative de la liste suit dans tous les cas.
class RecipeAllergensBlock extends StatelessWidget {
  final RecipeAllergens allergens;

  const RecipeAllergensBlock({super.key, required this.allergens});

  static const String disclaimer =
      'Liste indicative établie par IA. Elle ne remplace pas la lecture des '
      'emballages.';
  static const String incompleteWithAllergens =
      'Analyse des allergènes incomplète : certains ingrédients n\'ont pas '
      'encore été examinés.';
  static const String incompleteWithout =
      'Analyse des allergènes incomplète : aucun allergène trouvé parmi les '
      'ingrédients déjà examinés.';
  static const String noneDetected = 'Aucun allergène majeur détecté.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final present = allergens.present;

    Widget statusLine(IconData? icon, String text) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(
            icon,
            size: AppIconSize.small,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
        ],
        Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Allergènes',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          if (!allergens.complete && present.isNotEmpty)
            statusLine(Icons.help_outline, incompleteWithAllergens),
          if (!allergens.complete && present.isEmpty)
            statusLine(Icons.help_outline, incompleteWithout),
          if (allergens.complete && present.isEmpty)
            statusLine(null, noneDetected),
          if (present.isNotEmpty) ...[
            if (!allergens.complete) const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final key in present)
                  _AllergenChip(
                    allergenKey: key,
                    ingredients: allergens.ingredientsFor(key),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: AppIconSize.small,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(child: Text(disclaimer, style: muted)),
            ],
          ),
        ],
      ),
    );
  }
}

class _AllergenChip extends StatelessWidget {
  final String allergenKey;
  final List<String> ingredients;

  const _AllergenChip({required this.allergenKey, required this.ingredients});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = allergenLabel(allergenKey);
    final showTooltip = !PlatformUtils.isMobile;
    void open() => showAllergenIngredientsSheet(context, label, ingredients);

    return Semantics(
      button: true,
      label: 'Allergène : $label. Afficher les ingrédients en cause.',
      excludeSemantics: true,
      onTap: open,
      child: ActionChip(
        label: Text(label),
        tooltip: showTooltip
            ? (ingredients.isEmpty
                  ? label
                  : '$label : ${ingredients.join(', ')}')
            : null,
        backgroundColor: theme.colorScheme.secondaryContainer,
        labelStyle: TextStyle(color: theme.colorScheme.onSecondaryContainer),
        side: BorderSide.none,
        onPressed: open,
      ),
    );
  }
}

/// Feuille des ingrédients en cause pour un allergène.
Future<void> showAllergenIngredientsSheet(
  BuildContext context,
  String label,
  List<String> ingredients,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Ingrédients en cause',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              if (ingredients.isEmpty)
                Text(
                  'Ingrédient en cause non précisé.',
                  style: theme.textTheme.bodyLarge,
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final name in ingredients)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(name),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  child: const Text('Fermer'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
