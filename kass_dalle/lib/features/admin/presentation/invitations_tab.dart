import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_reporting.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/widgets/error_message.dart';
import '../../auth/domain/app_user.dart';
import '../../auth/presentation/auth_providers.dart';
import '../domain/email_invitation.dart';
import 'admin_providers.dart';
import 'invite_by_email_screen.dart';

/// Onglet « Invitations » de la gestion des utilisateurs : en attente
/// d'abord, puis l'historique (acceptées, expirées, annulées).
class InvitationsTab extends ConsumerWidget {
  const InvitationsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(emailInvitationsProvider);
    return async.when(
      loading: () => const AppLoadingState(),
      error: (e, _) => AppErrorState(
        error: e,
        title: 'Invitations illisibles',
        onRetry: () => ref.invalidate(emailInvitationsProvider),
      ),
      data: (invitations) {
        if (invitations.isEmpty) {
          return const AppEmptyState(
            icon: Icons.mail_outline,
            title: 'Aucune invitation envoyée',
            message:
                'Invitez un proche par e-mail : son rôle l\'attendra à sa '
                'première connexion.',
          );
        }
        final now = DateTime.now();
        final pending = [
          for (final i in invitations)
            if (i.statusAt(now).isPending) i,
        ];
        final history = [
          for (final i in invitations)
            if (!i.statusAt(now).isPending) i,
        ];
        return ListView(
          // Le bouton flottant ne couvre pas la dernière ligne.
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            _SectionHeader('En attente (${pending.length})'),
            if (pending.isEmpty)
              const ListTile(title: Text('Aucune invitation en attente.')),
            for (final i in pending) _InvitationTile(invitation: i, now: now),
            if (history.isNotEmpty) ...[
              const _SectionHeader('Historique'),
              for (final i in history) _InvitationTile(invitation: i, now: now),
            ],
          ],
        );
      },
    );
  }
}

/// Nombre d'invitations en attente, pour le titre de l'onglet.
int pendingInvitationCount(List<EmailInvitation> invitations, DateTime now) =>
    invitations.where((i) => i.statusAt(now).isPending).length;

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

String _roleLabel(UserRole role) =>
    role == UserRole.editor ? 'Éditeur' : 'Lecteur';

/// Le sous-titre d'une invitation, selon son statut.
String invitationSubtitle(
  EmailInvitation invitation,
  EmailInvitationStatus status, {
  String? acceptedByName,
}) {
  final head =
      '${_roleLabel(invitation.role)} · ${invitation.groupName.isEmpty ? 'Groupe inconnu' : invitation.groupName}';
  switch (status) {
    case EmailInvitationStatus.accepted:
      final at = invitation.acceptedAt;
      final by = acceptedByName == null ? '' : 'par $acceptedByName';
      final when = at == null ? '' : 'le ${formatDayMonth(at)}';
      final detail = [by, when].where((s) => s.isNotEmpty).join(', ');
      // `group_missing` : groupe supprimé, recréé par un autre compte, ou
      // invitation sans `group_owner_id` (`invitationGroupOf`).
      // `group_invite: missing` sans `group_missing` : l'invitant avait
      // quitté le groupe au retour du compte, rien n'a été écrit.
      final missing = invitation.groupMissing
          ? ' · groupe non rejoint (supprimé ou changé) : '
                'invitez-le depuis Groupes familiaux'
          : invitation.groupInvite == 'missing'
          ? ' · pas invité au groupe (l\'invitant n\'en fait plus partie) : '
                'invitez-le depuis Groupes familiaux'
          : '';
      final restored = invitation.targetsRevokedAccount
          ? ' · accès rétabli'
          : '';
      final full = invitation.groupInvite == 'full'
          ? ' · pas invité au groupe, complet (50 invitations en attente) : '
                'invitez-le depuis Groupes familiaux quand une place se libère'
          : '';
      return '$head${detail.isEmpty ? '' : ' · $detail'}$restored$missing$full';
    case EmailInvitationStatus.cancelled:
      return head;
    case EmailInvitationStatus.sent:
    case EmailInvitationStatus.sendFailed:
    case EmailInvitationStatus.expired:
      final sent = invitation.lastSentAt;
      final expires = invitation.expiresAt;
      final parts = <String>[
        if (sent != null) 'envoyée le ${formatDayMonth(sent)}',
        if (expires != null)
          status == EmailInvitationStatus.expired
              ? 'expirée le ${formatDayMonth(expires)}'
              : 'expire le ${formatDayMonth(expires)}',
      ];
      final revoked = invitation.targetsRevokedAccount
          ? ' · compte révoqué'
          : '';
      return parts.isEmpty
          ? '$head$revoked'
          : '$head · ${parts.join(', ')}$revoked';
  }
}

