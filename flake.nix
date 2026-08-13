{
  description = "tileserver-gl - map tile server for JSON GL styles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        tileserver-gl = pkgs.callPackage ./nix/package.nix { };
        default = tileserver-gl;
      });

      overlays.default = final: prev: {
        tileserver-gl = final.callPackage ./nix/package.nix { };
      };

      nixosModules.tileserver-gl =
        { pkgs, lib, ... }:
        {
          imports = [ ./nix/module.nix ];
          services.tileserver-gl.package = lib.mkDefault
            self.packages.${pkgs.stdenv.hostPlatform.system}.tileserver-gl;
        };
      nixosModules.default = self.nixosModules.tileserver-gl;

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            nodejs_22
            python3
            pkg-config
            xvfb-run
            # native deps for `npm rebuild canvas --build-from-source`
            cairo
            pango
            glib
            libpng
            libjpeg
            giflib
            librsvg
            pixman
          ];
        };
      });
    };
}
