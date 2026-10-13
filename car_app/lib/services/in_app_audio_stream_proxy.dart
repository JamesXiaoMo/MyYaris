import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'backend_client.dart';

/// In-App Local Loopback Audio Streaming Proxy.
///
/// Binds strictly to 127.0.0.1 on an ephemeral port.
/// Bridges native Android ExoPlayer requests to upstream HTTPS backend services
/// while maintaining strict TLS SNI, host header, and certificate chain verification
/// through BackendClient without requiring insecure HTTP downgrade or OS-level DNS modifications.
class InAppAudioStreamProxy {
  static final InAppAudioStreamProxy _instance = InAppAudioStreamProxy._internal();
  factory InAppAudioStreamProxy() => _instance;
  InAppAudioStreamProxy._internal();

  BackendClient _backendClient = BackendClient();
  HttpServer? _server;
  String _defaultToken = '';
  bool _isStarting = false;

  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null;

  void configure({BackendClient? backendClient, String? defaultToken}) {
    if (backendClient != null) _backendClient = backendClient;
    if (defaultToken != null) _defaultToken = defaultToken.trim();
  }

  /// Starts the local loopback HTTP server.
  Future<void> start() async {
    if (_server != null || _isStarting) return;
    _isStarting = true;

    try {
      _server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0, // System assigns available ephemeral port
      );
      debugPrint('[InAppStreamProxy] Loopback proxy listening on 127.0.0.1:${_server!.port}');

      _server!.listen(
        _handleRequest,
        onError: (e) {
          debugPrint('[InAppStreamProxy] Server error: $e');
        },
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('[InAppStreamProxy] Failed to bind loopback proxy: $e');
    } finally {
      _isStarting = false;
    }
  }

  /// Stops the local loopback server.
  Future<void> stop() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }

  /// Resolves an upstream stream URL into an ExoPlayer-compatible stream URL.
  ///
  /// If the URL points to a host needing custom DNS resolution (e.g. MagicDNS on Tailnet)
  /// or requires authenticated streaming from the backend, wraps it with the loopback proxy.
  String resolveStreamUrl(String originalUrl, {String? token}) {
    if (originalUrl.isEmpty) return originalUrl;
    if (originalUrl.startsWith('asset:') ||
        originalUrl.startsWith('file:') ||
        originalUrl.startsWith('http://127.0.0.1') ||
        originalUrl.startsWith('http://localhost')) {
      return originalUrl;
    }

    final uri = Uri.tryParse(originalUrl);
    if (uri == null) return originalUrl;

    // Check if host needs loopback proxy routing
    final host = uri.host.toLowerCase();
    final isFallbackHost = _backendClient.fallbackDns.containsKey(host);
    final isTailnetHost = host.contains('.ts.net');
    final isBackendStream = uri.path.contains('/api/v1/music/');

    if ((isFallbackHost || isTailnetHost || isBackendStream) && _server != null && _server!.port > 0) {
      final effectiveToken = (token != null && token.isNotEmpty) ? token : _defaultToken;
      final qParams = <String, String>{
        'url': originalUrl,
      };
      if (effectiveToken.isNotEmpty) {
        qParams['token'] = effectiveToken;
      }

      final proxyUri = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: _server!.port,
        path: '/stream',
        queryParameters: qParams,
      );
      debugPrint('[InAppStreamProxy] Rewrote "$originalUrl" -> "$proxyUri"');
      return proxyUri.toString();
    }

    return originalUrl;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final clientMethod = request.method.toUpperCase();

    if (request.uri.path != '/stream') {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('Not Found');
      await _safeCloseResponse(request.response);
      return;
    }

    if (clientMethod != 'GET' && clientMethod != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await _safeCloseResponse(request.response);
      return;
    }

    final targetUrlStr = request.uri.queryParameters['url'];
    if (targetUrlStr == null || targetUrlStr.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('Missing url parameter');
      await _safeCloseResponse(request.response);
      return;
    }

    final targetUri = Uri.tryParse(targetUrlStr);
    if (targetUri == null || (!targetUri.isScheme('http') && !targetUri.isScheme('https'))) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('Invalid target URL scheme');
      await _safeCloseResponse(request.response);
      return;
    }

    final token = request.uri.queryParameters['token'] ?? _defaultToken;

    try {
      // If client sent HEAD, but upstream backend may only have GET route defined,
      // request upstream via GET with Range: bytes=0-0 to retrieve metadata headers safely.
      final upstreamMethod = (clientMethod == 'HEAD') ? 'GET' : clientMethod;
      final upstreamReq = await _backendClient.httpClient.openUrl(upstreamMethod, targetUri);

      // 1. Forward incoming Range header
      final clientRange = request.headers.value(HttpHeaders.rangeHeader);
      if (clientRange != null && clientRange.isNotEmpty) {
        upstreamReq.headers.set(HttpHeaders.rangeHeader, clientRange);
      } else if (clientMethod == 'HEAD') {
        upstreamReq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      }

      // 2. Set client identification & auth headers
      upstreamReq.headers.set(HttpHeaders.userAgentHeader, 'MyYaris-InAppStreamProxy/1.0');
      if (token.isNotEmpty) {
        upstreamReq.headers.set('X-Device-Token', token);
        upstreamReq.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }

      final upstreamRes = await upstreamReq.close().timeout(const Duration(seconds: 15));

      // 3. Forward response headers
      request.response.statusCode = (clientMethod == 'HEAD' && upstreamRes.statusCode == HttpStatus.partialContent)
          ? HttpStatus.ok
          : upstreamRes.statusCode;

      // 3. Forward non-hop-by-hop response headers
      const hopByHopHeaders = {
        'connection',
        'keep-alive',
        'proxy-authenticate',
        'proxy-authorization',
        'te',
        'trailer',
        'transfer-encoding',
        'upgrade',
      };

      upstreamRes.headers.forEach((name, values) {
        if (!hopByHopHeaders.contains(name.toLowerCase())) {
          for (final val in values) {
            request.response.headers.add(name, val);
          }
        }
      });

      // 4. Pipe content
      if (clientMethod == 'HEAD') {
        // Discard upstream body and complete
        await upstreamRes.drain<void>();
        await _safeCloseResponse(request.response);
      } else {
        try {
          await request.response.addStream(upstreamRes);
        } catch (e) {
          // Client seek or cancel interruption is normal for media playback
          debugPrint('[InAppStreamProxy] Downstream pipe interruption: $e');
        } finally {
          await _safeCloseResponse(request.response);
        }
      }
    } catch (e) {
      debugPrint('[InAppStreamProxy] Upstream proxy error: $e');
      try {
        request.response.statusCode = HttpStatus.badGateway;
        request.response.write('Bad Gateway: $e');
        await _safeCloseResponse(request.response);
      } catch (_) {}
    }
  }

  Future<void> _safeCloseResponse(HttpResponse response) async {
    try {
      await response.close();
    } catch (_) {}
  }
}
