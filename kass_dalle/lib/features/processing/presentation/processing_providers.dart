import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/presentation/auth_providers.dart';
import '../data/processing_job_repository.dart';
import '../domain/processing_job.dart';

final processingJobRepositoryProvider = Provider<ProcessingJobRepository>((
  ref,
) {
  return ProcessingJobRepository();
});

final processingJobsProvider = StreamProvider<List<ProcessingJob>>((ref) {
  final uid = ref.watch(appUserProvider).valueOrNull?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(processingJobRepositoryProvider).watchRecentByUser(uid);
});

final activeProcessingJobsCountProvider = Provider<int>((ref) {
  final jobs =
      ref.watch(processingJobsProvider).valueOrNull ?? const <ProcessingJob>[];
  return jobs.where((j) => j.isActive).length;
});
