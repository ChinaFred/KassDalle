import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_reporting.dart';
import '../../../core/utils/context_extensions.dart';
import '../domain/nutrition_policy.dart';
import 'billing_providers.dart';

/// Réglage de la politique de calcul nutritionnel.
///
/// Ces trois seuils gouvernaient déjà l'onglet Nutrition de chaque recette,
/// mais aucun écran ne les exposait : le document Firestore n'ayant jamais été
/// écrit, seules les valeurs par défaut du backend avaient jamais servi.
///
/// Chaque curseur est présenté par son effet observable, pas par son nom
/// technique : un seuil qu'on règle sans savoir ce qu'il masque est un seuil
/// qu'on règle au hasard.
class NutritionPolicyScreen extends ConsumerStatefulWidget {
  const NutritionPolicyScreen({super.key});

  @override
  ConsumerState<NutritionPolicyScreen> createState() =>
      _NutritionPolicyScreenState();
}

class _NutritionPolicyScreenState extends ConsumerState<NutritionPolicyScreen> {
  NutritionPolicy? _loaded;
  NutritionPolicy? _draft;
  Object? _loadError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final policy = await ref
          .read(gcpBillingRepositoryProvider)
          .fetchNutritionPolicy();
      if (!mounted) return;
      setState(() {
        _loaded = policy;
        _draft = policy;
        _loadError = null;
      });
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.fetchNutritionPolicy',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() => _loadError = error);
    }
  }

  Future<void> _save() async {
    final draft = _draft;
    if (draft == null) return;
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(gcpBillingRepositoryProvider)
          .saveNutritionPolicy(draft);
      if (!mounted) return;
      setState(() {
        _loaded = saved;
        _draft = saved;
      });
      context.showSuccessSnackBar(
        'Politique enregistrée. Elle s\'applique au prochain calcul de chaque recette.',
      );
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.saveNutritionPolicy',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) context.showErrorSnackBar('Enregistrement refusé : $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool get _dirty =>
      _draft != null && _loaded != null && !_draft!.sameSettingsAs(_loaded!);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final draft = _draft;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Politique nutrition'),
        actions: [
          if (draft != null)
            TextButton(
              onPressed: _saving || draft.sameSettingsAs(NutritionPolicy.defaults)
                  ? null
                  : () => setState(
                      () => _draft = draft.copyWith(
                        minCoverageForPartial:
                            NutritionPolicy.defaults.minCoverageForPartial,
                        minCoverageForPer100g:
                            NutritionPolicy.defaults.minCoverageForPer100g,
                        kcalConsistencyWarnDeltaPct: NutritionPolicy
                            .defaults
                            .kcalConsistencyWarnDeltaPct,
                        fallbackPolicy: NutritionPolicy.defaults.fallbackPolicy,
                      ),
                    ),
              child: const Text('Valeurs par défaut'),
            ),
        ],
      ),
      floatingActionButton: draft == null
          ? null
          : FloatingActionButton.extended(
              onPressed: (_saving || !_dirty || !draft.isConsistent)
                  ? null
                  : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(_saving ? 'Enregistrement…' : 'Enregistrer'),
            ),
      body: _loadError != null
          ? _ErrorBody(error: _loadError!, onRetry: _load)
          : draft == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'La « couverture » est la part des ingrédients d\'une '
                            'recette dont le poids est connu. Plus le seuil est '
                            'haut, plus l\'app se tait quand elle n\'est pas sûre.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                _RatioSlider(
                  title: 'Afficher un calcul nutritionnel',
                  effect:
                      'En dessous de ce seuil, l\'app remplace le détail par '
                      '« Trop peu d\'ingrédients ont un poids connu pour que le '
                      'calcul soit représentatif ».',
                  value: draft.minCoverageForPartial,
                  enabled: !_saving,
                  onChanged: (v) => setState(
                    () => _draft = draft.copyWith(minCoverageForPartial: v),
                  ),
                ),
                const SizedBox(height: 8),

                _RatioSlider(
                  title: 'Afficher les valeurs pour 100 g',
                  effect:
                      'En dessous de ce seuil, les valeurs pour 100 g sont '
                      'masquées : ramener à 100 g un poids total incomplet '
                      'donnerait un chiffre faux.',
                  value: draft.minCoverageForPer100g,
                  enabled: !_saving,
                  onChanged: (v) => setState(
                    () => _draft = draft.copyWith(minCoverageForPer100g: v),
                  ),
                ),

                if (!draft.isConsistent)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Le seuil des valeurs pour 100 g ne peut pas être plus '
                      'permissif que celui du calcul : l\'app afficherait un '
                      'détail pour 100 g sur une recette qu\'elle déclare par '
                      'ailleurs trop incomplète.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),

                _RatioSlider(
                  title: 'Tolérance d\'incohérence des calories',
                  effect:
                      'Au-delà de cet écart entre les calories annoncées et '
                      'celles recalculées depuis protéines, glucides et lipides, '
                      'l\'app signale qu\'une valeur du référentiel est '
                      'probablement inexacte.',
                  value: draft.kcalConsistencyWarnDeltaPct,
                  enabled: !_saving,
                  max: 0.5,
                  onChanged: (v) => setState(
                    () => _draft = draft.copyWith(
                      // Zéro est refusé par le backend : ce seuil sert de
                      // dénominateur au score de qualité.
                      kcalConsistencyWarnDeltaPct: v <= 0.01 ? 0.01 : v,
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                _ReadOnlyCard(policy: draft),
              ],
            ),
    );
  }
}

