defmodule MultiAgent.Worker do
  @moduledoc false

  @compile {:inline, rand: 1, dec: 1, inc: 1, new_state: 1}

  alias MultiAgent.Callback

  @wait 10 #milliseconds

  #
  # HELPERS
  #

  def dec(:infinity), do: :infinity
  def dec(i) when is_integer(i), do: i
  def dec( key), do: Process.put key, dec( Process.get key)

  def inc(:infinity), do: :infinity
  def inc(i) when is_integer(i), do: i
  def inc( key), do: Process.put key, inc( Process.get key)


  def new_state( state \\ nil), do: {state, false, 4} # 5 processes per state by def


  defp call?(:infinity), do: true
  defp call?( exp), do: Process.get(:'$late_call') || (System.system_time < exp)

  # is OK for numbers < 1000
  defp rand( to), do: rem System.system_time, to

  #
  # EXECUTE ACTION
  #

  defp execute(:get, fun, from) do
    state = Process.get :'$state'
    GenServer.reply from, Callback.run( fun, [state])
  end

  defp execute(:get_and_update, fun, from) do
    case Callback.run fun, [Process.get :'$state'] do
      {get, state} ->
        Process.put :'$state', state
        GenServer.reply from, get
      :pop ->
        GenServer.reply from, Process.delete :'$state'
    end
  end

  defp execute(:update, fun, from) do
    execute :cast, fun
    GenServer.reply from, :ok
  end

  defp execute(:cast, fun) do
    state = Process.get :'$state'
    Process.put :'$state', Callback.run( fun, [state])
  end

  # transaction
  defp execute(:t, fun) do
    case Callback.run fun, [Process.get :'$state'] do
      :drop_state -> Process.delete :'$state'
      :id -> :ignore
      {:new_state, state} -> Process.put :'$state', state
    end
  end

  #
  # PROCESS MSG
  #

  # get case if cannot create more threads
  defp process({:get, fun, from, expires}) do
    if call? expires do
      t_limit = Process.get :'$threads_limit'
      if t_limit > 1 do
        worker = self()
        Task.start_link fn ->
          execute :get, fun, from
          unless t_limit == :infinity do
            send worker, :done
          end
        end
        dec :'$threads_limit'
      else
        execute :get, fun, from
      end
    end
  end

  # get_and_update, update
  defp process({action, fun, from, exp}) do
    if call?(exp), do: execute( action, fun, from)
  end
  defp process({action, fun}), do: execute action, fun

  defp process(:done), do: inc :'$threads_limit'
  defp process(:done_on_server) do
    inc :'$max_threads'
    process :done
  end


  # main
  def loop( server, key, nil), do: loop server, key, new_state()
  def loop( server, key, {state, late_call, threads_limit}) do
    if state = Callback.parse( state),
      do: Process.put :'$state', state
    if late_call,
      do: Process.put :'$late_call', true

    Process.put :'$key', key
    Process.put :'$max_threads', threads_limit
    Process.put :'$threads_limit', threads_limit # == max_threads
    Process.put :'$gen_server', server
    Process.put :'$wait', @wait+rand(25)
    Process.put :'$selective_receive', true

    # wait, threads_limit, selective_receive are process keys,
    # so they are easy inspectable from outside of the process
    loop() # →
  end

  # →
  def loop( selective_receive \\ true)
  def loop( true) do
    if Process.info( self(), :message_queue_len) > 100 do
      # turn off selective receive
      Process.put :'$selective_receive', false
      loop false
    end

    # selective receive
    receive do
      {:!, msg} ->
        process msg
        loop true
    after 0 ->
      loop :sub
    end
  end

  def loop( s_receive) do
    s_receive = (s_receive == :sub)
    wait = Process.get :'$wait'

    receive do
      {:!, msg} ->
        process msg
        loop s_receive
      msg ->
        process msg
        loop s_receive

      after wait ->
        send Process.get(:'$gen_server'), {self(), :mayidie?}
        receive do
          :continue ->
            Process.put :'$selective_receive', true
            # 1. next time wait a little bit longer (a few ms)
            Process.put :'$wait', wait+rand 5
            # 2. use selective receive (maybe, again)
            loop true

          :die! -> :bye
        end
    end
  end
end
