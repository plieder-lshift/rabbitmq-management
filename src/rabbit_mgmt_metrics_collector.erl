%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%
-module(rabbit_mgmt_metrics_collector).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_core_metrics.hrl").
-include("rabbit_mgmt_metrics.hrl").

-behaviour(gen_server).

-spec start_link(atom()) -> rabbit_types:ok_pid_or_error().

-export([name/1]).
-export([start_link/1]).
-export([override_lookups/2, reset_lookups/1]).
-export([delete_queue/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).
-export([index_table/2]).

-import(rabbit_misc, [pget/3]).
-import(rabbit_mgmt_db, [pget/2, lookup_element/3]).

-record(state, {table, interval, policies, rates_mode, lookup_queue, lookup_exchange}).

%% Data is stored in ETS tables:
%% * One ETS table per metric (queue_stats, channel_stats_deliver_stats...)
%%   (see ?TABLES in rabbit_mgmt_metrics.hrl)
%% * Stats are stored as key value pairs where the key is a tuple of
%%  some value (such as a channel pid) and the retention interval.
%%  The value is an instance of an exometer_slide providing a sliding window
%%  of samples for some {Object, Interval}.
%% * Each slide can store multiple stats. See stats_per_table in
%%  rabbit_mgmt_metrics.hrl for a map of which stats are recorded in which
%%  table.


name(Table) ->
    list_to_atom((atom_to_list(Table) ++ "_metrics_collector")).


start_link(Table) ->
    gen_server:start_link({local, name(Table)}, ?MODULE, [Table], []).

override_lookups(Table, Lookups) ->
    gen_server:call(name(Table), {override_lookups, Lookups}, infinity).

reset_lookups(Table) ->
    gen_server:call(name(Table), reset_lookups, infinity).

delete_queue(Table, Queue, Stats) ->
    gen_server:cast(name(Table), {delete_queue, Queue, Stats}).

init([Table]) ->
    {ok, RatesMode} = application:get_env(rabbitmq_management, rates_mode),
    {ok, Policies} = application:get_env(
                       rabbitmq_management, sample_retention_policies),
    Policy = retention_policy(Table),
    Interval = take_smaller(proplists:get_value(Policy, Policies)) * 1000,
    erlang:send_after(Interval, self(), collect_metrics),
    {ok, #state{table = Table, interval = Interval,
                policies = {proplists:get_value(basic, Policies),
                            proplists:get_value(detailed, Policies),
                            proplists:get_value(global, Policies)},
                rates_mode = RatesMode,
                lookup_queue = fun queue_exists/1,
                lookup_exchange = fun exchange_exists/1}}.

handle_call(reset_lookups, _From, State) ->
    {reply, ok, State#state{lookup_queue = fun queue_exists/1,
			    lookup_exchange = fun exchange_exists/1}};
handle_call({override_lookups, Lookups}, _From, State) ->
    {reply, ok, State#state{lookup_queue = pget(queue, Lookups),
			    lookup_exchange = pget(exchange, Lookups)}};
handle_call({submit, Fun}, _From, State) ->
    {reply, Fun(), State};
handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast({delete_queue, Queue, {R, U, M}}, State = #state{table = queue_coarse_metrics,
							     policies = {_, _, GPolicies}}) ->
    TS = exometer_slide:timestamp(),
    NegStats = ?vhost_msg_stats(-R, -U, -M),
    [insert_entry(vhost_msg_stats, vhost(Queue), TS, NegStats, Size, Interval, true)
     || {Size, Interval} <- GPolicies],
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.


