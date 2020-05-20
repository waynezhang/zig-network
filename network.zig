const std = @import("std");

comptime {
    std.debug.assert(@sizeOf(std.os.sockaddr) >= @sizeOf(std.os.sockaddr_in));
    // std.debug.assert(@sizeOf(std.os.sockaddr) >= @sizeOf(std.os.sockaddr_in6));
}

const is_windows = std.builtin.os.tag == .windows;

const windows_data = struct {
    usingnamespace std.os.windows;

    extern "ws2_32" fn socket(af: c_int, type_0: c_int, protocol: c_int) callconv(.Stdcall) ws2_32.SOCKET;
    extern "ws2_32" fn sendto(s: ws2_32.SOCKET, buf: [*c]const u8, len: c_int, flags: c_int, to: [*c]const std.os.sockaddr, tolen: c_int) callconv(.Stdcall) c_int;
    extern "ws2_32" fn send(s: ws2_32.SOCKET, buf: [*c]const u8, len: c_int, flags: c_int) callconv(.Stdcall) c_int;
    extern "ws2_32" fn recvfrom(s: ws2_32.SOCKET, buf: [*c]u8, len: c_int, flags: c_int, from: [*c]std.os.sockaddr, fromlen: [*c]c_int) callconv(.Stdcall) c_int;

    fn windows_socket(addr_family: u32, socket_type: u32, protocol: u32) std.os.SocketError!ws2_32.SOCKET {
        const sock = socket(@intCast(c_int, addr_family), @intCast(c_int, socket_type), @intCast(c_int, protocol));
        if (sock == ws2_32.INVALID_SOCKET) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
                .WSAEMFILE => return error.ProcessFdQuotaExceeded,
                .WSAENOBUFS => return error.SystemResources,
                .WSAEPROTONOSUPPORT => return error.ProtocolNotSupported,
                else => |err| return unexpectedWSAError(err),
            };
        }
        return sock;
    }

    fn windows_connect(sock: ws2_32.SOCKET, sock_addr: *const std.os.sockaddr, len: std.os.socklen_t) std.os.ConnectError!void {
        while (true) if (ws2_32.connect(sock, sock_addr, len) != 0) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSAEACCES => error.PermissionDenied,
                .WSAEADDRINUSE => error.AddressInUse,
                .WSAEINPROGRESS => error.WouldBlock,
                .WSAEALREADY => unreachable,
                .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
                .WSAECONNREFUSED => error.ConnectionRefused,
                .WSAEFAULT => unreachable,
                .WSAEINTR => continue,
                .WSAEISCONN => unreachable,
                .WSAENETUNREACH => error.NetworkUnreachable,
                .WSAEHOSTUNREACH => error.NetworkUnreachable,
                .WSAENOTSOCK => unreachable,
                .WSAETIMEDOUT => error.ConnectionTimedOut,
                .WSAEWOULDBLOCK => error.WouldBlock,
                else => |err| return unexpectedWSAError(err),
            };
        } else return;
    }

    fn windows_close(sock: ws2_32.SOCKET) void {
        if (ws2_32.closesocket(sock) != 0) {
            switch (ws2_32.WSAGetLastError()) {
                .WSAENOTSOCK => unreachable,
                .WSAEINPROGRESS => unreachable,
                else => return,
            }
        }
    }

    fn windows_sendto(sock: ws2_32.SOCKET, buf: []const u8, flags: u32, dest_addr: ?*const std.os.sockaddr, addrlen: std.os.socklen_t) std.os.SendError!usize {
        while (true) {
            const result = sendto(sock, buf.ptr, @intCast(c_int, buf.len), @intCast(c_int, flags), dest_addr, @intCast(c_int, addrlen));
            if (result == ws2_32.SOCKET_ERROR) {
                return switch (ws2_32.WSAGetLastError()) {
                    .WSAEACCES => error.AccessDenied,
                    .WSAECONNRESET => error.ConnectionResetByPeer,
                    .WSAEDESTADDRREQ => unreachable,
                    .WSAEFAULT => unreachable,
                    .WSAEINTR => continue,
                    .WSAEINVAL => unreachable,
                    .WSAEMSGSIZE => error.MessageTooBig,
                    .WSAENOBUFS => error.SystemResources,
                    .WSAENOTCONN => unreachable,
                    .WSAENOTSOCK => unreachable,
                    .WSAEOPNOTSUPP => unreachable,
                    else => |err| return unexpectedWSAError(err),
                };
            }
            return @intCast(usize, result);
        }
    }

    fn windows_send(sock: ws2_32.SOCKET, buf: []const u8, flags: u32) std.os.SendError!usize {
        return windows_sendto(sock, buf, flags, null, 0);
    }

    fn windows_recvfrom(sock: ws2_32.SOCKET, buf: []u8, flags: u32, src_addr: ?*std.os.sockaddr, addrlen: ?*std.os.socklen_t) std.os.RecvFromError!usize {
        while (true) {
            var our_addrlen: c_int = undefined;
            const result = recvfrom(sock, buf.ptr, @intCast(c_int, buf.len), @intCast(c_int, flags), src_addr, if (addrlen != null) &our_addrlen else null);
            if (result == ws2_32.SOCKET_ERROR) {
                return switch (ws2_32.WSAGetLastError()) {
                    .WSAEFAULT => unreachable,
                    .WSAEINVAL => unreachable,
                    .WSAEISCONN => unreachable,
                    .WSAENOTSOCK => unreachable,
                    .WSAESHUTDOWN => unreachable,
                    .WSAEOPNOTSUPP => unreachable,
                    .WSAEWOULDBLOCK => error.WouldBlock,
                    .WSAEINTR => continue,
                    else => |err| return unexpectedWSAError(err),
                };
            }
            if (addrlen) |a| a.* = @intCast(u32, our_addrlen);
            return @intCast(usize, result);
        }
    }
};

