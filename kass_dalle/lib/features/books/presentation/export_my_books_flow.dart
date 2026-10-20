import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/book_pdf_export.dart';
import '../../../core/services/books_archive_export.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/utils/context_extensions.dart';
import '../../recipes/presentation/recipe_providers.dart';
import '../domain/book.dart';
import 'delete_book_flow.dart';

/// Exporte les livres de l'utilisateur, un PDF par livre, réunis dans un ZIP.
///
/// Un livre sans page validée est ignoré. Un livre dont le PDF échoue est
/// signalé et compté, sans arrêter les autres. Le compte rendu final donne
/// les trois nombres : exportés, sans page validée, en erreur.
///
/// Un seul export à la fois : « Annuler » ferme la fenêtre avant la fin du
/// livre en cours, et l'icône redevient cliquable pendant ce temps.
Future<void> exportMyBooksAsZip({
  required BuildContext context,
  required WidgetRef ref,
  required List<Book> books,
}) async {
  if (books.isEmpty) return;
  if (_exportRunning) {
    context.showSnackBar('Un export de vos livres est déjà en cours.');
    return;
  }
  _exportRunning = true;
  try {
    await _exportMyBooksAsZip(context: context, ref: ref, books: books);
  } finally {
    _exportRunning = false;
  }
}

bool _exportRunning = false;

Future<void> _exportMyBooksAsZip({
  required BuildContext context,
  required WidgetRef ref,
  required List<Book> books,
}) async {
  final viewer = ref.read(recipeViewerProvider);
  if (viewer == null) {
    context.showErrorSnackBar(kAccountNotLoadedMessage);
    return;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Exporter mes livres en PDF'),
      content: Text(
        books.length == 1
            ? 'Votre livre sera exporté en PDF, dans un fichier ZIP.'
            : 'Vos ${books.length} livres seront exportés, un PDF par livre, '
                  'réunis dans un seul fichier ZIP.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Exporter'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final progress = ValueNotifier<({int done, String title})>((
    done: 0,
    title: '',
  ));
  var cancelled = false;
  final navigator = Navigator.of(context, rootNavigator: true);
  final dialogClosed = showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Export en cours'),
        content: ValueListenableBuilder(
          valueListenable: progress,
          builder: (ctx, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Livre ${value.done + 1} sur ${books.length}'),
              const SizedBox(height: 4),
              Text(
                value.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: value.done / books.length),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.of(ctx).pop();
            },
            child: const Text('Annuler'),
          ),
        ],
      ),
    ),
  );

  final pdfs = <({String filename, Uint8List bytes})>[];
  var empty = 0;
  var failed = 0;
  final repository = ref.read(recipeRepositoryProvider);
  for (var i = 0; i < books.length && !cancelled; i++) {
    final book = books[i];
    progress.value = (done: i, title: book.titre);
    try {
      final pages = await repository.getAllValidatedPagesByBook(
        book.id,
        viewer,
      );
      if (pages.isEmpty) {
        empty++;
        continue;
      }
      pdfs.add(
        await buildBookPdf(
          bookTitle: book.titre,
          bookAuthor: book.auteur,
          pages: pages,
        ),
      );
    } catch (e, stackTrace) {
      failed++;
      reportUnexpectedError(
        feature: 'bookListScreen.exportMyBooks',
        error: e,
        stackTrace: stackTrace,
        context: {'book_id': book.id},
      );
    }
  }
  if (!cancelled) navigator.pop();
  await dialogClosed;
  progress.dispose();
  if (!context.mounted) return;
  if (cancelled) {
    context.showSnackBar('Export annulé.');
    return;
  }

  if (pdfs.isEmpty) {
    context.showErrorSnackBar(
      failed > 0
          ? 'Aucun livre exporté : $failed en erreur.'
          : 'Aucune page validée à exporter dans vos livres.',
    );
    return;
  }

  try {
    final saved = await saveBooksArchive(
      zipBookPdfs(pdfs),
      libraryArchiveFilename(DateTime.now()),
    );
    if (!context.mounted) return;
    if (!saved) {
      context.showSnackBar('Export annulé.');
      return;
    }
    final report = exportReport(
      exported: pdfs.length,
      empty: empty,
      failed: failed,
    );
    if (failed > 0) {
      context.showErrorSnackBar(report);
    } else {
      context.showSuccessSnackBar(report);
    }
  } catch (e, stackTrace) {
    reportUnexpectedError(
      feature: 'bookListScreen.exportMyBooks.save',
      error: e,
      stackTrace: stackTrace,
    );
    if (!context.mounted) return;
    context.showFailureSnackBar('Archive non enregistrée', e);
  }
}

/// Compte rendu de l'export : « 8 livres exportés, 2 sans page validée, 1 en erreur ».
String exportReport({
  required int exported,
  required int empty,
  required int failed,
}) {
  final parts = [
    exported == 1 ? '1 livre exporté' : '$exported livres exportés',
    if (empty > 0) '$empty sans page validée',
    if (failed > 0) '$failed en erreur',
  ];
  return parts.join(', ');
}
