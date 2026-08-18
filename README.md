# DFUUtility

Technical-spike CLI for automating Apple Silicon Mac DFU transition and restore on macOS 14+.

```sh
swift build -c release
.build/release/dfuctl status
sudo .build/release/dfuctl dfu
.build/release/dfuctl restore /path/to/UniversalMac_Restore.ipsw
```

`restore` is destructive and runs only when explicitly invoked. Install Apple Configurator for its `cfgutil` restore engine and install [macvdmtool](https://github.com/AsahiLinux/macvdmtool) separately for programmatic DFU entry. Override discovery locations with `DFUCTL_CFGUTIL_PATH` and `DFUCTL_MACVDMTOOL_PATH`.

See [restore engine research](docs/RESTORE_ENGINE_RESEARCH.md) and [IPSW discovery](docs/IPSW_DISCOVERY.md).
