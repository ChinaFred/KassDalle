import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/presentation/auth_providers.dart';
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
    final isAdmin = ref.watch(isAdminProvider);

    final destinations = _destinations(isAdmin);
    final selectedIndex = _indexForLocation(location, destinations);

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
            onDestinationSelected: (i) => context.go(destinations[i].route),
            labelType: NavigationRailLabelType.all,
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Icon(Icons.menu_book_rounded, size: 32),
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
    final isAdmin = ref.watch(isAdminProvider);
    final canEdit = ref.watch(canEditProvider);

    final destinations = _destinations(isAdmin);
    final selectedIndex = _indexForLocation(location, destinations);

    return Scaffold(
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
      floatingActionButton: canEdit && PlatformUtils.hasCameraSupport
          ? FloatingActionButton.extended(
              onPressed: () => context.go('/scan'),
              icon: const Icon(Icons.camera_alt),
              label: const Text('Scanner'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
        onDestinationSelected: (i) => context.go(destinations[i].route),
        destinations: destinations
            .map(
              (d) => NavigationDestination(
                icon: d.route == AppRoutes.drafts
                    ? _DraftsIcon(icon: d.icon)
                    : Icon(d.icon),
                label: d.label,
              ),
            )
            .toList(),
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

List<_NavDestination> _destinations(bool isAdmin) => [
  const _NavDestination(AppRoutes.home, Icons.library_books, 'Bibliothèque'),
  const _NavDestination(AppRoutes.recipes, Icons.restaurant_menu, 'Recettes'),
  const _NavDestination(AppRoutes.drafts, Icons.edit_note, 'Brouillons'),
  if (isAdmin)
    const _NavDestination(AppRoutes.admin, Icons.admin_panel_settings, 'Admin'),
];

int _indexForLocation(String location, List<_NavDestination> destinations) {
  for (var i = 0; i < destinations.length; i++) {
    if (location.startsWith(destinations[i].route)) return i;
  }
  return 0;
}

enum _AccountAction { profile, signOut }

class _AccountBadge extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(appUserProvider).valueOrNull;
    if (user == null) return const SizedBox.shrink();

    return PopupMenuButton<_AccountAction>(
      tooltip: user.displayName,
      onSelected: (action) {
        if (action == _AccountAction.profile) {
          context.push(AppRoutes.account);
          return;
        }
        ref.read(authRepositoryProvider).signOut();
      },
      child: Chip(
        avatar: CircleAvatar(
          backgroundImage: user.photoUrl != null
              ? NetworkImage(user.photoUrl!)
              : null,
          child: user.photoUrl == null
              ? Text(user.displayName[0].toUpperCase())
              : null,
        ),
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

/// Icône Brouillons avec badge si des brouillons sont en attente.
class _DraftsIcon extends ConsumerWidget {
  final IconData icon;
  const _DraftsIcon({required this.icon});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(draftsCountProvider);
    if (count == 0) return Icon(icon);
    return Badge(label: Text('$count'), child: Icon(icon));
  }
}
