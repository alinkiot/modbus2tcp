-module(modbus2tcp_listen).

-include_lib("esockd/include/esockd.hrl").

-behaviour(gen_server).

%% start
-export([start/2]).

%% esockd callback
-export([start_link/3]).

%% gen_server function exports
-export([ init/1
    , handle_call/3
    , handle_cast/2
    , handle_info/2
    , terminate/2
    , code_change/3
]).

-record(state, {transport, socket, from}).

start(Name, Port) ->
    ok = esockd:start(),
    Opts = [{acceptors, 2},
        {max_connections, 100000},
        {max_conn_rate, 10}
    ],
    MFArgs = {?MODULE, start_link, [Name]},
    esockd:open(echo, Port, Opts, MFArgs).

start_link(Transport, Sock, Name) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [[Transport, Sock, Name]])}.

init([Transport, Sock, Name]) ->
    case Transport:wait(Sock) of
        {ok, NewSock} ->
            register(Name, self()),
            Transport:setopts(Sock, [{active, once}]),
            gen_server:enter_loop(?MODULE, [], #state{transport = Transport, socket = NewSock});
        {error, Reason} ->
            {stop, Reason}
    end.



handle_call({modbus, Data}, From, #state{transport = Transport, socket = Socket, from = undefined } = State) ->
    Transport:send(Socket, Data),
    {noreply, State#state{ from = From }};
handle_call({modbus, _Data}, From, #state{ from = From } = State) ->
    {reply, {error, busy}, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({tcp, Sock, Data}, State = #state{transport = Transport, socket = Sock, from = From }) ->
    {ok, Peername} = Transport:peername(Sock),
    io:format("Data from ~s: ~s~n", [esockd:format(Peername), binary:encode_hex(iolist_to_binary(Data))]),
    From =/= undefined andalso gen_server:reply(State#state.from, {ok, Data}),
    Transport:setopts(Sock, [{active, once}]),
    {noreply, State#state{ from = undefined }};

handle_info({tcp_error, Sock, Reason}, State = #state{socket = Sock}) ->
    io:format("Error from: ~p~n", [Sock]),
    io:format("tcp_error: ~s~n", [Reason]),
    {stop, {shutdown, Reason}, State};

handle_info({tcp_closed, Sock}, State = #state{socket = Sock}) ->
    io:format("tcp_closed~n"),
    {stop, normal, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
