// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library test.util.nesting_middleware;

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;

shelf.Middleware nestingMiddleware(String beneath) {
  var beneathSegments = p.url.split(beneath);

  return (handler) {
    return (request) {
      var segments = p.url.split(request.url.path);
      if (segments.length < beneathSegments.length) {
        return new shelf.Response.notFound("Not found.");
      }

      var i;
      for (i = 0; i < beneathSegments.length; i++) {
        if (segments[i] != beneathSegments[i]) {
          return new shelf.Response.notFound("Not found.");
        }
      }

      return handler(request.change(path: p.url.joinAll(segments.take(i))));
    };
  };
}
