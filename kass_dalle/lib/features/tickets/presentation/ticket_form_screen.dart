import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/app_version.dart';
import '../../../core/presentation/leave_guard.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/error_message.dart';
import '../../auth/presentation/auth_providers.dart';
import '../data/ticket_repository.dart';
import '../domain/ticket.dart';
import '../domain/ticket_form.dart';
import '../domain/ticket_screens.dart';
import 'ticket_widgets.dart';
import 'tickets_providers.dart';

/// « Signaler ou proposer » : le formulaire d'un ticket (`/tickets/new`).
///
/// [initialScreen] est le modèle de route de l'écran quitté, lu dans le
/// paramètre `ecran`. Il ne sert qu'à présélectionner la liste « Écran
/// concerné », dont les valeurs forment un ensemble fermé
/// ([ticketScreenValue]) : une adresse réelle glissée dans l'URL devient
/// « Je ne sais pas ».
class TicketFormScreen extends ConsumerStatefulWidget {
  final String? initialScreen;
  const TicketFormScreen({super.key, this.initialScreen});

  @override
  ConsumerState<TicketFormScreen> createState() => _TicketFormScreenState();
}

class _TicketFormScreenState extends ConsumerState<TicketFormScreen> {
  final _titleCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  final _typeFocus = FocusNode();
  final _titleFocus = FocusNode();
  final _descriptionFocus = FocusNode();

  TicketType? _type;
  late String _screen = ticketScreenValue(widget.initialScreen);

  /// Image de l'écran quitté, prise par le shell. Jointe seulement si la
  /// case est cochée.
  Uint8List? _shellCapture;
  bool _attachShellCapture = false;

  /// Image choisie dans la galerie ou parmi les fichiers.
  TicketScreenshot? _picked;
  String? _pickError;

  TicketFormErrors _errors = const TicketFormErrors();
  bool _sending = false;
  bool _done = false;

  late final LeaveGuardNotifier _leaveGuardNotifier;
  late final LeaveGuard _leaveGuard = _confirmLeave;

