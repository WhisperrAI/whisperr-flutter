import 'package:flutter/material.dart';
import 'package:whisperr/whisperr.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Whisperr.initialize(
    // baseUrl defaults to https://api.whisperr.net — no need to set it.
    apiKey: const String.fromEnvironment('WHISPERR_API_KEY', defaultValue: 'wrk_replace_me'),
    options: const WhisperrOptions(debug: true),
  );

  // Identify the signed-in user once you know who they are.
  await Whisperr.instance.identify(
    'user_123',
    traits: {'email': 'ada@example.com', 'plan': 'pro'},
    channels: [WhisperrChannel.email('ada@example.com', verified: true)],
    preferredChannel: WhisperrChannelType.email,
  );

  runApp(const _ExampleApp());
}

class _ExampleApp extends StatelessWidget {
  const _ExampleApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Whisperr example')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: () => Whisperr.instance.track('opened_feature', properties: {'feature': 'demo'}),
                child: const Text('Track opened_feature'),
              ),
              ElevatedButton(
                onPressed: () => Whisperr.instance.track('checkout_completed', properties: {'amount': 42}),
                child: const Text('Track checkout_completed'),
              ),
              ElevatedButton(
                onPressed: () => Whisperr.instance.flush(),
                child: const Text('Flush now'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
