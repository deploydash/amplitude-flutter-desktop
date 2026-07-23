// ignore_for_file: depend_on_referenced_packages
import 'package:amplitude_flutter/amplitude.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AppState extends InheritedWidget {
  const AppState({
    Key? key,
    required this.analytics,
    required this.setMessage,
    required this.message,
    required Widget child,
  }) : super(key: key, child: child);

  final Amplitude analytics;
  final ValueSetter<String> setMessage;

  /// Last status message set via [setMessage]; listenable so any screen can
  /// display it.
  final ValueListenable<String> message;

  @override
  bool updateShouldNotify(InheritedWidget oldWidget) {
    return false;
  }

  static AppState of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AppState>()!;
  }
}
