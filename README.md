# Network UPS Tools

[Network UPS Tools](https://github.com/networkupstools/nut) packaged for the [Zig](https://github.com/ziglang/zig) build system.

## Status

**Very** unfinished:

* Most drivers are being built
* Builds on `aarch64-macos`, `x86_64-windows` and `x86_64-linux`
  * Runs on MacOS
  * Tested with APC UPS on Windows
* Requires Zig 0.14.1 or later
  * Works with Zig 0.15.1

## TODO

* [ ] Non-driver binaries
* [ ] SNMP drivers
* [ ] NEON drivers
* [ ] Modbus drivers
* [ ] IMPI driver
* [ ] GPIO driver
* [ ] Configuration options (default dirs, ports, libraries to link, etc.)
* [ ] Don't log driver build warnings when listing `--help`

## Building

```sh
# to build all supported drivers
zig build
# to build specific drivers
zig build -Ddriver=usbhid-ups -Ddriver=nutdrv_qx

# to run
./zig-out/bin/upshid-ups
```
