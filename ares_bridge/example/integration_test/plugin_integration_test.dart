// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ares_bridge/ares_bridge.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('validates a transfer request', (WidgetTester tester) async {
    final request = AresFileTransferRequest(
      sourcePath: '/tmp/example.txt',
      destinationPath: 'example.txt',
    );

    expect(request.sourcePath, '/tmp/example.txt');
    expect(request.destinationPath, 'example.txt');
  });
}
