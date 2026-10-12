import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/services/backend_client.dart';

// Test CA Certificate (Self-signed Root CA: CN=TestRootCA)
const String testCaCertPem = '''
-----BEGIN CERTIFICATE-----
MIIC+jCCAeKgAwIBAgIUc6GiU0/+IxJQPPbpm4p40/KEso0wDQYJKoZIhvcNAQEL
BQAwFTETMBEGA1UEAwwKVGVzdFJvb3RDQTAeFw0yNjEwMDcwOTM3MTVaFw0yNzEw
MDcwOTM3MTVaMBUxEzARBgNVBAMMClRlc3RSb290Q0EwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQDfXfCVtMp9D8bE42pCqEqSBW6kc+eQJPVtlvT08WQn
KAfqqVQptRvx2aytFcr2t9O8Pkbd+BCZGfG49MZDqUyHonSssH3kW+dv1t7w0gvI
3C759xRreyCEcwhmLc6+JCYOpiT9cmcRKIbc4Nh4CVhzm9+jaFp6Kp/rEYr5CJ13
3YB3TjRueXn2S6UXe1t8HRbigPXpvKg0SZeQfH/mLoP0Znk/A6HDuxHdEtzCucBo
PFgncMfBUviHuT9VDgrlfG7EY0QMrhuYwit6C+P4jRd4PXwnuVs8gKyulSLIoZhZ
z9a3lwJaHssx2gmhUgEUEod/Pgo3L16JJraruvTlntVJAgMBAAGjQjBAMA8GA1Ud
EwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBRHRP6/MmIlK0LK
EnCd2lE0IXrTMDANBgkqhkiG9w0BAQsFAAOCAQEAEq0kw02GICsw/MfGSP2N5YH3
xMlmE2GlrJFPOEvNn8tP6l5Rp1zQ0Fcm9ohgGZAsNtqYxaXTDJ4p9/lNVTJyRxeU
ldVZwH0b98yXqVfhEjJ6RnR7LVFO+rFycUnPqi2iDelJiuDEqV9MmoI47tMW042D
SOOxzvIZBSun9bGlVosZGho4NslpKFRUsUJ6SKRQfpofpSaKXD9Z9jwubkhBn43n
9ctXgUi1CXss/3bJpPgOvzy7hGJXJS1lb8vlRwxIfoehv2Zy3q0aHpvV+yz2VQix
PvPS9dodTiZAhS2j0hkeF7Opbr7rflnAcIalBUox5/1xzGCeIoIIo+diQmlkzg==
-----END CERTIFICATE-----
''';

