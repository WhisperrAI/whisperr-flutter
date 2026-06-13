import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/whisperr.dart';

const _fastOptions = WhisperrOptions(
  flushOnLifecyclePause: false,
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
  );
}

void main() {
  test('identify posts a normalized body to /v1/identify with auth header', () async {
    final requests = <http.Request>[];
    final mock = MockClient((req) async {
      requests.add(req);
      return http.Response('{"user":{"id":"usr_1","external_id":"u1","created":true}}', 200);
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
    expect((body['channels'] as List).first, {'channel': 'email', 'address': 'a@b.com', 'verified': true});
    expect(client.currentUserId, 'u1');
  });

  test('email/phone shortcuts expand into opted-in channels', () async {
    final requests = <http.Request>[];
    final mock = MockClient((req) async {
      requests.add(req);
      return http.Response('{"user":{"id":"usr_1","external_id":"u1","created":true}}', 200);
    });
    final client = buildClient(mock);
    addTearDown(client.close);
    await client.start();

    await client.identify('u1', email: 'ada@example.com', phone: '+15551234567');
    await client.flush();

    final body = jsonDecode(requests.first.body) as Map<String, dynamic>;
    final channels = (body['channels'] as List).cast<Map<String, dynamic>>();
    expect(channels, hasLength(2));
    expect(channels[0], {'channel': 'email', 'address': 'ada@example.com', 'opted_in': true});
    expect(channels[1], {'channel': 'sms', 'address': '+15551234567', 'opted_in': true});
    expect(body.containsKey('preferred_channel'), isFalse);
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
    await client.track('checkout_completed', properties: {'amount': 42}, userId: 'u1');
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

  test('track without a user throws', () async {
    final mock = MockClient((req) async => http.Response('{}', 202));
    final client = buildClient(mock);
    addTearDown(client.close);
    await client.start();

    expect(() => client.track('opened_app'), throwsStateError);
  });

  test('a failed flush keeps the queue and persists it; a fresh client restores and delivers', () async {
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

    expect(await store.load(), isNotNull);

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
      return http.Response('{"error":{"code":"invalid_request","message":"bad"}}', 400);
    });
    final client = buildClient(mock);
    addTearDown(client.close);
    await client.start();

    await client.track('opened_app', userId: 'u1');
    await client.flush();

    expect(client.pendingCount, 0);
  });

  test('an auth error pauses delivery and keeps the queue', () async {
    final mock = MockClient((req) async {
      return http.Response('{"error":{"code":"invalid_api_key","message":"nope"}}', 401);
    });
    final client = buildClient(mock);
    addTearDown(client.close);
    await client.start();

    await client.track('opened_app', userId: 'u1');
    await client.flush();

    expect(client.pendingCount, 1); // retained for a later flush once the key is fixed
  });

  test('reaching flushAt triggers an automatic flush', () async {
    var batches = 0;
    final mock = MockClient((req) async {
      batches++;
      return http.Response('{"accepted":3,"rejected":0}', 202);
    });
    final client = buildClient(
      mock,
      options: const WhisperrOptions(flushAt: 3, flushOnLifecyclePause: false),
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

  test('identify is delivered before subsequent tracks (ordered queue)', () async {
    final paths = <String>[];
    final mock = MockClient((req) async {
      paths.add(req.url.path);
      final ok = req.url.path.endsWith('identify') ? '{"user":{"id":"x","external_id":"u1","created":true}}' : '{"accepted":1,"rejected":0}';
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
}
