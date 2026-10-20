import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/services/error_reporting.dart';
import '../../../core/utils/context_extensions.dart';
import '../data/ai_routing_repository.dart';
import '../domain/ai_routing_diff.dart';
import 'ai_console_links.dart';
import '../../../core/widgets/app_states.dart';
import 'admin_server_message.dart';
import '../../../core/theme/app_icon_size.dart';

final aiRoutingRepositoryProvider = Provider<AiRoutingRepository>((ref) {
  return AiRoutingRepository();
});

/// Choix du moteur d'IA, poste par poste.
///
/// Le projet a longtemps eu un seul moteur, donc aucune décision à prendre.
/// Avec deux, la question n'est plus « lequel est le meilleur » dans l'absolu
/// mais « lequel sur quel poste » : l'extraction d'un scan est massivement de
/// l'entrée (une image, peu de sortie), l'estimation nutritionnelle est
/// l'inverse. Comme les tarifs des deux fournisseurs ne sont pas dans le même
/// rapport à l'entrée et à la sortie, la réponse diffère d'un poste à l'autre.
///
/// Cet écran existe pour que la comparaison se fasse sur des données réelles :
/// basculer un poste ne demande pas de déploiement, et le coût de chaque moteur
/// se lit ensuite dans l'écran Comptabilité, à la même clé de poste.
class AiRoutingScreen extends ConsumerStatefulWidget {
  const AiRoutingScreen({super.key});

  @override
  ConsumerState<AiRoutingScreen> createState() => _AiRoutingScreenState();
}

class _AiRoutingScreenState extends ConsumerState<AiRoutingScreen> {
  AiRoutingSnapshot? _snapshot;
  AiRoutingPolicy? _draft;
  Object? _loadError;
  bool _saving = false;

