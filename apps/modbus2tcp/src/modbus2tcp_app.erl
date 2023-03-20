%%%-------------------------------------------------------------------
%% @doc modbus2tcp public API
%% @end
%%%-------------------------------------------------------------------

-module(modbus2tcp_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    modbus2tcp_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
