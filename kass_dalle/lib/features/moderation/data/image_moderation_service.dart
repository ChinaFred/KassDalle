import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../../../core/services/error_report_service.dart';
import '../domain/moderation_labels.dart';

/// Destination d'une image, telle que l'attend le serveur.
enum ModerationTarget {
  bookCover('book_cover'),
  recipeIllustration('recipe_illustration'),
  draftIllustration('draft_illustration'),
  freeRecipeCover('free_recipe_cover');

  final String wire;
  const ModerationTarget(this.wire);
}

/// Origine déclarée d'une image — une indication, jamais une décision.
///
/// Le serveur ne croit pas cette valeur (`functions/src/moderation/origin.ts`,
/// v0.23.8) : `ai` venant d'un client est analysé comme une image
/// d'utilisateur, et `asset` n'est dispensé d'analyse que si l'empreinte du
/// fichier est celle d'une couverture livrée avec l'application. Toutes les
/// images passent par le même chemin — c'est ce qui permet de fermer les
/// dossiers publiés en écriture.
enum ModerationOrigin {
  user('user'),
  ai('ai'),
  asset('asset');

  final String wire;
  const ModerationOrigin(this.wire);
}

/// Issue d'une demande de publication.
class ModerationOutcome {
  final String moderationId;
  final String status;
  final String reason;
  final String? url;

  const ModerationOutcome({
    required this.moderationId,
    required this.status,
    required this.reason,
    required this.url,
  });

  /// Publiée : l'URL est disponible et l'appelant peut l'enregistrer.
  bool get isPublished => status == 'approved' && url != null;

  /// En attente d'un administrateur, ou d'une relance du moteur.
  bool get isHeld => status == 'manual_review' || status == 'pending';

  bool get isRejected => status == 'rejected';

  factory ModerationOutcome.fromMap(Map<Object?, Object?> raw) {
    return ModerationOutcome(
      moderationId: (raw['moderationId'] ?? '').toString(),
      status: (raw['status'] ?? '').toString(),
      reason: (raw['reason'] ?? '').toString(),
      url: raw['url'] as String?,
    );
  }
}

/// Une image à publier.
class PendingImage {
  final Uint8List bytes;
  final String filename;
  final String contentType;
  final ModerationTarget target;
  final String? ownerId;
  final ModerationOrigin origin;

  const PendingImage({
    required this.bytes,
    required this.filename,
    required this.contentType,
    required this.target,
    this.ownerId,
    this.origin = ModerationOrigin.user,
  });
}

/// Levée quand une image n'a pas pu être publiée.
///
/// Porte le statut et le motif : l'écran doit pouvoir dire « en attente » et
/// « refusée » différemment, faute de quoi une image retenue passerait pour une
/// panne.
class ImageNotPublished implements Exception {
  final ModerationOutcome outcome;
  const ImageNotPublished(this.outcome);

  /// Une phrase, pas un identifiant.
  ///
  /// Les écrans affichent `'Erreur upload : $e'`. Rendre
  /// `ImageNotPublished(pending/engine_unavailable)` ferait lire à
  /// l'utilisateur une clé technique là où il attend de savoir ce qui arrive à
  /// sa photo — et lui ferait croire à une panne alors que l'image est
  /// simplement retenue.
  @override
  String toString() => moderationLabel(
    kModerationReasons,
    outcome.reason.isEmpty ? null : outcome.reason,
  );
}

/// Levée quand le format d'une image n'est pas transportable.
///
/// Ce refus arrive **avant** l'envoi. Sans lui, Storage rendait un
/// `[firebase_storage/unauthorized]` — un message qui accuse les droits de
/// l'utilisateur alors que le problème est le format, et qui ne dit rien de ce
/// qu'il faut faire.
class UnsupportedImageFormat implements Exception {
  final String filename;
  const UnsupportedImageFormat(this.filename);

