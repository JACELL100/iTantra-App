import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/core/transport/offline_guard.dart';

void main() {
  group('OfflineGuard', () {
    const OfflineGuard guard = OfflineGuard(allowLoopback: true);

    test('permits link-local and private addresses', () {
      // These are the only addresses a paired phone or an embedded bridge
      // can legitimately have.
      for (final String address in <String>[
        '192.168.4.1',
        '192.168.49.1',
        '10.0.0.7',
        '172.16.3.9',
        '169.254.10.20',
        '127.0.0.1',
      ]) {
        expect(guard.isPermittedString(address), isTrue,
            reason: '$address should be allowed');
      }
    });

    test('rejects routable addresses', () {
      // Belt and braces: the app also holds no INTERNET permission, so this
      // check exists to fail loudly during development rather than to be the
      // only line of defence.
      for (final String address in <String>[
        '8.8.8.8',
        '1.1.1.1',
        '13.107.42.14',
      ]) {
        expect(guard.isPermittedString(address), isFalse,
            reason: '$address should be blocked');
      }
    });

    test('rejects hostnames, since a name implies a resolver', () {
      expect(guard.isPermittedString('example.com'), isFalse);
      expect(guard.isPermittedString('api.openai.com'), isFalse);
    });

    test('requireLinkLocal throws for a routable address', () {
      expect(
        () => guard.requireLinkLocal('8.8.8.8'),
        throwsA(isA<OfflineViolation>()),
      );
    });

    test('requireLinkLocal accepts a private address', () {
      expect(
        () => guard.requireLinkLocal('192.168.4.1'),
        returnsNormally,
      );
    });
  });
}
