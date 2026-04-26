import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/presentation/auth_providers.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/books/presentation/book_list_screen.dart';
import '../../features/books/presentation/book_form_screen.dart';
import '../../features/recipes/presentation/list/recipe_list_screen.dart';
import '../../features/recipes/presentation/detail/recipe_detail_screen.dart';
import '../../features/recipes/presentation/scan/scan_screen.dart';
import '../../features/recipes/presentation/drafts/draft_list_screen.dart';
import '../../features/recipes/presentation/drafts/draft_review_screen.dart';
import '../../features/admin/presentation/admin_screen.dart';
import '../../features/recipes/presentation/edit/recipe_edit_screen.dart';
import '../presentation/app_shell.dart';

// Noms des routes
class AppRoutes {
  static const login = '/login';
  static const home = '/';
  static const books = '/books';
  static const bookNew = '/books/new';
  static const bookEdit = '/books/:bookId/edit';
  static const recipes = '/recipes';
  static const recipeDetail = '/recipes/:recipeId';
  static const recipeEdit = '/recipes/:recipeId/edit';
  static const scan = '/scan';
  static const drafts = '/drafts';
  static const draftReview = '/drafts/:recipeId';
  static const admin = '/admin';
}

final routerProvider = Provider<GoRouter>((ref) {
  final appUserAsync = ref.watch(appUserProvider);

  return GoRouter(
    initialLocation: AppRoutes.home,
    redirect: (context, state) {
      final user = appUserAsync.valueOrNull;
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
            builder: (context, state) =>
                RecipeListScreen(bookId: state.uri.queryParameters['bookId']),
            routes: [
              GoRoute(
                path: ':recipeId',
                builder: (context, state) => RecipeDetailScreen(
                  recipeId: state.pathParameters['recipeId']!,
                ),
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
            builder: (context, state) => const DraftListScreen(),
            routes: [
              GoRoute(
                path: ':recipeId',
                builder: (context, state) => DraftReviewScreen(
                  recipeId: state.pathParameters['recipeId']!,
                ),
              ),
            ],
          ),
          GoRoute(
            path: AppRoutes.admin,
            builder: (context, state) => const AdminScreen(),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(child: Text('Page introuvable : ${state.error}')),
    ),
  );
});
