import 'dart:async';

import 'package:flutter/material.dart';
import 'package:bluebird/bluebird.dart';

import 'device_screen.dart';
import '../utils/snackbar.dart';
import '../widgets/system_device_tile.dart';
import '../widgets/scan_result_tile.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({Key? key}) : super(key: key);

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  List<BluetoothDevice> _systemDevices = [];
  List<ScanResult> _scanResults = [];
  bool _isScanning = false;

  late StreamSubscription<List<ScanResult>> _scanResultsSubscription;
  late StreamSubscription<bool> _isScanningSubscription;

  @override
  void initState() {
    super.initState();

    // mirror the managed scan's result list into local state
    _scanResultsSubscription = Bluebird.scanResults.listen((results) {
      _scanResults = results;
      if (mounted) {
        setState(() {});
      }
    });

    _isScanningSubscription = Bluebird.isScanning.listen((state) {
      _isScanning = state;
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _scanResultsSubscription.cancel();
    _isScanningSubscription.cancel();
    super.dispose();
  }

  /// Starts a managed scan that stops itself after [timeout], or via
  /// [onStopPressed].
  Future<void> _startScan({Duration timeout = const Duration(seconds: 15)}) async {
    try {
      await Bluebird.startScan(timeout: timeout);
    } catch (e) {
      Snackbar.show(prettyException("Start Scan Error:", e), success: false);
      print(e);
    }
  }

  Future onScanPressed() async {
    try {
      // `withServices` is required on iOS for privacy purposes, ignored on android.
      var withServices = [Uuid("180f")]; // Battery Level Service
      _systemDevices = await Bluebird.systemDevices(withServices);
    } catch (e) {
      Snackbar.show(prettyException("System Devices Error:", e), success: false);
      print(e);
    }
    await _startScan();
    if (mounted) {
      setState(() {});
    }
  }

  Future onStopPressed() async {
    try {
      await Bluebird.stopScan();
    } catch (e) {
      Snackbar.show(prettyException("Stop Scan Error:", e), success: false);
      print(e);
    }
  }

  Future onConnectPressed(BluetoothDevice device) async {
    try {
      await device.connect(mtu: null);
    } catch (e) {
      // connection failed — surface the error and stay on the scan page
      Snackbar.show(prettyException("Connect Error:", e), success: false);
      return;
    }
    if (!mounted) return;
    MaterialPageRoute route = MaterialPageRoute(builder: (context) => DeviceScreen(device: device));
    Navigator.of(context).push(route);
  }

  Future onRefresh() {
    if (_isScanning == false) {
      _startScan();
    }
    if (mounted) {
      setState(() {});
    }
    return Future.delayed(Duration(milliseconds: 500));
  }

  Widget _buildMenu(BuildContext context) {
    return PopupMenuButton<String>(
      onSelected: (value) {
        if (value == 'licenses') {
          showLicensePage(
            context: context,
            applicationName: 'bluebird',
            applicationIcon: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Image.asset('assets/bluebird-icon.png', height: 48),
            ),
          );
        }
      },
      itemBuilder: (context) => const [PopupMenuItem(value: 'licenses', child: Text('Open-source licenses'))],
    );
  }

  Widget buildScanButton(BuildContext context) {
    final scanning = Bluebird.isScanning.value;
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        icon: Icon(scanning ? Icons.stop : Icons.bluetooth_searching),
        label: Text(scanning ? 'Stop' : 'Scan'),
        // stop is destructive: error colors keep the label readable in light/dark
        style: scanning
            ? FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              )
            : null,
        onPressed: scanning ? onStopPressed : onScanPressed,
      ),
    );
  }

  List<Widget> _buildSystemDeviceTiles(BuildContext context) {
    return _systemDevices
        .map(
          (d) => SystemDeviceTile(
            device: d,
            onOpen: () => Navigator.of(context).push(MaterialPageRoute(builder: (context) => DeviceScreen(device: d))),
            onConnect: () => onConnectPressed(d),
          ),
        )
        .toList();
  }

  List<Widget> _buildScanResultTiles(BuildContext context) {
    return _scanResults.map((r) => ScanResultTile(result: r, onTap: () => onConnectPressed(r.device))).toList();
  }

  @override
  Widget build(BuildContext context) {
    // the empty state already shows the big logo, so drop the title until a
    // scan has started (or produced results)
    final hasDevices = _systemDevices.isNotEmpty || _scanResults.isNotEmpty;
    final showAppBar = _isScanning || hasDevices;
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        // the empty state already shows the big logo, so drop the title there
        title: showAppBar
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset('assets/bluebird-icon.png', height: 28),
                  const SizedBox(width: 8),
                  const Text('bluebird'),
                ],
              )
            : null,
        actions: [_buildMenu(context)],
      ),
      body: RefreshIndicator(
        onRefresh: onRefresh,
        child: (_systemDevices.isEmpty && _scanResults.isEmpty)
            ? ListView(
                // keep it scrollable so pull-to-refresh still works when empty
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 96, bottom: 16),
                    child: Center(child: Image.asset('assets/bluebird.png', height: 180)),
                  ),
                  Center(
                    child: Text(
                      'Tap Scan to find nearby devices',
                      style: TextStyle(color: Theme.of(context).hintColor),
                    ),
                  ),
                ],
              )
            : ListView(children: <Widget>[..._buildSystemDeviceTiles(context), ..._buildScanResultTiles(context)]),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(padding: const EdgeInsets.all(16.0), child: buildScanButton(context)),
      ),
    );
  }
}
