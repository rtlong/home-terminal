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

                # Build then exec the BEAM directly (exec replaces the shell so
                # watchexec's SIGTERM reaches beam.smp without an intermediary).
                scripts.gleam-run-dev.exec = ''
                  gleam build && exec gleam run -m app
                '';

                # Watch src/ for changes, rebuild and restart the server.
                # --stop-signal TERM   send SIGTERM first (BEAM handles it cleanly)
                # --stop-timeout 5000  wait up to 5s for it to exit before SIGKILL
                # This ensures the port is fully released before the new process starts.
                processes.dev.exec = ''
                  watchexec \
                    --watch src \
                    --exts gleam \
                    --restart \
                    --stop-signal TERM \
                    --stop-timeout 5000 \
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
