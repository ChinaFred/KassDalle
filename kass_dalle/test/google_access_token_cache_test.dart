import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/google_access_token_cache.dart';

/// Le jeton Google (Agenda, Tasks) gardé en mémoire appartient au compte qui
/// l'a obtenu : un second compte connecté sur le même appareil ne s'en sert
/// pas, et la déconnexion l'oublie.
void main() {
  var now = DateTime.utc(2026, 10, 22, 12);
  GoogleAccessTokenCache cache() => GoogleAccessTokenCache(now: () => now);

  setUp(() => now = DateTime.utc(2026, 10, 22, 12));

  test('un jeton gardé pour A est rendu à A', () {
    final c = cache()..store('uid-a', 'jeton-a');
    expect(c.read('uid-a'), 'jeton-a');
  });

  test('un jeton gardé pour A n’est pas rendu à B', () {
    final c = cache()..store('uid-a', 'jeton-a');
    expect(c.read('uid-b'), isNull);
  });

  test('sans compte connecté, aucun jeton n’est rendu', () {
    final c = cache()..store('uid-a', 'jeton-a');
    expect(c.read(null), isNull);
  });

  test('sans compte connu, rien n’est gardé', () {
    final c = cache()
      ..store('uid-a', 'jeton-a')
      ..store(null, 'jeton-inconnu');
    expect(c.read('uid-a'), isNull);
  });

  test('le jeton n’est plus rendu cinq minutes avant son échéance', () {
    final c = cache()..store('uid-a', 'jeton-a');
    now = now.add(const Duration(minutes: 49));
    expect(c.read('uid-a'), 'jeton-a');
    now = now.add(const Duration(minutes: 1));
    expect(c.read('uid-a'), isNull);
  });

  test('un jeton arrivé à échéance est effacé de la mémoire', () {
    final c = cache()..store('uid-a', 'jeton-a');
    now = now.add(const Duration(minutes: 50));
    expect(c.read('uid-a'), isNull);
    // Revenir en arrière ne le fait pas réapparaître : il a été effacé.
    now = DateTime.utc(2026, 10, 22, 12);
    expect(c.read('uid-a'), isNull);
  });

  test('clearAll vide tous les caches (déconnexion)', () {
    final agenda = cache()..store('uid-a', 'jeton-agenda');
    final tasks = cache()..store('uid-a', 'jeton-tasks');
    GoogleAccessTokenCache.clearAll();
    expect(agenda.read('uid-a'), isNull);
    expect(tasks.read('uid-a'), isNull);
  });
}
