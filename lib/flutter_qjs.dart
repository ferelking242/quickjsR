import 'package:flutter_qjs/javascript_runtime.dart';
import './quickjs/quickjs_runtime2.dart';
import './extensions/handle_promises.dart';

export './extensions/handle_promises.dart';
export './quickjs/quickjs_runtime2.dart';
export 'javascript_runtime.dart';
export 'js_eval_result.dart';

JavascriptRuntime getJavascriptRuntime({
  Map<String, dynamic>? extraArgs = const {},
  int stackSize = 1024 * 1024,
  int? timeout,
  int? memoryLimit,
  int? gcThreshold,
}) {
  JavascriptRuntime runtime;
  runtime = QuickJsRuntime2(
    stackSize: stackSize,
    timeout: timeout,
    memoryLimit: memoryLimit,
    gcThreshold: gcThreshold,
  );
  runtime.enableHandlePromises();
  return runtime;
}
