import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'admin_providers.dart';
import '../../planning/domain/meal_staple.dart';
import '../../planning/presentation/meal_staples_providers.dart';
import '../../planning/presentation/staple_allergens_field.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/theme/app_icon_size.dart';

/// Le référentiel des garnitures simples, tenu par un administrateur.
///
/// Riz, pâtes, salade verte, yaourt : ce qui accompagne un plat sans avoir de
/// recette, avec la part par personne. La liste de base se sème d'un bouton
/// et ne remplace jamais une valeur corrigée ici. Ce que chacun retouche
/// pour soi vit ailleurs, sous son compte.
class MealStaplesScreen extends ConsumerStatefulWidget {
  const MealStaplesScreen({super.key});

  @override
  ConsumerState<MealStaplesScreen> createState() => _MealStaplesScreenState();
}

class _MealStaplesScreenState extends ConsumerState<MealStaplesScreen> {
  final _searchCtrl = TextEditingController();
  String _search = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final staplesAsync = ref.watch(baseMealStaplesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Garnitures simples'),
        // Le semis de la liste de base ne vit pas ici : c'est une écriture
        // ponctuelle, et elle se lance depuis Admin › Backfills avec les
        // autres. Cet écran montre et corrige.
        actions: [
          IconButton(
            tooltip: 'Ajouter une garniture',
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
                hintText: 'Rechercher (nom, famille, produit)',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _search = '');
                        },
                        tooltip: 'Effacer la recherche',
                        icon: const Icon(Icons.close),
                      ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) =>
                  setState(() => _search = value.trim().toLowerCase()),
            ),
          ),
          Expanded(
            child: staplesAsync.when(
              skipLoadingOnReload: true,
              skipLoadingOnRefresh: true,
              loading: () => const AppLoadingState(),
              error: (e, _) => AppErrorState(
                error: e,
                onRetry: () => ref.invalidate(baseMealStaplesProvider),
              ),
              data: (items) {
                if (items.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Aucune garniture. Ajoutez-en une avec le bouton '
                        '« Nouvelle garniture ».',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                final sorted = [...items]..sort(_compare);
                final filtered = sorted
                    .where(_matchesSearch)
                    .toList(growable: false);
                if (filtered.isEmpty) {
                  return const Center(
                    child: Text('Aucune garniture ne correspond.'),
                  );
                }
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
                  children: _withCategoryHeaders(context, filtered),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreateDialog,
        icon: const Icon(Icons.add),
        label: const Text('Nouvelle garniture'),
      ),
    );
  }

  static int _compare(MealStaple a, MealStaple b) {
    final byCategory = a.category.index.compareTo(b.category.index);
    if (byCategory != 0) return byCategory;
    final byOrder = a.sortOrder.compareTo(b.sortOrder);
    if (byOrder != 0) return byOrder;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  bool _matchesSearch(MealStaple s) {
    if (_search.isEmpty) return true;
    return s.id.contains(_search) ||
        s.name.toLowerCase().contains(_search) ||
        s.category.label.toLowerCase().contains(_search) ||
        s.effectiveShoppingProduct.toLowerCase().contains(_search) ||
        s.note.toLowerCase().contains(_search);
  }

  /// La liste, avec un en-tête à chaque changement de famille.
  List<Widget> _withCategoryHeaders(
    BuildContext context,
    List<MealStaple> staples,
  ) {
    final theme = Theme.of(context);
    final out = <Widget>[];
    StapleCategory? current;
    for (final s in staples) {
      if (s.category != current) {
        current = s.category;
        out.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
            child: Text(
              s.category.label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        );
      }
      out.add(
        _StapleCard(
          staple: s,
          onEdit: () => _openEditDialog(s),
          onToggleActive: () => _toggleActive(s),
          onDelete: () => _confirmDelete(s),
        ),
      );
    }
    return out;
  }

  Future<void> _openCreateDialog() async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<MealStaple>(
      context: context,
      builder: (_) => const _StapleEditorDialog(),
    );
    if (!mounted || result == null) return;
    await _runAction(
      messenger,
      () => ref.read(mealStaplesRepositoryProvider).createBase(result),
      success: 'Garniture créée.',
      feature: 'admin_meal_staples_create',
      context: {'id': result.id},
    );
  }

  Future<void> _openEditDialog(MealStaple staple) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<MealStaple>(
      context: context,
      builder: (_) => _StapleEditorDialog(existing: staple),
    );
    if (!mounted || result == null) return;
    await _runAction(
      messenger,
      () => ref.read(mealStaplesRepositoryProvider).updateBase(result),
      success: 'Garniture mise à jour.',
      feature: 'admin_meal_staples_update',
      context: {'id': staple.id},
    );
  }

  Future<void> _toggleActive(MealStaple staple) async {
    final messenger = ScaffoldMessenger.of(context);
    await _runAction(
      messenger,
      () => ref
          .read(mealStaplesRepositoryProvider)
          .updateBase(staple.copyWith(active: !staple.active)),
      success: staple.active
          ? '« ${staple.name} » désactivée : plus proposée à personne.'
          : '« ${staple.name} » réactivée.',
      feature: 'admin_meal_staples_toggle_active',
      context: {'id': staple.id, 'active': !staple.active},
    );
  }

  Future<void> _confirmDelete(MealStaple staple) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Supprimer cette garniture ?'),
        content: Text(
          '« ${staple.name} » disparaît du référentiel. Les retouches que des '
          'utilisateurs y ont faites ne s\'appliqueront plus. Pour la retirer '
          'sans perdre ces retouches, désactivez-la plutôt.',
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
    await _runAction(
      messenger,
      () => ref.read(mealStaplesRepositoryProvider).deleteBase(staple.id),
      success: 'Garniture supprimée.',
      feature: 'admin_meal_staples_delete',
      context: {'id': staple.id},
    );
  }

  Future<void> _runAction(
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
          feature: 'mealStaplesScreen.runAction',
          error: error,
          stackTrace: stackTrace,
        );
      }
      messenger.showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
  }
}

