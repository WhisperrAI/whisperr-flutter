import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/whisperr.dart';

const _fastOptions = WhisperrOptions(
  flushOnLifecyclePause: false,
  trackAutomaticEvents: false,
  retryBaseDelay: Duration(milliseconds: 1),
  maxRetryDelay: Duration(milliseconds: 5),
  maxRetries: 2,
);

WhisperrClient buildClient(
  MockClient mock, {
  WhisperrPersistence? persistence,
  WhisperrOptions options = _fastOptions,
}) {
  final api = WhisperrApiClient(
    httpClient: mock,
    baseUrl: 'https://api.test',
    apiKey: 'wrk_test',
    sdkVersion: 'test',
  );
  return WhisperrClient(
    apiClient: api,
    persistence: persistence ?? InMemoryPersistence(),
    options: options,
    clock: () => DateTime.utc(2026, 5, 31, 12),
    random: Random(7),
    // Device-trait defaults are environment-dependent and never pinned by
    // the spec fixtures; device_traits_test.dart covers them.
    deviceTraits: () => const <String, Object?>{},
    // Harnesses run with the environment keys disabled.
    appContext: () async => const <String, Object?>{},
  );
}

void main() {
  test('interactive reset clears identity without waiting for stalled delivery', () async {
    final response = Completer<http.Response>();
    final client = buildClient(MockClient((_) => response.future));
    await client.start();
    await client.identify('old-user');
    await client.reset(flushBeforeReset: false).timeout(const Duration(seconds: 1));
    expect(client.currentUserId, isNull);
    await client.identify('new-user');
    response.complete(http.Response('{}', 200));
    await client.flush();
    expect(client.currentUserId, 'new-user');
    await client.close();
  });

  test('identify posts a normalized body to /v1/identify with auth header',
      () async {
    final requests = <http.Request>[];
    final mock = MockClient((req) async {
      requests.add(req);
      return http.Response(
          '{"user":{"id":"usr_1","external_id":"u1","created":true}}', 200);
    });
    final client = buildClient(mock);
    addTearDown(client.close);
    await client.start();

    await client.identify(
      ' u1 ',
      traits: {'plan': 'pro'},
      channels: [WhisperrChannel.email('a@b.com', verified: true)],
    );
    await client.flush();

    expect(requests, hasLength(1));
    expect(requests.first.url.path, '/v1/identify');
    expect(requests.first.headers['Authorization'], 'Bearer wrk_test');
    expect(requests.first.headers['X-Whisperr-Sdk'], 'flutter/test');

    final body = jsonDecode(requests.first.body) as Map<String, dynamic>;
    expect(body['external_user_id'], 'u1');
    expect(body['traits'], {'plan': 'pro'});
    expect(body.containsKey('preferred_channel'), isFalse);
    expect((body['channels'] as List).first,
        {'channel': 'email', 'address': 'a@b.com', 'verified': true});
    expect(client.currentUserId, 'u1');
  });

  test('email/phone shortcuts: email claims no consent, phone is opted in',
      () async {
    final requests = <http.Request>[];
    final mock = MockClient((req) async {
      requests.add(req);
      return http.Response(
          '{"user":{"id":"usr_1","external_id":"u1","created":true}}', 200);
    });
    final client = buildClient(mock);
    addTearDown(client.close);
    await client.start();

    await client.identify('u1',
        email: 'ada@example.com', phone: '+15551234567');
    await client.flush();

    final body = jsonDecode(requests.first.body) as Map<String, dynamic>;
    final channels = (body['channels'] as List).cast<Map<String, dynamic>>();
    expect(channels, hasLength(2));
    expect(channels[0], {'channel': 'email', 'address': 'ada@example.com'});
    expect(channels[1],
        {'channel': 'sms', 'address': '+15551234567', 'opted_in': true});
    expect(body.containsKey('preferred_channel'), isFalse);
  });

  for (final optedIn in [true, false]) {
    test('emailOptedIn: $optedIn is sent as opted_in on the email shortcut',
        () async {
      final requests = <http.Request>[];
      final mock = MockClient((req) async {
        requests.add(req);
        return http.Response(
            '{"user":{"id":"usr_1","external_id":"u1","created":true}}', 200);
      });
      final client = buildClient(mock);
      addTearDown(client.close);
      await client.start();

      await client.identify('u1',
          email: 'ada@example.com', emailOptedIn: optedIn);
      await client.flush();

      final body = jsonDecode(requests.first.body) as Map<String, dynamic>;
      expect(body['channels'], [
        {'channel': 'email', 'address': 'ada@example.com', 'opted_in': optedIn}
      ]);
    });
  }

  test('emailOptedIn without an email sends no channel', () async {
    final requests = <http.Request>[];
    final mock = MockClient((req) async {
      requests.add(req);
      return http.Response(
          '{"user":{"id":"usr_1","external_id":"u1","created":true}}', 200);
    });
    final client = buildClient(mock);
    addTearDown(client.close);
    await client.start();

    await client.identify('u1', emailOptedIn: true);
    await client.flush();

    final body = jsonDecode(requests.first.body) as Map<String, dynamic>;
    expect(body.containsKey('channels'), isFalse);
  });

  test('track buffers events and flushes them as a single batch', () async {
    final requests = <http.Request>[];
    final mock = MockClient((req) async {
      requests.add(req);
      return http.Response('{"accepted":2,"rejected":0}', 202);
    });
    final client = buildClient(mock);
    addTearDown(client.close);
    await client.start();

    await client.track('opened_app', userId: 'u1');
    await client.track('checkout_completed',
        properties: {'amount': 42}, userId: 'u1');
    expect(client.pendingCount, 2);

    await client.flush();

    expect(requests, hasLength(1));
    expect(requests.first.url.path, '/v1/events/batch');
    final body = jsonDecode(requests.first.body) as Map<String, dynamic>;
    final events = body['events'] as List;
    expect(events, hasLength(2));
    expect(events[0]['event_type'], 'opened_app');
    expect(events[0]['occurred_at'], '2026-05-31T12:00:00.000Z');
    expect(events[1]['properties'], {'amount': 42});
    // Each event carries a unique idempotency key for server-side dedup.
    final firstMessageId = events[0]['context'][r'$message_id'] as String;
    final secondMessageId = events[1]['context'][r'$message_id'] as String;
    expect(firstMessageId, isNotEmpty);
    expect(firstMessageId, isNot(secondMessageId));
    expect(client.pendingCount, 0);
  });

  test('track without a user is sent under the anonymous id, never throws',
      () async {
    final requests = <http.Request>[];
    final mock = MockClient((req) async {
      requests.add(req);
      return http.Response('{"accepted":1,"rejected":0}', 202);
    });
    final client = buildClient(mock);
    addTearDown(client.close);
    await client.start();

    await client.track('opened_app');
    await client.flush();

    final event = ((jsonDecode(requests.single.body) as Map)['events'] as List)
        .single as Map;
    expect(event.containsKey('external_user_id'), isFalse);
    expect(event['anonymous_id'], client.anonymousId);
    expect(client.anonymousId, isNotNull);
  });

  test('invalid event_type is dropped before it can poison a batch', () async {
    final requests = <http.Request>[];
    final errors = <WhisperrError>[];
    final mock = MockClient((req) async {
      requests.add(req);
      return http.Response('{"accepted":1,"rejected":0}', 202);
    });
    final client = buildClient(
      mock,
      options: WhisperrOptions(
        flushOnLifecyclePause: false,
        trackAutomaticEvents: false,
        retryBaseDelay: const Duration(milliseconds: 1),
        maxRetryDelay: const Duration(milliseconds: 5),
        maxRetries: 2,
        onError: errors.add,
      ),
    );
    addTearDown(client.close);
    await client.start();

    await client.track('User Signed Up', userId: 'u1');
    await client.track('checkout_completed', userId: 'u1');
    await client.flush();

    expect(errors.any((e) => e.type == 'dropped'), isTrue);
    final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
    final events = body['events'] as List;
    expect(events, hasLength(1));
    expect(events.first['event_type'], 'checkout_completed');
  });

  test(
      'a failed flush keeps the queue and persists it; a fresh client restores and delivers',
      () async {
    final store = InMemoryPersistence();
    final requests = <http.Request>[];
    var online = false;
    final mock = MockClient((req) async {
      if (!online) throw Exception('offline');
      requests.add(req);
      return http.Response('{"accepted":1,"rejected":0}', 202);
    });

    final c1 = buildClient(mock, persistence: store);
    await c1.start();
    await c1.track('opened_app', userId: 'u1');
    await c1.flush(); // offline: retries then gives up
    expect(c1.pendingCount, 1);
    await c1.close();

    expect(await store.load(WhisperrPersistence.queueSlot), isNotNull);

    online = true;
    final c2 = buildClient(mock, persistence: store);
    addTearDown(c2.close);
    await c2.start();
    await c2.flush();

    expect(requests, hasLength(1));
    expect(c2.pendingCount, 0);
  });

  test('a permanent client error (400) drops the offending op', () async {
    final mock = MockClient((req) async {
      return http.Response(
          '{"error":{"code":"invalid_request","message":"bad"}}', 400);
    });
    final client = buildClient(mock);
    addTearDown(client.close);
    await client.start();

    await client.track('opened_app', userId: 'u1');
    await client.flush();

    expect(client.pendingCount, 0);
  });

  group('rejected requests warn without debug', () {
    Future<List<String>> capturePrints(Future<void> Function() body) async {
      final prints = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) prints.add(message);
      };
      try {
        await body();
      } finally {
        debugPrint = original;
      }
      return prints;
    }

    String warning(int status) =>
        '[whisperr] dropped a request: the server rejected it with $status. '
        'Later rejections with this status are reported through onError, '
        'or here with debug on.';

    test('once per status code, and every drop reaches onError', () async {
      var status = 400;
      final errors = <WhisperrError>[];
      final client = buildClient(
        MockClient((_) async => http.Response(
            '{"error":{"code":"invalid_request","message":"bad"}}', status)),
        options: WhisperrOptions(
          flushOnLifecyclePause: false,
          trackAutomaticEvents: false,
          retryBaseDelay: const Duration(milliseconds: 1),
          maxRetryDelay: const Duration(milliseconds: 5),
          maxRetries: 2,
          onError: errors.add,
        ),
      );
      addTearDown(client.close);
      await client.start();

      final prints = await capturePrints(() async {
        await client.track('first_event', userId: 'u1');
        await client.flush();
        await client.track('second_event', userId: 'u1');
        await client.flush();
        status = 422;
        await client.track('third_event', userId: 'u1');
        await client.flush();
      });

      expect(prints.where((m) => m.contains('rejected')),
          [warning(400), warning(422)]);
      expect(
        errors.where((e) => e.type == 'dropped').map((e) => e.status),
        [400, 400, 422],
      );
      expect(client.pendingCount, 0);
    });

    test('with debug on, every drop is logged', () async {
      final client = buildClient(
        MockClient((_) async => http.Response(
            '{"error":{"code":"invalid_request","message":"bad"}}', 400)),
        options: const WhisperrOptions(
          flushOnLifecyclePause: false,
          trackAutomaticEvents: false,
          debug: true,
        ),
      );
      addTearDown(client.close);
      await client.start();

      final prints = await capturePrints(() async {
        await client.track('first_event', userId: 'u1');
        await client.flush();
        await client.track('second_event', userId: 'u1');
        await client.flush();
      });

      expect(prints.where((m) => m.contains('dropping op')), hasLength(2));
      expect(prints.where((m) => m.startsWith('[whisperr] dropped a request')),
          isEmpty);
    });

    for (final status in [429, 503]) {
      test('a $status is kept for retry without a drop warning', () async {
        var code = status;
        final errors = <WhisperrError>[];
        final client = buildClient(
          MockClient((_) async => http.Response('{}', code)),
          options: WhisperrOptions(
            flushOnLifecyclePause: false,
            trackAutomaticEvents: false,
            retryBaseDelay: const Duration(milliseconds: 1),
            maxRetryDelay: const Duration(milliseconds: 5),
            maxRetries: 0,
            onError: errors.add,
          ),
        );
        addTearDown(client.close);
        await client.start();

        final prints = await capturePrints(() async {
          await client.track('feature_used', userId: 'u1');
          await client.flush();
        });

        expect(prints.where((m) => m.contains('rejected')), isEmpty);
        expect(errors.where((e) => e.type == 'dropped'), isEmpty);
        expect(client.pendingCount, 1);

        code = 202;
        await client.flush();
        expect(client.pendingCount, 0);
      });
    }
  });

  test('an auth error pauses delivery and keeps the queue', () async {
    final mock = MockClient((req) async {
      return http.Response(
          '{"error":{"code":"invalid_api_key","message":"nope"}}', 401);
    });
    final client = buildClient(mock);
    addTearDown(client.close);
    await client.start();

    await client.track('opened_app', userId: 'u1');
    await client.flush();

    expect(client.pendingCount,
        1); // retained for a later flush once the key is fixed
  });

  test('reaching flushAt triggers an automatic flush', () async {
    var batches = 0;
    final mock = MockClient((req) async {
      batches++;
      return http.Response('{"accepted":3,"rejected":0}', 202);
    });
    final client = buildClient(
      mock,
      options: const WhisperrOptions(
          flushAt: 3,
          flushOnLifecyclePause: false,
          trackAutomaticEvents: false),
    );
    addTearDown(client.close);
    await client.start();

    await client.track('e1', userId: 'u1');
    await client.track('e2', userId: 'u1');
    await client.track('e3', userId: 'u1'); // hits flushAt
    await client.flush(); // join the in-flight auto-flush

    expect(batches, 1);
    expect(client.pendingCount, 0);
  });

  test(
      'reset moves the token to the new anonymous handle; identify attaches it',
      () async {
    final store = InMemoryPersistence();
    final identifies = <Map<String, dynamic>>[];
    final mock = MockClient((req) async {
      if (req.url.path == '/v1/identify') {
        identifies.add(jsonDecode(req.body) as Map<String, dynamic>);
      }
      return http.Response(
          '{"user":{"id":"x","external_id":"u1","created":true}}', 200);
    });

    final c1 = buildClient(mock, persistence: store);
    await c1.start();
    await c1.identify('u1');
    await c1.setPushToken('tok_a');
    await c1.reset(); // logout: the token moves to a new anonymous handle
    final anon = c1.anonymousId;
    await c1.close();
    expect(anon, isNotNull);

    final c2 = buildClient(mock, persistence: store);
    addTearDown(c2.close);
    await c2.start();
    expect(c2.currentUserId, isNull); // reset cleared the persisted identity
    expect(c2.anonymousId, anon);

    await c2.identify('u2'); // attaches the token the device holds
    await c2.setPushToken('tok_a'); // already sent for u2: no-op
    await c2.flush();

    expect(identifies, [
      {'external_user_id': 'u1'},
      {
        'external_user_id': 'u1',
        'channels': [
          {'channel': 'push', 'address': 'tok_a', 'opted_in': true}
        ],
      },
      {
        'external_user_id': 'u1',
        'channels': [
          {'channel': 'push', 'address': 'tok_a', 'opted_in': false}
        ],
      },
      {
        'anonymous_id': anon,
        'channels': [
          {'channel': 'push', 'address': 'tok_a', 'opted_in': true}
        ],
      },
      {
        'external_user_id': 'u2',
        'anonymous_id': anon,
        'channels': [
          {'channel': 'push', 'address': 'tok_a', 'opted_in': true}
        ],
      },
    ]);
  });

  test(
      'a token buffered before identify that matches the restored pair is not re-sent',
      () async {
    final store = InMemoryPersistence();
    final identifies = <Map<String, dynamic>>[];
    final mock = MockClient((req) async {
      if (req.url.path == '/v1/identify') {
        identifies.add(jsonDecode(req.body) as Map<String, dynamic>);
      }
      return http.Response(
          '{"user":{"id":"x","external_id":"u1","created":true}}', 200);
    });

    final c1 = buildClient(mock, persistence: store);
    await c1.start();
    await c1.identify('u1');
    await c1.setPushToken('tok_a');
    await c1.close();

    // Relaunch where getToken() fires before the client starts: the token is
    // buffered, then identify() must NOT re-attach it — the restored last-sent
    // pair says this exact (user, token) was already delivered.
    final c2 = buildClient(mock, persistence: store);
    addTearDown(c2.close);
    await c2.setPushToken('tok_a'); // buffered (no user known yet)
    await c2.start();
    await c2.identify('u1');
    await c2.flush();

    // identify #1, push partial identify, identify #3 (no push channel).
    expect(identifies, hasLength(3));
    expect(identifies.last, {'external_user_id': 'u1'});
  });

  test('identify is delivered before subsequent tracks (ordered queue)',
      () async {
    final paths = <String>[];
    final mock = MockClient((req) async {
      paths.add(req.url.path);
      final ok = req.url.path.endsWith('identify')
          ? '{"user":{"id":"x","external_id":"u1","created":true}}'
          : '{"accepted":1,"rejected":0}';
      return http.Response(ok, req.url.path.endsWith('identify') ? 200 : 202);
    });
    final client = buildClient(mock);
    addTearDown(client.close);
    await client.start();

    await client.identify('u1');
    await client.track('opened_app');
    await client.flush();

    expect(paths, ['/v1/identify', '/v1/events/batch']);
  });

  test('setPushToken silently ignores empty/whitespace tokens', () async {
    final identifies = <Map<String, dynamic>>[];
    final mock = MockClient((req) async {
      if (req.url.path == '/v1/identify') {
        identifies.add(jsonDecode(req.body) as Map<String, dynamic>);
      }
      return http.Response(
          '{"user":{"id":"x","external_id":"u1","created":true}}', 200);
    });
    final client = buildClient(mock);
    addTearDown(client.close);
    await client.start();

    await client.identify('u1');
    await client.flush();
    identifies.clear();
    // No throw, no request — safe to call every launch before getToken() is ready.
    await client.setPushToken('');
    await client.setPushToken('   ');
    await client.flush();

    expect(identifies, isEmpty);
  });

  test('attachPushTokenStream forwards tokens and survives a source error',
      () async {
    final identifies = <Map<String, dynamic>>[];
    final mock = MockClient((req) async {
      if (req.url.path == '/v1/identify') {
        identifies.add(jsonDecode(req.body) as Map<String, dynamic>);
      }
      return http.Response(
          '{"user":{"id":"x","external_id":"u1","created":true}}', 200);
    });
    final client = buildClient(mock);
    addTearDown(client.close);
    await client.start();
    await client.identify('u1');
    await client.flush();
    identifies.clear();

    final controller = StreamController<String>();
    client.attachPushTokenStream(controller.stream);

    // A source error must be handled, not surface as an uncaught zone error
    // (which would fail this test).
    controller.addError(StateError('token source blew up'));
    await Future<void>.delayed(Duration.zero);
    controller.add('fcm_tok_a');
    await Future<void>.delayed(Duration.zero);
    await client.flush();
    await controller.close();

    expect(identifies, hasLength(1));
    expect(identifies.first['channels'], [
      {'channel': 'push', 'address': 'fcm_tok_a', 'opted_in': true}
    ]);
  });

  test('close() cancels attached push-token subscriptions', () async {
    final identifies = <Map<String, dynamic>>[];
    final mock = MockClient((req) async {
      if (req.url.path == '/v1/identify') {
        identifies.add(jsonDecode(req.body) as Map<String, dynamic>);
      }
      return http.Response(
          '{"user":{"id":"x","external_id":"u1","created":true}}', 200);
    });
    final client = buildClient(mock);
    await client.start();
    await client.identify('u1');

    final controller = StreamController<String>();
    client.attachPushTokenStream(controller.stream);
    await client.close();
    identifies.clear();

    // Emitting after close() must be inert — the subscription was cancelled, so
    // setPushToken is never invoked on the dead client (no throw, no request).
    controller.add('fcm_tok_late');
    await Future<void>.delayed(Duration.zero);
    await controller.close();

    expect(identifies, isEmpty);
  });

  test('a dropped push registration clears the dedupe mark so it re-sends',
      () async {
    var rejectPush = true;
    final pushBodies = <Map<String, dynamic>>[];
    final mock = MockClient((req) async {
      if (req.url.path == '/v1/identify') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        if (body.containsKey('channels')) {
          pushBodies.add(body);
          if (rejectPush) {
            return http.Response(
                '{"error":{"code":"invalid_request","message":"bad"}}', 400);
          }
        }
      }
      return http.Response(
          '{"user":{"id":"x","external_id":"u1","created":true}}', 200);
    });
    final client = buildClient(mock);
    addTearDown(client.close);
    await client.start();

    await client.identify('u1');
    await client.setPushToken('fcm_tok_a'); // 400 → dropped, mark cleared
    await client.flush();
    expect(pushBodies, hasLength(1));

    rejectPush = false;
    pushBodies.clear();
    await client.setPushToken('fcm_tok_a'); // same token — must re-send
    await client.flush();

    expect(pushBodies, hasLength(1));
    expect(pushBodies.first['channels'], [
      {'channel': 'push', 'address': 'fcm_tok_a', 'opted_in': true}
    ]);
  });
}
