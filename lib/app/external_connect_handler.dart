import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/native_vpn_bridge.dart';
import '../state/app_controller.dart';

class _PendingHandoff {
  bool pending = false;
  VoidCallback? notify;
}

final _handoffs = Expando<_PendingHandoff>();

/// Consumes cold and warm launcher requests only after the controller is ready.
class ExternalConnectHandler extends StatefulWidget {
  const ExternalConnectHandler({
    super.key,
    required this.controller,
    required this.child,
  });

  final AppController controller;
  final Widget child;

  @override
  State<ExternalConnectHandler> createState() => _ExternalConnectHandlerState();
}

class _ExternalConnectHandlerState extends State<ExternalConnectHandler> {
  StreamSubscription<void>? _subscription;
  ExternalConnectBridge? _bridge;
  _PendingHandoff? _handoff;
  bool _initialScan = false;
  bool _scanning = false;
  bool _rescan = false;
  bool _connecting = false;
  bool _waitingForConfiguration = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    final bridge = widget.controller.bridge;
    if (bridge is! ExternalConnectBridge) return;
    _bridge = bridge as ExternalConnectBridge;
    _handoff = _handoffs[bridge] ??= _PendingHandoff();
    _handoff!.notify = _scan;
    widget.controller.addListener(_onControllerChanged);
    _subscription = _bridge!.externalConnectRequests.listen(
      (_) => _scan(),
      onError: (Object _, StackTrace _) {},
    );
    _onControllerChanged();
  }

  void _onControllerChanged() {
    if (widget.controller.initialized && !_initialScan) {
      _initialScan = true;
      _scan();
    } else if (_waitingForConfiguration) {
      _scan();
    }
  }

  void _scan() {
    if (!widget.controller.initialized || _bridge == null) return;
    final controller = widget.controller;
    final duplicate =
        _connecting ||
        controller.preparingConnection ||
        controller.snapshot.isBusy ||
        controller.snapshot.isConnected;
    if (controller.configurationChangeInProgress && !duplicate) {
      _waitingForConfiguration = true;
      return;
    }
    _waitingForConfiguration = false;
    if (_scanning) {
      _rescan = true;
      return;
    }
    unawaited(_drain(_generation));
  }

  Future<void> _drain(int generation) async {
    _scanning = true;
    final bridge = _bridge!;
    final handoff = _handoff!;
    try {
      do {
        _rescan = false;
        final bool pending;
        if (handoff.pending) {
          handoff.pending = false;
          pending = true;
          _rescan = true;
        } else {
          pending = await bridge.consumeExternalConnect();
        }
        if (!mounted || generation != _generation) {
          if (pending) {
            final target = mounted ? _handoff ?? handoff : handoff;
            target.pending = true;
            target.notify?.call();
          }
          return;
        }
        final controller = widget.controller;
        if (pending) {
          final duplicate =
              _connecting ||
              controller.preparingConnection ||
              controller.snapshot.isBusy ||
              controller.snapshot.isConnected;
          if (!duplicate && controller.configurationChangeInProgress) {
            handoff.pending = true;
            _waitingForConfiguration = true;
            return;
          }
          if (!_connecting && controller.canStartExternalConnection) {
            _connecting = true;
            unawaited(_connect(controller, generation));
          }
        }
      } while (_rescan && mounted && generation == _generation);
    } catch (_) {
      // Unsupported platforms and a detached native activity have no request.
    } finally {
      if (generation == _generation) _scanning = false;
    }
  }

  Future<void> _connect(AppController controller, int generation) async {
    try {
      await controller.toggleVpn();
    } catch (_) {
      // The controller normally reports connection failures itself.
    } finally {
      if (generation == _generation) _connecting = false;
    }
  }

  void _detach(AppController controller) {
    _generation++;
    controller.removeListener(_onControllerChanged);
    unawaited(_subscription?.cancel());
    _subscription = null;
    _bridge = null;
    _handoff?.notify = null;
    _handoff = null;
    _initialScan = false;
    _scanning = false;
    _rescan = false;
    _connecting = false;
    _waitingForConfiguration = false;
  }

  @override
  void didUpdateWidget(covariant ExternalConnectHandler oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      final previousHandoff = _handoff;
      _detach(oldWidget.controller);
      _attach();
      if (previousHandoff != null &&
          previousHandoff != _handoff &&
          previousHandoff.pending &&
          _handoff != null) {
        previousHandoff.pending = false;
        _handoff!.pending = true;
        _scan();
      }
    }
  }

  @override
  void dispose() {
    _detach(widget.controller);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
