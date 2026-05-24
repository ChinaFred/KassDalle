import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/admin/data/token_usage_repository.dart';
import '../../features/admin/presentation/admin_providers.dart';
import '../../features/auth/presentation/auth_providers.dart';
import 'gemini_service.dart';

/// Provider global pour [GeminiService].
///
/// Configure automatiquement le tracking des tokens si un utilisateur
/// est connecté. À utiliser partout où Gemini est appelé depuis un
/// contexte Riverpod.
final geminiServiceProvider = Provider<GeminiService>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid ?? '';
  final tokenRepo = ref.watch(tokenUsageRepositoryProvider);
  return GeminiService(
    onTokenUsage: uid.isNotEmpty
        ? TokenUsageRepository.makeCallback(uid, tokenRepo)
        : null,
  );
});
