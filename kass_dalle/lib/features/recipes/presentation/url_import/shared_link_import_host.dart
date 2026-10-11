import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/context_extensions.dart';
import '../../../auth/domain/app_user.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../domain/url_import.dart';
import '../recipe_providers.dart';
import 'url_import_dialog.dart';

/// Traite « Partager vers Kass'Dalle » (Android) par-dessus l'écran courant.
///
/// Posé dans le shell. Un partage reçu avant la connexion attend dans
/// [pendingSharedTextProvider]. Il n'est pris ([PendingSharedTextNotifier.take])
/// qu'une fois le compte lu : tant que [appUserProvider] charge, ou que
/// personne n'est connecté, le texte reste en attente. Le rôle se lit alors
/// sur le compte chargé, jamais sur la valeur par défaut de [canEditProvider]
/// pendant le chargement (`false`), qui refusait l'import à un éditeur.
///
/// - éditeur ou administrateur, une adresse web : la boîte « Importer depuis
///   un lien » s'ouvre, l'adresse posée ; rien ne part avant « Importer » ;
/// - lecteur : une boîte dit que l'import est réservé aux éditeurs ;
/// - aucune adresse web : un message d'erreur.
class SharedLinkImportHost extends ConsumerStatefulWidget {
  const SharedLinkImportHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SharedLinkImportHost> createState() =>
      _SharedLinkImportHostState();
}

class _SharedLinkImportHostState extends ConsumerState<SharedLinkImportHost> {
  @override
  void initState() {
    super.initState();
    // Un partage arrivé avant le shell (démarrage à froid, connexion).
    WidgetsBinding.instance.addPostFrameCallback((_) => _consume());
  }

  void _consume() {
    if (!mounted) return;
    // Compte en cours de lecture, ou personne de connecté : le texte reste en
    // attente, et l'écoute de [appUserProvider] relance la prise.
    final account = ref.read(appUserProvider);
    final user = account.value;
    if (account.isLoading || user == null) return;
    final text = ref.read(pendingSharedTextProvider.notifier).take();
    if (text == null) return;
    final decision = resolveSharedText(text, canEdit: user.canEdit);
    switch (decision.outcome) {
      case SharedTextOutcome.import:
        unawaited(
          showUrlImportDialog(context, initialUrl: decision.url.toString()),
        );
      case SharedTextOutcome.editorsOnly:
        unawaited(
          showDialog<void>(
            context: context,
            builder: (ctx) => const ImportReservedDialog(),
          ),
        );
      case SharedTextOutcome.noWebLink:
        context.showErrorSnackBar('Ce partage ne contient pas d\'adresse web.');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(pendingSharedTextProvider, (_, next) {
      if (next == null) return;
      // Après le rendu : une boîte ne s'ouvre pas pendant une construction.
      WidgetsBinding.instance.addPostFrameCallback((_) => _consume());
    });
    // Un partage reçu pendant la lecture du compte se prend dès que le rôle
    // est connu.
    ref.listen<AsyncValue<AppUser?>>(appUserProvider, (_, next) {
      if (next.isLoading || next.value == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) => _consume());
    });
    return widget.child;
  }
}

/// « Import réservé aux éditeurs », pour un lecteur qui partage un lien.
class ImportReservedDialog extends StatelessWidget {
  const ImportReservedDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import réservé aux éditeurs'),
      content: const Text(
        'Importer une recette ou un livre est réservé aux éditeurs et aux '
        'administrateurs. Demandez à un administrateur de vous nommer '
        'éditeur.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer'),
        ),
      ],
    );
  }
}
