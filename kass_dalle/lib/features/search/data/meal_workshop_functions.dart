/// Les deux appels de l'atelier repas, par `GeminiService` : un tour de
/// conversation (`mealWorkshopTurnFn`) et la recette d'un plat figé
/// (`mealWorkshopRecipeFn`). Ce fichier construit les payloads, lit les
/// réponses, et traduit un échec en ce que l'écran doit en dire.
library;

import '../../../core/services/gemini_service.dart';
import '../../../core/widgets/error_message.dart';
import '../../planning/domain/meal_kind.dart';
import '../../recipes/domain/recipe.dart';
import '../domain/meal_workshop_menu.dart';
import '../domain/generated_recipe.dart';

/// Ce qu'un échec d'appel signifie pour l'écran.
enum WorkshopFailureKind {
  /// Les 30 tours du jour sont faits : pas de carte, l'aide sous le champ le
  /// dit. Le tour n'a pas eu lieu.
  dailyQuota,

  /// Le budget d'IA du jour du compte : message du serveur, sans
  /// « Réessayer ». Rien n'a eu lieu.
  aiBudget,

  /// Le contrôle serveur a refusé la réponse du modèle : le tour a été
  /// facturé et compté, le menu n'a pas changé. « Réessayer ».
  unreadable,

  /// Le rôle n'est plus éditeur : sans « Réessayer ».
  permissionDenied,

  /// Le serveur a refusé l'entrée (`invalid-argument`) : le même envoi serait
  /// refusé de nouveau, sans « Réessayer ».
  refused,

  /// Réseau, serveur, décodage : « Réessayer » si [WorkshopFailure.retryable].
  other,
}

/// Un échec d'appel, lu pour l'écran : sa nature, la phrase à afficher, et
/// pour une réponse illisible le compteur du jour après le tour facturé.
class WorkshopFailure {
  final WorkshopFailureKind kind;

  /// La seconde phrase de la carte, avec son point final.
  final String message;
  final bool retryable;

  /// Le compteur du jour rendu avec le refus (réponse illisible, plafond).
  final WorkshopQuota? quota;

  /// Le plafond du jour, quand le refus l'a dit.
  final int? limit;

  const WorkshopFailure({
    required this.kind,
    required this.message,
    required this.retryable,
    this.quota,
    this.limit,
  });
}

String _sentence(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '';
  const endings = ['.', '!', '?', '…'];
  return endings.any(trimmed.endsWith) ? trimmed : '$trimmed.';
}

/// Lit un échec d'appel de l'atelier.
///
/// Les refus attendus portent un code et une raison posés par le serveur ;
/// tout le reste passe par [describeError], qui traduit réseau, délai et
/// session expirée.
WorkshopFailure describeWorkshopFailure(Object error) {
  if (error is GeminiCallableException) {
    final code = error.code.toLowerCase().replaceAll('_', '-');
    final details = error.details is Map
        ? Map<String, dynamic>.from(error.details as Map)
        : null;
    final reason = details?['reason'];
    if (code == 'resource-exhausted' && reason == kWorkshopDailyQuotaReason) {
      final limit = details?['limit'];
      return WorkshopFailure(
        kind: WorkshopFailureKind.dailyQuota,
        message: _sentence(error.message),
        retryable: false,
        limit: limit is num ? limit.round() : null,
      );
    }
    final budget = aiBudgetRefusalMessage(error);
    if (budget != null) {
      return WorkshopFailure(
        kind: WorkshopFailureKind.aiBudget,
        message: _sentence(budget),
        retryable: false,
      );
    }
    if (reason == kWorkshopUnreadableReason) {
      return WorkshopFailure(
        kind: WorkshopFailureKind.unreadable,
        message: _sentence(
          error.message.trim().isEmpty
              ? 'L\'IA n\'a pas rendu de réponse lisible.'
              : error.message,
        ),
        retryable: true,
        quota: WorkshopQuota.fromJson(details?['quota']),
      );
    }
    if (code == 'permission-denied') {
      return const WorkshopFailure(
        kind: WorkshopFailureKind.permissionDenied,
        message: 'L\'IA est réservée aux éditeurs.',
        retryable: false,
      );
    }
    if (code == 'invalid-argument') {
      return WorkshopFailure(
        kind: WorkshopFailureKind.refused,
        message: _sentence(
          error.message.trim().isEmpty
              ? describeError(error).title
              : error.message,
        ),
        retryable: false,
      );
    }
  }
  final described = describeError(error);
  return WorkshopFailure(
    kind: WorkshopFailureKind.other,
    message: _sentence(described.title),
    retryable: described.retryable,
  );
}

/// Le serveur a répondu sans recette : « Non rédigée. L'IA n'a pas rendu de
/// recette. »
class WorkshopNoRecipeException implements Exception {
  const WorkshopNoRecipeException();

  @override
  String toString() => 'WorkshopNoRecipeException';
}

class MealWorkshopFunctions {
  final GeminiService _gemini;

  const MealWorkshopFunctions(this._gemini);

  /// Un tour : le texte de la personne et tout ce que le modèle doit savoir.
  /// Le serveur rend le texte, le menu contrôlé et le compteur du jour.
  Future<WorkshopTurnResult> turn({
    required String conversationId,
    required MealKind kind,
    required List<Map<String, String>> history,
    required String message,
    required List<Map<String, String>> recipes,
    required List<Map<String, String>> staples,
    required String globalConstraints,
    required int portions,
    required WorkshopMenu? menu,
  }) async {
    final data = await _gemini.mealWorkshopTurn({
      'conversationId': conversationId,
      'kind': kind.key,
      'history': history,
      'message': message,
      'recipes': recipes,
      'staples': staples,
      'globalConstraints': globalConstraints,
      'portions': portions,
      'menu': menu?.toJson(),
    });
    return WorkshopTurnResult.fromJson(data);
  }

  /// La recette d'un plat figé, rédigée pour [portions] parts. Les
  /// accompagnements sont cités dans la recette, sans recette à part.
  Future<Recipe> writeRecipe({
    required String conversationId,
    required String titre,
    required String? description,
    required List<String> sides,
    required int portions,
    required String globalConstraints,
  }) async {
    final Map<String, dynamic> data;
    try {
      data = await _gemini.mealWorkshopRecipe({
        'conversationId': conversationId,
        'titre': titre,
        'description': description,
        'sides': sides,
        'portions': portions,
        'globalConstraints': globalConstraints,
      });
    } on GeminiCallableException catch (error) {
      // Le serveur a appelé le modèle et n'a pas pu lire de recette : la
      // ligne le dit, et « Réessayer » refait l'appel.
      final details = error.details;
      if (details is Map &&
          details['reason'] == kWorkshopRecipeUnreadableReason) {
        throw const WorkshopNoRecipeException();
      }
      rethrow;
    }
    final recipe = recipeFromGeneratedRaw(data, fallbackTitle: titre);
    if (recipe.rawCooklang.trim().isEmpty) {
      throw const WorkshopNoRecipeException();
    }
    return recipe;
  }
}
