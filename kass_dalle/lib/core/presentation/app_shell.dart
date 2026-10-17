import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/search/presentation/search_providers.dart';
import '../app_version.dart';
import '../services/app_update_service.dart';
import '../services/push_registration_service.dart';
import 'app_update_dialog.dart';
import 'leave_guard.dart';
import '../../features/auth/presentation/auth_providers.dart';
import '../../features/processing/presentation/processing_providers.dart';
import '../../features/recipes/presentation/recipe_providers.dart';
import '../../features/recipes/presentation/url_import/shared_link_import_host.dart';
import '../router/app_router.dart';
import '../utils/platform_utils.dart';
import '../widgets/app_shortcuts.dart';
import '../widgets/readable_width.dart';
import '../../features/groups/presentation/group_providers.dart';
import '../../features/moderation/presentation/moderation_providers.dart';
import '../../features/tickets/presentation/ticket_launcher.dart';
import '../../features/tickets/presentation/tickets_providers.dart';
import '../theme/app_icons.dart';
import 'usage_warning_banner.dart';

class AppShell extends ConsumerStatefulWidget {
  final Widget child;
  const AppShell({super.key, required this.child});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  final AppUpdateService _appUpdateService = AppUpdateService();
  PushRegistrationService? _push;
  String? _registeredUid;

  @override
  void initState() {
    super.initState();
    _checkForUpdate();
    _setUpReleaseNotifications();
  }

  @override
  void dispose() {
    _push?.dispose();
    super.dispose();
  }

  /// Notification de nouvelle version : réservée aux administrateurs, sur
  /// Android. L'appareil s'enregistre quand le rôle `admin` est connu ; un
  /// toucher sur la notification rouvre la fenêtre de mise à jour.
  void _setUpReleaseNotifications() {
    if (!PlatformUtils.isAndroidApp) return;
    final push = _push = PushRegistrationService();
    push.listenForReleaseTaps(_checkForUpdate);
    ref.listenManual(appUserProvider, (_, next) {
      final user = next.value;
      if (user == null) return;
      if (user.isAdmin && _registeredUid != user.uid) {
        _registeredUid = user.uid;
        push.register(user.uid);
      } else if (!user.isAdmin && _registeredUid == user.uid) {
        _registeredUid = null;
        push.unregister(user.uid);
      }
    }, fireImmediately: true);
  }

