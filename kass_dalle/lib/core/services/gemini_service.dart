import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';
import '../../features/recipes/domain/recipe.dart';

/// Service d'extraction de recettes via Gemini.
///
/// La clé API est fournie à la construction (lue depuis Firestore/Remote Config
/// ou via --dart-define=GEMINI_API_KEY=xxx au build).
class GeminiService {
  static const _modelName = 'gemini-2.5-flash';

  late final GenerativeModel _model;

  GeminiService(String apiKey)
    : _model = GenerativeModel(model: _modelName, apiKey: apiKey);

  static const _prompt = r'''
Tu es un expert en cuisine et en format CookLang.
Extrais TOUTES les recettes présentes dans ce document et convertis-les en format CookLang strict.

Règle FONDAMENTALE — COPIE FIDÈLE :
- Conserve le texte des étapes AUSSI PROCHE QUE POSSIBLE de l'original.
- Ne reformule PAS, ne résume PAS, ne réinterprète PAS, n'invente AUCUN ingrédient ni quantité.
- Respecte EXACTEMENT les quantités, les ingrédients et le découpage des étapes du document.
- Si l'original dit "coupez le chou en dés", écris "coupez le @chou{} en dés" — ne remplace pas par une autre formulation.
- Si une information n'est pas dans le document, ne l'invente pas.

Règles CookLang :
- Métadonnées (lignes commençant par >>) :
    >> titre: Nom de la recette
    >> page: 42
    >> portions: 4
    >> difficulté: facile|moyen|difficile
    >> temps_préparation: 20 min
    >> temps_cuisson: 35 min
  Règle importante : si un numéro de page est visible dans le document (coin de page, en-tête, pied de page), indique-le dans « >> page: N ».
- Les ingrédients sont intégrés dans le texte des étapes : @nom{quantité%unité}
  Règles importantes :
  1. Utilise des ESPACES dans les noms multi-mots (jamais des underscores).
  2. Les accolades {} sont obligatoires, et TOUJOURS remplies avec quantité%unité quand connus.
  3. Si l'ingrédient est mesuré en « brin », « filet », « noisette », « pince », « pincee », « bouquet », etc., utilise ce mot comme unité même si c'est aussi le début du nom.
  4. Ne laisse JAMAIS les accolades vides si la quantité ou l'unité est connue.
  5. COHÉRENCE ABSOLUE : utilise EXACTEMENT la même orthographe pour un même ingrédient dans toutes les étapes de la recette (même forme singulier/pluriel, même ordre des mots, même casse). Ne jamais écrire @côte de veau dans une étape et @côtes de veau dans une autre.
  Exemples corrects : @oeufs{3}, @farine{200%g}, @sel{1%pincée}, @brin de romarin{1%brin}, @brin de sauge{2%brins}, @filet d'huile d'olive{1%filet}, @noisette de beurre{1%noisette}, @huile d'olive{2%cuillères à soupe}, @côtes de veau{2%pièces}
  Mauvais exemples (à éviter) : @brin_de_romarin{1}, @brin de romarin{}, @brin_de_romarin{}, écrire @côte de veau dans une étape et @côtes de veau dans une autre
- Les équipements : #nom{quantité}  Exemples : #four{}, #poêle{}, #moule à tarte{}, #moule à muffin{12}, #plaque de cuisson{}, #saladier{}, #casserole{}, #mixeur{}
  RÈGLE CRITIQUE — ustensiles vs ingrédients :
  • Un ustensile, contenant ou accessoire de cuisine est TOUJOURS un équipement (#), JAMAIS un ingrédient (@),
    même si la recette précise une quantité ou des dimensions (ex : "12 moules à muffin" → #moule à muffin{12}).
  • Les mots suivants désignent TOUJOURS des équipements (#) : moule à, plaque, casserole, poêle, saladier,
    bol, mixeur, fouet, spatule, rouleau, tamis, passoire, cocotte, wok, sauteuse, ramequin, terrine.
  • EXCEPTION : « moule » seul (sans complément) peut être le mollusque (@moule{}) ou l'ustensile selon le contexte ;
    si le texte parle de cuisine de pâtisserie/cuisson au four → équipement (#moule{}) ;
    si le texte parle de fruits de mer/plat de la mer → ingrédient (@moule{}).
  • Les températures ("180°C", "thermostat 6") sont du texte plain dans les étapes, jamais des ingrédients (@).
    Écris : "Préchauffez le #four{} à 180°C" et NON "à @180°C{}"
- Les timers : ~{durée%unité}  Exemples : ~{20%minutes}, ~{1%heure}
- Chaque étape est une ligne de texte plain
- Séparateur entre plusieurs recettes : ---

Exemple de sortie attendue :
>> titre: Tarte aux pommes
>> page: 42
>> portions: 6
>> difficulté: facile

Préchauffez le #four{} à 180°C.
Épluchez et découpez @pommes{6} en fines tranches.
Étalez la @pâte brisée{1} dans un #moule à tarte{}.
Disposez les pommes et saupoudrez de @sucre roux{2%cuillères à soupe}.
Enfournez pendant ~{35%minutes} jusqu'à coloration dorée.

---

Retourne UNIQUEMENT le contenu CookLang, sans explication, sans markdown, sans ``` .
Si plusieurs recettes, sépare-les avec ---.
Si aucune recette n'est trouvée, retourne exactement : NO_RECIPE
''';

