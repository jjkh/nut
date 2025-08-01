# Network UPS Tools

[Network UPS Tools](https://github.com/networkupstools/nut) packaged for the [Zig](https://github.com/ziglang/zig) build system.

## Status

**Extremely** unfinished:

* Only the `usbhid-ups` driver is being built
* Builds on `aarch64-macos`, `x86_64-windows` and `x86_64-linux`
    * Runs on MacOS, but have not tested with a UPS
* Requires Zig 0.15.0-dev.1254 or later

## Building

```sh
# to build
zig build
# to run
./zig-out/bin/upshid-ups
```