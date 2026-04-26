import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

class PlatformUtils {
  PlatformUtils._();

  static bool get isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  static bool get isWeb => kIsWeb;

  static bool get hasCameraSupport => isMobile;

  /// Largeur à partir de laquelle on utilise le layout large (side-by-side)
  static const double wideBreakpoint = 800.0;
}
