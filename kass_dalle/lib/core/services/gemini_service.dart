import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';
import '../../features/recipes/domain/recipe.dart';
import 'cooklang_parser.dart';
import 'gemini_prompts.dart';

/// Service d'extraction de recettes via Gemini.
///
/// La clé API est fournie à la construction (lue depuis Firestore/Remote Config
/// ou via --dart-define=GEMINI_API_KEY=xxx au build).
///
/// [onTokenUsage] : callback appelé après chaque appel API pour logger l'usage.
/// Signature : (feature, inputTokens, outputTokens, totalTokens)
class GeminiService {
  static const _modelName = 'gemini-2.5-flash';

  late final GenerativeModel _model;
  final Future<void> Function(
    String feature,
    int inputTokens,
    int outputTokens,
    int totalTokens,
  )?
  onTokenUsage;

  GeminiService(String apiKey, {this.onTokenUsage})
    : _model = GenerativeModel(model: _modelName, apiKey: apiKey);

  /// Log l'usage des tokens après un appel Gemini.
  Future<void> _logUsage(
    String feature,
    GenerateContentResponse response,
  ) async {
    final meta = response.usageMetadata;
    if (meta == null || onTokenUsage == null) return;
    final input = meta.promptTokenCount ?? 0;
    final output = meta.candidatesTokenCount ?? 0;
    final total = meta.totalTokenCount ?? (input + output);
    await onTokenUsage!(feature, input, output, total);
  }

