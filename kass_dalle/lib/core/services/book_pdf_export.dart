import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../features/recipes/domain/recipe.dart';
import 'pdf_download_stub.dart'
    if (dart.library.js_interop) 'pdf_download_web.dart';

const _kAccent = PdfColor.fromInt(0xFFD84315);
const _kMuted = PdfColor.fromInt(0xFF757575);
const _kDivider = PdfColor.fromInt(0xFFBDBDBD);

typedef _IndexEntry = ({Recipe recipe, int pdfStartPage, int pageCount});

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

  final regular = pw.Font.helvetica();
  final oblique = pw.Font.helveticaOblique();
  final bold = pw.Font.helveticaBold();

  final theme = pw.ThemeData.withFont(
    base: regular,
    bold: bold,
    italic: oblique,
  ).copyWith(defaultTextStyle: pw.TextStyle(font: regular, fontSize: 10));

  final pageTheme = pw.PageTheme(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.symmetric(horizontal: 48, vertical: 56),
    theme: theme,
  );

  final recipePageCounts = <int>[];
  for (final page in sortedPages) {
    recipePageCounts.add(
      await _estimateRecipePdfPageCount(
        page: page,
        pageTheme: pageTheme,
        bold: bold,
        regular: regular,
        oblique: oblique,
      ),
    );
  }

  final indexEntries = <_IndexEntry>[];
  var indexPageCount = 1;
  while (true) {
    indexEntries.clear();
    var startPage = indexPageCount + 1;
    for (var i = 0; i < sortedPages.length; i++) {
      final pageCount = recipePageCounts[i];
      indexEntries.add((
        recipe: sortedPages[i],
        pdfStartPage: startPage,
        pageCount: pageCount,
      ));
      startPage += pageCount;
    }

    final measuredIndexPages = await _estimateIndexPdfPageCount(
      bookTitle: bookTitle,
      bookAuthor: bookAuthor,
      entries: indexEntries,
      pageTheme: pageTheme,
      bold: bold,
      regular: regular,
      totalBookPages: sortedPages.length,
    );

    if (measuredIndexPages == indexPageCount) {
      break;
    }
    indexPageCount = measuredIndexPages;
  }

  final doc = pw.Document(title: _sanitize(bookTitle), author: 'Kass\'Dalle');

  doc.addPage(
    pw.MultiPage(
      pageTheme: pageTheme,
      footer: (context) => _buildPdfFooter(context, regular),
      build: (context) => _buildIndexEntries(
        bookTitle: bookTitle,
        bookAuthor: bookAuthor,
        entries: indexEntries,
        bold: bold,
        regular: regular,
        totalBookPages: sortedPages.length,
      ),
    ),
  );

  doc.addPage(
    pw.MultiPage(
      pageTheme: pageTheme,
      footer: (context) => _buildPdfFooter(context, regular),
      build: (context) =>
          _buildPageEntries(sortedPages, bold, regular, oblique),
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

Future<int> _estimateRecipePdfPageCount({
  required Recipe page,
  required pw.PageTheme pageTheme,
  required pw.Font bold,
  required pw.Font regular,
  required pw.Font oblique,
}) async {
  final doc = pw.Document(title: _sanitize(page.titre), author: 'Kass\'Dalle');
  doc.addPage(
    pw.MultiPage(
      pageTheme: pageTheme,
      footer: (context) => _buildPdfFooter(context, regular),
      build: (context) => _buildSinglePageEntry(page, bold, regular, oblique),
    ),
  );
  await doc.save();
  return doc.document.pdfPageList.pages.length;
}

Future<int> _estimateIndexPdfPageCount({
  required String bookTitle,
  required String? bookAuthor,
  required List<_IndexEntry> entries,
  required pw.PageTheme pageTheme,
  required pw.Font bold,
  required pw.Font regular,
  required int totalBookPages,
}) async {
  final doc = pw.Document(title: _sanitize(bookTitle), author: 'Kass\'Dalle');
  doc.addPage(
    pw.MultiPage(
      pageTheme: pageTheme,
      footer: (context) => _buildPdfFooter(context, regular),
      build: (context) => _buildIndexEntries(
        bookTitle: bookTitle,
        bookAuthor: bookAuthor,
        entries: entries,
        bold: bold,
        regular: regular,
        totalBookPages: totalBookPages,
      ),
    ),
  );
  await doc.save();
  return doc.document.pdfPageList.pages.length;
}

pw.Widget _buildPdfFooter(pw.Context context, pw.Font regular) {
  return pw.Align(
    alignment: pw.Alignment.centerRight,
    child: pw.Text(
      'Page ${context.pageNumber} / ${context.pagesCount}',
      style: pw.TextStyle(font: regular, fontSize: 9, color: _kMuted),
    ),
  );
}

List<pw.Widget> _buildIndexEntries({
  required String bookTitle,
  required String? bookAuthor,
  required List<_IndexEntry> entries,
  required pw.Font bold,
  required pw.Font regular,
  required int totalBookPages,
}) {
  final widgets = <pw.Widget>[
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
      'Nombre de pages du livre: $totalBookPages',
      style: pw.TextStyle(font: regular, fontSize: 10, color: _kMuted),
    ),
    pw.SizedBox(height: 20),
    pw.Text('Index', style: pw.TextStyle(font: bold, fontSize: 16)),
    pw.SizedBox(height: 10),
  ];

  for (final entry in entries) {
    final recipe = entry.recipe;
    widgets.add(
      pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 4),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Text(
                _sanitize(recipe.titre),
                style: pw.TextStyle(font: regular, fontSize: 10),
              ),
            ),
            pw.SizedBox(width: 8),
            pw.Text(
              '${entry.pdfStartPage}',
              style: pw.TextStyle(font: regular, fontSize: 10, color: _kMuted),
            ),
          ],
        ),
      ),
    );
  }

  return widgets;
}

