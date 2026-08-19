import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'admin_providers.dart';
import '../data/nutrition_units_repository.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/widgets/app_states.dart';

const _measurementTypes = <String>['weight', 'volume', 'count', 'unknown'];
const _statuses = <String>['known', 'unknown', 'pending_review', 'deprecated'];
const _sources = <String>['builtin', 'fallback_auto', 'admin_validated'];

class NutritionUnitsScreen extends ConsumerStatefulWidget {
  const NutritionUnitsScreen({super.key});

  @override
  ConsumerState<NutritionUnitsScreen> createState() =>
      _NutritionUnitsScreenState();
}

class _NutritionUnitsScreenState extends ConsumerState<NutritionUnitsScreen> {
  final _searchCtrl = TextEditingController();
  String _search = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unitsAsync = ref.watch(allNutritionUnitsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Unités de mesure'),
        actions: [
          IconButton(
            tooltip: 'Initialiser les unités par défaut',
            onPressed: _seedDefaults,
            icon: const Icon(Icons.auto_fix_high_outlined),
          ),
          IconButton(
            tooltip: 'Ajouter une unité',
            onPressed: _openCreateDialog,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Rechercher (id, label, alias, type, status)',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _search = '');
                        },
                        icon: const Icon(Icons.close),
                      ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) =>
                  setState(() => _search = value.trim().toLowerCase()),
            ),
          ),
          Expanded(
            child: unitsAsync.when(
              skipLoadingOnReload: true,
              skipLoadingOnRefresh: true,
              loading: () => const AppLoadingState(),
              error: (e, _) => AppErrorState(
                error: e,
                onRetry: () => ref.invalidate(allNutritionUnitsProvider),
              ),
              data: (items) {
                final filtered = items
                    .where(_matchesSearch)
                    .toList(growable: false);
                if (filtered.isEmpty) {
                  return const Center(child: Text('Aucune unite trouvee.'));
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: filtered.length,
                  itemBuilder: (_, index) {
                    final unit = filtered[index];
                    return _UnitCard(
                      unit: unit,
                      onEdit: () => _openEditDialog(unit),
                      onDelete: () => _confirmDelete(unit),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreateDialog,
        icon: const Icon(Icons.add),
        label: const Text('Nouvelle unite'),
      ),
    );
  }

  bool _matchesSearch(NutritionUnitDoc unit) {
    if (_search.isEmpty) return true;
    final inAliases = unit.aliases.any(
      (a) => a.toLowerCase().contains(_search),
    );
    return unit.normalizedUnit.toLowerCase().contains(_search) ||
        unit.displayLabel.toLowerCase().contains(_search) ||
        unit.measurementType.toLowerCase().contains(_search) ||
        unit.status.toLowerCase().contains(_search) ||
        inAliases;
  }

  Future<void> _openCreateDialog() async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<NutritionUnitUpsertInput>(
      context: context,
      builder: (_) => const _UnitEditorDialog(),
    );
    if (!mounted || result == null) return;
    await _runCrudAction(
      messenger,
      () async {
        await ref.read(nutritionUnitsRepositoryProvider).create(result);
      },
      success: 'Unite creee.',
      feature: 'admin_nutrition_units_create',
    );
  }

  Future<void> _openEditDialog(NutritionUnitDoc doc) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<NutritionUnitUpsertInput>(
      context: context,
      builder: (_) => _UnitEditorDialog(existing: doc),
    );
    if (!mounted || result == null) return;
    await _runCrudAction(
      messenger,
      () async {
        await ref.read(nutritionUnitsRepositoryProvider).update(doc.id, result);
      },
      success: 'Unite mise a jour.',
      feature: 'admin_nutrition_units_update',
      context: {'docId': doc.id},
    );
  }

  Future<void> _confirmDelete(NutritionUnitDoc doc) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Supprimer cette unite ?'),
        content: Text(
          'Cette action supprimera ${doc.normalizedUnit} du referentiel.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _runCrudAction(
      messenger,
      () async {
        await ref.read(nutritionUnitsRepositoryProvider).delete(doc.id);
      },
      success: 'Unite supprimee.',
      feature: 'admin_nutrition_units_delete',
      context: {'docId': doc.id, 'normalizedUnit': doc.normalizedUnit},
    );
  }

  Future<void> _seedDefaults() async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Initialiser les unités par défaut ?'),
        content: const Text(
          'Crée les unités standard françaises absentes, et complète '
          'les unités existantes qui n’ont pas encore leur grammage ou volume.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Initialiser'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _runCrudAction(
      messenger,
      () async {
        final r = await ref
            .read(nutritionUnitsRepositoryProvider)
            .seedDefaultUnits();
        final msg = (r.created == 0 && r.patched == 0)
            ? 'Tout était déjà à jour.'
            : '${r.created} créée(s), ${r.patched} mise(s) à jour.';
        messenger.showSnackBar(SnackBar(content: Text(msg)));
      },
      success: '',
      feature: 'admin_nutrition_units_seed',
    );
  }

  Future<void> _runCrudAction(
    ScaffoldMessengerState messenger,
    Future<void> Function() action, {
    required String success,
    required String feature,
    Map<String, dynamic> context = const {},
  }) async {
    try {
      await action();
      if (success.isNotEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(success)));
      }
    } catch (e, st) {
      try {
        await ref
            .read(errorReportServiceProvider)
            .reportError(
              feature: feature,
              error: e,
              stackTrace: st,
              context: context,
            );
      } catch (error, stackTrace) {
        reportUnexpectedError(
          feature: 'nutritionUnitsScreen.runCrudAction',
          error: error,
          stackTrace: stackTrace,
        );
      }
      messenger.showSnackBar(SnackBar(content: Text('Erreur: $e')));
    }
  }
}