class _InvitationTile extends ConsumerWidget {
  final EmailInvitation invitation;
  final DateTime now;
  const _InvitationTile({required this.invitation, required this.now});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = invitation.statusAt(now);
    final acceptedUid = invitation.acceptedUid;
    final acceptedBy = acceptedUid == null
        ? null
        : ref.watch(memberNameProvider(acceptedUid));
    // Motif à montrer : l'erreur d'un envoi échoué, ou le refus de l'adresse
    // par Gmail qui a fait annuler l'invitation par le serveur.
    final error = switch (status) {
      EmailInvitationStatus.sendFailed => invitation.lastError,
      EmailInvitationStatus.cancelled when invitation.cancelledBySystem =>
        invitation.lastError,
      _ => null,
    };

    return ListTile(
      title: Text(invitation.email),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: InvitationStatusChip(status: status),
                  ),
                ),
                TextSpan(
                  text: invitationSubtitle(
                    invitation,
                    status,
                    acceptedByName: acceptedBy,
                  ),
                ),
              ],
            ),
          ),
          if (error != null)
            Text(
              error,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
      isThreeLine: error != null,
      trailing: status.canResend || status.canCancel
          ? _InvitationMenu(invitation: invitation, status: status)
          : null,
    );
  }
}

/// Puce de statut, couleurs du thème, posée en tête du sous-titre.
class InvitationStatusChip extends StatelessWidget {
  final EmailInvitationStatus status;
  const InvitationStatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (status) {
      EmailInvitationStatus.sent => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      EmailInvitationStatus.accepted => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      EmailInvitationStatus.sendFailed => (
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      EmailInvitationStatus.expired || EmailInvitationStatus.cancelled => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      label: 'Statut : ${status.label}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          status.label,
          style: textTheme.labelSmall?.copyWith(color: fg),
        ),
      ),
    );
  }
}

enum _InvitationAction { resend, cancel, copyLink }

class _InvitationMenu extends ConsumerWidget {
  final EmailInvitation invitation;
  final EmailInvitationStatus status;
  const _InvitationMenu({required this.invitation, required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<_InvitationAction>(
      tooltip: 'Actions',
      icon: const Icon(Icons.more_vert),
      onSelected: (action) => _handle(context, ref, action),
      itemBuilder: (_) => [
        if (status.canResend)
          const PopupMenuItem(
            value: _InvitationAction.resend,
            child: ListTile(
              leading: Icon(Icons.send_outlined),
              title: Text('Renvoyer'),
              dense: true,
            ),
          ),
        if (status.canCancel)
          const PopupMenuItem(
            value: _InvitationAction.cancel,
            child: ListTile(
              leading: Icon(Icons.cancel_outlined),
              title: Text('Annuler l\'invitation'),
              dense: true,
            ),
          ),
        if (status.canCopyLink)
          const PopupMenuItem(
            value: _InvitationAction.copyLink,
            child: ListTile(
              leading: Icon(Icons.link),
              title: Text('Copier le lien'),
              dense: true,
            ),
          ),
      ],
    );
  }

  Future<void> _handle(
    BuildContext context,
    WidgetRef ref,
    _InvitationAction action,
  ) async {
    final repo = ref.read(invitationsRepositoryProvider);
    try {
      switch (action) {
        case _InvitationAction.copyLink:
          await Clipboard.setData(const ClipboardData(text: kAppPublicUrl));
          if (context.mounted) context.showSuccessSnackBar('Lien copié.');
        case _InvitationAction.resend:
          final outcome = await repo.resend(invitation.id);
          if (!context.mounted) return;
          switch (outcome.kind) {
            case InvitationOutcomeKind.sent:
              context.showSuccessSnackBar(
                invitationResentMessage(invitation.email, outcome),
              );
            case InvitationOutcomeKind.sendFailed:
              context.showErrorSnackBar(
                'E-mail non envoyé. L\'invitation est enregistrée : '
                'renvoyez-la plus tard, ou copiez le lien.',
              );
            case InvitationOutcomeKind.refused:
            case InvitationOutcomeKind.cancelled:
              context.showErrorSnackBar(outcome.message ?? 'Renvoi refusé.');
          }
        case _InvitationAction.cancel:
          final confirmed = await _confirmCancel(context);
          if (confirmed != true) return;
          final outcome = await repo.cancel(invitation.id);
          if (!context.mounted) return;
          if (outcome.kind == InvitationOutcomeKind.refused) {
            context.showErrorSnackBar(outcome.message ?? 'Annulation refusée.');
          } else {
            context.showSuccessSnackBar('Invitation annulée.');
          }
      }
    } catch (e, st) {
      // Les appels au serveur sont déjà rapportés par le dépôt
      // (`admin.invitations`) ; le presse-papiers ne l'est pas.
      if (action == _InvitationAction.copyLink) {
        reportUnexpectedError(
          feature: 'admin.invitations.copy_link',
          error: e,
          stackTrace: st,
        );
      }
      if (context.mounted) {
        context.showErrorSnackBar(
          'Action impossible : ${shortErrorMessage(e)}',
        );
      }
    }
  }

  Future<bool?> _confirmCancel(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Annuler l\'invitation de ${invitation.email} ?'),
        content: const Text(
          'Le lien ne donnera plus de rôle. L\'e-mail déjà reçu ne peut pas '
          'être repris.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Garder'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Annuler l\'invitation'),
          ),
        ],
      ),
    );
  }
}
