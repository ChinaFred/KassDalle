import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/router/app_router.dart';
import '../../../core/utils/platform_utils.dart';

/// Page d'accueil de la section Administration.
///
/// Sections :
/// - Gestion : utilisateurs, référentiels, backfills
/// - Comptabilité : coûts de l'application, mois par mois
/// - Monitoring : rapports d'erreurs, dead letter queue, cloud logging
/// - Outils : téléchargement APK Android (desktop/web uniquement)
class AdminHubScreen extends ConsumerWidget {
  const AdminHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Administration')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // ── Gestion ──────────────────────────────────────────────────────
          const _SectionHeader(label: 'Gestion'),
          _AdminTile(
            icon: Icons.group_outlined,
            color: theme.colorScheme.primary,
            title: 'Gestion des utilisateurs',
            subtitle:
                'Gérer les rôles, révoquer ou rétablir l\'accès des comptes.',
            onTap: () => context.push(AppRoutes.adminUsers),
          ),
          _AdminTile(
            icon: Icons.dataset_outlined,
            color: theme.colorScheme.secondary,
            title: 'Référentiels',
            subtitle:
                'CRUD et visualisation des référentiels units et nutrition.',
            onTap: () => context.push(AppRoutes.adminReferentials),
          ),
          _AdminTile(
            icon: Icons.build_circle_outlined,
            color: theme.colorScheme.secondary,
            title: 'Backfills',
            subtitle:
                'Exécuter les trois backfills historiques (images, logs IA, courses).',
            onTap: () => context.push(AppRoutes.adminBackfills),
          ),
          _AdminTile(
            icon: Icons.alt_route_outlined,
            color: theme.colorScheme.tertiary,
            title: 'Moteur d\'IA',
            subtitle:
                'Choisir Gemini ou Claude, poste par poste, sans redéployer.',
            onTap: () => context.push(AppRoutes.adminAiRouting),
          ),
          _AdminTile(
            icon: Icons.verified_user_outlined,
            color: theme.colorScheme.tertiary,
            title: 'Attestation de l\'application',
            subtitle:
                'App Check : exiger que les appels viennent de l\'application, '
                'et non d\'un script.',
            onTap: () => context.push(AppRoutes.adminAppCheck),
          ),

          // ── Comptabilité ─────────────────────────────────────────────────
          const _SectionHeader(label: 'Comptabilité'),
          _AdminTile(
            icon: Icons.euro_outlined,
            color: theme.colorScheme.primary,
            title: 'Coûts de l\'application',
            subtitle:
                'Mois par mois : IA par poste et par moteur, infrastructure '
                'par service, et réconciliation avec la facturation.',
            onTap: () => context.push(AppRoutes.adminCosts),
          ),
          _AdminTile(
            icon: Icons.speed_outlined,
            color: theme.colorScheme.tertiary,
            title: 'Dépense par utilisateur',
            subtitle:
                'Qui dépense, à quoi, sur la période — et les plafonds quotidiens.',
            onTap: () => context.push(AppRoutes.adminAiSpend),
          ),

          // ── Monitoring ───────────────────────────────────────────────────
          const _SectionHeader(label: 'Monitoring'),
          _AdminTile(
            icon: Icons.bug_report_outlined,
            color: theme.colorScheme.error,
            title: 'Rapports d\'erreurs',
            subtitle:
                'Consulter les erreurs d\'import avec leur contexte et ID.',
            onTap: () => context.push(AppRoutes.errorReports),
          ),
          _AdminTile(
            icon: Icons.report_problem_outlined,
            color: theme.colorScheme.tertiary,
            title: 'Dead Letter Queue',
            subtitle:
                'Jobs en échec après 3 tentatives — relancer ou supprimer.',
            onTap: () => context.push(AppRoutes.deadLetters),
          ),
          _AdminTile(
            icon: Icons.terminal,
            color: theme.colorScheme.secondary,
            title: 'Cloud Logging',
            subtitle:
                'Explorer les logs structurés du pipeline (filtres + recherche).',
            onTap: () => context.push(AppRoutes.logs),
          ),

          // ── Outils ───────────────────────────────────────────────────────
          if (!PlatformUtils.isMobile) ...[
            const _SectionHeader(label: 'Outils'),
            _AdminTile(
              icon: Icons.android,
              color: theme.colorScheme.primary,
              title: 'Télécharger l\'APK Android',
              subtitle:
                  'Récupérer la dernière version de l\'application mobile.',
              onTap: () => launchUrl(
                Uri.parse('https://kassdale-6d948.web.app/app-release.apk'),
                mode: LaunchMode.platformDefault,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _AdminTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _AdminTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Card(
        child: ListTile(
          leading: Icon(icon, color: color),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      ),
    );
  }
}