pub fn init() error{InitializationError}!void {
    if (is_windows) {
        _ = windows_data.WSAStartup(2, 2) catch return error.InitializationError;
    }
}

pub fn deinit() void {
    if (is_windows) {
        windows_data.WSACleanup() catch return;
    }
}

/// A network address abstraction. Contains one member for each possible type of address.
pub const Address = union(AddressFamily) {
    ipv4: IPv4,
    ipv6: IPv6,

    pub const IPv4 = struct {
        const Self = @This();

        pub const any = IPv4.init(0, 0, 0, 0);
        pub const broadcast = IPv4.init(255, 255, 255, 255);

        value: [4]u8,

        pub fn init(a: u8, b: u8, c: u8, d: u8) Self {
            return Self{
                .value = [4]u8{ a, b, c, d },
            };
        }

        pub fn format(value: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, out_stream: var) !void {
            try out_stream.print("{}.{}.{}.{}", .{
                value.value[0],
                value.value[1],
                value.value[2],
                value.value[3],
            });
        }
    };

    pub const IPv6 = struct {
        const Self = @This();

        pub const any = Self{};

        pub fn format(value: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, out_stream: var) !void {
            unreachable;
        }
    };

    pub fn format(value: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, out_stream: var) !void {
        switch (value) {
            .ipv4 => |a| try a.format(fmt, options, out_stream),
            .ipv6 => |a| try a.format(fmt, options, out_stream),
        }
    }
};

pub const AddressFamily = enum {
    const Self = @This();

    ipv4,
    ipv6,

    fn toNativeAddressFamily(af: Self) u32 {
        return switch (af) {
            .ipv4 => std.os.AF_INET,
            .ipv6 => std.os.AF_INET6,
        };
    }

    fn fromNativeAddressFamily(af: i32) !Self {
        return switch (af) {
            std.os.AF_INET => .ipv4,
            std.os.AF_INET6 => .ipv6,
            else => return error.UnsupportedAddressFamily,
        };
    }
};

