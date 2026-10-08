import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/meal_staple.dart';

/// Lit et écrit les garnitures simples : le référentiel partagé, et les
/// retouches d'un utilisateur.
///
/// Le référentiel vit dans `meal_staples/{id}` — lu par tout compte nommé,
/// écrit par un administrateur. Les retouches vivent dans
/// `users/{uid}/preferences/meal_staples`, un seul document : une carte
/// `entries` indexée par identifiant de garniture. Une entrée dont
/// l'identifiant est celui d'une garniture de base la retouche ; une entrée
/// marquée `own` est une garniture propre à l'utilisateur.
class MealStaplesRepository {
  final FirebaseFirestore _db;

  MealStaplesRepository({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _base =>
      _db.collection('meal_staples');

  DocumentReference<Map<String, dynamic>> _overridesDoc(String uid) => _db
      .collection('users')
      .doc(uid)
      .collection('preferences')
      .doc('meal_staples');

  // ── Référentiel partagé ─────────────────────────────────────────────────────

  /// Le référentiel en direct, par identifiant.
  ///
  /// Plafond large : une lecture plafonnée trop bas coupe la fin de
  /// l'alphabet et ressemble à une liste incomplète.
  Stream<List<MealStaple>> watchBase() => _base
      .orderBy(FieldPath.documentId)
      .limit(1000)
      .snapshots()
      .map(
        (snap) => snap.docs
            .map((d) => MealStaple.fromFirestore(d.id, d.data()))
            .toList(growable: false),
      );

  /// Crée une garniture de base. Refuse d'écraser : un identifiant déjà pris
  /// est une erreur de saisie, pas une mise à jour.
  Future<void> createBase(MealStaple staple) async {
    final ref = _base.doc(staple.id);
    final snap = await ref.get();
    if (snap.exists) {
      throw StateError('La garniture « ${staple.id} » existe déjà.');
    }
    final now = FieldValue.serverTimestamp();
    await ref.set({
      ...staple.toFirestore(),
      'created_at': now,
      'updated_at': now,
    });
  }

  /// Met à jour une garniture de base, sans toucher à sa date de création.
  Future<void> updateBase(MealStaple staple) async {
    await _base.doc(staple.id).update({
      ...staple.toFirestore(),
      'updated_at': FieldValue.serverTimestamp(),
    });
  }

  Future<void> deleteBase(String id) async {
    await _base.doc(id).delete();
  }

  /// Les garnitures d'un compte, fusionnées, lues une fois.
  ///
  /// Pour un écran qui compose un cycle sans s'abonner : ce qu'il lit à
  /// l'ouverture lui suffit, une retouche faite pendant ce temps attendra le
  /// prochain cycle.
  Future<List<UserStaple>> loadMyStaples(String uid) async {
    final base = await _base.orderBy(FieldPath.documentId).limit(1000).get();
    final overrides = await _overridesDoc(uid).get();
    return mergeStaples(
      base.docs.map((d) => MealStaple.fromFirestore(d.id, d.data())),
      parseStapleOverrides(overrides.data()),
    );
  }

  // ── Retouches d'un utilisateur ──────────────────────────────────────────────

  /// Les retouches du compte [uid], en direct.
  Stream<Map<String, StapleOverride>> watchOverrides(String uid) =>
      _overridesDoc(
        uid,
      ).snapshots().map((snap) => parseStapleOverrides(snap.data()));

  /// Écrit une retouche, ou la retire si elle ne dit plus rien.
  ///
  /// Le champ `entries.{id}` est remplacé en entier : une retouche est un
  /// tout, pas une fusion — sinon effacer une quantité retouchée laisserait
  /// l'ancienne valeur en place.
  Future<void> saveOverride(String uid, StapleOverride override) async {
    if (override.isEmpty) return removeOverride(uid, override.id);
    await _overridesDoc(uid).set(
      {
        'entries': {override.id: override.toMap()},
        'updated_at': FieldValue.serverTimestamp(),
      },
      SetOptions(
        mergeFields: [
          FieldPath(['entries', override.id]),
          'updated_at',
        ],
      ),
    );
  }

  /// Retire une retouche : la garniture de base reprend ses valeurs, une
  /// garniture propre à l'utilisateur disparaît.
  Future<void> removeOverride(String uid, String id) async {
    await _overridesDoc(uid).set(
      {
        'entries': {id: FieldValue.delete()},
        'updated_at': FieldValue.serverTimestamp(),
      },
      SetOptions(
        mergeFields: [
          FieldPath(['entries', id]),
          'updated_at',
        ],
      ),
    );
  }
}
