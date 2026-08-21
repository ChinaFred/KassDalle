import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/services/gemini_providers.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../ai/ai_ui_copy.dart';
import '../../../../core/services/error_reporting.dart';
import '../../data/draft_review_service.dart';
import 'illustration_card.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/theme/app_icon_size.dart';

/// Onglet « Illustrations » d'un brouillon : extraction par IA, amélioration,
/// génération et gestion manuelle des images.
///
/// Extrait de draft_review_widgets.dart.

class DraftIllustrationsTab extends ConsumerStatefulWidget {
  final Recipe recipe;
  final bool isOwner;
  final bool aiRefining;
  final bool saving;
  final Future<String?> Function(Uint8List bytes, String fileName)?
  onUploadImage;
  final void Function(List<String> urls, int startIndex)? onShowGallery;
  final VoidCallback? onExtract;
  final VoidCallback? onExtractFromOriginal;
  final void Function(int index)? onEdit;

  /// Bouton « AI enhance » (perspective + couleurs) — admin uniquement.
  final void Function(int index)? onEnhance;

  /// Index actuellement en cours d'amélioration AI (spinner sur la carte).
  final int? enhancingIndex;

  const DraftIllustrationsTab({
    super.key,
    required this.recipe,
    required this.isOwner,
    required this.aiRefining,
    required this.saving,
    this.onUploadImage,
    this.onShowGallery,
    this.onExtract,
    this.onExtractFromOriginal,
    this.onEdit,
    this.onEnhance,
    this.enhancingIndex,
  });

  @override
  ConsumerState<DraftIllustrationsTab> createState() =>
      _DraftIllustrationsTabState();
}

class _DraftIllustrationsTabState extends ConsumerState<DraftIllustrationsTab> {
  bool _selectMode = false;
  bool _uploadingManual = false;
  bool _generatingAi = false;
  final Set<int> _selected = {};

  String _buildDefaultAiPrompt() {
    final ingredients = widget.recipe.ingredientsIndex.take(8).join(', ');
    final dishTypes = widget.recipe.tags.dishTypes.join(', ');
    final rawCooklang = widget.recipe.rawCooklang
        .replaceAll(RegExp(r'^>>.*$', multiLine: true), '')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();

    final contextParts = <String>[
      'Titre: ${widget.recipe.titre}',
      if (dishTypes.isNotEmpty) 'Type de plat: $dishTypes',
      if (ingredients.isNotEmpty) 'Éléments essentiels: $ingredients',
      if (rawCooklang.isNotEmpty)
        'Contexte recette: ${rawCooklang.length > 700 ? '${rawCooklang.substring(0, 700)}…' : rawCooklang}',
    ];

    return [
      'Créer une photo réaliste du plat ci-dessous.',
      ...contextParts,
      'Photo culinaire appétissante, dressage soigneux, éléments essentiels bien visibles et identifiables.',
      'Lumière naturelle, fond sobre, sans texte ni watermark.',
    ].join('\n');
  }

