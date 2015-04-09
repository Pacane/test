// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library test.runner.browser.server;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pool/pool.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';

import '../../backend/suite.dart';
import '../../backend/test_platform.dart';
import '../../util/io.dart';
import '../../util/one_off_handler.dart';
import '../../utils.dart';
import '../load_exception.dart';
import 'browser.dart';
import 'browser_manager.dart';
import 'compiler_pool.dart';
import 'chrome.dart';
import 'firefox.dart';

/// A server that serves JS-compiled tests to browsers.
///
/// A test suite may be loaded for a given file using [loadSuite].
class BrowserServer {
  /// Starts the server.
  ///
  /// If [packageRoot] is passed, it's used for all package imports when
  /// compiling tests to JS. Otherwise, the package root is inferred from the
  /// location of the source file.
  ///
  /// If [pubServeUrl] is passed, tests will be loaded from the `pub serve`
  /// instance at that URL rather than from the filesystem.
  ///
  /// If [color] is true, console colors will be used when compiling Dart.
  static Future<BrowserServer> start({String packageRoot, Uri pubServeUrl,
      bool color: false}) {
    var server = new BrowserServer._(packageRoot, pubServeUrl, color);
    return server._load().then((_) => server);
  }

  /// The underlying HTTP server.
  HttpServer _server;

  /// The URL for this server.
  Uri get url => baseUrlForAddress(_server.address, _server.port);

  /// a [OneOffHandler] for servicing WebSocket connections for
  /// [BrowserManager]s.
  ///
  /// This is one-off because each [BrowserManager] can only connect to a single
  /// WebSocket,
  final _webSocketHandler = new OneOffHandler();

  /// The [CompilerPool] managing active instances of `dart2js`.
  ///
  /// This is `null` if tests are loaded from `pub serve`.
  final CompilerPool _compilers;

  /// The temporary directory in which compiled JS is emitted.
  final String _compiledDir;

  /// The package root which is passed to `dart2js`.
  final String _packageRoot;

  /// The URL for the `pub serve` instance to use to load tests.
  ///
  /// This is `null` if tests should be compiled manually.
  final Uri _pubServeUrl;

  /// The pool of active `pub serve` compilations.
  ///
  /// Pub itself ensures that only one compilation runs at a time; we just use
  /// this pool to make sure that the output is nice and linear.
  final _pubServePool = new Pool(1);

  /// The HTTP client to use when caching JS files in `pub serve`.
  final HttpClient _http;

  /// Whether [close] has been called.
  bool get _closed => _closeCompleter != null;

  /// The completer for the [Future] returned by [close].
  Completer _closeCompleter;

  /// All currently-running browsers.
  ///
  /// These are controlled by [_browserManager]s.
  final _browsers = new Map<TestPlatform, Browser>();

  /// A map from browser identifiers to futures that will complete to the
  /// [BrowserManager]s for those browsers.
  ///
  /// This should only be accessed through [_browserManagerFor].
  final _browserManagers = new Map<TestPlatform, Future<BrowserManager>>();

  BrowserServer._(this._packageRoot, Uri pubServeUrl, bool color)
      : _pubServeUrl = pubServeUrl,
        _compiledDir = pubServeUrl == null ? createTempDir() : null,
        _http = pubServeUrl == null ? null : new HttpClient(),
        _compilers = new CompilerPool(color: color);

  /// Starts the underlying server.
  Future _load() {
    var cascade = new shelf.Cascade()
        .add(_webSocketHandler.handler);

    if (_pubServeUrl == null) {
      var staticPath = p.join(libDir(packageRoot: _packageRoot),
          'src/runner/browser/static');
      cascade = cascade
          .add(createStaticHandler(staticPath, defaultDocument: 'index.html'))
          .add(createStaticHandler(_compiledDir,
              defaultDocument: 'index.html'));
    }

    return shelf_io.serve(cascade.handler, 'localhost', 0).then((server) {
      _server = server;
    });
  }

  /// Loads the test suite at [path] on the browser [browser].
  ///
  /// This will start a browser to load the suite if one isn't already running.
  /// Throws an [ArgumentError] if [browser] isn't a browser platform.
  Future<Suite> loadSuite(String path, TestPlatform browser) {
    if (!browser.isBrowser) {
      throw new ArgumentError("$browser is not a browser.");
    }

    return new Future.sync(() {
      if (_pubServeUrl != null) {
        var suitePrefix = p.withoutExtension(p.relative(path, from: 'test')) +
            '.browser_test';
        var jsUrl = _pubServeUrl.resolve('$suitePrefix.dart.js');
        return _pubServeSuite(path, jsUrl)
            .then((_) => _pubServeUrl.resolve('$suitePrefix.html'));
      } else {
        return _compileSuite(path).then((dir) {
          if (_closed) return null;

          // Add a trailing slash because at least on Chrome, the iframe's
          // window.location.href will do so automatically, and if that differs
          // from the original URL communication will fail.
          return url.resolve(
              "/" + p.toUri(p.relative(dir, from: _compiledDir)).path + "/");
        });
      }
    }).then((suiteUrl) {
      if (_closed) return null;

      // TODO(nweiz): Don't start the browser until all the suites are compiled.
      return _browserManagerFor(browser).then((browserManager) {
        if (_closed) return null;
        return browserManager.loadSuite(path, suiteUrl);
      });
    });
  }

