import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/whisperr.dart';

const _specUrl =
    'https://raw.githubusercontent.com/WhisperrAI/whisperr-spec/main/conformance/wire.json';
final _rfc3339Z = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$');

Future<Map<String, dynamic>> _loadSpec() async {
  final local = Platform.environment['WHISPERR_SPEC_PATH'];
  if (local != null && local.isNotEmpty) {
    return jsonDecode(await File(local).readAsString()) as Map<String, dynamic>;
  }
  final res = await http.get(Uri.parse(_specUrl));
  if (res.statusCode != 200) {
    throw StateError('fetch wire spec: ${res.statusCode}');
  }
  return jsonDecode(res.body) as Map<String, dynamic>;
}

WhisperrClient _client(MockClient mock, {DateTime? clock}) {
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
      retryBaseDelay: Duration(milliseconds: 1),
      maxRetryDelay: Duration(milliseconds: 5),
      maxRetries: 2,
    ),
    clock: () => clock ?? DateTime.utc(2026, 5, 31, 12),
    random: Random(7),
  );
}

Future<void> _applyCase(WhisperrClient client, Map<String, dynamic> c) async {
  final s = c['scenario'] as Map<String, dynamic>;
  if (c['op'] == 'track') {
    await client.identify(s['externalUserId'] as String);
    await client.track(
      s['eventType'] as String,
      properties: (s['properties'] as Map<String, dynamic>?),
    );
    return;
  }
  List<WhisperrChannel>? channels;
  if (s['channels'] != null) {
    channels = (s['channels'] as List).map((raw) {
      final ch = raw as Map<String, dynamic>;
      return WhisperrChannel(
        type: WhisperrChannelType.values
            .firstWhere((t) => t.wireValue == ch['type']),
        address: ch['address'] as String,
        optedIn: ch['optedIn'] as bool?,
        verified: ch['verified'] as bool?,
      );
    }).toList();
  }
  await client.identify(
    s['externalUserId'] as String,
    traits: (s['traits'] as Map<String, dynamic>?),
    email: s['email'] as String?,
    phone: s['phone'] as String?,
    pushToken: s['pushToken'] as String?,
    preferredChannel: s['preferredChannel'] as String?,
    channels: channels,
  );
}

void main() {
  test('wire conformance (whisperr-spec)', () async {
    final spec = await _loadSpec();
    final cases = (spec['cases'] as List).cast<Map<String, dynamic>>();
    expect(cases, isNotEmpty);

    for (final c in cases) {
      final requests = <http.Request>[];
      final mock = MockClient((req) async {
        requests.add(req);
        return http.Response(
            '{"user":{"id":"u","external_id":"u","created":true}}', 200);
      });
      final clockIso =
          (c['scenario'] as Map<String, dynamic>)['clockIso'] as String?;
      final client = _client(mock,
          clock: clockIso == null ? null : DateTime.parse(clockIso).toUtc());
      addTearDown(client.close);
      await client.start();
      await _applyCase(client, c);
      await client.flush();

      final endpoint = c['endpoint'] as String;
      final req = requests.firstWhere(
        (r) => r.url.path == endpoint,
        orElse: () => throw StateError('${c['name']}: expected POST $endpoint'),
      );
      final body = jsonDecode(req.body) as Map<String, dynamic>;

      if (c['op'] == 'track') {
        final event = (body['events'] as List).first as Map<String, dynamic>;
        (c['expectedEvent'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
          expect(event[k], v, reason: '${c['name']}.$k');
        });
        for (final key in (c['contextMustContain'] as List? ?? [])) {
          expect((event['context'] as Map)[key], isNotNull,
              reason: '${c['name']} context.$key');
        }
        if (c['occurredAtRfc3339Z'] == true) {
          expect(_rfc3339Z.hasMatch(event['occurred_at'] as String), isTrue);
        }
        if (c['expectedOccurredAt'] != null) {
          expect(event['occurred_at'], c['expectedOccurredAt'],
              reason: '${c['name']}.occurred_at');
        }
      } else {
        (c['expectedBody'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
          expect(body[k], v, reason: '${c['name']}.$k');
        });
      }
    }
  });
}
