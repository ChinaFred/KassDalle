import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_icon_size.dart';
import 'ai_ui_copy.dart';

/// État d'une étape affichée dans [AiProcessingOverlay].
enum AiProcessingStepState { done, current, upcoming }

/// Une ligne de la liste d'étapes de [AiProcessingOverlay].
class AiProcessingStep {
  final String label;
  final AiProcessingStepState state;

  const AiProcessingStep(this.label, this.state);

  @override
  bool operator ==(Object other) =>
      other is AiProcessingStep && other.label == label && other.state == state;

  @override
  int get hashCode => Object.hash(label, state);

  @override
  String toString() => 'AiProcessingStep($label, ${state.name})';
}

/// Overlay modal de progression pour les traitements IA.
///
/// Il bloque les interactions pendant l'execution et explicite l'etat
/// afin d'eviter l'impression d'un simple spinner sans contexte.
///
/// Un traitement d'IA sur une recette dure une à deux minutes. Le voile
/// affiche donc le temps écoulé, mesuré sur l'appareil, et prévient au-delà
/// de [slowThreshold] que le traitement continue : sans ces repères, un
/// membre a pris une conversion de 131 s pour un blocage.
///
/// [steps] n'est rempli que quand le serveur annonce ses étapes. Vide, aucune
/// liste ne s'affiche : une liste qui n'avance pas laisserait croire au
/// blocage qu'elle doit éviter.
class AiProcessingOverlay extends StatefulWidget {
  final String title;
  final String? message;

  /// Estimation de durée (« Comptez 1 à 2 minutes. »), remplacée par
  /// [RecipeAiUiCopy.processingSlow] après [slowThreshold].
  final String? estimate;

  final List<AiProcessingStep> steps;

  /// Horloge du chronomètre ; `DateTime.now` hors des tests.
  final DateTime Function()? clock;

  /// Durée au-delà de laquelle le voile prévient que c'est plus long que
  /// d'habitude.
  static const slowThreshold = Duration(minutes: 3);

  const AiProcessingOverlay({
    super.key,
    required this.title,
    this.message,
    this.estimate,
    this.steps = const [],
    this.clock,
  });

  @override
  State<AiProcessingOverlay> createState() => _AiProcessingOverlayState();
}

class _AiProcessingOverlayState extends State<AiProcessingOverlay> {
  late final DateTime _startedAt;
  Timer? _ticker;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _startedAt = _now();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final elapsed = _now().difference(_startedAt);
    final slow = elapsed >= AiProcessingOverlay.slowThreshold;
    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final hasSteps = widget.steps.isNotEmpty;
    final durationLine = slow ? RecipeAiUiCopy.processingSlow : widget.estimate;

    return Positioned.fill(
      child: ColoredBox(
        // Même opacité que l'ancien `Colors.black45`, sur la couleur de voile
        // du thème.
        color: theme.colorScheme.scrim.withValues(alpha: 0.45),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              elevation: 8,
              // Défilement interne : avec un texte à 200 % sur un téléphone,
              // la carte dépasse la hauteur de l'écran.
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // Avec une liste, l'indicateur tourne sur l'étape en
                        // cours : un second dans le titre ferait doublon.
                        if (!hasSteps) ...[
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          ),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          child: Text(
                            widget.title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (hasSteps) ...[
                      const SizedBox(height: 12),
                      for (final step in widget.steps)
                        _StepRow(key: ValueKey(step.label), step: step),
                    ],
                    if ((durationLine ?? '').isNotEmpty) ...[
                      const SizedBox(height: 10),
                      // Annoncée une fois, au passage des trois minutes.
                      Semantics(
                        liveRegion: slow,
                        child: Text(durationLine!, style: secondary),
                      ),
                    ],
                    SizedBox(height: durationLine == null ? 10 : 4),
                    Text(
                      RecipeAiUiCopy.processingElapsed(elapsed),
                      style: secondary?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if ((widget.message ?? '').isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(widget.message!, style: secondary),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final AiProcessingStep step;

  const _StepRow({super.key, required this.step});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (Widget marker, String stateLabel) = switch (step.state) {
      AiProcessingStepState.done => (
        Icon(
          Icons.check_circle,
          size: AppIconSize.small,
          color: scheme.primary,
        ),
        'terminé',
      ),
      AiProcessingStepState.current => (
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
        'en cours',
      ),
      AiProcessingStepState.upcoming => (
        Icon(
          Icons.radio_button_unchecked,
          size: AppIconSize.small,
          color: scheme.onSurfaceVariant,
        ),
        'à venir',
      ),
    };
    final current = step.state == AiProcessingStepState.current;
    return Semantics(
      // L'étape en cours est annoncée par le lecteur d'écran quand elle
      // change ; les autres se lisent au parcours.
      liveRegion: current,
      label: '${step.label}, $stateLabel',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: AppIconSize.small,
              child: Center(child: marker),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                step.label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: current ? FontWeight.w600 : null,
                  color: step.state == AiProcessingStepState.upcoming
                      ? scheme.onSurfaceVariant
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
