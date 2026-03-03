import 'package:flutter_test/flutter_test.dart';

import 'package:vive/main.dart';

void main() {
  testWidgets('App renders download screen', (WidgetTester tester) async {
    await tester.pumpWidget(const ViveApp());

    expect(find.text('Vive'), findsOneWidget);
    expect(find.text('Download MP3'), findsOneWidget);
  });
}
