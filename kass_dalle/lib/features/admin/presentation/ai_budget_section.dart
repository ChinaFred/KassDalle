import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_reporting.dart';
import '../../../core/utils/context_extensions.dart';
import '../data/ai_budget_repository.dart';
import 'admin_providers.dart';
import 'costs_format.dart';

/// Plafonds de dépense d'IA, et ce qui a été consommé aujourd'hui.
///
/// Le reste de cet écran regarde le passé : ce que la famille a dépensé, mois
/// par mois. Cette section-ci regarde ce qui peut encore l'être aujourd'hui —
/// c'est le seul endroit de l'application où la dépense se **borne** au lieu de
/// se constater.
class AiBudgetSection extends ConsumerStatefulWidget {
  const AiBudgetSection({super.key});

  @override
  ConsumerState<AiBudgetSection> createState() => _AiBudgetSectionState();
}

class _AiBudgetSectionState extends ConsumerState<AiBudgetSection> {
  AiBudgetSnapshot? _snapshot;
  Object? _error;
  bool _saving = false;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snapshot = await ref.read(aiBudgetRepositoryProvider).fetch();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _error = null;
      });
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.fetchAiBudget',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  Future<void> _save(AiBudgetPolicy policy) async {
    setState(() => _saving = true);
    try {
      final saved = await ref.read(aiBudgetRepositoryProvider).save(policy);
      if (!mounted) return;
      setState(() {
        final previous = _snapshot;
        _snapshot = AiBudgetSnapshot(
          policy: saved,
          day: previous?.day ?? '',
          spends: previous?.spends ?? const [],
        );
      });
      context.showSuccessSnackBar('Plafonds enregistrés.');
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
    final snapshot = _snapshot;

    if (_error != null) {
      return Card(
        color: theme.colorScheme.errorContainer,
        child: ListTile(
          leading: const Icon(Icons.speed),
          title: const Text('Plafonds illisibles'),
          subtitle: Text('$_error'),
          trailing: IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ),
      );
    }

    if (snapshot == null) {
      return const Card(
        child: ListTile(
          leading: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text('Lecture des plafonds…'),
        ),
      );
    }

    final policy = snapshot.policy;
    final spends = snapshot.spends;
    final totalToday = spends.fold<double>(0, (sum, s) => sum + s.costUsd);
    final unpriced = spends.fold<int>(0, (sum, s) => sum + s.unpricedCalls);

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
            title: const Text('Plafond de dépense'),
            subtitle: Text(
              policy.enabled
                  ? 'Aujourd\'hui : ${formatUsd(totalToday)} sur '
                        '${spends.length} compte${spends.length > 1 ? 's' : ''}. '
                        'Plafond ${formatUsd(policy.dailyCostUsdPerUser)} et '
                        '${policy.dailyCallsPerUser} appels par compte et par jour.'
                  : 'Désactivé : aucune limite ne s\'applique.',
            ),
            trailing: IconButton(
              icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (unpriced > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '$unpriced appel${unpriced > 1 ? 's' : ''} sans montant '
                'aujourd\'hui : la grille tarifaire n\'était pas lisible. '
                'Le plafond en nombre d\'appels prend le relais.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (_expanded) ...[
            const Divider(height: 1),
            _PolicyEditor(policy: policy, saving: _saving, onSave: _save),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'Consommé aujourd\'hui (jour UTC ${snapshot.day})',
                style: theme.textTheme.titleSmall,
              ),
            ),
            if (spends.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text('Aucun appel d\'IA aujourd\'hui.'),
              )
            else
              for (final row in spends) _SpendRow(row: row, policy: policy),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

/// Une ligne par compte, avec sa part de plafond déjà consommée.
class _SpendRow extends StatelessWidget {
  final DailySpendRow row;
  final AiBudgetPolicy policy;

  const _SpendRow({required this.row, required this.policy});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // La barre montre le plus contraignant des deux plafonds : c'est celui qui
    // fermera la porte, et afficher l'autre donnerait une marge qui n'existe pas.
    final costRatio = policy.dailyCostUsdPerUser > 0
        ? row.costUsd / policy.dailyCostUsdPerUser
        : 0.0;
    final callsRatio = policy.dailyCallsPerUser > 0
        ? row.calls / policy.dailyCallsPerUser
        : 0.0;
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
                  row.uid,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${formatUsd(row.costUsd)} · ${row.calls} appels',
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
    text: widget.policy.dailyCostUsdPerUser.toString(),
  );
  late final TextEditingController _calls = TextEditingController(
    text: widget.policy.dailyCallsPerUser.toString(),
  );
  late final TextEditingController _alert = TextEditingController(
    text: widget.policy.monthlyAlertUsd.toString(),
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
        dailyCostUsdPerUser: cost,
        dailyCallsPerUser: calls,
        monthlyAlertUsd: alert,
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
            'nombre d\'appels existe pour tenir quand la grille tarifaire est '
            'en panne et que plus rien n\'a de prix. Zéro désactive un critère.',
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
                    labelText: 'Dollars / compte / jour',
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
                    labelText: 'Alerte mensuelle (\$)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
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
