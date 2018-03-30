defmodule CowBoySupervisor do

  #start workers and supervise
  def start_and_supervise(nodes) do
    Supervisor.start_link(__MODULE__, nodes)
  end

  def start_node(i, node) do
    #{m,b,f} = :code.get_object_code(DateHandler)
    pid = Node.spawn_link(node, fn ->
      IO.puts "to start cowboy"
      case :cowboy.start_clear(:cowboy_date, [{:port, 8080 + i}], %{:env => %{
       :dispatch => :cowboy_router.compile([{:_, [{:_, DateHandler, []}]}])
      }}) do
        {:ok, pid} ->
          :global.register_name("#{node}_cowboy_parent", self())
          Process.flag(:trap_exit, true)
          Process.monitor(pid)
          receive do
            {:EXIT, _f, _r} ->
              IO.puts "to stop cowboy"
              :ok = :cowboy.stop_listener(:cowboy_date)
            {:DOWN, _ref, :process, _p, reason} ->IO.puts "server down, reason: #{reason}"
          end
          {:ok, pid}
        x ->
          IO.puts "from remote: #{inspect x}"
          x
      end
    end)

    case pid do
      nil -> {:error, "can not start remote cowboy server"}
      x -> {:ok, x}
    end
  end

  #init children specification
  def init(nodes) do
    children = nodes
              |> Stream.with_index(1)
              |> Stream.map(fn {n,i}->%{id: "worker#{i}", start: {__MODULE__, :start_node, [i, n]}} end)
              |> Enum.to_list
    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule DateHandler do
  def init(req, state) do
    handle(req, state)
  end

  def handle(request, state) do
    {:ok, :cowboy_req.reply(200, %{"content-type" => "text/plain"}, DateTime.to_string(DateTime.utc_now()), request), state}
  end

  def terminate(_reason, _request, _state) do
    :ok
  end
end