  static const _freeTextPrompt = r'''
Tu es un expert en cuisine et en format CookLang.
L'utilisateur t'a fourni le texte brut d'une recette. Convertis-la en format CookLang strict.

Règle FONDAMENTALE — COPIE FIDÈLE :
- Conserve le texte des étapes AUSSI PROCHE QUE POSSIBLE de l'original.
- Ne reformule PAS, ne résume PAS, ne réinterprète PAS, n'invente AUCUN ingrédient ni quantité.
- Respecte EXACTEMENT les quantités, les ingrédients et le découpage des étapes.
- Ton seul travail est d'identifier les ingrédients (@), les équipements (#) et les timers (~) dans le texte existant.
- Si une information n'est pas dans le texte, ne l'invente pas.

Règles CookLang :
- Métadonnées (lignes commençant par >>) :
    >> titre: Nom de la recette
    >> portions: 4
    >> difficulté: facile|moyen|difficile
    >> temps_préparation: 20 min
    >> temps_cuisson: 35 min
- Les ingrédients sont intégrés dans le texte des étapes : @nom{quantité%unité}
  Règles importantes :
  1. Utilise des ESPACES dans les noms multi-mots (jamais des underscores).
  2. Les accolades {} sont obligatoires, et TOUJOURS remplies avec quantité%unité quand connus.
  3. Si l'ingrédient est mesuré en « brin », « filet », « noisette », « pincée », « bouquet », etc., utilise ce mot comme unité même si c'est aussi le début du nom.
  4. Ne laisse JAMAIS les accolades vides si la quantité ou l'unité est connue.
  5. COHÉRENCE ABSOLUE : utilise EXACTEMENT la même orthographe pour un même ingrédient dans toutes les étapes (même forme singulier/pluriel, même ordre des mots). Ne jamais écrire @côte de veau dans une étape et @côtes de veau dans une autre.
  Exemples corrects : @oeufs{3}, @farine{200%g}, @sel{1%pincée}, @brin de romarin{1%brin}, @brin de sauge{2%brins}, @filet d'huile d'olive{1%filet}, @noisette de beurre{1%noisette}, @huile d'olive{2%cuillères à soupe}
  Mauvais exemples (à éviter) : @brin_de_romarin{1}, @brin de romarin{}, @brin_de_romarin{}, écrire @côte de veau dans une étape et @côtes de veau dans une autre
- Les équipements : #nom{quantité}  Exemples : #four{}, #poêle{}, #moule à muffin{12}, #plaque de cuisson{}, #saladier{}
  RÈGLE CRITIQUE — ustensiles vs ingrédients :
  • Un ustensile, contenant ou accessoire de cuisine est TOUJOURS un équipement (#), JAMAIS un ingrédient (@),
    même si la recette précise une quantité ou des dimensions (ex : "12 moules à muffin" → #moule à muffin{12}).
  • Les mots suivants désignent TOUJOURS des équipements (#) : moule à, plaque, casserole, poêle, saladier,
    bol, mixeur, fouet, spatule, rouleau, tamis, passoire, cocotte, wok, sauteuse, ramequin, terrine.
  • EXCEPTION : « moule » seul peut être le mollusque (@moule{}) ou l'ustensile selon le contexte.
  • Les températures ("180°C") sont du texte plain, jamais des ingrédients (@).
    Écris : "Préchauffez le #four{} à 180°C" et NON "à @180°C{}"
- Les timers : ~{durée%unité}  Exemples : ~{20%minutes}, ~{1%heure}
- Chaque étape est une ligne de texte plain

Retourne UNIQUEMENT le contenu CookLang, sans explication, sans markdown, sans ```.
Si aucune recette n'est trouvée, retourne exactement : NO_RECIPE
''';

