import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../utils/ingredient_display.dart';

import 'pdf_download_stub.dart'
    if (dart.library.js_interop) 'pdf_download_web.dart';
import '../../features/recipes/domain/recipe.dart';
import '../utils/recipe_portion_scaler.dart';
import 'cooklang_parser.dart';
import 'error_reporting.dart';
import '../utils/recipe_tag_sections.dart';

// ── Couleurs thématiques ─────────────────────────────────────────────────────

const _kAccent = PdfColor.fromInt(0xFFD84315); // deep orange 800
const _kAccentLight = PdfColor.fromInt(0xFFFBE9E7); // deep orange 50
const _kMuted = PdfColor.fromInt(0xFF757575); // grey 600
const _kDivider = PdfColor.fromInt(0xFFBDBDBD); // grey 400

// ── Point d'entrée public ────────────────────────────────────────────────────

/// Génère le PDF et le télécharge / partage selon la plateforme.
/// Si [includeImages] est true, les photos de la recette sont intégrées.
/// Retourne les bytes et le nom de fichier pour permettre une réouverture.
Future<({Uint8List bytes, String filename})> exportRecipeToPdf(
  Recipe recipe, {
  bool includeImages = false,
  int? basePortions,
  int? selectedPortions,
}) async {
  final cooklang = recipe.draftCooklang?.isNotEmpty == true
      ? recipe.draftCooklang!
      : recipe.rawCooklang;
  final effectiveBasePortions =
      basePortions ?? recipe.portions ?? extractPortions(cooklang);
  final effectiveSelectedPortions = selectedPortions ?? effectiveBasePortions;
  final factor =
      effectiveBasePortions != null &&
          effectiveSelectedPortions != null &&
          effectiveBasePortions > 0 &&
          effectiveSelectedPortions > 0
      ? portionScaleFactor(
          basePortions: effectiveBasePortions,
          targetPortions: effectiveSelectedPortions,
        )
      : 1.0;

  final bytes = await _buildRecipePdf(
    recipe,
    includeImages: includeImages,
    displayedPortions: effectiveSelectedPortions,
    ingredientsOverride: scaleRecipeIngredients(recipe.ingredients, factor),
  );
  // Sanitize le nom de fichier
  final safe = recipe.titre
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), '_');
  final filename = '${safe.isEmpty ? 'recette' : safe}.pdf';

  // helper conditionnel :
  //   • Web    → package:web <a download> (téléchargement direct)
  //   • Android/iOS → share sheet (Enregistrer dans Fichiers)
  //   • Desktop → dialogue d'impression / sauvegarde
  await downloadPdf(bytes, filename);
  return (bytes: bytes, filename: filename);
}

/// Ré-ouvre le PDF (share sheet / impression) à partir de bytes déjà générés.
Future<void> openPdf(Uint8List bytes, String filename) =>
    downloadPdf(bytes, filename);

// ── Construction du document ─────────────────────────────────────────────────

