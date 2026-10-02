defmodule LoopexComposition.TraceConfigurationTest do
  use ExUnit.Case, async: false

  alias Loopex.Trace.Config
  alias LoopexComposition.TraceConfiguration

  test "empty selection stays disabled with the existing runtime defaults" do
    assert {:ok, default} = Config.validate(%{})

    assert TraceConfiguration.validate(%{}) ==
             {:ok, %{enabled: false, configuration: default}}
  end

  test "explicit trace options map losslessly into the closed diagnostics configuration" do
    for {level, atom} <- [{"calls", :calls}, {"returns", :returns}, {"arguments", :arguments}] do
      selection = %{
        "enabled" => true,
        "level" => level,
        "modules" => ["Loopex.*", "LoopexProtocol.*", "Loopex.Runtime", "Elixir.Loopex.Runtime"],
        "max_entry_bytes" => 1,
        "max_entries_per_second" => 1,
        "max_queue_entries" => 1
      }

      assert TraceConfiguration.validate(selection) ==
               {:ok,
                %{
                  enabled: true,
                  configuration: %{
                    modules: [:loopex, :loopex_protocol, Loopex.Runtime],
                    level: atom,
                    limits: %{entry_bytes: 1, entries_per_second: 1, queued: 1},
                    sink: :diagnostics
                  }
                }}
    end
  end

  test "each trace limit may lower the runtime ceiling and never raise it" do
    ceilings = Config.ceilings()

    for {field, key} <- [
          {"max_entry_bytes", :entry_bytes},
          {"max_entries_per_second", :entries_per_second},
          {"max_queue_entries", :queued}
        ] do
      for value <- [1, ceilings[key]] do
        assert {:ok, selected} = TraceConfiguration.validate(%{field => value})
        assert selected.configuration.limits[key] == value
        assert selected.enabled == false
      end

      for value <- [0, -1, ceilings[key] + 1, nil, "1", 1.0, true] do
        assert TraceConfiguration.validate(%{field => value}) ==
                 {:error, :invalid_trace_configuration}
      end
    end
  end

  test "disabled tracing still validates every authored field and selector" do
    for fields <- [
          %{"level" => :calls},
          %{"level" => "CALLS"},
          %{"level" => nil},
          %{"modules" => []},
          %{"modules" => [:loopex]},
          %{"modules" => ["String"]},
          %{"modules" => ["Loopex.UnknownTraceModule"]},
          %{"modules" => ["ReqLLM.*"]},
          %{"modules" => ["Loopex.*" | :tail]},
          %{"modules" => [String.duplicate("x", 129)]},
          %{"modules" => [<<255>>]},
          %{"modules" => List.duplicate("Loopex.*", 65)}
        ] do
      assert TraceConfiguration.validate(Map.put(fields, "enabled", false)) ==
               {:error, :invalid_trace_configuration}
    end

    assert {:ok, %{configuration: %{modules: [:loopex]}}} =
             TraceConfiguration.validate(%{"modules" => List.duplicate("Loopex.*", 64)})
  end

  test "a host cannot inject another runtime, sink, callback, PID or arbitrary module atom" do
    for extra <- ["runtime", "sink", "diagnostics_to", "callback", "limits", :enabled] do
      assert TraceConfiguration.validate(%{extra => self()}) ==
               {:error, :invalid_trace_configuration}
    end

    for value <- [nil, true, false, [], :trace, %URI{}] do
      assert TraceConfiguration.validate(value) == {:error, :invalid_trace_configuration}
    end

    for enabled <- [nil, "true", :enabled, 1] do
      assert TraceConfiguration.validate(%{"enabled" => enabled}) ==
               {:error, :invalid_trace_configuration}
    end
  end

  test "selector validation creates no atom and starts no applications or trace process" do
    before = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    for i <- 1..100 do
      name = "UnknownSharedTraceModule#{i}"

      assert TraceConfiguration.validate(%{"enabled" => true, "modules" => [name]}) ==
               {:error, :invalid_trace_configuration}

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> name) end
    end

    assert {:ok, _} = TraceConfiguration.validate(%{"enabled" => true})
    assert Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort() == before
  end
end
