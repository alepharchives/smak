%% @author Hunter Morris <hunter.morris@smarkets.com>
%% @copyright 2009 Smarkets Limited.
%%
%% @doc Smak cookie-based session/authentication middleware.
%% @end
%%
%% Licensed under the MIT license:
%% http://www.opensource.org/licenses/mit-license.php

-module(smak_auth_cookie).
-author('Hunter Morris <hunter.morris@smarkets.com>').

-export([init/3]).

-include("smak.hrl").

-import(ewgi_util_cookie, [simple_cookie/3, simple_cookie/4, cookie_safe_encode/1, cookie_safe_decode/1, get_domains/1]).

-compile(export_all).

-define(DEFAULT_COOKIE_NAME, "smak_auth").
-define(DEFAULT_ENCODER, smak_sn_cookie).
-define(SET_USER_ENV_NAME, "smak.auth_cookie.set_user").
-define(LOGOUT_USER_ENV_NAME, "smak.auth_cookie.logout_user").
-define(DEFAULT_IP, "0.0.0.0").

-record(cka, {
          application = undefined,
          key = undefined,
          cookie_name = ?DEFAULT_COOKIE_NAME,
          encoder = ?DEFAULT_ENCODER,
          include_ip = false,
          timeout = 15 * 60 * 1000, %% 15 minutes
          maxlength = 4096,
          secure = false
         }).

