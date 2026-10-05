import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/src/api_client.dart' show parseRetryAfter;
import 'package:whisperr/src/app_context.dart' show isIanaTimezone;
import 'package:whisperr/src/os_version_io.dart' show parseOsVersion;
import 'package:whisperr/whisperr.dart';

const _appContext = <String, Object?>{
  'app_version': '1.2.0',
  'app_build': '42',
  'os_name': 'ios',
  'os_version': '17.4',
  'platform': 'ios',
};

const _deviceTraits = <String, Object?>{
  'locale': 'de-DE',
  'timezone': 'Europe/Berlin',
};

/// The flat context every SDK-generated event carries (with the pins above).
const _context = <String, Object?>{
  'sdk_name': 'whisperr-flutter',
  'sdk_version': kWhisperrSdkVersion,
  ..._appContext,
  ..._deviceTraits,
};

class _Harness {
  _Harness({WhisperrPersistence? persistence})
      : persistence = persistence ?? InMemoryPersistence();

  final WhisperrPersistence persistence;
  final requests = <http.Request>[];
  // Shared across restarts so each client draws fresh ids.
  final random = Random(7);
  DateTime now = DateTime.utc(2026, 10, 5, 12);
  int status = 202;
  Map<String, String> headers = const {};

  late final MockClient mock = MockClient((req) async {
    requests.add(req);
    return http.Response(
      status < 300 ? '{"accepted":1,"rejected":0}' : '{"error":{}}',
      status,
      headers: headers,
    );
  });

  WhisperrClient client({
    Map<String, Object?> appContext = _appContext,
    bool automatic = true,
    bool enablePersistence = true,
    int maxRetries = 2,
    Duration retryBaseDelay = const Duration(milliseconds: 1),
    Duration maxRetryDelay = const Duration(milliseconds: 5),
  }) {
    return WhisperrClient(
      apiClient: WhisperrApiClient(
        httpClient: mock,
        baseUrl: 'https://api.test',
        apiKey: 'wrk_test',
        sdkVersion: 'test',
      ),
      persistence: persistence,
      options: WhisperrOptions(
        flushInterval: const Duration(hours: 1),
        flushOnLifecyclePause: false,
        trackAutomaticEvents: automatic,
        enablePersistence: enablePersistence,
        retryBaseDelay: retryBaseDelay,
        maxRetryDelay: maxRetryDelay,
        maxRetries: maxRetries,
      ),
      clock: () => now,
      random: random,
      deviceTraits: () => _deviceTraits,
      appContext: () async => appContext,
    );
  }

  List<Map<String, dynamic>> get events => [
        for (final r in requests)
          if (r.url.path == '/v1/events/batch')
            for (final e in (jsonDecode(r.body) as Map)['events'] as List)
              Map<String, dynamic>.from(e as Map),
      ];

  List<String> get eventTypes =>
      events.map((e) => e['event_type'] as String).toList();

  List<Map<String, dynamic>> get identifies => [
        for (final r in requests)
          if (r.url.path == '/v1/identify')
            jsonDecode(r.body) as Map<String, dynamic>,
      ];
}

Map<String, dynamic> _props(Map<String, dynamic> event) =>
    Map<String, dynamic>.from(event['properties'] as Map);

