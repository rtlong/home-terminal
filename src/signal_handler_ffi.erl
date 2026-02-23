-module(signal_handler_ffi).
-export([trap_sigterm/0]).
-behaviour(gen_event).
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).

%% Register a gen_event handler on erl_signal_server that calls init:stop()
%% when SIGTERM is received. This gives the BEAM VM a chance to shut down
%% supervisors (and release the TCP port) before the OS process exits.
trap_sigterm() ->
    os:set_signal(sigterm, handle),
    gen_event:add_handler(erl_signal_server, ?MODULE, []),
    nil.

%% gen_event callbacks

init([]) -> {ok, []}.

handle_event(sigterm, State) ->
    init:stop(),
    {ok, State};
handle_event(_Event, State) ->
    {ok, State}.

handle_call(_Request, State) -> {ok, ok, State}.
handle_info(_Info, State) -> {ok, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
