import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'error_message.dart';
import '../theme/app_icon_size.dart';

/// États transverses d'un écran : chargement, vide, erreur.
///
/// Ces trois états étaient réécrits dans chaque écran — une quinzaine de copies
/// de `Center(child: Text('Erreur : $e'))`, aucune avec un bouton Réessayer.
/// Les rassembler ici donne un seul endroit où améliorer le message, et un seul
/// endroit où le corriger.

// ── Chargement ───────────────────────────────────────────────────────────────

class AppLoadingState extends StatelessWidget {
  /// Ce qu'on attend. Un libellé vaut mieux qu'une roue muette dès que
  /// l'attente dépasse la seconde.
  final String? label;

  const AppLoadingState({super.key, this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (label != null) ...[
            const SizedBox(height: 16),
            Text(
              label!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Liste vide ───────────────────────────────────────────────────────────────

class AppEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;

  /// Pourquoi c'est vide, ou quoi faire pour que ça ne le soit plus.
  final String? message;

  /// Action de sortie — « Ajouter un livre », « Lancer un scan ».
  final Widget? action;

  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Décorative : le titre juste en dessous dit la même chose.
              ExcludeSemantics(
                child: Icon(
                  icon,
                  size: AppIconSize.hero,
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (message != null) ...[
                const SizedBox(height: 8),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 20), action!],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Erreur ───────────────────────────────────────────────────────────────────

class AppErrorState extends StatefulWidget {
  final Object? error;

  /// Rappelé par le bouton Réessayer. Sans lui, le bouton n'apparaît pas :
  /// proposer de réessayer sans rien relancer serait un mensonge.
  final VoidCallback? onRetry;

  /// Remplace le titre déduit de l'exception quand l'écran sait mieux.
  final String? title;

  /// Présentation resserrée pour un encart dans une page, plutôt qu'un écran
  /// entier.
  final bool compact;

  const AppErrorState({
    super.key,
    required this.error,
    this.onRetry,
    this.title,
    this.compact = false,
  });

  @override
  State<AppErrorState> createState() => _AppErrorStateState();
}

class _AppErrorStateState extends State<AppErrorState> {
  bool _detailsOpen = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final described = describeError(widget.error);
    final showRetry = widget.onRetry != null && described.retryable;

    // `liveRegion` : le lecteur d'écran annonce le basculement en erreur sans
    // que l'utilisateur ait à repartir explorer l'écran.
    final content = Semantics(
      liveRegion: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Décorative : le titre porte déjà l'information.
          ExcludeSemantics(
            child: Icon(
              Icons.error_outline,
              size: widget.compact ? AppIconSize.medium : AppIconSize.large,
              color: theme.colorScheme.error,
            ),
          ),
          SizedBox(height: widget.compact ? 8 : 16),
          Text(
            widget.title ?? described.title,
            textAlign: TextAlign.center,
            style:
                (widget.compact
                        ? theme.textTheme.titleSmall
                        : theme.textTheme.titleMedium)
                    ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            described.advice,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (showRetry) ...[
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: widget.onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Réessayer'),
            ),
          ],
          if (widget.error != null) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => setState(() => _detailsOpen = !_detailsOpen),
              child: Text(_detailsOpen ? 'Masquer les détails' : 'Détails'),
            ),
            if (_detailsOpen)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  '${widget.error}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
          ],
        ],
      ),
    );

    return Center(
      child: Padding(
        padding: EdgeInsets.all(widget.compact ? 16 : 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: content,
        ),
      ),
    );
  }
}

// ── Câblage AsyncValue ───────────────────────────────────────────────────────

extension AsyncValueStates<T> on AsyncValue<T> {
  /// Rend les trois états d'un [AsyncValue] sans avoir à les réécrire.
  ///
  /// `onRetry` est presque toujours `() => ref.invalidate(monProvider)`.
  Widget render({
    required Widget Function(T value) data,
    VoidCallback? onRetry,
    String? loadingLabel,
    String? errorTitle,
    bool compactError = false,
  }) {
    return when(
      data: data,
      loading: () => AppLoadingState(label: loadingLabel),
      error: (error, _) => AppErrorState(
        error: error,
        onRetry: onRetry,
        title: errorTitle,
        compact: compactError,
      ),
      skipLoadingOnRefresh: false,
    );
  }
}
