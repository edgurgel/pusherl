-compile([{parse_transform, lager_transform}]).
-module(websocket_handler).

-behavior(cowboy_websocket_handler).

-export([init/3]).
-export([websocket_init/3]).
-export([websocket_handle/3]).
-export([websocket_info/3]).
-export([websocket_terminate/3]).

init(_Transport, _Req, _Opts) ->
  {upgrade, protocol, cowboy_websocket}.

websocket_init(_TransportName, Req, _Opts) ->
  {AppKey, Req} = cowboy_req:binding(app_key, Req),
  case application:get_env(poxa, app_key) of
    {ok, AppKey} -> self() ! start,
      {ok, Req, empty};
    _ -> lager:error("Invalid app_key, expected ~p, found ~p",
                     [application:get_env(poxa, app_key), AppKey]), % FIXME error message?
      {shutdown, Req, empty}
  end.

websocket_handle({text, Json}, Req, State) ->
  try jsx:decode(Json) of
    DecodedJson -> Event = proplists:get_value(<<"event">>, DecodedJson),
      handle_pusher_event(Event, DecodedJson, Req, State)
  catch
    error:badarg -> lager:error("Invalid json"), % FIXME better error message
      {ok, Req, State}
  end.

handle_pusher_event(<<"pusher:subscribe">>, DecodedJson, Req, State) ->
  Data = proplists:get_value(<<"data">>, DecodedJson, undefined),
  Reply = case subscription:subscribe(Data, State) of
    ok -> pusher_event:subscription_succeeded();
    {presence, Channel, PresenceData} -> pusher_event:presence_subscription_succeeded(Channel, PresenceData);
    error -> pusher_event:subscription_error()
  end,
  {reply, {text, Reply}, Req, State};
handle_pusher_event(<<"pusher:unsubscribe">>, DecodedJson, Req, State) ->
  Data = proplists:get_value(<<"data">>, DecodedJson, undefined),
  subscription:unsubscribe(Data),
  {ok, Req, State};
handle_pusher_event(<<"pusher:ping">>, _DecodedJson, Req, State) ->
  Reply = pusher_event:pong(),
  {reply, {text, Reply} ,Req, State};
% Client Events
handle_pusher_event(<<"client-", _EventName/binary>> = _Event, DecodedJson, Req, State) ->
  {Message, Channels, _Exclude} = pusher_event:parse_channels(DecodedJson),
  [pusher_event:send_message_to_channel(Channel, Message, [self()]) ||
    Channel <- Channels, private_or_presence_channel(Channel),
                         subscription:is_subscribed(Channel)],
  {ok, Req, State};
handle_pusher_event(_, _Data, Req, State) ->
  lager:error("Undefined event"),
  {ok, Req, State}.

private_or_presence_channel(Channel) ->
  case Channel of
    <<"presence-", _PresenceChannel/binary>> ->
      true;
    <<"private-", _PrivateChannel/binary>> ->
      true;
    _ -> false
  end.

websocket_info(start, Req, _State) ->
  % Unique identifier for the connection
  SocketId =  list_to_binary(uuid:to_string(uuid:uuid1())),
  % Register the name of the connection as SocketId
  gproc:reg({n, l, SocketId}),
  Reply = pusher_event:connection_established(SocketId),
  {reply, {text, Reply}, Req, SocketId};
websocket_info({_PID, Msg}, Req, State) ->
  {reply, {text, Msg}, Req, State};
websocket_info(Info, Req, State) ->
  lager:debug("WS Unknown message: ~p", [Info]),
  {ok, Req, State}.

websocket_terminate(_Reason, _Req, _State) ->
  presence_subscription:check_and_remove(),
  ok.
