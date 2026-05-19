import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/router/app_router.dart';
import '../../../core/utils/platform_utils.dart';

/// Page d'accueil de la section Administration.
///
/// Liste les outils réservés aux admins :
/// - Gestion des utilisateurs
/// - Usage des tokens IA
/// - Rapports d'erreurs
/// - Dead Letter Queue
/// - Cloud Logging
/// - Téléchargement de l'APK Android (desktop/web uniquement)
class AdminHubScreen extends ConsumerWidget {
  const AdminHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    final entries = <_AdminEntry>[
      _AdminEntry(
        icon: Icons.group_outlined,
        color: theme.colorScheme.primary,
        title: 'Gestion des utilisateurs',
        subtitle:
            'Gérer les rôles, révoquer ou rétablir l\'accès des comptes.',
        onTap: () => context.push(AppRoutes.adminUsers),
      ),
      _AdminEntry(
        icon: Icons.analytics_outlined,
        color: theme.colorScheme.primary,
        title: 'Usage des tokens IA',
        subtitle:
            'Visualiser la consommation Gemini par utilisateur et par feature.',
        onTap: () => context.push(AppRoutes.tokenUsage),
      ),
      _AdminEntry(
        icon: Icons.bug_report_outlined,
        color: theme.colorScheme.error,
        title: 'Rapports d\'erreurs',
        subtitle:
            'Consulter les erreurs d\'import avec leur contexte et ID.',
        onTap: () => context.push(AppRoutes.errorReports),
      ),
      _AdminEntry(
        icon: Icons.report_problem_outlined,
        color: theme.colorScheme.tertiary,
        title: 'Dead Letter Queue',
        subtitle:
            'Jobs en échec après 3 tentatives — relancer ou supprimer.',
        onTap: () => context.push(AppRoutes.deadLetters),
      ),
      _AdminEntry(
        icon: Icons.terminal,
        color: theme.colorScheme.secondary,
        title: 'Cloud Logging',
        subtitle:
            'Explorer les logs structurés du pipeline (filtres + recherche).',
        onTap: () => context.push(AppRoutes.logs),
      ),
      if (!PlatformUtils.isMobile)
        _AdminEntry(
          icon: Icons.android,
          color: theme.colorScheme.primary,
          title: 'Télécharger l\'APK Android',
          subtitle: 'Récupérer la dernière version de l\'application mobile.',
          onTap: () => launchUrl(
            Uri.parse('https://kassdale-6d948.web.app/app-release.apk'),
            mode: LaunchMode.platformDefault,
          ),
        ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Administration')),
      body: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final e = entries[i];
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Card(
              child: ListTile(
                leading: Icon(e.icon, color: e.color),
                title: Text(e.title),
                subtitle: Text(e.subtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: e.onTap,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AdminEntry {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  _AdminEntry({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
}
