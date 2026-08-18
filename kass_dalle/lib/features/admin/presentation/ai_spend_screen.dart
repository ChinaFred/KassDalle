import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_reporting.dart';
import '../../../core/utils/context_extensions.dart';
import '../data/ai_budget_repository.dart';
import '../data/feature_catalog.dart';
import 'admin_providers.dart';
import 'costs_format.dart';
import 'monthly_costs_screen.dart' show CostsDepthChips, costsDepthProvider;

/// Dépense par utilisateur, et plafonds.
///
/// Écran à part et non section d'un onglet : les coûts mensuels répondent à
/// « combien l'application coûte », celui-ci à « qui dépense, à quoi, et
/// jusqu'où il peut aller ». Ce sont deux questions qu'on ne se pose pas au
/// même moment, et la seconde a besoin de place — une ligne par compte, un
/// détail par poste.
///
/// Le sélecteur de période est celui des deux autres onglets, à l'état près :
/// c'est le même composant et le même provider, pour qu'un mois choisi ici se
/// retrouve là-bas.
class AiSpendScreen extends ConsumerStatefulWidget {
  const AiSpendScreen({super.key});

  @override
  ConsumerState<AiSpendScreen> createState() => _AiSpendScreenState();
}

class _AiSpendScreenState extends ConsumerState<AiSpendScreen> {
  AiBudgetSnapshot? _snapshot;
  Object? _error;
  bool _loading = true;
  bool _saving = false;
  int? _loadedDepth;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final depth = ref.read(costsDepthProvider);
    if (_loadedDepth != depth || _snapshot == null) _load(depth);
  }

  Future<void> _load(int? depth) async {
    setState(() {
      _loading = true;
      _loadedDepth = depth;
    });
    try {
      final snapshot = await ref
          .read(aiBudgetRepositoryProvider)
          .fetch(depth: depth);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _error = null;
        _loading = false;
      });
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.fetchAiSpend',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _save(AiBudgetPolicy policy) async {
    setState(() => _saving = true);
    try {
      await ref.read(aiBudgetRepositoryProvider).save(policy);
      if (!mounted) return;
      context.showSuccessSnackBar('Plafonds enregistrés.');
      await _load(ref.read(costsDepthProvider));
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.saveAiBudget',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      context.showErrorSnackBar('Enregistrement impossible : $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final depth = ref.watch(costsDepthProvider);
    final snapshot = _snapshot;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dépense par utilisateur'),
        actions: [
          IconButton(
            tooltip: 'Rafraîchir',
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(depth),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          CostsDepthChips(
            depth: depth,
            onChanged: (months) {
              ref.read(costsDepthProvider.notifier).set(months);
              _load(months);
            },
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Card(
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.error_outline),
                title: const Text('Lecture impossible'),
                subtitle: Text('$_error'),
                trailing: IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _load(depth),
                ),
              ),
            )
          else if (snapshot == null || (_loading && _snapshot == null))
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            _BudgetCard(snapshot: snapshot, saving: _saving, onSave: _save),
            const SizedBox(height: 16),
            _PeriodHeader(snapshot: snapshot, loading: _loading),
            const SizedBox(height: 8),
            if (snapshot.spends.isEmpty)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.person_off_outlined),
                  title: Text('Aucune dépense sur la période'),
                ),
              )
            else
              for (final user in snapshot.spends)
                _UserCard(user: user, snapshot: snapshot),
          ],
        ],
      ),
    );
  }
}

/// Ce que la période couvre, et ce qu'elle ne peut pas montrer.
class _PeriodHeader extends StatelessWidget {
  final AiBudgetSnapshot snapshot;
  final bool loading;

  const _PeriodHeader({required this.snapshot, required this.loading});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final periods = snapshot.periods;
    final total = snapshot.spends.fold<double>(0, (sum, u) => sum + u.costUsd);
    final calls = snapshot.spends.fold<int>(0, (sum, u) => sum + u.calls);

