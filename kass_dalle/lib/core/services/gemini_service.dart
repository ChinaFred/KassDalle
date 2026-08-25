/// Service d'extraction de recettes via Gemini — version distante (Cloud Functions).
///
/// Remplace la version qui appelait Gemini directement avec la clé API.
/// Tous les appels passent par des HTTPS Callable Functions, ce qui :
///  - garde la clé API uniquement dans Secret Manager côté backend ;
///  - centralise le logging (Cloud Logging) et le suivi des tokens (Firestore) ;
///  - facilite la résilience (les Functions gèrent le retry quota côté serveur).
///
/// API publique 100 % compatible avec l'ancien [GeminiService] : drop-in.
library;

import 'dart:async';
import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'error_report_service.dart';
import '../../features/recipes/domain/recipe.dart';

/// Région des Cloud Functions Kass'Dalle (cf. functions/src/config.ts).
const String _functionsRegion = 'europe-west1';

/// Project ID Firebase — utilisé pour bâtir l'URL des callables en bypass web.
const String _firebaseProjectId = 'kassdale-6d948';

/// Service d'appels Gemini côté client — tout passe par Cloud Functions.
///
/// La clé API est gérée côté backend via Secret Manager.
///
/// [onTokenUsage] est conservé pour compatibilité, mais le suivi
/// des tokens est désormais fait directement par les Cloud Functions dans
/// Firestore (`token_usage/{uid}`). Le callback ne sera donc pas invoqué.
class GeminiService {
  // Nullable : sur web on n'initialise jamais le SDK cloud_functions_web
  // (bug Int64 accessor non supporté par dart2js).
  FirebaseFunctions? _functions;
  // ignore: unused_field
  final Future<void> Function(
    String feature,
    int inputTokens,
    int outputTokens,
    int totalTokens,
  )?
  onTokenUsage;

  GeminiService({this.onTokenUsage});

  /// Constructeur explicite pour les tests / injection.
  GeminiService.withFunctions(FirebaseFunctions functions, {this.onTokenUsage})
    : _functions = functions;

  FirebaseFunctions _ensureFunctions() {
    return _functions ??= FirebaseFunctions.instanceFor(
      region: _functionsRegion,
    );
  }

  HttpsCallable _callable(String name) => _ensureFunctions().httpsCallable(
    name,
    options: HttpsCallableOptions(timeout: const Duration(minutes: 9)),
  );

  /// Récupère le `data` typé d'une réponse callable en gérant les erreurs.
  ///
  /// Sur web, on bypass le SDK `cloud_functions_web` qui a un bug persistant
  /// ("Int64 accessor not supported by dart2js") en faisant un POST HTTP
  /// direct vers le endpoint de la callable. Sur mobile/desktop on garde le
  /// SDK natif qui marche bien.
  Future<dynamic> _call(String name, Map<String, dynamic> payload) async {
    if (kIsWeb) {
      return _callViaHttp(name, payload);
    }
    try {
      final result = await _callable(name).call<dynamic>(payload);
      return result.data;
    } on FirebaseFunctionsException catch (e) {
      unawaited(
        ErrorReportService().reportError(
          feature: 'gemini_callable_sdk:$name',
          error: e,
          context: {'code': e.code, 'details': e.details},
        ),
      );
      throw GeminiCallableException(e.code, e.message ?? '', e.details);
    } catch (e, st) {
      unawaited(
        ErrorReportService().reportError(
          feature: 'gemini_callable_sdk:$name',
          error: e,
          stackTrace: st,
          context: {'payload_keys': payload.keys.toList(growable: false)},
        ),
      );
      rethrow;
    }
  }

