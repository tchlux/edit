// ___________________________________________________________________
//                         macos/edit_app.m
//
// DESCRIPTION
//  A tiny AppKit wrapper that gives edit its own macOS app identity while
//  keeping the C terminal editor as the engine. Each window owns a pty running
//  the bundled edit binary and renders the small ANSI subset edit emits.
// ___________________________________________________________________

#import <Cocoa/Cocoa.h>

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

#define TERM_ROWS 30
#define TERM_COLS 100
#define SCROLL_MAX_KEYS 48
#define CSI_MAX 64

enum { AnsiNormal, AnsiEsc, AnsiCsi, AnsiOsc, AnsiOscEsc };

typedef struct {
  unichar ch;
  int fg[3];
  int bg[3];
  bool bold;
  bool italic;
  bool strike;
  bool underline;
  int underline_rgb[3];
  bool reverse;
} cell;

typedef struct {
  int fg[3];
  int bg[3];
  bool bold;
  bool italic;
  bool strike;
  bool underline;
  int underline_rgb[3];
  bool reverse;
} attr;

@interface EditTerminalView : NSView
@property int fd;
@property pid_t pid;
@property int rows;
@property int cols;
@property int row;
@property int col;
@property bool wrapPending;
@property bool cursorVisible;
@property attr current;
@property cell *cells;
@property NSMutableData *utf8;
@property NSMutableData *pendingWrite;
@property NSMutableString *csi;
@property NSFileHandle *handle;
@property dispatch_source_t writeSource;
@property int ansiState;
@property CGFloat scrollX;
@property CGFloat scrollY;
@property BOOL readPending;
@property NSUInteger readGeneration;
@property NSTimeInterval ignoreScrollUntil;
@property BOOL dirtyAll;
@property BOOL hasDirty;
@property BOOL *dirtyRows;
@property NSString *sessionID;
@property NSFont *font;
@property NSFont *boldFont;
@property NSSize cachedCellSize;
@property NSMutableDictionary<NSNumber *, NSColor *> *colorCache;
@property NSMutableDictionary<NSNumber *, NSDictionary *> *attrCache;
@property NSMenu *spellingMenu;
@property unsigned spellingRequest;
@property NSInteger spellingItems;
- (instancetype)initWithPath:(NSString *)path;
- (instancetype)initWithPath:(NSString *)path sessionID:(NSString *)sessionID;
- (void)stopEditor;
- (instancetype)initForAnsiSelfTest;
- (NSString *)lineText:(int)width;
- (NSUInteger)csiLength;
- (void)readBytes:(NSData *)data;
- (BOOL)sendMouseClickRow:(int)row col:(int)col;
- (int)sendScrollDeltaX:(CGFloat)dx y:(CGFloat)dy precise:(BOOL)precise;
- (void)panicCancel;
- (void)sendBytes:(const char *)bytes length:(NSUInteger)length;
- (void)flushWrites;
- (void)sendKey:(const char *)bytes;
- (void)sendCommand:(id)sender;
- (void)pasteString:(NSString *)s;
- (void)cut:(id)sender;
- (void)saveDocument:(id)sender;
- (void)quitDocument:(id)sender;
@end

static void attr_default(attr *a) {
  a->fg[0] = 224; a->fg[1] = 224; a->fg[2] = 224;
  a->bg[0] = 32; a->bg[1] = 32; a->bg[2] = 32;
  a->bold = false;
  a->italic = false;
  a->strike = false;
  a->underline = false;
  a->underline_rgb[0] = 235; a->underline_rgb[1] = 85; a->underline_rgb[2] = 85;
  a->reverse = false;
}

static cell blank_cell(attr a) {
  cell c;
  c.ch = ' ';
  memcpy(c.fg, a.fg, sizeof(c.fg));
  memcpy(c.bg, a.bg, sizeof(c.bg));
  c.bold = a.bold;
  c.italic = a.italic;
  c.strike = a.strike;
  c.underline = a.underline;
  memcpy(c.underline_rgb, a.underline_rgb, sizeof(c.underline_rgb));
  c.reverse = a.reverse;
  return c;
}

static bool cell_equal(cell a, cell b) {
  return a.ch == b.ch && memcmp(a.fg, b.fg, sizeof(a.fg)) == 0 &&
    memcmp(a.bg, b.bg, sizeof(a.bg)) == 0 && a.bold == b.bold &&
    a.italic == b.italic && a.strike == b.strike && a.reverse == b.reverse &&
    a.underline == b.underline && !memcmp(a.underline_rgb, b.underline_rgb, sizeof(a.underline_rgb));
}

static int rgb_key(const int *rgb) {
  return (rgb[0] << 16) | (rgb[1] << 8) | rgb[2];
}

static bool rgb_equal(const int *a, const int *b) {
  return a[0] == b[0] && a[1] == b[1] && a[2] == b[2];
}

static const int *cell_fg(cell *c) { return c->reverse ? c->bg : c->fg; }
static const int *cell_bg(cell *c) { return c->reverse ? c->fg : c->bg; }

static bool cell_same_bg(cell *a, cell *b) {
  return rgb_equal(cell_bg(a), cell_bg(b));
}

static bool cell_same_text(cell *a, cell *b) {
  return rgb_equal(cell_fg(a), cell_fg(b)) && a->bold == b->bold &&
    a->italic == b->italic && a->strike == b->strike && a->underline == b->underline &&
    rgb_equal(a->underline_rgb, b->underline_rgb);
}

@implementation EditTerminalView

