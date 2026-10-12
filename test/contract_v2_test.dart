// Spec v2 client contract (whisperr-spec C1–C5): restore identify, app
// language, anonymous push tokens, push metadata and re-registration, and
// the environment keys in every event context.
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/src/device_traits.dart' show normalizeLanguageTag;
import 'package:whisperr/whisperr.dart';

const _context = <String, Object?>{
  'app_version': '2.1.0',
  'app_build': '210',
  'platform': 'android',
  'os_name': 'android',
  'client_app_id': 'com.example.app',
};

class _Harness {
  _Harness({this.appContext = _context});

  final Map<String, Object?> appContext;
  final persistence = InMemoryPersistence();
  final requests = <http.Request>[];
  final random = Random(7);
  DateTime now = DateTime.utc(2026, 10, 12, 9);
  Map<String, Object?> traits = const {'locale': 'de-DE'};
  bool offline = false;

  late final MockClient mock = MockClient((req) async {
    if (offline) throw http.ClientException('offline');
    requests.add(req);
    return http.Response('{"accepted":1,"rejected":0}', 200);
  });

  WhisperrClient client({
    Duration restoreDelay = Duration.zero,
    bool automatic = false,
  }) {
    final c = WhisperrClient(
      apiClient: WhisperrApiClient(
        httpClient: mock,
        baseUrl: 'https://api.test',
        apiKey: 'wpk_test',
        sdkVersion: 'test',
      ),
      persistence: persistence,
      options: WhisperrOptions(
        flushInterval: const Duration(hours: 1),
        flushOnLifecyclePause: false,
        trackAutomaticEvents: automatic,
        restoreIdentifyDelay: restoreDelay,
        retryBaseDelay: const Duration(milliseconds: 1),
        maxRetryDelay: const Duration(milliseconds: 2),
        maxRetries: 0,
      ),
      clock: () => now,
      random: random,
      deviceTraits: () => traits,
      appContext: () async => appContext,
    );
    addTearDown(c.close);
    return c;
  }

  Future<WhisperrClient> start({Duration restoreDelay = Duration.zero}) async {
    final c = client(restoreDelay: restoreDelay);
    await c.start();
    await c.flush();
    return c;
  }

  List<Map<String, dynamic>> get identifies => [
        for (final r in requests)
          if (r.url.path == '/v1/identify')
            jsonDecode(r.body) as Map<String, dynamic>,
      ];

  List<Map<String, dynamic>> get events => [
        for (final r in requests)
          if (r.url.path == '/v1/events/batch')
            for (final e in (jsonDecode(r.body) as Map)['events'] as List)
              Map<String, dynamic>.from(e as Map),
      ];
}

Map<String, Object?> _push(String token,
        {Map<String, Object?> extra = const {}}) =>
    {
      'channel': 'push',
      'address': token,
      'opted_in': true,
      'platform': 'android',
      'client_app_id': 'com.example.app',
      ...extra,
    };

