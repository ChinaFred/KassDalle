import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/presentation/auth_providers.dart';
import '../domain/meal_staple.dart';
import 'meal_staples_providers.dart';
import 'staple_allergens_field.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/widgets/app_states.dart';

/// Les garnitures simples, vues et retouchées par une personne.
///
/// Le référentiel est celui de la famille ; ce qu'on change ici — une part
/// de riz plus petite, une garniture masquée, une garniture à soi — ne
/// s'écrit que sous son propre compte. Personne d'autre ne le voit, et une
/// correction du référentiel par l'admin continue de s'appliquer à tout ce
/// qu'on n'a pas retouché.
class MyStaplesScreen extends ConsumerStatefulWidget {
  const MyStaplesScreen({super.key});

  @override
  ConsumerState<MyStaplesScreen> createState() => _MyStaplesScreenState();
}

class _MyStaplesScreenState extends ConsumerState<MyStaplesScreen> {
  bool _showHidden = false;

  String? get _uid => ref.read(appUserProvider).value?.uid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final staples = ref.watch(myStaplesProvider);
    final isAdmin = ref.watch(isAdminProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mes garnitures'),
        actions: [
          IconButton(
            tooltip: _showHidden
                ? 'Cacher les garnitures masquées'
                : 'Voir les garnitures masquées',
            icon: Icon(
              _showHidden ? Icons.visibility_off_outlined : Icons.visibility,
            ),
            onPressed: () => setState(() => _showHidden = !_showHidden),
          ),
          IconButton(
            tooltip: 'Ajouter une garniture à moi',
            icon: const Icon(Icons.add),
            onPressed: _addOwn,
          ),
        ],
      ),
      body: staples.when(
        loading: () => const AppLoadingState(),
        error: (e, _) => AppErrorState(
          error: e,
          title: 'Garnitures illisibles',
          onRetry: () {
            ref.invalidate(baseMealStaplesProvider);
            ref.invalidate(myStapleOverridesProvider);
          },
        ),
        data: (all) {
          final hiddenCount = all.where((u) => u.hidden).length;
          final shown = _showHidden
              ? all
              : all.where((u) => !u.hidden).toList(growable: false);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
            children: [
              Text(
                'Riz, pâtes, salade, yaourt : ce qui accompagne un plat sans '
                'recette, avec la part par personne. Vos retouches ne '
                'changent rien pour les autres membres.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (all.isEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 32),
                  child: Text(
                    'Aucune garniture pour l\'instant. Ajoutez les vôtres '
                    'avec le bouton « Ma garniture ».',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                if (isAdmin)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'La liste commune se tient dans Admin › Référentiels › '
                      'Garnitures simples.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 32),
              ] else
                ..._grouped(context, shown),
              if (hiddenCount > 0 && !_showHidden)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '$hiddenCount garniture${hiddenCount > 1 ? 's' : ''} '
                    'masquée${hiddenCount > 1 ? 's' : ''} — l\'œil en haut '
                    'à droite les montre.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addOwn,
        icon: const Icon(Icons.add),
        label: const Text('Ma garniture'),
      ),
    );
  }

  List<Widget> _grouped(BuildContext context, List<UserStaple> staples) {
    final theme = Theme.of(context);
    final out = <Widget>[];
    StapleCategory? current;
    for (final u in staples) {
      if (u.staple.category != current) {
        current = u.staple.category;
        out.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
            child: Text(
              u.staple.category.label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        );
      }
      out.add(
        _UserStapleTile(
          entry: u,
          onEdit: () => _edit(u),
          onToggleHidden: () => _toggleHidden(u),
          onReset: u.isOverridden ? () => _resetToBase(u) : null,
          onDelete: u.isOwn ? () => _deleteOwn(u) : null,
        ),
      );
    }
    return out;
  }

  StapleOverride? _existingOverride(String id) =>
      ref.read(myStapleOverridesProvider).value?[id];

  Future<void> _run(
    String feature,
    Future<void> Function(String uid) action, {
    required String success,
    Map<String, dynamic> context = const {},
  }) async {
    final uid = _uid;
    if (uid == null) {
      this.context.showErrorSnackBar('Aucun compte connecté.');
      return;
    }
    try {
      await action(uid);
      if (mounted && success.isNotEmpty) {
        this.context.showSuccessSnackBar(success);
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: feature,
        error: e,
        stackTrace: stackTrace,
        context: context,
      );
      if (mounted) this.context.showErrorSnackBar('Erreur : $e');
    }
  }

  Future<void> _edit(UserStaple u) async {
    final form = await showDialog<_StapleForm>(
      context: context,
      builder: (_) => _UserStapleDialog(
        title: u.isOwn ? 'Ma garniture' : 'Retoucher « ${u.staple.name} »',
        initial: u.staple,
        baseHint: u.base,
      ),
    );
    if (form == null || !mounted) return;
    final existing = _existingOverride(u.staple.id);
    final hidden = existing?.hidden ?? false;
    final StapleOverride override;
    if (u.isOwn) {
      override = StapleOverride(
        id: u.staple.id,
        isOwn: true,
        hidden: hidden,
        name: form.name,
        category: form.category,
        quantityPerPortion: form.quantity,
        unit: form.unit,
        note: form.note,
        shoppingProduct: form.shoppingProduct,
        allergens: form.allergens,
      );
    } else {
      // Seuls les champs qui diffèrent de la base sont stockés : le reste
      // continue de suivre les corrections du référentiel.
      final base = u.base!;
      override = StapleOverride(
        id: u.staple.id,
        hidden: hidden,
        name: form.name != base.name ? form.name : null,
        category: form.category != base.category ? form.category : null,
        quantityPerPortion: form.quantity != base.quantityPerPortion
            ? form.quantity
            : null,
        unit: form.unit != base.unit ? form.unit : null,
        note: form.note != base.note ? form.note : null,
        shoppingProduct: form.shoppingProduct != base.shoppingProduct
            ? form.shoppingProduct
            : null,
        // Des allergènes retouchés ne se stockent que s'ils diffèrent ; un
        // retour à « non renseignés » suit le référentiel.
        allergens:
            form.allergens != null &&
                !_sameAllergens(form.allergens, base.allergens)
            ? form.allergens
            : null,
      );
    }
    await _run(
      'myStaplesScreen.edit',
      (uid) =>
          ref.read(mealStaplesRepositoryProvider).saveOverride(uid, override),
      success: override.isEmpty
          ? '« ${form.name} » suit à nouveau le référentiel.'
          : '« ${form.name} » enregistrée pour vous.',
      context: {'id': u.staple.id},
    );
  }

  static bool _sameAllergens(List<String>? a, List<String>? b) {
    if (a == null || b == null) return a == b;
    return a.length == b.length && a.toSet().containsAll(b);
  }

  Future<void> _toggleHidden(UserStaple u) async {
    final existing =
        _existingOverride(u.staple.id) ?? StapleOverride(id: u.staple.id);
    final override = existing.copyWith(hidden: !u.hidden);
    await _run(
      'myStaplesScreen.toggleHidden',
      (uid) =>
          ref.read(mealStaplesRepositoryProvider).saveOverride(uid, override),
      success: u.hidden
          ? '« ${u.staple.name} » à nouveau proposée.'
          : '« ${u.staple.name} » masquée : elle ne vous sera plus proposée.',
      context: {'id': u.staple.id, 'hidden': !u.hidden},
    );
  }

  Future<void> _resetToBase(UserStaple u) async {
    // Le masquage survit au retour à la base : ce sont deux décisions.
    final hidden = _existingOverride(u.staple.id)?.hidden ?? false;
    await _run(
      'myStaplesScreen.resetToBase',
      (uid) => hidden
          ? ref
                .read(mealStaplesRepositoryProvider)
                .saveOverride(
                  uid,
                  StapleOverride(id: u.staple.id, hidden: true),
                )
          : ref
                .read(mealStaplesRepositoryProvider)
                .removeOverride(uid, u.staple.id),
      success:
          '« ${u.base?.name ?? u.staple.name} » revient à la valeur de base.',
      context: {'id': u.staple.id},
    );
  }

  Future<void> _deleteOwn(UserStaple u) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Supprimer cette garniture ?'),
        content: Text('« ${u.staple.name} » n\'existe que pour vous.'),
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
    if (confirmed != true || !mounted) return;
    await _run(
      'myStaplesScreen.deleteOwn',
      (uid) => ref
          .read(mealStaplesRepositoryProvider)
          .removeOverride(uid, u.staple.id),
      success: '« ${u.staple.name} » supprimée.',
      context: {'id': u.staple.id},
    );
  }

