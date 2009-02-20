%% @author Hunter Morris <hunter.morris@smarkets.com>
%% @copyright 2009 Smarkets Limited.
%%
%% @doc Smak HTTP response utility functions for dealing with EWGI
%% context returned from an application.
%% @end
%%
%% Licensed under the MIT license:
%% http://www.opensource.org/licenses/mit-license.php

-module(smak_http_response).
-author('Hunter Morris <hunter.morris@smarkets.com>').

-export([init/2, init/3]).

-include("smak.hrl").

-type response_key() :: 'status' | 'content_type' | 'headers'.
-type init_params() :: [{response_key(), string() | ewgi_status()}].

% TODO: Most frameworks let the author set this...
-define(DEFAULT_CONTENT_TYPE, "text/plain; charset=utf-8").

% Possible parameters
-record(p, {
          status={200, "OK"} :: ewgi_status(),
          content_type :: string(),
          headers :: ewgi_header_list()
         }).

-spec init(#ewgi_context{}, iolist()) -> #ewgi_context{}.
init(Ctx, Content) ->
    init(Ctx, Content, []).

-spec init(#ewgi_context{}, iolist(), init_params()) -> #ewgi_context{}.
init(Ctx, Content, Params0) ->
    Params = parse(Params0),
    Ctx1 = ewgi_api:response_message_body(Content, Ctx),
    Ctx2 = ewgi_api:response_status(Params#p.status, Ctx1),
    Ctx3 = merge_headers(Params#p.headers, Ctx2),
    add_content_type(Params, Ctx3).

-spec add_content_type(#p{}, #ewgi_context{}) -> #ewgi_context{}.
add_content_type(#p{content_type=undefined}, Ctx) ->
    case ewgi_api:get_header_value("content-type", Ctx) of
        undefined ->
            ewgi_api:insert_header("content-type", ?DEFAULT_CONTENT_TYPE, Ctx);
        _ ->
            Ctx
    end;
add_content_type(#p{content_type=V}, Ctx) ->
    ewgi_api:set_header("content-type", V, Ctx).

-spec merge_headers(ewgi_header_list(), #ewgi_context{}) -> #ewgi_context{}.
merge_headers(L, Ctx0) ->
    lists:foldl(fun({H, V}, Ctx) ->
                        case ewgi_api:get_header_value(H, Ctx) of
                            undefined ->
                                ewgi_api:insert_header(H, V, Ctx);
                            V ->
                                Ctx;
                            V1 ->
                                ewgi_api:set_header(H, V1, Ctx)
                        end
                end, Ctx0, L).

-spec parse(init_params()) -> #p{}.
parse(L) ->
    lists:foldl(fun({status, {S, M}=V}, P) when is_integer(S),
                                                is_list(M) ->
                        P#p{status = V};
                   ({content_type, V}, P) when is_list(V) ->
                        P#p{content_type = V};
                   ({headers, Hl}, P) when is_list(Hl) ->
                        P#p{headers = Hl};
                   (Unk, _) -> 
                        throw({error, {unknown_param, Unk}})
                end, #p{}, L).