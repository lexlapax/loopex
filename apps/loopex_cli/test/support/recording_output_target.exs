defmodule LoopexCli.Test.RecordingOutputTarget do
  @moduledoc false

  # Concept: an owned output target that tells the test each write it completes.
  #
  # Technical depth: it speaks the owned-target protocol from the original
  # target process. Each completed write appends to its buffers and reports
  # `{:written, bytes}` and `{:target_written, self(), destination, bytes}`.
  # `hold_first: true` reports `{:blocked_control_output, self()}` for the first
  # write and completes it only on `{:release_output, :ok}`; any other release
  # result ends this target, which its owner observes as target loss.
  # `block_closing: true` holds the chat closing record until `:release_closing`.

  def start(test, options \\ []) do
    spawn(fn ->
      loop(%{
        test: test,
        hold_first: Keyword.get(options, :hold_first, false),
        fail_first: Keyword.get(options, :fail_first, false),
        block_closing: Keyword.get(options, :block_closing, false),
        owner: nil,
        incarnation: nil,
        stdout: [],
        stderr: []
      })
    end)
  end

  def contents(target) do
    ref = make_ref()
    send(target, {:recorded_contents, self(), ref})

    receive do
      {^ref, contents} -> contents
    after
      5_000 -> raise "the recording target did not answer"
    end
  end

  defp loop(state) do
    receive do
      {:loopex_cli_output_target, :acquire, owner, id} when state.owner == nil ->
        incarnation = make_ref()
        send(owner, {:loopex_cli_output_target, :acquired, self(), id, incarnation})
        loop(%{state | owner: owner, incarnation: incarnation})

      {:loopex_cli_output_target, :write, owner, incarnation, nonce, destination, bytes}
      when owner == state.owner and incarnation == state.incarnation ->
        state = before_write(state, bytes)
        state = Map.update!(state, destination, &[&1, bytes])
        send(state.test, {:written, bytes})
        send(state.test, {:target_written, self(), destination, bytes})
        send(owner, {:loopex_cli_output_target, :written, self(), incarnation, nonce})
        loop(state)

      {:loopex_cli_output_target, :retire, owner, incarnation, nonce}
      when owner == state.owner and incarnation == state.incarnation ->
        send(owner, {:loopex_cli_output_target, :retired, self(), incarnation, nonce})
        loop(state)

      {:recorded_contents, from, ref} ->
        send(from, {ref, {IO.iodata_to_binary(state.stdout), IO.iodata_to_binary(state.stderr)}})
        loop(state)
    end
  end

  defp before_write(%{fail_first: true} = state, _bytes) do
    send(state.test, {:broken_output_fault, self()})
    exit(:broken_output)
  end

  defp before_write(%{hold_first: true} = state, _bytes) do
    send(state.test, {:blocked_control_output, self()})

    receive do
      {:release_output, :ok} -> %{state | hold_first: false}
      {:release_output, _failure} -> exit(:broken_output)
    end
  end

  defp before_write(%{block_closing: true} = state, bytes) do
    if String.starts_with?(bytes, "@loopex ") and
         JSON.decode!(binary_part(bytes, 8, byte_size(bytes) - 8))["event"] == "closing" do
      send(state.test, {:blocked_closing, self()})
      receive do: (:release_closing -> :ok)
    end

    state
  end

  defp before_write(state, _bytes), do: state
end
