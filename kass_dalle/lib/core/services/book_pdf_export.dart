import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../features/recipes/domain/recipe.dart';
import 'pdf_download_stub.dart' if (dart.library.html) 'pdf_download_web.dart';

const _kAccent = PdfColor.fromInt(0xFFD84315);
const _kMuted = PdfColor.fromInt(0xFF757575);
const _kDivider = PdfColor.fromInt(0xFFBDBDBD);

/// Exporte un livre complet (recettes et pages non-recettes) en PDF.
///
/// La table des matieres est generee en debut de document avec les numeros de
/// pages finaux du PDF.
Future<({Uint8List bytes, String filename})> exportBookToPdf({
  required String bookTitle,
  required List<Recipe> pages,
  String? bookAuthor,
}) async {
  final sortedPages = [...pages]..sort(_sortByBookOrder);

  final doc = pw.Document(title: _sanitize(bookTitle), author: 'Kass\'Dalle');
  final regular = pw.Font.helvetica();
  final bold = pw.Font.helveticaBold();

  final theme = pw.ThemeData.withFont(
    base: regular,
    bold: bold,
  ).copyWith(defaultTextStyle: pw.TextStyle(font: regular, fontSize: 10));

  final toc = pw.TableOfContent();

  doc.addPage(
    pw.Page(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 48, vertical: 56),
        theme: theme,
      ),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            _sanitize(bookTitle),
            style: pw.TextStyle(font: bold, fontSize: 24, color: _kAccent),
          ),
          if ((bookAuthor ?? '').trim().isNotEmpty) ...[
            pw.SizedBox(height: 6),
            pw.Text(
              'Auteur: ${_sanitize(bookAuthor!.trim())}',
              style: pw.TextStyle(font: regular, fontSize: 11, color: _kMuted),
            ),
          ],
          pw.SizedBox(height: 8),
          pw.Text(
            'Nombre de pages du livre: ${sortedPages.length}',
            style: pw.TextStyle(font: regular, fontSize: 10, color: _kMuted),
          ),
          pw.SizedBox(height: 20),
          pw.Text(
            'Table des matieres',
            style: pw.TextStyle(font: bold, fontSize: 16),
          ),
          pw.SizedBox(height: 10),
          toc,
        ],
      ),
    ),
  );

  doc.addPage(
    pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 48, vertical: 56),
        theme: theme,
      ),
      footer: (context) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          'Page ${context.pageNumber} / ${context.pagesCount}',
          style: pw.TextStyle(font: regular, fontSize: 9, color: _kMuted),
        ),
      ),
      build: (context) => _buildPageEntries(sortedPages, bold, regular),
    ),
  );

  final bytes = await doc.save();
  final safe = bookTitle
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), '_');
  final filename = '${safe.isEmpty ? 'livre' : safe}.pdf';

  await downloadPdf(bytes, filename);
  return (bytes: bytes, filename: filename);
}

