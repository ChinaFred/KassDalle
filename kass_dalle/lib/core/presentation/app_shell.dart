import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_version.dart';
import '../services/app_update_service.dart';
import '../../features/auth/presentation/auth_providers.dart';
import '../../features/processing/presentation/processing_providers.dart';
import '../../features/recipes/presentation/recipe_providers.dart';
import '../router/app_router.dart';
import '../utils/platform_utils.dart';
import 'usage_warning_banner.dart';

class AppShell extends ConsumerStatefulWidget {
  final Widget child;
  const AppShell({super.key, required this.child});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  void initState() {
    super.initState();
    _checkForUpdate();
  }

  Future<void> _checkForUpdate() async {
    // Cas 1 : web ouvert sur Android → proposer l'installation de l'app native
    if (kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog<void>(
          context: context,
          builder: (_) => const _ApkInstallDialog(),
        );
      });
      return;
    }

    // Cas 2 : app native Android → vérifier si une mise à jour est disponible
    final info = await checkForAppUpdate();
    if (info == null || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => _AppUpdateDialog(info: info),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final isWide =
        MediaQuery.of(context).size.width >= PlatformUtils.wideBreakpoint;

    return isWide ? _WideShell(child: widget.child) : _NarrowShell(child: widget.child);
  }
}

// ── Dialog : installation APK (web sur Android) ─────────────────────────────

class _ApkInstallDialog extends StatelessWidget {
  const _ApkInstallDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.android, size: 40, color: Color(0xFF3DDC84)),
      title: const Text('Application Android disponible'),
      content: const Text(
        'Une application native Kass\'Dalle est disponible pour Android.\n'
        'Elle offre une meilleure expérience : caméra, scan de recettes, accès hors-ligne…',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Continuer sur le web'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.download_outlined),
          label: const Text('Installer'),
          onPressed: () async {
            Navigator.of(context).pop();
            await launchUrl(
              Uri.parse(kApkDownloadUrl),
              mode: LaunchMode.externalApplication,
            );
          },
        ),
      ],
    );
  }
}

// ── Dialog : mise à jour disponible (app native Android) ─────────────────────

class _AppUpdateDialog extends StatefulWidget {
  final AppUpdateInfo info;
  const _AppUpdateDialog({required this.info});

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<_AppUpdateDialog> {
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.system_update_outlined, size: 40),
      title: const Text('Mise à jour disponible'),
      content: Text(
        'La version ${widget.info.latestVersion} est disponible.\n'
        'Vous utilisez actuellement la version $kAppVersion.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Plus tard'),
        ),
        FilledButton.icon(
          icon: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.download_outlined),
          label: Text(_loading ? 'Ouverture…' : 'Mettre à jour'),
          onPressed: _loading ? null : _download,
        ),
      ],
    );
  }

  Future<void> _download() async {
    setState(() => _loading = true);
    try {
      await launchUrl(
        Uri.parse(widget.info.apkUrl),
        mode: LaunchMode.externalApplication,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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

    final destinations = _destinations(isAdmin: isAdmin);
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
    final isAdmin = ref.watch(isAdminProvider);

    final destinations = _destinations(isAdmin: isAdmin);
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

List<_NavDestination> _destinations({required bool isAdmin}) => [
  const _NavDestination(AppRoutes.home, Icons.library_books, 'Bibliothèque'),
  const _NavDestination(AppRoutes.search, Icons.explore_outlined, 'Explorer'),
  const _NavDestination(
    AppRoutes.planning,
    Icons.calendar_month_outlined,
    'Planning',
  ),
  const _NavDestination(AppRoutes.drafts, Icons.edit_note, 'Brouillons'),
  if (isAdmin)
    const _NavDestination(
      AppRoutes.admin,
      Icons.admin_panel_settings_outlined,
      'Admin',
    ),
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

enum _AccountAction { profile, groups, signOut }

class _AccountBadge extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(appUserProvider).value;
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
