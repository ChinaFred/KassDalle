import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/presentation/leave_guard.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/error_message.dart';
import '../../auth/domain/app_user.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../groups/domain/family_group.dart';
import '../../groups/presentation/group_providers.dart';
import '../domain/email_invitation.dart';
import 'admin_providers.dart';

/// Adresse publique de l'application, citée dans l'e-mail et copiée par
/// « Copier le lien ».
const kAppPublicUrl = 'https://kassdale-6d948.web.app';

/// Adresse de l'APK Android servi par le Hosting, citée dans l'e-mail.
const kAppApkUrl = '$kAppPublicUrl/app-release.apk';

/// Formulaire « Inviter par e-mail » (Admin › Gestion des utilisateurs).
///
/// Rend `true` à l'écran appelant quand une invitation a été enregistrée —
/// e-mail parti ou non —, pour qu'il ouvre l'onglet Invitations.
class InviteByEmailScreen extends ConsumerStatefulWidget {
  const InviteByEmailScreen({super.key});

  @override
  ConsumerState<InviteByEmailScreen> createState() =>
      _InviteByEmailScreenState();
}

class _InviteByEmailScreenState extends ConsumerState<InviteByEmailScreen> {
  final _emailCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();

  UserRole _role = UserRole.reader;
  String? _groupId;

  /// Vrai dès que l'administrateur a retouché le message : le nom du groupe
  /// n'y est plus remplacé.
  bool _messageEdited = false;

  /// Le texte que le formulaire a lui-même posé dans le message.
  String _autoMessage = '';

  bool _sending = false;
  bool _done = false;

  String? _emailError;
  String? _groupError;
  InvitationOutcome? _refusal;

  late final LeaveGuardNotifier _leaveGuardNotifier;
  late final LeaveGuard _leaveGuard = _confirmLeave;

