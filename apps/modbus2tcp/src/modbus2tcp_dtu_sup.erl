%%%-------------------------------------------------------------------
%% @doc modbus2tcp top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(modbus2tcp_dtu_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 0,
                 period => 1},
    ChildSpecs = [#{
        id => modbus2tcp_dtu,
        start => {modbus2tcp_dtu, start_link, []},
        restart => transient,
        shutdown => 2000,
        type => worker,
        modules => [modbus2tcp_dtu]
    }],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