  @override
  String toString() =>
      'Format d\'image non pris en charge ($filename). '
      'Formats acceptés : JPEG et PNG.';
}

/// Types réellement transportables, du client jusqu'au moteur.
///
/// La liste n'est pas un choix de confort : c'est l'intersection de trois
/// verrous qui doivent s'accorder, sans quoi le refus tombe au mauvais endroit
/// avec le mauvais message —
/// `storage.rules` (`isImportableUnder`), `uploadSecurity.ts`
/// (`ALLOWED_MIME_TYPES` et sa vérification de signature binaire), et la
/// correspondance extension ↔ type MIME que le serveur exige.
///
/// **`image/jpg` n'existe pas.** Un fichier `photo.jpg` dont on déduirait le
/// type par concaténation produit `image/jpg`, que la quarantaine refuse — et
/// l'utilisateur lit « non autorisé » pour un fichier parfaitement valide.
const Map<String, String> _canonicalImageTypes = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
};

/// Type MIME canonique d'une image, ou `null` si le format n'est pas accepté.
///
/// **La signature binaire fait foi, pas le nom.** Le sélecteur d'images
/// réencode en JPEG (`imageQuality: 85`) sans toujours renommer : une photo
/// prise sur iPhone arrive en `IMG_0042.heic` alors que les octets sont du
/// JPEG parfaitement valide. Se fier à l'extension refuserait une image que le
/// serveur, lui, accepterait — il lit la signature, comme ici.
///
/// L'extension ne sert que de repli, pour un format sans signature reconnue.
String? canonicalImageType(Uint8List bytes, String filename) {
  // JPEG : FF D8 FF — PNG : 89 50 4E 47 0D 0A 1A 0A
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return 'image/png';
  }

  final dot = filename.lastIndexOf('.');
  if (dot < 0 || dot == filename.length - 1) return null;
  return _canonicalImageTypes[filename.substring(dot + 1).toLowerCase()];
}

/// Publie une image en passant par la quarantaine et la modération.
///
/// C'est désormais la **seule** voie : les quatre dossiers publiés sont fermés
/// en écriture côté règles Storage, et seul le serveur y dépose.
class ImageModerationService {
  final FirebaseStorage? _injectedStorage;
  final FirebaseAuth? _injectedAuth;
  final FirebaseFunctions? _injectedFunctions;
  final ErrorReportService? _injectedErrorReportService;

  static const _functionsRegion = 'europe-west1';

  /// Tout est résolu à la première utilisation, jamais à la construction.
  ///
  /// `FirebaseStorage.instance` et `FirebaseFunctions.instanceFor` exigent une
  /// App Firebase initialisée. Les appeler dans le constructeur imposait cette
  /// exigence à tout code qui *contient* un repository d'images — y compris aux
  /// tests de parcours qui n'envoient aucune image. C'est la même leçon que
  /// les Functions de `RecipeRepository`, et elle se paie deux fois si on ne
  /// l'applique pas ici.
  FirebaseStorage get _storage => _injectedStorage ?? FirebaseStorage.instance;
  FirebaseAuth get _auth => _injectedAuth ?? FirebaseAuth.instance;
  FirebaseFunctions get _functions =>
      _injectedFunctions ??
      FirebaseFunctions.instanceFor(region: _functionsRegion);
  ErrorReportService get _errorReportService =>
      _injectedErrorReportService ?? ErrorReportService();

  ImageModerationService({
    FirebaseStorage? storage,
    FirebaseAuth? auth,
    FirebaseFunctions? functions,
    ErrorReportService? errorReportService,
  }) : _injectedStorage = storage,
       _injectedAuth = auth,
       _injectedFunctions = functions,
       _injectedErrorReportService = errorReportService;

  static String _sanitize(String filename) => filename
      .replaceAll(RegExp(r'[^a-zA-Z0-9._\-]'), '_')
      .replaceAll(RegExp(r'_+'), '_');

