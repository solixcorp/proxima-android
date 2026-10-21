import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class ProximaWebScreen extends StatefulWidget {
  const ProximaWebScreen({super.key});

  @override
  State<ProximaWebScreen> createState() => _ProximaWebScreenState();
}

class _ProximaWebScreenState extends State<ProximaWebScreen> {
  late final WebViewController _controller;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) => setState(() => _progress = progress),
          onPageFinished: (_) => setState(() => _progress = 100),
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            return uri?.scheme == 'https'
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(Uri.parse('https://server.tun.re'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Proxima'),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: _controller.reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_progress < 100) LinearProgressIndicator(value: _progress / 100),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
