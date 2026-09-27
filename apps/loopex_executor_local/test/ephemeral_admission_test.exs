defmodule Loopex.Executor.Local.EphemeralAdmissionTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias Loopex.Executor.Local.EphemeralAdmission

  defmodule Host do
    @moduledoc false
    @behaviour EphemeralAdmission
    @impl true
    def request({:return, result}, _operation, _deadline), do: result
    def request({:exit, reason}, _operation, _deadline), do: exit(reason)

    def request({:observe, test}, operation, deadline) do
      send(test, {:requested, self(), operation, deadline})
      {:ok, {:session_grant, make_ref(), :tool_grant, self(), make_ref(), deadline}}
    end
  end

  test "a tool grant remains correlated to this process and native expiry" do
    operation = {:tool_grant, self(), make_ref(), make_ref()}
    expiry = System.monotonic_time() + System.convert_time_unit(1, :second, :native)

    assert {:ok, {:session_grant, _, :tool_grant, requester, _, ^expiry}} =
             EphemeralAdmission.request(Host, {:observe, self()}, operation, expiry)

    assert requester == self()
    assert_receive {:requested, ^requester, ^operation, ^expiry}
  end

  test "expired, malformed and model-edge operations never invoke the host" do
    future = System.monotonic_time() + System.convert_time_unit(1, :second, :native)

    for {operation, expiry} <- [
          {{:tool_grant, self(), make_ref(), make_ref()}, System.monotonic_time() - 1},
          {{:tool_grant, self(), :bad_instance, make_ref()}, future},
          {{:tool_grant, self(), make_ref(), :bad_dispatch}, future},
          {{:begin_model, self(), make_ref()}, future}
        ] do
      assert {:error, :session_admission_closed} =
               EphemeralAdmission.request(Host, {:observe, self()}, operation, expiry)
    end

    refute_receive {:requested, _, _, _}
  end

  test "malformed, mismatched and stale replies and host loss stay fixed" do
    operation = {:tool_grant, self(), make_ref(), make_ref()}
    expiry = System.monotonic_time() + System.convert_time_unit(1, :second, :native)
    token = {:session_grant, make_ref(), :tool_grant, self(), make_ref(), expiry}

    for reply <- [
          :ok,
          {:error, "private"},
          {:ok, :invalid},
          {:ok, put_elem(token, 1, :bad_generation)},
          {:ok, put_elem(token, 2, :begin_model)},
          {:ok, put_elem(token, 3, :other)},
          {:ok, put_elem(token, 4, :bad_reference)},
          {:ok, put_elem(token, 5, expiry + 1)},
          {:ok, put_elem(token, 5, System.monotonic_time() - 1)}
        ] do
      assert {:error, :session_admission_closed} =
               EphemeralAdmission.request(Host, {:return, reply}, operation, expiry)
    end

    assert {:error, :session_admission_closed} =
             EphemeralAdmission.request(Host, {:exit, "private"}, operation, expiry)

    assert {:error, :session_admission_closed} =
             EphemeralAdmission.request(__MODULE__, nil, operation, expiry)
  end
end
