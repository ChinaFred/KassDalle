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
import '../../features/recipes/data/book_import_analysis.dart';
import '../../features/recipes/domain/recipe.dart';
import '../../features/recipes/domain/url_import.dart';
import '../../features/search/domain/web_search.dart';

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
      langueOrigine: map['langue_origine'] as String?,
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
  /// [mode] `model` (défaut) : présélection serveur puis un appel de modèle ;
  /// `code` : présélection seule, sans appel de modèle ni coût. Le client
  /// résout les identifiants rendus.
  ///
  /// [groupId] : le planning généré est celui de ce groupe ; le serveur
  /// vérifie que l'appelant en est le propriétaire.
  Future<MealPlanResponse> suggestMealPlan({
    required List<Map<String, dynamic>> recipes,
    required List<String> slotDates,
    required Map<int, Map<String, dynamic>> dailyConstraints,
    required String globalConstraints,
    int? batchCookingDay,
    List<Map<String, dynamic>> alreadyAssigned = const [],
    List<Map<String, dynamic>?>? slotConstraints,
    List<Map<String, dynamic>> recentlyServed = const [],
    String? mode,
    List<List<String>?>? slotDismissed,
    String? groupId,
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
      if (recentlyServed.isNotEmpty) 'recentlyServed': recentlyServed,
      'mode': ?mode,
      'slotDismissed': ?slotDismissed,
      'groupId': ?groupId,
    });
    return MealPlanResponse.fromMap(data is Map ? data : const {});
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
    Map<String, dynamic>? requestedDish,
    String? runId,
  }) async {
    final data = await _call('generateRecipeConceptFn', {
      'slotDate': slotDate,
      'globalConstraints': globalConstraints,
      'dayConstraint': ?dayConstraint,
      'alreadyPlanned': alreadyPlanned,
      'requestedDish': ?requestedDish,
      // Rattache la conception à sa génération : le serveur y applique le
      // plafond de conceptions et de coût.
      'runId': ?runId,
    });
    final map = data as Map;
    return (
      titre: map['titre'] as String? ?? 'Recette générée par l\'IA',
      cooklang: map['cooklang'] as String? ?? '',
      justification: map['justification'] as String? ?? '',
    );
  }

  /// Trois idées de repas sur une consigne libre, pour le sélecteur du planning.
  ///
  /// [previousTitles] : les idées déjà rendues, pour que la relance en propose
  /// d'autres. Le serveur ne conçoit pas de recette et n'écrit rien.
  Future<
    List<
      ({String titre, String description, int? prepMinutes, int? cookMinutes})
    >
  >
  suggestMealIdeas({
    required String prompt,
    String globalConstraints = '',
    List<String> previousTitles = const [],
  }) async {
    final data = await _call('suggestMealIdeasFn', {
      'prompt': prompt,
      if (globalConstraints.isNotEmpty) 'globalConstraints': globalConstraints,
      if (previousTitles.isNotEmpty) 'previousTitles': previousTitles,
    });
    final ideas = (data as Map)['ideas'] as List? ?? const [];
    return [
      for (final item in ideas)
        if (item is Map && (item['titre'] as String? ?? '').trim().isNotEmpty)
          (
            titre: (item['titre'] as String).trim(),
            description: (item['description'] as String? ?? '').trim(),
            prepMinutes: (item['prepMinutes'] as num?)?.toInt(),
            cookMinutes: (item['cookMinutes'] as num?)?.toInt(),
          ),
    ];
  }

  // ── Suggest recipe tags (Cuisine + Type de plat + rôle dans un repas) ──────

  Future<
    ({
      List<String> cuisines,
      List<String> dishTypes,
      String? mealRole,
      List<String> contains,
      List<String> suggestedSides,
      String? mainProtein,
      String? mainStarch,
      bool mainIngredientsChecked,
    })
  >
  suggestRecipeTags({required String titre, required String cooklang}) async {
    final data = await _call('suggestRecipeTagsFn', {
      'titre': titre,
      'cooklang': cooklang,
    });
    final map = data as Map;
    List<String> strings(String key) =>
        List<String>.from(map[key] as List? ?? []);
    final role = map['mealRole'] as String?;
    String? nonEmpty(String key) {
      final v = map[key];
      return (v is String && v.isNotEmpty) ? v : null;
    }

    return (
      cuisines: strings('cuisines'),
      dishTypes: strings('dishTypes'),
      // Vide vaut « pas su » : le serveur ne rend un rôle que parmi les
      // valeurs admises.
      mealRole: (role == null || role.isEmpty) ? null : role,
      contains: strings('contains'),
      suggestedSides: strings('suggestedSides'),
      // Posés par le serveur pour un plat ou un accompagnement seulement.
      mainProtein: nonEmpty('mainProtein'),
      mainStarch: nonEmpty('mainStarch'),
      mainIngredientsChecked: map['mainIngredientsChecked'] == true,
    );
  }

  // ── Upload security (quarantine scan) ────────────────────────────────────

  Future<
    ({String downloadUrl, String storagePath, String mimeType, int sizeBytes})
  >
  scanAndPromoteUpload({required String storagePath, String? scanId}) async {
    final data = await _call('scanAndPromoteUploadFn', {
      'storagePath': storagePath,
      // Le contrôle du fichier a lieu AVANT que le job d'import existe : le
      // serveur n'a aucun moyen de savoir de quel scan il fait partie, et son
      // coût restait un groupe de journaux isolé. Seul le client le sait.
      'scanId': ?scanId,
    });
    final map = Map<String, dynamic>.from(data as Map);
    return (
      downloadUrl: map['downloadUrl'] as String? ?? '',
      storagePath: map['storagePath'] as String? ?? '',
      mimeType: map['mimeType'] as String? ?? 'application/octet-stream',
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
    );
  }

  // ── Import d'un livre entier ──────────────────────────────────────────────

  /// Fait lire un livre déjà promu par le serveur : pages ou texte, nombre de
  /// jobs qu'il va créer, coût estimé d'après les imports précédents.
  ///
  /// Ne dépense rien. `storagePath` est celui rendu par
  /// [scanAndPromoteUpload].
  Future<BookImportAnalysis> analyzeBookFile({
    required String storagePath,
  }) async {
    final data = await _call('analyzeBookFileFn', {'storagePath': storagePath});
    return BookImportAnalysis.fromMap(Map<String, dynamic>.from(data as Map));
  }

  /// Supprime un livre envoyé puis abandonné avant l'import.
  Future<void> discardBookFile({required String storagePath}) async {
    await _call('analyzeBookFileFn', {
      'storagePath': storagePath,
      'discard': true,
    });
  }

  /// Demande l'import d'une recette depuis un lien.
  ///
  /// Le serveur vérifie le rôle, l'adresse, le doublon et le plafond du jour,
  /// puis crée le job : la recette arrive en brouillon, plus tard. [force]
  /// passe outre le doublon (« Importer quand même »).
  Future<UrlImportResult> importRecipeFromUrl(
    String url, {
    bool force = false,
  }) async {
    final data = await _call('importRecipeFromUrlFn', {
      'url': url,
      'force': force,
    });
    return UrlImportResult.fromMap(Map<String, dynamic>.from(data as Map));
  }

  /// Crée (ou retrouve) le livre système « Mes recettes du web » et rend son
  /// identifiant. Le client ne peut pas le créer lui-même : les règles
  /// refusent `books/web_*` et le tag `__web`. Éditeurs et administrateurs.
  Future<String> ensureWebBook() async {
    final data = await _call('ensureWebBookFn', const <String, dynamic>{});
    return (Map<String, dynamic>.from(data as Map)['bookId'] as String?) ?? '';
  }

  /// Le compteur d'imports par lien du jour.
  Future<UrlImportQuota> getUrlImportQuota() async {
    final data = await _call('getUrlImportQuotaFn', const <String, dynamic>{});
    return UrlImportQuota.fromMap(Map<String, dynamic>.from(data as Map));
  }

  // ── Tickets ─────────────────────────────────────────────────────────────────
  //
  // Aucun appel d'IA : ces callables passent ici pour le contournement web du
  // SDK `cloud_functions_web` (voir [_call]). Le repository des tickets lit
  // les réponses et traduit les refus.

  /// Crée un ticket. Entrée `{type, title, description, screen, app_version,
  /// platform}` ; sortie `{ticketId, status, remaining_today}`.
  Future<Map<String, dynamic>> submitTicket(
    Map<String, dynamic> payload,
  ) async {
    final data = await _call('submitTicket', payload);
    return Map<String, dynamic>.from(data as Map);
  }

  /// Rattache la capture envoyée sur [path] au ticket [ticketId].
  Future<void> attachTicketScreenshot({
    required String ticketId,
    required String path,
  }) async {
    await _call('attachTicketScreenshot', {'ticketId': ticketId, 'path': path});
  }

  /// Relance l'envoi à GitHub d'un ticket en anomalie (administrateur).
  /// Rend le statut du ticket après l'essai.
  Future<String> retryTicketSend(String ticketId) async {
    final data = await _call('retryTicketSend', {'ticketId': ticketId});
    return (Map<String, dynamic>.from(data as Map)['status'] as String?) ?? '';
  }

  /// Valide un ticket analysé (administrateur) : étiquette `validé` sur
  /// l'Issue. Rend le statut du ticket.
  Future<String> validateTicket(String ticketId) async {
    final data = await _call('validateTicket', {'ticketId': ticketId});
    return (Map<String, dynamic>.from(data as Map)['status'] as String?) ?? '';
  }

  /// Refuse un ticket (administrateur) : publie `Réponse : <motif>` sur
  /// l'Issue et la ferme. Rend le statut du ticket.
  Future<String> refuseTicket(String ticketId, String reason) async {
    final data = await _call('refuseTicket', {
      'ticketId': ticketId,
      'reason': reason,
    });
    return (Map<String, dynamic>.from(data as Map)['status'] as String?) ?? '';
  }

  /// Publie la réponse de l'administrateur à la dernière analyse d'un ticket
  /// Analysé ou Validé (`## Précisions de l'administrateur`) et le ramène à
  /// Reçu. Rend le statut du ticket.
  Future<String> answerTicketAnalysis(String ticketId, String answer) async {
    final data = await _call('answerTicketAnalysis', {
      'ticketId': ticketId,
      'answer': answer,
    });
    return (Map<String, dynamic>.from(data as Map)['status'] as String?) ?? '';
  }

  /// Clôt un ticket (administrateur) : publie `Réponse : <commentaire>` sur
  /// l'Issue, pose `statut:clos` et la ferme. Rend le statut du ticket.
  Future<String> closeTicket(String ticketId, String comment) async {
    final data = await _call('closeTicket', {
      'ticketId': ticketId,
      'comment': comment,
    });
    return (Map<String, dynamic>.from(data as Map)['status'] as String?) ?? '';
  }

  /// Lance la routine Claude Code d'analyse sur un ticket Reçu
  /// (administrateur). Sortie `{outcome: "launched" | "unknown",
  /// session_url}`. Aucun appel de modèle facturé au projet.
  Future<Map<String, dynamic>> launchTicketAnalysis(String ticketId) async {
    final data = await _call('launchTicketAnalysis', {'ticketId': ticketId});
    return Map<String, dynamic>.from(data as Map);
  }

  /// Lance la routine Claude Code de développement sur un ticket Validé
  /// (administrateur). Même sortie que [launchTicketAnalysis].
  Future<Map<String, dynamic>> launchTicketDevelopment(String ticketId) async {
    final data = await _call('launchTicketDevelopment', {'ticketId': ticketId});
    return Map<String, dynamic>.from(data as Map);
  }

  /// « Livrer » un ticket En cours (administrateur) : la routine de
  /// développement reçoit `livraison #N`. Même sortie que
  /// [launchTicketAnalysis].
  Future<Map<String, dynamic>> launchTicketDelivery(String ticketId) async {
    final data = await _call('launchTicketDelivery', {'ticketId': ticketId});
    return Map<String, dynamic>.from(data as Map);
  }

  /// « Chercher sur le web » : jusqu'à huit pages de recettes trouvées par
  /// Google pour [query], tous rôles.
  ///
  /// Traduit les refus attendus du serveur, que l'écran distingue d'une
  /// panne (voir [webSearchErrorFrom]) ; relance toute autre erreur.
  Future<WebSearchResponse> searchWebRecipes(String query) async {
    try {
      final data = await _call('searchWebRecipesFn', {'query': query});
      return WebSearchResponse.fromMap(Map<String, dynamic>.from(data as Map));
    } on GeminiCallableException catch (e) {
      final known = webSearchErrorFrom(e);
      if (known != null) throw known;
      rethrow;
    }
  }
}

