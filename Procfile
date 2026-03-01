beam: port=${PORT:-46548}; while lsof -iTCP:$port -sTCP:LISTEN -t >/dev/null 2>&1; do echo "[beam] waiting for port $port to be free..."; sleep 0.25; done; exec gleam run -m app
watcher: watchexec --watch src --exts gleam --on-busy-update queue -- rebuild-and-restart
tailwind: tailwindcss --input tailwind.css --output priv/static/app.css --watch
