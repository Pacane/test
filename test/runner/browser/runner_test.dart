// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn("vm")

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/src/util/exit_codes.dart' as exit_codes;
import 'package:test/src/util/io.dart';
import 'package:test/test.dart';

import '../../io.dart';

String _sandbox;

final _success = """
import 'dart:async';

import 'package:test/test.dart';

void main() {
  test("success", () {});
}
""";

void main() {
  setUp(() {
    _sandbox = createTempDir();
  });

  tearDown(() {
    new Directory(_sandbox).deleteSync(recursive: true);
  });

  group("fails gracefully if", () {
    test("a test file fails to compile", () {
      var testPath = p.join(_sandbox, "test.dart");
      new File(testPath).writeAsStringSync("invalid Dart file");
      var result = _runUnittest(["-p", "chrome", "test.dart"]);

      expect(result.stdout,
          contains("Expected a declaration, but got 'invalid'"));
      expect(result.stderr, equals(
          'Failed to load "${p.relative(testPath, from: _sandbox)}": dart2js '
            'failed.\n'));
      expect(result.exitCode, equals(exit_codes.data));
    });

    test("a test file throws", () {
      var testPath = p.join(_sandbox, "test.dart");
      new File(testPath).writeAsStringSync("void main() => throw 'oh no';");

      var result = _runUnittest(["-p", "chrome", "test.dart"]);
      expect(result.stderr, startsWith(
          'Failed to load "${p.relative(testPath, from: _sandbox)}": oh no\n'));
      expect(result.exitCode, equals(exit_codes.data));
    });

    test("a test file doesn't have a main defined", () {
      var testPath = p.join(_sandbox, "test.dart");
      new File(testPath).writeAsStringSync("void foo() {}");

      var result = _runUnittest(["-p", "chrome", "test.dart"]);
      expect(result.stderr, startsWith(
          'Failed to load "${p.relative(testPath, from: _sandbox)}": No '
              'top-level main() function defined.\n'));
      expect(result.exitCode, equals(exit_codes.data));
    });

    test("a test file has a non-function main", () {
      var testPath = p.join(_sandbox, "test.dart");
      new File(testPath).writeAsStringSync("int main;");

      var result = _runUnittest(["-p", "chrome", "test.dart"]);
      expect(result.stderr, startsWith(
          'Failed to load "${p.relative(testPath, from: _sandbox)}": Top-level '
              'main getter is not a function.\n'));
      expect(result.exitCode, equals(exit_codes.data));
    });

    test("a test file has a main with arguments", () {
      var testPath = p.join(_sandbox, "test.dart");
      new File(testPath).writeAsStringSync("void main(arg) {}");

      var result = _runUnittest(["-p", "chrome", "test.dart"]);
      expect(result.stderr, startsWith(
          'Failed to load "${p.relative(testPath, from: _sandbox)}": Top-level '
              'main() function takes arguments.\n'));
      expect(result.exitCode, equals(exit_codes.data));
    });

    // TODO(nweiz): test what happens when a test file is unreadable once issue
    // 15078 is fixed.
  });

  group("runs successful tests", () {
    test("on Chrome", () {
      new File(p.join(_sandbox, "test.dart")).writeAsStringSync(_success);
      var result = _runUnittest(["-p", "chrome", "test.dart"]);
      expect(result.exitCode, equals(0));
    });

    test("on Firefox", () {
      new File(p.join(_sandbox, "test.dart")).writeAsStringSync(_success);
      var result = _runUnittest(["-p", "firefox", "test.dart"]);
      expect(result.exitCode, equals(0));
    });

    test("on the browser and the VM", () {
      new File(p.join(_sandbox, "test.dart")).writeAsStringSync(_success);
      var result = _runUnittest(["-p", "chrome", "-p", "vm", "test.dart"]);
      expect(result.exitCode, equals(0));
    });
  });

  group("runs failing tests", () {
    test("on Chrome", () {
      new File(p.join(_sandbox, "test.dart")).writeAsStringSync("""
import 'dart:async';

import 'package:test/test.dart';

void main() {
  test("failure", () => throw new TestFailure("oh no"));
}
""");
      var result = _runUnittest(["-p", "chrome", "test.dart"]);
      expect(result.exitCode, equals(1));
    });

    test("on Firefox", () {
      new File(p.join(_sandbox, "test.dart")).writeAsStringSync("""
import 'dart:async';

import 'package:test/test.dart';

void main() {
  test("failure", () => throw new TestFailure("oh no"));
}
""");
      var result = _runUnittest(["-p", "firefox", "test.dart"]);
      expect(result.exitCode, equals(1));
    });

    test("that fail only on the browser", () {
      new File(p.join(_sandbox, "test.dart")).writeAsStringSync("""
import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test("test", () {
    if (p.style == p.Style.url) throw new TestFailure("oh no");
  });
}
""");
      var result = _runUnittest(["-p", "chrome", "-p", "vm", "test.dart"]);
      expect(result.exitCode, equals(1));
    });

    test("that fail only on the VM", () {
      new File(p.join(_sandbox, "test.dart")).writeAsStringSync("""
import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test("test", () {
    if (p.style != p.Style.url) throw new TestFailure("oh no");
  });
}
""");
      var result = _runUnittest(["-p", "chrome", "-p", "vm", "test.dart"]);
      expect(result.exitCode, equals(1));
    });
  });

  test("forwards prints from the browser test", () {
    new File(p.join(_sandbox, "test.dart")).writeAsStringSync("""
import 'dart:async';

import 'package:test/test.dart';

void main() {
  test("test", () {
    print("Hello,");
    return new Future(() => print("world!"));
  });
}
""");

    var result = _runUnittest(["-p", "chrome", "test.dart"]);
    expect(result.stdout, contains("Hello,\nworld!\n"));
    expect(result.exitCode, equals(0));
  });
}

ProcessResult _runUnittest(List<String> args) =>
    runUnittest(args, workingDirectory: _sandbox);