  static const _bookCoverPrompt = r'''
Tu analyses une page de garde de livre de cuisine.
Retourne strictement un JSON valide, sans markdown, sans texte additionnel.

Schema attendu:
{
  "titre": "string",
  "sous_titre": "string|null",
  "auteur": "string",
  "editeur": "string|null",
  "serie": "string|null",
  "annee": 2024,
  "langue": "fr|en|nl",
  "isbn": "string|null",
  "description": "string|null",
  "tags": ["tag1", "tag2"]
}

Contraintes:
- "titre" et "auteur" doivent etre non vides.
- Si valeur inconnue, utilise null.
- "annee" doit etre un entier ou null.
- "langue" doit etre l'une des valeurs fr/en/nl (par defaut fr).
- "tags" doit etre une liste (vide possible).
''';

  /// Envoie un fichier (PDF, DOCX, image) à Gemini et retourne le CookLang extrait.
  /// Retourne une liste de strings CookLang (une par recette détectée).
  Future<List<String>> extractRecipes(Uint8List bytes, String mimeType) async {
    final content = Content.multi([
      DataPart(mimeType, bytes),
      TextPart(_prompt),
    ]);

    final response = await _model
        .generateContent([content])
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw TimeoutException('Gemini API timeout'),
        );
    final text = response.text?.trim() ?? '';

    if (text.isEmpty || text == 'NO_RECIPE') return [];

    // Sépare les recettes multiples
    return text
        .split(RegExp(r'\n---+\n'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// Convertit un texte libre (recette saisie à la main) en CookLang via Gemini.
  /// Retourne null si aucune recette n'est détectée dans le texte.
  Future<String?> extractRecipeFromText(String text) async {
    final content = Content.text('$_freeTextPrompt\n\n---\n$text');
    final response = await _model
        .generateContent([content])
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw TimeoutException('Gemini API timeout'),
        );
    final result = response.text?.trim() ?? '';
    if (result.isEmpty || result == 'NO_RECIPE') return null;
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
    final text = response.text?.trim() ?? '';
    if (text.isEmpty)
      return {'results': [], 'suggestion': null, 'preference_insight': null};

    final jsonText = _extractJsonObject(text);
    return json.decode(jsonText) as Map<String, dynamic>;
  }

  Future<BookCoverExtraction> extractBookCover(
    Uint8List bytes,
    String mimeType,
  ) async {
    final content = Content.multi([
      DataPart(mimeType, bytes),
      TextPart(_bookCoverPrompt),
    ]);

    final response = await _model
        .generateContent([content])
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw TimeoutException('Gemini API timeout'),
        );
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

    final prompt = '''
Tu es un chef cuisinier expert francophone. L\'utilisateur cherche une recette : "$query"$prefSection
Génère une recette originale complète qui répond exactement à cette demande.
Si des préférences utilisateur sont indiquées, adapte la recette pour lui correspondre.

Retourne la réponse en DEUX sections exactement dans ce format (rien d\'autre) :

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
    "difficulty": "facile",
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
- Chaque étape sur une nouvelle ligne distincte.
- Le texte doit être en français.
- INTERDIT : N'utilise JAMAIS ~{0:00:00} — un timer nul n'a aucun sens.
- INTERDIT : Ne mets PAS de timer pour les températures (ex: "préchauffer le four à 200°C" → écris simplement 200°C dans le texte, sans ~{}).
- INTERDIT : Les mesures d'épaisseur ou de taille dans le texte (ex: 0.5 cm, 1 cm) ne sont PAS des ingrédients — écris-les directement dans le texte, jamais avec @.
- Les timers servent UNIQUEMENT pour des durées réelles de cuisson ou d'attente (valeur strictement > 0).
''';  

    final content = Content.text(prompt);
    final response = await _model
        .generateContent([content])
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw TimeoutException('Gemini generate timeout'),
        );
    final text = response.text?.trim() ?? '';
    if (text.isEmpty) throw const FormatException('Réponse Gemini vide');

