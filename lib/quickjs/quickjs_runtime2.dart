/* START PARTS IMPORT QJS ENGINE */
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_qjs/javascript_runtime.dart';
import 'package:flutter_qjs/js_eval_result.dart';

import 'ffi.dart';

export 'ffi.dart' show JSEvalFlag, JSRef;

part 'isolate.dart';
part 'object.dart';
part 'wrapper.dart';

/// Handler function to manage js module.
typedef _JsModuleHandler = String Function(String name);

/// Handler to manage unhandled promise rejection.
typedef _JsHostPromiseRejectionHandler = void Function(dynamic reason);

/// Quickjs engine for flutter.
class QuickJsRuntime2 extends JavascriptRuntime {
  Pointer<JSRuntime>? _rt;
  Pointer<JSContext>? _ctx;

  /// Set by [dispose]. A disposed runtime is terminal: [_ensureEngine] must
  /// never silently create a second engine for a caller that still holds this
  /// object (a pending promise poller, a late extension call). Re-creating one
  /// left the old JSRefs and channel callbacks pointing at freed memory, which
  /// is the SIGSEGV seen in `js_channel`.
  bool _disposed = false;

  /// Max stack size for quickjs.
  int stackSize;

  /// Maximum CPU time for one synchronous JavaScript evaluation in ms.
  final int? timeout;

  /// Max memory for quickjs.
  final int? memoryLimit;

  /// Garbage collection threshold in bytes. Zero keeps QuickJS's default.
  final int? gcThreshold;

  /// Message Port for event loop. Close it to stop dispatching event loop.
  ReceivePort port = ReceivePort();

  /// Handler function to manage js module.
  final _JsModuleHandler? moduleHandler;

  /// Handler function to manage js module.
  final _JsHostPromiseRejectionHandler? hostPromiseRejectionHandler;

  QuickJsRuntime2({
    this.moduleHandler,
    this.stackSize = 1024 * 1024,
    this.timeout,
    this.memoryLimit,
    this.gcThreshold,
    this.hostPromiseRejectionHandler,
  }) {
    this.init();
  }

  _ensureEngine() {
    if (_rt != null) return;
    if (_disposed) {
      throw JSError('InternalError: JavaScript runtime has been disposed');
    }
    final rt = jsNewRuntime((ctx, type, ptr) {
      try {
        switch (type) {
          case JSChannelType.METHON:
            final pdata = ptr.cast<Pointer<JSValue>>();
            final argc = (pdata + 1).value.cast<Int32>().value;
            final pargs = [];
            for (var i = 0; i < argc; ++i) {
              pargs.add(_jsToDart(
                ctx,
                Pointer.fromAddress(
                  (pdata + 2).value.address + sizeOfJSValue * i,
                ),
              ));
            }
            final JSInvokable func = _jsToDart(
              ctx,
              (pdata + 3).value,
            );
            return _dartToJs(
                ctx,
                func.invoke(
                  pargs,
                  _jsToDart(ctx, (pdata + 0).value),
                ));
          case JSChannelType.MODULE:
            if (moduleHandler == null) throw JSError('No ModuleHandler');
            final ret = moduleHandler!(
              ptr.cast<Utf8>().toDartString(),
            ).toNativeUtf8();
            Future.microtask(() {
              malloc.free(ret);
            });
            return ret.cast();
          case JSChannelType.PROMISE_TRACK:
            final err = _parseJSException(ctx, ptr);
            if (hostPromiseRejectionHandler != null) {
              hostPromiseRejectionHandler!(err);
            } else {
              print('unhandled promise rejection: $err');
            }
            return nullptr;
          case JSChannelType.FREE_OBJECT:
            final rt = ctx.cast<JSRuntime>();
            _DartObject.fromAddress(rt, ptr.address)?.free();
            return nullptr;
        }
        throw JSError('call channel with wrong type');
      } catch (e) {
        if (type == JSChannelType.FREE_OBJECT) {
          print('DartObject release error: $e');
          return nullptr;
        }
        if (type == JSChannelType.MODULE) {
          print('host Promise Rejection Handler error: $e');
          return nullptr;
        }
        final throwObj = _dartToJs(ctx, e);
        final err = jsThrow(ctx, throwObj);
        jsFreeValue(ctx, throwObj);
        if (type == JSChannelType.MODULE) {
          jsFreeValue(ctx, err);
          return nullptr;
        }
        return err;
      }
    }, timeout ?? 0, port);
    final stackSize = this.stackSize;
    if (stackSize > 0) jsSetMaxStackSize(rt, stackSize);
    final memoryLimit = this.memoryLimit ?? 0;
    if (memoryLimit > 0) jsSetMemoryLimit(rt, memoryLimit);
    final gcThreshold = this.gcThreshold ?? 0;
    if (gcThreshold > 0) jsSetGCThreshold(rt, gcThreshold);
    _rt = rt;
    _ctx = jsNewContext(rt);
  }

  /// Free Runtime and Context which can recreate when evaluate again.
  close() {
    final rt = _rt;
    final ctx = _ctx;
    if (rt == null) return;
    _drainPendingJobs();
    // Mark closed before touching anything native, so a poller that wakes up
    // during teardown stops instead of evaluating into a dying engine.
    _rt = null;
    _ctx = null;
    // JS refs are released *first*: each destroy() frees a JSValue through the
    // still-live context. Doing it after jsFreeContext freed the context first
    // and turned teardown into a use-after-free.
    jsReleaseRuntimeRefs(rt);
    if (ctx != null) jsFreeContext(ctx);
    try {
      jsFreeRuntime(rt);
    } on String catch (e) {
      throw JSError(e);
    }
  }

