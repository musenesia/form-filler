// Smoke test: the app boots to the profile list screen.
//
// Storage uses its in-memory test mode because real async file I/O does not
// complete inside flutter_test's fake async zone.

import 'package:flutter_test/flutter_test.dart';

import 'package:form_filler/main.dart';
import 'package:form_filler/services/storage_service.dart';

void main() {
  testWidgets('App shows profile list', (WidgetTester tester) async {
    StorageService.inMemoryForTests = true;

    await tester.pumpWidget(const FormFillerApp());
    await tester.pumpAndSettle();

    expect(find.text('Form Filler'), findsOneWidget);
    expect(find.text('New profile'), findsOneWidget);
    expect(find.text('No profiles yet'), findsOneWidget);
  });
}
