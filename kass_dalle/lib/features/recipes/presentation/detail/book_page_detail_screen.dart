import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/recipe.dart';
import '../recipe_providers.dart';
import '../source_viewer.dart';

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
  const BookPageDetailScreen({super.key, required this.pageId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recipeAsync = ref.watch(recipeByIdProvider(pageId));
    return recipeAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Erreur')),
        body: Center(child: Text('$e')),
      ),
      data: (recipe) {
        if (recipe == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Page introuvable')),
            body: const Center(child: Text('Cette page est introuvable.')),
          );
        }
        return _BookPageContent(recipe: recipe);
      },
    );
  }
}

// ── Content widget (watch book pages for grouping) ────────────────────────────

class _BookPageContent extends ConsumerWidget {
  final Recipe recipe;
  const _BookPageContent({required this.recipe});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // Toutes les pages validées du livre pour le regroupement
    final allPages =
        ref.watch(allPagesByBookProvider(recipe.bookId ?? '')).value ??
        [recipe];

    final group = _consecutiveGroup(allPages, recipe);
    final pageIcon = _iconForPageType(recipe.pageType);
    final pageLabel = _labelForPageType(recipe.pageType);
    final isMulti = group.length > 1;

    final pageRange = isMulti
        ? 'p.${group.first.pageNumber}–${group.last.pageNumber}'
        : (recipe.pageNumber != null ? 'p.${recipe.pageNumber}' : null);

    // Images dédupliquées de tout le groupe
    final allImages = <String>{};
    for (final p in group) {
      allImages.addAll(p.imageUrls);
    }
    final images = allImages.toList();

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
                Icon(pageIcon, size: 18, color: theme.colorScheme.primary),
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
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Chip(
              avatar: Icon(pageIcon, size: 16),
              label: Text(pageLabel),
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(height: 16),

            // Pages jointes
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

            // Images extraites
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
      ),
    );
  }
}

// ── Page text ──────────────────────────────────────────────────────────────────

class _PageTextContent extends StatelessWidget {
  final Recipe page;
  const _PageTextContent({required this.page});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final raw = (page.draftCooklang?.isNotEmpty == true
            ? page.draftCooklang!
            : page.rawCooklang)
        .trim();

    // Supprimer les lignes de métadonnées CookLang (>> clé: valeur)
    final cleaned = raw
        .split('\n')
        .where((l) => !RegExp(r'^\s*>>').hasMatch(l))
        .join('\n')
        .trim();

    if (cleaned.isEmpty) {
      return Text(
        'Aucun contenu extrait.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    // Découper en paragraphes (séparateur : une ou plusieurs lignes vides)
    final paragraphs = cleaned
        .split(RegExp(r'\n[ \t]*\n'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < paragraphs.length; i++) ...[
          if (i > 0) const SizedBox(height: 16),
          _renderParagraph(paragraphs[i], theme),
        ],
      ],
    );
  }

  /// Détecte si un paragraphe est une liste (chaque ligne commence par un
  /// numéro, un tiret ou une puce) et l'affiche avec indentation. Sinon
  /// affiche le texte tel quel en respectant les sauts de ligne internes.
  Widget _renderParagraph(String paragraph, ThemeData theme) {
    final lines = paragraph.split('\n');

    // Annotation d'image/schéma entre crochets → italique discret
    if (lines.length == 1 &&
        paragraph.trimLeft().startsWith('[') &&
        paragraph.trimRight().endsWith(']')) {
      return Text(
        paragraph,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    // Liste : chaque ligne commence par un marqueur (1. 2. - • *)
    final listPattern = RegExp(r'^(\d+[.)]\s+|[-•*]\s+)');
    final isList = lines.every((l) => listPattern.hasMatch(l.trimLeft()));

    if (isList) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines) _renderListItem(line.trim(), theme),
        ],
      );
    }

    // Texte courant – on préserve les sauts de ligne simples
    return SelectableText(
      paragraph,
      style: theme.textTheme.bodyMedium?.copyWith(height: 1.75),
    );
  }

  Widget _renderListItem(String line, ThemeData theme) {
    final numMatch = RegExp(r'^(\d+[.)]\s+)(.*)$').firstMatch(line);
    if (numMatch != null) {
      final marker = numMatch.group(1)!.trim();
      final content = numMatch.group(2)!;
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 28,
              child: Text(
                marker,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                  height: 1.75,
                ),
              ),
            ),
            Expanded(
              child: SelectableText(
                content,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.75),
              ),
            ),
          ],
        ),
      );
    }

    // Tiret ou puce
    final bulletMatch = RegExp(r'^([-•*]\s+)(.*)$').firstMatch(line);
    if (bulletMatch != null) {
      final content = bulletMatch.group(2)!;
      return Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 8),
              child: Icon(
                Icons.circle,
                size: 6,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Expanded(
              child: SelectableText(
                content,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.75),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: SelectableText(
        line,
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.75),
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
      onTap: () => _showFullscreen(context),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
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
                child: CachedNetworkImage(imageUrl: url),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
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
