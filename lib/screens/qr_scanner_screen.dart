import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/vpn_models.dart';

/// Captures one VLESS + REALITY share link and returns it to the profile flow.
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key, required this.resolvePayload});

  final Future<QrProfileResult> Function(String value) resolvePayload;

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
    autoZoom: true,
  );
  bool _finished = false;
  bool _processing = false;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_finished || _processing || capture.barcodes.isEmpty) return;
    final value = capture.barcodes.first.rawValue?.trim();
    if (value == null || value.isEmpty) return;
    _processing = true;
    await _controller.stop();
    QrProfileResult result;
    try {
      result = await widget.resolvePayload(value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('이 QR 코드에서 사용할 수 있는 프로필을 찾지 못했습니다.')),
        );
        _processing = false;
        await _restartScanner();
      }
      return;
    }
    _finished = true;
    if (mounted) Navigator.pop(context, result);
  }

  Future<void> _restartScanner() async {
    if (_finished || !mounted) return;
    try {
      await _controller.start();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('카메라를 다시 시작할 수 없습니다.')));
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('QR 코드 스캔')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            placeholderBuilder: (_) => const ColoredBox(
              color: Colors.black,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text(
                      '카메라를 준비하고 있습니다.',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
            errorBuilder: (_, error) => ColoredBox(
              color: Colors.black,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.videocam_off_outlined,
                        color: Colors.white,
                        size: 48,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        error.errorCode ==
                                MobileScannerErrorCode.permissionDenied
                            ? '카메라 권한이 필요합니다.\nAndroid 설정에서 Proxima의 카메라 권한을 허용해 주세요.'
                            : '카메라를 시작할 수 없습니다.\n실제 기기에서는 카메라 권한을, 에뮬레이터에서는 카메라 입력을 확인해 주세요.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              minimum: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () => _controller.toggleTorch(),
                        icon: const Icon(Icons.flash_on_outlined),
                        label: const Text('플래시'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonalIcon(
                        onPressed: () => _controller.switchCamera(),
                        icon: const Icon(Icons.cameraswitch_outlined),
                        label: const Text('카메라 전환'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
