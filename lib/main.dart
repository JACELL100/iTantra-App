import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/util/log.dart';
import 'di/service_locator.dart';

/// Entry point.
///
/// The bootstrap is awaited before the first frame because the model pack
/// scan decides which languages the UI may offer; showing a language picker
/// and then removing options a second later is worse than a short splash.
Future<void> main() async {
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Landscape would put the talk button somewhere different on every
    // device, and this is a button people find without looking.
    await SystemChrome.setPreferredOrientations(
      <DeviceOrientation>[DeviceOrientation.portraitUp],
    );

    FlutterError.onError = (FlutterErrorDetails details) {
      ItLog.e('flutter', details.exceptionAsString(), details.exception,
          details.stack);
    };

    await ServiceLocator.bootstrap();
    runApp(const ItantraApp());
  }, (Object error, StackTrace stack) {
    // A crash here must not be silent: on a distress device, an app that
    // quietly died looks identical to an app that is listening.
    ItLog.e('boot', 'unhandled error', error, stack);
  });
}