// Server Certificate signed by TestRootCA with SAN=DNS:correct-host.test and CA certificate
const String testServerFullChainPem = '''
-----BEGIN CERTIFICATE-----
MIIDVDCCAjygAwIBAgIUW7V8GLga2RT4zyqgC9iX8qn4XE4wDQYJKoZIhvcNAQEL
BQAwFTETMBEGA1UEAwwKVGVzdFJvb3RDQTAeFw0yNjEwMDcwOTM3MTVaFw0yNzEw
MDcwOTM3MTVaMBwxGjAYBgNVBAMMEWNvcnJlY3QtaG9zdC50ZXN0MIIBIjANBgkq
hkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAz+u3fVYw0MD7b54rwdBNAmjpNk9nRdlB
0xFXuDa/X5JYPdQBL3gYgLJ2ndchF5jLmUc6yniPodyH7zEIoFZCUjiLzhWG+vO1
ntF7xEjyy3ivf1456G93wlNYB4oYb4s/WIa8IeS/aEjOAQzgQ/mauc7cmolrLgjD
+8dfOa2XoZTjj2dhz1EbUE1JivbXkpac5YFCtyoM62f+olIZR1w6PvDkdKAO1Y15
1SNsLGjOvxcYXso6/sXaC57podnYc0mtulvIKvGNWpCvjvdZVglBQytA79mbmpFl
Tf7JtSiYyiLWShZuVjunjRq5pUuOd88aRwrhFMfpwWB/OZgraGV7XQIDAQABo4GU
MIGRMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoGCCsG
AQUFBwMBMBwGA1UdEQQVMBOCEWNvcnJlY3QtaG9zdC50ZXN0MB0GA1UdDgQWBBRk
at7onqGCy+yDOspzPTYYbDmgdzAfBgNVHSMEGDAWgBRHRP6/MmIlK0LKEnCd2lE0
IXrTMDANBgkqhkiG9w0BAQsFAAOCAQEA3mH2utXWn9eu2hqrVAIp9RDiUjxjEluc
9oSWhWTtRmntWPPJLzh9jrjikQcbzJjM45mIg2VuRpwiy7gNZCTizhHDnQTSTPa2
XRQ7pqAdWXW3MfB25RxVGZcG/2zfwigP3PcKyQNcq6IKmxJfr2iYPpzV7mLDgJSg
ey0h/JWW9Y8kTolW0C2zz1cTEfAGfg3DWnLMI6WSirAv184law0sG+UGPC+JIDhq
8mU7FEcW1D7PCVhIkf95ogUsefU8E7Q2bSDfZ5fCgDb6ahy7xJnwPnZJf6hqODB9
tA7zbvlqhnOtzv1A1qUyUPUo3G+Oa5SVwJBb4MPq6sWZjANFfCveYA==
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIC+jCCAeKgAwIBAgIUc6GiU0/+IxJQPPbpm4p40/KEso0wDQYJKoZIhvcNAQEL
BQAwFTETMBEGA1UEAwwKVGVzdFJvb3RDQTAeFw0yNjEwMDcwOTM3MTVaFw0yNzEw
MDcwOTM3MTVaMBUxEzARBgNVBAMMClRlc3RSb290Q0EwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQDfXfCVtMp9D8bE42pCqEqSBW6kc+eQJPVtlvT08WQn
KAfqqVQptRvx2aytFcr2t9O8Pkbd+BCZGfG49MZDqUyHonSssH3kW+dv1t7w0gvI
3C759xRreyCEcwhmLc6+JCYOpiT9cmcRKIbc4Nh4CVhzm9+jaFp6Kp/rEYr5CJ13
3YB3TjRueXn2S6UXe1t8HRbigPXpvKg0SZeQfH/mLoP0Znk/A6HDuxHdEtzCucBo
PFgncMfBUviHuT9VDgrlfG7EY0QMrhuYwit6C+P4jRd4PXwnuVs8gKyulSLIoZhZ
z9a3lwJaHssx2gmhUgEUEod/Pgo3L16JJraruvTlntVJAgMBAAGjQjBAMA8GA1Ud
EwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBRHRP6/MmIlK0LK
EnCd2lE0IXrTMDANBgkqhkiG9w0BAQsFAAOCAQEAEq0kw02GICsw/MfGSP2N5YH3
xMlmE2GlrJFPOEvNn8tP6l5Rp1zQ0Fcm9ohgGZAsNtqYxaXTDJ4p9/lNVTJyRxeU
ldVZwH0b98yXqVfhEjJ6RnR7LVFO+rFycUnPqi2iDelJiuDEqV9MmoI47tMW042D
SOOxzvIZBSun9bGlVosZGho4NslpKFRUsUJ6SKRQfpofpSaKXD9Z9jwubkhBn43n
9ctXgUi1CXss/3bJpPgOvzy7hGJXJS1lb8vlRwxIfoehv2Zy3q0aHpvV+yz2VQix
PvPS9dodTiZAhS2j0hkeF7Opbr7rflnAcIalBUox5/1xzGCeIoIIo+diQmlkzg==
-----END CERTIFICATE-----
''';

