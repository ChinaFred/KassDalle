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

  /// Stack trace tronquée (max 2000 chars).
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

  Map<String, dynamic> toFirestore() => {
    'user_id': userId,
    'job_id': jobId,
    'timestamp': Timestamp.fromDate(timestamp),
    'app_version': appVersion,
    'feature': feature,
    'error_type': errorType,
    'error_message': errorMessage,
    'stack_trace': stackTrace,
    'context': context,
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

  static Map<String, dynamic> _parseContext(dynamic raw) {
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
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
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  ErrorReportService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance,
      _auth = FirebaseAuth.instance;

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
    return rawStackTrace.substring(
      0,
      rawStackTrace.length.clamp(0, 2000).toInt(),
    );
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
