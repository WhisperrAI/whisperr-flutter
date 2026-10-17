import 'dart:async';

import 'package:flutter/widgets.dart';

import 'whisperr_client.dart';

/// Sends `screen_viewed` for each page route the app navigates to, named by
/// its `RouteSettings.name`. Add it to your app's navigator:
///
/// ```dart
/// MaterialApp(navigatorObservers: [WhisperrNavigatorObserver()]);
/// ```
///
/// Only [PageRoute]s count (dialogs and popups do not). A route without a
/// name is skipped unless [nameOf] names it. A pop reports the route it
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
    final name = (nameOf ?? _settingsName)(route)?.trim();
    if (name == null || name.isEmpty) return;
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
