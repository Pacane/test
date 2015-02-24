// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library unittest.browser_listener;

import 'dart:async';
import 'dart:html';

import 'declarer.dart';
import 'multi_channel.dart';
import 'remote_exception.dart';
import 'suite.dart';
import 'test.dart';
import 'utils.dart';

class BrowserListener {
  /// The test suite to run.
  final Suite _suite;

  static void start(Function getMain()) {
    print("in browser listener");
    var channel = _postMessageChannel();
    print("opened message channel");

    var main;
    try {
      main = getMain();
    } on NoSuchMethodError catch (_) {
      _sendLoadException(channel, "No top-level main() function defined.");
      return;
    }

    if (main is! Function) {
      _sendLoadException(channel, "Top-level main getter is not a function.");
      return;
    } else if (main is! AsyncFunction) {
      _sendLoadException(channel, "Top-level main() function takes arguments.");
      return;
    }

    var declarer = new Declarer();
    try {
      runZoned(main, zoneValues: {#unittest.declarer: declarer});
    } catch (error, stackTrace) {
      print("sending error: $error\n$stackTrace");
      channel.output.add({
        "type": "error",
        "error": RemoteException.serialize(error, stackTrace)
      });
      return;
    }
    print("done running declarer");

    new BrowserListener._(new Suite("BrowserListener", declarer.tests))
        ._listen(channel);
  }

  static MultiChannel _postMessageChannel() {
    var inputController = new StreamController(sync: true);
    var outputController = new StreamController(sync: true);

    var first = true;
    window.onMessage.listen((message) {
      print("[inner pm] incoming message: ${message.data}");
      if (message.origin != window.location.origin) return;
      message.stopPropagation();

      if (first) {
        outputController.stream.listen((data) {
          print("[inner pm] outgoing message: $data");
          message.source.postMessage(data, window.location.origin);
        });
        first = false;
      } else {
        inputController.add(message.data);
      }
    });

    return new MultiChannel(inputController.stream, outputController.sink);
  }

  static void _sendLoadException(MultiChannel channel, String message) {
    print("sending load exception: $message");
    channel.output.add({"type": "loadException", "message": message});
  }

  BrowserListener._(this._suite);

  void _listen(MultiChannel channel) {
    var tests = [];
    for (var i = 0; i < _suite.tests.length; i++) {
      var test = _suite.tests[i];
      var testChannel = channel.createSubChannel();
      tests.add({"name": test.name, "channel": testChannel.id});

      testChannel.input.listen((message) {
        assert(message['command'] == 'run');
        _runTest(test, channel.createSubChannel(message['channel']));
      });
    }

    print("sending ${{"type": "success", "tests": tests}}");
    channel.output.add({
      "type": "success",
      "tests": tests
    });
  }

  /// Runs [test] and send the results across [sendPort].
  void _runTest(Test test, MultiChannel channel) {
    var liveTest = test.load(_suite);

    liveTest.onStateChange.listen((state) {
      channel.output.add({
        "type": "state-change",
        "status": state.status.name,
        "result": state.result.name
      });
    });

    liveTest.onError.listen((asyncError) {
      channel.output.add({
        "type": "error",
        "error": RemoteException.serialize(
            asyncError.error, asyncError.stackTrace)
      });
    });

    liveTest.run().then((_) => channel.output.add({"type": "complete"}));
  }
}
