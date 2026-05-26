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
#include <unistd.h>
#include <util.h>

#define TERM_ROWS 30
#define TERM_COLS 100

enum { AnsiNormal, AnsiEsc, AnsiCsi };

typedef struct {
  unichar ch;
  int fg[3];
  int bg[3];
  bool bold;
  bool italic;
  bool reverse;
} cell;

typedef struct {
  int fg[3];
  int bg[3];
  bool bold;
  bool italic;
  bool reverse;
} attr;

@interface EditTerminalView : NSView
@property int fd;
@property pid_t pid;
@property int rows;
@property int cols;
@property int row;
@property int col;
@property bool cursorVisible;
@property attr current;
@property cell *cells;
@property NSMutableData *utf8;
@property NSMutableString *csi;
@property NSFileHandle *handle;
@property int ansiState;
- (instancetype)initWithPath:(NSString *)path;
- (instancetype)initForAnsiSelfTest;
- (NSString *)lineText:(int)width;
- (void)readBytes:(NSData *)data;
- (void)sendBytes:(const char *)bytes length:(NSUInteger)length;
- (void)sendKey:(const char *)bytes;
- (void)sendCommand:(id)sender;
- (void)saveDocument:(id)sender;
- (void)quitDocument:(id)sender;
@end

static void attr_default(attr *a) {
  a->fg[0] = 224; a->fg[1] = 224; a->fg[2] = 224;
  a->bg[0] = 32; a->bg[1] = 32; a->bg[2] = 32;
  a->bold = false;
  a->italic = false;
  a->reverse = false;
}

static cell blank_cell(attr a) {
  cell c;
  c.ch = ' ';
  memcpy(c.fg, a.fg, sizeof(c.fg));
  memcpy(c.bg, a.bg, sizeof(c.bg));
  c.bold = a.bold;
  c.italic = a.italic;
  c.reverse = a.reverse;
  return c;
}

@implementation EditTerminalView

- (instancetype)initWithPath:(NSString *)path {
  self = [super initWithFrame:NSMakeRect(0, 0, 900, 520)];
  if (!self) return nil;
  self.rows = TERM_ROWS;
  self.cols = TERM_COLS;
  self.cursorVisible = true;
  self.utf8 = [NSMutableData data];
  self.csi = [NSMutableString string];
  self.ansiState = AnsiNormal;
  attr_default(&_current);
  _cells = calloc((size_t)_rows * (size_t)_cols, sizeof(cell));
  [self clearScreen];
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
  self.csi = [NSMutableString string];
  self.ansiState = AnsiNormal;
  attr_default(&_current);
  _cells = calloc((size_t)_rows * (size_t)_cols, sizeof(cell));
  [self clearScreen];
  return self;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isOpaque { return YES; }

- (NSSize)cellSize {
  NSDictionary *attrs = @{ NSFontAttributeName: [NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular] };
  return [@"M" sizeWithAttributes:attrs];
}

- (void)viewDidMoveToWindow {
  [self.window makeFirstResponder:self];
}

- (void)dealloc {
  if (_fd > 0) close(_fd);
  if (_pid > 0) kill(_pid, SIGHUP);
  free(_cells);
}

- (void)clearScreen {
  for (int i = 0; i < _rows * _cols; i++) _cells[i] = blank_cell(_current);
  _row = 0;
  _col = 0;
}

- (void)resizeGrid {
  NSSize size = [self cellSize];
  int cols = MAX(20, (int)(self.bounds.size.width / size.width));
  int rows = MAX(8, (int)(self.bounds.size.height / size.height));
  if (cols == _cols && rows == _rows) return;
  _cols = cols;
  _rows = rows;
  free(_cells);
  _cells = calloc((size_t)_rows * (size_t)_cols, sizeof(cell));
  [self clearScreen];
  struct winsize ws = { .ws_row = (unsigned short)_rows, .ws_col = (unsigned short)_cols };
  if (_fd > 0) ioctl(_fd, TIOCSWINSZ, &ws);
  if (_pid > 0) kill(_pid, SIGWINCH);
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self resizeGrid];
}

- (void)startEdit:(NSString *)path {
  NSString *edit = [NSBundle.mainBundle pathForResource:@"edit" ofType:nil];
  if (!edit) edit = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:@"edit"];

  struct winsize ws = { .ws_row = (unsigned short)_rows, .ws_col = (unsigned short)_cols };
  int master = -1;
  pid_t child = forkpty(&master, NULL, NULL, &ws);
  if (child == 0) {
    setenv("TERM", "xterm-256color", 1);
    execl(edit.fileSystemRepresentation, "edit", path.fileSystemRepresentation, NULL);
    _exit(127);
  }
  if (child < 0) return;

  _fd = master;
  _pid = child;
  fcntl(_fd, F_SETFL, fcntl(_fd, F_GETFL, 0) | O_NONBLOCK);
  NSFileHandle *handle = [[NSFileHandle alloc] initWithFileDescriptor:_fd closeOnDealloc:NO];
  self.handle = handle;
  __weak EditTerminalView *weakSelf = self;
  handle.readabilityHandler = ^(NSFileHandle *h) {
    NSData *data = [h availableData];
    if (data.length == 0) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf.window close];
      });
      return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf readBytes:data];
    });
  };
}

