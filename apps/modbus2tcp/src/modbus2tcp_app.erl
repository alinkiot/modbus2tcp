%%%-------------------------------------------------------------------
%% @doc modbus2tcp public API
%% @end
%%%-------------------------------------------------------------------

-module(modbus2tcp_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    {ok, Sup} = modbus2tcp_sup:start_link(),
    modbus2tcp_dtu:start(test, "127.0.0.1", 6500),
    {ok, Sup}.

stop(_State) ->
    ok.

%% internal functions
