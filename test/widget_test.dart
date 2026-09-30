import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/core/security/pairing_verifier.dart';
import 'package:itantra/ui/widgets/pairing_sheet.dart';

void main() {
  testWidgets('PairingSheet renders SAS code and handles confirmation',
      (WidgetTester tester) async {
    bool confirmed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PairingSheet(
            payload: PairingPayload(
              transport: 'wifi',
              address: '192.168.4.1',
              port: 8080,
              publicKey: Uint8List(32),
            ),
            shortAuthString: '492817',
            onConfirmed: () => confirmed = true,
            onCancelled: () {},
            peerLabel: 'Test Peer',
          ),
        ),
      ),
    );

    expect(find.text('492 817'), findsOneWidget);
    expect(find.text('They match'), findsOneWidget);

    await tester.tap(find.text('They match'));
    expect(confirmed, isTrue);
  });
}
