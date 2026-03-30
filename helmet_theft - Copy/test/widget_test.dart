import 'package:flutter_test/flutter_test.dart';
import 'package:helmet_theft/main.dart';

void main() {
  testWidgets('App loads successfully', (WidgetTester tester) async {
    await tester.pumpWidget(const HelmetApp());
    expect(find.byType(HelmetApp), findsOneWidget);
  });
}