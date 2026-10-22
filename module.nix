{ lib, ... }:
{
  perSystem = { config, pkgs, ... }:
    let
      cfg = config.rbwEnv;

      scriptArgs =
        lib.optionals (cfg.itemName != null) [ "--name" cfg.itemName ]
        ++ lib.optionals (cfg.folder != null) [ "--folder" cfg.folder ];
    in
    {
      options.rbwEnv = {
        itemName = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = ''
            Name of the Bitwarden item to retrieve.
            When null, the script falls back to the name of the git repository
            root (or of the current directory when outside a git repository).
          '';
        };

        folder = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = ''
            Optional folder of the Bitwarden item to retrieve.
          '';
        };

        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.callPackage ./package.nix { };
          defaultText = lib.literalExpression "rbw-env";
          description = "The rbw-env script package.";
        };

        shellHook = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          description = ''
            A bash snippet that evaluates the environment variables retrieved
            from rbw. Add it to the `shellHook` of your dev shells.
          '';
        };

        devShell = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          description = ''
            A development shell with the rbw-env script available and the
            environment variables loaded. Compose it into your own shells via
            `inputsFrom` and set `shellHook = config.rbwEnv.shellHook;`.
          '';
        };
      };

      config = {
        rbwEnv.shellHook = ''
          eval "$(${cfg.package}/bin/rbw-env ${lib.escapeShellArgs scriptArgs})"
        '';

        rbwEnv.devShell = pkgs.mkShell {
          packages = [ cfg.package ];
          inherit (cfg) shellHook;
        };
      };
    };
}
