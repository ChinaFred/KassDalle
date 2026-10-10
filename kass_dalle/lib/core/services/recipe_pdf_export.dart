import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../utils/ingredient_display.dart';
import '../utils/timer_display.dart';

import 'pdf_download_stub.dart'
    if (dart.library.js_interop) 'pdf_download_web.dart';
import '../../features/annotations/domain/annotation.dart';
import '../../features/recipes/domain/nutrition_contributions.dart';
import '../../features/recipes/domain/recipe.dart';
import '../utils/recipe_portion_scaler.dart';
import 'cooklang_parser.dart';
import 'error_reporting.dart';
import '../utils/recipe_tag_sections.dart';
import '../utils/app_image_url.dart';

// ── Couleurs thématiques ─────────────────────────────────────────────────────

const _kAccent = PdfColor.fromInt(0xFFD84315); // deep orange 800
const _kAccentLight = PdfColor.fromInt(0xFFFBE9E7); // deep orange 50
const _kMuted = PdfColor.fromInt(0xFF757575); // grey 600
const _kDivider = PdfColor.fromInt(0xFFBDBDBD); // grey 400

// ── Ce que le document emporte en plus de la méthode ─────────────────────────

/// Ce que la recette porte, en nombre, avant que l'utilisateur choisisse.
///
/// Le dialogue d'export ne propose que ce qui existe : une case « Inclure les
/// astuces » sur une recette qui n'en a aucune donne un réglage sans objet, et
/// laisse croire qu'il manque quelque chose au document.
class PdfExtraCounts {
  const PdfExtraCounts({
    required this.images,
    required this.notes,
    required this.tips,
    required this.corrections,
    this.nutrition = false,
    this.ingredientLines = 0,
  });

  factory PdfExtraCounts.of(Recipe recipe, List<Annotation> annotations) {
    int compte(AnnotationType type) =>
        annotations.where((a) => a.type == type).length;
    return PdfExtraCounts(
      images: recipe.imageUrls.length,
      notes: compte(AnnotationType.note),
      tips: compte(AnnotationType.tip),
      corrections: compte(AnnotationType.correction),
      nutrition: recipe.nutrition != null,
      ingredientLines: recipe.ingredients
          .where((ingredient) => ingredient.name.trim().isNotEmpty)
          .length,
    );
  }

  final int images;
  final int notes;
  final int tips;
  final int corrections;

  /// La recette porte un calcul nutritionnel. Un compte n'aurait pas de sens :
  /// le bloc existe ou n'existe pas.
  final bool nutrition;

  /// Combien d'ingrédients auraient une ligne dans le détail par ingrédient.
  ///
  /// Sert au seul second interrupteur : proposer « détail par ingrédient » sur
  /// une recette qui n'en liste aucun donnerait un tableau à une ligne.
  final int ingredientLines;

  /// Faux quand il n'y a rien à choisir : le dialogue n'a alors pas lieu d'être.
  bool get hasAny => images + notes + tips + corrections > 0 || nutrition;

  /// Le détail par ingrédient ne se propose que s'il a de quoi se remplir.
  bool get hasNutritionDetails => nutrition && ingredientLines > 0;
}

/// Ce que l'utilisateur a décidé d'emporter dans son PDF.
class PdfExportChoice {
  const PdfExportChoice({
    required this.images,
    required this.notes,
    required this.tips,
    required this.corrections,
    this.nutrition = false,
    this.nutritionDetails = false,
  });

  /// Rien de plus que la recette — l'état quand il n'y a rien à choisir.
  static const rien = PdfExportChoice(
    images: false,
    notes: false,
    tips: false,
    corrections: false,
  );

  final bool images;
  final bool notes;
  final bool tips;
  final bool corrections;

  /// Les valeurs nutritionnelles de synthèse : par portion, recette entière,
  /// et pour 100 g quand le calcul est complet.
  final bool nutrition;

  /// Le détail par ingrédient sous ces valeurs.
  ///
  /// Subordonné à [nutrition] : un tableau d'apports sans le total qu'il
  /// alimente n'aurait rien à quoi se rapporter. [wantsNutritionDetails] tient
  /// cette règle plutôt que le dialogue, pour qu'un réglage mémorisé ne puisse
  /// pas la contourner.
  final bool nutritionDetails;

  /// Vrai quand le détail par ingrédient part réellement dans le document.
  bool get wantsNutritionDetails => nutrition && nutritionDetails;

