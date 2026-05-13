import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_version.dart';
import '../../features/auth/presentation/auth_providers.dart';
import '../../features/processing/presentation/processing_providers.dart';
import '../../features/recipes/presentation/recipe_providers.dart';
import '../router/app_router.dart';
import '../utils/platform_utils.dart';
import 'usage_warning_banner.dart';

class AppShell extends ConsumerWidget {
  final Widget child;
  const AppShell({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isWide =
        MediaQuery.of(context).size.width >= PlatformUtils.wideBreakpoint;

    return isWide ? _WideShell(child: child) : _NarrowShell(child: child);
  }
}

// Layout large : NavigationRail latérale (Web / Desktop)
class _WideShell extends ConsumerWidget {
  final Widget child;
  const _WideShell({required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;

    final destinations = _destinations();
    final selectedIndex = _indexForLocation(location, destinations);

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
            onDestinationSelected: (i) => context.go(destinations[i].route),
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Image.asset('assets/Icon.png', width: 48, height: 48),
            ),
            destinations: destinations.map((d) {
              final icon = d.route == AppRoutes.drafts
                  ? _DraftsIcon(icon: d.icon)
                  : Icon(d.icon);
              return NavigationRailDestination(
                icon: icon,
                label: Text(d.label),
              );
            }).toList(),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                const UsageWarningBanner(),
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: _AccountBadge(),
                  ),
                ),
                Expanded(child: child),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Layout étroit : BottomNavigationBar (Mobile)
class _NarrowShell extends ConsumerWidget {
  final Widget child;
  const _NarrowShell({required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;

    final destinations = _destinations();
    final selectedIndex = _indexForLocation(location, destinations);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && context.canPop()) context.pop();
      },
      child: Scaffold(
        body: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: _AccountBadge(),
                ),
              ),
            ),
            const UsageWarningBanner(),
            Expanded(child: child),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
          onDestinationSelected: (i) => context.go(destinations[i].route),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
          destinations: destinations
              .map(
                (d) => NavigationDestination(
                  icon: d.route == AppRoutes.drafts
                      ? _DraftsIcon(icon: d.icon)
                      : Icon(d.icon),
                  label: d.label,
                  tooltip: d.label,
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _NavDestination {
  final String route;
  final IconData icon;
  final String label;
  const _NavDestination(this.route, this.icon, this.label);
}

List<_NavDestination> _destinations() => [
  const _NavDestination(AppRoutes.home, Icons.library_books, 'Bibliothèque'),
  const _NavDestination(AppRoutes.recipes, Icons.restaurant_menu, 'Recettes'),
  const _NavDestination(
    AppRoutes.search,
    Icons.manage_search_rounded,
    'Recherche',
  ),
  const _NavDestination(AppRoutes.drafts, Icons.edit_note, 'Brouillons'),
];

int _indexForLocation(String location, List<_NavDestination> destinations) {
  for (var i = 0; i < destinations.length; i++) {
    final route = destinations[i].route;
    // '/' est préfixe de tout — on vérifie l'égalité exacte pour la racine
    final matches = route == '/' ? location == '/' : location.startsWith(route);
    if (matches) return i;
  }
  return -1;
}

enum _AccountAction { profile, groups, admin, tokenUsage, downloadApk, signOut }

class _AccountBadge extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(appUserProvider).value;
    final isAdmin = ref.watch(isAdminProvider);
    if (user == null) return const SizedBox.shrink();

    return PopupMenuButton<_AccountAction>(
      tooltip: user.displayName,
      onSelected: (action) {
        if (action == _AccountAction.profile) {
          context.push(AppRoutes.account);
          return;
        }
        if (action == _AccountAction.groups) {
          context.push(AppRoutes.groups);
          return;
        }
        if (action == _AccountAction.admin) {
          context.push(AppRoutes.admin);
          return;
        }
        if (action == _AccountAction.tokenUsage) {
          context.push(AppRoutes.tokenUsage);
          return;
        }
        if (action == _AccountAction.downloadApk) {
          launchUrl(
            Uri.parse('https://kassdale-6d948.web.app/app-release.apk'),
            // platformDefault ouvre un nouvel onglet sur navigateur web
            // (externalApplication naviguait dans le même onglet et vidait l'app).
            mode: LaunchMode.platformDefault,
          );
          return;
        }
        ref.read(authRepositoryProvider).signOut();
      },
      child: Chip(
        avatar:
            (FirebaseAuth.instance.currentUser?.photoURL ?? user.photoUrl ?? '')
                .isNotEmpty
            ? ClipOval(
                child: CachedNetworkImage(
                  imageUrl:
                      FirebaseAuth.instance.currentUser?.photoURL ??
                      user.photoUrl!,
                  width: 32,
                  height: 32,
                  fit: BoxFit.cover,
                  placeholder: (_, _) => CircleAvatar(
                    child: Text(user.displayName[0].toUpperCase()),
                  ),
                  errorWidget: (_, _, _) => CircleAvatar(
                    child: Text(user.displayName[0].toUpperCase()),
                  ),
                ),
              )
            : CircleAvatar(child: Text(user.displayName[0].toUpperCase())),
        label: Text(user.displayName, overflow: TextOverflow.ellipsis),
      ),
      itemBuilder: (_) => <PopupMenuEntry<_AccountAction>>[
        PopupMenuItem<_AccountAction>(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                user.displayName,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(user.email, style: Theme.of(context).textTheme.bodySmall),
              Text(
                'Rôle : ${user.role.name}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                'v$kAppVersion',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<_AccountAction>(
          value: _AccountAction.profile,
          child: Row(
            children: [
              Icon(Icons.account_circle_outlined),
              SizedBox(width: 8),
              Text('Profil et compte'),
            ],
          ),
        ),
        const PopupMenuItem<_AccountAction>(
          value: _AccountAction.groups,
          child: Row(
            children: [
              Icon(Icons.group_outlined),
              SizedBox(width: 8),
              Text('Groupes familiaux'),
            ],
          ),
        ),
        if (isAdmin)
          const PopupMenuItem<_AccountAction>(
            value: _AccountAction.admin,
            child: Row(
              children: [
                Icon(Icons.admin_panel_settings_outlined),
                SizedBox(width: 8),
                Text('Administration'),
              ],
            ),
          ),
        const PopupMenuItem<_AccountAction>(
          value: _AccountAction.tokenUsage,
          child: Row(
            children: [
              Icon(Icons.analytics_outlined),
              SizedBox(width: 8),
              Text('Usage IA'),
            ],
          ),
        ),
        if (!PlatformUtils.isMobile)
          const PopupMenuItem<_AccountAction>(
            value: _AccountAction.downloadApk,
            child: Row(
              children: [
                Icon(Icons.android),
                SizedBox(width: 8),
                Text('Télécharger l\'APK Android'),
              ],
            ),
          ),
        const PopupMenuItem<_AccountAction>(
          value: _AccountAction.signOut,
          child: Row(
            children: [
              Icon(Icons.logout),
              SizedBox(width: 8),
              Text('Se déconnecter'),
            ],
          ),
        ),
      ],
    );
  }
}

/// Icône Brouillons & Traitements — badge = brouillons en attente + jobs actifs.
class _DraftsIcon extends ConsumerWidget {
  final IconData icon;
  const _DraftsIcon({required this.icon});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drafts = ref.watch(draftsCountProvider);
    final jobs = ref.watch(activeProcessingJobsCountProvider);
    final total = drafts + jobs;
    if (total == 0) return Icon(icon);
    return Badge(label: Text('$total'), child: Icon(icon));
  }
}