- (void)setFontSize:(CGFloat)size {
  self.font = [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
  self.boldFont = [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightBold];
  self.cachedCellSize = [@"M" sizeWithAttributes:@{ NSFontAttributeName: _font }];
  self.colorCache = [NSMutableDictionary dictionary];
  self.attrCache = [NSMutableDictionary dictionary];
}


- (instancetype)initWithPath:(NSString *)path {
  return [self initWithPath:path sessionID:nil];
}

- (instancetype)initWithPath:(NSString *)path sessionID:(NSString *)sessionID {
  self = [super initWithFrame:NSMakeRect(0, 0, 900, 520)];
  if (!self) return nil;
  self.sessionID = sessionID;
  self.rows = TERM_ROWS;
  self.cols = TERM_COLS;
  self.cursorVisible = true;
  self.utf8 = [NSMutableData data];
  self.pendingWrite = [NSMutableData data];
  self.csi = [NSMutableString string];
  self.ansiState = AnsiNormal;
  [self setFontSize:14];
  attr_default(&_current);
  _cells = calloc((size_t)_rows * (size_t)_cols, sizeof(cell));
  _dirtyRows = calloc((size_t)_rows, sizeof(BOOL));
  [self clearScreen];
  [self resizeGrid];
  [self startEdit:path];
  return self;
}

- (instancetype)initForAnsiSelfTest {
  self = [super initWithFrame:NSMakeRect(0, 0, 900, 520)];
  if (!self) return nil;
  self.rows = TERM_ROWS;
  self.cols = TERM_COLS;
  self.cursorVisible = true;
  self.utf8 = [NSMutableData data];
  self.pendingWrite = [NSMutableData data];
  self.csi = [NSMutableString string];
  self.ansiState = AnsiNormal;
  [self setFontSize:14];
  attr_default(&_current);
  _cells = calloc((size_t)_rows * (size_t)_cols, sizeof(cell));
  _dirtyRows = calloc((size_t)_rows, sizeof(BOOL));
  [self clearScreen];
  return self;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isOpaque { return YES; }

- (NSSize)cellSize {
  return _cachedCellSize;
}

- (void)viewDidMoveToWindow {
  [self.window makeFirstResponder:self];
}

// Drain the pty while the child finishes its snapshot, including large final frames.
- (void)stopEditor {
  if (_pid <= 0) return;
  self.handle.readabilityHandler = nil;
  kill(_pid, SIGHUP);
  char discard[8192];
  while (waitpid(_pid, NULL, WNOHANG) == 0) {
    while (read(_fd, discard, sizeof(discard)) > 0) {}
    usleep(1000);
  }
  _pid = 0;
}

- (void)dealloc {
  if (_writeSource) dispatch_source_cancel(_writeSource);
  if (_fd > 0) close(_fd);
  if (_pid > 0) kill(_pid, SIGHUP);
  free(_cells);
  free(_dirtyRows);
}

- (void)clearScreen {
  for (int i = 0; i < _rows * _cols; i++) _cells[i] = blank_cell(_current);
  _row = 0;
  _col = 0;
  _wrapPending = false;
  _dirtyAll = YES;
}

- (NSRect)rowRect:(int)row {
  NSSize size = [self cellSize];
  return NSMakeRect((self.bounds.size.width - _cols * size.width) / 2,
                    self.bounds.size.height - (row + 1) * size.height,
                    _cols * size.width, size.height);
}

- (void)markCellDirtyRow:(int)row col:(int)col {
  if (_dirtyAll || row < 0 || row >= _rows || col < 0 || col >= _cols) return;
  _dirtyRows[row] = YES;
  _hasDirty = YES;
}

- (void)markCursorDirty {
  if (_cursorVisible) [self markCellDirtyRow:_row col:_col];
}

- (void)flushDirty {
  if (_dirtyAll) [self setNeedsDisplay:YES];
  else if (_hasDirty) {
    for (int r = 0; r < _rows; r++)
      if (_dirtyRows[r]) [self setNeedsDisplayInRect:NSInsetRect([self rowRect:r], -1, -1)];
  }
  _dirtyAll = NO;
  _hasDirty = NO;
  if (_dirtyRows) memset(_dirtyRows, 0, (size_t)_rows * sizeof(BOOL));
}

- (void)resizeGrid {
  NSSize size = [self cellSize];
  // Leave half a cell at each side and at least half a row below the grid.
  int cols = MAX(20, (int)(self.bounds.size.width / size.width) - 1);
  int rows = MAX(8, (int)(self.bounds.size.height / size.height - 0.5));
  if (cols == _cols && rows == _rows) return;
  // Keep the previous frame visible while the editor redraws at the new size.
  cell *cells = calloc((size_t)rows * (size_t)cols, sizeof(cell));
  for (int r = 0; r < rows; r++)
    for (int c = 0; c < cols; c++)
      cells[r * cols + c] = r < _rows && c < _cols ?
        _cells[r * _cols + c] : blank_cell(_current);
  free(_cells);
  _cells = cells;
  _cols = cols;
  _rows = rows;
  _row = MIN(_row, rows - 1);
  _col = MIN(_col, cols - 1);
  _wrapPending = false;
  free(_dirtyRows);
  _dirtyRows = calloc((size_t)_rows, sizeof(BOOL));
  _dirtyAll = YES;
  [self flushDirty];
  struct winsize ws = { .ws_row = (unsigned short)_rows, .ws_col = (unsigned short)_cols };
  if (_fd > 0) ioctl(_fd, TIOCSWINSZ, &ws);
  if (_pid > 0) kill(_pid, SIGWINCH);
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self resizeGrid];
  [self setNeedsDisplay:YES];
}

- (void)viewDidEndLiveResize {
  [super viewDidEndLiveResize];
  [self resizeGrid];
  if (_pid > 0) kill(_pid, SIGWINCH);
  [self setNeedsDisplay:YES];
}

- (void)startEdit:(NSString *)path {
  NSString *edit = [NSBundle.mainBundle pathForResource:@"edit" ofType:nil];
  if (!edit) edit = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:@"edit"];

  NSString *snapshot = nil;
  if (_sessionID && !getenv("EDIT_SESSION")) {
    NSString *home = [(NSProcessInfo.processInfo.environment[@"HOME"] ?: NSHomeDirectory()) stringByAppendingPathComponent:@".edit"];
    [[NSFileManager defaultManager] createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:nil];
    snapshot = [home stringByAppendingPathComponent:[@"session-" stringByAppendingString:_sessionID]];
  }

  struct winsize ws = { .ws_row = (unsigned short)_rows, .ws_col = (unsigned short)_cols };
  int master = -1;
  pid_t child = forkpty(&master, NULL, NULL, &ws);
  if (child == 0) {
    if (snapshot) setenv("EDIT_SESSION", snapshot.fileSystemRepresentation, 1);
    setenv("TERM", "xterm-256color", 1);
    setenv("EDIT_BATCH_ARROWS", "1", 1);
    setenv("EDIT_APP", "1", 1);
    if (path) execl(edit.fileSystemRepresentation, "edit", path.fileSystemRepresentation, NULL);
    else execl(edit.fileSystemRepresentation, "edit", NULL);
    _exit(127);
  }
  if (child < 0) return;

  _fd = master;
  _pid = child;
  fcntl(_fd, F_SETFL, fcntl(_fd, F_GETFL, 0) | O_NONBLOCK);
  NSFileHandle *handle = [[NSFileHandle alloc] initWithFileDescriptor:_fd closeOnDealloc:NO];
  self.handle = handle;
  [self installReadHandler];
}

- (void)installReadHandler {
  __weak EditTerminalView *weakSelf = self;
  NSUInteger generation = _readGeneration;
  self.handle.readabilityHandler = ^(NSFileHandle *h) {
    h.readabilityHandler = nil;
    EditTerminalView *pendingView = weakSelf;
    if (pendingView) pendingView.readPending = true;
    NSData *data = [h availableData];
    if (data.length == 0) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf.window close];
      });
      return;
    }
    // Deliver output during AppKit's resize tracking loop as well as normal input.
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
      EditTerminalView *view = weakSelf;
      if (!view) return;
      if (view.readGeneration != generation) {
        view.readPending = false;
        [view installReadHandler];
        return;
      }
      view.readPending = true;
      [view readBytes:data];
      view.readPending = false;
      [view installReadHandler];
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
  };
}

- (void)sendBytes:(const char *)bytes length:(NSUInteger)length {
  if (_fd <= 0 || length == 0) return;
  [_pendingWrite appendBytes:bytes length:length];
  [self flushWrites];
}

- (void)flushWrites {
  while (_fd > 0 && _pendingWrite.length > 0) {
    ssize_t n = write(_fd, _pendingWrite.bytes, _pendingWrite.length);
    if (n > 0) {
      [_pendingWrite replaceBytesInRange:NSMakeRange(0, (NSUInteger)n) withBytes:NULL length:0];
      continue;
    }
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && !_writeSource) {
      __weak EditTerminalView *weakSelf = self;
      _writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)_fd, 0,
                                             dispatch_get_main_queue());
      dispatch_source_set_event_handler(_writeSource, ^{ [weakSelf flushWrites]; });
      dispatch_resume(_writeSource);
    }
    return;
  }
  if (_writeSource) {
    dispatch_source_cancel(_writeSource);
    _writeSource = nil;
  }
}

- (void)drainPtyOutput {
  if (_fd <= 0) return;
  char buf[8192];
  while (read(_fd, buf, sizeof(buf)) > 0) {}
}

- (void)panicCancel {
  _scrollX = 0;
  _scrollY = 0;
  _ignoreScrollUntil = [NSDate timeIntervalSinceReferenceDate] + 0.4;
  _readGeneration++;
  _readPending = false;
  if (_handle) _handle.readabilityHandler = nil;
  [_pendingWrite setLength:0];
  if (_writeSource) {
    dispatch_source_cancel(_writeSource);
    _writeSource = nil;
  }
  if (_fd > 0) {
    tcflush(_fd, TCIOFLUSH);
    [self drainPtyOutput];
    char c = 0x07;
    write(_fd, &c, 1);
  }
  [self installReadHandler];
}

- (void)sendKey:(const char *)bytes {
  [self sendBytes:bytes length:strlen(bytes)];
}

- (void)sendCommand:(id)sender {
  NSData *data = [sender representedObject];
  if (data.length == 1 && ((const unsigned char *)data.bytes)[0] == 0x07)
    return [self panicCancel];
  [self sendBytes:data.bytes length:data.length];
}

- (void)putChar:(unichar)ch {
  if (_wrapPending) {
    _col = 0;
    if (_row + 1 < _rows) _row++;
    _wrapPending = false;
  }
  if (_row < 0 || _row >= _rows || _col < 0 || _col >= _cols) return;
  cell c = blank_cell(_current);
  c.ch = ch;
  int at = _row * _cols + _col;
  if (!cell_equal(_cells[at], c)) {
    _cells[at] = c;
    [self markCellDirtyRow:_row col:_col];
  }
  if (_col + 1 < _cols) _col++;
  else _wrapPending = true;
}

- (void)clearLine {
  if (_row < 0 || _row >= _rows) return;
  for (int c = MAX(0, _col); c < _cols; c++) {
    int at = _row * _cols + c;
    cell blank = blank_cell(_current);
    if (!cell_equal(_cells[at], blank)) {
      _cells[at] = blank;
      [self markCellDirtyRow:_row col:c];
    }
  }
}

- (NSArray<NSString *> *)csiParts:(NSString *)seq final:(char *)final {
  *final = [seq characterAtIndex:seq.length - 1];
  NSString *body = [seq substringToIndex:seq.length - 1];
  if ([body hasPrefix:@"?"]) body = [body substringFromIndex:1];
  return [body componentsSeparatedByString:@";"];
}