void main() {
  group('C1 restore identify', () {
    test('a start with a stored user sends one restore identify', () async {
      final h = _Harness();
      final first = await h.start();
      await first.track('lesson_done'); // creates the anonymous handle
      await first.identify('user_1');
      await first.flush();
      final anon = first.anonymousId;
      await first.close();

      h.now = h.now.add(const Duration(days: 2));
      h.requests.clear();
      final second = await h.start();
      await second.flush();
      expect(h.identifies, [
        {
          'external_user_id': 'user_1',
          'anonymous_id': anon,
          'traits': {'locale': 'de-DE'},
        }
      ]);
    });

    test('skipped when the same traits went out less than 24 hours ago',
        () async {
      final h = _Harness();
      final first = await h.start();
      await first.identify('user_1', traits: {'plan': 'pro'});
      await first.flush();
      await first.close();

      h.now = h.now.add(const Duration(hours: 23));
      h.requests.clear();
      final second = await h.start();
      await second.close();
      expect(h.identifies, isEmpty);

      // After 24 hours it goes out again.
      h.now = h.now.add(const Duration(hours: 2));
      final third = await h.start();
      await third.close();
      expect(h.identifies, [
        {
          'external_user_id': 'user_1',
          'traits': {'locale': 'de-DE'},
        }
      ]);

      // Delivered now: the next launch the same day skips it.
      h.requests.clear();
      h.now = h.now.add(const Duration(minutes: 5));
      final fourth = await h.start();
      await fourth.close();
      expect(h.identifies, isEmpty);
    });

    test('a changed device trait sends it before 24 hours', () async {
      final h = _Harness();
      final first = await h.start();
      await first.identify('user_1');
      await first.flush();
      await first.close();

      h.traits = const {'locale': 'fr-FR'};
      h.requests.clear();
      final second = await h.start();
      await second.close();
      expect(h.identifies, [
        {
          'external_user_id': 'user_1',
          'traits': {'locale': 'fr-FR'},
        }
      ]);
    });

    test('the app identify() during the delay replaces it', () async {
      final h = _Harness();
      final first = await h.start();
      await first.identify('user_1');
      await first.close();
      h.now = h.now.add(const Duration(days: 3));
      h.requests.clear();

      final second =
          await h.start(restoreDelay: const Duration(milliseconds: 30));
      await second.identify('user_1', traits: {'plan': 'pro'});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await second.flush();
      expect(h.identifies, [
        {
          'external_user_id': 'user_1',
          'traits': {'locale': 'de-DE', 'plan': 'pro'},
        }
      ]);
    });

    test('waits for the delay, then queues it', () async {
      final h = _Harness();
      final first = await h.start();
      await first.identify('user_1');
      await first.close();
      h.now = h.now.add(const Duration(days: 3));
      h.requests.clear();

      final second =
          await h.start(restoreDelay: const Duration(milliseconds: 30));
      expect(second.pendingCount, 0);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await second.flush();
      expect(h.identifies.single['external_user_id'], 'user_1');
    });

    test('nothing after reset or while opted out', () async {
      final h = _Harness();
      final first = await h.start();
      await first.identify('user_1');
      await first.optOut();
      await first.close();
      h.now = h.now.add(const Duration(days: 3));
      h.requests.clear();
      final second = await h.start();
      await second.close();
      expect(h.identifies, isEmpty);
    });

    test('offline: it waits in the persisted queue', () async {
      final h = _Harness();
      final first = await h.start();
      await first.identify('user_1');
      await first.flush();
      await first.close();
      h.now = h.now.add(const Duration(days: 3));
      h.requests.clear();

      h.offline = true;
      final second = await h.start();
      expect(second.pendingCount, 1);
      await second.close();

      h.offline = false;
      final third = await h.start();
      await third.flush();
      // The queued restore identify is delivered; no second one is added.
      expect(h.identifies, [
        {
          'external_user_id': 'user_1',
          'traits': {'locale': 'de-DE'},
        }
      ]);
    });
  });

  group('C2 setAppLanguage', () {
    test('with a user: a partial identify, persisted, carried by identify',
        () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      await c.setAppLanguage('pt_BR');
      await c.setAppLanguage('pt-BR'); // same value: nothing new
      await c.identify('user_1', traits: {'plan': 'pro'});
      await c.identify('user_1', traits: {'app_language': 'es'});
      await c.flush();
      expect(c.appLanguage, 'pt-BR');
      expect(h.identifies.skip(1).toList(), [
        {
          'external_user_id': 'user_1',
          'traits': {'app_language': 'pt-BR'},
        },
        {
          'external_user_id': 'user_1',
          'traits': {'locale': 'de-DE', 'app_language': 'pt-BR', 'plan': 'pro'},
        },
        {
          'external_user_id': 'user_1',
          'traits': {'locale': 'de-DE', 'app_language': 'es'},
        },
      ]);
      await c.close();

      // Persisted: the restore identify carries it too.
      h.now = h.now.add(const Duration(days: 2));
      h.requests.clear();
      final next = await h.start();
      expect(next.appLanguage, 'pt-BR');
      await next.flush();
      expect(h.identifies.single['traits'],
          {'locale': 'de-DE', 'app_language': 'pt-BR'});
    });

    test('without a user: an anonymous identify', () async {
      final h = _Harness();
      final c = await h.start();
      await c.setAppLanguage('de');
      await c.flush();
      expect(h.identifies, [
        {
          'anonymous_id': c.anonymousId,
          'traits': {'app_language': 'de'},
        }
      ]);
    });

    test('an invalid tag is ignored; null clears and sends nothing', () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      await c.setAppLanguage('fr');
      await c.setAppLanguage('not a tag!');
      expect(c.appLanguage, 'fr');
      await c.setAppLanguage(null);
      expect(c.appLanguage, isNull);
      await c.identify('user_1');
      await c.flush();
      expect(h.identifies.map((b) => b['traits']).toList(), [
        {'locale': 'de-DE'},
        {'app_language': 'fr'},
        {'locale': 'de-DE'},
      ]);
      expect(await h.persistence.load(WhisperrPersistence.appLanguageSlot),
          isNull);
    });

    test('set before start(): sent after the restore', () async {
      final h = _Harness();
      final first = await h.start();
      await first.identify('user_1');
      await first.close();
      h.requests.clear();

      final second = h.client();
      await second.setAppLanguage('it');
      await second.start();
      await second.flush();
      expect(h.identifies.last, {
        'external_user_id': 'user_1',
        'traits': {'app_language': 'it'},
      });
    });

    test('normalizes tags', () {
      expect(normalizeLanguageTag(' en_US '), 'en-US');
      expect(normalizeLanguageTag('zh-Hant-TW'), 'zh-Hant-TW');
      expect(normalizeLanguageTag('e'), isNull);
      expect(normalizeLanguageTag('en US'), isNull);
      expect(normalizeLanguageTag(''), isNull);
    });
  });

  group('C3 anonymous push token', () {
    test('before identify: an anonymous identify; identify attaches the token',
        () async {
      final h = _Harness();
      final c = await h.start();
      await c.setPushToken('fcm_a', kind: WhisperrPushTokenKind.fcm);
      await c.setPushToken('fcm_a', kind: WhisperrPushTokenKind.fcm); // dedup
      await c.identify('user_1');
      await c.setPushToken('fcm_a', kind: WhisperrPushTokenKind.fcm); // dedup
      await c.flush();
      final anon = c.anonymousId;
      expect(anon, isNotNull);
      final entry = _push('fcm_a', extra: {'kind': 'fcm'});
      expect(h.identifies, [
        {
          'anonymous_id': anon,
          'channels': [entry],
        },
        {
          'external_user_id': 'user_1',
          'anonymous_id': anon,
          'traits': {'locale': 'de-DE'},
          'channels': [entry],
        },
      ]);
    });

    test('an anonymous rotation opts the old token out under the handle',
        () async {
      final h = _Harness();
      final c = await h.start();
      await c.setPushToken('tok_a');
      await c.setPushToken('tok_b');
      await c.flush();
      expect(h.identifies.last, {
        'anonymous_id': c.anonymousId,
        'channels': [
          {'channel': 'push', 'address': 'tok_a', 'opted_in': false},
          _push('tok_b'),
        ],
      });
    });

    test('the anonymous pair survives a restart', () async {
      final h = _Harness();
      final first = await h.start();
      await first.setPushToken('tok_a');
      await first.close();
      final second = await h.start();
      await second.setPushToken('tok_a');
      await second.flush();
      expect(h.identifies, hasLength(1));
    });

    test('denied before identify holds the token; granted registers it',
        () async {
      final h = _Harness();
      final c = await h.start();
      await c.setPushPermission(WhisperrPushPermission.denied);
      await c.setPushToken('tok_a');
      await c.flush();
      expect(h.identifies, isEmpty);
      await c.setPushPermission(WhisperrPushPermission.granted);
      await c.flush();
      expect(h.identifies, [
        {
          'anonymous_id': c.anonymousId,
          'channels': [_push('tok_a')],
        }
      ]);
    });

    test('denied after an anonymous registration opts it out', () async {
      final h = _Harness();
      final c = await h.start();
      await c.setPushToken('tok_a');
      await c.setPushPermission(WhisperrPushPermission.denied);
      await c.flush();
      expect(h.identifies.last, {
        'anonymous_id': c.anonymousId,
        'channels': [
          {'channel': 'push', 'address': 'tok_a', 'opted_in': false}
        ],
      });
    });

    test('optOut opts an anonymous token out under the handle', () async {
      final h = _Harness();
      final c = await h.start();
      await c.setPushToken('tok_a');
      await c.flush();
      await c.optOut();
      await c.flush();
      expect(h.identifies.last, {
        'anonymous_id': c.anonymousId,
        'channels': [
          {'channel': 'push', 'address': 'tok_a', 'opted_in': false}
        ],
      });
      await c.setPushToken('tok_b');
      await c.flush();
      expect(h.identifies, hasLength(2));
    });

    test('reset while anonymous moves the token to the new handle', () async {
      final h = _Harness();
      final c = await h.start();
      await c.setPushToken('tok_a');
      final before = c.anonymousId;
      await c.reset();
      await c.flush();
      final after = c.anonymousId;
      expect(after, isNot(before));
      expect(h.identifies.skip(1).toList(), [
        {
          'anonymous_id': before,
          'channels': [
            {'channel': 'push', 'address': 'tok_a', 'opted_in': false}
          ],
        },
        {
          'anonymous_id': after,
          'channels': [_push('tok_a')],
        },
      ]);
    });

    test('reset while opted out sends nothing', () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      await c.setPushToken('tok_a');
      await c.optOut();
      await c.flush();
      final sent = h.identifies.length;
      await c.reset();
      await c.flush();
      expect(h.identifies, hasLength(sent));
    });

    test('a token set before start() goes under the restored user', () async {
      final h = _Harness();
      final first = await h.start();
      await first.identify('user_1');
      await first.close();
      h.requests.clear();

      final second = h.client();
      await second.setPushToken('tok_a');
      await second.start();
      await second.flush();
      expect(h.identifies, [
        {
          'external_user_id': 'user_1',
          'channels': [_push('tok_a')],
        }
      ]);
    });
  });

  group('C4 push metadata and re-registration', () {
    test('every token carries platform and client_app_id; FCM its project',
        () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1', pushToken: 'tok_id');
      await c.setPushToken('tok_a',
          kind: WhisperrPushTokenKind.fcm, providerProject: 'hotcard-prod');
      await c.flush();
      expect(h.identifies[0]['channels'], [_push('tok_id')]);
      expect(
          (h.identifies[1]['channels'] as List).last,
          _push('tok_a',
              extra: {'kind': 'fcm', 'provider_project': 'hotcard-prod'}));
    });

    test('client_app_id never goes into event properties or context', () async {
      final h = _Harness();
      final c = await h.start();
      await c.screen('home');
      await c.flush();
      final e = h.events.single;
      expect((e['properties'] as Map).containsKey('client_app_id'), isFalse);
      expect((e['context'] as Map).containsKey('client_app_id'), isFalse);
    });

    test('the same token is sent again at launch after 7 days', () async {
      final h = _Harness();
      final first = await h.start();
      await first.identify('user_1');
      await first.setPushToken('tok_a', kind: WhisperrPushTokenKind.fcm);
      await first.close();
      h.requests.clear();

      h.now = h.now.add(const Duration(days: 6));
      final second = await h.start();
      await second.close();
      expect(h.identifies.where((b) => b['channels'] != null), isEmpty);

      h.now = h.now.add(const Duration(days: 2));
      final third = await h.start();
      await third.setPushToken('tok_a', kind: WhisperrPushTokenKind.fcm);
      await third.flush();
      expect(h.identifies.where((b) => b['channels'] != null).toList(), [
        {
          'external_user_id': 'user_1',
          'channels': [
            _push('tok_a', extra: {'kind': 'fcm'})
          ],
        }
      ]);
    });

    test('setPushToken re-sends the same token after 7 days', () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      await c.setPushToken('tok_a');
      h.now = h.now.add(const Duration(days: 8));
      await c.setPushToken('tok_a');
      await c.setPushToken('tok_a');
      await c.flush();
      expect(h.identifies.where((b) => b['channels'] != null), hasLength(2));
    });

    test('a pair stored by 0.5 is sent again with the new metadata', () async {
      final h = _Harness();
      await h.persistence.save(
          WhisperrPersistence.identitySlot, jsonEncode({'user_id': 'user_1'}));
      await h.persistence.save(WhisperrPersistence.pushSlot,
          jsonEncode({'user_id': 'user_1', 'token': 'tok_a', 'meta': 'fcm||'}));
      final c = await h.start();
      await c.flush();
      expect(h.identifies.firstWhere((b) => b['channels'] != null), {
        'external_user_id': 'user_1',
        'channels': [
          _push('tok_a', extra: {'kind': 'fcm'})
        ],
      });
    });

    test('a token with less metadata never replaces what was sent', () async {
      final h = _Harness();
      final c = await h.start();
      await c.identify('user_1');
      await c.setPushToken('tok_a',
          kind: WhisperrPushTokenKind.fcm, providerProject: 'p1');
      await c.setPushToken('tok_a');
      await c.setPushToken('tok_a', kind: WhisperrPushTokenKind.fcm);
      await c.setPushToken('tok_a',
          kind: WhisperrPushTokenKind.fcm, providerProject: 'p2');
      await c.flush();
      final pushes = h.identifies.where((b) => b['channels'] != null).toList();
      expect(pushes, hasLength(2));
      expect(
          (pushes.last['channels'] as List).single['provider_project'], 'p2');
    });
  });

  group('C5 environment keys in every event context', () {
    test('custom and automatic events carry them; the caller wins', () async {
      final h = _Harness();
      final c = h.client(automatic: true);
      await c.start();
      await c.track('lesson_done', context: {'app_build': 'override'});
      await c.flush();
      for (final e in h.events) {
        final ctx = Map<String, dynamic>.from(e['context'] as Map)
          ..remove(r'$message_id');
        expect(
            ctx,
            {
              'app_version': '2.1.0',
              'app_build':
                  e['event_type'] == 'lesson_done' ? 'override' : '210',
              'platform': 'android',
              'sdk_name': 'whisperr-flutter',
              'sdk_version': kWhisperrSdkVersion,
            },
            reason: e['event_type'] as String);
      }
      expect(h.events.map((e) => e['event_type']),
          containsAll(['app_installed', 'app_opened', 'lesson_done']));
    });

    test('no value, no key', () async {
      final h = _Harness(appContext: const {});
      final c = await h.start();
      await c.track('lesson_done');
      await c.flush();
      final ctx = Map<String, dynamic>.from(h.events.single['context'] as Map)
        ..remove(r'$message_id');
      expect(ctx, {
        'sdk_name': 'whisperr-flutter',
        'sdk_version': kWhisperrSdkVersion,
      });
    });
  });
}
