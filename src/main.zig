const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/cursorfont.h");
    @cInclude("X11/Xft/Xft.h");
});
const std = @import("std");
const print = std.debug.window_attributes.n;
const allocator = std.heap.c_allocator;

var xerrorxlib: fn (?*c.Display, [*]c.XErrorEvent) callconv(.C) c_int = undefined;
var clients = std.ArrayList(*Client).init(allocator);
var focus: ?*Client = null;
const Cursor = enum {
    Normal,
    Resize,
    Move,
    Last,
};

const Dimension = struct {
    width: i32,
    height: i32,
};
const Position = struct {
    x: i32,
    y: i32,
};
const Client = struct {
    name: [25]u8,
    min_a: f32,
    max_a: f32,
    pos: Position,
    dim: Dimension,
    old_pos: Position,
    old_dim: Dimension,
    base_dim: Dimension,
    inc_dim: Dimension,
    max_dim: Dimension,
    min_dim: Dimension,
    border_width: i32,
    old_border_width: i32,
    tags: u32,
    is_fixed: bool,
    is_floating: bool,
    is_urgent: bool,
    never_focus: i32,
    old_state: i32,
    is_fullscreen: i32,
    is_decorated: bool,
    win: c.Window,

    pub fn init(self: *Client, window_attributes: c.XWindowAttributes) *Client {
        self.pos = Position{ .x = window_attributes.x, .y = window_attributes.y };
        self.old_pos = Position{ .x = window_attributes.x, .y = window_attributes.y };
        self.dim = Dimension{ .width = window_attributes.width, .height = window_attributes.height };
        self.old_dim = Dimension{ .width = window_attributes.width, .height = window_attributes.height };
        return self;
    }

    pub fn set_decorations(self: *Client) void {
        self.*.is_decorated = true;
    }
};

fn process_client_message(message: [20]u8, display: *c.Display) void {
    print("Message: {s}\n", .{message});
    switch (message[0]) {
        'k' => try if (focus) |f| {
            try c.XKillCient(display, f.win);
            print("Killing client: {}\n", .{f.win});
        },
        else => {
            print("Error: Unknown message: {s}\n", .{message});
        },
    }
}

fn on_wm_detected(display: ?*c.Display, error_event: [*c]c.XErrorEvent) callconv(.C) c_int {
    print("{} :: {}\n", .{ display, error_event });
    print("Error: Another window manager is running.", .{});
    std.os.exit(1);
}

fn on_x_error(display: ?*c.Display, error_event: [*c]c.XErrorEvent) callconv(.C) c_int {
    print("{} :: {}\n", .{ display, error_event });
    print("Error: X Error.", .{});
    return 1;
}

pub fn main() !void {
    var display: *c.Display = c.XOpenDisplay(null) orelse return print("Failed to open X display\n", .{});
    defer c.XCloseDisplay(display);

    var root = c.XDefaultRootWindow(display);
    var no_focus: c.Window = undefined;

    {
        xerrorxlib = c.XSetErrorHandler(on_wm_detected) orelse return print("Error: Failed to set error handler.\n", .{});
        try c.XSelectInput(display, root, 0 | c.FocusChangeMask | c.StructureNotifyMask | c.SubstructureRedirectMask | c.SubstructureNotifyMask);
        try c.XSync(display, c.False);

        try c.XSetErrorHandler(on_x_error);
        try c.XSync(display, c.False);

        var screen: i32 = c.XDefaultScreen(display);
        var screen_width: i32 = c.XDisplayWidth(display, screen);
        var screen_height: i32 = c.XDisplayHeight(display, screen);
        print("Screen initialized...\n", .{});

        var cursor_normal = c.XCreateFontCursor(display, c.XC_left_ptr);
        var cursor_resize = c.XCreateFontCursor(display, c.XC_sizing);
        var cursor_move = c.XCreateFontCursor(display, c.XC_fleur);
        print("Unused cursors:\n{}\n{}", .{ cursor_move, cursor_resize });
        try c.XDefineCursor(display, root, cursor_normal);
        try c.XWarpPointer(display, c.None, root, 0, 0, 0, 0, @divTrunc(screen_width, 2), @divTrunc(screen_height, 2));
        print("Cursor intialized...\n", .{});

        {
            no_focus = c.XCreateSimpleWindow(display, root, -10, -10, 1, 1, 0, 0, 0);
            var window_attributes: c.XSetWindowAttributes = undefined;
            window_attributes.override_redirect = c.True;
            try c.XChangeWindowAttributes(display, no_focus, c.CWOverrideRedirect, &window_attributes);
            try c.XMapWindow(display, no_focus);
            try c.XSetInputFocus(display, no_focus, c.RevertToParent, c.CurrentTime);
            print("NoFocus window created...\n", .{});
        }
        print("Setup complete.\n", .{});
    }

    {
        try c.XGrabServer(display);
        defer c.XUngrabServer(display);

        var returned_root: c.Window = undefined;
        var returned_parent: c.Window = undefined;
        var top_level_windows: [*c]c.Window = undefined;
        defer c.XFree(top_level_windows);

        var num_top_level_windows: u32 = undefined;

        if (c.XQueryTree(display, root, &returned_root, &returned_parent, &top_level_windows, &num_top_level_windows) != 0) {
            var i: u32 = 0;
            var window_attributes: c.XWindowAttributes = undefined;
            while (i < num_top_level_windows) : (i += 1) {
                var window = top_level_windows[i];
                if (c.XGetWindowAttributes(display, window, &window_attributes) == 0 or window_attributes.override_redirect != 0 or c.XGetTransientForHint(display, window, &returned_root) != 0) continue;
                if (window_attributes.map_state == c.IsViewable) manageWindows(window, window_attributes, display);
            }
            i = 0;
            while (i < num_top_level_windows) : (i += 1) {
                var window = top_level_windows[i];
                if (c.XGetWindowAttributes(display, window, &window_attributes) == 0 or window_attributes.override_redirect != 0) continue;
                if (c.XGetTransientForHint(display, window, &returned_root) != 0 and window_attributes.map_state == c.IsViewable) manageWindow(window, window_attributes, display);
            }
        }
    }

    var event: c.XEvent = undefined;
    while (c.XNextEvent(display, &event) == 0) {
        print("Received event: {}\n", .{event.type});
        switch (event.type) {
            c.ConfigureRequest => {
                if (win_to_client(event.xconfigurerequest.window)) |client| {
                } else {
                }
            },
            c.ConfigureNotify => {
                print("Configure Notify\n", .{});
                if (event.xconfigure.window != root) continue;
            },
            c.MapRequest => {
                print("Map Request\n", .{});
                var window_attributes: c.XWindowAttributes = undefined;
            }
        }
    }
}
