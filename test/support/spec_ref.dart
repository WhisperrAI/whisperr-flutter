/// The whisperr-spec git ref the conformance suites download when no local
/// fixture path is set (CI checks out the same ref; see ci.yml).
///
/// To test against an unmerged spec branch, set it here and as `ref:` in
/// ci.yml.
const String kSpecRef = 'main';

/// Base URL of the conformance fixtures at [kSpecRef].
const String kSpecBaseUrl =
    'https://raw.githubusercontent.com/WhisperrAI/whisperr-spec/$kSpecRef/conformance';
