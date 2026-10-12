// whisperr-spec conformance/v2.json (SPEC.md -> Contract v2 conformance).
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/src/app_context.dart' show kWhisperrSdkName, osFamily;
import 'package:whisperr/whisperr.dart';

import 'support/spec_loader.dart';

/// The context keys a v2 expectation governs.
const _governed = [
  'app_version',
  'app_build',
  'platform',
  'sdk_name',
  'sdk_version',
  'locale',
];

class _Case {
  _Case(this.section, this.spec)
      : device = spec['device'] == null
            ? null
            : Map<String, dynamic>.from(spec['device'] as Map);

  final String section;
  final Map<String, dynamic> spec;

  /// The injected environment. Null: environment detection is off.
  Map<String, dynamic>? device;
  final persistence = InMemoryPersistence();
  final requests = <http.Request>[];
  final random = Random(7);
  DateTime now = DateTime.utc(2026, 10, 12, 12);

  String get name => '$section/${spec['name']}';

  late final MockClient mock = MockClient((req) async {
    requests.add(req);
    return http.Response('{"accepted":1,"rejected":0}', 200);
  });

  Map<String, Object?> deviceTraits() {
    final d = device;
    if (d == null) return const {};
    return {
      if (d['locale'] != null) 'locale': d['locale'],
      if (d['timezone'] != null) 'timezone': d['timezone'],
    };
  }

  Map<String, Object?> appContext() {
    final d = device;
    if (d == null) return const {};
    final os = osFamily();
    return {
      if (os != null) 'platform': os,
      if (os != null) 'os_name': os,
      if (d['osVersion'] != null) 'os_version': d['osVersion'],
      if (d['appVersion'] != null) 'app_version': d['appVersion'],
      if (d['appBuild'] != null) 'app_build': d['appBuild'],
      if (d['clientAppId'] != null) 'client_app_id': d['clientAppId'],
    };
  }

  WhisperrClient build() => WhisperrClient(
        apiClient: WhisperrApiClient(
          httpClient: mock,
          baseUrl: 'https://api.test',
          apiKey: 'wpk_test',
          sdkVersion: 'test',
        ),
        persistence: persistence,
        options: const WhisperrOptions(
          flushInterval: Duration(hours: 1),
          flushOnLifecyclePause: false,
          trackAutomaticEvents: false,
          restoreIdentifyDelay: Duration.zero,
          retryBaseDelay: Duration(milliseconds: 1),
          maxRetryDelay: Duration(milliseconds: 5),
          maxRetries: 0,
        ),
        clock: () => now,
        random: random,
        deviceTraits: deviceTraits,
        appContext: () async => appContext(),
      );
}

T? _byWire<T extends Enum>(
    List<T> values, Object? wire, String Function(T) of) {
  for (final v in values) {
    if (of(v) == wire) return v;
  }
  return null;
}

Future<void> _run(_Case c) async {
  var client = c.build();
  await client.start();
  for (final raw in c.spec['steps'] as List) {
    final step = Map<String, dynamic>.from(raw as Map);
    final kind = step.keys.single;
    final value = step[kind];
    switch (kind) {
      case 'identify':
        final s = Map<String, dynamic>.from(value as Map);
        await client.identify(
          s['externalUserId'] as String,
          traits: (s['traits'] as Map?)?.cast<String, dynamic>(),
          pushToken: s['pushToken'] as String?,
        );
      case 'track':
        final s = Map<String, dynamic>.from(value as Map);
        await client.track(
          s['eventType'] as String,
          properties: (s['properties'] as Map?)?.cast<String, dynamic>(),
        );
      case 'setPushToken':
        // Flutter detects provider_project and push_env in its push
        // companion (whisperr_firebase_messaging), which passes them in;
        // the harness plays that part with the device block.
        final t = value is Map
            ? Map<String, dynamic>.from(value)
            : <String, dynamic>{'token': value};
        if (t.containsKey('clientAppId')) {
          fail('${c.name}: setPushToken has no clientAppId argument');
        }
        await client.setPushToken(
          t['token'] as String,
          kind: _byWire(
              WhisperrPushTokenKind.values, t['kind'], (k) => k.wireValue),
          platform: t['platform'] as String?,
          pushEnv: _byWire(WhisperrPushEnvironment.values,
              t['pushEnv'] ?? c.device?['pushEnv'], (e) => e.wireValue),
          providerProject:
              (t['providerProject'] ?? c.device?['providerProject']) as String?,
        );
      case 'setAppLanguage':
        await client.setAppLanguage(value as String?);
      case 'restart':
        await client.close();
        client = c.build();
        if (value is Map && value['thenIdentify'] != null) {
          // The app calls identify() in the same tick as construction.
          final s = Map<String, dynamic>.from(value['thenIdentify'] as Map);
          final started = client.start();
          final identified = client.identify(
            s['externalUserId'] as String,
            traits: (s['traits'] as Map?)?.cast<String, dynamic>(),
          );
          await started;
          await identified;
        } else {
          await client.start();
        }
      case 'reset':
        await client.reset();
      case 'optOut':
        await client.optOut();
      case 'optIn':
        await client.optIn();
      case 'pushPermission':
        final status = WhisperrPushPermission.fromWire(value);
        if (status == null) fail('${c.name}: unknown status $value');
        await client.setPushPermission(status);
      case 'advanceClock':
        c.now = c.now.add(Duration(hours: (value as Map)['hours'] as int));
      case 'setDevice':
        c.device = Map<String, dynamic>.from(value as Map);
      default:
        fail('${c.name}: unknown step $kind');
    }
    await client.flush();
  }
  await client.close();
}

