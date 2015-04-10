// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library test.util.path_handler;

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;

class PathHandler {
  final _paths = new _Node();

  shelf.Handler get handler => _onRequest;

  PathHandler();

  void add(String path, shelf.Handler handler) {
    var node = _paths;
    for (var component in p.url.split(path)) {
      node = node.children.putIfAbsent(component, () => new _Node());
    }
    node.handler = handler;
  }

  shelf.Response _onRequest(shelf.Request request) {
    var handler = null;
    var node = _paths;
    var components = p.url.split(request.url.path);
    var i;
    for (i = 0; i < components.length; i++ ) {
      node = node.children[components[i]];
      if (node == null) break;
      if (node.handler != null) handler = node.handler;
    }

    if (handler == null) return new shelf.Response.notFound("Not found.");

    return handler(request.change(path: p.joinAll(components.take(i))));
  }
}

class _Node {
  shelf.Handler handler;
  final children = new Map<String, _Node>();
}