  @override
  void initState() {
    super.initState();
    _leaveGuardNotifier = ref.read(leaveGuardProvider.notifier);
    _messageCtrl.addListener(() {
      if (_messageCtrl.text != _autoMessage && !_messageEdited) {
        setState(() => _messageEdited = true);
      }
    });
    _emailCtrl.addListener(() {
      if (_emailError != null || _refusal != null) {
        setState(() {
          _emailError = null;
          _refusal = null;
        });
      } else {
        setState(() {});
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _leaveGuardNotifier.set(_leaveGuard);
    });
    // Un seul groupe : présélectionné, et son nom posé dans le message.
    ref.listenManual<AsyncValue<List<FamilyGroup>>>(myGroupsProvider, (
      _,
      next,
    ) {
      final groups = next.value;
      if (_groupId != null || groups == null || groups.length != 1) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _groupId != null) return;
        setState(() {
          _groupId = groups.first.id;
          _applyGroupToMessage(groups.first.name);
        });
      });
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    final notifier = _leaveGuardNotifier;
    final guard = _leaveGuard;
    Future.microtask(() => notifier.clearIf(guard));
    _emailCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  bool get _hasInput =>
      !_done && (_emailCtrl.text.trim().isNotEmpty || _messageEdited);

  Future<bool> _confirmLeave() async {
    if (!_hasInput) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Abandonner l\'invitation ?'),
        content: const Text('L\'adresse et le message saisis seront perdus.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Rester'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Abandonner'),
          ),
        ],
      ),
    );
    return leave == true;
  }

  Future<void> _leaveAfterConfirmation() async {
    if (!await _confirmLeave() || !mounted) return;
    _done = true;
    Navigator.of(context).pop();
  }

  /// Pose le message par défaut du groupe, tant qu'il n'a pas été retouché.
  void _applyGroupToMessage(String groupName) {
    if (_messageEdited) return;
    _autoMessage = defaultInvitationMessage(groupName);
    _messageCtrl.text = _autoMessage;
  }

  FamilyGroup? _selectedGroup(List<FamilyGroup> groups) {
    for (final g in groups) {
      if (g.id == _groupId) return g;
    }
    return null;
  }

  Future<void> _send(FamilyGroup group) async {
    final email = _emailCtrl.text.trim();
    if (!looksLikeEmail(email)) {
      setState(() => _emailError = 'Adresse e-mail invalide.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _sending = true;
      _emailError = null;
      _groupError = null;
      _refusal = null;
    });
    try {
      final outcome = await ref
          .read(invitationsRepositoryProvider)
          .create(
            email: email,
            role: _role,
            groupId: group.id,
            message: _messageCtrl.text,
          );
      if (!mounted) return;
      switch (outcome.kind) {
        case InvitationOutcomeKind.sent:
          _done = true;
          context.showSuccessSnackBar('Invitation envoyée à $email');
          Navigator.of(context).pop(true);
        case InvitationOutcomeKind.sendFailed:
          _done = true;
          context.showErrorSnackBar(
            'E-mail non envoyé. L\'invitation est enregistrée : renvoyez-la '
            'depuis la liste, ou copiez le lien.',
          );
          Navigator.of(context).pop(true);
        case InvitationOutcomeKind.refused:
        case InvitationOutcomeKind.cancelled:
          _showRefusal(outcome);
      }
    } catch (e) {
      // Déjà rapportée par `InvitationsRepository` (`admin.invitations`).
      if (mounted) {
        context.showErrorSnackBar(
          'Invitation non envoyée : ${shortErrorMessage(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showRefusal(InvitationOutcome outcome) {
    final message = outcome.message ?? 'Invitation refusée.';
    setState(() {
      _refusal = outcome;
      if (outcome.field == 'email') _emailError = message;
      if (outcome.field == 'group') _groupError = message;
    });
    if (outcome.field == null) context.showErrorSnackBar(message);
  }

  /// Compte en attente : lui donner le rôle choisi par le geste de l'onglet
  /// Comptes, sans invitation.
  Future<void> _grantRoleNow(String uid) async {
    setState(() => _sending = true);
    try {
      await ref.read(adminRepositoryProvider).updateRole(uid, _role);
      if (!mounted) return;
      _done = true;
      context.showSuccessSnackBar(
        'Rôle donné. Ajoutez-le au groupe depuis Groupes familiaux.',
      );
      Navigator.of(context).pop();
    } catch (e, st) {
      await ref
          .read(errorReportServiceProvider)
          .reportError(
            feature: 'admin.invitations',
            error: e,
            stackTrace: st,
            context: {'step': 'grant_role_now', 'target_uid': uid},
          );
      if (mounted) {
        context.showErrorSnackBar('Rôle non modifié : ${shortErrorMessage(e)}');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Doublon : renvoyer l'invitation déjà en attente.
  Future<void> _resendExisting(String invitationId) async {
    setState(() => _sending = true);
    try {
      final outcome = await ref
          .read(invitationsRepositoryProvider)
          .resend(invitationId);
      if (!mounted) return;
      switch (outcome.kind) {
        case InvitationOutcomeKind.sent:
          _done = true;
          context.showSuccessSnackBar('Invitation renvoyée.');
          Navigator.of(context).pop(true);
        case InvitationOutcomeKind.sendFailed:
          _done = true;
          context.showErrorSnackBar(
            'E-mail non envoyé. L\'invitation est enregistrée : renvoyez-la '
            'depuis la liste, ou copiez le lien.',
          );
          Navigator.of(context).pop(true);
        case InvitationOutcomeKind.refused:
        case InvitationOutcomeKind.cancelled:
          context.showErrorSnackBar(outcome.message ?? 'Renvoi refusé.');
      }
    } catch (e) {
      // Déjà rapportée par `InvitationsRepository` (`admin.invitations`).
      if (mounted) {
        context.showErrorSnackBar(
          'Invitation non renvoyée : ${shortErrorMessage(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groupsAsync = ref.watch(myGroupsProvider);
    final me = ref.watch(appUserProvider).value;
    final groups = groupsAsync.value ?? const <FamilyGroup>[];

    final group = _selectedGroup(groups);

    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
    final preview = _EmailPreview(
      inviterName: me?.displayedName ?? '',
      groupName: group?.name ?? '…',
      message: _messageCtrl.text,
      toEmail: _emailCtrl.text.trim().isEmpty ? '…' : _emailCtrl.text.trim(),
    );

    final form = _buildForm(context, groupsAsync, groups, group);

    return PopScope(
      canPop: !_hasInput,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _leaveAfterConfirmation();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Inviter par e-mail')),
        body: isWide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: form,
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    flex: 2,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Aperçu de l\'e-mail',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 12),
                          preview,
                        ],
                      ),
                    ),
                  ),
                ],
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    form,
                    const SizedBox(height: 16),
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: ExpansionTile(
                        title: const Text('Aperçu de l\'e-mail'),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          16,
                          0,
                          16,
                          16,
                        ),
                        children: [preview],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildForm(
    BuildContext context,
    AsyncValue<List<FamilyGroup>> groupsAsync,
    List<FamilyGroup> groups,
    FamilyGroup? group,
  ) {
    final theme = Theme.of(context);
    final enabled = !_sending;
    final noGroup = groupsAsync.hasValue && groups.isEmpty;
    final canSend =
        enabled && group != null && _emailCtrl.text.trim().isNotEmpty;
    final refusal = _refusal;

    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _emailCtrl,
            enabled: enabled,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            autocorrect: false,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'Adresse e-mail',
              helperText:
                  'L\'adresse du compte Google qu\'il utilisera pour se '
                  'connecter.',
              helperMaxLines: 2,
              errorText: _emailError,
              errorMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
          ),
          if (refusal?.reason == 'account_pending' &&
              refusal?.existingUid != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: enabled
                    ? () => _grantRoleNow(refusal!.existingUid!)
                    : null,
                icon: const Icon(Icons.how_to_reg_outlined),
                label: const Text('Lui donner ce rôle maintenant'),
              ),
            ),
          if (refusal?.reason == 'duplicate' && refusal?.invitationId != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: enabled
                    ? () => _resendExisting(refusal!.invitationId!)
                    : null,
                icon: const Icon(Icons.send_outlined),
                label: const Text('Renvoyer l\'invitation'),
              ),
            ),
          const SizedBox(height: 20),
          Text('Rôle', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<UserRole>(
            segments: const [
              ButtonSegment(
                value: UserRole.reader,
                label: Text('Lecteur'),
                icon: Icon(Icons.visibility_outlined),
              ),
              ButtonSegment(
                value: UserRole.editor,
                label: Text('Éditeur'),
                icon: Icon(Icons.edit_outlined),
              ),
            ],
            selected: {_role},
            onSelectionChanged: enabled
                ? (s) => setState(() => _role = s.first)
                : null,
          ),
          const SizedBox(height: 6),
          Text(
            _role == UserRole.editor
                ? 'Crée et importe ses propres recettes.'
                : 'Consulte, note, planifie. Ne crée pas de recette.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          if (noGroup)
            Text(
              'Vous n\'appartenez à aucun groupe. Créez-en un dans Groupes '
              'familiaux.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            )
          else
            DropdownButtonFormField<String>(
              key: ValueKey('group-${_groupId ?? ''}'),
              initialValue: _groupId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Groupe',
                helperText: 'Il en deviendra membre à sa première connexion.',
                errorText: _groupError,
                border: const OutlineInputBorder(),
              ),
              items: [
                for (final g in groups)
                  DropdownMenuItem(value: g.id, child: Text(g.name)),
              ],
              onChanged: enabled
                  ? (id) {
                      setState(() {
                        _groupId = id;
                        _groupError = null;
                        final chosen = _selectedGroup(groups);
                        if (chosen != null) _applyGroupToMessage(chosen.name);
                      });
                    }
                  : null,
            ),
          const SizedBox(height: 20),
          TextField(
            controller: _messageCtrl,
            enabled: enabled,
            minLines: 3,
            maxLines: 8,
            maxLength: kInvitationMessageMax,
            maxLengthEnforcement: MaxLengthEnforcement.enforced,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              labelText: 'Message',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: canSend && !noGroup ? () => _send(group) : null,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_outlined),
              label: Text(_sending ? 'Envoi…' : 'Envoyer l\'invitation'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Aperçu de l'e-mail tel que le serveur le compose
/// (`buildInvitationEmail`, `functions/src/invitations/rules.ts`).
class _EmailPreview extends StatelessWidget {
  final String inviterName;
  final String groupName;
  final String message;
  final String toEmail;

  const _EmailPreview({
    required this.inviterName,
    required this.groupName,
    required this.message,
    required this.toEmail,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final inviter = inviterName.trim().isEmpty ? 'Kass\'Dalle' : inviterName;
    final expires = DateTime.now().add(const Duration(days: 30));
    final body = message.trim().isEmpty
        ? defaultInvitationMessage(groupName)
        : message.trim();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('De : $inviter via Kass\'Dalle', style: muted),
          Text('À : $toEmail', style: muted),
          const SizedBox(height: 4),
          Text(
            '$inviter t\'invite dans « $groupName » sur Kass\'Dalle',
            style: theme.textTheme.titleSmall,
          ),
          const Divider(height: 24),
          Text(body),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              onPressed: null,
              child: const Text('Ouvrir Kass\'Dalle'),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Sur Android, l\'application se télécharge ici : $kAppApkUrl',
            style: muted,
          ),
          const SizedBox(height: 4),
          Text(
            'Connecte-toi avec le compte Google $toEmail. Avec une autre '
            'adresse, ton accès devra être validé à la main.',
            style: muted,
          ),
          const SizedBox(height: 4),
          Text(
            'Cette invitation expire le ${formatDayMonthYear(expires)}.',
            style: muted,
          ),
          const SizedBox(height: 12),
          Text(inviter),
        ],
      ),
    );
  }
}

/// jj/mm/aaaa.
String formatDayMonthYear(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/'
    '${d.month.toString().padLeft(2, '0')}/${d.year}';

/// jj/mm.
String formatDayMonth(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/'
    '${d.month.toString().padLeft(2, '0')}';
