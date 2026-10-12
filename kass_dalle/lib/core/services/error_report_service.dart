import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../../core/app_version.dart';

/// Rapport d'erreur sauvegardé dans Firestore pour faciliter le debug.
///
/// Chaque erreur reçoit un ID unique (ID du document Firestore) qui peut être
/// communiqué à l'admin pour tracer la cause.
class ErrorReport {
  final String id;
  final String userId;
  final String? jobId;
  final DateTime timestamp;
  final String appVersion;

  /// Feature / étape où l'erreur est survenue (ex: 'extractRecipes').
  final String feature;

  /// Type Dart de l'exception (ex: 'TimeoutException', 'FirebaseException').
  final String errorType;

  /// Message de l'exception.
  final String errorMessage;

  /// Stack trace tronquée ([maxStackTrace] caractères au plus).
  final String? stackTrace;

  /// Paramètres du contexte au moment de l'erreur.
  final Map<String, dynamic> context;

  ErrorReport({
    required this.id,
    required this.userId,
    this.jobId,
    required this.timestamp,
    required this.appVersion,
    required this.feature,
    required this.errorType,
    required this.errorMessage,
    this.stackTrace,
    required this.context,
  });

  // ── Bornes d'écriture ─────────────────────────────────────────────────────
  //
  // Les règles Firestore (`error_reports`) refusent un rapport aux champs
  // inconnus ou trop longs : tout compte connecté, même en attente, en écrit,
  // et un rapport sans borne servait de stockage libre (audit sécurité).
  // Les règles admettent le double de ces longueurs : la marge couvre une
  // différence de décompte des caractères, et un rapport tronqué ici n'est
  // jamais refusé là-bas.

  static const maxShortText = 200;
  static const maxAppVersion = 50;
  static const maxMessage = 4000;
  static const maxStackTrace = 2000;
  static const maxContext = 4000;
  static const maxContextValue = 500;

  /// [value] coupé à [max] unités UTF-16, sans couper un caractère en deux,
  /// avec « … » quand il a été coupé.
  static String truncate(String value, int max) {
    if (value.length <= max) return value;
    var end = max - 1;
    final last = value.codeUnitAt(end - 1);
    // Une moitié haute de paire de substitution ne reste pas seule.
    if (last >= 0xD800 && last <= 0xDBFF) end -= 1;
    return '${value.substring(0, end)}…';
  }

  /// Le contexte, écrit en JSON borné à [maxContext] caractères.
  ///
  /// Une chaîne plutôt qu'une carte : les règles bornent la longueur d'une
  /// chaîne, pas celle des valeurs d'une carte. Chaque valeur devient du
  /// texte coupé à [maxContextValue] ; les entrées qui ne tiennent plus sont
  /// comptées sous `_omis`. Le JSON reste toujours valide.
  static String encodeContext(Map<String, dynamic> context) {
    final kept = <String, Object?>{};
    var omitted = 0;
    for (final entry in context.entries) {
      final raw = entry.value;
      final Object? value = raw == null || raw is num || raw is bool
          ? raw
          : truncate(raw.toString(), maxContextValue);
      final candidate = {...kept, truncate(entry.key, maxShortText): value};
      // Place gardée pour le compteur des entrées omises.
      if (jsonEncode(candidate).length > maxContext - 20) {
        omitted++;
        continue;
      }
      kept[truncate(entry.key, maxShortText)] = value;
    }
    if (omitted > 0) kept['_omis'] = omitted;
    return jsonEncode(kept);
  }

  Map<String, dynamic> toFirestore() => {
    'user_id': userId,
    'job_id': jobId == null ? null : truncate(jobId!, maxShortText),
    'timestamp': Timestamp.fromDate(timestamp),
    'app_version': truncate(appVersion, maxAppVersion),
    'feature': truncate(feature, maxShortText),
    'error_type': truncate(errorType, maxShortText),
    'error_message': truncate(errorMessage, maxMessage),
    'stack_trace': stackTrace == null
        ? null
        : truncate(stackTrace!, maxStackTrace),
    'context': encodeContext(context),
  };

  static DateTime _parseTimestamp(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    if (raw is String) {
      final dt = DateTime.tryParse(raw);
      if (dt != null) return dt;
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// Le contexte relu : une chaîne JSON depuis la v0.23.46, une carte avant.
  static Map<String, dynamic> _parseContext(dynamic raw) {
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return decoded.map((key, value) => MapEntry(key.toString(), value));
        }
      } on FormatException {
        // Pas de remontée ici : ce service est celui qui remonte les erreurs,
        // et il lit sa propre collection. Le texte n'est pas perdu : il
        // s'affiche tel quel sous `brut`.
        return {'brut': raw};
      }
      return {'brut': raw};
    }
    return <String, dynamic>{};
  }

  static String? _asNullableString(dynamic raw) {
    if (raw == null) return null;
    if (raw is String) return raw;
    return raw.toString();
  }

  factory ErrorReport.fromFirestore(String id, Map<String, dynamic> data) =>
      ErrorReport(
        id: id,
        userId: _asNullableString(data['user_id']) ?? '',
        jobId: _asNullableString(data['job_id']),
        timestamp: _parseTimestamp(data['timestamp']),
        appVersion: _asNullableString(data['app_version']) ?? '',
        feature: _asNullableString(data['feature']) ?? '',
        errorType: _asNullableString(data['error_type']) ?? '',
        errorMessage: _asNullableString(data['error_message']) ?? '',
        stackTrace: _asNullableString(data['stack_trace']),
        context: _parseContext(data['context']),
      );
}

