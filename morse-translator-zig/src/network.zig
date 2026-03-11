// ============================================================================
//  Morse-Pi — Peer-to-peer networking via UDP beacons.
// ============================================================================
const std = @import("std");
const state = @import("state.zig");

pub const BEACON_PORT: u16 = 5001;
pub var device_uuid: [36]u8 = undefined;
var uuid_initialized: bool = false;

pub const Peer = struct {
    uuid: [36]u8,
    name: [64]u8 = .{0} ** 64,
    name_len: usize = 0,
    ip: [45]u8 = .{0} ** 45,
    ip_len: usize = 0,
    port: u16 = 5000,
    last_seen: i64 = 0,
};

pub var peers: [32]?Peer = .{null} ** 32;
pub var peers_mu: std.Thread.Mutex = .{};
var cached_local_ip: [45]u8 = .{0} ** 45;
var cached_ip_len: usize = 0;
var cached_ip_time: i64 = 0;

pub fn initUuid() void {
    if (uuid_initialized) return;
    // Generate a v4-ish UUID from random bytes
    var rng = std.Random.DefaultPrng.init(@as(u64, @bitCast(std.time.milliTimestamp())));
    var bytes: [16]u8 = undefined;
    rng.fill(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
    const hex = "0123456789abcdef";
    var pos: usize = 0;
    for (bytes, 0..) |b, i| {
        device_uuid[pos] = hex[b >> 4];
        pos += 1;
        device_uuid[pos] = hex[b & 0x0f];
        pos += 1;
        if (i == 3 or i == 5 or i == 7 or i == 9) {
            device_uuid[pos] = '-';
            pos += 1;
        }
    }
    uuid_initialized = true;
}

pub fn getLocalIp() []const u8 {
    const now = std.time.milliTimestamp();
    if (cached_ip_len > 0 and now - cached_ip_time < 10000) {
        return cached_local_ip[0..cached_ip_len];
    }

    // Try to find local IP by connecting to an external address
    const addr = std.net.Address.parseIp4("8.8.8.8", 80) catch {
        return if (cached_ip_len > 0) cached_local_ip[0..cached_ip_len] else "127.0.0.1";
    };
    const sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch {
        return if (cached_ip_len > 0) cached_local_ip[0..cached_ip_len] else "127.0.0.1";
    };
    defer std.posix.close(sock);

    std.posix.connect(sock, &addr.any, addr.getOsSockLen()) catch {
        return if (cached_ip_len > 0) cached_local_ip[0..cached_ip_len] else "127.0.0.1";
    };

    var local_addr: std.posix.sockaddr = undefined;
    var local_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    std.posix.getsockname(sock, &local_addr, &local_addr_len) catch {
        return if (cached_ip_len > 0) cached_local_ip[0..cached_ip_len] else "127.0.0.1";
    };

    // Format IPv4 address
    const sa4: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&local_addr));
    const ip_bytes = @as(*const [4]u8, @ptrCast(&sa4.addr));
    var buf: [45]u8 = undefined;
    const ip_str = std.fmt.bufPrint(&buf, "{}.{}.{}.{}", .{ ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3] }) catch "127.0.0.1";

    @memcpy(cached_local_ip[0..ip_str.len], ip_str);
    cached_ip_len = ip_str.len;
    cached_ip_time = now;
    return cached_local_ip[0..cached_ip_len];
}

/// Start beacon sender & listener threads.
pub fn startBeacons() void {
    initUuid();
    const t1 = std.Thread.spawn(.{}, beaconSender, .{}) catch return;
    t1.detach();
    const t2 = std.Thread.spawn(.{}, beaconListener, .{}) catch return;
    t2.detach();
}

fn beaconSender() void {
    const sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch return;
    defer std.posix.close(sock);

    // Enable broadcast
    const optval: c_int = 1;
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.BROADCAST, std.mem.asBytes(&optval)) catch {};

    const broadcast_addr = std.net.Address.parseIp4("255.255.255.255", BEACON_PORT) catch return;

    while (true) {
        var buf: [512]u8 = undefined;
        const ip = getLocalIp();
        const pkt = std.fmt.bufPrint(&buf,
            \\{{"type":"morse_pi_beacon","uuid":"{s}","name":"{s}","ip":"{s}","port":5000}}
        , .{ &device_uuid, state.settings.device_name, ip }) catch continue;

        _ = std.posix.sendto(sock, pkt, 0, &broadcast_addr.any, broadcast_addr.getOsSockLen()) catch {};
        std.time.sleep(3 * std.time.ns_per_s);
    }
}

