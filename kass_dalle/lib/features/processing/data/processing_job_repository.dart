import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/processing_job.dart';

class ProcessingJobRepository {
  final FirebaseFirestore _firestore;

  ProcessingJobRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('processing_jobs');

  Future<String> createJob(ProcessingJob job) async {
    final ref = await _col.add(job.toFirestore());
    return ref.id;
  }

  Future<void> updateJob(String id, Map<String, dynamic> data) async {
    await _col.doc(id).update({...data, 'updated_at': DateTime.now()});
  }

  Future<ProcessingJob?> getJob(String id) async {
    final doc = await _col.doc(id).get();
    if (!doc.exists) return null;
    return ProcessingJob.fromFirestore(doc.id, doc.data()!);
  }

  Future<void> deleteJob(String id) async {
    await _col.doc(id).delete();
  }

  Stream<List<ProcessingJob>> watchRecentByUser(String uid) {
    return _col.where('created_by', isEqualTo: uid).snapshots().map((snapshot) {
      final list = snapshot.docs
          .map((doc) => ProcessingJob.fromFirestore(doc.id, doc.data()))
          .toList();
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return list.take(100).toList(growable: false);
    });
  }

  /// Tous les jobs — réservé à l'admin.
  Stream<List<ProcessingJob>> watchAll() {
    return _col.snapshots().map((snapshot) {
      final list = snapshot.docs
          .map((doc) => ProcessingJob.fromFirestore(doc.id, doc.data()))
          .toList();
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return list;
    });
  }
}
