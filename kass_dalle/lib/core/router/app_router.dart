import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/domain/app_user.dart';
import '../../features/auth/presentation/auth_providers.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/pending_approval_screen.dart';
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
import '../../features/admin/presentation/invite_by_email_screen.dart';
import '../../features/admin/presentation/admin_backfills_screen.dart';
import '../../features/admin/presentation/admin_data_quality_screen.dart';
import '../../features/admin/presentation/monthly_costs_screen.dart';
import '../../features/admin/presentation/error_reports_screen.dart';
import '../../features/admin/presentation/dead_letters_screen.dart';
import '../../features/admin/presentation/logs_screen.dart';
import '../../features/admin/presentation/admin_referentials_screen.dart';
import '../../features/admin/presentation/nutrition_ingredients_screen.dart';
import '../../features/admin/presentation/ai_routing_screen.dart';
import '../../features/admin/presentation/ai_pricing_screen.dart';
import '../../features/moderation/presentation/admin_moderation_screen.dart';
import '../../features/admin/presentation/ai_spend_screen.dart';
import '../../features/admin/presentation/app_check_screen.dart';
import '../../features/admin/presentation/nutrition_policy_screen.dart';
import '../../features/admin/presentation/nutrition_units_screen.dart';
import '../../features/admin/presentation/meal_staples_screen.dart';
import '../../features/sandbox/presentation/sandbox_hub_screen.dart';
import '../../features/auth/presentation/preferences_screen.dart';
import '../../features/groups/presentation/groups_screen.dart';
import '../../features/recipes/presentation/edit/recipe_edit_screen.dart';
import '../../features/recipes/presentation/edit/recipe_create_screen.dart';
import '../../features/recipes/presentation/detail/book_page_detail_screen.dart';
import '../../features/recipes/presentation/detail/book_reader_navigation.dart';
import '../../features/search/presentation/search_screen.dart';
import '../../features/auth/presentation/editor_only_gate.dart';
import '../../features/planning/domain/meal_prep_context.dart';
import '../../features/planning/presentation/planning_screen.dart';
import '../../features/planning/presentation/batch_planning_screen.dart';
import '../../features/planning/presentation/planning_config_screen.dart';
import '../../features/planning/presentation/my_staples_screen.dart';
import '../../features/tickets/presentation/admin_tickets_screen.dart';
import '../../features/tickets/presentation/my_tickets_screen.dart';
import '../../features/tickets/presentation/ticket_launcher.dart';
import '../../features/tickets/presentation/ticket_form_screen.dart';
import '../presentation/app_shell.dart';

/// Notifie GoRouter sans exposer notifyListeners() comme protected.
class _RouterNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

// Noms des routes
class AppRoutes {
  static const login = '/login';
  static const pending = '/pending';
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
  static const adminUsersInvite = '/admin/users/invite';
  static const adminCosts = '/admin/costs';
  static const adminBackfills = '/admin/backfills';
  static const adminReferentials = '/admin/referentials';
  static const adminNutritionIngredients = '/admin/nutrition-ingredients';
  static const adminNutritionUnits = '/admin/nutrition-units';
  static const adminNutritionPolicy = '/admin/nutrition-policy';
  static const adminDataQuality = '/admin/data-quality';
  static const adminMealStaples = '/admin/meal-staples';
  static const adminAiRouting = '/admin/ai-routing';
  static const adminAiPricing = '/admin/ai-pricing';
  static const adminAppCheck = '/admin/app-check';
  static const adminModeration = '/admin/moderation';
  static const adminAiSpend = '/admin/ai-spend';
  static const adminSandbox = '/admin/sandbox';
  static const account = '/account';
  static const preferences = '/preferences';
  static const groups = '/groups';
  static const search = '/search';
  static const tokenUsage = '/token-usage';
  static const errorReports = '/error-reports';
  static const deadLetters = '/dead-letters';
  static const logs = '/logs';
  static const planning = '/planning';
  static const batchPlanning = '/planning/batch';
  static const planningConfig = '/planning/config';
  static const myStaples = '/planning/staples';
  static const tickets = '/tickets';
  static const ticketNew = '/tickets/new';
  static const adminTickets = '/admin/tickets';

  /// Suivi d'un ticket du membre.
  static String ticketDetail(String id) => '$tickets/$id';

  /// Un ticket dans Admin › Tickets des membres.
  static String adminTicketDetail(String id) => '$adminTickets/$id';

  /// Une expérience du bac à sable, désignée par son identifiant.
  static String sandboxExperiment(String id) => '$adminSandbox/$id';
}

/// Les écrans du planning réservés aux éditeurs : créer un planning, en
/// régler les préférences, tenir ses garnitures.
const kPlanningEditorRoutes = {
  AppRoutes.batchPlanning,
  AppRoutes.planningConfig,
  AppRoutes.myStaples,
};