Future<Uint8List> _buildRecipePdf(
  Recipe recipe, {
  bool includeImages = false,
  int? displayedPortions,
  List<RecipeIngredient>? ingredientsOverride,
}) async {
  final cooklang = recipe.draftCooklang?.isNotEmpty == true
      ? recipe.draftCooklang!
      : recipe.rawCooklang;
  final doc = pw.Document(title: recipe.titre, author: 'Kass\'Dalle');

  // Polices intégrées (Latin-1 = accents français OK, 100 % hors-ligne)
  final regular = pw.Font.helvetica();
  final bold = pw.Font.helveticaBold();
  final oblique = pw.Font.helveticaOblique();

  final theme = pw.ThemeData.withFont(
    base: regular,
    bold: bold,
    italic: oblique,
  ).copyWith(defaultTextStyle: pw.TextStyle(font: regular, fontSize: 10));

  final sections = _parseSections(cooklang);
  final meta = _parseMeta(cooklang);
  final tagSections = buildRecipeTagSections(recipe.tags);

  // ── Pré-chargement des images ──────────────────────────────────────────────
  Map<String, pw.MemoryImage> imageCache = {};
  List<pw.MemoryImage> galleryImages = [];

  if (includeImages && recipe.imageUrls.isNotEmpty) {
    final inlineUrls = _extractInlineImageUrls(cooklang);

    // Télécharge toutes les images référencées dans imageUrls
    for (final url in recipe.imageUrls) {
      final bytes = await _fetchImageBytes(url);
      if (bytes != null) imageCache[url] = pw.MemoryImage(bytes);
    }
    // Télécharge les images inline non présentes dans imageUrls
    for (final url in inlineUrls) {
      if (!imageCache.containsKey(url)) {
        final bytes = await _fetchImageBytes(url);
        if (bytes != null) imageCache[url] = pw.MemoryImage(bytes);
      }
    }
    // Sépare les images hors-texte pour la galerie
    for (final url in recipe.imageUrls) {
      if (!inlineUrls.contains(url) && imageCache.containsKey(url)) {
        galleryImages.add(imageCache[url]!);
      }
    }
  }
  // ──────────────────────────────────────────────────────────────────────────

  doc.addPage(
    pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 48, vertical: 56),
        theme: theme,
      ),
      build: (pw.Context ctx) => [
        _header(recipe, bold, regular, oblique),
        pw.SizedBox(height: 10),
        _metaRow(
          recipe,
          meta,
          regular,
          oblique,
          displayedPortions: displayedPortions,
        ),
        if (tagSections.isNotEmpty) ...[
          pw.SizedBox(height: 8),
          _tagSectionsBlock(tagSections, bold, regular, oblique),
        ],
        pw.SizedBox(height: 10),
        _divider(),
        pw.SizedBox(height: 10),
        if ((ingredientsOverride ?? recipe.ingredients).isNotEmpty) ...[
          _ingredientsSection(
            ingredientsOverride ?? recipe.ingredients,
            bold,
            regular,
          ),
          pw.SizedBox(height: 10),
          _divider(),
          pw.SizedBox(height: 10),
        ],
        if (sections.isNotEmpty) ...[
          _preparationSection(
            sections,
            bold,
            regular,
            oblique,
            imageCache: imageCache,
          ),
        ],
        pw.SizedBox(height: 20),
        if (galleryImages.isNotEmpty) ...[
          _divider(),
          pw.SizedBox(height: 10),
          _gallerySection(galleryImages, bold),
          pw.SizedBox(height: 20),
        ],
        _footer(regular),
      ],
    ),
  );

  return doc.save();
}

// ── Téléchargement d'image ────────────────────────────────────────────────────

/// Télécharge les octets d'une image depuis son URL.
/// Retourne null en cas d'échec (réseau, CORS, 4xx/5xx…).
Future<Uint8List?> _fetchImageBytes(String url) async {
  try {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) return response.bodyBytes;
    reportUnexpectedError(
      feature: 'recipePdfExport.fetchImage',
      error: 'HTTP ${response.statusCode} sur une image de recette',
      context: {'url': url, 'statusCode': response.statusCode},
    );
    return null;
  } catch (error, stackTrace) {
    // Best-effort : le PDF est généré sans cette image, mais l'échec doit
    // rester visible (règle projet : aucun catch silencieux).
    reportUnexpectedError(
      feature: 'recipePdfExport.fetchImage',
      error: error,
      stackTrace: stackTrace,
      context: {'url': url},
    );
    return null;
  }
}

/// Extrait les URLs d'images inline ![...](url) du texte CookLang.
Set<String> _extractInlineImageUrls(String cooklang) {
  final regex = RegExp(r'!\[[^\]]*\]\(([^)]+)\)');
  return regex.allMatches(cooklang).map((m) => m.group(1)!).toSet();
}

// ── En-tête ──────────────────────────────────────────────────────────────────

pw.Widget _header(
  Recipe recipe,
  pw.Font bold,
  pw.Font regular,
  pw.Font oblique,
) {
  return pw.Container(
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: _kAccentLight,
      border: pw.Border(left: pw.BorderSide(color: _kAccent, width: 4)),
      borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          _sanitize(recipe.titre),
          style: pw.TextStyle(
            font: bold,
            fontSize: 22,
            color: PdfColor.fromInt(0xFF212121),
          ),
        ),
        if (recipe.bookTitre != null) ...[
          pw.SizedBox(height: 4),
          pw.Text(
            [
              'Extrait de << ${_sanitize(recipe.bookTitre!)} >>', // guillemets ASCII (WinAnsi)
              if (recipe.pageNumber != null) 'p. ${recipe.pageNumber}',
            ].join(', '),
            style: pw.TextStyle(font: oblique, fontSize: 10, color: _kMuted),
          ),
        ] else ...[
          pw.SizedBox(height: 4),
          pw.Text(
            'Recette libre',
            style: pw.TextStyle(font: oblique, fontSize: 10, color: _kMuted),
          ),
        ],
      ],
    ),
  );
}

