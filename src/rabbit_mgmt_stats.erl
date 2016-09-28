%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ Management Plugin.
%%
%%   The Initial Developer of the Original Code is GoPivotal, Inc.
%%   Copyright (c) 2010-2012 GoPivotal, Inc.  All rights reserved.
%%

-module(rabbit_mgmt_stats).

-include("rabbit_mgmt.hrl").
-include("rabbit_mgmt_metrics.hrl").

-export([format/4,
	 get_keys/2]).

-export([format_sum/4]).

-export([lookup_smaller_sample/2, lookup_samples/3, lookup_all/3,
         select_smaller_sample/1, select_range_sample/2]).
-export([format_range/5, format_no_range/3]).

% -import(rabbit_misc, [pget/2]).

-define(ALWAYS_REPORT, [queue_msg_counts, coarse_node_stats]).
-define(MICRO_TO_MILLI, 1000).

%% Data is stored in ETS tables:
%% * one set of ETS tables per event (queue_stats, queue_exchange_stats...)
%% * each set contains one table per group of events (queue_msg_rates,
%%   deliver_get, fine_stats...) such as aggr_queue_stats_deliver_get
%%   (see ?AGGR_TABLES in rabbit_mgmt_metrics.hrl)
%% * data is then stored as a tuple (not a record) to take advantage of the
%%   atomic call ets:update_counter/3. The equivalent records are noted in
%%   rabbit_mgmt_metrics.hrl to get the position and as reference for developers
%% * Records are of the shape:
%%    {{Id, base}, Field1, Field2, ....} 
%%    {{Id, total}, Field1, Field2, ....} 
%%    {{Id, Timestamp}, Field1, Field2, ....} 
%%    where Id can be a simple key or a tuple {Id0, Id1} 
%%
%% This module is not generic any longer, any new event or field needs to be
%% manually added, but it increases the performance and allows concurrent
%% GC, event collection and querying
%%

get_keys(Table, Id0) ->
    ets:select(Table, match_spec_keys(Id0)).

match_spec_keys(Id) ->
    MatchCondition = to_match_condition(Id),
    MatchHead = {{{'$1', '$2'}, '_'}, '_'},
    [{MatchHead, [MatchCondition], [{{'$1', '$2'}}]}].

%%----------------------------------------------------------------------------
%% Query-time
%%----------------------------------------------------------------------------
format(no_range, Table, Id, Interval) ->
    InstantRateFun = fun() -> lookup_smaller_sample(Table, Id) end,
    format_no_range(Table, Interval, InstantRateFun);
format(Range, Table, Id, Interval) ->
    InstantRateFun = fun() -> lookup_smaller_sample(Table, Id) end,
    SamplesFun = fun() -> lookup_samples(Table, Id, Range) end,
    format_range(Range, Table, Interval, InstantRateFun, SamplesFun).

format_sum(no_range, Interval, Table, VHosts) ->
    InstantRateFun = fun() -> lookup_all(Table, VHosts, select_smaller_sample(Table)) end,
    format_no_range(Table, Interval, InstantRateFun);
format_sum(Range, Interval, Table, VHosts) ->
    InstantRateFun = fun() -> lookup_all(Table, VHosts, select_smaller_sample(Table)) end,
    SamplesFun = fun() -> lookup_all(Table, VHosts, select_range_sample(Table, Range)) end,
    format_range(Range, Table, Interval, InstantRateFun, SamplesFun).

lookup_all(Table, Ids, SecondKey) ->
    Slides = lists:foldl(fun(Id, Acc) ->
				 case ets:lookup(Table, {Id, SecondKey}) of
				     [] ->
                         Acc;
				     [{_, Slide}] ->
                         [Slide | Acc]
				 end
			 end, [], Ids),
    case Slides of
        [] ->
            not_found;
        _ ->
            exometer_slide:sum(Slides)
    end.

format_range(no_range, Table, Interval, InstantRateFun, _SamplesFun) ->
    format_no_range(Table, Interval, InstantRateFun);
