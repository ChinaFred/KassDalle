import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_version.dart';
import '../services/error_report_service.dart';
import '../services/app_update_service.dart';
import '../../features/auth/presentation/auth_providers.dart';
import '../../features/processing/presentation/processing_providers.dart';
import '../../features/recipes/presentation/recipe_providers.dart';
import '../router/app_router.dart';
import '../utils/platform_utils.dart';
import '../widgets/app_shortcuts.dart';
import '../widgets/readable_width.dart';
import '../../features/moderation/presentation/moderation_providers.dart';
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
    // Sur web Android, Chrome gère nativement l'installation PWA via sa
    // mini-bannière "Ajouter à l'écran d'accueil" (beforeinstallprompt sans
    // preventDefault dans index.html). Pas de dialog custom nécessaire.

    // App native Android → vérifier si une mise à jour est disponible
    if (kIsWeb) return;
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
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;

    // Ctrl+K posé au niveau du shell : la recherche est joignable depuis
    // n'importe quel écran, sans que chacun ait à le savoir. Ctrl+S reste
    // local aux écrans d'édition, seuls à savoir ce qu'enregistrer veut dire.
    return AppShortcuts(
      onSearch: () => context.go(AppRoutes.search),
      child: isWide
          ? _WideShell(child: widget.child)
          : _NarrowShell(child: widget.child),
    );
  }
}

// ── Dialog : mise à jour disponible (app native Android) ─────────────────────

// ── Dialog : mise à jour disponible (app native Android) ─────────────────────

class _AppUpdateDialog extends StatefulWidget {
  final AppUpdateInfo info;
  const _AppUpdateDialog({required this.info});

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<_AppUpdateDialog> {
  bool _loading = false;
  final ErrorReportService _errorReportService = ErrorReportService();

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
    } catch (e, st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'app_update_download',
          error: e,
          stackTrace: st,
          context: {'apk_url': widget.info.apkUrl},
        ),
      );
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
              // Décoratif : le nom de l'application est déjà partout ailleurs.
              // Un logo annoncé à chaque ouverture de la navigation est du
              // bruit pour qui écoute l'écran.
              child: const ExcludeSemantics(
                child: Image(
                  image: AssetImage('assets/Icon.png'),
                  width: 48,
                  height: 48,
                ),
              ),
            ),
            destinations: destinations.map((d) {
              final icon = _badgedIcon(d);
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
                Expanded(
                  child: _wantsFullWidth(location)
                      ? child
                      : ReadableWidth(child: child),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Écrans qui ont besoin de toute la largeur : ce sont des tableaux.
///
/// Borner la lecture sert la prose d'une recette ; ça dessert un journal de
/// logs ou une réconciliation comptable, où chaque pixel est une colonne.
bool _wantsFullWidth(String location) {
  const fullWidthPrefixes = [
    '/admin',
    '/logs',
    '/token-usage',
    '/error-reports',
    '/dead-letters',
    '/planning/batch',
  ];
  return fullWidthPrefixes.any(location.startsWith);
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
    final isOnRootDestination = _isOnRootDestination(location, destinations);

    return PopScope(
      canPop: isOnRootDestination,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;

        final router = GoRouter.of(context);
        if (router.canPop()) {
          router.pop();
          return;
        }

        if (!isOnRootDestination) {
          context.go(AppRoutes.home);
        }
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
                  icon: _badgedIcon(d),
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

bool _isOnRootDestination(String location, List<_NavDestination> destinations) {
  for (final d in destinations) {
    if (location == d.route) return true;
  }
  return false;
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

/// Icône d'une destination, badgée quand elle porte une file d'attente.
///
/// Deux barres de navigation affichent les mêmes destinations : la règle ne
/// peut pas vivre en double, sans quoi un badge finirait par n'apparaître que
/// sur l'une des deux.
Widget _badgedIcon(_NavDestination d) {
  if (d.route == AppRoutes.drafts) return _DraftsIcon(icon: d.icon);
  if (d.route == AppRoutes.admin) return _AdminIcon(icon: d.icon);
  return Icon(d.icon);
}

/// Icône Administration — badge = images en attente de décision.
///
/// Personne n'ouvre une file d'attente pour vérifier qu'elle est vide. Sans ce
/// badge, une image en attente y resterait des semaines, et la modération
/// deviendrait une suppression lente.
class _AdminIcon extends ConsumerWidget {
  final IconData icon;
  const _AdminIcon({required this.icon});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingModerationCountProvider).value ?? 0;
    if (pending == 0) return Icon(icon);
    return Semantics(
      label: '$pending image(s) en attente de modération',
      child: Badge(label: Text('$pending'), child: Icon(icon)),
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
    // Le badge se lit d'un coup d'œil ; à l'oreille, « 3 » seul ne dit rien.
    return Semantics(
      label: '$total élément(s) en attente',
      child: Badge(label: Text('$total'), child: Icon(icon)),
    );
  }
}
