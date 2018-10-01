defmodule AgentMapServerStateTest do
  alias AgentMap.Server.State
  import State

  use ExUnit.Case

  test "put" do
    assert put(%{}, :key, {nil, {0, nil}}) == %{}
    assert put(%{}, :key, {box(42), {0, nil}}) == %{key: box(42)}
    assert put(%{}, :key, {box(42), {0, 5}}) == %{key: {box(42), {0, 5}}}
    assert put(%{}, :key, {box(42), {3, nil}}) == %{key: {box(42), 3}}
  end

  test "get" do
    assert get(%{}, :key) == {nil, {0, nil}}
    assert get(%{key: box(42)}, :key) == {box(42), {0, nil}}
    assert get(%{key: {box(42), 3}}, :key) == {box(42), {3, nil}}
    assert get(%{key: {box(42), {0, 6}}}, :key) == {box(42), {0, 6}}
    assert get(%{key: {box(42), {4, 6}}}, :key) == {box(42), {4, 6}}
  end

  test "fetch" do
    state =
      %{}
      |> put(:a, {box(42), {4, 6}})
      |> put(:b, {box(42), {4, 6}})
      |> put(:c, {box(42), {1, 6}})
      |> put(:d, {nil, {2, 5}})

    assert fetch(state, :a) == {:ok, 42}
    assert fetch(state, :b) == {:ok, 42}
    assert fetch(state, :c) == {:ok, 42}
    assert fetch(state, :d) == :error
    assert fetch(state, :e) == :error

    state =
      state
      |> spawn_worker(:c)
      |> spawn_worker(:d)
      |> spawn_worker(:e)

    assert fetch(state, :c) == {:ok, 42}
    assert fetch(state, :d) == :error
    assert fetch(state, :e) == :error
  end

  test "take" do
    state =
      %{}
      |> put(:a, {box(42), {4, 6}})
      |> put(:b, {box(42), {4, 6}})
      |> put(:c, {box(42), {1, 6}})
      |> put(:d, {nil, {2, 5}})
      |> spawn_worker(:c)
      |> spawn_worker(:d)
      |> spawn_worker(:e)

    assert take(state, [:a, :b, :c, :d, :e]) == %{a: 42, b: 42, c: 42}
  end

  test "separate" do
    state =
      %{}
      |> put(:a, {box(42), {4, 6}})
      |> put(:b, {box(42), {4, 6}})
      |> put(:c, {box(42), {1, 6}})
      |> put(:d, {nil, {2, 5}})
      |> spawn_worker(:c)
      |> spawn_worker(:d)
      |> spawn_worker(:e)

    wc = get(state, :c)
    wd = get(state, :d)
    we = get(state, :e)

    assert {%{a: 42, b: 42}, %{c: wc, d: wd, e: we}} == separate(state, [:a, :b, :c, :d, :e])
  end
end