- (int)csiInt:(NSArray<NSString *> *)parts at:(NSUInteger)i fallback:(int)fallback {
  if (i >= parts.count || [parts[i] length] == 0) return fallback;
  return parts[i].intValue;
}

- (void)applySgr:(NSArray<NSString *> *)parts {
  if (parts.count == 0) {
    attr_default(&_current);
    return;
  }
  for (NSUInteger i = 0; i < parts.count; i++) {
    int p = [self csiInt:parts at:i fallback:0];
    if (p == 0) attr_default(&_current);
    else if (p == 1) _current.bold = true;
    else if (p == 3) _current.italic = true;
    else if (p == 4) _current.underline = true;
    else if (p == 24) _current.underline = false;
    else if (p == 59) {
      _current.underline_rgb[0] = 235; _current.underline_rgb[1] = 85; _current.underline_rgb[2] = 85;
    }
    else if (p == 9) _current.strike = true;
    else if (p == 29) _current.strike = false;
    else if (p == 7) _current.reverse = true;
    else if (p == 27) _current.reverse = false;
    else if ((p == 38 || p == 48 || p == 58) && i + 4 < parts.count && [self csiInt:parts at:i + 1 fallback:0] == 2) {
      int *rgb = p == 38 ? _current.fg : p == 48 ? _current.bg : _current.underline_rgb;
      rgb[0] = [self csiInt:parts at:i + 2 fallback:rgb[0]];
      rgb[1] = [self csiInt:parts at:i + 3 fallback:rgb[1]];
      rgb[2] = [self csiInt:parts at:i + 4 fallback:rgb[2]];
      i += 4;
    }
  }
}

- (void)handleCsi:(NSString *)seq {
  char final = 0;
  NSArray<NSString *> *parts = [self csiParts:seq final:&final];
  // Private font command from the editor; resizing notifies the child via SIGWINCH.
  if (final == 't' && [self csiInt:parts at:0 fallback:0] == 777) {
    int action = [self csiInt:parts at:1 fallback:0];
    CGFloat size = action == 0 ? 14 : _font.pointSize + (action == 1 ? 1 : -1);
    [self setFontSize:MAX(6, MIN(72, size))];
    [self resizeGrid];
    [self setNeedsDisplay:YES];
    return;
  }
  if (final == 'H' || final == 'f') {
    [self markCursorDirty];
    _row = MAX(0, MIN(_rows - 1, [self csiInt:parts at:0 fallback:1] - 1));
    _col = MAX(0, MIN(_cols - 1, [self csiInt:parts at:1 fallback:1] - 1));
    _wrapPending = false;
    [self markCursorDirty];
  } else if (final == 'K') {
    [self clearLine];
  } else if (final == 'J') {
    [self clearScreen];
  } else if (final == 'm') {
    [self applySgr:parts];
  } else if (final == 'l' || final == 'h') {
    if ([seq containsString:@"?25l"]) {
      [self markCursorDirty];
      _cursorVisible = false;
    }
    if ([seq containsString:@"?25h"]) {
      _cursorVisible = true;
      [self markCursorDirty];
    }
  }
}

- (void)readBytes:(NSData *)data {
  const unsigned char *bytes = data.bytes;

  for (NSUInteger i = 0; i < data.length; i++) {
    unsigned char b = bytes[i];
    if (_ansiState == AnsiOsc || _ansiState == AnsiOscEsc) {
      if (b == 7 || (_ansiState == AnsiOscEsc && b == '\\')) {
        [self spellingResponse:_csi];
        [_csi setString:@""];
        _ansiState = AnsiNormal;
      } else if (b == 27) _ansiState = AnsiOscEsc;
      else {
        if (_csi.length <= 8192) [_csi appendFormat:@"%c", b];
        _ansiState = AnsiOsc;
      }
      continue;
    }
    if (_ansiState == AnsiEsc) {
      if (b == '[') {
        _ansiState = AnsiCsi;
        [_csi setString:@""];
      } else if (b == ']') {
        _ansiState = AnsiOsc;
        [_csi setString:@""];
      } else _ansiState = AnsiNormal;
      continue;
    }
    if (_ansiState == AnsiCsi) {
      [_csi appendFormat:@"%c", b];
      if (_csi.length > CSI_MAX) {
        [_csi setString:@""];
        _ansiState = AnsiNormal;
        continue;
      }
      if (b >= 0x40 && b <= 0x7e) {
        [self handleCsi:_csi];
        [_csi setString:@""];
        _ansiState = AnsiNormal;
      }
      continue;
    }
    if (b == 0x1b) {
      _ansiState = AnsiEsc;
    } else if (b == '\r') {
      _col = 0;
      _wrapPending = false;
    } else if (b == '\n') {
      if (_row + 1 < _rows) _row++;
      _wrapPending = false;
    } else if (b == '\b') {
      if (_col > 0) _col--;
      _wrapPending = false;
    } else if (b >= 32) {
      if (b < 128) [self putChar:b];
      else {
        [_utf8 appendBytes:&b length:1];
        NSString *s = [[NSString alloc] initWithData:_utf8 encoding:NSUTF8StringEncoding];
        if (s.length > 0) {
          [self putChar:[s characterAtIndex:0]];
          [_utf8 setLength:0];
        } else if (_utf8.length >= 4) [_utf8 setLength:0];
      }
    }
  }
  // The editor hides its cursor at frame start and shows it after the full redraw.
  if (_cursorVisible) [self flushDirty];
}

- (NSUInteger)csiLength { return _csi.length; }

- (NSString *)lineText:(int)width {
  NSMutableString *s = [NSMutableString string];
  for (int c = 0; c < width && c < _cols; c++)
    [s appendFormat:@"%C", _cells[c].ch];
  return s;
}

- (NSColor *)color:(const int *)rgb {
  NSNumber *key = @(rgb_key(rgb));
  NSColor *color = _colorCache[key];
  if (!color) {
    color = [NSColor colorWithCalibratedRed:rgb[0] / 255.0 green:rgb[1] / 255.0 blue:rgb[2] / 255.0 alpha:1.0];
    _colorCache[key] = color;
  }
  return color;
}

- (NSDictionary *)attrsForCell:(cell *)x {
  NSUInteger key = ((NSUInteger)rgb_key(cell_fg(x)) << 28) |
    ((NSUInteger)rgb_key(x->underline_rgb) << 4) | (x->italic ? 1 : 0) |
    (x->bold ? 2 : 0) | (x->strike ? 4 : 0) | (x->underline ? 8 : 0);
  NSNumber *boxed = @(key);
  NSDictionary *attrs = _attrCache[boxed];
  if (!attrs) {
    attrs = @{
      NSFontAttributeName: x->bold ? _boldFont : _font,
      NSForegroundColorAttributeName: [self color:cell_fg(x)],
      NSObliquenessAttributeName: x->italic ? @0.18 : @0,
      NSStrikethroughStyleAttributeName: x->strike ? @1 : @0,
      NSUnderlineStyleAttributeName: x->underline ? @1 : @0,
      NSUnderlineColorAttributeName: [self color:x->underline_rgb]
    };
    _attrCache[boxed] = attrs;
  }
  return attrs;
}

- (void)drawRect:(NSRect)dirtyRect {
  NSSize size = [self cellSize];
  [[NSColor colorWithCalibratedRed:32 / 255.0 green:32 / 255.0 blue:32 / 255.0 alpha:1] setFill];
  NSRectFill(dirtyRect);

  unichar *chars = malloc((size_t)_cols * sizeof(unichar));
  for (int r = 0; r < _rows; r++) {
    NSRect rowRect = [self rowRect:r];
    if (!NSIntersectsRect(dirtyRect, rowRect)) continue;

    for (int c = 0; c < _cols;) {
      int start = c;
      cell *first = &_cells[r * _cols + c++];
      while (c < _cols && cell_same_bg(first, &_cells[r * _cols + c])) c++;
      [[self color:cell_bg(first)] setFill];
      NSRectFill(NSMakeRect(rowRect.origin.x + start * size.width, rowRect.origin.y,
                            (c - start) * size.width, size.height));
    }

    for (int c = 0; c < _cols;) {
      int start = c;
      bool hasText = false;
      cell *first = &_cells[r * _cols + c];
      while (c < _cols && cell_same_text(first, &_cells[r * _cols + c])) {
        chars[c - start] = _cells[r * _cols + c].ch;
        if (_cells[r * _cols + c].ch != ' ') hasText = true;
        c++;
      }
      if (!hasText) continue;
      NSString *s = [[NSString alloc] initWithCharacters:chars length:c - start];
      [s drawAtPoint:NSMakePoint(rowRect.origin.x + start * size.width, rowRect.origin.y)
      withAttributes:[self attrsForCell:first]];
    }
  }
  free(chars);
  if (_cursorVisible && _row >= 0 && _row < _rows && _col >= 0 && _col < _cols) {
    [[NSColor colorWithCalibratedWhite:0.85 alpha:1] setFill];
    NSRect cursor = [self rowRect:_row];
    cursor.origin.x += _col * size.width;
    cursor.size.width = size.width;
    NSRectFillUsingOperation(cursor, NSCompositingOperationDifference);
  }
}

