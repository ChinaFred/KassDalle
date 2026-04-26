import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'usage_tracker.dart';

final usageTrackerProvider = Provider<UsageTracker>((ref) => UsageTracker());

final usageStatsProvider = StreamProvider<UsageStats>((ref) {
  return ref.watch(usageTrackerProvider).watch();
});
