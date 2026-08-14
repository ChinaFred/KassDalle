import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_reporting.dart';
import '../../../core/utils/context_extensions.dart';
import '../data/ai_routing_repository.dart';
import '../../../core/widgets/error_message.dart';

final aiRoutingRepositoryProvider = Provider<AiRoutingRepository>((ref) {
  return AiRoutingRepository();
});

/// Choix du moteur d'IA, poste par poste.
///
/// Le projet a longtemps eu un seul moteur, donc aucune décision à prendre.
/// Avec deux, la question n'est plus « lequel est le meilleur » dans l'absolu
/// mais « lequel sur quel poste » : l'extraction d'un scan est massivement de
/// l'entrée (une image, peu de sortie), l'estimation nutritionnelle est
/// l'inverse. Comme les tarifs des deux fournisseurs ne sont pas dans le même
/// rapport à l'entrée et à la sortie, la réponse diffère d'un poste à l'autre.
///
/// Cet écran existe pour que la comparaison se fasse sur des données réelles :
/// basculer un poste ne demande pas de déploiement, et le coût de chaque moteur
/// se lit ensuite dans l'écran Comptabilité, à la même clé de poste.
class AiRoutingScreen extends ConsumerStatefulWidget {
  const AiRoutingScreen({super.key});

  @override
  ConsumerState<AiRoutingScreen> createState() => _AiRoutingScreenState();
}

