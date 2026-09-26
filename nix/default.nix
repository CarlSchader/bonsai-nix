# Per-system packages, checks, and dev shells for bonsai-nix.
{
  nixpkgs,
  flake-utils,
  ...
}:
flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system: let
  pkgs = import nixpkgs {
    inherit system;
    config.allowUnfree = true;
  };

  base = import ./llama-server.nix {
    inherit nixpkgs system;
  };

  moduleEval = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      ../modules/bonsai.nix
      ../modules/dgx-spark-bonsai2.nix
      {
        nixpkgs.hostPlatform = system;
        nixpkgs.config.allowUnfree = true;
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        system.stateVersion = "25.05";

        services.bonsai = {
          enable = true;
          package = base.packages.llamaServer;
          openFirewall = true;
          ui.enable = true;
          ui.webSearch.enable = true;
        };
      }
    ];
  };

in {
  inherit (base) packages;

  checks = base.checks // {
    bonsaiModuleEval = pkgs.stdenvNoCC.mkDerivation {
      name = "bonsai-module-eval-${system}";
      dontUnpack = true;
      dontConfigure = true;
      dontBuild = true;
      dontFixup = true;
      installPhase = ''
        mkdir -p $out
        cat > $out/manifest.txt <<'EOF'
module evaluated for system: ${system}
services.bonsai enabled: ${toString moduleEval.config.services.bonsai.enable}
ui enabled: ${toString moduleEval.config.services.open-webui.enable}
EOF
        cat >> $out/manifest.txt <<EOF
ExecStart: ${moduleEval.config.systemd.services.bonsai.serviceConfig.ExecStart}
EOF
      '';
    };
  };

  devShells =
    (import ./shells.nix {
      inherit nixpkgs system;
      llamaServer = base.packages.llamaServer;
    })
      .devShells;
})
