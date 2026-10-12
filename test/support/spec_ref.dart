/// The whisperr-spec git ref the conformance suites download when no local
/// fixture path is set (CI checks out the same ref; see ci.yml).
///
/// Contract v2 fixtures live on the spec branch until the spec PR merges.
/// After it merges, set this back to `main` (and drop `ref:` in ci.yml).
const String kSpecRef = 'feat/contract-v2-sdk';

/// Base URL of the conformance fixtures at [kSpecRef].
const String kSpecBaseUrl =
    'https://raw.githubusercontent.com/WhisperrAI/whisperr-spec/$kSpecRef/conformance';
