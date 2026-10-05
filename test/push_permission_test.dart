import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/whisperr.dart';

const _expo = 'ExponentPushToken[xxxxxxxxxxxxxxxxxxxxxx]';
const _apns =
    'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';

class _Harness {
  _Harness() {
    mock = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      if (req.url.path == '/v1/identify') identifies.add(body);
      if (req.url.path == '/v1/events/batch') {
        events.addAll((body['events'] as List).cast<Map<String, dynamic>>());
      }
      return http.Response('{}', status);
    });
  }

  final identifies = <Map<String, dynamic>>[];
  final events = <Map<String, dynamic>>[];
  final persistence = InMemoryPersistence();
  int status = 200;
  late final MockClient mock;

  Future<WhisperrClient> start() async {
    final client = WhisperrClient(
      apiClient: WhisperrApiClient(
        httpClient: mock,
        baseUrl: 'https://api.test',
        apiKey: 'wrk_test',
        sdkVersion: 'test',
      ),
      persistence: persistence,
      options: const WhisperrOptions(
        flushOnLifecyclePause: false,
        trackAutomaticEvents: false,
        retryBaseDelay: Duration(milliseconds: 1),
        maxRetryDelay: Duration(milliseconds: 5),
        maxRetries: 0,
      ),
      clock: () => DateTime.utc(2026, 10, 5, 12),
      random: Random(7),
      deviceTraits: () => const <String, Object?>{},
      appContext: () async => const <String, Object?>{'platform': 'ios'},
    );
    addTearDown(client.close);
    await client.start();
    return client;
  }
}