  @override
  void initState() {
    super.initState();
    _leaveGuardNotifier = ref.read(leaveGuardProvider.notifier);
    _shellCapture = ref.read(pendingTicketCaptureProvider);
    _titleCtrl.addListener(_onTextChanged);
    _descriptionCtrl.addListener(_onTextChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Reprise après la première image : modifier un provider pendant la
      // construction de l'arbre est refusé par Riverpod.
      ref.read(pendingTicketCaptureProvider.notifier).take();
      _leaveGuardNotifier.set(_leaveGuard);
    });
  }

  @override
  void dispose() {
    final notifier = _leaveGuardNotifier;
    final guard = _leaveGuard;
    Future.microtask(() => notifier.clearIf(guard));
    _titleCtrl.dispose();
    _descriptionCtrl.dispose();
    _typeFocus.dispose();
    _titleFocus.dispose();
    _descriptionFocus.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    // La faute d'un champ disparaît dès qu'on le corrige.
    if (_errors.title != null || _errors.description != null) {
      setState(() {
        _errors = TicketFormErrors(
          type: _errors.type,
          title: _titleCtrl.text.trim().isEmpty ? _errors.title : null,
          description: _descriptionCtrl.text.trim().isEmpty
              ? _errors.description
              : null,
        );
      });
    } else {
      setState(() {});
    }
  }

  bool get _hasInput =>
      !_done &&
      (_titleCtrl.text.trim().isNotEmpty ||
          _descriptionCtrl.text.trim().isNotEmpty ||
          _picked != null);

  Future<bool> _confirmLeave() async {
    if (!_hasInput) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Abandonner ce ticket ?'),
        content: const Text('Le texte saisi sera perdu.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Continuer la saisie'),
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
    _closeForm();
  }

  void _closeForm() {
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
    } else {
      router.go(AppRoutes.tickets);
    }
  }

  // ── Capture ─────────────────────────────────────────────────────────────────

  Future<void> _pickImage() async {
    try {
      Uint8List? bytes;
      if (PlatformUtils.isMobile) {
        final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery,
        );
        if (picked == null) return;
        bytes = await picked.readAsBytes();
      } else {
        final result = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['png', 'jpg', 'jpeg'],
          withData: true,
        );
        if (result == null || result.files.isEmpty) return;
        bytes = result.files.single.bytes;
      }
      if (!mounted) return;
      if (bytes == null) {
        setState(() {
          _picked = null;
          _pickError = 'Seules les images PNG ou JPEG sont acceptées.';
        });
        return;
      }
      final check = checkTicketScreenshot(bytes);
      setState(() {
        _picked = check.screenshot;
        _pickError = check.error;
        if (check.screenshot != null) _attachShellCapture = false;
      });
    } catch (e, st) {
      reportUnexpectedError(
        feature: 'tickets',
        error: e,
        stackTrace: st,
        context: {'step': 'pick_image'},
      );
      if (mounted) {
        context.showErrorSnackBar(
          'Image non ouverte : ${shortErrorMessage(e)}',
        );
      }
    }
  }

  /// La capture qui partira avec le ticket, ou `null`.
  TicketScreenshot? get _screenshotToSend {
    final shell = _shellCapture;
    if (_attachShellCapture && shell != null) {
      return checkTicketScreenshot(shell).screenshot;
    }
    return _picked;
  }

  // ── Envoi ───────────────────────────────────────────────────────────────────

  Future<void> _send() async {
    if (_sending) return;
    final errors = validateTicketForm(
      type: _type,
      title: _titleCtrl.text,
      description: _descriptionCtrl.text,
    );
    if (!errors.isValid) {
      setState(() => _errors = errors);
      if (errors.type != null) {
        _typeFocus.requestFocus();
      } else if (errors.title != null) {
        _titleFocus.requestFocus();
      } else {
        _descriptionFocus.requestFocus();
      }
      return;
    }
    final user = ref.read(appUserProvider).value;
    if (user == null) return;
    final platform = currentTicketPlatform();
    if (platform == null) {
      context.showErrorSnackBar(
        'Cette plateforme ne permet pas d\'envoyer un ticket.',
      );
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _sending = true;
      _errors = const TicketFormErrors();
    });
    try {
      final result = await ref
          .read(ticketRepositoryProvider)
          .submit(
            uid: user.uid,
            type: _type!,
            title: _titleCtrl.text,
            description: _descriptionCtrl.text,
            screen: _screen,
            appVersion: kAppVersion,
            platform: platform,
            screenshot: _screenshotToSend,
          );
      ref
          .read(lastTicketRemainingProvider.notifier)
          .record(result.remainingToday, DateTime.now());
      if (!mounted) return;
      _done = true;
      final router = GoRouter.of(context);
      context.showSuccessSnackBar(
        result.screenshotFailed
            ? 'Ticket envoyé, sans la capture : elle n\'a pas pu être '
                  'jointe. Vous pouvez le suivre dans Mes tickets.'
            : 'Ticket envoyé. Vous pouvez le suivre dans Mes tickets.',
        action: SnackBarAction(
          label: 'Voir',
          onPressed: () => router.go(AppRoutes.ticketDetail(result.ticketId)),
        ),
      );
      _closeForm();
    } on TicketSubmitError catch (e) {
      // Déjà remontée par `TicketRepository` (feature `tickets`), sauf un
      // plafond atteint, qui est une réponse attendue. Le texte saisi reste.
      if (mounted) context.showErrorSnackBar(e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ── Affichage ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
    final remaining = ref.watch(remainingTicketsTodayProvider);

    final formFields = _FormFields(
      type: _type,
      typeFocus: _typeFocus,
      titleCtrl: _titleCtrl,
      titleFocus: _titleFocus,
      descriptionCtrl: _descriptionCtrl,
      descriptionFocus: _descriptionFocus,
      screen: _screen,
      errors: _errors,
      enabled: !_sending,
      onTypeChanged: (type) => setState(() {
        _type = type;
        _errors = TicketFormErrors(
          title: _errors.title,
          description: _errors.description,
        );
      }),
      onScreenChanged: (value) => setState(() => _screen = value),
    );

    final capture = _CaptureSection(
      shellCapture: _shellCapture,
      attachShellCapture: _attachShellCapture,
      picked: _picked,
      pickError: _pickError,
      enabled: !_sending,
      onAttachChanged: (value) => setState(() {
        _attachShellCapture = value;
        if (value) {
          _picked = null;
          _pickError = null;
        }
      }),
      onPick: _pickImage,
      onRemovePicked: () => setState(() {
        _picked = null;
        _pickError = null;
      }),
    );

    final sendBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          // Toujours actif : les fautes se disent à l'appui, sous leur champ.
          onPressed: _sending ? () {} : _send,
          icon: _sending
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send_outlined),
          label: Text(_sending ? 'Envoi…' : 'Envoyer'),
        ),
        if (remainingTicketsNotice(remaining) case final notice?) ...[
          const SizedBox(height: 8),
          Text(
            notice,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );

    final side = [
      if (isWide && _type != null) ...[
        _TypeHelp(type: _type!),
        const SizedBox(height: 16),
      ],
      const _PublicWarning(),
      const SizedBox(height: 16),
      const _SendInfo(),
    ];

    final body = isWide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      formFields,
                      const SizedBox(height: 16),
                      capture,
                      const SizedBox(height: 24),
                      sendBlock,
                    ],
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                flex: 2,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: side,
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
                formFields,
                const SizedBox(height: 16),
                capture,
                const SizedBox(height: 16),
                ...side,
                const SizedBox(height: 24),
                sendBlock,
              ],
            ),
          );

    return PopScope(
      canPop: !_hasInput,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _leaveAfterConfirmation();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Signaler ou proposer')),
        body: AbsorbPointer(absorbing: _sending, child: body),
      ),
    );
  }
}

class _FormFields extends StatelessWidget {
  final TicketType? type;
  final FocusNode typeFocus;
  final TextEditingController titleCtrl;
  final FocusNode titleFocus;
  final TextEditingController descriptionCtrl;
  final FocusNode descriptionFocus;
  final String screen;
  final TicketFormErrors errors;
  final bool enabled;
  final ValueChanged<TicketType> onTypeChanged;
  final ValueChanged<String> onScreenChanged;