  Future<void> _addOwn() async {
    final form = await showDialog<_StapleForm>(
      context: context,
      builder: (_) => const _UserStapleDialog(title: 'Ma garniture'),
    );
    if (form == null || !mounted) return;
    final root = stapleIdFromName(form.name);
    if (root.isEmpty) {
      context.showErrorSnackBar(
        'Impossible de déduire un identifiant de ce nom.',
      );
      return;
    }
    // Un identifiant déjà pris — par la base ou par une garniture à soi —
    // recevrait la retouche à la place d'une création.
    final taken = <String>{
      ...?ref.read(myStaplesProvider).value?.map((u) => u.staple.id),
      ...?ref.read(myStapleOverridesProvider).value?.keys,
    };
    var id = root;
    for (var n = 2; taken.contains(id); n++) {
      id = '${root}_$n';
    }
    final override = StapleOverride(
      id: id,
      isOwn: true,
      name: form.name,
      category: form.category,
      quantityPerPortion: form.quantity,
      unit: form.unit,
      note: form.note,
      shoppingProduct: form.shoppingProduct,
      allergens: form.allergens,
    );
    await _run(
      'myStaplesScreen.addOwn',
      (uid) =>
          ref.read(mealStaplesRepositoryProvider).saveOverride(uid, override),
      success: '« ${form.name} » ajoutée à vos garnitures.',
      context: {'id': id},
    );
  }
}

