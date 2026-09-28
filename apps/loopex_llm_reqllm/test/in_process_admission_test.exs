defmodule Loopex.LLM.ReqLLM.InProcess.AdmissionTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias Loopex.LLM.ReqLLM.InProcess.Admission

  defmodule Host do
    @moduledoc false
    @behaviour Admission
    @impl true
    def request({:return, result}, _operation, _deadline), do: result
    def request({:raise, value}, _operation, _deadline), do: raise(value)
    def request({:throw, value}, _operation, _deadline), do: throw(value)
    def request({:exit, value}, _operation, _deadline), do: exit(value)

    def request({:observe, test}, operation, deadline) do
      send(test, {:requested, self(), operation, deadline})
      {:ok, {:session_grant, make_ref(), elem(operation, 0), self(), make_ref(), deadline}}
    end
  end

  test "all model operations invoke the host callback in the requesting process" do
    for operation <- operations() do
      expiry = System.monotonic_time() + System.convert_time_unit(1, :second, :native)

      assert {:ok, {:session_grant, _, tag, requester, _, ^expiry}} =
               Admission.request(Host, {:observe, self()}, operation, expiry)

      assert tag == elem(operation, 0)
      assert requester == self()
      assert_receive {:requested, ^requester, ^operation, ^expiry}
    end
  end

  test "expired, malformed and foreign-edge operations never invoke the host" do
    deadline = System.monotonic_time() - 1
    assert closed?({:begin_model, self(), make_ref()}, deadline)

    future = System.monotonic_time() + System.convert_time_unit(1, :second, :native)

    for operation <- [
          :begin_model,
          {:begin_model, :not_a_pid, make_ref()},
          {:register_model, make_ref(), self(), :bad_proof},
          {:record_model_resources, make_ref(), self(), 0, []},
          {:tool_grant, self(), make_ref(), make_ref()}
        ] do
      assert closed?(operation, future)
    end

    refute_receive {:requested, _, _, _}
  end

  test "malformed, mismatched and stale host replies become the fixed refusal" do
    expiry = System.monotonic_time() + System.convert_time_unit(1, :second, :native)
    operation = {:begin_model, self(), make_ref()}
    token = {:session_grant, make_ref(), :begin_model, self(), make_ref(), expiry}

    for reply <- [
          :ok,
          {:error, {:host_data, "private"}},
          {:ok, :invalid},
          {:ok, put_elem(token, 0, :other)},
          {:ok, put_elem(token, 1, :invalid)},
          {:ok, put_elem(token, 2, :retire_model)},
          {:ok, put_elem(token, 3, :other)},
          {:ok, put_elem(token, 4, :invalid)},
          {:ok, put_elem(token, 5, expiry + 1)},
          {:ok, put_elem(token, 5, System.monotonic_time() - 1)}
        ] do
      assert {:error, :session_admission_closed} =
               Admission.request(Host, {:return, reply}, operation, expiry)
    end
  end

  test "host exceptions and missing modules expose no host value" do
    expiry = System.monotonic_time() + System.convert_time_unit(1, :second, :native)
    operation = {:begin_model, self(), make_ref()}

    for handle <- [{:raise, "private"}, {:throw, "private"}, {:exit, "private"}] do
      assert {:error, :session_admission_closed} =
               Admission.request(Host, handle, operation, expiry)
    end

    assert {:error, :session_admission_closed} =
             Admission.request(__MODULE__, nil, operation, expiry)
  end

  test "only a live stage operation preserves the host's clean cancellation proof" do
    expiry = System.monotonic_time() + System.convert_time_unit(1, :second, :native)
    stage = {:stage_model, make_ref(), self(), make_ref(), make_ref(), :start_proof}
    clean = {:return, {:error, :model_stage_cancelled}}

    assert {:error, :model_stage_cancelled} = Admission.request(Host, clean, stage, expiry)

    assert {:error, :session_admission_closed} =
             Admission.request(Host, clean, {:begin_model, self(), make_ref()}, expiry)

    assert {:error, :session_admission_closed} =
             Admission.request(Host, clean, stage, System.monotonic_time() - 1)
  end

  defp closed?(operation, expiry),
    do:
      Admission.request(Host, {:observe, self()}, operation, expiry) ==
        {:error, :session_admission_closed}

  defp operations do
    ref = make_ref()
    proof = make_ref()

    [
      {:begin_model, self(), ref},
      {:stage_model, ref, self(), proof, make_ref(), :private_start_proof},
      {:register_model, ref, self(), proof},
      {:record_model_resources, ref, self(), 1, []},
      {:retire_model, ref, self(), proof},
      {:cancel_model, ref, :private_start_proof}
    ]
  end
end
