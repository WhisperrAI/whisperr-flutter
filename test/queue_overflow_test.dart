import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/whisperr.dart';

WhisperrClient overflowClient(
    MockClient transport, WhisperrPersistence persistence,
    {int capacity = 3}) {
  return WhisperrClient(
    apiClient: WhisperrApiClient(
      httpClient: transport,
      baseUrl: 'https://example.test',
      apiKey: 'test',
      sdkVersion: 'test',
    ),
    persistence: persistence,
    options: WhisperrOptions(
      flushInterval: const Duration(hours: 1),
      flushAt: 3,
      maxBatchSize: 3,
      maxQueueSize: capacity,
      flushOnLifecyclePause: false,
      trackAutomaticEvents: false,
    ),
    deviceTraits: () => {},
    appContext: () async => const <String, Object?>{},
  );
}

Future<List<dynamic>> persistedQueue(WhisperrPersistence store) async =>
    jsonDecode((await store.load(WhisperrPersistence.queueSlot))!) as List;

void main() {
  for (final status in [200, 400]) {
    for (final nextUser in ['new-user', 'old-user']) {
      test('protected identify $status cannot remove $nextUser replacement work',
          () async {
        final nextToken = nextUser == 'old-user' ? 'old-token' : 'new-token';
        final started = Completer<void>();
        final response = Completer<http.Response>();
        final identifies = <Map<String, dynamic>>[];
        final events = <dynamic>[];
        final store = InMemoryPersistence();
        final client = overflowClient(MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path == '/v1/identify') {
            identifies.add(body);
            if (identifies.length == 1) {
              started.complete();
              return response.future;
            }
            return http.Response('{}', 200);
          }
          final batch = body['events'] as List;
          events.addAll(batch);
          return http.Response(
              jsonEncode({'accepted': batch.length, 'rejected': 0}), 202);
          // Room for the two identifies reset() adds to move the token.
        }), store, capacity: 5);
        addTearDown(() async {
          if (!response.isCompleted) {
            response.complete(http.Response('{}', 400));
          }
          await client.close();
        });
        await client.start();
        await client.identify('old-user', pushToken: 'old-token');
        await started.future;
        for (var i = 1; i <= 3; i++) {
          await client.track('old_event_$i', userId: 'old-user');
        }
        expect(client.pendingCount, 4);

        // reset() queues the token's opt-out under old-user and its opt-in
        // under the new anonymous handle; capacity evicts old events.
        await client.reset(flushBeforeReset: false);
        await client.identify(nextUser, pushToken: nextToken);
        final queued = await persistedQueue(store);
        expect(queued, hasLength(5));
        final expectedEvents = queued
            .map((op) => op['body'])
            .where((body) => body['event_type'] != null)
            .toList();
        expect(expectedEvents.map((body) => body['event_type']),
            ['old_event_3']);

        response.complete(http.Response('{}', status));
        await client.flush();
        expect(events, expectedEvents,
            reason: 'Only capacity-evicted operations may be lost.');
        expect(identifies.map((body) => body['external_user_id']),
            ['old-user', 'old-user', null, nextUser]);
        expect(identifies[2]['anonymous_id'], isNotNull);
        expect(client.currentUserId, nextUser);
        expect(client.pendingCount, 0);
        expect(await persistedQueue(store), isEmpty);

        // An old rejected registration must not clear a replacement push mark,
        // even when the same account logs in again with the same token.
        await client.setPushToken(nextToken);
        await client.flush();
        expect(identifies, hasLength(4));
        final pair =
            jsonDecode((await store.load(WhisperrPersistence.pushSlot))!)
                as Map<String, dynamic>;
        expect(pair['user_id'], nextUser);
        expect(pair['token'], nextToken);
      });
    }
  }

  for (final status in [202, 400]) {
    for (final added in [1, 3]) {
      test(
          'in-flight batch $status with $added evictions retains unsent events',
          () async {
        final started = Completer<void>();
        final response = Completer<http.Response>();
        final batches = <List<dynamic>>[];
        final store = InMemoryPersistence();
        final client = overflowClient(MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final batch = body['events'] as List;
          batches.add(batch);
          if (batches.length == 1) {
            started.complete();
            return response.future;
          }
          return http.Response(
              jsonEncode({'accepted': batch.length, 'rejected': 0}), 202);
        }), store);
        addTearDown(() async {
          if (!response.isCompleted) {
            response.complete(http.Response('{}', 400));
          }
          await client.close();
        });
        await client.start();
        for (var i = 1; i <= 3; i++) {
          await client.track('sent_$i', userId: 'old-user');
        }
        await started.future;
        for (var i = 1; i <= added; i++) {
          await client.track('new_$i', userId: 'new-user');
          expect(client.pendingCount, 3);
        }
        final queuedBodies =
            (await persistedQueue(store)).map((op) => op['body']).toList();
        final expected = status == 400
            ? queuedBodies
            : queuedBodies
                .where(
                    (body) => (body['event_type'] as String).startsWith('new_'))
                .toList();

        response.complete(http.Response(
            status == 202 ? '{"accepted":3,"rejected":0}' : '{}', status));
        await client.flush();
        expect(batches.skip(1).expand((batch) => batch).toList(), expected,
            reason: 'Late acknowledgment/drop applies to original IDs only.');
        expect(client.pendingCount, 0);
        expect(await persistedQueue(store), isEmpty);
      });
    }
  }
}
