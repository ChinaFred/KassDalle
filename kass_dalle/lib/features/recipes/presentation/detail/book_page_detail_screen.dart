import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:markdown/markdown.dart' as md;
import '../../../../core/utils/platform_utils.dart';
import '../../domain/recipe.dart';
import '../recipe_providers.dart';
import '../source_viewer.dart';
import '../../../auth/presentation/auth_providers.dart';
import 'book_reader_navigation.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/services/error_reporting.dart';
import '../../../../core/widgets/app_states.dart';
import '../../../../core/theme/app_icon_size.dart';
import '../../../../core/widgets/app_network_image.dart';
import '../../../../core/utils/app_image_url.dart';

final _prefetchedReaderItemIds = <String>{};

void _prefetchReaderItem(WidgetRef ref, Recipe item) {
  if (_prefetchedReaderItemIds.contains(item.id)) return;
  _prefetchedReaderItemIds.add(item.id);
  unawaited(() async {
    try {
      if (item.pageType == PageType.recipe) {
        await ref.read(recipeDetailProvider(item.id).future);
      } else {
        await ref.read(recipeByIdProvider(item.id).future);
      }
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'bookPageDetailScreen.prefetchReaderItem',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }());
}

// ── Top-level helper: suppression avec confirmation ───────────────────────────

Future<void> _deleteBookPage(
  BuildContext context,
  WidgetRef ref,
  Recipe recipe,
) async {
  // Capturer repo avant le dialogue (avant tout await).
  final repo = ref.read(recipeRepositoryProvider);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Supprimer cette page ?'),
      content: Text(
        '\u00ab ${recipe.titre} \u00bb sera supprim\u00e9e d\u00e9finitivement.',
      ),
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
  if (confirmed != true || !context.mounted) return;
  try {
    await repo.deleteRecipe(recipe.id);
  } catch (e, stackTrace) {
    reportUnexpectedError(
      feature: 'bookPageDetailScreen.deleteBookPage',
      error: e,
      stackTrace: stackTrace,
    );
    if (!context.mounted) return;
    context.showFailureSnackBar('Page non supprimée', e);
    return;
  }
  if (!context.mounted) return;
  final bookId = recipe.bookId;
  final bookTitre = recipe.bookTitre;
  if (bookId != null && bookId.isNotEmpty) {
    final titleParam = bookTitre != null && bookTitre.isNotEmpty
        ? '&bookTitre=${Uri.encodeQueryComponent(bookTitre)}'
        : '';
    context.go('/recipes?bookId=$bookId$titleParam');
  } else {
    context.go('/recipes');
  }
}

// ── Top-level helper: détacher du livre ───────────────────────────────────────

Future<void> _detachBookPage(
  BuildContext context,
  WidgetRef ref,
  Recipe recipe,
) async {
  final repo = ref.read(recipeRepositoryProvider);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Détacher cette page ?'),
      content: Text(
        'La page \u00ab ${recipe.titre} \u00bb sera retir\u00e9e de son livre et restera disponible.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Détacher'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await repo.detachRecipeFromBook(recipe.id);
    if (!context.mounted) return;
    context.showSuccessSnackBar('Page détachée du livre.');
  } catch (e, stackTrace) {
    reportUnexpectedError(
      feature: 'bookPageDetailScreen.detachBookPage',
      error: e,
      stackTrace: stackTrace,
    );
    if (!context.mounted) return;
    context.showFailureSnackBar('Page non détachée du livre', e);
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────────

IconData _iconForPageType(PageType t) => switch (t) {
  PageType.technique => Icons.tips_and_updates_outlined,
  PageType.equipment => Icons.kitchen_outlined,
  PageType.ingredientNote => Icons.eco_outlined,
  PageType.other => Icons.description_outlined,
  _ => Icons.description_outlined,
};

String _labelForPageType(PageType t) => switch (t) {
  PageType.technique => 'Technique culinaire',
  PageType.equipment => 'Matériel & ustensiles',
  PageType.ingredientNote => 'Note sur les ingrédients',
  PageType.other => 'Page de livre',
  _ => 'Page de livre',
};

/// Collecte toutes les pages consécutives (même [PageType], numéros contigus)
/// autour de [current] dans [allPages]. Retourne [current] seul si pas de contexte.
List<Recipe> _consecutiveGroup(List<Recipe> allPages, Recipe current) {
  if (current.pageNumber == null) return [current];

  final byNum = <int, Recipe>{};
  for (final p in allPages) {
    if (p.pageType == current.pageType && p.pageNumber != null) {
      byNum[p.pageNumber!] = p;
    }
  }

  int start = current.pageNumber!;
  while (byNum.containsKey(start - 1)) {
    start--;
  }

  final group = <Recipe>[];
  int n = start;
  while (byNum.containsKey(n)) {
    group.add(byNum[n]!);
    n++;
  }

  return group.isEmpty ? [current] : group;
}

// ── Screen ─────────────────────────────────────────────────────────────────────

/// Affiche le contenu d'une page non-recette d'un livre.
/// Regroupe automatiquement les pages consécutives du même type.
class BookPageDetailScreen extends ConsumerWidget {
  final String pageId;
  final BookReadingContext readingContext;
  const BookPageDetailScreen({
    super.key,
    required this.pageId,
    this.readingContext = const BookReadingContext(),
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recipeAsync = ref.watch(recipeByIdProvider(pageId));
    return recipeAsync.when(
      loading: () {
        final isMobile =
            MediaQuery.sizeOf(context).width <
            PlatformUtils.compactDetailBreakpoint;
        return Scaffold(
          body: Center(
            child: isMobile
                ? const CircularProgressIndicator()
                : const Text('Chargement de la page...'),
          ),
        );
      },
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: AppErrorState(
          error: e,
          onRetry: () => ref.invalidate(recipeByIdProvider(pageId)),
        ),
      ),
      data: (recipe) {
        if (recipe == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Page introuvable')),
            body: const Center(child: Text('Cette page est introuvable.')),
          );
        }
        return _BookPageContent(recipe: recipe, readingContext: readingContext);
      },
    );
  }
}

// ── Content widget (watch book pages for grouping) ────────────────────────────

class _BookPageContent extends ConsumerWidget {
  final Recipe recipe;
  final BookReadingContext readingContext;
  const _BookPageContent({required this.recipe, required this.readingContext});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    final allPages =
        ref.watch(allPagesByBookProvider(recipe.bookId ?? '')).value ??
        [recipe];

    final group = _consecutiveGroup(allPages, recipe);
    final pageIcon = _iconForPageType(recipe.pageType);
    final pageLabel = _labelForPageType(recipe.pageType);
    final isMulti = group.length > 1;
    final readingPosition = readingContext.isEnabled
        ? resolveBookReadingPosition(allPages, recipe.id)
        : null;

    if (readingPosition != null) {
      _prefetchReaderItem(ref, readingPosition.current);
      final previous = readingPosition.previous;
      if (previous != null) {
        _prefetchReaderItem(ref, previous);
      }
      final next = readingPosition.next;
      if (next != null) {
        _prefetchReaderItem(ref, next);
      }
    }

    void openReaderItem(Recipe target) {
      _prefetchReaderItem(ref, target);
      final location = target.pageType == PageType.recipe
          ? buildReaderRecipeLocation(target.id, readingContext)
          : buildReaderBookPageLocation(target.id, readingContext);
      context.go(location);
    }

    final pageRange = isMulti
        ? 'p.${group.first.pageNumber}–${group.last.pageNumber}'
        : (recipe.pageNumber != null ? 'p.${recipe.pageNumber}' : null);

    final allImages = <String>{};
    for (final p in group) {
      allImages.addAll(p.imageUrls);
    }
    final images = allImages.toList();

    final user = ref.watch(appUserProvider).value;
    // Créateur ou administrateur seulement, éditeur compris : miroir de la
    // règle `recipes` de `firestore.rules`.
    final canEdit = user?.canModifyRecipe(recipe.createdBy) ?? false;
    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  pageIcon,
                  size: AppIconSize.small,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(recipe.titre, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            if (pageRange != null)
              Text(
                pageRange,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
          ],
        ),
        actions: [
          if ((recipe.sourceFileUrl ?? '').isNotEmpty)
            SourceViewerButton(
              sourceFileUrl: recipe.sourceFileUrl,
              sourceFileName: recipe.sourceFileName,
              additionalSourceFileUrls: recipe.additionalSourceFileUrls,
            ),
          if (canEdit && (recipe.bookId ?? '').isNotEmpty)
            IconButton(
              icon: const Icon(Icons.link_off_outlined),
              tooltip: 'Détacher du livre',
              onPressed: () => _detachBookPage(context, ref, recipe),
            ),
          if (canEdit)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Modifier la page',
              onPressed: () => context.push('/recipes/${recipe.id}/edit'),
            ),
          if (canEdit)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Supprimer cette page',
              color: Theme.of(context).colorScheme.error,
              onPressed: () => _deleteBookPage(context, ref, recipe),
            ),
        ],
      ),
      body: BookReaderViewport(
        position: readingPosition,
        onOpen: openReaderItem,
        child: isWide
            ? _buildWideBody(context, theme, group, images, pageIcon, pageLabel)
            : _buildNarrowBody(
                context,
                theme,
                group,
                images,
                pageIcon,
                pageLabel,
              ),
      ),
      bottomNavigationBar: BookReaderBottomBar(
        position: readingPosition,
        onOpen: openReaderItem,
      ),
    );
  }

  Widget _buildWideBody(
    BuildContext context,
    ThemeData theme,
    List<Recipe> group,
    List<String> images,
    IconData pageIcon,
    String pageLabel,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Sidebar gauche : type + illustrations ─────────────────────────
        SizedBox(
          width: 280,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Chip(
                  avatar: Icon(pageIcon, size: AppIconSize.inline),
                  label: Text(pageLabel),
                  visualDensity: VisualDensity.compact,
                ),
                if (images.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text(
                    'Illustrations',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (final url in images) ...[
                    _SidebarImage(url: url),
                    const SizedBox(height: 8),
                  ],
                ],
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        // ── Contenu : texte centré, largeur max 720 ────────────────────────
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(32, 16, 32, 80),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (int i = 0; i < group.length; i++) ...[
                      if (i > 0) ...[
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            const Expanded(child: Divider()),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Text(
                                'p.${group[i].pageNumber}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            const Expanded(child: Divider()),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                      _PageTextContent(page: group[i]),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNarrowBody(
    BuildContext context,
    ThemeData theme,
    List<Recipe> group,
    List<String> images,
    IconData pageIcon,
    String pageLabel,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Chip(
            avatar: Icon(pageIcon, size: AppIconSize.inline),
            label: Text(pageLabel),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(height: 16),
          for (int i = 0; i < group.length; i++) ...[
            if (i > 0) ...[
              const SizedBox(height: 20),
              Row(
                children: [
                  const Expanded(child: Divider()),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      'p.${group[i].pageNumber}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const Expanded(child: Divider()),
                ],
              ),
              const SizedBox(height: 12),
            ],
            _PageTextContent(page: group[i]),
          ],
          if (images.isNotEmpty) ...[
            const SizedBox(height: 24),
            Divider(color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 8),
            Text(
              'Illustrations',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final url in images) _ImageThumbnail(url: url)],
            ),
          ],
          const SizedBox(height: 80),
        ],
      ),
    );
  }
}

