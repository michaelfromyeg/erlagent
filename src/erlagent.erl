-module(erlagent).
-export([run/0]).

read_file(Input) ->
    case file:read_file(maps:get(<<"path">>, Input)) of
        {ok, Content} -> Content;
        {error, Reason} -> Reason
    end.

read_file_tool() ->
    #{
        name => <<"read_file">>,
        description => <<"Read the contents of a file">>,
        function => fun read_file/1,
        params => [
            #{
                name => <<"path">>,
                type => <<"string">>,
                description => <<"The relative path of the file">>
            }
        ]
    }.

list_files(Input) ->
    Path =
        case maps:get(<<"path">>, Input, <<"">>) of
            <<"">> -> ".";
            P -> binary_to_list(P)
        end,
    % TODO(michaelfromyeg): append trailing slash when needed
    case file:list_dir(Path) of
        {ok, Files} -> jsx:encode(lists:map(fun list_to_binary/1, Files));
        {error, Reason} -> list_to_binary(io_lib:format("Error: ~p", [Reason]))
    end.

list_files_tool() ->
    #{
        name => <<"list_files">>,
        description => <<"List files in a directory">>,
        function => fun list_files/1,
        params => [
            #{
                name => <<"path">>,
                type => <<"string">>,
                description => <<"The path to a directory, ending in a /">>
            }
        ]
    }.

% TODO(michaelfromyeg): edit file
% edit_file(Input) ->

tool_to_jsonschema(Tool) ->
    #{
        <<"type">> => <<"object">>,
        <<"properties">> => lists:foldl(
            fun(Param, Acc) ->
                Name = maps:get(name, Param),
                Prop = #{
                    <<"type">> => maps:get(type, Param),
                    <<"description">> => maps:get(description, Param)
                },
                maps:put(Name, Prop, Acc)
            end,
            #{},
            maps:get(params, Tool)
        ),
        <<"required">> => lists:map(fun(P) -> maps:get(name, P) end, maps:get(params, Tool))
    }.

tools_to_api(Tools) ->
    lists:map(
        fun(Tool) ->
            #{
                <<"name">> => maps:get(name, Tool),
                <<"description">> => maps:get(description, Tool),
                <<"input_schema">> => tool_to_jsonschema(Tool)
            }
        end,
        Tools
    ).

find_tool(Name, Tools) ->
    case lists:filter(fun(T) -> maps:get(name, T) =:= Name end, Tools) of
        [Tool | _] -> {ok, Tool};
        [] -> {error, not_found}
    end.

run() ->
    io:format("Starting conversation...~n"),
    Tools = [read_file_tool(), list_files_tool()],
    run([], Tools).

run(Conversation, Tools) ->
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
    Headers = [
        {<<"content-type">>, <<"application/json">>},
        {<<"x-api-key">>, list_to_binary(ApiKey)},
        {<<"anthropic-version">>, <<"2023-06-01">>}
    ],
    Body = jsx:encode(#{
        <<"model">> => <<"claude-sonnet-4-20250514">>,
        <<"max_tokens">> => 1024,
        <<"messages">> => lists:reverse(Conversation),
        <<"tools">> => tools_to_api(Tools)
    }),
    {ok, Status, _RespHeaders, RespBody} = hackney:request(post, URL, Headers, Body, [
        with_body, {connect_timeout, 10000}, {pool, false}
    ]),
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

    lists:foreach(
        fun(Block) ->
            case maps:get(<<"type">>, Block) of
                <<"text">> -> io:format("Erlagent: ~ts~n", [maps:get(<<"text">>, Block)]);
                _ -> ok
            end
        end,
        Content
    ),

    ToolResults = lists:filtermap(
        fun(Block) ->
            case maps:get(<<"type">>, Block) of
                <<"tool_use">> ->
                    ToolName = maps:get(<<"name">>, Block),
                    ToolInput = maps:get(<<"input">>, Block),
                    ToolId = maps:get(<<"id">>, Block),

                    {ok, Tool} = find_tool(ToolName, Tools),

                    Function = maps:get(function, Tool),
                    Result = Function(ToolInput),

                    % TODO(michaelfromyeg): add print function for each tool
                    % io:format("[Using ~s on ~s~n]", ToolName, ToolInput),

                    {true, #{
                        <<"type">> => <<"tool_result">>,
                        <<"tool_use_id">> => ToolId,
                        <<"content">> => Result
                    }};
                _ ->
                    false
            end
        end,
        Content
    ),
    ToolResultMsg = #{<<"role">> => <<"user">>, <<"content">> => ToolResults},
    case ToolResults of
        [] -> [AssistantMsg | Conversation];
        _ -> [ToolResultMsg, AssistantMsg | Conversation]
    end.

finish(Conversation) ->
    io:format("~p~n", [Conversation]).