    // Parse les deux sections délimitées (évite les problèmes JSON avec le CookLang)
    const metaMarker = '===METADATA===';
    const cooklangMarker = '===COOKLANG===';
    const endMarker = '===END===';
    final metaStart = text.indexOf(metaMarker);
    final cooklangStart = text.indexOf(cooklangMarker);
    if (metaStart == -1 || cooklangStart == -1) {
      throw const FormatException('Format de réponse Gemini invalide (marqueurs manquants)');
    }
    final metaJson = text
        .substring(metaStart + metaMarker.length, cooklangStart)
        .trim();
    final endIdx = text.indexOf(endMarker);
    final cooklang = (endIdx == -1
            ? text.substring(cooklangStart + cooklangMarker.length)
            : text.substring(cooklangStart + cooklangMarker.length, endIdx))
        .trim();

    final data = json.decode(_extractJsonObject(metaJson)) as Map<String, dynamic>;
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
        .map((i) => '- ${[i['qty'], i['unit'], i['name']].where((s) => (s as String?)?.isNotEmpty == true).join(' ')}'.trim())
        .join('\n');

    final portions = currentPortions != null ? '\nPortions : $currentPortions' : '';

    final prompt = '''
Tu es un chef cuisinier expert francophone. Voici une recette existante :

TITRE: $currentTitre$portions
INGRÉDIENTS:
$ingredientsList

RECETTE AU FORMAT COOKLANG:
$currentCooklang

L\'utilisateur souhaite modifier cette recette avec la consigne suivante :
"$instruction"

Applique EXACTEMENT cette consigne en modifiant la recette. Conserve tout ce qui n\'est pas concerné par la consigne (structure, autres ingrédients, étapes non touchées, etc.).

Retourne la recette MODIFIÉE en DEUX sections exactement dans ce format (rien d\'autre) :

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
- Chaque étape sur une nouvelle ligne distincte.
- Le texte doit être en français.
- INTERDIT : N'utilise JAMAIS ~{0:00:00} — un timer nul n'a aucun sens.
- INTERDIT : Ne mets PAS de timer pour les températures (ex: "préchauffer le four à 200°C" → écris simplement 200°C dans le texte, sans ~{}).
- INTERDIT : Les mesures d'épaisseur ou de taille dans le texte (ex: 0.5 cm, 1 cm) ne sont PAS des ingrédients — écris-les directement dans le texte, jamais avec @.
- Les timers servent UNIQUEMENT pour des durées réelles de cuisson ou d'attente (valeur strictement > 0).
''';