/// Paramètre de `/planning` posé par la redirection d'un lecteur : l'écran
/// affiche alors « Planification réservée aux éditeurs ».
const kPlanningReservedParam = 'reserve';

/// Paramètre de `/login` qui porte l'adresse demandée avant la connexion.
const kNextQueryParam = 'next';

/// Adresse de la page de connexion pour une adresse demandée sans session.
///
/// L'accueil n'est pas retenu : c'est déjà la destination par défaut, et
/// `/login` nu reste l'adresse que les tests et les captures connaissent.
String loginLocationFor(Uri requested) {
  if (requested.path == AppRoutes.home && !requested.hasQuery) {
    return AppRoutes.login;
  }
  return Uri(
    path: AppRoutes.login,
    queryParameters: {kNextQueryParam: requested.toString()},
  ).toString();
}

/// Adresse à ouvrir une fois connecté, lue dans `?next=`, ou null.
///
/// Seule une route interne est acceptée. Un `next` qui commence par `//` ou
/// par un schéma ferait de la page de connexion un renvoi vers un autre site ;
/// `/login` et `/pending` y feraient tourner en rond.
String? nextLocationAfterLogin(Uri loginUri) {
  final next = loginUri.queryParameters[kNextQueryParam];
  if (next == null || !next.startsWith('/') || next.startsWith('//')) {
    return null;
  }
  final path = Uri.parse(next).path;
  if (path == AppRoutes.login || path == AppRoutes.pending) return null;
  return next;
}

