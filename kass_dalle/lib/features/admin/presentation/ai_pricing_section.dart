import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_reporting.dart';
import '../../../core/utils/context_extensions.dart';
import '../data/ai_pricing.dart';
import '../data/ai_pricing_repository.dart';

final aiPricingRepositoryProvider = Provider<AiPricingRepository>((ref) {
  return AiPricingRepository();
});

/// Grille tarifaire des modèles, modifiable sans déploiement.
///
/// Un fournisseur change ses prix bien plus souvent qu'on ne livre. Tant que la
/// grille vivait dans le code, corriger un tarif demandait un déploiement — et
/// entre-temps le reporting chiffrait faux sans que rien ne le signale.
///
/// Le tarif livré avec le code reste le **repli** : un modèle jamais modifié
/// ici s'affiche à sa valeur d'origine, et une table Firestore injoignable ne
/// fait pas tomber les coûts à zéro.
class AiPricingSection extends ConsumerStatefulWidget {
  const AiPricingSection({super.key});

  @override
  ConsumerState<AiPricingSection> createState() => _AiPricingSectionState();
}

class _AiPricingSectionState extends ConsumerState<AiPricingSection> {
  Map<String, AiModelPricing>? _table;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final table = await ref.read(aiPricingRepositoryProvider).load();
      if (!mounted) return;
      setState(() {
        _table = table;
        _error = null;
      });
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.loadAiPricing',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) setState(() => _error = error);
    }
  }

  /// Vrai si le tarif affiché diffère de celui livré avec le code.
  bool _isOverridden(String model, AiModelPricing entry) {
    final base = AiPricing.builtinTable[model];
    if (base == null) return true;
    return base.inputPerMillion != entry.inputPerMillion ||
        base.outputPerMillion != entry.outputPerMillion ||
        base.imageOutputPerUnit != entry.imageOutputPerUnit;
  }

  Future<void> _edit(String model, AiModelPricing current) async {
    final result = await showDialog<_PricingEdit>(
      context: context,
      builder: (ctx) => _PricingDialog(model: model, current: current),
    );
    if (result == null || !mounted) return;
    await _save(result.model, result.pricing);
  }

  Future<void> _reset(String model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revenir au tarif du code ?'),
        content: Text(
          'Le tarif saisi pour « $model » sera oublié. Les montants déjà '
          'enregistrés ne changent pas : ils ont été figés au moment de '
          'chaque appel.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Revenir'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _save(model, null);
  }

  Future<void> _save(String model, AiModelPricing? pricing) async {
    setState(() => _busy = true);
    try {
      await ref
          .read(aiPricingRepositoryProvider)
          .save(model: model, pricing: pricing);
      await _load();
      if (mounted) {
        context.showSuccessSnackBar(
          pricing == null
              ? 'Tarif de « $model » revenu à la valeur du code ✓'
              : 'Tarif de « $model » enregistré ✓',
        );
      }
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.saveAiPricing',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) context.showErrorSnackBar('Erreur : $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addModel() async {
    final result = await showDialog<_PricingEdit>(
      context: context,
      builder: (ctx) => const _PricingDialog(model: null, current: null),
    );
    if (result == null || !mounted) return;
    await _save(result.model, result.pricing);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final table = _table;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Grille tarifaire',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _busy ? null : _addModel,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Ajouter un modèle'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Prix en dollars par million de jetons. Un tarif modifié ici prend '
          'effet en moins d\'une minute, sans déploiement, et ne chiffre que '
          'les appels à venir : les montants déjà enregistrés restent figés au '
          'tarif qui avait cours au moment de l\'appel.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (_error != null)
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Grille illisible : les tarifs livrés avec le code s\'appliquent. '
                '$_error',
                style: theme.textTheme.bodySmall,
              ),
            ),
          )
        else if (table == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          Card(
            child: Column(
              children: [
                for (final model in table.keys.toList()..sort()) ...[
                  _PricingTile(
                    model: model,
                    pricing: table[model]!,
                    overridden: _isOverridden(model, table[model]!),
                    onEdit: _busy ? null : () => _edit(model, table[model]!),
                    onReset: _busy || !_isOverridden(model, table[model]!)
                        ? null
                        : () => _reset(model),
                  ),
                  const Divider(height: 1),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _PricingTile extends StatelessWidget {
  final String model;
  final AiModelPricing pricing;
  final bool overridden;
  final VoidCallback? onEdit;
  final VoidCallback? onReset;

  const _PricingTile({
    required this.model,
    required this.pricing,
    required this.overridden,
    required this.onEdit,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = <String>[
      'entrée ${pricing.inputPerMillion} \$',
      'sortie ${pricing.outputPerMillion} \$',
      if (pricing.imageOutputPerUnit > 0)
        'image ${pricing.imageOutputPerUnit} \$',
    ];
    final promo = pricing.introductory;

    return ListTile(
      title: Row(
        children: [
          Flexible(child: Text(model)),
          if (overridden) ...[
            const SizedBox(width: 8),
            Chip(
              visualDensity: VisualDensity.compact,
              label: const Text('modifié'),
              labelStyle: theme.textTheme.labelSmall,
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(parts.join(' · '), style: theme.textTheme.bodySmall),
          if (promo != null)
            Text(
              'promotion ${promo.inputPerMillion} / ${promo.outputPerMillion} \$ '
              'jusqu\'au ${promo.untilIso.split('T').first}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.tertiary,
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onReset != null)
            IconButton(
              tooltip: 'Revenir au tarif du code',
              icon: const Icon(Icons.undo, size: 18),
              onPressed: onReset,
            ),
          IconButton(
            tooltip: 'Modifier',
            icon: const Icon(Icons.edit_outlined, size: 18),
            onPressed: onEdit,
          ),
        ],
      ),
    );
  }
}

/// Résultat de la saisie : l'identifiant et son tarif voyagent ensemble.
///
/// Un dialogue vit sur sa propre route : il ne peut pas déposer l'identifiant
/// dans l'état de la section, qui n'est pas son ancêtre.
typedef _PricingEdit = ({String model, AiModelPricing pricing});

/// Saisie d'un tarif. [model] null = ajout d'un modèle absent de la grille.
class _PricingDialog extends StatefulWidget {
  final String? model;
  final AiModelPricing? current;

  const _PricingDialog({required this.model, required this.current});

  @override
  State<_PricingDialog> createState() => _PricingDialogState();
}

class _PricingDialogState extends State<_PricingDialog> {
  late final TextEditingController _modelCtrl;
  late final TextEditingController _inputCtrl;
  late final TextEditingController _outputCtrl;
  late final TextEditingController _imageCtrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    final c = widget.current;
    _modelCtrl = TextEditingController(text: widget.model ?? '');
    _inputCtrl = TextEditingController(text: '${c?.inputPerMillion ?? ''}');
    _outputCtrl = TextEditingController(text: '${c?.outputPerMillion ?? ''}');
    _imageCtrl = TextEditingController(
      text: (c?.imageOutputPerUnit ?? 0) > 0 ? '${c!.imageOutputPerUnit}' : '',
    );
  }

  @override
  void dispose() {
    _modelCtrl.dispose();
    _inputCtrl.dispose();
    _outputCtrl.dispose();
    _imageCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final model = _modelCtrl.text.trim();
    if (model.isEmpty) {
      setState(() => _error = 'L\'identifiant du modèle est requis.');
      return;
    }
    final input = double.tryParse(_inputCtrl.text.trim().replaceAll(',', '.'));
    final output = double.tryParse(
      _outputCtrl.text.trim().replaceAll(',', '.'),
    );
    if (input == null || output == null || input < 0 || output < 0) {
      setState(
        () => _error =
            'Entrée et sortie doivent être des nombres positifs. Un tarif '
            'illisible ferait chiffrer les appels à zéro.',
      );
      return;
    }
    final image =
        double.tryParse(_imageCtrl.text.trim().replaceAll(',', '.')) ?? 0;

    Navigator.pop(context, (
      model: model,
      pricing: AiModelPricing(
        inputPerMillion: input,
        outputPerMillion: output,
        imageOutputPerUnit: image < 0 ? 0 : image,
        // La promotion n'est pas éditable ici : elle porte une date de fin, et
        // une date mal saisie transforme une remise en tarif permanent. Elle
        // reste pilotée par le code tant qu'un écran ne sait pas la valider.
        introductory: widget.current?.introductory,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.model == null ? 'Ajouter un modèle' : widget.model!),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.model == null) ...[
              TextField(
                controller: _modelCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Identifiant du modèle',
                  hintText: 'ex : claude-sonnet-5',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            _NumberField(
              controller: _inputCtrl,
              label: 'Entrée (\$ / million de jetons)',
            ),
            const SizedBox(height: 12),
            _NumberField(
              controller: _outputCtrl,
              label: 'Sortie (\$ / million de jetons)',
            ),
            const SizedBox(height: 12),
            _NumberField(
              controller: _imageCtrl,
              label: 'Image (\$ / image, vide si aucune)',
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Enregistrer')),
      ],
    );
  }
}

class _NumberField extends StatelessWidget {
  final TextEditingController controller;
  final String label;

  const _NumberField({required this.controller, required this.label});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}
