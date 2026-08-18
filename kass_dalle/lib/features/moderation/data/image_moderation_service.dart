import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../../../core/services/error_report_service.dart';

/// Destination d'une image, telle que l'attend le serveur.
enum ModerationTarget {
  bookCover('book_cover'),
  recipeIllustration('recipe_illustration'),
  draftIllustration('draft_illustration'),
  freeRecipeCover('free_recipe_cover');

  final String wire;
  const ModerationTarget(this.wire);
}

/// Origine d'une image.
///
/// Seules les images soumises par une personne sont analysées. Une image
/// produite par l'IA sort d'un moteur qui applique déjà ses garde-fous, et un
/// asset livré avec l'application est le nôtre. Toutes passent par le même
/// chemin — c'est ce qui permet de fermer les dossiers publiés en écriture —
/// et le journal dit pourquoi chacune est passée.
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

  @override
  String toString() => 'ImageNotPublished(${outcome.status}/${outcome.reason})';
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
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = 'quarantine/$uid/${ts}_${i}_${_sanitize(image.filename)}';
      try {
        await _storage
            .ref(path)
            .putData(
              image.bytes,
              SettableMetadata(contentType: image.contentType),
            );
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
            'mimeType': image.contentType,
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
        'contentType': image.contentType,
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
