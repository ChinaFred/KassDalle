import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'error_reporting.dart';

/// Applique — ou relâche — le maintien de l'écran auprès de la plateforme.
///
/// Injectable pour les tests : le comptage se vérifie sans plugin ni binding.
typedef WakelockToggle = Future<void> Function({required bool enable});

/// Maintient l'écran allumé tant qu'au moins un écran le demande.
///
/// On cuisine les mains occupées : la fiche reste affichée sans qu'on la
/// touche, et l'écran s'éteint au milieu d'une étape — au moment précis où on
/// ne peut pas le rallumer.
///
/// Le maintien est **compté**, pas booléen : deux écrans superposés — une
/// recette ouverte depuis une autre — le demandent chacun, et le premier
/// refermé ne doit pas éteindre l'écran de celui qui reste. Le verrou ne tombe
/// qu'au dernier départ.
class ScreenWakelock {
  ScreenWakelock({WakelockToggle? toggle})
    : _toggle = toggle ?? WakelockPlus.toggle;

  /// Instance partagée : le compteur n'a de sens que s'il est unique.
  static final ScreenWakelock instance = ScreenWakelock();

  final WakelockToggle _toggle;
  int _holders = 0;
  bool _failureReported = false;

  /// Nombre d'écrans demandant le maintien. Exposé pour les tests.
  @visibleForTesting
  int get holders => _holders;

  Future<void> acquire() async {
    _holders++;
    if (_holders == 1) await _apply(true);
  }

  Future<void> release() async {
    if (_holders == 0) return;
    _holders--;
    if (_holders == 0) await _apply(false);
  }

  /// Réapplique le verrou au retour d'arrière-plan.
  ///
  /// Les navigateurs et Android le relâchent dès que la page ou l'application
  /// passe en fond, sans jamais le rendre : sans cette reprise, revenir à la
  /// recette après un appel laisse l'écran s'éteindre comme si personne ne le
  /// tenait.
  Future<void> refresh() async {
    if (_holders > 0) await _apply(true);
  }

  Future<void> _apply(bool enable) async {
    try {
      await _toggle(enable: enable);
    } catch (error, stackTrace) {
      // Une seule remontée par session. L'échec vient de la plateforme — API
      // absente, onglet en arrière-plan, refus du navigateur — et se
      // reproduirait à chaque ouverture de recette : cent rapports identiques
      // n'apprennent rien de plus que le premier et noient les autres.
      if (_failureReported) return;
      _failureReported = true;
      reportUnexpectedError(
        feature: 'screenWakelock.apply',
        error: error,
        stackTrace: stackTrace,
        context: {'enable': enable, 'holders': _holders},
      );
    }
  }
}

/// Garde l'écran allumé tant que l'écran qui mixe ceci est monté.
///
/// À mixer sur l'état d'un écran de lecture. Le verrou est pris à la
/// construction, rendu à la destruction, et repris au retour d'arrière-plan.
mixin KeepScreenAwake<T extends StatefulWidget> on State<T> {
  /// Surchargeable en test pour observer les prises sans toucher la plateforme.
  @visibleForTesting
  ScreenWakelock get wakelock => ScreenWakelock.instance;

  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    unawaited(wakelock.acquire());
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(wakelock.refresh()),
    );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    unawaited(wakelock.release());
    super.dispose();
  }
}
