// Engagement signals v3: sessions, launch source, app_error, app_crashed.
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whisperr/src/navigator_observer.dart' show screenNameOf;
import 'package:whisperr/src/signals.dart';
import 'package:whisperr/whisperr.dart';

import 'support/spec_loader.dart';

class _Harness {
  final persistence = InMemoryPersistence();
  final requests = <http.Request>[];
  DateTime now = DateTime.utc(2026, 10, 17, 12);

  /// Monotonic ms; follows [now] unless a test freezes it (device sleep).
  int? frozenMono;

  late final MockClient mock = MockClient((req) async {
    requests.add(req);
    return http.Response('{"accepted":1,"rejected":0}', 202);
  });

  WhisperrClient client({
    bool captureErrors = true,
    bool debugBuild = false,
    Duration window = const Duration(milliseconds: 1500),
  }) =>
      WhisperrClient(
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
          captureErrors: captureErrors,
          launchSourceWindow: window,
        ),
        clock: () => now,
        monotonicMs: () => frozenMono ?? now.millisecondsSinceEpoch,
        debugBuild: debugBuild,
        random: Random(3),
        deviceTraits: () => const {},
        appContext: () async => const {'app_version': '2.0.0'},
      );

  List<Map<String, dynamic>> get events => [
        for (final r in requests)
          if (r.url.path == '/v1/events/batch')
            for (final e in (jsonDecode(r.body) as Map)['events'] as List)
              Map<String, dynamic>.from(e as Map),
      ];

  List<Map<String, dynamic>> named(String type) =>
      events.where((e) => e['event_type'] == type).toList();
}

Map<String, dynamic> _props(Map<String, dynamic> e) =>
    Map<String, dynamic>.from(e['properties'] as Map);

class _CartError extends Error {}