class _UnitCard extends StatelessWidget {
  final NutritionUnitDoc unit;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _UnitCard({
    required this.unit,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = unit.displayLabel.isNotEmpty
        ? unit.displayLabel
        : unit.normalizedUnit;
    final hasConversion =
        unit.gramsPerUnit != null || unit.volumeMlPerUnit != null;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(label, style: theme.textTheme.titleMedium),
                        const SizedBox(width: 8),
                        _StatusBadge(unit.status),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      children: [
                        _InfoChip(icon: Icons.code, label: unit.normalizedUnit),
                        _InfoChip(
                          icon: Icons.straighten,
                          label: _typeLabel(unit.measurementType),
                        ),
                        if (unit.gramsPerUnit != null)
                          _InfoChip(
                            icon: Icons.kitchen_outlined,
                            label: '${_fmt(unit.gramsPerUnit!)} g',
                          ),
                        if (unit.volumeMlPerUnit != null)
                          _InfoChip(
                            icon: Icons.water_drop_outlined,
                            label: '${_fmt(unit.volumeMlPerUnit!)} ml',
                          ),
                        if (!hasConversion)
                          _InfoChip(
                            icon: Icons.warning_amber_outlined,
                            label: 'pas de conversion',
                          ),
                        if (unit.aliases.isNotEmpty)
                          _InfoChip(
                            icon: Icons.label_outline,
                            label: unit.aliases.take(3).join(', '),
                          ),
                        if (unit.seenCount > 0)
                          _InfoChip(
                            icon: Icons.visibility_outlined,
                            label: 'vu ${unit.seenCount}×',
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (action) {
                  if (action == 'edit') onEdit();
                  if (action == 'delete') onDelete();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Modifier')),
                  PopupMenuItem(value: 'delete', child: Text('Supprimer')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _typeLabel(String type) => switch (type) {
    'weight' => 'masse',
    'volume' => 'volume',
    'count' => 'comptage',
    _ => type,
  };

  String _fmt(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge(this.status);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = switch (status) {
      'known' => ('connu', theme.colorScheme.primary),
      'unknown' => ('inconnu', theme.colorScheme.error),
      'pending_review' => ('à valider', theme.colorScheme.tertiary),
      'deprecated' => ('obsolète', theme.disabledColor),
      _ => (status, theme.disabledColor),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
}

class _UnitEditorDialog extends StatefulWidget {
  final NutritionUnitDoc? existing;

  const _UnitEditorDialog({this.existing});

  @override
  State<_UnitEditorDialog> createState() => _UnitEditorDialogState();
}

class _UnitEditorDialogState extends State<_UnitEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _normalizedCtrl;
  late final TextEditingController _labelCtrl;
  late final TextEditingController _aliasesCtrl;
  late final TextEditingController _gramsCtrl;
  late final TextEditingController _volumeCtrl;

  late String _measurementType;
  late String _status;
  late String _source;

  bool get _isCreate => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _normalizedCtrl = TextEditingController(
      text: existing?.normalizedUnit ?? '',
    );
    _labelCtrl = TextEditingController(text: existing?.displayLabel ?? '');
    _aliasesCtrl = TextEditingController(
      text: (existing?.aliases ?? const []).join(', '),
    );
    _gramsCtrl = TextEditingController(
      text: existing?.gramsPerUnit == null
          ? ''
          : existing!.gramsPerUnit!.toString(),
    );
    _volumeCtrl = TextEditingController(
      text: existing?.volumeMlPerUnit == null
          ? ''
          : existing!.volumeMlPerUnit!.toString(),
    );
    _measurementType = existing?.measurementType ?? 'unknown';
    _status = existing?.status ?? 'pending_review';
    _source = existing?.source ?? 'fallback_auto';
  }

  @override
  void dispose() {
    _normalizedCtrl.dispose();
    _labelCtrl.dispose();
    _aliasesCtrl.dispose();
    _gramsCtrl.dispose();
    _volumeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isCreate ? 'Nouvelle unite' : 'Modifier unite'),
      content: SizedBox(
        width: 560,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _normalizedCtrl,
                  enabled: _isCreate,
                  decoration: const InputDecoration(
                    labelText: 'normalized_unit',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final v = (value ?? '').trim();
                    if (v.isEmpty) return 'Champ obligatoire';
                    if (!RegExp(r'^[a-z0-9_]+$').hasMatch(v)) {
                      return 'Utiliser uniquement a-z, 0-9 et _';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _labelCtrl,
                  decoration: const InputDecoration(
                    labelText: 'display_label',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _aliasesCtrl,
                  decoration: const InputDecoration(
                    labelText: 'aliases (separes par ,)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _measurementType,
                  decoration: const InputDecoration(
                    labelText: 'measurement_type',
                    border: OutlineInputBorder(),
                  ),
                  items: _measurementTypes
                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                      .toList(growable: false),
                  onChanged: (value) {
                    if (value != null) setState(() => _measurementType = value);
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _gramsCtrl,
                        enabled: _measurementType != 'volume',
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: 'grams_per_unit',
                          border: const OutlineInputBorder(),
                          // Sur une unité de volume, le poids dépend de la
                          // densité de l'ingrédient : une valeur saisie ici
                          // serait ignorée à la conversion. Champ désactivé
                          // plutôt que silencieusement sans effet.
                          helperText: _measurementType == 'volume'
                              ? 'Ignoré : poids = volume × densité de l\'ingrédient'
                              : null,
                          helperMaxLines: 2,
                        ),
                        validator: _validateNumberField,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _volumeCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'volume_ml_per_unit',
                          border: OutlineInputBorder(),
                        ),
                        validator: _validateNumberField,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _status,
                  decoration: const InputDecoration(
                    labelText: 'status',
                    border: OutlineInputBorder(),
                  ),
                  items: _statuses
                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                      .toList(growable: false),
                  onChanged: (value) {
                    if (value != null) setState(() => _status = value);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _source,
                  decoration: const InputDecoration(
                    labelText: 'source',
                    border: OutlineInputBorder(),
                  ),
                  items: _sources
                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                      .toList(growable: false),
                  onChanged: (value) {
                    if (value != null) setState(() => _source = value);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(_isCreate ? 'Creer' : 'Enregistrer'),
        ),
      ],
    );
  }

  String? _validateNumberField(String? value) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) return null;
    final parsed = double.tryParse(raw.replaceAll(',', '.'));
    if (parsed == null || parsed < 0) return 'Nombre invalide';
    return null;
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final aliases = _aliasesCtrl.text
        .split(',')
        .map((a) => a.trim())
        .where((a) => a.isNotEmpty)
        .toSet()
        .toList(growable: false);

    final input = NutritionUnitUpsertInput(
      normalizedUnit: _normalizedCtrl.text.trim(),
      displayLabel: _labelCtrl.text.trim(),
      aliases: aliases,
      measurementType: _measurementType,
      gramsPerUnit: _parseNullableDouble(_gramsCtrl.text),
      volumeMlPerUnit: _parseNullableDouble(_volumeCtrl.text),
      status: _status,
      source: _source,
    );

    Navigator.of(context).pop(input);
  }

  double? _parseNullableDouble(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return null;
    return double.tryParse(raw.replaceAll(',', '.'));
  }
}