  /// Configuration choisie dans la liste, `null` tant qu'aucune ne l'est.
  ///
  /// Ce n'est pas « la configuration en vigueur » : une configuration ne
  /// commande rien, elle sert à remplir le brouillon. Rien dans Firestore ne
  /// dit qu'une politique vient de l'une d'elles.
  String? _selectedPresetId;
  bool _presetBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snapshot = await ref.read(aiRoutingRepositoryProvider).fetch();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _draft = snapshot.policy;
        _loadError = null;
      });
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.fetchAiRoutingPolicy',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() => _loadError = error);
    }
  }

  Future<void> _save() async {
    final draft = _draft;
    if (draft == null) return;
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(aiRoutingRepositoryProvider)
          .save(_withoutLockedFeatures(draft));
      if (!mounted) return;
      setState(() {
        // L'écriture ne renvoie ni les postes, ni les modèles, ni les
        // configurations : `copyWith` garde ce qu'elle ne rapporte pas.
        // Reconstruire le snapshot champ par champ faisait disparaître de
        // l'écran, jusqu'au rechargement suivant, tout champ ajouté ici et
        // oublié là.
        _snapshot = _snapshot?.copyWith(
          policy: saved.policy,
          anthropicKeyPresent: saved.anthropicKeyPresent,
        );
        _draft = saved.policy;
      });
      context.showSuccessSnackBar('Politique de routage enregistrée.');
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.saveAiRoutingPolicy',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      // `invalid-argument` : refus de `setAiRoutingPolicyFn`, écrit par
      // `readRoutingPolicy` (« Poste inconnu : … », « Fournisseur invalide
      // pour … »). Il écrit aussi « policy est requis. » et
      // « defaultProvider doit valoir … », que cet écran ne provoque pas : il
      // envoie toujours une politique complète. Écart accepté.
      context.showErrorSnackBar(
        adminFailureMessage(
          'Politique de routage non enregistrée',
          error,
          codes: const {'invalid-argument'},
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Retire de la politique les postes qui n'ont rien à y faire.
  ///
  /// Un poste verrouillé ne se route pas : sa valeur ne commanderait rien, et
  /// le serveur refuse la politique entière si elle lui prête un fournisseur
  /// qu'il n'admet pas. Une valeur laissée par une version antérieure de cet
  /// écran se nettoie donc au premier enregistrement, au lieu de le bloquer.
  AiRoutingPolicy _withoutLockedFeatures(AiRoutingPolicy policy) {
    final locked = {
      for (final feature
          in _snapshot?.routableFeatures ?? const <RoutableFeature>[])
        if (feature.lockedProvider != null) feature.id,
    };
    if (locked.isEmpty) return policy;
    return policy.copyWith(
      features: {
        for (final entry in policy.features.entries)
          if (!locked.contains(entry.key)) entry.key: entry.value,
      },
    );
  }

  /// Bascule d'un coup tous les postes fournis.
  ///
  /// Une trentaine de postes se bascule par famille, jamais un par un : sans
  /// ce geste, essayer Claude sur tout l'import demanderait cinq allers-retours
  /// et personne ne le ferait.
  ///
  /// Un poste que le serveur n'autorise pas est ignoré, pas écrit quand même :
  /// il refuserait la politique ENTIÈRE à l'enregistrement, pour les quarante
  /// autres postes aussi.
  void _setProviderFor(
    Iterable<RoutableFeature> features,
    AiProvider provider,
  ) {
    final draft = _draft;
    if (draft == null) return;
    final next = Map<String, AiProvider>.from(draft.features);
    var changed = false;
    for (final feature in features) {
      if (!feature.allows(provider)) continue;
      next[feature.id] = provider;
      changed = true;
    }
    if (!changed) return;
    setState(() => _draft = draft.copyWith(features: next));
  }

  /// Choisit le modèle Claude d'un poste, ou le rend au réglage par défaut.
  ///
  /// Un poste réglé sur le modèle par défaut n'écrit RIEN : garder l'exception
  /// figerait ce poste le jour où le défaut change, sans que personne s'en
  /// souvienne.
  void _setModelFor(String featureId, String model) {
    final draft = _draft;
    if (draft == null) return;
    final models = Map<String, String>.from(draft.anthropicModels);
    if (model == draft.anthropicModel) {
      models.remove(featureId);
    } else {
      models[featureId] = model;
    }
    setState(() => _draft = draft.copyWith(anthropicModels: models));
  }

  /// Choisit l'effort de réflexion d'un poste, ou l'efface (retour au code).
  ///
  /// Contrairement au modèle, il n'y a pas de valeur « par défaut » à
  /// retrouver : effacer un réglage enlève la clé, et le poste reprend
  /// l'effort que son propre code demande.
  void _setEffortFor(String featureId, String? effort) {
    final draft = _draft;
    if (draft == null) return;
    final efforts = Map<String, String>.from(draft.anthropicEfforts);
    if (effort == null) {
      efforts.remove(featureId);
    } else {
      efforts[featureId] = effort;
    }
    setState(() => _draft = draft.copyWith(anthropicEfforts: efforts));
  }

  // ── Configurations enregistrées ────────────────────────────────────────────

  AiRoutingPreset? get _selectedPreset {
    final id = _selectedPresetId;
    if (id == null) return null;
    for (final preset in _snapshot?.presets ?? const <AiRoutingPreset>[]) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  /// Écart entre le brouillon courant et une configuration.
  AiRoutingDiff _diffWith(AiRoutingPolicy other) {
    return AiRoutingDiff.between(
      current: _draft!,
      next: other,
      features: _snapshot?.routableFeatures ?? const [],
    );
  }

  /// Charge une configuration dans le brouillon.
  ///
  /// Le remplacement est intégral : un poste absent de la configuration
  /// retombe sur le moteur par défaut. Une fusion rendrait le résultat
  /// dépendant de ce qui était en place avant, et deux essais successifs ne
  /// seraient plus comparables.
  ///
  /// Rien n'est écrit ici. Le brouillon rempli fait apparaître la barre
  /// d'enregistrement, et c'est elle qui décide.
  Future<void> _loadPreset(AiRoutingPreset preset) async {
    if (_draft == null) return;
    final diff = _diffWith(preset.policy);

    if (diff.isEmpty) {
      context.showSuccessSnackBar(
        '« ${preset.name} » est déjà le réglage affiché.',
      );
      return;
    }

    final go = await _confirmLoad(preset, diff);
    if (!go || !mounted) return;

    setState(() => _draft = preset.policy);
    if (!mounted) return;
    context.showSuccessSnackBar(
      '« ${preset.name} » chargée. Rien n\'est écrit tant que vous '
      'n\'enregistrez pas.',
    );
  }

  Future<void> _createPreset() async {
    final draft = _draft;
    if (draft == null) return;

    final name = await _askName(
      title: 'Enregistrer la configuration',
      initial: '',
    );
    if (name == null || !mounted) return;

    // Un nom déjà pris vaut mise à jour : le serveur refuse deux homonymes, et
    // renvoyer l'administrateur choisir un autre nom l'obligerait à deviner
    // lequel des deux gestes il voulait.
    final existing = _snapshot?.presets
        .where((p) => p.name.toLowerCase() == name.toLowerCase())
        .firstOrNull;

    if (existing != null) {
      final overwrite = await _confirmAction(
        title: 'Écraser « ${existing.name} » ?',
        message:
            'Une configuration porte déjà ce nom. Son contenu sera remplacé '
            'par les réglages affichés.',
        confirmLabel: 'Écraser',
      );
      if (!overwrite || !mounted) return;
      await _runPresetAction(
        () => ref
            .read(aiRoutingRepositoryProvider)
            .updatePreset(id: existing.id, policy: draft),
        success: '« ${existing.name} » mise à jour.',
        failure: '« ${existing.name} » non mise à jour',
        selectId: existing.id,
      );
      return;
    }

    await _runPresetAction(
      () => ref
          .read(aiRoutingRepositoryProvider)
          .createPreset(name: name, policy: draft),
      success: '« $name » enregistrée.',
      failure: '« $name » non enregistrée',
      selectName: name,
    );
  }

  Future<void> _updateSelectedPreset() async {
    final draft = _draft;
    final preset = _selectedPreset;
    if (draft == null || preset == null) return;

    final diff = _diffWith(preset.policy);
    final go = await _confirmAction(
      title: 'Mettre à jour « ${preset.name} » ?',
      message: diff.isEmpty
          ? 'Les réglages affichés sont déjà ceux de cette configuration.'
          : 'Cette configuration prendra les réglages affichés :\n\n'
                '${diff.lines.map((l) => '• $l').join('\n')}',
      confirmLabel: 'Mettre à jour',
    );
    if (!go || !mounted) return;

    await _runPresetAction(
      () => ref
          .read(aiRoutingRepositoryProvider)
          .updatePreset(id: preset.id, policy: draft),
      success: '« ${preset.name} » mise à jour.',
      failure: '« ${preset.name} » non mise à jour',
      selectId: preset.id,
    );
  }

  Future<void> _renameSelectedPreset() async {
    final preset = _selectedPreset;
    if (preset == null) return;

    final name = await _askName(
      title: 'Renommer la configuration',
      initial: preset.name,
    );
    if (name == null || name == preset.name || !mounted) return;

    await _runPresetAction(
      () => ref
          .read(aiRoutingRepositoryProvider)
          .renamePreset(id: preset.id, name: name),
      success: 'Configuration renommée en « $name ».',
      failure: 'Configuration non renommée',
      selectId: preset.id,
    );
  }

  Future<void> _deleteSelectedPreset() async {
    final preset = _selectedPreset;
    if (preset == null) return;

    final go = await _confirmAction(
      title: 'Supprimer « ${preset.name} » ?',
      message:
          'La configuration disparaît définitivement. Le routage en vigueur '
          'ne change pas.',
      confirmLabel: 'Supprimer',
      destructive: true,
    );
    if (!go || !mounted) return;

    await _runPresetAction(
      () => ref.read(aiRoutingRepositoryProvider).deletePreset(preset.id),
      success: '« ${preset.name} » supprimée.',
      failure: '« ${preset.name} » non supprimée',
    );
  }

  /// Exécute un geste sur les configurations et remplace la liste affichée.
  ///
  /// La réponse rapporte la liste entière : garder l'ancienne montrerait un
  /// état d'avant l'écriture, ce qu'aucune erreur ne viendrait démentir.
  Future<void> _runPresetAction(
    Future<List<AiRoutingPreset>> Function() action, {
    required String success,
    required String failure,
    String? selectId,
    String? selectName,
  }) async {
    setState(() => _presetBusy = true);
    try {
      final presets = await action();
      if (!mounted) return;
      setState(() {
        _snapshot = _snapshot?.copyWith(presets: presets, presetsFailed: false);
        if (selectName != null) {
          _selectedPresetId = presets
              .where((p) => p.name == selectName)
              .firstOrNull
              ?.id;
        } else if (selectId != null) {
          _selectedPresetId = selectId;
        }
        // Une configuration supprimée ne reste pas sélectionnée : les boutons
        // agiraient sur un document qui n'existe plus.
        if (!presets.any((p) => p.id == _selectedPresetId)) {
          _selectedPresetId = null;
        }
      });
      context.showSuccessSnackBar(success);
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.aiRoutingPreset',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      // Textes lus dans `aiRoutingPresetsFn` : `already-exists` (« Une
      // configuration porte déjà le nom … ») et `not-found` (« Cette
      // configuration n'existe plus. »). `invalid-argument` reste écarté :
      // la fonction y écrit aussi des textes de développeur (« id est
      // requis. », « policy est requis. »).
      context.showErrorSnackBar(
        adminFailureMessage(
          failure,
          error,
          codes: const {'already-exists', 'not-found'},
        ),
      );
    } finally {
      if (mounted) setState(() => _presetBusy = false);
    }
  }

  Future<bool> _confirmLoad(AiRoutingPreset preset, AiRoutingDiff diff) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Charger « ${preset.name} » ?'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Ce chargement change :'),
              const SizedBox(height: 8),
              for (final line in diff.lines) Text('• $line'),
              const SizedBox(height: 12),
              Text(
                'Les postes que la configuration ne nomme pas repartent au '
                'moteur par défaut. Rien n\'est écrit avant l\'enregistrement.',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              if (preset.stale.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Écarté, faute d\'exister encore :',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                for (final line in preset.stale)
                  Text(
                    '• $line',
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Charger'),
          ),
        ],
      ),
    );
    return go ?? false;
  }

  Future<bool> _confirmAction({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(dialogContext).colorScheme.error,
                    foregroundColor: Theme.of(
                      dialogContext,
                    ).colorScheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return go ?? false;
  }

  Future<String?> _askName({
    required String title,
    required String initial,
  }) async {
    final controller = TextEditingController(text: initial);
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 60,
            decoration: const InputDecoration(
              labelText: 'Nom',
              hintText: 'Économique, Import soigné, Tout Gemini…',
            ),
            onSubmitted: (value) =>
                Navigator.of(dialogContext).pop(value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('Valider'),
            ),
          ],
        ),
      );
      if (name == null || name.isEmpty) return null;
      return name;
    } finally {
      controller.dispose();
    }
  }

  /// Le bandeau des configurations, en tête d'écran.
  ///
  /// Il est placé avant les réglages parce qu'on choisit un état complet avant
  /// de le retoucher, jamais l'inverse.
  Widget _buildPresetsCard(
    ThemeData theme,
    AiRoutingSnapshot snapshot,
    AiRoutingPolicy draft,
  ) {
    final presets = snapshot.presets;
    final selected = _selectedPreset;
    final busy = _presetBusy;
    final ecart = selected == null ? null : _diffWith(selected.policy);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Configurations',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Les sept réglages de cet écran, enregistrés sous un nom. '
              'Charger remplit le formulaire ; le routage ne change qu\'à '
              'l\'enregistrement.',
              style: theme.textTheme.bodySmall,
            ),
            if (snapshot.presetsFailed) ...[
              const SizedBox(height: 8),
              Text(
                'Configurations illisibles : la liste ci-dessous est '
                'incomplète. En enregistrer une par-dessus risquerait d\'en '
                'écraser une autre.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (presets.isEmpty)
              Text(
                'Aucune configuration enregistrée.',
                style: theme.textTheme.bodyMedium,
              )
            else
              DropdownButton<String>(
                isExpanded: true,
                value: _selectedPresetId,
                hint: const Text('Choisir une configuration'),
                onChanged: busy
                    ? null
                    : (value) => setState(() => _selectedPresetId = value),
                items: [
                  for (final preset in presets)
                    DropdownMenuItem(
                      value: preset.id,
                      child: Text(preset.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
              ),
            if (selected != null) ...[
              const SizedBox(height: 4),
              Text(_presetSubtitle(selected), style: theme.textTheme.bodySmall),
              if (ecart != null && ecart.isNotEmpty)
                Text(
                  'Les réglages affichés s\'écartent de cette configuration '
                  '(${ecart.lines.length} ${ecart.lines.length > 1 ? 'différences' : 'différence'}).',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontStyle: FontStyle.italic,
                  ),
                ),
              if (selected.stale.isNotEmpty)
                Text(
                  '${selected.stale.length} réglage${selected.stale.length > 1 ? 's' : ''} '
                  'de cette configuration ne correspond${selected.stale.length > 1 ? 'ent' : ''} '
                  'plus à rien et ${selected.stale.length > 1 ? 'seront écartés' : 'sera écarté'} '
                  'au chargement.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: busy || selected == null
                      ? null
                      : () => _loadPreset(selected),
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('Charger'),
                ),
                OutlinedButton(
                  onPressed: busy || selected == null
                      ? null
                      : _updateSelectedPreset,
                  child: const Text('Mettre à jour'),
                ),
                OutlinedButton(
                  onPressed: busy || selected == null
                      ? null
                      : _renameSelectedPreset,
                  child: const Text('Renommer'),
                ),
                OutlinedButton(
                  onPressed: busy || selected == null
                      ? null
                      : _deleteSelectedPreset,
                  child: const Text('Supprimer'),
                ),
                FilledButton.icon(
                  onPressed: busy ? null : _createPreset,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: const Text('Enregistrer sous…'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _presetSubtitle(AiRoutingPreset preset) {
    final quand = preset.updatedAt;
    final qui = preset.updatedBy;
    if (quand == null && qui == null) return preset.name;
    final date = quand == null
        ? null
        : DateFormat('dd/MM/yy HH:mm').format(quand);
    if (date != null && qui != null) return 'Modifiée le $date par $qui';
    if (date != null) return 'Modifiée le $date';
    return 'Modifiée par $qui';
  }

  bool get _dirty {
    final draft = _draft;
    final loaded = _snapshot?.policy;
    if (draft == null || loaded == null) return false;
    if (draft.defaultProvider != loaded.defaultProvider) return true;
    if (draft.anthropicModel != loaded.anthropicModel) return true;
    if (draft.fallbackEnabled != loaded.fallbackEnabled) return true;
    if (draft.thinkingBudget != loaded.thinkingBudget) return true;
    if (draft.features.length != loaded.features.length) return true;
    for (final entry in draft.features.entries) {
      if (loaded.features[entry.key] != entry.value) return true;
    }
    // Le modèle par poste compte comme le reste: sans cette comparaison, le
    // bouton Enregistrer resterait gris et le choix serait perdu au retour.
    if (draft.anthropicModels.length != loaded.anthropicModels.length) {
      return true;
    }
    for (final entry in draft.anthropicModels.entries) {
      if (loaded.anthropicModels[entry.key] != entry.value) return true;
    }
    // Le plafond par poste compte aussi. L'écran ne le règle pas encore, mais
    // une configuration chargée peut en porter : sans cette comparaison, elle
    // se chargerait sans que la barre d'enregistrement apparaisse, et le
    // réglage serait perdu au retour.
    if (draft.thinkingBudgets.length != loaded.thinkingBudgets.length) {
      return true;
    }
    for (final entry in draft.thinkingBudgets.entries) {
      if (loaded.thinkingBudgets[entry.key] != entry.value) return true;
    }
    // Même garde que le modèle et le plafond, pour le même risque : sans elle,
    // ne changer QUE des efforts de réflexion laisse `_dirty` à faux, la barre
    // d'enregistrement ne s'affiche pas, et `PopScope` laisse quitter l'écran
    // sans prévenir — vingt-sept réglages perdus en silence.
    if (draft.anthropicEfforts.length != loaded.anthropicEfforts.length) {
      return true;
    }
    for (final entry in draft.anthropicEfforts.entries) {
      if (loaded.anthropicEfforts[entry.key] != entry.value) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = _snapshot;
    final draft = _draft;

    return PopScope(
      // Quitter avec des modifications en attente les perd sans un mot. Le
      // même silence que le bouton hors d'écran, par une autre porte.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !mounted) return;
        final leave = await _confirmLeave(context);
        if (leave && context.mounted) Navigator.of(context).pop();
      },
      child: _buildScaffold(context, theme, snapshot, draft),
    );
  }

  Future<bool> _confirmLeave(BuildContext context) async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Modifications non enregistrées'),
        content: const Text(
          'Le routage a été modifié sans être enregistré. Quitter maintenant '
          'perd ces changements.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Rester'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Quitter sans enregistrer'),
          ),
        ],
      ),
    );
    return leave ?? false;
  }

  Widget _buildScaffold(
    BuildContext context,
    ThemeData theme,
    AiRoutingSnapshot? snapshot,
    AiRoutingPolicy? draft,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Moteur d\'IA'),
        actions: [
          // Doublon volontaire de la barre du bas : celle-ci vit en fin d'un
          // formulaire de plus de quarante postes, et se confond au premier
          // coup d'œil avec « Enregistrer sous… » de la carte des
          // préconfigurations — deux boutons qui portent presque le même nom,
          // l'un range une configuration à part, l'autre écrit le routage en
          // vigueur. Celui-ci reste sous les yeux, sans défilement possible.
          IconButton(
            tooltip: _saving
                ? 'Enregistrement en cours…'
                : _dirty
                ? 'Enregistrer le routage en vigueur'
                : 'Aucune modification à enregistrer',
            onPressed: (_saving || !_dirty) ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: _loadError != null
          ? AppErrorState(
              error: _loadError,
              title: 'Routage non chargé',
              onRetry: _load,
            )
          : (snapshot == null || draft == null)
          ? const AppLoadingState(label: 'Chargement du routage…')
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (!snapshot.anthropicKeyPresent)
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(
                            Icons.key_off_outlined,
                            color: theme.colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'La clé Claude n\'est pas posée dans Secret Manager. '
                              'Les postes routés vers Claude continuent d\'être servis '
                              'par Gemini — aucune erreur, mais aucune bascule non plus.',
                              style: TextStyle(
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const AiConsoleLinks(),
                const SizedBox(height: 8),
                _buildPresetsCard(theme, snapshot, draft),
                const SizedBox(height: 20),
                Text('Réglages généraux', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        title: const Text('Moteur par défaut'),
                        subtitle: const Text(
                          'Sert tous les postes qui n\'ont pas de choix explicite.',
                        ),
                        trailing: _ProviderToggle(
                          value: draft.defaultProvider,
                          onChanged: (provider) => setState(
                            () => _draft = draft.copyWith(
                              defaultProvider: provider,
                            ),
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        value: draft.fallbackEnabled,
                        onChanged: (value) => setState(
                          () => _draft = draft.copyWith(fallbackEnabled: value),
                        ),
                        title: const Text('Repli automatique'),
                        subtitle: const Text(
                          'Si le moteur choisi échoue techniquement, l\'autre prend le relais. '
                          'Une réponse refusée pour raison de sûreté n\'est jamais rejouée ailleurs.',
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        title: const Text('Modèle Claude'),
                        subtitle: Text(draft.anthropicModel),
                        trailing: DropdownButton<String>(
                          value: draft.anthropicModel,
                          onChanged: (value) => setState(
                            () => _draft = draft.copyWith(
                              anthropicModel: value ?? draft.anthropicModel,
                            ),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'claude-haiku-4-5',
                              child: Text('Haiku 4.5 — 1 \$ / 5 \$'),
                            ),
                            DropdownMenuItem(
                              value: 'claude-sonnet-5',
                              child: Text('Sonnet 5 — 3 \$ / 15 \$'),
                            ),
                            DropdownMenuItem(
                              value: 'claude-opus-5',
                              child: Text('Opus 5 — 5 \$ / 25 \$'),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      // Le réglage qui pèse le plus lourd sur la facture
                      // Gemini, et le seul qui ne se voyait nulle part : le
                      // raisonnement est facturé au tarif de sortie sans
                      // jamais apparaître dans une réponse.
                      _ThinkingBudgetTile(
                        value: draft.thinkingBudget,
                        onChanged: (value) => setState(
                          () => _draft = draft.copyWith(
                            thinkingBudget: value,
                            clearThinkingBudget: value == null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Postes fonctionnels',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: () => _setProviderFor(
                        snapshot.routableFeatures,
                        AiProvider.gemini,
                      ),
                      child: const Text('Tout Gemini'),
                    ),
                    TextButton(
                      onPressed: () => _setProviderFor(
                        snapshot.routableFeatures,
                        AiProvider.anthropic,
                      ),
                      child: const Text('Tout Claude'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Chaque poste est une clé du reporting de coûts : ce que vous '
                  'basculez ici se mesure dans l\'écran Comptabilité.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                for (final group in _groupedFeatures(
                  snapshot.routableFeatures,
                ).entries) ...[
                  Builder(
                    builder: (context) {
                      // Un raccourci ne s'affiche que s'il commande quelque
                      // chose : « Tout Claude » sur un groupe verrouillé ne
                      // basculait rien et faisait refuser l'enregistrement.
                      final switchable = group.value
                          .where((f) => f.lockedProvider == null)
                          .toList(growable: false);
                      return _GroupHeader(
                        title: group.key,
                        count: group.value.length,
                        onAll: switchable.isEmpty
                            ? null
                            : (provider) =>
                                  _setProviderFor(switchable, provider),
                      );
                    },
                  ),
                  Card(
                    child: Column(
                      children: [
                        for (final feature in group.value) ...[
                          _FeatureTile(
                            feature: feature,
                            provider:
                                feature.lockedProvider ??
                                draft.providerFor(feature.id),
                            onChanged: (provider) =>
                                _setProviderFor([feature], provider),
                          ),
                          // Le modèle ne se choisit que là où il s'applique.
                          //
                          // Un poste servi par Gemini n'a que faire d'un
                          // sélecteur Claude : le montrer inactif ferait croire
                          // qu'il manque un réglage, alors qu'il manque une
                          // bascule.
                          if ((feature.lockedProvider ??
                                      draft.providerFor(feature.id)) ==
                                  AiProvider.anthropic &&
                              snapshot.anthropicModelChoices.isNotEmpty)
                            _ModelPicker(
                              choices: snapshot.anthropicModelChoices,
                              value: draft.anthropicModelFor(feature.id),
                              defaultModel: draft.anthropicModel,
                              onChanged: (model) =>
                                  _setModelFor(feature.id, model),
                            ),
                          // Même condition que le modèle : l'effort ne se
                          // règle que là où Claude répond effectivement.
                          if ((feature.lockedProvider ??
                                      draft.providerFor(feature.id)) ==
                                  AiProvider.anthropic &&
                              snapshot.anthropicEffortChoices.isNotEmpty)
                            _EffortPicker(
                              choices: snapshot.anthropicEffortChoices,
                              value: draft.anthropicEffortFor(feature.id),
                              onChanged: (effort) =>
                                  _setEffortFor(feature.id, effort),
                            ),
                          if (feature != group.value.last)
                            const Divider(height: 1),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (snapshot.imageGenerationFeatures.isNotEmpty) ...[
                  _GroupHeader(
                    title: 'Génération d\'image',
                    count: snapshot.imageGenerationFeatures.length,
                  ),
                  Text(
                    'Aucun modèle Claude ne produit d\'image : ces postes sont '
                    'servis par Gemini, sur un modèle dédié, et ne se basculent '
                    'pas. Leur coût se lit dans Comptabilité aux mêmes clés.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Card(
                    child: Column(
                      children: [
                        for (final feature
                            in snapshot.imageGenerationFeatures) ...[
                          ListTile(
                            title: Text(feature.label),
                            subtitle: Text(
                              feature.id,
                              style: theme.textTheme.bodySmall,
                            ),
                            // Une puce, et non un commutateur : la forme dit
                            // qu'il n'y a rien à choisir. Un commutateur grisé
                            // aurait laissé croire à un choix indisponible.
                            trailing: Chip(
                              avatar: const Icon(
                                Icons.auto_awesome_outlined,
                                size: AppIconSize.small,
                              ),
                              label: Text(
                                snapshot.imageModelLabel.isEmpty
                                    ? 'Gemini'
                                    : snapshot.imageModelLabel,
                              ),
                            ),
                          ),
                          if (feature != snapshot.imageGenerationFeatures.last)
                            const Divider(height: 1),
                        ],
                      ],
                    ),
                  ),
                  if (snapshot.imageModel.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Modèle : ${snapshot.imageModel}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 12),
                ],
                // La grille tarifaire a quitté cet écran pour le sien, sous
                // Comptabilité : elle vivait après quarante-cinq postes, et
                // rien dans le menu ne disait qu'elle était là. Ici on choisit
                // un moteur ; le prix auquel on le facture se lit à côté des
                // montants qu'il produit.
                //
                // Le bouton d'enregistrement n'est plus ici non plus : il vit
                // dans la barre du bas (`bottomNavigationBar`) et dans le
                // bandeau (`appBar.actions`), pour rester visible sans
                // défiler jusqu'en bas d'un formulaire de plus de quarante
                // postes.
                const SizedBox(height: 20),
              ],
            ),
      bottomNavigationBar: _dirty ? _buildSaveBar(context) : null,
    );
  }

  /// La barre d'enregistrement, collée en bas et visible dès qu'un réglage
  /// change.
  ///
  /// Le bouton vivait en fin de liste, après cinquante postes et la grille
  /// tarifaire. On changeait le modèle d'un poste en haut de page, on quittait
  /// l'écran, et le choix était perdu sans qu'aucun message ne le dise — un
  /// réglage qui ne s'enregistre pas ressemble en tout point à un réglage qui
  /// s'enregistre.
  Widget _buildSaveBar(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      elevation: 8,
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              Icon(Icons.edit_note, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Modifications non enregistrées.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(_saving ? 'Enregistrement…' : 'Enregistrer'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Plafond de raisonnement de Gemini.
///
/// Gemini 2.5 Flash délibère avant de répondre. Ces jetons sont facturés au
/// tarif de sortie et n'apparaissent dans aucune réponse : sur un mois observé,
/// ils pesaient 2,1 millions de jetons sur les 2,4 millions de sortie
/// facturés. Beaucoup de postes n'en ont aucun besoin — classer une page ou
/// proposer des tags ne demande pas de délibération.
///
/// « Le modèle décide » reste le défaut : couper le raisonnement partout
/// dégraderait les postes qui en vivent, l'extraction d'un scan en tête.
class _ThinkingBudgetTile extends StatelessWidget {
  final int? value;
  final ValueChanged<int?> onChanged;

  const _ThinkingBudgetTile({required this.value, required this.onChanged});

  /// `null` ne peut pas être la valeur d'un `DropdownMenuItem` distinguée d'une
  /// absence de sélection : le sentinelle négatif porte « le modèle décide ».
  static const _auto = -1;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: const Text('Raisonnement de Gemini'),
      subtitle: const Text(
        'Facturé au tarif de sortie, sans jamais apparaître dans la réponse. '
        'Le couper allège la ligne la plus chère de la facture Gemini, au prix '
        'de la qualité sur les postes qui délibèrent vraiment.',
      ),
      trailing: DropdownButton<int>(
        value: value ?? _auto,
        onChanged: (next) => onChanged(next == _auto ? null : next),
        items: const [
          DropdownMenuItem(value: _auto, child: Text('Le modèle décide')),
          DropdownMenuItem(value: 0, child: Text('Coupé')),
          DropdownMenuItem(value: 512, child: Text('512 jetons')),
          DropdownMenuItem(value: 2048, child: Text('2 048 jetons')),
          DropdownMenuItem(value: 8192, child: Text('8 192 jetons')),
        ],
      ),
    );
  }
}

/// Regroupe les postes par famille en conservant l'ordre du serveur.
///
/// L'ordre vient du backend et non d'un tri alphabétique : il suit le parcours
/// d'une recette (import, illustrations, rédaction…), ce qu'un tri par lettre
/// détruirait.
Map<String, List<RoutableFeature>> _groupedFeatures(
  List<RoutableFeature> features,
) {
  final grouped = <String, List<RoutableFeature>>{};
  for (final feature in features) {
    grouped.putIfAbsent(feature.group, () => []).add(feature);
  }
  return grouped;
}

class _GroupHeader extends StatelessWidget {
  final String title;
  final int count;

  /// Absent quand le groupe ne se bascule pas : un raccourci « Tout Claude » sur
  /// des postes que Claude ne sait pas servir serait un piège.
  final ValueChanged<AiProvider>? onAll;

  const _GroupHeader({required this.title, required this.count, this.onAll});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$title · $count poste${count > 1 ? 's' : ''}',
              style: theme.textTheme.titleSmall,
            ),
          ),
          if (onAll != null) ...[
            TextButton(
              onPressed: () => onAll!(AiProvider.gemini),
              child: const Text('Gemini'),
            ),
            TextButton(
              onPressed: () => onAll!(AiProvider.anthropic),
              child: const Text('Claude'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Une ligne de poste : son nom, sa clé de coût, et qui le sert.
///
/// Un poste verrouillé porte une puce, pas un commutateur grisé — même forme
/// que la génération d'image juste en dessous, pour la même raison : la forme
/// doit dire qu'il n'y a rien à choisir. L'écran affichait auparavant un
/// commutateur « Gemini / Claude » sur la modération, avec Gemini sélectionné,
/// alors que ces deux postes sont servis par Cloud Vision et refusés à
/// l'écriture par le serveur.
class _FeatureTile extends StatelessWidget {
  final RoutableFeature feature;

  /// Le fournisseur effectif : celui que le poste impose, à défaut celui de la
  /// politique.
  final AiProvider provider;
  final ValueChanged<AiProvider> onChanged;

  const _FeatureTile({
    required this.feature,
    required this.provider,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locked = feature.lockedProvider;
    final switchable =
        locked == null &&
        feature.allows(AiProvider.gemini) &&
        feature.allows(AiProvider.anthropic);
    final reason = feature.lockedReason;

    return ListTile(
      title: Text(feature.label),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(feature.id, style: theme.textTheme.bodySmall),
          if (!switchable && reason != null && reason.isNotEmpty)
            Text(
              reason,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
        ],
      ),
      trailing: switchable
          ? _ProviderToggle(value: provider, onChanged: onChanged)
          : Chip(
              avatar: const Icon(Icons.lock_outline, size: AppIconSize.small),
              // Une liste de fournisseurs vide veut dire que le serveur en
              // déclare un que ce client ne connaît pas : le nommer « Gemini »
              // serait exactement l'erreur qu'on corrige ici.
              label: Text(locked?.label ?? 'Non basculable'),
            ),
    );
  }
}

class _ProviderToggle extends StatelessWidget {
  final AiProvider value;
  final ValueChanged<AiProvider> onChanged;

  const _ProviderToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<AiProvider>(
      segments: const [
        ButtonSegment(value: AiProvider.gemini, label: Text('Gemini')),
        ButtonSegment(value: AiProvider.anthropic, label: Text('Claude')),
      ],
      selected: {value},
      showSelectedIcon: false,
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}

/// Sélecteur du modèle Claude d'un poste.
///
/// Il ne s'affiche que sous un poste effectivement routé vers Claude : ailleurs
/// il ferait croire qu'il manque un réglage, alors qu'il manque une bascule.
///
/// Le modèle par défaut porte la mention « défaut » plutôt que d'être
/// simplement coché : la différence entre « ce poste suit le réglage général »
/// et « ce poste a choisi la même chose » compte le jour où le général change.
class _ModelPicker extends StatelessWidget {
  const _ModelPicker({
    required this.choices,
    required this.value,
    required this.defaultModel,
    required this.onChanged,
  });

  final List<AnthropicModelChoice> choices;
  final String value;
  final String defaultModel;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final courant = choices.where((c) => c.id == value).firstOrNull;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.subdirectory_arrow_right,
            size: AppIconSize.small,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final choice in choices)
                      ChoiceChip(
                        label: Text(
                          choice.id == defaultModel
                              ? '${choice.label} · défaut'
                              : choice.label,
                        ),
                        selected: choice.id == value,
                        onSelected: (_) => onChanged(choice.id),
                      ),
                  ],
                ),
                if (courant != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    courant.hint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Effort de réflexion Claude d'un poste, sous le même sélecteur que le modèle.
///
/// Contrairement au modèle, il n'y a pas de « défaut » à afficher : un poste
/// sans réglage garde l'effort que SON propre code demande, pas un effort
/// commun à tous — d'où la puce « code », qui efface le réglage plutôt que de
/// le pointer vers une valeur partagée.
class _EffortPicker extends StatelessWidget {
  const _EffortPicker({
    required this.choices,
    required this.value,
    required this.onChanged,
  });

  final List<AnthropicEffortChoice> choices;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final courant = choices.where((c) => c.id == value).firstOrNull;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.psychology_outlined,
            size: AppIconSize.small,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('Réglage du code'),
                      selected: value == null,
                      onSelected: (_) => onChanged(null),
                    ),
                    for (final choice in choices)
                      ChoiceChip(
                        label: Text('Réflexion ${choice.label.toLowerCase()}'),
                        selected: choice.id == value,
                        onSelected: (_) => onChanged(choice.id),
                      ),
                  ],
                ),
                if (courant != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    courant.hint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
