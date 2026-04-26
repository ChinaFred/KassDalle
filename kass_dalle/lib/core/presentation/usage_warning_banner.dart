import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/usage_providers.dart';
import '../services/usage_tracker.dart';
import '../../features/auth/presentation/auth_providers.dart';

/// Bandeau d'alerte coût — visible uniquement pour les admins.
/// S'affiche quand on approche des seuils de facturation Firebase/Gemini.
class UsageWarningBanner extends ConsumerWidget {
  const UsageWarningBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(isAdminProvider);
    if (!isAdmin) return const SizedBox.shrink();

    return ref
        .watch(usageStatsProvider)
        .maybeWhen(
          data: (stats) {
            if (!stats.hasWarning) return const SizedBox.shrink();
            return _BannerContent(stats: stats);
          },
          orElse: () => const SizedBox.shrink(),
        );
  }
}

class _BannerContent extends StatefulWidget {
  final UsageStats stats;
  const _BannerContent({required this.stats});

  @override
  State<_BannerContent> createState() => _BannerContentState();
}

class _BannerContentState extends State<_BannerContent> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final msgs = <String>[];
    if (widget.stats.storageWarning) {
      msgs.add(
        'Stockage : ${widget.stats.storageFmt} / 5 Go'
        ' — seuil de facturation proche !',
      );
    }
    if (widget.stats.geminiWarning) {
      msgs.add(
        'Scans IA ce mois : ${widget.stats.scansThisMonth}'
        ' / ${UsageLimits.geminiWarnPerMonth} — quota approché !',
      );
    }

    return Container(
      color: cs.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: cs.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              msgs.join('  •  '),
              style: TextStyle(color: cs.onErrorContainer, fontSize: 13),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, color: cs.onErrorContainer, size: 18),
            tooltip: 'Fermer',
            onPressed: () => setState(() => _dismissed = true),
          ),
        ],
      ),
    );
  }
}
