// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:bluebird/bluebird.dart';

import 'device_screen.dart';
import '../utils/snackbar.dart';

// Well-known service names offered as autocomplete suggestions. Values come
// from the library so they stay in sync.
final _knownServices = <String, Uuid>{
  'Generic Access': Uuids.service.genericAccess,
  'Generic Attribute': Uuids.service.genericAttribute,
  'Immediate Alert': Uuids.service.immediateAlert,
  'Link Loss': Uuids.service.linkLoss,
  'Tx Power': Uuids.service.txPower,
  'Current Time': Uuids.service.currentTime,
  'Health Thermometer': Uuids.service.healthThermometer,
  'Device Information': Uuids.service.deviceInformation,
  'Heart Rate': Uuids.service.heartRate,
  'Battery': Uuids.service.battery,
  'Human Interface Device': Uuids.service.humanInterfaceDevice,
  'Environmental Sensing': Uuids.service.environmentalSensing,
};

/// Resolves a typed entry — a known service name or a raw UUID — to a [Uuid].
Uuid? _resolve(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  for (final e in _knownServices.entries) {
    if (e.key.toLowerCase() == t.toLowerCase()) return e.value;
  }
  try {
    return Uuid(t);
  } catch (_) {
    return null;
  }
}

/// The known name for a service uuid, or null if it isn't a standard one.
String? _serviceName(Uuid uuid) {
  for (final e in _knownServices.entries) {
    if (e.value == uuid) return e.key;
  }
  return null;
}

/// Web has no passive scan — the browser shows a chooser that returns a single
/// device. This page lets you configure the chooser (filters + the optional
/// services you want access to) and connects to whatever you pick.
class WebScanScreen extends StatefulWidget {
  const WebScanScreen({Key? key}) : super(key: key);

  @override
  State<WebScanScreen> createState() => _WebScanScreenState();
}

class _WebScanScreenState extends State<WebScanScreen> {
  final List<Uuid> _serviceFilter = [];
  final List<Uuid> _optionalServices = [Uuids.service.deviceInformation, Uuids.service.battery];
  final _nameFilter = TextEditingController();

  bool _connecting = false;

  @override
  void dispose() {
    _nameFilter.dispose();
    super.dispose();
  }

  Future<void> onConnectPressed() async {
    setState(() => _connecting = true);
    try {
      final name = _nameFilter.text.trim();

      // whatever the chooser returns lands as the (single) scan result;
      // taking .first stops the scan
      // no timeout: the browser's device chooser gives the user unlimited time,
      // and .first resolves when they pick (or errors if they cancel)
      final result = await Bluebird.performScan(
        withServices: _serviceFilter,
        withNames: name.isEmpty ? const [] : [name],
        webOptionalServices: _optionalServices,
      ).first;
      final device = result.device;

      await device.connect(mtu: null);

      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(builder: (context) => DeviceScreen(device: device)));
    } catch (e) {
      Snackbar.show(prettyException("Connect Error:", e), success: false);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // no app bar on web — the logo is the header
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                Center(child: Image.asset('assets/bluebird.png', height: 140)),
                const SizedBox(height: 24),
                Text('Connect a device', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'The browser will show a device chooser. On web you can only access '
                  'services you list up front — narrow the chooser with filters if you like.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _nameFilter,
                  decoration: const InputDecoration(
                    labelText: 'Filter by name',
                    hintText: 'exact device name (optional)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                _ServiceSelector(label: 'Filter by service', values: _serviceFilter, onChanged: () => setState(() {})),
                const SizedBox(height: 12),
                _ServiceSelector(
                  label: 'Optional services',
                  values: _optionalServices,
                  onChanged: () => setState(() {}),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  icon: _connecting
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.bluetooth),
                  label: Text(_connecting ? 'Connecting…' : 'Connect a device'),
                  onPressed: _connecting ? null : onConnectPressed,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An autocompleting service picker: type a known service name or a raw UUID,
/// press enter to add it. Selections are shown as compact list tiles (UUID with
/// the known name as subtitle). [values] is mutated in place.
class _ServiceSelector extends StatefulWidget {
  const _ServiceSelector({required this.label, required this.values, required this.onChanged});

  final String label;
  final List<Uuid> values;
  final VoidCallback onChanged;

  @override
  State<_ServiceSelector> createState() => _ServiceSelectorState();
}

class _ServiceSelectorState extends State<_ServiceSelector> {
  TextEditingController? _controller;

  void _add(Uuid uuid) {
    if (!widget.values.contains(uuid)) {
      widget.values.add(uuid);
      widget.onChanged();
    }
    _controller?.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Autocomplete<String>(
          // match on the name or the UUID (short or full form), so typing
          // "battery", "180f", or "0000180f-…" all surface the same service
          optionsBuilder: (value) {
            final q = value.text.trim().toLowerCase();
            if (q.isEmpty) return const Iterable<String>.empty();
            return _knownServices.entries
                .where((e) => e.key.toLowerCase().contains(q) || e.value.string128.toLowerCase().contains(q))
                .map((e) => e.key);
          },
          fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
            _controller = controller;
            return TextField(
              controller: controller,
              focusNode: focusNode,
              decoration: InputDecoration(
                labelText: widget.label,
                hintText: 'service name or UUID, press enter to add',
                border: const OutlineInputBorder(),
                isDense: true,
                prefixIcon: const Icon(Icons.add),
              ),
              onSubmitted: (text) {
                final uuid = _resolve(text);
                if (uuid == null) {
                  Snackbar.show('Not a known service or valid UUID: $text', success: false);
                } else {
                  _add(uuid);
                }
                onFieldSubmitted();
              },
            );
          },
          // show both the name and the UUID in the dropdown
          optionsViewBuilder: (context, onSelected, options) {
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260, maxWidth: 472),
                  child: ListView(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    children: [
                      for (final name in options)
                        ListTile(
                          dense: true,
                          title: Text(name),
                          subtitle: Text(_knownServices[name]!.string),
                          onTap: () => onSelected(name),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
          onSelected: (name) => _add(_knownServices[name]!),
        ),
        for (final uuid in widget.values)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 12),
            title: Text(uuid.string),
            subtitle: _serviceName(uuid) != null ? Text(_serviceName(uuid)!) : null,
            trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                widget.values.remove(uuid);
                widget.onChanged();
              },
            ),
          ),
      ],
    );
  }
}