class _StapleCard extends StatelessWidget {
  final MealStaple staple;
  final VoidCallback onEdit;
  final VoidCallback onToggleActive;
  final VoidCallback onDelete;

  const _StapleCard({
    required this.staple,
    required this.onEdit,
    required this.onToggleActive,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
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
                        Flexible(
                          child: Text(
                            staple.name,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: staple.active ? null : muted,
                              decoration: staple.active
                                  ? null
                                  : TextDecoration.lineThrough,
                            ),
                          ),
                        ),
                        if (!staple.active) ...[
                          const SizedBox(width: 8),
                          _Badge('désactivée', theme.colorScheme.error),
                        ] else if (staple.source == 'admin') ...[
                          const SizedBox(width: 8),
                          _Badge('ajoutée', theme.colorScheme.tertiary),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 10,
                      runSpacing: 2,
                      children: [
                        _Info(Icons.code, staple.id),
                        _Info(Icons.scale_outlined, staple.quantityLabel),
                        if (staple.note.isNotEmpty)
                          _Info(Icons.info_outline, staple.note),
                        if (staple.shoppingProduct.trim().isNotEmpty)
                          _Info(
                            Icons.shopping_cart_outlined,
                            staple.effectiveShoppingProduct,
                          ),
                        _Info(Icons.sort, 'rang ${staple.sortOrder}'),
                        _Info(
                          Icons.health_and_safety_outlined,
                          stapleAllergensSummary(staple.allergens),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (action) {
                  if (action == 'edit') onEdit();
                  if (action == 'toggle') onToggleActive();
                  if (action == 'delete') onDelete();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Modifier')),
                  PopupMenuItem(
                    value: 'toggle',
                    child: Text(staple.active ? 'Désactiver' : 'Réactiver'),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Supprimer'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge(this.label, this.color);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withAlpha(25),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: color.withAlpha(80)),
    ),
    child: Text(label, style: TextStyle(fontSize: 11, color: color)),
  );
}

class _Info extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Info(this.icon, this.label);

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: AppIconSize.badge, color: color),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
}

/// Création ou modification d'une garniture de base.
///
/// L'identifiant ne se choisit qu'à la création : il est la clé du document
/// et celle des retouches des utilisateurs. Vide, il se déduit du nom.
class _StapleEditorDialog extends StatefulWidget {
  final MealStaple? existing;

  const _StapleEditorDialog({this.existing});

  @override
  State<_StapleEditorDialog> createState() => _StapleEditorDialogState();
}

class _StapleEditorDialogState extends State<_StapleEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _idCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _quantityCtrl;
  late final TextEditingController _noteCtrl;
  late final TextEditingController _shoppingCtrl;
  late final TextEditingController _sortCtrl;
  late StapleCategory _category;
  late String _unit;
  late bool _active;
  List<String>? _allergens;

  bool get _isCreate => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _idCtrl = TextEditingController(text: e?.id ?? '');
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _quantityCtrl = TextEditingController(
      text: e == null ? '' : _fmt(e.quantityPerPortion),
    );
    _noteCtrl = TextEditingController(text: e?.note ?? '');
    _shoppingCtrl = TextEditingController(text: e?.shoppingProduct ?? '');
    _sortCtrl = TextEditingController(text: e == null ? '0' : '${e.sortOrder}');
    _category = e?.category ?? StapleCategory.feculent;
    _unit = e?.unit ?? 'g';
    _active = e?.active ?? true;
    _allergens = e?.allergens;
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _nameCtrl.dispose();
    _quantityCtrl.dispose();
    _noteCtrl.dispose();
    _shoppingCtrl.dispose();
    _sortCtrl.dispose();
    super.dispose();
  }