    final content = Content.text(prompt);
    final response = await _model
        .generateContent([content])
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw TimeoutException('Gemini refine timeout'),
        );
    final text = response.text?.trim() ?? '';
    if (text.isEmpty) throw const FormatException('Réponse Gemini vide');

    const metaMarker = '===METADATA===';
    const cooklangMarker = '===COOKLANG===';
    const endMarker = '===END===';
    final metaStart = text.indexOf(metaMarker);
    final cooklangStart = text.indexOf(cooklangMarker);
    if (metaStart == -1 || cooklangStart == -1) {
      throw const FormatException('Format de réponse Gemini invalide (marqueurs manquants)');
    }
    final metaJson = text
        .substring(metaStart + metaMarker.length, cooklangStart)
        .trim();
    final endIdx = text.indexOf(endMarker);
    final cooklang = (endIdx == -1
            ? text.substring(cooklangStart + cooklangMarker.length)
            : text.substring(cooklangStart + cooklangMarker.length, endIdx))
        .trim();

    final data = json.decode(_extractJsonObject(metaJson)) as Map<String, dynamic>;
    data['cooklang'] = cooklang;
    return data;
  }
}

class BookCoverExtraction {
  final String titre;
  final String auteur;
  final String? sousTitre;
  final String? editeur;
  final String? serie;
  final int? annee;
  final String langue;
  final String? isbn;
  final String? description;
  final List<String> tags;

  const BookCoverExtraction({
    required this.titre,
    required this.auteur,
    this.sousTitre,
    this.editeur,
    this.serie,
    this.annee,
    required this.langue,
    this.isbn,
    this.description,
    this.tags = const [],
  });

  factory BookCoverExtraction.fromMap(Map<String, dynamic> data) {
    final rawLangue = (data['langue'] as String? ?? 'fr').toLowerCase();
    final langue = switch (rawLangue) {
      'fr' || 'en' || 'nl' => rawLangue,
      _ => 'fr',
    };

    return BookCoverExtraction(
      titre: (data['titre'] as String? ?? '').trim().isEmpty
          ? 'Livre sans titre'
          : (data['titre'] as String).trim(),
      auteur: (data['auteur'] as String? ?? '').trim().isEmpty
          ? 'Auteur inconnu'
          : (data['auteur'] as String).trim(),
      sousTitre: _nullableTrim(data['sous_titre'] as String?),
      editeur: _nullableTrim(data['editeur'] as String?),
      serie: _nullableTrim(data['serie'] as String?),
      annee: _toNullableInt(data['annee']),
      langue: langue,
      isbn: _nullableTrim(data['isbn'] as String?),
      description: _nullableTrim(data['description'] as String?),
      tags: List<String>.from(
        data['tags'] as List? ?? [],
      ).map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList(),
    );
  }
}

// ── Helpers CookLang ──────────────────────────────────────────────────────────

/// Extrait les métadonnées >> d'un bloc CookLang.
Map<String, String> parseCooklangMeta(String cooklang) {
  final meta = <String, String>{};
  for (final line in cooklang.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('>>')) {
      final content = trimmed.substring(2);
      final colonIdx = content.indexOf(':');
      if (colonIdx > 0) {
        final key = content.substring(0, colonIdx).trim().toLowerCase();
        final value = content.substring(colonIdx + 1).trim();
        meta[key] = value;
      }
    }
  }
  return meta;
}

/// Retourne true si le nom ressemble à une température (ex: "180°c") ou commence
/// par un chiffre — ces tokens ne sont pas des ingrédients.
bool _isTemperatureLike(String name) {
  final n = name.trim().toLowerCase();
  return n.contains('°') || RegExp(r'^\d').hasMatch(n);
}

/// Extrait la liste des ingrédients (@nom) d'un bloc CookLang.
/// Résultat trié par ordre d'apparition, sans doublons de nom, sans températures.
List<String> extractIngredients(String cooklang) {
  final re = RegExp(r'@([^{@#~\n]+)(?:\{[^}]*\})?');
  final seen = <String>{};
  final result = <String>[];
  for (final m in re.allMatches(cooklang)) {
    final name = m.group(1)!.trim().toLowerCase();
    if (_isTemperatureLike(name)) continue;
    if (seen.add(name)) result.add(name);
  }
  return result;
}

