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
        Future.microtask(() async {
          if (!mounted) return;
          // ignore: use_build_context_synchronously
          await _showImageEnhancer(
            context,
            ref,
            next.pendingImageBytes!,
            next.pendingImageFilename ?? 'cover.jpg',
          );
        });
      }
      if (next.status == ScanStatus.done && next.successMessage != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.successMessage!),
            showCloseIcon: true,
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: 'Importer',
              onPressed: () {
                ref.read(scanUploadProvider.notifier).reset();
                context.go('/scan');
              },
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Importer un scan')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Illustration ───────────────────────────────────────────
                const SizedBox(height: 16),
                Icon(
                  Icons.document_scanner_outlined,
                  size: 72,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  _titleForIntent(_selectedIntent),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  _subtitleForIntent(_selectedIntent),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 32),

                // ── Choix du livre ─────────────────────────────────────────
                if (_selectedIntent != ScanIntent.bookCover)
                  booksAsync.when(
                    loading: () => const SizedBox.shrink(),
                    error: (_, __) => const SizedBox.shrink(),
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
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Utilisez l\'import fichier pour un livre complet.',
                                ),
                              ),
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
  }

  String _titleForIntent(ScanIntent intent) => switch (intent) {
    ScanIntent.recipe => 'Importer des recettes',
    ScanIntent.bookCover => 'Creer un livre depuis sa couverture',
    ScanIntent.bookDocument => 'Importer un livre complet',
  };

  /// Ouvre [ImageEnhancerScreen], puis continue ou annule selon le résultat.
  Future<void> _showImageEnhancer(
    BuildContext context,
    WidgetRef ref,
    Uint8List bytes,
    String filename,
  ) async {
    final result = await Navigator.of(context).push<Uint8List?>(
      MaterialPageRoute(
        builder: (_) => ImageEnhancerScreen(
          imageBytes: bytes,
          title: 'Améliorer la couverture',
        ),
      ),
    );

    if (!mounted) return;

    if (result == null) {
      ref.read(scanUploadProvider.notifier).cancelEnhancement();
    } else {
      ref.read(scanUploadProvider.notifier).confirmEnhancedCover(result, filename);
    }
  }


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
            ] else if (state.status == ScanStatus.processing) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
          ],
        ),
      ),
    );
  }
}
