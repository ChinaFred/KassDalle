import 'dart:async';
import 'dart:typed_data';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:image_picker/image_picker.dart';

import '../utils/platform_utils.dart';
import 'error_report_service.dart';
import 'error_reporting.dart';

/// Une image prise ou choisie par l'utilisateur, prête à être envoyée.
class CapturedPhoto {
  const CapturedPhoto({required this.bytes, required this.filename});

  final Uint8List bytes;

  /// Nom de fichier avec extension, tel que les envois l'attendent.
  final String filename;
}

/// Une photo à la fois, caméra ou galerie, pour les boutons « Ajouter une
/// photo » : relecture d'un brouillon, détail d'une recette, recette générée,
/// formulaire de livre.
///
/// Sur mobile, la caméra est le scanner du système — ML Kit Document Scanner
/// sur Android, VisionKit sur iOS. Il cherche les coins sur le flux vidéo,
/// montre le cadre à l'utilisateur et rend une image cadrée et redressée.
/// L'appareil photo nu rendait la page de travers, avec la table autour, et
/// l'import de pages passait déjà par le scanner : le même geste donnait deux
/// résultats selon le bouton.
///
/// Ailleurs, `image_picker` ouvre l'appareil photo : aucune de ces API n'existe
/// dans un navigateur ni sur Windows. La galerie reste `image_picker` partout,
/// une photo déjà prise n'ayant pas de flux vidéo à analyser.
///
/// L'import de pages (`scan_upload_service.dart`) garde sa propre chaîne :
/// plusieurs pages par session, noms ordonnés, file d'attente. Ce service ne
/// l'appelle pas, et elle ne l'appelle pas non plus. Les deux partagent le
/// critère de disponibilité, `PlatformUtils.isMobile`.
class PhotoCaptureService {
  PhotoCaptureService({
    ImagePicker? imagePicker,
    ErrorReportService? errorReportService,
  }) : _imagePicker = imagePicker ?? ImagePicker(),
       _errorReportService = errorReportService ?? ErrorReportService();

  final ImagePicker _imagePicker;
  final ErrorReportService _errorReportService;

  /// La plateforme sait-elle numériser un document elle-même ?
  static bool get scannerSystemeDisponible => PlatformUtils.isMobile;

  /// Prend ou choisit une photo. Rend `null` quand l'utilisateur annule.
  ///
  /// [imageQuality] et [maxWidth] ne s'appliquent qu'à `image_picker` : le
  /// scanner du système rend un JPEG à sa résolution, sans réglage exposé.
  ///
  /// Lève l'erreur du greffon — permission refusée, échec du scanner — pour
  /// que l'écran la dise à l'utilisateur.
  Future<CapturedPhoto?> pick({
    required ImageSource source,
    int imageQuality = 100,
    double? maxWidth,
  }) async {
    if (source == ImageSource.camera && scannerSystemeDisponible) {
      return _scanneAvecLeSysteme();
    }
    final photo = await _imagePicker.pickImage(
      source: source,
      preferredCameraDevice: CameraDevice.rear,
      imageQuality: imageQuality,
      maxWidth: maxWidth,
    );
    if (photo == null) return null;
    return CapturedPhoto(
      bytes: await photo.readAsBytes(),
      filename: photo.name.isNotEmpty ? photo.name : _nomParDefaut(),
    );
  }

  Future<CapturedPhoto?> _scanneAvecLeSysteme() async {
    try {
      final chemins = await CunningDocumentScanner.getPictures(
        noOfPages: 1,
        scannerSource: ScannerSource.camera,
      );
      // Annulation : le scanner rend `null` sur les deux plateformes.
      if (chemins == null || chemins.isEmpty) return null;

      // Le fichier vit dans un cache appartenant au greffon, effacé par
      // `cleanCache` : on lit ses octets avant de le lâcher.
      final bytes = await XFile(chemins.first).readAsBytes();
      return CapturedPhoto(bytes: bytes, filename: _nomParDefaut());
    } finally {
      _videLeCacheDuScanner();
    }
  }

  /// Vide le cache du greffon, sans jamais échouer en silence.
  ///
  /// Les fichiers numérisés vivent dans un dossier qui lui appartient. Les
  /// laisser s'accumuler est un coût de stockage que rien n'affiche.
  void _videLeCacheDuScanner() {
    unawaited(
      CunningDocumentScanner.cleanCache().catchError((Object e, StackTrace st) {
        reportUnexpectedError(
          feature: 'photoCapture.scannerCache',
          error: e,
          stackTrace: st,
          service: _errorReportService,
        );
      }),
    );
  }

  static String _nomParDefaut() =>
      'photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
}
