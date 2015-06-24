%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2015, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 11 Mar 2015 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(ejabberd_sm_redis).

-behaviour(ejabberd_config).

-behaviour(ejabberd_sm).

-export([init/0, set_session/1, delete_session/1,
	 get_sessions/0, get_sessions/1, get_sessions/2,
	 get_session/3, get_node_sessions/1, delete_node/1,
	 get_sessions_number/0, opt_type/1]).

-include("ejabberd.hrl").
-include("ejabberd_sm.hrl").
-include("logger.hrl").
-include("jlib.hrl").

-define(PROCNAME, 'ejabberd_redis_client').

%%%===================================================================
%%% API
%%%===================================================================
-spec init() -> ok | {error, any()}.
init() ->
    Server = ejabberd_config:get_option(redis_server,
					fun iolist_to_list/1,
					"localhost"),
    Port = ejabberd_config:get_option(redis_port,
				      fun(P) when is_integer(P),
						  P>0, P<65536 ->
					      P
				      end, 6379),
    DB = ejabberd_config:get_option(redis_db,
				    fun(I) when is_integer(I), I >= 0 ->
					    I
				    end, 0),
    Pass = ejabberd_config:get_option(redis_password,
				      fun iolist_to_list/1,
				      ""),
    ReconnTimeout = timer:seconds(
		      ejabberd_config:get_option(
			redis_reconnect_timeout,
			fun(I) when is_integer(I), I>0 -> I end,
			1)),
    ConnTimeout = timer:seconds(
		    ejabberd_config:get_option(
		      redis_connect_timeout,
		      fun(I) when is_integer(I), I>0 -> I end,
		      1)),
    case eredis:start_link(Server, Port, DB, Pass,
			   ReconnTimeout, ConnTimeout) of
	{ok, Client} ->
	    register(?PROCNAME, Client),
	    clean_table(),
	    ok;
	{error, _} = Err ->
	    ?ERROR_MSG("failed to start redis client: ~p", [Err]),
	    Err
    end.

