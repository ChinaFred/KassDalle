import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/presentation/auth_providers.dart';
import '../data/processing_job_repository.dart';
import '../domain/processing_job.dart';

final processingJobRepositoryProvider = Provider<ProcessingJobRepository>((
  ref,
) {
  return ProcessingJobRepository();
});

final processingJobsProvider = StreamProvider.autoDispose<List<ProcessingJob>>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(processingJobRepositoryProvider).watchRecentByUser(uid);
});

/// Tous les jobs — admin uniquement.
final allProcessingJobsProvider = StreamProvider.autoDispose<List<ProcessingJob>>((ref) {
  return ref.watch(processingJobRepositoryProvider).watchAll();
});

/// Filtre UID pour la vue admin (null = tous les utilisateurs).
class _AdminJobUserFilter extends Notifier<String?> {
  @override
  String? build() => null;

  void setFilter(String? uid) => state = uid;
}

final adminJobUserFilterProvider =
    NotifierProvider<_AdminJobUserFilter, String?>(_AdminJobUserFilter.new);

/// Jobs filtrés pour la vue admin.
final filteredAdminJobsProvider = Provider<AsyncValue<List<ProcessingJob>>>((
  ref,
) {
  final jobs = ref.watch(allProcessingJobsProvider);
  final filter = ref.watch(adminJobUserFilterProvider);
  return jobs.whenData(
    (list) => filter == null
        ? list
        : list.where((j) => j.createdBy == filter).toList(),
  );
});

final activeProcessingJobsCountProvider = Provider<int>((ref) {
  final jobs =
      ref.watch(processingJobsProvider).value ?? const <ProcessingJob>[];
  return jobs.where((j) => j.isActive).length;
});
