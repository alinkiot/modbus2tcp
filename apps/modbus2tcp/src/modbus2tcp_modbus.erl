-module(modbus2tcp_modbus).
-behaviour(gen_server).

%% API
-export([start/0, start/1, start_link/4, start_link/5, stop/1, send_call/3, send_cast/2, do_sync_command/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
    terminate/2, code_change/3]).

-type pipeline() :: [iolist()].


-type reconnect_sleep() :: no_reconnect | integer().

-record(state, {
    host :: string() | undefined,
    port :: integer() | undefined,
    reconnect_sleep :: reconnect_sleep() | undefined,
    connect_timeout :: integer() | undefined,
    socket_options :: list(),
    socket :: port() | undefined,
    queue :: undefined
}).

-define(SOCKET_MODE, binary).
-define(SOCKET_OPTS, [{active, once}, {packet, raw}, {reuseaddr, false},
    {keepalive, false}, {send_timeout, ?SEND_TIMEOUT}]).

-define(RECV_TIMEOUT, 5000).
-define(SEND_TIMEOUT, 5000).
%%
%% API
%%

start() ->
    {ok, Opts} = application:get_env(modbus2tcp, modbus),
    start(Opts).

start(Opts) ->
    Host = proplists:get_value(host, Opts),
    Port = proplists:get_value(port, Opts),
    Args = [Host, Port, 5000, 30000],
    supervisor:start_child(modbus2tcp_modbus_sup, Args).


send_call(Pid, Data, Timeout) ->
    gen_server:call(Pid, {request, Data}, Timeout).

send_cast(Pid, Data) ->
    gen_server:cast(Pid, {request, Data}).

start_link(Host, Port, ReconnectSleep, ConnectTimeout) ->
    start_link(Host, Port, ReconnectSleep, ConnectTimeout, []).

start_link(Host, Port, ReconnectSleep, ConnectTimeout, SocketOptions) ->
    gen_server:start_link(?MODULE, [Host, Port,
        ReconnectSleep, ConnectTimeout, SocketOptions], []).


stop(Pid) ->
    gen_server:call(Pid, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host, Port, ReconnectSleep, ConnectTimeout, SocketOptions]) ->
    State = #state{host = Host,
        port = Port,
        reconnect_sleep = ReconnectSleep,
        connect_timeout = ConnectTimeout,
        socket_options = SocketOptions,
        queue = queue:new()
    },
    case ReconnectSleep of
        no_reconnect ->
            case connect(State) of
                {ok, _NewState} = Res -> Res;
                {error, Reason} -> {stop, Reason}
            end;
        T when is_integer(T) ->
            self() ! initiate_connection,
            {ok, State}
    end.

handle_call({request, Req}, From, State) ->
    do_request(Req, From, State);

handle_call({pipeline, Pipeline}, From, State) ->
    do_pipeline(Pipeline, From, State);

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(_Request, _From, State) ->
    {reply, unknown_request, State}.


handle_cast({request, Req}, State) ->
    case do_request(Req, undefined, State) of
        {reply, _Reply, State1} ->
            {noreply, State1};
        {noreply, State1} ->
            {noreply, State1}
    end;

