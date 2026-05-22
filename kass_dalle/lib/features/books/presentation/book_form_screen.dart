import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../auth/presentation/auth_providers.dart';
import '../domain/book.dart';
import 'book_providers.dart';

class BookFormScreen extends ConsumerStatefulWidget {
  final String? bookId;
  const BookFormScreen({super.key, this.bookId});

  @override
  ConsumerState<BookFormScreen> createState() => _BookFormScreenState();
}

class _BookFormScreenState extends ConsumerState<BookFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titreCtrl = TextEditingController();
  final _sousTitreCtrl = TextEditingController();
  final _editeurCtrl = TextEditingController();
  final _serieCtrl = TextEditingController();
  final _auteurCtrl = TextEditingController();
  final _anneeCtrl = TextEditingController();
  final _isbnCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  final _tagsCtrl = TextEditingController();
  final _coverCtrl = TextEditingController(); // URL actuelle
  String _langue = 'fr';
  bool _initialized = false;
  bool _saving = false;

  // Couverture sélectionnée localement (avant upload)
  Uint8List? _localCoverBytes;
  bool _uploadingCover = false;

  @override
  void dispose() {
    _titreCtrl.dispose();
    _sousTitreCtrl.dispose();
    _editeurCtrl.dispose();
    _serieCtrl.dispose();
    _auteurCtrl.dispose();
    _anneeCtrl.dispose();
    _isbnCtrl.dispose();
    _descriptionCtrl.dispose();
    _tagsCtrl.dispose();
    _coverCtrl.dispose();
    super.dispose();
  }

  void _initFromBook(Book book) {
    if (_initialized) return;
    _titreCtrl.text = book.titre;
    _sousTitreCtrl.text = book.sousTitre ?? '';
    _editeurCtrl.text = book.editeur ?? '';
    _serieCtrl.text = book.serie ?? '';
    _auteurCtrl.text = book.auteur;
    _anneeCtrl.text = book.annee?.toString() ?? '';
    _isbnCtrl.text = book.isbn ?? '';
    _descriptionCtrl.text = book.description ?? '';
    _tagsCtrl.text = book.tags.join(', ');
    _coverCtrl.text = book.urlCouverture ?? '';
    _langue = book.langue;
    _initialized = true;
  }

  Future<void> _pickCover(ImageSource source, {String? bookId}) async {
    final picker = ImagePicker();
    final xFile = await picker.pickImage(
      source: source,
      imageQuality: 85,
      maxWidth: 1200,
    );
    if (xFile == null) return;
    if (bookId != null) {
      // Upload immédiat si on édite un livre existant
      setState(() => _uploadingCover = true);
      try {
        final bytes = await xFile.readAsBytes();
        final url = await _uploadCoverFile(bytes, bookId);
        await ref
            .read(bookRepositoryProvider)
            .updateBook(
              (await ref.read(bookRepositoryProvider).getBook(bookId))!
                  .copyWith(urlCouverture: url, updatedAt: DateTime.now()),
            );
        setState(() {
          _coverCtrl.text = url;
          _localCoverBytes = null;
        });
        ref.invalidate(myBooksProvider);
        ref.invalidate(accessibleBooksProvider);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Erreur upload : $e')));
        }
      } finally {
        if (mounted) setState(() => _uploadingCover = false);
      }
    } else {
      // Nouveau livre : stocker localement, uploader à la création
      final bytes = await xFile.readAsBytes();
      setState(() => _localCoverBytes = bytes);
    }
  }

  Future<String> _uploadCoverFile(Uint8List bytes, String bookId) async {
    final storageRef = FirebaseStorage.instance.ref('covers/$bookId/cover.jpg');
    final task = await storageRef.putData(
      bytes,
      SettableMetadata(contentType: 'image/jpeg'),
    );
    return task.ref.getDownloadURL();
  }

  Future<void> _save({Book? existing}) async {
    if (!_formKey.currentState!.validate()) return;
    final appUser = ref.read(appUserProvider).value;
    if (appUser == null) return;

    setState(() => _saving = true);
    try {
      // ── Livres système : titre + description ────────────────────────────
      if (existing?.isSystemBook == true) {
        final updated = existing!.copyWith(
          titre: _titreCtrl.text.trim(),
          description: _descriptionCtrl.text.trim().isEmpty
              ? null
              : _descriptionCtrl.text.trim(),
          updatedAt: DateTime.now(),
        );
        await ref.read(bookRepositoryProvider).updateBook(updated);
        ref.invalidate(myBooksProvider);
        ref.invalidate(accessibleBooksProvider);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Livre mis à jour')));
          context.pop();
        }
        return;
      }

      // ── Autres livres ───────────────────────────────────────────────────────
      final annee = int.tryParse(_anneeCtrl.text.trim());
      final tags = _tagsCtrl.text
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      if (existing == null) {
        final now = DateTime.now();
        final book = Book(
          id: '',
          titre: _titreCtrl.text.trim(),
          sousTitre: _sousTitreCtrl.text.trim().isEmpty
              ? null
              : _sousTitreCtrl.text.trim(),
          editeur: _editeurCtrl.text.trim().isEmpty
              ? null
              : _editeurCtrl.text.trim(),
          serie: _serieCtrl.text.trim().isEmpty ? null : _serieCtrl.text.trim(),
          auteur: _auteurCtrl.text.trim(),
          annee: annee,
          langue: _langue,
          isbn: _isbnCtrl.text.trim().isEmpty ? null : _isbnCtrl.text.trim(),
          description: _descriptionCtrl.text.trim().isEmpty
              ? null
              : _descriptionCtrl.text.trim(),
          urlCouverture: _coverCtrl.text.trim().isEmpty
              ? null
              : _coverCtrl.text.trim(),
          tags: tags,
          reviewStatus: BookReviewStatus.validated,
          createdBy: appUser.uid,
          createdAt: now,
          updatedAt: now,
        );
        final newId = await ref.read(bookRepositoryProvider).createBook(book);
        // Upload cover si sélection locale
        if (_localCoverBytes != null) {
          try {
            final url = await _uploadCoverFile(_localCoverBytes!, newId);
            await ref
                .read(bookRepositoryProvider)
                .updateBook(
                  book.copyWith(urlCouverture: url, updatedAt: DateTime.now()),
                );
          } catch (_) {}
        }
      } else {
        final updated = existing.copyWith(
          titre: _titreCtrl.text.trim(),
          sousTitre: _sousTitreCtrl.text.trim().isEmpty
              ? null
              : _sousTitreCtrl.text.trim(),
          editeur: _editeurCtrl.text.trim().isEmpty
              ? null
              : _editeurCtrl.text.trim(),
          serie: _serieCtrl.text.trim().isEmpty ? null : _serieCtrl.text.trim(),
          auteur: _auteurCtrl.text.trim(),
          annee: annee,
          langue: _langue,
          isbn: _isbnCtrl.text.trim().isEmpty ? null : _isbnCtrl.text.trim(),
          description: _descriptionCtrl.text.trim().isEmpty
              ? null
              : _descriptionCtrl.text.trim(),
          urlCouverture: _coverCtrl.text.trim().isEmpty
              ? null
              : _coverCtrl.text.trim(),
          tags: tags,
          updatedAt: DateTime.now(),
        );
        await ref.read(bookRepositoryProvider).updateBook(updated);
      }

      ref.invalidate(myBooksProvider);
      ref.invalidate(sharedBooksProvider);
      ref.invalidate(accessibleBooksProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              existing == null
                  ? 'Livre ajouté manuellement'
                  : 'Livre mis à jour',
            ),
          ),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _validateBook(Book existing) async {
    setState(() => _saving = true);
    try {
      await ref
          .read(bookRepositoryProvider)
          .updateBook(
            existing.copyWith(
              titre: _titreCtrl.text.trim(),
              sousTitre: _sousTitreCtrl.text.trim().isEmpty
                  ? null
                  : _sousTitreCtrl.text.trim(),
              editeur: _editeurCtrl.text.trim().isEmpty
                  ? null
                  : _editeurCtrl.text.trim(),
              serie: _serieCtrl.text.trim().isEmpty
                  ? null
                  : _serieCtrl.text.trim(),
              auteur: _auteurCtrl.text.trim(),
              annee: int.tryParse(_anneeCtrl.text.trim()),
              langue: _langue,
              isbn: _isbnCtrl.text.trim().isEmpty
                  ? null
                  : _isbnCtrl.text.trim(),
              description: _descriptionCtrl.text.trim().isEmpty
                  ? null
                  : _descriptionCtrl.text.trim(),
              tags: _tagsCtrl.text
                  .split(',')
                  .map((e) => e.trim())
                  .where((e) => e.isNotEmpty)
                  .toList(),
              urlCouverture: _coverCtrl.text.trim().isEmpty
                  ? null
                  : _coverCtrl.text.trim(),
              reviewStatus: BookReviewStatus.validated,
              updatedAt: DateTime.now(),
            ),
          );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Livre valide et publie dans la bibliotheque.'),
          ),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bookId = widget.bookId;
    if (bookId == null) {
      return _buildScaffold(existing: null);
    }

    return FutureBuilder<Book?>(
      future: ref.read(bookRepositoryProvider).getBook(bookId),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final existing = snap.data;
        if (existing == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Modifier le livre')),
            body: const Center(child: Text('Livre introuvable')),
          );
        }
        _initFromBook(existing);
        return _buildScaffold(existing: existing);
      },
    );
  }

  Scaffold _buildScaffold({Book? existing}) {
    final isSystem = existing?.isSystemBook == true;

    return Scaffold(
      appBar: AppBar(
        title: Text(existing == null ? 'Nouveau livre' : 'Modifier le livre'),
        actions: [
          if (!isSystem && existing?.reviewStatus == BookReviewStatus.draft)
            FilledButton.tonalIcon(
              onPressed: _saving ? null : () => _validateBook(existing!),
              icon: const Icon(Icons.verified_outlined),
              label: const Text('Valider le livre'),
            ),
          if (!isSystem && existing?.reviewStatus == BookReviewStatus.draft)
            const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _saving ? null : () => _save(existing: existing),
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: const Text('Enregistrer'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── Cover picker (toujours visible) ──────────────────────────────
            _buildCoverPicker(existing),
            const SizedBox(height: 16),
            // ── Titre (toujours visible) ──────────────────────────────────────
            TextFormField(
              controller: _titreCtrl,
              decoration: const InputDecoration(
                labelText: 'Titre du livre *',
                prefixIcon: Icon(Icons.title),
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Le titre est obligatoire'
                  : null,
            ),
            // ── Champs complets (non-système uniquement) ──────────────────────
            if (!isSystem) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _sousTitreCtrl,
                decoration: const InputDecoration(
                  labelText: 'Sous-titre / Legende',
                  prefixIcon: Icon(Icons.short_text),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _editeurCtrl,
                decoration: const InputDecoration(
                  labelText: 'Editeur',
                  prefixIcon: Icon(Icons.business_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _serieCtrl,
                decoration: const InputDecoration(
                  labelText: 'Serie',
                  prefixIcon: Icon(Icons.collections_bookmark_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _auteurCtrl,
                decoration: const InputDecoration(
                  labelText: 'Auteur *',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'L auteur est obligatoire'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _anneeCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Annee',
                  prefixIcon: Icon(Icons.calendar_today_outlined),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return null;
                  return int.tryParse(v.trim()) == null
                      ? 'Annee invalide'
                      : null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _isbnCtrl,
                decoration: const InputDecoration(
                  labelText: 'ISBN',
                  prefixIcon: Icon(Icons.pin_outlined),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _langue,
                decoration: const InputDecoration(
                  labelText: 'Langue',
                  prefixIcon: Icon(Icons.language),
                ),
                items: const [
                  DropdownMenuItem(value: 'fr', child: Text('Francais')),
                  DropdownMenuItem(value: 'en', child: Text('Anglais')),
                  DropdownMenuItem(value: 'nl', child: Text('Neerlandais')),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() => _langue = value);
                      },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _tagsCtrl,
                decoration: const InputDecoration(
                  labelText: 'Tags (separes par des virgules)',
                  prefixIcon: Icon(Icons.sell_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _descriptionCtrl,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  prefixIcon: Icon(Icons.description_outlined),
                  alignLabelWithHint: true,
                ),
              ),
              if (existing?.sourceFileName != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Source IA: ${existing!.sourceFileName}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _saving ? null : () => _save(existing: existing),
              icon: const Icon(Icons.save_outlined),
              label: Text(
                existing == null
                    ? 'Ajouter le livre manuellement'
                    : 'Enregistrer les modifications',
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Widget de sélection de couverture.
  Widget _buildCoverPicker(Book? existing) {
    final currentUrl = _coverCtrl.text.trim().isNotEmpty
        ? _coverCtrl.text.trim()
        : existing?.urlCouverture;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Aperçu
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _uploadingCover
                  ? Container(
                      height: 160,
                      color: Colors.grey.shade200,
                      child: const Center(child: CircularProgressIndicator()),
                    )
                  : _localCoverBytes != null
                  ? Image.memory(
                      _localCoverBytes!,
                      width: double.infinity,
                      fit: BoxFit.contain,
                    )
                  : currentUrl != null
                  ? CachedNetworkImage(
                      imageUrl: currentUrl,
                      width: double.infinity,
                      fit: BoxFit.contain,
                      placeholder: (_, __) => Container(
                        height: 160,
                        color: Colors.grey.shade200,
                        child: const Center(child: CircularProgressIndicator()),
                      ),
                      errorWidget: (_, __, ___) => Container(
                        height: 160,
                        color: Colors.grey.shade200,
                        child: const Icon(Icons.broken_image, size: 48),
                      ),
                    )
                  : existing?.defaultCoverAsset != null
                  ? Image.asset(
                      existing!.defaultCoverAsset!,
                      width: double.infinity,
                      fit: BoxFit.contain,
                    )
                  : Container(
                      height: 160,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.image_outlined, size: 48),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _uploadingCover || _saving
                    ? null
                    : () =>
                          _pickCover(ImageSource.camera, bookId: existing?.id),
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('Prendre une photo'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _uploadingCover || _saving
                    ? null
                    : () =>
                          _pickCover(ImageSource.gallery, bookId: existing?.id),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Galerie'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
