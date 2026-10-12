import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'spec_ref.dart';

/// Loads a conformance fixture: from [overrideEnv] when set, else next to
/// `WHISPERR_SPEC_PATH` (wire.json), else from GitHub at [kSpecRef].
Future<Map<String, dynamic>> loadSpecFixture(String file,
    {String? overrideEnv}) async {
  var local = overrideEnv == null ? null : Platform.environment[overrideEnv];
  final wire = Platform.environment['WHISPERR_SPEC_PATH'];
  if ((local == null || local.isEmpty) && wire != null && wire.isNotEmpty) {
    local = File(wire).parent.uri.resolve(file).toFilePath();
  }
  if (local != null && local.isNotEmpty) {
    return jsonDecode(await File(local).readAsString()) as Map<String, dynamic>;
  }
  final res = await http.get(Uri.parse('$kSpecBaseUrl/$file'));
  if (res.statusCode != 200) {
    throw StateError('fetch $file at $kSpecRef: ${res.statusCode}');
  }
  return jsonDecode(res.body) as Map<String, dynamic>;
}

/// The v2 sections this SDK runs (whisperr-spec SPEC.md -> Contract v2
/// conformance). `serverVersionContext` is for server SDKs only.
const kV2Sections = [
  'restoreIdentify',
  'appLanguage',
  'anonymousPush',
  'pushRegistration',
  'versionContext',
];

/// The legacy cases (`<file>:<case name>`) that the v2 sections this SDK
/// runs supersede, plus those of `automatic.json` `pushEventsV2`.
Future<Set<String>> supersededCases() async {
  final v2 =
      await loadSpecFixture('v2.json', overrideEnv: 'WHISPERR_V2_SPEC_PATH');
  final automatic = await loadSpecFixture('automatic.json',
      overrideEnv: 'WHISPERR_AUTOMATIC_SPEC_PATH');
  final sections = v2['sections'] as Map<String, dynamic>;
  return {
    for (final name in kV2Sections)
      ...((sections[name] as Map)['supersedes'] as List).cast<String>(),
    ...(((automatic['pushEventsV2'] as Map?)?['supersedes'] as List?) ??
            const [])
        .cast<String>(),
  };
}

/// The v2 comparison rule for identify bodies: on a body that carries
/// `external_user_id`, `anonymous_id` is ignored when the expected body does
/// not name it.
Map<String, dynamic> withoutUnnamedAnonymousId(
    Map<String, dynamic> actual, Map<String, dynamic> expected) {
  if (actual.containsKey('external_user_id') &&
      !expected.containsKey('anonymous_id')) {
    return Map<String, dynamic>.from(actual)..remove('anonymous_id');
  }
  return actual;
}
