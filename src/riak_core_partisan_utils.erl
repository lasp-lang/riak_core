%% -------------------------------------------------------------------
%%
%% Copyright (c) 2017 Christopher Meiklejohn.  All Rights Reserved.
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

-module(riak_core_partisan_utils).
-author("Christopher S. Meiklejohn <christopher.meiklejohn@gmail.com>").

-export([cast/3,
         bang_unreliable/3,
         bang_reliable/3,
         join/1, 
         leave/1, 
         update/1, 
         forward/4,
         configure_dispatch/0]).

%% The major difference in Riak was that bang vs. bang_unreliable were used
%% avoid buffer overflows with Distributed Erlang's distribution port;
%% bang_unreliable wouldn't establish a connection, where as the reliable
%% version would use gen_fsm:send; in our model, we have the function
%% distinction for portability but they both function mostly the same: until we need
%% the distinction.

cast(Tag, Destination, Message) ->
    Options = [noconnect, nosuspend],
    bang(Tag, Destination, {'$gen_cast', Message}, Options),
    ok.

bang_unreliable(Tag, Destination, Message) ->
    bang(Tag, Destination, Message, [noconnect, nosuspend]).

bang_reliable(Tag, Destination, Message) ->
    bang(Tag, Destination, Message, []).

bang(Tag, Pid, Message, _Options) when is_pid(Pid) ->
    Node = node(Pid),
    forward(Tag, Node, Pid, Message),
    Message;
bang(_Tag, Port, Message, Options) when is_port(Port) ->
    catch erlang:send(Port, Message, Options),
    Message;
bang(_Tag, RegName, Message, Options) when is_atom(RegName) ->
    catch erlang:send(RegName, Message, Options),
    Message;
bang(Tag, {RegName, Node}, Message, _Options) when is_atom(RegName) ->
    forward(Tag, Node, RegName, Message),
    Message.

forward(_Type, Peer, Module, Message) ->
    case should_dispatch() of
        false ->
            case node() of
                Peer ->
                    erlang:send(Module, Message);
                _ ->
                    erlang:send({Module, Peer}, Message)
            end;
        true ->
            Manager = partisan_config:get(partisan_peer_service_manager,
                                          partisan_default_peer_service_manager),
            Manager:forward_message(Peer, Module, Message)
    end.

update(Nodes) ->
    lager:info("Membership now updating members to: ~p on node ~p", [Nodes, node()]),
    partisan_peer_service:update_members(Nodes).

leave(Node) ->
    ok = partisan_peer_service:leave(Node).

join(Nodes) when is_list(Nodes) ->
    [join(Node) || Node <- Nodes],
    ok;
join(Node) ->
    %% Use RPC to get the node's specific IP and port binding
    %% information for the partisan backend connections.
    ListenAddrs = rpc:call(Node, partisan_config, get, [listen_addrs]),

    %% Ignore failure, partisan will retry in the background to
    %% establish connections.
    ok = partisan_peer_service:join(#{name => Node, listen_addrs => ListenAddrs}),

    ok.

%% @private
should_dispatch() ->
    partisan_mochiglobal:get(partisan_dispatch, false).

configure_dispatch() ->
    ShouldDispatch = application:get_env(riak_core, partisan_dispatch, false),
    Dispatch = case ShouldDispatch of
        undefined ->
            false;
        Other ->
            Other
    end,
    lager:info("Configuring partisan dispatch: ~p", [Dispatch]),
    partisan_mochiglobal:put(partisan_dispatch, Dispatch).