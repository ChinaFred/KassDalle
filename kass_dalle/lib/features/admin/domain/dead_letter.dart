import 'package:cloud_firestore/cloud_firestore.dart';

/// Représente une entrée Dead Letter Queue : un ProcessingJob qui a échoué
/// après [retryCount] tentatives côté backend.
class DeadLetter {
  final String id;
  final String originalJobId;
  final String userId;
  final String? correlationId;
  final String failureReason;
  final String lastError;
  final int retryCount;
  final String? filePath;
  final DateTime? failedAt;
  final DateTime? relaunchedAt;
  final String? relaunchedBy;
  final String? relaunchedIntoJobId;
  final String? queueName;

  const DeadLetter({
    required this.id,
    required this.originalJobId,
    required this.userId,
    required this.correlationId,
    required this.failureReason,
    required this.lastError,
    required this.retryCount,
    required this.filePath,
    required this.failedAt,
    required this.relaunchedAt,
    required this.relaunchedBy,
    required this.relaunchedIntoJobId,
    required this.queueName,
  });

  bool get isRelaunched => relaunchedAt != null;

  factory DeadLetter.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    DateTime? ts(dynamic v) => v is Timestamp ? v.toDate() : null;
    return DeadLetter(
      id: doc.id,
      originalJobId: (d['original_job_id'] ?? '') as String,
      userId: (d['user_id'] ?? '') as String,
      correlationId: d['correlation_id'] as String?,
      failureReason: (d['failure_reason'] ?? '') as String,
      lastError: (d['last_error'] ?? '') as String,
      retryCount: ((d['retry_count'] ?? 0) as num).toInt(),
      filePath: d['file_path'] as String?,
      failedAt: ts(d['failed_at']),
      relaunchedAt: ts(d['relaunched_at']),
      relaunchedBy: d['relaunched_by'] as String?,
      relaunchedIntoJobId: d['relaunched_into_job_id'] as String?,
      queueName: d['queue_name'] as String?,
    );
  }
}