  const _FormFields({
    required this.type,
    required this.typeFocus,
    required this.titleCtrl,
    required this.titleFocus,
    required this.descriptionCtrl,
    required this.descriptionFocus,
    required this.screen,
    required this.errors,
    required this.enabled,
    required this.onTypeChanged,
    required this.onScreenChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Type', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (i, t) in TicketType.values.indexed)
              ChoiceChip(
                focusNode: i == 0 ? typeFocus : null,
                avatar: Icon(ticketTypeIcon(t)),
                label: Text(t.label),
                selected: type == t,
                onSelected: enabled ? (_) => onTypeChanged(t) : null,
              ),
          ],
        ),
        if (errors.type != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 12),
            child: Semantics(
              liveRegion: true,
              child: Text(
                errors.type!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ),
        const SizedBox(height: 16),
        TextField(
          controller: titleCtrl,
          focusNode: titleFocus,
          enabled: enabled,
          maxLength: kTicketTitleMaxLength,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: 'Titre',
            border: const OutlineInputBorder(),
            errorText: errors.title,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: descriptionCtrl,
          focusNode: descriptionFocus,
          enabled: enabled,
          maxLength: kTicketDescriptionMaxLength,
          minLines: 5,
          maxLines: 12,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration(
            labelText: 'Description',
            alignLabelWithHint: true,
            border: const OutlineInputBorder(),
            hintText: type?.descriptionHint,
            hintMaxLines: 4,
            errorText: errors.description,
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: screen,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Écran concerné',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final option in ticketScreenOptions())
              DropdownMenuItem(
                value: option.value,
                child: Text(option.label, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: enabled
              ? (value) {
                  if (value != null) onScreenChanged(value);
                }
              : null,
        ),
      ],
    );
  }
}

class _CaptureSection extends StatelessWidget {
  final Uint8List? shellCapture;
  final bool attachShellCapture;
  final TicketScreenshot? picked;
  final String? pickError;
  final bool enabled;
  final ValueChanged<bool> onAttachChanged;
  final VoidCallback onPick;
  final VoidCallback onRemovePicked;

  const _CaptureSection({
    required this.shellCapture,
    required this.attachShellCapture,
    required this.picked,
    required this.pickError,
    required this.enabled,
    required this.onAttachChanged,
    required this.onPick,
    required this.onRemovePicked,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shell = shellCapture;
    final chosen = picked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Capture', style: theme.textTheme.titleSmall),
        if (shell != null) ...[
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: attachShellCapture,
            onChanged: enabled ? (v) => onAttachChanged(v ?? false) : null,
            title: const Text('Joindre une capture de l\'écran précédent'),
          ),
          _Thumbnail(bytes: shell, label: 'Capture de l\'écran précédent'),
          const SizedBox(height: 8),
        ],
        if (!attachShellCapture) ...[
          if (chosen != null) ...[
            const SizedBox(height: 8),
            _Thumbnail(bytes: chosen.bytes, label: 'Capture choisie'),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: enabled ? onRemovePicked : null,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Retirer la capture'),
              ),
            ),
          ] else
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: enabled ? onPick : null,
                icon: Icon(
                  PlatformUtils.isMobile
                      ? Icons.photo_library_outlined
                      : Icons.upload_file_outlined,
                ),
                label: Text(
                  PlatformUtils.isMobile
                      ? 'Choisir dans la galerie'
                      : 'Choisir un fichier',
                ),
              ),
            ),
        ],
        if (pickError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Semantics(
              liveRegion: true,
              child: Text(
                pickError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Thumbnail extends StatelessWidget {
  final Uint8List bytes;
  final String label;
  const _Thumbnail({required this.bytes, required this.label});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.memory(
          bytes,
          height: 140,
          fit: BoxFit.contain,
          semanticLabel: label,
        ),
      ),
    );
  }
}

/// Aide du type choisi, dans la colonne de droite sur grand écran.
class _TypeHelp extends StatelessWidget {
  final TicketType type;
  const _TypeHelp({required this.type});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(ticketTypeIcon(type)),
                const SizedBox(width: 8),
                Text(type.label, style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 8),
            Text(type.descriptionHint, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// Le titre et la description partent sur un site public.
class _PublicWarning extends StatelessWidget {
  const _PublicWarning();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: cs.onTertiaryContainer,
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(Icons.public, color: cs.onTertiaryContainer),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Le titre et la description seront publiés sur un site '
                  'public. N\'y mettez ni nom, ni adresse, ni recette privée.',
                  style: style?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  'Votre nom et la capture ne sont jamais publiés : seul '
                  'l\'administrateur les voit.',
                  style: style,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// « Envoyé avec : version X, Plateforme ».
class _SendInfo extends StatelessWidget {
  const _SendInfo();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final platform = currentTicketPlatform();
    return Text(
      'Envoyé avec : version $kAppVersion, '
      '${ticketPlatformLabel(platform ?? '')}',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