handle_info(collect_metrics, #state{interval = Interval} = State) ->
    Timestamp = exometer_slide:timestamp(),
    aggregate_metrics(Timestamp, State),
    erlang:send_after(Interval, self(), collect_metrics),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

retention_policy(connection_created) -> basic; %% really nothing
retention_policy(connection_metrics) -> basic;
retention_policy(connection_coarse_metrics) -> basic;
retention_policy(channel_created) -> basic;
retention_policy(channel_metrics) -> basic;
retention_policy(channel_queue_exchange_metrics) -> detailed;
retention_policy(channel_exchange_metrics) -> detailed;
retention_policy(channel_queue_metrics) -> detailed;
retention_policy(channel_process_metrics) -> basic;
retention_policy(consumer_created) -> basic;
retention_policy(queue_metrics) -> basic;
retention_policy(queue_coarse_metrics) -> basic;
retention_policy(node_persister_metrics) -> global;
retention_policy(node_coarse_metrics) -> global;
retention_policy(node_metrics) -> basic;
retention_policy(node_node_metrics) -> global.

take_smaller(Policies) ->
    lists:min([I || {_, I} <- Policies]).

aggregate_metrics(Timestamp, State) ->
    Table = State#state.table,
    ets:foldl(
        fun(R, noacc) ->
            _ = aggregate_entry(Timestamp, R, State),
            noacc
        end,
        noacc,
        Table).

aggregate_entry(_TS, {Id, Metrics}, #state{table = connection_created}) ->
    Ftd = rabbit_mgmt_format:format(
	    Metrics,
	    {fun rabbit_mgmt_format:format_connection_created/1, true}),
    ets:insert(connection_created_stats,
	       ?connection_created_stats(Id, pget(name, Ftd, unknown), Ftd));
aggregate_entry(_TS, {Id, Metrics}, #state{table = connection_metrics}) ->
    ets:insert(connection_stats, ?connection_stats(Id, Metrics));
aggregate_entry(TS, {Id, RecvOct, SendOct, Reductions},
                #state{table = connection_coarse_metrics,
                       policies = {BPolicies, _, GPolicies}}) ->
    Stats = ?vhost_stats_coarse_conn_stats(RecvOct, SendOct),
    Diff = get_difference(Id, Stats),
    ets:insert(old_aggr_stats, ?old_aggr_stats(Id, Stats)),
    [insert_entry(vhost_stats_coarse_conn_stats, vhost({connection_created_stats, Id}),
		 TS, Diff, Size, Interval, true) || {Size, Interval} <- GPolicies],
    [begin
         insert_entry(connection_stats_coarse_conn_stats, Id, TS,
                      ?connection_stats_coarse_conn_stats(RecvOct, SendOct, Reductions),
                      Size, Interval, false)
     end || {Size, Interval} <- BPolicies];
aggregate_entry(_TS, {Id, Metrics}, #state{table = channel_created}) ->
    Ftd = rabbit_mgmt_format:format(Metrics, {[], false}),
    ets:insert(channel_created_stats,
               ?channel_created_stats(Id, pget(name, Ftd, unknown), Ftd));
aggregate_entry(_TS, {Id, Metrics}, #state{table = channel_metrics}) ->
    Ftd = rabbit_mgmt_format:format(Metrics,
				    {fun rabbit_mgmt_format:format_channel_stats/1, true}),
    ets:insert(channel_stats, ?channel_stats(Id, Ftd));
aggregate_entry(TS, {{Ch, X} = Id, Metrics}, #state{table = channel_exchange_metrics,
                                                    policies = {BPolicies, DPolicies, GPolicies},
                                                    rates_mode = RatesMode,
                                                    lookup_exchange = ExchangeFun}) ->
    Stats = ?channel_stats_fine_stats(pget(publish, Metrics, 0),
                                      pget(confirm, Metrics, 0),
                                      pget(return_unroutable, Metrics, 0)),
    {Publish, _, _} = Diff = get_difference(Id, Stats),
    ets:insert(old_aggr_stats, ?old_aggr_stats(Id, Stats)),
    %% Custom insert for channel only to avoid ambiguity with {Channel, Queue} key
    ets:insert(index_table(old_aggr_stats, channel), {Ch, Id}),
    [begin
         insert_entry(channel_stats_fine_stats, Ch, TS, Diff, Size, Interval,
                      true)
     end || {Size, Interval} <- BPolicies],
    [begin
         insert_entry(vhost_stats_fine_stats, vhost(X), TS, Diff, Size,
                      Interval, true)
     end || {Size, Interval} <- GPolicies],
    case {ExchangeFun(X), RatesMode} of
        {true, basic} ->
            [insert_entry(exchange_stats_publish_in, X, TS,
                          ?exchange_stats_publish_in(Publish), Size, Interval, true)
             || {Size, Interval} <- DPolicies];
        {true, _} ->
            [begin
             insert_entry(exchange_stats_publish_in, X, TS,
                          ?exchange_stats_publish_in(Publish), Size, Interval, true),
             insert_entry(channel_exchange_stats_fine_stats, Id, TS, Stats,
                          Size, Interval, false)
             end || {Size, Interval} <- DPolicies];
        _ ->
            ok
    end;
aggregate_entry(TS, {{Ch, Q} = Id, Metrics}, #state{table = channel_queue_metrics,
                                                    policies = {BPolicies, DPolicies, GPolicies},
                                                    rates_mode = RatesMode,
                                                    lookup_queue = QueueFun}) ->
    Deliver = pget(deliver, Metrics, 0),
    DeliverNoAck = pget(deliver_no_ack, Metrics, 0),
    Get = pget(get, Metrics, 0),
    GetNoAck = pget(get_no_ack, Metrics, 0),
    Stats = ?vhost_stats_deliver_stats(Get, GetNoAck, Deliver, DeliverNoAck,
				       pget(redeliver, Metrics, 0),
				       pget(ack, Metrics, 0),
				       Deliver + DeliverNoAck + Get + GetNoAck),
    Diff = get_difference(Id, Stats),
    insert_with_index(old_aggr_stats, Id, ?old_aggr_stats(Id, Stats)),
    [begin
	 insert_entry(vhost_stats_deliver_stats, vhost(Q), TS, Diff, Size,
		      Interval, true)
     end || {Size, Interval} <- GPolicies],
    [begin
	 insert_entry(channel_stats_deliver_stats, Ch, TS, Diff, Size, Interval,
		      true)
     end || {Size, Interval} <- BPolicies],
     case {QueueFun(Q), RatesMode} of
     {true, basic} ->
	    [insert_entry(queue_stats_deliver_stats, Q, TS, Diff, Size, Interval,
			  true) || {Size, Interval} <- BPolicies];
     {true, _} ->
	    [insert_entry(queue_stats_deliver_stats, Q, TS, Diff, Size, Interval,
			  true) || {Size, Interval} <- BPolicies],
	    [insert_entry(channel_queue_stats_deliver_stats, Id, TS, Stats, Size,
                      Interval, false)
         || {Size, Interval} <- DPolicies];
	_ ->
	    ok
    end;
aggregate_entry(TS, {{_Ch, {Q, X}} = Id, Publish},
                #state{table = channel_queue_exchange_metrics,
                       policies = {BPolicies, _, _},
                       rates_mode = RatesMode,
                       lookup_queue = QueueFun,
                       lookup_exchange = ExchangeFun}) ->
    Stats = ?queue_stats_publish(Publish),
    Diff = get_difference(Id, Stats),
    insert_with_index(old_aggr_stats, Id, ?old_aggr_stats(Id, Stats)),
    case {QueueFun(Q), ExchangeFun(Q), RatesMode} of
        {true, false, _} ->
            [insert_entry(queue_stats_publish, Q, TS, Diff, Size, Interval, true)
             || {Size, Interval} <- BPolicies];
        {false, true, _} ->
            [insert_entry(exchange_stats_publish_out, X, TS, Diff, Size, Interval, true)
             || {Size, Interval} <- BPolicies];
        {true, true, basic} ->
            [begin
             insert_entry(queue_stats_publish, Q, TS, Diff, Size, Interval, true),
             insert_entry(exchange_stats_publish_out, X, TS, Diff, Size, Interval, true)
             end || {Size, Interval} <- BPolicies];
        {true, true, _} ->
            [begin
             insert_entry(queue_stats_publish, Q, TS, Diff, Size, Interval, true),
             insert_entry(exchange_stats_publish_out, X, TS, Diff, Size, Interval, true),
             insert_entry(queue_exchange_stats_publish, Id, TS, Diff, Size, Interval, true)
             end || {Size, Interval} <- BPolicies];
        _ ->
            ok
    end;
aggregate_entry(TS, {Id, Reductions}, #state{table = channel_process_metrics,
					     policies = {BPolicies, _, _}}) ->
    [begin
	 insert_entry(channel_process_stats, Id, TS, ?channel_process_stats(Reductions),
		      Size, Interval, false)
     end || {Size, Interval} <- BPolicies];