/// Service de persistance des rapports d'erreur.
class ErrorReportService {
  final FirebaseFirestore? _injectedFirestore;

  /// Résolus à l'usage, pas à la construction.
  ///
  /// `FirebaseFirestore.instance` et `FirebaseAuth.instance` exigent une App
  /// initialisée. Ce service est construit par défaut dans chaque repository :
  /// l'exiger dès la construction rendait tout repository inconstructible hors
  /// application, donc hors test.
  FirebaseFirestore get _firestore =>
      _injectedFirestore ?? FirebaseFirestore.instance;
  FirebaseAuth get _auth => FirebaseAuth.instance;

  ErrorReportService({FirebaseFirestore? firestore})
    : _injectedFirestore = firestore;

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('error_reports');

  String _resolveUserId(String? userId) {
    if (userId != null && userId.isNotEmpty) return userId;
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId != null && currentUserId.isNotEmpty) {
      return currentUserId;
    }
    return 'anonymous';
  }

  String? _truncateStackTrace(StackTrace? stackTrace) {
    if (stackTrace == null) return null;
    final rawStackTrace = stackTrace.toString();
    if (rawStackTrace.isEmpty) return null;
    return ErrorReport.truncate(rawStackTrace, ErrorReport.maxStackTrace);
  }

  Future<String> reportError({
    String? userId,
    String? jobId,
    required String feature,
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic> context = const {},
  }) {
    return save(
      userId: _resolveUserId(userId),
      jobId: jobId,
      feature: feature,
      error: error,
      stackTrace: stackTrace,
      context: context,
    );
  }

  Future<T> protect<T>({
    String? userId,
    String? jobId,
    required String feature,
    required Future<T> Function() action,
    Map<String, dynamic> context = const {},
  }) async {
    try {
      return await action();
    } catch (error, stackTrace) {
      await reportError(
        userId: userId,
        jobId: jobId,
        feature: feature,
        error: error,
        stackTrace: stackTrace,
        context: context,
      );
      rethrow;
    }
  }

  /// Sauvegarde une erreur et retourne son ID.
  Future<String> save({
    required String userId,
    String? jobId,
    required String feature,
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic> context = const {},
  }) async {
    final now = DateTime.now();
    final truncatedStack = _truncateStackTrace(stackTrace);

    final report = ErrorReport(
      id: '',
      userId: _resolveUserId(userId),
      jobId: jobId,
      timestamp: now,
      appVersion: kAppVersion,
      feature: feature,
      errorType: error.runtimeType.toString(),
      errorMessage: error.toString(),
      stackTrace: truncatedStack,
      context: context,
    );

    final ref = await _col.add(report.toFirestore());
    return ref.id;
  }

  /// Tous les rapports — réservé à l'admin.
  Stream<List<ErrorReport>> watchAll() {
    return _col
        .orderBy('timestamp', descending: true)
        .limit(200)
        .snapshots()
        .map((snap) {
          final reports = <ErrorReport>[];
          for (final d in snap.docs) {
            try {
              reports.add(ErrorReport.fromFirestore(d.id, d.data()));
            } catch (error, stackTrace) {
              // Un document mal formé ne doit pas casser toute la liste. On ne
              // peut pas remonter l'incident via ce service — ce serait écrire
              // dans la collection qu'on est en train de lire : la console est
              // ici le seul recours possible.
              debugPrint(
                '[ErrorReportService] rapport ${d.id} illisible : '
                '$error\n$stackTrace',
              );
            }
          }
          return reports;
        });
  }

  /// Rapports d'un utilisateur.
  Stream<List<ErrorReport>> watchByUser(String userId) {
    return _col
        .where('user_id', isEqualTo: userId)
        .orderBy('timestamp', descending: true)
        .limit(50)
        .snapshots()
        .map((snap) {
          final reports = <ErrorReport>[];
          for (final d in snap.docs) {
            try {
              reports.add(ErrorReport.fromFirestore(d.id, d.data()));
            } catch (error, stackTrace) {
              // Un document mal formé ne doit pas casser toute la liste. On ne
              // peut pas remonter l'incident via ce service — ce serait écrire
              // dans la collection qu'on est en train de lire : la console est
              // ici le seul recours possible.
              debugPrint(
                '[ErrorReportService] rapport ${d.id} illisible : '
                '$error\n$stackTrace',
              );
            }
          }
          return reports;
        });
  }
}
