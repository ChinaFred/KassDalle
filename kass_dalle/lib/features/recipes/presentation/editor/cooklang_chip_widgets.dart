import 'package:flutter/material.dart';
import 'cooklang_block_model.dart';

// ── Color constants ───────────────────────────────────────────────────────────

const _kIngredientColor = Color(0xFF1565C0); // blue 800
const _kUtensilColor = Color(0xFFE64A19); // deep-orange 700
const _kTimerColor = Color(0xFF6A1B9A); // purple 800

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
          color: _kIngredientColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _kIngredientColor.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '🥬 $_label',
              style: TextStyle(
                color: _kIngredientColor,
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
                  size: 14,
                  color: _kIngredientColor.withValues(alpha: 0.7),
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.eco_outlined, color: _kIngredientColor),
              const SizedBox(width: 8),
              Text(
                'Ingrédient',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: _kIngredientColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
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
                onPressed: () {
                  final updated = widget.segment.copyWith(
                    name: _name.text.trim(),
                    qty: _qty.text.trim(),
                    unit: _unit.text.trim(),
                  );
                  Navigator.pop(context, updated);
                },
                style: FilledButton.styleFrom(
                  backgroundColor: _kIngredientColor,
                ),
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
            const Icon(Icons.kitchen_outlined, color: _kUtensilColor),
            const SizedBox(width: 8),
            Text(
              'Ustensile',
              style: TextStyle(
                color: _kUtensilColor,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
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
            style: FilledButton.styleFrom(backgroundColor: _kUtensilColor),
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
          color: _kUtensilColor.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _kUtensilColor.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '🍳 ${segment.name}',
              style: TextStyle(
                color: _kUtensilColor,
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
                  size: 14,
                  color: _kUtensilColor.withValues(alpha: 0.7),
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
          color: _kTimerColor.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _kTimerColor.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '⏱ $_label',
              style: TextStyle(
                color: _kTimerColor,
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
                  size: 14,
                  color: _kTimerColor.withValues(alpha: 0.7),
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.timer_outlined, color: _kTimerColor),
              const SizedBox(width: 8),
              Text(
                'Minuteur',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: _kTimerColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
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
                  value: _unit,
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
                onPressed: () {
                  final updated = widget.segment.copyWith(
                    name: _name.text.trim(),
                    qty: _qty.text.trim(),
                    unit: _unit,
                  );
                  Navigator.pop(context, updated);
                },
                style: FilledButton.styleFrom(backgroundColor: _kTimerColor),
                child: const Text('Valider'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
