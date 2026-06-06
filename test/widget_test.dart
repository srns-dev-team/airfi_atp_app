import 'package:flutter_test/flutter_test.dart';

import 'package:airfi_atp_app/main.dart';

void main() {
  testWidgets('app builds', (tester) async {
    await tester.pumpWidget(const AirfiAtpApp());
    expect(find.text('Devices'), findsOneWidget);
  });
}
