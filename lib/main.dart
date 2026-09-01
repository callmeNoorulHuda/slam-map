import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const SlamApp());

class SlamApp extends StatelessWidget {
  const SlamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iPhone SLAM',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const SlamHomePage(),
    );
  }
}

class SlamHomePage extends StatefulWidget {
  const SlamHomePage({super.key});

  @override
  State<SlamHomePage> createState() => _SlamHomePageState();
}

class _SlamHomePageState extends State<SlamHomePage> {
  // These channel names must match ios/Runner/AppDelegate.swift exactly.
  static const _control = MethodChannel('com.noor.slam/control');
  static const _frames = EventChannel('com.noor.slam/frames');

  StreamSubscription? _sub;
  bool _running = false;
  int _pointCount = 0;
  double _x = 0, _y = 0, _z = 0;
  String _trackingState = 'notAvailable';
  String? _lastExportPath;

  void _startListening() {
    _sub = _frames.receiveBroadcastStream().listen((event) {
      final map = Map<String, dynamic>.from(event as Map);
      setState(() {
        _pointCount = map['pointCount'] as int;
        _x = (map['x'] as num).toDouble();
        _y = (map['y'] as num).toDouble();
        _z = (map['z'] as num).toDouble();
        _trackingState = map['trackingState'] as String;
      });
    }, onError: (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Stream error: $e')));
    });
  }

  Future<void> _toggleScan() async {
    if (_running) {
      await _control.invokeMethod('stop');
      await _sub?.cancel();
    } else {
      _startListening();
      await _control.invokeMethod('start');
    }
    setState(() => _running = !_running);
  }

  Future<void> _export() async {
    try {
      final path = await _control.invokeMethod<String>('export');
      setState(() => _lastExportPath = path);
      if (path != null) {
        await Share.shareXFiles([XFile(path)], text: 'SLAM point cloud (.ply)');
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Export failed: ${e.message}')));
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('iPhone SLAM Mapper')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Tracking: $_trackingState',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text('Map points: $_pointCount'),
                    Text(
                      'Pose (x, y, z): '
                      '${_x.toStringAsFixed(2)}, '
                      '${_y.toStringAsFixed(2)}, '
                      '${_z.toStringAsFixed(2)}',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: Icon(_running ? Icons.stop : Icons.play_arrow),
              label: Text(_running ? 'Stop Scan' : 'Start Scan'),
              onPressed: _toggleScan,
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              icon: const Icon(Icons.upload_file),
              label: const Text('Export & Share Map (.ply)'),
              onPressed: _pointCount > 0 ? _export : null,
            ),
            if (_lastExportPath != null) ...[
              const SizedBox(height: 12),
              Text('Saved to: $_lastExportPath',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            const Spacer(),
            const Text(
              'Move the phone slowly around the room to build up the map. '
              'Good lighting and textured surfaces improve tracking quality.',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
