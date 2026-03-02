-module(erlagent).

-export([run/0]).

read_file(Input) ->
  Path = maps:get(<<"path">>, Input),
  case file:read_file(Path) of
    {ok, Content} ->
      Content;
    {error, Reason} ->
      list_to_binary(io_lib:format("Error: ~p", [Reason]))
  end.

read_file_tool() ->
  #{name => <<"read_file">>,
    description => <<"Read the contents of a file">>,
    function => fun read_file/1,
    params =>
      [#{name => <<"path">>,
         type => <<"string">>,
         description => <<"The relative path of the file">>}]}.

list_files(Input) ->
  Path =
    case maps:get(<<"path">>, Input, <<"">>) of
      <<"">> ->
        ".";
      P ->
        binary_to_list(P)
    end,
  case file:list_dir(Path) of
    {ok, Files} ->
      jsx:encode(
        lists:map(fun list_to_binary/1, Files));
    {error, Reason} ->
      list_to_binary(io_lib:format("Error: ~p", [Reason]))
  end.

list_files_tool() ->
  #{name => <<"list_files">>,
    description => <<"List files in a directory">>,
    function => fun list_files/1,
    params =>
      [#{name => <<"path">>,
         type => <<"string">>,
         description => <<"The path to a directory, ending in a /">>}]}.

edit_file(Input) ->
  OldStr = maps:get(<<"old_str">>, Input),
  NewStr = maps:get(<<"new_str">>, Input),
  case OldStr =:= NewStr of
    true ->
      <<"Error: old_str and new_str must be different!">>;
    false ->
      Path = maps:get(<<"path">>, Input),
      case filelib:is_file(binary_to_list(Path)) of
        true ->
          case OldStr of
            <<"">> ->
              file:write_file(Path, NewStr),
              <<"OK">>;
            _ ->
              {ok, Content} = file:read_file(Path),
              NewContent = binary:replace(Content, OldStr, NewStr),
              case NewContent =:= Content of
                true ->
                  <<"Error: old_str not found in file!">>;
                false ->
                  file:write_file(Path, NewContent),
                  <<"OK">>
              end
          end;
        false ->
          filelib:ensure_dir(Path),
          file:write_file(Path, NewStr),
          <<"OK">>
      end
  end.

edit_file_tool() ->
  #{name => <<"edit_files">>,
    description =>
      <<"Make edits to a text file.\n\nReplaces 'old_str' with 'new_str' "
        "in the given file. 'old_str' and 'new_str' must be different.\nIf "
        "the file specified doesn't exist, it will be created.\n">>,
    function => fun edit_file/1,
    params =>
      [#{name => <<"path">>,
         type => <<"string">>,
         description => <<"The path to the file">>},
       #{name => <<"old_str">>,
         type => <<"string">>,
         description => <<"Text to search for - must exactly match the original string">>},
       #{name => <<"new_str">>,
         type => <<"string">>,
         description => <<"Text to replace old_str with">>}]}.

run_command(Input) ->
  Command = binary_to_list(maps:get(<<"command">>, Input)),
  io:format("Run command: ~ts? [y/n] ", [Command]),
  UserInput = io:get_line(""),
  case string:trim(UserInput) of
    "y" ->
      list_to_binary(os:cmd(Command));
    _ ->
      <<"Command rejected by user.">>
  end.

run_command_tool() ->
  #{name => <<"run_command">>,
    description => <<"Run a command">>,
    function => fun run_command/1,
    params =>
      [#{name => <<"command">>,
         type => <<"string">>,
         description =>
           <<"The command to be run. The user has the ability to accept or "
             "reject.">>}]}.

tool_to_jsonschema(Tool) ->
  #{<<"type">> => <<"object">>,
    <<"properties">> =>
      lists:foldl(fun(Param, Acc) ->
                     Name = maps:get(name, Param),
                     Prop =
                       #{<<"type">> => maps:get(type, Param),
                         <<"description">> => maps:get(description, Param)},
                     maps:put(Name, Prop, Acc)
                  end,
                  #{},
                  maps:get(params, Tool)),
    <<"required">> => lists:map(fun(P) -> maps:get(name, P) end, maps:get(params, Tool))}.