/// Le code d'une erreur de callable, sous sa forme du SDK : le SDK rend
/// `resource-exhausted`, l'appel HTTP du web `resource_exhausted`.
String callableErrorCode(GeminiCallableException e) =>
    e.code.toLowerCase().replaceAll('_', '-');

/// Les refus de `searchWebRecipesFn` que l'écran affiche à sa façon, ou
/// `null` pour toute autre erreur :
///
/// - [WebSearchQuotaExceeded] : plafond de recherches du jour ;
/// - [WebSearchAiBudgetExceeded] : plafond de dépense d'IA du jour ;
/// - [WebSearchQueryRefused] : requête vide ou trop longue ;
/// - [WebSearchEngineUnavailable] : moteur en panne ou saturé.
///
/// Chacun se reconnaît à `details.reason`, posé par le serveur : un
/// `unavailable` sans raison est une coupure réseau, pas le moteur.
Exception? webSearchErrorFrom(GeminiCallableException e) {
  final details = e.details;
  final reason = details is Map ? details['reason'] : null;
  final message = e.message.trim();
  switch ((callableErrorCode(e), reason)) {
    case ('resource-exhausted', webSearchQuotaReason):
      final limit = (details as Map)['limit'];
      return WebSearchQuotaExceeded(limit: (limit as num?)?.toInt());
    case ('resource-exhausted', webSearchAiBudgetReason):
      return WebSearchAiBudgetExceeded(message);
    case ('invalid-argument', webSearchQueryReason) when message.isNotEmpty:
      return WebSearchQueryRefused(message);
    case ('unavailable', webSearchEngineReason) when message.isNotEmpty:
      return WebSearchEngineUnavailable(message);
  }
  return null;
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
    this.langueOrigine,
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

  /// Code ISO 639-1 du texte collé quand il a été traduit, sinon `null`.
  final String? langueOrigine;
}

