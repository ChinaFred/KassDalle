import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/presentation/auth_providers.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/account_screen.dart';
import '../../features/books/presentation/book_list_screen.dart';
import '../../features/books/presentation/book_form_screen.dart';
import '../../features/books/presentation/book_validation_screen.dart';
import '../../features/recipes/presentation/list/recipe_list_screen.dart';
import '../../features/recipes/presentation/detail/recipe_detail_screen.dart';
import '../../features/recipes/presentation/scan/scan_screen.dart';
import '../../features/recipes/presentation/drafts/draft_review_screen.dart';
import '../../features/recipes/presentation/drafts/work_queue_screen.dart';
import '../../features/admin/presentation/admin_hub_screen.dart';
import '../../features/admin/presentation/admin_screen.dart';
import '../../features/admin/presentation/admin_backfills_screen.dart';
import '../../features/admin/presentation/billing_screen.dart';
import '../../features/admin/presentation/token_usage_screen.dart';
import '../../features/admin/presentation/error_reports_screen.dart';
import '../../features/admin/presentation/dead_letters_screen.dart';
import '../../features/admin/presentation/logs_screen.dart';
import '../../features/admin/presentation/admin_referentials_screen.dart';
import '../../features/admin/presentation/nutrition_ingredients_screen.dart';
import '../../features/admin/presentation/ai_routing_screen.dart';
import '../../features/admin/presentation/nutrition_policy_screen.dart';
import '../../features/admin/presentation/nutrition_units_screen.dart';
import '../../features/groups/presentation/groups_screen.dart';
import '../../features/recipes/presentation/edit/recipe_edit_screen.dart';
import '../../features/recipes/presentation/edit/recipe_create_screen.dart';
import '../../features/recipes/presentation/detail/book_page_detail_screen.dart';
import '../../features/recipes/presentation/detail/book_reader_navigation.dart';
import '../../features/search/presentation/search_screen.dart';
import '../../features/planning/presentation/planning_screen.dart';
import '../../features/planning/presentation/batch_planning_screen.dart';
import '../../features/planning/presentation/planning_config_screen.dart';
import '../presentation/app_shell.dart';

/// Notifie GoRouter sans exposer notifyListeners() comme protected.
class _RouterNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

// Noms des routes
class AppRoutes {
  static const login = '/login';
  static const home = '/';
  static const books = '/books';
  static const bookNew = '/books/new';
  static const bookEdit = '/books/:bookId/edit';
  static const bookValidation = '/books/validation';
  static const recipes = '/recipes';
  static const recipeCreate = '/recipes/new';
  static const recipeDetail = '/recipes/:recipeId';
  static const recipeEdit = '/recipes/:recipeId/edit';
  static const bookPageDetail = '/book-pages/:pageId';
  static const scan = '/scan';
  static const drafts = '/drafts';
  static const draftReview = '/drafts/:recipeId';
  static const processing = '/processing';
  static const admin = '/admin';
  static const adminUsers = '/admin/users';
  static const adminBilling = '/admin/billing';
  static const adminBackfills = '/admin/backfills';
  static const adminReferentials = '/admin/referentials';
  static const adminNutritionIngredients = '/admin/nutrition-ingredients';
  static const adminNutritionUnits = '/admin/nutrition-units';
  static const adminNutritionPolicy = '/admin/nutrition-policy';
  static const adminAiRouting = '/admin/ai-routing';
  static const account = '/account';
  static const groups = '/groups';
  static const search = '/search';
  static const tokenUsage = '/token-usage';
  static const errorReports = '/error-reports';
  static const deadLetters = '/dead-letters';
  static const logs = '/logs';
  static const planning = '/planning';
  static const batchPlanning = '/planning/batch';
  static const planningConfig = '/planning/config';
}

