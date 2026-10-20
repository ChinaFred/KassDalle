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

  /// Pour la retouche d'une garniture du référentiel ([retouch]) : les
  /// allergènes que le référentiel a saisis. Sans valeur propre, la garniture
  /// les suit : « Suit le référentiel : Gluten. ». Si le référentiel n'en a
  /// pas saisi (`null`), l'avertissement « Non renseignés » reste : rien ne
  /// peut être vérifié.
  final List<String>? baseAllergens;

  /// Retouche d'une garniture du référentiel, et non garniture à soi.
  final bool retouch;

  const StapleAllergensField({
    super.key,
    required this.value,
    required this.onChanged,
    this.baseAllergens,
    this.retouch = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = value;
    final none = current != null && current.isEmpty;
    final baseList = baseAllergens;
    final base = retouch && baseList != null
        ? stapleAllergensSummary(baseList)
        : null;
    final helper = current == null
        ? base != null
              ? 'Suit le référentiel : ${_capitalized(base)}.'
              : 'Non renseignés : une exclusion d\'allergène ne peut pas être '
                    'vérifiée sur cette garniture.'
        : [
            if (none) 'Aucun allergène majeur.',
            if (base != null) 'Référentiel : ${_capitalized(base)}.',
          ].join(' ');
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
        if (helper.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            helper,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

String _capitalized(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// « Gluten, Œuf », « aucun allergène majeur » ou « allergènes non
/// renseignés » : la ligne d'une garniture dans une liste.
String stapleAllergensSummary(List<String>? allergens) {
  if (allergens == null) return 'allergènes non renseignés';
  if (allergens.isEmpty) return 'aucun allergène majeur';
  return allergens.map(allergenLabel).join(', ');
}