// ── Métadonnées (temps, portions, difficulté) ─────────────────────────────────

pw.Widget _metaRow(
  Recipe recipe,
  Map<String, String> meta,
  pw.Font regular,
  pw.Font oblique, {
  int? displayedPortions,
}) {
  final items = <_MetaItem>[];

  final portionsStr = meta['portions'] ?? meta['servings'];
  final portionsInt = displayedPortions ?? recipe.portions;
  if (portionsStr != null || portionsInt != null) {
    items.add(_MetaItem('Portions', '${portionsStr ?? portionsInt}'));
  }

  final prepTime = meta['prep_time'] != null
      ? int.tryParse(meta['prep_time']!)
      : recipe.tags.prepTime;
  if (prepTime != null && prepTime > 0) {
    items.add(_MetaItem('Prép.', '$prepTime min'));
  }

  final cookTime = meta['cook_time'] != null
      ? int.tryParse(meta['cook_time']!)
      : recipe.tags.cookTime;
  if (cookTime != null && cookTime > 0) {
    items.add(_MetaItem('Cuisson', '$cookTime min'));
  }

  if (recipe.tags.difficulty != null && recipe.tags.difficulty!.isNotEmpty) {
    items.add(_MetaItem('Difficulté', recipe.tags.difficulty!));
  }

  if (items.isEmpty) return pw.SizedBox.shrink();

  return pw.Wrap(
    spacing: 20,
    runSpacing: 6,
    children: items.map((item) {
      return pw.Row(
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          pw.Container(
            width: 6,
            height: 6,
            decoration: pw.BoxDecoration(
              color: _kAccent,
              shape: pw.BoxShape.circle,
            ),
          ),
          pw.SizedBox(width: 4),
          pw.RichText(
            text: pw.TextSpan(
              children: [
                pw.TextSpan(
                  text: '${item.label} ',
                  style: pw.TextStyle(
                    font: oblique,
                    fontSize: 9,
                    color: _kMuted,
                  ),
                ),
                pw.TextSpan(
                  text: item.value,
                  style: pw.TextStyle(fontSize: 10),
                ),
              ],
            ),
          ),
        ],
      );
    }).toList(),
  );
}

class _MetaItem {
  final String label;
  final String value;
  const _MetaItem(this.label, this.value);
}

pw.Widget _tagSectionsBlock(
  List<RecipeTagSection> sections,
  pw.Font bold,
  pw.Font regular,
  pw.Font oblique,
) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      _sectionTitle('CATÉGORISATION', bold),
      pw.SizedBox(height: 6),
      ...sections.map(
        (section) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 3),
          child: pw.RichText(
            text: pw.TextSpan(
              children: [
                pw.TextSpan(
                  text: '${_sanitize(section.label)}: ',
                  style: pw.TextStyle(
                    font: oblique,
                    fontSize: 9,
                    color: _kMuted,
                  ),
                ),
                pw.TextSpan(
                  text: _sanitize(section.values.join(', ')),
                  style: pw.TextStyle(
                    font: regular,
                    fontSize: 10,
                    color: PdfColor.fromInt(0xFF212121),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

// ── Section Ingrédients ───────────────────────────────────────────────────────

pw.Widget _ingredientsSection(
  List<RecipeIngredient> ingredients,
  pw.Font bold,
  pw.Font regular,
) {
  // Grouper par catégorie
  final Map<String?, List<RecipeIngredient>> grouped = {};
  for (final ing in ingredients) {
    final cat = (ing.category?.isEmpty ?? true) ? null : ing.category;
    grouped.putIfAbsent(cat, () => []).add(ing);
  }

  // Ordre des catégories tel qu'elles apparaissent
  final List<String?> catOrder = [];
  for (final ing in ingredients) {
    final cat = (ing.category?.isEmpty ?? true) ? null : ing.category;
    if (!catOrder.contains(cat)) catOrder.add(cat);
  }

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      _sectionTitle('INGRÉDIENTS', bold),
      pw.SizedBox(height: 6),
      for (final cat in catOrder) ...[
        if (cat != null) ...[
          pw.SizedBox(height: 6),
          pw.Text(
            _sanitize(cat).toUpperCase(),
            style: pw.TextStyle(
              font: bold,
              fontSize: 8,
              color: _kMuted,
              letterSpacing: 0.5,
            ),
          ),
          pw.SizedBox(height: 3),
        ],
        for (final ing in grouped[cat]!) _ingredientRow(ing, regular),
      ],
    ],
  );
}

pw.Widget _ingredientRow(RecipeIngredient ing, pw.Font regular) {
  // Une seule chaîne, accordée en nombre et liée par « de » : « 3 cuillères à
  // soupe de sauce soja » plutôt que « 3 Cuillère à soupe sauce soja ». Le
  // découpage en trois morceaux collés était la source de la moitié des fautes
  // lues sur une fiche imprimée.
  final parts = [
    formatIngredientDisplay(qty: ing.qty, unit: ing.unit, name: ing.name),
  ];
  return pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(width: 8),
        pw.Text(
          '- ',
          style: pw.TextStyle(font: regular, fontSize: 10, color: _kAccent),
        ),
        pw.Expanded(
          child: pw.Text(
            _sanitize(parts.join(' ')),
            style: pw.TextStyle(font: regular, fontSize: 10),
          ),
        ),
      ],
    ),
  );
}

