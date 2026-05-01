import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/utils/platform_utils.dart';
import '../recipe_providers.dart';
import '../../../books/presentation/book_providers.dart';
import '../../data/scan_upload_service.dart';

class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  String? _selectedBookId;
  String? _selectedBookTitre;
  bool _seededFromQuery = false;

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
    }
    final lockBook = (_selectedBookId ?? '').isNotEmpty;

    final scanState = ref.watch(scanUploadProvider);
    final booksAsync = ref.watch(myBooksProvider);

    // Navigation automatique vers les brouillons une fois terminé
    ref.listen<ScanState>(scanUploadProvider, (prev, next) {
      if (next.status == ScanStatus.done && next.createdRecipeIds.isNotEmpty) {
        final count = next.createdRecipeIds.length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              count == 1
                  ? '1 recette ajoutée aux brouillons !'
                  : '$count recettes ajoutées aux brouillons !',
            ),
            action: SnackBarAction(
              label: 'Voir',
              onPressed: () {
                ref.read(scanUploadProvider.notifier).reset();
                context.go('/drafts');
              },
            ),
            duration: const Duration(seconds: 6),
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
                  'Importer des recettes',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Sélectionnez un fichier PDF, DOCX ou une image.\nGemini extraira automatiquement les recettes en CookLang.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 32),

                // ── Choix du livre ─────────────────────────────────────────
                booksAsync.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => const SizedBox.shrink(),
                  data: (books) => books.isEmpty
                      ? const SizedBox.shrink()
                      : DropdownButtonFormField<String>(
                          decoration: const InputDecoration(
                            labelText: 'Assigner à un livre (optionnel)',
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
                if (lockBook)
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
                  if (PlatformUtils.isMobile) ...[
                    FilledButton.icon(
                      onPressed: () {
                        if (scanState.status != ScanStatus.idle) {
                          ref.read(scanUploadProvider.notifier).reset();
                        }
                        ref
                            .read(scanUploadProvider.notifier)
                            .pickFromCameraAndProcess(
                              bookId: _selectedBookId,
                              bookTitre: _selectedBookTitre,
                            );
                      },
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Prendre une photo'),
                    ),
                    const SizedBox(height: 12),
                  ],
                  FilledButton.tonalIcon(
                    onPressed: () {
                      if (scanState.status != ScanStatus.idle) {
                        ref.read(scanUploadProvider.notifier).reset();
                      }
                      ref
                          .read(scanUploadProvider.notifier)
                          .pickAndProcess(
                            bookId: _selectedBookId,
                            bookTitre: _selectedBookTitre,
                          );
                    },
                    icon: const Icon(Icons.upload_file),
                    label: Text(
                      scanState.status == ScanStatus.error ||
                              scanState.status == ScanStatus.done
                          ? 'Importer un autre fichier'
                          : 'Choisir un fichier (PDF, DOCX, image)',
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
                            '${scanState.createdRecipeIds.length} recette(s) créée(s) en brouillon',
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
                              context.go('/drafts');
                            },
                            icon: const Icon(Icons.edit_note),
                            label: const Text('Réviser les brouillons'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
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
