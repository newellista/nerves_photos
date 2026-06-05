defmodule NervesPhotos.GoogleOAuthState do
  @moduledoc false
  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def put(index, state), do: Agent.update(__MODULE__, &Map.put(&1, index, state))
  def get(index), do: Agent.get(__MODULE__, &Map.get(&1, index))
  def delete(index), do: Agent.update(__MODULE__, &Map.delete(&1, index))
end