- (void)sendBytes:(const char *)bytes length:(NSUInteger)length {
  if (_fd > 0 && length > 0) write(_fd, bytes, length);
}

- (void)sendKey:(const char *)bytes {
  [self sendBytes:bytes length:strlen(bytes)];
}

- (void)sendCommand:(id)sender {
  NSData *data = [sender representedObject];
  [self sendBytes:data.bytes length:data.length];
}

- (void)putChar:(unichar)ch {
  if (_row < 0 || _row >= _rows || _col < 0 || _col >= _cols) return;
  cell c = blank_cell(_current);
  c.ch = ch;
  _cells[_row * _cols + _col] = c;
  if (++_col >= _cols) {
    _col = 0;
    if (_row + 1 < _rows) _row++;
  }
}

- (void)clearLine {
  if (_row < 0 || _row >= _rows) return;
  for (int c = MAX(0, _col); c < _cols; c++)
    _cells[_row * _cols + c] = blank_cell(_current);
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
    else if (p == 7) _current.reverse = true;
    else if (p == 27) _current.reverse = false;
    else if ((p == 38 || p == 48) && i + 4 < parts.count && [self csiInt:parts at:i + 1 fallback:0] == 2) {
      int *rgb = p == 38 ? _current.fg : _current.bg;
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
  if (final == 'H' || final == 'f') {
    _row = MAX(0, MIN(_rows - 1, [self csiInt:parts at:0 fallback:1] - 1));
    _col = MAX(0, MIN(_cols - 1, [self csiInt:parts at:1 fallback:1] - 1));
  } else if (final == 'K') {
    [self clearLine];
  } else if (final == 'J') {
    [self clearScreen];
  } else if (final == 'm') {
    [self applySgr:parts];
  } else if (final == 'l' || final == 'h') {
    if ([seq containsString:@"?25l"]) _cursorVisible = false;
    if ([seq containsString:@"?25h"]) _cursorVisible = true;
  }
}

- (void)readBytes:(NSData *)data {
  const unsigned char *bytes = data.bytes;

  for (NSUInteger i = 0; i < data.length; i++) {
    unsigned char b = bytes[i];
    if (_ansiState == AnsiEsc) {
      if (b == '[') {
        _ansiState = AnsiCsi;
        [_csi setString:@""];
      } else _ansiState = AnsiNormal;
      continue;
    }
    if (_ansiState == AnsiCsi) {
      [_csi appendFormat:@"%c", b];
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
    } else if (b == '\n') {
      if (_row + 1 < _rows) _row++;
    } else if (b == '\b') {
      if (_col > 0) _col--;
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
  [self setNeedsDisplay:YES];
}

- (NSString *)lineText:(int)width {
  NSMutableString *s = [NSMutableString string];
  for (int c = 0; c < width && c < _cols; c++)
    [s appendFormat:@"%C", _cells[c].ch];
  return s;
}

- (NSColor *)color:(int *)rgb {
  return [NSColor colorWithCalibratedRed:rgb[0] / 255.0 green:rgb[1] / 255.0 blue:rgb[2] / 255.0 alpha:1.0];
}

- (void)drawRect:(NSRect)dirtyRect {
  [self resizeGrid];
  NSFont *font = [NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular];
  NSSize size = [self cellSize];
  [[NSColor colorWithCalibratedRed:32 / 255.0 green:32 / 255.0 blue:32 / 255.0 alpha:1] setFill];
  NSRectFill(self.bounds);

  for (int r = 0; r < _rows; r++) {
    for (int c = 0; c < _cols; c++) {
      cell x = _cells[r * _cols + c];
      int *fg = x.reverse ? x.bg : x.fg;
      int *bg = x.reverse ? x.fg : x.bg;
      NSRect rect = NSMakeRect(c * size.width, self.bounds.size.height - (r + 1) * size.height, size.width, size.height);
      [[self color:bg] setFill];
      NSRectFill(rect);
      NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [self color:fg],
        NSObliquenessAttributeName: x.italic ? @0.18 : @0
      };
      [[NSString stringWithCharacters:&x.ch length:1] drawAtPoint:rect.origin withAttributes:attrs];
    }
  }
  if (_cursorVisible && _row >= 0 && _row < _rows && _col >= 0 && _col < _cols) {
    [[NSColor colorWithCalibratedWhite:0.85 alpha:1] setFill];
    NSRectFillUsingOperation(NSMakeRect(_col * size.width, self.bounds.size.height - (_row + 1) * size.height, size.width, size.height), NSCompositingOperationDifference);
  }
}

- (void)keyDown:(NSEvent *)event {
  NSString *plain = event.charactersIgnoringModifiers ?: @"";
  NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  if (event.keyCode == 53) return [self sendKey:"\x1b"];
  if (event.keyCode == 123) return [self sendKey:"\x1b[D"];
  if (event.keyCode == 124) return [self sendKey:"\x1b[C"];
  if (event.keyCode == 125) return [self sendKey:"\x1b[B"];
  if (event.keyCode == 126) return [self sendKey:"\x1b[A"];
  if (flags & NSEventModifierFlagControl) {
    if (plain.length == 0) return;
    char c = (char)[plain characterAtIndex:0];
    char ctrl = (c == ' ') ? 0 : (c & 0x1f);
    return [self sendBytes:&ctrl length:1];
  }
  if ((flags & NSEventModifierFlagOption) && plain.length > 0) {
    [self sendKey:"\x1b"];
    NSData *data = [plain dataUsingEncoding:NSUTF8StringEncoding];
    return [self sendBytes:data.bytes length:data.length];
  }
  NSData *data = [event.characters dataUsingEncoding:NSUTF8StringEncoding];
  [self sendBytes:data.bytes length:data.length];
}

- (void)paste:(id)sender {
  NSString *s = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
  if (!s) return;
  [self sendKey:"\x1b[200~"];
  NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
  [self sendBytes:data.bytes length:data.length];
  [self sendKey:"\x1b[201~"];
}

- (void)copy:(id)sender {
  NSMutableString *s = [NSMutableString string];
  for (int r = 0; r < _rows; r++) {
    for (int c = 0; c < _cols; c++) [s appendFormat:@"%C", _cells[r * _cols + c].ch];
    [s appendString:@"\n"];
  }
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:s forType:NSPasteboardTypeString];
}

- (void)saveDocument:(id)sender { [self sendKey:"\030\023"]; }
- (void)quitDocument:(id)sender { [self sendKey:"\030\003"]; }

@end

@interface EditAppDelegate : NSObject <NSApplicationDelegate>
@property BOOL openedFiles;
@end

@implementation EditAppDelegate

- (NSString *)scratchPath {
  NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@".edit"];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *path = [dir stringByAppendingPathComponent:@"scratch.txt"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:path])
    [[NSData data] writeToFile:path atomically:YES];
  return path;
}

