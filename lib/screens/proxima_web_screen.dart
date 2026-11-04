import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/proxima_website.dart';

class ProximaWebScreen extends StatefulWidget {
  const ProximaWebScreen({super.key});

  @override
  State<ProximaWebScreen> createState() => _ProximaWebScreenState();
}

class _ProximaWebScreenState extends State<ProximaWebScreen> {
  late final WebViewController _controller;
  int _progress = 0;
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _progress = 100);
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            return uri?.scheme == 'https'
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
        ),
      );
    _loadWebsite();
  }

  Future<void> _loadWebsite() async {
    if (_resolving) return;
    setState(() {
      _resolving = true;
      _progress = 0;
    });
    try {
      final uri = await fetchProximaWebsite();
      if (!mounted) return;
      await _controller.loadRequest(uri);
    } catch (_) {
      if (!mounted) return;
      setState(() => _progress = 100);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('사이트 주소를 불러오지 못했습니다. 새로고침해 주세요.')),
      );
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Proxima'),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: _resolving ? null : _loadWebsite,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (_progress < 100)
              LinearProgressIndicator(value: _progress / 100),
            Expanded(child: WebViewWidget(controller: _controller)),
          ],
        ),
      ),
    );
  }
}
