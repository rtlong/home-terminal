%% FFI helpers for parsing CalDAV XML responses using Erlang's built-in xmerl.
%%
%% We expose simple functions to Gleam for extracting text content from XML
%% elements identified by namespace URI and local name.
-module(xmerl_ffi).
-export([parse_xml/1, find_text_content/3, find_all_elements/3]).

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

%% Find the text content of all elements with the given namespace URI and
%% local name anywhere in the XML tree rooted at Root.
%%
%% Returns a list of binary strings, one per matching element.
-spec find_text_content(#xmlElement{}, binary(), binary()) -> [binary()].
find_text_content(Root, NsUri, LocalName) ->
    Elems = find_all_elements(Root, NsUri, LocalName),
    [collect_text(E) || E <- Elems].

%% Find all elements with the given namespace URI and local name in the tree.
-spec find_all_elements(#xmlElement{} | #xmlText{}, binary(), binary()) -> [#xmlElement{}].
find_all_elements(#xmlElement{nsinfo = {Ns, Local}, content = Children} = Elem, NsUri, LocalName) ->
    NsUriStr = binary_to_list(NsUri),
    LocalStr = binary_to_list(LocalName),
    SelfMatch = case {Ns, Local} of
        {NsUriStr, LocalStr} -> [Elem];
        _ -> []
    end,
    ChildMatches = lists:flatmap(
        fun(C) -> find_all_elements(C, NsUri, LocalName) end,
        Children
    ),
    SelfMatch ++ ChildMatches;
find_all_elements(#xmlElement{nsinfo = undefined, name = Name, content = Children} = Elem, NsUri, LocalName) ->
    %% Fallback: no namespace info, try matching by atom name only
    LocalStr = binary_to_list(LocalName),
    SelfMatch = case atom_to_list(Name) of
        LocalStr -> [Elem];
        _ -> []
    end,
    ChildMatches = lists:flatmap(
        fun(C) -> find_all_elements(C, NsUri, LocalName) end,
        Children
    ),
    SelfMatch ++ ChildMatches;
find_all_elements(#xmlElement{content = Children} = _Elem, NsUri, LocalName) ->
    lists:flatmap(
        fun(C) -> find_all_elements(C, NsUri, LocalName) end,
        Children
    );
find_all_elements(_Other, _NsUri, _LocalName) ->
    [].

%% Collect all character data inside an element (recursively) as a binary.
-spec collect_text(#xmlElement{} | #xmlText{} | term()) -> binary().
collect_text(#xmlText{value = V}) ->
    list_to_binary(V);
collect_text(#xmlElement{content = Children}) ->
    iolist_to_binary([collect_text(C) || C <- Children]);
collect_text(_) ->
    <<>>.
