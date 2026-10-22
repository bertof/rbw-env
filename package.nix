{ lib, stdenv, makeWrapper, rbw }:

stdenv.mkDerivation {
  pname = "rbw-env";
  version = "0.1.1";
  src = ./.;
  dontBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    install -Dm755 rbw-env.sh $out/bin/rbw-env
    patchShebangs $out/bin/rbw-env
    wrapProgram $out/bin/rbw-env --prefix PATH : ${lib.makeBinPath [ rbw ]}
    runHook postInstall
  '';

  meta = {
    description = "Load environment variables from a Bitwarden note via rbw";
    longDescription = ''
      rbw-env retrieves a Bitwarden item with rbw and prints `export KEY=value`
      lines, suitable for `eval` in an interactive shell, a direnv .envrc, or
      the shellHook of a Nix development shell.
    '';
    license = lib.licenses.lgpl3Only;
    mainProgram = "rbw-env";
    platforms = lib.platforms.all;
  };
}
