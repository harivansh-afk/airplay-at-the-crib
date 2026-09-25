# Bluetooth AirPlay discovery service

The service broadcasts the existing Roku's IPv4 address and AirPlay port using
Bluetooth LE. Apple senders fetch the receiver's name and capabilities from the
TV over the normal network. Playback remains a direct sender-to-TV connection.
This is discovery only, not a media proxy, Bluetooth video transport, or AWDL.

## Requirements and user flow

- An always-on Linux host near the casting devices, with a BlueZ-compatible
  Bluetooth LE adapter that supports advertising.
- A Roku with AirPlay enabled and Control by mobile apps enabled, so its identity
  can be verified through ECP. Keep the normal AirPlay pairing/code protections.
- Casting devices with Bluetooth enabled and network access to the Roku.
  This bypasses missing multicast discovery; it cannot bypass client isolation.

Users join the apartment Wi-Fi, open Control Center → Screen Mirroring, choose
the Roku, and enter the TV's code if asked. There is no client installation or
Bluetooth pairing with the Linux host. Apps with an AirPlay button use their
normal AirPlay picker; app/content restrictions still apply.

The Linux host must stay on for reliable new discovery. Its service does not
participate in an established media session. The TV must remain available too;
Roku's Fast TV Start setting can preserve connectivity in standby, at a standby
power cost. Turning the TV on is the simplest first test. Actual Bluetooth
coverage depends on placement and walls.

## NixOS setup

Add this repository as a flake input, following your system's nixpkgs input,
and import `inputs.airplay-at-the-crib.nixosModules.default`:

```nix
services.airplay-beacon = {
  enable = true;
  address = "192.168.1.50";
  serial = "YOUR_ROKU_SERIAL";
  mac = "aa:bb:cc:dd:ee:ff";
  lanInterface = "wlan0";
  discoveryNetworks = [ "192.168.1.0/24" ];
};
```

`address` is a starting hint. `serial` identifies the paired TV and is checked
before advertising any candidate address. `mac`, `lanInterface` and
`discoveryNetworks` are optional recovery aids. Obtain identity values from Roku
Settings → System → About and Settings → Network → About. AirPlay port defaults
to 7000; set `port` if your receiver advertises a different port.

The module enables Bluetooth, starts `airplay-beacon.service` at boot, restarts
it after failures, and follows Bluetooth daemon restarts. It runs as an
unprivileged dynamic user, uses a private state directory, and opens no listening
network ports. Apply it through the normal persistent system deployment—not only
`switch-to-configuration test`, which a later normal deployment will replace.

## Resource bounds and recovery

The daemon is a compiled Go binary. Bluetooth advertising is registered with
BlueZ and handled by the controller. The application does not wake for every
advertisement, encode video, or maintain media buffers.

- Healthy TV: two small bounded HTTP reads once per minute. Requests have a
  two-second total timeout and responses are limited to 64 KiB each.
- Unavailable TV: remove the stale advertisement, then retry known addresses
  every 15 seconds. Log state changes rather than every failed poll.
- Changed address: check the persistent last-known address, configured hint,
  and MAC-matched neighbors on the selected LAN interface.
- Optional fallback: at most once every five minutes while the TV is unavailable,
  check only explicitly configured private `/24`-or-smaller ranges. The total
  scope cannot exceed 1024 addresses; at most eight requests run concurrently.
  This is a bounded recovery burst, not the normal idle workload. Omit the ranges
  if you prefer to maintain the address yourself.
- Validate the original serial and full AirPlay bootstrap before publishing a
  recovered address. This prevents accidentally advertising another TV; serial
  checks are not cryptographic network authentication.
- Restart on Bluetooth loss/unexpected advertisement release. Wait for the
  adapter to power up at startup; unregister on normal shutdown.

The NixOS unit sets a **64 MiB hard service-memory limit**, a 32 MiB pressure
threshold, a CPU quota of **5% of one core**, and at most 16 tasks. Go is limited
to one scheduler processor and a 16 MiB soft runtime memory target. These are
bounds/settings, not measurements of steady-state consumption.

## Verification and troubleshooting

```sh
systemctl status airplay-beacon bluetooth
journalctl -u airplay-beacon -n 30 --no-pager
busctl get-property org.bluez /org/bluez/hci0 org.bluez.LEAdvertisingManager1 ActiveInstances
systemctl show airplay-beacon -p MemoryCurrent -p MemoryPeak -p CPUUsageNSec -p NRestarts
```

A healthy log says `advertising ... at ...`. BlueZ registration proves host-side
acceptance, not reception by an Apple device. Complete the test in native Screen
Mirroring, including pairing, picture and sound. Test sleep/wake and movement
around the apartment separately. Restarting this discovery service does not
restart the Roku or a media relay.

The executable can check the receiver without touching Bluetooth:

```sh
nix run . -- --check --address 192.168.1.50 --serial YOUR_ROKU_SERIAL
```

To build and test:

```sh
nix build
nix flake check
```

Package checks include an isolated D-Bus integration test of registration,
optional-property handling, withdrawal, recovery and shutdown, plus bounded
network/identity tests. They do not access the real system Bluetooth bus.

## Protocol references

The advertisement matches the
[UxPlay Bluetooth beacon format](https://github.com/FDH2/UxPlay/blob/e3599e8c40ff1abe62146ba8a3e51c937bcf2524/Bluetooth_LE_beacon/uxplay_beacon_module_BlueZ.py):
Apple manufacturer ID `0x004c`, bytes `09 08 13 30`, the IPv4 address, and the
two-byte big-endian port. No UxPlay receiver process or media stack is needed.
[Apple's deployment guide](https://support.apple.com/guide/deployment/use-airplay-dep9151c4ace/web)
describes Bluetooth IP-address discovery.