  Future<void> _checkForUpdate() async {
    // Sur web Android, Chrome gère nativement l'installation PWA via sa
    // mini-bannière "Ajouter à l'écran d'accueil" (beforeinstallprompt sans
    // preventDefault dans index.html). Pas de dialog custom nécessaire.

    // App native Android → vérifier si une mise à jour est disponible.
    // `check` répond null partout ailleurs, le garde ici évite un aller-retour
    // réseau inutile sur le web.
    if (kIsWeb) return;
    final info = await _appUpdateService.check();
    if (info == null || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showAppUpdateDialog(context, info: info, service: _appUpdateService);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;

    // L'écran courant seul, sans la navigation ni le menu du compte : c'est
    // l'image que « Signaler ou proposer » propose de joindre au ticket.
    final child = RepaintBoundary(
      key: ticketShellCaptureKey,
      child: widget.child,
    );

    // Ctrl+K posé au niveau du shell : la recherche est joignable depuis
    // n'importe quel écran, sans que chacun ait à le savoir. Ctrl+S reste
    // local aux écrans d'édition, seuls à savoir ce qu'enregistrer veut dire.
    return AppShortcuts(
      onSearch: () {
        // L'Explorer met le focus dans son champ, qu'il soit déjà affiché ou
        // qu'il s'ouvre.
        ref.read(exploreSearchFocusRequestProvider.notifier).request();
        // Déjà sur l'Explorer : rien à quitter, donc aucune question de
        // sortie à poser sur des idées qui ne seraient pas perdues.
        final location = GoRouter.of(
          context,
        ).routeInformationProvider.value.uri.path;
        if (location == AppRoutes.search) return;
        goGuarded(context, ref, AppRoutes.search);
      },
      // « Partager vers Kass'Dalle » (Android) : la boîte d'import s'ouvre
      // par-dessus l'écran courant.
      child: SharedLinkImportHost(
        child: isWide ? _WideShell(child: child) : _NarrowShell(child: child),
      ),
    );
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
            onDestinationSelected: (i) =>
                goGuarded(context, ref, destinations[i].route),
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
              return NavigationRailDestination(
                icon: _badgedIcon(d),
                selectedIcon: _badgedIcon(d, selected: true),
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
  // Un formulaire, pas un tableau : le shell lui pose `ReadableWidth`.
  if (location.startsWith('/admin/users/invite')) return false;
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
          onDestinationSelected: (i) =>
              goGuarded(context, ref, destinations[i].route),
          // Sans libellé.
          //
          // Ils avaient été affichés parce que cinq icônes muettes se
          // distinguent mal — une boussole, un carnet. Mais les cinq mots se
          // partagent la largeur de l'écran, et à l'échelle de police du
          // système « Bibliothèque » se coupait en deux, la barre montant sur
          // deux lignes en rognant le contenu.
          //
          // Le nom reste accessible par un appui long, sur chaque icône.
          labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
          destinations: destinations
              .map(
                (d) => NavigationDestination(
                  icon: _badgedIcon(d),
                  selectedIcon: _badgedIcon(d, selected: true),
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

/// Une destination de la navigation.
///
/// Deux icônes, pas une : le contour pour les destinations où l'on n'est pas,
/// le plein pour celle où l'on est. C'est la convention Material, et c'est
/// surtout le seul repère qui reste quand la barre est étroite.
class _NavDestination {
  final String route;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const _NavDestination(this.route, this.icon, this.selectedIcon, this.label);
}

List<_NavDestination> _destinations({required bool isAdmin}) => [
  const _NavDestination(
    AppRoutes.home,
    Icons.library_books_outlined,
    Icons.library_books_outlined,
    'Bibliothèque',
  ),
  const _NavDestination(
    AppRoutes.search,
    Icons.explore_outlined,
    Icons.explore,
    'Explorer',
  ),
  const _NavDestination(
    AppRoutes.planning,
    Icons.calendar_month_outlined,
    Icons.calendar_month_outlined,
    'Planning',
  ),
  const _NavDestination(
    AppRoutes.drafts,
    Icons.edit_note_outlined,
    Icons.edit_note_outlined,
    'Brouillons',
  ),
  if (isAdmin)
    const _NavDestination(
      AppRoutes.admin,
      Icons.admin_panel_settings_outlined,
      Icons.admin_panel_settings,
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

enum _AccountAction {
  profile,
  preferences,
  groups,
  newTicket,
  myTickets,
  adminTickets,
  releaseNotes,
  signOut,
}

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
        if (action == _AccountAction.preferences) {
          context.push(AppRoutes.preferences);
          return;
        }
        if (action == _AccountAction.groups) {
          context.push(AppRoutes.groups);
          return;
        }
        if (action == _AccountAction.newTicket) {
          openTicketForm(context, ref);
          return;
        }
        if (action == _AccountAction.myTickets) {
          context.push(AppRoutes.tickets);
          return;
        }
        if (action == _AccountAction.adminTickets) {
          ref.read(adminTicketStatusFilterProvider.notifier).enterToProcess();
          context.push(AppRoutes.adminTickets);
          return;
        }
        if (action == _AccountAction.releaseNotes) {
          context.push(AppRoutes.releaseNotes);
          return;
        }
        ref.read(authRepositoryProvider).signOut();
      },
      child: _AccountDot(
        child: Chip(
          avatar:
              (FirebaseAuth.instance.currentUser?.photoURL ??
                      user.photoUrl ??
                      '')
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
          value: _AccountAction.preferences,
          child: Row(
            children: [
              Icon(Icons.tune_outlined),
              SizedBox(width: 8),
              Text('Préférences'),
            ],
          ),
        ),
        const PopupMenuItem<_AccountAction>(
          value: _AccountAction.groups,
          child: Row(
            children: [
              _GroupsIcon(),
              SizedBox(width: 8),
              Text('Groupes familiaux'),
            ],
          ),
        ),
        const PopupMenuItem<_AccountAction>(
          value: _AccountAction.newTicket,
          child: Row(
            children: [
              Icon(AppIcons.ticketNew),
              SizedBox(width: 8),
              Text('Signaler ou proposer'),
            ],
          ),
        ),
        const PopupMenuItem<_AccountAction>(
          value: _AccountAction.myTickets,
          child: Row(
            children: [
              _MyTicketsIcon(),
              SizedBox(width: 8),
              Text('Mes tickets'),
            ],
          ),
        ),
        if (user.isAdmin)
          const PopupMenuItem<_AccountAction>(
            value: _AccountAction.adminTickets,
            child: Row(
              children: [
                _AdminTicketsIcon(),
                SizedBox(width: 8),
                _AdminTicketsLabel(),
              ],
            ),
          ),
        const PopupMenuItem<_AccountAction>(
          value: _AccountAction.releaseNotes,
          child: Row(
            children: [
              Icon(Icons.new_releases_outlined),
              SizedBox(width: 8),
              Text('Nouveautés'),
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
///
/// `selected` sert à badger aussi la variante pleine : sans lui, le compteur
/// disparaîtrait précisément quand on ouvre l'écran qui le porte.
Widget _badgedIcon(_NavDestination d, {bool selected = false}) {
  final icon = selected ? d.selectedIcon : d.icon;
  if (d.route == AppRoutes.drafts) return _DraftsIcon(icon: icon);
  if (d.route == AppRoutes.admin) return _AdminIcon(icon: icon);
  return Icon(icon);
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

/// Pastille chiffrée sur le compte : invitations de groupe en attente, plus
/// les tickets avec un suivi non lu ou, pour l'administrateur, à traiter
/// (Reçu, Analysé ou Validé) et eux seuls. `99+` au-delà de 99, rien à zéro.
///
/// Les Groupes et « Mes tickets » ne s'ouvrent que par le menu du compte :
/// sans ce signal, un invité ne trouverait pas son invitation, et un membre
/// ne saurait pas que l'administrateur lui a répondu.
class _AccountDot extends ConsumerWidget {
  final Widget child;
  const _AccountDot({required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invitations = ref.watch(pendingInvitationsCountProvider);
    final tickets = ref.watch(accountTicketsBadgeCountProvider);
    final isAdmin = ref.watch(isAdminProvider);
    final total = invitations + tickets;
    if (total == 0) return child;
    return Semantics(
      label:
          '$total élément(s) en attente : '
          '${[if (invitations > 0) '$invitations invitation(s)', if (tickets > 0) '$tickets ticket(s)${isAdmin ? ' à traiter' : ''}'].join(', ')}',
      child: Badge(label: Text(total > 99 ? '99+' : '$total'), child: child),
    );
  }
}

/// Icône « Tickets à traiter » du menu compte (administrateur) — badge =
/// tickets Reçus, Analysés ou Validés.
class _AdminTicketsIcon extends ConsumerWidget {
  const _AdminTicketsIcon();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(adminTicketsToProcessCountProvider).value ?? 0;
    if (count == 0) return const Icon(AppIcons.ticketsToProcess);
    return Semantics(
      label: '$count ticket(s) de membres à traiter',
      child: Badge(
        label: Text('$count'),
        child: const Icon(AppIcons.ticketsToProcess),
      ),
    );
  }
}

/// « Tickets à traiter » du menu compte (administrateur) ; le nombre est sur
/// la pastille de l'icône.
class _AdminTicketsLabel extends StatelessWidget {
  const _AdminTicketsLabel();

  @override
  Widget build(BuildContext context) {
    return const Text('Tickets à traiter');
  }
}

/// Icône « Mes tickets » du menu compte — badge = tickets à lire.
class _MyTicketsIcon extends ConsumerWidget {
  const _MyTicketsIcon();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unseen = ref.watch(unseenTicketsCountProvider);
    if (unseen == 0) return const Icon(AppIcons.tickets);
    return Semantics(
      label: '$unseen ticket(s) avec un nouveau suivi',
      child: Badge(label: Text('$unseen'), child: const Icon(AppIcons.tickets)),
    );
  }
}

/// Icône « Groupes familiaux » du menu compte — badge = invitations reçues.
class _GroupsIcon extends ConsumerWidget {
  const _GroupsIcon();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingInvitationsCountProvider);
    if (pending == 0) return const Icon(Icons.group_outlined);
    return Semantics(
      label: '$pending invitation(s) de groupe en attente',
      child: Badge(
        label: Text('$pending'),
        child: const Icon(Icons.group_outlined),
      ),
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
