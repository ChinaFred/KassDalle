import 'dart:async';
import 'dart:typed_data';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image/image.dart' as img;
import '../domain/recipe.dart';
import '../../../core/services/error_report_service.dart';
import '../../../core/services/gemini_service.dart';

/// Résultat d'une extraction d'illustrations depuis un scan.
class IllustrationExtractionResult {
  final List<String> urls;
  final bool usedFallback;

  const IllustrationExtractionResult({
    required this.urls,
    required this.usedFallback,
  });
}

/// Résultat d'un raffinement IA d'une recette.
class RecipeRefineResult {
  final String? cooklang;
  final String? titre;
  final List<RecipeIngredient>? ingredients;

  const RecipeRefineResult({this.cooklang, this.titre, this.ingredients});
}

/// Logique métier pour l'écran de revue de brouillon :
/// extraction d'illustrations et raffinement IA.
class DraftReviewService {
  static final ErrorReportService _errorReportService = ErrorReportService();

  /// Télécharge le scan source, détecte les régions culinaires via Gemini,
  /// recadre les images et les upload sur Firebase Storage.
  ///
  /// Retourne la liste des URLs uploadées (ou [sourceUrl] en repli).
  /// Retourne une liste vide si aucune région n'est détectée.
  static Future<IllustrationExtractionResult> extractAndUploadIllustrations({
    required String sourceUrl,
    required String? sourceFileName,
    required String uid,
    required GeminiService gemini,
  }) async {
    final lower = (sourceFileName ?? sourceUrl).toLowerCase();
    final mimeType = lower.endsWith('.png') ? 'image/png' : 'image/jpeg';

    final storageRef = FirebaseStorage.instance.refFromURL(sourceUrl);
    final bytes = await storageRef.getData(30 * 1024 * 1024);
    if (bytes == null) {
      return const IllustrationExtractionResult(urls: [], usedFallback: false);
    }

    var regions = await gemini.detectIllustrationRegions(bytes, mimeType);
    if (regions.isEmpty) {
      final singleBox = await gemini.detectMainCulinaryPhoto(bytes, mimeType);
      if (singleBox != null) regions = [singleBox];
    }

    if (regions.isEmpty) {
      return const IllustrationExtractionResult(urls: [], usedFallback: false);
    }

    final srcImage = img.decodeImage(bytes);
    if (srcImage == null) {
      return IllustrationExtractionResult(
        urls: [sourceUrl],
        usedFallback: true,
      );
    }

    final allUrls = <String>[];
    for (var i = 0; i < regions.length; i++) {
      final box = regions[i]; // [yMin, xMin, yMax, xMax] en millièmes
      final x = (box[1] * srcImage.width / 1000).round();
      final y = (box[0] * srcImage.height / 1000).round();
      final w = ((box[3] - box[1]) * srcImage.width / 1000).round();
      final h = ((box[2] - box[0]) * srcImage.height / 1000).round();
      if (w <= 50 || h <= 50) continue;

      final cropped = img.copyCrop(srcImage, x: x, y: y, width: w, height: h);
      final croppedBytes = Uint8List.fromList(
        img.encodeJpg(cropped, quality: 85),
      );

      try {
        final ts = DateTime.now().millisecondsSinceEpoch;
        final path = 'illustrations/$uid/${ts}_ill_$i.jpg';
        final ref = FirebaseStorage.instance.ref(path);
        final snap = await ref.putData(
          croppedBytes,
          SettableMetadata(contentType: 'image/jpeg'),
        );
        allUrls.add(await snap.ref.getDownloadURL());
      } catch (e, st) {
        unawaited(
          _errorReportService.reportError(
            feature: 'draft_review_upload_illustration',
            error: e,
            stackTrace: st,
            context: {'uid': uid, 'source_url': sourceUrl, 'index': i},
          ),
        );
      }
    }

    if (allUrls.isEmpty) {
      return IllustrationExtractionResult(
        urls: [sourceUrl],
        usedFallback: true,
      );
    }
    return IllustrationExtractionResult(urls: allUrls, usedFallback: false);
  }

