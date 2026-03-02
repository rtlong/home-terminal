-module(demo_data_ffi).
-export([system_time_nanoseconds/0]).

system_time_nanoseconds() ->
    erlang:system_time(nanosecond).