  /// Vrai si les annotations de ce type partent dans le document.
  bool keeps(AnnotationType type) => switch (type) {
    AnnotationType.note => notes,
    AnnotationType.tip => tips,
    AnnotationType.correction => corrections,
  };

  PdfExportChoice copyWith({
    bool? images,
    bool? notes,
    bool? tips,
    bool? corrections,
    bool? nutrition,
    bool? nutritionDetails,
  }) => PdfExportChoice(
    images: images ?? this.images,
    notes: notes ?? this.notes,
    tips: tips ?? this.tips,
    corrections: corrections ?? this.corrections,
    nutrition: nutrition ?? this.nutrition,
    nutritionDetails: nutritionDetails ?? this.nutritionDetails,
  );
}

/// Ce que le document imprime de la nutrition.
///
/// Construit par l'appelant, qui seul dispose des référentiels d'unités et
/// d'ingrédients : le générateur de PDF ne lit pas Firestore.
class PdfNutritionBlock {
  const PdfNutritionBlock({
    required this.snapshot,
    this.displayedPortions,
    this.contributions,
  });

  final RecipeNutritionSnapshot snapshot;

  /// Les parts pour lesquelles la colonne « par portion » est calculée.
  ///
  /// Le bloc stocké est calculé aux portions de la recette et ne bouge pas :
  /// la division se refait ici, comme à l'écran, pour les parts affichées.
  final int? displayedPortions;

  /// Le détail par ingrédient, quand l'utilisateur l'a demandé. `null` sinon —
  /// le document n'imprime alors que la synthèse.
  final NutritionContributionTable? contributions;
}

/// « Cette recette contient 1 photo, 2 astuces et 1 correction. »
///
/// La phrase se construit ici plutôt que dans l'écran : c'est l'énumération
/// française qui est délicate — virgules partout sauf devant le dernier, et
/// aucune virgule du tout quand il n'y a qu'un élément.
String pdfExtrasSentence(PdfExtraCounts counts) {
  String pluriel(int n, String singulier) => '$n $singulier${n > 1 ? "s" : ""}';
  final morceaux = <String>[
    if (counts.images > 0) pluriel(counts.images, 'photo'),
    if (counts.notes > 0) pluriel(counts.notes, 'remarque'),
    if (counts.tips > 0) pluriel(counts.tips, 'astuce'),
    if (counts.corrections > 0) pluriel(counts.corrections, 'correction'),
    // Ni compté, ni pluriel : le bloc nutritionnel est unique. Il se nomme
    // donc en toutes lettres et ferme l'énumération.
    if (counts.nutrition) 'des valeurs nutritionnelles',
  ];
  if (morceaux.isEmpty) return 'Cette recette ne contient rien de plus.';
  if (morceaux.length == 1) return 'Cette recette contient ${morceaux.first}.';
  final dernier = morceaux.removeLast();
  return 'Cette recette contient ${morceaux.join(', ')} et $dernier.';
}

// ── Point d'entrée public ────────────────────────────────────────────────────

