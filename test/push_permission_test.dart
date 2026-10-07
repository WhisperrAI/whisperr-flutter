import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/whisperr.dart';

const _expo = 'ExponentPushToken[xxxxxxxxxxxxxxxxxxxxxx]';
const _apns =
    'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';

/// The common properties with this harness's pins.
const _common = <String, Object?>{
  'sdk_name': 'whisperr-flutter',
  'sdk_version': kWhisperrSdkVersion,
  'platform': 'ios',
};

/// Storage whose reads finish a timer tick later, like a first disk read.
class _SlowLoads extends InMemoryPersistence {
  @override
  Future<String?> load(String slot) async {
    await Future<void>.delayed(Duration.zero);
    return super.load(slot);
  }
}

class _Harness {
  _Harness() {
    mock = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      if (status == 200 && req.url.path == '/v1/identify') {
        identifies.add(body);
      }
      if (status == 200 && req.url.path == '/v1/events/batch') {
        events.addAll((body['events'] as List).cast<Map<String, dynamic>>());
      }
      return http.Response('{}', status);
    });
  }

  /// The identify bodies and events the server accepted.
  final identifies = <Map<String, dynamic>>[];
  final events = <Map<String, dynamic>>[];
  WhisperrPersistence persistence = InMemoryPersistence();
  int status = 200;
  late final MockClient mock;

  List<Map<String, dynamic>> get permissionEvents => [
        for (final e in events)
          if (e['event_type'] == 'push_permission_changed')
            {
              if (e['external_user_id'] != null)
                'external_user_id': e['external_user_id'],
              'properties': e['properties'],
            },
      ];

  Future<WhisperrClient> start() async {
    final client = build();
    await client.start();
    return client;
  }

  WhisperrClient build() {
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
    test('sends push_permission_changed once per status, also across restarts',
        () async {
      final h = _Harness();
      final first = await h.start();
      await first.identify('user_1');
      await first.setPushPermission(WhisperrPushPermission.undetermined);
      await first.setPushPermission(WhisperrPushPermission.undetermined);
      await first.setPushPermission(WhisperrPushPermission.granted);
      await first.close();

      final second = await h.start();
      await second.setPushPermission(WhisperrPushPermission.granted);
      await second.flush();
      expect(h.permissionEvents, [
        {
          'external_user_id': 'user_1',
          'properties': {..._common, 'status': 'not_determined'},
        },
        {
          'external_user_id': 'user_1',
          'properties': {
            ..._common,
            'status': 'authorized',
            'previous_status': 'not_determined',
          },
        },
      ]);
      // The event is the only record: no trait, no extra identify.
      expect(h.identifies, [
        {'external_user_id': 'user_1', 'anonymous_id': first.anonymousId}
          ..removeWhere((_, v) => v == null)
      ]);
    });

    test('before identify the event goes out on the anonymous lane', () async {
      final h = _Harness();
      final c = await h.start();
      await c.setPushPermission(WhisperrPushPermission.denied);
      await c.identify('user_1');
      await c.flush();
      final event = h.events.single;
      expect(event['event_type'], 'push_permission_changed');
      expect(event['anonymous_id'], c.anonymousId);
      expect(event.containsKey('external_user_id'), isFalse);
      expect(event['properties'], {..._common, 'status': 'denied'});
      expect(h.identifies.single.containsKey('traits'), isFalse);
    });

    test('denied opts the token out and holds it; provisional re-registers it',
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
          'channels': [
            {'channel': 'push', 'address': 'fcm_tok', 'opted_in': false}
          ],
        }
      ]);

      // Every-launch token wiring while notifications are off: held back.
      h.identifies.clear();
      await c.setPushToken('fcm_tok', kind: WhisperrPushTokenKind.fcm);
      await c.identify('user_1', traits: {'plan': 'pro'});
      await c.setPushPermission(WhisperrPushPermission.denied);
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
      expect(h.permissionEvents.map((e) => e['properties']['status']),
          ['authorized', 'denied', 'provisional']);
    });

    test('reset forgets the sent status but keeps the denied gate', () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      await c.setPushPermission(WhisperrPushPermission.denied);
      await c.reset();
      await c.identify('user_2');
      await c.setPushToken('fcm_tok');
      await c.setPushPermission(WhisperrPushPermission.denied);
      await c.flush();
      expect(h.permissionEvents, [
        {
          'external_user_id': 'user_1',
          'properties': {..._common, 'status': 'denied'},
        },
        {
          'external_user_id': 'user_2',
          'properties': {..._common, 'status': 'denied'},
        },
      ]);
      expect(h.identifies.where((b) => b.containsKey('channels')), isEmpty);
    });

    test('a 0.5.x record sends the event once and keeps its denied gate',
        () async {
      final h = _Harness();
      await h.persistence.save(
          WhisperrPersistence.identitySlot, jsonEncode({'user_id': 'user_1'}));
      await h.persistence.save(WhisperrPersistence.pushPermissionSlot,
          jsonEncode({'status': 'denied', 'sent_for': 'user_1'}));
      final c = await h.start();
      await c.setPushToken('fcm_tok');
      await c.setPushPermission(WhisperrPushPermission.denied);
      await c.setPushPermission(WhisperrPushPermission.denied);
      await c.flush();
      expect(h.identifies, isEmpty);
      expect(h.permissionEvents, [
        {
          'external_user_id': 'user_1',
          'properties': {..._common, 'status': 'denied'},
        },
      ]);
    });
  });

  group('optOut', () {
    test('the opt-out identify survives a restart and is the only request',
        () async {
      final h = _Harness();
      final first = await h.start();
      await first.identify('user_1');
      await first.setPushToken('fcm_tok');
      await first.flush();
      h.identifies.clear();
      h.status = 503;
      await first.track('pricing_viewed');
      await first.optOut();
      await first.flush();
      expect(first.pendingCount, 1);
      await first.close();

      h.status = 200;
      h.identifies.clear();
      final second = await h.start();
      await second.track('pricing_viewed');
      await second.setPushPermission(WhisperrPushPermission.denied);
      await second.flush();
      expect(second.isOptedOut, isTrue);
      expect(h.identifies, [
        {
          'external_user_id': 'user_1',
          'channels': [
            {'channel': 'push', 'address': 'fcm_tok', 'opted_in': false}
          ],
        }
      ]);
      expect(h.events, isEmpty);
      expect(second.pendingCount, 0);
    });

    test(
        'after identify(other) without reset, opts the token out under its '
        'own user', () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      await c.setPushToken('fcm_tok');
      await c.identify('user_2');
      await c.flush();
      h.identifies.clear();
      await c.optOut();
      await c.flush();
      expect(h.identifies, [_pushOptOut('user_1', 'fcm_tok')]);
    });

    test('an opted-out install that still holds the pair opts it out once',
        () async {
      final h = _Harness();
      await h.persistence.save(
          WhisperrPersistence.identitySlot, jsonEncode({'user_id': 'user_1'}));
      await h.persistence.save(WhisperrPersistence.pushSlot,
          jsonEncode({'user_id': 'user_1', 'token': 'fcm_tok'}));
      await h.persistence.save(WhisperrPersistence.optOutSlot, '1');
      final first = await h.start();
      await first.flush();
      await first.close();
      final second = await h.start();
      await second.optOut();
      await second.flush();
      expect(h.identifies, [_pushOptOut('user_1', 'fcm_tok')]);
      expect(await h.persistence.load(WhisperrPersistence.pushSlot), isNull);
    });

    test('a restart while opted out keeps only the queued push opt-outs',
        () async {
      final h = _Harness();
      await h.persistence.save(
          WhisperrPersistence.queueSlot,
          jsonEncode([
            {
              'id': 'op_1',
              'kind': 'identify',
              'body': {
                'external_user_id': 'user_1',
                'channels': [
                  {'channel': 'email', 'address': 'a@b.co', 'opted_in': true},
                  {'channel': 'push', 'address': 'fcm_old', 'opted_in': false},
                ],
              },
            },
          ]));
      await h.persistence.save(WhisperrPersistence.optOutSlot, '1');
      final c = await h.start();
      await c.flush();
      expect(h.identifies, [_pushOptOut('user_1', 'fcm_old')]);
      expect(c.pendingCount, 0);
    });

    test('keeps a denied-permission opt-out queued offline', () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      await c.setPushToken('fcm_tok');
      await c.flush();
      h.identifies.clear();
      h.status = 503;
      await c.track('pricing_viewed');
      await c.setPushPermission(WhisperrPushPermission.denied);
      await c.flush();
      await c.optOut();
      h.status = 200;
      h.events.clear();
      await c.flush();
      expect(h.identifies, [_pushOptOut('user_1', 'fcm_tok')]);
      expect(h.events, isEmpty);
    });

    test('keeps the retirement of a rotation queued offline', () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      await c.setPushToken('fcm_a');
      await c.flush();
      h.identifies.clear();
      h.status = 503;
      await c.setPushToken('fcm_b');
      await c.flush();
      await c.optOut();
      h.status = 200;
      await c.flush();
      expect(h.identifies, [
        _pushOptOut('user_1', 'fcm_a'),
        _pushOptOut('user_1', 'fcm_b'),
      ]);
    });

    test('keeps an earlier opt-out that was not delivered yet', () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      await c.setPushToken('fcm_tok');
      await c.flush();
      h.identifies.clear();
      h.status = 503;
      await c.optOut();
      await c.flush();
      await c.optIn();
      await c.flush();
      await c.optOut();
      h.status = 200;
      await c.flush();
      expect(h.identifies, [_pushOptOut('user_1', 'fcm_tok')]);
    });

    test('waits for start() to restore the pair', () async {
      final h = _Harness()..persistence = _SlowLoads();
      await h.persistence.save(
          WhisperrPersistence.identitySlot, jsonEncode({'user_id': 'user_1'}));
      await h.persistence.save(WhisperrPersistence.pushSlot,
          jsonEncode({'user_id': 'user_1', 'token': 'fcm_tok'}));
      final c = h.build();
      final started = c.start();
      await c.optOut();
      await started;
      await c.flush();
      expect(h.identifies, [_pushOptOut('user_1', 'fcm_tok')]);
      expect(await h.persistence.load(WhisperrPersistence.pushSlot), isNull);
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

Map<String, Object?> _pushOptOut(String user, String token) => {
      'external_user_id': user,
      'channels': [
        {'channel': 'push', 'address': token, 'opted_in': false}
      ],
    };
