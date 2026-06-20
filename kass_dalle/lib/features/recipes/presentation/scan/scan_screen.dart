import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/presentation/image_enhancer_screen.dart';
import '../../../../core/utils/platform_utils.dart';
import '../recipe_providers.dart';
import '../../../books/presentation/book_providers.dart';
import '../../data/scan_upload_service.dart';
import '../../../processing/presentation/processing_providers.dart';
import '../../../../core/utils/context_extensions.dart';

class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  String? _selectedBookId;
  String? _selectedBookTitre;
  ScanIntent _selectedIntent = ScanIntent.recipe;
  bool _seededFromQuery = false;
  bool _autoStartedCamera = false;

  // Enhancer inline (sans Navigator, évite la redirection go_router web)
  Uint8List? _enhancerBytes;
  String? _enhancerFilename;
  bool _showingEnhancer = false;

  @override
  void dispose() {
    // Réinitialise l'état si on quitte sans finir.
    // Important: ne pas différer cet appel, sinon ref devient invalide après dispose.
    ref.read(scanUploadProvider.notifier).reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = GoRouterState.of(context).uri.queryParameters;
    if (!_seededFromQuery) {
      _seededFromQuery = true;
      _selectedBookId = query['bookId'];
      _selectedBookTitre = query['bookTitre'];
      final mode = query['mode'];
      if (mode == 'book-cover') {
        _selectedIntent = ScanIntent.bookCover;
      } else if (mode == 'book-document') {
        _selectedIntent = ScanIntent.bookDocument;
      } else {
        _selectedIntent = ScanIntent.recipe;
      }
    }
    final lockBook = (_selectedBookId ?? '').isNotEmpty;

    final scanState = ref.watch(scanUploadProvider);
    final booksAsync = ref.watch(myBooksProvider);
    final activeJobsCount = ref.watch(activeProcessingJobsCountProvider);

    // Auto-démarrage caméra uniquement sur mobile natif (pas web : le navigateur
    // bloque les file-pickers non initiés par un geste utilisateur).
    if (_selectedIntent != ScanIntent.bookDocument &&
        PlatformUtils.isMobile &&
        !_autoStartedCamera &&
        scanState.status == ScanStatus.idle) {
      _autoStartedCamera = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final notifier = ref.read(scanUploadProvider.notifier);
        if (_selectedIntent == ScanIntent.bookCover) {
          notifier.pickFromCameraAndQueueBookCover();
        } else {
          notifier.pickFromCameraAndQueueRecipe(
            bookId: _selectedBookId,
            bookTitre: _selectedBookTitre,
          );
        }
      });
    }

    // Navigation automatique vers les brouillons une fois terminé
    ref.listen<ScanState>(scanUploadProvider, (prev, next) {
      // Étape d'amélioration de la couverture
      if (next.status == ScanStatus.pendingEnhancement &&
          next.pendingImageBytes != null &&
          prev?.status != ScanStatus.pendingEnhancement) {
        Future.microtask(() {
          if (!mounted) return;
          setState(() {
            _enhancerBytes = next.pendingImageBytes!;
            _enhancerFilename = next.pendingImageFilename ?? 'cover.jpg';
            _showingEnhancer = true;
          });
        });
      }
      if (next.status == ScanStatus.done && next.successMessage != null) {
        final messenger = ScaffoldMessenger.of(context);
        messenger.clearSnackBars();
        messenger.showSnackBar(
          SnackBar(
            content: Text(next.successMessage!),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    });

    final scaffold = Scaffold(
      appBar: AppBar(title: const Text('Importer un scan')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Illustration compacte ──────────────────────────────────
                const SizedBox(height: 8),
                Icon(
                  Icons.photo_camera_outlined,
                  size: 36,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 8),
                Text(
                  _subtitleForIntent(_selectedIntent),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),

                // ── Choix du livre ─────────────────────────────────────────
                if (_selectedIntent != ScanIntent.bookCover)
                  booksAsync.when(
                    loading: () => const SizedBox.shrink(),
                    error: (_, _) => const SizedBox.shrink(),
                    data: (books) => books.isEmpty
                        ? const SizedBox.shrink()
                        : DropdownButtonFormField<String>(
                            decoration: InputDecoration(
                              labelText:
                                  _selectedIntent == ScanIntent.bookDocument
                                  ? 'Livre cible (recommandé)'
                                  : 'Assigner à un livre (optionnel)',
                              prefixIcon: Icon(Icons.menu_book_outlined),
                            ),
                            initialValue: _selectedBookId,
                            items: [
                              const DropdownMenuItem<String>(
                                value: null,
                                child: Text('Aucun livre'),
                              ),
                              ...books.map(
                                (b) => DropdownMenuItem(
                                  value: b.id,
                                  child: Text(b.titre),
                                ),
                              ),
                            ],
                            onChanged: scanState.isRunning
                                ? null
                                : lockBook
                                ? null
                                : (val) {
                                    setState(() {
                                      _selectedBookId = val;
                                      _selectedBookTitre = val == null
                                          ? null
                                          : books
                                                .firstWhere((b) => b.id == val)
                                                .titre;
                                    });
                                  },
                          ),
                  ),
                if (lockBook && _selectedIntent != ScanIntent.bookCover)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Ce scan sera ajoute au livre: ${_selectedBookTitre ?? _selectedBookId}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 24),

                // ── Bouton principal ───────────────────────────────────────
                if (scanState.status == ScanStatus.idle ||
                    scanState.status == ScanStatus.done ||
                    scanState.status == ScanStatus.error) ...[
                  if (PlatformUtils.hasCameraSupport) ...[
                    FilledButton.icon(
                      onPressed: () {
                        if (scanState.status != ScanStatus.idle) {
                          ref.read(scanUploadProvider.notifier).reset();
                        }
                        switch (_selectedIntent) {
                          case ScanIntent.recipe:
                            ref
                                .read(scanUploadProvider.notifier)
                                .pickFromCameraAndQueueRecipe(
                                  bookId: _selectedBookId,
                                  bookTitre: _selectedBookTitre,
                                );
                            break;
                          case ScanIntent.bookCover:
                            ref
                                .read(scanUploadProvider.notifier)
                                .pickFromCameraAndQueueBookCover();
                            break;
                          case ScanIntent.bookDocument:
                            context.showSnackBar(
                              'Utilisez l\'import fichier pour un livre complet.',
                            );
                            break;
                        }
                      },
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: Text(
                        _selectedIntent == ScanIntent.bookCover
                            ? 'Photographier la couverture'
                            : 'Prendre une photo',
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  FilledButton.tonalIcon(
                    onPressed: () {
                      if (scanState.status != ScanStatus.idle) {
                        ref.read(scanUploadProvider.notifier).reset();
                      }
                      final notifier = ref.read(scanUploadProvider.notifier);
                      switch (_selectedIntent) {
                        case ScanIntent.recipe:
                          notifier.pickAndQueueRecipe(
                            bookId: _selectedBookId,
                            bookTitre: _selectedBookTitre,
                          );
                          break;
                        case ScanIntent.bookCover:
                          notifier.pickAndQueueBookCover();
                          break;
                        case ScanIntent.bookDocument:
                          notifier.pickAndQueueBookDocument(
                            bookId: _selectedBookId,
                            bookTitre: _selectedBookTitre,
                          );
                          break;
                      }
                    },
                    icon: const Icon(Icons.upload_file),
                    label: Text(
                      _buttonLabel(scanState.status, _selectedIntent),
                    ),
                  ),
                ],

                // ── Progression ────────────────────────────────────────────
                if (scanState.isRunning) ...[_ProgressCard(state: scanState)],

                // ── Pages en attente (multi-page) ──────────────────────────
                if (scanState.status == ScanStatus.pendingFiles) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Pages à analyser (${scanState.pendingPageNames.length})',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  ...scanState.pendingPageNames.asMap().entries.map(
                    (e) => Card(
                      child: ListTile(
                        leading: CircleAvatar(child: Text('${e.key + 1}')),
                        title: Text(e.value, overflow: TextOverflow.ellipsis),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Barre d'actions compacte : tout visible d'un coup
                  Row(
                    children: [
                      if (PlatformUtils.hasCameraSupport)
                        Expanded(
                          child: IconButton.outlined(
                            tooltip: 'Ajouter une page (photo)',
                            onPressed: () => ref
                                .read(scanUploadProvider.notifier)
                                .addPageFromCamera(),
                            icon: const Icon(Icons.add_a_photo_outlined),
                          ),
                        ),
                      if (PlatformUtils.hasCameraSupport)
                        const SizedBox(width: 8),
                      Expanded(
                        child: IconButton.outlined(
                          tooltip: 'Ajouter une page (fichier)',
                          onPressed: () =>
                              ref.read(scanUploadProvider.notifier).addPage(),
                          icon: const Icon(Icons.upload_file_outlined),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: FilledButton.icon(
                          onPressed: () => ref
                              .read(scanUploadProvider.notifier)
                              .processPages(
                                bookId: _selectedBookId,
                                bookTitre: _selectedBookTitre,
                              ),
                          icon: const Icon(Icons.auto_fix_high_outlined),
                          label: Text(
                            'Analyser (${scanState.pendingPageNames.length})',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () =>
                          ref.read(scanUploadProvider.notifier).reset(),
                      child: const Text('Annuler'),
                    ),
                  ),
                ],

                // ── Erreur ─────────────────────────────────────────────────
                if (scanState.status == ScanStatus.error &&
                    scanState.errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: Theme.of(
                              context,
                            ).colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              scanState.errorMessage!,
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                // ── Succès ─────────────────────────────────────────────────
                if (scanState.status == ScanStatus.done) ...[
                  const SizedBox(height: 16),
                  Card(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            color: Theme.of(
                              context,
                            ).colorScheme.onPrimaryContainer,
                            size: 32,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Traitement en file d\'attente',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: () {
                              ref.read(scanUploadProvider.notifier).reset();
                              context.go('/processing');
                            },
                            icon: const Icon(Icons.list_alt_outlined),
                            label: const Text('Voir les traitements'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                if (activeJobsCount > 0) ...[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () => context.go('/processing'),
                    icon: const Icon(Icons.hourglass_top_outlined),
                    label: Text('$activeJobsCount traitement(s) en cours'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    if (_showingEnhancer && _enhancerBytes != null) {
      return Stack(
        children: [
          scaffold,
          Positioned.fill(
            child: ImageEnhancerScreen(
              imageBytes: _enhancerBytes!,
              title: 'Améliorer la couverture',
              onResult: (result) async {
                if (result == null) {
                  // Annulation : ferme immédiatement
                  setState(() => _showingEnhancer = false);
                  ref.read(scanUploadProvider.notifier).cancelEnhancement();
                  return;
                }
                // Upload + création du job en gardant le spinner visible
                try {
                  await ref
                      .read(scanUploadProvider.notifier)
                      .confirmEnhancedCover(result, _enhancerFilename!);
                } finally {
                  // Ferme l'enhancer une fois le job créé (ou en cas d'erreur)
                  if (mounted) setState(() => _showingEnhancer = false);
                }
              },
            ),
          ),
        ],
      );
    }
    return scaffold;
  }

  // ignore: unused_element
  String _titleForIntent(ScanIntent intent) => switch (intent) {
    ScanIntent.recipe => 'Importer des recettes',
    ScanIntent.bookCover => 'Creer un livre depuis sa couverture',
    ScanIntent.bookDocument => 'Importer un livre complet',
  };

  String _subtitleForIntent(ScanIntent intent) => switch (intent) {
    ScanIntent.recipe =>
      'Selectionnez un PDF, DOCX ou une image. Gemini extrait les recettes en brouillons.',
    ScanIntent.bookCover =>
      'Photographiez la page de garde pour creer un livre. La camera se lance automatiquement sur mobile.',
    ScanIntent.bookDocument =>
      'Importez un PDF ou DOCX de livre pour extraire les recettes et les rattacher au livre choisi.',
  };

  String _buttonLabel(ScanStatus status, ScanIntent intent) {
    if (status == ScanStatus.error || status == ScanStatus.done) {
      return 'Importer un autre fichier';
    }
    return switch (intent) {
      ScanIntent.recipe => 'Choisir un fichier (PDF, DOCX, image)',
      ScanIntent.bookCover => 'Choisir une couverture (image ou PDF)',
      ScanIntent.bookDocument => 'Choisir un livre (PDF, DOCX, image)',
    };
  }
}

class _ProgressCard extends StatelessWidget {
  final ScanState state;
  const _ProgressCard({required this.state});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.filename != null)
              Text(
                state.filename!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (state.status == ScanStatus.processing)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                const SizedBox(width: 12),
                Text(state.statusLabel),
              ],
            ),
            if (state.status == ScanStatus.uploading) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: state.uploadProgress),
              const SizedBox(height: 4),
              Text(
                '${(state.uploadProgress * 100).toInt()}%',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ] else if (state.status == ScanStatus.processing ||
                state.status == ScanStatus.scanning) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
          ],
        ),
      ),
    );
  }
}
