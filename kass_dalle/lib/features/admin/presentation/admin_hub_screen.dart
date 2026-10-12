import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/app_update_service.dart';
import '../../../core/utils/platform_utils.dart';
import '../../moderation/presentation/moderation_providers.dart';

/// Page d'accueil de la section Administration.
///
/// Sections :
/// - Gestion : utilisateurs, référentiels, backfills
/// - Comptabilité : coûts de l'application, mois par mois
/// - Monitoring : rapports d'erreurs, dead letter queue, cloud logging
/// - Laboratoire : bac à sable des fonctionnalités expérimentales
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
            subtitle: 'Lancer, programmer et suivre les reprises de données.',
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
            icon: Icons.shield_outlined,
            color: theme.colorScheme.error,
            title: 'Modération des images',
            subtitle:
                'Journal complet : ce qui est publié, ce qui est refusé, et ce '
                'qui attend une décision.',
            trailing: const _ModerationBadge(),
            onTap: () => context.push(AppRoutes.adminModeration),
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
          // La grille a d'abord été posée en icône dans la barre de « Coûts de
          // l'application ». Un raccourci n'est pas une entrée : on ne le
          // trouve qu'en ouvrant l'écran qui le porte, et un tarif qu'on ne
          // trouve pas est un tarif qu'on ne corrige pas. Le raccourci reste,
          // il sert quand on lit déjà les montants ; l'entrée, elle, se voit.
          _AdminTile(
            icon: Icons.sell_outlined,
            color: theme.colorScheme.primary,
            title: 'Grille tarifaire',
            subtitle:
                'Le prix de chaque modèle d\'IA. Un tarif corrigé ici chiffre '
                'l\'appel suivant, sans déploiement.',
            onTap: () => context.push(AppRoutes.adminAiPricing),
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
            icon: Icons.fact_check_outlined,
            color: theme.colorScheme.secondary,
            title: 'Qualité des données',
            subtitle:
                'Produit d\'achat manquant, nutrition incomplète, sel '
                'implausible, unités non confirmées.',
            onTap: () => context.push(AppRoutes.adminDataQuality),
          ),
          _AdminTile(
            icon: Icons.terminal,
            color: theme.colorScheme.secondary,
            // « Cloud Logging » est le nom du produit Google, pas celui de la
            // chose cherchée : on cherche les journaux, et on ne les trouvait
            // pas sous ce titre-là.
            title: 'Journaux (Cloud Logging)',
            subtitle:
                'Logs du pipeline, filtrables — et le texte rendu par l\'IA à '
                'chaque étape d\'un import (chercher « Texte IA »).',
            onTap: () => context.push(AppRoutes.logs),
          ),

          // ── Laboratoire ──────────────────────────────────────────────────
          const _SectionHeader(label: 'Laboratoire'),
          _AdminTile(
            icon: Icons.science_outlined,
            color: theme.colorScheme.tertiary,
            title: 'Bac à sable',
            subtitle:
                'Fonctionnalités expérimentales : terrain d\'essai isolé, qui '
                'ne promet rien et n\'enregistre rien.',
            onTap: () => context.push(AppRoutes.adminSandbox),
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
                Uri.parse(kApkDownloadUrl),
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

  /// Ornement placé avant le chevron — un badge de file d'attente, par exemple.
  final Widget? trailing;

  const _AdminTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
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
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [?trailing, const Icon(Icons.chevron_right)],
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}

/// Badge du nombre d'images en attente de décision.
///
/// Masqué à zéro : un badge qui ne redescend jamais cesse d'être lu. Il compte
/// ce sur quoi il faut agir, pas le journal entier.
class _ModerationBadge extends ConsumerWidget {
  const _ModerationBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(pendingModerationCountProvider).value ?? 0;
    if (count == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        label: '$count image(s) en attente de décision',
        child: Badge(label: Text('$count')),
      ),
    );
  }
}
