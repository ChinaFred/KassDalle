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
  // Le dialogue rend la saisie, ou null s'il est annulé. Son contrôleur vit
  // dans son état et n'est libéré qu'à son démontage, après l'animation de
  // fermeture : libéré au retour de `showDialog`, il était encore lu par le
  // champ qui disparaissait.
  final value = await showDialog<String>(
    context: context,
    builder: (_) => _PreferredNameDialog(user: user),
  );
  if (value == null) return;

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
      context.showFailureSnackBar('Nom préféré non enregistré', e);
    }
  }
}

class _PreferredNameDialog extends StatefulWidget {
  final AppUser user;
  const _PreferredNameDialog({required this.user});

  @override
  State<_PreferredNameDialog> createState() => _PreferredNameDialogState();
}

class _PreferredNameDialogState extends State<_PreferredNameDialog> {
  // Un nom enregistré avant la borne de 60 caractères se pré-remplit coupé :
  // les règles refuseraient sinon de l'enregistrer tel quel.
  late final TextEditingController _controller = TextEditingController(
    text: UserProfile.truncateName(widget.user.preferredName ?? ''),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    final fallback = AppUser.defaultPreferredName(
      widget.user.displayName,
      widget.user.email,
    );
    return AlertDialog(
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
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: UserProfile.maxNameLength,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Nom préféré',
                hintText: fallback,
                helperText: 'Vide : le prénom du compte Google ($fallback).',
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Enregistrer')),
      ],
    );
  }
}
