import 'package:cloud_firestore/cloud_firestore.dart';
import '../domain/proposal.dart';

class ProposalRepository {
  final FirebaseFirestore _firestore;

  ProposalRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('proposals');

  // ── Lecture ─────────────────────────────────────────────────────────────────

  /// Propositions reçues par [uid] (en attente).
  Stream<List<Proposal>> watchIncoming(String uid) {
    return _col
        .where('to_uid', isEqualTo: uid)
        .where('status', isEqualTo: ProposalStatus.pending.name)
        .orderBy('created_at', descending: true)
        .snapshots()
        .map(
          (s) => s.docs
              .map((d) => Proposal.fromFirestore(d.id, d.data()))
              .toList(),
        );
  }

  /// Propositions envoyées par [uid].
  Stream<List<Proposal>> watchOutgoing(String uid) {
    return _col
        .where('from_uid', isEqualTo: uid)
        .orderBy('created_at', descending: true)
        .snapshots()
        .map(
          (s) => s.docs
              .map((d) => Proposal.fromFirestore(d.id, d.data()))
              .toList(),
        );
  }

  // ── Création ─────────────────────────────────────────────────────────────────

  /// Soumet une nouvelle proposition.
  Future<String> submitProposal(Proposal proposal) async {
    final ref = await _col.add(proposal.toFirestore());
    return ref.id;
  }

  // ── Résolution ───────────────────────────────────────────────────────────────

  /// Accepte une proposition. Retourne l'objet mis à jour.
  Future<void> accept(String proposalId, {String? comment}) async {
    await _col.doc(proposalId).update({
      'status': ProposalStatus.accepted.name,
      'resolved_at': DateTime.now(),
      'resolved_comment': comment,
    });
  }

  /// Rejette une proposition.
  Future<void> reject(String proposalId, {String? comment}) async {
    await _col.doc(proposalId).update({
      'status': ProposalStatus.rejected.name,
      'resolved_at': DateTime.now(),
      'resolved_comment': comment,
    });
  }
}
