import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/admin_repository.dart';
import '../data/token_usage_repository.dart';
import '../../auth/domain/app_user.dart';
import '../../auth/presentation/auth_providers.dart';

final adminRepositoryProvider = Provider<AdminRepository>((ref) {
  return AdminRepository();
});

final allUsersProvider = StreamProvider<List<AppUser>>((ref) {
  return ref.watch(adminRepositoryProvider).watchAllUsers();
});

final tokenUsageRepositoryProvider = Provider<TokenUsageRepository>((_) {
  return TokenUsageRepository();
});

/// Stream de tous les enregistrements (admin uniquement).
final allTokenUsageProvider = StreamProvider<List<TokenUsageRecord>>((ref) {
  return ref.watch(tokenUsageRepositoryProvider).watchAll();
});

/// Stream des enregistrements de l'utilisateur courant.
final myTokenUsageProvider = StreamProvider<List<TokenUsageRecord>>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(tokenUsageRepositoryProvider).watchByUser(uid);
});
