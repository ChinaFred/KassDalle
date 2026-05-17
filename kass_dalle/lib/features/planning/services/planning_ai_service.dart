import 'dart:convert';

import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:intl/intl.dart';

import '../../recipes/domain/recipe.dart';
import '../domain/planning_preferences.dart';

/// Service d'IA pour la génération de planning de repas via Gemini.
class PlanningAiService {
  static const _modelName = 'gemini-2.5-flash';

  /// Suggère un planning de repas pour les [slotDates] données.
  ///
  /// Retourne une liste de la même taille que [slotDates].
  /// Chaque entrée est soit une Recipe suggérée, soit null si aucune suggestion.
  static Future<List<Recipe?>> suggestMealPlan({
    required String apiKey,
    required List<Recipe> recipes,
    required List<DateTime> slotDates,
    required Map<int, DayConstraint> dailyConstraints,
    required String globalConstraints,
  }) async {
    if (recipes.isEmpty) return List.filled(slotDates.length, null);

    final model = GenerativeModel(model: _modelName, apiKey: apiKey);
    final prompt = _buildPrompt(
      recipes: recipes,
      slotDates: slotDates,
      dailyConstraints: dailyConstraints,
      globalConstraints: globalConstraints,
    );

    final response = await model.generateContent([Content.text(prompt)]);
    final text = response.text ?? '';
    return _parseResponse(text, recipes, slotDates.length);
  }

  static String _buildPrompt({
    required List<Recipe> recipes,
    required List<DateTime> slotDates,
    required Map<int, DayConstraint> dailyConstraints,
    required String globalConstraints,
  }) {
    final buf = StringBuffer();
    final dateFmt = DateFormat('EEEE d MMMM yyyy', 'fr_FR');

    buf.writeln(
      'Tu es un assistant culinaire. Tu dois proposer un planning de repas '
      'pour les jours suivants en choisissant parmi les recettes disponibles.',
    );
    buf.writeln();

    // Recettes disponibles
    buf.writeln('=== RECETTES DISPONIBLES ===');
    for (final r in recipes) {
      final prep = r.tags.prepTime != null ? '${r.tags.prepTime}min prép' : '';
      final cook = r.tags.cookTime != null ? '${r.tags.cookTime}min cuisson' : '';
      final times = [prep, cook].where((s) => s.isNotEmpty).join(', ');
      buf.writeln(
        '- ID: ${r.id} | Titre: ${r.titre}'
        '${times.isNotEmpty ? " | $times" : ""}',
      );
    }
    buf.writeln();

    // Contraintes globales
    if (globalConstraints.trim().isNotEmpty) {
      buf.writeln('=== CONTRAINTES GLOBALES ===');
      buf.writeln(globalConstraints.trim());
      buf.writeln();
    }

    // Slots à remplir
    buf.writeln('=== JOURS À PLANIFIER ===');
    for (int i = 0; i < slotDates.length; i++) {
      final date = slotDates[i];
      final dayConstraint = dailyConstraints[date.weekday];
      final label = dateFmt.format(date);
      buf.write('Slot $i — $label');
      if (dayConstraint != null && !dayConstraint.isEmpty) {
        final parts = <String>[];
        if (dayConstraint.maxPrepMinutes > 0) {
          parts.add('max ${dayConstraint.maxPrepMinutes}min de préparation');
        }
        if (dayConstraint.isBatchCooking) {
          parts.add('batch cooking (plat préparé à l\'avance, réchauffage)');
        }
        if (dayConstraint.notes.trim().isNotEmpty) {
          parts.add(dayConstraint.notes.trim());
        }
        if (parts.isNotEmpty) buf.write(' [${parts.join(" | ")}]');
      }
      buf.writeln();
    }
    buf.writeln();

    // Instructions de réponse
    buf.writeln('=== INSTRUCTIONS ===');
    buf.writeln(
      'Réponds UNIQUEMENT avec un tableau JSON valide, sans texte autour, '
      'sans markdown, sans bloc de code. Format attendu :',
    );
    buf.writeln(
      '[{"slot": 0, "recipe_id": "abc123"}, {"slot": 1, "recipe_id": "def456"}, ...]',
    );
    buf.writeln(
      'Règles : '
      '1) Respecte les contraintes de chaque jour (durée max, batch cooking). '
      '2) Varie les recettes, évite les répétitions. '
      '3) Si aucune recette ne convient pour un slot, omets cet index du tableau. '
      '4) N\'invente pas de recipe_id — utilise uniquement ceux de la liste ci-dessus.',
    );

    return buf.toString();
  }

  static List<Recipe?> _parseResponse(
    String text,
    List<Recipe> recipes,
    int slotCount,
  ) {
    final result = List<Recipe?>.filled(slotCount, null);

    // Extraire le JSON (enlever ```json ... ``` si présent)
    var json = text.trim();
    final jsonMatch = RegExp(r'\[.*\]', dotAll: true).firstMatch(json);
    if (jsonMatch == null) return result;
    json = jsonMatch.group(0)!;

    try {
      final list = jsonDecode(json) as List<dynamic>;
      final recipeById = {for (final r in recipes) r.id: r};
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final slot = item['slot'] as int?;
        final recipeId = item['recipe_id'] as String?;
        if (slot == null || recipeId == null) continue;
        if (slot < 0 || slot >= slotCount) continue;
        result[slot] = recipeById[recipeId];
      }
    } catch (_) {
      // Réponse malformée → retourner les suggestions partielles
    }

    return result;
  }
}
