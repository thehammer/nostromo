// One snapshot of what is on screen, as a single line of JSON. Used by space-watch.sh.
// Reads only window metadata (owner app, layer, bounds); never window contents or titles.
ObjC.import('CoreGraphics');
ObjC.import('Foundation');
ObjC.import('AppKit');

function run() {
  var ref = $.CGWindowListCopyWindowInfo(
    $.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, 0);
  var list = ObjC.deepUnwrap(ObjC.castRefToObject(ref)) || [];
  var out = [];
  for (var i = 0; i < list.length; i++) {
    var w = list[i];
    if ((w.kCGWindowLayer || 0) !== 0) continue;           // normal app windows only
    var b = w.kCGWindowBounds || {};
    if ((b.Width || 0) < 200 || (b.Height || 0) < 150) continue;
    out.push([w.kCGWindowOwnerName, Math.round(b.X), Math.round(b.Y),
              Math.round(b.Width), Math.round(b.Height)].join(' '));
  }
  var screens = $.NSScreen.screens;
  var frames = [];
  for (var s = 0; s < screens.count; s++) {
    var f = screens.objectAtIndex(s).frame;
    frames.push([Math.round(f.origin.x), Math.round(f.origin.y),
                 Math.round(f.size.width), Math.round(f.size.height)].join(' '));
  }
  return JSON.stringify({ screens: frames, windows: out });
}
