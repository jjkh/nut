const std = @import("std");
const Build = std.Build;

fn defineFromBool(val: bool) ?u1 {
    return if (val) 1 else null;
}

pub fn build(b: *Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const system_libudev = b.option(
        bool,
        "system-libudev",
        "link with system libudev on linux (default: true)",
    ) orelse true;

    const libusb = createLibusb(b, target, optimize, system_libudev);
    b.installArtifact(libusb);

    const build_all = b.step("all", "build libusb for all targets");
    for (targets(b)) |t| {
        const lib = createLibusb(b, t, optimize, system_libudev);
        build_all.dependOn(&lib.step);
    }
}

fn createLibusb(
    b: *Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    system_libudev: bool,
) *Build.Step.Compile {
    const upstream = b.dependency("libusb", .{});
    const libusb = upstream.path("libusb");
    const libusb_os = libusb.path(b, "os");

    const is_posix =
        target.result.isDarwinLibC() or
        target.result.os.tag == .linux or
        target.result.os.tag == .openbsd;

    const lib = b.addLibrary(.{
        .name = "usb",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib.addCSourceFiles(.{
        .files = src,
        .root = libusb,
    });

    if (is_posix)
        lib.addCSourceFiles(.{
            .files = posix_platform_src,
            .root = libusb_os,
        });

    if (target.result.isDarwinLibC()) {
        lib.addCSourceFiles(.{
            .files = darwin_src,
            .root = libusb_os,
        });
        lib.linkFramework("CoreFoundation");
        lib.linkFramework("IOKit");
        lib.linkFramework("Security");
    } else if (target.result.os.tag == .linux) {
        lib.addCSourceFiles(.{ .files = linux_src, .root = libusb_os });
        if (system_libudev) {
            lib.addCSourceFiles(.{ .files = linux_udev_src, .root = libusb_os });
            lib.linkSystemLibrary("udev");
        }
    } else if (target.result.os.tag == .windows) {
        lib.addCSourceFiles(.{ .files = windows_src, .root = libusb_os });
        lib.addCSourceFiles(.{ .files = windows_platform_src, .root = libusb_os });
    } else if (target.result.os.tag == .netbsd) {
        lib.addCSourceFiles(.{ .files = netbsd_src, .root = libusb_os });
    } else if (target.result.os.tag == .openbsd) {
        lib.addCSourceFiles(.{ .files = openbsd_src, .root = libusb_os });
    } else if (target.result.os.tag == .haiku) {
        lib.addCSourceFiles(.{ .files = haiku_src, .root = libusb_os });
    } else if (target.result.os.tag == .solaris) {
        lib.addCSourceFiles(.{ .files = sunos_src, .root = libusb_os });
    } else unreachable;

    lib.addIncludePath(libusb);
    lib.installHeader(libusb.path(b, "libusb.h"), "libusb.h");

    // config header
    if (target.result.isDarwinLibC()) {
        lib.addIncludePath(libusb.path(b, "Xcode"));
    } else if (target.result.abi == .msvc) {
        lib.addIncludePath(libusb.path(b, "msvc"));
    } else if (target.result.abi == .android) {
        lib.addIncludePath(libusb.path(b, "android"));
    } else {
        const config_h = b.addConfigHeader(.{
            .style = .blank,
            .include_path = "config.h",
        }, .{
            .DEFAULT_VISIBILITY = .@"__attribute__ ((visibility (\"default\")))",
            .ENABLE_DEBUG_LOGGING = defineFromBool(optimize == .Debug),
            .ENABLE_LOGGING = 1,
            .HAVE_CLOCK_GETTIME = defineFromBool(!(target.result.os.tag == .windows)),
            .HAVE_IOKIT_USB_IOUSBHOSTFAMILYDEFINITIONS_H = defineFromBool(target.result.isDarwinLibC()),
            .HAVE_LIBUDEV = defineFromBool(system_libudev),
            .HAVE_STDINT_H = 1,
            .HAVE_STDIO_H = 1,
            .HAVE_STDLIB_H = 1,
            .HAVE_STRINGS_H = 1,
            .HAVE_STRING_H = 1,
            .HAVE_STRUCT_TIMESPEC = 1,
            .HAVE_SYSLOG = defineFromBool(is_posix),
            .HAVE_SYS_STAT_H = 1,
            .HAVE_SYS_TIME_H = 1,
            .HAVE_SYS_TYPES_H = 1,
            .HAVE_UNISTD_H = 1,
            .PACKAGE = "libusb-1.0",
            .PACKAGE_BUGREPORT = "libusb-devel@lists.sourceforge.net",
            .PACKAGE_NAME = "libusb-1.0",
            .PACKAGE_STRING = "libusb-1.0 1.0.29",
            .PACKAGE_TARNAME = "libusb-1.0",
            .PACKAGE_URL = "http://libusb.info",
            .PACKAGE_VERSION = "1.0.29",
            .PLATFORM_POSIX = defineFromBool(is_posix),
            .PLATFORM_WINDOWS = defineFromBool(target.result.os.tag == .windows),
            .@"PRINTF_FORMAT(a, b)" = .@"__attribute__ ((__format__ (__printf__, a, b)))",
            .STDC_HEADERS = 1,
            .VERSION = "1.0.29",
            ._GNU_SOURCE = 1,
        });
        lib.addConfigHeader(config_h);
    }
    return lib;
}

const src = &.{
    "core.c",
    "descriptor.c",
    "hotplug.c",
    "io.c",
    "strerror.c",
    "sync.c",
};

const posix_platform_src: []const []const u8 = &.{
    "events_posix.c",
    "threads_posix.c",
};

const windows_platform_src: []const []const u8 = &.{
    "events_windows.c",
    "threads_windows.c",
};

const darwin_src: []const []const u8 = &.{
    "darwin_usb.c",
};

const haiku_src: []const []const u8 = &.{
    "haiku_pollfs.cpp",
    "haiku_usb_backend.cpp",
    "haiku_usb_raw.cpp",
};

const linux_src: []const []const u8 = &.{
    "linux_netlink.c",
    "linux_usbfs.c",
};
const linux_udev_src: []const []const u8 = &.{
    "linux_udev.c",
};

const netbsd_src: []const []const u8 = &.{
    "netbsd_usb.c",
};

const null_src: []const []const u8 = &.{
    "null_usb.c",
};

const openbsd_src: []const []const u8 = &.{
    "openbsd_usb.c",
};

// sunos isn't supported by zig
const sunos_src: []const []const u8 = &.{
    "sunos_usb.c",
};

const windows_src: []const []const u8 = &.{
    "events_windows.c",
    "threads_windows.c",
    "windows_common.c",
    "windows_usbdk.c",
    "windows_winusb.c",
};

pub fn targets(b: *Build) [17]std.Build.ResolvedTarget {
    return [_]std.Build.ResolvedTarget{
        // zig fmt: off
        b.resolveTargetQuery(.{}),
        b.resolveTargetQuery(.{ .os_tag = .linux,   .cpu_arch = .x86_64,    .abi = .musl        }),
        b.resolveTargetQuery(.{ .os_tag = .linux,   .cpu_arch = .x86_64,    .abi = .gnu         }),
        b.resolveTargetQuery(.{ .os_tag = .linux,   .cpu_arch = .aarch64,   .abi = .musl        }),
        b.resolveTargetQuery(.{ .os_tag = .linux,   .cpu_arch = .aarch64,   .abi = .gnu         }),
        b.resolveTargetQuery(.{ .os_tag = .linux,   .cpu_arch = .arm,       .abi = .musleabi    }),
        b.resolveTargetQuery(.{ .os_tag = .linux,   .cpu_arch = .arm,       .abi = .musleabihf  }),
        b.resolveTargetQuery(.{ .os_tag = .linux,   .cpu_arch = .arm,       .abi = .gnueabi     }),
        b.resolveTargetQuery(.{ .os_tag = .linux,   .cpu_arch = .arm,       .abi = .gnueabihf   }),
        b.resolveTargetQuery(.{ .os_tag = .macos,   .cpu_arch = .aarch64                        }),
        b.resolveTargetQuery(.{ .os_tag = .macos,   .cpu_arch = .x86_64                         }),
        b.resolveTargetQuery(.{ .os_tag = .windows, .cpu_arch = .aarch64                        }),
        b.resolveTargetQuery(.{ .os_tag = .windows, .cpu_arch = .x86_64                         }),
        b.resolveTargetQuery(.{ .os_tag = .netbsd,  .cpu_arch = .x86_64                         }),
        b.resolveTargetQuery(.{ .os_tag = .openbsd, .cpu_arch = .x86_64                         }),
        b.resolveTargetQuery(.{ .os_tag = .haiku,   .cpu_arch = .x86_64                         }),
        b.resolveTargetQuery(.{ .os_tag = .solaris, .cpu_arch = .x86_64                         }),
        //zig fmt: on
    };
}