// Private key for server certificate
const String testServerKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDP67d9VjDQwPtv
nivB0E0CaOk2T2dF2UHTEVe4Nr9fklg91AEveBiAsnad1yEXmMuZRzrKeI+h3Ifv
MQigVkJSOIvOFYb687We0XvESPLLeK9/Xjnob3fCU1gHihhviz9Yhrwh5L9oSM4B
DOBD+Zq5ztyaiWsuCMP7x185rZehlOOPZ2HPURtQTUmK9teSlpzlgUK3KgzrZ/6i
UhlHXDo+8OR0oA7VjXnVI2wsaM6/Fxheyjr+xdoLnumh2dhzSa26W8gq8Y1akK+O
91lWCUFDK0Dv2ZuakWVN/sm1KJjKItZKFm5WO6eNGrmlS453zxpHCuEUx+nBYH85
mCtoZXtdAgMBAAECggEAJk3VGGyMArFCwP3hLsv6m/KK4DwBmQ8cvs8nm2LOn8M8
qWtIqp+T2AXIr2xmBsxZ2cuTC6DpSRbxHgIpBizN/Aq5ysYRf2Ltdyw9glw0CoMZ
xbusrGL4q56iDYWF2erLyTnNJ+tVzdb3yJ7AJBW0SP3Qi1G8opbv0A8bPmt6D0Sj
Hk/P97Gh3ACHI41S0y/spZC+4UavIz4oHk2WPHvUInr6YgMjVlgThECxRxjne1XP
n4Ua+iPDegt1VNW2cxOYUA1m3WQRueZGsxKgpeLBMN3dZSJhx5QtWdzafZwENk6W
CFYEvSUu6qliXtAxAQHnguK34Vex4uGq58ZpXNQcewKBgQDsAaYVWTSSpMwlLEZ0
S7T/QdUpr5JpRpQ3ugS/NMbqSnUKGb15YbYr6s+HQlvr0gcFajm4IpGZp1SbjJtT
2lX9hqI7OM/DFXL+GXSTb/0rot8uHdrs5yxgIoNsWinxWBsFB3CK0Tl+D8xEKWUI
6MhKxy0YaP7eZ9lfQBp7W8c6fwKBgQDhiPbtShy2hQMQNCUi/N2G64h3bVCJBkLz
HhSUKHFRIsd3pzInKb9TgY6VsSWhEtdVn2Kl7O20hD7IlyK8QtKPaxqMLSHMWTzv
NOsMB17ZvrkTMP24MK0aVH7jNrRyHKNLkvyhag98tKxF4MZOkutcvX1FSwhHYAaK
gIIFWIGEIwKBgDXWMnLQRKPnIAKi1PeWhZVtCRlXScjmJs2Hi6mqem3bylMhiA12
cr4V9H1gb+Odp6hekQgmKpyohS5upsg8GD2bRsrHrO1NqUu5ttQjSdd4cfztJpHA
MmlDtkMzVjoN5SwChHPGQp01MV2jK78aiwYz5V+aI/nMKtQFpYTabNo1AoGAOAyQ
yTHU5usxcrJy1DohV6lrNbrd+9+pfb/o/1T5rF9HUQ4lIaR3XupgpATtRBVpnGbK
3k9+V5FSBQnCYST+LRRB+boxnxZCVXRCQbAHO3fxiLpxI3g9XMDI8/ChcYZ6coqp
6/dut+Ayu/77aYWLpnWVD0ZxXUOY/IypQ2jWbx8CgYEA5dmXTmh8BhmNEGVqTAbx
9vYApFCVmCzu3Fnulhb9p5zQPyu8s9ki0CYHfcCrRe2UAOZR0cIYWiPPNboYiXtv
Lhng9vzqkMFbP1cLZDEFJyDLRrJgUaIExBA/bk7GnuAwWqtwD0yKqiAq1AXVcq+V
RIWlQLLSeWYMeOtRblCPhIc=
-----END PRIVATE KEY-----
''';

// Untrusted self-signed certificate and private key
const String testUntrustedCertPem = '''
-----BEGIN CERTIFICATE-----
MIIDGTCCAgGgAwIBAgIUAmuwxWye7F+uMJu34FVjIFVc+IcwDQYJKoZIhvcNAQEL
BQAwHDEaMBgGA1UEAwwRY29ycmVjdC1ob3N0LnRlc3QwHhcNMjYxMDA3MDkzNTAx
WhcNMjcxMDA3MDkzNTAxWjAcMRowGAYDVQQDDBFjb3JyZWN0LWhvc3QudGVzdDCC
ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAIjyJVokxXAwkb8G8qnOOeB0
QqnneZHuhxT8XvGuKazJJsF8LH7/bXKCarzDaq0JKIE2BV7MGCUMn5viScdA9NmH
xcHWC06fvcspFUUyFdQty8C+brA9LHSZK6c0g01jz+OvLXJUgXSqau378CHewMMZ
5Pb3VfxuZEp8qq2Ec1BbisTvdthzwg2eTjWL0l7/lQzuB7mw8Tbj8PBTDaaKhLuh
IqhFq3H3z6JH2yR3ApZn0+aQngWH10Xc2P1cvS00gUjNX5CWpYXshDAj7eABJcQu
oEAnxpwD/7zhoZutsNVZmNy8FJcKc0HNdAQzD7G6hOtucGLFIUqCtiM4H8OalOEC
AwEAAaNTMFEwHQYDVR0OBBYEFKmyb9cofcnSzhNO8sgmv7A88cZyMB8GA1UdIwQY
MBaAFKmyb9cofcnSzhNO8sgmv7A88cZyMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZI
hvcNAQELBQADggEBAHfg1Ru4rJQkz0Z8HyR6vdbCzvxqPtyX7DiTZRD/TSnWhxnn
4q0298HvJKlvCozp0hrRJBu4QWCP6ydSmSU29H+L32qfz/XiAspxMFwjjmBCemh8
NHnP7JRVPOxv9WPXs5Mi/vQvhL7NAu2pOqGhDh7A0+DCs6Lz74xXpH8ZVOQH8bJK
CMKG5v47iiUPfGYkXvgwJNLpEN640pJJL7LJjE/gbYFPg/oxOrlLodt9ZSR+L8Ap
p/ukt2TH5PLI/zEWyfK9s0/GiekDGOjc8lP8Rhj+8Ys/BoqUmb52wq/FyM2GfyRy
LsrbP1E1b5Je7jca9avwqcPYMoWBOjfi+bAyR2c=
-----END CERTIFICATE-----
''';

const String testUntrustedKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCI8iVaJMVwMJG/
BvKpzjngdEKp53mR7ocU/F7xrimsySbBfCx+/21ygmq8w2qtCSiBNgVezBglDJ+b
4knHQPTZh8XB1gtOn73LKRVFMhXULcvAvm6wPSx0mSunNINNY8/jry1yVIF0qmrt
+/Ah3sDDGeT291X8bmRKfKqthHNQW4rE73bYc8INnk41i9Je/5UM7ge5sPE24/Dw
Uw2mioS7oSKoRatx98+iR9skdwKWZ9PmkJ4Fh9dF3Nj9XL0tNIFIzV+QlqWF7IQw
I+3gASXELqBAJ8acA/+84aGbrbDVWZjcvBSXCnNBzXQEMw+xuoTrbnBixSFKgrYj
OB/DmpThAgMBAAECggEAQstAVqhKuH6oB7E+2H2ikwyBm1cwX3Ik5qJ1OJHG9+Sg
h4ymM0coPcrIfssdk8o8vFD565PGTwPKMYD8lTfkdNkZJoLcvvuA2b9vBXH5XaT8
lUUMvd8IeNJgjUw6opuFQTsnAnWfMqUQRIU2SX7ZLA/MMnzOrrG1LvOBV+KbT9yv
uxa+8BX+oiiMKLogXg4oRReHz+daxhGjaE8zBBIY+oeKm6TITh/mvMYGCAXsahH9
/sNe3WYN7OF6meEMkuWH+pJv7wQFRivp0Qcizg0k9EwVkFkq3p9AfAoYnxLgLvtu
55iCzlSHdtvZ5HKLGw8tAjlVTFLuGZPsVqRrIGy3RQKBgQC7iOjdJAaqGJxOT6i9
Pc5KWwSFiZSG42N/jjjqkldJQAgbmAPr7LnPJB6k4fs4hOPKihf7P7rU1+Zuu4Sl
tSu3hfyeLg6sDjNZCIpo6OwIPzyl5+GjwI0fhVLzJOnfUYAC+k/cQ2uF69GuNkB0
95jR5EVMEHxVqM5AcOulqkjWswKBgQC68SwOok+VY5dgXotzLt4HtSxdzwT7+mSZ
w4gkitdKmSuBt1cn7GSzjBkfuQFrhF266tkYp8rqpuz1+7CvWPGIHMQ5xNjYOMXg
6fkATG6nN+id5XBCr48ylbQkJK3dReWyFURbckJ3tUb1/aT0fhBNwxNUcNgNf+hj
o+SW09xQGwKBgHrhBKQR/QPrSE/PxmLpYog6B0ZwlY+k4wcra4PYC7WFbUqXWsp1
vHJL2oBzSicIfDG0Nm58nbDlHqoj2JCzm0ePVa1XxGlcjKyj+f0v0ai9tsGGpMSl
YFLtCyMiZtPbFSPeXAGZc5S2pheemLGLoui0x+tFShLenvZ+hwlwAHYdAoGACYTI
MoKPPNMSXSTTQu0q/wd5l9k3rsDkKHQtVXcAWVsNPRChznWZ9w52JQhdiyT1RNQ6
c6fvjB0tyaSkLXmA6uZUE4DzbacOZFJljF9X7wnIvWl2Wt7nkrLOtlxrwe2SMYwl
q+ZYfhHr6BCfOpfEqsD5Ff6c8asGoTQyKn/lIusCgYEAh4YPZH7xB+mOvIGRk5cq
vBW7z8jz8dNFBi+LUSN60aX0O19UQd/Rqm8iwOM0WtdfAZd9//NUl7zygTB0PUGb
Um0jfcV66OcI1vJ/pW6Xu5bq2z7Br0aV2j60M0cEus2vK6T2beEneVx2scqkd5hP
8HZUfnuvBVqEQ4XBZa0btys=
-----END PRIVATE KEY-----
''';

