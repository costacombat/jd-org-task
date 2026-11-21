{
  description = "ot: Org tasks from the shell, through a small Emacs";

  inputs.nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1"; # unstable Nixpkgs

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSystem =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              overlays = [ self.overlays.default ];
            }
          )
        );
    in
    {
      overlays.default = final: _prev: { ot = final.callPackage ./nix/package.nix { }; };

      packages = forEachSystem (pkgs: {
        default = pkgs.ot;
        inherit (pkgs) ot;
      });

      devShells = forEachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            emacs-nox
            jq
            shellcheck
            nixfmt
          ];
        };
      });

      formatter = forEachSystem (pkgs: pkgs.nixfmt-tree);

      checks = forEachSystem (
        pkgs:
        {
          # Every command, with --batch and through a daemon, in real Emacs
          ot =
            pkgs.runCommand "ot-test"
              {
                nativeBuildInputs = [
                  pkgs.ot
                  pkgs.emacs-nox
                  pkgs.jq
                ];
              }
              ''
                bash ${./tests}/test.sh
                touch $out
              '';

          shellcheck = pkgs.runCommand "ot-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
            shellcheck ${./bin/ot} ${./tests/test.sh}
            touch $out
          '';
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # The modular service, plugged into NixOS: its systemd unit
          service =
            let
              unit =
                (nixpkgs.lib.nixosSystem {
                  inherit (pkgs.stdenv.hostPlatform) system;
                  modules = [
                    {
                      nixpkgs.pkgs = pkgs;
                      boot.loader.grub.enable = false;
                      fileSystems."/" = {
                        device = "none";
                        fsType = "tmpfs";
                      };
                      system.stateVersion = "25.11";
                      system.services.ot = {
                        imports = [ pkgs.ot.services.default ];
                        ot.user = "ash";
                      };
                    }
                  ];
                }).config.systemd.services.ot;
            in
            pkgs.writeText "ot-service.json" (
              assert unit.serviceConfig.User == "ash";
              assert unit.serviceConfig.RuntimeDirectory == "ot";
              assert unit.serviceConfig.RuntimeDirectoryMode == "0700";
              assert unit.environment.OT_SOCKET == "/run/ot/server";
              assert pkgs.lib.hasSuffix "/bin/ot\" \"daemon\"" (pkgs.lib.head unit.serviceConfig.ExecStart);
              builtins.toJSON {
                inherit (unit.serviceConfig) ExecStart User RuntimeDirectory;
                inherit (unit.environment) OT_SOCKET;
              }
            );
        }
      );
    };
}