format_range(Range, Table, Interval, InstantRateFun, SamplesFun) ->
    RangePoint = Range#range.last - Interval,
    case SamplesFun() of
        not_found ->
            [];
        Slide ->
            Empty0 = empty(Table, 0),
            {Samples0, SampleTotals0, _, Length0, Previous, _, _} =
                exometer_slide:foldl(
                  Range#range.first - Range#range.incr, fun extract_samples/2,
                  {empty(Table, []), Empty0, Empty0, 0, empty, Range,
                   Range#range.first}, Slide),
            {Samples, SampleTotals, Length} = fill_range(Samples0, SampleTotals0,
                                                         Length0, Range, Empty0, Previous),
            {Total, Rate} = calculate_instant_rate(InstantRateFun, Table, RangePoint),
            format_rate(Table, Total, Rate, Samples, SampleTotals, Length)
    end.

format_no_range(Table, Interval, InstantRateFun) ->
    Now = time_compat:os_system_time(milli_seconds),
    RangePoint = ((Now div Interval) * Interval) - Interval,
    case calculate_instant_rate(InstantRateFun, Table, RangePoint) of
        {Total, Rate} ->
            format_rate(Table, Total, Rate);
        not_found ->
            []
    end.

lookup_smaller_sample(Table, Id) ->
    case ets:lookup(Table, {Id, select_smaller_sample(Table)}) of
	[] ->
	    not_found;
	[{_, Slide}] ->
	    Slide
    end.

lookup_samples(Table, Id, Range) ->
    case ets:lookup(Table, {Id, select_range_sample(Table, Range)}) of
        [] ->
            not_found;
        [{_, Slide}] ->
            Slide
    end.

calculate_instant_rate(Fun, Table, RangePoint) ->
  case Fun() of
      not_found ->
          not_found;
      Slide ->
          case exometer_slide:last_two(Slide) of
              [] -> {empty(Table, 0), empty(Table, 0.0)};
              [{_TS, Total} = Last | T] ->
                  Rate = rate_from_last_increment(Table, Last, T, RangePoint),
                  {Total, Rate}
          end
  end.

fill_range(Samples0, Totals0, Length0, #range{last = Last, incr = Incr, first = First}, Empty, Previous) ->
    AnySample = element(1, Samples0),
    {MissingSamples, ToAdd} = case AnySample of
				  [] ->
				      {missing_samples(First, Incr, Last), Empty};
				  [H | _T] ->
				      TS = proplists:get_value(timestamp, H),
				      {missing_samples(TS + Incr, Incr, Last),
				       maybe_empty(Previous, Empty)}
			      end,
    {Samples, Totals} = append_missing_samples(MissingSamples, ToAdd, Samples0, Totals0),
    {Samples, Totals, length(MissingSamples) + Length0}.

maybe_empty(empty, Empty) ->
    Empty;
maybe_empty({_, Values}, _) ->
    Values.

extract_samples(_, {_, _, _, _, _, #range{last = Last}, Next} = Acc)
  when Next > Last ->
    Acc;
extract_samples({TS, _} = Sa, {Sample0, Totals0, Empty, Length, _,
			       #range{first = First, incr = Incr} = Range, Next})
  when First =:= Next, Next < TS, (TS - Incr) < Next ->
    {Sample0, Totals0, Empty, Length, Sa, Range,  next_ts(Next, TS, Incr)};
extract_samples({TS, Values} = Sa, {Sample0, Totals0, Empty, Length, Previous,
				    #range{first = First, incr = Incr} = Range, Next})
  when Next < TS ->
    MissingSamples = missing_samples(Next, Incr, TS),
    PreviousSample = select_missing_sample(First == Next, Empty, Previous, Values),
    {Sample, Totals} = append_missing_samples(
			 MissingSamples, PreviousSample, Sample0, Totals0),
    {Sample, Totals, Empty, Length + length(MissingSamples), Sa, Range,  next_ts(Next, TS, Incr)};
extract_samples({TS, Values} = Sa, {Sample0, Totals0, Empty, Length, _,
			       #range{incr = Incr} = Range, Next})
  when Next =:= TS ->
    {Sample, Totals} = append_full_sample(TS, Values, Sample0, Totals0),
    {Sample, Totals, Empty, Length + 1, Sa, Range, Next + Incr};
extract_samples({TS, _} = Sa, {S, T, E, L, _, R, Next}) when Next > TS ->
    {S, T, E, L, Sa, R, Next}.

select_missing_sample(true, Empty, _, _) ->
    Empty;
select_missing_sample(false, _, empty, Current) ->
    Current;
select_missing_sample(false, _, {_, Previous}, _) ->
    Previous.

next_ts(Next, TS, Incr) ->
    Next + (((TS - Next) div Incr) + 1) * Incr.

append_missing_samples(MissingSamples, Sample, Samples, Totals) ->
    lists:foldl(fun(TS, {SamplesAcc, TotalsAcc}) ->
			append_full_sample(TS, Sample, SamplesAcc, TotalsAcc)
		end, {Samples, Totals}, MissingSamples).

missing_samples(Next, Incr, TS) ->
    lists:seq(Next, TS, Incr).

%% connection_stats_coarse_conn_stats, channel_stats_fine_stats,
%% vhost_stats_fine_stats, channel_exchange_stats_fine_stats,
%% queue_msg_stats, vhost_msg_stats
append_full_sample(TS, {V1, V2, V3}, {S1, S2, S3}, {T1, T2, T3}) ->
    {{append_sample(V1, TS, S1), append_sample(V2, TS, S2), append_sample(V3, TS, S3)},
     {V1 + T1, V2 + T2, V3 + T3}};
%% channel_queue_stats_deliver_stats, queue_stats_deliver_stats,
%% vhost_stats_deliver_stats, channel_stats_deliver_stats 
append_full_sample(TS, {V1, V2, V3, V4, V5, V6, V7},
		   {S1, S2, S3, S4, S5, S6, S7},
		   {T1, T2, T3, T4, T5, T6, T7}) ->
    {{append_sample(V1, TS, S1), append_sample(V2, TS, S2),
      append_sample(V3, TS, S3), append_sample(V4, TS, S4),
      append_sample(V5, TS, S5), append_sample(V6, TS, S6),
      append_sample(V7, TS, S7)},
     {V1 + T1, V2 + T2, V3 + T3, V4 + T4, V5 + T5, V6 + T6, V7 + T7}};
%% channel_process_stats, queue_stats_publish, queue_exchange_stats_publish,
%% exchange_stats_publish_out, exchange_stats_publish_in, queue_process_stats
append_full_sample(TS, {V1}, {S1}, {T1}) ->
    {{append_sample(V1, TS, S1)}, {V1 + T1}};
%% node_coarse_stats
append_full_sample(TS, {V1, V2, V3, V4, V5, V6, V7, V8},
		   {S1, S2, S3, S4, S5, S6, S7, S8},
		   {T1, T2, T3, T4, T5, T6, T7, T8}) ->
    {{append_sample(V1, TS, S1), append_sample(V2, TS, S2),
      append_sample(V3, TS, S3), append_sample(V4, TS, S4),
      append_sample(V5, TS, S5), append_sample(V6, TS, S6),
      append_sample(V7, TS, S7), append_sample(V8, TS, S8)},
     {V1 + T1, V2 + T2, V3 + T3, V4 + T4, V5 + T5, V6 + T6, V7 + T7, V8 + T8}};
%% node_persister_stats
append_full_sample(TS,
		   {V1, V2, V3, V4, V5, V6, V7, V8, V9, V10, V11, V12, V13, V14,
		    V15, V16, V17, V18, V19, V20},
		   {S1, S2, S3, S4, S5, S6, S7, S8, S9, S10, S11, S12, S13, S14,
		    S15, S16, S17, S18, S19, S20},
		   {T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14,
		    T15, T16, T17, T18, T19, T20}
		  ) ->
    {{append_sample(V1, TS, S1), append_sample(V2, TS, S2),
      append_sample(V3, TS, S3), append_sample(V4, TS, S4),
      append_sample(V5, TS, S5), append_sample(V6, TS, S6),
      append_sample(V7, TS, S7), append_sample(V8, TS, S8),
      append_sample(V9, TS, S9), append_sample(V10, TS, S10),
      append_sample(V11, TS, S11), append_sample(V12, TS, S12),
      append_sample(V13, TS, S13), append_sample(V14, TS, S14),
      append_sample(V15, TS, S15), append_sample(V16, TS, S16),
      append_sample(V17, TS, S17), append_sample(V18, TS, S18),
      append_sample(V19, TS, S19), append_sample(V20, TS, S20)},
     {V1 + T1, V2 + T2, V3 + T3, V4 + T4, V5 + T5, V6 + T6, V7 + T7, V8 + T8,
      V9 + T9, V10 + T10, V11 + T11, V12 + T12, V13 + T13, V14 + T14, V15 + T15,
      V16 + T16, V17 + T17, V18 + T18, V19 + T19, V20 + T20}};
%% node_node_coarse_stats, vhost_stats_coarse_connection_stats, queue_msg_rates,
%% vhost_msg_rates
append_full_sample(TS, {V1, V2}, {S1, S2}, {T1, T2}) ->
    {{append_sample(V1, TS, S1), append_sample(V2, TS, S2)}, {V1 + T1, V2 + T2}}.

select_range_sample(Table, #range{first = First, last = Last}) ->
    Range = Last - First,
    {ok, Policies} = application:get_env(
                       rabbitmq_management, sample_retention_policies),
    Policy = retention_policy(Table),
    [T | TablePolicies] = lists:sort(proplists:get_value(Policy, Policies)),
    {_, Sample} = select_largest_below(T, TablePolicies, Range),
    Sample.

select_smaller_sample(Table) ->
    {ok, Policies} = application:get_env(
                       rabbitmq_management, sample_retention_policies),
    Policy = retention_policy(Table),
    TablePolicies = proplists:get_value(Policy, Policies),
    [V | _] = lists:sort([I || {_, I} <- TablePolicies]),
    V.

select_largest_below(V, [], _) ->
    V;
select_largest_below(V, [{H, _} | _T], Interval) when (H * 1000) > Interval ->
    V;
select_largest_below(_, [H | T], Interval) ->
    select_largest_below(H, T, Interval).

retention_policy(connection_stats_coarse_conn_stats) ->
    basic;
retention_policy(channel_stats_fine_stats) ->
    basic;
retention_policy(channel_queue_stats_deliver_stats) ->
    detailed;
retention_policy(channel_exchange_stats_fine_stats) ->
    detailed;
retention_policy(channel_process_stats) ->
    basic;
retention_policy(vhost_stats_fine_stats) ->
    global;
retention_policy(vhost_stats_deliver_stats) ->
    global;
retention_policy(vhost_stats_coarse_conn_stats) ->
    global;
retention_policy(vhost_msg_rates) ->
    global;
retention_policy(channel_stats_deliver_stats) ->
    basic;
retention_policy(queue_stats_deliver_stats) ->
    basic;
retention_policy(queue_stats_publish) ->
    basic;
retention_policy(queue_exchange_stats_publish) ->
    basic;
retention_policy(exchange_stats_publish_out) ->
    basic;
retention_policy(exchange_stats_publish_in) ->
    basic;
retention_policy(queue_process_stats) ->
    basic;
retention_policy(queue_msg_stats) ->
    basic;
retention_policy(queue_msg_rates) ->
    basic;
retention_policy(vhost_msg_stats) ->
    global;
retention_policy(node_coarse_stats) ->
    global;
retention_policy(node_persister_stats) ->
    global;
retention_policy(node_node_coarse_stats) ->
    global.

format_rate(connection_stats_coarse_conn_stats, {TR, TS, TRe}, {RR, RS, RRe}) ->
    [
     {send_oct, TS},
     {send_oct_details, [{rate, RS}]},
     {recv_oct, TR},
     {recv_oct_details, [{rate, RR}]},
     {reductions, TRe},
     {reductions_details, [{rate, RRe}]}
    ];
format_rate(vhost_stats_coarse_conn_stats, {TR, TS}, {RR, RS}) ->
    [
     {send_oct, TS},
     {send_oct_details, [{rate, RS}]},
     {recv_oct, TR},
     {recv_oct_details, [{rate, RR}]}
    ];
format_rate(Type, {TR, TW}, {RR, RW}) when Type =:= vhost_msg_rates;
					   Type =:= queue_msg_rates ->
    [
     {disk_reads, TR},
     {disk_reads_details, [{rate, RR}]},
     {disk_writes, TW},
     {disk_writes_details, [{rate, RW}]}
    ];
format_rate(Type, {TP, TC, TRe}, {RP, RC, RRe})
  when Type =:= channel_stats_fine_stats;
       Type =:= vhost_stats_fine_stats;
       Type =:= channel_exchange_stats_fine_stats ->
    [
     {publish, TP},
     {publish_details, [{rate, RP}]},
     {confirm, TC},
     {confirm_details, [{rate, RC}]},
     {return_unroutable, TRe},
     {return_unroutable_details, [{rate, RRe}]}
    ];
format_rate(Type, {TG, TGN, TD, TDN, TR, TA, TDG},
	    {RG, RGN, RD, RDN, RR, RA, RDG})
  when Type =:= channel_queue_stats_deliver_stats;
       Type =:= channel_stats_deliver_stats;
       Type =:= vhost_stats_deliver_stats;
       Type =:= queue_stats_deliver_stats ->
    [
     {get, TG},
     {get_details, [{rate, RG}]},
     {get_no_ack, TGN},
     {get_no_ack_details, [{rate, RGN}]},
     {deliver, TD},
     {deliver_details, [{rate, RD}]},
     {deliver_no_ack, TDN},
     {deliver_no_ack_details, [{rate, RDN}]},
     {redeliver, TR},
     {redeliver_details, [{rate, RR}]},
     {ack, TA},
     {ack_details, [{rate, RA}]},
     {deliver_get, TDG},
     {deliver_get_details, [{rate, RDG}]}
    ];
format_rate(Type, {TR}, {RR}) when Type =:= channel_process_stats;
				   Type =:= queue_process_stats ->
    [
     {reductions, TR},
     {reductions_details, [{rate, RR}]}
    ];
format_rate(exchange_stats_publish_out, {TP}, {RP}) ->
    [
     {publish_out, TP},
     {publish_out_details, [{rate, RP}]}
    ];
format_rate(exchange_stats_publish_in, {TP}, {RP}) ->
    [
     {publish_in, TP},
     {publish_in_details, [{rate, RP}]}
    ];
format_rate(Type, {TP}, {RP}) when Type =:= queue_stats_publish;
				   Type =:= queue_exchange_stats_publish ->
    [
     {publish, TP},
     {publish_details, [{rate, RP}]}
    ];
format_rate(Type, {TR, TU, TM}, {RR, RU, RM}) when Type =:= queue_msg_stats;
						   Type =:= vhost_msg_stats ->
    [
     {messages_ready, TR},
     {messages_ready_details, [{rate, RR}]},
     {messages_unacknowledged, TU},
     {messages_unacknowledged_details, [{rate, RU}]},
     {messages, TM},
     {messages_details, [{rate, RM}]}
    ];
format_rate(node_coarse_stats, {TF, TS, TM, TD, TP, TGC, TGCW, TCS},
            {RF, RS, RM, RD, RP, RGC, RGCW, RCS}) ->
    [
     {mem_used, TM},
     {mem_used_details, [{rate, RM}]},
     {fd_used, TF},
     {fd_used_details, [{rate, RF}]},
     {sockets_used, TS},
     {sockets_used_details, [{rate, RS}]},
     {proc_used, TP},
     {proc_used_details, [{rate, RP}]},
     {disk_free, TD},
     {disk_free_details, [{rate, RD}]},
     {gc_num, TGC},
     {gc_num_details, [{rate, RGC}]},
     {gc_bytes_reclaimed, TGCW},
     {gc_bytes_reclaimed_details, [{rate, RGCW}]},
     {context_switches, TCS},
     {context_switches_details, [{rate, RCS}]}
    ];
format_rate(node_persister_stats,
            {TIR, TIB, TIA, TIWC, TIWB, TIWAT, TIS, TISAT, TISC,
             TISEAT, TIRC, TMRTC, TMDTC, TMSRC, TMSWC, TQIJWC, TQIWC, TQIRC,
             TIO, TIOAT},
            {RIR, RIB, RIA, RIWC, RIWB, RIWAT, RIS, RISAT, RISC,
             RISEAT, RIRC, RMRTC, RMDTC, RMSRC, RMSWC, RQIJWC, RQIWC, RQIRC,
             RIO, RIOAT}) ->
    %% Calculates average times for read/write/sync/seek from the
    %% accumulated time and count
    %% io_<op>_avg_time is the average operation time for the life of the node
    %% io_<op>_avg_time_details/rate is the average operation time during the
    %% last time unit calculated (thus similar to an instant rate)
    [
     {io_read_count, TIR},
     {io_read_count_details, [{rate, RIR}]},
     {io_read_bytes, TIB},
     {io_read_bytes_details, [{rate, RIB}]},
     {io_read_avg_time, avg_time(TIA, TIR)},
     {io_read_avg_time_details, [{rate, avg_time(RIA, RIR)}]},
     {io_write_count, TIWC},
     {io_write_count_details, [{rate, RIWC}]},
     {io_write_bytes, TIWB},
     {io_write_bytes_details, [{rate, RIWB}]},
     {io_write_avg_time, avg_time(TIWAT, TIWC)},
     {io_write_avg_time_details, [{rate, avg_time(RIWAT, RIWC)}]},
     {io_sync_count, TIS},
     {io_sync_count_details, [{rate, RIS}]},
     {io_sync_avg_time, avg_time(TISAT, TIS)},
     {io_sync_avg_time_details, [{rate, avg_time(RISAT, RIS)}]},
     {io_seek_count, TISC},
     {io_seek_count_details, [{rate, RISC}]},
     {io_seek_avg_time, avg_time(TISEAT, TISC)},
     {io_seek_avg_time_details, [{rate, avg_time(RISEAT, RISC)}]},
     {io_reopen_count, TIRC},
     {io_reopen_count_details, [{rate, RIRC}]},
     {mnesia_ram_tx_count, TMRTC},
     {mnesia_ram_tx_count_details, [{rate, RMRTC}]},
     {mnesia_disk_tx_count, TMDTC},
     {mnesia_disk_tx_count_details, [{rate, RMDTC}]},
     {msg_store_read_count, TMSRC},
     {msg_store_read_count_details, [{rate, RMSRC}]},
     {msg_store_write_count, TMSWC},
     {msg_store_write_count_details, [{rate, RMSWC}]},
     {queue_index_journal_write_count, TQIJWC},
     {queue_index_journal_write_count_details, [{rate, RQIJWC}]},
     {queue_index_write_count, TQIWC},
     {queue_index_write_count_details, [{rate, RQIWC}]},
     {queue_index_read_count, TQIRC},
     {queue_index_read_count_details, [{rate, RQIRC}]},
     {io_file_handle_open_attempt_count, TIO},
     {io_file_handle_open_attempt_count_details, [{rate, RIO}]},
     {io_file_handle_open_attempt_avg_time, avg_time(TIOAT, TIO)},
     {io_file_handle_open_attempt_avg_time_details, [{rate, avg_time(RIOAT, RIO)}]}
    ];
format_rate(node_node_coarse_stats, {TS, TR}, {RS, RR}) ->
    [
     {send_bytes, TS},
     {send_bytes_details, [{rate, RS}]},
     {recv_bytes, TR},
     {recv_bytes_details, [{rate, RR}]}
    ].

format_rate(connection_stats_coarse_conn_stats, {TR, TS, TRe}, {RR, RS, RRe},
	    {SR, SS, SRe}, {STR, STS, STRe}, Length) ->
    [
     {send_oct, TS},
     {send_oct_details, [{rate, RS},
			 {samples, SS}] ++ average(SS, STS, Length)},
     {recv_oct, TR},
     {recv_oct_details, [{rate, RR},
			 {samples, SR}] ++ average(SR, STR, Length)},
     {reductions, TRe},
     {reductions_details, [{rate, RRe},
			   {samples, SRe}] ++ average(SRe, STRe, Length)}
    ];
format_rate(vhost_stats_coarse_conn_stats, {TR, TS}, {RR, RS}, {SR, SS},
	    {STR, STS}, Length) ->
    [
     {send_oct, TS},
     {send_oct_details, [{rate, RS},
			 {samples, SS}] ++ average(SS, STS, Length)},
     {recv_oct, TR},
     {recv_oct_details, [{rate, RR},
			 {samples, SR}] ++ average(SR, STR, Length)}
    ];
format_rate(Type, {TR, TW}, {RR, RW}, {SR, SW}, {STR, STW}, Length)
  when Type =:= vhost_msg_rates;
       Type =:= queue_msg_rates ->
    [
     {disk_reads, TR},
     {disk_reads_details, [{rate, RR},
			   {samples, SR}] ++ average(SR, STR, Length)},
     {disk_writes, TW},
     {disk_writes_details, [{rate, RW},
			    {samples, SW}] ++ average(SW, STW, Length)}
    ];
format_rate(Type, {TP, TC, TRe}, {RP, RC, RRe},
	    {SP, SC, SRe}, {STP, STC, STRe}, Length)
  when Type =:= channel_stats_fine_stats;
       Type =:= vhost_stats_fine_stats;
       Type =:= channel_exchange_stats_fine_stats ->
    [
     {publish, TP},
     {publish_details, [{rate, RP},
			{samples, SP}] ++ average(SP, STP, Length)},
     {confirm, TC},
     {confirm_details, [{rate, RC},
			{samples, SC}] ++ average(SC, STC, Length)},
     {return_unroutable, TRe},
     {return_unroutable_details, [{rate, RRe},
				  {samples, SRe}] ++ average(SRe, STRe, Length)}
    ];
format_rate(Type, {TG, TGN, TD, TDN, TR, TA, TDG}, {RG, RGN, RD, RDN, RR, RA, RDG},
	    {SG, SGN, SD, SDN, SR, SA, SDG}, {STG, STGN, STD, STDN, STR, STA, STDG},
	    Length)
  when Type =:= channel_queue_stats_deliver_stats;
       Type =:= channel_stats_deliver_stats;
       Type =:= vhost_stats_deliver_stats;
       Type =:= queue_stats_deliver_stats ->
    [
     {get, TG},
     {get_details, [{rate, RG},
		    {samples, SG}] ++ average(SG, STG, Length)},
     {get_no_ack, TGN},
     {get_no_ack_details, [{rate, RGN},
			   {samples, SGN}] ++ average(SGN, STGN, Length)},
     {deliver, TD},
     {deliver_details, [{rate, RD},
			{samples, SD}] ++ average(SD, STD, Length)},
     {deliver_no_ack, TDN},
     {deliver_no_ack_details, [{rate, RDN},
			       {samples, SDN}] ++ average(SDN, STDN, Length)},
     {redeliver, TR},
     {redeliver_details, [{rate, RR},
			  {samples, SR}] ++ average(SR, STR, Length)},
     {ack, TA},
     {ack_details, [{rate, RA},
		    {samples, SA}] ++ average(SA, STA, Length)},
     {deliver_get, TDG},
     {deliver_get_details, [{rate, RDG},
			    {samples, SDG}] ++ average(SDG, STDG, Length)}
    ];
format_rate(Type, {TR}, {RR}, {SR}, {STR}, Length)
  when Type =:= channel_process_stats;
       Type =:= queue_process_stats ->
    [
     {reductions, TR},
     {reductions_details, [{rate, RR},
			   {samples, SR}] ++ average(SR, STR, Length)}
    ];
format_rate(exchange_stats_publish_out, {TP}, {RP}, {SP}, {STP}, Length) ->
    [
     {publish_out, TP},
     {publish_out_details, [{rate, RP},
			    {samples, SP}] ++ average(SP, STP, Length)}
    ];
format_rate(exchange_stats_publish_in, {TP}, {RP}, {SP}, {STP}, Length) ->
    [
     {publish_in, TP},
     {publish_in_details, [{rate, RP},
			   {samples, SP}] ++ average(SP, STP, Length)}
    ];
format_rate(Type, {TP}, {RP}, {SP}, {STP}, Length)
  when Type =:= queue_stats_publish;
       Type =:= queue_exchange_stats_publish ->
    [
     {publish, TP},
     {publish_details, [{rate, RP},
			    {samples, SP}] ++ average(SP, STP, Length)}
    ];
format_rate(Type, {TR, TU, TM}, {RR, RU, RM}, {SR, SU, SM}, {STR, STU, STM},
	    Length) when Type =:= queue_msg_stats;
			 Type =:= vhost_msg_stats ->
    [
     {messages_ready, TR},
     {messages_ready_details, [{rate, RR},
			{samples, SR}] ++ average(SR, STR, Length)},
     {messages_unacknowledged, TU},
     {messages_unacknowledged_details, [{rate, RU},
					{samples, SU}] ++ average(SU, STU, Length)},
     {messages, TM},
     {messages_details, [{rate, RM},
			 {samples, SM}] ++ average(SM, STM, Length)}
    ];
format_rate(node_coarse_stats, {TF, TS, TM, TD, TP, TGC, TGCW, TCS},
            {RF, RS, RM, RD, RP, RGC, RGCW, RCS},
	    {SF, SS, SM, SD, SP, SGC, SGCW, SCS},
	    {STF, STS, STM, STD, STP, STGC, STGCW, STCS}, Length) ->
    [
     {mem_used, TM},
     {mem_used_details, [{rate, RM},
			 {samples, SM}] ++ average(SM, STM, Length)},
     {fd_used, TF},
     {fd_used_details, [{rate, RF},
			{samples, SF}] ++ average(SF, STF, Length)},
     {sockets_used, TS},
     {sockets_used_details, [{rate, RS},
			     {samples, SS}] ++ average(SS, STS, Length)},
     {proc_used, TP},
     {proc_used_details, [{rate, RP},
			  {samples, SP}] ++ average(SP, STP, Length)},
     {disk_free, TD},
     {disk_free_details, [{rate, RD},
			  {samples, SD}] ++ average(SD, STD, Length)},
     {gc_num, TGC},
     {gc_num_details, [{rate, RGC},
		       {samples, SGC}] ++ average(SGC, STGC, Length)},
     {gc_bytes_reclaimed, TGCW},
     {gc_bytes_reclaimed_details, [{rate, RGCW},
				   {samples, SGCW}] ++ average(SGCW, STGCW, Length)},
     {context_switches, TCS},
     {context_switches_details, [{rate, RCS},
				 {samples, SCS}] ++ average(SCS, STCS, Length)}
    ];
format_rate(node_persister_stats,
            {TIR, TIB, TIA, TIWC, TIWB, TIWAT, TIS, TISAT, TISC,
             TISEAT, TIRC, TMRTC, TMDTC, TMSRC, TMSWC, TQIJWC, TQIWC, TQIRC,
             TIO, TIOAT},
            {RIR, RIB, RIA, RIWC, RIWB, RIWAT, RIS, RISAT, RISC,
             RISEAT, RIRC, RMRTC, RMDTC, RMSRC, RMSWC, RQIJWC, RQIWC, RQIRC,
             RIO, RIOAT},
	    {SIR, SIB, SIA, SIWC, SIWB, SIWAT, SIS, SISAT, SISC,
             SISEAT, SIRC, SMRTC, SMDTC, SMSRC, SMSWC, SQIJWC, SQIWC, SQIRC,
             SIO, SIOAT},
	    {STIR, STIB, STIA, STIWC, STIWB, STIWAT, STIS, STISAT, STISC,
             STISEAT, STIRC, STMRTC, STMDTC, STMSRC, STMSWC, STQIJWC, STQIWC, STQIRC,
             STIO, STIOAT}, Length) ->
    %% Calculates average times for read/write/sync/seek from the
    %% accumulated time and count
    %% io_<op>_avg_time is the average operation time for the life of the node
    %% io_<op>_avg_time_details/rate is the average operation time during the
    %% last time unit calculated (thus similar to an instant rate)


    %% TODO avg_time

    [
     {io_read_count, TIR},
     {io_read_count_details, [{rate, RIR},
			      {samples, SIR}] ++ average(SIR, STIR, Length)},
     {io_read_bytes, TIB},
     {io_read_bytes_details, [{rate, RIB},
			     {samples, SIB}] ++ average(SIB, STIB, Length)},
     {io_read_avg_time, avg_time(TIA, TIR)},
     {io_read_avg_time_details, [{rate, avg_time(RIA, RIR)},
				 {samples, SIA}] ++ average(SIA, STIA, Length)},
     {io_write_count, TIWC},
     {io_write_count_details, [{rate, RIWC},
			       {samples, SIWC}] ++ average(SIWC, STIWC, Length)},
     {io_write_bytes, TIWB},
     {io_write_bytes_details, [{rate, RIWB},
			       {samples, SIWB}] ++ average(SIWB, STIWB, Length)},
     {io_write_avg_time, avg_time(TIWAT, TIWC)},
     {io_write_avg_time_details, [{rate, avg_time(RIWAT, RIWC)},
				  {samples, SIWAT}] ++ average(SIWAT, STIWAT, Length)},
     {io_sync_count, TIS},
     {io_sync_count_details, [{rate, RIS},
			      {samples, SIS}] ++ average(SIS, STIS, Length)},
     {io_sync_avg_time, avg_time(TISAT, TIS)},
     {io_sync_avg_time_details, [{rate, avg_time(RISAT, RIS)},
				 {samples, SISAT}] ++ average(SISAT, STISAT, Length)},
     {io_seek_count, TISC},
     {io_seek_count_details, [{rate, RISC},
			      {samples, SISC}] ++ average(SISC, STISC, Length)},
     {io_seek_avg_time, avg_time(TISEAT, TISC)},
     {io_seek_avg_time_details, [{rate, avg_time(RISEAT, RISC)},
				 {samples, SISEAT}] ++ average(SISEAT, STISEAT, Length)},
     {io_reopen_count, TIRC},
     {io_reopen_count_details, [{rate, RIRC},
				{samples, SIRC}] ++ average(SIRC, STIRC, Length)},
     {mnesia_ram_tx_count, TMRTC},
     {mnesia_ram_tx_count_details, [{rate, RMRTC},
				    {samples, SMRTC}] ++ average(SMRTC, STMRTC, Length)},
     {mnesia_disk_tx_count, TMDTC},
     {mnesia_disk_tx_count_details, [{rate, RMDTC},
				     {samples, SMDTC}] ++ average(SMDTC, STMDTC, Length)},
     {msg_store_read_count, TMSRC},
     {msg_store_read_count_details, [{rate, RMSRC},
				     {samples, SMSRC}] ++ average(SMSRC, STMSRC, Length)},
     {msg_store_write_count, TMSWC},
     {msg_store_write_count_details, [{rate, RMSWC},
				      {samples, SMSWC}] ++ average(SMSWC, STMSWC, Length)},
     {queue_index_journal_write_count, TQIJWC},
     {queue_index_journal_write_count_details, [{rate, RQIJWC},
						{samples, SQIJWC}] ++ average(SQIJWC, STQIJWC, Length)},
     {queue_index_write_count, TQIWC},
     {queue_index_write_count_details, [{rate, RQIWC},
					{samples, SQIWC}] ++ average(SQIWC, STQIWC, Length)},
     {queue_index_read_count, TQIRC},
     {queue_index_read_count_details, [{rate, RQIRC},
				       {samples, SQIRC}] ++ average(SQIRC, STQIRC, Length)},
     {io_file_handle_open_attempt_count, TIO},
     {io_file_handle_open_attempt_count_details, [{rate, RIO},
						  {samples, SIO}] ++ average(SIO, STIO, Length)},
     {io_file_handle_open_attempt_avg_time, avg_time(TIOAT, TIO)},
     {io_file_handle_open_attempt_avg_time_details, [{rate, avg_time(RIOAT, RIO)},
						     {samples, SIOAT}] ++ average(SIOAT, STIOAT, Length)}
    ];
format_rate(node_node_coarse_stats, {TS, TR}, {RS, RR}, {SS, SR}, {STS, STR}, Length) ->
    [
     {send_bytes, TS},
     {send_bytes_details, [{rate, RS},
			   {samples, SS}] ++ average(SS, STS, Length)},
     {recv_bytes, TR},
     {recv_bytes_details, [{rate, RR},
			   {samples, SR}] ++ average(SR, STR, Length)}
    ].

average(_Samples, _Total, Length) when Length =< 1->
    [];
average(Samples, Total, Length) ->
    [{sample, S2}, {timestamp, T2}] = hd(Samples),
    [{sample, S1}, {timestamp, T1}] = lists:last(Samples),
    [{avg_rate, (S2 - S1) * 1000 / (T2 - T1)},
     {avg, Total / Length}].

rate_from_last_increment(Table, {TS, _} = Last, T, RangePoint) ->
    case TS - RangePoint of % [0]
        D when D >= 0 ->
            case rate_from_last_increment(Last, T) of
                unknown ->
                    empty(Table, 0.0);
                Rate ->
                    Rate
            end;
        _ ->
            empty(Table, 0.0)
    end.

%% [0] Only display the rate if it's live - i.e. ((the end of the
%% range) - interval) corresponds to the last data point we have
rate_from_last_increment(_Total, []) ->
    unknown;
rate_from_last_increment(Total, [H | _T]) ->
    rate_from_difference(Total, H).

rate_from_difference({TS0, {A0, A1, A2}}, {TS1, {B0, B1, B2}}) ->
    Interval = TS0 - TS1,
    {rate(A0 - B0, Interval), rate(A1 - B1, Interval), rate(A2 - B2, Interval)};
rate_from_difference({TS0, {A0, A1}}, {TS1, {B0, B1}}) ->
    Interval = TS0 - TS1,
    {rate(A0 - B0, Interval), rate(A1 - B1, Interval)};
rate_from_difference({TS0, {A0, A1, A2, A3, A4, A5, A6}},
		     {TS1, {B0, B1, B2, B3, B4, B5, B6}}) ->
    Interval = TS0 - TS1,
    {rate(A0 - B0, Interval), rate(A1 - B1, Interval), rate(A2 - B2, Interval),
     rate(A3 - B3, Interval), rate(A4 - B4, Interval), rate(A5 - B5, Interval),
     rate(A6 - B6, Interval)};
rate_from_difference({TS0, {A0, A1, A2, A3, A4, A5, A6, A7}},
		     {TS1, {B0, B1, B2, B3, B4, B5, B6, B7}}) ->
    Interval = TS0 - TS1,
    {rate(A0 - B0, Interval), rate(A1 - B1, Interval), rate(A2 - B2, Interval),
     rate(A3 - B3, Interval), rate(A4 - B4, Interval), rate(A5 - B5, Interval),
     rate(A6 - B6, Interval), rate(A7 - B7, Interval)};
rate_from_difference({TS0, {A0, A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13,
			    A14, A15, A16, A17, A18, A19}},
		     {TS1, {B0, B1, B2, B3, B4, B5, B6, B7, B8, B9, B10, B11, B12, B13,
			    B14, B15, B16, B17, B18, B19}}) ->
    Interval = TS0 - TS1,
    {rate(A0 - B0, Interval), rate(A1 - B1, Interval), rate(A2 - B2, Interval),
     rate(A3 - B3, Interval), rate(A4 - B4, Interval), rate(A5 - B5, Interval),
     rate(A6 - B6, Interval), rate(A7 - B7, Interval), rate(A8 - B8, Interval),
     rate(A9 - B9, Interval), rate(A10 - B10, Interval), rate(A11 - B11, Interval),
     rate(A12 - B12, Interval), rate(A13 - B13, Interval), rate(A14 - B14, Interval),
     rate(A15 - B15, Interval), rate(A16 - B16, Interval), rate(A17 - B17, Interval),
     rate(A18 - B18, Interval), rate(A19 - B19, Interval)};
rate_from_difference({TS0, {A0}}, {TS1, {B0}}) ->
    Interval = TS0 - TS1,
    {rate(A0 - B0, Interval)}.

rate(V, Interval) ->
    V * 1000 / Interval.

empty(Type, V) when Type =:= connection_stats_coarse_conn_stats;
			Type =:= channel_stats_fine_stats;
			Type =:= channel_exchange_stats_fine_stats;
			Type =:= vhost_stats_fine_stats;
			Type =:= queue_msg_stats;
			Type =:= vhost_msg_stats ->
    {V, V, V};
empty(Type, V) when Type =:= channel_queue_stats_deliver_stats;
			Type =:= queue_stats_deliver_stats;
			Type =:= vhost_stats_deliver_stats;
			Type =:= channel_stats_deliver_stats ->
    {V, V, V, V, V, V, V};
empty(Type, V) when Type =:= channel_process_stats;
			Type =:= queue_process_stats;
			Type =:= queue_stats_publish;
			Type =:= queue_exchange_stats_publish;
			Type =:= exchange_stats_publish_out;
			Type =:= exchange_stats_publish_in ->
    {V};
empty(node_coarse_stats, V) ->
    {V, V, V, V, V, V, V, V};
empty(node_persister_stats, V) ->
    {V, V, V, V, V, V, V, V, V, V, V, V, V, V, V, V, V, V, V, V};
empty(Type, V) when Type =:= node_node_coarse_stats;
			Type =:= vhost_stats_coarse_conn_stats;
			Type =:= queue_msg_rates;
			Type =:= vhost_msg_rates ->
    {V, V}.

append_sample(S, TS, List) ->
    [[{sample, S}, {timestamp, TS}] | List].

%%----------------------------------------------------------------------------
%% Match specs to select from the ETS tables
%%----------------------------------------------------------------------------
to_match_condition({'_', Id1}) when is_tuple(Id1) ->
    {'==', {Id1}, '$2'};
to_match_condition({'_', Id1}) ->
    {'==', Id1, '$2'};
to_match_condition({Id0, '_'}) when is_tuple(Id0) ->
    {'==', {Id0}, '$1'};
to_match_condition({Id0, '_'}) ->
    {'==', Id0, '$1'}.

avg_time(_Total, Count) when Count == 0;
			     Count == 0.0 ->
    0.0;
avg_time(Total, Count) ->
    (Total / Count) / ?MICRO_TO_MILLI.
