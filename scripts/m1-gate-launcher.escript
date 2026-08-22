#!/usr/bin/env escript
%%! -noshell

-module(m1_gate_launcher).
-export([main/1]).

%% Concept: The launcher is the single-purpose process boundary that gives the
%% M1 gate a closed child environment without changing Bash's search path and
%% invalidating the immutable M0 gate.
%% Technical depth: It accepts one bounded NUL-framed control record on stdin,
%% clears every environment name visible to its VM from the Bash child, derives
%% and checks the exact non-secret child carriers, installs the five canonical
%% entries, forwards output, and preserves the child's exit.
-define(OUTER_HEADER, <<"LOOPEX_M1_LAUNCHER_V1">>).
-define(INNER_HEADER, <<"LOOPEX_M1_SEALED_INNER_V1">>).
-define(MAX_CONTROL_BYTES, 262144).

main(Arguments) ->
    try
        ok = bootstrap_environment(),
        {ok, Controls} = outer_controls(),
        ok = arguments(Arguments),
        launch(Arguments, Controls)
    catch
        throw:{refuse, Reason} -> refuse(Reason);
        _:_ -> refuse("sealed launcher failed before the gate started")
    end.

bootstrap_environment() ->
    Required = [
        {"ERL_CRASH_DUMP", "/dev/null"},
        {"ERL_CRASH_DUMP_SECONDS", "0"},
        {"LANG", "C.UTF-8"},
        {"LC_ALL", "C.UTF-8"}
    ],
    Environment = split_environment(os:getenv()),
    lists:foreach(
      fun({Name, Value}) ->
          case proplists:get_value(Name, Environment) of
              Value -> ok;
              _ -> throw({refuse, "sealed launcher bootstrap controls are unavailable"})
          end
      end,
      Required),
    ok.

split_environment(Environment) ->
    lists:map(
      fun(Entry) ->
          case string:split(Entry, "=", leading) of
              [Name, Value] -> {Name, Value};
              [Name] -> {Name, ""}
          end
      end,
      Environment).

outer_controls() ->
    io:setopts(standard_io, [binary]),
    case read_all([], 0) of
        {ok, Bytes} -> parse_outer_frame(Bytes);
        _ -> throw({refuse, "sealed launcher input is unavailable"})
    end.

read_all(Chunks, Size) ->
    case file:read(standard_io, 65536) of
        {ok, Bytes} ->
            NewSize = Size + byte_size(Bytes),
            case NewSize =< ?MAX_CONTROL_BYTES of
                true -> read_all([Bytes | Chunks], NewSize);
                false -> throw({refuse, "sealed launcher input exceeds its bound"})
            end;
        eof -> {ok, iolist_to_binary(lists:reverse(Chunks))};
        Error -> Error
    end.

parse_outer_frame(Bytes) ->
    case binary:split(Bytes, <<0>>, [global]) of
        [?OUTER_HEADER, SuppliedHome, TaskTmp, SourceMixHome, GateSeed, SafePath,
         ProviderKey, <<>>] ->
            Nonsecret = [SuppliedHome, TaskTmp, SourceMixHome, GateSeed, SafePath],
            case lists:all(fun(Value) -> control(Value) end, Nonsecret) andalso
                 safe_path(SafePath) of
                true ->
                    {ok, {SuppliedHome, TaskTmp, SourceMixHome, GateSeed, SafePath,
                          ProviderKey}};
                false ->
                    throw({refuse, "sealed launcher controls are malformed"})
            end;
        _ ->
            throw({refuse, "sealed launcher input is malformed"})
    end.

control(Value) ->
    binary:match(Value, <<"\n">>) =:= nomatch andalso
    binary:match(Value, <<"\r">>) =:= nomatch andalso
    binary:match(Value, <<0>>) =:= nomatch.

safe_path(Value) ->
    Entries = binary:split(Value, <<":">>, [global]),
    Entries =/= [] andalso
    lists:all(
      fun(Entry) ->
          control(Entry) andalso
          byte_size(Entry) > 1 andalso
          binary:at(Entry, 0) =:= $/
      end,
      Entries).

arguments(Arguments) ->
    case lists:member("--loopex-m1-sealed-inner", Arguments) of
        true -> throw({refuse, "sealed inner role cannot be requested directly"});
        false -> ok
    end.

launch(Arguments,
       Controls = {SuppliedHome, TaskTmp, SourceMixHome, GateSeed, SafePath,
                   ProviderKey}) ->
    InheritedNames = [Name || {Name, _} <- split_environment(os:getenv())],
    Clear = [{Name, false} || Name <- InheritedNames],
    Canonical = [
        {"PATH", binary_to_list(SafePath)},
        {"HOME", "/"},
        {"LANG", "C.UTF-8"},
        {"LC_ALL", "C.UTF-8"},
        {"GIT_OPTIONAL_LOCKS", "0"}
    ],
    Gate = filename:absname(filename:join(filename:dirname(escript:script_name()),
                                          "check-m1-gate.sh")),
    case filelib:is_regular(Gate) of
        true -> ok;
        false -> throw({refuse, "the sealed gate runner is unavailable"})
    end,
    ChildArguments = ["-p", Gate, "--loopex-m1-sealed-inner" | Arguments],
    ChildEnvironment = Clear ++ Canonical,
    NonsecretFrame = [
        ?INNER_HEADER,
        SuppliedHome,
        TaskTmp,
        SourceMixHome,
        GateSeed,
        SafePath
    ],
    ok = provider_carriers(
           ProviderKey,
           ["/bin/bash" | ChildArguments] ++
           environment_carriers(ChildEnvironment) ++ NonsecretFrame),
    Port = open_port(
             {spawn_executable, "/bin/bash"},
             [binary, use_stdio, exit_status,
              {args, ChildArguments},
              {env, ChildEnvironment}]),
    true = port_command(Port, inner_frame(Controls)),
    relay(Port).

environment_carriers([]) ->
    [];
environment_carriers([{Name, false} | Rest]) ->
    [Name | environment_carriers(Rest)];
environment_carriers([{Name, Value} | Rest]) ->
    [Name, Value, [Name, "=", Value] | environment_carriers(Rest)].

provider_carriers(<<>>, _Carriers) ->
    ok;
provider_carriers(ProviderKey, Carriers) ->
    case lists:any(
           fun(Carrier) ->
               binary:match(iolist_to_binary(Carrier), ProviderKey) =/= nomatch
           end,
           Carriers) of
        true -> throw({refuse, "sealed child carrier collides with provider credential bytes"});
        false -> ok
    end.

inner_frame({SuppliedHome, TaskTmp, SourceMixHome, GateSeed, SafePath, ProviderKey}) ->
    iolist_to_binary([
        ?INNER_HEADER, 0,
        SuppliedHome, 0,
        TaskTmp, 0,
        SourceMixHome, 0,
        GateSeed, 0,
        SafePath, 0,
        ProviderKey, 0
    ]).

relay(Port) ->
    receive
        {Port, {data, Bytes}} ->
            ok = file:write(standard_io, Bytes),
            relay(Port);
        {Port, {exit_status, Status}} ->
            halt(Status)
    after 3600000 ->
        port_close(Port),
        throw({refuse, "sealed gate child did not terminate"})
    end.

refuse(Reason) ->
    io:format(standard_error, "M1 gate RED: ~s~n", [Reason]),
    halt(1).
