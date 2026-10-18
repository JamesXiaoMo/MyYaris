import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/services/backend_client.dart';
import 'package:my_yaris/services/in_app_audio_stream_proxy.dart';

void main() {
  group('InAppAudioStreamProxy Tests', () {
    late HttpServer mockUpstreamServer;
    late InAppAudioStreamProxy proxy;
    late BackendClient mockBackendClient;

    setUp(() async {
      // 1. Setup mock upstream server that simulates R9000P / NetEase audio streaming with HTTP 206
      mockUpstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      mockUpstreamServer.listen((HttpRequest request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        final token = request.headers.value('X-Device-Token');

        if (request.uri.path == '/api/v1/music/netease/stream/1830260053') {
          final dummyAudioData = List<int>.generate(2048, (i) => i % 256);
          final totalSize = dummyAudioData.length;

          if (range != null && range.startsWith('bytes=')) {
            final parts = range.replaceFirst('bytes=', '').split('-');
            final start = int.tryParse(parts[0]) ?? 0;
            final end = (parts.length > 1 && parts[1].isNotEmpty)
                ? int.tryParse(parts[1])!
                : (start + 511).clamp(0, totalSize - 1);

            final chunk = dummyAudioData.sublist(start, end + 1);

            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(HttpHeaders.contentTypeHeader, 'audio/mpeg');
            request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
            request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$totalSize');
            request.response.headers.set(HttpHeaders.contentLengthHeader, chunk.length.toString());
            request.response.headers.set('x-cache-status', 'HIT');
            if (token != null) request.response.headers.set('x-auth-verified', 'true');

            if (request.method == 'GET') {
              request.response.add(chunk);
            }
            await request.response.close();
            return;
          } else {
            request.response.statusCode = HttpStatus.ok;
            request.response.headers.set(HttpHeaders.contentTypeHeader, 'audio/mpeg');
            request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
            request.response.headers.set(HttpHeaders.contentLengthHeader, totalSize.toString());
            if (request.method == 'GET') {
              request.response.add(dummyAudioData);
            }
            await request.response.close();
            return;
          }
        }

        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });

      // 2. Setup proxy with mock backend client routing to mock upstream server
      mockBackendClient = BackendClient(
        fallbackDns: {
          'mock-stream-node.ts.net': '127.0.0.1',
        },
      );

      proxy = InAppAudioStreamProxy();
      proxy.configure(
        backendClient: mockBackendClient,
        defaultToken: 'test-token-123',
      );
      await proxy.start();
    });

    tearDown(() async {
      await proxy.stop();
      await mockUpstreamServer.close(force: true);
      mockBackendClient.close();
    });

    test('Proxy binds to loopback IPv4 and assigns valid port', () {
      expect(proxy.isRunning, isTrue);
      expect(proxy.port, greaterThan(0));
    });

    test('resolveStreamUrl correctly transforms Tailnet & backend stream URLs', () {
      // Local/asset paths are unchanged
      expect(proxy.resolveStreamUrl('assets/audio/test.wav'), 'assets/audio/test.wav');
      expect(proxy.resolveStreamUrl('http://127.0.0.1:8000/test'), 'http://127.0.0.1:8000/test');

      // Tailnet stream URL is converted to loopback proxy URL
      const originalUrl = 'https://mock-stream-node.ts.net/api/v1/music/netease/stream/1830260053';
      final resolved = proxy.resolveStreamUrl(originalUrl, token: 'car-secret-token');

      expect(resolved.startsWith('http://127.0.0.1:${proxy.port}/stream?'), isTrue);
      final resolvedUri = Uri.parse(resolved);
      expect(resolvedUri.queryParameters['url'], originalUrl);
      expect(resolvedUri.queryParameters['token'], 'car-secret-token');
    });

    test('Proxy streams HTTP 206 Partial Content with Range forwarding to client', () async {
      final client = HttpClient();
      final upstreamUrl = 'http://mock-stream-node.ts.net:${mockUpstreamServer.port}/api/v1/music/netease/stream/1830260053';
      final proxyUrl = proxy.resolveStreamUrl(upstreamUrl, token: 'custom-car-token');

      final req = await client.getUrl(Uri.parse(proxyUrl));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=100-299');
      final res = await req.close();

      expect(res.statusCode, HttpStatus.partialContent);
      expect(res.headers.value(HttpHeaders.contentTypeHeader), 'audio/mpeg');
      expect(res.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
      expect(res.headers.value(HttpHeaders.contentRangeHeader), 'bytes 100-299/2048');
      expect(res.headers.value(HttpHeaders.contentLengthHeader), '200');
      expect(res.headers.value('x-cache-status'), 'HIT');
      expect(res.headers.value('x-auth-verified'), 'true');

      final body = await res.fold<List<int>>([], (acc, chunk) => acc..addAll(chunk));
      expect(body.length, 200);
      expect(body[0], 100 % 256);
      expect(body.last, 299 % 256);

      client.close();
    });

    test('Proxy handles HEAD requests and converts to safe metadata queries', () async {
      final client = HttpClient();
      final upstreamUrl = 'http://mock-stream-node.ts.net:${mockUpstreamServer.port}/api/v1/music/netease/stream/1830260053';
      final proxyUrl = proxy.resolveStreamUrl(upstreamUrl);

      final req = await client.headUrl(Uri.parse(proxyUrl));
      final res = await req.close();

      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers.value(HttpHeaders.contentTypeHeader), 'audio/mpeg');
      expect(res.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');

      client.close();
    });
  });
}
