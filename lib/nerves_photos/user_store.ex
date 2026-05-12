defmodule NervesPhotos.UserStore do
  @moduledoc false
  use GenServer

  @default_path "/data/nerves_photos/users.json"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def all, do: GenServer.call(__MODULE__, :all)
  def get(username), do: GenServer.call(__MODULE__, {:get, username})
  def put(username, user_map), do: GenServer.call(__MODULE__, {:put, username, user_map})
  def delete(username), do: GenServer.call(__MODULE__, {:delete, username})

  @impl true
  def init(opts) do
    path = opts[:path] || Application.get_env(:nerves_photos, :users_path, @default_path)
    {:ok, %{path: path, users: load(path)}}
  end

  @impl true
  def handle_call(:all, _from, state) do
    {:reply, state.users, state}
  end

  def handle_call({:get, username}, _from, state) do
    {:reply, Enum.find(state.users, fn u -> u.username == username end), state}
  end

  def handle_call({:put, username, user_map}, _from, state) do
    users = Enum.reject(state.users, fn u -> u.username == username end) ++ [user_map]

    case persist(state.path, users) do
      :ok -> {:reply, :ok, %{state | users: users}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete, username}, _from, state) do
    users = Enum.reject(state.users, fn u -> u.username == username end)

    case persist(state.path, users) do
      :ok -> {:reply, :ok, %{state | users: users}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp load(path) do
    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json, keys: :atoms) do
          {:ok, users} when is_list(users) -> users
          _ -> []
        end

      {:error, _} ->
        []
    end
  end

  defp persist(path, users) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, Jason.encode!(users))
    end
  end
end
