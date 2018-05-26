defmodule AgentMap.Server do
  @moduledoc false
  require Logger

  alias AgentMap.{Callback, Req}

  import Enum, only: [uniq: 1]
  import Map, only: [delete: 2]

  use GenServer

  @max_threads 5

  ##
  ## GenServer callbacks
  ##

  def init({funs, timeout}) do
    with keys = Keyword.keys(funs),
         # check for dups
         [] <- keys -- uniq(keys),
         {:ok, results} <- Callback.safe_run(funs, timeout) do
      map =
        for {key, s} <- results, into: %{} do
          {key, {{:value, s}, @max_threads}}
        end

      {:ok, map}
    else
      {:error, reason} ->
        {:stop, reason}

      dup ->
        {:stop,
         for key <- dup do
           {key, :exists}
         end}
    end
  end

  def handle_call(req, from, map) do
    Req.handle(%{req | from: from}, map)
  end

  def handle_cast(req, map) do
    map =
      case Req.handle(req, map) do
        {:reply, _r, map} ->
          map

        {_, map} ->
          map
      end

    {:noreply, map}
  end

  ##
  ## INFO
  ##

  def handle_info({:done_on_server, key}, map) do
    case map[key] do
      {:pid, worker} ->
        send(worker, {:!, :done_on_server})
        {:noreply, map}

      {nil, @max_threads} ->
        {:noreply, delete(map, key)}

      {_, :infinity} ->
        {:noreply, map}

      {value, quota} ->
        map = put_in(map[key], {value, quota + 1})
        {:noreply, map}

      _ ->
        {:noreply, map}
    end
  end

  def handle_info({:chain, data, from}, map) do
    %Req{action: :get_and_update, data: data, from: from}
    |> Req.handle(map)
  end

  # Worker asks to exit.
  def handle_info({worker, :mayidie?}, map) do
    {_, dict} = Process.info(worker, :dictionary)

    # Msgs could came during a small delay between
    # this call happend and :mayidie? was sent.
    {_, queue} = Process.info(worker, :messages)

    if length(queue) > 0 do
      send(worker, :continue)
      {:noreply, map}
    else
      max_t = dict[:"$max_threads"]
      value = dict[:"$value"]
      key = dict[:"$key"]

      send(worker, :die!)

      if {value, max_t} == {:no, @max_threads} do
        # GC
        {:noreply, delete(map, key)}
      else
        map = put_in(map[key], {value, max_t})
        {:noreply, map}
      end
    end
  end

  def handle_info(msg, value) do
    super(msg, value)
  end

  def code_change(_old, map, fun) do
    for key <- Map.keys(map) do
      %Req{action: :cast, data: {key, fun}}
      |> Req.handle(map)
    end

    {:ok, map}
  end
end
