## 监控

分布式系统下常规工作之一就是监控和重启。OTP下定义了[Supervisor Behaviour]和基本的监控功能。我们可以自己基于这个基本功能组装出符合自己业务需要的监控系统。

### Process.monitor/exit

OTP的

### Supervisor：监控其他进程（们）的进程

OTP的Supervisor是基于erlang进程的，因为进程的轻量化设计，所以其实就能很方便的监控一切过程（像之前看到的Task.Supervisor）。Supervisor进程同样可以监控Supervisor进程，所以可以形成监控树，一层层监控和控制重启。

Supervisor监控的是进程状态并能够重启进程，为此定义了一个重启策略和[Child Specification]描述，用来告诉Supervisor进程该怎么启动，何时重启。

**Supervisor控制子进程重启能保持进程状态数据（屌屌）**

重启策略是整个Supervisor统一的：
* strategy键：谁挂谁重启、一个挂全重启、谁挂在他之后启动的全重启
* intensity和period键：period时间内重启超过intensity次则全完蛋

Child Specification是针对每个被监控的进程的：
* start键：创建被监控进程的入口
* restart健：定义进程是一直要重启，还是一直不重启，还是非正常结束才重启。
* shutdown键：强制杀死、请求结束后段时间后强制杀死、永远等他自己结束。[how process know being requested to exit]
* modules键：代码升级用的

Supervisor进程如果被杀(Process.exit/2)，他所有被监视的子进程都会被杀。但是这套东西到分布式环境下会怎样？比如Supervisor进程所在的Node

### 一个利用spawn自己衔接的例子

[cowboy]的启动函数：

```erlang
start_tls(Name          :: ranch:ref(),
          TransportOpts :: ranch_ssl:opts(),
          ProtocolOpts  :: opts())
    -> {ok, ListenerPid :: pid()}
     | {error, any()}
```
> An ok tuple is returned on success. It contains the pid of the top-level supervisor for the listener.

可见cowboy内部自己也是用supervisor树来监控各种过程，然后把树根暴露给了我们。所以我们只要把这颗树根接到更大的树枝上即可。

```elixir
defmodule CowBoySupervisor do

  #start workers and supervise
  def start_and_supervise(nodes) do
    Supervisor.start_link(__MODULE__, nodes)
  end

  def start_node(i, node) do
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
```

`start_and_supervise/1`会启动一个Supervisor，被监视的进程由`init/1`的返回值控制，即通过`start_node/2` spawn_link出一个被监控进程。这个被监视的进程是在远程的，注册了一个全局名字`#{node}_cowboy_parent`，然后又监控(Process.monitor)了cowboy的进程。
如果cowboy进程挂掉，会收到`{:DOWN, }`然后自己也退出，如果被请求退出(Process.exit),会受到`{:EXIT, }`，那就优雅得结束掉cowboy然后退出。

启动一个Supervisor，在两个远程节点上分别启动两个cowboy
```elixir
iex(super@computre-name)>{:ok, sup_pid} = CowBoySupervisor.start_and_supervise([:"foo@computre-name", :"bar@computre-name"])
```

此时如果我杀掉foo上的这个被sup_pid监视的远程进程
```elixir
iex(foo@computre-name)>Process.exit(:global.whereis_name("#{node()}_cowboy_parent"), :normal)
```

则在supervisor的节点上就会检测到并重启子进程。如果我停掉sup_pid,那么他监视的所有子进程也会被停掉

```elixir
to stop cowboy
to start cowboy
iex(super@computer-name)2>Process.exit(sup_pid, :normal)
true
to stop cowboy
to stop cowboy
iex(super@computer-name)2>
```

**问题** 直接杀掉super节点，foo节点的cowboy竟然没有退出！！！我猜那应该是因为我们没有在`#{node()}_cowboy_parent`中监控(Process.monitor/1) Superivor进程。

不过TCP网络本身如果没有心跳，在很多环境下本身就不能检测是否活着，所以我们对于分布式系统的监控，我觉得有必要在代码里自己心跳（假设Supervisor实现没有心跳的话）。

### 为什么不太好

上面的例子中，其实Supervisor并没有形成一棵树，因为`#{node}_cowboy_parent`这个进程，并不是一个Supervisor进程，而是自己通过Process.monitor来做了监控。

[Supervisor Behaviour]: http://erlang.org/doc/design_principles/sup_princ.html
[Child Specification]: http://erlang.org/doc/design_principles/sup_princ.html#id79540
[how process know being requested to exit]: http://erlang.org/doc/man/erlang.html#process_flag-2
[cowboy]: https://github.com/ninenines/cowboy