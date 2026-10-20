import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/presentation/app_shell.dart';

/// Le shell borne tout écran à `ReadableWidth`, sauf une liste fermée de
/// tableaux.
void main() {
  test('le sommaire de l’administration est borné', () {
    expect(wantsFullWidth('/admin'), isFalse);
  });

  test('la réconciliation des coûts reste en pleine largeur', () {
    expect(wantsFullWidth('/admin/costs'), isTrue);
  });

  test('le journal des logs reste en pleine largeur', () {
    expect(wantsFullWidth('/logs'), isTrue);
  });

  test('un ticket des membres est borné', () {
    expect(wantsFullWidth('/admin/tickets/abc'), isFalse);
  });

  test('les autres tableaux restent en pleine largeur', () {
    expect(wantsFullWidth('/error-reports'), isTrue);
    expect(wantsFullWidth('/dead-letters'), isTrue);
    expect(wantsFullWidth('/planning/batch'), isTrue);
  });

  test('un préfixe qui ressemble à une route ne compte pas', () {
    expect(wantsFullWidth('/admin/ai-spend'), isFalse);
    expect(wantsFullWidth('/admin/users/invite'), isFalse);
    expect(wantsFullWidth('/planning'), isFalse);
  });
}
