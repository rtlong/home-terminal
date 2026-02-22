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

                # Watch src/ for changes, rebuild and restart the server.
                # On change: gleam build first; if it succeeds, kill the old
                # server and start the new one (watchexec -r handles the restart).
                processes.dev.exec = ''
                  watchexec \
                    --watch src \
                    --exts gleam \
                    --restart \
                    --on-busy-update restart \
                    -- sh -c 'gleam build && gleam run'
                '';

                enterShell = ''
                  echo "Gleam $(gleam --version)"
                  echo ""
                  echo "Run 'devenv up' to start the dev server with auto-reload."
                  echo "App will be available at http://localhost:1234"
                '';
              }
            ];
          };
        }
      );
    };
}
