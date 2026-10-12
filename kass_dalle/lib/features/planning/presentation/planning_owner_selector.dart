import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/planning_visibility.dart';
import 'planning_providers.dart';

/// Le sélecteur « Plannings affichés » : « Mon planning », puis
/// « Planning de Marie » pour chaque planning partagé avec l'utilisateur.
///
/// Deux présentations, un même état ([planningOwnerOptionsProvider]) :
/// - sur un téléphone, une ligne sous la barre, avec un bouton-puce qui
///   résume le choix et ouvre une feuille ([PlanningOwnersChipRow]) ;
/// - sur grand écran, une carte au-dessus du calendrier, cases visibles
///   ([PlanningOwnersCard]).
///
/// Cocher ou décocher ne lit ni n'écrit rien dans Firestore : le choix est
/// mémorisé sur l'appareil (voir `planning_visibility_store.dart`).

/// Les cases à cocher, une par planning proposé.
class _OwnerCheckboxes extends ConsumerWidget {
  const _OwnerCheckboxes();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(planningOwnerOptionsProvider).value ?? const [];
    final notifier = ref.read(planningVisibilityProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final option in options)
          CheckboxListTile(
            value: option.shown,
            onChanged: (_) => notifier.toggle(option.uid),
            title: Text(option.title),
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
          ),
      ],
    );
  }
}

/// Ouvre la feuille du bas des plannings affichés.
Future<void> showPlanningOwnersSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Text(
                'Plannings affichés',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            const _OwnerCheckboxes(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Fermer'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Téléphone : « Plannings : Moi, Marie », sous la barre.
class PlanningOwnersChipRow extends ConsumerWidget {
  const PlanningOwnersChipRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(planningOwnerOptionsProvider).value ?? const [];
    final label = planningSelectorLabel([
      for (final o in options)
        if (o.shown) o.shortName,
    ]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ActionChip(
          avatar: const Icon(Icons.people_outline),
          label: Text(label),
          tooltip: 'Choisir les plannings affichés',
          onPressed: () => showPlanningOwnersSheet(context),
        ),
      ),
    );
  }
}

/// Grand écran : la carte « Plannings affichés », au-dessus du calendrier.
class PlanningOwnersCard extends StatelessWidget {
  const PlanningOwnersCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              'Plannings affichés',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          const _OwnerCheckboxes(),
        ],
      ),
    );
  }
}
