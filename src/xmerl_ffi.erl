%% FFI helpers for parsing CalDAV XML responses using Erlang's built-in xmerl.
%%
%% xmerl's namespace handling is quirky:
%%   - Prefixed elements (D:href) get name='D:href' and nsinfo={"D","href"} (charlists)
%%   - Default-namespace elements (xmlns="DAV:") get name='href' and nsinfo=[]
%%   - nsinfo never contains the full namespace URI, only the prefix
%%
%% We match by local name only (the part after the last colon in the atom name).
%% This is safe for CalDAV since element local names are unambiguous in practice.
-module(xmerl_ffi).
-export([parse_xml/1, find_text_content/3, find_all_elements/3,
         find_child_text/4, find_response_calendars/1]).

-include_lib("xmerl/include/xmerl.hrl").

%% Parse an XML string and return the root element, or an error binary.
-spec parse_xml(binary()) -> {ok, #xmlElement{}} | {error, binary()}.
parse_xml(XmlBin) ->
    XmlStr = binary_to_list(XmlBin),
    try
        {RootElem, _Rest} = xmerl_scan:string(XmlStr, [{namespace_conformant, true}]),
        {ok, RootElem}
    catch
        _Class:Reason ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Find the text content of all elements whose local name matches LocalName.
-spec find_text_content(#xmlElement{}, binary(), binary()) -> [binary()].
find_text_content(Root, NsUri, LocalName) ->
    Elems = find_all_elements(Root, NsUri, LocalName),
    [collect_text(E) || E <- Elems].

%% Find text of the first Child element that is a direct or indirect child of
%% a Parent element. This lets us find e.g. the <href> inside <calendar-home-set>
%% without also matching the response-level <href>.
%%
%% Returns {ok, Text} or {error, not_found}.
-spec find_child_text(#xmlElement{}, binary(), binary(), binary()) ->
    {ok, binary()} | {error, not_found}.
find_child_text(Root, _ParentNs, ParentLocal, _ChildLocal) ->
    ParentLocalStr = binary_to_list(ParentLocal),
    ChildLocalStr  = binary_to_list(_ChildLocal),
    Parents = find_all_elements(Root, _ParentNs, list_to_binary(ParentLocalStr)),
    find_child_in_parents(Parents, ChildLocalStr).

find_child_in_parents([], _ChildLocal) ->
    {error, not_found};
find_child_in_parents([Parent | Rest], ChildLocal) ->
    Children = find_all_elements(Parent, <<>>, list_to_binary(ChildLocal)),
    case Children of
        [Child | _] ->
            Text = collect_text(Child),
            case Text of
                <<>> -> find_child_in_parents(Rest, ChildLocal);
                T    -> {ok, T}
            end;
        [] ->
            find_child_in_parents(Rest, ChildLocal)
    end.

%% Find all elements whose local name matches LocalName, anywhere in the tree.
-spec find_all_elements(#xmlElement{} | #xmlText{} | term(), binary(), binary()) -> [#xmlElement{}].
find_all_elements(#xmlElement{name = Name, content = Children} = Elem, NsUri, LocalName) ->
    LocalStr = binary_to_list(LocalName),
    AtomStr  = atom_to_list(Name),
    LocalPart = lists:last(string:split(AtomStr, ":", all)),
    SelfMatch = case LocalPart =:= LocalStr of
        true  -> [Elem];
        false -> []
    end,
    ChildMatches = lists:flatmap(
        fun(C) -> find_all_elements(C, NsUri, LocalName) end,
        Children
    ),
    SelfMatch ++ ChildMatches;
find_all_elements(_Other, _NsUri, _LocalName) ->
    [].

%% Find all <D:response> subtrees that contain a <C:calendar> resourcetype,
%% and return [{Href, DisplayName}] for each one.
-spec find_response_calendars(#xmlElement{}) -> [{binary(), binary()}].
find_response_calendars(Root) ->
    Responses = find_all_elements(Root, <<"DAV:">>, <<"response">>),
    lists:filtermap(fun(Resp) ->
        Calendars = find_all_elements(Resp, <<"urn:ietf:params:xml:ns:caldav">>, <<"calendar">>),
        case Calendars of
            [] -> false;
            _  ->
                Hrefs = find_all_elements(Resp, <<"DAV:">>, <<"href">>),
                Names = find_all_elements(Resp, <<"DAV:">>, <<"displayname">>),
                Href = case Hrefs of
                    [H|_] -> collect_text(H);
                    []    -> <<>>
                end,
                Name = case Names of
                    [N|_] -> collect_text(N);
                    []    -> <<>>
                end,
                case Href of
                    <<>> -> false;
                    _    -> {true, {Href, Name}}
                end
        end
    end, Responses).

%% Collect all character data inside an element (recursively) as a binary.
-spec collect_text(#xmlElement{} | #xmlText{} | term()) -> binary().
collect_text(#xmlText{value = V}) ->
    unicode:characters_to_binary(V);
collect_text(#xmlElement{content = Children}) ->
    iolist_to_binary([collect_text(C) || C <- Children]);
collect_text(_) ->
    <<>>.
