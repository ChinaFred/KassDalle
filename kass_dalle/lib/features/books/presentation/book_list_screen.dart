import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// Écrans placeholder pour les modules non encore implémentés
class BookListScreen extends ConsumerWidget {
  const BookListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bibliothèque')),
      body: const Center(child: Text('Liste des livres — à venir')),
    );
  }
}
