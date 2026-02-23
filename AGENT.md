# Agent notes for home-terminal

## Nix / devenv

This project uses [devenv](https://devenv.sh) with a flake integration. The
devenv flake uses Import From Derivation (IFD), which means **`nix develop`
requires `--impure`** — without it the evaluation fails.

Always use:

```sh
nix develop --impure --command <cmd> [args...]
```

For example, to do a one-shot Tailwind CSS build:

```sh
nix develop --impure --command tailwindcss \
  --config tailwind.config.js \
  --input tailwind.css \
  --output priv/static/app.css
```

Commands run via `devenv up` (i.e. inside process-compose) already have the
devenv shell on `$PATH`, so they do not need `nix develop` at all.

## CSS / Tailwind

Tailwind CSS is built from `tailwind.css` → `priv/static/app.css` using the
standalone `tailwindcss` CLI (v3, from `pkgs.tailwindcss` in nixpkgs).

- Config: `tailwind.config.js` — content glob points at `./src/**/*.gleam`
- Input: `tailwind.css` (the three `@tailwind` directives)
- Output: `priv/static/app.css` — gitignored, must be generated before running the app
- In dev: `devenv up` runs a `tailwind` process that watches and rebuilds automatically
- The Gleam server serves the file at `/app.css` via `mist.send_file`

**Dynamic class names do not work** with the scanner. Always use complete
Tailwind class name strings in literals. Dynamic CSS values (e.g. per-calendar
colors) go through `attribute.style(...)` instead.

## Running

```sh
# Start all processes (Gleam watcher + Tailwind watcher):
devenv up

# App is at http://localhost:46548
```
