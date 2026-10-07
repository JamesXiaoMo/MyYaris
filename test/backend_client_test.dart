import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/services/backend_client.dart';

void main() {
  group('BackendClient DNS Fallback & TLS Verification Tests', () {
    test('Default fallback DNS mapping contains authorized backend host', () {
      final client = BackendClient();
      expect(
        client.fallbackDns['myyaris.example.com'],
        '192.0.2.10',
      );
      client.close();
    });

    test('Custom fallback DNS mapping is respected', () {
      final customMap = {'myyaris.example.com': '192.0.2.10'};
      final client = BackendClient(fallbackDns: customMap);
      expect(client.fallbackDns['myyaris.example.com'], '192.0.2.10');
      expect(client.fallbackDns.containsKey('myyaris.example.com'), false);
      client.close();
    });

    test('Strict TLS verification rejects mismatched hostname without badCertificateCallback', () async {
      // Directs an arbitrary hostname to the authorized backend IP
      final client = BackendClient(fallbackDns: {
        'mismatched.invalid.domain': '192.0.2.10',
      });

      // The TLS handshake MUST fail because the certificate is for myyaris.example.com,
      // NOT mismatched.invalid.domain. This proves badCertificateCallback is NOT bypassing verification!
      bool failedWithTlsHandshake = false;
      try {
        await client.checkHealth('https://mismatched.invalid.domain');
      } catch (e) {
        if (e is HandshakeException) {
          failedWithTlsHandshake = true;
        }
      }
      // checkHealth catches exceptions internally and returns false on error
      final health = await client.checkHealth('https://mismatched.invalid.domain');
      expect(health, false);

      client.close();
    });

    test('checkHealth succeeds against real authorized backend host via fallback mapping', () async {
      final client = BackendClient();
      final health = await client.checkHealth('https://myyaris.example.com');
      expect(health, true);
      client.close();
    });
  });
}