/// Normalise un nom d'ingrédient pour la déduplication.
/// Passe en minuscules et supprime le 's' final de chaque mot
/// afin de traiter identiquement les formes singulier et pluriel
/// (ex : « côtes de veau » et « côte de veau » → même clé).
String _ingredientKey(String name) => name
    .toLowerCase()
    .split(' ')
    .map(
      (w) => w.endsWith('s') && w.length > 2 ? w.substring(0, w.length - 1) : w,
    )
    .join(' ');

/// Extrait la liste structurée des ingrédients avec quantité et unité.
/// Triée par ordre d'apparition dans la recette.
/// Si un même ingrédient apparaît avec des quantités différentes, elles sont
/// combinées (ex : "45 g + une poignée").
List<RecipeIngredient> extractIngredientsStructured(String cooklang) {
  final re = RegExp(r'@([^{@#~\n]+)\{([^}]*)\}');
  final indexMap = <String, int>{};
  final result = <RecipeIngredient>[];
  for (final m in re.allMatches(cooklang)) {
    final name = m.group(1)!.trim();
    if (_isTemperatureLike(name)) continue;
    final key = _ingredientKey(name);
    final parts = (m.group(2) ?? '').split('%');
    final qty = parts.isNotEmpty ? parts[0].trim() : '';
    final unit = parts.length > 1 ? parts[1].trim() : '';
    if (indexMap.containsKey(key)) {
      // Combine les quantités si elles diffèrent
      final idx = indexMap[key]!;
      final existing = result[idx];
      if (qty.isNotEmpty && qty != existing.qty) {
        final combinedQty = existing.qty.isNotEmpty
            ? '${existing.qty} + $qty'
            : qty;
        result[idx] = RecipeIngredient(
          name: existing.name,
          qty: combinedQty,
          unit: existing.unit.isNotEmpty ? existing.unit : unit,
        );
      }
    } else {
      indexMap[key] = result.length;
      result.add(RecipeIngredient(name: name, qty: qty, unit: unit));
    }
  }
  return result;
}

/// Extrait le nombre de portions depuis les métadonnées CookLang (>> portions: N).
int? extractPortions(String cooklang) {
  final meta = parseCooklangMeta(cooklang);
  final raw = meta['portions'] ?? meta['servings'];
  if (raw == null) return null;
  return int.tryParse(raw.split(' ').first);
}

int? _parseTimeToMinutes(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final text = raw.toLowerCase().trim();
  final match = RegExp(r'(\d+)').firstMatch(text);
  if (match == null) return null;
  final value = int.tryParse(match.group(1)!);
  if (value == null) return null;
  if (text.contains('h')) {
    return value * 60;
  }
  return value;
}

RecipeTags extractRecipeTags(String cooklang) {
  final meta = parseCooklangMeta(cooklang);
  return RecipeTags(
    difficulty: meta['difficulte'] ?? meta['difficulté'] ?? meta['difficulty'],
    prepTime: _parseTimeToMinutes(
      meta['temps_preparation'] ??
          meta['temps_préparation'] ??
          meta['prep_time'],
    ),
    cookTime: _parseTimeToMinutes(
      meta['temps_cuisson'] ?? meta['cook_time'] ?? meta['cuisson'],
    ),
  );
}

/// Extrait le titre depuis les métadonnées ou retourne un fallback.
String extractTitle(String cooklang) {
  final meta = parseCooklangMeta(cooklang);
  return meta['titre'] ?? meta['title'] ?? meta['nom'] ?? 'Recette sans titre';
}

/// Extrait le numéro de page depuis les métadonnées CookLang (>> page: N).
int? extractPageNumber(String cooklang) {
  final meta = parseCooklangMeta(cooklang);
  final raw = meta['page'] ?? meta['page_number'];
  if (raw == null) return null;
  return int.tryParse(raw.trim().split(' ').first);
}

String _extractJsonObject(String text) {
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start == -1 || end == -1 || end <= start) {
    throw const FormatException('JSON invalide');
  }
  return text.substring(start, end + 1);
}

String? _nullableTrim(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _toNullableInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}