/// Binds the fixture placeholders; checks [actual] against [expected].
class _Matcher {
  _Matcher(this.name);

  final String name;
  final Map<String, String> _anon = {};

  static final _own = <String, Object?>{
    r'$platform': osFamily(),
    r'$sdk_name': kWhisperrSdkName,
    r'$sdk_version': kWhisperrSdkVersion,
  };

  void check(Object? expected, Object? actual, String where) {
    if (expected is String && expected.startsWith(r'$anon_')) {
      expect(actual, isA<String>(), reason: where);
      final value = actual! as String;
      final prior = _anon[expected];
      if (prior == null) {
        expect(_anon.values, isNot(contains(value)),
            reason: '$where: $expected must differ from other handles');
        _anon[expected] = value;
      } else {
        expect(value, prior, reason: '$where: $expected must stay stable');
      }
      return;
    }
    if (expected is String && _own.containsKey(expected)) {
      expect(actual, _own[expected], reason: where);
      return;
    }
    if (expected is Map) {
      expect(actual, isA<Map<dynamic, dynamic>>(), reason: where);
      final a = actual! as Map;
      expect(a.keys.toSet(), expected.keys.toSet(), reason: where);
      for (final key in expected.keys) {
        check(expected[key], a[key], '$where.$key');
      }
      return;
    }
    if (expected is List) {
      expect(actual, isA<List<dynamic>>(), reason: where);
      final a = actual! as List;
      expect(a.length, expected.length, reason: where);
      for (var i = 0; i < expected.length; i++) {
        check(expected[i], a[i], '$where[$i]');
      }
      return;
    }
    expect(actual, expected, reason: where);
  }

  void event(Map<dynamic, dynamic> expected, Map<String, dynamic> actual,
      String where) {
    final e = Map<String, dynamic>.from(actual)..remove('occurred_at');
    final context = Map<String, dynamic>.from(e.remove('context') as Map);
    expect(context[r'$message_id'], isNotNull,
        reason: '$where context.\$message_id');
    final want = Map<String, dynamic>.from(expected);
    final wantContext = want.remove('context') as Map?;
    check(want, e, where);
    if (wantContext == null) return;
    for (final key in _governed) {
      check(wantContext[key], context[key], '$where.context.$key');
    }
  }
}

/// The requests a case sent, minus `push_permission_changed` events.
///
/// The v2 `anonymousPush` cases with a `pushPermission` step list only the
/// identify requests, but SPEC.md (Push permission) sends that event on every
/// change, also with automatic events off. Reported to the spec owner; this
/// filter goes when the fixtures list the event.
List<Map<String, dynamic>> _sent(_Case c) {
  final out = <Map<String, dynamic>>[];
  for (final r in c.requests) {
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.url.path == '/v1/identify') {
      out.add({'endpoint': '/v1/identify', 'body': body});
      continue;
    }
    final events = (body['events'] as List)
        .cast<Map<String, dynamic>>()
        .where((e) => e['event_type'] != 'push_permission_changed')
        .toList();
    if (events.isEmpty) continue;
    out.add({'endpoint': r.url.path, 'events': events});
  }
  return out;
}

void main() {
  for (final section in kV2Sections) {
    test('contract v2 conformance: $section (whisperr-spec v2.json)', () async {
      final spec = await loadSpecFixture('v2.json',
          overrideEnv: 'WHISPERR_V2_SPEC_PATH');
      final s = (spec['sections'] as Map)[section] as Map;
      expect((s['appliesTo'] as List), contains('mobile'));
      final cases = (s['cases'] as List).cast<Map<String, dynamic>>();
      expect(cases, isNotEmpty);
      for (final raw in cases) {
        final c = _Case(section, raw);
        await _run(c);
        final sent = _sent(c);
        final expected =
            (raw['expectedRequests'] as List).cast<Map<String, dynamic>>();
        expect(sent.map((r) => r['endpoint']).toList(),
            expected.map((r) => r['endpoint']).toList(),
            reason: '${c.name}: requests ${jsonEncode(sent)}');
        final m = _Matcher(c.name);
        for (var i = 0; i < expected.length; i++) {
          final want = expected[i];
          final where = '${c.name} request[$i]';
          if (want['endpoint'] == '/v1/identify') {
            final body = sent[i]['body'] as Map<String, dynamic>;
            final wantBody = Map<String, dynamic>.from(want['body'] as Map);
            m.check(wantBody, withoutUnnamedAnonymousId(body, wantBody),
                '$where.body');
          } else {
            final events = sent[i]['events'] as List;
            final wantEvents = want['events'] as List;
            expect(events.length, wantEvents.length, reason: where);
            for (var j = 0; j < wantEvents.length; j++) {
              m.event(wantEvents[j] as Map, events[j] as Map<String, dynamic>,
                  '$where.events[$j]');
            }
          }
        }
      }
    });
  }
}
