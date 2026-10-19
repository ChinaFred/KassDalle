import 'package:flutter/material.dart';

import '../../recipes/domain/allergens.dart';

/// Les allergènes majeurs d'une garniture, saisis à la main : une pastille
/// par allergène de l'annexe II INCO, et « Aucun ».
///
/// Trois états : non renseignés (`null`, aucune pastille), aucun allergène
/// (`[]`, « Aucun » cochée), ou la liste cochée. Décocher le dernier
/// allergène rend « non renseignés » : « Aucun » est un choix explicite. Le
/// planning lit ce champ pour écarter un accompagnement qui contient un
/// allergène exclu ; non renseigné, l'exclusion n'est pas vérifiée.
class StapleAllergensField extends StatelessWidget {
  final List<String>? value;
  final ValueChanged<List<String>?> onChanged;

  /// Rappel de la valeur du référentiel, pour une retouche.
  final String? baseHint;

  const StapleAllergensField({
    super.key,
    required this.value,
    required this.onChanged,
    this.baseHint,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = value;
    final none = current != null && current.isEmpty;
    final helper = current == null
        ? 'Non renseignés : une exclusion d\'allergène ne peut pas être '
              'vérifiée sur cette garniture.'
        : none
        ? 'Aucun allergène majeur.'
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Allergènes majeurs', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            FilterChip(
              label: const Text('Aucun'),
              selected: none,
              onSelected: (selected) => onChanged(selected ? const [] : null),
            ),
            for (final key in kAllergenKeys)
              FilterChip(
                label: Text(allergenLabel(key)),
                selected: current?.contains(key) ?? false,
                onSelected: (selected) {
                  final next = {...?current};
                  if (selected) {
                    next.add(key);
                  } else {
                    next.remove(key);
                  }
                  onChanged(next.isEmpty ? null : sortAllergenKeys(next));
                },
              ),
          ],
        ),
        if (helper != null || baseHint != null) ...[
          const SizedBox(height: 4),
          Text(
            [?helper, ?baseHint].join(' '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// « Gluten, Œuf », « aucun allergène majeur » ou « allergènes non
/// renseignés » : la ligne d'une garniture dans une liste.
String stapleAllergensSummary(List<String>? allergens) {
  if (allergens == null) return 'allergènes non renseignés';
  if (allergens.isEmpty) return 'aucun allergène majeur';
  return allergens.map(allergenLabel).join(', ');
}
