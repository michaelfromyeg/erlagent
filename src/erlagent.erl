-module(erlagent).
-export([run/0]).

run() ->
  io:format("Starting conversation...~n"),
  run([]).

run(Conversation) ->
  Input = string:trim(io:get_line("You: ")),
  case Input of
    "quit" ->
      finish(Conversation);
    _ ->
      %% Erlang is weird about strings; "hello" is actually represented
      %% as a list of integers (character codes), vs. `<<"hello">>` is
      %% represented as a binary, compact byte sequence
      %% because we serialize to JSON (for the API call), we use binary strings
      Msg = #{<<"role">> => <<"user">>, <<"content">> => list_to_binary(Input)},
      run([Msg | Conversation])
  end.

finish(Conversation) ->
  io:format("~p~n", [Conversation]).
