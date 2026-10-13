import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/error_report_service.dart';
import '../domain/shopping_cart.dart';

/// Ce qu'on fait des articles qui arrivent quand le panier n'est pas vide.
enum ShoppingAddMode {
  /// Fusionner avec la liste en place.
  add,

  /// Effacer la liste en place, puis poser les nouveaux articles.
  replace,
}

/// Résultat d'un ajout : la liste d'avant, pour « Annuler » après un
/// remplacement, et la liste écrite.
typedef ShoppingAddResult = ({
  List<ShoppingItem> previous,
  List<ShoppingItem> written,
});

/// Lit et écrit le panier de courses d'un compte :
/// `users/{uid}/shopping/current`, un seul document.
///
/// Ajouter ou remplacer passe par une transaction : la fusion part de la
/// liste à jour, même si un autre appareil vient d'écrire. Cocher, retirer
/// les articles cochés et vider sont des écritures simples, qui partent aussi
/// hors ligne — on coche dans le magasin, où le réseau manque souvent.
///
/// Une erreur d'écriture est remontée au rapport d'erreurs ici, puis relancée
/// à l'appelant, qui la dit à l'écran.
class ShoppingCartRepository {
  ShoppingCartRepository({
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
    Future<SharedPreferences> Function()? preferences,
  }) : _db = firestore ?? FirebaseFirestore.instance,
       _errorReportService =
           errorReportService ?? ErrorReportService(firestore: firestore),
       _preferences = preferences ?? SharedPreferences.getInstance;

  final FirebaseFirestore _db;
  final ErrorReportService _errorReportService;
  final Future<SharedPreferences> Function() _preferences;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      _db.collection('users').doc(uid).collection('shopping').doc('current');

  /// Clés de l'ancienne liste locale, valable le jour même (avant le panier
  /// Firestore).
  static String legacyItemsKey(String uid) => 'sl_items_$uid';
  static String legacyDateKey(String uid) => 'sl_date_$uid';

  /// Le panier en direct.
  Stream<ShoppingCart> watch(String uid) => _doc(
    uid,
  ).snapshots().map((snap) => ShoppingCart.fromFirestore(snap.data()));

  /// Le panier en direct, après la reprise de l'ancienne liste locale.
  ///
  /// La reprise ne bloque jamais la lecture : un échec est remonté, et le
  /// panier s'affiche tel qu'il est.
  Stream<ShoppingCart> watchAfterMigration(String uid) async* {
    await migrateLocalList(uid);
    yield* watch(uid);
  }

  /// Le panier, lu une fois. Une erreur remonte à l'appelant.
  Future<ShoppingCart> load(String uid) async {
    try {
      final snap = await _doc(uid).get();
      return ShoppingCart.fromFirestore(snap.data());
    } catch (e, stackTrace) {
      _report('shopping.load', e, stackTrace, uid);
      rethrow;
    }
  }

  /// Ajoute [incoming] au panier, fusionné ([ShoppingAddMode.add]) ou à la
  /// place de la liste en place ([ShoppingAddMode.replace]).
  ///
  /// Lève [ShoppingCartFullException] si le panier dépasserait
  /// [kShoppingCartMaxItems] articles : rien n'est écrit.
  Future<ShoppingAddResult> addItems(
    String uid,
    List<ShoppingItem> incoming, {
    required ShoppingAddMode mode,
  }) async {
    try {
      final ref = _doc(uid);
      return await _db.runTransaction((tx) async {
        final snap = await tx.get(ref);
        final previous = ShoppingCart.fromFirestore(snap.data()).items;
        final written = switch (mode) {
          ShoppingAddMode.add => mergeShoppingItems(previous, incoming),
          ShoppingAddMode.replace => mergeShoppingItems(const [], incoming),
        };
        if (written.length > kShoppingCartMaxItems) {
          throw ShoppingCartFullException(written.length);
        }
        tx.set(ref, _payload(written));
        return (previous: previous, written: written);
      });
    } on ShoppingCartFullException {
      // Pas une panne : l'écran dit la borne, rien n'est à remonter.
      rethrow;
    } catch (e, stackTrace) {
      _report('shopping.addItems', e, stackTrace, uid, {
        'mode': mode.name,
        'incoming_count': incoming.length,
      });
      rethrow;
    }
  }

  /// Remet le panier à [items] tel quel — « Annuler » après un remplacement.
  Future<void> restore(String uid, List<ShoppingItem> items) async {
    try {
      await _doc(uid).set(_payload(items));
    } catch (e, stackTrace) {
      _report('shopping.restore', e, stackTrace, uid, {'count': items.length});
      rethrow;
    }
  }