List<pw.Widget> _buildPageEntries(
  List<Recipe> pages,
  pw.Font bold,
  pw.Font regular,
) {
  final widgets = <pw.Widget>[];

  for (final page in pages) {
    final title = [
      if (page.pageNumber != null) 'p.${page.pageNumber}',
      _sanitize(page.titre),
    ].join(' - ');

    widgets.add(
      pw.Header(
        level: 0,
        text: title,
        textStyle: pw.TextStyle(font: bold, fontSize: 15, color: _kAccent),
      ),
    );

    widgets.add(
      pw.Text(
        _pageTypeLabel(page.pageType),
        style: pw.TextStyle(font: regular, fontSize: 10, color: _kMuted),
      ),
    );
    widgets.add(pw.SizedBox(height: 8));

    if (page.pageType == PageType.recipe) {
      if (page.ingredients.isNotEmpty) {
        widgets.add(
          pw.Text('Ingredients', style: pw.TextStyle(font: bold, fontSize: 12)),
        );
        widgets.add(pw.SizedBox(height: 4));
        for (final ing in page.ingredients) {
          final qty = [
            ing.qty,
            ing.unit,
          ].where((e) => e.trim().isNotEmpty).join(' ');
          final left = qty.isEmpty
              ? '- ${_sanitize(ing.name)}'
              : '- ${_sanitize(ing.name)}: ${_sanitize(qty)}';
          widgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 2),
              child: pw.Text(
                left,
                style: pw.TextStyle(font: regular, fontSize: 10),
              ),
            ),
          );
        }
        widgets.add(pw.SizedBox(height: 8));
      }

      final steps = _extractBodyParagraphs(page.rawCooklang);
      if (steps.isNotEmpty) {
        widgets.add(
          pw.Text('Preparation', style: pw.TextStyle(font: bold, fontSize: 12)),
        );
        widgets.add(pw.SizedBox(height: 4));
        for (var i = 0; i < steps.length; i++) {
          widgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 4),
              child: pw.Text(
                '${i + 1}. ${_sanitize(steps[i])}',
                style: pw.TextStyle(font: regular, fontSize: 10),
              ),
            ),
          );
        }
      }
    } else {
      final paragraphs = _extractBodyParagraphs(page.rawCooklang);
      if (paragraphs.isEmpty) {
        widgets.add(
          pw.Text(
            'Aucun contenu textuel.',
            style: pw.TextStyle(font: regular, fontSize: 10, color: _kMuted),
          ),
        );
      } else {
        for (final p in paragraphs) {
          widgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 6),
              child: pw.Text(
                _sanitize(p),
                style: pw.TextStyle(font: regular, fontSize: 10),
              ),
            ),
          );
        }
      }
    }

    widgets.add(pw.SizedBox(height: 8));
    widgets.add(pw.Divider(color: _kDivider, height: 1));
    widgets.add(pw.SizedBox(height: 10));
  }

  return widgets;
}

String _pageTypeLabel(PageType type) => switch (type) {
  PageType.recipe => 'Recette',
  PageType.technique => 'Technique culinaire',
  PageType.equipment => 'Materiel et ustensiles',
  PageType.ingredientNote => 'Note sur les ingredients',
  PageType.other => 'Page de livre',
};

List<String> _extractBodyParagraphs(String rawCooklang) {
  final rows = rawCooklang.split('\n');
  final out = <String>[];

  for (final row in rows) {
    final t = row.trim();
    if (t.isEmpty) continue;
    if (t.startsWith('>>')) continue;
    if (t.startsWith('==')) continue;
    if (t.startsWith('--')) continue;

    final continued = t.startsWith('+ ') && t.length > 2;
    final content = continued ? t.substring(2).trim() : t;
    final cleaned = _cleanCooklang(content);
    if (cleaned.isEmpty) continue;

    if (continued && out.isNotEmpty) {
      out[out.length - 1] = '${out.last}\n$cleaned';
    } else {
      out.add(cleaned);
    }
  }

  return out;
}

int _sortByBookOrder(Recipe a, Recipe b) {
  final pa = a.pageNumber;
  final pb = b.pageNumber;
  if (pa == null && pb == null) return a.titre.compareTo(b.titre);
  if (pa == null) return 1;
  if (pb == null) return -1;
  return pa.compareTo(pb);
}

String _sanitize(String text) => text
    .replaceAll('\u2018', "'")
    .replaceAll('\u2019', "'")
    .replaceAll('\u201C', '"')
    .replaceAll('\u201D', '"')
    .replaceAll('\u2013', '-')
    .replaceAll('\u2014', '-')
    .replaceAll('\u2026', '...')
    .replaceAll('\u2022', '-')
    .replaceAll('\u00B7', '-')
    .replaceAll('\u0152', 'Oe')
    .replaceAll('\u0153', 'oe')
    .replaceAll('\u20AC', 'EUR');

String _cleanCooklang(String text) {
  return text
      .replaceAllMapped(
        RegExp(r'@([^{@#~\n]+)(?:\{[^}]*\})?'),
        (m) => m.group(1)!.trim(),
      )
      .replaceAllMapped(
        RegExp(r'#([^{#\n]+)(?:\{[^}]*\})?'),
        (m) => m.group(1)!.trim(),
      )
      .replaceAllMapped(RegExp(r'~[^{~\n]*(?:\{([^}]*)\})?'), (m) {
        final braces = m.group(1) ?? '';
        if (braces.isNotEmpty) {
          final parts = braces.split('%');
          final val = parts[0].trim();
          final unit = parts.length > 1 ? parts[1].trim() : '';
          return [val, unit].where((e) => e.isNotEmpty).join(' ');
        }
        return '';
      })
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]+\)'), '')
      .trim();
}