// ── Normalisation du Markdown ──────────────────────────────────────────────────

/// Corrige les espaces parasites à l'intérieur des marqueurs inline Markdown.
/// Exemple : `** Germes de soja**` → `**Germes de soja**`
/// Produit courant du scan IA qui ajoute un espace après l'ouverture ** ou *.
String _fixMarkdownSpacing(String text) {
  // Gras : ** text** ou **text ** → **text**
  text = text.replaceAllMapped(
    RegExp(r'\*\*\s+(.+?)\*\*'),
    (m) => '**${m.group(1)!.trimRight()}**',
  );
  // Italique (étoile simple, pas précédée/suivie d'une autre) : * text* → *text*
  text = text.replaceAllMapped(
    RegExp(r'(?<!\*)\*\s+(.+?)\*(?!\*)'),
    (m) => '*${m.group(1)!.trimRight()}*',
  );
  return text;
}

// ── Page text ──────────────────────────────────────────────────────────────────

class _PageTextContent extends StatelessWidget {
  final Recipe page;
  const _PageTextContent({required this.page});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final raw =
        (page.draftCooklang?.isNotEmpty == true
                ? page.draftCooklang!
                : page.rawCooklang)
            .trim();

    // Supprimer les lignes de métadonnées CookLang (>> clé: valeur)
    final rawCleaned = raw
        .split('\n')
        .where((l) => !RegExp(r'^\s*>>').hasMatch(l))
        .join('\n')
        .trim();

