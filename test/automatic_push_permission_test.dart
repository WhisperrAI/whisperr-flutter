import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/whisperr.dart';

/// Automatic notification-permission reporting
/// (WhisperrOptions.automaticPushPermission and pushPermissionReader).
class _Harness {
  _Harness() {
    mock = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      if (req.url.path == '/v1/events/batch') {
        events.addAll((body['events'] as List).cast<Map<String, dynamic>>());
      }
      return http.Response('{}', 200);
    });
  }

  late final MockClient mock;
  final events = <Map<String, dynamic>>[];
  WhisperrPersistence persistence = InMemoryPersistence();

  /// What the OS reports; null means the reader cannot tell.
  WhisperrPushPermission? os = WhisperrPushPermission.granted;
  Object? readError;
  int reads = 0;

  Future<WhisperrPushPermission?> read() async {
    reads++;
    final error = readError;
    if (error != null) throw error;
    return os;
  }

  /// The `properties` of each push_permission_changed the server accepted.
  List<Object?> get permissionEvents => [
        for (final e in events)
          if (e['event_type'] == 'push_permission_changed')
            {
              'status': (e['properties'] as Map)['status'],
              if ((e['properties'] as Map).containsKey('previous_status'))
                'previous_status': (e['properties'] as Map)['previous_status'],
            },
      ];

  Future<WhisperrClient> start({
    bool automatic = true,
    bool withReader = true,
  }) async {
    final client = WhisperrClient(
      apiClient: WhisperrApiClient(
        httpClient: mock,
        baseUrl: 'https://api.test',
        apiKey: 'wrk_test',
        sdkVersion: 'test',
      ),
      persistence: persistence,
      options: WhisperrOptions(
        flushOnLifecyclePause: false,
        trackAutomaticEvents: false,
        automaticPushPermission: automatic,
        pushPermissionReader: withReader ? read : null,
        retryBaseDelay: const Duration(milliseconds: 1),
        maxRetryDelay: const Duration(milliseconds: 5),
        maxRetries: 0,
      ),
      clock: () => DateTime.utc(2026, 10, 5, 12),
      random: Random(7),
      deviceTraits: () => const <String, Object?>{},
      appContext: () async => const <String, Object?>{'platform': 'ios'},
    );
    addTearDown(client.close);
    await client.start();
    await settle(client);
    return client;
  }

  /// Lets the un-awaited permission read finish, then delivers the queue.
  Future<void> settle(WhisperrClient client) async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await client.flush();
  }

  Future<void> resume(WhisperrClient client) async {
    client.handleLifecycleState(AppLifecycleState.resumed);
    await settle(client);
  }
}

void main() {
  test('reads the permission after start and reports it', () async {
    final h = _Harness();
    final c = await h.start();
    expect(h.reads, 1);
    expect(h.permissionEvents, [
      {'status': 'authorized'}
    ]);
    expect(c.pushPermission, WhisperrPushPermission.granted);
  });

  test('reads again on resume and reports only a change', () async {
    final h = _Harness();
    final c = await h.start();
    await h.resume(c);
    expect(h.reads, 2);
    expect(h.permissionEvents, hasLength(1));

    h.os = WhisperrPushPermission.denied;
    await h.resume(c);
    expect(h.permissionEvents.last,
        {'status': 'denied', 'previous_status': 'authorized'});
    expect(c.pushPermission, WhisperrPushPermission.denied);
  });

  test('an unchanged OS answer does not override setPushPermission', () async {
    final h = _Harness();
    final c = await h.start();
    // The app knows better (for example its own notification switch).
    await c.setPushPermission(WhisperrPushPermission.denied);
    await c.flush();
    await h.resume(c);
    await h.resume(c);
    expect(h.permissionEvents, [
      {'status': 'authorized'},
      {'status': 'denied', 'previous_status': 'authorized'},
    ]);
    expect(c.pushPermission, WhisperrPushPermission.denied);
  });

  test('the manual value also stands across a restart', () async {
    final h = _Harness();
    final first = await h.start();
    await first.setPushPermission(WhisperrPushPermission.denied);
    await first.close();

    final second = await h.start();
    expect(h.reads, 2);
    expect(h.permissionEvents, hasLength(2));
    expect(second.pushPermission, WhisperrPushPermission.denied);
  });

  test('a changed OS answer reports over a manual value', () async {
    final h = _Harness();
    final c = await h.start();
    await c.setPushPermission(WhisperrPushPermission.denied);
    h.os = WhisperrPushPermission.provisional;
    await h.resume(c);
    expect(h.permissionEvents.last,
        {'status': 'provisional', 'previous_status': 'denied'});
  });

  test('automaticPushPermission: false reads nothing on its own', () async {
    final h = _Harness();
    final c = await h.start(automatic: false);
    await h.resume(c);
    expect(h.reads, 0);
    expect(h.permissionEvents, isEmpty);

    // refreshPushPermission() is explicit and still works.
    expect(await c.refreshPushPermission(), WhisperrPushPermission.granted);
    await c.flush();
    expect(h.permissionEvents, [
      {'status': 'authorized'}
    ]);
  });

  test('refreshPushPermission() reports right after an app prompt', () async {
    final h = _Harness();
    h.os = WhisperrPushPermission.undetermined;
    final c = await h.start();
    h.os = WhisperrPushPermission.granted; // the user said yes
    expect(await c.refreshPushPermission(), WhisperrPushPermission.granted);
    await c.flush();
    expect(h.permissionEvents, [
      {'status': 'not_determined'},
      {'status': 'authorized', 'previous_status': 'not_determined'},
    ]);
  });

  test('after reset() the next read reports again for the next user',
      () async {
    final h = _Harness();
    final c = await h.start();
    await c.identify('user_1');
    await c.reset();
    await h.resume(c);
    expect(h.permissionEvents, [
      {'status': 'authorized'},
      {'status': 'authorized'},
    ]);
  });

  test('while opted out nothing is read or sent', () async {
    final h = _Harness();
    final c = await h.start();
    await c.optOut();
    h.os = WhisperrPushPermission.denied;
    await h.resume(c);
    expect(await c.refreshPushPermission(), isNull);
    expect(h.reads, 1);

    await c.optIn();
    await h.resume(c);
    expect(h.permissionEvents.last,
        {'status': 'denied', 'previous_status': 'authorized'});
  });

  test('no reader, a null answer or a failing reader send nothing', () async {
    final none = _Harness();
    final c1 = await none.start(withReader: false);
    await none.resume(c1);
    expect(await c1.refreshPushPermission(), isNull);
    expect(none.permissionEvents, isEmpty);

    final unknown = _Harness()..os = null;
    final c2 = await unknown.start();
    await unknown.resume(c2);
    expect(unknown.permissionEvents, isEmpty);

    final failing = _Harness()..readError = StateError('no plugin');
    final c3 = await failing.start();
    expect(await c3.refreshPushPermission(), isNull);
    expect(failing.permissionEvents, isEmpty);
  });

  test('a reader set after start is used from the next resume', () async {
    final h = _Harness();
    final c = await h.start(withReader: false);
    c.pushPermissionReader = h.read;
    await h.resume(c);
    expect(h.permissionEvents, [
      {'status': 'authorized'}
    ]);
  });
}
