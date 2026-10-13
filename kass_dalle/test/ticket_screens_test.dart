import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kass_dalle/core/router/app_router.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/tickets/domain/ticket_screens.dart';
import 'package:kass_dalle/features/tickets/presentation/ticket_launcher.dart';

/// L'écran d'un ticket part sur un dépôt GitHub public : seule une valeur de
/// l'ensemble fermé de `ticket_screens.dart` peut sortir, jamais une adresse
/// réelle avec un identifiant ou une requête.
void main() {
  final allowed = {
    ...kTicketScreenNames.keys,
    kTicketScreenOther,
    kTicketScreenUnknown,
  };

  group('ticketScreenValue', () {
    test('un modèle de route connu passe tel quel', () {
      expect(ticketScreenValue('/recipes/:recipeId'), '/recipes/:recipeId');
      expect(ticketScreenValue('/'), '/');
      expect(ticketScreenValue('/admin/tickets'), '/admin/tickets');
    });

    test('/books se range sous la Bibliothèque', () {
      expect(ticketScreenValue('/books'), '/');
    });

    test('« autre » reste « autre »', () {
      expect(ticketScreenValue(kTicketScreenOther), kTicketScreenOther);
    });

    test('aucune adresse réelle ne sort', () {
      const real = [
        '/recipes/Xy7AbC12',
        '/recipes/Xy7AbC12/edit',
        '/recipes/:recipeId?bookId=abc',
        '/recipes?bookId=abc&bookTitre=Mamie',
        '/tickets/aBcD',
        '/admin/sandbox/image-import',
        '/drafts/42',
        'https://kassdale-6d948.web.app/recipes/Xy7',
        '/recipes/:recipeId#annotations',
        '',
      ];
      for (final value in real) {
        expect(
          ticketScreenValue(value),
          kTicketScreenUnknown,
          reason: '« $value » ne doit pas sortir',
        );
      }
    });

    test('sans modèle de route : « Je ne sais pas »', () {
      expect(ticketScreenValue(null), kTicketScreenUnknown);
    });

    test('toute sortie appartient à l\'ensemble fermé', () {
      const inputs = [
        null,
        '/',
        '/books',
        '/x',
        '/recipes/abc',
        'autre',
        'inconnu',
        '/planning/staples',
      ];
      for (final input in inputs) {
        expect(allowed, contains(ticketScreenValue(input)));
      }
    });
  });

  test('aucune clé de la table ne porte d\'identifiant ni de requête', () {
    final segment = RegExp(r'^(?:[a-z][a-z-]*|:[A-Za-z][A-Za-z0-9]*)$');
    for (final key in kTicketScreenNames.keys) {
      if (key == '/') continue;
      expect(key.startsWith('/'), isTrue, reason: key);
      expect(key.contains('?'), isFalse, reason: key);
      for (final s in key.substring(1).split('/')) {
        expect(segment.hasMatch(s), isTrue, reason: '$key : « $s »');
      }
    }
  });

  test('la liste finit par « Autre écran » puis « Je ne sais pas »', () {
    final options = ticketScreenOptions();
    expect(options[options.length - 2].label, 'Autre écran');
    expect(options.last.label, 'Je ne sais pas');
    expect(options.map((o) => o.value).toSet().length, options.length);
  });

  test('libellés des valeurs stockées', () {
    expect(ticketScreenLabel('/planning/staples'), 'Mes garnitures');
    expect(
      ticketScreenLabel('/admin/costs'),
      'Administration — Coûts de l\'application',
    );
    expect(ticketScreenLabel(kTicketScreenOther), 'Autre écran');
    expect(ticketScreenLabel(kTicketScreenUnknown), 'Je ne sais pas');
    expect(ticketScreenLabel('/route/ancienne'), '/route/ancienne');
  });

  test('chaque route du routeur a son nom d\'écran', () {
    final container = ProviderContainer(
      overrides: [appUserProvider.overrideWith((ref) => Stream.value(null))],
    );
    addTearDown(container.dispose);
    final router = container.read(routerProvider);

    final patterns = <String>[];
    void walk(List<RouteBase> routes, String parent) {
      for (final route in routes) {
        if (route is GoRoute) {
          final full = route.path.startsWith('/')
              ? route.path
              : parent == '/'
              ? '/${route.path}'
              : '$parent/${route.path}';
          patterns.add(full);
          walk(route.routes, full);
        } else if (route is ShellRouteBase) {
          walk(route.routes, parent);
        }
      }
    }

    walk(router.configuration.routes, '/');
    // Hors du shell : on n'y ouvre pas le menu du compte.
    patterns.removeWhere((p) => p == AppRoutes.login || p == AppRoutes.pending);
    expect(patterns, isNotEmpty);
    for (final p in patterns) {
      expect(
        ticketScreenValue(p),
        isNot(kTicketScreenUnknown),
        reason: 'la route $p n\'a pas de nom dans kTicketScreenNames',
      );
    }
  });

  group('ticketFormLocation', () {
    test('porte le modèle dans « ecran »', () {
      final uri = Uri.parse(ticketFormLocation('/recipes/:recipeId'));
      expect(uri.path, AppRoutes.ticketNew);
      expect(
        uri.queryParameters[kTicketScreenQueryParam],
        '/recipes/:recipeId',
      );
    });

    test('sans modèle : le formulaire nu', () {
      expect(ticketFormLocation(null), AppRoutes.ticketNew);
      expect(ticketFormLocation(''), AppRoutes.ticketNew);
    });
  });
}
