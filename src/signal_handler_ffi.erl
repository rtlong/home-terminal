-module(signal_handler_ffi).
-export([trap_sigterm/0, try_start/1]).
-behaviour(gen_event).
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).

%% Register a gen_event handler on erl_signal_server that calls init:stop()
%% when SIGTERM is received. This gives the BEAM VM a chance to shut down
%% supervisors (and release the TCP port) before the OS process exits.
trap_sigterm() ->
    os:set_signal(sigterm, handle),
    gen_event:add_handler(erl_signal_server, ?MODULE, []),
    nil.

%% Wrap a mist.start call with trap_exit so that if supervisor:start_link
%% sends an EXIT to the caller before returning, we catch it as an error
%% instead of crashing. This lets Gleam see the Error result and retry.
try_start(StartFun) ->
    OldTrap = erlang:process_flag(trap_exit, true),
    Result = try StartFun() of
        {ok, _} = Ok -> Ok;
        {error, _} = Err -> Err
    catch
        exit:Reason -> {error, {init_exited, {abnormal, Reason}}};
        error:Reason -> {error, {init_exited, {abnormal, Reason}}}
    end,
    %% Drain any queued EXIT message that arrived during the call.
    receive
        {'EXIT', _, _} -> ok
    after 0 -> ok
    end,
    erlang:process_flag(trap_exit, OldTrap),
    Result.

%% gen_event callbacks

init([]) -> {ok, []}.

handle_event(sigterm, State) ->
    %% erlang:halt() exits the OS process immediately and synchronously,
    %% so the port is released the moment the signal is handled.
    %% init:stop() is async and leaves the socket open during shutdown,
    %% which causes EADDRINUSE when the next instance starts too quickly.
    erlang:halt(0),
    {ok, State};
handle_event(_Event, State) ->
    {ok, State}.

handle_call(_Request, State) -> {ok, ok, State}.
handle_info(_Info, State) -> {ok, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
