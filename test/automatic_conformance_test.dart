import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails, FlutterExceptionHandler;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/src/app_context.dart' show kWhisperrSdkName, osFamily;
import 'package:whisperr/whisperr.dart';

import 'support/spec_loader.dart';
import 'support/spec_ref.dart';

const _specUrl = '$kSpecBaseUrl/automatic.json';

Future<Map<String, dynamic>> _loadSpec() async {
  // automatic.json lives next to wire.json; derive it like the push suite.
  var local = Platform.environment['WHISPERR_AUTOMATIC_SPEC_PATH'];
  final wire = Platform.environment['WHISPERR_SPEC_PATH'];
  if ((local == null || local.isEmpty) && wire != null && wire.isNotEmpty) {
    local = File(wire).parent.uri.resolve('automatic.json').toFilePath();
  }
  if (local != null && local.isNotEmpty) {
    return jsonDecode(await File(local).readAsString()) as Map<String, dynamic>;
  }
  final res = await http.get(Uri.parse(_specUrl));
  if (res.statusCode != 200) {
    throw StateError('fetch automatic spec: ${res.statusCode}');
  }
  return jsonDecode(res.body) as Map<String, dynamic>;
}

/// The SDK's own values for the fixture placeholders.
final _placeholders = <String, Object?>{
  r'$platform': osFamily(),
  r'$sdk_name': kWhisperrSdkName,
  r'$sdk_version': kWhisperrSdkVersion,
};

Object? _bind(Object? expected) {
  if (expected is String && _placeholders.containsKey(expected)) {
    return _placeholders[expected];
  }
  if (expected is Map) {
    return {for (final e in expected.entries) e.key: _bind(e.value)};
  }
  return expected;
}

class _Case {
  _Case(this.spec) {
    final device = Map<String, dynamic>.from(spec['device'] as Map? ?? {});
    osVersion = device['osVersion'] as String?;
    deviceTraits = {
      if (device['locale'] != null) 'locale': device['locale'],
      if (device['timezone'] != null) 'timezone': device['timezone'],
      if (device['timezoneOffsetMinutes'] != null)
        'timezone_offset_minutes': device['timezoneOffsetMinutes'],
    };
  }

  final Map<String, dynamic> spec;
  late final String? osVersion;
  late final Map<String, Object?> deviceTraits;
  final persistence = InMemoryPersistence();
  final requests = <http.Request>[];
  final random = Random(7);
  DateTime now = DateTime.utc(2026, 10, 7, 12);

  String get name => spec['name'] as String;

  bool get automatic =>
      (spec['config'] as Map?)?['automaticEvents'] as bool? ?? true;

  bool get captureErrors =>
      (spec['config'] as Map?)?['captureErrors'] as bool? ?? true;

  bool get debugBuild =>
      (spec['config'] as Map?)?['debugBuild'] as bool? ?? false;

  late final MockClient mock = MockClient((req) async {
    requests.add(req);
    return http.Response('{"accepted":1,"rejected":0}', 202);
  });

  WhisperrClient client(String appVersion, String appBuild) {
    final os = osFamily();
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
        captureErrors: captureErrors,
        retryBaseDelay: const Duration(milliseconds: 1),
        maxRetryDelay: const Duration(milliseconds: 5),
        maxRetries: 2,
      ),
      clock: () => now,
      monotonicMs: () => now.millisecondsSinceEpoch,
      debugBuild: debugBuild,
      random: random,
      deviceTraits: () => deviceTraits,
      appContext: () async => {
        'app_version': appVersion,
        'app_build': appBuild,
        if (os != null) 'platform': os,
        if (os != null) 'os_name': os,
        if (osVersion != null) 'os_version': osVersion,
      },
    );
  }

  /// Every event sent, in send order, without identity, time and context.
  /// [contexts] receives each event's context.
  List<Map<String, dynamic>> sentEvents(
      [List<Map<dynamic, dynamic>>? contexts]) {
    final out = <Map<String, dynamic>>[];
    for (final r in requests) {
      final path = r.url.path;
      if (path != '/v1/events/batch' && path != '/v1/events/track') continue;
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      final events = path == '/v1/events/batch'
          ? (body['events'] as List).cast<Map<String, dynamic>>()
          : [body];
      for (final e in events) {
        expect((e['context'] as Map)[r'$message_id'], isNotNull,
            reason: '$name: context.\$message_id');
        expect((e['context'] as Map)['session_id'], matches(_sessionPattern),
            reason: '$name: context.session_id');
        contexts?.add(e['context'] as Map);
        out.add({'event_type': e['event_type'], 'properties': e['properties']});
      }
    }
    return out;
  }
}

