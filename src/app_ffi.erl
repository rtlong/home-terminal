-module(app_ffi).
-export([try_start_mist/1]).

%% Calls the given fun (which calls mist.start) with trap_exit enabled so that
%% if supervisor:start_link exits the calling process before returning an Error,
%% we catch the exit signal and return {error, Reason} instead of crashing.
%%
%% Background: supervisor:start_link/2 links the new supervisor to the caller.
%% When a child fails to start, the supervisor exits abnormally, sending an
%% EXIT signal to the caller. On OTP versions where the signal arrives before
%% start_link returns, the caller dies before Gleam can pattern-match on the
%% Error result. Trapping exits for the duration of the call prevents this.
try_start_mist(StartFun) ->
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
