{
  inputs = {
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    systems.url = "github:nix-systems/default";
    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";
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
      ...
    }@inputs:
    let
      forEachSystem = nixpkgs.lib.genAttrs (import systems);
    in
    {
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
                  pkgs.tailwindcss
                ];

                # Runs the app by exec'ing erl directly — bypasses gleam run's
                # fork so the process we launch IS beam.smp, no intermediary.
                # gleam run normally does: gleam run -> erl -> erl_child_setup -> beam.smp
                # We skip straight to: erl -> erl_child_setup -> beam.smp
                # watchexec then kills erl (which kills beam.smp via its pipe).
                scripts.gleam-run-dev.exec = ''
                  set -e
                  gleam build
                  # Collect all build output directories as -pa flags.
                  PA=$(find build/dev/erlang -maxdepth 2 -name ebin -type d \
                         | sort | sed 's/^/-pa /' | tr '\n' ' ')
                  exec erl $PA \
                    -eval "home_terminal@@main:run(app)" \
                    -noshell
                '';

                # Watch src/ for changes, rebuild and restart.
                # --wrap-process=session ensures erl and beam.smp are in the
                # same session and both receive SIGTERM on restart.
                processes.dev.exec = ''
                  watchexec \
                    --watch src \
                    --exts gleam \
                    --restart \
                    --wrap-process=session \
                    --stop-signal SIGTERM \
                    -- gleam-run-dev
                '';

                # Restart on crash (network errors, etc.) with exponential backoff.
                # process-compose won't restart on exit code 0 (clean shutdown).
                processes.dev.process-compose = {
                  availability = {
                    restart = "on_failure";
                    backoff_seconds = 2;
                    max_restarts = 0; # 0 = unlimited
                  };
                };

                # Tailwind CSS watcher — regenerates priv/static/app.css whenever
                # src/*.gleam files change. Runs in parallel with the Gleam server.
                processes.tailwind.exec = ''
                  tailwindcss \
                    --config tailwind.config.js \
                    --input tailwind.css \
                    --output priv/static/app.css \
                    --watch
                '';

                processes.tailwind.process-compose = {
                  availability = {
                    restart = "on_failure";
                    backoff_seconds = 1;
                    max_restarts = 0;
                  };
                };

                enterShell = ''
                  echo "Gleam $(gleam --version)"
                  echo ""
                  echo "Run 'devenv up' to start the dev server with auto-reload."
                  echo "App will be available at http://localhost:46548"
                  echo ""
                  echo "One-shot CSS build (from outside the shell):"
                  echo "  nix develop --impure --command tailwindcss --config tailwind.config.js --input tailwind.css --output priv/static/app.css"
                '';
              }
            ];
          };
        }
      );
    };
}