    // Corriger les espaces parasites après ** ou * (artéfacts du scan IA)
    final cleaned = _fixMarkdownSpacing(rawCleaned);

    if (cleaned.isEmpty) {
      return Text(
        'Aucun contenu extrait.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    return MarkdownBody(
      data: cleaned,
      selectable: true,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        h1: theme.textTheme.headlineMedium,
        h2: theme.textTheme.headlineSmall,
        h3: theme.textTheme.titleLarge,
        p: theme.textTheme.bodyMedium?.copyWith(height: 1.75),
        listBullet: theme.textTheme.bodyMedium?.copyWith(height: 1.75),
        blockquote: theme.textTheme.bodyMedium?.copyWith(
          fontStyle: FontStyle.italic,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      imageBuilder: (uri, title, alt) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AppNetworkImage(
            imageUrl: uri.toString(),
            fit: BoxFit.cover,
            errorWidget: (_, _, _) => Container(
              height: 80,
              color: theme.colorScheme.surfaceContainerHighest,
              child: const Center(child: Icon(Icons.broken_image_outlined)),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Sidebar image (wide layout) ────────────────────────────────────────────────

class _SidebarImage extends StatelessWidget {
  final String url;
  const _SidebarImage({required this.url});

  @override
  Widget build(BuildContext context) {
    // Une image hors de Kass'Dalle n'ouvre pas de visionneuse.
    return GestureDetector(
      onTap: !isAppImageUrl(url)
          ? null
          : () => showDialog<void>(
              context: context,
              builder: (_) => Dialog.fullscreen(
                backgroundColor: Colors.black,
                child: Stack(
                  children: [
                    Center(
                      child: InteractiveViewer(
                        minScale: 0.5,
                        maxScale: 6,
                        child: AppNetworkImage(imageUrl: url),
                      ),
                    ),
                    Positioned(
                      top: 16,
                      right: 16,
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        tooltip: 'Fermer',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: AppNetworkImage(
          imageUrl: url,
          width: double.infinity,
          fit: BoxFit.cover,
          placeholder: (_, _) => Container(
            height: 150,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          errorWidget: (_, _, _) => Container(
            height: 80,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Icon(Icons.broken_image_outlined),
          ),
        ),
      ),
    );
  }
}

// ── Image thumbnail ────────────────────────────────────────────────────────────

class _ImageThumbnail extends StatelessWidget {
  final String url;
  const _ImageThumbnail({required this.url});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Une image hors de Kass'Dalle n'ouvre pas de visionneuse.
      onTap: isAppImageUrl(url) ? () => _showFullscreen(context) : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: AppNetworkImage(
          imageUrl: url,
          width: 120,
          height: 90,
          fit: BoxFit.cover,
          placeholder: (_, _) => Container(
            width: 120,
            height: 90,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          errorWidget: (_, _, _) => Container(
            width: 120,
            height: 90,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Icon(Icons.broken_image_outlined),
          ),
        ),
      ),
    );
  }

  void _showFullscreen(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 6,
                child: AppNetworkImage(imageUrl: url),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                tooltip: 'Fermer',
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