aggregate_entry(_TS, {Id, Exclusive, AckRequired, PrefetchCount, Args},
                #state{table = consumer_created}) ->
    Fmt = rabbit_mgmt_format:format([{exclusive, Exclusive},
                                     {ack_required, AckRequired},
                                     {prefetch_count, PrefetchCount},
                                     {arguments, Args}], {[], false}),
    insert_with_index(consumer_stats, Id, ?consumer_stats(Id, Fmt)),
    ok;
aggregate_entry(TS, {Id, Metrics}, #state{table = queue_metrics,
                                          policies = {BPolicies, _, GPolicies},
                                          lookup_queue = QueueFun}) ->
    Stats = ?queue_msg_rates(pget(disk_reads, Metrics, 0), pget(disk_writes, Metrics, 0)),
    Diff = get_difference({Id, rates}, Stats),
    ets:insert(old_aggr_stats, ?old_aggr_stats({Id, rates}, Stats)),
    [insert_entry(vhost_msg_rates, vhost(Id), TS, Diff, Size, Interval, true)
     || {Size, Interval} <- GPolicies],
    case QueueFun(Id) of
	true ->
	    [insert_entry(queue_msg_rates, Id, TS, Stats, Size, Interval, false)
	     || {Size, Interval} <- BPolicies],
	    Fmt = rabbit_mgmt_format:format(
                    Metrics,
                    {fun rabbit_mgmt_format:format_queue_stats/1, false}),
	    ets:insert(queue_stats, ?queue_stats(Id, Fmt));
	false ->
	    ok
    end;
