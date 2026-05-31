import 'dart:typed_data';

import 'package:printing/printing.dart';

/// Implémentation non-web : share sheet / dialogue d'impression natif.
Future<void> downloadPdf(Uint8List bytes, String filename) =>
    Printing.sharePdf(bytes: bytes, filename: filename);
