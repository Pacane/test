// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library unittest.io;

import 'dart:async';
import 'dart:io';
import 'dart:mirrors';

import 'package:path/path.dart' as p;

/// The root directory of the `unittest` package.
final String libDir = _computeLibDir();
String _computeLibDir() =>
    p.dirname(p.dirname(p.dirname(_libraryPath(#unittest.io))));

/// Returns whether the current Dart version supports [Isolate.kill].
final bool supportsIsolateKill = _supportsIsolateKill;
bool get _supportsIsolateKill {
  // This isn't 100% accurate, since early 1.9 dev releases didn't support
  // Isolate.kill(), but it's very unlikely anyone will be using them.
  // TODO(nweiz): remove this when we no longer support older Dart versions.
  var path = p.join(p.dirname(p.dirname(Platform.executable)), 'version');
  return new File(path).readAsStringSync().startsWith('1.9');
}

// TODO(nweiz): Make this check [stdioType] once that works within "pub run".
/// Whether "special" strings such as Unicode characters or color escapes are
/// safe to use.
///
/// On Windows or when not printing to a terminal, only printable ASCII
/// characters should be used.
bool get canUseSpecialChars =>
    Platform.operatingSystem != 'windows' &&
    Platform.environment["_UNITTEST_USE_COLOR"] != "false";

/// Gets a "special" string (ANSI escape or Unicode).
///
/// On Windows or when not printing to a terminal, returns something else since
/// those aren't supported.
String getSpecial(String special, [String onWindows = '']) =>
    canUseSpecialChars ? special : onWindows;

/// Creates a temporary directory and passes its path to [fn].
///
/// Once the [Future] returned by [fn] completes, the temporary directory and
/// all its contents are deleted. [fn] can also return `null`, in which case
/// the temporary directory is deleted immediately afterwards.
///
/// Returns a future that completes to the value that the future returned from
/// [fn] completes to.
Future withTempDir(Future fn(String path)) {
  return new Future.sync(() {
    // TODO(nweiz): Empirically test whether sync or async functions perform
    // better here when starting a bunch of isolates.
    var tempDir = Directory.systemTemp.createTempSync('unittest_');
    return new Future.sync(() => fn(tempDir.path))
        .whenComplete(() => tempDir.deleteSync(recursive: true));
  });
}

/// Creates a URL string for [address]:[port].
///
/// Handles properly formatting IPv6 addresses.
Uri baseUrlForAddress(InternetAddress address, int port) {
  if (address.isLoopback) {
    return new Uri(scheme: "http", host: "localhost", port: port);
  }

  // IPv6 addresses in URLs need to be enclosed in square brackets to avoid
  // URL ambiguity with the ":" in the address.
  if (address.type == InternetAddressType.IP_V6) {
    return new Uri(scheme: "http", host: "[${address.address}]", port: port);
  }

  return new Uri(scheme: "http", host: address.address, port: port);
}

String packageRootFor(String path, [String override]) {
  var packageRoot = override == null
      ? p.join(p.dirname(path), 'packages')
      : override;

  if (!new Directory(packageRoot).existsSync()) {
    throw new LoadException(path, "Directory $packageRoot does not exist.");
  }

  return packageRoot;
}

/// The library name must be globally unique, or the wrong library path may be
/// returned.
String _libraryPath(Symbol libraryName) {
  var lib = currentMirrorSystem().findLibrary(libraryName);
  if (lib.uri.scheme != 'package') return p.fromUri(lib.uri);

  // TODO: don't assume this is being run next to a packages directory.
  return p.join('packages', p.fromUri(lib.uri.path));
}