void main() {
  group('setPushToken metadata', () {
    test('sends kind and the device platform with an FCM token', () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      await c.setPushToken('fcm_tok', kind: WhisperrPushTokenKind.fcm);
      await c.flush();
      expect(h.identifies.last, {
        'external_user_id': 'user_1',
        'channels': [
          {
            'channel': 'push',
            'address': 'fcm_tok',
            'opted_in': true,
            'kind': 'fcm',
            // flutter_test runs as Android unless a test overrides it.
            'platform': 'android',
          }
        ],
      });
    });

    test('APNs with push_env; an Expo token gets kind expo', () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      await c.setPushToken(_apns,
          kind: WhisperrPushTokenKind.apns,
          platform: 'ios',
          pushEnv: WhisperrPushEnvironment.sandbox);
      await c.setPushToken(_expo, platform: 'ios');
      await c.flush();
      expect(h.identifies[1]['channels'], [
        {
          'channel': 'push',
          'address': _apns,
          'opted_in': true,
          'kind': 'apns',
          'platform': 'ios',
          'push_env': 'sandbox',
        }
      ]);
      expect(h.identifies[2]['channels'], [
        {'channel': 'push', 'address': _apns, 'opted_in': false},
        {
          'channel': 'push',
          'address': _expo,
          'opted_in': true,
          'kind': 'expo',
          'platform': 'ios',
        },
      ]);
    });

    test('a bare token stays bare; unknown platforms are dropped', () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      await c.setPushToken('tok_a', platform: 'symbian');
      await c.flush();
      expect(h.identifies.last['channels'], [
        {
          'channel': 'push',
          'address': 'tok_a',
          'opted_in': true,
          'platform': 'android',
        }
      ]);
    });

    test('re-sends once when metadata arrives; bare never downgrades',
        () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      await c.setPushToken('fcm_tok');
      await c.setPushToken('fcm_tok', kind: WhisperrPushTokenKind.fcm);
      await c.setPushToken('fcm_tok');
      await c.setPushToken('fcm_tok', kind: WhisperrPushTokenKind.fcm);
      await c.flush();
      expect(h.identifies.skip(1).map((b) => b['channels']).toList(), [
        [
          {'channel': 'push', 'address': 'fcm_tok', 'opted_in': true}
        ],
        [
          {
            'channel': 'push',
            'address': 'fcm_tok',
            'opted_in': true,
            'kind': 'fcm',
            'platform': 'android',
          }
        ],
      ]);
    });

    test('the metadata dedupe holds across a restart', () async {
      final h = _Harness();
      final first = await h.start();
      await first.identify('user_1');
      await first.setPushToken('fcm_tok', kind: WhisperrPushTokenKind.fcm);
      await first.close();

      final second = await h.start();
      await second.setPushToken('fcm_tok', kind: WhisperrPushTokenKind.fcm);
      await second.flush();
      expect(h.identifies.where((b) => b['channels'] != null), hasLength(1));
    });

    test('attachPushTokenStream passes the metadata', () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      final sub = c.attachPushTokenStream(Stream.value('fcm_tok'),
          kind: WhisperrPushTokenKind.fcm);
      await Future<void>.delayed(Duration.zero);
      await c.flush();
      await sub.cancel();
      expect((h.identifies.last['channels'] as List).single,
          containsPair('kind', 'fcm'));
    });
  });

  group('setPushPermission', () {
    test('sends the push_permission trait once, also across restarts',
        () async {
      final h = _Harness();
      final first = await h.start();
      await first.identify('user_1');
      await first.setPushPermission(WhisperrPushPermission.granted);
      await first.setPushPermission(WhisperrPushPermission.granted);
      await first.close();

      final second = await h.start();
      await second.setPushPermission(WhisperrPushPermission.granted);
      await second.flush();
      expect(h.identifies.skip(1).toList(), [
        {
          'external_user_id': 'user_1',
          'traits': {'push_permission': 'granted'},
        }
      ]);
    });

    test('denied opts the token out and holds it; granted re-registers it',
        () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      await c.setPushToken('fcm_tok', kind: WhisperrPushTokenKind.fcm);
      await c.setPushPermission(WhisperrPushPermission.granted);
      await c.flush();
      h.identifies.clear();

      await c.setPushPermission(WhisperrPushPermission.denied);
      await c.flush();
      expect(h.identifies, [
        {
          'external_user_id': 'user_1',
          'traits': {'push_permission': 'denied'},
          'channels': [
            {'channel': 'push', 'address': 'fcm_tok', 'opted_in': false}
          ],
        }
      ]);

      // Every-launch token wiring while notifications are off: held back.
      h.identifies.clear();
      await c.setPushToken('fcm_tok', kind: WhisperrPushTokenKind.fcm);
      await c.identify('user_1', traits: {'plan': 'pro'});
      await c.flush();
      expect(h.identifies, [
        {
          'external_user_id': 'user_1',
          'anonymous_id': c.anonymousId,
          'traits': {'plan': 'pro'},
        }..removeWhere((_, v) => v == null)
      ]);

      h.identifies.clear();
      await c.setPushPermission(WhisperrPushPermission.provisional);
      await c.flush();
      expect(h.identifies, [
        {
          'external_user_id': 'user_1',
          'traits': {'push_permission': 'provisional'},
          'channels': [
            {
              'channel': 'push',
              'address': 'fcm_tok',
              'opted_in': true,
              'kind': 'fcm',
              'platform': 'android',
            }
          ],
        }
      ]);
    });

    test('before identify the status rides on it; the caller trait wins',
        () async {
      final h = _Harness();
      final c = await h.start();
      await c.setPushPermission(WhisperrPushPermission.denied);
      await c.identify('user_1');
      await c.identify('user_2', traits: {'push_permission': 'custom'});
      await c.flush();
      expect(h.identifies[0]['traits'], {'push_permission': 'denied'});
      expect(h.identifies[1]['traits'], {'push_permission': 'custom'});
    });

    test('after reset the next user gets the device status', () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      await c.setPushPermission(WhisperrPushPermission.granted);
      await c.reset();
      await c.identify('user_2');
      await c.flush();
      expect(h.identifies.last['external_user_id'], 'user_2');
      expect(h.identifies.last['traits'], {'push_permission': 'granted'});
    });

    test('a report the server rejected is sent again', () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      await c.flush();
      h.status = 400;
      await c.setPushPermission(WhisperrPushPermission.granted);
      await c.flush();
      h.status = 200;
      h.identifies.clear();
      await c.setPushPermission(WhisperrPushPermission.granted);
      await c.flush();
      expect(h.identifies, [
        {
          'external_user_id': 'user_1',
          'traits': {'push_permission': 'granted'},
        }
      ]);
    });
  });

  group('push opens', () {
    test('WhisperrPushOpen.fromData prefers whisperr_deep_link', () {
      expect(
        WhisperrPushOpen.fromData({
          'whisperr_message_id': 'm',
          'whisperr_deep_link': 'app://a',
          'deep_link': 'app://b',
        }),
        const WhisperrPushOpen(messageId: 'm', deepLink: 'app://a'),
      );
      expect(
        WhisperrPushOpen.fromData(
            {'whisperr_message_id': 'm', 'deep_link': 'app://b'})?.deepLink,
        'app://b',
      );
      expect(WhisperrPushOpen.fromData({'campaign': 'x'}), isNull);
      expect(WhisperrPushOpen.fromData({'whisperr_message_id': ' '}), isNull);
    });

    test('push_opened carries the deep link from whisperr_deep_link', () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      expect(
        await c.trackPushOpened({
          'whisperr_message_id': 'msg_1',
          'whisperr_deep_link': 'myapp://offers',
        }),
        isTrue,
      );
      await c.flush();
      final open =
          h.events.singleWhere((e) => e['event_type'] == 'push_opened');
      expect(open['properties'], containsPair('deep_link', 'myapp://offers'));
      expect(open['properties'], containsPair('whisperr_message_id', 'msg_1'));
    });
  });
}
