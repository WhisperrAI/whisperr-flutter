/// Official Whisperr SDK for Flutter.
///
/// Identify users and track product events to power Whisperr's
/// churn-prevention interventions.
library whisperr;

export 'src/api_client.dart' show WhisperrApiException, WhisperrBatchResult, WhisperrApiClient;
export 'src/models.dart' show WhisperrChannel, WhisperrChannelType;
export 'src/persistence.dart' show WhisperrPersistence, InMemoryPersistence, SharedPreferencesPersistence;
export 'src/whisperr_client.dart' show Whisperr, WhisperrClient, kWhisperrSdkVersion, kWhisperrDefaultBaseUrl;
export 'src/whisperr_options.dart' show WhisperrOptions;
