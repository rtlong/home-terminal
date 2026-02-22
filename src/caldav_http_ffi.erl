%% HTTP FFI for CalDAV requests using custom methods (PROPFIND, REPORT).
%%
%% gleam_httpc passes the Gleam Method ADT directly to erlang httpc:request/4,
%% which expects an atom. http.Other("PROPFIND") becomes {other, <<"PROPFIND">>}
%% in Erlang — not an atom — so httpc rejects it with invalid_method.
%%
%% This module calls httpc:request/4 directly with a proper atom method.
-module(caldav_http_ffi).
-export([request/4]).

%% request(MethodBin, Url, Headers, Body) -> {ok, {Status, ResponseBody}} | {error, Reason}
%%
%% MethodBin  :: binary()  e.g. <<"PROPFIND">>
%% Url        :: binary()
%% Headers    :: [{binary(), binary()}]
%% Body       :: binary()  (the request body; use <<>> for no body)
%%
%% Returns {ok, {StatusCode :: integer(), Body :: binary()}}
%%      or {error, Reason :: binary()}
-spec request(binary(), binary(), list({binary(), binary()}), binary()) ->
    {ok, {integer(), binary()}} | {error, binary()}.
request(MethodBin, UrlBin, Headers, Body) ->
    ok = ensure_inets_started(),
    ok = ensure_ssl_started(),
    Method = binary_to_atom(MethodBin, utf8),
    Url = binary_to_list(UrlBin),
    ErlHeaders = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Headers],
    ContentType = case lists:keyfind("content-type", 1, ErlHeaders) of
        {_, CT} -> CT;
        false   -> "application/xml"
    end,
    HttpOptions = [{ssl, [{verify, verify_none}]}, {autoredirect, true}, {timeout, 30000}],
    Options = [{body_format, binary}],
    Request = {Url, ErlHeaders, ContentType, Body},
    case httpc:request(Method, Request, HttpOptions, Options) of
        {ok, {{_Version, Status, _Phrase}, _RespHeaders, RespBody}} ->
            {ok, {Status, RespBody}};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

ensure_inets_started() ->
    case application:start(inets) of
        ok -> ok;
        {error, {already_started, inets}} -> ok;
        {error, Reason} -> error({could_not_start_inets, Reason})
    end.

ensure_ssl_started() ->
    case application:start(ssl) of
        ok -> ok;
        {error, {already_started, ssl}} -> ok;
        {error, Reason} -> error({could_not_start_ssl, Reason})
    end.
