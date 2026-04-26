import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/annotation_repository.dart';
import '../domain/annotation.dart';
import '../../auth/presentation/auth_providers.dart';

final annotationRepositoryProvider = Provider<AnnotationRepository>((ref) {
  return AnnotationRepository();
});

/// Flux des annotations d'une recette.
final annotationsProvider =
    StreamProvider.family<List<Annotation>, String>((ref, recipeId) {
  return ref.watch(annotationRepositoryProvider).watchAnnotations(recipeId);
});

/// Ajoute une annotation à une recette.
/// Retourne l'id créé ou lève une exception.
Future<String> addAnnotation({
  required WidgetRef ref,
  required String recipeId,
  required String text,
  required AnnotationType type,
}) async {
  final user = ref.read(appUserProvider).valueOrNull;
  if (user == null) throw Exception('Non authentifié');
  return ref.read(annotationRepositoryProvider).addAnnotation(
        recipeId: recipeId,
        uid: user.uid,
        authorName: user.displayName,
        text: text,
        type: type,
      );
}

/// Met à jour une annotation existante.
Future<void> updateAnnotation({
  required WidgetRef ref,
  required String recipeId,
  required String annotationId,
  required String text,
  required AnnotationType type,
}) async {
  return ref.read(annotationRepositoryProvider).updateAnnotation(
        recipeId: recipeId,
        annotationId: annotationId,
        text: text,
        type: type,
      );
}

/// Supprime une annotation.
Future<void> deleteAnnotation({
  required WidgetRef ref,
  required String recipeId,
  required String annotationId,
}) async {
  return ref.read(annotationRepositoryProvider).deleteAnnotation(
        recipeId: recipeId,
        annotationId: annotationId,
      );
}