class _UserStapleTile extends StatelessWidget {
  final UserStaple entry;
  final VoidCallback onEdit;
  final VoidCallback onToggleHidden;
  final VoidCallback? onReset;
  final VoidCallback? onDelete;

  const _UserStapleTile({
    required this.entry,
    required this.onEdit,
    required this.onToggleHidden,
    this.onReset,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = entry.staple;
    final muted = theme.colorScheme.onSurfaceVariant;
    final note = s.note.trim();
    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: ListTile(
        onTap: onEdit,
        title: Row(
          children: [
            Flexible(
              child: Text(
                s.name,
                style: TextStyle(
                  color: entry.hidden ? muted : null,
                  decoration: entry.hidden ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
            if (entry.isOwn) ...[
              const SizedBox(width: 8),
              _Badge('à moi', theme.colorScheme.tertiary),
            ] else if (entry.isOverridden) ...[
              const SizedBox(width: 8),
              _Badge('retouchée', theme.colorScheme.primary),
            ],
          ],
        ),
        subtitle: Text(
          '${s.quantityLabel} par part${note.isNotEmpty ? ' · $note' : ''}'
          ' · ${stapleAllergensSummary(s.allergens)}',
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (action) {
            switch (action) {
              case 'edit':
                onEdit();
              case 'hide':
                onToggleHidden();
              case 'reset':
                onReset?.call();
              case 'delete':
                onDelete?.call();
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('Modifier')),
            PopupMenuItem(
              value: 'hide',
              child: Text(entry.hidden ? 'Afficher' : 'Masquer'),
            ),
            if (onReset != null)
              const PopupMenuItem(
                value: 'reset',
                child: Text('Revenir à la valeur de base'),
              ),
            if (onDelete != null)
              const PopupMenuItem(value: 'delete', child: Text('Supprimer')),
          ],
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

/// Ce que le formulaire rend : les valeurs saisies, sans identifiant.
class _StapleForm {
  final String name;
  final StapleCategory category;
  final double quantity;
  final String unit;
  final String note;
  final String shoppingProduct;

  /// Allergènes saisis ; `null` : non renseignés.
  final List<String>? allergens;

  const _StapleForm({
    required this.name,
    required this.category,
    required this.quantity,
    required this.unit,
    required this.note,
    required this.shoppingProduct,
    this.allergens,
  });
}

/// Saisie d'une garniture pour soi : création, ou retouche d'une garniture
/// de base. Pour une retouche, la valeur du référentiel est rappelée sous le
/// champ, pour savoir de quoi l'on s'écarte.
class _UserStapleDialog extends StatefulWidget {
  final String title;
  final MealStaple? initial;
  final MealStaple? baseHint;

  const _UserStapleDialog({required this.title, this.initial, this.baseHint});

  @override
  State<_UserStapleDialog> createState() => _UserStapleDialogState();
}

class _UserStapleDialogState extends State<_UserStapleDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _quantityCtrl;
  late final TextEditingController _noteCtrl;
  late final TextEditingController _shoppingCtrl;
  late StapleCategory _category;
  late String _unit;
  List<String>? _allergens;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _nameCtrl = TextEditingController(text: i?.name ?? '');
    _quantityCtrl = TextEditingController(
      text: i == null ? '' : _fmt(i.quantityPerPortion),
    );
    _noteCtrl = TextEditingController(text: i?.note ?? '');
    _shoppingCtrl = TextEditingController(text: i?.shoppingProduct ?? '');
    _category = i?.category ?? StapleCategory.feculent;
    _unit = i?.unit ?? 'g';
    _allergens = i?.allergens;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _quantityCtrl.dispose();
    _noteCtrl.dispose();
    _shoppingCtrl.dispose();
    super.dispose();
  }

  static String _fmt(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

  @override
  Widget build(BuildContext context) {
    final base = widget.baseHint;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nameCtrl,
                  autofocus: widget.initial == null,
                  decoration: InputDecoration(
                    labelText: 'Nom',
                    helperText: base == null
                        ? null
                        : 'Référentiel : ${base.name}',
                    border: const OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Champ obligatoire' : null,
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
                        decoration: InputDecoration(
                          labelText: 'Quantité par part',
                          helperText: base == null
                              ? null
                              : 'Référentiel : ${base.quantityLabel}',
                          border: const OutlineInputBorder(),
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
                StapleAllergensField(
                  value: _allergens,
                  onChanged: (v) => setState(() => _allergens = v),
                  retouch: base != null,
                  baseAllergens: base?.allergens,
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
        FilledButton(onPressed: _submit, child: const Text('Enregistrer')),
      ],
    );
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(
      _StapleForm(
        name: _nameCtrl.text.trim(),
        category: _category,
        quantity: double.parse(_quantityCtrl.text.trim().replaceAll(',', '.')),
        unit: _unit,
        note: _noteCtrl.text.trim(),
        shoppingProduct: _shoppingCtrl.text.trim(),
        allergens: _allergens,
      ),
    );
  }
}
