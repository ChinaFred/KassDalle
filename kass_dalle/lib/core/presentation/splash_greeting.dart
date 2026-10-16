import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../features/auth/presentation/auth_providers.dart';
import '../utils/platform_utils.dart';

/// Durée minimale d'affichage de l'écran de démarrage.
const kSplashMinDuration = Duration(seconds: 5);

/// Plafond d'attente du profil : au-delà, l'écran affiche la formule sans prénom.
const kSplashMaxDuration = Duration(seconds: 10);

/// Formules d'accueil de chaque tranche horaire. Chaque entrée reçoit le nom
/// affiché, ou `null` quand le profil n'est pas lu.
typedef GreetingVariant = String Function(String? name);

String _withName(String lead, String? name, {String tail = ''}) =>
    name == null ? '$lead$tail' : '$lead, $name$tail';

/// Matin (5 h à 11 h 59).
final List<GreetingVariant> kSplashMorningGreetings = [
  (name) => name == null ? 'Bonjour' : 'Bonjour $name',
  (name) => _withName('Belle matinée', name),
  (name) => _withName('Bien réveillé', name, tail: ' ?'),
];

/// Après-midi (12 h à 17 h 59).
final List<GreetingVariant> kSplashAfternoonGreetings = [
  (name) => name == null ? 'Bon après-midi' : 'Bon après-midi $name',
  (name) => _withName('Content de te revoir', name),
  (name) => _withName("Les casseroles t'attendent", name),
];

/// Soir et nuit (18 h à 4 h 59).
final List<GreetingVariant> kSplashEveningGreetings = [
  (name) => name == null ? 'Bonsoir' : 'Bonsoir $name',
  (name) => _withName('Bonne soirée', name),
  (name) => _withName("C'est l'heure du dîner", name, tail: ' ?'),
];

/// Formules de la tranche horaire de [now].
List<GreetingVariant> splashGreetingsFor(DateTime now) {
  if (now.hour >= 5 && now.hour < 12) return kSplashMorningGreetings;
  if (now.hour >= 12 && now.hour < 18) return kSplashAfternoonGreetings;
  return kSplashEveningGreetings;
}

/// Écran de démarrage (formule selon l'heure, prénom, date et heure), posé en calque au-dessus du
/// routeur (aucune route, donc aucune redirection ni lien profond perturbé).
///
/// S'affiche une fois par lancement à froid : l'état vit dans ce widget, qui
/// n'est construit qu'une fois. Un appui le ferme avant la fin des 5 secondes.
class SplashGreeting extends ConsumerStatefulWidget {
  const SplashGreeting({
    super.key,
    required this.child,
    this.now = DateTime.now,
    this.random,
  });

  final Widget child;

  /// Horloge, injectable pour les tests.
  final DateTime Function() now;

  /// Tirage de la variante, injectable pour les tests.
  final Random? random;

  @override
  ConsumerState<SplashGreeting> createState() => _SplashGreetingState();
}

class _SplashGreetingState extends ConsumerState<SplashGreeting> {
  Timer? _minTimer;
  Timer? _maxTimer;
  bool _minElapsed = false;
  bool _maxElapsed = false;
  bool _dismissed = false;
  late final DateTime _openedAt;
  late final int _variantPick;

  @override
  void initState() {
    super.initState();
    // Heure et variante sont fixées au lancement : elles ne bougent plus
    // pendant l'affichage.
    _openedAt = widget.now();
    _variantPick = (widget.random ?? Random()).nextInt(1 << 16);
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
    final variants = splashGreetingsFor(_openedAt);
    final greeting = variants[_variantPick % variants.length](
      showName ? user.displayedName : null,
    );

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
                    greeting: showGreeting ? greeting : null,
                    dateLine: DateFormat(
                      "EEEE d MMMM y '·' HH:mm",
                      'fr',
                    ).format(_openedAt),
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
  const _SplashBody({
    super.key,
    required this.greeting,
    required this.dateLine,
    required this.onTap,
  });

  final String? greeting;
  final String dateLine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= PlatformUtils.wideBreakpoint;
    final fontSize = wide ? 32.0 : 22.0;
    final dateFontSize = wide ? 20.0 : 16.0;
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FittedBox(
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
                      const SizedBox(height: 8),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          dateLine,
                          maxLines: 1,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontSize: dateFontSize,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
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