  /// Appel HTTP direct au endpoint callable (web uniquement).
  /// Format Firebase Callable : body `{"data": {...}}`, response `{"result": {...}}`.
  Future<dynamic> _callViaHttp(
    String name,
    Map<String, dynamic> payload,
  ) async {
    debugPrint('[geminiHttp] $name → start');
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw GeminiCallableException(
        'unauthenticated',
        'Utilisateur non connecté.',
        null,
      );
    }
    String? idToken;
    try {
      idToken = await user.getIdToken();
      debugPrint(
        '[geminiHttp] $name → got token (${idToken?.length ?? 0} chars)',
      );
    } catch (e, st) {
      debugPrint('[geminiHttp] $name → getIdToken FAILED: $e\n$st');
      unawaited(
        ErrorReportService().reportError(
          feature: 'gemini_http_get_id_token:$name',
          error: e,
          stackTrace: st,
          context: {'user_id': user.uid},
        ),
      );
      rethrow;
    }
    final url = Uri.parse(
      'https://$_functionsRegion-$_firebaseProjectId.cloudfunctions.net/$name',
    );
    debugPrint('[geminiHttp] $name → POST $url');
    final http.Response res;
    try {
      res = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $idToken',
        },
        body: jsonEncode({'data': payload}),
      );
    } catch (e, st) {
      debugPrint('[geminiHttp] $name → http.post FAILED: $e\n$st');
      unawaited(
        ErrorReportService().reportError(
          feature: 'gemini_http_post:$name',
          error: e,
          stackTrace: st,
          context: {'url': url.toString()},
        ),
      );
      rethrow;
    }
    debugPrint(
      '[geminiHttp] $name → HTTP ${res.statusCode} (${res.body.length} bytes)',
    );
    if (res.statusCode != 200) {
      String code = 'internal';
      String message = 'HTTP ${res.statusCode}';
      dynamic details;
      try {
        final err = jsonDecode(res.body) as Map<String, dynamic>;
        final errObj = err['error'] as Map<String, dynamic>?;
        if (errObj != null) {
          code = (errObj['status'] as String?)?.toLowerCase() ?? code;
          message = (errObj['message'] as String?) ?? message;
          details = errObj['details'];
        }
      } catch (e, st) {
        unawaited(
          ErrorReportService().reportError(
            feature: 'gemini_http_error_decode:$name',
            error: e,
            stackTrace: st,
            context: {'status_code': res.statusCode},
          ),
        );
      }
      throw GeminiCallableException(code, message, details);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['result'];
  }

  // ── Détection illustrations ─────────────────────────────────────────────────

  /// Découpes retenues par le serveur, prêtes à téléverser.
  ///
  /// Le serveur détecte, redresse la perspective et écarte ce qui n'est pas une
  /// photographie. Le client recevait auparavant les boîtes et refaisait la
  /// découpe au rectangle : le redressement était calculé, facturé, puis jeté.
  Future<List<Uint8List>> detectAndCropIllustrations(
    Uint8List bytes,
    String mimeType,
  ) async {
    final data = await _call('detectAndCropIllustrationsFn', {
      'bytesBase64': base64Encode(bytes),
      'mimeType': mimeType,
    });
    return (data['cropsBase64'] as List? ?? [])
        .map((e) => base64Decode(e as String))
        .toList();
  }

  /// Améliore une illustration existante (perspective + couleurs) via Gemini
  /// Image. Réservé aux administrateurs côté backend.
  ///
  /// Le backend télécharge l'image depuis [illustrationUrl], appelle Gemini,
  /// upload le résultat dans Storage et remplace l'URL dans
  /// `recipes/{recipeId}.image_urls`. Retourne la nouvelle URL.
  Future<String> enhanceIllustration({
    required String recipeId,
    required String illustrationUrl,
  }) async {
    final data = await _call('enhanceIllustrationFn', {
      'recipeId': recipeId,
      'illustrationUrl': illustrationUrl,
    });
    return data['enhancedUrl'] as String;
  }

  /// Génère une illustration photo-réaliste pour une recette / un plat.
  Future<String> generateRecipeIllustration({
    required String recipeTitle,
    required String recipeContext,
    String? userInstruction,
    String? style,
  }) async {
    final data = await _call('generateRecipeIllustrationFn', {
      'recipeTitle': recipeTitle,
      'recipeContext': recipeContext,
      if (userInstruction != null && userInstruction.isNotEmpty)
        'userInstruction': userInstruction,
      if (style != null && style.isNotEmpty) 'style': style,
    });
    return data['generatedUrl'] as String;
  }

  // ── Dressage ────────────────────────────────────────────────────────────────

  /// Demande un conseil de dressage propre à cette recette.
  ///
  /// Le backend lit la recette, appelle le moteur et écrit le résultat sur le
  /// document : l'appel n'est donc pas idempotent en coût, il ne doit partir
  /// que sur un geste explicite de l'utilisateur.
  Future<Map<String, dynamic>> suggestPlating({
    required String recipeId,
    String? userInstruction,
  }) async {
    final data = await _call('suggestPlatingFn', {
      'recipeId': recipeId,
      if (userInstruction != null && userInstruction.isNotEmpty)
        'userInstruction': userInstruction,
    });
    return Map<String, dynamic>.from(data['platingAdvice'] as Map);
  }

  /// Grille tarifaire en vigueur, pour l'écran d'administration.
  ///
  /// Passe par la Cloud Function parce qu'elle seule connaît la table
  /// d'amorçage, et peut donc dire quels tarifs ont été modifiés depuis. Le
  /// client ne porte plus de prix.
  Future<List<Map<String, dynamic>>> getAiPricing() async {
    final data = await _call('getAiPricingFn', const <String, dynamic>{});
    final models = (data as Map)['models'] as List? ?? const [];
    return models
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList(growable: false);
  }

  /// Enregistre le tarif d'un modèle dans la grille en vigueur.
  ///
  /// [pricing] à `null` retire la surcouche : le modèle repasse au tarif livré
  /// avec le code.
  Future<void> setAiPricing({
    required String model,
    required Map<String, dynamic>? pricing,
  }) async {
    await _call('setAiPricingFn', {'model': model, 'pricing': pricing});
  }

  /// Conseil de conservation et de réchauffage d'une recette.
  ///
  /// La Cloud Function écrit elle-même le conseil sur la recette et le renvoie.
  Future<Map<String, dynamic>> suggestStorageAdvice({
    required String recipeId,
  }) async {
    final data = await _call('suggestStorageAdviceFn', {'recipeId': recipeId});
    return Map<String, dynamic>.from(data['storageAdvice'] as Map);
  }

  /// Génère le visuel de montage d'une étape du conseil de dressage.
  Future<String> generatePlatingImage({
    required String recipeId,
    required int stepIndex,
  }) async {
    final data = await _call('generatePlatingImageFn', {
      'recipeId': recipeId,
      'stepIndex': stepIndex,
    });
    return data['imageUrl'] as String;
  }

  // ── Texte → CookLang ────────────────────────────────────────────────────────

  /// Lit un texte libre et rend une recette balisée, vérifiée.
  ///
  /// Retourne null quand le texte ne contient aucune recette.
  ///
  /// Le serveur ne rend plus seulement du CookLang : il rend aussi la liste
  /// d'ingrédients qu'il a normalisée. C'est la seule forme qui porte la note
  /// explicative — « dégermées », « avec la peau mais écaillée » — et la ligne
  /// d'origine. Les reconstituer ici en relisant les balises `@` du CookLang
  /// les perdait toutes les deux, sans que rien ne le signale.
  Future<TextRecipeExtraction?> extractRecipeFromText(String text) async {
    final data = await _call('extractRecipeFromTextFn', {'text': text});
    final map = Map<String, dynamic>.from(data as Map);
    final cooklang = (map['cooklang'] as String?)?.trim() ?? '';
    if (cooklang.isEmpty) return null;
    return TextRecipeExtraction(
      cooklang: cooklang,
      ingredients: (map['ingredients'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => RecipeIngredient.fromMap(Map<String, dynamic>.from(e)))
          .toList(growable: false),
      cuisines: List<String>.from(map['cuisines'] as List? ?? const []),
      dishTypes: List<String>.from(map['dish_types'] as List? ?? const []),
      fidelityLevel: map['fidelity_level'] as String?,
      fidelityFindings: FidelityFinding.listFrom(map['fidelity_findings']),
      recettesTrouvees: (map['recettes_trouvees'] as num?)?.toInt() ?? 1,
    );
  }

  // ── Polish ──────────────────────────────────────────────────────────────────

  Future<String?> polishCooklang(String cooklang) async {
    final data = await _call('polishCooklangFn', {'cooklang': cooklang});
    return data['cooklang'] as String?;
  }

  /// Corrige l'orthographe et la mise en forme Markdown d'un document non-recette.
  /// Ne modifie pas le contenu/sens.
  Future<String?> polishMarkdown(String markdown, {String? instruction}) async {
    final data = await _call('polishMarkdownFn', {
      'markdown': markdown,
      if (instruction != null && instruction.isNotEmpty)
        'instruction': instruction,
    });
    return data['markdown'] as String?;
  }

  // ── Search ──────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> searchRecipes({
    required String query,
    required List<Map<String, String>> recipes,
    List<Map<String, String>> ratedRecipes = const [],
  }) async {
    final data = await _call('searchRecipesFn', {
      'query': query,
      'recipes': recipes,
      'ratedRecipes': ratedRecipes,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  // ── Generate ────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> generateRecipe({
    required String query,
    String? preferenceInsight,
    List<Map<String, String>> libraryContext = const [],
    String? variantLabel,
    String? variantInstruction,
    List<String> siblingVariantLabels = const [],
    List<String> avoidTitles = const [],
  }) async {
    final data = await _call('generateRecipeFn', {
      'query': query,
      'preferenceInsight': preferenceInsight,
      if (libraryContext.isNotEmpty) 'libraryContext': libraryContext,
      if (variantLabel != null && variantLabel.isNotEmpty)
        'variantLabel': variantLabel,
      if (variantInstruction != null && variantInstruction.isNotEmpty)
        'variantInstruction': variantInstruction,
      if (siblingVariantLabels.isNotEmpty)
        'siblingVariantLabels': siblingVariantLabels,
      if (avoidTitles.isNotEmpty) 'avoidTitles': avoidTitles,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  // ── Refine ──────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> refineRecipe({
    required String currentTitre,
    required String currentCooklang,
    required List<Map<String, dynamic>> currentIngredients,
    required Map<String, dynamic> currentTags,
    required int? currentPortions,
    required String instruction,
  }) async {
    final data = await _call('refineRecipeFn', {
      'currentTitre': currentTitre,
      'currentCooklang': currentCooklang,
      'currentIngredients': currentIngredients,
      'currentTags': currentTags,
      'currentPortions': currentPortions,
      'instruction': instruction,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  // ── Meal planning ──────────────────────────────────────────────────────────

  /// Suggère un planning de repas via la Cloud Function `suggestMealPlanFn`.
  ///
  /// Retourne des paires `(slot, recipeId, justification, resized, resizeReason, prepDate)` — le client résout les IDs.
  Future<
    List<
      ({
        int slot,
        String recipeId,
        String? justification,
        bool resized,
        String? resizeReason,
        String? prepDate,
      })
    >
  >
  suggestMealPlan({
    required List<Map<String, dynamic>> recipes,
    required List<String> slotDates,
    required Map<int, Map<String, dynamic>> dailyConstraints,
    required String globalConstraints,
    int? batchCookingDay,
    List<Map<String, dynamic>> alreadyAssigned = const [],
    List<Map<String, dynamic>?>? slotConstraints,
  }) async {
    final data = await _call('suggestMealPlanFn', {
      'recipes': recipes,
      'slotDates': slotDates,
      'dailyConstraints': {
        for (final e in dailyConstraints.entries) e.key.toString(): e.value,
      },
      'slotConstraints': ?slotConstraints,
      'globalConstraints': globalConstraints,
      'batchCookingDay': ?batchCookingDay,
      if (alreadyAssigned.isNotEmpty) 'alreadyAssigned': alreadyAssigned,
    });
    final suggestions = (data as Map)['suggestions'] as List? ?? [];
    return suggestions
        .map(
          (item) => (
            slot: (item['slot'] as num).toInt(),
            recipeId: item['recipeId'] as String? ?? '',
            justification: item['justification'] as String?,
            resized: item['resized'] as bool? ?? false,
            resizeReason: item['resizeReason'] as String?,
            prepDate: item['prepDate'] as String?,
          ),
        )
        .toList();
  }

  /// Génère une recette de toutes pièces (conception IA) pour un slot donné.
  ///
  /// Utilisé quand aucune recette existante ne satisfait les contraintes.
  Future<({String titre, String cooklang, String justification})>
  generateRecipeConcept({
    required String slotDate,
    required String globalConstraints,
    Map<String, dynamic>? dayConstraint,
    List<String> alreadyPlanned = const [],
  }) async {
    final data = await _call('generateRecipeConceptFn', {
      'slotDate': slotDate,
      'globalConstraints': globalConstraints,
      'dayConstraint': ?dayConstraint,
      'alreadyPlanned': alreadyPlanned,
    });
    final map = data as Map;
    return (
      titre: map['titre'] as String? ?? 'Recette générée par l\'IA',
      cooklang: map['cooklang'] as String? ?? '',
      justification: map['justification'] as String? ?? '',
    );
  }

  // ── Web search query ────────────────────────────────────────────────────────

  Future<String> generateWebSearchQuery(String userQuery) async {
    final data = await _call('generateWebSearchQueryFn', {
      'userQuery': userQuery,
    });
    return data['query'] as String;
  }

  // ── Suggest recipe tags (Cuisine + Type de plat) ────────────────────────────

  Future<({List<String> cuisines, List<String> dishTypes})> suggestRecipeTags({
    required String titre,
    required String cooklang,
  }) async {
    final data = await _call('suggestRecipeTagsFn', {
      'titre': titre,
      'cooklang': cooklang,
    });
    final cuisines = List<String>.from(
      (data as Map)['cuisines'] as List? ?? [],
    );
    final dishTypes = List<String>.from(data['dishTypes'] as List? ?? []);
    return (cuisines: cuisines, dishTypes: dishTypes);
  }

  // ── Upload security (quarantine scan) ────────────────────────────────────

  Future<
    ({String downloadUrl, String storagePath, String mimeType, int sizeBytes})
  >
  scanAndPromoteUpload({required String storagePath}) async {
    final data = await _call('scanAndPromoteUploadFn', {
      'storagePath': storagePath,
    });
    final map = Map<String, dynamic>.from(data as Map);
    return (
      downloadUrl: map['downloadUrl'] as String? ?? '',
      storagePath: map['storagePath'] as String? ?? '',
      mimeType: map['mimeType'] as String? ?? 'application/octet-stream',
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Ce qu'un texte libre rend une fois lu, balisé et vérifié par le serveur.
///
/// Le texte collé emprunte désormais la chaîne de l'import : transcription,
/// puis balisage, puis contrôle de fidélité. Il rend donc la même chose qu'un
/// scan de page — d'où les tags et la réserve de fidélité, qui n'existaient
/// jusqu'ici que pour les recettes venues d'un livre.
class TextRecipeExtraction {
  const TextRecipeExtraction({
    required this.cooklang,
    this.ingredients = const [],
    this.cuisines = const [],
    this.dishTypes = const [],
    this.fidelityLevel,
    this.fidelityFindings = const [],
    this.recettesTrouvees = 1,
  });

  final String cooklang;

  /// Une entrée par ligne d'ingrédient du texte, note et ligne d'origine
  /// comprises.
  final List<RecipeIngredient> ingredients;

  final List<String> cuisines;
  final List<String> dishTypes;

  /// `avertissement` ou `rupture` — null quand le contrôle n'a rien à dire.
  final String? fidelityLevel;
  final List<FidelityFinding> fidelityFindings;

  /// Combien de recettes le texte contenait. Une seule est reprise : l'écran
  /// de création n'en édite qu'une, et l'utilisateur doit apprendre que le
  /// reste n'a pas été gardé.
  final int recettesTrouvees;
}

/// Exception levée quand un appel Callable Gemini échoue.
class GeminiCallableException implements Exception {
  final String code;
  final String message;
  final dynamic details;
  GeminiCallableException(this.code, this.message, this.details);
  @override
  String toString() => 'GeminiCallableException[$code]: $message';
}