/// Protocols supported by this library.
pub const Protocol = enum {
    const Self = @This();

    tcp,
    udp,

    fn toSocketType(proto: Self) u32 {
        return switch (proto) {
            .tcp => std.os.SOCK_STREAM,
            .udp => std.os.SOCK_DGRAM,
        };
    }
};

/// A network end point. Is composed of an address and a port.
pub const EndPoint = struct {
    const Self = @This();

    address: Address,
    port: u16,

    pub fn format(value: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, out_stream: var) !void {
        try out_stream.print("{}:{}", .{
            value.address,
            value.port,
        });
    }

    pub fn fromSocketAddress(src: *const std.os.sockaddr, size: usize) !Self {
        switch (src.family) {
            std.os.AF_INET => {
                if (size < @sizeOf(std.os.sockaddr_in))
                    return error.InsufficientBytes;
                const value = @ptrCast(*const std.os.sockaddr_in, @alignCast(4, src));
                return EndPoint{
                    .port = std.mem.bigToNative(u16, value.port),
                    .address = Address{
                        .ipv4 = Address.IPv4{
                            .value = @bitCast([4]u8, value.addr),
                        },
                    },
                };
            },
            std.os.AF_INET6 => {
                return error.UnsupportedAddressFamily;
            },
            else => {
                std.debug.warn("got invalid socket address: {}\n", .{src});
                return error.UnsupportedAddressFamily;
            },
        }
    }

    fn toSocketAddress(self: Self) std.os.sockaddr {
        var result: std.os.sockaddr align(8) = undefined;
        switch (self.address) {
            .ipv4 => |addr| {
                @ptrCast(*std.os.sockaddr_in, &result).* = std.os.sockaddr_in{
                    .family = std.os.AF_INET,
                    .port = std.mem.nativeToBig(u16, self.port),
                    .addr = @bitCast(u32, addr.value),
                    .zero = [_]u8{0} ** 8,
                };
            },
            .ipv6 => |addr| {
                unreachable;
            },
        }
        return result;
    }
};