- (void)openPath:(NSString *)path {
  EditTerminalView *view = [[EditTerminalView alloc] initWithPath:path];
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 900, 520)
                                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
  window.title = path.lastPathComponent.length ? path.lastPathComponent : @"Edit";
  window.contentView = view;
  [window makeKeyAndOrderFront:nil];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  [self buildMenus];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self.openedFiles && NSApp.windows.count == 0) [self openPath:[self scratchPath]];
  });
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
  _openedFiles = YES;
  for (NSString *path in filenames) [self openPath:path];
  [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
  return YES;
}

- (void)newDocument:(id)sender { [self openPath:[self scratchPath]]; }

- (void)openDocument:(id)sender {
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseFiles = YES;
  panel.canChooseDirectories = NO;
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
  [self addCommand:@"Quit    C-x C-c" bytes:"\030\003" length:2 to:commands];
  [commands addItem:[NSMenuItem separatorItem]];

  [self addCommand:@"Split Below    C-x 2" bytes:"\0302" length:2 to:commands];
  [self addCommand:@"Split Right    C-x 3" bytes:"\0303" length:2 to:commands];
  [self addCommand:@"Other Pane    C-x o" bytes:"\030o" length:2 to:commands];
  [self addCommand:@"Close Pane    C-x 0" bytes:"\0300" length:2 to:commands];
  [self addCommand:@"One Pane    C-x 1" bytes:"\0301" length:2 to:commands];
  [commands addItem:[NSMenuItem separatorItem]];

  [self addCommand:@"Toggle Read-Only    C-c C-r" bytes:"\003\022" length:2 to:commands];
  [self addCommand:@"Toggle Visual Wrap    C-c C-w" bytes:"\003\027" length:2 to:commands];
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
  return 0;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc == 2 && strcmp(argv[1], "--ansi-self-test") == 0)
      return ansi_self_test();
    NSApplication *app = [NSApplication sharedApplication];
    EditAppDelegate *delegate = [[EditAppDelegate alloc] init];
    app.delegate = delegate;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [app activateIgnoringOtherApps:YES];
    [app run];
  }
  return 0;
}
