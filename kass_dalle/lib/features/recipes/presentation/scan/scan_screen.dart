import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/presentation/image_enhancer_screen.dart';
import '../../../../core/services/error_reporting.dart';
import '../../../../core/utils/platform_utils.dart';
import '../recipe_providers.dart';
import '../../../books/presentation/book_providers.dart';
import '../../data/scan_upload_service.dart';
import '../../../auth/data/user_preferences_repository.dart';
import '../../../processing/presentation/processing_providers.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/theme/app_icon_size.dart';

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

  /// Extraire les illustrations : le choix de cet écran, pas celui du compte.
  ///
  /// Il part du défaut enregistré dans les préférences, se garde d'un import au
  /// suivant, et retombe sur ce défaut quand on revient sur l'écran.
  bool _importIllustrations = false;
  bool _seededIllustrations = false;
  bool _autoStartedCamera = false;
  late final ScanUploadNotifier _scanNotifier;
  bool? _wasCurrentRoute;

  /// Combien de fois l'atelier s'est ouvert depuis l'arrivée sur l'écran.
  ///
  /// Une seconde ouverture pour un seul import est une anomalie : elle veut
  /// dire que l'écran est reparti de l'image d'origine.
  int _ouverturesAtelier = 0;
  int? _dernierOctetsOuverts;

  // Enhancer inline (sans Navigator, évite la redirection go_router web)
  Uint8List? _enhancerBytes;
  String? _enhancerFilename;
  bool _showingEnhancer = false;

  @override
  void initState() {
    super.initState();
    _scanNotifier = ref.read(scanUploadProvider.notifier);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isCurrentRoute = ModalRoute.of(context)?.isCurrent ?? true;

    // Quand on arrive pour la première fois, ou quand on revient sur l'écran,
    // on repart d'un état propre pour ne pas conserver un message d'erreur.
    if (_wasCurrentRoute == null) {
      _wasCurrentRoute = isCurrentRoute;
      if (isCurrentRoute) {
        _scanNotifier.reset();
      }
      return;
    }

    if (_wasCurrentRoute == false && isCurrentRoute) {
      _scanNotifier.reset();
      _seededFromQuery = false;
      _autoStartedCamera = false;
      _showingEnhancer = false;
      _enhancerBytes = null;
      _enhancerFilename = null;
      _selectedIntent = ScanIntent.recipe;
      _selectedBookId = null;
      _selectedBookTitre = null;
      _seededIllustrations = false;
      setState(() {});
    }

    _wasCurrentRoute = isCurrentRoute;
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

    // Le défaut du compte arrive après coup : on l'applique à la première
    // lecture réussie, et plus jamais ensuite — sinon un rafraîchissement
    // écraserait le choix que l'utilisateur vient de faire.
    final preferences = ref.watch(userPreferencesProvider).value;
    if (!_seededIllustrations && preferences != null) {
      _seededIllustrations = true;
      _importIllustrations = preferences.importIllustrations;
    }

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

    // Filet : l'atelier s'ouvre aussi depuis l'ÉTAT COURANT.
    //
    // `ref.listen` ne délivre jamais la valeur en place au moment où il
    // s'enregistre. Si l'image est passée en attente d'amélioration alors que
    // cet écran n'était pas monté — un retour de caméra qui recrée l'arbre, un
    // onglet restauré — l'atelier ne s'ouvrait plus jamais. L'écran gardait son
    // indicateur, aucune erreur n'était levée, et la seule trace possible était
    // une capture d'écran.
    if (scanState.status == ScanStatus.pendingEnhancement &&
        scanState.pendingImageBytes != null &&
        !_showingEnhancer) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openEnhancer(scanState, rattrapage: true),
      );
    }

    // Navigation automatique vers les brouillons une fois terminé
    ref.listen<ScanState>(scanUploadProvider, (prev, next) {
      // Étape d'amélioration de la couverture
      if (next.status == ScanStatus.pendingEnhancement &&
          next.pendingImageBytes != null &&
          prev?.status != ScanStatus.pendingEnhancement) {
        Future.microtask(() => _openEnhancer(next, rattrapage: false));
      }
      // Sur la mise en file, et non sur le statut « terminé » : depuis que
      // l'écran reste disponible pendant l'envoi, un import peut aboutir alors
      // que l'écran prépare déjà le suivant — et le statut, lui, n'a pas
      // bougé. C'est le job qui vient d'entrer en file qui mérite l'annonce.
      if (next.queuedJobId != null &&
          next.queuedJobId != prev?.queuedJobId &&
          next.successMessage != null) {
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
                  size: AppIconSize.large,
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
                                  : 'Assigner à un livre',
                              helperText:
                                  _selectedIntent == ScanIntent.bookDocument
                                  ? null
                                  : 'À défaut, la recette rejoint « Mes recettes libres »',
                              prefixIcon: Icon(Icons.menu_book_outlined),
                            ),
                            initialValue: _selectedBookId,
                            // Pas d'option « Aucun livre » pour une recette :
                            // sans choix, elle rejoint le livre des recettes
                            // libres. L'import d'un livre entier, lui, en crée
                            // un — le laisser vide y a un sens.
                            items: [
                              if (_selectedIntent == ScanIntent.bookDocument)
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
                  // Troisième voie d'import : un texte collé, que l'IA met en
                  // forme. Elle n'avait d'entrée que dans le menu d'un livre,
                  // donc aucune depuis les brouillons.
                  if (_selectedIntent == ScanIntent.recipe) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => context.go(_manualEntryRoute()),
                      icon: const Icon(Icons.edit_note_outlined),
                      label: const Text('Saisie manuelle (texte à coller)'),
                    ),
                  ],
                ],

                // ── Progression ────────────────────────────────────────────
                //
                // Sous les boutons, et non à leur place : l'envoi se poursuit
                // pendant qu'on prépare l'import suivant. Ce qui prenait
                // l'écran entier pour quelques secondes tient maintenant en une
                // ligne par envoi.
                if (scanState.isRunning) ...[_ProgressCard(state: scanState)],
                if (scanState.hasActiveImports) ...[
                  const SizedBox(height: 12),
                  ...scanState.activeImports.map(
                    (u) => _ActiveImportTile(upload: u),
                  ),
                ],

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
                        trailing: IconButton(
                          tooltip: 'Supprimer cette page',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => ref
                              .read(scanUploadProvider.notifier)
                              .removePendingPageAt(e.key),
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Le défaut vient des préférences du compte, mais le choix se
                  // fait ici, import par import. Il tient jusqu'à ce qu'on
                  // quitte l'écran : enchaîner dix pages ne demande pas de
                  // recocher dix fois.
                  CheckboxListTile(
                    value: _importIllustrations,
                    onChanged: (value) =>
                        setState(() => _importIllustrations = value ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Extraire les illustrations'),
                    subtitle: const Text(
                      'Découpe les photos de la page et les attache à la '
                      'recette.',
                    ),
                  ),
                  const SizedBox(height: 8),
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
                          icon: const Icon(Icons.upload_file),
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
                                importIllustrations: _importIllustrations,
                              ),
                          icon: const Icon(Icons.auto_awesome_outlined),
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
                            size: AppIconSize.large,
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

  /// Ouvre l'atelier de retouche, une seule fois par image.
  ///
  /// [rattrapage] vaut vrai quand l'ouverture vient du filet et non de la
  /// transition. C'est une anomalie : elle ne bloque plus rien depuis que le
  /// filet existe, mais elle dit que l'écran a manqué le changement d'état, et
  /// personne ne le saurait sans cette remontée.
  void _openEnhancer(ScanState state, {required bool rattrapage}) {
    if (!mounted || _showingEnhancer) return;
    final bytes = state.pendingImageBytes;
    if (bytes == null) return;

    _ouverturesAtelier++;
    // Une réouverture sur la MÊME image est le symptôme à traquer :
    // `ScanState.copyWith` ne remet jamais `pendingImageBytes` à zéro, et un
    // retour en attente d'amélioration rouvrirait donc l'atelier sur la photo
    // d'origine, pas sur le résultat du recadrage.
    final memeImage = _dernierOctetsOuverts == bytes.length;
    _dernierOctetsOuverts = bytes.length;

    reportUnexpectedError(
      feature: 'scanUpload.enhancerOpened',
      error: StateError(
        rattrapage
            ? "Atelier ouvert par le filet (ouverture $_ouverturesAtelier)"
            : "Atelier ouvert par la transition (ouverture $_ouverturesAtelier)",
      ),
      context: {
        'voie': rattrapage ? 'filet' : 'transition',
        'ouverture': _ouverturesAtelier,
        'meme_image_que_la_precedente': memeImage,
        'intent': state.intent.name,
        'octets': bytes.length,
        'fichier': state.pendingImageFilename ?? '',
      },
    );

    setState(() {
      _enhancerBytes = bytes;
      _enhancerFilename = state.pendingImageFilename ?? 'cover.jpg';
      _showingEnhancer = true;
    });
  }

  // ignore: unused_element
  String _titleForIntent(ScanIntent intent) => switch (intent) {
    ScanIntent.recipe => 'Importer des recettes',
    ScanIntent.bookCover => 'Créer un livre depuis sa couverture',
    ScanIntent.bookDocument => 'Importer un livre complet',
  };

  String _subtitleForIntent(ScanIntent intent) => switch (intent) {
    ScanIntent.recipe =>
      'Une photo, un fichier (PDF, DOCX, image) ou un texte à coller. '
          'L\'IA extrait les recettes en brouillons.',
    ScanIntent.bookCover =>
      'Photographiez la page de garde pour créer un livre. La caméra se lance automatiquement sur mobile.',
    ScanIntent.bookDocument =>
      'Importez un PDF ou DOCX de livre pour extraire les recettes et les rattacher au livre choisi.',
  };

  /// Route de la saisie manuelle, en emportant le livre choisi sur cet écran.
  String _manualEntryRoute() {
    final bookId = _selectedBookId;
    if (bookId == null || bookId.isEmpty) return '/recipes/new';
    return '/recipes/new'
        '?bookId=${Uri.encodeQueryComponent(bookId)}'
        '&bookTitre=${Uri.encodeQueryComponent(_selectedBookTitre ?? '')}';
  }

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

/// Une ligne par envoi en vol : ce qu'il est, où il en est.
///
/// Elle vit **sous** les boutons et ne les remplace plus. Un envoi dure
/// quelques secondes ; il n'avait aucune raison de confisquer l'écran pendant
/// ce temps, alors que le travail long — l'extraction — se fait déjà en file
/// sans bloquer personne.
class _ActiveImportTile extends StatelessWidget {
  final ActiveImport upload;

  const _ActiveImportTile({required this.upload});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showBar = upload.phase == ScanUploadPhase.uploading;

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                // Pendant l'envoi la progression est connue ; pendant le
                // contrôle de sécurité, non — un indicateur qui feindrait
                // d'avancer mentirait sur ce qu'il sait.
                value: showBar ? upload.progress.clamp(0.0, 1.0) : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    upload.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    showBar
                        ? '${upload.label} · ${(upload.progress * 100).clamp(0, 100).toStringAsFixed(0)} %'
                        : upload.label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
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
