import 'package:flutter/material.dart';

/// Clé du [ScaffoldMessenger] racine, posée sur le [MaterialApp].
///
/// Elle sert à ce qu'un message survive un changement de route : le messager
/// vit au-dessus du routeur, pas dans l'écran qui l'a déclenché.
///
/// Il y avait ici une seconde fonction, `showAppSnackBar(SnackBar)`, qui
/// masquait le message courant avant d'afficher le suivant. Aucun appelant :
/// tout le code passe par l'extension `context.showSnackBar` de
/// `core/utils/context_extensions.dart`, qui est le chemin unique. Deux API
/// pour la même chose, dont une morte, c'était une invitation à diverger.
final GlobalKey<ScaffoldMessengerState> appScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
