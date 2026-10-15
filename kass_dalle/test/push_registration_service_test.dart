import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/push_registration_service.dart';

void main() {
  test('reconnaît la notification de nouvelle version', () {
    expect(
      isApkReleaseMessage({'type': 'apk_release', 'version': '1.0.0'}),
      isTrue,
    );
    expect(isApkReleaseMessage({'type': 'autre'}), isFalse);
    expect(isApkReleaseMessage(const {}), isFalse);
  });

  test(
    'le document appareil ne porte que les champs que les règles acceptent',
    () {
      final doc = deviceDocument('tok');
      expect(doc.keys.toSet(), {'token', 'platform', 'updated_at'});
      expect(doc['token'], 'tok');
      expect(doc['platform'], 'android');
      expect(doc['updated_at'], isA<FieldValue>());
    },
  );
}