void main() {
  group('automatic events', () {
    test('first launch sends app_installed then app_opened, with context',
        () async {
      final h = _Harness();
      final client = h.client();
      await client.start();
      await client.flush();
      await client.close();

      expect(h.eventTypes, ['app_installed', 'app_opened']);
      expect(_props(h.events[0]), {..._context});
      expect(_props(h.events[1]), {..._context, 'cold_start': true});
      // Before identify they go out under the device's anonymous handle.
      for (final e in h.events) {
        expect(e.containsKey('external_user_id'), isFalse);
        expect(e['anonymous_id'], isNotNull);
      }
    });

    test('a relaunch on the same version sends only app_opened', () async {
      final h = _Harness();
      final first = h.client();
      await first.start();
      await first.close();
      h.requests.clear();

      final second = h.client();
      await second.start();
      await second.close();
      expect(h.eventTypes, ['app_opened']);
    });

    test('a new version sends app_updated with the previous version', () async {
      final h = _Harness();
      final first = h.client();
      await first.start();
      await first.close();
      h.requests.clear();

      final second = h.client(appContext: {
        ..._appContext,
        'app_version': '1.3.0',
        'app_build': '50'
      });
      await second.start();
      await second.close();

      expect(h.eventTypes, ['app_updated', 'app_opened']);
      expect(_props(h.events.first), {
        ..._context,
        'app_version': '1.3.0',
        'app_build': '50',
        'previous_version': '1.2.0',
        'previous_build': '42',
      });
    });

    test('state from an older SDK is an upgrade, not an install', () async {
      final persistence = InMemoryPersistence();
      await persistence.save(
          WhisperrPersistence.identitySlot, jsonEncode({'user_id': 'u1'}));
      final h = _Harness(persistence: persistence);
      final client = h.client();
      await client.start();
      await client.close();

      expect(h.eventTypes, ['app_opened']);
      expect(h.events.single['external_user_id'], 'u1');
      // The version is recorded, so the next upgrade is detected.
      expect(await persistence.load(WhisperrPersistence.appSlot), isNotNull);
    });

    test('without persistence there is no install/update detection', () async {
      final h = _Harness();
      final client = h.client(enablePersistence: false);
      await client.start();
      await client.close();
      expect(h.eventTypes, ['app_opened']);
    });

    test('background and foreground send app_backgrounded and app_opened',
        () async {
      final h = _Harness();
      final client = h.client();
      await client.start();

      h.now = h.now.add(const Duration(seconds: 90));
      client.handleLifecycleState(AppLifecycleState.inactive);
      client.handleLifecycleState(AppLifecycleState.hidden);
      client.handleLifecycleState(AppLifecycleState.paused); // same visit
      h.now = h.now.add(const Duration(minutes: 10));
      client.handleLifecycleState(AppLifecycleState.hidden);
      client.handleLifecycleState(AppLifecycleState.inactive);
      client.handleLifecycleState(AppLifecycleState.resumed);
      client.handleLifecycleState(AppLifecycleState.resumed); // no-op
      await pumpEventQueue();
      await client.flush();
      await client.close();

      expect(h.eventTypes,
          ['app_installed', 'app_opened', 'app_backgrounded', 'app_opened']);
      expect(_props(h.events[2]), {..._context, 'foreground_ms': 90000});
      expect(_props(h.events[3]), {..._context, 'cold_start': false});
    });

    test('the switch turns all automatic events off', () async {
      final h = _Harness();
      final client = h.client(automatic: false);
      await client.start();
      client.handleLifecycleState(AppLifecycleState.paused);
      client.handleLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      await client.flush();
      await client.close();
      expect(h.requests, isEmpty);
    });

    test('identify carries the anonymous id the launch events used', () async {
      final h = _Harness();
      final client = h.client();
      await client.start();
      final anon = client.anonymousId;
      await client.identify('user_1');
      await client.flush();
      await client.close();

      expect(anon, isNotNull);
      expect(h.identifies.single['anonymous_id'], anon);
      expect(
          RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
              .hasMatch(anon!),
          isTrue,
          reason: 'anonymous_id is a UUID v4');
    });

    test('the anonymous id survives a restart and rotates on reset', () async {
      final h = _Harness();
      final first = h.client(automatic: false);
      await first.start();
      await first.track('pricing_viewed');
      final anon = first.anonymousId;
      await first.close();

      final second = h.client(automatic: false);
      await second.start();
      expect(second.anonymousId, anon);
      await second.reset();
      expect(second.anonymousId, isNull);
      await second.track('pricing_viewed');
      expect(second.anonymousId, isNot(anon));
      await second.close();
    });
  });

  group('screen', () {
    test('screen() sends screen_viewed with the name and context', () async {
      final h = _Harness();
      final client = h.client(automatic: false);
      await client.start();
      await client.identify('user_1');
      await client.screen('Checkout', properties: {'step': 2});
      await client.screen('   '); // ignored
      await client.flush();
      await client.close();

      expect(h.eventTypes, ['screen_viewed']);
      expect(h.events.single['external_user_id'], 'user_1');
      expect(_props(h.events.single),
          {..._context, 'step': 2, 'screen_name': 'Checkout'});
    });
  });

  group('trackPushOpened', () {
    test('sends push_opened once per whisperr_message_id', () async {
      final h = _Harness();
      final client = h.client(automatic: false);
      await client.start();
      await client.identify('user_1');

      expect(
          await client.trackPushOpened(
              {'whisperr_message_id': 'msg_1', 'deep_link': 'app://offers'}),
          isTrue);
      expect(await client.trackPushOpened({'whisperr_message_id': 'msg_1'}),
          isFalse);
      expect(await client.trackPushOpened({'title': 'not ours'}), isFalse);
      expect(await client.trackPushOpened({'whisperr_message_id': 'msg_2'}),
          isTrue);
      await client.flush();
      await client.close();

      expect(h.eventTypes, ['push_opened', 'push_opened']);
      expect(_props(h.events[0]), {
        ..._context,
        'whisperr_message_id': 'msg_1',
        'deep_link': 'app://offers',
      });
      expect(
          _props(h.events[1]), {..._context, 'whisperr_message_id': 'msg_2'});
    });

    test('dedupe survives a restart (cold start re-delivers the tap)',
        () async {
      final h = _Harness();
      final first = h.client(automatic: false);
      await first.start();
      expect(await first.trackPushOpened({'whisperr_message_id': 'msg_1'}),
          isTrue);
      await first.close();

      final second = h.client(automatic: false);
      await second.start();
      expect(await second.trackPushOpened({'whisperr_message_id': 'msg_1'}),
          isFalse);
      await second.close();
    });
  });

  group('opt-out', () {
    test('setOptOut(true) clears the queue and stops all sending', () async {
      final h = _Harness()..status = 503;
      final client = h.client(automatic: false, maxRetries: 0);
      await client.start();
      await client.identify('user_1');
      await client.track('pricing_viewed');
      await client.flush();
      expect(client.pendingCount, greaterThan(0));
      h.status = 202;
      h.requests.clear();

      await client.setOptOut(true);
      expect(client.isOptedOut, isTrue);
      expect(client.pendingCount, 0);

      await client.track('pricing_viewed');
      await client.screen('Home');
      await client.identify('user_2');
      await client.setPushToken('tok');
      expect(
          await client.trackPushOpened({'whisperr_message_id': 'm'}), isFalse);
      client.handleLifecycleState(AppLifecycleState.paused);
      await pumpEventQueue();
      await client.flush();
      expect(h.requests, isEmpty);
      expect(client.pendingCount, 0);
      // Identity is still tracked locally.
      expect(client.currentUserId, 'user_2');
      await client.close();
    });

    test('opt-out persists across restarts and can be undone', () async {
      final h = _Harness();
      final first = h.client(automatic: false);
      await first.start();
      await first.setOptOut(true);
      await first.close();

      final second = h.client();
      await second.start(); // no automatic events while opted out
      expect(second.isOptedOut, isTrue);
      await second.track('pricing_viewed');
      await second.flush();
      expect(h.requests, isEmpty);

      await second.setOptOut(false);
      await second.track('pricing_viewed');
      await second.flush();
      await second.close();
      expect(h.eventTypes, ['pricing_viewed']);
    });
  });

  group('Retry-After', () {
    test('parses delay-seconds and HTTP-dates, capped at 60 s', () {
      final now = DateTime.utc(2026, 10, 5, 12);
      expect(parseRetryAfter('7', now: now), const Duration(seconds: 7));
      expect(parseRetryAfter(' 0 ', now: now), Duration.zero);
      expect(parseRetryAfter('3600', now: now), const Duration(seconds: 60));
      expect(parseRetryAfter('Mon, 05 Oct 2026 12:00:30 GMT', now: now),
          const Duration(seconds: 30));
      expect(parseRetryAfter('Monday, 05-Oct-26 12:00:10 GMT', now: now),
          const Duration(seconds: 10));
      expect(parseRetryAfter('Mon Oct  5 12:00:20 2026', now: now),
          const Duration(seconds: 20));
      expect(parseRetryAfter('Mon, 05 Oct 2026 11:00:00 GMT', now: now),
          Duration.zero);
      expect(parseRetryAfter(null, now: now), isNull);
      expect(parseRetryAfter('', now: now), isNull);
      expect(parseRetryAfter('1.5', now: now), isNull);
      expect(parseRetryAfter('-5', now: now), isNull);
      expect(parseRetryAfter('soon', now: now), isNull);
    });

    Future<WhisperrApiException> failWith(int status, String retryAfter) async {
      final api = WhisperrApiClient(
        httpClient: MockClient((_) async =>
            http.Response('{}', status, headers: {'retry-after': retryAfter})),
        baseUrl: 'https://api.test',
        apiKey: 'wrk_test',
        sdkVersion: 'test',
      );
      try {
        await api.identify({'external_user_id': 'u'});
      } on WhisperrApiException catch (e) {
        return e;
      }
      throw StateError('expected a failure');
    }

    test('only 429 and 503 carry the server wait', () async {
      expect((await failWith(429, '5')).retryAfter, const Duration(seconds: 5));
      expect((await failWith(503, '5')).retryAfter, const Duration(seconds: 5));
      expect((await failWith(500, '5')).retryAfter, isNull);
    });

    test('a 429 Retry-After replaces the computed backoff', () async {
      final h = _Harness()
        ..status = 429
        ..headers = const {'retry-after': '0'};
      // The computed backoff would be 10 minutes and time the test out.
      final client = h.client(
        automatic: false,
        maxRetries: 1,
        retryBaseDelay: const Duration(minutes: 10),
        maxRetryDelay: const Duration(minutes: 10),
      );
      await client.start();
      await client.track('pricing_viewed', userId: 'u1');
      await client.flush().timeout(const Duration(seconds: 5));
      // First attempt + one retry; the retry limit is not extended.
      expect(h.requests, hasLength(2));
      expect(client.pendingCount, 1);
      await client.setOptOut(true); // stop further retries before close
      await client.close();
    });
  });

  group('channels', () {
    test('the email shortcut sends no verified field', () async {
      final h = _Harness();
      final client = h.client(automatic: false);
      await client.start();
      await client.identify('user_1', email: 'ada@example.com');
      await client.flush();
      await client.close();

      final channels = h.identifies.single['channels'] as List;
      expect(channels.single,
          {'channel': 'email', 'address': 'ada@example.com', 'opted_in': true});
    });
  });

  group('timezone', () {
    test('only real IANA names count as timezone', () {
      expect(isIanaTimezone('Europe/Berlin'), isTrue);
      expect(isIanaTimezone('America/Argentina/Buenos_Aires'), isTrue);
      expect(isIanaTimezone('Etc/GMT+4'), isTrue);
      expect(isIanaTimezone('UTC'), isTrue);
      expect(isIanaTimezone('CET'), isFalse);
      expect(isIanaTimezone('+04'), isFalse);
      expect(isIanaTimezone('GMT+04:00'), isFalse);
      expect(isIanaTimezone(120), isFalse);
    });

    test('events keep the offset and drop a non-IANA timezone', () async {
      final h = _Harness();
      final client = WhisperrClient(
        apiClient: WhisperrApiClient(
          httpClient: h.mock,
          baseUrl: 'https://api.test',
          apiKey: 'wrk_test',
          sdkVersion: 'test',
        ),
        persistence: h.persistence,
        options: const WhisperrOptions(
          flushOnLifecyclePause: false,
          trackAutomaticEvents: false,
        ),
        clock: () => h.now,
        random: h.random,
        deviceTraits: () => {'timezone': 'CET', 'timezone_offset_minutes': 60},
        appContext: () async => _appContext,
      );
      await client.start();
      await client.screen('Home');
      await client.flush();
      await client.close();

      final props = _props(h.events.single);
      expect(props.containsKey('timezone'), isFalse);
      expect(props['timezone_offset_minutes'], 60);
    });
  });

  group('os_version', () {
    test('reads the release on iOS, macOS and Windows only', () {
      expect(parseOsVersion('ios', 'Version 17.4 (Build 21E213)'), '17.4');
      expect(parseOsVersion('macos', 'Version 14.1.2 (Build 23B92)'), '14.1.2');
      expect(parseOsVersion('windows', '"Windows 10 Pro" 10.0 (Build 19045)'),
          '10.0.19045');
      expect(parseOsVersion('android', 'Linux 5.10.43 #1 SMP PREEMPT'), isNull);
      expect(parseOsVersion('linux', '6.5.0-generic'), isNull);
    });
  });
}
