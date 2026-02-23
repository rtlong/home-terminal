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

                # Watch loop: build, start the BEAM, wait for file changes,
                # kill the exact BEAM pid, repeat. No intermediaries — we own
                # the pid and kill it directly, so no orphans are possible.
                processes.dev.exec = ''
                  BEAM_PID=""

                  kill_beam() {
                    if [ -n "$BEAM_PID" ]; then
                      echo "[dev] stopping BEAM (pid $BEAM_PID)"
                      kill "$BEAM_PID" 2>/dev/null
                      wait "$BEAM_PID" 2>/dev/null
                      BEAM_PID=""
                    fi
                  }

                  # On SIGTERM (process-compose shutting down), kill BEAM and exit.
                  trap 'kill_beam; exit 0' TERM INT

                  while true; do
                    echo "[dev] building..."
                    if gleam build; then
                      PA=$(find build/dev/erlang -maxdepth 2 -name ebin -type d \
                             | sort | sed 's/^/-pa /' | tr '\n' ' ')
                      erl $PA -eval "home_terminal@@main:run(app)" -noshell &
                      BEAM_PID=$!
                      echo "[dev] started BEAM pid $BEAM_PID"
                    else
                      echo "[dev] build failed, waiting for changes..."
                    fi

                    # Block until a .gleam file in src/ changes.
                    watchexec \
                      --watch src \
                      --exts gleam \
                      --postpone \
                      true

                    kill_beam
                  done
                '';

                # Restart on crash (process-compose level).
                processes.dev.process-compose = {
                  availability = {
                    restart = "on_failure";
                    backoff_seconds = 2;
                    max_restarts = 0;
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