/// A network socket, can receive and send data for TCP/UDP and accept
/// incoming connections if bound as a TCP server.
pub const Socket = struct {
    pub const Error = error{
        AccessDenied,
        WouldBlock,
        FastOpenAlreadyInProgress,
        ConnectionResetByPeer,
        MessageTooBig,
        SystemResources,
        BrokenPipe,
        Unexpected,
    };
    const Self = @This();

    const NativeSocket = if (is_windows) std.os.windows.ws2_32.SOCKET else std.os.fd_t;

    family: AddressFamily,
    internal: NativeSocket,

    /// Spawns a new socket that must be freed with `close()`.
    /// `family` defines the socket family, `protocol` the protocol used.
    pub fn create(family: AddressFamily, protocol: Protocol) !Self {
        const socket_fn = if (is_windows) windows_data.windows_socket else std.os.socket;

        return Self{
            .family = family,
            .internal = try socket_fn(family.toNativeAddressFamily(), protocol.toSocketType(), 0),
        };
    }

    /// Closes the socket and releases its resources.
    pub fn close(self: Self) void {
        const close_fn = if (is_windows) windows_data.windows_close else std.os.close;
        close_fn(self.internal);
    }

    /// Binds the socket to the given end point.
    pub fn bind(self: Self, ep: EndPoint) !void {
        var sockaddr = ep.toSocketAddress();
        try std.os.bind(self.internal, &sockaddr, @sizeOf(@TypeOf(sockaddr)));
    }

    /// Binds the socket to all supported addresses on the local device.
    /// This will use the any IP (`0.0.0.0` for IPv4).
    pub fn bindToPort(self: Self, port: u16) !void {
        return switch (self.family) {
            .ipv4 => self.bind(EndPoint{
                .address = Address{ .ipv4 = Address.IPv4.any },
                .port = port,
            }),
            .ipv6 => self.bind(EndPoint{
                .address = Address{ .ipv6 = Address.IPv6.any },
                .port = port,
            }),
        };
    }

    /// Connects the UDP or TCP socket to a remote server.
    /// The `target` address type must fit the address type of the socket.
    pub fn connect(self: Self, target: EndPoint) !void {
        if (target.address != self.family)
            return error.AddressFamilyMismach;

        const connect_fn = if (is_windows) windows_data.windows_connect else std.os.connect;
        const sa = target.toSocketAddress();
        try connect_fn(self.internal, &sa, @sizeOf(@TypeOf(sa)));
    }

    /// Makes this socket a TCP server and allows others to connect to
    /// this socket.
    /// Call `accept()` to handle incoming connections.
    pub fn listen(self: Self) !void {
        try std.os.listen(self.internal, 0);
    }

    /// Waits until a new TCP client connects to this socket and accepts the incoming TCP connection.
    /// This function is only allowed for a bound TCP socket. `listen()` must have been called before!
    pub fn accept(self: Self) !Socket {
        var addr: std.os.sockaddr = undefined;
        var addr_size: std.os.socklen_t = @sizeOf(std.os.sockaddr);

        const fd = try std.os.accept4(self.internal, &addr, &addr_size, 0);
        errdefer std.os.close(fd);

        return Socket{
            .family = try AddressFamily.fromNativeAddressFamily(addr.family),
            .internal = fd,
        };
    }

    /// Send some data to the connected peer. In UDP, this
    /// will always send full packets, on TCP it will append
    /// to the stream.
    pub fn send(self: Self, data: []const u8) !usize {
        const send_fn = if (is_windows) windows_data.windows_send else std.os.send;
        return try send_fn(self.internal, data, 0);
    }

    /// Blockingly receives some data from the connected peer.
    /// Will read all available data from the TCP stream or
    /// a UDP packet.
    pub fn receive(self: Self, data: []u8) !usize {
        const recvfrom_fn = if (is_windows) windows_data.windows_recvfrom else std.os.recvfrom;

        return try recvfrom_fn(self.internal, data, 0, null, null);
    }

    const ReceiveFrom = struct { numberOfBytes: usize, sender: EndPoint };

    /// Same as ´receive`, but will also return the end point from which the data
    /// was received. This is only a valid operation on UDP sockets.
    pub fn receiveFrom(self: Self, data: []u8) !ReceiveFrom {
        const recvfrom_fn = if (is_windows) windows_data.windows_recvfrom else std.os.recvfrom;

        var addr: std.os.sockaddr align(4) = undefined;
        var size: std.os.socklen_t = @sizeOf(std.os.sockaddr);

        const len = try recvfrom_fn(self.internal, data, 0, &addr, &size);

        return ReceiveFrom{
            .numberOfBytes = len,
            .sender = try EndPoint.fromSocketAddress(&addr, size),
        };
    }

    /// Sends a packet to a given network end point. Behaves the same as `send()`, but will only work for
    /// for UDP sockets.
    pub fn sendTo(self: Self, receiver: EndPoint, data: []const u8) !usize {
        const sendto_fn = if (is_windows) windows_data.windows_sendto else std.os.sendto;

        const sa = receiver.toSocketAddress();
        return try sendto_fn(self.internal, data, 0, &sa, @sizeOf(std.os.sockaddr));
    }

    /// Sets the socket option `SO_REUSEPORT` which allows
    /// multiple bindings of the same socket to the same address
    /// on UDP sockets and allows quicker re-binding of TCP sockets.
    pub fn enablePortReuse(self: Self, enabled: bool) !void {
        var opt: c_int = if (enabled) 1 else 0;
        try std.os.setsockopt(self.internal, std.os.SOL_SOCKET, std.os.SO_REUSEADDR, std.mem.asBytes(&opt));
    }

    /// Retrieves the end point to which the socket is bound.
    pub fn getLocalEndPoint(self: Self) !EndPoint {
        var addr: std.os.sockaddr align(4) = undefined;
        var size: std.os.socklen_t = @sizeOf(@TypeOf(addr));

        try std.os.getsockname(self.internal, &addr, &size);

        return try EndPoint.fromSocketAddress(&addr, size);
    }

    /// Retrieves the end point to which the socket is connected.
    pub fn getRemoteEndPoint(self: Self) !EndPoint {
        var addr: std.os.sockaddr align(4) = undefined;
        var size: std.os.socklen_t = @sizeOf(@TypeOf(addr));

        try getpeername(self.internal, &addr, &size);

        return try EndPoint.fromSocketAddress(&addr, size);
    }

    pub const MulticastGroup = struct {
        interface: Address.IPv4,
        group: Address.IPv4,
    };

    /// Joins the UDP socket into a multicast group.
    /// Multicast enables sending packets to the group and all joined peers
    /// will receive the sent data.
    pub fn joinMulticastGroup(self: Self, group: MulticastGroup) !void {
        const ip_mreq = extern struct {
            imr_multiaddr: u32,
            imr_address: u32,
            imr_ifindex: u32,
        };

        const request = ip_mreq{
            .imr_multiaddr = @bitCast(u32, group.group.value),
            .imr_address = @bitCast(u32, group.interface.value),
            .imr_ifindex = 0, // this cannot be crossplatform, so we set it to zero
        };

        const IP_ADD_MEMBERSHIP = 35;

        try std.os.setsockopt(self.internal, std.os.SOL_SOCKET, IP_ADD_MEMBERSHIP, std.mem.asBytes(&request));
    }

    /// Gets an input stream that allows reading data from the socket.
    pub fn inStream(self: Self) std.io.InStream(Socket, std.os.RecvFromError, receive) {
        return .{
            .context = self,
        };
    }

    /// Gets an output stream that allows writing data to the socket.
    pub fn outStream(self: Self) std.io.OutStream(Socket, Error, send) {
        return .{
            .context = self,
        };
    }
};