// ── Section Préparation ───────────────────────────────────────────────────────

pw.Widget _preparationSection(
  List<_Section> sections,
  pw.Font bold,
  pw.Font regular,
  pw.Font oblique, {
  Map<String, pw.MemoryImage> imageCache = const {},
}) {
  final children = <pw.Widget>[
    _sectionTitle('PRÉPARATION', bold),
    pw.SizedBox(height: 6),
  ];

  for (final section in sections) {
    if (section.name != null) {
      children.add(pw.SizedBox(height: 8));
      children.add(
        pw.Text(
          _sanitize(section.name!),
          style: pw.TextStyle(font: bold, fontSize: 11, color: _kAccent),
        ),
      );
      children.add(pw.SizedBox(height: 4));
    }

    // Largeur de contenu A4 : 595.28 - 2*48 = 499 pt
    const contentWidth = 499.0;
    int stepNum = 0;
    final steps = section.steps;
    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];

      // Image inline sans étape précédente → rendu comme bloc
      if (step.inlineImageUrl != null) {
        final img = imageCache[step.inlineImageUrl];
        if (img != null) {
          children.add(_inlineImageBlock(img, step, contentWidth));
        }
        continue;
      }

      // Look-ahead : l'étape suivante est-elle une image left/right ?
      _Step? nextImgStep;
      pw.MemoryImage? sideImage;
      if (i + 1 < steps.length) {
        final next = steps[i + 1];
        if (next.inlineImageUrl != null &&
            (next.imagePos == 'left' || next.imagePos == 'right')) {
          sideImage = imageCache[next.inlineImageUrl];
          nextImgStep = next;
          i++; // consomme l'étape image
        }
      }

      if (step.isNote) {
        children.add(
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(16, 3, 0, 3),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('> ', style: pw.TextStyle(fontSize: 8, color: _kMuted)),
                pw.Expanded(
                  child: pw.Text(
                    _sanitize(step.text),
                    style: pw.TextStyle(
                      font: oblique,
                      fontSize: 9,
                      color: _kMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        stepNum++;
        final isRight = nextImgStep == null || nextImgStep.imagePos == 'right';
        final imgW = sideImage != null
            ? contentWidth * (nextImgStep!.imagePct ?? 30.0) / 100
            : 0.0;
        final imgH = imgW * 0.75;

        children.add(
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 3),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                if (sideImage != null && !isRight) ...[
                  pw.Image(
                    sideImage,
                    width: imgW,
                    height: imgH,
                    fit: pw.BoxFit.cover,
                  ),
                  pw.SizedBox(width: 8),
                ],
                pw.SizedBox(
                  width: 22,
                  child: pw.Text(
                    '$stepNum.',
                    style: pw.TextStyle(
                      font: bold,
                      fontSize: 10,
                      color: _kAccent,
                    ),
                  ),
                ),
                pw.Expanded(
                  child: pw.Text(
                    _sanitize(step.text),
                    style: pw.TextStyle(font: regular, fontSize: 10),
                  ),
                ),
                if (sideImage != null && isRight) ...[
                  pw.SizedBox(width: 8),
                  pw.Image(
                    sideImage,
                    width: imgW,
                    height: imgH,
                    fit: pw.BoxFit.cover,
                  ),
                ],
              ],
            ),
          ),
        );
      }
    }
  }

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: children,
  );
}