  /// Loads a test suite at [path] from the `pub serve` URL [jsUrl].
  ///
  /// This ensures that only one suite is loaded at a time, and that any errors
  /// are exposed as [LoadException]s.
  Future _pubServeSuite(String path, Uri jsUrl) {
    return _pubServePool.withResource(() {
      var timer = new Timer(new Duration(seconds: 1), () {
        print('"pub serve" is compiling $path...');
      });

      return _http.headUrl(jsUrl)
          .then((request) => request.close())
          .whenComplete(timer.cancel)
          .catchError((error, stackTrace) {
        if (error is! IOException) throw error;

        var message = getErrorMessage(error);
        if (error is SocketException) {
          message = "${error.osError.message} "
              "(errno ${error.osError.errorCode})";
        }

        throw new LoadException(path,
            "Error getting $jsUrl: $message\n"
            'Make sure "pub serve" is running.');
      }).then((response) {
        if (response.statusCode == 200) return;

        throw new LoadException(path,
            "Error getting $jsUrl: ${response.statusCode} "
                "${response.reasonPhrase}\n"
            'Make sure "pub serve" is serving the test/ directory.');
      });
    });
  }

  /// Compile the test suite at [dartPath] to JavaScript.
  ///
  /// Returns a [Future] that completes to the path to the JavaScript.
  Future<String> _compileSuite(String dartPath) {
    var dir = new Directory(_compiledDir).createTempSync('test_').path;
    var jsPath = p.join(dir, p.basename(dartPath) + ".js");
    return _compilers.compile(dartPath, jsPath,
            packageRoot: packageRootFor(dartPath, _packageRoot))
        .then((_) {
      if (_closed) return null;

      // TODO(nweiz): support user-authored HTML files.
      new File(p.join(dir, "index.html")).writeAsStringSync('''
<!DOCTYPE html>
<html>
<head>
  <title>${HTML_ESCAPE.convert(dartPath)} Test</title>
  <script src="${HTML_ESCAPE.convert(p.basename(jsPath))}"></script>
</head>
</html>
''');
      return dir;
    });
  }

  /// Returns the [BrowserManager] for [platform], which should be a browser.
  ///
  /// If no browser manager is running yet, starts one.
  Future<BrowserManager> _browserManagerFor(TestPlatform platform) {
    var manager = _browserManagers[platform];
    if (manager != null) return manager;

    var completer = new Completer();
    _browserManagers[platform] = completer.future;
    var path = _webSocketHandler.create(webSocketHandler((webSocket) {
      completer.complete(new BrowserManager(webSocket));
    }));

    var webSocketUrl = url.replace(scheme: 'ws', path: '/$path');

    var hostUrl = url;
    if (_pubServeUrl != null) {
      hostUrl = _pubServeUrl.resolve(
          '/packages/test/src/runner/browser/static/');
    }

    var browser = _newBrowser(hostUrl.replace(queryParameters: {
      'managerUrl': webSocketUrl.toString()
    }), platform);
    _browsers[platform] = browser;

    // TODO(nweiz): Gracefully handle the browser being killed before the
    // tests complete.
    browser.onExit.catchError((error, stackTrace) {
      if (completer.isCompleted) return;
      completer.completeError(error, stackTrace);
    });

    return completer.future;
  }

  /// Starts the browser identified by [browser] and has it load [url].
  Browser _newBrowser(Uri url, TestPlatform browser) {
    switch (browser) {
      case TestPlatform.dartium: return new Dartium(url);
      case TestPlatform.chrome: return new Chrome(url);
      case TestPlatform.firefox: return new Firefox(url);
      default:
        throw new ArgumentError("$browser is not a browser.");
    }
  }

  /// Closes the server and releases all its resources.
  ///
  /// Returns a [Future] that completes once the server is closed and its
  /// resources have been fully released.
  Future close() {
    if (_closeCompleter != null) return _closeCompleter.future;
    _closeCompleter = new Completer();

    return Future.wait([
      _server.close(),
      _compilers.close()
    ]).then((_) {
      if (_browserManagers.isEmpty) return null;
      return Future.wait(_browserManagers.keys.map((platform) {
        return _browserManagers[platform]
            .then((_) => _browsers[platform].close());
      }));
    }).then((_) {
      if (_pubServeUrl == null) {
        new Directory(_compiledDir).deleteSync(recursive: true);
      } else {
        _http.close();
      }

      _closeCompleter.complete();
    }).catchError(_closeCompleter.completeError);
  }
}