handle_cast({request, Req, Pid}, State) ->
    case do_request(Req, Pid, State) of
        {reply, Reply, State1} ->
            safe_send(Pid, {response, Reply}),
            {noreply, State1};
        {noreply, State1} ->
            {noreply, State1}
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Receive data from socket, see handle_response/2. Match `Socket' to
%% enforce sanity.
handle_info({tcp, Socket, Bs}, #state{socket = Socket} = State) ->
    io:format("Modbus Recv:~p~n", [Bs]),
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, handle_response(Bs, State)};

handle_info({tcp, Socket, _}, #state{socket = OurSocket} = State)
    when OurSocket =/= Socket ->
    %% Ignore tcp messages when the socket in message doesn't match
    %% our state. In order to test behavior around receiving
    %% tcp_closed message with clients waiting in queue, we send a
    %% fake tcp_close message. This allows us to ignore messages that
    %% arrive after that while we are reconnecting.
    {noreply, State};

handle_info({tcp_error, _Socket, _Reason}, State) ->
    %% This will be followed by a close
    {noreply, State};

%% Socket got closed, for example by Redis terminating idle
%% clients. If desired, spawn of a new process which will try to reconnect and
%% notify us when Redis is ready. In the meantime, we can respond with
%% an error message to all our clients.
handle_info({tcp_closed, _Socket}, State) ->
    maybe_reconnect(tcp_closed, State);

%% Redis is ready to accept requests, the given Socket is a socket
%% already connected and authenticated.
handle_info({connection_ready, Socket}, #state{socket = undefined} = State) ->
    {noreply, State#state{socket = Socket}};

%% eredis can be used in Poolboy, but it requires to support a simple API
%% that Poolboy uses to manage the connections.
handle_info(stop, State) ->
    {stop, shutdown, State};

handle_info(initiate_connection, #state{socket = undefined} = State) ->
    case connect(State) of
        {ok, NewState} ->
            {noreply, NewState};
        {error, Reason} ->
            maybe_reconnect(Reason, State)
    end;

handle_info(_Info, State) ->
    {stop, {unhandled_message, _Info}, State}.

terminate(_Reason, State) ->
    case State#state.socket of
        undefined -> ok;
        Socket    -> gen_tcp:close(Socket)
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

-spec do_request(Req::iolist(), From::pid(), #state{}) ->
    {noreply, #state{}} | {reply, Reply::any(), #state{}}.
%% @doc: Sends the given request to redis. If we do not have a
%% connection, returns error.
do_request(_Req, _From, #state{socket = undefined} = State) ->
    {reply, {error, no_connection}, State};

do_request(Req, From, State) ->
    case gen_tcp:send(State#state.socket, Req) of
        ok ->
            io:format("Send Succ:~p~n", [Req]),
            NewQueue = queue:in({1, From}, State#state.queue),
            {noreply, State#state{queue = NewQueue}};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

-spec do_pipeline(Pipeline::pipeline(), From::pid(), #state{}) ->
    {noreply, #state{}} | {reply, Reply::any(), #state{}}.
%% @doc: Sends the entire pipeline to redis. If we do not have a
%% connection, returns error.
do_pipeline(_Pipeline, _From, #state{socket = undefined} = State) ->
    {reply, {error, no_connection}, State};

do_pipeline(Pipeline, From, State) ->
    case gen_tcp:send(State#state.socket, Pipeline) of
        ok ->
            NewQueue = queue:in({length(Pipeline), From, []}, State#state.queue),
            {noreply, State#state{queue = NewQueue}};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

-spec handle_response(Data::binary(), State::#state{}) -> NewState::#state{}.
%% @doc: Handle the response coming from Redis. This includes parsing
%% and replying to the correct client, handling partial responses,
%% handling too much data and handling continuations.
handle_response(Data, #state{queue = Queue} = State) ->
    NewQueue = reply({ok, Data}, Queue),
    State#state{ queue = NewQueue }.

%% @doc: Sends a value to the first client in queue. Returns the new
%% queue without this client. If we are still waiting for parts of a
%% pipelined request, push the reply to the the head of the queue and
%% wait for another reply from redis.
reply(Value, Queue) ->
    case queue:out(Queue) of
        {{value, {1, From}}, NewQueue} ->
            safe_reply(From, Value),
            NewQueue;
        {{value, {1, From, Replies}}, NewQueue} ->
            safe_reply(From, lists:reverse([Value | Replies])),
            NewQueue;
        {{value, {N, From, Replies}}, NewQueue} when N > 1 ->
            queue:in_r({N - 1, From, [Value | Replies]}, NewQueue);
        {empty, Queue} ->
            %% Oops
            error_logger:info_msg("Nothing in queue, but got value from parser~n"),
            exit(empty_queue)
    end.

%% @doc Send `Value' to each client in queue. Only useful for sending
%% an error message. Any in-progress reply data is ignored.
reply_all(Value, Queue) ->
    case queue:peek(Queue) of
        empty ->
            ok;
        {value, Item} ->
            safe_reply(receipient(Item), Value),
            reply_all(Value, queue:drop(Queue))
    end.

