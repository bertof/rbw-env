{
  description = "Load environment variables from a Bitwarden note via rbw";

  inputs = {
    systems.url = "github:nix-systems/default";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } {
    systems = import inputs.systems;
    imports = [
      inputs.git-hooks.flakeModule
      ./module.nix
    ];
    perSystem = { config, pkgs, ... }: {
      packages.rbw-env = pkgs.callPackage ./package.nix { };

      devShells.default = pkgs.mkShell {
        packages = [ config.rbwEnv.package pkgs.rbw ];
        inputsFrom = [ config.pre-commit.devShell ];
        shellHook = ''
          ${config.pre-commit.settings.installationScript}
          ${config.rbwEnv.shellHook}
        '';
      };

      pre-commit = {
        inherit pkgs;
        settings = {
          hooks = {
            # Nix
            deadnix.enable = true;
            nixpkgs-fmt.enable = true;
            statix.enable = true;
            # flake-checker is not useful here: this flake must not ship a lock file

            # Shell
            shellcheck.enable = true;
            shfmt.enable = true;
            bats = { enable = true; files = "\\.bats$"; };

            # Markdown
            mdformat.enable = true;
            markdownlint.enable = true;

            # Typo
            typos = { enable = true; stages = [ "pre-commit" "commit-msg" "pre-push" "manual" ]; };
          };
        };
      };
      formatter = pkgs.nixpkgs-fmt;
    };
    flake = {
      flakeModule = ./module.nix;
      flakeModules.default = ./module.nix;
      flakeModules.rbw-env = ./module.nix;
    };
  };
}
