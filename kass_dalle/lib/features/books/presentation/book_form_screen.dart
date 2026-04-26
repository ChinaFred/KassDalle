import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class BookFormScreen extends ConsumerWidget {
  final String? bookId;
  const BookFormScreen({super.key, this.bookId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: Text(bookId == null ? 'Nouveau livre' : 'Modifier le livre'),
      ),
      body: const Center(child: Text('Formulaire livre — à venir')),
    );
  }
}
