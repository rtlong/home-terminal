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

                # Kill any leftover beam.smp from a previous run, then start fresh.
                # pkill -TERM waits for the signal to be delivered; the sleep gives
                # the VM time to release the port before erl starts.
                scripts.start-beam.exec = ''
                  pkill -TERM -f 'home_terminal@@main' 2>/dev/null || true
                  sleep 0.5
                  PA=$(find build/dev/erlang -maxdepth 2 -name ebin -type d \
                         | sort | sed 's/^/-pa /' | tr '\n' ' ')
                  exec erl $PA -eval "home_terminal@@main:run(app)" -noshell
                '';

                processes.beam.exec = "start-beam";

                processes.beam.process-compose = {
                  availability = {
                    restart = "on_failure";
                    backoff_seconds = 1;
                    max_restarts = 0;
                  };
                  shutdown = {
                    # Kill beam.smp directly by name — erl forks it and killing
                    # erl alone does not kill beam.smp on macOS.
                    command = "pkill -TERM -f 'home_terminal@@main'";
                    timeout_seconds = 10;
                  };
                };

                # On a file change: build, then tell process-compose to restart
                # the beam process. No children of its own — just pokes the API.
                scripts.rebuild-and-restart.exec = ''
                  gleam build && process-compose process restart beam -U
                '';

                processes.watcher.exec = ''
                  watchexec \
                    --watch src \
                    --exts gleam \
                    --on-busy-update queue \
                    -- rebuild-and-restart
                '';

                processes.watcher.process-compose = {
                  availability = {
                    restart = "on_failure";
                    backoff_seconds = 1;
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