  /// Publie une image et rend son URL, ou lève [ImageNotPublished].
  ///
  /// L'appelant qui veut afficher un état d'attente attrape l'exception ; celui
  /// qui n'a rien à en dire la laisse remonter.
  Future<String> publish(PendingImage image) async {
    final outcomes = await publishAll([image]);
    final outcome = outcomes.first;
    if (!outcome.isPublished) throw ImageNotPublished(outcome);
    return outcome.url!;
  }

  /// Publie un lot d'images en un seul appel.
  ///
  /// Le groupage est un poste de coût à part côté serveur : promouvoir douze
  /// illustrations d'un scan en douze appels coûterait douze fois la latence,
  /// et le reporting ne saurait pas distinguer les deux cas.
  Future<List<ModerationOutcome>> publishAll(List<PendingImage> images) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      throw StateError('Publication d\'image sans utilisateur connecté.');
    }

    final items = <Map<String, Object?>>[];
    for (var i = 0; i < images.length; i++) {
      final image = images[i];

      // Le type est CANONIQUE, jamais déduit par concaténation : `image/jpg`
      // n'existe pas, et la quarantaine le refuse. Le nom du fichier déposé
      // porte l'extension canonique correspondante, parce que le serveur
      // recoupe les deux avant d'analyser quoi que ce soit.
      final contentType = canonicalImageType(image.bytes, image.filename);
      if (contentType == null) {
        throw UnsupportedImageFormat(image.filename);
      }
      final ext = contentType == 'image/png' ? 'png' : 'jpg';

      final ts = DateTime.now().millisecondsSinceEpoch;
      final base = _sanitize(image.filename);
      final stem = base.contains('.')
          ? base.substring(0, base.lastIndexOf('.'))
          : base;
      final path = 'quarantine/$uid/${ts}_${i}_$stem.$ext';
      try {
        await _storage
            .ref(path)
            .putData(image.bytes, SettableMetadata(contentType: contentType));
      } catch (e, st) {
        // La taille et le chemin sont indispensables : sans eux, un refus de
        // règle ne se distingue pas d'un dépassement de quota. La leçon vient
        // de `scanUpload.uploadAndPromote`, où l'absence de ces deux valeurs a
        // rendu une panne indéchiffrable.
        await _errorReportService.reportError(
          feature: 'imageModeration.uploadQuarantine',
          error: e,
          stackTrace: st,
          userId: uid,
          context: {
            'sizeBytes': image.bytes.length,
            // Le type ENVOYÉ, pas celui demandé par l'appelant : c'est lui que
            // la règle a jugé, et c'est donc lui qui explique un refus.
            'mimeType': contentType,
            'declaredType': image.contentType,
            'sourceFilename': image.filename,
            'targetKind': image.target.wire,
            'storagePath': 'quarantine/$uid/',
          },
        );
        rethrow;
      }
      items.add({
        'quarantinePath': path,
        'targetKind': image.target.wire,
        'ownerId': image.ownerId,
        // Pas de `contentType` : le serveur lit le type sur les octets
        // (ticket #157) et ignore celui qu'on lui enverrait.
        'origin': image.origin.wire,
      });
    }

    try {
      final result = await _functions
          .httpsCallable(
            'moderateAndPromoteImagesFn',
            options: HttpsCallableOptions(timeout: const Duration(minutes: 5)),
          )
          .call<Map<Object?, Object?>>({'items': items});
      final raw = (result.data['results'] as List? ?? const []);
      return raw
          .whereType<Map<Object?, Object?>>()
          .map(ModerationOutcome.fromMap)
          .toList();
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'imageModeration.moderateAndPromote',
        error: e,
        stackTrace: st,
        userId: uid,
        context: {
          'count': images.length,
          'targetKinds': images.map((i) => i.target.wire).toList(),
          'sizeBytes': images.fold<int>(0, (sum, i) => sum + i.bytes.length),
        },
      );
      rethrow;
    }
  }
}
