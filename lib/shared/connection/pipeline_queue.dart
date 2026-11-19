/// The Mac's media pipelines run one operation at a time: every capture or
/// decoder start, rebuild and stop of every tablet's session, in the order
/// they were asked for. A session can end while its capture is still
/// starting; its stop then runs right after that start instead of beside
/// it, so the stop always wins. Across sessions it also keeps the native
/// side from seeing two sessions' virtual displays and streams being made
/// or removed at once (adding a display moves the others).
///
/// Never [run] from inside an operation that is itself running here: it
/// would wait for itself.
class PipelineQueue {
  Future<void> _tail = Future<void>.value();

  /// Runs [operation] once everything queued before it has finished,
  /// whether that worked or not.
  Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}