- (void)keyDown:(NSEvent *)event {
  NSString *plain = event.charactersIgnoringModifiers ?: @"";
  NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  if (flags & NSEventModifierFlagCommand) {
    if ([plain isEqualToString:@"x"]) return [self cut:nil];
    if ([plain isEqualToString:@"c"]) return [self copy:nil];
    if ([plain isEqualToString:@"v"]) return [self paste:nil];
    if ([plain isEqualToString:@"s"]) return [self saveDocument:nil];
    if ([plain isEqualToString:@"q"]) return [self quitDocument:nil];
    return;
  }
  if (flags & NSEventModifierFlagControl) {
    if (plain.length == 0) return;
    char c = (char)[plain characterAtIndex:0];
    char ctrl = c == '/' ? 0x1f : c == ' ' ? 0 : (c & 0x1f);
    if (ctrl == 0x07) return [self panicCancel];
    _ignoreScrollUntil = 0;
    return [self sendBytes:&ctrl length:1];
  }
  _ignoreScrollUntil = 0;
  if (event.keyCode == 53) return [self sendKey:"\x1b"];
  if (event.keyCode == 123) return [self sendKey:"\x1b[D"];
  if (event.keyCode == 124) return [self sendKey:"\x1b[C"];
  if (event.keyCode == 125) return [self sendKey:"\x1b[B"];
  if (event.keyCode == 126) return [self sendKey:"\x1b[A"];
  if ((flags & NSEventModifierFlagOption) && plain.length > 0) {
    [self sendKey:"\x1b"];
    NSData *data = [plain dataUsingEncoding:NSUTF8StringEncoding];
    return [self sendBytes:data.bytes length:data.length];
  }
  NSData *data = [event.characters dataUsingEncoding:NSUTF8StringEncoding];
  [self sendBytes:data.bytes length:data.length];
}

- (BOOL)sendMouseClickRow:(int)row col:(int)col {
  if (row < 0 || row >= _rows || col < 0 || col >= _cols) return NO;
  char seq[32];
  int n = snprintf(seq, sizeof(seq), "\033[<0;%d;%dM", col + 1, row + 1);
  if (n <= 0 || n >= (int)sizeof(seq)) return NO;
  [self sendBytes:seq length:(NSUInteger)n];
  return YES;
}

- (void)mouseDown:(NSEvent *)event {
  [self.window makeFirstResponder:self];
  NSSize cell = [self cellSize];
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  int col = (int)floor((p.x - [self rowRect:0].origin.x) / cell.width);
  int row = (int)((self.bounds.size.height - p.y) / cell.height);
  [self sendMouseClickRow:row col:col];
}

- (NSMenuItem *)contextItem:(NSString *)title bytes:(const char *)bytes length:(NSUInteger)length {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(sendCommand:) keyEquivalent:@""];
  item.target = self;
  item.representedObject = [NSData dataWithBytes:bytes length:length];
  return item;
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
  NSSize cell = [self cellSize];
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  int row = (int)((self.bounds.size.height - p.y) / cell.height);
  int col = (int)floor((p.x - [self rowRect:0].origin.x) / cell.width);
  if (row < 0 || row >= _rows || col < 0 || col >= _cols) return nil;
  _spellingRequest = _spellingRequest >= INT_MAX ? 1 : _spellingRequest + 1;
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Edit"];
  menu.autoenablesItems = NO;
  NSMenuItem *checking = [[NSMenuItem alloc] initWithTitle:@"Checking spelling…" action:NULL keyEquivalent:@""];
  checking.enabled = NO;
  [menu addItem:checking];
  [menu addItem:[NSMenuItem separatorItem]];
  _spellingMenu = menu;
  _spellingItems = 1;
  [menu addItem:[self contextItem:@"Create Comment" bytes:"\003c" length:2]];
  [menu addItem:[self contextItem:@"Delete Comment" bytes:"\003d" length:2]];
  [menu addItem:[self contextItem:@"Show/Hide Comments" bytes:"\003]" length:2]];
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItem:[self contextItem:@"Accept All Changes" bytes:"\003a" length:2]];
  [menu addItem:[self contextItem:@"Reject All Changes" bytes:"\003r" length:2]];
  char request[64];
  int n = snprintf(request, sizeof(request), "\033[778;%u;%d;%d~", _spellingRequest, row + 1, col + 1);
  [self sendBytes:request length:(NSUInteger)n];
  return menu;
}

// Update the open native menu from the editor's Aspell results, including split reads.
- (void)spellingResponse:(NSString *)message {
  if (message.length > 8192) return;
  NSArray<NSString *> *parts = [message componentsSeparatedByString:@";"];
  if (parts.count < 4 || parts.count > 13 || ![parts[0] isEqualToString:@"777"] ||
      ![parts[1] isEqualToString:@"spell"] || parts[2].longLongValue != _spellingRequest || !_spellingMenu) return;
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  for (NSUInteger i = 4; i < parts.count; i++) {
    NSString *hex = parts[i];
    if (!hex.length || hex.length > 512 || hex.length % 2) return;
    NSMutableData *data = [NSMutableData data];
    for (NSUInteger j = 0; j < hex.length; j += 2) {
      NSScanner *scan = [NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(j, 2)]];
      unsigned byte;
      if (![scan scanHexInt:&byte] || !scan.isAtEnd || byte == 0) return;
      unsigned char c = (unsigned char)byte;
      [data appendBytes:&c length:1];
    }
    NSString *label = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!label) return;
    [labels addObject:label];
  }
  for (NSInteger i = 0; i < _spellingItems; i++) [_spellingMenu removeItemAtIndex:0];
  _spellingItems = (NSInteger)labels.count;
  for (NSUInteger i = 0; i < labels.count; i++) {
    char command[48];
    int n = snprintf(command, sizeof(command), "\033[779;%u;%u~", _spellingRequest, (unsigned)i + 1);
    [_spellingMenu insertItem:[self contextItem:labels[i] bytes:command length:(NSUInteger)n] atIndex:(NSInteger)i];
  }
  if (!labels.count) {
    NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:@"No spelling suggestions" action:NULL keyEquivalent:@""];
    empty.enabled = NO;
    [_spellingMenu insertItem:empty atIndex:0];
    _spellingItems = 1;
  }
  char add[48];
  int n = snprintf(add, sizeof(add), "\033[779;%u;0~", _spellingRequest);
  NSMenuItem *accept = [self contextItem:@"Add word" bytes:add length:(NSUInteger)n];
  accept.enabled = parts[3].length > 0;
  [_spellingMenu insertItem:accept atIndex:_spellingItems++];
  [_spellingMenu update];
}

- (int)sendScrollDeltaX:(CGFloat)dx y:(CGFloat)dy precise:(BOOL)precise {
  NSSize cell = [self cellSize];
  CGFloat ax = fabs(dx), ay = fabs(dy);
  int sent = 0;
  if ([NSDate timeIntervalSinceReferenceDate] < _ignoreScrollUntil) return 0;
  if (ax == 0 && ay == 0) return 0;

  if (ay >= ax) {
    _scrollY += dy;
    CGFloat step = precise ? cell.height : 1;
    while (fabs(_scrollY) >= step && sent < SCROLL_MAX_KEYS) {
      [self sendKey:_scrollY < 0 ? "\x1b[B" : "\x1b[A"];
      _scrollY += (_scrollY < 0) ? step : -step;
      sent++;
    }
  } else {
    _scrollX += dx;
    CGFloat step = precise ? cell.width : 1;
    while (fabs(_scrollX) >= step && sent < SCROLL_MAX_KEYS) {
      [self sendKey:_scrollX < 0 ? "\x1b[C" : "\x1b[D"];
      _scrollX += (_scrollX < 0) ? step : -step;
      sent++;
    }
  }
  return sent;
}