List<pw.Widget> _buildPageEntries(
  List<Recipe> pages,
  pw.Font bold,
  pw.Font regular,
  pw.Font oblique,
) {
  final widgets = <pw.Widget>[];

  for (var i = 0; i < pages.length; i++) {
    if (i > 0) {
      widgets.add(pw.NewPage());
    }
    widgets.addAll(_buildSinglePageEntry(pages[i], bold, regular, oblique));
  }

  return widgets;
}

List<pw.Widget> _buildSinglePageEntry(
  Recipe page,
  pw.Font bold,
  pw.Font regular,
  pw.Font oblique,
) {
  final widgets = <pw.Widget>[];
  final cooklang = page.draftCooklang?.isNotEmpty == true
      ? page.draftCooklang!
      : page.rawCooklang;
  final title = _sanitize(page.titre);

  widgets.add(
    pw.Header(
      level: 0,
      text: title,
      textStyle: pw.TextStyle(font: bold, fontSize: 15, color: _kAccent),
    ),
  );

  final bookPage = page.pageNumber;
  final bookPageLabel = bookPage == null ? 'n/a' : '$bookPage';
  widgets.add(
    pw.Text(
      '${_pageTypeLabel(page.pageType)}  |  Page du livre: $bookPageLabel',
      style: pw.TextStyle(font: regular, fontSize: 10, color: _kMuted),
    ),
  );
  widgets.add(pw.SizedBox(height: 8));

  if (page.pageType == PageType.recipe) {
    if (page.ingredients.isNotEmpty) {
      widgets.add(
        pw.Text('Ingrédients', style: pw.TextStyle(font: bold, fontSize: 12)),
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
        // La remarque du livre suit l'ingrédient, entre parenthèses. Même
        // règle que la fiche d'une seule recette : ce que le livre disait en
        // plus de la quantité — « concassés », « avec la peau » — se perdait
        // à l'impression, c'est-à-dire au moment où l'on emporte la recette
        // en cuisine.
        final note = ing.note?.trim();
        widgets.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 2),
            child: (note == null || note.isEmpty)
                ? pw.Text(
                    left,
                    style: pw.TextStyle(font: regular, fontSize: 10),
                  )
                : pw.RichText(
                    text: pw.TextSpan(
                      style: pw.TextStyle(font: regular, fontSize: 10),
                      children: [
                        pw.TextSpan(text: left),
                        pw.TextSpan(
                          text: ' (${_sanitize(note)})',
                          style: pw.TextStyle(
                            font: oblique,
                            fontSize: 9,
                            color: _kMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        );
      }
      widgets.add(pw.SizedBox(height: 8));
    }

    final steps = _extractBodyParagraphs(cooklang);
    if (steps.isNotEmpty) {
      widgets.add(
        pw.Text('Préparation', style: pw.TextStyle(font: bold, fontSize: 12)),
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
    final paragraphs = _extractBodyParagraphs(cooklang);
    if (paragraphs.isEmpty) {
      widgets.add(
        pw.Text(
          'Aucun contenu textuel.',
          style: pw.TextStyle(font: regular, fontSize: 10, color: _kMuted),
        ),
      );
    } else {
      widgets.addAll(_buildMarkdownParagraphs(paragraphs, bold, regular));
    }
  }

  widgets.add(pw.SizedBox(height: 8));
  widgets.add(pw.Divider(color: _kDivider, height: 1));
  widgets.add(pw.SizedBox(height: 10));
  return widgets;
}

String _pageTypeLabel(PageType type) => switch (type) {
  PageType.recipe => 'Recette',
  PageType.technique => 'Technique culinaire',
  PageType.equipment => 'Materiel et ustensiles',
  PageType.ingredientNote => 'Note sur les ingrédients',
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

List<pw.Widget> _buildMarkdownParagraphs(
  List<String> paragraphs,
  pw.Font bold,
  pw.Font regular,
) {
  final widgets = <pw.Widget>[];

  for (final paragraph in paragraphs) {
    final lines = paragraph.split('\n');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final headingMatch = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(trimmed);
      if (headingMatch != null) {
        final level = headingMatch.group(1)!.length;
        final text = _sanitize(headingMatch.group(2)!.trim());
        widgets.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 4),
            child: pw.Text(text, style: _headingStyle(level, bold)),
          ),
        );
        continue;
      }

      final quoteMatch = RegExp(r'^>\s+(.+)$').firstMatch(trimmed);
      if (quoteMatch != null) {
        widgets.add(
          pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 6),
            padding: const pw.EdgeInsets.only(left: 10),
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                left: pw.BorderSide(color: _kDivider, width: 2),
              ),
            ),
            child: pw.Text(
              _sanitize(quoteMatch.group(1)!.trim()),
              style: pw.TextStyle(font: regular, fontSize: 10, color: _kMuted),
            ),
          ),
        );
        continue;
      }

      final bulletMatch = RegExp(r'^[-*]\s+(.+)$').firstMatch(trimmed);
      if (bulletMatch != null) {
        widgets.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(left: 8, bottom: 3),
            child: pw.RichText(
              text: pw.TextSpan(
                style: pw.TextStyle(font: regular, fontSize: 10),
                children: [
                  const pw.TextSpan(text: '- '),
                  ..._buildInlineSpans(
                    bulletMatch.group(1)!.trim(),
                    regular,
                    bold,
                  ),
                ],
              ),
            ),
          ),
        );
        continue;
      }

      widgets.add(
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 6),
          child: pw.RichText(
            text: pw.TextSpan(
              style: pw.TextStyle(font: regular, fontSize: 10),
              children: _buildInlineSpans(trimmed, regular, bold),
            ),
          ),
        ),
      );
    }

    widgets.add(pw.SizedBox(height: 2));
  }

  return widgets;
}

