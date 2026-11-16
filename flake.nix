{
  description = "Native Noctalia resource monitoring plugin";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          collector = pkgs.writeShellApplication {
            name = "noctalia-stats-collector";
            runtimeInputs = [
              pkgs.jq
              pkgs.iproute2
              pkgs.getconf
            ];
            text = builtins.readFile ./stats/bin/noctalia-stats-collector;
          };
          pluginSource = pkgs.lib.cleanSourceWith {
            src = ./stats;
            filter =
              path: type:
              baseNameOf path != "__pycache__" && !(pkgs.lib.hasSuffix ".pyc" path);
          };
        in
        {
          inherit collector;
          default = pkgs.runCommand "noctalia-stats-0.1.0" { } ''
            mkdir -p $out/share/noctalia-stats
            cp -r ${pluginSource} $out/share/noctalia-stats/stats
            cp ${./catalog.toml} $out/share/noctalia-stats/catalog.toml
            chmod -R u+w $out/share/noctalia-stats
            cp --remove-destination ${collector}/bin/noctalia-stats-collector $out/share/noctalia-stats/stats/bin/
          '';
        }
      );
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.luau
              pkgs.stylua
              pkgs.python3
              pkgs.uv
              pkgs.just
              pkgs.bash
              pkgs.jq
              pkgs.iproute2
              pkgs.getconf
              pkgs.shellcheck
            ];
          };
        }
      );
    };
}
