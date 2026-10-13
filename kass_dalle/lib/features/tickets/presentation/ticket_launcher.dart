import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/error_reporting.dart';
import '../domain/ticket_form.dart';
import 'tickets_providers.dart';

/// Clé du `RepaintBoundary` que le shell pose autour de l'écran courant.
///
/// Elle borne l'image à l'écran lui-même : ni la barre de navigation, ni le
/// menu du compte, ni une boîte de dialogue — qui vivent hors de cette
/// limite — n'y figurent.
final ticketShellCaptureKey = GlobalKey(debugLabel: 'ticketShellCapture');

/// Plus grand côté de l'image, en pixels. Au-delà, une capture de bureau en
/// PNG dépasse les 5 Mo que les règles Storage acceptent.
const _kCaptureMaxSide = 2000.0;

/// Paramètre de `/tickets/new` qui porte le modèle de route de l'écran
/// quitté.
const kTicketScreenQueryParam = 'ecran';

/// Ouvre « Signaler ou proposer » depuis le menu du compte.
///
/// Lit le **modèle** de la route courante (`/recipes/:recipeId`), jamais son
/// adresse ni sa requête, et prend une image de l'écran si la plateforme le
/// permet. L'image attend le formulaire dans [pendingTicketCaptureProvider] ;
/// la case qui la joint est décochée par défaut.
Future<void> openTicketForm(BuildContext context, WidgetRef ref) async {
  final router = GoRouter.of(context);
  final pattern = router.state.fullPath;
  final capture = await captureTicketScreen();
  ref.read(pendingTicketCaptureProvider.notifier).set(capture);
  router.push(ticketFormLocation(pattern));
}

/// Adresse du formulaire pour le modèle de route [routePattern].
String ticketFormLocation(String? routePattern) {
  if (routePattern == null || routePattern.isEmpty) {
    return AppRoutes.ticketNew;
  }
  return Uri(
    path: AppRoutes.ticketNew,
    queryParameters: {kTicketScreenQueryParam: routePattern},
  ).toString();
}

/// Image PNG de l'écran courant, ou `null` si elle ne peut pas être prise.
///
/// Une capture impossible n'empêche pas le ticket : le formulaire propose
/// alors de choisir une image.
Future<Uint8List?> captureTicketScreen() async {
  final context = ticketShellCaptureKey.currentContext;
  if (context == null) return null;
  try {
    final boundary = context.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) return null;
    final size = boundary.size;
    final longest = math.max(size.width, size.height);
    if (longest <= 0) return null;
    final ratio = math.min(
      math.min(MediaQuery.devicePixelRatioOf(context), 2.0),
      _kCaptureMaxSide / longest,
    );
    final image = await boundary.toImage(pixelRatio: ratio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      final bytes = data.buffer.asUint8List();
      return bytes.length > kTicketScreenshotMaxBytes ? null : bytes;
    } finally {
      image.dispose();
    }
  } catch (e, st) {
    reportUnexpectedError(
      feature: 'tickets',
      error: e,
      stackTrace: st,
      context: {'step': 'capture_screen'},
    );
    return null;
  }
}