/// Exception levée quand un appel Callable Gemini échoue.
/// Une suggestion de `suggestMealPlanFn`, telle que le serveur la rend.
typedef MealPlanSlotDto = ({
  int slot,
  String recipeId,
  String? starterId,
  String? dessertId,
  String? justification,
  bool resized,
  String? resizeReason,
  String? prepDate,
  String source,
  bool repeat,

  /// Écarts aux critères compris, bruts : `{key, regime, status, service,
  /// detail}` (v0.24.18). Lus par la feature planning.
  List<Map<dynamic, dynamic>> unmet,
});

/// Réponse de `suggestMealPlanFn`.
///
/// Les champs ajoutés avec la présélection serveur (v0.23.18) sont lus avec
/// des valeurs neutres : une réponse plus ancienne reste lisible.
class MealPlanResponse {
  final List<MealPlanSlotDto> suggestions;
  final List<String> excludedRecentIds;

  /// Génération à laquelle rattacher les conceptions ; `null` sans génération
  /// enregistrée (mode `code`, ou écriture en échec côté serveur).
  final String? runId;

  /// `ok`, `partial`, `failed`, `budget` ou `skipped`.
  final String modelStatus;

  /// Phrase à afficher quand le modèle n'a pas choisi.
  final String? notice;

  /// Listes classées par créneau, brutes : `{slot, plats, entrees, desserts}`.
  final List<Map<dynamic, dynamic>> rankedCandidates;

