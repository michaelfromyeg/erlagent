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
      UserMsg = #{<<"role">> => <<"user">>, <<"content">> => list_to_binary(Input)},
      NewConversation = [UserMsg | Conversation],
      Answer = run_inference(NewConversation),
      io:format("Erlagent: ~ts~n", [Answer]),
      AgentMsg = #{<<"role">> => <<"assistant">>, <<"content">> => Answer},
      run([AgentMsg | NewConversation])
  end.

run_inference(Conversation) ->
  ApiKey = os:getenv("ANTHROPIC_API_KEY"),
  URL = <<"https://api.anthropic.com/v1/messages">>,
  Headers = [
    {<<"content-type">>, <<"application/json">>},
    {<<"x-api-key">>, list_to_binary(ApiKey)},
    {<<"anthropic-version">>, <<"2023-06-01">>}
  ],
  Body = jsx:encode(#{
                      <<"model">> => <<"claude-sonnet-4-20250514">>,
                      <<"max_tokens">> => 1024,
                      <<"messages">> => lists:reverse(Conversation)
                      }),
  {ok, Status, _RespHeaders, RespBody} = hackney:request(post, URL, Headers, Body, [with_body, {connect_timeout, 10000}, {pool, false}]),
  case Status of
    200 ->
      DecBody = jsx:decode(RespBody),
      [First | _Rest] = maps:get(<<"content">>, DecBody),
      maps:get(<<"text">>, First);
    _ ->
      io:format("An error occurred.~n")
  end.

finish(Conversation) ->
  io:format("~p~n", [Conversation]).
