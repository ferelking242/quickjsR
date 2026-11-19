import 'dart:async';
import 'package:flutter_qjs/javascript_runtime.dart';
import 'package:flutter_qjs/js_eval_result.dart';

const REGISTER_PROMISE_FUNCTION = 'FLUTTER_NATIVEJS_REGISTER_PROMISE';

extension HandlePromises on JavascriptRuntime {
  enableHandlePromises() {
    evaluate("""
     var FLUTTER_NATIVEJS_PENDING_PROMISES = {};
      var FLUTTER_NATIVEJS_PENDING_PROMISES_COUNT = -1;

      function $REGISTER_PROMISE_FUNCTION(promise) {
        FLUTTER_NATIVEJS_PENDING_PROMISES_COUNT += 1;
        idx = FLUTTER_NATIVEJS_PENDING_PROMISES_COUNT;
        FLUTTER_NATIVEJS_PENDING_PROMISES[idx] = FLUTTER_NATIVEJS_MakeQuerablePromise(promise);
        return idx;
      }
    """);
    final fnResult = evaluate("""
      function FLUTTER_NATIVEJS_CLEAN_PROMISE(idx) {
        delete FLUTTER_NATIVEJS_PENDING_PROMISES[idx];
      }

      function FLUTTER_NATIVEJS_IS_PENDING_PROMISE(idx) {
        return FLUTTER_NATIVEJS_PENDING_PROMISES[idx].isPending();
      }

      function FLUTTER_NATIVEJS_IS_FULLFILLED_PROMISE(idx) {
        return FLUTTER_NATIVEJS_PENDING_PROMISES[idx].isFulfilled();
      }

      function FLUTTER_NATIVEJS_IS_REJECTED_PROMISE(idx) {
        return FLUTTER_NATIVEJS_PENDING_PROMISES[idx].isRejected();
      }
      
      /**
       * This function allow you to modify a JS Promise by adding some status properties.
       * Based on: http://stackoverflow.com/questions/21485545/is-there-a-way-to-tell-if-an-es6-promise-is-fulfilled-rejected-resolved
       * But modified according to the specs of promises : https://promisesaplus.com/
       */
      function FLUTTER_NATIVEJS_MakeQuerablePromise(promise) {
          // Don't modify any promise that has been already modified.
          if (promise.isResolved) return promise;

          // Set initial state
          var isPending = true;
          var isRejected = false;
          var isFulfilled = false;
          var value = null;

          // Observe the promise, saving the fulfillment in a closure scope.
          var result = promise.then(
              function(v) {
                  isFulfilled = true;
                  isPending = false;
                  value = v;
                  return v; 
              }, 
              function(e) {
                  isRejected = true;
                  isPending = false;
                  value = e; 
              }
          );

          result.isFulfilled = function() { return isFulfilled; };
          result.isPending = function() { return isPending; };
          result.isRejected = function() { return isRejected; };
          result.getValue = function() { return value };
          return result;
      }
      FLUTTER_NATIVEJS_MakeQuerablePromise;
    """);

    localContext['makeQuerablePromise'] = fnResult.rawResult;
  }

  bool isPendingPromise(int idx) {
    String resultIsPending =
        evaluate("FLUTTER_NATIVEJS_IS_PENDING_PROMISE($idx)").stringResult;

    return "true" == resultIsPending;
  }

  bool isFulfilledPromise(int idx) {
    return "true" ==
        evaluate("FLUTTER_NATIVEJS_IS_FULLFILLED_PROMISE($idx)").stringResult;
  }

  Future<JsEvalResult> handlePromise(JsEvalResult value,
      {Duration? timeout}) async {
    final completer = Completer<JsEvalResult>();

    if (timeout != null) {
      // `Future.timeout` only abandons the outer future: the inner completer
      // stays pending and its poll timer keeps evaluating JS on a runtime the
      // caller has already walked away from. Complete it so the poll stops.
      return _doHandlePromise(value, completer).timeout(
        timeout,
        onTimeout: () {
          if (!completer.isCompleted) {
            completer.completeError(
              JsEvalResult('Promise timed out', null, isError: true),
            );
          }
          throw TimeoutException('Promise timed out', timeout);
        },
      );
    } else {
      return _doHandlePromise(value, completer);
    }
  }

