import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/whisperr.dart';

const _specUrl =
    'https://raw.githubusercontent.com/WhisperrAI/whisperr-spec/main/conformance/anonymous.json';

Future<Map<String, dynamic>> _loadSpec() async {
  // anonymous.json lives next to wire.json; derive it like the push suite.
  var local = Platform.environment['WHISPERR_ANONYMOUS_SPEC_PATH'];
  final wire = Platform.environment['WHISPERR_SPEC_PATH'];
  if ((local == null || local.isEmpty) && wire != null && wire.isNotEmpty) {
    local = File(wire).parent.uri.resolve('anonymous.json').toFilePath();
  }
  if (local != null && local.isNotEmpty) {
    return jsonDecode(await File(local).readAsString()) as Map<String, dynamic>;
  }
  final res = await http.get(Uri.parse(_specUrl));
  if (res.statusCode != 200) {
    throw StateError('fetch anonymous spec: ${res.statusCode}');
  }
  return jsonDecode(res.body) as Map<String, dynamic>;
}

WhisperrClient _client(MockClient mock) {
  final api = WhisperrApiClient(
    httpClient: mock,
    baseUrl: 'https://api.test',
    apiKey: 'wrk_test',
    sdkVersion: 'test',
  );
  return WhisperrClient(
    apiClient: api,
    persistence: InMemoryPersistence(),
    options: const WhisperrOptions(
      flushOnLifecyclePause: false,
      trackAutomaticEvents: false,
      retryBaseDelay: Duration(milliseconds: 1),
      maxRetryDelay: Duration(milliseconds: 5),
      maxRetries: 2,
    ),
    clock: () => DateTime.utc(2026, 5, 31, 12),
    random: Random(7),
    // Harnesses run with device trait defaults disabled (anonymous.json).
    deviceTraits: () => const <String, Object?>{},
  );
}

/// Binds `$anon_x` placeholders to the first value seen; every later use must
/// match, and different placeholders must carry different values.
class _Placeholders {
  final Map<String, String> _bound = {};

  void check(Object? expected, Object? actual, String where) {
    if (expected is String && expected.startsWith(r'$anon_')) {
      expect(actual, isA<String>(), reason: where);
      final value = actual! as String;
      expect(value.length, inInclusiveRange(1, 128), reason: where);
      final prior = _bound[expected];
      if (prior == null) {
        expect(_bound.values, isNot(contains(value)),
            reason: '$where: $expected must differ from other handles');
        _bound[expected] = value;
      } else {
        expect(value, prior, reason: '$where: $expected must stay stable');
      }
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
}

void main() {
  test('anonymous-lane conformance (whisperr-spec)', () async {
    final spec = await _loadSpec();
    final cases = (spec['cases'] as List).cast<Map<String, dynamic>>();
    expect(cases, isNotEmpty);

    for (final c in cases) {
      final name = c['name'] as String;
      final requests = <http.Request>[];
      final mock = MockClient((req) async {
        requests.add(req);
        return http.Response('{"accepted":1,"rejected":0}', 202);
      });
      final client = _client(mock);
      await client.start();

      for (final raw in c['steps'] as List) {
        final step = raw as Map<String, dynamic>;
        if (step.containsKey('reset')) {
          await client.reset();
        } else if (step.containsKey('track')) {
          final s = Map<String, dynamic>.from(step['track'] as Map);
          await client.track(
            s['eventType'] as String,
            properties: (s['properties'] as Map?)?.cast<String, dynamic>(),
          );
        } else if (step.containsKey('identify')) {
          final s = Map<String, dynamic>.from(step['identify'] as Map);
          await client.identify(
            s['externalUserId'] as String,
            traits: (s['traits'] as Map?)?.cast<String, dynamic>(),
          );
        } else {
          fail('$name: unknown step $step');
        }
        await client.flush();
      }
      await client.close();

      final expected =
          (c['expectedRequests'] as List).cast<Map<String, dynamic>>();
      expect(requests.length, expected.length, reason: '$name: request count');
      final placeholders = _Placeholders();
      for (var i = 0; i < expected.length; i++) {
        final want = expected[i];
        final req = requests[i];
        final where = '$name request[$i]';
        expect(req.url.path, want['endpoint'], reason: where);
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        if (want['endpoint'] == '/v1/events/batch') {
          final events = (body['events'] as List).map((raw) {
            final e = Map<String, dynamic>.from(raw as Map);
            expect((e['context'] as Map)[r'$message_id'], isNotNull,
                reason: '$where context.\$message_id');
            return e
              ..remove('occurred_at')
              ..remove('context');
          }).toList();
          placeholders.check(want['events'], events, '$where.events');
        } else {
          placeholders.check(want['body'], body, '$where.body');
        }
      }
    }
  });
}
