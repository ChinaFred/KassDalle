import 'dart:async';
import 'dart:typed_data';
import 'package:firebase_storage/firebase_storage.dart';
import '../domain/recipe.dart';
import '../../../core/services/error_report_service.dart';
import '../../moderation/data/image_moderation_service.dart';
import '../../../core/services/gemini_service.dart';
import '../../../core/utils/app_image_url.dart';

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
  final String? justification;

  const RecipeRefineResult({
    this.cooklang,
    this.titre,
    this.ingredients,
    this.justification,
  });
}

/// Logique métier pour l'écran de revue de brouillon :
/// extraction d'illustrations et raffinement IA.
class DraftReviewService {
  static final ErrorReportService _errorReportService = ErrorReportService();

  /// Télécharge le scan source, demande au serveur les découpes culinaires et
  /// les téléverse sur Firebase Storage.
  ///
  /// Retourne la liste des URLs uploadées (ou [sourceUrl] en repli).
  /// Retourne une liste vide si aucune découpe n'est retenue.
  static Future<IllustrationExtractionResult> extractAndUploadIllustrations({
    required String sourceUrl,
    required String? sourceFileName,
    required String uid,
    required GeminiService gemini,
  }) async {
    final lower = (sourceFileName ?? sourceUrl).toLowerCase();
    final mimeType = lower.endsWith('.png') ? 'image/png' : 'image/jpeg';

    await _requireAppImage(sourceUrl, 'extractAndUploadIllustrations');
    final storageRef = FirebaseStorage.instance.refFromURL(sourceUrl);
    final bytes = await storageRef.getData(30 * 1024 * 1024);
    if (bytes == null) {
      return const IllustrationExtractionResult(urls: [], usedFallback: false);
    }

    // Les découpes viennent du serveur, redressées et triées. Le client les
    // refaisait lui-même à partir des boîtes, au rectangle : sur une page
    // photographiée de biais, chaque illustration gardait ses deux coins de
    // papier et de table.
    final crops = await gemini.detectAndCropIllustrations(bytes, mimeType);
    if (crops.isEmpty) {
      return const IllustrationExtractionResult(urls: [], usedFallback: false);
    }

    // Les découpes partent en UN SEUL appel de modération. Douze appels
    // unitaires coûteraient douze allers-retours, et le reporting ne saurait
    // pas distinguer un lot d'une rafale d'envois individuels — c'est
    // exactement ce que le poste `_batch` existe pour montrer.
    final pending = <PendingImage>[];
    for (var i = 0; i < crops.length; i++) {
      pending.add(
        PendingImage(
          bytes: crops[i],
          filename: 'ill_$i.jpg',
          contentType: 'image/jpeg',
          target: ModerationTarget.draftIllustration,
        ),
      );
    }

    final allUrls = <String>[];
    if (pending.isNotEmpty) {
      try {
        final outcomes = await ImageModerationService().publishAll(pending);
        for (final outcome in outcomes) {
          final url = outcome.url;
          if (url != null) allUrls.add(url);
        }
      } catch (e, st) {
        unawaited(
          _errorReportService.reportError(
            feature: 'draft_review_upload_illustration',
            error: e,
            stackTrace: st,
            context: {
              'uid': uid,
              'source_url': sourceUrl,
              'count': pending.length,
            },
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
        'rest_time': currentTags.restTime,
      },
      currentPortions: currentPortions,
      instruction: instruction,
    );

    final cooklang = raw['cooklang'] as String?;
    final titre = raw['titre'] as String?;
    final justification =
        (raw['justification'] as String?) ?? (raw['explication'] as String?);

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
      justification: (justification?.trim().isNotEmpty ?? false)
          ? justification!.trim()
          : null,
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

  /// Publie une illustration retouchée par l'IA et retourne son URL.
  ///
  /// Origine déclarée « ia ». Le serveur ne la croit pas venant d'un client :
  /// l'image est analysée comme une autre (v0.23.8). Elle emprunte le chemin
  /// de la quarantaine, faute de quoi `illustrations/` ne pourrait pas être
  /// fermé en écriture — et la modération serait contournable par cette porte.
  static Future<String> uploadEnhancedIllustration(
    String uid,
    Uint8List bytes,
  ) async {
    return ImageModerationService().publish(
      PendingImage(
        bytes: bytes,
        filename: 'enhanced.jpg',
        contentType: 'image/jpeg',
        target: ModerationTarget.draftIllustration,
        origin: ModerationOrigin.ai,
      ),
    );
  }

  /// Télécharge les octets d'une image depuis son URL Storage.
  ///
  /// Lève [ForeignImageUrl] sans rien télécharger quand l'URL ne désigne pas
  /// le stockage de l'application (`isAppImageUrl`) : `refFromURL` accepte
  /// n'importe quel bucket.
  static Future<Uint8List?> downloadImageBytes(
    String url, {
    int maxBytes = 20 * 1024 * 1024,
  }) async {
    await _requireAppImage(url, 'downloadImageBytes');
    return FirebaseStorage.instance.refFromURL(url).getData(maxBytes);
  }

  /// Refuse une URL hors du stockage de l'application, et le trace : une
  /// donnée qui pointe ailleurs est une anomalie à retrouver dans les rapports.
  static Future<void> _requireAppImage(String url, String action) async {
    if (isAppImageUrl(url)) return;
    final refusal = ForeignImageUrl(url);
    await _errorReportService.reportError(
      feature: 'draftReviewService.foreignImageUrl',
      error: refusal,
      stackTrace: StackTrace.current,
      context: {'action': action, 'url': url},
    );
    throw refusal;
  }

  /// Publie une illustration ajoutée à la main et retourne son URL.
  ///
  /// Retourne null si [uid] est vide. Lève [ImageNotPublished] si la
  /// modération retient ou refuse l'image : l'écran doit le dire, et ne peut
  /// pas le confondre avec une panne.
  static Future<String?> uploadIllustration(
    Uint8List bytes,
    String fileName,
    String uid,
  ) async {
    if (uid.isEmpty) return null;
    final ext = fileName.contains('.') ? fileName.split('.').last : 'jpg';
    return ImageModerationService().publish(
      PendingImage(
        bytes: bytes,
        filename: fileName,
        contentType: 'image/$ext',
        target: ModerationTarget.draftIllustration,
      ),
    );
  }
}
