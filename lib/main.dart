import 'dart:async';
import 'dart:io' show Platform;
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
  // These channel/view-type names must match ios/Runner/AppDelegate.swift exactly.
  static const _control = MethodChannel('com.noor.slam/control');
  static const _frames = EventChannel('com.noor.slam/frames');
  static const _arViewType = 'ar-preview-view';

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
      body: Stack(
        children: [
          // Live camera feed + ARKit's yellow feature-point overlay,
          // filling the whole screen behind the UI.
          Positioned.fill(
            child: Platform.isIOS
                ? const UiKitView(
                    viewType: _arViewType,
                    creationParamsCodec: StandardMessageCodec(),
                  )
                : const ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: Text(
                        'AR preview only available on iOS',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
          ),

          // Top overlay: live stats.
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 16,
            right: 16,
            child: Card(
              color: Colors.black.withOpacity(0.6),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Tracking: $_trackingState',
                        style: const TextStyle(color: Colors.white)),
                    Text('Map points: $_pointCount',
                        style: const TextStyle(color: Colors.white)),
                    Text(
                      'Pose (x, y, z): ${_x.toStringAsFixed(2)}, '
                      '${_y.toStringAsFixed(2)}, ${_z.toStringAsFixed(2)}',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom overlay: controls.
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 16,
            left: 16,
            right: 16,
            child: Column(
              children: [
                ElevatedButton.icon(
                  icon: Icon(_running ? Icons.stop : Icons.play_arrow),
                  label: Text(_running ? 'Stop Scan' : 'Start Scan'),
                  onPressed: _toggleScan,
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Export & Share Map (.ply)'),
                  onPressed: _pointCount > 0 ? _export : null,
                ),
                if (_lastExportPath != null) ...[
                  const SizedBox(height: 6),
                  Text('Saved to: $_lastExportPath',
                      style:
                          const TextStyle(color: Colors.white, fontSize: 11)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