// ── Curseur de ratio ──────────────────────────────────────────────────────────

class _RatioSlider extends StatelessWidget {
  final String title;
  final String effect;
  final double value;
  final bool enabled;
  final double max;
  final ValueChanged<double> onChanged;

  const _RatioSlider({
    required this.title,
    required this.effect,
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.max = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = (value * 100).round();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: theme.textTheme.titleSmall),
                ),
                Text(
                  '$pct %',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(effect, style: theme.textTheme.bodySmall),
            Slider(
              value: value.clamp(0, max),
              max: max,
              divisions: (max * 100).round(),
              label: '$pct %',
              onChanged: enabled ? onChanged : null,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Réglages non modifiables ici ──────────────────────────────────────────────

class _ReadOnlyCard extends StatelessWidget {
  final NutritionPolicy policy;

  const _ReadOnlyCard({required this.policy});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ordre de confiance des sources', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Quand un ingrédient a plusieurs origines de valeurs, la première '
              'de cette liste l\'emporte. Modifier cet ordre demande de '
              'comprendre la chaîne d\'enrichissement : il se règle côté backend.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            ...policy.sourcePriority.asMap().entries.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text(
                  '${e.key + 1}. ${_sourceLabel(e.value)}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
            const Divider(height: 24),
            Text('Repli', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              _fallbackLabel(policy.fallbackPolicy),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  static String _sourceLabel(String source) => switch (source) {
    'user_validated' => 'Valeurs validées à la main',
    'internal_reference' => 'Référentiel interne',
    'external_reference' => 'Référentiel externe',
    'ai_estimated' => 'Estimation par l\'IA',
    _ => source,
  };

  static String _fallbackLabel(String policy) => switch (policy) {
    'off' => 'Aucun repli : un ingrédient sans donnée reste sans donnée.',
    'strict' =>
      'Strict : repli seulement sur des correspondances sûres. (Valeur en vigueur.)',
    'permissive' =>
      'Permissif : accepte des correspondances approchantes, au risque de valeurs inexactes.',
    _ => policy,
  };
}

class _ErrorBody extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ErrorBody({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error, size: 40),
            const SizedBox(height: 12),
            Text(
              'Politique illisible',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Réessayer'),
            ),
          ],
        ),
      ),
    );
  }
}
