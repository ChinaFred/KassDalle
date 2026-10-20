import 'package:flutter/material.dart';
import 'cooklang_editor_colors.dart';
import 'cooklang_block_model.dart';
import '../../../../core/theme/app_icon_size.dart';

// ══════════════════════════════════════════════════════════════════════════════
// IngredientChip
// ══════════════════════════════════════════════════════════════════════════════

/// Interactive chip for an ingredient segment (`@name{qty%unit}`).
/// Tapping opens a [BottomSheet] with 3 fields (name, qty, unit).
class IngredientChipWidget extends StatelessWidget {
  final IngredientSegment segment;
  final bool enabled;
  final ValueChanged<IngredientSegment>? onChanged;
  final VoidCallback? onDelete;

  const IngredientChipWidget({
    super.key,
    required this.segment,
    this.enabled = true,
    this.onChanged,
    this.onDelete,
  });

  String get _label {
    final parts = [
      segment.name,
      if (segment.qty.isNotEmpty) segment.qty,
      if (segment.unit.isNotEmpty) segment.unit,
    ];
    return parts.join(' ');
  }

  Future<void> _edit(BuildContext context) async {
    final result = await showModalBottomSheet<IngredientSegment>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _IngredientEditSheet(segment: segment),
    );
    if (result != null) onChanged?.call(result);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? () => _edit(context) : null,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.eco_outlined,
              size: AppIconSize.badge,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
            const SizedBox(width: 3),
            Text(
              _label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimaryContainer,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (enabled && onDelete != null) ...[
              const SizedBox(width: 4),
              GestureDetector(
                onTap: onDelete,
                child: Icon(
                  Icons.close,
                  size: AppIconSize.inline,
                  color: Theme.of(
                    context,
                  ).colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _IngredientEditSheet extends StatefulWidget {
  final IngredientSegment segment;
  const _IngredientEditSheet({required this.segment});
  @override
  State<_IngredientEditSheet> createState() => _IngredientEditSheetState();
}

class _IngredientEditSheetState extends State<_IngredientEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _qty;
  late final TextEditingController _unit;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.segment.name);
    _qty = TextEditingController(text: widget.segment.qty);
    _unit = TextEditingController(text: widget.segment.unit);
  }

  @override
  void dispose() {
    _name.dispose();
    _qty.dispose();
    _unit.dispose();
    super.dispose();
  }

  void _confirm(BuildContext context) {
    final updated = widget.segment.copyWith(
      name: _name.text.trim(),
      qty: _qty.text.trim(),
      unit: _unit.text.trim(),
    );
    Navigator.pop(context, updated);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.eco_outlined,
                color: CooklangPalette.ofContext(context).ingredient,
              ),
              const SizedBox(width: 8),
              Text(
                'Ingrédient',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: CooklangPalette.ofContext(context).ingredient,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Nom',
              hintText: 'ex: farine',
              border: OutlineInputBorder(),
              prefixText: '@',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _qty,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Quantité',
                    hintText: 'ex: 250',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _unit,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _confirm(context),
                  decoration: const InputDecoration(
                    labelText: 'Unité',
                    hintText: 'ex: g, ml, pièces…',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Annuler'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _confirm(context),
                child: const Text('Valider'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// UtensilChip
// ══════════════════════════════════════════════════════════════════════════════

/// Interactive chip for a utensil segment (`#name{}`).
/// Tapping opens a small popup to edit the name.
class UtensilChipWidget extends StatelessWidget {
  final UtensilSegment segment;
  final bool enabled;
  final ValueChanged<UtensilSegment>? onChanged;
  final VoidCallback? onDelete;

  const UtensilChipWidget({
    super.key,
    required this.segment,
    this.enabled = true,
    this.onChanged,
    this.onDelete,
  });

  Future<void> _edit(BuildContext context) async {
    final ctrl = TextEditingController(text: segment.name);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.kitchen_outlined,
              color: CooklangPalette.ofContext(context).utensil,
            ),
            const SizedBox(width: 8),
            Text(
              'Ustensile',
              style: TextStyle(
                color: CooklangPalette.ofContext(context).utensil,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) Navigator.pop(ctx, v.trim());
          },
          decoration: const InputDecoration(
            labelText: 'Nom de l\'ustensile',
            hintText: 'ex: poêle à crêpes',
            border: OutlineInputBorder(),
            prefixText: '#',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Valider'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (result != null && result.isNotEmpty) {
      onChanged?.call(segment.copyWith(name: result));
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? () => _edit(context) : null,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.kitchen_outlined,
              size: AppIconSize.badge,
              color: Theme.of(context).colorScheme.onTertiaryContainer,
            ),
            const SizedBox(width: 3),
            Text(
              segment.name,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onTertiaryContainer,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (enabled && onDelete != null) ...[
              const SizedBox(width: 4),
              GestureDetector(
                onTap: onDelete,
                child: Icon(
                  Icons.close,
                  size: AppIconSize.inline,
                  color: Theme.of(
                    context,
                  ).colorScheme.onTertiaryContainer.withValues(alpha: 0.7),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// TimerChip
// ══════════════════════════════════════════════════════════════════════════════

/// Interactive chip for a timer segment (`~{qty%unit}`).
/// Tapping opens an adjustment dialog (qty + unit selector).
class TimerChipWidget extends StatelessWidget {
  final TimerSegment segment;
  final bool enabled;
  final ValueChanged<TimerSegment>? onChanged;
  final VoidCallback? onDelete;

  const TimerChipWidget({
    super.key,
    required this.segment,
    this.enabled = true,
    this.onChanged,
    this.onDelete,
  });

  String get _label {
    final parts = <String>[
      if (segment.name.isNotEmpty) segment.name,
      segment.qty,
      if (segment.unit.isNotEmpty) segment.unit,
    ];
    return parts.join(' ');
  }

  Future<void> _edit(BuildContext context) async {
    final result = await showModalBottomSheet<TimerSegment>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TimerEditSheet(segment: segment),
    );
    if (result != null) onChanged?.call(result);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? () => _edit(context) : null,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.timer_outlined,
              size: AppIconSize.badge,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
            const SizedBox(width: 3),
            Text(
              _label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSecondaryContainer,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (enabled && onDelete != null) ...[
              const SizedBox(width: 4),
              GestureDetector(
                onTap: onDelete,
                child: Icon(
                  Icons.close,
                  size: AppIconSize.inline,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSecondaryContainer.withValues(alpha: 0.7),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

const _kTimerUnits = ['secondes', 'minutes', 'heures'];

class _TimerEditSheet extends StatefulWidget {
  final TimerSegment segment;
  const _TimerEditSheet({required this.segment});
  @override
  State<_TimerEditSheet> createState() => _TimerEditSheetState();
}

class _TimerEditSheetState extends State<_TimerEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _qty;
  late String _unit;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.segment.name);
    _qty = TextEditingController(text: widget.segment.qty);
    _unit = _kTimerUnits.contains(widget.segment.unit)
        ? widget.segment.unit
        : 'minutes';
  }

  @override
  void dispose() {
    _name.dispose();
    _qty.dispose();
    super.dispose();
  }

  void _confirm(BuildContext context) {
    final updated = widget.segment.copyWith(
      name: _name.text.trim(),
      qty: _qty.text.trim(),
      unit: _unit,
    );
    Navigator.pop(context, updated);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.timer_outlined,
                color: CooklangPalette.ofContext(context).timer,
              ),
              const SizedBox(width: 8),
              Text(
                'Minuteur',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: CooklangPalette.ofContext(context).timer,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Nom (optionnel)',
              hintText: 'ex: pétrissage',
              border: OutlineInputBorder(),
              prefixText: '~',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _qty,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _confirm(context),
                  decoration: const InputDecoration(
                    labelText: 'Durée',
                    hintText: 'ex: 30',
                    border: OutlineInputBorder(),
                  ),
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
                  items: _kTimerUnits
                      .map((u) => DropdownMenuItem(value: u, child: Text(u)))
                      .toList(),
                  onChanged: (v) => setState(() => _unit = v ?? 'minutes'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Annuler'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _confirm(context),
                child: const Text('Valider'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