Future<void> _seed(String? storage, WhisperrPersistence persistence) async {
  switch (storage ?? 'empty') {
    case 'empty':
      return;
    case 'legacy_sdk_state':
      await persistence.save(
          WhisperrPersistence.identitySlot, jsonEncode({'user_id': 'user_1'}));
      return;
    default:
      fail('unknown storage $storage');
  }
}

Future<void> _run(_Case c) async {
  await _seed(c.spec['storage'] as String?, c.persistence);
  WhisperrClient? client;
  WhisperrClient live() {
    final current = client;
    if (current == null) fail('${c.name}: step before launch');
    return current;
  }

  for (final raw in c.spec['steps'] as List) {
    final step = Map<String, dynamic>.from(raw as Map);
    final kind = step.keys.single;
    final value = step[kind];
    switch (kind) {
      case 'launch':
        final launch = Map<String, dynamic>.from(value as Map);
        final next = c.client(
            launch['appVersion'] as String, launch['appBuild'] as String);
        client = next;
        // No binding in this suite: start() treats the process as in the
        // foreground and delivers the cold-start open itself.
        await next.start();
        await next.identify('user_1');
        final via = launch['via'] as Map?;
        if (via?['link'] != null) {
          next.handleLaunchUri(Uri.parse(via!['link'] as String));
        }
        if (via?['push'] != null) {
          await next.trackPushOpened(
              Map<String, dynamic>.from(via!['push'] as Map),
              coldStart: true);
        }
      case 'track':
        await live().track(value as String);
      case 'trackError':
        final e = Map<String, dynamic>.from(value as Map);
        await live().trackError(Exception('conformance'),
            name: e['name'] as String,
            kind: e['kind'] as String?,
            screen: e['screen'] as String?);
      case 'uncaughtError':
        final e = Map<String, dynamic>.from(value as Map);
        final error = _uncaught(e['name'] as String);
        if (e['fatal'] == true) {
          live().captureUncaughtError(error, StackTrace.current, fatal: true);
        } else {
          final before = _priorHandlerCalls;
          FlutterError.onError!(
              FlutterErrorDetails(exception: error, stack: StackTrace.current));
          expect(_priorHandlerCalls, before + 1,
              reason: '${c.name}: the prior FlutterError.onError still runs');
        }
      case 'background':
        c.now =
            c.now.add(Duration(milliseconds: (value as Map)['afterMs'] as int));
        live().handleLifecycleState(AppLifecycleState.paused);
      case 'foreground':
        c.now =
            c.now.add(Duration(milliseconds: (value as Map)['afterMs'] as int));
        live().handleLifecycleState(AppLifecycleState.resumed);
      case 'terminate':
        await live().close();
        client = null;
      case 'screen':
        await live().screen(value as String);
      case 'pushOpened':
        await live().trackPushOpened(Map<String, dynamic>.from(value as Map));
      case 'receivePush':
        // Flutter's only receipt path is the in-app foreground handler.
        final push = Map<String, dynamic>.from(value as Map);
        await live()
            .trackPushReceived(Map<String, dynamic>.from(push['data'] as Map));
      case 'openPush':
        final push = Map<String, dynamic>.from(value as Map);
        await live().trackPushOpened(
          Map<String, dynamic>.from(push['data'] as Map),
          actionId: push['actionId'] as String?,
          coldStart: push['launchedApp'] as bool?,
        );
      case 'pushPermission':
        final status = WhisperrPushPermission.fromWire(value);
        if (status == null) fail('${c.name}: unknown status $value');
        await live().setPushPermission(status);
      case 'reset':
        await live().reset();
      case 'optOut':
        await live().optOut();
      case 'optIn':
        await live().optIn();
      default:
        fail('${c.name}: unknown step $kind');
    }
    await pumpEventQueue();
    await client?.flush();
  }
  await client?.close();
}

