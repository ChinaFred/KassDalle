import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Raccourcis clavier.
///
/// Les seuls `FocusNode` du projet servaient les champs de saisie : rien pour
/// Ctrl+S en édition, Ctrl+K vers la recherche, Échap pour fermer. Sur desktop
/// et sur le web, c'est le signe le plus net qu'une application est un portage
/// mobile — on l'utilise à la souris parce qu'il n'y a rien d'autre.
///
/// Sur mobile ces raccourcis n'existent pas, mais rien n'y coûte : sans clavier
/// physique, aucune de ces intentions n'est jamais émise.

// ── Intentions ───────────────────────────────────────────────────────────────

/// Enregistrer le travail en cours (Ctrl/Cmd + S).
class SaveIntent extends Intent {
  const SaveIntent();
}

/// Ouvrir la recherche (Ctrl/Cmd + K).
class SearchIntent extends Intent {
  const SearchIntent();
}

// ── Câblage ──────────────────────────────────────────────────────────────────

/// Pose les raccourcis d'application autour de [child].
///
/// Chaque action est facultative : un écran ne déclare que ce qu'il sait faire.
/// Un raccourci sans action ne fait rien plutôt que d'échouer — mieux vaut un
/// Ctrl+S sans effet sur un écran de lecture qu'un plantage.
///
/// `Échap` n'est pas déclaré ici : Flutter le câble déjà sur
/// `DismissIntent` pour les dialogues et les feuilles modales. Le redéclarer
/// aurait masqué ce comportement natif.
class AppShortcuts extends StatelessWidget {
  final Widget child;
  final VoidCallback? onSave;
  final VoidCallback? onSearch;

  const AppShortcuts({
    super.key,
    required this.child,
    this.onSave,
    this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        // `control` et `meta` déclarés séparément : un raccourci Windows/Linux
        // et son équivalent macOS ne sont pas le même activateur.
        SingleActivator(LogicalKeyboardKey.keyS, control: true): SaveIntent(),
        SingleActivator(LogicalKeyboardKey.keyS, meta: true): SaveIntent(),
        SingleActivator(LogicalKeyboardKey.keyK, control: true): SearchIntent(),
        SingleActivator(LogicalKeyboardKey.keyK, meta: true): SearchIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          SaveIntent: CallbackAction<SaveIntent>(
            onInvoke: (_) {
              onSave?.call();
              return null;
            },
          ),
          SearchIntent: CallbackAction<SearchIntent>(
            onInvoke: (_) {
              onSearch?.call();
              return null;
            },
          ),
        },
        // Sans ce Focus, aucun raccourci ne part tant que l'utilisateur n'a pas
        // cliqué dans un champ : les activateurs remontent depuis le nœud
        // focalisé, et un écran fraîchement ouvert n'en a aucun.
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}