  /// Appelle `gemini.refineRecipe` et retourne le résultat structuré.
  static Future<RecipeRefineResult> refineRecipe({
    required GeminiService gemini,
    required String currentTitre,
    required String currentCooklang,
    required List<RecipeIngredient> formIngredients,
    required RecipeTags currentTags,
    required int? currentPortions,
    required String instruction,
  }) async {
    final raw = await gemini.refineRecipe(
      currentTitre: currentTitre,
      currentCooklang: currentCooklang,
      currentIngredients: formIngredients
          .map((i) => {'name': i.name, 'qty': i.qty, 'unit': i.unit})
          .toList(),
      currentTags: {
        'themes': currentTags.themes,
        'cuisines': currentTags.cuisines,
        'difficulty': currentTags.difficulty,
        'prep_time': currentTags.prepTime,
        'cook_time': currentTags.cookTime,
      },
      currentPortions: currentPortions,
      instruction: instruction,
    );

    final cooklang = raw['cooklang'] as String?;
    final titre = raw['titre'] as String?;

    final ingredientsRaw = raw['ingredients'] as List?;
    final ingredients = ingredientsRaw?.map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      return RecipeIngredient(
        name: m['name'] as String? ?? '',
        qty: m['qty'] as String? ?? '',
        unit: m['unit'] as String? ?? '',
      );
    }).toList();

    return RecipeRefineResult(
      cooklang: (cooklang?.isNotEmpty ?? false) ? cooklang : null,
      titre: (titre?.isNotEmpty ?? false) ? titre : null,
      ingredients: ingredients,
    );
  }

  /// Appelle `gemini.polishMarkdown` pour corriger l'orthographe et la mise
  /// en forme d'un document non-recette sans en modifier le contenu.
  static Future<String?> polishMarkdownContent({
    required GeminiService gemini,
    required String markdown,
    String? instruction,
  }) => gemini.polishMarkdown(markdown, instruction: instruction);

  /// Délègue à `gemini.enhanceIllustration` — encapsule l'appel AI pour cohérence.
  static Future<void> enhanceIllustration({
    required GeminiService gemini,
    required String recipeId,
    required String illustrationUrl,
  }) => gemini.enhanceIllustration(
    recipeId: recipeId,
    illustrationUrl: illustrationUrl,
  );

  /// Retourne true si l'URL ou le nom de fichier correspond à une image JPEG/PNG.
  static bool isImageUrl(String? url, String? fileName) {
    final lower = (fileName ?? url ?? '').toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png');
  }

  /// Upload une illustration améliorée sur Storage et retourne son URL.
  static Future<String> uploadEnhancedIllustration(
    String uid,
    Uint8List bytes,
  ) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final snap = await FirebaseStorage.instance
        .ref('illustrations/$uid/${ts}_enhanced.jpg')
        .putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    return snap.ref.getDownloadURL();
  }

  /// Télécharge les octets d'une image depuis son URL Storage.
  static Future<Uint8List?> downloadImageBytes(
    String url, {
    int maxBytes = 20 * 1024 * 1024,
  }) => FirebaseStorage.instance.refFromURL(url).getData(maxBytes);

  /// Upload une illustration sur Firebase Storage et retourne son URL de téléchargement.
  /// Retourne null en cas d'erreur ou si [uid] est vide.
  static Future<String?> uploadIllustration(
    Uint8List bytes,
    String fileName,
    String uid,
  ) async {
    if (uid.isEmpty) return null;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ext = fileName.contains('.') ? fileName.split('.').last : 'jpg';
    final snap = await FirebaseStorage.instance
        .ref('illustrations/$uid/${ts}_editor.$ext')
        .putData(bytes, SettableMetadata(contentType: 'image/$ext'));
    return await snap.ref.getDownloadURL();
  }
}