/// Génère le PDF et le télécharge / partage selon la plateforme.
/// Si [includeImages] est true, les photos de la recette sont intégrées.
/// Retourne les bytes et le nom de fichier pour permettre une réouverture.
///
/// [annotations] est la liste **déjà filtrée** par l'appelant : c'est le
/// dialogue d'export qui décide si les remarques, les astuces et les
/// corrections partent, et ce fichier n'a pas à refaire ce tri.
///
/// [userRating] est la note de celui qui imprime, sur 10 — la sienne, pas une
/// moyenne. Une note personnelle imprimée à côté du titre dit à quoi s'attendre
/// d'un plat qu'on a déjà fait.
Future<({Uint8List bytes, String filename})> exportRecipeToPdf(
  Recipe recipe, {
  bool includeImages = false,
  List<Annotation> annotations = const [],
  PdfNutritionBlock? nutrition,
  int? userRating,
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

  final bytes = await buildRecipePdfBytes(
    recipe,
    includeImages: includeImages,
    annotations: annotations,
    nutrition: nutrition,
    userRating: userRating,
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

/// Construit le document, sans le télécharger.
///
/// Séparé d'[exportRecipeToPdf] pour être rendu dans un test : le partage passe
/// par le canal natif de la plateforme, qui n'existe pas en test, alors que
/// c'est la mise en page qui casse — une forme vectorielle mal contrainte lève
/// à la composition, et rien avant l'ouverture du fichier ne le dirait.
Future<Uint8List> buildRecipePdfBytes(
  Recipe recipe, {
  bool includeImages = false,
  List<Annotation> annotations = const [],
  PdfNutritionBlock? nutrition,
  int? userRating,
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
        _header(recipe, bold, regular, oblique, userRating: userRating),
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
            oblique,
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
        // La nutrition suit la méthode : elle décrit ce que la recette donne
        // à manger, ce qui ne se lit qu'une fois su ce qu'elle contient.
        if (nutrition != null) ...[
          _divider(),
          pw.SizedBox(height: 10),
          _nutritionSection(nutrition, bold, regular, oblique),
          pw.SizedBox(height: 20),
        ],
        // Les annotations viennent APRÈS la préparation et AVANT les photos :
        // ce sont des commentaires sur la recette, ils se lisent une fois la
        // méthode connue.
        if (annotations.isNotEmpty) ...[
          _divider(),
          pw.SizedBox(height: 10),
          _annotationsSection(annotations, bold, regular, oblique),
          pw.SizedBox(height: 20),
        ],
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
///
/// Une URL hors du stockage de l'application n'est pas téléchargée
/// (`isAppImageUrl`) : le PDF part sans elle, comme pour une image illisible.
Future<Uint8List?> _fetchImageBytes(String url) async {
  if (!isAppImageUrl(url)) return null;
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
  pw.Font oblique, {
  int? userRating,
}) {
  return pw.Container(
    padding: const pw.EdgeInsets.all(12),
    // Le liseré gauche SANS coins arrondis : le paquet pdf n'accepte un rayon
    // que sur une bordure uniforme, et les deux réunis levaient une assertion à
    // la composition du document. Elle ne se voyait pas — les assertions sont
    // retirées du binaire de production, où la bordure était simplement
    // dessinée de travers. C'est ce qu'a révélé le premier test qui compose
    // vraiment le document.
    decoration: const pw.BoxDecoration(
      color: _kAccentLight,
      border: pw.Border(left: pw.BorderSide(color: _kAccent, width: 4)),
    ),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
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
                  style: pw.TextStyle(
                    font: oblique,
                    fontSize: 10,
                    color: _kMuted,
                  ),
                ),
              ] else ...[
                pw.SizedBox(height: 4),
                pw.Text(
                  'Recette libre',
                  style: pw.TextStyle(
                    font: oblique,
                    fontSize: 10,
                    color: _kMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (userRating != null) ...[
          pw.SizedBox(width: 12),
          _ratingBadge(userRating, bold),
        ],
      ],
    ),
  );
}

/// La note de celui qui imprime, à côté du titre : une étoile et un chiffre.
///
/// Le dénominateur est écrit. À l'écran, « ★ 8 » se comprend parce que le
/// sélecteur de note est à un doigt ; sur une feuille posée sur un plan de
/// travail, rien ne dit si l'échelle va à cinq ou à dix.
pw.Widget _ratingBadge(int rating, pw.Font bold) {
  return pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: const pw.BoxDecoration(
      color: _kAccent,
      borderRadius: pw.BorderRadius.all(pw.Radius.circular(10)),
    ),
    child: pw.Row(
      mainAxisSize: pw.MainAxisSize.min,
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        _star(11, PdfColors.white),
        pw.SizedBox(width: 5),
        pw.Text(
          '$rating/10',
          style: pw.TextStyle(font: bold, fontSize: 12, color: PdfColors.white),
        ),
      ],
    ),
  );
}

/// Une étoile à cinq branches, dessinée en vectoriel.
///
/// Les polices du document sont les Helvetica intégrées au format PDF, qui
/// s'arrêtent à Latin-1 : le caractère ★ (U+2605) n'y existe pas et sortirait
/// en case vide. Embarquer une police pour un seul glyphe coûterait quelques
/// centaines de kilo-octets par fichier. Dix points suffisent, et le document
/// reste entièrement hors-ligne.
pw.Widget _star(double size, PdfColor color) {
  const branches = 5;
  // 0.42 : le rapport qui donne une étoile ni maigre ni bouffie. Plus bas, les
  // branches deviennent des aiguilles ; plus haut, la forme tourne au décagone.
  const creux = 0.42;
  final rayon = size / 2;
  final points = <PdfPoint>[
    for (var i = 0; i < branches * 2; i++)
      () {
        final r = i.isEven ? rayon : rayon * creux;
        // -pi/2 met la première pointe en haut ; le widget Polygon retourne
        // l'axe vertical, donc ces points se lisent comme à l'écran.
        final angle = -math.pi / 2 + i * math.pi / branches;
        return PdfPoint(
          rayon + r * math.cos(angle),
          rayon + r * math.sin(angle),
        );
      }(),
  ];
  return pw.SizedBox(
    width: size,
    height: size,
    child: pw.Polygon(points: points, fillColor: color),
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

  // Le repos vient du champ de la recette, jamais des métadonnées : celles-ci
  // portent la durée telle que le livre l'écrit — « une nuit » —, que le PDF ne
  // sait pas convertir. Le champ, lui, est déjà en minutes.
  final restTime = recipe.tags.restTime;
  if (restTime != null && restTime > 0) {
    items.add(_MetaItem('Repos', formatRestTime(restTime)));
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
  pw.Font oblique,
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
        for (final ing in grouped[cat]!)
          ingredientPdfRow(ing, regular, oblique),
      ],
    ],
  );
}

/// Une ligne d'ingrédient de la fiche imprimée, remarque comprise.
///
/// Publique pour être testée. Une remarque qui disparaît de l'impression ne
/// lève aucune erreur et ne se voit pas à l'écran : c'est précisément le
/// défaut qu'on corrige ici, et le seul moyen de le tenir est de le vérifier.
pw.Widget ingredientPdfRow(
  RecipeIngredient ing,
  pw.Font regular,
  pw.Font oblique,
) {
  // Une seule chaîne, accordée en nombre et liée par « de » : « 3 cuillères à
  // soupe de sauce soja » plutôt que « 3 Cuillère à soupe sauce soja ». Le
  // découpage en trois morceaux collés était la source de la moitié des fautes
  // lues sur une fiche imprimée.
  final libelle = _sanitize(
    formatIngredientDisplay(qty: ing.qty, unit: ing.unit, name: ing.name),
  );

  // La remarque du livre, entre parenthèses, à la suite de l'ingrédient.
  //
  // Elle manquait entièrement à la fiche imprimée. « Avec la peau mais
  // écaillée », « concassés », « à température ambiante » : ce que le livre
  // disait en plus de la quantité s'affichait à l'écran et disparaissait au
  // moment précis où l'on emporte la recette en cuisine.
  //
  // Entre parenthèses et en italique, sur la même ligne : une fiche imprimée
  // n'a pas de place pour une seconde ligne par ingrédient, et le renvoi en
  // bas de bloc a déjà été essayé à l'écran — il obligeait à un aller-retour
  // pour quatre mots.
  final note = ing.note?.trim();
  final hasNote = note != null && note.isNotEmpty;

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
          child: hasNote
              ? pw.RichText(
                  text: pw.TextSpan(
                    style: pw.TextStyle(font: regular, fontSize: 10),
                    children: [
                      pw.TextSpan(text: libelle),
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
                )
              : pw.Text(
                  libelle,
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
                  child: cooklangRichText(
                    step.raw,
                    regular: regular,
                    bold: bold,
                    italic: oblique,
                    fontSize: 9,
                    color: _kMuted,
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
                  child: cooklangRichText(
                    step.raw,
                    regular: regular,
                    bold: bold,
                    fontSize: 10,
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

// ── Remarques, astuces et corrections ────────────────────────────────────

/// Le libellé au pluriel de chaque type d'annotation, dans l'ordre d'impression.
///
/// L'ordre n'est pas alphabétique : il va du plus courant au plus rare, et
/// termine par ce qui reste à faire. Une correction en attente se lit mieux en
/// bas de page qu'entre deux remarques.
const _kAnnotationOrdre = <AnnotationType, String>{
  AnnotationType.note: 'REMARQUES',
  AnnotationType.tip: 'ASTUCES',
  AnnotationType.correction: 'CORRECTIONS',
};

/// Les annotations retenues à l'export, groupées par type.
///
/// Le tri par type est refait ici plutôt que demandé à l'appelant : il décide
/// de ce qui part, pas de la mise en page.
pw.Widget _annotationsSection(
  List<Annotation> annotations,
  pw.Font bold,
  pw.Font regular,
  pw.Font oblique,
) {
  final blocs = <pw.Widget>[];
  for (final entry in _kAnnotationOrdre.entries) {
    final duType = annotations.where((a) => a.type == entry.key).toList();
    if (duType.isEmpty) continue;
    if (blocs.isNotEmpty) blocs.add(pw.SizedBox(height: 12));
    blocs.add(_sectionTitle(entry.value, bold));
    blocs.add(pw.SizedBox(height: 6));
    for (final annotation in duType) {
      blocs.add(_annotationRow(annotation, regular, oblique));
    }
  }
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: blocs,
  );
}

pw.Widget _annotationRow(
  Annotation annotation,
  pw.Font regular,
  pw.Font oblique,
) {
  final auteur = annotation.authorName.trim();
  return pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 5),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(width: 8),
        pw.Text(
          '- ',
          style: pw.TextStyle(font: regular, fontSize: 10, color: _kAccent),
        ),
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                _sanitize(annotation.text),
                style: pw.TextStyle(
                  font: regular,
                  fontSize: 10,
                  color: PdfColor.fromInt(0xFF212121),
                ),
              ),
              // Le nom de l'auteur suit le texte, en petit : une astuce vaut
              // par qui l'a écrite, mais elle se lit avant lui.
              if (auteur.isNotEmpty)
                pw.Text(
                  _sanitize(auteur),
                  style: pw.TextStyle(
                    font: oblique,
                    fontSize: 8,
                    color: _kMuted,
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

// ── Valeurs nutritionnelles ──────────────────────────────────────────────────

/// L'unité d'un nutriment : les calories se comptent en kcal, le reste en g.
String _nutritionUnit(String key) => key == 'kcal' ? 'kcal' : 'g';

/// Une valeur de la synthèse, unité comprise, ou un tiret seul.
String _nutritionSummaryValue(Map<String, double>? values, String key) {
  final value = values?[key];
  if (value == null) return '-';
  return '${formatNutritionValue(value, integer: key == 'kcal')} '
      '${_nutritionUnit(key)}';
}

pw.Widget _nutritionCell(
  String text,
  pw.Font font, {
  double fontSize = 9,
  PdfColor? color,
  pw.Alignment alignment = pw.Alignment.centerRight,
}) {
  return pw.Container(
    alignment: alignment,
    padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 3),
    child: pw.Text(
      _sanitize(text),
      style: pw.TextStyle(font: font, fontSize: fontSize, color: color),
    ),
  );
}

/// La synthèse, et sous elle le détail par ingrédient quand il a été demandé.
///
/// Le document n'arbitre pas : ce qu'il reçoit, il l'imprime. Le tri appartient
/// au dialogue d'export, comme pour les annotations.
pw.Widget _nutritionSection(
  PdfNutritionBlock block,
  pw.Font bold,
  pw.Font regular,
  pw.Font oblique,
) {
  final snapshot = block.snapshot;
  final portions = block.displayedPortions ?? snapshot.selectedPortions;
  final perPortion = snapshot.perPortionFor(block.displayedPortions);
  // Le calcul partiel masque la vue pour 100 g, à l'écran comme ici : elle
  // rapporterait les valeurs d'une partie de la recette au poids du tout.
  final per100g = snapshot.per100g;
  final contributions = block.contributions;

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      _sectionTitle('VALEURS NUTRITIONNELLES', bold),
      pw.SizedBox(height: 6),
      pw.Text(
        _sanitize(
          'Couverture ${(snapshot.coverage * 100).toStringAsFixed(0)} % - '
          'Fiabilite ${snapshot.quality.level} '
          '(${snapshot.quality.score}/100) - '
          '${_coverageStateLabel(snapshot.coverageState)}',
        ),
        style: pw.TextStyle(font: oblique, fontSize: 9, color: _kMuted),
      ),
      pw.SizedBox(height: 6),
      pw.Table(
        border: const pw.TableBorder(
          horizontalInside: pw.BorderSide(color: _kDivider, width: 0.5),
        ),
        columnWidths: {
          0: const pw.FlexColumnWidth(2.2),
          1: const pw.FlexColumnWidth(1.4),
          2: const pw.FlexColumnWidth(1.4),
          if (per100g != null) 3: const pw.FlexColumnWidth(1.4),
        },
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: _kAccentLight),
            children: [
              _nutritionCell(
                'Nutriment',
                bold,
                alignment: pw.Alignment.centerLeft,
              ),
              _nutritionCell(
                portions > 0 ? 'Par portion ($portions parts)' : 'Par portion',
                bold,
              ),
              _nutritionCell('Recette', bold),
              if (per100g != null) _nutritionCell('Pour 100 g', bold),
            ],
          ),
          for (final metric in kNutritionMetricKeys)
            pw.TableRow(
              children: [
                _nutritionCell(
                  metric.$2,
                  regular,
                  alignment: pw.Alignment.centerLeft,
                ),
                _nutritionCell(
                  _nutritionSummaryValue(perPortion, metric.$1),
                  regular,
                ),
                _nutritionCell(
                  _nutritionSummaryValue(snapshot.totals, metric.$1),
                  regular,
                ),
                if (per100g != null)
                  _nutritionCell(
                    _nutritionSummaryValue(per100g, metric.$1),
                    regular,
                  ),
              ],
            ),
        ],
      ),
      // Ce que le calcul lui-même signale. Imprimé sans mise en garde, un
      // total dont les calories ne collent pas aux macronutriments se lirait
      // comme une mesure.
      if (snapshot.quality.warnings.isNotEmpty) ...[
        pw.SizedBox(height: 6),
        for (final warning in snapshot.quality.warnings)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 2),
            child: pw.Text(
              _sanitize('- $warning'),
              style: pw.TextStyle(font: oblique, fontSize: 8, color: _kAccent),
            ),
          ),
      ],
      if (contributions != null) ...[
        pw.SizedBox(height: 12),
        _nutritionContributionsTable(contributions, bold, regular, oblique),
      ],
    ],
  );
}