pw.TextStyle _headingStyle(int level, pw.Font bold) {
  final size = switch (level) {
    1 => 18.0,
    2 => 15.0,
    3 => 13.0,
    4 => 12.0,
    5 => 11.0,
    _ => 10.0,
  };

  return pw.TextStyle(font: bold, fontSize: size, color: _kAccent);
}

List<pw.InlineSpan> _buildInlineSpans(
  String text,
  pw.Font regular,
  pw.Font bold,
) {
  final spans = <pw.InlineSpan>[];
  final sanitized = _sanitize(text);
  final pattern = RegExp(r'(\*\*.+?\*\*|__.+?__|\*[^*]+\*|_[^_]+_)');
  var index = 0;

  for (final match in pattern.allMatches(sanitized)) {
    if (match.start > index) {
      spans.add(pw.TextSpan(text: sanitized.substring(index, match.start)));
    }

    final token = match.group(0)!;
    final isBold = token.startsWith('**') || token.startsWith('__');
    final inner = token.substring(
      isBold ? 2 : 1,
      token.length - (isBold ? 2 : 1),
    );
    spans.add(
      pw.TextSpan(
        text: inner,
        style: pw.TextStyle(
          font: isBold ? bold : regular,
          fontSize: 10,
          fontStyle: isBold ? pw.FontStyle.normal : pw.FontStyle.italic,
        ),
      ),
    );
    index = match.end;
  }

  if (index < sanitized.length) {
    spans.add(pw.TextSpan(text: sanitized.substring(index)));
  }

  return spans;
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