-spec set_session(#session{}) -> ok.
set_session(Session) ->
    T = term_to_binary(Session),
    {_, _, LResource} = Session#session.usr,
    USKey = us_to_key(Session#session.us),
    ServKey = server_to_key(element(2, Session#session.us)),
    USRKey = usr_to_key(Session#session.usr),
    case eredis:qp(?PROCNAME, [["HSET", USKey, LResource, T],
			       ["HSET", ServKey, USRKey, T]]) of
	[{ok, _}, {ok, _}] ->
	    ok;
	Err ->
	    ?ERROR_MSG("failed to set session for redis: ~p", [Err])
    end.

-spec delete_session({binary(), binary(), binary()}) -> ok.
delete_session({LUser, LServer, LResource}) ->
    USKey = us_to_key({LUser, LServer}),
    ServKey = server_to_key(LServer),
    USRKey = usr_to_key({LUser, LServer, LResource}),
    eredis:qp(?PROCNAME, [["HDEL", USKey, LResource],
                          ["HDEL", ServKey, USRKey]]),
    ok.

-spec get_sessions() -> [#session{}].
get_sessions() ->
    lists:flatmap(
      fun(LServer) ->
	      get_sessions(LServer)
      end, ?MYHOSTS).

-spec get_sessions(binary()) -> [#session{}].
get_sessions(LServer) ->
    ServKey = server_to_key(LServer),
    case eredis:q(?PROCNAME, ["HGETALL", ServKey]) of
	{ok, Vals} ->
	    decode_session_list(Vals);
	Err ->
	    ?ERROR_MSG("failed to get sessions from redis: ~p", [Err]),
	    []
    end.

-spec get_sessions(binary(), binary()) -> [#session{}].
get_sessions(LUser, LServer) ->
    USKey = us_to_key({LUser, LServer}),
    case eredis:q(?PROCNAME, ["HGETALL", USKey]) of
	{ok, Vals} when is_list(Vals) ->
	    decode_session_list(Vals);
	Err ->
	    ?ERROR_MSG("failed to get sessions from redis: ~p", [Err]),
	    []
    end.

-spec get_session(binary(), binary(), binary()) ->
    {ok, #session{}} | {error, notfound}.
get_session(LUser, LServer, LResource) ->
    USKey = us_to_key({LUser, LServer}),
    case eredis:q(?PROCNAME, ["HGET", USKey, LResource]) of
	{ok, Val} when is_binary(Val) ->
            {ok, binary_to_term(Val)};
	{ok, undefined} ->
            {error, notfound};
	Err ->
	    ?ERROR_MSG("failed to get sessions from redis: ~p", [Err]),
	    {error, notfound}
    end.

get_node_sessions(Node) ->
    lists:flatmap(
      fun(LServer) ->
	      ServKey = server_to_key(LServer),
	      case eredis:q(?PROCNAME, ["HVALS", ServKey]) of
		  {ok, []} ->
		      [];
		  {ok, Vals} ->
		      lists:flatmap(
                        fun(T) ->
                                S = binary_to_term(T),
                                SID = S#session.sid,
                                if
                                    node(element(2, SID)) == Node ->
                                        [S];
                                    true -> []
                                end
                        end, Vals);
		  _Err ->
                      []
	      end
      end, ?MYHOSTS).

delete_node(Node) ->
    lists:foreach(
      fun(LServer) ->
	      ServKey = server_to_key(LServer),
	      case eredis:q(?PROCNAME, ["HVALS", ServKey]) of
		  {ok, []} ->
		      ok;
		  {ok, Vals} ->
		      Vals1 = lists:flatmap(
				fun(T) ->
                                        S = binary_to_term(T),
                                        SID = S#session.sid,
					if
                                            node(element(2, SID)) == Node ->
                                                [S];
                                            true -> []
                                        end
				end, Vals),
                      Vals2 = [usr_to_key(S#session.usr) || S <- Vals1],
		      Q1 = ["HDEL", ServKey | Vals2],
		      Q2 = lists:map(
			     fun(S) ->
                                     {_, _, R} = S#session.usr,
				     USKey = us_to_key(S#session.us),
				     ["HDEL", USKey, R]
			     end, Vals1),
		      Res = eredis:qp(?PROCNAME, [Q1|Q2]),
		      case lists:filter(
			     fun({ok, _}) -> false;
				(_) -> true
			     end, Res) of
			  [] ->
			      ok;
			  Errs ->
			      ?ERROR_MSG("failed to clean redis table for "
					 "server ~s: ~p", [LServer, Errs])
		      end;
		  Err ->
		      ?ERROR_MSG("failed to clean redis table for "
				 "server ~s: ~p", [LServer, Err])
	      end
      end, ?MYHOSTS).

get_sessions_number() ->
    lists:foldl(
      fun(LServer, Acc) ->
	      ServKey = server_to_key(LServer),
	      case eredis:q(?PROCNAME, ["HLEN", ServKey]) of
		  {ok, Count} ->
                      jlib:binary_to_integer(Count);
		  _Err ->
                      0
	      end + Acc
      end, 0, ?MYHOSTS).

%%%===================================================================
%%% Internal functions
%%%===================================================================
iolist_to_list(IOList) ->
    binary_to_list(iolist_to_binary(IOList)).

us_to_key({LUser, LServer}) ->
    <<"ejabberd:sm:", LUser/binary, "@", LServer/binary>>.

server_to_key(LServer) ->
    <<"ejabberd:sm:", LServer/binary>>.

usr_to_key({LUser, LServer, LResource}) ->
    <<"ejabberd:sm:",
     LUser/binary, "@", LServer/binary, "/", LResource/binary>>.

decode_session_list([_, Val|T]) ->
    [binary_to_term(Val)|decode_session_list(T)];
decode_session_list([]) ->
    [].

clean_table() ->
    ?INFO_MSG("Cleaning Redis SM table...", []),
    delete_node(node()).

opt_type(redis_connect_timeout) ->
    fun (I) when is_integer(I), I > 0 -> I end;
opt_type(redis_db) ->
    fun (I) when is_integer(I), I >= 0 -> I end;
opt_type(redis_password) -> fun iolist_to_list/1;
opt_type(redis_port) ->
    fun (P) when is_integer(P), P > 0, P < 65536 -> P end;
opt_type(redis_reconnect_timeout) ->
    fun (I) when is_integer(I), I > 0 -> I end;
opt_type(redis_server) -> fun iolist_to_list/1;
opt_type(_) ->
    [redis_connect_timeout, redis_db, redis_password,
     redis_port, redis_reconnect_timeout, redis_server].