  /// True once [close] released the engine. Anything still holding a timer or
  /// a callback into this runtime (promise polling, a late JS call) must stop
  /// instead of evaluating against freed native memory.
  bool get isClosed => _rt == null || _disposed;

  int _executeOnePendingJob() {
    final rt = _rt;
    final ctx = _ctx;
    if (rt == null || ctx == null) return 0;
    final result = jsExecutePendingJob(rt);
    if (result < 0) {
      print(_parseJSException(ctx));
    }
    return result;
  }

  void _drainPendingJobs() {
    while (_executeOnePendingJob() > 0) {
      // Keep running queued Promise jobs until QuickJS reports none left.
    }
  }

  /// Dispatch JavaScript Event loop.
  Future<void> dispatch() async {
    _drainPendingJobs();
  }

  @override
  void setInspectable(bool inspectable) {
    // Nothing to do.
  }

  /// Evaluate js script.
  JsEvalResult evaluate(
    String command, {
    String? name,
    int? evalFlags,
    String? sourceUrl,
  }) {
    _ensureEngine();
    final ctx = _ctx!;
    final jsval = jsEval(
      ctx,
      command,
      name ?? '<eval>',
      evalFlags ?? JSEvalFlag.GLOBAL,
    );

    if (jsIsException(jsval) != 0) {
      jsFreeValue(ctx, jsval);
      JSError exception = _parseJSException(ctx);
      return JsEvalResult(exception.toString(), exception, isError: true);
    }
    final result = _jsToDart(ctx, jsval);
    jsFreeValue(ctx, jsval);
    return JsEvalResult(result?.toString() ?? "null", result);
  }

  JsEvalResult evaluateBytecode(Uint8List bytecode) {
    _ensureEngine();
    final ctx = _ctx!;
    final Pointer<Uint8> pointer = calloc<Uint8>(bytecode.length);
    pointer.asTypedList(bytecode.length).setAll(0, bytecode);

    final value = evaluateBytecodeFn(ctx, bytecode.length, pointer);

    calloc.free(pointer);

    if (jsIsException(value) != 0) {
      jsFreeValue(ctx, value);
      JSError exception = _parseJSException(ctx);
      return JsEvalResult(exception.toString(), exception, isError: true);
    }

    final result = _jsToDart(ctx, value);
    jsFreeValue(ctx, value);
    return JsEvalResult(result?.toString() ?? "null", result);
  }

  Uint8List compile(String script, String fileName) {
    // `close()`/`dispose()` null the context. Without this guard a late
    // compile hit the `_ctx!` null check instead of a clear JSError.
    _ensureEngine();
    final ctx = _ctx!;
    final scriptPtr = script.toNativeUtf8().cast<Char>();
    final fileNamePtr = fileName.toNativeUtf8().cast<Char>();
    final lengthPtr = calloc<IntPtr>();
    final value = compileFn(ctx, scriptPtr, fileNamePtr, lengthPtr);
    final length = lengthPtr.value;

    calloc.free(scriptPtr);
    calloc.free(fileNamePtr);
    calloc.free(lengthPtr);

    // CompileScript returns NULL when the script does not compile. Building a
    // typed list from a null pointer is a native crash, so surface it as an
    // empty result and let the caller fall back to source evaluation.
    if (value.address == 0 || length <= 0) {
      if (value.address != 0) jsFreeBuffer(ctx, value);
      return Uint8List(0);
    }

    final data = Uint8List.fromList(value.asTypedList(length));
    // JS_WriteObject allocates through js_malloc; the C allocator's free()
    // would corrupt the heap.
    jsFreeBuffer(ctx, value);
    return data;
  }

  @override
  Future<JsEvalResult> evaluateAsyncBytecode(Uint8List bytecode) {
    return Future.value(evaluateBytecode(bytecode));
  }

  @override
  JsEvalResult callFunction(Pointer<NativeType> fn, Pointer<NativeType> obj) {
    throw UnimplementedError();
  }

  @override
  T? convertValue<T>(JsEvalResult jsValue) {
    return true as T;
  }

  @override
  void dispose() {
    _disposed = true;
    try {
      port.close(); // stop dispatch loop
      close(); // close engine
    } on JSError catch (e) {
      print(e); // catch reference leak exception
    }
  }

  @override
  Future<JsEvalResult> evaluateAsync(String code, {String? sourceUrl}) {
    return Future.value(evaluate(code, sourceUrl: sourceUrl));
  }

  @override
  int executePendingJob() {
    return _executeOnePendingJob();
  }

  @override
  String getEngineInstanceId() {
    return this.hashCode.toString();
  }

  @override
  void initChannelFunctions() {
    JavascriptRuntime.channelFunctionsRegistered[getEngineInstanceId()] = {};
    final setToGlobalObject =
        evaluate("(key, val) => { this[key] = val; }").rawResult;
    (setToGlobalObject as JSInvokable).invoke([
      'sendMessage',
      (String channelName, String message) {
        final channelFunctions = JavascriptRuntime
            .channelFunctionsRegistered[getEngineInstanceId()]!;

        if (channelFunctions.containsKey(channelName)) {
          return channelFunctions[channelName]!.call(jsonDecode(message));
        } else {
          print('No channel $channelName registered');
        }
        if (JavascriptRuntime.debugEnabled) {
          print('CHANNEL: $channelName - Message: $message');
        }
      }
    ]);
  }

  @override
  String jsonStringify(JsEvalResult jsValue) {
    throw UnimplementedError();
  }

  @override
  bool setupBridge(String channelName, void Function(dynamic args) fn) {
    final channelFunctionCallbacks =
        JavascriptRuntime.channelFunctionsRegistered[getEngineInstanceId()]!;

    if (channelFunctionCallbacks.keys.contains(channelName)) return false;

    channelFunctionCallbacks[channelName] = fn;

    return true;
  }
}