/// Image de type bloc (position neutre / center) : alignée selon imagePos, largeur calculée.
pw.Widget _inlineImageBlock(
  pw.MemoryImage img,
  _Step step,
  double contentWidth,
) {
  const defaultPct = 65.0;
  const maxWidth = 320.0;
  final pct = step.imagePct ?? defaultPct;
  final w = (contentWidth * pct / 100).clamp(0.0, maxWidth);
  final h = w * 0.67;

  final pw.Alignment align;
  switch (step.imagePos) {
    case 'left':
      align = pw.Alignment.centerLeft;
      break;
    case 'right':
      align = pw.Alignment.centerRight;
      break;
    default:
      align = pw.Alignment.center;
  }

  return pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 6),
    child: pw.Align(
      alignment: align,
      child: pw.Image(img, width: w, height: h, fit: pw.BoxFit.contain),
    ),
  );
}

// ── Galerie photos ───────────────────────────────────────────────────────

/// Affiche les images hors-texte en grille 2 colonnes au bas du document.
pw.Widget _gallerySection(List<pw.MemoryImage> images, pw.Font bold) {
  const colWidth = 245.0; // (499 pt content − 8 pt gap) / 2
  const colHeight = 160.0;
  const gap = 8.0;

  final rows = <pw.Widget>[];
  for (var i = 0; i < images.length; i += 2) {
    rows.add(
      pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: gap),
        child: pw.Row(
          children: [
            pw.Image(
              images[i],
              width: colWidth,
              height: colHeight,
              fit: pw.BoxFit.contain,
            ),
            if (i + 1 < images.length) ...[
              pw.SizedBox(width: gap),
              pw.Image(
                images[i + 1],
                width: colWidth,
                height: colHeight,
                fit: pw.BoxFit.contain,
              ),
            ],
          ],
        ),
      ),
    );
  }

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [_sectionTitle('PHOTOS', bold), pw.SizedBox(height: 8), ...rows],
  );
}
// ── Pied de page ──────────────────────────────────────────────────────────────

pw.Widget _footer(pw.Font regular) {
  return pw.Row(
    children: [
      pw.Expanded(child: pw.Divider(color: _kDivider)),
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 8),
        child: pw.Text(
          'Kass\'Dalle',
          style: pw.TextStyle(font: regular, fontSize: 8, color: _kMuted),
        ),
      ),
      pw.Expanded(child: pw.Divider(color: _kDivider)),
    ],
  );
}

// ── Helpers visuels ───────────────────────────────────────────────────────────

pw.Widget _sectionTitle(String text, pw.Font bold) {
  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.center,
    children: [
      pw.Container(
        width: 3,
        height: 14,
        color: _kAccent,
        margin: const pw.EdgeInsets.only(right: 8),
      ),
      pw.Text(
        text,
        style: pw.TextStyle(
          font: bold,
          fontSize: 13,
          color: PdfColor.fromInt(0xFF212121),
        ),
      ),
    ],
  );
}

pw.Widget _divider() {
  return pw.Divider(color: _kDivider, height: 1);
}

// ── Parsing CookLang ─────────────────────────────────────────────────────────

class _Step {
  final String text;
  final bool isNote;

  /// URL d’une image inline (ligne isolée !… dans le CookLang).
  final String? inlineImageUrl;

  /// Position de l'image : 'left', 'right', ou '' (bloc centré).
  final String imagePos;

  /// Largeur de l'image en % de la largeur de contenu (null = défaut selon position).
  final double? imagePct;
  const _Step(
    this.text, {
    this.isNote = false,
    this.inlineImageUrl,
    this.imagePos = '',
    this.imagePct,
  });
}

class _Section {
  final String? name;
  final List<_Step> steps;
  const _Section(this.name, this.steps);
}

