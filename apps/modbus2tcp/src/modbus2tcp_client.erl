-module(modbus2tcp_client).
-export([start/3, run/4, connect/4, loop/2]).
-define(TCP_OPTIONS, [binary, {packet, raw}, {active, true}]).

start(Host, Port, Num) ->
    spawn(?MODULE, run, [self(), Host, Port, Num]),
    main_loop(1).

main_loop(Count) ->
    receive
        {connected, _Sock} ->
            io:format("conneted: ~p~n", [Count]),
            main_loop(Count+1)
    end.

run(_Parent, _Host, _Port, 0) ->
    ok;
run(Parent, Host, Port, Num) ->
    spawn(?MODULE, connect, [Parent, Host, Port, Num]),
    timer:sleep(5),
    run(Parent, Host, Port, Num-1).

connect(Parent, Host, Port, Num) ->
    case gen_tcp:connect(Host, Port, ?TCP_OPTIONS, 6000) of
        {ok, Sock} ->
            Addr = list_to_binary(io_lib:format("~6.10.0B",[Num])),
            Dk = <<"P5sPmWfR">>,
            Ds = <<"4xXJZXE76bjANsFK">>,
            gen_tcp:send(Sock, <<"reg,1,", Addr/binary, ",", Dk/binary, ",", Ds/binary, "\r\n">>),
            Parent ! {connected, Sock},
            loop(Num, Sock);
        {error, Reason} ->
            io:format("Client ~p connect error: ~p~n", [Num, Reason])
    end.

loop(Num, Sock) ->
    Timeout = 5000 + rand:uniform(5000),
    receive
        {tcp, Sock, Data} ->
            io:format("Client ~w received: ~s~n", [Num, Data]),
            gen_server:call(whereis(modbus), {modbus, Data}),
            loop(Num, Sock);
        {tcp_closed, Sock} ->
            io:format("Client ~w socket closed~n", [Num]);
        {tcp_error, Sock, Reason} ->
            io:format("Client ~w socket error: ~p~n", [Num, Reason]);
        Other ->
            io:format("Client ~w unexpected: ~p", [Num, Other])
    after
        Timeout ->
            loop(Num, Sock)
    end.
