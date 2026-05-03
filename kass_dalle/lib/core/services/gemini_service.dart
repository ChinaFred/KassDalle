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
- Les équipements : #nom{}  Exemples : #four{}, #poêle{}, #moule à tarte{}
- Les timers : ~{durée%unité}  Exemples : ~{20%minutes}, ~{1%heure}
- Chaque étape est une ligne de texte plain
- Séparateur entre plusieurs recettes : ---

Exemple de sortie attendue :
>> titre: Tarte aux pommes
>> page: 42
>> portions: 6
>> difficulté: facile

Préchauffez le #four{} à @température{180%°C}.
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
- Les équipements : #nom{}  Exemples : #four{}, #poêle{}
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

/// Extrait la liste des ingrédients (@nom) d'un bloc CookLang.
List<String> extractIngredients(String cooklang) {
  final re = RegExp(r'@([^{@#~\n]+)(?:\{[^}]*\})?');
  return re
      .allMatches(cooklang)
      .map((m) => m.group(1)!.trim().toLowerCase())
      .toSet()
      .toList()
    ..sort();
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
List<RecipeIngredient> extractIngredientsStructured(String cooklang) {
  final re = RegExp(r'@([^{@#~\n]+)\{([^}]*)\}');
  final seen = <String>{};
  final result = <RecipeIngredient>[];
  for (final m in re.allMatches(cooklang)) {
    final name = m.group(1)!.trim();
    final key = _ingredientKey(name);
    if (seen.contains(key)) continue;
    seen.add(key);
    final parts = (m.group(2) ?? '').split('%');
    result.add(
      RecipeIngredient(
        name: name,
        qty: parts.isNotEmpty ? parts[0].trim() : '',
        unit: parts.length > 1 ? parts[1].trim() : '',
      ),
    );
  }
  result.sort((a, b) => a.name.compareTo(b.name));
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
