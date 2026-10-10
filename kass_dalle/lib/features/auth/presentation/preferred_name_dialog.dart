import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/context_extensions.dart';
import '../domain/app_user.dart';
import '../domain/user_profile.dart';
import 'auth_providers.dart';

/// Demande le nom préféré de [user] et l'enregistre.
///
/// Un champ laissé vide efface le nom : le compte revient au prénom de son
/// compte Google. C'est le seul retour en arrière possible — sans lui, il
/// faudrait deviner ce prénom et le retaper à l'identique.
///
/// Le même dialogue sert des deux côtés : chacun pour soi depuis « Profil et
/// compte », un administrateur pour n'importe qui depuis « Gestion des
/// utilisateurs ». Les règles Firestore autorisent exactement ces deux cas.
Future<void> showPreferredNameDialog(
  BuildContext context,
  WidgetRef ref,
  AppUser user,
) async {
  // Un nom enregistré avant la borne de 60 caractères se pré-remplit coupé :
  // les règles refuseraient sinon de l'enregistrer tel quel.
  final controller = TextEditingController(
    text: UserProfile.truncateName(user.preferredName ?? ''),
  );
  final fallback = AppUser.defaultPreferredName(user.displayName, user.email);

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Nom préféré'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Le nom qui désigne cette personne et sa bibliothèque auprès du '
              'reste de la famille.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: UserProfile.maxNameLength,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Nom préféré',
                hintText: fallback,
                helperText: 'Vide : le prénom du compte Google ($fallback).',
              ),
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Enregistrer'),
        ),
      ],
    ),
  );

  final value = controller.text;
  controller.dispose();
  if (confirmed != true) return;

  try {
    await ref.read(authRepositoryProvider).updatePreferredName(user.uid, value);
    // Le profil des autres membres est lu une fois et mis en cache : sans
    // cette invalidation, les en-têtes de bibliothèque garderaient l'ancien
    // nom jusqu'au prochain démarrage.
    ref.invalidate(userProfileProvider(user.uid));
    if (context.mounted) {
      context.showSuccessSnackBar('Nom préféré enregistré.');
    }
  } catch (e) {
    // Le repository a déjà rapporté l'erreur et l'a relancée : un second
    // rapport ferait doublon. Ce qui manquait, c'est de le dire à l'écran.
    if (context.mounted) {
      context.showErrorSnackBar('Enregistrement impossible : $e');
    }
  }
}