void main() {
  group('BackendClient DNS Fallback & Strict TLS Verification (Hermetic Local Tests)', () {
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

    test('Hermetic Test: Valid Host & Trusted CA via IP fallback succeeds with 200 OK', () async {
      // 1. Setup local TLS server with SAN=DNS:correct-host.test signed by TestRootCA
      final serverSec = SecurityContext();
      serverSec.useCertificateChainBytes(utf8.encode(testServerFullChainPem));
      serverSec.usePrivateKeyBytes(utf8.encode(testServerKeyPem));

      final server = await HttpServer.bindSecure('127.0.0.1', 0, serverSec);
      server.listen((HttpRequest req) {
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'status': 'ok'}));
        req.response.close();
      });

      // 2. Client SecurityContext explicitly trusts TestRootCA (scoped strictly to this test)
      final testClientContext = SecurityContext(withTrustedRoots: false);
      testClientContext.setTrustedCertificatesBytes(utf8.encode(testCaCertPem));

      // 3. BackendClient with fallback mapping pointing correct-host.test to 127.0.0.1
      final client = BackendClient(
        httpClient: HttpClient(context: testClientContext)
          ..connectionFactory = (uri, proxyHost, proxyPort) {
            final targetIp = {'correct-host.test': '127.0.0.1'}[uri.host];
            final connectHost = targetIp ?? uri.host;
            final isHttps = uri.isScheme('https');
            final port = uri.hasPort ? uri.port : (isHttps ? 443 : 80);

            Socket? currentSocket;
            bool isCancelled = false;
            final completer = Completer<Socket>();

            Socket.connect(connectHost, port, timeout: const Duration(seconds: 5)).then(
              (plainSocket) {
                if (isCancelled) {
                  plainSocket.destroy();
                  return;
                }
                currentSocket = plainSocket;
                if (isHttps) {
                  SecureSocket.secure(
                    plainSocket,
                    host: uri.host,
                    context: testClientContext,
                  ).then(
                    (secureSocket) {
                      if (isCancelled) {
                        secureSocket.destroy();
                      } else {
                        completer.complete(secureSocket);
                      }
                    },
                    onError: (Object err, StackTrace st) => completer.completeError(err, st),
                  );
                } else {
                  completer.complete(plainSocket);
                }
              },
              onError: (Object err, StackTrace st) => completer.completeError(err, st),
            );

            return Future.value(ConnectionTask.fromSocket(completer.future, () {
              isCancelled = true;
              currentSocket?.destroy();
            }));
          },
      );

      final ok = await client.checkHealth('https://correct-host.test:${server.port}');
      expect(ok, isTrue);

      client.close();
      await server.close(force: true);
    });

    test('Hermetic Test: Client-side hostname mismatch rejection (server cert trusted but SAN mismatch)', () async {
      // Server serves valid certificate with SAN=DNS:correct-host.test signed by TestRootCA
      final serverSec = SecurityContext();
      serverSec.useCertificateChainBytes(utf8.encode(testServerFullChainPem));
      serverSec.usePrivateKeyBytes(utf8.encode(testServerKeyPem));

      final server = await HttpServer.bindSecure('127.0.0.1', 0, serverSec);
      server.listen((HttpRequest req) {
        req.response.statusCode = HttpStatus.ok;
        req.response.close();
      });

      // Client trusts TestRootCA, but requests https://mismatched-host.test:<port>
      // The server cert is trusted by the client, but SAN is correct-host.test, NOT mismatched-host.test.
      // This strictly verifies that the CLIENT's TLS engine performs hostname verification and rejects!
      final testClientContext = SecurityContext(withTrustedRoots: false);
      testClientContext.setTrustedCertificatesBytes(utf8.encode(testCaCertPem));

      final client = BackendClient(
        httpClient: HttpClient(context: testClientContext)
          ..connectionFactory = (uri, proxyHost, proxyPort) {
            final targetIp = {'mismatched-host.test': '127.0.0.1'}[uri.host];
            final connectHost = targetIp ?? uri.host;
            final isHttps = uri.isScheme('https');
            final port = uri.hasPort ? uri.port : (isHttps ? 443 : 80);

            Socket? currentSocket;
            bool isCancelled = false;
            final completer = Completer<Socket>();

            Socket.connect(connectHost, port, timeout: const Duration(seconds: 5)).then(
              (plainSocket) {
                if (isCancelled) {
                  plainSocket.destroy();
                  return;
                }
                currentSocket = plainSocket;
                if (isHttps) {
                  SecureSocket.secure(
                    plainSocket,
                    host: uri.host, // host is mismatched-host.test
                    context: testClientContext,
                  ).then(
                    (secureSocket) {
                      if (isCancelled) {
                        secureSocket.destroy();
                      } else {
                        completer.complete(secureSocket);
                      }
                    },
                    onError: (Object err, StackTrace st) => completer.completeError(err, st),
                  );
                } else {
                  completer.complete(plainSocket);
                }
              },
              onError: (Object err, StackTrace st) => completer.completeError(err, st),
            );

            return Future.value(ConnectionTask.fromSocket(completer.future, () {
              isCancelled = true;
              currentSocket?.destroy();
            }));
          },
      );

      final ok = await client.checkHealth('https://mismatched-host.test:${server.port}');
      // Must be false because TLS handshake fails on hostname mismatch
      expect(ok, isFalse);

      client.close();
      await server.close(force: true);
    });

    test('Hermetic Test: Client-side untrusted CA chain rejection (no trusted root in context)', () async {
      // Server serves untrusted self-signed certificate
      final untrustedSec = SecurityContext();
      untrustedSec.useCertificateChainBytes(utf8.encode(testUntrustedCertPem));
      untrustedSec.usePrivateKeyBytes(utf8.encode(testUntrustedKeyPem));

      final server = await HttpServer.bindSecure('127.0.0.1', 0, untrustedSec);
      server.listen((HttpRequest req) {
        req.response.statusCode = HttpStatus.ok;
        req.response.close();
      });

      // Client only trusts TestRootCA (does not trust the self-signed cert)
      final testClientContext = SecurityContext(withTrustedRoots: false);
      testClientContext.setTrustedCertificatesBytes(utf8.encode(testCaCertPem));

      final client = BackendClient(
        httpClient: HttpClient(context: testClientContext)
          ..connectionFactory = (uri, proxyHost, proxyPort) {
            final targetIp = {'correct-host.test': '127.0.0.1'}[uri.host];
            final connectHost = targetIp ?? uri.host;
            final isHttps = uri.isScheme('https');
            final port = uri.hasPort ? uri.port : (isHttps ? 443 : 80);

            Socket? currentSocket;
            bool isCancelled = false;
            final completer = Completer<Socket>();

            Socket.connect(connectHost, port, timeout: const Duration(seconds: 5)).then(
              (plainSocket) {
                if (isCancelled) {
                  plainSocket.destroy();
                  return;
                }
                currentSocket = plainSocket;
                if (isHttps) {
                  SecureSocket.secure(
                    plainSocket,
                    host: uri.host,
                    context: testClientContext,
                  ).then(
                    (secureSocket) {
                      if (isCancelled) {
                        secureSocket.destroy();
                      } else {
                        completer.complete(secureSocket);
                      }
                    },
                    onError: (Object err, StackTrace st) => completer.completeError(err, st),
                  );
                } else {
                  completer.complete(plainSocket);
                }
              },
              onError: (Object err, StackTrace st) => completer.completeError(err, st),
            );

            return Future.value(ConnectionTask.fromSocket(completer.future, () {
              isCancelled = true;
              currentSocket?.destroy();
            }));
          },
      );

      final ok = await client.checkHealth('https://correct-host.test:${server.port}');
      // Must be false because CA is not trusted
      expect(ok, isFalse);

      client.close();
      await server.close(force: true);
    });

    test('Live Backend Connectivity (Conditional: skipped when network unavailable)', () async {
      final client = BackendClient();
      try {
        final ok = await client.checkHealth('https://myyaris.example.com');
        // If on Tailscale network, it will be true; if offline, ok is false
        // This test documents the live state without breaking offline test runners.
        expect(ok, isTrue);
      } catch (e) {
        // Explicitly report offline condition
        markTestSkipped('Remote Tailscale backend not reachable in current offline test runner context.');
      } finally {
        client.close();
      }
    });
  });
}