/// A socket event that can be waited for.
pub const SocketEvent = struct {
    /// Wait for data ready to be read.
    read: bool,

    /// Wait for all pending data to be sent and the socket accepting
    /// non-blocking writes.
    write: bool,
};

/// A set of sockets that can be used to query socket readiness.
/// This is similar to `select()´ or `poll()` and provides a way to
/// create non-blocking socket I/O.
/// This is intented to be used with `waitForSocketEvents()`.
pub const SocketSet = struct {
    const Self = @This();

    internal: OSLogic,

    /// Initialize a new socket set. This can be reused for
    /// multiple queries without having to reset the set every time.
    /// Call `deinit()` to free the socket set.
    pub fn init(allocator: *std.mem.Allocator) Self {
        return Self{
            .internal = OSLogic.init(allocator),
        };
    }

    /// Frees the contained resources.
    pub fn deinit(self: Self) void {
        self.internal.deinit();
    }

    /// Removes all sockets from the set.
    pub fn clear(self: *Self) void {
        self.internal.clear();
    }

    /// Adds a socket to the set and enables waiting for any of the events
    /// in `events`.
    pub fn add(self: *Self, sock: Socket, events: SocketEvent) !void {
        try self.internal.add(sock, events);
    }

    /// Removes the socket from the set.
    pub fn remove(self: *Self, sock: Socket) void {
        self.internal.remove(sock);
    }

    /// Checks if the socket is ready to be read.
    /// Only valid after the first call to `waitForSocketEvents()`.
    pub fn isReadyRead(self: Self, sock: Socket) bool {
        return self.internal.isReadyRead(sock);
    }

    /// Checks if the socket is ready to be written.
    /// Only valid after the first call to `waitForSocketEvents()`.
    pub fn isReadyWrite(self: Self, sock: Socket) bool {
        return self.internal.isReadyWrite(sock);
    }

    /// Checks if the socket is faulty and cannot be used anymore.
    /// Only valid after the first call to `waitForSocketEvents()`.
    pub fn isFaulted(self: Self, sock: Socket) bool {
        return self.internal.isFaulted(sock);
    }
};

