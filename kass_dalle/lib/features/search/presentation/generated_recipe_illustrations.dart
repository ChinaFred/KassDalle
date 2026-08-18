import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/services/error_reporting.dart';
import '../../../core/services/gemini_providers.dart';
import '../../../core/utils/context_extensions.dart';
import '../../moderation/data/image_moderation_service.dart';
import '../../recipes/presentation/ai/ai_ui_copy.dart';

/// Section photos d'une recette générée par l'IA, **avant** son enregistrement.
///
/// La recette n'existe pas encore en base : aucun identifiant à donner. Les
/// deux voies fonctionnent quand même, parce qu'aucune n'en a besoin — la
/// génération part du titre et d'un prompt, l'envoi d'une photo se range sous
/// l'utilisateur. Les URL obtenues sont tenues en mémoire et partent avec la
/// recette au moment de l'enregistrer.
///
/// Sans cette section, une recette née de l'IA arrivait forcément sans image,
/// et il fallait la sauvegarder puis rouvrir le brouillon pour l'illustrer.
class GeneratedRecipeIllustrations extends ConsumerStatefulWidget {
  final String recipeTitle;

  /// Corps de la recette, servi de contexte au générateur d'image.
  final String recipeContext;

  final List<String> imageUrls;
  final ValueChanged<List<String>> onChanged;
  final bool enabled;

  const GeneratedRecipeIllustrations({
    super.key,
    required this.recipeTitle,
    required this.recipeContext,
    required this.imageUrls,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  ConsumerState<GeneratedRecipeIllustrations> createState() =>
      _GeneratedRecipeIllustrationsState();
}

class _GeneratedRecipeIllustrationsState
    extends ConsumerState<GeneratedRecipeIllustrations> {
  bool _uploading = false;
  bool _generating = false;

  bool get _busy => _uploading || _generating || !widget.enabled;

  void _add(String url) {
    widget.onChanged([...widget.imageUrls, url]);
  }

  void _remove(String url) {
    widget.onChanged(widget.imageUrls.where((u) => u != url).toList());
  }

  Future<void> _addPhoto() async {
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

    final picked = await ImagePicker().pickImage(
      source: source,
      imageQuality: 85,
      maxWidth: 1600,
    );
    if (picked == null || !mounted) return;

    setState(() => _uploading = true);
    try {
      final bytes = await picked.readAsBytes();
      final url = await ImageModerationService().publish(
        PendingImage(
          bytes: bytes,
          filename: picked.name,
          contentType: 'image/jpeg',
          target: ModerationTarget.draftIllustration,
        ),
      );
      if (!mounted) return;
      _add(url);
    } on ImageNotPublished catch (e) {
      // Une photo retenue par la modération n'est pas une panne : le message
      // porte le motif, faute de quoi l'utilisateur croirait à un bug et
      // réessaierait indéfiniment.
      if (!mounted) return;
      context.showErrorSnackBar('$e');
    } on UnsupportedImageFormat catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar('$e');
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'generatedRecipeIllustrations.addPhoto',
        error: e,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      context.showErrorSnackBar('Erreur upload : $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _generate() async {
    final promptCtrl = TextEditingController(text: widget.recipeTitle);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text(RecipeAiUiCopy.generateImageDialogTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(RecipeAiUiCopy.generateImageDialogHelper),
              const SizedBox(height: 12),
              TextField(
                controller: promptCtrl,
                autofocus: true,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Ce que l\'image doit montrer',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(RecipeAiUiCopy.generateImageDialogPrimaryCta),
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

      setState(() => _generating = true);
      try {
        // Le générateur n'a pas besoin d'un identifiant de recette : il part du
        // titre et du prompt, et le serveur dépose l'image sous l'utilisateur.
        final url = await ref
            .read(geminiServiceProvider)
            .generateRecipeIllustration(
              recipeTitle: widget.recipeTitle,
              recipeContext: prompt,
            );
        if (!mounted) return;
        _add(url);
        context.showSnackBar(RecipeAiUiCopy.generateImageSuccess);
      } catch (e, stackTrace) {
        reportUnexpectedError(
          feature: 'generatedRecipeIllustrations.generate',
          error: e,
          stackTrace: stackTrace,
        );
        if (!mounted) return;
        context.showErrorSnackBar('Erreur génération image : $e');
      } finally {
        if (mounted) setState(() => _generating = false);
      }
    } finally {
      promptCtrl.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Photos et illustrations', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Les images choisies ici partent avec la recette quand vous '
            'l\'enregistrez. Une photo que vous envoyez passe par la '
            'modération ; une image créée par l\'IA en est dispensée.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final url in widget.imageUrls)
                _Thumbnail(
                  url: url,
                  onRemove: _busy ? null : () => _remove(url),
                ),
            ],
          ),
          if (widget.imageUrls.isNotEmpty) const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                icon: _uploading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_a_photo_outlined),
                label: Text(_uploading ? 'Envoi…' : 'Ajouter une photo'),
                onPressed: _busy ? null : _addPhoto,
              ),
              FilledButton.icon(
                icon: _generating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),
                label: Text(
                  _generating
                      ? 'Génération…'
                      : RecipeAiUiCopy.generateImageLabel,
                ),
                onPressed: _busy ? null : _generate,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  final String url;
  final VoidCallback? onRemove;

  const _Thumbnail({required this.url, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CachedNetworkImage(
            imageUrl: url,
            width: 120,
            height: 120,
            fit: BoxFit.cover,
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: IconButton(
            tooltip: 'Retirer',
            icon: const Icon(Icons.close),
            iconSize: 18,
            style: IconButton.styleFrom(
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surface.withValues(alpha: 0.8),
              minimumSize: const Size(28, 28),
              padding: EdgeInsets.zero,
            ),
            onPressed: onRemove,
          ),
        ),
      ],
    );
  }
}