/// Libellé français de l'état de couverture renvoyé par le backend.
String _coverageStateLabel(String state) => switch (state) {
  'full' => 'Calcul complet',
  'partial' => 'Calcul partiel',
  'low' => 'Calcul incomplet',
  'failed' => 'Calcul en échec',
  _ => 'État inconnu',
};

/// Le tableau des apports, une ligne par ingrédient, le total en tête.
///
/// Dix colonnes sur une A4 portrait : les valeurs descendent à 7 points et les
/// en-têtes à 6,5. En dessous, la colonne des noms ne tient plus « chapelure de
/// pain de mie » sur deux lignes.
pw.Widget _nutritionContributionsTable(
  NutritionContributionTable table,
  pw.Font bold,
  pw.Font regular,
  pw.Font oblique,
) {
  const nomLargeur = 110.0;
  const quantiteLargeur = 52.0;
  const metriqueLargeur = 40.0;
  final absorbedOil = table.absorbedOil;

  pw.TableRow ligne({
    required String nom,
    required String quantite,
    required Map<String, double>? valeurs,
    required pw.Font font,
    PdfColor? color,
  }) {
    return pw.TableRow(
      children: [
        _nutritionCell(
          nom,
          font,
          fontSize: 7,
          color: color,
          alignment: pw.Alignment.centerLeft,
        ),
        _nutritionCell(quantite, font, fontSize: 7, color: color),
        for (final metric in kNutritionMetricKeys)
          _nutritionCell(
            formatNutritionValue(
              valeurs?[metric.$1],
              integer: metric.$1 == 'kcal',
            ),
            font,
            fontSize: 7,
            color: color,
          ),
      ],
    );
  }

  /// L'huile que la friture a fait passer du bain à l'assiette.
  ///
  /// [nested] la range sous le bain qui l'a produite : les deux lignes se
  /// lisent alors comme une seule idée — on jette le litre, on mange les 55 g.
  pw.TableRow ligneHuile(RecipeAbsorbedOil oil, {required bool nested}) =>
      ligne(
        nom: nested ? '   dont absorbée' : '${oil.sourceName} absorbée',
        quantite: '${oil.grams.toStringAsFixed(0)} g',
        valeurs: oil.contribution,
        font: oblique,
        color: _kMuted,
      );

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        'Apports par ingrédient',
        style: pw.TextStyle(
          font: bold,
          fontSize: 10,
          color: PdfColor.fromInt(0xFF212121),
        ),
      ),
      pw.SizedBox(height: 4),
      pw.Table(
        border: const pw.TableBorder(
          horizontalInside: pw.BorderSide(color: _kDivider, width: 0.5),
        ),
        columnWidths: {
          0: const pw.FixedColumnWidth(nomLargeur),
          1: const pw.FixedColumnWidth(quantiteLargeur),
          for (var i = 0; i < kNutritionMetricKeys.length; i++)
            i + 2: const pw.FixedColumnWidth(metriqueLargeur),
        },
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: _kAccentLight),
            children: [
              _nutritionCell(
                'Ingrédient',
                bold,
                fontSize: 6.5,
                alignment: pw.Alignment.centerLeft,
              ),
              _nutritionCell('Quantité', bold, fontSize: 6.5),
              for (final metric in kNutritionMetricKeys)
                _nutritionCell(metric.$2, bold, fontSize: 6.5),
            ],
          ),
          // Le total ouvre le tableau, comme à l'écran : c'est le chiffre
          // qu'on vient chercher, les lignes en dessous l'expliquent.
          pw.TableRow(
            children: [
              _nutritionCell(
                'TOTAL',
                bold,
                fontSize: 7,
                alignment: pw.Alignment.centerLeft,
              ),
              _nutritionCell(
                table.knownWeight > 0
                    ? '${table.knownWeight.toStringAsFixed(0)} g'
                    : '-',
                bold,
                fontSize: 7,
              ),
              for (final metric in kNutritionMetricKeys)
                _nutritionCell(
                  formatNutritionValue(
                    table.totalFor(metric.$1),
                    integer: metric.$1 == 'kcal',
                  ),
                  bold,
                  fontSize: 7,
                ),
            ],
          ),
          for (final row in table.rows) ...[
            ligne(
              // Ce qui sort du total le dit sur la ligne : sans tooltip pour
              // l'expliquer, un nom en italique ne suffirait pas sur papier.
              nom: row.isExcluded
                  ? '${row.ingredient.name} (hors total)'
                  : row.isMissing
                  ? '${row.ingredient.name} (sans valeur)'
                  : row.ingredient.name,
              quantite: nutritionQuantityCellText(row),
              valeurs: row.perIngredient,
              font: row.isExcluded ? oblique : regular,
              color: row.isExcluded ? _kMuted : null,
            ),
            if (absorbedOil != null && table.isAbsorbedOilSource(row))
              ligneHuile(absorbedOil, nested: true),
          ],
          // Le bain n'est pas listé, ou sous un nom que le serveur n'a pas
          // retenu : la ligne dérivée ferme le tableau plutôt que de
          // disparaître.
          if (absorbedOil != null && table.hasOrphanAbsorbedOil)
            ligneHuile(absorbedOil, nested: false),
        ],
      ),
      if (table.needsLegend) ...[
        pw.SizedBox(height: 6),
        for (final entry in nutritionLegendEntries(table))
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 2),
            child: pw.Text(
              _sanitize('- ${entry.label}'),
              style: pw.TextStyle(font: oblique, fontSize: 7, color: _kMuted),
            ),
          ),
      ],
    ],
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
  /// Le texte débarrassé de la syntaxe — sert à savoir si la ligne est vide,
  /// et de repli si le rendu enrichi ne s'applique pas.
  final String text;

  /// La ligne CookLang d'origine, avec ses jetons : c'est elle que le rendu
  /// transforme en badges.
  final String raw;
  final bool isNote;

  /// URL d’une image inline (ligne isolée !… dans le CookLang).
  final String? inlineImageUrl;

  /// Position de l'image : 'left', 'right', ou '' (bloc centré).
  final String imagePos;

  /// Largeur de l'image en % de la largeur de contenu (null = défaut selon position).
  final double? imagePct;
  const _Step(
    this.text, {
    this.raw = '',
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
    // La ligne d'origine, jetons compris : c'est elle que le rendu balise.
    final source = isNote ? t.substring(1).trim() : t;
    final text = isNote ? source : _cleanCooklang(t);
    if (text.isNotEmpty) steps.add(_Step(text, raw: source, isNote: isNote));
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

// ── Badges CookLang dans le PDF ──────────────────────────────────────────────

/// Fond des ingrédients : la teinte d'accent du document, en clair.
const _kBadgeIngredientBg = _kAccentLight;
const _kBadgeIngredientFg = PdfColor.fromInt(0xFF8A3212);

/// Fond du matériel et des minuteurs : gris, pour ne pas concurrencer
/// l'ingrédient — c'est lui qu'on cherche des yeux en cuisinant.
const _kBadgeToolBg = PdfColor.fromInt(0xFFEEEEEE);
const _kBadgeToolFg = PdfColor.fromInt(0xFF424242);

/// Espace insécable de respiration autour du texte d'un badge.
///
/// Une `BoxDecoration` de span épouse les glyphes sans marge : sans ces deux
/// espaces, le fond colle aux lettres et le badge paraît sale.
const _kBadgePad = '\u00A0';

/// Une étape rendue **avec ses badges**, comme à l'écran.
///
/// Le PDF imprimait le CookLang débarrassé de sa syntaxe : « Émincer finement
/// le poivron, les carotte » — le lecteur ne pouvait pas savoir que « carotte »
/// n'était pas un mot de la phrase mais une **référence structurée**, reprise
/// telle quelle de la liste d'ingrédients. D'où deux gênes à la lecture : une
/// faute d'accord apparente, et une syntaxe invisible.
///
/// Le badge résout les deux d'un coup, exactement comme la puce le fait à
/// l'écran : il sort le jeton du fil de la phrase. « les ⟦2 carottes⟧ » se lit
/// sans heurt, parce que le badge s'annonce comme une donnée et non comme un
/// mot accordé.
pw.Widget cooklangRichText(
  String raw, {
  required pw.Font regular,
  required pw.Font bold,
  required double fontSize,
  PdfColor? color,
  pw.Font? italic,
}) {
  final spans = <pw.InlineSpan>[];
  final baseStyle = pw.TextStyle(
    font: italic ?? regular,
    fontSize: fontSize,
    color: color,
  );

  pw.TextStyle badge(PdfColor bg, PdfColor fg) => pw.TextStyle(
    font: bold,
    fontSize: fontSize - 0.5,
    color: fg,
    background: pw.BoxDecoration(
      color: bg,
      borderRadius: pw.BorderRadius.circular(2),
    ),
  );

  void addText(String text) {
    if (text.isEmpty) return;
    spans.add(pw.TextSpan(text: _sanitize(text), style: baseStyle));
  }

  void addBadge(String label, PdfColor bg, PdfColor fg) {
    final clean = _sanitize(label).trim();
    if (clean.isEmpty) return;
    spans.add(
      pw.TextSpan(text: '$_kBadgePad$clean$_kBadgePad', style: badge(bg, fg)),
    );
  }

  final re = RegExp(
    r'(@[^{@#~\n]+\{[^}]*\}|#[^{@#~\n]+\{[^}]*\}|~[^{@#~\s]*\{[^}]*\})',
  );
  var cursor = 0;
  for (final match in re.allMatches(raw)) {
    addText(raw.substring(cursor, match.start));
    final token = match.group(0)!;
    final braceIdx = token.indexOf('{');
    final name = token.substring(1, braceIdx).trim();
    final content = token.substring(braceIdx + 1, token.length - 1);

    if (token.startsWith('@')) {
      final parts = content.split('%');
      addBadge(
        formatIngredientDisplay(
          qty: parts.isNotEmpty ? parts[0].trim() : '',
          unit: parts.length > 1 ? parts[1].trim() : '',
          name: name,
        ),
        _kBadgeIngredientBg,
        _kBadgeIngredientFg,
      );
    } else if (token.startsWith('#')) {
      addBadge(name, _kBadgeToolBg, _kBadgeToolFg);
    } else {
      addBadge(cooklangFormatTimer(content), _kBadgeToolBg, _kBadgeToolFg);
    }
    cursor = match.end;
  }
  addText(raw.substring(cursor));

  // Les références d'images markdown n'ont rien à faire dans une phrase.
  return pw.RichText(text: pw.TextSpan(children: spans));
}

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
          // Dans la prose, un ingrédient s'écrit le plus souvent sans
          // quantité : c'est l'article qui donne le nombre.
          before: m.input.substring(0, m.start),
        );
      })
      // #equipment{} → equipment
      .replaceAllMapped(
        RegExp(r'#([^{#\n]+)(?:\{[^}]*\})?'),
        (m) => m.group(1)!.trim(),
      )
      // ~timer{0:12:00} → « 12 minutes », comme dans l'application. La valeur
      // brute était imprimée telle quelle : « Cuire 0:12:00 ».
      .replaceAllMapped(RegExp(r'~[^{~\n]*(?:\{([^}]*)\})?'), (m) {
        final braces = m.group(1) ?? '';
        return braces.isEmpty ? '' : cooklangFormatTimer(braces);
      })
      // Références images markdown traitées séparément (lignes isolées → _Step)
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]+\)'), '')
      .trim();
}