class _AiRoutingScreenState extends ConsumerState<AiRoutingScreen> {
  AiRoutingSnapshot? _snapshot;
  AiRoutingPolicy? _draft;
  Object? _loadError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snapshot = await ref.read(aiRoutingRepositoryProvider).fetch();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _draft = snapshot.policy;
        _loadError = null;
      });
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.fetchAiRoutingPolicy',
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
      final saved = await ref.read(aiRoutingRepositoryProvider).save(draft);
      if (!mounted) return;
      setState(() {
        _snapshot = AiRoutingSnapshot(
          policy: saved.policy,
          anthropicKeyPresent: saved.anthropicKeyPresent,
          routableFeatures: _snapshot?.routableFeatures ?? const [],
        );
        _draft = saved.policy;
      });
      context.showSuccessSnackBar('Politique de routage enregistrée.');
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.saveAiRoutingPolicy',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      context.showErrorSnackBar('Enregistrement impossible : $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Bascule d'un coup tous les postes fournis.
  ///
  /// Une trentaine de postes se bascule par famille, jamais un par un : sans
  /// ce geste, essayer Claude sur tout l'import demanderait cinq allers-retours
  /// et personne ne le ferait.
  void _setProviderFor(Iterable<String> featureIds, AiProvider provider) {
    final draft = _draft;
    if (draft == null) return;
    final features = Map<String, AiProvider>.from(draft.features);
    for (final id in featureIds) {
      features[id] = provider;
    }
    setState(() => _draft = draft.copyWith(features: features));
  }

  bool get _dirty {
    final draft = _draft;
    final loaded = _snapshot?.policy;
    if (draft == null || loaded == null) return false;
    if (draft.defaultProvider != loaded.defaultProvider) return true;
    if (draft.anthropicModel != loaded.anthropicModel) return true;
    if (draft.fallbackEnabled != loaded.fallbackEnabled) return true;
    if (draft.thinkingBudget != loaded.thinkingBudget) return true;
    if (draft.features.length != loaded.features.length) return true;
    for (final entry in draft.features.entries) {
      if (loaded.features[entry.key] != entry.value) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = _snapshot;
    final draft = _draft;

    return Scaffold(
      appBar: AppBar(title: const Text('Moteur d\'IA')),
      body: _loadError != null
          ? _ErrorState(error: _loadError!, onRetry: _load)
          : (snapshot == null || draft == null)
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (!snapshot.anthropicKeyPresent)
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(
                            Icons.key_off_outlined,
                            color: theme.colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'La clé Claude n\'est pas posée dans Secret Manager. '
                              'Les postes routés vers Claude continuent d\'être servis '
                              'par Gemini — aucune erreur, mais aucune bascule non plus.',
                              style: TextStyle(
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Text('Réglages généraux', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        title: const Text('Moteur par défaut'),
                        subtitle: const Text(
                          'Sert tous les postes qui n\'ont pas de choix explicite.',
                        ),
                        trailing: _ProviderToggle(
                          value: draft.defaultProvider,
                          onChanged: (provider) => setState(
                            () => _draft = draft.copyWith(
                              defaultProvider: provider,
                            ),
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        value: draft.fallbackEnabled,
                        onChanged: (value) => setState(
                          () => _draft = draft.copyWith(fallbackEnabled: value),
                        ),
                        title: const Text('Repli automatique'),
                        subtitle: const Text(
                          'Si le moteur choisi échoue techniquement, l\'autre prend le relais. '
                          'Une réponse refusée pour raison de sûreté n\'est jamais rejouée ailleurs.',
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        title: const Text('Modèle Claude'),
                        subtitle: Text(draft.anthropicModel),
                        trailing: DropdownButton<String>(
                          value: draft.anthropicModel,
                          onChanged: (value) => setState(
                            () => _draft = draft.copyWith(
                              anthropicModel: value ?? draft.anthropicModel,
                            ),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'claude-haiku-4-5',
                              child: Text('Haiku 4.5 — 1 \$ / 5 \$'),
                            ),
                            DropdownMenuItem(
                              value: 'claude-sonnet-5',
                              child: Text('Sonnet 5 — 3 \$ / 15 \$'),
                            ),
                            DropdownMenuItem(
                              value: 'claude-opus-5',
                              child: Text('Opus 5 — 5 \$ / 25 \$'),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      // Le réglage qui pèse le plus lourd sur la facture
                      // Gemini, et le seul qui ne se voyait nulle part : le
                      // raisonnement est facturé au tarif de sortie sans
                      // jamais apparaître dans une réponse.
                      _ThinkingBudgetTile(
                        value: draft.thinkingBudget,
                        onChanged: (value) => setState(
                          () => _draft = draft.copyWith(
                            thinkingBudget: value,
                            clearThinkingBudget: value == null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Postes fonctionnels',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: () => _setProviderFor(
                        snapshot.routableFeatures.map((f) => f.id),
                        AiProvider.gemini,
                      ),
                      child: const Text('Tout Gemini'),
                    ),
                    TextButton(
                      onPressed: () => _setProviderFor(
                        snapshot.routableFeatures.map((f) => f.id),
                        AiProvider.anthropic,
                      ),
                      child: const Text('Tout Claude'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Chaque poste est une clé du reporting de coûts : ce que vous '
                  'basculez ici se mesure dans l\'écran Comptabilité.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                for (final group in _groupedFeatures(
                  snapshot.routableFeatures,
                ).entries) ...[
                  _GroupHeader(
                    title: group.key,
                    count: group.value.length,
                    onAll: (provider) =>
                        _setProviderFor(group.value.map((f) => f.id), provider),
                  ),
                  Card(
                    child: Column(
                      children: [
                        for (final feature in group.value) ...[
                          ListTile(
                            title: Text(feature.label),
                            subtitle: Text(
                              feature.id,
                              style: theme.textTheme.bodySmall,
                            ),
                            trailing: _ProviderToggle(
                              value: draft.providerFor(feature.id),
                              onChanged: (provider) =>
                                  _setProviderFor([feature.id], provider),
                            ),
                          ),
                          if (feature != group.value.last)
                            const Divider(height: 1),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: (_dirty && !_saving) ? _save : null,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(_saving ? 'Enregistrement…' : 'Enregistrer'),
                ),
              ],
            ),
    );
  }
}

/// Plafond de raisonnement de Gemini.
///
/// Gemini 2.5 Flash délibère avant de répondre. Ces jetons sont facturés au
/// tarif de sortie et n'apparaissent dans aucune réponse : sur un mois observé,
/// ils pesaient 2,1 millions de jetons sur les 2,4 millions de sortie
/// facturés. Beaucoup de postes n'en ont aucun besoin — classer une page ou
/// proposer des tags ne demande pas de délibération.
///
/// « Le modèle décide » reste le défaut : couper le raisonnement partout
/// dégraderait les postes qui en vivent, l'extraction d'un scan en tête.
class _ThinkingBudgetTile extends StatelessWidget {
  final int? value;
  final ValueChanged<int?> onChanged;

  const _ThinkingBudgetTile({required this.value, required this.onChanged});

  /// `null` ne peut pas être la valeur d'un `DropdownMenuItem` distinguée d'une
  /// absence de sélection : le sentinelle négatif porte « le modèle décide ».
  static const _auto = -1;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: const Text('Raisonnement de Gemini'),
      subtitle: const Text(
        'Facturé au tarif de sortie, sans jamais apparaître dans la réponse. '
        'Le couper allège la ligne la plus chère de la facture Gemini, au prix '
        'de la qualité sur les postes qui délibèrent vraiment.',
      ),
      trailing: DropdownButton<int>(
        value: value ?? _auto,
        onChanged: (next) => onChanged(next == _auto ? null : next),
        items: const [
          DropdownMenuItem(value: _auto, child: Text('Le modèle décide')),
          DropdownMenuItem(value: 0, child: Text('Coupé')),
          DropdownMenuItem(value: 512, child: Text('512 jetons')),
          DropdownMenuItem(value: 2048, child: Text('2 048 jetons')),
          DropdownMenuItem(value: 8192, child: Text('8 192 jetons')),
        ],
      ),
    );
  }
}

/// Regroupe les postes par famille en conservant l'ordre du serveur.
///
/// L'ordre vient du backend et non d'un tri alphabétique : il suit le parcours
/// d'une recette (import, illustrations, rédaction…), ce qu'un tri par lettre
/// détruirait.
Map<String, List<RoutableFeature>> _groupedFeatures(
  List<RoutableFeature> features,
) {
  final grouped = <String, List<RoutableFeature>>{};
  for (final feature in features) {
    grouped.putIfAbsent(feature.group, () => []).add(feature);
  }
  return grouped;
}

class _GroupHeader extends StatelessWidget {
  final String title;
  final int count;
  final ValueChanged<AiProvider> onAll;

  const _GroupHeader({
    required this.title,
    required this.count,
    required this.onAll,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$title · $count poste${count > 1 ? 's' : ''}',
              style: theme.textTheme.titleSmall,
            ),
          ),
          TextButton(
            onPressed: () => onAll(AiProvider.gemini),
            child: const Text('Gemini'),
          ),
          TextButton(
            onPressed: () => onAll(AiProvider.anthropic),
            child: const Text('Claude'),
          ),
        ],
      ),
    );
  }
}

class _ProviderToggle extends StatelessWidget {
  final AiProvider value;
  final ValueChanged<AiProvider> onChanged;

  const _ProviderToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<AiProvider>(
      segments: const [
        ButtonSegment(value: AiProvider.gemini, label: Text('Gemini')),
        ButtonSegment(value: AiProvider.anthropic, label: Text('Claude')),
      ],
      selected: {value},
      showSelectedIcon: false,
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ErrorState({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Politique de routage illisible — ${shortErrorMessage(error)}',
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Réessayer')),
          ],
        ),
      ),
    );
  }
}
