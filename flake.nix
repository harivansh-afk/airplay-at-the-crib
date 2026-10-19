{
  description = "AirPlay discovery for an existing Roku using a Linux Bluetooth beacon";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/f20cd90e28fe0403873f473b29e42662cd86e8c4";
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
