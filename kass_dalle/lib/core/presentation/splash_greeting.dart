import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/presentation/auth_providers.dart';
import '../utils/platform_utils.dart';

/// Durée minimale d'affichage de l'écran de démarrage.
const kSplashMinDuration = Duration(seconds: 5);

/// Plafond d'attente du profil : au-delà, l'écran affiche « Bonjour » seul.
const kSplashMaxDuration = Duration(seconds: 10);

/// Écran de démarrage « Bonjour {prénom} », posé en calque au-dessus du
/// routeur (aucune route, donc aucune redirection ni lien profond perturbé).
///
/// S'affiche une fois par lancement à froid : l'état vit dans ce widget, qui
/// n'est construit qu'une fois. Un appui le ferme avant la fin des 5 secondes.
class SplashGreeting extends ConsumerStatefulWidget {
  const SplashGreeting({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SplashGreeting> createState() => _SplashGreetingState();
}

class _SplashGreetingState extends ConsumerState<SplashGreeting> {
  Timer? _minTimer;
  Timer? _maxTimer;
  bool _minElapsed = false;
  bool _maxElapsed = false;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _minTimer = Timer(kSplashMinDuration, () {
      if (mounted) setState(() => _minElapsed = true);
    });
    _maxTimer = Timer(kSplashMaxDuration, () {
      if (mounted) setState(() => _maxElapsed = true);
    });
  }

  @override
  void dispose() {
    _minTimer?.cancel();
    _maxTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(firebaseAuthStateProvider);
    final appUser = ref.watch(appUserProvider);

    // Le profil est prêt quand la session est connue et, pour un compte
    // connecté, quand son document est lu. Une lecture en erreur compte comme
    // terminée : l'erreur est rapportée par le dépôt, l'écran dit « Bonjour ».
    final user = appUser.value;
    final sessionKnown = authState.hasValue || authState.hasError;
    final signedOut = authState.hasValue && authState.value == null;
    final ready =
        sessionKnown && (signedOut || user != null || appUser.hasError);
    final showName = ready && user != null;
    final showGreeting = ready || _maxElapsed;

    final visible = !_dismissed && !(_maxElapsed || (_minElapsed && ready));

    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        Positioned.fill(
          child: ExcludeFocus(
            excluding: visible,
            child: ExcludeSemantics(excluding: visible, child: widget.child),
          ),
        ),
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 250),
            child: visible
                ? _SplashBody(
                    key: const ValueKey('splash'),
                    greeting: showGreeting
                        ? (showName
                              ? 'Bonjour ${user.displayedName}'
                              : 'Bonjour')
                        : null,
                    onTap: () => setState(() => _dismissed = true),
                  )
                : const SizedBox.shrink(key: ValueKey('gone')),
          ),
        ),
      ],
    );
  }
}

class _SplashBody extends StatelessWidget {
  const _SplashBody({super.key, required this.greeting, required this.onTap});

  final String? greeting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final fontSize = width >= PlatformUtils.wideBreakpoint ? 32.0 : 22.0;
    final content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/Icon.png',
                width: 72,
                height: 72,
                semanticLabel: "Kass'Dalle",
              ),
              const SizedBox(height: 20),
              if (greeting == null)
                SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: theme.colorScheme.primary,
                  ),
                )
              else
                Semantics(
                  liveRegion: true,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      greeting!,
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontSize: fontSize,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return Semantics(
      container: true,
      button: true,
      label: "Fermer l'écran de bienvenue",
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): onTap,
          const SingleActivator(LogicalKeyboardKey.enter): onTap,
        },
        child: Material(
          color: theme.scaffoldBackgroundColor,
          child: InkWell(autofocus: true, onTap: onTap, child: content),
        ),
      ),
    );
  }
}