  static String _fmt(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isCreate ? 'Nouvelle garniture' : 'Modifier la garniture'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nameCtrl,
                  autofocus: _isCreate,
                  decoration: const InputDecoration(
                    labelText: 'Nom',
                    hintText: 'Pâtes',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Champ obligatoire' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _idCtrl,
                  enabled: _isCreate,
                  decoration: const InputDecoration(
                    labelText: 'Identifiant',
                    helperText: 'Vide : déduit du nom. Minuscules, chiffres, _',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) {
                    final id = (v ?? '').trim();
                    if (id.isEmpty) return null;
                    if (!RegExp(r'^[a-z0-9_]+$').hasMatch(id)) {
                      return 'Utiliser uniquement a-z, 0-9 et _';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<StapleCategory>(
                  initialValue: _category,
                  decoration: const InputDecoration(
                    labelText: 'Famille',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final c in StapleCategory.values)
                      DropdownMenuItem(value: c, child: Text(c.label)),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _category = v);
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: _quantityCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Quantité par part',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) {
                          final q = double.tryParse(
                            (v ?? '').trim().replaceAll(',', '.'),
                          );
                          if (q == null || q <= 0) return 'Nombre positif';
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _unit,
                        decoration: const InputDecoration(
                          labelText: 'Unité',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final u in kStapleUnits)
                            DropdownMenuItem(value: u, child: Text(u)),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _unit = v);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _noteCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Note',
                    hintText: 'poids sec',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _shoppingCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Produit de courses',
                    helperText: 'Vide : le nom de la garniture',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _sortCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Rang dans sa famille',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 4),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  subtitle: const Text(
                    'Désactivée, elle n\'est proposée à personne.',
                  ),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
                const SizedBox(height: 8),
                StapleAllergensField(
                  value: _allergens,
                  onChanged: (v) => setState(() => _allergens = v),
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
          child: Text(_isCreate ? 'Créer' : 'Enregistrer'),
        ),
      ],
    );
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final name = _nameCtrl.text.trim();
    final typedId = _idCtrl.text.trim();
    final id = _isCreate
        ? (typedId.isEmpty ? stapleIdFromName(name) : typedId)
        : widget.existing!.id;
    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Impossible de déduire un identifiant de ce nom.'),
        ),
      );
      return;
    }
    Navigator.of(context).pop(
      MealStaple(
        id: id,
        name: name,
        category: _category,
        quantityPerPortion: double.parse(
          _quantityCtrl.text.trim().replaceAll(',', '.'),
        ),
        unit: _unit,
        note: _noteCtrl.text.trim(),
        shoppingProduct: _shoppingCtrl.text.trim(),
        sortOrder: int.tryParse(_sortCtrl.text.trim()) ?? 0,
        active: _active,
        source: widget.existing?.source ?? 'admin',
        allergens: _allergens,
      ),
    );
  }
}