  /// Conceptions encore permises pour cette génération.
  final int conceptsRemaining;

  /// Ce que le serveur a compris de chaque texte, brut : `{text, criteria,
  /// untranslated, status}` (v0.24.18).
  final List<Map<dynamic, dynamic>> constraintTranslations;

  const MealPlanResponse({
    required this.suggestions,
    required this.excludedRecentIds,
    this.runId,
    this.modelStatus = 'ok',
    this.notice,
    this.rankedCandidates = const [],
    this.conceptsRemaining = 0,
    this.constraintTranslations = const [],
  });

  factory MealPlanResponse.fromMap(Map<dynamic, dynamic> data) {
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    final suggestions = <MealPlanSlotDto>[];
    for (final item in data['suggestions'] as List? ?? const []) {
      if (item is! Map) continue;
      final slot = item['slot'];
      final recipeId = item['recipeId'];
      if (slot is! num || recipeId is! String) continue;
      suggestions.add((
        slot: slot.toInt(),
        recipeId: recipeId,
        starterId: str(item['starterId']),
        dessertId: str(item['dessertId']),
        justification: str(item['justification']),
        resized: item['resized'] == true,
        resizeReason: str(item['resizeReason']),
        prepDate: str(item['prepDate']),
        source: str(item['source']) ?? 'model',
        repeat: item['repeat'] == true,
        unmet: (item['unmet'] as List? ?? const [])
            .whereType<Map<dynamic, dynamic>>()
            .toList(growable: false),
      ));
    }
    final remaining = data['conceptsRemaining'];
    return MealPlanResponse(
      suggestions: suggestions,
      excludedRecentIds: (data['excludedRecentIds'] as List? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      runId: str(data['runId']),
      modelStatus: str(data['modelStatus']) ?? 'ok',
      notice: str(data['notice']),
      rankedCandidates: (data['rankedCandidates'] as List? ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .toList(growable: false),
      conceptsRemaining: remaining is num ? remaining.toInt() : 0,
      constraintTranslations:
          (data['constraintTranslations'] as List? ?? const [])
              .whereType<Map<dynamic, dynamic>>()
              .toList(growable: false),
    );
  }
}

class GeminiCallableException implements Exception {
  final String code;
  final String message;
  final dynamic details;
  GeminiCallableException(this.code, this.message, this.details);
  @override
  String toString() => 'GeminiCallableException[$code]: $message';
}
