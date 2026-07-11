import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'admin_providers.dart';
import '../data/nutrition_units_repository.dart';

const _measurementTypes = <String>['weight', 'volume', 'count', 'unknown'];
const _statuses = <String>['known', 'unknown', 'pending_review', 'deprecated'];
const _sources = <String>['builtin', 'fallback_auto', 'admin_validated'];

class NutritionUnitsScreen extends ConsumerStatefulWidget {
  const NutritionUnitsScreen({super.key});

  @override
  ConsumerState<NutritionUnitsScreen> createState() => _NutritionUnitsScreenState();
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
        title: const Text('Nutrition Units'),
        actions: [
          IconButton(
            tooltip: 'Ajouter une unite',
            onPressed: () => _openCreateDialog(context),
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
              onChanged: (value) => setState(() => _search = value.trim().toLowerCase()),
            ),
          ),
          Expanded(
            child: unitsAsync.when(
              skipLoadingOnReload: true,
              skipLoadingOnRefresh: true,
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Erreur: $e')),
              data: (items) {
                final filtered = items.where(_matchesSearch).toList(growable: false);
                if (filtered.isEmpty) {
                  return const Center(child: Text('Aucune unite trouvee.'));
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final unit = filtered[index];
                    return Card(
                      child: ListTile(
                        title: Text(unit.normalizedUnit),
                        subtitle: Text(
                          '${unit.displayLabel.isEmpty ? 'label:n/a' : unit.displayLabel} · '
                          'type:${unit.measurementType} · status:${unit.status} · seen:${unit.seenCount}',
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (action) {
                            if (action == 'edit') {
                              _openEditDialog(context, unit);
                            } else if (action == 'delete') {
                              _confirmDelete(context, unit);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('Modifier')),
                            PopupMenuItem(value: 'delete', child: Text('Supprimer')),
                          ],
                        ),
                        onTap: () => _openEditDialog(context, unit),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openCreateDialog(context),
        icon: const Icon(Icons.add),
        label: const Text('Nouvelle unite'),
      ),
    );
  }

  bool _matchesSearch(NutritionUnitDoc unit) {
    if (_search.isEmpty) return true;
    final inAliases = unit.aliases.any((a) => a.toLowerCase().contains(_search));
    return unit.normalizedUnit.toLowerCase().contains(_search) ||
        unit.displayLabel.toLowerCase().contains(_search) ||
        unit.measurementType.toLowerCase().contains(_search) ||
        unit.status.toLowerCase().contains(_search) ||
        inAliases;
  }

  Future<void> _openCreateDialog(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<NutritionUnitUpsertInput>(
      context: context,
      builder: (_) => const _UnitEditorDialog(),
    );
    if (!mounted || result == null) return;
    await _runCrudAction(messenger, () async {
      await ref.read(nutritionUnitsRepositoryProvider).create(result);
    }, success: 'Unite creee.');
  }

  Future<void> _openEditDialog(BuildContext context, NutritionUnitDoc doc) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<NutritionUnitUpsertInput>(
      context: context,
      builder: (_) => _UnitEditorDialog(existing: doc),
    );
    if (!mounted || result == null) return;
    await _runCrudAction(messenger, () async {
      await ref.read(nutritionUnitsRepositoryProvider).update(doc.id, result);
    }, success: 'Unite mise a jour.');
  }

  Future<void> _confirmDelete(BuildContext context, NutritionUnitDoc doc) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Supprimer cette unite ?'),
        content: Text('Cette action supprimera ${doc.normalizedUnit} du referentiel.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _runCrudAction(messenger, () async {
      await ref.read(nutritionUnitsRepositoryProvider).delete(doc.id);
    }, success: 'Unite supprimee.');
  }

  Future<void> _runCrudAction(
    ScaffoldMessengerState messenger,
    Future<void> Function() action, {
    required String success,
  }) async {
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text(success)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Erreur: $e')));
    }
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
    _normalizedCtrl = TextEditingController(text: existing?.normalizedUnit ?? '');
    _labelCtrl = TextEditingController(text: existing?.displayLabel ?? '');
    _aliasesCtrl = TextEditingController(text: (existing?.aliases ?? const []).join(', '));
    _gramsCtrl = TextEditingController(
      text: existing?.gramsPerUnit == null ? '' : existing!.gramsPerUnit!.toString(),
    );
    _volumeCtrl = TextEditingController(
      text: existing?.volumeMlPerUnit == null ? '' : existing!.volumeMlPerUnit!.toString(),
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
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'grams_per_unit',
                          border: OutlineInputBorder(),
                        ),
                        validator: _validateNumberField,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _volumeCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
    if (!_formKey.currentState!.validate()) return;

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