receipient({_, From}) ->
    From;
receipient({_, From, _}) ->
    From.

safe_reply(undefined, _Value) ->
    ok;
safe_reply(Pid, Value) when is_pid(Pid) ->
    safe_send(Pid, {response, Value});
safe_reply(From, Value) ->
    gen_server:reply(From, Value).

safe_send(Pid, Value) ->
    try erlang:send(Pid, Value)
    catch
        Err:Reason ->
            error_logger:info_msg("Failed to send message to ~p with reason ~p~n", [Pid, {Err, Reason}])
    end.

%% @doc: Helper for connecting to Redis, authenticating and selecting
%% the correct database. These commands are synchronous and if Redis
%% returns something we don't expect, we crash. Returns {ok, State} or
%% {SomeError, Reason}.
connect(#state{host = Addr, port = Port} = State) ->
    SocketOptions = lists:ukeymerge(1, lists:keysort(1, State#state.socket_options), lists:keysort(1, ?SOCKET_OPTS)),
    ConnectOptions = [?SOCKET_MODE | SocketOptions],
    case gen_tcp:connect(Addr, Port, ConnectOptions, State#state.connect_timeout) of
        {ok, Socket} ->
            {ok, State#state{socket = Socket }};
        {error, Reason} ->
            {error, {connection_error, Reason}}
    end.

do_sync_command(Socket, Command) ->
    ok = inet:setopts(Socket, [{active, false}]),
    case gen_tcp:send(Socket, Command) of
        ok ->
            %% Hope there's nothing else coming down on the socket..
            case gen_tcp:recv(Socket, 0, ?RECV_TIMEOUT) of
                {ok, Data} ->
                    ok = inet:setopts(Socket, [{active, once}]),
                    {ok, Data};
                Other ->
                    {error, {unexpected_data, Other}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

maybe_reconnect(Reason, #state{reconnect_sleep = no_reconnect, queue = Queue} = State) ->
    reply_all({error, Reason}, Queue),
    %% If we aren't going to reconnect, then there is nothing else for
    %% this process to do.
    {stop, normal, State#state{socket = undefined}};
maybe_reconnect(Reason, #state{queue = Queue} = State) ->
    error_logger:error_msg("Re-establishing connection to ~p:~p due to ~p",
        [State#state.host, State#state.port, Reason]),
    Self = self(),
    spawn_link(fun() -> reconnect_loop(Self, State) end),

    %% tell all of our clients what has happened.
    reply_all({error, Reason}, Queue),

    %% Throw away the socket and the queue, as we will never get a
    %% response to the requests sent on the old socket. The absence of
    %% a socket is used to signal we are "down"
    {noreply, State#state{socket = undefined, queue = queue:new()}}.

%% @doc: Loop until a connection can be established, this includes
%% successfully issuing the auth and select calls. When we have a
%% connection, give the socket to the redis client.
reconnect_loop(Client, #state{reconnect_sleep = ReconnectSleep} = State) ->
    case catch(connect(State)) of
        {ok, #state{socket = Socket}} ->
            Client ! {connection_ready, Socket},
            gen_tcp:controlling_process(Socket, Client),
            Msgs = get_all_messages([]),
            [Client ! M || M <- Msgs];
        {error, _Reason} ->
            timer:sleep(ReconnectSleep),
            reconnect_loop(Client, State);
        %% Something bad happened when connecting, like Redis might be
        %% loading the dataset and we got something other than 'OK' in
        %% auth or select
        _ ->
            timer:sleep(ReconnectSleep),
            reconnect_loop(Client, State)
    end.


get_all_messages(Acc) ->
    receive
        M ->
            [M | Acc]
    after 0 ->
        lists:reverse(Acc)
    end.