final routerProvider = Provider<GoRouter>((ref) {
  // _RouterNotifier est notifié à chaque changement de appUserProvider
  // (auth Firebase + chargement doc Firestore) sans que le Provider se reconstuise.
  // ref.listen n'ajoute PAS de dépendance reactive → le routeur n'est jamais recréé.
  final notifier = _RouterNotifier();
  ref.listen(appUserProvider, (_, _) => notifier.notify());
  ref.onDispose(notifier.dispose);

  return GoRouter(
    initialLocation: AppRoutes.home,
    refreshListenable: notifier,
    redirect: (context, state) {
      final appUserAsync = ref.read(appUserProvider);
      final user = appUserAsync.value;
      final isLoading = appUserAsync.isLoading;
      final isLoginRoute = state.matchedLocation == AppRoutes.login;

      // Pendant le chargement, ne pas rediriger
      if (isLoading) return null;

      // Non authentifié → login
      if (user == null) {
        return isLoginRoute ? null : AppRoutes.login;
      }

      // Compte révoqué → login avec paramètre
      if (user.isRevoked) {
        return '${AppRoutes.login}?revoked=true';
      }

      // Connecté et sur /login → home
      if (isLoginRoute) return AppRoutes.home;

      // Admin requis pour /admin
      if (state.matchedLocation.startsWith('/admin') && !user.isAdmin) {
        return AppRoutes.home;
      }

      // /processing est fusionné dans /drafts
      if (state.matchedLocation == AppRoutes.processing) {
        return AppRoutes.drafts;
      }

      return null;
    },
    routes: [
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: AppRoutes.home,
            builder: (context, state) => const BookListScreen(),
          ),
          GoRoute(
            path: AppRoutes.books,
            builder: (context, state) => const BookListScreen(),
            routes: [
              GoRoute(
                path: 'validation',
                builder: (context, state) => const BookValidationScreen(),
              ),
              GoRoute(
                path: 'new',
                builder: (context, state) => const BookFormScreen(),
              ),
              GoRoute(
                path: ':bookId/edit',
                builder: (context, state) =>
                    BookFormScreen(bookId: state.pathParameters['bookId']),
              ),
            ],
          ),
          GoRoute(
            path: AppRoutes.recipes,
            builder: (context, state) => RecipeListScreen(
              bookId: state.uri.queryParameters['bookId'],
              bookTitre: state.uri.queryParameters['bookTitre'],
              bookCoverUrl: state.uri.queryParameters['bookCoverUrl'],
              showUnattached:
                  state.uri.queryParameters['showUnattached'] == 'true',
            ),
            routes: [
              GoRoute(
                path: 'new',
                builder: (context, state) => RecipeCreateScreen(
                  initialBookId: state.uri.queryParameters['bookId'],
                  initialBookTitre: state.uri.queryParameters['bookTitre'],
                ),
              ),
              GoRoute(
                path: ':recipeId',
                pageBuilder: (context, state) {
                  final recipeId = state.pathParameters['recipeId']!;
                  final scrollToAnnotations =
                      state.uri.queryParameters['anchor'] == 'annotations';
                  final readingContext = BookReadingContext(
                    bookId: state.uri.queryParameters['bookId'],
                    bookTitre: state.uri.queryParameters['bookTitre'],
                    bookCoverUrl: state.uri.queryParameters['bookCoverUrl'],
                    showUnattached:
                        state.uri.queryParameters['showUnattached'] == 'true',
                  );

                  return NoTransitionPage(
                    child: RecipeDetailScreen(
                      recipeId: recipeId,
                      scrollToAnnotations: scrollToAnnotations,
                      readingContext: readingContext,
                    ),
                  );
                },
                routes: [
                  GoRoute(
                    path: 'edit',
                    builder: (context, state) => RecipeEditScreen(
                      recipeId: state.pathParameters['recipeId']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            path: AppRoutes.scan,
            builder: (context, state) => const ScanScreen(),
          ),
          GoRoute(
            path: AppRoutes.drafts,
            builder: (context, state) => const WorkQueueScreen(),
            routes: [
              GoRoute(
                path: ':recipeId',
                builder: (context, state) => DraftReviewScreen(
                  recipeId: state.pathParameters['recipeId']!,
                  autoOpenAiRefine: state.uri.queryParameters['ai'] == 'true',
                ),
              ),
            ],
          ),
          GoRoute(
            path: AppRoutes.processing,
            redirect: (_, _) => AppRoutes.drafts,
          ),
          GoRoute(
            path: AppRoutes.admin,
            builder: (context, state) => const AdminHubScreen(),
            routes: [
              GoRoute(
                path: 'users',
                builder: (context, state) => const AdminScreen(),
              ),
              GoRoute(
                path: 'billing',
                builder: (context, state) => const BillingScreen(),
              ),
              GoRoute(
                path: 'backfills',
                builder: (context, state) => const AdminBackfillsScreen(),
              ),
              GoRoute(
                path: 'referentials',
                builder: (context, state) => const AdminReferentialsScreen(),
              ),
              GoRoute(
                path: 'nutrition-ingredients',
                builder: (context, state) => const NutritionIngredientsScreen(),
              ),
              GoRoute(
                path: 'nutrition-units',
                builder: (context, state) => const NutritionUnitsScreen(),
              ),
              GoRoute(
                path: 'nutrition-policy',
                builder: (context, state) => const NutritionPolicyScreen(),
              ),
              GoRoute(
                path: 'ai-routing',
                builder: (context, state) => const AiRoutingScreen(),
              ),
            ],
          ),
          GoRoute(
            path: AppRoutes.account,
            builder: (context, state) => const AccountScreen(),
          ),
          GoRoute(
            path: AppRoutes.groups,
            builder: (context, state) => const GroupsScreen(),
          ),
          GoRoute(
            path: AppRoutes.search,
            builder: (context, state) => const SearchScreen(),
          ),
          GoRoute(
            path: AppRoutes.tokenUsage,
            builder: (context, state) => const TokenUsageScreen(),
          ),
          GoRoute(
            path: AppRoutes.errorReports,
            builder: (context, state) => const ErrorReportsScreen(),
          ),
          GoRoute(
            path: AppRoutes.deadLetters,
            builder: (context, state) => const DeadLettersScreen(),
          ),
          GoRoute(
            path: AppRoutes.logs,
            builder: (context, state) => const LogsScreen(),
          ),
          GoRoute(
            path: AppRoutes.planning,
            builder: (context, state) => const PlanningScreen(),
            routes: [
              GoRoute(
                path: 'batch',
                builder: (context, state) => const BatchPlanningScreen(),
              ),
              GoRoute(
                path: 'config',
                builder: (context, state) => const PlanningConfigScreen(),
              ),
            ],
          ),
          GoRoute(
            path: AppRoutes.bookPageDetail,
            pageBuilder: (context, state) => NoTransitionPage(
              child: BookPageDetailScreen(
                pageId: state.pathParameters['pageId']!,
                readingContext: BookReadingContext(
                  bookId: state.uri.queryParameters['bookId'],
                  bookTitre: state.uri.queryParameters['bookTitre'],
                  bookCoverUrl: state.uri.queryParameters['bookCoverUrl'],
                  showUnattached:
                      state.uri.queryParameters['showUnattached'] == 'true',
                ),
              ),
            ),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(child: Text('Page introuvable : ${state.error}')),
    ),
  );
});