fn beaconListener() void {
    while (true) {
        const sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch {
            std.time.sleep(5 * std.time.ns_per_s);
            continue;
        };
        // Reuse address
        const optval: c_int = 1;
        std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&optval)) catch {};

        const bind_addr = std.net.Address.parseIp4("0.0.0.0", BEACON_PORT) catch {
            std.posix.close(sock);
            std.time.sleep(5 * std.time.ns_per_s);
            continue;
        };
        std.posix.bind(sock, &bind_addr.any, bind_addr.getOsSockLen()) catch {
            std.posix.close(sock);
            std.time.sleep(5 * std.time.ns_per_s);
            continue;
        };

        // Set receive timeout
        const timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
        std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

        while (true) {
            var recv_buf: [2048]u8 = undefined;
            var src_addr: std.posix.sockaddr = undefined;
            var src_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
            const n = std.posix.recvfrom(sock, &recv_buf, 0, &src_addr, &src_addr_len) catch |err| {
                if (err == error.WouldBlock) {
                    // Timeout — expire old peers
                    expirePeers();
                    continue;
                }
                break; // Other error — restart socket
            };

            processBeacon(recv_buf[0..n]);
        }
        std.posix.close(sock);
    }
}

fn processBeacon(data: []const u8) void {
    // Simple JSON field extraction (no full parser needed for beacons)
    const uuid_str = extractJsonString(data, "uuid") orelse return;
    if (std.mem.eql(u8, uuid_str, &device_uuid)) return; // skip self

    const type_str = extractJsonString(data, "type") orelse return;
    if (!std.mem.eql(u8, type_str, "morse_pi_beacon")) return;

    const name_str = extractJsonString(data, "name") orelse "Unknown";
    const ip_str = extractJsonString(data, "ip") orelse "0.0.0.0";

    peers_mu.lock();
    defer peers_mu.unlock();

    // Find existing or empty slot
    var slot: ?usize = null;
    for (&peers, 0..) |*p, i| {
        if (p.*) |*peer| {
            if (std.mem.eql(u8, &peer.uuid, uuid_str)) {
                // Update existing
                @memcpy(peer.name[0..@min(name_str.len, 64)], name_str[0..@min(name_str.len, 64)]);
                peer.name_len = @min(name_str.len, 64);
                @memcpy(peer.ip[0..@min(ip_str.len, 45)], ip_str[0..@min(ip_str.len, 45)]);
                peer.ip_len = @min(ip_str.len, 45);
                peer.last_seen = std.time.milliTimestamp();
                return;
            }
        } else if (slot == null) {
            slot = i;
        }
    }

    // Add new peer
    if (slot) |s| {
        var peer = Peer{ .uuid = undefined, .last_seen = std.time.milliTimestamp() };
        if (uuid_str.len == 36) {
            @memcpy(&peer.uuid, uuid_str[0..36]);
        }
        @memcpy(peer.name[0..@min(name_str.len, 64)], name_str[0..@min(name_str.len, 64)]);
        peer.name_len = @min(name_str.len, 64);
        @memcpy(peer.ip[0..@min(ip_str.len, 45)], ip_str[0..@min(ip_str.len, 45)]);
        peer.ip_len = @min(ip_str.len, 45);
        peers[s] = peer;
    }
}

fn expirePeers() void {
    const now = std.time.milliTimestamp();
    peers_mu.lock();
    defer peers_mu.unlock();
    for (&peers) |*p| {
        if (p.*) |peer| {
            if (now - peer.last_seen > 15000) {
                p.* = null;
            }
        }
    }
}

fn extractJsonString(data: []const u8, key: []const u8) ?[]const u8 {
    // Look for "key":"value" pattern (simple, not a full JSON parser)
    var buf: [68]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, data, needle) orelse return null;
    const start = idx + needle.len;
    if (start >= data.len) return null;
    const end = std.mem.indexOfScalarPos(u8, data, start, '"') orelse return null;
    return data[start..end];
}

/// Write peers list as JSON.
pub fn writePeersJson(w: anytype) !void {
    const now = std.time.milliTimestamp();
    const ip = getLocalIp();
    try std.fmt.format(w,
        \\{{"self":{{"uuid":"{s}","name":"{s}","ip":"{s}","port":5000}},"peers":[
    , .{ &device_uuid, state.settings.device_name, ip });

    peers_mu.lock();
    defer peers_mu.unlock();
    var first = true;
    for (peers) |maybe_peer| {
        if (maybe_peer) |peer| {
            if (!first) try w.writeAll(",");
            first = false;
            const ago = @as(f64, @floatFromInt(now - peer.last_seen)) / 1000.0;
            try std.fmt.format(w,
                \\{{"uuid":"{s}","name":"{s}","ip":"{s}","port":{},"last_seen_ago":{d:.1}}}
            , .{
                &peer.uuid,
                peer.name[0..peer.name_len],
                peer.ip[0..peer.ip_len],
                peer.port,
                ago,
            });
        }
    }
    try w.writeAll("]}");
}
