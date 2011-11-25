-module(proposer_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("proposer_state.hrl").
-include_lib("accepted_record.hrl").

-define(PROMISES(N),#state{promises=N}).
-define(ACCEPTS(N), #state{accepts=N}).
-define(ROUND(N),   #state{round=N}).
-define(VALUE(V),   #state{value=#proposal{value=V}}).


startup_behaviour_test_() -> {foreach, fun setup/0, fun teardown/1, [
    fun awaiting_promises/0,
    fun starts_with_round_1/0,
    fun starts_with_0_promises/0,
    fun remembers_proposal/0
]}.

    awaiting_promises() ->
        ?assertMatch({ok, awaiting_promises, _}, proposer:init([foo])).

    starts_with_round_1() ->
        ?assertMatch({ok, _, #state{round=1}}, proposer:init([foo])).

    starts_with_0_promises() ->
        ?assertMatch({ok, _, #state{promises=0}}, proposer:init([foo])).

    remembers_proposal() ->
        Proposal = foo,
        {ok, _, State} = proposer:init([Proposal]),
        Value = State#state.value#proposal.value,
        ?assertEqual(Proposal, Value).



awaiting_promises_transitions_test_() -> {foreach, fun setup/0, fun teardown/1, [
    fun should_restart_prepare_with_higher_round_when_higher_round_promise_seen/0,
    fun should_count_promises_for_same_round/0,
    fun should_not_count_promise_for_lower_round/0,
    fun should_ignore_proposal_value_sent_with_promise_when_round_lower/0,
    fun should_adopt_proposal_value_sent_with_promise_when_round_higher/0
]}.

    should_count_promises_for_same_round() -> 
        InitialState = #state{round = 10, promises = 1},
        Result = proposer:awaiting_promises(
            {promised, InitialState#state.round, no_value}, InitialState),
        {next_state, awaiting_promises, NewState=#state{}} = Result,
        ?assertEqual(InitialState#state.promises + 1, NewState#state.promises).

    %TODO property-testing candidate ?
    should_not_count_promise_for_lower_round() -> 
        InitialState = #state{round = 10, promises = 1},
        Result = proposer:awaiting_promises(
            {promised, InitialState#state.round - 1, no_value}, InitialState),
        {next_state, awaiting_promises, NewState=#state{}} = Result,
        ?assertEqual(InitialState#state.promises + 0, NewState#state.promises).

    should_restart_prepare_with_higher_round_when_higher_round_promise_seen() ->
        InitialState = #state{round = 1, value = #proposal{value = foo}},
        ReceivedRound = InitialState#state.round + 1,
        Result = proposer:awaiting_promises({promised, ReceivedRound, bar}, InitialState),
        {next_state, awaiting_promises, NewState=#state{}} = Result,
        ?assertEqual(ReceivedRound + 1, NewState#state.round),
        ?assertEqual(0, NewState#state.promises).

    should_ignore_proposal_value_sent_with_promise_when_round_lower() -> 
        ReceivedRound = 2, ReceivedValue = bar,
        InitialState = #state{round = 4, value = #proposal{value = foo}},
        Result = proposer:awaiting_promises({promised, ReceivedRound, ReceivedValue}, InitialState),
        {next_state, awaiting_promises, NewState=#state{}} = Result,
        ?assertEqual(InitialState#state.value, NewState#state.value).

    should_adopt_proposal_value_sent_with_promise_when_round_higher() ->
        InitialState = #state{round = 10, value = #proposal{value = foo}},
        {next_state, awaiting_promises, NewState} = proposer:awaiting_promises(
            {promised, InitialState#state.round, {4, bar}}, InitialState
        ),
        ?assertMatch(
            #state{ 
                value = #proposal{
                    accepted_in_round = 4, 
                    value = bar
                }
            }, NewState).
    


awaiting_promises_prepare_quorum_test_() -> {foreach, fun setup/0, fun teardown/1, [
    fun should_transition_to_awaiting_accepts_when_2_promises_and_promise_for_round_received/0
]}.

    should_transition_to_awaiting_accepts_when_2_promises_and_promise_for_round_received() ->
        Proposal = #proposal{value = v},
        InitialState = #state{round = 10, promises = 2, value = Proposal},
        ?assertMatch(
            {next_state, awaiting_accepts, #state{
                round = 10,
                accepts = 0,
                rejects = 0,
                value = Proposal
            }},
            proposer:awaiting_promises(
                {promised, InitialState#state.round, no_value}, InitialState
            )
        ).


%% Meck stub modules, used to enable decoupled unit tests
setup() ->
    Mods = [acceptors, gaoler],
    meck:new(Mods),
    meck:expect(gaoler, deliver, 1, ok),
    meck:expect(acceptors, send_accept_requests, 3, ok),
    meck:expect(acceptors, send_promise_requests, 2, ok),
    Mods.

teardown(Mods) ->
    meck:unload(Mods).


% happy case: no other proposers and round 1 succeeds
first_promise_received_test() ->
    Round = 1,
    InitialState = ?PROMISES(0)?ROUND(Round),    
    Result = proposer:awaiting_promises({promised, Round, no_value}, 
                  InitialState),
    ?assertMatch({next_state, awaiting_promises, ?PROMISES(1)}, Result).



%% Testing proposer accept request broadcasts
promise_quorum_broadcast_test_() -> 
    {foreach, 
     fun setup/0, fun teardown/1, 
     [  
        fun on_promise_quorum_state_moves_to_accepting/0, 
        fun on_promise_quorum_proposer_broadcasts_accept/0
     ]}.

on_promise_quorum_state_moves_to_accepting() ->
    Round = 1,
    InitialState = ?PROMISES(2)?ROUND(Round),
    Result = proposer:awaiting_promises({promised, Round, no_value},
                  InitialState),
    ?assertMatch({next_state, awaiting_accepts, ?PROMISES(3)}, Result).

on_promise_quorum_proposer_broadcasts_accept() ->
    Round = 1,
    InitialState = ?PROMISES(2)?ROUND(Round)?VALUE(foo),
    proposer:awaiting_promises({promised, Round, no_value},
                 InitialState),
    ?assert(meck:called(acceptors, send_accept_requests, '_')).


%% Testing proposer prepare request broadcasts
proposer_broadcast_prepare_test_() -> 
    {foreach, 
     fun setup/0, fun teardown/1, 
     [  
        fun on_init_proposer_broadcasts_prepare/0, 
        fun on_higher_promise_received_proposer_increments_round/0
     ]}.

% initialising proposer broadcasts prepare
on_init_proposer_broadcasts_prepare() ->
    proposer:init([val]),
    ?assert(meck:called(acceptors, send_promise_requests, [self(), _Round=1])).

% sad case: someone else has been promised a higher round
on_higher_promise_received_proposer_increments_round() ->
    Round = 1,
    AcceptedValue = no_value,
    InitialState = ?PROMISES(0)?ROUND(Round),
    Result = proposer:awaiting_promises({promised, 100, AcceptedValue}, 
                  InitialState),
    ?assertMatch({next_state, awaiting_promises, ?ROUND(101)}, Result).

% 
% %% TestCase: awaiting_accepts state
% awaiting_accepts_test_() ->
%     {foreach, 
%      fun setup/0, 
%      fun teardown/1,
%      [
%       fun first_accept_received/0,
%       fun on_accept_quorum_proposer_delivers_value/0,
%       fun on_accept_quorum_state_moves_to_accepted/0
%      ]
%     }.
% 
% first_accept_received() ->
%     Round = 1,
%     InitialState = ?PROMISES(3)?ACCEPTS(0)?ROUND(Round)?VALUE(foo),
%     Result = proposer:awaiting_accepts({accepted, Round}, InitialState),
%     ?assertMatch({next_state, awaiting_accepts, ?ACCEPTS(1)}, Result).
% 
% on_accept_quorum_proposer_delivers_value() ->
%     Round = 1,
%     Value = foo,
%     InitialState = ?PROMISES(3)?ACCEPTS(2)?ROUND(Round)?VALUE(Value),
%     proposer:awaiting_accepts({accepted, Round}, InitialState),
%     ?assert(meck:called(gaoler, deliver, [Value])).
% 
% on_accept_quorum_state_moves_to_accepted() ->
%     Round = 1,
%     Value = 1,
%     InitialState = ?PROMISES(3)?ACCEPTS(2)?ROUND(Round)?VALUE(Value),
%     Result = {_, _, AcceptedState} = 
%   proposer:awaiting_accepts({accepted, Round}, InitialState),
%     ?assertMatch({next_state, accepted, _}, Result),
%     ?assertEqual(InitialState?ACCEPTS(3), AcceptedState).
