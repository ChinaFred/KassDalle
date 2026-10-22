import 'dart:typed_data';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../auth/presentation/not_owner_scaffold.dart';
import '../../../core/presentation/leave_guard.dart';
import '../../../core/router/app_router.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/widgets/error_message.dart';
import '../../moderation/data/image_moderation_service.dart';
import '../../recipes/presentation/recipe_providers.dart';
import '../domain/book.dart';
import 'book_providers.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/presentation/image_action_card.dart';
import '../../../core/presentation/stylus_pad_text_field.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/services/photo_capture_service.dart';

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

  /// Le livre est-il réservé à son créateur ?
  bool _isPrivate = false;

  /// Le livre à modifier, lu une seule fois : créé dans `build`, le futur
  /// relisait le livre à chaque reconstruction.
  Future<Book?>? _bookFuture;

  /// Les champs tels qu'ouverts — vides en création, ceux du livre en
  /// modification. Ce qui en diffère au moment de partir est une saisie non
  /// enregistrée. `null` tant que le livre à modifier n'est pas lu.
  Map<String, String>? _openedSnapshot;

  /// Vrai une fois enregistré, ou l'abandon accepté : quitter ne perd plus
  /// rien.
  bool _saved = false;

  // Garde de sortie : la barre de navigation et le menu latéral appellent
  // `context.go`, que `PopScope` ne voit pas (voir `leave_guard.dart`).
  late final LeaveGuardNotifier _leaveGuardNotifier;
  late final LeaveGuard _leaveGuard = _confirmLeave;

  @override
  void initState() {
    super.initState();
    _leaveGuardNotifier = ref.read(leaveGuardProvider.notifier);
    // Après le rendu : un provider ne se modifie pas pendant la construction.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _leaveGuardNotifier.set(_leaveGuard);
    });
    final bookId = widget.bookId;
    if (bookId != null) {
      _bookFuture = _loadBook(bookId);
    } else {
      _openedSnapshot = _currentSnapshot();
    }
  }

  /// Lit le livre à modifier. Une lecture en échec est remontée, puis rendue
  /// au `FutureBuilder`, qui affiche l'erreur et « Réessayer ».
  Future<Book?> _loadBook(String bookId) async {
    try {
      return await ref.read(bookRepositoryProvider).getBook(bookId);
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'bookFormScreen.loadBook',
        error: e,
        stackTrace: stackTrace,
        context: {'book_id': bookId},
      );
      rethrow;
    }
  }

  /// Les champs du formulaire, sous une forme comparable.
  Map<String, String> _currentSnapshot() => {
    'titre': _titreCtrl.text,
    'sous_titre': _sousTitreCtrl.text,
    'editeur': _editeurCtrl.text,
    'serie': _serieCtrl.text,
    'auteur': _auteurCtrl.text,
    'annee': _anneeCtrl.text,
    'isbn': _isbnCtrl.text,
    'description': _descriptionCtrl.text,
    'tags': _tagsCtrl.text,
    'couverture': _coverCtrl.text,
    'langue': _langue,
    'prive': '$_isPrivate',
  };

  bool get _dirty {
    final opened = _openedSnapshot;
    if (_saved || opened == null) return false;
    return _localCoverBytes != null || !mapEquals(_currentSnapshot(), opened);
  }

  /// Vrai quand l'écran peut être quitté : rien à perdre, ou l'utilisateur
  /// accepte d'abandonner sa saisie.
  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quitter sans enregistrer ?'),
        content: Text(
          widget.bookId == null
              ? 'Ce livre ne sera pas créé.'
              : 'Les modifications de ce livre seront perdues.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Rester'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Quitter'),
          ),
        ],
      ),
    );
    return leave == true;
  }

  Future<void> _leaveAfterConfirmation() async {
    if (!await _confirmLeave() || !mounted) return;
    _saved = true; // la question est posée : le retour suivant passe
    Navigator.of(context).pop();
  }

  // Couverture sélectionnée localement (avant upload)
  Uint8List? _localCoverBytes;
  bool _uploadingCover = false;

  @override
  void dispose() {
    // Différé : un provider ne se modifie pas pendant le démontage de l'arbre.
    final notifier = _leaveGuardNotifier;
    final guard = _leaveGuard;
    Future.microtask(() => notifier.clearIf(guard));
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
    _isPrivate = book.isPrivate;
    _initialized = true;
    _openedSnapshot = _currentSnapshot();
  }

  /// La couverture vient d'être enregistrée à part : elle n'est plus une
  /// modification en attente.
  void _coverSaved(String url) {
    final opened = _openedSnapshot;
    if (opened != null) _openedSnapshot = {...opened, 'couverture': url};
  }

  Future<void> _pickCover(ImageSource source, {String? bookId}) async {
    // Sur mobile, la caméra est le scanner du système : la couverture revient
    // cadrée et redressée, comme à l'import.
    final Uint8List bytes;
    try {
      final photo = await PhotoCaptureService().pick(
        source: source,
        imageQuality: 85,
        maxWidth: 1200,
      );
      if (photo == null) return;
      bytes = photo.bytes;
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'bookFormScreen.pickCover',
        error: e,
        stackTrace: stackTrace,
        context: {'etape': 'capture', 'source': source.name},
      );
      if (mounted) {
        context.showFailureSnackBar('Photo non prise', e);
      }
      return;
    }
    if (!mounted) return;
    if (bookId != null) {
      // Upload immédiat si on édite un livre existant
      setState(() => _uploadingCover = true);
      try {
        final url = await _uploadCoverFile(bytes, bookId);
        await ref
            .read(bookRepositoryProvider)
            .updateBook(
              (await ref.read(bookRepositoryProvider).getBook(bookId))!
                  .copyWith(urlCouverture: url, updatedAt: DateTime.now()),
            );
        _coverSaved(url);
        setState(() {
          _coverCtrl.text = url;
          _localCoverBytes = null;
        });
        ref.invalidate(myBooksProvider);
        ref.invalidate(accessibleBooksProvider);
      } on ImageNotPublished catch (e) {
        // Couverture retenue ou refusée par la modération : pas une panne,
        // rien à rapporter.
        if (mounted) {
          context.showErrorSnackBar(
            memberImageRefusal(e, what: 'Couverture non enregistrée'),
          );
        }
      } catch (e, stackTrace) {
        reportUnexpectedError(
          feature: 'bookFormScreen.pickCover',
          error: e,
          stackTrace: stackTrace,
        );
        if (mounted) {
          context.showErrorSnackBar(
            photoFailureMessage(
              'Couverture non enregistrée',
              e,
              canEdit: ref.read(canEditProvider),
            ),
          );
        }
      } finally {
        if (mounted) setState(() => _uploadingCover = false);
      }
    } else {
      // Nouveau livre : stocker localement, uploader à la création
      setState(() => _localCoverBytes = bytes);
    }
  }

  Future<String> _uploadCoverFile(Uint8List bytes, String bookId) {
    return ref.read(bookRepositoryProvider).uploadCover(bookId, bytes);
  }

  Future<void> _replaceCoverBytes(Uint8List bytes, {String? bookId}) async {
    if (bookId == null) {
      setState(() => _localCoverBytes = bytes);
      return;
    }

    setState(() => _uploadingCover = true);
    try {
      final url = await _uploadCoverFile(bytes, bookId);
      await ref
          .read(bookRepositoryProvider)
          .updateBook(
            (await ref.read(bookRepositoryProvider).getBook(bookId))!.copyWith(
              urlCouverture: url,
              updatedAt: DateTime.now(),
            ),
          );
      _coverSaved(url);
      setState(() {
        _coverCtrl.text = url;
        _localCoverBytes = null;
      });
      ref.invalidate(myBooksProvider);
      ref.invalidate(accessibleBooksProvider);
    } on ImageNotPublished catch (e) {
      // Couverture retenue ou refusée par la modération : pas une panne, rien
      // à rapporter.
      if (mounted) {
        context.showErrorSnackBar(
          memberImageRefusal(e, what: 'Couverture non enregistrée'),
        );
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'bookFormScreen.replaceCoverBytes',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar(
          photoFailureMessage(
            'Couverture non enregistrée',
            e,
            canEdit: ref.read(canEditProvider),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingCover = false);
    }
  }

  /// Prévient de ce qu'un basculement de confidentialité emporte, et rend
  /// `false` si l'utilisateur renonce.
  ///
  /// Un livre bascule d'une case cochée ; ses recettes suivent en silence. Sans
  /// ce décompte, retirer trente recettes à quatre personnes — ou les leur
  /// rendre — est un geste dont on ne mesure la portée qu'après coup.
  Future<bool> _confirmPrivacyChange(Book existing) async {
    if (_isPrivate == existing.isPrivate) return true;

    int recipeCount;
    try {
      final viewer = ref.read(recipeViewerProvider);
      if (viewer == null) throw StateError('Compte non chargé');
      recipeCount = await ref
          .read(recipeRepositoryProvider)
          .countInBook(existing.id, viewer);
    } catch (e, stackTrace) {
      // Le décompte échoue : on demande quand même, sans le chiffre. Renoncer
      // au basculement parce qu'on n'a pas su compter serait pire.
      reportUnexpectedError(
        feature: 'bookFormScreen.countRecipes',
        error: e,
        stackTrace: stackTrace,
      );
      recipeCount = -1;
    }
    if (!mounted) return false;

    final quoi = switch (recipeCount) {
      -1 => 'Les recettes de ce livre',
      0 => null,
      1 => 'La recette de ce livre',
      _ => 'Les $recipeCount recettes de ce livre',
    };
    final message = quoi == null
        ? (_isPrivate
              ? 'Ce livre ne sera plus visible par les membres de vos groupes.'
              : 'Ce livre redeviendra visible par les membres de vos groupes.')
        : (_isPrivate
              ? '$quoi disparaîtront de la bibliothèque, de la recherche et du '
                    'planning des membres de vos groupes.'
              : '$quoi redeviendront visibles par les membres de vos groupes, '
                    'dans la bibliothèque, la recherche et le planning.');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          _isPrivate ? 'Rendre ce livre privé ?' : 'Repartager ce livre ?',
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_isPrivate ? 'Rendre privé' : 'Repartager'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _save({Book? existing}) async {
    if (!_formKey.currentState!.validate()) return;
    final appUser = ref.read(appUserProvider).value;
    if (appUser == null) return;

    if (existing != null && !await _confirmPrivacyChange(existing)) return;
    if (!mounted) return;

    setState(() => _saving = true);
    // Message de l'échec de la couverture à la création, si elle n'est pas
    // partie : il remplace le succès.
    String? coverFailure;
    try {
      // ── Livres système : titre + description ────────────────────────────
      if (existing?.isSystemBook == true) {
        final updated = existing!.copyWith(
          titre: _titreCtrl.text.trim(),
          description: _descriptionCtrl.text.trim().isEmpty
              ? null
              : _descriptionCtrl.text.trim(),
          isPrivate: _isPrivate,
          updatedAt: DateTime.now(),
        );
        await ref.read(bookRepositoryProvider).updateBook(updated);
        ref.invalidate(myBooksProvider);
        ref.invalidate(accessibleBooksProvider);
        _saved = true;
        if (mounted) {
          context.showSuccessSnackBar('Livre mis à jour');
          context.pop();
        }
        return;
      }

      // ── Autres livres ───────────────────────────────────────────────────────
      final annee = int.tryParse(_anneeCtrl.text.trim());
      // Un tag réservé (`__…`) est refusé par le validateur du champ.
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
          isPrivate: _isPrivate,
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
          } on ImageNotPublished catch (error) {
            // Retenue ou refusée par la modération : pas une panne, rien à
            // rapporter. Le livre existe : le message le dit avant l'échec.
            coverFailure =
                'Livre ajouté. '
                '${memberImageRefusal(error, what: 'Couverture non enregistrée')}';
          } catch (error, stackTrace) {
            reportUnexpectedError(
              feature: 'bookFormScreen.save',
              error: error,
              stackTrace: stackTrace,
              context: {'etape': 'couverture', 'book_id': newId},
            );
            coverFailure =
                'Livre ajouté. '
                '${photoFailureMessage('Couverture non enregistrée', error, canEdit: appUser.canEdit)}';
          }
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
          reviewStatus: BookReviewStatus.validated,
          isPrivate: _isPrivate,
          updatedAt: DateTime.now(),
        );
        await ref.read(bookRepositoryProvider).updateBook(updated);
      }

      ref.invalidate(myBooksProvider);
      ref.invalidate(accessibleBooksProvider);

      _saved = true;
      if (mounted) {
        // Une couverture perdue à la création n'est pas un succès : le livre
        // est créé, le message le dit, en erreur.
        if (coverFailure != null) {
          context.showErrorSnackBar(coverFailure);
        } else {
          context.showSuccessSnackBar(
            existing == null ? 'Livre ajouté manuellement' : 'Livre mis à jour',
          );
        }
        context.pop();
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'bookFormScreen.save',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showFailureSnackBar(
          existing == null ? 'Livre non ajouté' : 'Livre non mis à jour',
          e,
        );
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

    // Lu ici, dans `build`, pour que la garde suive le compte.
    final userAsync = ref.watch(appUserProvider);
    Widget? gateFor(Book existing) => ownershipGate(
      ref: ref,
      userAsync: userAsync,
      title: 'Modifier le livre',
      message: 'Seul le créateur peut modifier ce livre.',
      fallbackLocation: '/',
      canModify: (u) => u.canModifyBook(existing.createdBy),
    );
    return FutureBuilder<Book?>(
      future: _bookFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Scaffold(
            appBar: AppBar(title: const Text('Modifier le livre')),
            body: const AppLoadingState(),
          );
        }
        if (snap.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('Modifier le livre')),
            body: AppErrorState(
              error: snap.error,
              onRetry: () => setState(() => _bookFuture = _loadBook(bookId)),
            ),
          );
        }
        final existing = snap.data;
        if (existing == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Modifier le livre')),
            body: AppEmptyState(
              icon: Icons.library_books_outlined,
              title: 'Livre introuvable',
              message: 'Ce livre a peut-être été supprimé.',
              action: FilledButton.icon(
                onPressed: () => context.go(AppRoutes.books),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Retour à la bibliothèque'),
              ),
            ),
          );
        }
        final gate = gateFor(existing);
        if (gate != null) return gate;
        _initFromBook(existing);
        return _buildScaffold(existing: existing);
      },
    );
  }

  Widget _buildScaffold({Book? existing}) {
    return PopScope(
      // Toujours retenu : la question ne se pose que s'il y a quelque chose à
      // perdre, ce que seul le moment du départ sait (les champs de texte ne
      // reconstruisent pas l'écran).
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _leaveAfterConfirmation();
      },
      child: _buildForm(existing: existing),
    );
  }

  Scaffold _buildForm({Book? existing}) {
    final isSystem = existing?.isSystemBook == true;

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
            // ── Description (système + non-système) ──────────────────────────
            const SizedBox(height: 12),
            StylusPadTextField(
              controller: _descriptionCtrl,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Description',
                prefixIcon: Icon(Icons.description_outlined),
                alignLabelWithHint: true,
              ),
            ),
            // ── Confidentialité (tous les livres sauf le refuge) ─────────────
            const SizedBox(height: 12),
            _buildPrivacyTile(existing),
            // ── Champs complets (non-système uniquement) ──────────────────────
            if (!isSystem) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _sousTitreCtrl,
                decoration: const InputDecoration(
                  labelText: 'Sous-titre / Légende',
                  prefixIcon: Icon(Icons.short_text),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _editeurCtrl,
                decoration: const InputDecoration(
                  labelText: 'Éditeur',
                  prefixIcon: Icon(Icons.business_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _serieCtrl,
                decoration: const InputDecoration(
                  labelText: 'Série',
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
                    ? 'L’auteur est obligatoire'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _anneeCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Année',
                  prefixIcon: Icon(Icons.calendar_today_outlined),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return null;
                  return int.tryParse(v.trim()) == null
                      ? 'Année invalide'
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
                  DropdownMenuItem(value: 'fr', child: Text('Français')),
                  DropdownMenuItem(value: 'en', child: Text('Anglais')),
                  DropdownMenuItem(value: 'nl', child: Text('Néerlandais')),
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
                  labelText: 'Tags (séparés par des virgules)',
                  prefixIcon: Icon(Icons.sell_outlined),
                ),
                validator: Book.reservedTagError,
              ),
              if (existing?.sourceFileName != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Source IA : ${existing!.sourceFileName}',
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

  /// L'interrupteur de confidentialité.
  ///
  /// Verrouillé sur « Mes Recettes Secrètes », et sur lui seul. Ce livre est le
  /// refuge : s'il peut redevenir public d'une case décochée, il cesse d'en
  /// être un. Les autres livres système basculent librement — « Mes recettes
  /// du web » naît privé, et son propriétaire peut le partager.
  Widget _buildPrivacyTile(Book? existing) {
    final locked = existing?.isSecretesBook == true;
    final colors = Theme.of(context).colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      child: SwitchListTile(
        value: locked ? true : _isPrivate,
        onChanged: (_saving || locked)
            ? null
            : (value) => setState(() => _isPrivate = value),
        secondary: Icon(
          (locked || _isPrivate) ? Icons.lock_outline : Icons.group_outlined,
          color: (locked || _isPrivate)
              ? colors.primary
              : colors.onSurfaceVariant,
        ),
        title: const Text('Livre privé'),
        subtitle: Text(
          locked
              ? 'Ce livre est toujours privé : c’est là que vivent les recettes '
                    'que vous ne partagez pas.'
              : (_isPrivate
                    ? 'Vous êtes le seul à voir ce livre et ses recettes.'
                    : 'Les membres de vos groupes voient ce livre et ses recettes.'),
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
            child: ImageActionCard(
              imageUrl: currentUrl,
              imageBytes: _localCoverBytes,
              assetPath: existing?.defaultCoverAsset,
              aspectRatio: 3 / 4,
              showBusyOverlay: _uploadingCover,
              showActions: currentUrl != null || _localCoverBytes != null,
              onEdit: (currentUrl != null || _localCoverBytes != null)
                  ? (mode, bytes) =>
                        _replaceCoverBytes(bytes, bookId: existing?.id)
                  : null,
              onDelete: (currentUrl != null || _localCoverBytes != null)
                  ? () {
                      setState(() {
                        _coverCtrl.clear();
                        _localCoverBytes = null;
                      });
                    }
                  : null,
              emptyLabel: existing?.defaultCoverAsset != null
                  ? 'Couverture par défaut'
                  : 'Aucune couverture',
              onTap: _uploadingCover || _saving
                  ? null
                  : () => _pickCover(ImageSource.gallery, bookId: existing?.id),
              cropTooltip: 'Recadrer',
              colorTooltip: 'Couleur',
              deleteTooltip: 'Retirer la couverture',
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
