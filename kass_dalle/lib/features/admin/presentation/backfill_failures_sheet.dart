import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../domain/backfill_failures.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/utils/context_extensions.dart';

/// Feuille « À revoir » d'un backfill : les éléments que le passage n'a pas
/// pu traiter, nommés, avec la raison. Une ligne ouvre l'ingrédient ou l'unité
/// dans son référentiel, la recette dans sa fiche, le ticket dans Admin ›
/// Tickets des membres.
Future<void> showBackfillFailuresSheet(
  BuildContext context, {
  required String title,
  required BackfillFailures failures,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => BackfillFailuresSheet(title: title, failures: failures),
  );
}

/// Ordre des groupes, et leur libellé.
const _kindOrder = [
  BackfillFailureKind.ingredient,
  BackfillFailureKind.unit,
  BackfillFailureKind.recipe,
  BackfillFailureKind.account,
  BackfillFailureKind.meal,
  BackfillFailureKind.ticket,
  BackfillFailureKind.invitation,
];

String _groupLabel(String kind, int count) => switch (kind) {
  BackfillFailureKind.ingredient => 'Ingrédients ($count)',
  BackfillFailureKind.unit => 'Unités ($count)',
  BackfillFailureKind.recipe => 'Recettes ($count)',
  BackfillFailureKind.account => 'Comptes ($count)',
  BackfillFailureKind.meal => 'Repas planifiés ($count)',
  BackfillFailureKind.ticket => 'Tickets ($count)',
  BackfillFailureKind.invitation => 'Invitations ($count)',
  _ => 'Autres ($count)',
};

/// Une ligne s'ouvre quand sa nature a un écran : ingrédient, unité, recette,
/// ticket.
bool _isOpenable(BackfillFailure f) =>
    f.kind == BackfillFailureKind.ingredient ||
    f.kind == BackfillFailureKind.unit ||
    f.kind == BackfillFailureKind.recipe ||
    f.kind == BackfillFailureKind.ticket;

/// Tri par raison puis par nom : les éléments qui ont la même cause se suivent.
List<BackfillFailure> _sorted(Iterable<BackfillFailure> items) {
  final list = items.toList();
  list.sort((a, b) {
    final byReason = a.reason.toLowerCase().compareTo(b.reason.toLowerCase());
    if (byReason != 0) return byReason;
    return a.label.toLowerCase().compareTo(b.label.toLowerCase());
  });
  return list;
}

/// Texte copié : une ligne « nom — raison » par élément, dans l'ordre affiché.
String backfillFailuresClipboardText(BackfillFailures failures) {
  return _groups(
    failures.items,
  ).values.expand((items) => items).map((f) => f.copyLine).join('\n');
}

/// Éléments regroupés par nature, dans l'ordre de [_kindOrder], natures
/// inconnues à la fin ; chaque groupe trié.
Map<String, List<BackfillFailure>> _groups(List<BackfillFailure> items) {
  final byKind = <String, List<BackfillFailure>>{};
  for (final f in items) {
    final key = _kindOrder.contains(f.kind) ? f.kind : '';
    byKind.putIfAbsent(key, () => []).add(f);
  }
  return {
    for (final kind in [..._kindOrder, ''])
      if (byKind[kind] != null) kind: _sorted(byKind[kind]!),
  };
}

class BackfillFailuresSheet extends StatelessWidget {
  final String title;
  final BackfillFailures failures;

  const BackfillFailuresSheet({
    super.key,
    required this.title,
    required this.failures,
  });

  String _subtitle() {
    final n = failures.total;
    final openable = failures.items.any(_isOpenable);
    if (n == 1) {
      return openable ? '1 élément. Touchez-le pour l\'ouvrir.' : '1 élément.';
    }
    return openable
        ? '$n éléments. Touchez une ligne pour l\'ouvrir.'
        : '$n éléments.';
  }

  void _open(BuildContext context, BackfillFailure f) {
    switch (f.kind) {
      case BackfillFailureKind.ingredient:
        context.push(AppRoutes.adminNutritionIngredients, extra: f.id);
      case BackfillFailureKind.unit:
        context.push(AppRoutes.adminNutritionUnits, extra: f.id);
      case BackfillFailureKind.recipe:
        context.push('/recipes/${f.id}');
      case BackfillFailureKind.ticket:
        context.push(AppRoutes.adminTicketDetail(f.id));
    }
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(
      ClipboardData(text: backfillFailuresClipboardText(failures)),
    );
    if (!context.mounted) return;
    context.showSuccessSnackBar('Liste copiée.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = _groups(failures.items);
    final showHeaders = groups.length > 1;

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      // Un ScaffoldMessenger propre à la feuille : la confirmation de copie
      // s'affiche dans la feuille, et non sous elle, dans l'écran masqué.
      builder: (ctx, scrollController) => ScaffoldMessenger(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Builder(
            builder: (scaffoldContext) => ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(8, 16, 8, 32),
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.4,
                      ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'À revoir — $title',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copier la liste',
                        icon: const Icon(Icons.copy_outlined),
                        onPressed: () => _copy(scaffoldContext),
                      ),
                      IconButton(
                        tooltip: 'Fermer',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    _subtitle(),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final entry in groups.entries) ...[
                  if (showHeaders)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text(
                        _groupLabel(entry.key, entry.value.length),
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  for (final f in entry.value)
                    ListTile(
                      title: Text(f.label),
                      subtitle: f.reason.isEmpty ? null : Text(f.reason),
                      trailing: _isOpenable(f)
                          ? const Icon(
                              Icons.chevron_right,
                              size: AppIconSize.small,
                            )
                          : null,
                      onTap: _isOpenable(f) ? () => _open(context, f) : null,
                    ),
                ],
                if (failures.truncated)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Text(
                      '${failures.items.length} affichés sur ${failures.total}.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
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