- (void)scrollWheel:(NSEvent *)event {
  if ([NSDate timeIntervalSinceReferenceDate] < _ignoreScrollUntil) return;
  [self sendScrollDeltaX:event.scrollingDeltaX y:event.scrollingDeltaY precise:event.hasPreciseScrollingDeltas];
}

- (void)paste:(id)sender {
  NSString *s = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
  if (!s) return;
  [self pasteString:s];
}

- (void)pasteString:(NSString *)s {
  NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
  NSMutableData *paste = [NSMutableData dataWithBytes:"\x1b[200~" length:6];
  [paste appendData:data];
  [paste appendBytes:"\x1b[201~" length:6];
  [self sendBytes:paste.bytes length:paste.length];
}

- (void)copy:(id)sender {
  [self sendKey:"\x1bw"];
}

- (void)cut:(id)sender { [self sendKey:"\027"]; }
- (void)saveDocument:(id)sender { [self sendKey:"\030\023"]; }
- (void)quitDocument:(id)sender { [self sendKey:"\030\003"]; }

@end

@interface EditAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property BOOL openedFiles;
@property BOOL terminating;
@property NSMutableArray<NSWindow *> *windows;
@end

@implementation EditAppDelegate

- (void)openPath:(NSString *)path {
  [self openPath:path session:nil];
}