/// Où doit aller un compte, selon ce qu'il est et où il tente d'aller.
///
/// Extrait de la fermeture `redirect` pour être testable : c'est le seul
/// endroit du client qui décide qui voit quoi, et il doit rester le miroir du
/// sas d'entrée de `firestore.rules`. Retourne `null` quand la destination
/// demandée convient.
String? resolveRedirect({
  required AppUser? user,
  required bool isLoading,
  required String location,
  Uri? uri,
}) {
  final isLoginRoute = location == AppRoutes.login;
  final isPendingRoute = location == AppRoutes.pending;
  final requested = uri ?? Uri(path: location);

  // Pendant le chargement, ne pas rediriger
  if (isLoading) return null;

  // Non authentifié → login, en gardant l'adresse demandée : un lien reçu
  // hors de l'application — l'événement Google Calendar d'un repas — doit
  // rouvrir la recette une fois la session ouverte, pas l'accueil.
  if (user == null) {
    return isLoginRoute ? null : loginLocationFor(requested);
  }

  // Compte révoqué → login avec paramètre
  if (user.isRevoked) {
    return '${AppRoutes.login}?revoked=true';
  }

  // Compte pas encore nommé → salle d'attente. Il est authentifié : le
  // renvoyer vers /login le ferait rebondir aussitôt vers l'accueil, où les
  // règles lui refuseraient tout sans jamais lui dire pourquoi.
  if (user.isPending) {
    return isPendingRoute ? null : AppRoutes.pending;
  }

  // Nommé entre-temps : la salle d'attente n'a plus lieu d'être.
  if (isPendingRoute) return AppRoutes.home;

  // Connecté et sur /login → l'adresse demandée avant la connexion, sinon home
  if (isLoginRoute) return nextLocationAfterLogin(requested) ?? AppRoutes.home;

  // Admin requis pour /admin
  if (location.startsWith('/admin') && !user.isAdmin) {
    return AppRoutes.home;
  }

  // Planifier est réservé aux éditeurs (v0.23.47) : le lecteur lit les
  // plannings partagés avec lui, il n'en crée pas. Les écrans de création,
  // de préférences et de garnitures le renvoient au planning, qui dit
  // pourquoi (voir [kPlanningReservedParam]).
  if (!user.canEdit && kPlanningEditorRoutes.contains(location)) {
    return '${AppRoutes.planning}?$kPlanningReservedParam=1';
  }

  // /processing est fusionné dans /drafts
  if (location == AppRoutes.processing) {
    return AppRoutes.drafts;
  }

  return null;
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
      return resolveRedirect(
        user: appUserAsync.value,
        isLoading: appUserAsync.isLoading,
        location: state.matchedLocation,
        uri: state.uri,
      );
    },
    routes: [
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      // Hors de l'AppShell : la barre de navigation ne mène qu'à des écrans
      // qu'un compte en attente n'a pas le droit de lire.
      GoRoute(
        path: AppRoutes.pending,
        builder: (context, state) => const PendingApprovalScreen(),
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
                // Le lecteur ne crée pas de recette : arrivé par un lien, il
                // voit un état qui le lui dit (même garde que `/scan`).
                builder: (context, state) => EditorOnlyGate(
                  appBarTitle: 'Nouvelle recette',
                  lockedTitle: 'Création réservée aux éditeurs',
                  lockedMessage:
                      'Créer une recette est réservé aux éditeurs et aux '
                      'administrateurs. Demandez à un administrateur de vous '
                      'nommer éditeur.',
                  builder: (_) => RecipeCreateScreen(
                    initialBookId: state.uri.queryParameters['bookId'],
                    initialBookTitre: state.uri.queryParameters['bookTitre'],
                    // Rappel de la page d'un import par lien qui a échoué :
                    // affichée, jamais enregistrée sur la recette.
                    sourceUrl: state.uri.queryParameters['sourceUrl'],
                  ),
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

                  // Portions imposées par le contexte d'ouverture — un repas
                  // planifié pour 8 doit s'afficher pour 8, sans écrire quoi
                  // que ce soit sur la recette ni sur les préférences.
                  final portions = int.tryParse(
                    state.uri.queryParameters['portions'] ?? '',
                  );

                  // Préparation à l'avance — même nature que les portions : le
                  // couple (jour de préparation, jour du repas) vient du repas
                  // planifié et n'est écrit nulle part.
                  final prepContext = MealPrepContext.fromQueryParameters(
                    state.uri.queryParameters,
                  );

                  return NoTransitionPage(
                    child: RecipeDetailScreen(
                      recipeId: recipeId,
                      scrollToAnnotations: scrollToAnnotations,
                      readingContext: readingContext,
                      initialPortions: (portions ?? 0) > 0 ? portions : null,
                      prepContext: prepContext,
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
                routes: [
                  GoRoute(
                    path: 'invite',
                    builder: (context, state) => const InviteByEmailScreen(),
                  ),
                ],
              ),
              GoRoute(
                path: 'costs',
                builder: (context, state) => const MonthlyCostsScreen(),
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
                builder: (context, state) => NutritionIngredientsScreen(
                  initialSearch: state.extra as String?,
                ),
              ),
              GoRoute(
                path: 'nutrition-units',
                builder: (context, state) =>
                    NutritionUnitsScreen(initialSearch: state.extra as String?),
              ),
              GoRoute(
                path: 'nutrition-policy',
                builder: (context, state) => const NutritionPolicyScreen(),
              ),
              GoRoute(
                path: 'data-quality',
                builder: (context, state) => const AdminDataQualityScreen(),
              ),
              GoRoute(
                path: 'meal-staples',
                builder: (context, state) => const MealStaplesScreen(),
              ),
              GoRoute(
                path: 'ai-spend',
                builder: (context, state) => const AiSpendScreen(),
              ),
              GoRoute(
                path: 'app-check',
                builder: (context, state) => const AppCheckScreen(),
              ),
              GoRoute(
                path: 'ai-routing',
                builder: (context, state) => const AiRoutingScreen(),
              ),
              GoRoute(
                path: 'ai-pricing',
                builder: (context, state) => const AiPricingScreen(),
              ),
              GoRoute(
                path: 'moderation',
                builder: (context, state) => const AdminModerationScreen(),
              ),
              GoRoute(
                path: 'tickets',
                builder: (context, state) => const AdminTicketsScreen(),
                routes: [
                  GoRoute(
                    path: ':ticketId',
                    builder: (context, state) => AdminTicketsScreen(
                      selectedTicketId: state.pathParameters['ticketId'],
                    ),
                  ),
                ],
              ),
              GoRoute(
                path: 'sandbox',
                builder: (context, state) => const SandboxHubScreen(),
                routes: [
                  GoRoute(
                    path: ':experimentId',
                    builder: (context, state) => SandboxExperimentScreen(
                      experimentId: state.pathParameters['experimentId']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            path: AppRoutes.account,
            builder: (context, state) => const AccountScreen(),
          ),
          GoRoute(
            path: AppRoutes.preferences,
            builder: (context, state) => const PreferencesScreen(),
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
            path: AppRoutes.tickets,
            builder: (context, state) => const MyTicketsScreen(),
            routes: [
              // Avant `:ticketId`, qui prendrait « new » pour un identifiant.
              GoRoute(
                path: 'new',
                builder: (context, state) => TicketFormScreen(
                  initialScreen:
                      state.uri.queryParameters[kTicketScreenQueryParam],
                ),
              ),
              GoRoute(
                path: ':ticketId',
                builder: (context, state) => MyTicketsScreen(
                  selectedTicketId: state.pathParameters['ticketId'],
                ),
              ),
            ],
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
            builder: (context, state) => PlanningScreen(
              showReservedNotice:
                  state.uri.queryParameters[kPlanningReservedParam] == '1',
            ),
            routes: [
              GoRoute(
                path: 'batch',
                builder: (context, state) => const BatchPlanningScreen(),
              ),
              GoRoute(
                path: 'config',
                builder: (context, state) => const PlanningConfigScreen(),
              ),
              GoRoute(
                path: 'staples',
                builder: (context, state) => const MyStaplesScreen(),
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
