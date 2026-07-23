import 'dart:async';

import 'package:ares_bridge/ares_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _bridge = AresBridge();
  final _subscriptions = <StreamSubscription<Object?>>[];

  String _connection = 'Starting';
  double? _progress;

  @override
  void initState() {
    super.initState();
    _subscriptions.add(
      _bridge.connectionEvents.listen((event) {
        setState(() => _connection = event.state.name);
      }),
    );
    _subscriptions.add(
      _bridge.transferProgress.listen((event) {
        setState(() => _progress = event.fraction);
      }),
    );
    _subscriptions.add(
      _bridge.receivedFiles.listen((event) {
        setState(() {
          _progress = null;
          _connection = 'Received ${event.fileName}';
        });
      }),
    );
    _start();
  }

  Future<void> _start() async {
    try {
      await _bridge.initialize();
      await _bridge.startListening();
    } on MissingPluginException {
      if (mounted) {
        setState(() => _connection = 'Native transport not installed');
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _connection = error.message ?? error.code);
      }
    }
  }

  /// Connect this to the desktop drop target's list of local file paths.
  Future<void> sendDroppedFiles(List<String> paths) async {
    await _bridge.sendFiles(<AresFileTransferRequest>[
      for (final path in paths) AresFileTransferRequest(sourcePath: path),
    ]);
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Ares Bridge')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('Connection: $_connection'),
              if (_progress case final progress?)
                SizedBox(
                  width: 240,
                  child: LinearProgressIndicator(value: progress),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
