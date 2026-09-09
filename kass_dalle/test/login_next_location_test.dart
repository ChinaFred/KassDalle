import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/router/app_router.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';

/// Un lien reçu hors de l'application — l'événement Google Calendar d'un
/// repas — ouvre le client web sur `/recipes/{id}`. Sans session, le routeur
/// mène à la connexion ; il rendait ensuite l'accueil, et le lecteur retapait
/// le titre. L'adresse demandée voyage maintenant dans `?next=`.
void main() {
  AppUser user({required UserRole role}) {
    return AppUser(
      uid: 'uid-1',
      email: 'invite@example.test',
      displayName: 'Invité',
      role: role,
      createdAt: DateTime.utc(2026, 8, 1),
      lastSeenAt: DateTime.utc(2026, 8, 1),
    );
  }

  String? redirect(AppUser? appUser, String requested) {
    final uri = Uri.parse(requested);
    return resolveRedirect(
      user: appUser,
      isLoading: false,
      location: uri.path,
      uri: uri,
    );
  }

  group('sans session', () {
    test(
      'la page de connexion garde l\'adresse demandée, paramètres compris',
      () {
        expect(
          redirect(null, '/recipes/abc?portions=8'),
          '/login?next=%2Frecipes%2Fabc%3Fportions%3D8',
        );
      },
    );

    test(
      'l\'accueil ne se garde pas : c\'est déjà la destination par défaut',
      () {
        expect(redirect(null, '/'), AppRoutes.login);
      },
    );

    test('déjà sur la page de connexion, rien ne bouge', () {
      expect(redirect(null, '/login?next=%2Frecipes%2Fabc'), isNull);
    });

    test('sans adresse complète, la route seule est gardée', () {
      expect(
        resolveRedirect(user: null, isLoading: false, location: '/recipes/abc'),
        '/login?next=%2Frecipes%2Fabc',
      );
    });
  });

  group('une fois connecté', () {
    final reader = user(role: UserRole.reader);

    test('la page de connexion renvoie à l\'adresse gardée', () {
      expect(
        redirect(reader, '/login?next=%2Frecipes%2Fabc%3Fportions%3D8'),
        '/recipes/abc?portions=8',
      );
    });

    test('sans adresse gardée, l\'accueil', () {
      expect(redirect(reader, '/login'), AppRoutes.home);
    });

    test('une adresse hors de l\'application est ignorée', () {
      for (final next in [
        'https://evil.example/',
        '//evil.example/',
        'recipes/abc',
      ]) {
        expect(
          nextLocationAfterLogin(
            Uri(path: AppRoutes.login, queryParameters: {'next': next}),
          ),
          isNull,
          reason: next,
        );
      }
    });

    test('la connexion et la salle d\'attente ne se gardent pas', () {
      expect(nextLocationAfterLogin(Uri.parse('/login?next=%2Flogin')), isNull);
      expect(
        nextLocationAfterLogin(Uri.parse('/login?next=%2Fpending')),
        isNull,
      );
    });

    test(
      'un compte en attente passe par la salle d\'attente ; l\'adresse est perdue',
      () {
        expect(
          redirect(
            user(role: UserRole.pending),
            '/login?next=%2Frecipes%2Fabc',
          ),
          AppRoutes.pending,
        );
      },
    );
  });

  test(
    'l\'aller-retour par l\'adresse conserve la route et ses paramètres',
    () {
      const requested = '/recipes/abc?prep=2026-09-10&meal=2026-09-12';
      final login = loginLocationFor(Uri.parse(requested));
      expect(nextLocationAfterLogin(Uri.parse(login)), requested);
    },
  );
}