/// Implementation of SocketSet for each platform,
/// keeps the thing above nice and clean, all functions get inlined.
const OSLogic = switch (std.builtin.os.tag) {

    // Windows afaik provides fd_set to be used with ws2_32.
    .windows => @compileError("Not supported yet."),

    // Linux uses `poll()` syscall to wait for socket events.
    // This allows an arbitrary number of sockets to be handled.
    .linux => struct {
        const Self = @This();
        // use poll on linux

        fds: std.ArrayList(std.os.pollfd),

        inline fn init(allocator: *std.mem.Allocator) Self {
            return Self{
                .fds = std.ArrayList(std.os.pollfd).init(allocator),
            };
        }

        inline fn deinit(self: Self) void {
            self.fds.deinit();
        }

        inline fn clear(self: *Self) void {
            self.fds.shrink(0);
        }

        inline fn add(self: *Self, sock: Socket, events: SocketEvent) !void {
            // Always poll for errors as this is done anyways
            var mask: i16 = std.os.POLLERR;

            if (events.read)
                mask |= std.os.POLLIN;
            if (events.write)
                mask |= std.os.POLLOUT;

            for (self.fds.items) |*pfd| {
                if (pfd.fd == sock.internal) {
                    pfd.events |= mask;
                    return;
                }
            }

            try self.fds.append(std.os.pollfd{
                .fd = sock.internal,
                .events = mask,
                .revents = 0,
            });
        }

        inline fn remove(self: *Self, sock: Socket) void {
            const index = for (self.fds.items) |item, i| {
                if (item.fd == sock.internal)
                    break i;
            } else null;

            if (index) |idx| {
                self.fds.removeSwap(idx);
            }
        }

        inline fn checkMaskAnyBit(self: Self, sock: Socket, mask: i16) bool {
            for (self.fds.items) |item| {
                if (item.fd != sock.internal)
                    continue;

                if ((item.revents & mask) != 0) {
                    return true;
                }

                return false;
            }
            return false;
        }

        inline fn isReadyRead(self: Self, sock: Socket) bool {
            return self.checkMaskAnyBit(sock, std.os.POLLIN);
        }

        inline fn isReadyWrite(self: Self, sock: Socket) bool {
            return self.checkMaskAnyBit(sock, std.os.POLLOUT);
        }

        inline fn isFaulted(self: Self, sock: Socket) bool {
            return self.checkMaskAnyBit(sock, std.os.POLLERR);
        }
    },
    else => @compileError("unsupported os " ++ @tagName(std.builtin.os.tag) ++ " for SocketSet!"),
};

/// Waits until sockets in SocketSet are ready to read/write or have a fault condition.
/// If `timeout` is not `null`, it describes a timeout in nanoseconds until the function
/// should return.
/// Note that `timeout` granularity may not be available in nanoseconds and larger
/// granularities are used.
/// If the requested timeout interval requires a finer granularity than the implementation supports, the
/// actual timeout interval shall be rounded up to the next supported value.
pub fn waitForSocketEvent(set: *SocketSet, timeout: ?u64) !usize {
    switch (std.builtin.os.tag) {
        .linux => return try std.os.poll(
            set.internal.fds.items,
            if (timeout) |val| @intCast(i32, (val + std.time.millisecond - 1) / std.time.millisecond) else -1,
        ),
        else => @compileError("unsupported os " ++ @tagName(std.builtin.os.tag) ++ " for SocketSet!"),
    }
}

const GetPeerNameError = error{
    /// Insufficient resources were available in the system to perform the operation.
    SystemResources,
    NotConnected,
} || std.os.UnexpectedError;

fn getpeername(sockfd: std.os.fd_t, addr: *std.os.sockaddr, addrlen: *std.os.socklen_t) GetPeerNameError!void {
    switch (std.os.errno(std.os.system.getsockname(sockfd, addr, addrlen))) {
        0 => return,
        else => |err| return std.os.unexpectedErrno(err),

        std.os.EBADF => unreachable, // always a race condition
        std.os.EFAULT => unreachable,
        std.os.EINVAL => unreachable, // invalid parameters
        std.os.ENOTSOCK => unreachable,
        std.os.ENOBUFS => return error.SystemResources,
        std.os.ENOTCONN => return error.NotConnected,
    }
}
