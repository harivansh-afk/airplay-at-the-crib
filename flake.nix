{
  description = "AirPlay discovery for an existing Roku using a Linux Bluetooth beacon";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/3e41b24abd260e8f71dbe2f5737d24122f972158";
  outputs =
    { self, nixpkgs }:
    let
      eachSystem = nixpkgs.lib.genAttrs [
        "aarch64-linux"
        "x86_64-linux"
      ];
    in
    {
      packages = eachSystem (system: {
        default = nixpkgs.legacyPackages.${system}.callPackage ./package.nix { };
      });
      checks = eachSystem (system: {
        package = self.packages.${system}.default;
      });
      nixosModules.default = import ./module.nix;
      formatter = eachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
