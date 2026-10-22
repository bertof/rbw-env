# rbw-env

Load environment variables from a [Bitwarden](https://bitwarden.com) note via
[rbw](https://github.com/doy/rbw), in any shell.

rbw-env is first and foremost a small, self-contained script: it `eval`s a set
of `export` statements retrieved from a Bitwarden item, wherever you need them
— an interactive shell, a direnv `.envrc`, a CI job, a profile file. On top of
the script, a [flake-parts](https://flake.parts) module is provided as a
convenient way to connect it to Nix development shells. Secrets never touch
disk (beyond rbw's own keyring) and never end up in your repository.

## How it works

The `rbw-env` script:

1. Resolves which Bitwarden item to fetch, trying in order:

   1. the `--name` command line argument,
   1. the `RBW_ENV_NAME` environment variable,
   1. the basename of the git repository root
      (`git rev-parse --show-toplevel`),
   1. the basename of the current directory.

   This means that, by default, each project fetches the item named after the
   repository itself.

1. Optionally restricts the lookup to a folder, via the `--folder` argument or
   the `RBW_ENV_FOLDER` environment variable.

1. Runs `rbw get [--folder <folder>] <name>` and prints one
   `export KEY=value` line per entry of the note.

The note content is a list of `KEY=value` lines. An optional leading `export`
on each line is tolerated, empty lines are ignored, and lines without a valid
shell variable name are skipped with a warning on stderr. Values are printed
with `printf %q`, so spaces, quotes and `$` are safe.

The script is deliberately forgiving: if `rbw` is unavailable, the item is not
found, or rbw is locked, it prints a warning on stderr and exits successfully
with no output. A missing vault must never block your shell or `nix develop`.

## Usage in any shell

The script is self-contained and only needs `rbw` on `PATH`. Load it wherever
you would load any environment file:

```sh
eval "$(rbw-env)"
```

Typical places:

- an interactive shell: add `eval "$(rbw-env)"` to your `.bashrc`/`.zshrc`;
- a direnv `.envrc`, so editors and tools inherit the secrets: `eval "$(rbw-env)"`;
- a one-off retrieval: `eval "$(rbw-env --name my-item --folder Dev)"`.

The output is compatible with bash and zsh. Plain values also work in any
POSIX shell, but values containing control characters are quoted in bash
`$'...'` style, which strict POSIX shells (e.g. dash) do not understand.

If you use Nix, you can run the script without installing it:

```sh
nix run github:bertof/rbw-env#rbw-env -- --name my-item --folder Dev
```

## Usage with Nix flakes

The flake-parts module is the recommended way to hook the script into Nix
development shells: the script becomes part of the shell, so every
`nix develop` (and every tool launched from it) sees the secrets without any
direnv involvement.

### 1. Add the input

```nix
{
  inputs = {
    systems.url = "github:nix-systems/default";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rbw-env = {
      url = "github:bertof/rbw-env";
      # Use *your* pinned nixpkgs: all packages (including rbw) will come
      # from your instance. Without this, rbw-env's own nixpkgs-unstable
      # would be instantiated.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

rbw-env does not ship a lock file on purpose: the `follows` above is what
pins the packages for your project.

### 2. Import the module

```nix
outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } {
  systems = import inputs.systems;
  imports = [ inputs.rbw-env.flakeModule ];
  # ...
};
```

### 3. Configure (optional)

```nix
perSystem = { config, pkgs, ... }: {
  rbwEnv = {
    # Fetch a specific item instead of the git-root-derived default:
    # itemName = "my-project-env";
    # Restrict the lookup to a Bitwarden folder:
    # folder = "Development";
    # Use a custom script (default: the one shipped by this flake):
    # package = pkgs.callPackage ./my-rbw-env.nix { };
  };
};
```

All packages used by rbw-env come from the `pkgs` module argument, i.e. from
*your* nixpkgs. The module never imports packages from its own inputs.

### 4. Enable it in a dev shell

The module provides two read-only values, mirroring the
[git-hooks.nix](https://github.com/cachix/git-hooks.nix) pattern:

- `config.rbwEnv.devShell`: a ready-made shell with the script on `PATH` and
  the environment variables loaded on entry;
- `config.rbwEnv.shellHook`: just the snippet, for composing into your own
  shells.

Note that `inputsFrom` propagates packages but **not** `shellHook`, so a
composed shell needs one explicit line:

```nix
perSystem = { config, pkgs, ... }: {
  devShells.default = pkgs.mkShell {
    inputsFrom = [
      config.pre-commit.devShell   # e.g. git-hooks
      config.rbwEnv.devShell
    ];
    shellHook = config.rbwEnv.shellHook;
  };
};
```

Entering the shell with `nix develop` then evaluates the note's variables
(warnings appear when the vault is locked or the item is missing, and the
shell proceeds regardless):

```console
nix develop
echo $API_KEY
```

You can also re-run the lookup manually at any time inside the shell:

```console
eval "$(rbw-env)"
```

## Security notes

- Secrets transit only between rbw's keyring and the environment of processes
  launched from your shell: nothing is written to files by rbw-env itself.
- The evaluation happens in your shell: as with any `eval` of dynamically
  fetched content, only load notes you control.
- If your shell history records command output (e.g. `asciinema`), keep in
  mind the environment is printed by `export` statements.
- With direnv, be aware that exported secrets are visible to any process
  spawned in the directory — same trust model as any other `.env` file.

## License

Released under the [GNU LGPL-3.0](COPYING.LESSER) (with
[GPL-3.0](COPYING) as referenced license).

## Development

The repository is a flake-parts flake with a `pre-commit` setup (deadnix,
nixpkgs-fmt, statix, shellcheck, shfmt, bats, markdown, typos). Tests are
[bats](https://github.com/bats-core/bats-core) files running the real script
against a mocked `rbw`:

```console
nix develop
bats rbw-env.bats
```

The same checks run automatically on `git commit`.

This flake intentionally does **not** ship a `flake.lock` (it is gitignored):
as a consumed input it would be ignored anyway, and consumers pin packages
through `inputs.nixpkgs.follows`.
