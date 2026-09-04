import 'package:amplitude_flutter/desktop/desktop_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('DesktopTransport client lifecycle', () {
    test('owned client is reused across accesses', () {
      final transport = DesktopTransport();
      expect(transport.client, same(transport.client));
      transport.close();
    });

    test('close resets the cached owned client', () {
      final transport = DesktopTransport();
      final first = transport.client;
      transport.close();
      expect(transport.client, isNot(same(first)));
      transport.close();
    });

    test('injected clients are used directly and never closed', () async {
      var closed = false;
      final injected = _CloseTrackingClient(() => closed = true);
      final transport = DesktopTransport(client: injected);
      expect(transport.client, same(injected));
      transport.close();
      expect(closed, isFalse);
    });
  });
}

class _CloseTrackingClient extends http.BaseClient {
  _CloseTrackingClient(this.onClose);

  final void Function() onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return MockClient((_) async => http.Response('{}', 200)).send(request);
  }

  @override
  void close() {
    onClose();
    super.close();
  }
}
