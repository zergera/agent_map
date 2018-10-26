defmodule AgentMapRequestTest do
  alias AgentMap.{Req, Time}
  import Time
  import Req

  use ExUnit.Case

  defp ms(), do: 1_000_000

  test "timeout" do
    req = %Req{action: :get_and_update}
    assert timeout(%{req | timeout: :infinity}) == :infinity
    assert timeout(req) == 5000
    assert timeout(%{req | timeout: {:!, 1000}}) == 1000

    past = now() - 3 * ms()
    assert timeout(%{req | timeout: {:!, 1000}, inserted_at: past}) < 1000
    assert timeout(%{req | timeout: 1000, inserted_at: past}) < 1000
  end

  test "compress" do
    f = & &1

    req = %Req{action: :max_processes, key: :a, data: 6}
    assert compress(req) == %{action: :max_processes, data: 6, !: 256}

    req = %Req{action: :get, key: :a, fun: f, data: nil}
    assert compress(req) == %{action: :get, fun: f, !: 256}

    past = now()

    req = %Req{
      action: :get,
      key: :a,
      fun: f,
      data: nil,
      timeout: {:!, 1000},
      inserted_at: past
    }

    assert compress(req) == %{
             action: :get,
             fun: f,
             timeout: {:!, 1000},
             inserted_at: past,
             !: 256
           }
  end
end
