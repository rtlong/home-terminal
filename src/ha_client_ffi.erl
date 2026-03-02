-module(ha_client_ffi).
-export([gethostname/0]).

gethostname() ->
    {ok, Hostname} = inet:gethostname(),
    list_to_binary(Hostname).
