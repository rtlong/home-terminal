beam: gleam build && PA=$(find build/dev/erlang -maxdepth 2 -name ebin -type d | sort | sed 's/^/-pa /' | tr '\n' ' ') && exec erl $PA -eval "home_terminal@@main:run(app)" -noshell
watcher: watchexec --watch src --exts gleam --on-busy-update queue -- rebuild-and-restart
tailwind: tailwindcss --config tailwind.config.js --input tailwind.css --output priv/static/app.css --watch