/// Extrait les métadonnées `>> key: value` du texte CookLang.
Map<String, String> _parseMeta(String cooklang) {
  final meta = <String, String>{};
  for (final line in cooklang.split('\n')) {
    final t = line.trim();
    if (!t.startsWith('>>')) continue;
    final rest = t.substring(2).trim();
    final idx = rest.indexOf(':');
    if (idx > 0) {
      meta[rest.substring(0, idx).trim().toLowerCase()] = rest
          .substring(idx + 1)
          .trim();
    }
  }
  return meta;
}

/// Convertit le texte CookLang en sections numérotées sans syntaxe parasite.
List<_Section> _parseSections(String cooklang) {
  final sections = <_Section>[];
  var steps = <_Step>[];
  String? currentSection;

  for (final raw in cooklang.split('\n')) {
    final t = raw.trim();
    if (t.isEmpty) continue;
    if (t.startsWith('>>')) continue;
    if (t.startsWith('--')) continue;

    if (t.startsWith('==')) {
      if (steps.isNotEmpty || currentSection != null) {
        sections.add(_Section(currentSection, List.from(steps)));
        steps = [];
      }
      final name = t.replaceAll('==', '').trim();
      currentSection = name.isEmpty ? null : name;
      continue;
    }

    // Ligne de continuation
    if (t.startsWith('+ ') && t.length > 2 && steps.isNotEmpty) {
      final last = steps.removeLast();
      if (!last.isNote) {
        steps.add(_Step('${last.text}\n${t.substring(2)}'));
        continue;
      }
      steps.add(last); // remettre
    }

    // Image inline isolée : ![pos|width%](url)
    final imgMatch = RegExp(r'^!\[([^\]]*)\]\(([^)]+)\)\s*$').firstMatch(t);
    if (imgMatch != null) {
      final altText = imgMatch.group(1)!.trim().toLowerCase();
      final url = imgMatch.group(2)!;
      final pipeIdx = altText.indexOf('|');
      final pos = pipeIdx >= 0 ? altText.substring(0, pipeIdx).trim() : altText;
      final widthStr = pipeIdx >= 0
          ? altText.substring(pipeIdx + 1).trim().replaceAll('%', '')
          : null;
      final widthPct = widthStr != null ? double.tryParse(widthStr) : null;
      steps.add(
        _Step('', inlineImageUrl: url, imagePos: pos, imagePct: widthPct),
      );
      continue;
    }

    final isNote = t.startsWith('>');
    final text = isNote ? t.substring(1).trim() : _cleanCooklang(t);
    if (text.isNotEmpty) steps.add(_Step(text, isNote: isNote));
  }

  if (steps.isNotEmpty || currentSection != null) {
    sections.add(_Section(currentSection, List.from(steps)));
  }

  return sections;
}

/// Remplace les caractères Unicode hors WinAnsiEncoding d'Helvetica.
/// Seuls U+0000-U+00FF sont sûrs ; les caractères Win-1252 > U+00FF ne sont
/// pas convertis automatiquement par le package pdf — on les normalise ici.
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

/// Supprime la syntaxe CookLang d'une ligne de texte.
String _cleanCooklang(String text) {
  return text
      // @ingredient{qty%unit} → le nom, accordé au nombre.
      //
      // Le nom écrit dans le CookLang est le nom **canonique** — singulier et
      // minuscule, celui qui sert à l'appariement nutritionnel. Injecté brut
      // dans une phrase, il donnait « Émincer finement le poivron, les
      // carotte ». Il ne s'accorde que si l'unité compte des objets : trois
      // cuillères de sauce soja restent « la sauce soja ».
      .replaceAllMapped(RegExp(r'@([^{@#~\n]+)(?:\{([^}]*)\})?'), (m) {
        final name = m.group(1)!.trim();
        final braces = m.group(2) ?? '';
        final parts = braces.split('%');
        return ingredientNameInProse(
          name: name,
          qty: parts.isNotEmpty ? parts[0].trim() : '',
          unit: parts.length > 1 ? parts[1].trim() : '',
        );
      })
      // #equipment{} → equipment
      .replaceAllMapped(
        RegExp(r'#([^{#\n]+)(?:\{[^}]*\})?'),
        (m) => m.group(1)!.trim(),
      )
      // ~timer{value%unit} → "value unit"
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
      // Références images markdown traitées séparément (lignes isolées → _Step)
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]+\)'), '')
      .trim();
}
