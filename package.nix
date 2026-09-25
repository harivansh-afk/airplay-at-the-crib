{
  lib,
  buildGoModule,
  dbus,
}:
buildGoModule {
  pname = "airplay-beacon";
  version = "0.3.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./go.mod
      ./go.sum
      ./cmd
    ];
  };
  vendorHash = "sha256-pj8HUvTWE6YmCxNtXmscCl1+O7G14D5kR+JPuPgdkvk=";
  subPackages = [ "cmd/airplay-beacon" ];
  env.CGO_ENABLED = 0;
  nativeCheckInputs = [ dbus ];
  checkPhase = ''
    runHook preCheck
    dbus-run-session --config-file=${dbus}/share/dbus-1/session.conf -- sh -c 'export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" AIRPLAY_TEST_PRIVATE_BUS=1; go test ./...'
    go vet ./...
    runHook postCheck
  '';
  ldflags = [
    "-s"
    "-w"
  ];
  meta = {
    description = "Bluetooth discovery of an existing Roku AirPlay receiver";
    mainProgram = "airplay-beacon";
    platforms = lib.platforms.linux;
  };
}
