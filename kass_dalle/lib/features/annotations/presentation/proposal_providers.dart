import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/proposal_repository.dart';
import '../domain/proposal.dart';
import '../../auth/presentation/auth_providers.dart';

final proposalRepositoryProvider = Provider<ProposalRepository>((ref) {
  return ProposalRepository();
});

/// Propositions reçues par l'utilisateur connecté (en attente de validation).
final incomingProposalsProvider = StreamProvider.autoDispose<List<Proposal>>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(proposalRepositoryProvider).watchIncoming(uid);
});

/// Propositions envoyées par l'utilisateur connecté.
final outgoingProposalsProvider = StreamProvider.autoDispose<List<Proposal>>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(proposalRepositoryProvider).watchOutgoing(uid);
});

/// Nombre de propositions en attente (pour le badge de notification).
final pendingProposalsCountProvider = Provider<int>((ref) {
  return ref.watch(incomingProposalsProvider).value?.length ?? 0;
});
