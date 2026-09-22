import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/whisperr.dart';

class ControlledPersistence extends InMemoryPersistence {
  bool rejectQueue = false;
  Completer<void>? gate;
  int writes = 0;
  int concurrentWrites = 0;
  int maxConcurrentWrites = 0;
  @override
  Future<void> save(String slot, String data) async {
    if (slot != WhisperrPersistence.queueSlot) return super.save(slot, data);
    writes++;
    concurrentWrites++;
    if (concurrentWrites > maxConcurrentWrites) {
      maxConcurrentWrites = concurrentWrites;
    }
    try {
      final blocked = gate;
      gate = null;
      if (blocked != null) await blocked.future;
      if (rejectQueue) throw StateError('storage unavailable');
      await super.save(slot, data);
    } finally {
      concurrentWrites--;
    }
  }
}

WhisperrClient makeClient(WhisperrPersistence persistence,
        {int capacity = 3, bool enabled = true}) =>
    WhisperrClient(
      apiClient: WhisperrApiClient(
          httpClient: MockClient((_) async => http.Response('{}', 401)),
          baseUrl: 'https://example.test',
          apiKey: 'test',
          sdkVersion: 'test'),
      persistence: persistence,
      options: WhisperrOptions(
          flushAt: 1,
          maxQueueSize: capacity,
          enablePersistence: enabled,
          flushOnLifecyclePause: false,
          flushInterval: const Duration(hours: 1)),
      deviceTraits: () => {},
    );

Future<List<dynamic>> queue(WhisperrPersistence store) async =>
    jsonDecode(await store.load(WhisperrPersistence.queueSlot) ?? '[]') as List;

void main() {
  test('strict identify rejects failed storage without accepting partial queue',
      () async {
    final store = ControlledPersistence();
    final client = makeClient(store);
    addTearDown(client.close);
    await client.start();
    await client.identify('123',
        requirePersistence: true,
        channels: [WhisperrChannel.push('old', optedIn: true)]);
    final before = await store.load(WhisperrPersistence.queueSlot);
    store.rejectQueue = true;
    await expectLater(
        client.identify('123',
            requirePersistence: true,
            channels: [WhisperrChannel.push('old', optedIn: false)]),
        throwsStateError);
    expect(client.pendingCount, 1);
    expect(await store.load(WhisperrPersistence.queueSlot), before);
    store.rejectQueue = false;
    await client.identify('123',
        requirePersistence: true,
        channels: [WhisperrChannel.push('old', optedIn: false)]);
    expect(client.pendingCount, 2);
  });

  test('revocation survives telemetry overflow and process restart', () async {
    final store = ControlledPersistence();
    final client = makeClient(store);
    addTearDown(client.close);
    await client.start();
    await client.identify('123',
        requirePersistence: true,
        channels: [WhisperrChannel.push('token', optedIn: false)]);
    for (var i = 0; i < 20; i++) {
      await client.track('event_$i', userId: '123');
      expect(client.pendingCount, lessThanOrEqualTo(3));
    }
    final persisted = await queue(store);
    expect(persisted.first['kind'], 'identify');
    expect(persisted.first['body']['channels'][0]['opted_in'], false);
    final restored = makeClient(store);
    addTearDown(restored.close);
    await restored.start();
    expect(restored.pendingCount, 3);
    expect((await queue(store)).first, persisted.first);
  });

  test('full protected queue rejects new identify and drops incoming telemetry',
      () async {
    final store = ControlledPersistence();
    final client = makeClient(store, capacity: 2);
    addTearDown(client.close);
    await client.start();
    await client.identify('123', requirePersistence: true);
    await client.identify('456', requirePersistence: true);
    final before = await store.load(WhisperrPersistence.queueSlot);
    await expectLater(
        client.identify('789', requirePersistence: true), throwsStateError);
    await client.track('excess', userId: '789');
    expect(client.pendingCount, 2);
    expect(await store.load(WhisperrPersistence.queueSlot), before);
  });

  test('queue saves serialize concurrent operations without stale overwrites',
      () async {
    final store = ControlledPersistence();
    final client = makeClient(store);
    addTearDown(client.close);
    await client.start();
    final gate = Completer<void>();
    store.gate = gate;
    final first = client.track('first', userId: '123');
    await Future<void>.delayed(Duration.zero);
    final second = client.track('second', userId: '123');
    await Future<void>.delayed(Duration.zero);
    expect(store.writes, 1);
    gate.complete();
    await Future.wait([first, second]);
    expect(store.maxConcurrentWrites, 1);
    expect((await queue(store)).map((op) => op['body']['event_type']),
        ['first', 'second']);
  });

  test('strict identify refuses explicitly disabled persistence', () async {
    final client = makeClient(InMemoryPersistence(), enabled: false);
    addTearDown(client.close);
    await client.start();
    await expectLater(
        client.identify('123', requirePersistence: true), throwsStateError);
    expect(client.pendingCount, 0);
    expect(client.currentUserId, null);
  });
  test('failed strict grant does not suppress later token registration', () async {
    final store = ControlledPersistence()..rejectQueue = true;
    final client = makeClient(store);
    addTearDown(client.close);
    await client.start();
    await expectLater(client.identify('123', requirePersistence: true,
      channels: [WhisperrChannel.push('token', optedIn: true)]), throwsStateError);
    store.rejectQueue = false;
    await client.setPushToken('token');
    expect(client.pendingCount, 1);
    expect((await queue(store)).single['body']['channels'][0]['address'], 'token');
  });

  test('concurrent rotations revoke each previously accepted token', () async {
    final store = ControlledPersistence();
    final client = makeClient(store, capacity: 5);
    addTearDown(client.close);
    await client.start();
    await client.identify('123', requirePersistence: true,
      channels: [WhisperrChannel.push('a', optedIn: true)]);
    final gate = Completer<void>();
    store.gate = gate;
    final b = client.identify('123', requirePersistence: true,
      channels: [WhisperrChannel.push('b', optedIn: true)]);
    await Future<void>.delayed(Duration.zero);
    final c = client.setPushToken('c');
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await Future.wait([b, c]);
    final controls = await queue(store);
    expect(controls[1]['body']['channels'][0],
      {'channel': 'push', 'address': 'a', 'opted_in': false});
    expect(controls[2]['body']['channels'], [
      {'channel': 'push', 'address': 'b', 'opted_in': false},
      {'channel': 'push', 'address': 'c', 'opted_in': true},
    ]);
  });

}
