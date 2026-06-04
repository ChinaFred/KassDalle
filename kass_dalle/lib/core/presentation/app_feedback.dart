import 'package:flutter/material.dart';

/// Global messenger key to display feedback across route changes.
final GlobalKey<ScaffoldMessengerState> appScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void showAppSnackBar(SnackBar snackBar) {
  final state = appScaffoldMessengerKey.currentState;
  if (state == null) return;
  state
    ..hideCurrentSnackBar()
    ..showSnackBar(snackBar);
}
