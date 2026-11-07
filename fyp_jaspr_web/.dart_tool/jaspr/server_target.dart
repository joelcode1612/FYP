  import 'package:sitewise_jaspr_web/main.server.dart' as m;
  import 'package:hotreloader/hotreloader.dart';

  void main(List<String> args) async {
    final mainFunc = m.main as dynamic;
    final mainCall = mainFunc is dynamic Function(List<String>) ? () => mainFunc(args) : () => mainFunc();

    try {
      await HotReloader.create(
        // A non-zero interval is required: hotreloader falls back to polling watchers
        // for paths that don't exist (e.g. unused bin/ or test/ dirs), and a zero
        // pollingDelay there causes a busy loop pinning a CPU core (see #816).
        // This matches hotreloader's own default.
        debounceInterval: Duration(seconds: 1),
        onAfterReload: (ctx) => mainCall(),
      );
      print('[INFO] Server hot reload is enabled.');
    } on StateError catch (e) {
      if (e.message.contains('VM service not available')) {
        print('[WARNING] Server hot reload not enabled. Run with --enable-vm-service to enable hot reload.');
      } else {
        rethrow;
      }
    }
    
    mainCall();
  }
