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

import 'cooklang_parser.dart';

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
      throw GeminiCallableException(e.code, e.message ?? '', e.details);
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
      } catch (_) {}
      throw GeminiCallableException(code, message, details);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['result'];
  }

  // ── extractRecipes ──────────────────────────────────────────────────────────
  //
  // Le scan de fichier (PDF / image multi-pages) passe désormais par
  // `processing_jobs/` → `recipeProcessor` (Cloud Tasks). Cette méthode est
  // conservée pour rétrocompatibilité mais lève une exception explicite si
  // appelée — le client doit créer un ProcessingJob.
  Future<List<String>> extractRecipes(
    Uint8List bytes,
    String mimeType, {
    List<({Uint8List bytes, String mimeType})> additionalPages = const [],
  }) async {
    throw UnsupportedError(
      'extractRecipes a été déplacé côté backend (Cloud Tasks). '
      'Créez un ProcessingJob via ProcessingJobRepository pour déclencher '
      'le pipeline asynchrone.',
    );
  }

  // ── Détection illustrations ─────────────────────────────────────────────────

  Future<List<List<int>>> detectIllustrationRegions(
    Uint8List bytes,
    String mimeType,
  ) async {
    final data = await _call('detectAndCropIllustrationsFn', {
      'bytesBase64': base64Encode(bytes),
      'mimeType': mimeType,
    });
    final boxes = (data['boxes'] as List? ?? [])
        .map((e) => (e as List).map((v) => (v as num).toInt()).toList())
        .toList();
    return boxes;
  }

  /// Version qui retourne aussi les bytes croppés (évite un re-call backend).
  Future<({List<List<int>> boxes, List<Uint8List> crops})>
  detectAndCropIllustrations(Uint8List bytes, String mimeType) async {
    final data = await _call('detectAndCropIllustrationsFn', {
      'bytesBase64': base64Encode(bytes),
      'mimeType': mimeType,
    });
    final boxes = (data['boxes'] as List? ?? [])
        .map((e) => (e as List).map((v) => (v as num).toInt()).toList())
        .toList();
    final crops = (data['cropsBase64'] as List? ?? [])
        .map((b64) => base64Decode(b64 as String))
        .toList();
    return (boxes: boxes, crops: crops);
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

  Future<List<int>?> detectMainCulinaryPhoto(
    Uint8List bytes,
    String mimeType,
  ) async {
    final data = await _call('detectMainCulinaryPhotoFn', {
      'bytesBase64': base64Encode(bytes),
      'mimeType': mimeType,
    });
    final box = data['box'];
    if (box == null) return null;
    return (box as List).map((v) => (v as num).toInt()).toList();
  }

  // ── Texte → CookLang ────────────────────────────────────────────────────────

  Future<String?> extractRecipeFromText(String text) async {
    final data = await _call('extractRecipeFromTextFn', {'text': text});
    return data['cooklang'] as String?;
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
      if (instruction != null && instruction.isNotEmpty) 'instruction': instruction,
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

  // ── Book cover ──────────────────────────────────────────────────────────────

  Future<BookCoverExtraction> extractBookCover(
    Uint8List bytes,
    String mimeType,
  ) async {
    final data = await _call('extractBookCoverFn', {
      'bytesBase64': base64Encode(bytes),
      'mimeType': mimeType,
    });
    return BookCoverExtraction.fromMap(Map<String, dynamic>.from(data as Map));
  }

  // ── Generate ────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> generateRecipe({
    required String query,
    String? preferenceInsight,
  }) async {
    final data = await _call('generateRecipeFn', {
      'query': query,
      'preferenceInsight': preferenceInsight,
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
  /// Retourne des paires `(slot, recipeId, justification, prepDate)` — le client résout les IDs.
  Future<
    List<({int slot, String recipeId, String? justification, String? prepDate})>
  >
  suggestMealPlan({
    required List<Map<String, dynamic>> recipes,
    required List<String> slotDates,
    required Map<int, Map<String, dynamic>> dailyConstraints,
    required String globalConstraints,
    int? batchCookingDay,
    List<Map<String, dynamic>> alreadyAssigned = const [],
  }) async {
    final data = await _call('suggestMealPlanFn', {
      'recipes': recipes,
      'slotDates': slotDates,
      'dailyConstraints': {
        for (final e in dailyConstraints.entries) e.key.toString(): e.value,
      },
      'globalConstraints': globalConstraints,
      if (batchCookingDay != null) 'batchCookingDay': batchCookingDay,
      if (alreadyAssigned.isNotEmpty) 'alreadyAssigned': alreadyAssigned,
    });
    final suggestions = (data as Map)['suggestions'] as List? ?? [];
    return suggestions
        .map(
          (item) => (
            slot: (item['slot'] as num).toInt(),
            recipeId: item['recipeId'] as String? ?? '',
            justification: item['justification'] as String?,
            prepDate: item['prepDate'] as String?,
          ),
        )
        .toList();
  }

  /// Génère une recette de toutes pièces (conception IA) pour un slot donné.
  ///
  /// Utilisé quand aucune recette existante ne satisfait les contraintes.
  Future<({String titre, String cooklang, String justification})> generateRecipeConcept({
    required String slotDate,
    required String globalConstraints,
    Map<String, dynamic>? dayConstraint,
  }) async {
    final data = await _call('generateRecipeConceptFn', {
      'slotDate': slotDate,
      'globalConstraints': globalConstraints,
      if (dayConstraint != null) 'dayConstraint': dayConstraint,
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
