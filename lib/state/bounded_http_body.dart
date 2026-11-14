import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Reads a response with independent limits on size, inactivity and total time.
Future<List<int>> readBoundedHttpBody(
  HttpClientResponse response, {
  int maxBytes = 8 * 1024 * 1024,
  Duration idleTimeout = const Duration(seconds: 10),
  Duration totalTimeout = const Duration(seconds: 30),
  String sizeError = '응답은 8MB보다 작아야 합니다.',
}) {
  final result = Completer<List<int>>();
  final bytes = BytesBuilder(copy: false);
  late StreamSubscription<List<int>> subscription;
  Timer? idleTimer;
  Timer? totalTimer;

  void finish([Object? error, StackTrace? stack]) {
    if (result.isCompleted) return;
    idleTimer?.cancel();
    totalTimer?.cancel();
    // Cancellation must not itself hold up the deadline if the peer stalls.
    unawaited(subscription.cancel().catchError((Object _) {}));
    if (error != null) {
      result.completeError(error, stack);
    } else {
      result.complete(bytes.takeBytes());
    }
  }

  void resetIdleTimer() {
    idleTimer?.cancel();
    idleTimer = Timer(idleTimeout, () {
      finish(TimeoutException('HTTP response body idle timeout', idleTimeout));
    });
  }

  subscription = response.listen(
    (chunk) {
      if (bytes.length + chunk.length > maxBytes) {
        finish(FormatException(sizeError));
        return;
      }
      bytes.add(chunk);
      resetIdleTimer();
    },
    onError: (Object error, StackTrace stack) => finish(error, stack),
    onDone: () => finish(),
  );
  resetIdleTimer();
  totalTimer = Timer(totalTimeout, () {
    finish(
      TimeoutException('HTTP response body deadline exceeded', totalTimeout),
    );
  });
  return result.future;
}

/// Discards a response without waiting for an untrusted peer to finish it.
void cancelHttpBody(HttpClientResponse response) {
  final subscription = response.listen(null);
  unawaited(subscription.cancel().catchError((Object _) {}));
}