  /// Coche ou décoche la ligne [key] (`ShoppingItem.key`) : un seul champ
  /// écrit.
  Future<void> setChecked(String uid, String key, bool checked) async {
    try {
      await _doc(uid).update({
        FieldPath(['items', key, 'checked']): checked,
        'updated_at': FieldValue.serverTimestamp(),
      });
    } catch (e, stackTrace) {
      _report('shopping.setChecked', e, stackTrace, uid, {'checked': checked});
      rethrow;
    }
  }

  /// « Retirer les articles cochés » : les lignes [keys], celles que l'écran
  /// montre cochées, sortent de la carte. Une ligne cochée entre-temps sur un
  /// autre appareil reste.
  Future<void> removeItems(String uid, Iterable<String> keys) async {
    final unique = keys.toSet();
    if (unique.isEmpty) return;
    try {
      await _doc(uid).update({
        for (final key in unique)
          FieldPath(['items', key]): FieldValue.delete(),
        'updated_at': FieldValue.serverTimestamp(),
      });
    } catch (e, stackTrace) {
      _report('shopping.removeItems', e, stackTrace, uid, {
        'count': unique.length,
      });
      rethrow;
    }
  }

  /// « Vider la liste ».
  Future<void> clear(String uid) async {
    try {
      await _doc(uid).set(_payload(const []));
    } catch (e, stackTrace) {
      _report('shopping.clear', e, stackTrace, uid);
      rethrow;
    }
  }

  /// Reprend l'ancienne liste locale de cet appareil (`sl_items_{uid}`), une
  /// fois : si le panier Firestore est vide, elle y est écrite ; dans tous les
  /// cas, les clés locales sont effacées ensuite. Un panier déjà rempli —
  /// depuis un autre appareil — fait foi et n'est pas touché.
  ///
  /// Rend vrai si des articles ont été repris. Jamais bloquant : un échec est
  /// remonté (`shopping.migrateLocal`), les clés restent pour un nouvel essai
  /// au prochain lancement, et la fonction rend faux.
  Future<bool> migrateLocalList(String uid) async {
    final itemsKey = legacyItemsKey(uid);
    try {
      final prefs = await _preferences();
      final stored = prefs.getString(itemsKey);
      if (stored == null) return false;
      final legacy = _parseLegacy(uid, stored);
      var migrated = false;
      if (legacy.isNotEmpty) {
        // Passée par la fusion : deux lignes du même produit n'en font
        // qu'une, comme la carte du document l'exige.
        final items = mergeShoppingItems(
          const [],
          legacy,
        ).take(kShoppingCartMaxItems).toList();
        final ref = _doc(uid);
        migrated = await _db.runTransaction((tx) async {
          final snap = await tx.get(ref);
          if (!ShoppingCart.fromFirestore(snap.data()).isEmpty) return false;
          tx.set(ref, _payload(items));
          return true;
        });
      }
      await prefs.remove(itemsKey);
      await prefs.remove(legacyDateKey(uid));
      return migrated;
    } catch (e, stackTrace) {
      _report('shopping.migrateLocal', e, stackTrace, uid);
      return false;
    }
  }

  /// Lit l'ancienne liste locale. Un texte illisible rend une liste vide,
  /// après remontée : il n'y a rien à reprendre, et la clé sera effacée.
  List<ShoppingItem> _parseLegacy(String uid, String stored) {
    final Object? decoded;
    try {
      decoded = json.decode(stored);
    } on FormatException catch (e, stackTrace) {
      _report('shopping.migrateLocal.parse', e, stackTrace, uid, {
        'length': stored.length,
      });
      return const [];
    }
    if (decoded is! List) return const [];
    return [
      for (final e in decoded)
        if (e is Map)
          ?ShoppingItem.fromLegacyJson(Map<String, dynamic>.from(e)),
    ];
  }

  Map<String, dynamic> _payload(List<ShoppingItem> items) => {
    'items': ShoppingCart.itemsToFirestore(items),
    'updated_at': FieldValue.serverTimestamp(),
  };

  /// Remonte une erreur sans attendre l'écriture du rapport : hors ligne,
  /// elle n'aboutirait qu'au retour du réseau, et l'écran resterait figé.
  void _report(
    String feature,
    Object error,
    StackTrace stackTrace,
    String uid, [
    Map<String, dynamic> context = const {},
  ]) {
    unawaited(
      _errorReportService
          .reportError(
            userId: uid,
            feature: feature,
            error: error,
            stackTrace: stackTrace,
            context: context,
          )
          .catchError((Object reportingError, StackTrace reportingStack) {
            // La remontée elle-même a échoué : la console est le dernier
            // recours. L'erreur d'origine est relancée à l'appelant.
            debugPrint(
              '[ShoppingCartRepository] remontée impossible pour "$feature" : '
              '$reportingError\n$reportingStack\nErreur d\'origine : $error',
            );
            return '';
          }),
    );
  }
}
