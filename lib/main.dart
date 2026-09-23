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
  await runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Portrait on a phone keeps the one control that matters - the talk button
    // - in the same place every time. On a wide window it would sit somewhere
    // different on every device, and this is a button people find without
    // looking.
    await SystemChrome.setPreferredOrientations(
      const <DeviceOrientation>[DeviceOrientation.portraitUp],
    );

    FlutterError.onError = (FlutterErrorDetails details) {
      ItLog.e('flutter', details.exceptionAsString(), details.exception,
          details.stack);
    };

    final ServiceLocator locator = await ServiceLocator.bootstrap();
    runApp(ItantraApp(locator: locator));
  }, (Object error, StackTrace stack) {
    // A crash here must not be silent: on a distress device, an app that
    // quietly died looks identical to an app that is listening.
    ItLog.e('boot', 'unhandled error', error, stack);
  });
}
