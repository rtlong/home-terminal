%% HTTP FFI for CalDAV requests using custom methods (PROPFIND, REPORT).
%%
%% OTP's httpc only accepts a fixed set of HTTP method atoms and rejects
%% PROPFIND/REPORT with invalid_method. We implement a minimal HTTP/1.1
%% client over ssl directly.
-module(caldav_http_ffi).
-export([request/4]).

%% request(MethodBin, UrlBin, Headers, Body)
%%   -> {ok, {StatusCode :: integer(), Body :: binary()}}
%%    | {error, Reason :: binary()}
-spec request(binary(), binary(), [{binary(), binary()}], binary()) ->
    {ok, {integer(), binary()}} | {error, binary()}.
request(MethodBin, UrlBin, Headers, Body) ->
    case parse_url(UrlBin) of
        {ok, {Host, Port, Path}} ->
            do_request(MethodBin, Host, Port, Path, Headers, Body);
        {error, Reason} ->
            {error, Reason}
    end.

parse_url(UrlBin) ->
    Url = binary_to_list(UrlBin),
    case uri_string:parse(Url) of
        #{host := Host, path := Path0} = Map ->
            Scheme = maps:get(scheme, Map, "https"),
            Port = maps:get(port, Map, case Scheme of
                "https" -> 443;
                _       -> 80
            end),
            Query = maps:get(query, Map, ""),
            Path = case Path0 of
                "" -> "/";
                _  -> Path0
            end,
            FullPath = case Query of
                "" -> Path;
                Q  -> Path ++ "?" ++ Q
            end,
            {ok, {Host, Port, FullPath}};
        _ ->
            {error, <<"invalid_url">>}
    end.

do_request(Method, Host, Port, Path, ExtraHeaders, Body) ->
    ok = ensure_started(crypto),
    ok = ensure_started(asn1),
    ok = ensure_started(public_key),
    ok = ensure_started(ssl),
    SslOpts = [
        {verify, verify_none},
        {server_name_indication, Host},
        {versions, ['tlsv1.2', 'tlsv1.3']},
        {active, false}
    ],
    case ssl:connect(Host, Port, SslOpts, 30000) of
        {ok, Sock} ->
            send_request(Sock, Method, Host, Path, ExtraHeaders, Body);
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("ssl_connect: ~p", [Reason]))}
    end.

send_request(Sock, Method, Host, Path, ExtraHeaders, Body) ->
    ContentLength = integer_to_list(byte_size(Body)),
    DefaultHeaders = [
        {<<"host">>, list_to_binary(Host)},
        {<<"content-length">>, list_to_binary(ContentLength)},
        {<<"connection">>, <<"close">>}
    ],
    AllHeaders = merge_headers(DefaultHeaders, ExtraHeaders),
    HeaderLines = [
        [K, <<": ">>, V, <<"\r\n">>]
        || {K, V} <- AllHeaders
    ],
    RequestLine = [Method, <<" ">>, list_to_binary(Path),
                   <<" HTTP/1.1\r\n">>],
    Request = iolist_to_binary([RequestLine, HeaderLines, <<"\r\n">>, Body]),
    case ssl:send(Sock, Request) of
        ok ->
            receive_response(Sock);
        {error, Reason} ->
            ssl:close(Sock),
            {error, list_to_binary(io_lib:format("ssl_send: ~p", [Reason]))}
    end.

%% ExtraHeaders override DefaultHeaders on matching key (case-insensitive).
merge_headers(Defaults, Extras) ->
    ExtraKeys = [string:lowercase(binary_to_list(K)) || {K, _} <- Extras],
    Filtered = [{K, V} || {K, V} <- Defaults,
                          not lists:member(string:lowercase(binary_to_list(K)), ExtraKeys)],
    Filtered ++ Extras.

receive_response(Sock) ->
    receive_chunks(Sock, <<>>).

receive_chunks(Sock, Acc) ->
    case ssl:recv(Sock, 0, 30000) of
        {ok, Data} ->
            Bin = iolist_to_binary(Data),
            receive_chunks(Sock, <<Acc/binary, Bin/binary>>);
        {error, closed} ->
            ssl:close(Sock),
            parse_response(Acc);
        {error, Reason} ->
            ssl:close(Sock),
            {error, list_to_binary(io_lib:format("ssl_recv: ~p", [Reason]))}
    end.

parse_response(Data) ->
    case binary:split(Data, <<"\r\n\r\n">>) of
        [HeadersPart, RawBody] ->
            case binary:split(HeadersPart, <<"\r\n">>) of
                [StatusLine | HeaderLines] ->
                    case parse_status_line(StatusLine) of
                        {ok, Status} ->
                            IsChunked = is_chunked(HeaderLines),
                            Body = case IsChunked of
                                true  -> decode_chunked(RawBody);
                                false -> RawBody
                            end,
                            {ok, {Status, Body}};
                        error ->
                            {error, <<"failed to parse status line">>}
                    end;
                _ ->
                    {error, <<"malformed response headers">>}
            end;
        _ ->
            {error, <<"no header/body separator found">>}
    end.

parse_status_line(Line) ->
    case binary:split(Line, <<" ">>, [global]) of
        [_Version, CodeBin | _] ->
            case catch binary_to_integer(CodeBin) of
                N when is_integer(N) -> {ok, N};
                _ -> error
            end;
        _ ->
            error
    end.

is_chunked(HeaderLines) ->
    lists:any(fun(Line) ->
        Lower = string:lowercase(binary_to_list(Line)),
        string:find(Lower, "transfer-encoding: chunked") /= nomatch
    end, HeaderLines).

%% Decode HTTP/1.1 chunked transfer encoding.
decode_chunked(Data) ->
    decode_chunks(Data, <<>>).

decode_chunks(<<>>, Acc) ->
    Acc;
decode_chunks(Data, Acc) ->
    case binary:split(Data, <<"\r\n">>) of
        [SizeLine, Rest] ->
            %% Strip chunk extensions (e.g. "24d;ext=val")
            SizeHex = hd(binary:split(SizeLine, <<";">>)),
            case catch binary_to_integer(string:trim(SizeHex), 16) of
                0 ->
                    %% Last chunk
                    Acc;
                Size when is_integer(Size), Size > 0 ->
                    <<Chunk:Size/binary, "\r\n", Remaining/binary>> = Rest,
                    decode_chunks(Remaining, <<Acc/binary, Chunk/binary>>);
                _ ->
                    %% Not a valid chunk size — treat remainder as raw body
                    <<Acc/binary, Data/binary>>
            end;
        _ ->
            <<Acc/binary, Data/binary>>
    end.

ensure_started(App) ->
    case application:start(App) of
        ok -> ok;
        {error, {already_started, _}} -> ok;
        {error, Reason} -> error({could_not_start, App, Reason})
    end.
