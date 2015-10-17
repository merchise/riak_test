%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Basho Technologies, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
%% @doc A module to test Spark fail/recovery under BDP service manager.

-module(bdp_spark_pi_submit_test).
-behavior(riak_test).
-export([confirm/0]).
-include_lib("eunit/include/eunit.hrl").

%spark master definitions
-define(SPARK_MASTER_SERVICE_NAME, "my-spark-master").
-define(SPARK_MASTER_SERVICE_TYPE, "spark-master").
-define(SPARK_MASTER_SERVICE_CONFIG, [{"HOST", "127.0.0.1"},{"RIAK_HOST","127.0.0.1:8087"}]).
%spark worker definitions
-define(SPARK_WORKER_SERVICE_NAME, "my-spark-worker").
-define(SPARK_WORKER_SERVICE_TYPE, "spark-worker").
-define(SPARK_WORKER_SERVICE_CONFIG, [{"MASTER_URL", "spark://127.0.0.1:7077"},{"SPARK_WORKER_PORT","8081"}]).


% this code tests if a spark job can successfully be submitted to a two
% node spark cluster within a three node bdp cluster

% WARNINGS: spark worker configs must contain exact ip address of
% spark master, not 127.0.0.1.  Otherwise, spark master and worker
% will fail to link together.  As such, we determine the routed
% address using inet:getifaddrs/0.

confirm() ->

    %% prepare for httpc:request/1
    ok = application:start(inets),

    %build cluster
    lager:info("Building cluster"),
    ClusterSize = 3,
    _Nodes = [Node1, Node2, _Node3] =
        bdp_util:build_cluster(
          ClusterSize, [{lager, [{handlers, [{file, "console.log"}, {level, debug}] }]}]),

    %% add spark master and worker services
    lager:info("Adding Spaker Master and Spark Worker Service..."),
    %% add master service
    ok = bdp_util:add_service(Node1, ?SPARK_MASTER_SERVICE_NAME, ?SPARK_MASTER_SERVICE_TYPE, ?SPARK_MASTER_SERVICE_CONFIG),
    ok = bdp_util:wait_services(Node1, {[], [?SPARK_MASTER_SERVICE_NAME]}),
    %% add worker service
    [{_IfaceName, SparkMasterIP_}|_] = get_routed_interfaces(Node1),
    SparkMasterIP = inet:ntoa(SparkMasterIP_),
    SparkMasterAddr = "spark://"++SparkMasterIP++":7077",
    WorkerConfig = [{"MASTER_URL", SparkMasterAddr},{"SPARK_WORKER_PORT","8081"}],

    ok = bdp_util:add_service(Node2, ?SPARK_WORKER_SERVICE_NAME, ?SPARK_WORKER_SERVICE_TYPE, WorkerConfig),
    ok = bdp_util:wait_services(Node2, {[], [?SPARK_MASTER_SERVICE_NAME, ?SPARK_WORKER_SERVICE_NAME]}),

    lager:info("Service ~p (~s) added", [?SPARK_MASTER_SERVICE_NAME, ?SPARK_MASTER_SERVICE_TYPE]),
    %start master and worker
    ok = bdp_util:start_seervice(Node1, Node1, ?SPARK_MASTER_SERVICE_NAME, ?SPARK_MASTER_SERVICE_TYPE),
    ok = bdp_util:wait_services(Node1, {[?SPARK_MASTER_SERVICE_NAME], [?SPARK_MASTER_SERVICE_NAME, ?SPARK_WORKER_SERVICE_NAME]}),
    ok = bdp_util:start_seervice(Node2, Node2, ?SPARK_WORKER_SERVICE_NAME, ?SPARK_MASTER_SERVICE_TYPE),
    ok = bdp_util:wait_services(Node2, {[?SPARK_MASTER_SERVICE_NAME,?SPARK_WORKER_SERVICE_NAME], [?SPARK_MASTER_SERVICE_NAME, ?SPARK_WORKER_SERVICE_NAME]}),

    lager:info("Waiting 10 seconds..."),
    timer:sleep(10000),

    %check running services
    {Run,Ava} = bdp_util:get_services(Node1),

    MyServices = ["my-spark-master","my-spark-worker"],
    ?assert(Run == MyServices),
    ?assert(Ava == MyServices),
    lager:info("~s",[MyServices]),
    lager:info("Running: ~s", [Run]),
    lager:info("Available: ~s", [Ava]),

    %%run spark job pi.py
    SparkJobSubmit1 = "./lib/data_platform-1/priv/spark-master/bin/spark-submit --master ",
    SparkJobSubmit2 = " ./lib/data_platform-1/priv/spark-master/examples/src/main/python/pi.py 100",
    SparkJobSubmit3 = SparkJobSubmit1++SparkMasterAddr++SparkJobSubmit2,
    Results = rpc:call(Node2,os,cmd,[SparkJobSubmit3]),
    lager:info("Spark Job Results: ~s", [Results]),

    %Test if the spark job submission worked
    ?assert(string:str(Results,"Pi is roughly") > 0),

    %Assert proper cluster execution of spark job
    {ok, _Headers, Content_} = httpc:request("http://"++SparkMasterIP++":8080"),
    Content = unicode:characters_to_list(Content_),
    %assert master and worker see each other
    TestString1 = "<li><strong>Workers:</strong> 1</li>",
    ?assert(string:str(Content,TestString1) > 0),
    %assert job execution in cluster
    TestString2 = "<li><strong>Applications:</strong>
                0 Running,
                1 Completed </li>",
    ?assert(string:str(Content,TestString2) > 0),

    pass.


-spec get_routed_interfaces(node()) -> [{Iface::string(), inet:ip_address()}].
%% @private
get_routed_interfaces(Node) ->
    case rpc:call(Node, inet, getifaddrs, []) of
        {ok, Ifaces} ->
            lists:filtermap(
              fun({Iface, Details}) ->
                      case is_routed_addr(Details) of
                          undefined ->
                              false;
                          Addr ->
                              {true, {Iface, Addr}}
                      end
              end,
              Ifaces);
        {error, PosixCode} ->
            error(io_lib:format("Failed to enumerate network ifaces: ~p", [PosixCode]))
    end.


-spec is_routed_addr([{Ifname::string(), Ifopt::[{atom(), any()}]}]) ->
    inet:ip_address() | undefined.
%% @private
is_routed_addr(Details) ->
    Flags = proplists:get_value(flags, Details),
    case {(is_list(Flags) andalso
           %% andalso lists:member(running, Flags)
           %% iface is reported as 'running' when it's not according
           %% to ifconfig -- why?
           not lists:member(loopback, Flags)),
          proplists:get_all_values(addr, Details)} of
        {true, [_|_] = Ipv4AndPossibly6} ->
            %% prefer the ipv4 addr (4-elem tuple < 6-elem tuple),
            %% only select ipv6 if ipv4 is missing
            hd(lists:sort(Ipv4AndPossibly6));
        _ ->
            undefined
    end.