  Future<JsEvalResult> _doHandlePromise(
      JsEvalResult value, Completer completer) async {
    if (value.stringResult.contains('Instance of \'Future')) {
      var completed = false;
      Function? fnEvaluatePromise;
      fnEvaluatePromise = () async {
        // The runtime may be gone (source disposed, worker replaced) while a
        // JS promise is still pending: evaluating into a freed context is a
        // native use-after-free, not a Dart exception.
        if (isClosed || completed) return;
        this.executePendingJob();
        if (!completed) {
          await Future.delayed(
              Duration(milliseconds: 20), () => fnEvaluatePromise!.call());
        } else {
          if (JavascriptRuntime.debugEnabled) {
            print('Promise completed');
          }
        }
      };
      Future.delayed(
          Duration(milliseconds: 20), () => fnEvaluatePromise!.call());

      // Future.delayed(Duration(seconds: 1), () {
      //   this.executePendingJob();
      // });
      return await (value.rawResult as Future<dynamic>).then((dynamic res) {
        final resEval = JsEvalResult("$res", value.rawResult);
        completer.complete(resEval);
        completed = true;
        return resEval;
      });
    }
    if (value.stringResult != '[object Promise]') return Future.value(value);

    final fnRegisterPromiseFunction = evaluate(REGISTER_PROMISE_FUNCTION);
    final evalRegisterPromise = fnRegisterPromiseFunction.rawResult;
    // print(fnRegisterPromiseFunction);
    // todo: investigate - application is crashing around this point
    final promiseQuerableIdx =
        callFunction(evalRegisterPromise, value.rawResult).stringResult;
    int idxPromise = int.parse(promiseQuerableIdx);
    Timer? pollTimer;
    void stopPolling() {
      pollTimer?.cancel();
      pollTimer = null;
    }

    pollTimer = Timer.periodic(Duration(milliseconds: 20), (timer) {
      // Same use-after-free as above: this timer outlives the runtime it polls
      // when the source is disposed mid-request, and `evaluate` would then run
      // JS against freed native memory (SIGSEGV inside js_channel/jsEval).
      if (isClosed) {
        stopPolling();
        if (!completer.isCompleted) {
          completer.completeError(
            JsEvalResult('Runtime closed', null, isError: true),
          );
        }
        return;
      }
      // A timeout, a rejection or a second caller completing the completer must
      // stop the poll. Leaving it running re-entered `evaluate` on the same
      // runtime from a timer while the caller had already moved on, which nests
      // js_channel → Dart → evaluate until the stack is exhausted.
      if (completer.isCompleted) {
        stopPolling();
        return;
      }
      // call to _JS_ExecutePendingJob
      this.executePendingJob();
      //eval(REGISTER_PROMISE_FUNCTION);
      // REFERENCE: https://github.com/p7s1digital/oasis-jsbridge-android/blob/3b104ec46d4817a0688e2e50e18eb3e5b2976485/jsbridge/src/main/jni/JsBridgeContext_quickjs.cpp#L343
      //  * https://github.com/p7s1digital/oasis-jsbridge-android/blob/82e2cb0211cefc4ae74675a4fa59ea3e4f2845f0/jsbridge/src/main/jni/java-types/Deferred_quickjs.cpp
      //  * https://medium.com/@calbertts/how-to-create-asynchronous-apis-for-quickjs-8aca5488bb2e
      //  * https://docs.rs/crate/quick-js/0.2.3/source/src/bindings.rs

      //  * Vue view generation using QuickJS - https://github.com/galvez/fast-vue-ssr/
      if (!isPendingPromise(idxPromise)) {
        stopPolling();
        final value = evaluate(
          "JSON.stringify(FLUTTER_NATIVEJS_PENDING_PROMISES[$idxPromise].getValue())",
        );

        final isFullfilled = isFulfilledPromise(idxPromise);

        evaluate("FLUTTER_NATIVEJS_CLEAN_PROMISE($idxPromise);");

        if (isFullfilled) {
          completer.complete(value);
        } else {
          completer.completeError(value);
        }
      }
    });
    return completer.future as Future<JsEvalResult>;
  }
}