  /// Envoie un fichier (PDF, DOCX, image) à Gemini et retourne le CookLang extrait.
  /// Retourne une liste de strings CookLang (une par recette détectée).
  /// [additionalPages] : pages supplémentaires (multi-page scan).
  Future<List<String>> extractRecipes(
    Uint8List bytes,
    String mimeType, {
    List<({Uint8List bytes, String mimeType})> additionalPages = const [],
  }) async {
    final prompt = additionalPages.isNotEmpty
        ? kGeminiMultiPagePrefix + kGeminiScanPrompt
        : kGeminiScanPrompt;
    final parts = <Part>[
      DataPart(mimeType, bytes),
      ...additionalPages.map((p) => DataPart(p.mimeType, p.bytes)),
      TextPart(prompt),
    ];
    final content = Content.multi(parts);

    final response = await _model
        .generateContent([content])
        .timeout(
          // 5 min pour les scans multi-pages (plusieurs images volumineuses)
          const Duration(minutes: 5),
          onTimeout: () => throw TimeoutException('Gemini API timeout'),
        );
    await _logUsage('scan_extraction', response);
    final text = response.text?.trim() ?? '';

    if (text.isEmpty || text == 'NO_RECIPE') return [];

    // Sépare les recettes multiples
    return text
        .split(RegExp(r'\n---+\n'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// Détecte les zones de photos culinaires dans une image de recette.
  /// Retourne une liste de bounding boxes [yMin, xMin, yMax, xMax] (valeurs 0-1000).
  /// Retourne [] si aucune photo trouvée ou si le fichier n'est pas une image.
  Future<List<List<int>>> detectIllustrationRegions(
    Uint8List bytes,
    String mimeType,
  ) async {
    const prompt = '''
TÂCHE : trouver toutes les photographies culinaires dans cette image de livre.

MÉTHODE EN 2 ÉTAPES :
1. Compte le nombre total de photographies distinctes (une grille de 8 photos = 8 photos, pas 1).
2. Pour chaque photo, donne ses coordonnées précises.

RÈGLES ABSOLUES :
- Grille 2×4 = 8 boîtes séparées, PAS 1 boîte
- Grille 2×3 = 6 boîtes séparées
- Grille 2×2 = 4 boîtes séparées
- NE JAMAIS regrouper plusieurs photos en une seule boîte
- NE PAS inclure : texte, ingrédients, fond blanc, bordures, schémas

TYPES de photos à détecter :
- Photos d'étapes de préparation (souvent en grille)
- Photo du plat final
- Photo d'ingrédients mis en scène

COORDONNÉES : [y_min, x_min, y_max, x_max] entiers 0-1000
(0,0 = coin supérieur gauche ; 1000,1000 = coin inférieur droit)

Exemple grille 2×4 de 8 photos occupant la moitié basse de l'image :
[[500,0,750,500],[500,500,750,1000],[750,0,875,500],[750,500,875,1000],[875,0,1000,500],[875,500,1000,1000],[500,0,625,500],[500,500,625,1000]]

RÉPONSE : UNIQUEMENT le tableau JSON, sans markdown ni explication :
[[y1,x1,y2,x2], ...] ou [] si aucune photo.
''';
    var regions = await _callDetectAndParse(bytes, mimeType, prompt, 'detect_illustrations');

    // Deuxième passe : si Gemini a renvoyé 1 seule grande boîte (>15% de l'image),
    // c'est probablement une grille non subdivisée → on relance avec un prompt ciblé.
    if (regions.length == 1) {
      final box = regions[0];
      final area = (box[2] - box[0]) * (box[3] - box[1]); // sur 1 000 000
      if (area > 150000) {
        final subdivided = await _trySubdivideGrid(bytes, mimeType, box);
        if (subdivided.length > 1) return subdivided;
      }
    }

    return regions;
  }

  /// Deuxième passe de détection : demande à Gemini de subdiviser une grande zone.
  Future<List<List<int>>> _trySubdivideGrid(
    Uint8List bytes,
    String mimeType,
    List<int> box,
  ) async {
    final prompt = '''
Cette image de livre de cuisine contient probablement une grille de petites photos d'étapes culinaires.

COMPTE précisément :
- Combien de photographies individuelles vois-tu ?
- Si elles forment une grille, combien de LIGNES et de COLONNES ?

Retourne les coordonnées [y_min, x_min, y_max, x_max] de CHAQUE photo individuelle (0-1000).
NE regroupe PAS plusieurs photos ensemble.

RÉPONSE : UNIQUEMENT le tableau JSON sans markdown :
[[y1,x1,y2,x2], ...] ou [] si une seule photo.
''';
    return _callDetectAndParse(bytes, mimeType, prompt, 'detect_illustrations_grid');
  }

  /// Appelle Gemini et parse la réponse JSON en liste de boîtes.
  Future<List<List<int>>> _callDetectAndParse(
    Uint8List bytes,
    String mimeType,
    String prompt,
    String feature,
  ) async {
    try {
      final content = Content.multi([
        DataPart(mimeType, bytes),
        TextPart(prompt),
      ]);
      final response = await _model
          .generateContent([content])
          .timeout(
            const Duration(seconds: 90),
            onTimeout: () =>
                throw TimeoutException('detectIllustrationRegions timeout'),
          );
      await _logUsage(feature, response);
      final text = (response.text ?? '')
          .trim()
          .replaceAll(RegExp(r'```json?|```'), '')
          .trim();
      if (text.isEmpty || text == '[]') return [];
      final jsonMatch = RegExp(r'\[.*\]', dotAll: true).firstMatch(text);
      final jsonText = jsonMatch?.group(0) ?? text;
      final parsed = jsonDecode(jsonText) as List;
      return parsed
          .whereType<List>()
          .map((e) {
            final vals = e.map((v) => (v as num).toDouble()).toList();
            final maxVal = vals.fold(0.0, (m, v) => v > m ? v : m);
            final scale = maxVal <= 1.5 ? 1000.0 : 1.0;
            return vals.map((v) => (v * scale).round()).toList();
          })
          .where((box) => box.length == 4)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Détection simplifiée : demande à Gemini où se trouve LA photo culinaire principale.
  /// Utilisé en repli si [detectIllustrationRegions] retourne [].
  /// Retourne null si aucune photo n'est trouvée.
  Future<List<int>?> detectMainCulinaryPhoto(
    Uint8List bytes,
    String mimeType,
  ) async {
    const prompt = '''
Regarde cette image. Y a-t-il une photographie d'un plat cuisiné, d'un repas ou d'une nourriture préparée ?

Si OUI : donne les coordonnées de la zone photo [y_min, x_min, y_max, x_max] en entiers 0-1000.
Si NON : réponds [].

Réponds UNIQUEMENT avec le tableau JSON, rien d'autre.
Exemple pour une photo en bas de l'image : [480, 0, 1000, 1000]
''';
    try {
      final content = Content.multi([
        DataPart(mimeType, bytes),
        TextPart(prompt),
      ]);
      final response = await _model
          .generateContent([content])
          .timeout(
            const Duration(seconds: 45),
            onTimeout: () =>
                throw TimeoutException('detectMainCulinaryPhoto timeout'),
          );
      await _logUsage('detect_main_photo', response);
      final text = (response.text ?? '')
          .trim()
          .replaceAll(RegExp(r'```json?|```'), '')
          .trim();
      if (text.isEmpty || text == '[]') return null;
      final jsonMatch = RegExp(r'\[.*?\]', dotAll: true).firstMatch(text);
      if (jsonMatch == null) return null;
      final parsed = jsonDecode(jsonMatch.group(0)!) as List;
      if (parsed.isEmpty) return null;
      // Accepte [[y,x,y,x]] ou [y,x,y,x]
      final raw = parsed.first is List ? parsed.first as List : parsed;
      if (raw.length != 4) return null;
      final vals = raw.map((v) => (v as num).toDouble()).toList();
      final maxVal = vals.fold(0.0, (m, v) => v > m ? v : m);
      final scale = maxVal <= 1.5 ? 1000.0 : 1.0;
      return vals.map((v) => (v * scale).round()).toList();
    } catch (_) {
      return null;
    }
  }

  /// Convertit un texte libre (recette saisie à la main) en CookLang via Gemini.
  /// Retourne null si aucune recette n'est détectée dans le texte.
  Future<String?> extractRecipeFromText(String text) async {
    final content = Content.text('$kGeminiFreeTextPrompt\n\n---\n$text');
    final response = await _model
        .generateContent([content])
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw TimeoutException('Gemini API timeout'),
        );
    await _logUsage('text_extraction', response);
    final result = response.text?.trim() ?? '';
    if (result.isEmpty || result == 'NO_RECIPE') return null;
    return result;
  }

  /// Corrige l'orthographe, la grammaire et les incohérences sémantiques
  /// d'une recette déjà formatée en CookLang, sans en changer la substance.
  Future<String?> polishCooklang(String cooklang) async {
    const prompt = r'''
Tu es un expert culinaire et en format CookLang. On te donne une recette déjà formatée en CookLang.

Ton rôle est de corriger et améliorer ce contenu sans en changer la substance :

1. ORTHOGRAPHE ET GRAMMAIRE :
   - Corrige les fautes d'orthographe, de grammaire et de ponctuation dans les textes des étapes, les noms d'ingrédients et les métadonnées.
   - Corrige les accents manquants ou incorrects.
   - Corrige la capitalisation (titre en titre case, étapes en minuscules).

2. COHÉRENCE SÉMANTIQUE ET CULINAIRE :
   - Si l'ordre des étapes est manifestement illogique (ex : "enfournez" avant "préchauffez le four"), réordonne-les.
   - Corrige les unités manifestement incohérentes (ex : "200 litres de farine" → "200 g de farine").
   - Si un ingrédient est utilisé dans les étapes mais n'apparaît nulle part dans les @balisages, ajoute-le.

3. FORMAT CookLang :
   - Assure-toi que tous les ingrédients sont balisés @nom{qté%unité}.
   - Assure-toi que les équipements sont balisés #nom{}.
   - Les timers doivent être ~{durée%unité}.
   - Un même ingrédient doit toujours avoir exactement la même orthographe dans tout le document.

4. MÉTADONNÉES (lignes >>) :
   - Corrige l'orthographe du titre et la capitalisation.
   - Ne change pas les valeurs numériques (portions, temps) sauf erreur manifeste.

Ce que tu NE dois PAS faire :
- Ajouter des ingrédients, des étapes ou des notes qui n'existent pas dans l'original.
- Changer les quantités sans raison évidente.
- Reformuler ou paraphraser les étapes (sauf correction orthographique mineure).
- Changer la structure générale (sections, ordre des sections).

Retourne UNIQUEMENT le contenu CookLang corrigé, sans explication, sans markdown, sans ```.
''';
    final content = Content.text('$prompt\n\n---\n$cooklang');
    final response = await _model
        .generateContent([content])
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw TimeoutException('Gemini API timeout'),
        );
    await _logUsage('polish_cooklang', response);
    final result = response.text?.trim() ?? '';
    if (result.isEmpty) return null;
    return result;
  }

  /// Recherche en langage naturel dans une liste de recettes.
  ///
  /// [query] : requête de l'utilisateur en langage naturel.
  /// [recipes] : résumés compacts des recettes à analyser (avec champ `note` si noté).
  /// [ratedRecipes] : sous-ensemble des recettes notées, pour que Gemini infère les goûts.
  ///
  /// Retourne un JSON avec :
  /// - `results` : recettes correspondantes avec raison
  /// - `suggestion` : reformulation si aucun résultat
  /// - `preference_insight` : observation sur les goûts de l'utilisateur (nullable)
  Future<Map<String, dynamic>> searchRecipes({
    required String query,
    required List<Map<String, String>> recipes,
    List<Map<String, String>> ratedRecipes = const [],
  }) async {
    if (recipes.isEmpty) {
      return {'results': [], 'suggestion': null, 'preference_insight': null};
    }

    final recipesJson = json.encode(recipes);
    final preferencesSection = ratedRecipes.isEmpty
        ? ''
        : '''
Préférences connues de l'utilisateur — recettes qu'il a notées (note sur 10) :
${json.encode(ratedRecipes)}
(Interprétation : ≥8 = aime beaucoup, 5–7 = apprécie, ≤4 = n'aime pas ou n'apprécie pas)

En analysant ces notes, déduis ses goûts : quels ingrédients, cuisines ou techniques aime-t-il ou évite-t-il ?
Si un pattern clair existe (ex : tout ce qui est frit est noté bas, les desserts au chocolat sont bien notés…), mentionne-le dans "preference_insight".
Tiens compte de ces préférences pour classer et sélectionner les résultats : priorise les recettes qui correspondent à ses goûts, signale si une recette correspond à quelque chose qu'il n'aime généralement pas.
''';

    final prompt =
        '''
Tu es un assistant culinaire expert qui connaît les goûts de l'utilisateur.

Requête de l'utilisateur : "$query"
$preferencesSection
Collection de recettes disponibles (format JSON, champ "note" = note personnelle /10 ou "non notée") :
$recipesJson

Analyse chaque recette et détermine si elle correspond à la requête.
Prends en compte le titre, les ingrédients, les tags, la difficulté, le livre source et les préférences de l'utilisateur.
Sois généreux dans ta sélection : si une recette contient les ingrédients principaux ou correspond au thème, inclus-la.
Si une recette correspond à la requête mais semble contraire aux goûts de l'utilisateur, inclus-la quand même mais mentionne-le dans la "raison".

Retourne UNIQUEMENT un JSON valide, sans markdown, sans texte additionnel, avec exactement ce format :
{
  "results": [
    {"id": "id_de_la_recette", "raison": "Explication courte (1-2 phrases) de pourquoi cette recette correspond"},
    ...
  ],
  "suggestion": null,
  "preference_insight": null
}

Si AUCUNE recette ne correspond, retourne :
{
  "results": [],
  "suggestion": "Une suggestion de reformulation pour trouver des recettes similaires (1 phrase)",
  "preference_insight": null
}

Si tu as détecté un pattern de goût clair dans les notes, remplis "preference_insight" avec une observation concise (1-2 phrases, ex: "Vous semblez apprécier les plats mijotés et les desserts. Les fritures ont tendance à être moins appréciées.").
Sinon laisse "preference_insight" à null.
''';

    final content = Content.text(prompt);
    final response = await _model
        .generateContent([content])
        .timeout(
          const Duration(minutes: 1),
          onTimeout: () => throw TimeoutException('Gemini search timeout'),
        );
    await _logUsage('search', response);
    final text = response.text?.trim() ?? '';
    if (text.isEmpty) {
      return {'results': [], 'suggestion': null, 'preference_insight': null};
    }

    final jsonText = _extractJsonObject(text);
    return json.decode(jsonText) as Map<String, dynamic>;
  }

  Future<BookCoverExtraction> extractBookCover(
    Uint8List bytes,
    String mimeType,
  ) async {
    final content = Content.multi([
      DataPart(mimeType, bytes),
      TextPart(kGeminiBookCoverPrompt),
    ]);

    final response = await _model
        .generateContent([content])
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw TimeoutException('Gemini API timeout'),
        );
    await _logUsage('book_cover', response);
    final text = response.text?.trim() ?? '';
    if (text.isEmpty) {
      throw const FormatException('Reponse vide pour la couverture du livre');
    }

    final jsonText = _extractJsonObject(text);
    final data = json.decode(jsonText) as Map<String, dynamic>;
    return BookCoverExtraction.fromMap(data);
  }

  /// Génère une nouvelle recette originale correspondant à la demande.
  ///
  /// [query] : ce que l'utilisateur recherche.
  /// [preferenceInsight] : profil de goûts déduit des notes précédentes.
  ///
  /// Retourne un Map avec les champs nécessaires pour construire un [Recipe].
  Future<Map<String, dynamic>> generateRecipe({
    required String query,
    String? preferenceInsight,
  }) async {
    final prefSection =
        (preferenceInsight != null && preferenceInsight.isNotEmpty)
        ? '\nTiens compte des préférences connues de l\'utilisateur : $preferenceInsight\n'
        : '';

    final prompt =
        '''
Tu es un chef cuisinier expert francophone. L'utilisateur cherche une recette : "$query"$prefSection
Génère une recette originale complète qui répond exactement à cette demande.
Si des préférences utilisateur sont indiquées, adapte la recette pour lui correspondre.

Retourne la réponse en DEUX sections exactement dans ce format (rien d'autre) :

===METADATA===
{
  "titre": "Nom de la recette",
  "langue": "fr",
  "ingredients_index": ["ingredient1", "ingredient2"],
  "ingredients": [
    {"name": "ingredient", "qty": "200", "unit": "g"}
  ],
  "tags": {
    "themes": ["plat principal"],
    "cuisines": ["française"],
    "occasions": [],    "dish_types": ["viande"],    "difficulty": "facile",
    "prep_time": 20,
    "cook_time": 40
  },
  "portions": 4
}
===COOKLANG===
Contenu complet de la recette au format CookLang (ici pas de JSON, écris directement)
===END===

Règles CookLang (OBLIGATOIRES) :
- Ingrédients : @nom{quantité%unité} — ex : @farine{200%g}, @oeufs{2}, @sel{}
- Matériel : #nom{} — ex : #four{}, #poêle{}
- Temps : ~{hh:mm:ss} — ex : ~{0:30:00} pour 30 minutes, ~{1:30:00} pour 1h30
- Sections de préparation (quand la recette a plusieurs parties distinctes) : == Nom de section ==
  Exemples : == La sauce ==, == Le montage ==, == La pâte ==
  Mets == Nom == sur sa propre ligne AVANT les étapes de cette partie.
  N'utilise PAS de section si la recette est simple et linéaire.
- Notes et conseils (accompagnement, variante, astuce, conservation…) : > Texte de la note
  Exemples : > Idée d'accompagnement : servir avec une salade verte., > Conseil : peut se préparer la veille.
  Mets > Note sur sa propre ligne, après l'étape concernée ou en fin de recette.
  N'utilise PAS de note si l'information est déjà dans les étapes.
- Chaque étape sur une nouvelle ligne distincte.
- Le texte doit être en français.
- INTERDIT : N'utilise JAMAIS ~{0:00:00} — un timer nul n'a aucun sens.
- INTERDIT : Ne mets PAS de timer pour les températures (ex: "préchauffer le four à 200°C" → écris simplement 200°C dans le texte, sans ~{}).
- INTERDIT : Les mesures d'épaisseur ou de taille dans le texte (ex: 0.5 cm, 1 cm) ne sont PAS des ingrédients — écris-les directement dans le texte, jamais avec @.
- INTERDIT : Ne jamais baliser avec @ le plat ou produit FINAL que la recette crée (ex : chaussons, boulettes, croquettes, raviolis… le nom du produit fini n'est pas un ingrédient). Les instructions de division ("20 parts égales") ne sont jamais des ingrédients — écris-les en texte plain.
- Les timers servent UNIQUEMENT pour des durées réelles de cuisson ou d'attente (valeur strictement > 0).
''';

    final content = Content.text(prompt);
    final response = await _model
        .generateContent([content])
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw TimeoutException('Gemini generate timeout'),
        );
    await _logUsage('generate', response);
    final text = response.text?.trim() ?? '';
    if (text.isEmpty) throw const FormatException('Réponse Gemini vide');

    // Parse les deux sections délimitées (évite les problèmes JSON avec le CookLang)
    const metaMarker = '===METADATA===';
    const cooklangMarker = '===COOKLANG===';
    const endMarker = '===END===';
    final metaStart = text.indexOf(metaMarker);
    final cooklangStart = text.indexOf(cooklangMarker);
    if (metaStart == -1 || cooklangStart == -1) {
      throw const FormatException(
        'Format de réponse Gemini invalide (marqueurs manquants)',
      );
    }
    final metaJson = text
        .substring(metaStart + metaMarker.length, cooklangStart)
        .trim();
    final endIdx = text.indexOf(endMarker);
    final cooklang =
        (endIdx == -1
                ? text.substring(cooklangStart + cooklangMarker.length)
                : text.substring(cooklangStart + cooklangMarker.length, endIdx))
            .trim();

    final data =
        json.decode(_extractJsonObject(metaJson)) as Map<String, dynamic>;
    data['cooklang'] = cooklang;
    return data;
  }

  /// Raffine une recette existante en appliquant une instruction de l'utilisateur.
  ///
  /// Transmet la recette complète (CookLang + métadonnées) à Gemini avec
  /// l'instruction de modification. Seule la partie concernée par la consigne
  /// est modifiée, le reste est conservé.
  Future<Map<String, dynamic>> refineRecipe({
    required String currentTitre,
    required String currentCooklang,
    required List<Map<String, dynamic>> currentIngredients,
    required Map<String, dynamic> currentTags,
    required int? currentPortions,
    required String instruction,
  }) async {
    final ingredientsList = currentIngredients
        .map(
          (i) =>
              '- ${[i['qty'], i['unit'], i['name']].where((s) => (s as String?)?.isNotEmpty == true).join(' ')}'
                  .trim(),
        )
        .join('\n');

    final portions = currentPortions != null
        ? '\nPortions : $currentPortions'
        : '';

    final prompt =
        '''
Tu es un chef cuisinier expert francophone. Voici une recette existante :

TITRE: $currentTitre$portions
INGRÉDIENTS:
$ingredientsList

RECETTE AU FORMAT COOKLANG:
$currentCooklang

L'utilisateur souhaite modifier cette recette avec la consigne suivante :
"$instruction"

Applique EXACTEMENT cette consigne en modifiant la recette. Conserve tout ce qui n'est pas concerné par la consigne (structure, autres ingrédients, étapes non touchées, etc.).

Retourne la recette MODIFIÉE en DEUX sections exactement dans ce format (rien d'autre) :

===METADATA===
{
  "titre": "Nom de la recette",
  "langue": "fr",
  "ingredients_index": ["ingredient1", "ingredient2"],
  "ingredients": [
    {"name": "ingredient", "qty": "200", "unit": "g"}
  ],
  "tags": {
    "themes": ["plat principal"],
    "cuisines": ["française"],
    "occasions": [],
    "dish_types": ["viande"],
    "difficulty": "facile",
    "prep_time": 20,
    "cook_time": 40
  },
  "portions": 4
}
===COOKLANG===
Contenu complet de la recette modifiée au format CookLang (ici pas de JSON, écris directement)
===END===

Règles CookLang (OBLIGATOIRES) :
- Ingrédients : @nom{quantité%unité} — ex : @farine{200%g}, @oeufs{2}, @sel{}
- Matériel : #nom{} — ex : #four{}, #poêle{}
- Temps : ~{hh:mm:ss} — ex : ~{0:30:00} pour 30 minutes, ~{1:30:00} pour 1h30
- Sections de préparation (quand la recette a plusieurs parties distinctes) : == Nom de section ==
  Exemples : == La sauce ==, == Le montage ==, == La pâte ==
  Mets == Nom == sur sa propre ligne AVANT les étapes de cette partie.
  N'utilise PAS de section si la recette est simple et linéaire.
- Notes et conseils (accompagnement, variante, astuce, conservation…) : > Texte de la note
  Exemples : > Idée d'accompagnement : servir avec une salade verte., > Conseil : peut se préparer la veille.
  Mets > Note sur sa propre ligne, après l'étape concernée ou en fin de recette.
  N'utilise PAS de note si l'information est déjà dans les étapes.
- Chaque étape sur une nouvelle ligne distincte.
- Le texte doit être en français.
- INTERDIT : N'utilise JAMAIS ~{0:00:00} — un timer nul n'a aucun sens.
- INTERDIT : Ne mets PAS de timer pour les températures (ex: "préchauffer le four à 200°C" → écris simplement 200°C dans le texte, sans ~{}).
- INTERDIT : Les mesures d'épaisseur ou de taille dans le texte (ex: 0.5 cm, 1 cm) ne sont PAS des ingrédients — écris-les directement dans le texte, jamais avec @.
- INTERDIT : Ne jamais baliser avec @ le plat ou produit FINAL que la recette crée (ex : chaussons, boulettes, croquettes, raviolis… le nom du produit fini n'est pas un ingrédient). Les instructions de division ("20 parts égales") ne sont jamais des ingrédients — écris-les en texte plain.
- Les timers servent UNIQUEMENT pour des durées réelles de cuisson ou d'attente (valeur strictement > 0).
''';

    final content = Content.text(prompt);
    final response = await _model
        .generateContent([content])
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw TimeoutException('Gemini refine timeout'),
        );
    await _logUsage('refine', response);
    final text = response.text?.trim() ?? '';
    if (text.isEmpty) throw const FormatException('Réponse Gemini vide');

    const metaMarker = '===METADATA===';
    const cooklangMarker = '===COOKLANG===';
    const endMarker = '===END===';
    final metaStart = text.indexOf(metaMarker);
    final cooklangStart = text.indexOf(cooklangMarker);
    if (metaStart == -1 || cooklangStart == -1) {
      throw const FormatException(
        'Format de réponse Gemini invalide (marqueurs manquants)',
      );
    }
    final metaJson = text
        .substring(metaStart + metaMarker.length, cooklangStart)
        .trim();
    final endIdx = text.indexOf(endMarker);
    final cooklang =
        (endIdx == -1
                ? text.substring(cooklangStart + cooklangMarker.length)
                : text.substring(cooklangStart + cooklangMarker.length, endIdx))
            .trim();

    final data =
        json.decode(_extractJsonObject(metaJson)) as Map<String, dynamic>;
    data['cooklang'] = cooklang;
    return data;
  }

