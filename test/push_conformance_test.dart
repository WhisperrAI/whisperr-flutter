import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/whisperr.dart';

const _specUrl =
    'https://raw.githubusercontent.com/WhisperrAI/whisperr-spec/main/conformance/push.json';

Future<Map<String, dynamic>> _loadSpec() async {
  // push.json lives next to wire.json; derive it like the behavior suite does.
  var local = Platform.environment['WHISPERR_PUSH_SPEC_PATH'];
  final wire = Platform.environment['WHISPERR_SPEC_PATH'];
  if ((local == null || local.isEmpty) && wire != null && wire.isNotEmpty) {
    local = File(wire).parent.uri.resolve('push.json').toFilePath();
  }
  if (local != null && local.isNotEmpty) {
    return jsonDecode(await File(local).readAsString()) as Map<String, dynamic>;
  }
  final res = await http.get(Uri.parse(_specUrl));
  if (res.statusCode != 200) {
    throw StateError('fetch push spec: ${res.statusCode}');
  }
  return jsonDecode(res.body) as Map<String, dynamic>;
}

WhisperrClient _client(MockClient mock, WhisperrPersistence persistence) {
  final api = WhisperrApiClient(
    httpClient: mock,
    baseUrl: 'https://api.test',
    apiKey: 'wrk_test',
    sdkVersion: 'test',
  );
  return WhisperrClient(
    apiClient: api,
    persistence: persistence,
    options: const WhisperrOptions(
      flushOnLifecyclePause: false,
      retryBaseDelay: Duration(milliseconds: 1),
      maxRetryDelay: Duration(milliseconds: 5),
      maxRetries: 2,
    ),
    clock: () => DateTime.utc(2026, 5, 31, 12),
    random: Random(7),
    // Device-trait defaults are environment-dependent and never pinned by
    // the spec fixtures; device_traits_test.dart covers them.
    deviceTraits: () => const <String, Object?>{},
  );
}

void main() {
  test('push-token conformance (whisperr-spec)', () async {
    final spec = await _loadSpec();
    final cases = (spec['cases'] as List).cast<Map<String, dynamic>>();
    expect(cases, isNotEmpty);

    for (final c in cases) {
      final identifies = <Map<String, dynamic>>[];
      final mock = MockClient((req) async {
        if (req.url.path == '/v1/identify') {
          identifies.add(jsonDecode(req.body) as Map<String, dynamic>);
        }
        return http.Response(
            '{"user":{"id":"u","external_id":"u","created":true}}', 200);
      });
      final persistence = InMemoryPersistence();
      var client = _client(mock, persistence);
      addTearDown(() => client.close());
      await client.start();

      for (final raw in c['steps'] as List) {
        final step = raw as Map<String, dynamic>;
        if (step.containsKey('restart')) {
          // App relaunch: tear the client down and build a fresh instance on
          // the SAME persistence — identity and last-sent token must restore.
          await client.close();
          client = _client(mock, persistence);
          await client.start();
          continue;
        }
        if (step.containsKey('reset')) {
          await client.reset(); // logout: clears identity + last-sent pair
          await client.flush();
          continue;
        }
        if (step.containsKey('identify')) {
          final s = Map<String, dynamic>.from(step['identify'] as Map);
          await client.identify(
            s['externalUserId'] as String,
            traits: s['traits'] as Map<String, dynamic>?,
            pushToken: s['pushToken'] as String?,
          );
        } else {
          await client.setPushToken(step['setPushToken'] as String);
        }
        // Deliver each step before the next, so request order is pinned.
        await client.flush();
      }

      expect(identifies, c['expectedBodies'], reason: c['name'] as String);
    }
  });
}