aggregate_entry(TS, {Name, Ready, Unack, Msgs, Red}, #state{table = queue_coarse_metrics,
                                                            policies = {BPolicies, _, GPolicies},
                                                            lookup_queue = QueueFun}) ->
    Stats = ?vhost_msg_stats(Ready, Unack, Msgs),
    Diff = get_difference(Name, Stats),
    ets:insert(old_aggr_stats, ?old_aggr_stats(Name, Stats)),
    [insert_entry(vhost_msg_stats, vhost(Name), TS, Diff, Size, Interval, true)
     || {Size, Interval} <- GPolicies],
    case QueueFun(Name) of
        true ->
            [begin
             insert_entry(queue_process_stats, Name, TS, ?queue_process_stats(Red),
                          Size, Interval, false),
             insert_entry(queue_msg_stats, Name, TS, ?queue_msg_stats(Ready, Unack, Msgs),
                          Size, Interval, false)
             end || {Size, Interval} <- BPolicies];
        _ ->
            ok
    end;
aggregate_entry(_TS, {Id, Metrics}, #state{table = node_metrics}) ->
    ets:insert(node_stats, {Id, Metrics});
aggregate_entry(TS, {Id, Metrics}, #state{table = node_coarse_metrics,
					  policies = {_, _, GPolicies}}) ->
    Stats = ?node_coarse_stats(
	       pget(fd_used, Metrics, 0), pget(sockets_used, Metrics, 0),
	       pget(mem_used, Metrics, 0), pget(disk_free, Metrics, 0),
	       pget(proc_used, Metrics, 0), pget(gc_num, Metrics, 0),
	       pget(gc_bytes_reclaimed, Metrics, 0), pget(context_switches, Metrics, 0)),
    [insert_entry(node_coarse_stats, Id, TS, Stats, Size, Interval, false)
     || {Size, Interval} <- GPolicies];
aggregate_entry(TS, {Id, Metrics}, #state{table = node_persister_metrics,
					  policies = {_, _, GPolicies}}) ->
    Stats = ?node_persister_stats(
	       pget(io_read_count, Metrics, 0), pget(io_read_bytes, Metrics, 0),
	       pget(io_read_time, Metrics, 0), pget(io_write_count, Metrics, 0),
	       pget(io_write_bytes, Metrics, 0), pget(io_write_time, Metrics, 0),
	       pget(io_sync_count, Metrics, 0), pget(io_sync_time, Metrics, 0),
	       pget(io_seek_count, Metrics, 0), pget(io_seek_time, Metrics, 0),
	       pget(io_reopen_count, Metrics, 0), pget(mnesia_ram_tx_count, Metrics, 0),
	       pget(mnesia_disk_tx_count, Metrics, 0), pget(msg_store_read_count, Metrics, 0),
	       pget(msg_store_write_count, Metrics, 0),
	       pget(queue_index_journal_write_count, Metrics, 0),
	       pget(queue_index_write_count, Metrics, 0), pget(queue_index_read_count, Metrics, 0),
	       pget(io_file_handle_open_attempt_count, Metrics, 0),
	       pget(io_file_handle_open_attempt_time, Metrics, 0)),
    [insert_entry(node_persister_stats, Id, TS, Stats, Size, Interval, false)
     || {Size, Interval} <- GPolicies];
aggregate_entry(TS, {Id, Metrics}, #state{table = node_node_metrics,
					  policies = {_, _, GPolicies}}) ->
    Stats = ?node_node_coarse_stats(pget(send_bytes, Metrics, 0), pget(recv_bytes, Metrics, 0)),
    CleanMetrics = lists:keydelete(recv_bytes, 1, lists:keydelete(send_bytes, 1, Metrics)),
    ets:insert(node_node_stats, ?node_node_stats(Id, CleanMetrics)),
    [insert_entry(node_node_coarse_stats, Id, TS, Stats, Size, Interval, false)
     || {Size, Interval} <- GPolicies].

insert_entry(Table, Id, TS, Entry, Size, Interval, Incremental) ->
    Key = {Id, Interval},
    Slide = case ets:lookup(Table, Key) of
                [{Key, S}] ->
                    S;
                [] ->
                    exometer_slide:new(Size * 1000,
                                       [{interval, Interval * 1000},
                                        {max_n, trunc(Size / Interval)},
                                        {incremental, Incremental}])
            end,
    insert_with_index(Table, Key, {Key, exometer_slide:add_element(TS, Entry, Slide)}).