tools_to_api(Tools) ->
  lists:map(fun(Tool) ->
               #{<<"name">> => maps:get(name, Tool),
                 <<"description">> => maps:get(description, Tool),
                 <<"input_schema">> => tool_to_jsonschema(Tool)}
            end,
            Tools).

find_tool(Name, Tools) ->
  case lists:filter(fun(T) -> maps:get(name, T) =:= Name end, Tools) of
    [Tool | _] ->
      {ok, Tool};
    [] ->
      {error, not_found}
  end.

run() ->
  io:format("Starting conversation...~n"),
  Tools = [read_file_tool(), list_files_tool(), edit_file_tool(), run_command_tool()],
  run([], Tools).

run(Conversation, Tools) ->
  Input =
    string:trim(
      io:get_line("You: ")),
  case Input of
    "quit" ->
      finish(Conversation);
    _ ->
      %% Erlang is weird about strings; "hello" is actually represented
      %% as a list of integers (character codes), vs. `<<"hello">>` is
      %% represented as a binary, compact byte sequence
      %% because we serialize to JSON (for the API call), we use binary strings
      UserMsg = #{<<"role">> => <<"user">>, <<"content">> => list_to_binary(Input)},
      NewConversation = loop([UserMsg | Conversation], Tools),
      run(NewConversation, Tools)
  end.

loop(Conversation, Tools) ->
  DecBody = run_inference(Conversation, Tools),
  NewConversation = process_response(Conversation, Tools, DecBody),
  case maps:get(<<"stop_reason">>, DecBody) of
    <<"end_turn">> ->
      NewConversation;
    <<"tool_use">> ->
      loop(NewConversation, Tools)
  end.

run_inference(Conversation, Tools) ->
  ApiKey = os:getenv("ANTHROPIC_API_KEY"),
  URL = <<"https://api.anthropic.com/v1/messages">>,
  Headers =
    [{<<"content-type">>, <<"application/json">>},
     {<<"x-api-key">>, list_to_binary(ApiKey)},
     {<<"anthropic-version">>, <<"2023-06-01">>}],
  Body =
    jsx:encode(#{<<"model">> => <<"claude-sonnet-4-20250514">>,
                 <<"max_tokens">> => 1024,
                 <<"messages">> => lists:reverse(Conversation),
                 <<"tools">> => tools_to_api(Tools)}),
  {ok, Status, _RespHeaders, RespBody} =
    hackney:request(post,
                    URL,
                    Headers,
                    Body,
                    [with_body, {connect_timeout, 10000}, {pool, false}]),
  case Status of
    200 ->
      DecBody = jsx:decode(RespBody),
      DecBody;
    _ ->
      io:format("An error occurred.~n")
  end.

process_response(Conversation, Tools, DecBody) ->
  Content = maps:get(<<"content">>, DecBody),
  AssistantMsg = #{<<"role">> => <<"assistant">>, <<"content">> => Content},
  lists:foreach(fun(Block) ->
                   case maps:get(<<"type">>, Block) of
                     <<"text">> -> io:format("Erlagent: ~ts~n", [maps:get(<<"text">>, Block)]);
                     _ -> ok
                   end
                end,
                Content),
  ToolResults =
    lists:filtermap(fun(Block) ->
                       case maps:get(<<"type">>, Block) of
                         <<"tool_use">> ->
                           ToolName = maps:get(<<"name">>, Block),
                           ToolInput = maps:get(<<"input">>, Block),
                           ToolId = maps:get(<<"id">>, Block),

                           {ok, Tool} = find_tool(ToolName, Tools),

                           Function = maps:get(function, Tool),
                           Result = Function(ToolInput),

                           io:format("tool: ~ts(~ts)~n", [ToolName, jsx:encode(ToolInput)]),

                           {true,
                            #{<<"type">> => <<"tool_result">>,
                              <<"tool_use_id">> => ToolId,
                              <<"content">> => Result}};
                         _ -> false
                       end
                    end,
                    Content),
  ToolResultMsg = #{<<"role">> => <<"user">>, <<"content">> => ToolResults},
  case ToolResults of
    [] ->
      [AssistantMsg | Conversation];
    _ ->
      [ToolResultMsg, AssistantMsg | Conversation]
  end.

finish(Conversation) ->
  io:format("~p~n", [Conversation]).
