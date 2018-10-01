defmodule AgentMap.Worker do
  require Logger

  alias AgentMap.{Common, CallbackError, Server.State}

  import Process, only: [get: 1, put: 2, delete: 1]
  import Common, only: [run: 4, reply: 2, now: 0, left: 2]
  import State, only: [un: 1, box: 1]

  @moduledoc false

  @compile {:inline, rand: 1, dict: 1, busy?: 1}

  # ms
  @wait 10

  defp rand(n) when n < 100, do: rem(now(), n)

  defp info(worker, key) do
    Process.info(worker, key) |> elem(1)
  end

  defp max_processes() do
    unless max_p = get(:max_processes) do
      dict(get(:gen_server))[:max_processes]
    else
      max_p
    end
  end

  def dict(worker \\ self()), do: info(worker, :dictionary)

  def busy?(worker) do
    info(worker, :message_queue_len) > 0
  end

  def processes(worker) do
    ps =
      Enum.count(
        info(worker, :messages),
        &match?(%{info: :get!}, &1)
      )

    get(:processes) + ps
  end

  ##
  ## CALLBACKS
  ##

  def share_value(to: me) do
    key = Process.get(:key)
    box = Process.get(:value)
    delete(:dontdie?)
    reply(me, {key, box})
  end

  def accept_value() do
    receive do
      :drop ->
        :pop

      :id ->
        :id

      {:value, v} ->
        {:_get, v}
    end
  end

  ##
  ## REQUEST
  ##

  defp timeout(%{timeout: {_, t}, inserted_at: i}), do: left(t, since: i)
  defp timeout(%{}), do: :infinity

  defp run(req, box) do
    timeout = Map.get(req, :timeout)
    break? = match?({:break, _}, timeout)
    t_left = timeout(req)
    arg = un(box)

    result = run(req.fun, [arg], t_left, break?)
    interpret(req, arg, result)
  end

  defp interpret(%{action: :get} = req, _arg, {:ok, get}) do
    Map.get(req, :from) |> reply(get)
  end

  defp interpret(req, _arg, {:ok, {get}}) do
    Map.get(req, :from) |> reply(get)
  end

  defp interpret(req, _arg, {:ok, {get, v}}) do
    put(:value, box(v))
    Map.get(req, :from) |> reply(get)
  end

  defp interpret(req, arg, {:ok, :id}) do
    Map.get(req, :from) |> reply(arg)
  end

  defp interpret(req, arg, {:ok, :pop}) do
    delete(:value)
    Map.get(req, :from) |> reply(arg)
  end

  defp interpret(_req, _arg, {:ok, reply}) do
    raise CallbackError, got: reply
  end

  defp interpret(req, arg, {:error, :expired}) do
    Logger.error("""
    Key #{inspect(get(:key))} call is expired and will not be executed.
    Request: #{inspect(req)}.
    Value: #{inspect(arg)}.
    """)
  end

  defp interpret(req, arg, {:error, :toolong}) do
    Logger.error("""
    Key #{inspect(get(:key))} call takes too long and will be terminated.
    Request: #{inspect(req)}.
    Value: #{inspect(arg)}.
    """)
  end

  def spawn_get_task(req, {key, box}, opts \\ [server: self()]) do
    Task.start_link(fn ->
      put(:key, key)
      put(:value, box)

      run(req, box)

      done = %{info: :done, key: key}
      worker = opts[:worker]

      if worker && Process.alive?(worker) do
        send(worker, done)
      else
        send(opts[:server], done)
      end
    end)
  end

  ##
  ## HANDLERS
  ##

  defp handle(%{action: :get} = req) do
    box = get(:value)

    p = get(:processes)

    if p < max_processes() do
      key = get(:key)
      s = get(:gen_server)

      spawn_get_task(req, {key, box}, server: s, worker: self())

      put(:processes, p + 1)
    else
      run(req, box)
    end
  end

  defp handle(%{action: :get_and_update} = req) do
    run(req, get(:value))
  end

  defp handle(%{action: :max_processes} = req) do
    put(:max_processes, req.data)
  end

  defp handle(%{info: :done}) do
    p = get(:processes)
    put(:processes, p - 1)
  end

  defp handle(%{info: :get!}) do
    p = get(:processes)
    put(:processes, p + 1)
  end

  defp handle(:dontdie!) do
    put(:dontdie?, true)
  end

  defp handle(msg) do
    k = inspect(get(:key))

    Logger.warn("""
    Worker (key: #{k}) got unexpected message #{inspect(msg)}
    """)
  end

  ##
  ## MAIN
  ##

  # box = {:value, any} | nil
  def loop({ref, server}, key, {box, {p, max_p}}) do
    put(:value, box)

    # One (1) process is for loop.
    put(:processes, p + 1)
    put(:max_processes, max_p)

    send(server, {ref, :ok})

    put(:key, key)
    put(:gen_server, server)

    put(:wait, @wait + rand(25))

    # →
    loop({[], []})
  end

  # →
  defp loop({[], []} = state) do
    wait = get(:wait)

    receive do
      req ->
        place(state, req) |> loop()
    after
      wait ->
        if get(:dontdie?) do
          loop(state)
        else
          send(get(:gen_server), {self(), :die?})

          receive do
            :die! ->
              :bye

            :continue ->
              # Next time wait a few ms more.
              wait = get(:wait)
              put(:wait, wait + rand(5))
              loop(state)
          end
        end
    end
  end

  defp loop({_, [%{action: :get} = req | _]} = state) do
    state = {p_queue, queue} = flush(state)

    if get(:processes) < get(:max_processes) do
      [_req | tail] = queue
      handle(req)
      loop({p_queue, tail})
    else
      run(state) |> loop()
    end
  end

  defp loop({p_queue, queue} = state) when p_queue != [] and queue != [] do
    run(state) |> loop()
  end

  defp loop(state) do
    receive do
      req ->
        place(state, req) |> loop()
    after
      0 ->
        # Mailbox is empty. Run:
        run(state) |> loop()
    end
  end

  #

  defp run({[], [req | tail]}) do
    handle(req)
    {[], tail}
  end

  defp run({p_queue, [%{action: :get_and_update} | _] = queue}) do
    for req <- p_queue do
      handle(req)
    end

    {[], queue}
  end

  defp run({[req | tail], queue}) do
    handle(req)
    {tail, queue}
  end

  #

  # Mailbox → queues.
  defp flush(state) do
    receive do
      req ->
        place(state, req) |> flush()
    after
      0 ->
        state
    end
  end

  #

  # Req → queues.
  defp place({p_queue, queue} = state, req) do
    case req do
      %{info: _} = msg ->
        handle(msg)
        state

      %{!: true} = req ->
        {[req | p_queue], queue}

      _ ->
        {p_queue, queue ++ [req]}
    end
  end
end
