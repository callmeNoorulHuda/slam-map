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
  static const _mapViewType = 'point-cloud-view';

  StreamSubscription? _sub;
  bool _running = false;
  bool _showMap = false; // toggled after a scan, to view the built map
  bool _highDetail = true;
  int _pointCount = 0;
  int _lastPointCount = 0;
  DateTime _lastCountUpdate = DateTime.now();
  bool _showGapWarning = false;
  double _x = 0, _y = 0, _z = 0;
  String _trackingState = 'notAvailable';
  String? _lastExportPath;

  String get _guidanceMessage {
    if (!_running) return 'Tap Start to begin mapping';
    switch (_trackingState) {
      case 'normal':
        return 'Scanning... Move slowly for best results';
      case 'initializing':
        return 'Initializing... Keep the phone steady';
      case 'tooFast':
        return 'Moving too fast! Please slow down';
      case 'lowFeatures':
        return 'Looking for details... Avoid plain walls';
      case 'relocalizing':
        return 'Relocalizing... Return to a known area';
      default:
        return 'Scan in progress';
    }
  }

  void _startListening() {
    _sub = _frames.receiveBroadcastStream().listen((event) {
      final map = Map<String, dynamic>.from(event as Map);
      final newCount = map['pointCount'] as int;

      setState(() {
        // Gap warning logic: if we are moving but not finding new points
        if (_running && newCount > 0) {
          final now = DateTime.now();
          if (newCount > _lastPointCount) {
            _lastCountUpdate = now;
            _showGapWarning = false;
          } else if (now.difference(_lastCountUpdate).inSeconds > 3) {
            _showGapWarning = true;
          }
        }

        _lastPointCount = _pointCount;
        _pointCount = newCount;
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
      // Show pre-scan tips
      final proceed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Scanning Tips'),
          content: const Text(
            '• Move the phone slowly in a circular motion.\n'
            '• Ensure good lighting.\n'
            '• Aim at textured objects (not plain walls).\n'
            '• LiDAR will be used automatically if available.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Start'),
            ),
          ],
        ),
      );

      if (proceed != true) return;

      _showMap = false;
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

  Future<void> _toggleHighDetail(bool value) async {
    await _control.invokeMethod('setHighDetail', value);
    setState(() => _highDetail = value);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canViewMap = !_running && _pointCount > 0;

    return Scaffold(
      body: Stack(
        children: [
          // Background: either the live AR camera feed, or (after stopping)
          // the static orbit-able point-cloud map.
          Positioned.fill(
            child: !Platform.isIOS
                ? const ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: Text(
                        'AR preview only available on iOS',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  )
                : UiKitView(
                    // Changing the key forces Flutter to recreate the native
                    // view when switching modes, so the map viewer picks up
                    // the freshly finished scan's points on creation.
                    key: ValueKey(_showMap ? 'map-$_pointCount' : 'live'),
                    viewType: _showMap ? _mapViewType : _arViewType,
                    creationParamsCodec: const StandardMessageCodec(),
                  ),
          ),

          // Top overlay: live stats (hidden while viewing the finished map).
          if (!_showMap)
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              left: 16,
              right: 16,
              child: Column(
                children: [
                  Card(
                    color: Colors.black.withOpacity(0.6),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Tracking: $_trackingState',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold)),
                              Icon(
                                _trackingState == 'normal'
                                    ? Icons.check_circle
                                    : Icons.warning,
                                color: _trackingState == 'normal'
                                    ? Colors.green
                                    : Colors.orange,
                                size: 16,
                              ),
                            ],
                          ),
                          const Divider(color: Colors.white24),
                          Text('Points captured: $_pointCount',
                              style: const TextStyle(color: Colors.white)),
                          Text(
                            'Position: ${_x.toStringAsFixed(2)}, '
                            '${_y.toStringAsFixed(2)}, ${_z.toStringAsFixed(2)}',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_running) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.teal.withOpacity(0.8),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _guidanceMessage,
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                    if (_showGapWarning)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withOpacity(0.9),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            '⚠️ Gaps detected! Scan this area more thoroughly',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 12),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),

          if (_showMap)
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              left: 16,
              right: 16,
              child: Card(
                color: Colors.black.withOpacity(0.6),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Map view — $_pointCount points',
                          style: const TextStyle(color: Colors.white)),
                      const Text('Drag to rotate • Pinch to zoom',
                          style:
                              TextStyle(color: Colors.white70, fontSize: 12)),
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
                if (!_showMap) ...[
                  if (!_running)
                    Card(
                      color: Colors.black.withOpacity(0.6),
                      child: SwitchListTile(
                        title: const Text('High Detail Mode',
                            style:
                                TextStyle(color: Colors.white, fontSize: 14)),
                        subtitle: const Text('Uses raw LiDAR depth maps',
                            style:
                                TextStyle(color: Colors.white70, fontSize: 11)),
                        value: _highDetail,
                        onChanged: _toggleHighDetail,
                        activeThumbColor: Colors.tealAccent,
                      ),
                    ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    icon: Icon(_running ? Icons.stop : Icons.play_arrow),
                    label: Text(_running ? 'Stop Scan' : 'Start Scan'),
                    onPressed: _toggleScan,
                  ),
                  const SizedBox(height: 8),
                  if (canViewMap)
                    ElevatedButton.icon(
                      icon: const Icon(Icons.threed_rotation),
                      label: const Text('View Map'),
                      onPressed: () => setState(() => _showMap = true),
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
                ] else ...[
                  ElevatedButton.icon(
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Back to Camera'),
                    onPressed: () => setState(() => _showMap = false),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Export & Share Map (.ply)'),
                    onPressed: _export,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
