import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/error_reporting.dart';
import '../../../../core/services/gemini_providers.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/utils/platform_utils.dart';
import '../../domain/url_import.dart';

/// Ouvre la boîte « Importer depuis un lien » : une feuille sur téléphone, un
/// dialogue de 480 px sur grand écran.
///
/// Réservée aux éditeurs et administrateurs : l'appelant ne montre le point
/// d'entrée qu'à eux, et le serveur refuse les autres. Quand le lien part, la
/// boîte se ferme et un message le confirme.
///
/// [fromManualEntry] : la boîte est ouverte depuis la saisie d'une recette.
/// « Coller le texte » la ferme alors sans naviguer — on y est déjà —, et le
/// message de confirmation ne propose pas « Voir » : quitter la saisie
/// perdrait le texte en cours, et l'écran n'a pas de garde de sortie.
Future<void> showUrlImportDialog(
  BuildContext context, {
  bool fromManualEntry = false,
}) async {
  final router = GoRouter.of(context);
  final wide = MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
  final form = UrlImportForm(fromManualEntry: fromManualEntry);
  final bool? queued;
  if (wide) {
    queued = await showDialog<bool>(
      context: context,
      // La boîte se ferme par ses boutons : un clic à côté pendant l'envoi
      // laisserait l'utilisateur sans réponse.
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: form,
        ),
      ),
    );
  } else {
    queued = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: form,
      ),
    );
  }
  if (queued == true && context.mounted) {
    context.showSuccessSnackBar(
      'Lien envoyé. La recette arrivera dans Brouillons & Traitements.',
      action: fromManualEntry
          ? null
          : SnackBarAction(
              label: 'Voir',
              onPressed: () => router.go('/drafts'),
            ),
    );
  }
}

/// Message de plafond atteint. Sans valeur du serveur, pas de nombre inventé.
String urlImportQuotaMessage(int? limit) => limit == null
    ? 'Vous avez atteint la limite d\'imports par lien pour aujourd\'hui. '
          'Le compteur repart demain.'
    : 'Vous avez atteint la limite d\'imports par lien pour '
          'aujourd\'hui ($limit). Le compteur repart demain.';

/// Le contenu de la boîte. Rend `true` par `Navigator.pop` quand le job est créé.
class UrlImportForm extends ConsumerStatefulWidget {
  const UrlImportForm({super.key, this.fromManualEntry = false});

  final bool fromManualEntry;

  @override
  ConsumerState<UrlImportForm> createState() => _UrlImportFormState();
}

class _UrlImportFormState extends ConsumerState<UrlImportForm> {
  static const _notAWebLink =
      'Cette adresse n\'est pas un lien web (http ou https).';

  final _ctrl = TextEditingController();
  bool _sending = false;
  UrlImportQuota? _quota;

  /// Adresse mal formée : affichée sous le champ (`errorText`).
  String? _fieldError;

  /// Autre message d'échec, annoncé par les lecteurs d'écran.
  String? _error;
  UrlImportResult? _duplicate;
  bool _quotaReached = false;

  @override
  void initState() {
    super.initState();
    _loadQuota();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _loadQuota() async {
    try {
      final quota = await ref.read(geminiServiceProvider).getUrlImportQuota();
      if (!mounted) return;
      setState(() {
        _quota = quota;
        if (quota.remaining <= 0) {
          _quotaReached = true;
          _error = urlImportQuotaMessage(quota.limit);
        }
      });
    } catch (error, stackTrace) {
      // Le compteur ne s'affiche pas ; l'import reste possible, et le serveur
      // tranche le plafond.
      reportUnexpectedError(
        feature: 'urlImportDialog.loadQuota',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _paste() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) return;
      setState(() {
        _ctrl.text = text;
        _clearError();
      });
    } catch (error, stackTrace) {
      // Le presse-papiers est refusé par certains navigateurs : on dit quoi
      // faire à la place.
      reportUnexpectedError(
        feature: 'urlImportDialog.paste',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _error = 'Collez l\'adresse directement dans le champ.');
      }
    }
  }

  void _clearError() {
    _fieldError = null;
    _duplicate = null;
    if (!_quotaReached) _error = null;
  }

