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

                packages = [ pkgs.watchexec ];

                # A small script that gleam-builds then starts the server.
                # Used as the watchexec command so we avoid shell quoting issues
                # with && inside the processes.dev.exec string.
                scripts.gleam-run-dev.exec = ''
                  gleam build && gleam run -m app
                '';

                # Watch src/ for changes, rebuild and restart the server.
                processes.dev.exec = ''
                  watchexec \
                    --watch src \
                    --exts gleam \
                    --restart \
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

                enterShell = ''
                  echo "Gleam $(gleam --version)"
                  echo ""
                  echo "Run 'devenv up' to start the dev server with auto-reload."
                  echo "App will be available at http://localhost:46548"
                '';
              }
            ];
          };
        }
      );
    };
}