%% @spec init(Application::ewgi_app(), Key::binary(), Options::proplist()) -> ewgi_app()
%% @doc Initializes authentication middleware and returns the appropriate application.
-spec init(ewgi_app(), binary(), proplist()) -> ewgi_app().
init(Application, Key, Options) when is_binary(Key), size(Key) >= 16 ->
    case populate_record(Options, #cka{application=Application, key=Key}) of
        Cka when is_record(Cka, cka) ->
            F = fun(Ctx) ->
                        handle_request(Ctx, Cka)
                end,
            F;
        {error, Reason} ->
            {error, Reason};
        _ ->
            {error, invalid_parameters}
    end.

-spec handle_request(ewgi_context(), #cka{}) -> ewgi_context().
handle_request(Ctx0, Cka) ->
    Ctx = decode_cookies(ewgi_api:get_header_value("cookie", Ctx0), Ctx0, Cka),
    ewgi_application:run(Cka#cka.application, add_funs(Ctx, Cka)).

-spec decode_cookies('undefined' | string(), ewgi_context(), #cka{}) -> ewgi_context().
decode_cookies(undefined, Ctx, _) ->
    Ctx;
decode_cookies(Cookie, Ctx, Cka) ->
    CookieValues = ewgi_util_cookie:parse_cookie(Cookie),
    decode_cookies1(proplists:get_value(Cka#cka.cookie_name, CookieValues), Ctx, Cka).

-spec decode_cookies1('undefined' | string(), ewgi_context(), #cka{}) -> ewgi_context().
decode_cookies1(undefined, Ctx, _) ->
    Ctx;
decode_cookies1(Cookie0, Ctx, Cka) ->
    Cookie = cookie_safe_decode(Cookie0),
    case Cookie of
        <<>> ->
            Ctx;
        Cookie when is_binary(Cookie) ->
            case (Cka#cka.encoder):decode(Cka#cka.key, Cookie, Cka#cka.timeout) of
                {error, _Reason} ->
                    %% TODO: Warn?
                    Ctx;
                Content when is_binary(Content) ->
                    case (catch(binary_to_term(Content))) of
                        Values when is_list(Values) ->
                            case lists:foldl(scan_cookie_content(Cka), Ctx, Values) of
                                {error, _} ->
                                    %% TODO: Warn?
                                    Ctx;
                                Ctx1 ->
                                    Ctx1
                            end;
                        _ ->
                            Ctx
                    end;
                _ ->
                    Ctx
            end
    end.

-spec scan_cookie_content(#cka{}) -> function().
scan_cookie_content(#cka{include_ip=I}) ->
    F = fun
		   (_, PrevError) when not ?IS_EWGI_CONTEXT(PrevError) ->
			PrevError;
		   ({"REMOTE_USER", U}, Ctx) ->
                ewgi_api:remote_user(U, Ctx);
           ({"REMOTE_USER_DATA", D}, Ctx) ->
                ewgi_api:remote_user_data(D, Ctx);
           ({"REMOTE_ADDR", SavedAddr}, Ctx) when I =:= true ->
                Addr = ewgi_api:remote_addr(Ctx),
                if SavedAddr =:= Addr ->
                        Ctx;
                   true ->
                        error_logger:error_msg("Saved address: ~p, New address: ~p", [SavedAddr, Addr]),
                        {error, invalid_ip_address}
                end;
           (_, Ctx) ->
                %% TODO: Warn?
                Ctx
        end,
    F.

-spec add_funs(ewgi_context(), #cka{}) -> ewgi_context().
add_funs(Ctx0, Cka) ->
    lists:foldl(fun({K, V}, C) -> ewgi_api:store_data(K, V, C) end,
                Ctx0, [{?SET_USER_ENV_NAME, set_user(Ctx0, Cka)},
                       {?LOGOUT_USER_ENV_NAME, logout_user(Ctx0, Cka)}]).

-spec set_user(ewgi_context(), #cka{}) -> function().
set_user(Ctx, #cka{include_ip=IncludeIp,
                   cookie_name=CookieName,
                   encoder=Encoder,
                   key=Key,
                   maxlength=M,
                   secure=Sec}) ->
    F = fun(UserId, UserData) ->
                RemoteAddr = if IncludeIp -> ewgi_api:remote_addr(Ctx);
                                true -> ?DEFAULT_IP
                             end,
                CookieData = [{"REMOTE_USER", UserId},
                              {"REMOTE_USER_DATA", UserData},
                              {"REMOTE_ADDR", RemoteAddr}],
                CookieVal = case Encoder:encode(Key, term_to_binary(CookieData), M) of
                                {error, _Reason} ->
                                    [];
                                B ->
                                    cookie_safe_encode(B)
                            end,
                {CurDomain, WildDomain} = get_domains(Ctx),
                [simple_cookie(CookieName, CookieVal, Sec),
                 simple_cookie(CookieName, CookieVal, Sec, CurDomain),
                 simple_cookie(CookieName, CookieVal, Sec, WildDomain)]
        end,
    F.

-spec logout_user(ewgi_context(), #cka{}) -> function().
logout_user(Ctx, #cka{cookie_name=CookieName}) ->
    F = fun() ->
                {CurDomain, WildDomain} = get_domains(Ctx),
                [simple_cookie(CookieName, [], false),
                 simple_cookie(CookieName, [], false, CurDomain),
                 simple_cookie(CookieName, [], false, WildDomain)]
        end,
    F.

-spec populate_record(proplist(), #cka{}) -> #cka{} | {'error', {'invalid_option', any()}}.
populate_record(Options, Cka) ->
    lists:foldl(fun r_option/2, Cka, Options).

-spec r_option({atom(), any()}, #cka{}) -> #cka{} | {'error', {'invalid_option', any()}}.
r_option(_, PrevError) when not is_record(PrevError, cka) ->
	PrevError;
r_option({cookie_name, N}, Cka) when is_list(N) ->
    Cka#cka{cookie_name=N};
r_option({encoder, E}, Cka) ->
    Cka#cka{encoder=E};
r_option({include_ip, IncludeIp}, Cka) when is_boolean(IncludeIp) ->
    Cka#cka{include_ip=IncludeIp};
r_option({timeout, T}, Cka) when is_integer(T) ->
    Cka#cka{timeout=T};
r_option({maxlength, M}, Cka) when is_integer(M), M > 0 ->
    Cka#cka{maxlength=M};
r_option({secure, Secure}, Cka) when is_boolean(Secure) ->
    Cka#cka{secure=Secure};
r_option(O, _Cka) ->
    {error, {invalid_option, O}}.