    final label = periods.isEmpty
        ? 'Aucun mois enregistré'
        : periods.length == 1
        ? periods.single
        : '${periods.first} → ${periods.last}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Période : $label',
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Text(
                '${formatMoney(total, snapshot.usdToEur ?? 0)} · ${formatCount(calls)} appels',
                style: theme.textTheme.titleMedium,
              ),
          ],
        ),
        if (snapshot.periodsWithoutBreakdown.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Le détail par service manque pour ${snapshot.periodsWithoutBreakdown.join(', ')} : '
              'ces mois sont antérieurs à sa mise en place. Leur total reste juste, et une '
              'reconstruction des agrégats les rattrape.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

/// Un compte, son total sur la période, et le détail par service.
class _UserCard extends StatelessWidget {
  final UserSpend user;
  final AiBudgetSnapshot snapshot;

  const _UserCard({required this.user, required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rate = snapshot.usdToEur ?? 0;
    final isFounder = user.uid == snapshot.founderUid;

    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.person_outline),
        title: Row(
          children: [
            Expanded(child: Text(user.label, overflow: TextOverflow.ellipsis)),
            if (isFounder)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Chip(
                  label: Text('×${snapshot.founderMultiplier}'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  backgroundColor: theme.colorScheme.tertiaryContainer,
                  labelStyle: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Text(
          '${formatMoney(user.costUsd, rate)} · ${formatCount(user.calls)} appels',
        ),
        children: [
          if (user.byFeature.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text('Aucun détail par service sur cette période.'),
            )
          else
            for (final feature in user.byFeature)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        featureLabel(feature.feature),
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${formatMoney(feature.costUsd, rate)} · ${formatCount(feature.calls)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Les plafonds, et ce que la journée en cours a déjà consommé.
class _BudgetCard extends StatelessWidget {
  final AiBudgetSnapshot snapshot;
  final bool saving;
  final Future<void> Function(AiBudgetPolicy) onSave;

  const _BudgetCard({
    required this.snapshot,
    required this.saving,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final policy = snapshot.policy;
    final today = snapshot.today;
    final unpriced = today.fold<int>(0, (sum, s) => sum + s.unpricedCalls);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: Icon(
              policy.enabled ? Icons.speed : Icons.speed_outlined,
              color: policy.enabled
                  ? theme.colorScheme.primary
                  : theme.colorScheme.error,
            ),
            title: const Text('Plafond quotidien'),
            subtitle: Text(
              policy.enabled
                  ? '${formatEur(policy.dailyCostEurPerUser)} et '
                        '${policy.dailyCallsPerUser} appels par compte et par jour. '
                        'Le compte fondateur en a ${snapshot.founderMultiplier} fois plus.'
                  : 'Désactivé : aucune limite ne s\'applique.',
            ),
          ),
          if (snapshot.usdToEur == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Aucun taux de change relevé : le plafond en euros ne peut pas être '
                'appliqué, et les montants restent en dollars. Seul le plafond en '
                'nombre d\'appels protège pour l\'instant.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (unpriced > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '$unpriced appel${unpriced > 1 ? 's' : ''} sans montant aujourd\'hui : '
                'la grille tarifaire n\'était pas lisible. Le plafond en nombre '
                'd\'appels prend le relais.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Aujourd\'hui (jour UTC ${snapshot.day})',
              style: theme.textTheme.titleSmall,
            ),
          ),
          if (today.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text('Aucun appel d\'IA aujourd\'hui.'),
            )
          else
            for (final row in today) _TodayRow(row: row, snapshot: snapshot),
          const Divider(height: 1),
          _PolicyEditor(policy: policy, saving: saving, onSave: onSave),
        ],
      ),
    );
  }
}

/// Une ligne par compte, avec sa part de plafond déjà consommée.
class _TodayRow extends StatelessWidget {
  final DailySpendRow row;
  final AiBudgetSnapshot snapshot;

  const _TodayRow({required this.row, required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rate = snapshot.usdToEur ?? 0;
    final costLimit = snapshot.costLimitEurFor(row.uid);
    final callsLimit = snapshot.callsLimitFor(row.uid);

    // La barre montre le plus contraignant des deux plafonds : c'est celui qui
    // fermera la porte, et afficher l'autre donnerait une marge qui n'existe
    // pas. Sans taux, le plafond en euros n'entre pas dans le calcul — il ne
    // s'applique pas non plus côté serveur.
    final costRatio = (costLimit > 0 && rate > 0)
        ? (row.costUsd * rate) / costLimit
        : 0.0;
    final callsRatio = callsLimit > 0 ? row.calls / callsLimit : 0.0;
    final ratio = (costRatio > callsRatio ? costRatio : callsRatio).clamp(
      0.0,
      1.0,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.uid == snapshot.founderUid
                      ? '${row.uid}  (×${snapshot.founderMultiplier})'
                      : row.uid,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${formatMoney(row.costUsd, rate)} · ${row.calls} appels',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 6,
              color: ratio >= 1
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Les quatre réglages, modifiables sans redéployer.
class _PolicyEditor extends StatefulWidget {
  final AiBudgetPolicy policy;
  final bool saving;
  final Future<void> Function(AiBudgetPolicy) onSave;

  const _PolicyEditor({
    required this.policy,
    required this.saving,
    required this.onSave,
  });

  @override
  State<_PolicyEditor> createState() => _PolicyEditorState();
}

class _PolicyEditorState extends State<_PolicyEditor> {
  late final TextEditingController _cost = TextEditingController(
    text: widget.policy.dailyCostEurPerUser.toString(),
  );
  late final TextEditingController _calls = TextEditingController(
    text: widget.policy.dailyCallsPerUser.toString(),
  );
  late final TextEditingController _alert = TextEditingController(
    text: widget.policy.monthlyAlertEur.toString(),
  );
  late bool _enabled = widget.policy.enabled;
  String? _error;

  @override
  void dispose() {
    _cost.dispose();
    _calls.dispose();
    _alert.dispose();
    super.dispose();
  }

  void _submit() {
    final cost = double.tryParse(_cost.text.replaceAll(',', '.'));
    final calls = int.tryParse(_calls.text);
    final alert = double.tryParse(_alert.text.replaceAll(',', '.'));

    // Une saisie invalide est refusée, jamais devinée : un plafond retombé à
    // zéro par accident se lirait « aucune limite ».
    if (cost == null || calls == null || alert == null) {
      setState(() => _error = 'Trois nombres sont attendus.');
      return;
    }
    if (cost < 0 || calls < 0 || alert < 0) {
      setState(() => _error = 'Aucune valeur ne peut être négative.');
      return;
    }

    setState(() => _error = null);
    widget.onSave(
      widget.policy.copyWith(
        dailyCostEurPerUser: cost,
        dailyCallsPerUser: calls,
        monthlyAlertEur: alert,
        enabled: _enabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Un plafond atteint refuse les appels d\'IA de ce compte jusqu\'au '
            'lendemain — les autres comptes ne sont pas touchés. Le plafond en '
            'nombre d\'appels existe pour tenir quand la grille tarifaire ou le '
            'taux de change manquent, et qu\'aucun montant n\'est comparable. '
            'Zéro désactive un critère.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 190,
                child: TextField(
                  controller: _cost,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Euros / compte / jour',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              SizedBox(
                width: 190,
                child: TextField(
                  controller: _calls,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Appels / compte / jour',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              SizedBox(
                width: 190,
                child: TextField(
                  controller: _alert,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Alerte mensuelle (€)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
            title: const Text('Plafonds actifs'),
            subtitle: const Text(
              'Les couper laisse la dépense libre — le temps d\'un import massif.',
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: widget.saving ? null : _submit,
              icon: widget.saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('Enregistrer'),
            ),
          ),
        ],
      ),
    );
  }
}
