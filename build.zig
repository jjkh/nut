const std = @import("std");

// NOTE: temporary workaround for features not yet available in Zig 0.14.1
const zig_version = @import("builtin").zig_version;
const post_writergate = zig_version.major > 0 or zig_version.minor >= 15;

const version = if (post_writergate)
    std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable
else
    std.SemanticVersion{ .major = 2, .minor = 8, .patch = 3 };

pub fn build(b: *std.Build) !void {
    const upstream = b.dependency("nut", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const common_dir = upstream.path("common");
    const include_dir = upstream.path("include");
    const drivers_dir = upstream.path("drivers");

    // dependencies
    const libusb1_0 = b.dependency("libusb", .{
        .target = target,
        .optimize = optimize,
        .@"system-libudev" = false,
    }).artifact("usb");
    const maybe_libregex = createLibRegex(b, target, optimize);

    const version_str = std.fmt.comptimePrint(if (post_writergate) "{f}" else "{}", .{version});
    const nut_version_header = b.addConfigHeader(.{
        .style = .blank,
        .include_path = "nut_version.h",
    }, .{
        .NUT_VERSION_MACRO = version_str,
        .NUT_VERSION_SEMVER_MACRO = version_str,
        .NUT_VERSION_IS_RELEASE = 1,
        .NUT_VERSION_IS_PRERELEASE = 0,
    });

    const config_header = createConfigHeaderStep(
        b,
        include_dir.path(b, "config.h.in"),
        target.result,
    );

    // TODO: support specifying the drivers to build
    for (driver_sources.keys()) |driver_name| {
        const driver_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        // common
        driver_mod.addIncludePath(nut_version_header.getOutput().dirname());
        driver_mod.addIncludePath(config_header.getOutput().dirname());
        driver_mod.addIncludePath(include_dir);
        driver_mod.addIncludePath(common_dir);
        driver_mod.addCSourceFiles(.{ .files = common_src_files, .root = common_dir });
        driver_mod.addCSourceFiles(.{ .files = common_driver_sources, .root = drivers_dir });
        // driver-specific
        const opts = driver_sources.get(driver_name).?;
        if (opts.linux_only and target.result.os.tag != .linux) {
            std.log.info("skipping {s} - linux-only driver", .{driver_name});
            continue;
        }
        if (opts.reqs.contains(.snmp)) {
            std.log.warn("skipping {s} - SNMP not yet supported", .{driver_name});
            continue;
        }
        if (opts.reqs.contains(.neon)) {
            std.log.warn("skipping {s} - NEON not yet supported", .{driver_name});
            continue;
        }
        if (opts.reqs.contains(.powerman)) {
            std.log.warn("skipping {s} - NEON not yet supported", .{driver_name});
            continue;
        }
        if (opts.reqs.contains(.ipmi)) {
            std.log.warn("skipping {s} - IMPI not yet supported", .{driver_name});
            continue;
        }
        if (opts.reqs.contains(.macos) and !@import("builtin").os.tag.isDarwin()) {
            std.log.warn("skipping {s} - can't link macos framework on non-mac system", .{driver_name});
            continue;
        }
        if (opts.reqs.contains(.modbus)) {
            std.log.warn("skipping {s} - modbus not yet supported", .{driver_name});
            continue;
        }
        if (opts.reqs.contains(.gpio)) {
            std.log.warn("skipping {s} - GPIO not yet supported", .{driver_name});
            continue;
        }
        if (opts.reqs.contains(.i2c)) {
            std.log.warn("skipping {s} - I2C not yet supported", .{driver_name});
            continue;
        }
        driver_mod.addCSourceFiles(.{ .files = opts.files, .root = drivers_dir });
        for (opts.additional_include_paths) |include_path|
            driver_mod.addIncludePath(upstream.path(include_path));
        for (opts.additional_defines) |def|
            driver_mod.addCMacro(def[0], def[1]);
        if (target.result.os.tag == .windows) {
            if (maybe_libregex) |libregex| driver_mod.linkLibrary(libregex);
            driver_mod.linkSystemLibrary("Ws2_32", .{});
            if (opts.reqs.contains(.strsep))
                driver_mod.addCSourceFile(.{ .file = common_dir.path(b, "strsep.c") });
        }
        if (opts.reqs.contains(.usb)) {
            driver_mod.linkLibrary(libusb1_0);
            driver_mod.addCSourceFile(.{ .file = drivers_dir.path(b, "usb-common.c") });
        }
        if (opts.reqs.contains(.use_libusb1))
            driver_mod.addCSourceFile(.{ .file = drivers_dir.path(b, "libusb1.c") });

        if (opts.reqs.contains(.main)) driver_mod.addCSourceFile(.{ .file = drivers_dir.path(b, "main.c") });
        if (opts.reqs.contains(.serial)) driver_mod.addCSourceFile(.{ .file = drivers_dir.path(b, "serial.c") });

        // install output
        const install_driver = b.addInstallArtifact(
            b.addExecutable(.{ .name = driver_name, .root_module = driver_mod }),
            .{ .dest_dir = .{ .override = .{ .custom = "bin/drivers" } } },
        );
        b.getInstallStep().dependOn(&install_driver.step);
    }
}

fn createLibRegex(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*std.Build.Step.Compile {
    if (b.lazyDependency("mingw-regex", .{})) |regex_dep| {
        const regex_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        regex_mod.addIncludePath(regex_dep.path(""));
        regex_mod.addCSourceFile(.{ .file = regex_dep.path("regex.c") });

        const regex_lib = b.addLibrary(.{ .name = "mingw-regex", .root_module = regex_mod });
        regex_lib.installHeader(regex_dep.path("regex.h"), "regex.h");
        return regex_lib;
    }

    return null;
}

const Requirements = enum {
    usb,
    serial,
    snmp,
    neon,
    powerman,
    ipmi,
    macos,
    modbus,
    i2c,
    gpio,
    // common includes
    main,
    use_libusb1,
    strsep,
};
const DriverOptions = struct {
    files: []const []const u8,
    reqs: std.EnumSet(Requirements) = serial_reqs,
    linux_only: bool = false,
    additional_include_paths: []const []const u8 = &.{},
    additional_defines: []const [2][]const u8 = &.{},

    pub const serial_reqs = std.EnumSet(Requirements).initMany(&.{ .main, .serial });
    pub const usb_reqs = std.EnumSet(Requirements).initMany(&.{ .main, .usb, .use_libusb1 });
};

const common_driver_sources = &.{
    "dstate.c",
    "upsdrvquery.c",
};

const driver_sources = std.StaticStringMap(DriverOptions).initComptime(.{
    // serial drivers
    .{ "al175", DriverOptions{ .files = &.{"al175.c"} } },
    .{ "apcsmart", DriverOptions{ .files = &.{ "apcsmart.c", "apcsmart_tabs.c" } } },
    .{ "bcmxcp", DriverOptions{ .files = &.{ "bcmxcp.c", "bcmxcp_ser.c" } } },
    .{ "belkin", DriverOptions{ .files = &.{"belkin.c"} } },
    .{ "belkinunv", DriverOptions{ .files = &.{"belkinunv.c"} } },
    .{ "bestfcom", DriverOptions{ .files = &.{"bestfcom.c"} } },
    .{ "bestfortress", DriverOptions{ .files = &.{"bestfortress.c"} } },
    .{ "bestuferrups", DriverOptions{ .files = &.{"bestuferrups.c"} } },
    .{ "bestups", DriverOptions{ .files = &.{"bestups.c"} } },
    .{ "blazer_ser", DriverOptions{ .files = &.{ "blazer.c", "blazer_ser.c" } } },
    .{ "etapro", DriverOptions{ .files = &.{"etapro.c"} } },
    .{ "everups", DriverOptions{ .files = &.{"everups.c"} } },
    .{ "gamatronic", DriverOptions{ .files = &.{"gamatronic.c"} } },
    .{ "genericups", DriverOptions{ .files = &.{"genericups.c"} } },
    .{ "isbmex", DriverOptions{ .files = &.{"isbmex.c"} } },
    .{ "ivtscd", DriverOptions{ .files = &.{"ivtscd.c"} } },
    .{ "liebert", DriverOptions{ .files = &.{"liebert.c"} } },
    .{ "liebert_esp2", DriverOptions{ .files = &.{"liebert-esp2.c"} } },
    .{ "liebert_gxe", DriverOptions{ .files = &.{"liebert-gxe.c"} } },
    .{ "masterguard", DriverOptions{ .files = &.{"masterguard.c"} } },
    .{ "metasys", DriverOptions{ .files = &.{"metasys.c"} } },
    .{ "mge_utalk", DriverOptions{ .files = &.{"mge-utalk.c"} } },
    .{ "microdowell", DriverOptions{ .files = &.{"microdowell.c"} } },
    .{ "microsol_apc", DriverOptions{ .files = &.{ "microsol-apc.c", "microsol-common.c" } } },
    .{ "nhs_ser", DriverOptions{
        .files = &.{"nhs_ser.c"},
        .linux_only = true,
    } },
    .{ "nutdrv_hashx", DriverOptions{
        .files = &.{"nutdrv_hashx.c"},
        .reqs = DriverOptions.serial_reqs.unionWith(.initOne(.strsep)),
    } },
    .{ "oneac", DriverOptions{ .files = &.{"oneac.c"} } },
    .{ "optiups", DriverOptions{ .files = &.{"optiups.c"} } },
    .{ "powercom", DriverOptions{ .files = &.{"powercom.c"} } },
    .{ "powerpanel", DriverOptions{ .files = &.{ "powerpanel.c", "powerp-bin.c", "powerp-txt.c" } } },
    .{ "powervar_cx_ser", DriverOptions{
        .files = &.{ "powervar_cx_ser.c", "powervar_cx.c" },
        .additional_defines = &.{.{ "PVAR_USB", "1" }},
    } },
    .{ "rhino", DriverOptions{ .files = &.{"rhino.c"} } },
    .{ "safenet", DriverOptions{ .files = &.{"safenet.c"} } },
    .{ "nutdrv_siemens_sitop", DriverOptions{ .files = &.{"nutdrv_siemens_sitop.c"} } },
    .{ "solis", DriverOptions{ .files = &.{"solis.c"} } },
    .{ "tripplite", DriverOptions{ .files = &.{"tripplite.c"} } },
    .{ "tripplitesu", DriverOptions{ .files = &.{"tripplitesu.c"} } },
    .{ "upscode2", DriverOptions{ .files = &.{"upscode2.c"} } },
    .{ "victronups", DriverOptions{ .files = &.{"victronups.c"} } },
    .{ "riello_ser", DriverOptions{ .files = &.{ "riello.c", "riello_ser.c" } } },
    .{ "sms_ser", DriverOptions{ .files = &.{"sms_ser.c"} } },
    .{ "bicker_ser", DriverOptions{ .files = &.{"bicker_ser.c"} } },
    .{ "ve-direct", DriverOptions{ .files = &.{"ve-direct.c"} } },
    // dummy (NOTE: ssl option not yet supported)
    .{ "dummy", DriverOptions{
        .files = &.{ "dummy-ups.c", "../clients/upsclient.c" },
        .additional_include_paths = &.{"clients"},
    } },
    // clone drivers
    .{ "clone", DriverOptions{ .files = &.{"clone.c"} } },
    .{ "clone-outlet", DriverOptions{ .files = &.{"clone-outlet.c"} } },
    // failover driver
    .{ "failover", DriverOptions{ .files = &.{"failover.c"} } },
    // apcupsd client driver
    .{ "apcupsd-ups", DriverOptions{ .files = &.{"apcupsd-ups.c"} } },
    // sample skeleton driver
    .{ "skel", DriverOptions{ .files = &.{"skel.c"} } },
    // libusb drivers
    .{
        "usbhid-ups", DriverOptions{
            .files = &.{
                "usbhid-ups.c",
                // subdrivers
                "apc-hid.c",
                "arduino-hid.c",
                "belkin-hid.c",
                "cps-hid.c",
                "explore-hid.c",
                "liebert-hid.c",
                "mge-hid.c",
                "powercom-hid.c",
                "tripplite-hid.c",
                "idowell-hid.c",
                "openups-hid.c",
                "powervar-hid.c",
                "delta_ups-hid.c",
                "ecoflow-hid.c",
                "ever-hid.c",
                "legrand-hid.c",
                "salicru-hid.c",
                // common
                "libhid.c",
                "hidparser.c",
            },
            .reqs = DriverOptions.usb_reqs,
        },
    },
    .{ "powervar_cx_usb", DriverOptions{
        .files = &.{ "powervar_cx_usb.c", "powervar_cx.c" },
        .reqs = DriverOptions.usb_reqs,
        .additional_defines = &.{.{ "PVAR_USB", "1" }},
    } },
    .{ "tripplite_usb", DriverOptions{ .files = &.{"tripplite_usb.c"}, .reqs = DriverOptions.usb_reqs } },
    .{ "bcmxcp_usb", DriverOptions{
        .files = &.{ "bcmxcp_usb.c", "bcmxcp.c" },
        .reqs = DriverOptions.usb_reqs.differenceWith(.initOne(.use_libusb1)),
    } },
    .{ "blazer_usb", DriverOptions{ .files = &.{ "blazer_usb.c", "blazer.c" }, .reqs = DriverOptions.usb_reqs } },
    .{ "nutdrv_atcl_usb", DriverOptions{ .files = &.{"nutdrv_atcl_usb.c"}, .reqs = DriverOptions.usb_reqs } },
    .{ "richcomm_usb", DriverOptions{ .files = &.{"richcomm_usb.c"}, .reqs = DriverOptions.usb_reqs } },
    .{ "riello_usb", DriverOptions{ .files = &.{ "riello_usb.c", "riello.c" }, .reqs = DriverOptions.usb_reqs } },
    // HID-over-serial
    .{ "mge_shut", DriverOptions{
        .files = &.{
            "usbhid-ups.c",
            "libshut.c",
            "libhid.c",
            "hidparser.c",
            "mge-hid.c",
        },
        .additional_defines = &.{.{ "SHUT_MODE", "1" }},
    } },
    // SNMP
    .{ "snmp-ups", DriverOptions{
        .files = &.{
            "snmp-ups.c",
            "snmp-ups-helpers.c",
            "apc-mib.c",
            "apc-pdu-mib.c",
            "apc-epdu-mib.c",
            "baytech-mib.c",
            "baytech-rpc3nc-mib.c",
            "bestpower-mib.c",
            "compaq-mib.c",
            "cyberpower-mib.c",
            "delta_ups-mib.c",
            "eaton-pdu-genesis2-mib.c",
            "eaton-pdu-marlin-mib.c",
            "eaton-pdu-marlin-helpers.c",
            "eaton-pdu-pulizzi-mib.c",
            "eaton-pdu-revelation-mib.c",
            "eaton-pdu-nlogic-mib.c",
            "eaton-ats16-nmc-mib.c",
            "eaton-ats16-nm2-mib.c",
            "apc-ats-mib.c",
            "eaton-ats30-mib.c",
            "eaton-ups-pwnm2-mib.c",
            "eaton-ups-pxg-mib.c",
            "emerson-avocent-pdu-mib.c",
            "hpe-pdu-mib.c",
            "hpe-pdu3-cis-mib.c",
            "huawei-mib.c",
            "ietf-mib.c",
            "mge-mib.c",
            "netvision-mib.c",
            "raritan-pdu-mib.c",
            "raritan-px2-mib.c",
            "xppc-mib.c",
        },
        .reqs = .initMany(&.{ .main, .snmp }),
    } },
    // NEON XML/HTTP
    .{ "netxml-ups", DriverOptions{
        .files = &.{ "netxml-ups.c", "mge-xml.c" },
        .reqs = .initMany(&.{ .main, .neon }),
    } },
    // powerman
    .{ "powerman-pdu", DriverOptions{
        .files = &.{"powerman-pdu.c"},
        .reqs = .initMany(&.{ .main, .powerman }),
    } },
    // IPMI PSU
    .{ "nut-ipmipsu", DriverOptions{
        .files = &.{"nut-ipmipsu.c"},
        .reqs = .initMany(&.{ .main, .ipmi }),
    } },
    // Mac OS X metadriver
    .{ "macosx-ups", DriverOptions{
        .files = &.{"macosx-ups.c"},
        .reqs = .initMany(&.{ .main, .macos }),
    } },
    // modbus drivers
    .{ "phoenixcontact_modbus", DriverOptions{
        .files = &.{"phoenixcontact_modbus.c"},
        .reqs = .initMany(&.{ .main, .modbus }),
    } },
    .{ "generic_modbus", DriverOptions{
        .files = &.{"generic_modbus.c"},
        .reqs = .initMany(&.{ .main, .modbus }),
    } },
    .{ "adelsystem_cbi", DriverOptions{
        .files = &.{"adelsystem_cbi.c"},
        .reqs = .initMany(&.{ .main, .modbus }),
    } },
    .{ "socomec_jbus", DriverOptions{
        .files = &.{"socomec_jbus.c"},
        .reqs = .initMany(&.{ .main, .modbus }),
    } },
    // APC Modbus driver
    .{ "apc_modbus", DriverOptions{
        .files = &.{"apc_modbus.c"},
        .reqs = .initMany(&.{ .main, .modbus }),
    } },
    // Huawei UPS2000 driver (both a Modbus and a serial driver)
    .{ "huawei-ups2000", DriverOptions{
        .files = &.{"huawei-ups2000.c"},
        .reqs = .initMany(&.{ .main, .modbus, .serial }),
    } },
    // linux I2C drivers
    .{ "asem", DriverOptions{
        .files = &.{"asem.c"},
        .reqs = .initMany(&.{ .main, .i2c }),
        .linux_only = true,
    } },
    .{ "pijuice", DriverOptions{
        .files = &.{"pijuice.c"},
        .reqs = .initMany(&.{ .main, .i2c }),
        .linux_only = true,
    } },
    .{ "hwmon_ina219", DriverOptions{
        .files = &.{"hwmon_ina219.c"},
        .reqs = .initOne(.main),
        .linux_only = true,
    } },
    // GPIO drivers
    .{ "generic_gpio_libgpiod", DriverOptions{
        .files = &.{ "generic_gpio_common.c", "generic_gpio_libgpiod.c" },
        .reqs = .initMany(&.{ .main, .gpio }),
    } },
    // nutdrv_qx USB/Serial
    .{ "nutdrv_qx", DriverOptions{
        .files = &.{
            "nutdrv_qx.c",
            "nutdrv_qx_bestups.c",
            "nutdrv_qx_blazer-common.c",
            "nutdrv_qx_innovart31.c",
            "nutdrv_qx_innovart33.c",
            "nutdrv_qx_masterguard.c",
            "nutdrv_qx_mecer.c",
            "nutdrv_qx_megatec.c",
            "nutdrv_qx_megatec-old.c",
            "nutdrv_qx_mustek.c",
            "nutdrv_qx_q1.c",
            "nutdrv_qx_q2.c",
            "nutdrv_qx_q6.c",
            "nutdrv_qx_voltronic.c",
            "common_voltronic-crc.c",
            "nutdrv_qx_voltronic-axpert.c",
            "nutdrv_qx_voltronic-qs.c",
            "nutdrv_qx_voltronic-qs-hex.c",
            "nutdrv_qx_zinto.c",
            "nutdrv_qx_hunnox.c",
            "nutdrv_qx_ablerex.c",
            "nutdrv_qx_gtec.c",
        },
        .reqs = .initMany(&.{ .main, .usb, .use_libusb1, .serial }),
    } },
});

const common_src_files: []const []const u8 = &.{
    "common.c",
    "common-nut_version.c",
    "parseconf.c",
    "upsconf.c",
    "state.c",
    "str.c",
    "setenv.c",
    "wincompat.c",
};

fn createConfigHeaderStep(
    b: *std.Build,
    input_file: std.Build.LazyPath,
    target: std.Target,
) *std.Build.Step.ConfigHeader {
    const is_windows = target.os.tag == .windows;

    const opts = .{
        // default dirs
        .ALTPIDPATH = "/var/state/ups",
        .BINDIR = "/usr/local/ups/bin",
        .CGIPATH = "/usr/local/ups/cgi-bin",
        .CONFPATH = "/usr/local//ups/etc",
        .DRVPATH = "/usr/local/ups/bin",
        .HTMLPATH = "/usr/local/ups/html",
        .LIBDIR = "/usr/local/ups/lib",
        .LIBEXECDIR = "/usr/local/ups/libexec",
        .LT_OBJDIR = ".libs/", // TODO required?
        .NUT_DATADIR = "/usr/local/ups/share",
        .NUT_MANDIR = "/usr/local/ups/share/man",
        .PIDPATH = "/var/run",
        .PREFIX = "/usr/local/ups",
        .SBINDIR = "/usr/local/ups/sbin",
        .STATEPATH = "/var/state/ups",

        // build options (TODO support configuration)
        .LOG_FACILITY = .LOG_DAEMON,
        .CONFIG_FLAGS = "",
        .PORT = 3493,
        .RUN_AS_GROUP = "nobody",
        .RUN_AS_USER = "nobody",
        .WITH_ASCIIDOC = null,
        .WITH_AVAHI = null,
        .WITH_CGI = null,
        .WITH_DEV = null,
        .WITH_DEV_LIBNUTCONF = null,
        .WITH_DOCS = null,
        .WITH_FREEIPMI = null,
        .WITH_GPIO = null,
        .WITH_IPMI = null,
        .WITH_LIBGPIO_VERSION = 0x00000000,
        .WITH_LIBGPIO_VERSION_STR = "0x00000000",
        .WITH_LIBLTDL = null,
        .WITH_LIBPOWERMAN = null,
        .WITH_LIBSYSTEMD = null,
        .WITH_LIBSYSTEMD_INHIBITOR = 0,
        .WITH_LIBUSB_0_1 = 0,
        .WITH_LIBUSB_1_0 = 1,
        .WITH_LINUX_I2C = null,
        .WITH_MODBUS = null,
        .WITH_NEON = null,
        .WITH_NSS = null,
        .WITH_NUTCONF = null,
        .WITH_NUT_MONITOR = null,
        .WITH_NUT_SCANNER = null,
        .WITH_OPENSSL = null,
        .WITH_PYNUT = null,
        .WITH_SERIAL = 1,
        .WITH_SNMP = null,
        .WITH_SNMP_STATIC = null,
        .WITH_SOLARIS_SMF = null,
        .WITH_SPELLCHECK = null,
        .WITH_SSL = null,
        .WITH_UNMAPPED_DATA_POINTS = 0,
        .WITH_USB = 1,
        .WITH_USB_BUSPORT = 0,
        .WITH_WRAP = null,
        .MAN_DIR_AS_BASE = null,

        // build info
        .NUT_NETVERSION = "1.3", // TODO get this from somewhere?
        .NUT_WEBSITE_BASE = "https://www.networkupstools.org/historic/v2.8.3",
        .PACKAGE = "nut",
        .PACKAGE_BUGREPORT = "https://github.com/networkupstools/nut/issues",
        .PACKAGE_NAME = "nut",
        .PACKAGE_STRING = "nut 2.8.3", // TODO get this from somewhere?
        .PACKAGE_TARNAME = "nut",
        .PACKAGE_URL = "https://www.networkupstools.org/historic/v2.8.3/index.html",
        .PACKAGE_VERSION = "2.8.3", // TODO get this from somewhere?
        .TREE_VERSION = "2.8",
        .VERSION = "2.8.3",

        // compiler and build system details
        .AC_APPLE_UNIVERSAL_BUILD = null,
        // TODO generate during the build?
        .CC_VERSION = "clang version 20.1.2 (https://github.com/ziglang/zig-bootstrap de424301411b3a34a8a908d8dca01a1d29f2c6df); Target: x86_64-unknown-windows-gnu; Thread model: posix",
        .CPP_VERSION = "clang version 20.1.2 (https://github.com/ziglang/zig-bootstrap de424301411b3a34a8a908d8dca01a1d29f2c6df); Target: x86_64-unknown-windows-gnu; Thread model: posix",
        .CXX_VERSION = "clang version 20.1.2 (https://github.com/ziglang/zig-bootstrap de424301411b3a34a8a908d8dca01a1d29f2c6df); Target: x86_64-unknown-windows-gnu; Thread model: posix",
        .CXX_NO_MINUS_C_MINUS_O = null,
        .FLEXIBLE_ARRAY_MEMBER = .@"/**/",
        .HAVE_PRAGMAS_FOR_GCC_DIAGNOSTIC_IGNORED_CXX98_COMPAT = 1,
        .HAVE_PRAGMAS_FOR_GCC_DIAGNOSTIC_IGNORED_CXX98_COMPAT_BESIDEFUNC = 1,
        .HAVE_PRAGMAS_FOR_GCC_DIAGNOSTIC_IGNORED_FORMAT_NONLITERAL = 1,
        .HAVE_PRAGMAS_FOR_GCC_DIAGNOSTIC_IGNORED_FORMAT_NONLITERAL_BESIDEFUNC = 1,
        .HAVE_PRAGMAS_FOR_GCC_DIAGNOSTIC_IGNORED_FORMAT_TRUNCATION = 1,
        .HAVE_PRAGMAS_FOR_GCC_DIAGNOSTIC_IGNORED_FORMAT_TRUNCATION_BESIDEFUNC = 1,
        .HAVE_PRAGMAS_FOR_GCC_DIAGNOSTIC_IGNORED_UNREACHABLE_CODE = 1,
        .HAVE_PRAGMAS_FOR_GCC_DIAGNOSTIC_IGNORED_UNREACHABLE_CODE_BESIDEFUNC = 1,
        .HAVE_PRAGMA_CLANG_DIAGNOSTIC_IGNORED_DEPRECATED_DECLARATIONS = null,
        .HAVE_PRAGMA_CLANG_DIAGNOSTIC_IGNORED_DEPRECATED_DECLARATIONS_BESIDEFUNC = null,
        .HAVE_PRAGMA_CLANG_DIAGNOSTIC_IGNORED_UNREACHABLE_CODE_RETURN = null,
        .HAVE_PRAGMA_CLANG_DIAGNOSTIC_IGNORED_UNREACHABLE_CODE_RETURN_BESIDEFUNC = null,
        .HAVE_PRAGMA_CLANG_DIAGNOSTIC_PUSH_POP = 1,
        .HAVE_PRAGMA_CLANG_DIAGNOSTIC_PUSH_POP_BESIDEFUNC = 1,
        .HAVE_PRAGMA_CLANG_DIAGNOSTIC_PUSH_POP_INSIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_ADDRESS = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_ADDRESS_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_ARRAY_BOUNDS = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_ARRAY_BOUNDS_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_ASSIGN_ENUM = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_ASSIGN_ENUM_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_CAST_ALIGN = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_CAST_ALIGN_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_CAST_FUNCTION_TYPE_STRICT = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_CAST_FUNCTION_TYPE_STRICT_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_COVERED_SWITCH_DEFAULT = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_COVERED_SWITCH_DEFAULT_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_CXX98_COMPAT = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_CXX98_COMPAT_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_CXX98_COMPAT_PEDANTIC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_CXX98_COMPAT_PEDANTIC_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_DEPRECATED_DECLARATIONS = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_DEPRECATED_DYNAMIC_EXCEPTION_SPEC_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_EXIT_TIME_DESTRUCTORS = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_EXIT_TIME_DESTRUCTORS_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_EXTRA_SEMI_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_EXTRA_SEMI_STMT = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_EXTRA_SEMI_STMT_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_FORMAT = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_FORMAT_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_FORMAT_EXTRA_ARGS = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_FORMAT_EXTRA_ARGS_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_FORMAT_NONLITERAL = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_FORMAT_NONLITERAL_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_FORMAT_OVERFLOW = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_FORMAT_OVERFLOW_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_FORMAT_SECURITY = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_FORMAT_SECURITY_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_FORMAT_TRUNCATION = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_FORMAT_TRUNCATION_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_GLOBAL_CONSTRUCTORS = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_GLOBAL_CONSTRUCTORS_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_MAYBE_UNINITIALIZED = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_MAYBE_UNINITIALIZED_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_OLD_STYLE_CAST_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_PEDANTIC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_PEDANTIC_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_SIGN_COMPARE = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_SIGN_COMPARE_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_SIGN_CONVERSION = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_SIGN_CONVERSION_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_STRICT_PROTOTYPES = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_STRICT_PROTOTYPES_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_STRINGOP_TRUNCATION = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_STRINGOP_TRUNCATION_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_SUGGEST_DESTRUCTOR_OVERRIDE_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_SUGGEST_OVERRIDE_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_TAUTOLOGICAL_COMPARE = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_TAUTOLOGICAL_COMPARE_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_TAUTOLOGICAL_CONSTANT_OUT_OF_RANGE_COMPARE = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_TAUTOLOGICAL_CONSTANT_OUT_OF_RANGE_COMPARE_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_TAUTOLOGICAL_TYPE_LIMIT_COMPARE = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_TAUTOLOGICAL_TYPE_LIMIT_COMPARE_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_TAUTOLOGICAL_UNSIGNED_ZERO_COMPARE = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_TAUTOLOGICAL_UNSIGNED_ZERO_COMPARE_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_TYPE_LIMITS = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_TYPE_LIMITS_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_UNREACHABLE_CODE = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_UNREACHABLE_CODE_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_UNREACHABLE_CODE_BREAK = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_UNREACHABLE_CODE_BREAK_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_UNREACHABLE_CODE_RETURN = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_UNREACHABLE_CODE_RETURN_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_UNUSED_FUNCTION = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_UNUSED_PARAMETER = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_WEAK_VTABLES_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_IGNORED_ZERO_AS_NULL_POINTER_CONSTANT_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_PUSH_POP = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_PUSH_POP_BESIDEFUNC = 1,
        .HAVE_PRAGMA_GCC_DIAGNOSTIC_PUSH_POP_INSIDEFUNC = 1,
        .HAVE___ATTRIBUTE__ = 1,
        .HAVE___ATTRIBUTE__NORETURN = 1,
        .HAVE___ATTRIBUTE__UNUSED_ARG = 1,
        .HAVE___ATTRIBUTE__UNUSED_FUNC = 1,
        .STDC_HEADERS = 1,
        .TIME_WITH_SYS_TIME = 1,
        ._ALL_SOURCE = 1,
        ._GNU_SOURCE = 1,
        ._POSIX_PTHREAD_SEMANTICS = 1,
        ._TANDEM_SOURCE = 1,
        .__EXTENSIONS__ = 1,
        .HAVE_STDIO_H = 1,
        .HAVE_VA_COPY = 1,
        .HAVE_VA_COPY_VARIANT = 1,
        .HAVE_WCHAR_H = 1,
        .HAVE___VA_COPY = 1,
        .__STDC_WANT_IEC_60559_ATTRIBS_EXT__ = 1,
        .__STDC_WANT_IEC_60559_BFP_EXT__ = 1,
        .__STDC_WANT_IEC_60559_DFP_EXT__ = 1,
        .__STDC_WANT_IEC_60559_FUNCS_EXT__ = 1,
        .__STDC_WANT_IEC_60559_TYPES_EXT__ = 1,
        .__STDC_WANT_LIB_EXT2__ = 1,
        .__STDC_WANT_MATH_SPEC_FUNCS__ = 1,
        .__STDC_NO_VLA__ = null,
        ._XOPEN_SOURCE = null,
        ._MINIX = null,
        ._POSIX_1_SOURCE = null,
        ._POSIX_SOURCE = null,
        ._UINT32_T = null,
        ._UINT64_T = null,
        ._UINT8_T = null,
        .__func__ = null,
        .@"inline" = null,
        .int16_t = null,
        .int32_t = null,
        .int64_t = null,
        .int8_t = null,
        .intmax_t = null,
        .size_t = null,
        .socklen_t = null,
        .ssize_t = null,
        .uint16_t = null,
        .uint32_t = null,
        .uint64_t = null,
        .uint8_t = null,
        .uintmax_t = null,

        // target-specific defines
        .CPU_TYPE = @tagName(target.cpu.arch),
        .HAVE_IPHLPAPI_H = defFromBool(is_windows),
        .HAVE_WINDOWS_H = defFromBool(is_windows),
        .HAVE_WINSOCK2_H = defFromBool(is_windows),
        .HAVE_WS2TCPIP_H = defFromBool(is_windows),
        .WINDOWS_SOCKETS = defFromBool(is_windows),
        .HAVE_CFSETISPEED = defFromBool(!is_windows),
        .HAVE_DECL_LOCALTIME_R = @intFromBool(!is_windows),
        .HAVE_DECL_LOCALTIME_S = @intFromBool(is_windows),
        .HAVE_POLL_H = defFromBool(!is_windows),
        .HAVE_SETENV = defFromBool(!is_windows),
        .HAVE_SETEUID = defFromBool(!is_windows),
        .HAVE_STRPTIME = defFromBool(!is_windows and !target.abi.isGnu()),
        .HAVE_STRSEP = defFromBool(!is_windows),
        .HAVE_STRUCT_POLLFD = defFromBool(is_windows),
        .HAVE_SYS_SELECT_H = defFromBool(!is_windows),
        .HAVE_SYS_SIGNAL_H = defFromBool(!is_windows),
        .HAVE_SYS_SOCKET_H = defFromBool(!is_windows),
        .HAVE_UNSETENV = defFromBool(!is_windows),
        .WITH_MACOSX = defFromBool(target.os.tag.isDarwin()),
        .WORDS_BIGENDIAN = defFromBool(target.cpu.arch.endian() == .big),
        ._DARWIN_C_SOURCE = defFromBool(target.os.tag.isDarwin()),
        ._NETBSD_SOURCE = defFromBool(target.os.tag == .netbsd),
        ._OPENBSD_SOURCE = defFromBool(target.os.tag == .openbsd),

        // TODO: need checking for cross-compilation
        // current values generated by autoconf on mingw64
        .FOUND_BOOLEAN_IMPLEM_STR = null,
        .FOUND_BOOLEAN_TYPE = null,
        .FOUND_BOOLEAN_VALUE_FALSE = null,
        .FOUND_BOOLEAN_VALUE_TRUE = null,
        .FOUND_BOOL_IMPLEM_STR = "number",
        .FOUND_BOOL_TYPE = .bool,
        .FOUND_BOOL_T_IMPLEM_STR = null,
        .FOUND_BOOL_T_TYPE = null,
        .FOUND_BOOL_T_VALUE_FALSE = null,
        .FOUND_BOOL_T_VALUE_TRUE = null,
        .FOUND_BOOL_VALUE_FALSE = .false,
        .FOUND_BOOL_VALUE_TRUE = .true,
        .FOUND__BOOL_IMPLEM_STR = "number",
        .FOUND__BOOL_TYPE = ._Bool,
        .FOUND__BOOL_VALUE_FALSE = .false,
        .FOUND__BOOL_VALUE_TRUE = .true,
        .GETNAMEINFO_TYPE_ARG1 = .@"const struct sockaddr *",
        .GETNAMEINFO_TYPE_ARG2 = .socklen_t,
        .GETNAMEINFO_TYPE_ARG46 = .DWORD, // almost certainly windows-only
        .GETNAMEINFO_TYPE_ARG7 = .int,
        .HAVE_ABS = 1,
        .HAVE_ABS_VAL = null,
        .HAVE_ATEXIT = 1,
        .HAVE_AVAHI_CLIENT_CLIENT_H = null,
        .HAVE_AVAHI_CLIENT_NEW = null,
        .HAVE_AVAHI_COMMON_MALLOC_H = null,
        .HAVE_AVAHI_FREE = null,
        .HAVE_BOOLEAN_IMPLEM_ENUM = null,
        .HAVE_BOOLEAN_IMPLEM_INT = null,
        .HAVE_BOOLEAN_IMPLEM_MACRO = null,
        .HAVE_BOOLEAN_TYPE_CAMELCASE = null,
        .HAVE_BOOLEAN_TYPE_LOWERCASE = null,
        .HAVE_BOOLEAN_TYPE_UPPERCASE = null,
        .HAVE_BOOLEAN_VALUE_CAMELCASE = null,
        .HAVE_BOOLEAN_VALUE_LOWERCASE = null,
        .HAVE_BOOLEAN_VALUE_UPPERCASE = null,
        .HAVE_BOOL_IMPLEM_ENUM = null,
        .HAVE_BOOL_IMPLEM_INT = 1,
        .HAVE_BOOL_IMPLEM_MACRO = null,
        .HAVE_BOOL_TYPE_CAMELCASE = null,
        .HAVE_BOOL_TYPE_LOWERCASE = 1,
        .HAVE_BOOL_TYPE_UPPERCASE = null,
        .HAVE_BOOL_T_IMPLEM_ENUM = null,
        .HAVE_BOOL_T_IMPLEM_INT = null,
        .HAVE_BOOL_T_IMPLEM_MACRO = null,
        .HAVE_BOOL_T_TYPE_CAMELCASE = null,
        .HAVE_BOOL_T_TYPE_LOWERCASE = null,
        .HAVE_BOOL_T_TYPE_UPPERCASE = null,
        .HAVE_BOOL_T_VALUE_CAMELCASE = null,
        .HAVE_BOOL_T_VALUE_LOWERCASE = null,
        .HAVE_BOOL_T_VALUE_UPPERCASE = null,
        .HAVE_BOOL_VALUE_CAMELCASE = null,
        .HAVE_BOOL_VALUE_LOWERCASE = 1,
        .HAVE_BOOL_VALUE_UPPERCASE = null,
        .HAVE_CLOCK_GETTIME = 1,
        .HAVE_CLOCK_MONOTONIC = 1,
        .HAVE_CPPUNIT = null, // TODO: support tests?
        .HAVE_CSTDBOOL = null,
        .HAVE_CXX11 = 1,
        .HAVE_C_VARARRAYS = 1,
        .HAVE_DECL_FABS = 1,
        .HAVE_DECL_FABSF = 1,
        .HAVE_DECL_FABSL = 1,
        .HAVE_DECL_GMTIME_R = 0,
        .HAVE_DECL_GMTIME_S = 1,
        .HAVE_DECL_I2C_SMBUS_ACCESS = null,
        .HAVE_DECL_I2C_SMBUS_READ_BLOCK_DATA = null,
        .HAVE_DECL_I2C_SMBUS_READ_BYTE_DATA = null,
        .HAVE_DECL_I2C_SMBUS_READ_WORD_DATA = null,
        .HAVE_DECL_I2C_SMBUS_WRITE_BYTE_DATA = null,
        .HAVE_DECL_I2C_SMBUS_WRITE_WORD_DATA = null,
        .HAVE_DECL_LOG_UPTO = 0,
        .HAVE_DECL_OPTIND = 1,
        .HAVE_DECL_POW10 = 0,
        .HAVE_DECL_REALPATH = 0,
        .HAVE_DECL_REGCOMP = 1, // TODO: make regex support optional?
        .HAVE_DECL_REGEXEC = 1,
        .HAVE_DECL_ROUND = 1,
        .HAVE_DECL_TIMEGM = 0,
        .HAVE_DECL_UU_LOCK = 0,
        .HAVE_DECL__MKGMTIME = 1,
        .HAVE_DECL___FUNCTION__ = null,
        .HAVE_DECL___FUNC__ = 1,
        .HAVE_DLFCN_H = null,
        .HAVE_DUP = 1,
        .HAVE_DUP2 = 1,
        .HAVE_FCNTL_H = 1,
        .HAVE_FCVT = 1,
        .HAVE_FCVTL = null,
        .HAVE_FILENO = 1,
        .HAVE_FLOAT_H = 1,
        .HAVE_FLOCK = null,
        .HAVE_FREEIPMI = null,
        .HAVE_FREEIPMI_11X_12X = null,
        .HAVE_FREEIPMI_FREEIPMI_H = null,
        .HAVE_FREEIPMI_MONITORING = null,
        .HAVE_GDFONTMB_H = null,
        .HAVE_GD_H = null,
        .HAVE_GETADAPTERSADDRESSES = null,
        .HAVE_GETADAPTERSINFO = 1,
        .HAVE_GETIFADDRS = null,
        .HAVE_GETOPT_H = 1,
        .HAVE_GETOPT_LONG = 1,
        .HAVE_GETPASSPHRASE = null,
        .HAVE_GMTIME_R = null,
        .HAVE_GMTIME_S = null,
        .HAVE_GPIOD_CHIP_CLOSE = null,
        .HAVE_GPIOD_CHIP_OPEN = null,
        .HAVE_GPIOD_CHIP_OPEN_BY_NAME = null,
        .HAVE_GPIOD_H = null,
        .HAVE_IFADDRS_H = null,
        .HAVE_INET_NTOP = 1,
        .HAVE_INET_PTON = 1,
        .HAVE_INIT_SNMP = null, // TODO: support net-snmp
        .HAVE_INTMAX_T = 1,
        .HAVE_INTTYPES_H = 1,
        .HAVE_IPMI_MONITORING_H = null,
        .HAVE_LIBGD = null,
        .HAVE_LIBLTDL = null,
        .HAVE_LIBPOWERMAN_H = null,
        .HAVE_LIBREGEX = 1,
        .HAVE_LIBUSB_DETACH_KERNEL_DRIVER = null, // TODO: support libusb kernel driver?
        .HAVE_LIBUSB_DETACH_KERNEL_DRIVER_NP = null,
        .HAVE_LIBUSB_GET_PORT_NUMBER = 1, // TODO: make libusb support optional?
        .HAVE_LIBUSB_H = 1,
        .HAVE_LIBUSB_INIT = 1,
        .HAVE_LIBUSB_KERNEL_DRIVER_ACTIVE = null,
        .HAVE_LIBUSB_SET_AUTO_DETACH_KERNEL_DRIVER = null,
        .HAVE_LIBUSB_STRERROR = 1,
        .HAVE_LIB_BSD_KVM_PROC = null,
        .HAVE_LIB_ILLUMOS_PROC = null,
        .HAVE_LIMITS_H = 1,
        .HAVE_LINUX_I2C_DEV_H = null,
        .HAVE_LINUX_SERIAL_H = null,
        .HAVE_LINUX_SMBUS_H = null,
        .HAVE_LOCALTIME_R = null,
        .HAVE_LOCALTIME_S = null,
        .HAVE_LOCKF = null,
        .HAVE_LONG_DOUBLE = null,
        .HAVE_LONG_LONG_INT = 1,
        .HAVE_LTDL_H = null,
        .HAVE_LUSB0_USB_H = null, // TODO: support libusb-0.1?
        .HAVE_MATH_H = 1,
        .HAVE_MODBUS_H = null, // TODO support modbus?
        .HAVE_MODBUS_NEW_RTU = null,
        .HAVE_MODBUS_NEW_RTU_USB = null,
        .HAVE_MODBUS_NEW_TCP = null,
        .HAVE_MODBUS_SET_BYTE_TIMEOUT = null,
        .HAVE_MODBUS_SET_RESPONSE_TIMEOUT = null,
        .HAVE_NETDB_H = null,
        .HAVE_NETINET_IN_H = null,
        .HAVE_NET_IF_H = null,
        .HAVE_NET_SNMP_NET_SNMP_CONFIG_H = null,
        .HAVE_NET_SNMP_NET_SNMP_INCLUDES_H = null,
        .HAVE_NE_SET_CONNECT_TIMEOUT = null,
        .HAVE_NE_SOCK_CONNECT_TIMEOUT = null,
        .HAVE_NE_XMLREQ_H = null,
        .HAVE_NE_XML_DISPATCH_REQUEST = null,
        .HAVE_NSS_H = null,
        .HAVE_NSS_INIT = null,
        .HAVE_ON_EXIT = null,
        .HAVE_OPENSSL_SSL_H = null,
        .HAVE_PM_CONNECT = null,
        .HAVE_PTHREAD = 1,
        .HAVE_PTHREAD_TRYJOIN = null,
        .HAVE_READLINK = null,
        .HAVE_REGEX_H = 1,
        .HAVE_SD_BOOTED = null,
        .HAVE_SD_BUS_CALL_METHOD = null,
        .HAVE_SD_BUS_DEFAULT_SYSTEM = null,
        .HAVE_SD_BUS_ERROR_FREE = null,
        .HAVE_SD_BUS_FLUSH_CLOSE_UNREF = null,
        .HAVE_SD_BUS_GET_PROPERTY_TRIVIAL = null,
        .HAVE_SD_BUS_MESSAGE_READ_BASIC = null,
        .HAVE_SD_BUS_MESSAGE_UNREF = null,
        .HAVE_SD_BUS_OPEN_SYSTEM = null,
        .HAVE_SD_BUS_OPEN_SYSTEM_WITH_DESCRIPTION = null,
        .HAVE_SD_BUS_SET_DESCRIPTION = null,
        .HAVE_SD_NOTIFY = null,
        .HAVE_SD_NOTIFY_BARRIER = null,
        .HAVE_SD_WATCHDOG_ENABLED = null,
        .HAVE_SEMAPHORE_H = 1,
        .HAVE_SEMAPHORE_NAMED = 1,
        .HAVE_SEMAPHORE_UNNAMED = 1,
        .HAVE_SETLOGMASK = null,
        .HAVE_SETSID = null,
        .HAVE_SIGACTION = null,
        .HAVE_SIGEMPTYSET = null,
        .HAVE_SIGNAL_H = 1,
        .HAVE_SNPRINTF = 1,
        .HAVE_SSL_CTX_NEW = null,
        .HAVE_SSL_H = null,
        .HAVE_STDARG_H = 1,
        .HAVE_STDBOOL_H = 1,
        .HAVE_STDINT_H = 1,
        .HAVE_STDLIB_H = 1,
        .HAVE_STRCASECMP = 1,
        .HAVE_STRCASESTR = null,
        .HAVE_STRDUP = 1,
        .HAVE_STRERROR = 1,
        .HAVE_STRINGS_H = 1,
        .HAVE_STRING_H = 1,
        .HAVE_STRLWR = 1,
        .HAVE_STRNCASECMP = 1,
        .HAVE_STRNLEN = 1,
        .HAVE_STRSTR = 1,
        .HAVE_STRTOF = 1,
        .HAVE_STRTOK_R = 1,
        .HAVE_SUSECONDS_T = null,
        .HAVE_SYSTEMD = null,
        .HAVE_SYSTEMD_SD_BUS_H = null,
        .HAVE_SYSTEMD_SD_DAEMON_H = null,
        .HAVE_SYS_MODEM_H = null,
        .HAVE_SYS_RESOURCE_H = null,
        .HAVE_SYS_STAT_H = 1,
        .HAVE_SYS_TERMIOS_H = null,
        .HAVE_SYS_TIME_H = 1,
        .HAVE_SYS_TYPES_H = 1,
        .HAVE_TCPD_H = null,
        .HAVE_TCSENDBREAK = null,
        .HAVE_TERMIOS_H = null,
        .HAVE_TIMEGM = null,
        .HAVE_TIME_H = 1,
        .HAVE_UINTMAX_T = 1,
        .HAVE_UNISTD_H = 1,
        .HAVE_UNSIGNED_LONG_LONG_INT = 1,
        .HAVE_USB_DETACH_KERNEL_DRIVER_NP = null,
        .HAVE_USB_H = null,
        .HAVE_USB_INIT = null,
        .HAVE_USECONDS_T = 1,
        .HAVE_USLEEP = 1,
        .HAVE_UU_LOCK = null,
        .HAVE_VARARGS_H = null,
        .HAVE_VSNPRINTF = 1,
        .HAVE_WRAP = null,
        .HAVE__BOOL_IMPLEM_ENUM = null,
        .HAVE__BOOL_IMPLEM_INT = 1,
        .HAVE__BOOL_IMPLEM_MACRO = null,
        .HAVE__BOOL_TYPE_CAMELCASE = 1,
        .HAVE__BOOL_TYPE_LOWERCASE = null,
        .HAVE__BOOL_TYPE_UPPERCASE = null,
        .HAVE__BOOL_VALUE_CAMELCASE = null,
        .HAVE__BOOL_VALUE_LOWERCASE = 1,
        .HAVE__BOOL_VALUE_UPPERCASE = null,
        .HAVE__MKGMTIME = 1,
        .MAN_SECTION_API = "3",
        .MAN_SECTION_API_BASE = "3",
        .MAN_SECTION_CFG = "5",
        .MAN_SECTION_CFG_BASE = "5",
        .MAN_SECTION_CMD_SYS = "8",
        .MAN_SECTION_CMD_SYS_BASE = "8",
        .MAN_SECTION_CMD_USR = "1",
        .MAN_SECTION_CMD_USR_BASE = "1",
        .MAN_SECTION_MISC = "7",
        .MAN_SECTION_MISC_BASE = "7",
        .NEED_GETOPT_DECLS = null,
        .NEED_GETOPT_H = 1,
        .NUT_HAVE_LIBNETSNMP_DRAFT_BLUMENTHAL_AES_04 = null,
        .NUT_HAVE_LIBNETSNMP_usmAES128PrivProtocol = null,
        .NUT_HAVE_LIBNETSNMP_usmAES192PrivProtocol = null,
        .NUT_HAVE_LIBNETSNMP_usmAES256PrivProtocol = null,
        .NUT_HAVE_LIBNETSNMP_usmAESPrivProtocol = null,
        .NUT_HAVE_LIBNETSNMP_usmDESPrivProtocol = null,
        .NUT_HAVE_LIBNETSNMP_usmHMAC192SHA256AuthProtocol = null,
        .NUT_HAVE_LIBNETSNMP_usmHMAC256SHA384AuthProtocol = null,
        .NUT_HAVE_LIBNETSNMP_usmHMAC384SHA512AuthProtocol = null,
        .NUT_HAVE_LIBNETSNMP_usmHMACMD5AuthProtocol = null,
        .NUT_HAVE_LIBNETSNMP_usmHMACSHA1AuthProtocol = null,
        .NUT_MODBUS_HAS_USB = null,
        .NUT_MODBUS_LINKTYPE_STR = null,
        .NUT_MODBUS_TIMEOUT_ARG_sec_usec_uint32 = null,
        .NUT_MODBUS_TIMEOUT_ARG_sec_usec_uint32_cast_timeval_fields = null,
        .NUT_MODBUS_TIMEOUT_ARG_timeval = null,
        .NUT_MODBUS_TIMEOUT_ARG_timeval_numeric_fields = null,
        .REQUIRE_NUT_STRARG = 1,
        .SIZEOF_VOID_P = 8,
        .SUN_LIBUSB = null,
        .WANT_TIMEGM_FALLBACK = null,
        .HAVE_MINIX_CONFIG_H = null,
        ._HPUX_ALT_XOPEN_SOCKET_API = null,

        // details of the build env (not required)
        .ABS_TOP_BUILDDIR = null,
        .ABS_TOP_SRCDIR = null,
        .AUTOTOOLS_BUILD_ALIAS = null,
        .AUTOTOOLS_BUILD_SHORT_ALIAS = null,
        .AUTOTOOLS_HOST_ALIAS = null,
        .AUTOTOOLS_HOST_SHORT_ALIAS = null,
        .AUTOTOOLS_TARGET_ALIAS = null,
        .AUTOTOOLS_TARGET_SHORT_ALIAS = null,
        .CCACHE_NAMESPACE = null,
        .MULTIARCH_TARGET_ALIAS = null,
        .SOFILE_LIBAVAHI = null,
        .SOFILE_LIBFREEIPMI = null,
        .SOFILE_LIBNEON = null,
        .SOFILE_LIBNETSNMP = null,
        .SOFILE_LIBUSB0 = null,
        .SOFILE_LIBUSB1 = null,
        .SOPATH_LIBAVAHI = null,
        .SOPATH_LIBFREEIPMI = null,
        .SOPATH_LIBNEON = null,
        .SOPATH_LIBNETSNMP = null,
        .SOPATH_LIBUSB0 = null,
        .SOPATH_LIBUSB1 = null,
    };

    return b.addConfigHeader(
        .{ .style = .{ .autoconf_undef = input_file } },
        opts,
    );
}

fn defFromBool(val: bool) ?u1 {
    return if (val) 1 else null;
}