- (NSWindow *)openPath:(NSString *)path session:(NSDictionary *)session {
  NSString *sessionID = session[@"id"] ?: NSUUID.UUID.UUIDString;
  EditTerminalView *view = [[EditTerminalView alloc] initWithPath:path sessionID:sessionID];
  if (session[@"font"]) [view setFontSize:[session[@"font"] doubleValue]];
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 900, 520)
                                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
  window.releasedWhenClosed = NO;
  if (!_windows) _windows = [NSMutableArray array];
  [_windows addObject:window];
  window.delegate = self;
  if (session[@"frame"]) [window setFrame:NSRectFromString(session[@"frame"]) display:NO];
  window.title = path.lastPathComponent.length ? path.lastPathComponent : @"Edit";
  window.contentView = view;
  if (session[@"title"]) window.title = session[@"title"];
  [window makeKeyAndOrderFront:nil];
  if ([session[@"minimized"] boolValue]) [window miniaturize:nil];
  return window;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  [self buildMenus];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self.openedFiles && NSApp.windows.count == 0) {
      NSString *disabled = [(NSProcessInfo.processInfo.environment[@"HOME"] ?: NSHomeDirectory()) stringByAppendingPathComponent:@".edit/session-disabled"];
      NSArray *sessions = [[NSFileManager defaultManager] fileExistsAtPath:disabled] ? nil :
        [NSUserDefaults.standardUserDefaults arrayForKey:@"EditSessions"];
      for (NSDictionary *session in sessions) [self openPath:nil session:session];
      if (!sessions.count) [self openPath:nil];
    }
  });
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
  _openedFiles = YES;
  for (NSString *path in filenames) [self openPath:path];
  [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

// Remember all open windows on quit; closing the last window keeps it for relaunch.
- (NSArray *)sessionWindows:(NSWindow *)closing {
  NSMutableArray *windows = [_windows mutableCopy];
  NSWindow *key = NSApp.keyWindow;
  if ([windows containsObject:key]) { [windows removeObject:key]; [windows addObject:key]; }
  if (windows.count > 1 && closing) [windows removeObject:closing];
  NSMutableArray *sessions = [NSMutableArray array];
  // Reopen the key window last, including windows that were minimized.
  for (NSWindow *window in windows) {
    EditTerminalView *view = (EditTerminalView *)window.contentView;
    [sessions addObject:@{@"id": view.sessionID, @"frame": NSStringFromRect(window.frame),
                         @"font": @(view.font.pointSize), @"title": window.title,
                         @"minimized": @(window.isMiniaturized)}];
  }
  return sessions;
}

- (void)rememberWindows:(NSWindow *)closing {
  [NSUserDefaults.standardUserDefaults setObject:[self sessionWindows:closing] forKey:@"EditSessions"];
}

- (void)windowWillClose:(NSNotification *)notification {
  NSWindow *window = notification.object;
  if (!_terminating) [self rememberWindows:window];
  [(EditTerminalView *)window.contentView stopEditor];
  [_windows removeObject:window];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
  if (_windows.count) [self rememberWindows:nil];
  _terminating = YES;
  for (NSWindow *window in _windows) [(EditTerminalView *)window.contentView stopEditor];
  (void)sender;
  return NSTerminateNow;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
  return YES;
}

- (void)newDocument:(id)sender { [self openPath:nil]; }

- (void)openDocument:(id)sender {
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseFiles = YES;
  panel.canChooseDirectories = YES;
  panel.allowsMultipleSelection = YES;
  if ([panel runModal] != NSModalResponseOK) return;
  for (NSURL *url in panel.URLs) [self openPath:url.path];
}

- (void)buildMenus {
  NSMenu *bar = [[NSMenu alloc] init];
  NSApp.mainMenu = bar;

  NSMenuItem *commandsItem = [[NSMenuItem alloc] init];
  [bar addItem:commandsItem];
  NSMenu *commands = [[NSMenu alloc] initWithTitle:@"Commands"];
  commandsItem.submenu = commands;

  NSMenuItem *editItem = [[NSMenuItem alloc] init];
  [bar addItem:editItem];
  NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
  editItem.submenu = edit;
  [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
  [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
  [edit addItem:[NSMenuItem separatorItem]];

  [self addCommand:@"Backward Character    C-b / Left" bytes:"\002" length:1 to:commands];
  [self addCommand:@"Forward Character    C-f / Right" bytes:"\006" length:1 to:commands];
  [self addCommand:@"Previous Line    C-p / Up" bytes:"\020" length:1 to:commands];
  [self addCommand:@"Next Line    C-n / Down" bytes:"\016" length:1 to:commands];
  [self addCommand:@"Beginning of Line    C-a" bytes:"\001" length:1 to:commands];
  [self addCommand:@"End of Line    C-e" bytes:"\005" length:1 to:commands];
  [self addCommand:@"Backward Word    Esc b" bytes:"\033b" length:2 to:commands];
  [self addCommand:@"Forward Word    Esc f" bytes:"\033f" length:2 to:commands];
  [self addCommand:@"Page Down    C-v" bytes:"\026" length:1 to:commands];
  [self addCommand:@"Page Up    Esc v" bytes:"\033v" length:2 to:commands];
  [self addCommand:@"Down 10 Lines    Esc n" bytes:"\033n" length:2 to:commands];
  [self addCommand:@"Up 10 Lines    Esc p" bytes:"\033p" length:2 to:commands];
  [self addCommand:@"Beginning of File    Esc <" bytes:"\033<" length:2 to:commands];
  [self addCommand:@"End of File    Esc >" bytes:"\033>" length:2 to:commands];
  [self addCommand:@"Recenter    C-l" bytes:"\014" length:1 to:commands];
  [commands addItem:[NSMenuItem separatorItem]];

  [self addCommand:@"Insert Newline    Return" bytes:"\015" length:1 to:commands];
  [self addCommand:@"Insert Spaces / Tab    Tab" bytes:"\011" length:1 to:commands];
  [self addCommand:@"Quote Next Key    C-q" bytes:"\021" length:1 to:commands];
  [self addCommand:@"Open Line    C-o" bytes:"\017" length:1 to:commands];
  [self addCommand:@"Delete Character    C-d" bytes:"\004" length:1 to:commands];
  [self addCommand:@"Delete Backward    Delete" bytes:"\177" length:1 to:commands];
  [self addCommand:@"Delete Word Forward    Esc d" bytes:"\033d" length:2 to:commands];
  [self addCommand:@"Delete Word Backward    Esc Delete" bytes:"\033\177" length:2 to:commands];
  [self addCommand:@"Kill Line    C-k" bytes:"\013" length:1 to:commands];
  [self addCommand:@"Set Mark    C-Space" bytes:"\000" length:1 to:commands];
  [self addCommand:@"Cut Region    C-w" bytes:"\027" length:1 to:commands];
  [self addCommand:@"Copy Region    Esc w" bytes:"\033w" length:2 to:commands];
  [self addCommand:@"Paste    C-y" bytes:"\031" length:1 to:commands];
  [self addCommand:@"Cycle Paste    Esc y" bytes:"\033y" length:2 to:commands];
  [self addCommand:@"Fill Paragraph    Esc q" bytes:"\033q" length:2 to:commands];
  [self addCommand:@"Undo    C-_ / C-x u" bytes:"\037" length:1 to:commands];
  [self addCommand:@"Redo    C-x r" bytes:"\030r" length:2 to:commands];
  [commands addItem:[NSMenuItem separatorItem]];

  [self addCommand:@"Search Forward    C-s" bytes:"\023" length:1 to:commands];
  [self addCommand:@"Search Backward    C-r" bytes:"\022" length:1 to:commands];
  [self addCommand:@"Query Replace    Esc %" bytes:"\033%" length:2 to:commands];
  [self addCommand:@"Cancel    C-g" bytes:"\007" length:1 to:commands];
  [commands addItem:[NSMenuItem separatorItem]];

  [self addCommand:@"Find File    C-x C-f" bytes:"\030\006" length:2 to:commands];
  [self addCommand:@"Save File    C-x C-s" bytes:"\030\023" length:2 to:commands];
  [self addCommand:@"Next Buffer    C-x b" bytes:"\030b" length:2 to:commands];
  [self addCommand:@"List Buffers    C-x C-b" bytes:"\030\002" length:2 to:commands];
  [self addCommand:@"Kill Buffer    C-x k" bytes:"\030k" length:2 to:commands];
  [commands addItemWithTitle:@"Quit    C-x C-c" action:@selector(quitDocument:) keyEquivalent:@"q"];
  [commands addItem:[NSMenuItem separatorItem]];

  [self addCommand:@"Split Below    C-x 2" bytes:"\0302" length:2 to:commands];
  [self addCommand:@"Split Right    C-x 3" bytes:"\0303" length:2 to:commands];
  [self addCommand:@"Other Pane    C-x o" bytes:"\030o" length:2 to:commands];
  [self addCommand:@"Close Pane    C-x 0" bytes:"\0300" length:2 to:commands];
  [self addCommand:@"One Pane    C-x 1" bytes:"\0301" length:2 to:commands];
  [commands addItem:[NSMenuItem separatorItem]];

  [self addCommand:@"Run Command    C-c x" bytes:"\003x" length:2 to:commands];
  [self addCommand:@"Start Suggested Changes    C-c e" bytes:"\003e" length:2 to:commands];
  [self addCommand:@"Create Comment    C-c c" bytes:"\003c" length:2 to:commands];
  [self addCommand:@"Delete Nearest Comment    C-c d" bytes:"\003d" length:2 to:commands];
  [self addCommand:@"Show/Hide Comments    C-c ]" bytes:"\003]" length:2 to:commands];
  [self addCommand:@"Accept All Changes    C-c a" bytes:"\003a" length:2 to:commands];
  [self addCommand:@"Reject All Changes    C-c r" bytes:"\003r" length:2 to:commands];
  [self addCommand:@"Toggle Read-Only    C-c C-r" bytes:"\003\022" length:2 to:commands];
  [self addCommand:@"Cycle Visual Wrap    C-c C-w" bytes:"\003\027" length:2 to:commands];
  [self addCommand:@"Help    C-h" bytes:"\010" length:1 to:commands];
}

- (void)addCommand:(NSString *)title bytes:(const char *)bytes length:(NSUInteger)length to:(NSMenu *)menu {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(sendCommand:) keyEquivalent:@""];
  item.representedObject = [NSData dataWithBytes:bytes length:length];
  [menu addItem:item];
}

@end

static void ansi_feed(EditTerminalView *view, const char *s) {
  [view readBytes:[NSData dataWithBytes:s length:strlen(s)]];
}

static NSData *ansi_bench_frame(EditTerminalView *view, int phase) {
  NSMutableString *s = [NSMutableString stringWithString:@"\033[H"];
  for (int r = 0; r < view.rows; r++) {
    [s appendFormat:@"\033[%d;1H\033[38;2;%d;%d;%dm", r + 1,
     180 + ((r + phase) % 50), 190 + ((r * 3) % 40), 210 + ((phase * 7) % 30)];
    for (int c = 0; c < view.cols; c++)
      [s appendFormat:@"%c", 'a' + ((r + c + phase) % 26)];
  }
  return [s dataUsingEncoding:NSUTF8StringEncoding];
}

static int ansi_bench(void) {
  EditTerminalView *view = [[EditTerminalView alloc] initForAnsiSelfTest];
  NSData *frames[] = { ansi_bench_frame(view, 0), ansi_bench_frame(view, 1) };
  NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
    initWithBitmapDataPlanes:NULL pixelsWide:view.bounds.size.width
    pixelsHigh:view.bounds.size.height bitsPerSample:8 samplesPerPixel:4
    hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
    bytesPerRow:0 bitsPerPixel:0];
  NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
  int n = 300;
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  [NSGraphicsContext saveGraphicsState];
  [NSGraphicsContext setCurrentContext:ctx];
  for (int i = 0; i < n; i++) {
    [view readBytes:frames[i & 1]];
    [view drawRect:view.bounds];
  }
  [NSGraphicsContext restoreGraphicsState];
  CFAbsoluteTime secs = CFAbsoluteTimeGetCurrent() - start;
  printf("ansi-bench frames=%d seconds=%.3f fps=%.1f cells_per_second=%.0f\n",
         n, secs, n / secs, (double)n * view.rows * view.cols / secs);
  return 0;
}

static int ansi_self_test(void) {
  EditTerminalView *view = [[EditTerminalView alloc] initForAnsiSelfTest];
  ansi_feed(view, "\033[38;2;232");
  ansi_feed(view, ";232;232mfunc");
  ansi_feed(view, "\033");
  ansi_feed(view, "[0m");
  ansi_feed(view, "\033[");
  ansi_feed(view, "38;2;255;215;95marg");

  NSString *text = [view lineText:30];
  if (![[view lineText:7] isEqualToString:@"funcarg"] ||
      [text containsString:@"38;2"] ||
      [text containsString:@"["] ||
      [text containsString:@"m"]) {
    fprintf(stderr, "ansi self-test failed: %s\n", text.UTF8String);
    return 1;
  }

  // Resizing keeps the previous frame intact until replacement output arrives.
  [view resizeGrid];
  NSSize resized = NSMakeSize(view.bounds.size.width + 100, view.bounds.size.height + 100);
  [view setFrameSize:resized];
  if (![[view lineText:7] isEqualToString:@"funcarg"]) {
    fprintf(stderr, "resize preservation failed\n");
    return 1;
  }

  NSSize metrics = [view cellSize];
  NSRect firstRow = [view rowRect:0];
  CGFloat left = NSMinX(firstRow), right = view.bounds.size.width - NSMaxX(firstRow);
  CGFloat bottom = NSMinY([view rowRect:view.rows - 1]);
  if (fabs(left - right) > 0.001 || left < metrics.width / 2 || left >= metrics.width ||
      bottom < metrics.height / 2 || bottom >= metrics.height * 1.5) {
    fprintf(stderr, "grid padding failed: left=%.3f right=%.3f bottom=%.3f\n", left, right, bottom);
    return 1;
  }

  // A redraw split across reads is committed only after its final cursor command.
  [view flushDirty];
  ansi_feed(view, "\033[?25l\033[HZ");
  if (!view.hasDirty || view.cursorVisible) {
    fprintf(stderr, "partial frame was flushed\n");
    return 1;
  }
  ansi_feed(view, "\033[?25h");
  if (view.hasDirty || !view.cursorVisible) {
    fprintf(stderr, "complete frame was not flushed\n");
    return 1;
  }

  // Font commands refresh metrics, cached attributes, and terminal dimensions.
  EditTerminalView *fontView = [[EditTerminalView alloc] initForAnsiSelfTest];
  [fontView resizeGrid];
  int standardCols = fontView.cols;
  NSSize standardCell = fontView.cachedCellSize;
  ansi_feed(fontView, "\033[777;1t");
  if (fontView.font.pointSize != 15 || fontView.boldFont.pointSize != 15 ||
      fontView.cachedCellSize.width <= standardCell.width || fontView.cols >= standardCols) {
    fprintf(stderr, "font increase failed\n");
    return 1;
  }
  ansi_feed(fontView, "\033[777;2t");
  if (fontView.font.pointSize != 14 || fontView.cols != standardCols) return 1;
  ansi_feed(fontView, "\033[777;1t\033[777;0t");
  if (fontView.font.pointSize != 14 || fontView.cols != standardCols ||
      !NSEqualSizes(fontView.cachedCellSize, standardCell) || fontView.attrCache.count != 0) {
    fprintf(stderr, "font reset failed\n");
    return 1;
  }

  EditTerminalView *bgView = [[EditTerminalView alloc] initForAnsiSelfTest];
  ansi_feed(bgView, "\033[48;2;68;68;68mtwo");
  if (bgView.cells[0].bg[0] != 68 || bgView.cells[0].bg[1] != 68 ||
      bgView.cells[0].bg[2] != 68) {
    fprintf(stderr, "ansi background failed\n");
    return 1;
  }

  EditTerminalView *strikeView = [[EditTerminalView alloc] initForAnsiSelfTest];
  ansi_feed(strikeView, "\033[9mdeleted\033[29m kept");
  if (!strikeView.cells[0].strike || strikeView.cells[8].strike) {
    fprintf(stderr, "ansi strikethrough failed\n");
    return 1;
  }

  EditTerminalView *wrapView = [[EditTerminalView alloc] initForAnsiSelfTest];
  // Spelling decoration preserves foreground/background and participates in cache keys.
  EditTerminalView *spellView = [[EditTerminalView alloc] initForAnsiSelfTest];
  ansi_feed(spellView, "\033[38;2;170;255;170;48;2;68;68;68;4;58;2;235;85;85mwrong\033[24m right\033[0m reset");
  cell underlined = spellView.cells[0], plain = spellView.cells[6];
  NSDictionary *underAttrs = [spellView attrsForCell:&underlined];
  NSDictionary *plainAttrs = [spellView attrsForCell:&plain];
  if (!underlined.underline || plain.underline || spellView.cells[12].underline ||
      underlined.underline_rgb[0] != 235 || underlined.fg[0] != 170 || underlined.bg[0] != 68 ||
      [underAttrs[NSUnderlineStyleAttributeName] intValue] != 1 ||
      [plainAttrs[NSUnderlineStyleAttributeName] intValue] != 0 || cell_same_text(&underlined, &plain)) {
    fprintf(stderr, "ansi spelling underline failed\n");
    return 1;
  }
  cell changed = underlined;
  changed.underline_rgb[0] = 100;
  if (cell_equal(changed, underlined) || cell_same_text(&changed, &underlined) ||
      [[spellView attrsForCell:&changed] isEqual:underAttrs]) return 1;
  NSBitmapImageRep *spellBitmap = [[NSBitmapImageRep alloc]
    initWithBitmapDataPlanes:NULL pixelsWide:spellView.bounds.size.width
    pixelsHigh:spellView.bounds.size.height bitsPerSample:8 samplesPerPixel:4
    hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
  [NSGraphicsContext saveGraphicsState];
  [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:spellBitmap]];
  [spellView drawRect:spellView.bounds];
  [NSGraphicsContext restoreGraphicsState];
  BOOL redUnderline = NO;
  for (int y = 0; y < spellBitmap.pixelsHigh && !redUnderline; y++)
    for (int x = 0; x < spellBitmap.pixelsWide && !redUnderline; x++) {
      NSColor *color = [[spellBitmap colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
      redUnderline = color.redComponent > 0.5 && color.redComponent > color.greenComponent * 1.5;
    }
  if (!redUnderline) { fprintf(stderr, "spelling underline did not draw red\n"); return 1; }

  char fullRow[TERM_COLS + 1];
  memset(fullRow, 'a', TERM_COLS);
  fullRow[TERM_COLS] = '\0';
  ansi_feed(wrapView, fullRow);
  ansi_feed(wrapView, "\r\nX");
  if (wrapView.cells[TERM_COLS].ch != 'X') {
    fprintf(stderr, "ansi full-row wrap failed\n");
    return 1;
  }

  EditTerminalView *csiView = [[EditTerminalView alloc] initForAnsiSelfTest];
  char longCsi[CSI_MAX + 2];
  memset(longCsi, '1', sizeof(longCsi));
  longCsi[sizeof(longCsi) - 1] = '\0';
  ansi_feed(csiView, "\033[");
  ansi_feed(csiView, longCsi);
  if (csiView.csiLength != 0 || [[csiView lineText:10] containsString:@"1"]) {
    fprintf(stderr, "ansi csi cap failed\n");
    return 1;
  }

  int p[2];
  if (pipe(p) != 0) return 1;
  EditTerminalView *scrollView = [[EditTerminalView alloc] initForAnsiSelfTest];
  scrollView.fd = p[1];
  int sent = [scrollView sendScrollDeltaX:0 y:-100000 precise:NO];
  int sent2 = [scrollView sendScrollDeltaX:0 y:-100000 precise:NO];
  close(p[1]);
  scrollView.fd = -1;
  char buf[512];
  ssize_t got = read(p[0], buf, sizeof(buf));
  close(p[0]);
  if (sent != SCROLL_MAX_KEYS || sent2 != SCROLL_MAX_KEYS ||
      got != (sent + sent2) * 3) {
    fprintf(stderr, "scroll cap failed: sent=%d sent2=%d got=%zd\n", sent, sent2, got);
    return 1;
  }
  for (ssize_t i = 0; i < got; i += 3)
    if (buf[i] != 0x1b || buf[i + 1] != '[' || buf[i + 2] != 'B') {
      fprintf(stderr, "scroll emitted non-line-key bytes\n");
      return 1;
    }

  if (pipe(p) != 0) return 1;
  EditTerminalView *mouseView = [[EditTerminalView alloc] initForAnsiSelfTest];
  mouseView.fd = p[1];
  BOOL clicked = [mouseView sendMouseClickRow:1 col:1];
  close(p[1]);
  mouseView.fd = -1;
  got = read(p[0], buf, sizeof(buf));
  close(p[0]);
  const char mouse[] = "\033[<0;2;2M";
  if (!clicked || got != (ssize_t)strlen(mouse) || memcmp(buf, mouse, strlen(mouse)) != 0) {
    fprintf(stderr, "mouse click bytes failed\n");
    return 1;
  }

  // Right-click suggestions come from Aspell, and stale or malformed replies are ignored.
  if (pipe(p) != 0) return 1;
  EditTerminalView *menuView = [[EditTerminalView alloc] initForAnsiSelfTest];
  menuView.fd = p[1];
  NSRect menuRow = [menuView rowRect:0];
  NSEvent *rightClick = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown
    location:NSMakePoint(menuRow.origin.x + menuView.cellSize.width * 1.5, NSMidY(menuRow))
    modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:1 clickCount:1 pressure:1];
  NSMenu *context = [menuView menuForEvent:rightClick];
  got = read(p[0], buf, sizeof(buf));
  const char request[] = "\033[778;1;1;2~";
  if (!context || got != (ssize_t)strlen(request) || memcmp(buf, request, strlen(request))) return 1;
  ansi_feed(menuView, "\033]777;spell;1;7370656c696e67;7370656c6c696e67");
  if (![[context itemAtIndex:0].title isEqualToString:@"Checking spelling…"]) return 1;
  ansi_feed(menuView, ";7370696c6c696e67\a");
  if (![[context itemAtIndex:0].title isEqualToString:@"spelling"] ||
      ![[context itemAtIndex:1].title isEqualToString:@"spilling"] ||
      ![[context itemAtIndex:2].title isEqualToString:@"Add word"] ||
      ![context itemAtIndex:2].isEnabled ||
      ![[context itemAtIndex:4].title isEqualToString:@"Create Comment"]) return 1;
  ansi_feed(menuView, "\033]777;spell;2;00;626164\a\033]777;spell;1;00;zz\a");
  if (![[context itemAtIndex:0].title isEqualToString:@"spelling"]) return 1;
  [menuView sendCommand:[context itemAtIndex:0]];
  got = read(p[0], buf, sizeof(buf));
  const char choice[] = "\033[779;1;1~";
  if (got != (ssize_t)strlen(choice) || memcmp(buf, choice, strlen(choice))) return 1;
  [menuView sendCommand:[context itemAtIndex:2]];
  got = read(p[0], buf, sizeof(buf));
  const char add[] = "\033[779;1;0~";
  if (got != (ssize_t)strlen(add) || memcmp(buf, add, strlen(add))) return 1;
  ansi_feed(menuView, "\033]777;spell;1;7370656c696e67\a");
  if (![[context itemAtIndex:1].title isEqualToString:@"Add word"] ||
      ![context itemAtIndex:1].isEnabled) return 1;
  ansi_feed(menuView, "\033]777;spell;1;\a");
  if ([context itemAtIndex:1].isEnabled) return 1;
  close(p[0]); close(p[1]); menuView.fd = -1;

  if (pipe(p) != 0) return 1;
  EditTerminalView *shortcutView = [[EditTerminalView alloc] initForAnsiSelfTest];
  shortcutView.fd = p[1];
  [shortcutView cut:nil];
  [shortcutView copy:nil];
  [shortcutView pasteString:@"PASTE"];
  NSArray<NSString *> *keyChars = @[@"x", @"p", @"U", @"x", @"+", @"x", @"_", @"x", @")", @"/", @"t", @"q"];
  NSEventModifierFlags keyFlags[] = {
    NSEventModifierFlagControl, NSEventModifierFlagControl,
    NSEventModifierFlagOption | NSEventModifierFlagShift,
    NSEventModifierFlagControl, NSEventModifierFlagShift,
    NSEventModifierFlagControl, NSEventModifierFlagShift,
    NSEventModifierFlagControl, NSEventModifierFlagShift,
    NSEventModifierFlagControl, NSEventModifierFlagControl, NSEventModifierFlagCommand
  };
  for (NSUInteger i = 0; i < keyChars.count; i++) {
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
      modifierFlags:keyFlags[i] timestamp:0 windowNumber:0 context:nil
      characters:keyChars[i] charactersIgnoringModifiers:keyChars[i] isARepeat:NO keyCode:0];
    [shortcutView keyDown:event];
  }
  close(p[1]);
  shortcutView.fd = -1;
  got = read(p[0], buf, sizeof(buf));
  close(p[0]);
  const char shortcuts[] = "\027\033w\033[200~PASTE\033[201~\030\020\033U\030+\030_\030)\037\024\030\003";
  if (got != (ssize_t)strlen(shortcuts) || memcmp(buf, shortcuts, strlen(shortcuts)) != 0) {
    fprintf(stderr, "shortcut bytes failed got=%zd expected=%zu\n", got, strlen(shortcuts));
    for (ssize_t i = 0; i < got; i++) fprintf(stderr, "%02x%s", (unsigned char)buf[i], i + 1 == got ? "\n" : " ");
    return 1;
  }

  if (pipe(p) != 0) return 1;
  fcntl(p[0], F_SETFL, fcntl(p[0], F_GETFL, 0) | O_NONBLOCK);
  fcntl(p[1], F_SETFL, fcntl(p[1], F_GETFL, 0) | O_NONBLOCK);
  EditTerminalView *largeView = [[EditTerminalView alloc] initForAnsiSelfTest];
  largeView.fd = p[1];
  NSMutableString *large = [NSMutableString string];
  for (int i = 0; i < 20000; i++) [large appendString:@"paste-data-"];
  [largeView pasteString:large];
  NSMutableData *received = [NSMutableData data];
  while (largeView.pendingWrite.length > 0) {
    while ((got = read(p[0], buf, sizeof(buf))) > 0) [received appendBytes:buf length:(NSUInteger)got];
    [largeView flushWrites];
  }
  while ((got = read(p[0], buf, sizeof(buf))) > 0) [received appendBytes:buf length:(NSUInteger)got];
  close(p[1]);
  largeView.fd = -1;
  close(p[0]);
  NSMutableData *expectedPaste = [NSMutableData dataWithBytes:"\033[200~" length:6];
  [expectedPaste appendData:[large dataUsingEncoding:NSUTF8StringEncoding]];
  [expectedPaste appendBytes:"\033[201~" length:6];
  if (![received isEqualToData:expectedPaste]) {
    fprintf(stderr, "large paste queue failed: got=%zu expected=%zu\n",
            received.length, expectedPaste.length);
    return 1;
  }

  if (pipe(p) != 0) return 1;
  EditTerminalView *preciseView = [[EditTerminalView alloc] initForAnsiSelfTest];
  preciseView.fd = p[1];
  NSSize cell = [preciseView cellSize];
  int half = [preciseView sendScrollDeltaX:0 y:-cell.height / 2 precise:YES];
  int rest = [preciseView sendScrollDeltaX:0 y:-cell.height / 2 precise:YES];
  close(p[1]);
  preciseView.fd = -1;
  got = read(p[0], buf, sizeof(buf));
  close(p[0]);
  if (half != 0 || rest != 1 || got != 3 ||
      buf[0] != 0x1b || buf[1] != '[' || buf[2] != 'B') {
    fprintf(stderr, "precise scroll failed: half=%d rest=%d got=%zd\n", half, rest, got);
    return 1;
  }

  if (pipe(p) != 0) return 1;
  EditTerminalView *cancelView = [[EditTerminalView alloc] initForAnsiSelfTest];
  cancelView.fd = p[1];
  [cancelView panicCancel];
  int afterCancel = [cancelView sendScrollDeltaX:0 y:-100000 precise:NO];
  close(p[1]);
  cancelView.fd = -1;
  close(p[0]);
  if (afterCancel != 0) {
    fprintf(stderr, "scroll cancel failed: sent=%d\n", afterCancel);
    return 1;
  }

  // A real editor must deliver complete new-size frames during resize tracking.
  CFRunLoopAddCommonMode(CFRunLoopGetMain(), (__bridge CFStringRef)NSEventTrackingRunLoopMode);
  NSTimer *keepAlive = [NSTimer timerWithTimeInterval:60 repeats:YES block:^(NSTimer *timer) {
    (void)timer;
  }];
  [NSRunLoop.mainRunLoop addTimer:keepAlive forMode:NSRunLoopCommonModes];
  EditTerminalView *live = [[EditTerminalView alloc] initWithPath:nil];
  BOOL complete = NO;
  for (int pass = 0; pass < 3; pass++) {
    for (int step = 0; step < 20; step++)
      [live setFrameSize:NSMakeSize((pass == 2 ? 600 : 700 + pass * 100) + step * 3,
                                    (pass == 2 ? 360 : 400 + pass * 80) + step * 2)];
    complete = NO;
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 3;
    while (CFAbsoluteTimeGetCurrent() < deadline && !complete) {
      CFRunLoopRunInMode((__bridge CFStringRef)NSEventTrackingRunLoopMode, 0.01, false);
      int footer = (live.rows - 1) * live.cols + live.cols - 8;
      int modeline = (live.rows - 2) * live.cols;
      complete = live.cursorVisible && live.cells[modeline].ch == '*' &&
        live.cells[footer].ch == 'C' && live.cells[footer + 7].ch == 'p';
      if (pass > 0) complete = complete && live.cells[(live.rows / 2 - 1) * live.cols].ch == '*';
      for (int row = 0; complete && row < live.rows - 1; row++) {
        int edge = row * live.cols + live.cols - 1;
        bool modelineRow = row == live.rows - 2 || (pass > 0 && row == live.rows / 2 - 1);
        complete = live.cells[edge].ch == ' ' && live.cells[edge].reverse == modelineRow;
      }
    }
    if (!complete) break;
    if (pass == 0) [live sendKey:"\0302"];
  }
  // Filling the last column must keep the next insertion point blank and visible.
  if (complete) {
    [live sendKey:"\0301\003\027"];
    NSMutableString *line = [NSMutableString string];
    for (int col = 0; col < live.cols; col++) [line appendString:@"x"];
    [line appendString:@"\r\002"];
    [live sendKey:line.UTF8String];
    for (int pass = 0; pass < 2; pass++) {
      if (pass) [live sendKey:"Z"];
      complete = NO;
      CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 3;
      while (CFAbsoluteTimeGetCurrent() < deadline && !complete) {
        CFRunLoopRunInMode((__bridge CFStringRef)NSEventTrackingRunLoopMode, 0.01, false);
        complete = live.cursorVisible && live.row == 1 && live.col == pass &&
          live.cells[live.cols - 1].ch == 'x' &&
          live.cells[live.cols + pass].ch == ' ' &&
          (!pass || live.cells[live.cols].ch == 'Z');
      }
      if (!complete) break;
    }
  }
  [keepAlive invalidate];
  live.handle.readabilityHandler = nil;
  if (live.pid > 0) {
    kill(live.pid, SIGHUP);
    waitpid(live.pid, NULL, 0);
  } else complete = NO;
  live.pid = 0;
  if (!complete) {
    fprintf(stderr, "live editor rendering failed: rows=%d cols=%d cursor=%d:%d first=%s\n",
            live.rows, live.cols, live.row, live.col, [live lineText:20].UTF8String);
    return 1;
  }
  return 0;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc == 2 && strcmp(argv[1], "--ansi-self-test") == 0)
      return ansi_self_test();
    if (argc == 2 && strcmp(argv[1], "--ansi-bench") == 0)
      return ansi_bench();
    NSApplication *app = [NSApplication sharedApplication];
    EditAppDelegate *delegate = [[EditAppDelegate alloc] init];
    app.delegate = delegate;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [app activateIgnoringOtherApps:YES];
    [app run];
  }
  return 0;
}
