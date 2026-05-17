import 'package:cloud_firestore/cloud_firestore.dart';
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

  factory ErrorReport.fromFirestore(String id, Map<String, dynamic> data) =>
      ErrorReport(
        id: id,
        userId: data['user_id'] as String? ?? '',
        jobId: data['job_id'] as String?,
        timestamp: (data['timestamp'] as Timestamp).toDate(),
        appVersion: data['app_version'] as String? ?? '',
        feature: data['feature'] as String? ?? '',
        errorType: data['error_type'] as String? ?? '',
        errorMessage: data['error_message'] as String? ?? '',
        stackTrace: data['stack_trace'] as String?,
        context: Map<String, dynamic>.from(data['context'] as Map? ?? {}),
      );
}

/// Service de persistance des rapports d'erreur.
class ErrorReportService {
  final FirebaseFirestore _firestore;

  ErrorReportService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('error_reports');

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
    final truncatedStack = stackTrace != null
        ? stackTrace.toString().substring(
              0,
              stackTrace.toString().length.clamp(0, 2000),
            )
        : null;

    final report = ErrorReport(
      id: '',
      userId: userId,
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
        .map(
          (snap) => snap.docs
              .map((d) => ErrorReport.fromFirestore(d.id, d.data()))
              .toList(),
        );
  }

  /// Rapports d'un utilisateur.
  Stream<List<ErrorReport>> watchByUser(String userId) {
    return _col
        .where('user_id', isEqualTo: userId)
        .orderBy('timestamp', descending: true)
        .limit(50)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => ErrorReport.fromFirestore(d.id, d.data()))
              .toList(),
        );
  }
}
