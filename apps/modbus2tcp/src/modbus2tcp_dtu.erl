-module(modbus2tcp_dtu).
-behaviour(gen_server).

%% API
-export([start/3, start_link/6, start_link/5, stop/1, do_sync_command/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
    terminate/2, code_change/3]).



-type reconnect_sleep() :: no_reconnect | integer().

-record(state, {
    host :: string() | undefined,
    port :: integer() | undefined,
    reconnect_sleep :: reconnect_sleep() | undefined,
    connect_timeout :: integer() | undefined,
    socket_options :: list(),
    socket :: port() | undefined,
    modbus :: pid()
}).

-define(SOCKET_MODE, binary).
-define(SOCKET_OPTS, [{active, once}, {packet, raw}, {reuseaddr, false},
    {keepalive, false}, {send_timeout, ?SEND_TIMEOUT}]).

-define(RECV_TIMEOUT, 5000).
-define(SEND_TIMEOUT, 5000).
%%
%% API
%%

start(Name, Host, Port) ->
    supervisor:start_child(modbus2tcp_dtu_sup, [Name, Host, Port, 30000, 5000]).


start_link(Name, Host, Port, ReconnectSleep, ConnectTimeout) ->
    start_link(Name, Host, Port, ReconnectSleep, ConnectTimeout, []).

start_link(Name, Host, Port, ReconnectSleep, ConnectTimeout, SocketOptions) ->
    gen_server:start_link({local, Name}, ?MODULE, [Host, Port,
        ReconnectSleep, ConnectTimeout, SocketOptions], []).


stop(Pid) ->
    gen_server:call(Pid, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host, Port, ReconnectSleep, ConnectTimeout, SocketOptions]) ->
    {ok, Pid} = modbus2tcp_modbus:start(),
    erlang:monitor(process, Pid),
    State = #state{host = Host,
        port = Port,
        reconnect_sleep = ReconnectSleep,
        connect_timeout = ConnectTimeout,
        socket_options = SocketOptions,
        modbus = Pid
    },
    case ReconnectSleep of
        no_reconnect ->
            case connect(State) of
                {ok, _NewState} = Res ->
                    Res;
                {error, Reason} ->
                    {stop, Reason}
            end;
        T when is_integer(T) ->
            self() ! initiate_connection,
            {ok, State}
    end.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(_Request, _From, State) ->
    {reply, unknown_request, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _, process, Pid, Info}, #state{ modbus = Pid } = State) ->
    io:format("modbus(~p) exit ~p~n", [Pid, Info]),
    {ok, Pid1} = modbus2tcp_modbus:start(),
    erlang:monitor(process, Pid1),
    {noreply, State#state{ modbus = Pid1 }};

handle_info({tcp, Socket, Bs}, #state{socket = Socket} = State) ->
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, handle_response(Bs, State)};

handle_info({tcp, Socket, _}, #state{socket = OurSocket} = State)
    when OurSocket =/= Socket ->
    {noreply, State};

handle_info({tcp_error, _Socket, _Reason}, State) ->
    {noreply, State};

handle_info({tcp_closed, _Socket}, State) ->
    maybe_reconnect(tcp_closed, State);

handle_info({connection_ready, Socket}, #state{socket = undefined} = State) ->
    {noreply, State#state{socket = Socket}};

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

connect(#state{host = Addr, port = Port } = State) ->
    SocketOptions = lists:ukeymerge(1, lists:keysort(1, State#state.socket_options), lists:keysort(1, ?SOCKET_OPTS)),
    ConnectOptions = [?SOCKET_MODE | SocketOptions],
    case gen_tcp:connect(Addr, Port, ConnectOptions, State#state.connect_timeout) of
        {ok, Socket} ->
%%            DevId = list_to_binary(io_lib:format("~6.10.0B", [1])),
%%            DevId = <<"UYZ-000001">>,
%%            Dk = <<"6d5wZ8As">>,
%%            Ds = <<"SXazH5AmRx3AcNca">>,

            DevId = <<"ZLWIFI5020001">>,
            Dk = <<"kNTCkazx">>,
            Ds = <<"Rkr4MYYwx2HSHZSD">>,


            Command = <<"reg,1,", DevId/binary, ",", Dk/binary, ",", Ds/binary, "\\r\\n">>,
            case do_sync_command(Socket, Command) of
                ok ->
                    {ok, State#state{socket = Socket}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, {connection_error, Reason}}
    end.

handle_response(<<"Welcome to the AsyncSocket Echo Server\r\n">>, State) ->
    State;
handle_response(Data, #state{ modbus = Pid, socket = Socket } = State) ->
    case modbus2tcp_modbus:send_call(Pid, Data, 5000) of
        {ok, Recv} ->
            gen_tcp:send(Socket, Recv);
        {error, Reason} ->
            io:format("send to modbus error ~p~n", [Reason])
    end,
    State#state{  }.

do_sync_command(Socket, Command) ->
    ok = inet:setopts(Socket, [{active, false}]),
    case gen_tcp:send(Socket, Command) of
        ok ->
            io:format("DTU(~p) Send: ~p~n", [self(), Command]),
%%            case gen_tcp:recv(Socket, 0, ?RECV_TIMEOUT) of
%%                {ok, Data} ->
                    ok = inet:setopts(Socket, [{active, once}]),
                    ok;
%%                Other ->
%%                    {error, {unexpected_data, Other}}
%%            end;
        {error, Reason} ->
            {error, Reason}
    end.

maybe_reconnect(Reason, #state{reconnect_sleep = no_reconnect } = State) ->
    {stop, Reason, State#state{socket = undefined}};
maybe_reconnect(Reason, #state{ } = State) ->
    error_logger:error_msg("Re-establishing connection to ~p:~p due to ~p",
        [State#state.host, State#state.port, Reason]),
    Self = self(),
    spawn_link(fun() -> reconnect_loop(Self, State) end),
    {noreply, State#state{socket = undefined}}.


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
