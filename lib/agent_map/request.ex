defmodule AgentMap.Req do
  @moduledoc false

  alias AgentMap.{Callback, Worker, Transaction, Req}

  @max_threads 5

  defstruct [:action,  # :get, :get_and_update, :update, :cast, …
             :data,    # {key, fun}, {fun, keys}, {key, fun, opts}
             :from,
             !: false] # is not urgent by default


  def to_msg(%Req{!: true}=req), do: {:!, to_msg %{req | !: false}}

  def to_msg(%Req{action: :cast, data: {_, fun}}) do
    {:cast, fun}
  end
  def to_msg(%Req{action: {:one_key_t, :cast}, data: {_, fun}}) do
    {{:one_key_t, :cast}, fun}
  end

  def to_msg(%Req{data: {_, fun}}=req), do: {req.action, fun, req.from}


  def fetch(map, key) do
    case map[key] do
      {:pid, worker} ->
        {_, dict} = Process.info worker, :dictionary
        Keyword.fetch dict, :'$state'

      {{:state, state}, _} ->
        {:ok, state}

      nil -> :error
    end
  end

  def spawn_worker(map, key) do
    worker = spawn_link Worker, :loop, [self(), key, map[key]]
    put_in map[key], {:pid, worker}
  end

  # →
  def handle(%Req{action: :get, data: {fun, [key]}}=req, map) do
    handle %{req | data: {key, &Callback.run(fun, [[&1]])}}, map
  end

  def handle(%Req{data: {_fun, keys}}=req, map) when is_list(keys) do
    {:noreply, Transaction.run(req, map)}
  end

  def handle(%Req{action: :get, !: true}=req, map) do
    {key, fun} = req.data

    Task.start_link fn ->
      state = case fetch map, key do
        {:ok, state} -> state
        :error -> nil
      end

      GenServer.reply req.from, Callback.run(fun, [state])
    end

    {:noreply, map}
  end

  def handle(%Req{action: :get}=req, map) do
    {key,fun} = req.data

    case map[key] do

      {:pid, worker} ->
        send worker, to_msg req
        {:noreply, map}

      {_, 1} -> # cannot spawn more Task's
        map = spawn_worker map, key
        handle req, map

      {state, :infinity} ->
        state = if state do {:state, s} = state; s end

        Task.start_link fn ->
          GenServer.reply req.from, Callback.run(fun, [state])
        end
        {:noreply, map}

      {state, quota} when quota > 1 ->
        server = self()
        state = if state do {:state, s} = state; s end

        Task.start_link fn ->
          GenServer.reply req.from, Callback.run(fun, [state])
          send server, {:done_on_server, key}
        end

        map = put_in map[key], {state, quota-1}
        {:noreply, map}

      nil -> # no such key
        map = put_in map[key], {nil, @max_threads}
        handle req, map
    end
  end

  def handle(%Req{action: :put}=req, map) do
    {key, state} = req.data

    case map[key] do
      {{:state, _}, quota} ->
        map = put_in map[key], {{:state, state}, quota}
        {:noreply, map}

      {:pid, worker} ->
        send worker, to_msg %{req | action: :cast}
        {:noreply, map}

      {nil, max_t} ->
        value = {{:state, state}, max_t}
        map = put_in map[key], value
        {:noreply, map}

      nil ->
        map = put_in map[key], {nil, @max_threads}
        handle req, map
    end
  end

  def handle(%Req{action: :pop}=req, map) do
    {key, default} = req.data

    case fetch map, key do
      {:ok, _} ->
        req = %{req | action: :get_and_update,
                      data: {key, fn _ -> :pop end}}
        handle req, map

      :error ->
        {:reply, default, map}
    end
  end

  def handle(req, map) do
    {key,_} = req.data

    case map[key] do
      {:pid, worker} ->
        send worker, to_msg req
        {:noreply, map}

      _ ->
        map = spawn_worker map, key
        handle req, map
    end
  end

end
