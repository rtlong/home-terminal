-module(log_ffi).
-export([set_path/1, get_path/0, write_line/2, system_time_seconds/0]).

system_time_seconds() ->
    erlang:system_time(second).

%% Store the log path in the ETS application environment so all processes share it.
set_path(Path) ->
    application:set_env(home_terminal, log_path, Path),
    nil.

get_path() ->
    case application:get_env(home_terminal, log_path) of
        {ok, Path} -> Path;
        undefined   -> <<>>
    end.

%% Append a single line to a log file, prefixed with an ISO-8601 timestamp.
write_line(Path, Line) ->
    {{Y,Mo,D},{H,Mi,S}} = calendar:local_time(),
    Ts = io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B",
                       [Y, Mo, D, H, Mi, S]),
    Entry = iolist_to_binary([Ts, " ", Line, "\n"]),
    file:write_file(Path, Entry, [append]),
    nil.
