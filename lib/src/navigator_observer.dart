import 'dart:async';

import 'package:flutter/widgets.dart';

import 'signals.dart';
import 'whisperr_client.dart';

/// Sends `screen_viewed` for each page route the app navigates to, named by
/// its `RouteSettings.name`. Add it to your app's navigator:
///
/// ```dart
/// MaterialApp(navigatorObservers: [WhisperrNavigatorObserver()]);
/// ```
///
/// Only [PageRoute]s count (dialogs and popups do not). The query and
/// fragment of a name are dropped, and in a path name (`/orders/123`) ids
/// become `:id`. A route without a name is skipped unless [nameOf] names it. A pop reports the route it
/// returns to. It uses [client], else the [Whisperr] singleton once it is
/// initialized.
class WhisperrNavigatorObserver extends NavigatorObserver {
  WhisperrNavigatorObserver({this.client, this.nameOf});

  /// The client to report to; null uses [Whisperr.instance].
  final WhisperrClient? client;

  /// Names a route (return null to skip it). Defaults to
  /// `route.settings.name`.
  final String? Function(Route<dynamic> route)? nameOf;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _report(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) _report(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute && previousRoute != null) _report(previousRoute);
  }

  void _report(Route<dynamic> route) {
    if (route is! PageRoute) return;
    final name = screenNameOf((nameOf ?? _settingsName)(route));
    if (name == null) return;
    final target =
        client ?? (Whisperr.isInitialized ? Whisperr.instance : null);
    if (target == null) return;
    try {
      unawaited(target.screen(name).catchError((Object _) {}));
    } catch (_) {
      // a closed client: navigation must never fail because of analytics
    }
  }

  static String? _settingsName(Route<dynamic> route) => route.settings.name;
}

/// A route name as a screen name: the query and fragment dropped, and for a
/// path (`/…`) ids replaced by `:id`, so tokens and ids in a route never
/// leave the device. Null when nothing is left.
@visibleForTesting
String? screenNameOf(String? raw) {
  if (raw == null) return null;
  var name = raw.trim();
  final cut = name.indexOf(RegExp(r'[?#]'));
  if (cut != -1) name = name.substring(0, cut);
  if (name.startsWith('/')) name = redactRoute(name);
  return name.isEmpty ? null : name;
}
