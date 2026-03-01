{
  inputs = {
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    systems.url = "github:nix-systems/default";
    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";
    nix-gleam = {
      url = "github:arnarg/nix-gleam";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  outputs =
    {
      self,
      nixpkgs,
      devenv,
      systems,
      nix-gleam,
      ...
    }@inputs:
    let
      forEachSystem = nixpkgs.lib.genAttrs (import systems);
    in
    {
      packages = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system}.extend nix-gleam.overlays.default;

          src = self;

          # Build the Tailwind CSS before the Gleam build.
          # The compiled app.css must be present in priv/static/ so it gets included
          # in the OTP app's priv directory and can be served at runtime.
          css = pkgs.stdenvNoCC.mkDerivation {
            name = "home-terminal-css";
            inherit src;
            nativeBuildInputs = [ pkgs.tailwindcss_4 ];
            buildPhase = ''
              tailwindcss --input tailwind.css --output app.css --minify
            '';
            installPhase = ''
              install -Dm644 app.css $out/app.css
            '';
          };
        in
        {
          default = pkgs.buildGleamApplication {
            pname = "home-terminal";
            version = "1.0.0";

            # Patch in the compiled CSS before the Gleam build runs.
            src = pkgs.stdenvNoCC.mkDerivation {
              name = "home-terminal-src";
              inherit src;
              buildPhase = "";
              installPhase = ''
                cp -r $src $out
                chmod -R u+w $out
                install -Dm644 ${css}/app.css $out/priv/static/app.css
              '';
            };

            target = "erlang";

            # qdate_localtime uses a rebar3 pre_hook that runs `priv/ibuild.escript`
            # as a bare executable. Two problems in the Nix sandbox:
            #   1. nix-gleam's rsync strips the execute bit (--chmod=Fu=rw)
            #   2. The shebang is #!/usr/bin/env escript, but /usr/bin/env doesn't
            #      exist on Linux builders in the Nix sandbox
            # Fix: rewrite the rebar.config pre_hook to invoke escript explicitly,
            # and patch the shebang to use the escript from nativeBuildInputs.
            postConfigure = ''
              find build/packages -name "rebar.config" | while read rc; do
                sed -i 's|"priv/ibuild.escript"|"escript priv/ibuild.escript"|g' "$rc"
              done
              find build/packages -name "*.escript" -exec chmod +x {} \; -exec sed -i \
                '1s|#!/usr/bin/env escript|#!'"$(command -v escript)"'|' {} \;
            '';

            meta = {
              description = "Home dashboard terminal with calendar, HA integration, and travel times";
              mainProgram = "home_terminal";
            };
          };
        }
      );

      devShells = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = devenv.lib.mkShell {
            inherit inputs pkgs;
            modules = [
              {
                # https://devenv.sh/reference/options/
                languages.gleam.enable = true;

                packages = [
                  pkgs.watchexec
                  pkgs.tailwindcss_4
                  pkgs.overmind
                  pkgs.deno
                ];

                # On a file change: build then tell overmind to restart beam.
                # overmind sends SIGTERM, waits for exit, then starts fresh.
                # erlang:halt(0) makes the BEAM exit immediately on SIGTERM.
                # The Procfile beam command then polls until the port is free
                # before exec-ing gleam run, avoiding EADDRINUSE on macOS where
                # the kernel holds the socket briefly after process exit.
                scripts.rebuild-and-restart.exec = ''
                  gleam build && overmind restart beam
                '';

                enterShell = ''
                  echo "Gleam $(gleam --version)"
                  echo ""
                  echo "Run 'overmind start' to start the dev server with auto-reload."
                  echo "App will be available at http://localhost:46548"
                  echo ""
                  echo "One-shot CSS build (from outside the shell):"
                  echo "  nix develop --impure --command tailwindcss --input tailwind.css --output priv/static/app.css"
                '';
              }
            ];
          };
        }
      );
    };
}