get_difference(Id, Stats) ->
    case ets:lookup(old_aggr_stats, Id) of
	[] ->
	    Stats;
	[{Id, OldStats}] ->
	    difference(OldStats, Stats)
    end.

difference({A0}, {B0}) ->
    {B0 - A0};
difference({A0, A1}, {B0, B1}) ->
    {B0 - A0, B1 - A1};
difference({A0, A1, A2}, {B0, B1, B2}) ->
    {B0 - A0, B1 - A1, B2 - A2};
difference({A0, A1, A2, A3, A4, A5, A6}, {B0, B1, B2, B3, B4, B5, B6}) ->
    {B0 - A0, B1 - A1, B2 - A2, B3 - A3, B4 - A4, B5 - A5, B6 - A6}.

vhost(#resource{virtual_host = VHost}) ->
    VHost;
vhost({queue_stats, #resource{virtual_host = VHost}}) ->
    VHost;
vhost({TName, Pid}) ->
    pget(vhost, lookup_element(TName, Pid, 3)).

exchange_exists(Name) ->
    case rabbit_exchange:lookup(Name) of
	{ok, _} ->
	    true;
	_ ->
	    false
    end.

queue_exists(Name) ->
    case rabbit_amqqueue:lookup(Name) of
	{ok, _} ->
	    true;
	_ ->
	    false
    end.

insert_with_index(Table, Key, Tuple) ->
    Insert = ets:insert(Table, Tuple),
    insert_index(Table, Key),
    Insert.

insert_index(consumer_stats, {Q, Ch, _} = Key) ->
    ets:insert(index_table(consumer_stats, queue), {Q, Key}),
    ets:insert(index_table(consumer_stats, channel), {Ch, Key});
insert_index(old_aggr_stats, {Ch, {Q, _X}} = Key) ->
    ets:insert(index_table(old_aggr_stats, queue), {Q, Key}),
    ets:insert(index_table(old_aggr_stats, channel), {Ch, Key});
insert_index(old_aggr_stats, {Ch, Q} = Key) ->
    ets:insert(index_table(old_aggr_stats, queue), {Q, Key}),
    ets:insert(index_table(old_aggr_stats, channel), {Ch, Key});
insert_index(channel_exchange_stats_fine_stats, {{Ch, Ex}, _} = Key) ->
    ets:insert(index_table(channel_exchange_stats_fine_stats, exchange), {Ex, Key}),
    ets:insert(index_table(channel_exchange_stats_fine_stats, channel),  {Ch, Key});
insert_index(channel_queue_stats_deliver_stats, {{Ch, Q}, _} = Key) ->
    ets:insert(index_table(channel_queue_stats_deliver_stats, queue),   {Q, Key}),
    ets:insert(index_table(channel_queue_stats_deliver_stats, channel), {Ch, Key});
insert_index(queue_exchange_stats_publish, {{Q, Ex}, _} = Key) ->
    ets:insert(index_table(queue_exchange_stats_publish, queue),    {Q, Key}),
    ets:insert(index_table(queue_exchange_stats_publish, exchange), {Ex, Key});
insert_index(node_node_coarse_stats, {{_, Node}, _} = Key) ->
    ets:insert(index_table(node_node_coarse_stats, node), {Node, Key});
insert_index(_, _) -> ok.

index_table(consumer_stats, queue) -> consumer_stats_queue_index;
index_table(consumer_stats, channel) -> consumer_stats_channel_index;
index_table(old_aggr_stats, queue) -> old_aggr_stats_queue_index;
index_table(old_aggr_stats, channel) -> old_aggr_stats_channel_index;
index_table(channel_exchange_stats_fine_stats, exchange) -> channel_exchange_stats_fine_stats_exchange_index;
index_table(channel_exchange_stats_fine_stats, channel) -> channel_exchange_stats_fine_stats_channel_index;
index_table(channel_queue_stats_deliver_stats, queue) -> channel_queue_stats_deliver_stats_queue_index;
index_table(channel_queue_stats_deliver_stats, channel) -> channel_queue_stats_deliver_stats_channel_index;
index_table(queue_exchange_stats_publish, queue) -> queue_exchange_stats_publish_queue_index;
index_table(queue_exchange_stats_publish, exchange) -> queue_exchange_stats_publish_exchange_index;
index_table(node_node_coarse_stats, node) -> node_node_coarse_stats_node_index.
