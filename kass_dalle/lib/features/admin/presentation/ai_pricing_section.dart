import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_reporting.dart';
import '../../../core/utils/context_extensions.dart';
import '../data/ai_pricing.dart';
import '../data/ai_pricing_repository.dart';
import '../../../core/theme/app_icon_size.dart';

final aiPricingRepositoryProvider = Provider<AiPricingRepository>((ref) {
  return AiPricingRepository();
});

/// Grille tarifaire des modèles, modifiable sans déploiement.
///
/// Un fournisseur change ses prix bien plus souvent qu'on ne livre. Tant que la
/// grille vivait dans le code, corriger un tarif demandait un déploiement — et
/// entre-temps le reporting chiffrait faux sans que rien ne le signale.
///
/// Il n'y a pas de repli : une grille illisible n'affiche aucun prix et le dit.
/// Montrer les tarifs du code à la place donnerait des prix périmés présentés
/// comme exacts — un écran crédible et faux.
class AiPricingSection extends ConsumerStatefulWidget {
  const AiPricingSection({super.key});

  @override
  ConsumerState<AiPricingSection> createState() => _AiPricingSectionState();
}

class _AiPricingSectionState extends ConsumerState<AiPricingSection> {
  List<AiPricingRow>? _rows;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await ref.read(aiPricingRepositoryProvider).fetchForAdmin();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _error = null;
      });
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.loadAiPricing',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _rows = null;
          _error = error;
        });
      }
    }
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
    final rows = _rows;

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
              icon: const Icon(Icons.add, size: AppIconSize.small),
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
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: AppIconSize.small,
                        color: theme.colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Tarifs en panne',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Aucun prix n\'est affiché tant que la grille est '
                    'illisible : montrer les tarifs du code à la place donnerait '
                    'des prix périmés présentés comme exacts. Les appels passés '
                    'pendant ce temps sont enregistrés sans montant et comptés '
                    'à part.\n\n$_error',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh, size: AppIconSize.inline),
                    label: const Text('Réessayer'),
                  ),
                ],
              ),
            ),
          )
        else if (rows == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          Card(
            child: Column(
              children: [
                for (final row in rows) ...[
                  _PricingTile(
                    model: row.model,
                    pricing: row.pricing,
                    overridden: row.overridden,
                    onEdit: _busy ? null : () => _edit(row.model, row.pricing),
                    onReset: _busy || !row.overridden
                        ? null
                        : () => _reset(row.model),
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
              icon: const Icon(Icons.undo, size: AppIconSize.small),
              onPressed: onReset,
            ),
          IconButton(
            tooltip: 'Modifier',
            icon: const Icon(Icons.edit_outlined, size: AppIconSize.small),
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

  /// Promotion : elle est désormais saisissable, et surtout **supprimable**.
  ///
  /// Elle ne l'était pas, au motif qu'une date mal saisie transformerait une
  /// remise en tarif permanent. Le raisonnement avait un angle mort : une
  /// promotion qui n'existe pas non plus se corrige, et elle était alors
  /// impossible à retirer sans déploiement. Une remise annoncée que le
  /// fournisseur n'applique pas fait sous-estimer chaque appel sans qu'aucun
  /// écran ne bronche — c'est ce qui a coûté 50 % d'écart sur août.
  late bool _promoOn;
  late final TextEditingController _promoInputCtrl;
  late final TextEditingController _promoOutputCtrl;
  late final TextEditingController _promoUntilCtrl;
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
    final promo = c?.introductory;
    _promoOn = promo != null;
    _promoInputCtrl = TextEditingController(
      text: promo == null ? '' : '${promo.inputPerMillion}',
    );
    _promoOutputCtrl = TextEditingController(
      text: promo == null ? '' : '${promo.outputPerMillion}',
    );
    _promoUntilCtrl = TextEditingController(
      text: promo == null ? '' : promo.untilIso.split('T').first,
    );
  }

  @override
  void dispose() {
    _modelCtrl.dispose();
    _inputCtrl.dispose();
    _outputCtrl.dispose();
    _imageCtrl.dispose();
    _promoInputCtrl.dispose();
    _promoOutputCtrl.dispose();
    _promoUntilCtrl.dispose();
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

    // La promotion se saisit, se corrige et se **supprime**. Décochée, elle
    // disparaît de la grille : c'est le geste qui manquait quand un
    // fournisseur annonce une remise qu'il n'applique pas.
    AiIntroductoryPricing? promo;
    if (_promoOn) {
      final promoInput = double.tryParse(
        _promoInputCtrl.text.trim().replaceAll(',', '.'),
      );
      final promoOutput = double.tryParse(
        _promoOutputCtrl.text.trim().replaceAll(',', '.'),
      );
      if (promoInput == null ||
          promoOutput == null ||
          promoInput < 0 ||
          promoOutput < 0) {
        setState(
          () => _error =
              'Les tarifs promotionnels doivent être des nombres positifs.',
        );
        return;
      }
      // La date de fin est obligatoire, et vérifiée : c'est elle qui empêche
      // une remise de devenir un tarif permanent le jour où elle expire.
      final until = DateTime.tryParse(_promoUntilCtrl.text.trim());
      if (until == null) {
        setState(
          () => _error =
              'La date de fin est requise, au format AAAA-MM-JJ. Sans elle, '
              'la promotion deviendrait un tarif permanent le jour où elle '
              'expire, et le reporting sous-estimerait sans le dire.',
        );
        return;
      }
      // Borne EXCLUE, à minuit UTC : au premier instant de cette date, le
      // tarif catalogue reprend.
      promo = AiIntroductoryPricing(
        inputPerMillion: promoInput,
        outputPerMillion: promoOutput,
        untilIso: DateTime.utc(
          until.year,
          until.month,
          until.day,
        ).toIso8601String(),
      );
    }

    Navigator.pop(context, (
      model: model,
      pricing: AiModelPricing(
        inputPerMillion: input,
        outputPerMillion: output,
        imageOutputPerUnit: image < 0 ? 0 : image,
        introductory: promo,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.model == null ? 'Ajouter un modèle' : widget.model!),
      // Défilable : la promotion ajoute quatre champs, et un dialogue qui
      // déborde cache justement le bouton d'enregistrement.
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
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
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _promoOn,
                onChanged: (value) => setState(() => _promoOn = value),
                title: const Text('Tarif promotionnel en cours'),
                subtitle: const Text(
                  'À décocher dès que le fournisseur ne l\'applique plus : une '
                  'remise annoncée mais non facturée fait sous-estimer chaque '
                  'appel sans qu\'aucun écran ne le signale.',
                ),
              ),
              if (_promoOn) ...[
                const SizedBox(height: 8),
                _NumberField(
                  controller: _promoInputCtrl,
                  label: 'Promo — entrée (\$ / million)',
                ),
                const SizedBox(height: 12),
                _NumberField(
                  controller: _promoOutputCtrl,
                  label: 'Promo — sortie (\$ / million)',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _promoUntilCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Fin de la promotion (AAAA-MM-JJ, borne exclue)',
                    hintText: '2026-09-01',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
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