final _sessionPattern = RegExp(
    r'^sess_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

int _priorHandlerCalls = 0;

const _legacyEvents = {'app_error', 'app_crashed'};

class OffersRenderError extends Error {}

class CheckoutStateError extends Error {}

Object _uncaught(String name) => switch (name) {
      'OffersRenderError' => OffersRenderError(),
      'CheckoutStateError' => CheckoutStateError(),
      _ => throw StateError('no error type $name in this harness'),
    };

/// signalsV3 legacy rule: drop [legacyStrip.events], and remove the
/// [legacyStrip.properties] keys the expected event does not name.
List<Map<String, dynamic>> _legacy(Map<String, dynamic> spec,
    List<Map<String, dynamic>> sent, List<dynamic> expected) {
  final strip = (spec['signalsV3'] as Map)['legacyStrip'] as Map;
  final events = (strip['events'] as List).cast<String>().toSet();
  final keys = (strip['properties'] as List).cast<String>();
  final kept = sent.where((e) => !events.contains(e['event_type'])).toList();
  for (var i = 0; i < kept.length && i < expected.length; i++) {
    final want = ((expected[i] as Map)['properties'] as Map?) ?? const {};
    final props = Map<String, dynamic>.from(kept[i]['properties'] as Map);
    for (final k in keys) {
      if (!want.containsKey(k)) props.remove(k);
    }
    kept[i] = {...kept[i], 'properties': props};
  }
  return kept;
}

/// Binds `$session_<x>` / `$fp_<x>` placeholders (SPEC.md signalsV3).
class _Binder {
  final _bound = <String, Object?>{};

  void check(Object? want, Object? got, String reason) {
    if (want is String &&
        (want.startsWith(r'$session_') || want.startsWith(r'$fp_'))) {
      if (want.startsWith(r'$session_')) {
        expect(got, matches(_sessionPattern), reason: reason);
      } else {
        expect(got, matches(RegExp(r'^[0-9a-f]{16}$')), reason: reason);
      }
      if (_bound.containsKey(want)) {
        expect(got, _bound[want], reason: '$reason ($want)');
      } else {
        expect(_bound.values, isNot(contains(got)),
            reason: '$reason ($want must be distinct)');
        _bound[want] = got;
      }
      return;
    }
    if (want == r'$error_kind') {
      expect(got, 'dart', reason: reason);
      return;
    }
    if (want == r'$fatal_detected_by') {
      expect(got, 'dart_fatal', reason: reason);
      return;
    }
    expect(got, _bind(want), reason: reason);
  }
}

/// The context keys a v2 expectation governs (SPEC.md -> Version context).
const _governed = [
  'app_version',
  'app_build',
  'platform',
  'sdk_name',
  'sdk_version',
  'locale',
];

/// Whether this SDK has the receipt path a `receivePush` step names.
bool _hasReceiptPath(Map<String, dynamic> c) =>
    (c['steps'] as List).every((s) =>
        (s as Map)['receivePush'] == null ||
        s['receivePush']['source'] == 'foreground');

void main() {
  FlutterExceptionHandler? saved;
  setUpAll(() {
    saved = FlutterError.onError;
    FlutterError.onError = (_) => _priorHandlerCalls++;
  });
  tearDownAll(() => FlutterError.onError = saved);

  test('engagement signals conformance (signalsV3)', () async {
    final spec = await _loadSpec();
    final sections = (spec['signalsV3'] as Map)['sections'] as Map;
    var ran = 0;
    for (final entry in sections.entries) {
      final section = entry.value as Map;
      if (!(section['appliesTo'] as List).contains('mobile')) continue;
      for (final raw in (section['cases'] as List).cast<Map<String, dynamic>>()) {
        final c = _Case(raw);
        await _run(c);
        ran++;
        final contexts = <Map<dynamic, dynamic>>[];
        final sent = c.sentEvents(contexts);
        final expected = raw['expectedEvents'] as List;
        expect(sent.map((e) => e['event_type']).toList(),
            expected.map((e) => (e as Map)['event_type']).toList(),
            reason: c.name);
        final binder = _Binder();
        for (var i = 0; i < expected.length; i++) {
          final e = expected[i] as Map;
          final where = '${c.name} event[$i] ${e['event_type']}';
          final want = Map<String, dynamic>.from(e['properties'] as Map);
          final got = Map<String, dynamic>.from(sent[i]['properties'] as Map);
          expect(got.keys.toSet(), want.keys.toSet(), reason: '$where keys');
          for (final key in want.keys) {
            binder.check(want[key], got[key], '$where.$key');
          }
          final ctx = e['context'] as Map?;
          if (ctx != null && ctx['session_id'] != null) {
            binder.check(ctx['session_id'], contexts[i]['session_id'],
                '$where context.session_id');
          }
        }
      }
    }
    expect(ran, greaterThan(0));
  });

  test('automatic-events conformance, contract v2 push events (pushEventsV2)',
      () async {
    final spec = await _loadSpec();
    final cases = ((spec['pushEventsV2'] as Map?)?['cases'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .where(_hasReceiptPath)
        .toList();
    expect(cases, isNotEmpty);
    for (final raw in cases) {
      final c = _Case(raw);
      await _run(c);
      final allContexts = <Map<dynamic, dynamic>>[];
      final all = c.sentEvents(allContexts);
      final expected = raw['expectedEvents'] as List;
      final sent = _legacy(spec, all, expected);
      final contexts = [
        for (var i = 0; i < all.length; i++)
          if (!_legacyEvents.contains(all[i]['event_type'])) allContexts[i]
      ];
      expect(sent.length, expected.length, reason: c.name);
      for (var i = 0; i < expected.length; i++) {
        final e = expected[i] as Map;
        expect(
            sent[i],
            {
              'event_type': e['event_type'],
              'properties': _bind(e['properties']),
            },
            reason: '${c.name} event[$i]');
        final want = e['context'] as Map?;
        if (want == null) continue;
        for (final key in _governed) {
          expect(contexts[i][key], _bind(want[key]),
              reason: '${c.name} event[$i] context.$key');
        }
      }
    }
  });

  test('automatic-events conformance (whisperr-spec)', () async {
    final spec = await _loadSpec();
    final common = Map<String, dynamic>.from(spec['commonProperties'] as Map);
    for (final key in ['platform', 'os_name', 'sdk_name']) {
      final allowed = (common[key] as Map)['enum'] as List;
      expect(allowed, contains(_bind(common[key]['placeholder'])),
          reason: 'commonProperties.$key');
    }

    final superseded = await supersededCases();
    final cases = (spec['cases'] as List)
        .cast<Map<String, dynamic>>()
        .where((c) => !superseded.contains('automatic.json:${c['name']}'))
        .toList();
    expect(cases, isNotEmpty);
    for (final raw in cases) {
      final c = _Case(raw);
      await _run(c);
      final expected = [
        for (final e in raw['expectedEvents'] as List)
          {
            'event_type': (e as Map)['event_type'],
            'properties': _bind(e['properties']),
          }
      ];
      expect(_legacy(spec, c.sentEvents(), expected), expected,
          reason: c.name);
    }
  });
}
