%%%-------------------------------------------------------------------
%% @doc modbus2tcp public API
%% @end
%%%-------------------------------------------------------------------

-module(modbus2tcp_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    {ok, Sup} = modbus2tcp_sup:start_link(),
    modbus2tcp_listen:start(modbus, 3400),
    {ok, Sup}.

stop(_State) ->
    ok.

%% internal functions
