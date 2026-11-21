# A modular service (NixOS 25.11+) that keeps ot's Emacs running:
#
#   system.services.ot = {
#     imports = [ pkgs.ot.services.default ];
#     ot.user = "ash";
#   };
#
# and in that user's environment, OT_SOCKET=/run/ot/server (the default
# `socket`), so `ot` finds it. Without the service, `ot` starts its own
# daemon on first use, so this is optional.
{ }:

{
  lib,
  config,
  options,
  name,
  ...
}:
let
  cfg = config.ot;
in
{
  _class = "service";

  options.ot = {
    package = lib.mkOption {
      type = lib.types.package;
      description = "The ot package.";
    };
    socket = lib.mkOption {
      type = lib.types.str;
      default = "/run/${name}/server";
      defaultText = lib.literalExpression ''"/run/<name>/server"'';
      description = "Where Emacs puts its server socket. Set OT_SOCKET to the same path.";
    };
    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The user ot's Emacs runs as: the one whose Org files it edits.";
    };
  };

  config = {
    process.argv = [
      (lib.getExe cfg.package)
      "daemon"
    ];
  }
  // lib.optionalAttrs (options ? systemd) {
    systemd.service = {
      wantedBy = [ "multi-user.target" ];
      environment.OT_SOCKET = cfg.socket;
      serviceConfig = {
        RuntimeDirectory = name;
        RuntimeDirectoryMode = "0700"; # Emacs refuses a socket folder others can read
        Restart = "on-failure";
      }
      // lib.optionalAttrs (cfg.user != null) { User = cfg.user; };
    };
  };
}
