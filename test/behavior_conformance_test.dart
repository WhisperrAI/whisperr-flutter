import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/whisperr.dart';

const _specUrl =
    'https://raw.githubusercontent.com/WhisperrAI/whisperr-spec/main/conformance/behavior.json';

Future<Map<String, dynamic>> _loadSpec() async {
  final local = Platform.environment['WHISPERR_BEHAVIOR_SPEC_PATH'] ??
      _siblingBehaviorPath();
  if (local != null && local.isNotEmpty) {
    return jsonDecode(await File(local).readAsString()) as Map<String, dynamic>;
  }
  final res = await http.get(Uri.parse(_specUrl));
  if (res.statusCode != 200) {
    throw StateError('fetch behavior spec: ${res.statusCode}');
  }
  return jsonDecode(res.body) as Map<String, dynamic>;
}

String? _siblingBehaviorPath() {
  final wire = Platform.environment['WHISPERR_SPEC_PATH'];
  if (wire == null || wire.isEmpty) return null;
  return File(wire).parent.uri.resolve('behavior.json').toFilePath();
}

WhisperrClient _client(
  MockClient mock,
  int maxRetries,
  void Function(WhisperrError error) onError,
) {
  final api = WhisperrApiClient(
    httpClient: mock,
    baseUrl: 'https://api.test',
    apiKey: 'wrk_test',
    sdkVersion: 'test',
  );
  return WhisperrClient(
    apiClient: api,
    persistence: InMemoryPersistence(),
    options: WhisperrOptions(
      flushInterval: const Duration(hours: 1),
      flushOnLifecyclePause: false,
      retryBaseDelay: const Duration(milliseconds: 1),
      maxRetryDelay: const Duration(milliseconds: 5),
      maxRetries: maxRetries,
      onError: onError,
    ),
    clock: () => DateTime.utc(2026, 5, 31, 12),
    random: Random(7),
  );
}

void main() {
  test('behavior conformance (whisperr-spec)', () async {
    final spec = await _loadSpec();
    final cases = (spec['cases'] as List).cast<Map<String, dynamic>>();
    expect(cases, isNotEmpty);

    for (final c in cases) {
      var status =
          (c['firstResponse'] as Map<String, dynamic>)['status'] as int;
      final requests = <http.Request>[];
      final mock = MockClient((req) async {
        requests.add(req);
        final ok = status >= 200 && status < 300;
        return http.Response(
          ok
              ? '{"accepted":1,"rejected":0}'
              : '{"error":{"code":"test","message":"test"}}',
          status,
        );
      });
      final maxRetries =
          ((c['clientOptions'] as Map?)?['maxRetries'] as num?)?.toInt() ?? 0;
      final errors = <WhisperrError>[];
      final client = _client(mock, maxRetries, errors.add);

      try {
        await client.start();
        final scenario = c['scenario'] as Map<String, dynamic>;
        await client.track(
          scenario['eventType'] as String,
          userId: scenario['externalUserId'] as String,
          properties: _mapOrNull(scenario['properties']),
        );
        await client.flush();

        final expectSpec = c['expect'] as Map<String, dynamic>;
        expect(
          errors.any((e) => e.type == expectSpec['errorType']),
          isTrue,
          reason: '${c['name']}: emitted expected error',
        );
        final afterFirst = _batchBodies(requests);
        expect(afterFirst, hasLength(1),
            reason: '${c['name']}: first delivery attempt');
        expect(client.pendingCount > 0, expectSpec['retainedAfterFirstFlush'],
            reason: '${c['name']}: retained after first flush');

        status =
            (c['recoveryResponse'] as Map<String, dynamic>)['status'] as int;
        await client.flush();

        final afterRecovery = _batchBodies(requests);
        final retried = afterRecovery.length > afterFirst.length;
        expect(retried, expectSpec['retriesAfterRecovery'],
            reason: '${c['name']}: retried after recovery');

        final delivered =
            retried && _eventType(afterRecovery.last) == scenario['eventType'];
        expect(delivered, expectSpec['deliveredAfterRecovery'],
            reason: '${c['name']}: delivered after recovery');

        if (expectSpec['stableMessageIdOnRetry'] == true) {
          expect(_messageId(afterRecovery[1]), _messageId(afterRecovery[0]),
              reason: '${c['name']}: stable message id on retry');
        }
      } finally {
        await client.close();
      }
    }
  });
}

Map<String, dynamic>? _mapOrNull(Object? value) {
  if (value == null) return null;
  return Map<String, dynamic>.from(value as Map);
}

List<Map<String, dynamic>> _batchBodies(List<http.Request> requests) {
  return requests
      .where((r) => r.url.path == '/v1/events/batch')
      .map((r) => jsonDecode(r.body) as Map<String, dynamic>)
      .toList();
}

String? _eventType(Map<String, dynamic> body) {
  return ((body['events'] as List).first as Map<String, dynamic>)['event_type']
      as String?;
}

Object? _messageId(Map<String, dynamic> body) {
  final event = (body['events'] as List).first as Map<String, dynamic>;
  final context = event['context'] as Map<String, dynamic>;
  return context[r'$message_id'];
}
