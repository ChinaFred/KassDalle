import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_report_service.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/widgets/app_states.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../recipes/domain/recipe.dart';
import '../domain/meal_staple.dart';
import 'meal_staples_providers.dart';

/// Le contenu d'une feuille de choix, une fois recettes et garnitures lues.
typedef PickerSheetBuilder =
    Widget Function(
      BuildContext context,
      List<Recipe> recipes,
      List<UserStaple> staples,
    );

/// Hauteur de la feuille tant que son contenu n'est pas lu.
const double kPickerLoadingSheetHeight = 240;

/// Feuille de choix du planning (« Compléter », « Choisir ») qui s'ouvre dès
/// l'appui, avant la fin de la lecture des recettes et des garnitures.
///
/// Tant que l'une des deux manque, elle affiche « Lecture des recettes et des
/// garnitures… » ; un échec de lecture s'affiche avec « Réessayer », qui
/// relance la lecture dans la feuille. Données lues, [builder] rend la feuille
/// de choix, qui ferme la feuille avec son résultat.
///
/// Les garnitures ne sont jamais lues comme une liste vide tant qu'elles sont
/// en cours de lecture : la feuille dirait à tort qu'aucune n'existe.
class PickerLoadingSheet extends ConsumerStatefulWidget {
  const PickerLoadingSheet({
    super.key,
    required this.loadRecipes,
    required this.builder,
    this.initialRecipes,
    this.needsStaples = true,
    this.errorReporter,
  });

  /// Lit les recettes proposées ; lève si elles ne peuvent pas être lues.
  final Future<List<Recipe>> Function() loadRecipes;

  /// Recettes déjà lues : la feuille de choix s'affiche sans attente.
  final List<Recipe>? initialRecipes;

  /// Faux pour le choix d'un plat, qui ne propose que des recettes.
  final bool needsStaples;

  final PickerSheetBuilder builder;

  /// Remontée des erreurs ; `ErrorReportService()` par défaut.
  final ErrorReportService? errorReporter;

  @override
  ConsumerState<PickerLoadingSheet> createState() => _PickerLoadingSheetState();
}

class _PickerLoadingSheetState extends ConsumerState<PickerLoadingSheet> {
  late Future<List<Recipe>> _recipes;
  bool _staplesErrorReported = false;

  /// « Réessayer » sur les garnitures relance leur lecture. Riverpod garde
  /// l'erreur précédente pendant la relecture : sans ce drapeau, l'écran
  /// resterait sur l'erreur sans montrer qu'il relit.
  bool _staplesReloading = false;

  /// La valeur affichée au moment de « Réessayer » ; toute autre valeur ou
  /// erreur qui arrive ensuite met fin à la relecture.
  AsyncValue<List<UserStaple>>? _staplesAtRetry;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialRecipes;
    _recipes = initial != null ? Future.value(initial) : widget.loadRecipes();
    if (widget.needsStaples) {
      ref.listenManual(myStaplesProvider, (_, next) {
        if (!_staplesReloading || next == _staplesAtRetry) return;
        if (!next.hasValue && !next.hasError) return;
        setState(() {
          _staplesReloading = false;
          _staplesAtRetry = null;
          // Une nouvelle erreur après « Réessayer » se signale à son tour.
          _staplesErrorReported = false;
        });
      });
    }
  }

  void _retryRecipes() {
    setState(() {
      _recipes = widget.loadRecipes();
    });
  }

  void _retryStaples() {
    setState(() {
      _staplesReloading = true;
      _staplesAtRetry = ref.read(myStaplesProvider);
    });
    ref.invalidate(baseMealStaplesProvider);
    ref.invalidate(myStapleOverridesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final staplesAsync = widget.needsStaples
        ? ref.watch(myStaplesProvider)
        : const AsyncValue<List<UserStaple>>.data([]);
    // Le passage du chargement (240 px) à la feuille de choix (jusqu'à 80 %
    // de l'écran) s'anime au lieu de sauter.
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.bottomCenter,
      child: FutureBuilder<List<Recipe>>(
        future: _recipes,
        initialData: widget.initialRecipes,
        builder: (context, snap) {
          // L'erreur est déjà signalée par la fonction de lecture.
          if (snap.hasError) {
            return _frame(
              AppErrorState(
                error: snap.error,
                title: 'Les recettes n\'ont pas pu être lues.',
                onRetry: _retryRecipes,
                compact: true,
              ),
            );
          }
          if (_staplesReloading) return _loading;
          if (staplesAsync.hasError) {
            if (!_staplesErrorReported) {
              _staplesErrorReported = true;
              reportUnexpectedError(
                feature: 'planningScreen.pickerSheet.loadStaples',
                userId: ref.read(appUserProvider).value?.uid,
                error: staplesAsync.error!,
                stackTrace: staplesAsync.stackTrace,
                service: widget.errorReporter,
              );
            }
            return _frame(
              AppErrorState(
                error: staplesAsync.error,
                title: 'Vos garnitures n\'ont pas pu être lues.',
                onRetry: _retryStaples,
                compact: true,
              ),
            );
          }
          final recipes = snap.data;
          final staples = staplesAsync.value;
          if (recipes == null || staples == null) return _loading;
          return widget.builder(context, recipes, staples);
        },
      ),
    );
  }

  static const Widget _loading = SizedBox(
    height: kPickerLoadingSheetHeight,
    child: AppLoadingState(label: 'Lecture des recettes et des garnitures…'),
  );

  /// Au moins la hauteur du chargement, défilable : le détail d'une erreur
  /// peut dépasser l'écran.
  Widget _frame(Widget child) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: kPickerLoadingSheetHeight),
    child: SingleChildScrollView(child: child),
  );
}