  void _pasteTextInstead() {
    final url = _ctrl.text.trim();
    final router = GoRouter.of(context);
    Navigator.of(context).pop(false);
    if (widget.fromManualEntry) return;
    router.push(
      looksLikeWebLink(url)
          ? '/recipes/new?sourceUrl=${Uri.encodeQueryComponent(url)}'
          : '/recipes/new',
    );
  }

  Future<void> _submit({bool force = false}) async {
    final url = _ctrl.text.trim();
    if (!looksLikeWebLink(url)) {
      setState(() {
        _clearError();
        _fieldError = _notAWebLink;
      });
      return;
    }
    setState(() {
      _sending = true;
      _clearError();
    });
    try {
      final result = await ref
          .read(geminiServiceProvider)
          .importRecipeFromUrl(url, force: force);
      if (!mounted) return;
      switch (result.status) {
        case UrlImportStatus.queued:
          Navigator.of(context).pop(true);
          return;
        case UrlImportStatus.invalidUrl:
          _fieldError = _notAWebLink;
        case UrlImportStatus.refused:
          _error =
              'Ce lien ne peut pas être importé. Seules les pages web '
              'publiques sont acceptées.';
        case UrlImportStatus.duplicate:
          _duplicate = result;
          final titre = (result.titre ?? '').trim();
          _error = titre.isEmpty
              ? 'Cette page est déjà dans vos recettes.'
              : 'Cette page est déjà dans vos recettes : « $titre ».';
        case UrlImportStatus.quotaExceeded:
          _quotaReached = true;
          final limit = result.limit ?? _quota?.limit;
          _error = urlImportQuotaMessage(limit);
      }
      setState(() {});
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'urlImportDialog.submit',
        error: error,
        stackTrace: stackTrace,
        context: {'force': force},
      );
      if (mounted) {
        setState(() => _error = 'L\'import n\'a pas pu être lancé. Réessayez.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quota = _quota;
    final duplicate = _duplicate;
    // Pendant l'envoi, ni retour système ni geste ne ferment la boîte.
    return PopScope(
      canPop: !_sending,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Importer depuis un lien', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _ctrl,
              enabled: !_sending && !_quotaReached,
              autofocus: true,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _submit(),
              onChanged: (_) {
                if (_fieldError != null ||
                    _duplicate != null ||
                    (_error != null && !_quotaReached)) {
                  setState(_clearError);
                }
              },
              decoration: InputDecoration(
                labelText: 'Adresse de la page',
                hintText: 'https://…',
                border: const OutlineInputBorder(),
                errorText: _fieldError,
                suffixIcon: IconButton(
                  tooltip: 'Coller l\'adresse',
                  onPressed: (_sending || _quotaReached) ? null : _paste,
                  icon: const Icon(Icons.content_paste),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'La recette arrivera en brouillon dans « Mes recettes du web ».',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Photo du site reprise si la page en a une.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (quota != null && !_quotaReached) ...[
              const SizedBox(height: 4),
              Text(
                'Il vous reste ${quota.remaining} '
                '${quota.remaining > 1 ? 'imports' : 'import'} par lien '
                'aujourd\'hui.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
              if (duplicate != null)
                Wrap(
                  spacing: 8,
                  children: [
                    if (duplicate.recipeId != null)
                      TextButton(
                        onPressed: () {
                          final router = GoRouter.of(context);
                          Navigator.of(context).pop(false);
                          router.push('/recipes/${duplicate.recipeId}');
                        },
                        child: const Text('Ouvrir la recette'),
                      ),
                    TextButton(
                      onPressed: _sending ? null : () => _submit(force: true),
                      child: const Text('Importer quand même'),
                    ),
                  ],
                ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _sending
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: const Text('Annuler'),
                ),
                const SizedBox(width: 8),
                if (_quotaReached)
                  FilledButton(
                    onPressed: _pasteTextInstead,
                    child: const Text('Coller le texte'),
                  )
                else
                  FilledButton(
                    onPressed: _sending ? null : _submit,
                    child: _sending
                        ? Semantics(
                            label: 'Envoi en cours',
                            child: const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : const Text('Importer'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
