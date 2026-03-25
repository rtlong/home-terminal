-module(tz_ffi).
-export([local_to_utc/7, utc_to_local/7, system_timezone/0]).

%% local_to_utc(Year, Month, Day, Hour, Minute, Second, Timezone)
%%   -> GregorianSeconds (integer, UTC)
%%
%% Converts a wall-clock date/time in the named IANA timezone to UTC,
%% returned as Gregorian seconds (calendar:datetime_to_gregorian_seconds/1).
%%
%% On unknown timezone or impossible time (spring-forward gap), the wall-clock
%% time is treated as UTC (a safe degradation — same as the old behaviour of
%% using the server offset for everything).
%%
%% localtime:local_to_utc/2 can return:
%%   DateTime              - unambiguous conversion
%%   [DateTime, DateTime]  - ambiguous (DST fall-back); we pick first (std time)
%%   time_not_exists       - spring-forward gap; advance 1 h and retry
%%   {error, unknown_tz}   - unknown timezone name → treat wall-clock as UTC
local_to_utc(Year, Month, Day, Hour, Minute, Second, Timezone) ->
    DateTime = {{Year, Month, Day}, {Hour, Minute, Second}},
    FallbackSecs = calendar:datetime_to_gregorian_seconds(DateTime),
    case localtime:local_to_utc(DateTime, Timezone) of
        {error, unknown_tz} ->
            FallbackSecs;
        time_not_exists ->
            %% Spring-forward gap: advance 1 hour and retry.
            AdjDateTime = calendar:gregorian_seconds_to_datetime(FallbackSecs + 3600),
            case localtime:local_to_utc(AdjDateTime, Timezone) of
                {error, _}      -> FallbackSecs;
                time_not_exists -> FallbackSecs;
                [Utc | _]       -> calendar:datetime_to_gregorian_seconds(Utc);
                Utc             -> calendar:datetime_to_gregorian_seconds(Utc)
            end;
        [Utc | _] ->
            %% Ambiguous (DST fall-back): pick first (standard/pre-DST) result.
            calendar:datetime_to_gregorian_seconds(Utc);
        Utc ->
            calendar:datetime_to_gregorian_seconds(Utc)
    end.

%% utc_to_local(Year, Month, Day, Hour, Minute, Second, Timezone)
%%   -> GregorianSeconds (integer, in the local timezone)
%%
%% Converts a UTC date/time to wall-clock time in the named IANA timezone,
%% returned as Gregorian seconds.
%%
%% On unknown timezone, returns the input as-is (treats as UTC).
utc_to_local(Year, Month, Day, Hour, Minute, Second, Timezone) ->
    UtcDateTime = {{Year, Month, Day}, {Hour, Minute, Second}},
    case localtime:utc_to_local(UtcDateTime, Timezone) of
        {error, unknown_tz} ->
            calendar:datetime_to_gregorian_seconds(UtcDateTime);
        LocalDateTime ->
            calendar:datetime_to_gregorian_seconds(LocalDateTime)
    end.

%% system_timezone() -> binary() | undefined
%%
%% Returns the system's IANA timezone identifier (e.g., "America/New_York")
%% by reading /etc/localtime symlink. Returns 'undefined' if unable to determine.
system_timezone() ->
    case file:read_link("/etc/localtime") of
        {ok, Target} ->
            %% Target is something like "/var/db/timezone/zoneinfo/America/New_York"
            %% or "../usr/share/zoneinfo/America/New_York"
            %% Extract the IANA timezone name (everything after "zoneinfo/")
            %% Target can be either a binary or a list depending on the Erlang version
            TargetStr = case is_binary(Target) of
                true -> binary_to_list(Target);
                false -> Target  % Already a list
            end,
            case string:split(TargetStr, "zoneinfo/", trailing) of
                [_, TzName] -> list_to_binary(TzName);
                _ -> undefined
            end;
        {error, _} ->
            undefined
    end.
