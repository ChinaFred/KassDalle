import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/sandbox_model_choice.dart';

/// Le sélecteur de modèle d'une expérience.
///
/// Le choix est retenu d'une session à l'autre, par poste : comparer deux
/// modèles suppose de rejouer la même image plusieurs fois, et retaper le
/// réglage à chaque fois découragerait la comparaison.
///
/// Il ne touche pas au routage de l'application. « Défaut de l'application »
/// veut dire : suivre Admin → Moteur d'IA, comme n'importe quel poste.
class SandboxModelPicker extends StatefulWidget {
  /// Le poste concerné — sert de clé de mémorisation.
  final String featureKey;

  final SandboxModelChoice? value;
  final ValueChanged<SandboxModelChoice?> onChanged;

  /// Grisé pendant qu'un appel est en cours.
  final bool enabled;

  const SandboxModelPicker({
    super.key,
    required this.featureKey,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  /// Relit le choix mémorisé pour ce poste.
  static Future<SandboxModelChoice?> restore(String featureKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return SandboxModelChoice.parse(prefs.getString(_key(featureKey)));
    } catch (_) {
      // Un réglage qu'on ne sait pas relire n'est pas une panne : on repart du
      // défaut. Il n'y a rien à signaler à personne, et rien à réparer.
      return null;
    }
  }

  static String _key(String featureKey) => 'sandbox.model.$featureKey';

  @override
  State<SandboxModelPicker> createState() => _SandboxModelPickerState();
}

class _SandboxModelPickerState extends State<SandboxModelPicker> {
  static const _customSentinel = '__autre__';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = widget.value;

    // Un identifiant saisi à la main rejoint la liste le temps de la session,
    // sinon le menu ne pourrait pas afficher la valeur courante.
    final options = <SandboxModelChoice>[
      ...kSandboxModelPresets,
      if (value != null && !kSandboxModelPresets.contains(value)) value,
    ];

    return Row(
      children: [
        Icon(Icons.memory, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value?.storageValue ?? '',
              isDense: true,
              isExpanded: true,
              style: theme.textTheme.bodyMedium,
              onChanged: widget.enabled ? _onSelected : null,
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: Text('Défaut de l\'application'),
                ),
                for (final option in options)
                  DropdownMenuItem(
                    value: option.storageValue,
                    child: Text(option.label),
                  ),
                const DropdownMenuItem(
                  value: _customSentinel,
                  child: Text('Autre identifiant…'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _onSelected(String? selected) async {
    if (selected == null) return;

    if (selected == _customSentinel) {
      final custom = await _askCustom(context);
      if (custom == null) return;
      await _store(custom);
      return;
    }

    await _store(selected.isEmpty ? null : SandboxModelChoice.parse(selected));
  }

  Future<void> _store(SandboxModelChoice? choice) async {
    widget.onChanged(choice);
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = SandboxModelPicker._key(widget.featureKey);
      if (choice == null) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, choice.storageValue);
      }
    } catch (_) {
      // Le choix vaut pour la session en cours même s'il ne se grave pas.
    }
  }

  Future<SandboxModelChoice?> _askCustom(BuildContext context) {
    final controller = TextEditingController();
    var provider = 'gemini';

    return showDialog<SandboxModelChoice>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (builderContext, setDialogState) => AlertDialog(
          title: const Text('Identifiant de modèle'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Le nom est envoyé tel quel au fournisseur. S\'il n\'existe '
                'pas, l\'appel échoue avec son message — c\'est la réponse '
                'utile.',
              ),
              const SizedBox(height: 16),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'gemini', label: Text('Gemini')),
                  ButtonSegment(value: 'anthropic', label: Text('Claude')),
                ],
                selected: {provider},
                onSelectionChanged: (selection) =>
                    setDialogState(() => provider = selection.first),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Identifiant',
                  hintText: 'gemini-3-pro',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () {
                final model = controller.text.trim();
                if (model.isEmpty) return;
                Navigator.of(
                  dialogContext,
                ).pop(SandboxModelChoice.custom(provider, model));
              },
              child: const Text('Utiliser'),
            ),
          ],
        ),
      ),
    );
  }
}
