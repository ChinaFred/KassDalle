import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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
  final _tagsCtrl = TextEditingController();
  final _coverCtrl = TextEditingController();
  String _langue = 'fr';
  bool _initialized = false;
  bool _saving = false;

  @override
  void dispose() {
    _titreCtrl.dispose();
    _sousTitreCtrl.dispose();
    _editeurCtrl.dispose();
    _serieCtrl.dispose();
    _auteurCtrl.dispose();
    _anneeCtrl.dispose();
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
    _tagsCtrl.text = book.tags.join(', ');
    _coverCtrl.text = book.urlCouverture ?? '';
    _langue = book.langue;
    _initialized = true;
  }

  Future<void> _save({Book? existing}) async {
    if (!_formKey.currentState!.validate()) return;
    final appUser = ref.read(appUserProvider).valueOrNull;
    if (appUser == null) return;

    setState(() => _saving = true);
    try {
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
          urlCouverture: _coverCtrl.text.trim().isEmpty
              ? null
              : _coverCtrl.text.trim(),
          tags: tags,
          createdBy: appUser.uid,
          createdAt: now,
          updatedAt: now,
        );
        await ref.read(bookRepositoryProvider).createBook(book);
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
    return Scaffold(
      appBar: AppBar(
        title: Text(existing == null ? 'Nouveau livre' : 'Modifier le livre'),
        actions: [
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
                return int.tryParse(v.trim()) == null ? 'Annee invalide' : null;
              },
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
              controller: _coverCtrl,
              decoration: const InputDecoration(
                labelText: 'URL couverture (optionnel)',
                prefixIcon: Icon(Icons.image_outlined),
              ),
            ),
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
}
