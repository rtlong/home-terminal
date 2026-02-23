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

                # Build then run. erlang:halt(0) on SIGTERM exits synchronously
                # so the port is released before process-compose starts the next
                # instance. restart=always covers both clean exits and signals.
                processes.beam.exec = ''
                  gleam build
                  PA=$(find build/dev/erlang -maxdepth 2 -name ebin -type d \
                         | sort | sed 's/^/-pa /' | tr '\n' ' ')
                  exec erl $PA -eval "home_terminal@@main:run(app)" -noshell
                '';

                processes.beam.process-compose = {
                  availability = {
                    restart = "always";
                    backoff_seconds = 1;
                    max_restarts = 0;
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