  Future<void> _generateAiImage() async {
    if (!widget.isOwner) return;
    final gemini = ref.read(geminiServiceProvider);
    final promptCtrl = TextEditingController(text: _buildDefaultAiPrompt());

    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.auto_awesome_outlined),
              SizedBox(width: 8),
              Text(RecipeAiUiCopy.generateImageDialogTitle),
            ],
          ),
          content: SizedBox(
            width: MediaQuery.sizeOf(ctx).width > 720
                ? 560
                : MediaQuery.sizeOf(ctx).width * 0.9,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  RecipeAiUiCopy.generateImageDialogHelper,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: promptCtrl,
                  autofocus: true,
                  minLines: 8,
                  maxLines: 12,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(
                Icons.auto_awesome_outlined,
                size: AppIconSize.inline,
              ),
              label: const Text(RecipeAiUiCopy.generateImageDialogPrimaryCta),
            ),
          ],
        ),
      );

      if (confirmed != true || !mounted) return;

      final prompt = promptCtrl.text.trim();
      if (prompt.isEmpty) {
        context.showErrorSnackBar('Le prompt est vide');
        return;
      }

      setState(() => _generatingAi = true);
      try {
        final url = await gemini.generateRecipeIllustration(
          recipeTitle: widget.recipe.titre,
          recipeContext: prompt,
        );
        if (!mounted) return;

        final newUrls = List<String>.from(widget.recipe.imageUrls)..add(url);
        final newThumbs = List<String>.from(widget.recipe.thumbnailUrls)
          ..add(url);
        await ref
            .read(recipeRepositoryProvider)
            .updateRecipeIllustrations(
              widget.recipe.id,
              newUrls,
              thumbnailUrls: newThumbs,
            );
        if (mounted) {
          context.showSnackBar(RecipeAiUiCopy.generateImageSuccess);
        }
      } catch (e, stackTrace) {
        reportUnexpectedError(
          feature: 'draftReviewWidgets.generateAiImage',
          error: e,
          stackTrace: stackTrace,
        );
        if (!mounted) return;
        context.showErrorSnackBar('Erreur génération image : $e');
      } finally {
        if (mounted) setState(() => _generatingAi = false);
      }
    } finally {
      promptCtrl.dispose();
    }
  }

  Future<void> _addManualPhoto() async {
    final upload = widget.onUploadImage;
    if (!widget.isOwner || upload == null) return;

    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choisir dans la galerie'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: source,
      preferredCameraDevice: source == ImageSource.camera
          ? CameraDevice.rear
          : CameraDevice.front,
      imageQuality: 85,
      maxWidth: 1600,
    );
    if (picked == null || !mounted) return;

    setState(() => _uploadingManual = true);
    try {
      final bytes = await picked.readAsBytes();
      final url = await upload(bytes, picked.name);
      if (!mounted) return;
      if (url == null || url.isEmpty) {
        context.showErrorSnackBar('Upload image échoué');
        return;
      }

      final newUrls = List<String>.from(widget.recipe.imageUrls)..add(url);
      await ref
          .read(recipeRepositoryProvider)
          .updateRecipeIllustrations(widget.recipe.id, newUrls);
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'draftReviewWidgets.addManualPhoto',
        error: e,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      context.showErrorSnackBar('Erreur upload : $e');
    } finally {
      if (mounted) setState(() => _uploadingManual = false);
    }
  }

  void _toggleSelect(int i) => setState(
    () => _selected.contains(i) ? _selected.remove(i) : _selected.add(i),
  );

  void _startSelectMode() => setState(() => _selectMode = true);

  void _cancelSelectMode() => setState(() {
    _selectMode = false;
    _selected.clear();
  });

  void _selectAll() {
    setState(() {
      _selected.clear();
      for (var i = 0; i < widget.recipe.imageUrls.length; i++) {
        _selected.add(i);
      }
    });
  }

  Future<void> _removeAt(int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer cette photo ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final newUrls = List<String>.from(widget.recipe.imageUrls)..removeAt(index);
    final thumbs = widget.recipe.thumbnailUrls;
    final newThumbs = thumbs.length > index
        ? (List<String>.from(thumbs)..removeAt(index))
        : null;
    await ref
        .read(recipeRepositoryProvider)
        .updateRecipeIllustrations(
          widget.recipe.id,
          newUrls,
          thumbnailUrls: newThumbs,
        );
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final n = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Supprimer $n photo${n > 1 ? 's' : ''} ?'),
        content: Text(
          '$n photo${n > 1 ? 's' : ''} sélectionnée${n > 1 ? 's' : ''} '
          'ser${n > 1 ? 'ont' : 'a'} supprimée${n > 1 ? 's' : ''} définitivement.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // Supprimer du plus grand index au plus petit pour préserver les indices
    final sorted = _selected.toList()..sort((a, b) => b.compareTo(a));
    final newUrls = List<String>.from(widget.recipe.imageUrls);
    final newThumbs = List<String>.from(widget.recipe.thumbnailUrls);
    for (final i in sorted) {
      newUrls.removeAt(i);
      if (i < newThumbs.length) newThumbs.removeAt(i);
    }
    _cancelSelectMode();
    await ref
        .read(recipeRepositoryProvider)
        .updateRecipeIllustrations(
          widget.recipe.id,
          newUrls,
          thumbnailUrls: newThumbs.isEmpty ? null : newThumbs,
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final busy =
        widget.aiRefining || widget.saving || _uploadingManual || _generatingAi;

    // Ce que l’import a REPÉRÉ sur la page, qui n’a plus rien à voir avec ce
    // qui y est attaché : depuis le retrait de l’extraction automatique,
    // l’import compte les photos et n’en publie aucune.
    final reperees = widget.recipe.illustrationReport?.detectees ?? 0;

    final canAddManual = widget.isOwner && widget.onUploadImage != null;

    // Produire une image coûte 0,0336 $ l'unité, et le serveur réserve ce
    // poste aux éditeurs — comme le visuel de dressage. Proposer le bouton à
    // un lecteur, fût-il propriétaire de son brouillon, ne lui donnerait qu'un
    // refus de permission sans explication.
    final canGenerateAi = widget.isOwner && ref.watch(canEditProvider);

    final hasPhotos = widget.recipe.imageUrls.isNotEmpty;

    // Cadrer soi-même dans le scan de la page.
    //
    // L'écran disait « cadrez-les vous-même depuis la photo du livre » sans
    // offrir par où commencer : « Ajouter » ouvre la galerie du téléphone, pas
    // le scan du livre. Une consigne sans porte est une impasse.
    //
    // Le chemin existait déjà — il ouvre l'atelier de retouche sur le scan
    // téléchargé — mais son bouton était parti avec l'extraction automatique.
    // Ce n'est pas la même chose : celle-ci décidait du cadrage, celui-là le
    // laisse à qui regarde la page.
    final canCropSource =
        widget.isOwner &&
        widget.onExtractFromOriginal != null &&
        (widget.recipe.sourceFileUrl ?? '').isNotEmpty &&
        // Un PDF ne s'ouvre pas dans l'atelier de retouche. Proposer le
        // bouton quand même donnerait un échec silencieux au clic.
        DraftReviewService.isImageUrl(
          widget.recipe.sourceFileUrl,
          widget.recipe.sourceFileName,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Barre d'actions (toujours visible) ──────────────────────────────
        if (canAddManual || canGenerateAi || (hasPhotos && widget.isOwner))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            // Les actions passent à la ligne au lieu de sortir de l’écran.
            //
            // Une `Row` sur mobile poussait les derniers boutons hors du
            // cadre: ils existaient, ils étaient cliquables, ils n’étaient
            // simplement pas visibles - la pire des trois situations, parce
            // qu’on ne cherche pas ce qu’on ne soupçonne pas.
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              runSpacing: 4,
              children: [
                if (hasPhotos)
                  Text(
                    '${widget.recipe.imageUrls.length} photo'
                    '${widget.recipe.imageUrls.length > 1 ? 's' : ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                if (!_selectMode) ...[
                  if (canGenerateAi)
                    TextButton.icon(
                      onPressed: busy ? null : _generateAiImage,
                      icon: _generatingAi
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(
                              Icons.auto_awesome_outlined,
                              size: AppIconSize.inline,
                            ),
                      label: const Text(RecipeAiUiCopy.generateImageLabel),
                    ),
                  if (canAddManual)
                    TextButton.icon(
                      onPressed: busy ? null : _addManualPhoto,
                      icon: _uploadingManual
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(
                              Icons.add_a_photo_outlined,
                              size: AppIconSize.inline,
                            ),
                      label: const Text('Ajouter'),
                    ),
                  // « Extraire » et « Depuis l'original » ont été retirés.
                  //
                  // Ils appelaient la même détection que le pipeline d'import,
                  // avec les mêmes résultats : un cadrage qui rend le bureau
                  // avec le plat. Un bouton qui ne tient pas sa promesse coûte
                  // plus qu'il ne rend — on le presse, on attend, on jette.
                  //
                  // L'import dit maintenant COMBIEN de photos la page porte ;
                  // « Ajouter » et l'atelier de retouche font le reste, en dix
                  // secondes et sans surprise.
                  if (canCropSource)
                    TextButton.icon(
                      onPressed: busy ? null : widget.onExtractFromOriginal,
                      icon: const Icon(Icons.crop, size: AppIconSize.inline),
                      label: const Text('Cadrer depuis le scan'),
                    ),
                  if (hasPhotos && widget.isOwner)
                    IconButton(
                      tooltip: 'Sélectionner plusieurs',
                      icon: const Icon(Icons.checklist_outlined),
                      onPressed: _startSelectMode,
                    ),
                ] else ...[
                  // ── Mode sélection multiple ──────────────────────────────
                  Text(
                    '${_selected.length} sélectionnée'
                    '${_selected.length > 1 ? 's' : ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  TextButton(onPressed: _selectAll, child: const Text('Tout')),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.error,
                      foregroundColor: cs.onError,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                    ),
                    onPressed: _selected.isEmpty ? null : _deleteSelected,
                    icon: const Icon(
                      Icons.delete_outline,
                      size: AppIconSize.inline,
                    ),
                    label: Text('Supprimer (${_selected.length})'),
                  ),
                  TextButton(
                    onPressed: _cancelSelectMode,
                    child: const Text('Annuler'),
                  ),
                ],
              ],
            ),
          ),
        // ── Zone centrale ─────────────────────────────────────────────────
        Expanded(
          child: hasPhotos
              ? GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 260,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 4 / 3,
                  ),
                  itemCount: widget.recipe.imageUrls.length,
                  itemBuilder: (ctx, i) => IllustrationCard(
                    url: widget.recipe.imageUrls[i],
                    thumbnailUrl: widget.recipe.thumbnailUrls.length > i
                        ? widget.recipe.thumbnailUrls[i]
                        : null,
                    onTap: (!_selectMode && widget.onShowGallery != null)
                        ? () =>
                              widget.onShowGallery!(widget.recipe.imageUrls, i)
                        : null,
                    onDelete: (!_selectMode && widget.isOwner)
                        ? () => _removeAt(i)
                        : null,
                    onEdit:
                        (!_selectMode &&
                            widget.isOwner &&
                            widget.onEdit != null)
                        ? () => widget.onEdit!(i)
                        : null,
                    onEnhance:
                        (!_selectMode &&
                            widget.isOwner &&
                            widget.onEnhance != null)
                        ? () => widget.onEnhance!(i)
                        : null,
                    enhancing: widget.enhancingIndex == i,
                    selected: _selectMode && _selected.contains(i),
                    onSelectTap: _selectMode ? () => _toggleSelect(i) : null,
                  ),
                )
              // Centré ET défilable.
              //
              // Un Center seul suffit tant que le contenu tient. Sur un
              // téléphone il ne tient pas : icône, titre, deux lignes de texte
              // et trois boutons dépassent la hauteur disponible. Le bas était
              // rogné par la barre de navigation, et rien ne défilait — les
              // boutons existaient, ils n'étaient simplement pas atteignables.
              //
              // ConstrainedBox(minHeight) garde le centrage quand la place
              // suffit ; le SingleChildScrollView prend le relais sinon.
              : LayoutBuilder(
                  builder: (ctx, contraintes) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: contraintes.maxHeight,
                      ),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.photo_library_outlined,
                                size: AppIconSize.hero,
                                color: cs.onSurfaceVariant,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                reperees > 0
                                    ? '$reperees photo${reperees > 1 ? "s" : ""} '
                                          'repérée${reperees > 1 ? "s" : ""} sur la page'
                                    : 'Aucune photo dans ce brouillon',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                // Cet écran disait « Aucune photo détectée » quand le
                                // bandeau de relecture en annonçait cinq : deux
                                // affirmations contraires sur le même scan, à deux
                                // endroits de la même page.
                                //
                                // Il ne parlait pas de la même chose — il constatait
                                // qu'aucune image n'était ATTACHÉE, et en concluait
                                // qu'il n'y en avait pas à prendre. Depuis le retrait
                                // de l'extraction automatique, les deux n'ont plus
                                // rien à voir : l'import repère, il n'attache plus.
                                reperees > 0
                                    ? 'Le scan en contient, mais elles ne sont plus '
                                          'extraites automatiquement :\ncadrez-les '
                                          'vous-même dans la page du livre.'
                                    : "L'IA n'a trouvé aucune photo culinaire dans ce "
                                          'document.\nVous pouvez en ajouter une à la main.',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                              // Le scan d'abord : c'est là que sont les photos
                              // que le message vient d'annoncer.
                              if (canCropSource) ...[
                                const SizedBox(height: 16),
                                FilledButton.icon(
                                  onPressed: busy
                                      ? null
                                      : widget.onExtractFromOriginal,
                                  icon: const Icon(Icons.crop),
                                  label: const Text('Cadrer depuis le scan'),
                                ),
                              ],
                              if (canAddManual) ...[
                                const SizedBox(height: 16),
                                canCropSource
                                    ? OutlinedButton.icon(
                                        onPressed: busy
                                            ? null
                                            : _addManualPhoto,
                                        icon: const Icon(
                                          Icons.add_a_photo_outlined,
                                        ),
                                        label: const Text('Ajouter une photo'),
                                      )
                                    : FilledButton.icon(
                                        onPressed: busy
                                            ? null
                                            : _addManualPhoto,
                                        icon: const Icon(
                                          Icons.add_a_photo_outlined,
                                        ),
                                        label: const Text('Ajouter une photo'),
                                      ),
                                const SizedBox(height: 8),
                                FilledButton.tonalIcon(
                                  onPressed: busy ? null : _generateAiImage,
                                  icon: _generatingAi
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.auto_awesome_outlined),
                                  label: const Text(
                                    RecipeAiUiCopy.generateImageLabel,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