void main() {
  group('fingerprint', () {
    test('matches the spec vectors', () async {
      final spec = await loadSpecFixture('automatic.json',
          overrideEnv: 'WHISPERR_AUTOMATIC_SPEC_PATH');
      final vectors =
          (spec['signalsV3'] as Map)['fingerprintVectors'] as List;
      expect(vectors, isNotEmpty);
      for (final v in vectors.cast<Map<String, dynamic>>()) {
        expect(
            errorFingerprint(v['errorName'] as String,
                (v['frames'] as List).cast<String>()),
            v['fingerprint']);
      }
    });

    test('sha256 matches known digests', () {
      expect(sha256Hex(utf8.encode('abc')),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(sha256Hex(const []),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    });

    test('reads function names from a Dart VM stack', () {
      final stack = StackTrace.fromString(
          '#0      loadCart (package:shop/cart.dart:12:5)\n'
          '#1      CartScreen.build (package:shop/cart_screen.dart:40:7)\n'
          '<asynchronous suspension>\n'
          '#2      _render.<anonymous closure> (package:shop/x.dart:1:1)\n'
          '#3      main (package:shop/main.dart:3:3)\n');
      expect(stackFrameNames(stack),
          ['loadCart', 'CartScreen.build', '_render.<anonymous closure>']);
    });
  });

  group('links', () {
    test('redacts ids and keeps only the path', () {
      final s = linkSignal(Uri.parse(
          'https://shop.example.com/orders/12345/items/3f2c9a1e-8b7d-4c6e-9f00-1a2b3c4d5e6f/review/Zx9QmT4pLw8KvR2nB7?token=abc&utm_source=n#top'))!;
      expect(s.source, 'universal_link');
      expect(s.properties, {
        'link_route': '/orders/:id/items/:id/review/:id',
        'link_host': 'shop.example.com',
        'utm_source': 'n',
      });
    });

    test('custom scheme is a deep link without host; wsrc and wmid', () {
      final deep = linkSignal(Uri.parse('myapp://magic/Zx9QmT4pLw8KvR2nB7'))!;
      expect(deep.source, 'deep_link');
      expect(deep.properties, {'link_route': '/magic/:id'});
      expect(linkSignal(Uri.parse('myapp://home?wsrc=widget'))!.source,
          'widget');
      final email =
          linkSignal(Uri.parse('https://a.example/cart?wmid=msg_1'))!;
      expect(email.source, 'email');
      expect(email.properties['whisperr_message_id'], 'msg_1');
    });
  });

  group('sessions', () {
    test('every event carries the session id; it rolls after 30 min idle',
        () async {
      final h = _Harness();
      final c = h.client(window: Duration.zero);
      await c.start();
      await c.track('a');
      h.now = h.now.add(const Duration(minutes: 29));
      await c.track('b');
      h.now = h.now.add(const Duration(minutes: 31));
      await c.track('c');
      await c.close();
      final ids = [
        for (final e in h.events) (e['context'] as Map)['session_id'] as String
      ];
      expect(ids.every((id) => id.startsWith('sess_')), isTrue);
      expect(ids.toSet().length, 2);
      expect(ids[ids.length - 2], isNot(ids.last));
    });
  });

  group('sessions across device sleep', () {
    test('rolls when the wall clock moves 31 min but the monotonic clock '
        'stood still', () async {
      final h = _Harness();
      final c = h.client(window: Duration.zero);
      await c.start();
      await c.track('a');
      h.frozenMono = h.now.millisecondsSinceEpoch;
      h.now = h.now.add(const Duration(minutes: 31));
      await c.track('b');
      await c.close();
      final ids = [
        for (final e in h.events) (e['context'] as Map)['session_id'] as String
      ];
      expect(ids[ids.length - 2], isNot(ids.last));
    });
  });

  group('screen names', () {
    test('drop query and fragment and redact path ids', () {
      expect(screenNameOf('/reset?token=abc'), '/reset');
      expect(screenNameOf('/product/123'), '/product/:id');
      expect(screenNameOf('/a#frag'), '/a');
      expect(screenNameOf('Checkout'), 'Checkout');
      expect(screenNameOf('?x=1'), isNull);
      expect(screenNameOf(null), isNull);
    });
  });

  group('errors', () {
    late FlutterExceptionHandler? savedFlutter;
    late bool Function(Object, StackTrace)? savedPlatform;
    var flutterCalls = 0;
    var platformCalls = 0;

    setUp(() {
      savedFlutter = FlutterError.onError;
      savedPlatform = PlatformDispatcher.instance.onError;
      flutterCalls = 0;
      platformCalls = 0;
      FlutterError.onError = (_) => flutterCalls++;
      PlatformDispatcher.instance.onError = (_, __) {
        platformCalls++;
        return true;
      };
    });
    tearDown(() {
      FlutterError.onError = savedFlutter;
      PlatformDispatcher.instance.onError = savedPlatform;
    });

    test('both handlers are chained, the prior ones still run, and close '
        'restores them', () async {
      final h = _Harness();
      final c = h.client(window: Duration.zero);
      final prior = FlutterError.onError;
      await c.start();
      expect(FlutterError.onError, isNot(same(prior)));
      FlutterError.onError!(FlutterErrorDetails(exception: _CartError()));
      final handled = PlatformDispatcher.instance.onError!(
          StateError('x'), StackTrace.current);
      expect(flutterCalls, 1);
      expect(platformCalls, 1);
      expect(handled, isTrue);
      await c.close();
      expect(FlutterError.onError, same(prior));
      final errors = h.named('app_error').map(_props).toList();
      expect(errors.map((e) => e['error_name']), ['_CartError', 'StateError']);
      expect(errors.every((e) => e['error_kind'] == 'dart'), isTrue);
      expect(errors.every((e) => e['fatal'] == false), isTrue);
      for (final e in errors) {
        expect(e['fingerprint'], matches(RegExp(r'^[0-9a-f]{16}$')));
        expect(e.containsKey('message'), isFalse);
      }
    });

    test('captureErrors false installs nothing; trackError still sends',
        () async {
      final h = _Harness();
      final prior = FlutterError.onError;
      final c = h.client(captureErrors: false, window: Duration.zero);
      await c.start();
      expect(FlutterError.onError, same(prior));
      await c.trackError(Exception('secret'), name: 'HTTP_500', kind: 'network');
      await c.close();
      final e = _props(h.named('app_error').single);
      expect(e['error_name'], 'HTTP_500');
      expect(e['error_kind'], 'network');
      expect(jsonEncode(h.events), isNot(contains('secret')));
    });

    test('dedupes by fingerprint and caps at 20 per session; error_count '
        'keeps the true total', () async {
      final h = _Harness();
      final c = h.client(window: Duration.zero);
      await c.start();
      for (var i = 0; i < 25; i++) {
        await c.trackError(Exception(), name: 'E$i');
        await c.trackError(Exception(), name: 'E$i');
      }
      c.handleLifecycleState(AppLifecycleState.paused);
      await pumpEventQueue();
      await c.close();
      expect(h.named('app_error'), hasLength(20));
      expect(_props(h.named('app_backgrounded').single)['error_count'], 50);
    });
  });

  group('crashes', () {
    test('unclean shutdown sends app_crashed before the next app_opened',
        () async {
      final h = _Harness();
      final first = h.client(window: Duration.zero);
      await first.start();
      await first.screen('Checkout');
      await first.close(); // still in the foreground: no background
      final second = h.client(window: Duration.zero);
      await second.start();
      await second.close();
      final types = h.events.map((e) => e['event_type']).toList();
      final crash = types.indexOf('app_crashed');
      expect(crash, greaterThan(0));
      expect(types[crash + 1], 'app_opened');
      expect(_props(h.events[crash]), containsPair('crash_kind', 'abnormal_exit'));
      expect(_props(h.events[crash]),
          containsPair('detected_by', 'unclean_shutdown'));
      expect(_props(h.events[crash]),
          containsPair('crashed_screen_name', 'Checkout'));
      expect(_props(h.events[crash]),
          containsPair('crashed_app_version', '2.0.0'));
    });

    test('a debug build never sends app_crashed', () async {
      final h = _Harness();
      final first = h.client(debugBuild: true, window: Duration.zero);
      await first.start();
      await first.close();
      final second = h.client(debugBuild: true, window: Duration.zero);
      await second.start();
      await second.close();
      expect(h.named('app_crashed'), isEmpty);
    });

    test('a fatal error upgrades it to a crash', () async {
      final h = _Harness();
      final first = h.client(window: Duration.zero);
      await first.start();
      first.captureUncaughtError(_CartError(), StackTrace.current, fatal: true);
      await pumpEventQueue();
      await first.close();
      final second = h.client(window: Duration.zero);
      await second.start();
      await second.close();
      final crash = _props(h.named('app_crashed').single);
      expect(crash['crash_kind'], 'crash');
      expect(crash['detected_by'], 'dart_fatal');
    });
  });

  group('launch source', () {
    test('a push tap in the window makes app_opened push, sent before '
        'push_opened', () async {
      final h = _Harness();
      final c = h.client();
      await c.start();
      await c.trackPushOpened({'whisperr_message_id': 'm1'}, coldStart: true);
      await c.close();
      final types = h.events.map((e) => e['event_type']).toList();
      expect(types.indexOf('app_opened'), lessThan(types.indexOf('push_opened')));
      final open = _props(h.named('app_opened').single);
      expect(open['launch_source'], 'push');
      expect(open['whisperr_message_id'], 'm1');
    });

    test('a warm push tap before resumed sends app_opened first', () async {
      final h = _Harness();
      final c = h.client();
      await c.start();
      await c.flush();
      c.handleLifecycleState(AppLifecycleState.paused);
      await pumpEventQueue();
      await c.trackPushOpened({'whisperr_message_id': 'm2'});
      c.handleLifecycleState(AppLifecycleState.resumed); // no second open
      await pumpEventQueue();
      await c.close();
      final types = h.events.map((e) => e['event_type']).toList();
      expect(types.where((t) => t == 'app_opened'), hasLength(2));
      expect(types.lastIndexOf('app_opened'),
          lessThan(types.indexOf('push_opened')));
      final warm = _props(h.named('app_opened').last);
      expect(warm['launch_source'], 'push');
      expect(warm['cold_start'], false);
    });

    test('trackError with an empty screen uses the last screen', () async {
      final h = _Harness();
      final c = h.client(window: Duration.zero);
      await c.start();
      await c.screen('Cart');
      await c.trackError(Exception(), name: 'X', screen: '');
      await c.close();
      expect(_props(h.named('app_error').single)['screen_name'], 'Cart');
    });

    test('handleLaunchUri sets the source; flush ends the window', () async {
      final h = _Harness();
      final c = h.client();
      await c.start();
      c.handleLaunchUri(Uri.parse('myapp://orders/123?secret=1'));
      await c.flush();
      await c.close();
      final open = _props(h.named('app_opened').single);
      expect(open['launch_source'], 'deep_link');
      expect(open['link_route'], '/orders/:id');
      expect(jsonEncode(h.events), isNot(contains('secret')));
    });
  });

  group('WhisperrNavigatorObserver', () {
    test('reports named page routes and the route a pop returns to',
        () async {
      final h = _Harness();
      final c = h.client(window: Duration.zero);
      await c.start();
      final observer = WhisperrNavigatorObserver(client: c);
      final home = PageRouteBuilder<void>(
          settings: const RouteSettings(name: '/home'),
          pageBuilder: (_, __, ___) => const SizedBox());
      final cart = PageRouteBuilder<void>(
          settings: const RouteSettings(name: '/cart'),
          pageBuilder: (_, __, ___) => const SizedBox());
      final unnamed =
          PageRouteBuilder<void>(pageBuilder: (_, __, ___) => const SizedBox());
      final reset = PageRouteBuilder<void>(
          settings: const RouteSettings(name: '/reset?token=abc'),
          pageBuilder: (_, __, ___) => const SizedBox());
      final product = PageRouteBuilder<void>(
          settings: const RouteSettings(name: '/product/123'),
          pageBuilder: (_, __, ___) => const SizedBox());
      observer.didPush(reset, null);
      observer.didPush(product, reset);
      observer.didPush(home, product);
      observer.didPush(cart, home);
      observer.didPush(unnamed, cart);
      observer.didPop(cart, home);
      await pumpEventQueue();
      await c.close();
      expect(h.named('screen_viewed').map((e) => _props(e)['screen_name']),
          ['/reset', '/product/:id', '/home', '/cart', '/home']);
      expect(jsonEncode(h.events), isNot(contains('token=')));
    });
  });
}