  /// Génère une requête Google optimisée à partir d'une demande libre.
  ///
  /// Corrige les fautes, extrait les mots-clés culinaires pertinents et
  /// retourne une requête courte et efficace (sans le mot "recette",
  /// celui-ci sera ajouté en dehors).
  Future<String> generateWebSearchQuery(String userQuery) async {
    final prompt =
        '''
Tu es un expert SEO spécialisé en cuisine.
L'utilisateur veut chercher une recette sur Google avec la demande suivante : "$userQuery"

Génère UNE SEULE requête Google optimisée pour trouver cette recette.
Règles strictes :
- Corrige les fautes d'orthographe
- Garde uniquement les mots-clés culinaires essentiels (nom du plat, type de cuisine, contraintes clés)
- N'ajoute PAS le mot "recette" (il sera ajouté automatiquement)
- Ne dépasse pas 6 mots
- Réponds UNIQUEMENT avec la requête, sans guillemets, sans explication
''';
    final response = await _model
        .generateContent([Content.text(prompt)])
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () =>
              throw TimeoutException('generateWebSearchQuery timeout'),
        );
    await _logUsage('web_search_query', response);
    final query = response.text?.trim() ?? '';
    if (query.isEmpty) throw const FormatException('Réponse Gemini vide');
    return query;
  }
}

// ── Utilitaire ────────────────────────────────────────────────────────────────

/// Extrait le premier objet JSON valide (accolades équilibrées) d'une string.
/// Utile pour parser les réponses Gemini qui peuvent contenir du texte autour
/// du JSON.
String _extractJsonObject(String text) {
  final start = text.indexOf('{');
  if (start == -1) throw const FormatException('JSON invalide');

  int depth = 0;
  bool inString = false;
  bool escape = false;

  for (int i = start; i < text.length; i++) {
    final c = text[i];
    if (escape) {
      escape = false;
      continue;
    }
    if (c == r'\' && inString) {
      escape = true;
      continue;
    }
    if (c == '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return text.substring(start, i + 1);
    }
  }

  throw const FormatException('JSON invalide : accolades non appariées');
}
