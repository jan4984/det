## 监控

分布式系统下常规工作之一就是监控和重启。OTP下定义了[Supervisor Behaviour]和基本的监控功能。我们可以自己基于这个基本功能组装出符合自己业务需要的监控系统。

### Process.monitor/exit

如果进程自己允许，可以由`Process.exit(pid, :kill)`强制退出，这点比较奇怪，现在主流设计都是不允许杀线程的，因为你我们不清楚杀掉的时候数据处于什么状态，不过有这个机制也不一定要用。

进程内执行`Process.flag(:trap_exit, true)`后，可以将外部的退出请求转化为发给自己的`{:EXIT, }`消息。`Process.monitor`可以监控其他进程的退出，转化为`{:DOWN, }`消息。

所以基于Monitor和trap_exit，我们可以自己基于消息收发实现进程监控。

### Supervisor：监控其他进程（们）的进程

OTP的Supervisor是基于erlang进程的，因为进程的轻量化设计，所以其实就能很方便的监控一切过程（像之前看到的Task.Supervisor）。Supervisor进程同样可以监控Supervisor进程，所以可以形成监控树，一层层监控和控制重启。

当然应该是基于上面提到Process.monior那套设计，所以进程应该是不能block消息接受的(receive)，也不能不处理`{:EXIT,}`，否则没法正常根据Supervisor模式退出。

Supervisor监控的是进程状态并能够重启进程，为此定义了一个重启策略和[Child Specification]描述，用来告诉Supervisor进程该怎么启动，何时重启。

**Supervisor控制子进程重启能保持进程状态数据（屌屌）,前提当然是被监控进程要follow Supervisor的设计模式**

重启策略是整个Supervisor统一的：
* strategy键：谁挂谁重启、一个挂全重启、谁挂在他之后启动的全重启
* intensity和period键：period时间内重启超过intensity次则全完蛋

Child Specification是针对每个被监控的进程的：
* start键：创建被监控进程的入口
* restart健：定义进程是一直要重启，还是一直不重启，还是非正常结束才重启。
* shutdown键：强制杀死、请求结束后段时间后强制杀死、永远等他自己结束。[how process know being requested to exit]
* modules键：代码升级用的

**限制** Supervisor是不能先有进程再监控的，被监控的进程只能由Supervisor启动（因为Supervisor的模式是要完全掌控子进程嘛）。
**问题** Supervisor进程如果被杀(Process.exit/2)，他所有被监视的子进程都会被杀。但是这套东西到分布式环境下会怎样，比如Supervisor到子进程的TCP链接断了？

### 一个主动spawn_link并接入Supervisor树的例子

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
如果cowboy进程挂掉，会收到`{:DOWN, }`然后自己也退出，如果被请求退出(Process.exit),会收到`{:EXIT, }`，那就优雅得结束掉cowboy然后退出。

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

**问题** 直接杀掉super节点，foo节点的cowboy竟然没有退出！！！

我猜那应该是因为我们没有在`#{node()}_cowboy_parent`中监控(Process.monitor/1) Superivor进程。所以如果我们`Process.exit(sup_id)`,节点有足够的时间可以给被监控的进程发送`:Exit`,但是如果是直接杀死VM，那就没有这个过程了。但是`Process.monitor`却可以很快检测到远程的Node消失了，这是为啥？

没有搜到太多直接的信息，结合基础网络知识来看，这个[关于远程节点失效检测的回答]比较靠谱。就是你按ctrl+c，os其实会给这个进程(操作系统进程）的tcp链接全部发送RST给远端。那远端当然就知道这个节点挂了，对应的就是这个节点上的所有进程(erlang进程）全挂了。所以如果拔网线，其实`Process.monitor`也是一时半会儿检测不到的（还没实际试过）。

所以拔网线的话会等到Node的[心跳]，而如果业务上对时间比较敏感又不想改全局的远程节点检测心跳间隔，应用层自己做心跳也是很简单的，就是两个send/receive ping/pong嘛。

**问题** 如果不要自己spawn_link怎么种（Supervisor）树

你可以先有一个Supervisor进程,然后用`Supervisor.start_child`启动一个进程并加入到现有的Supervisor进程。上面cowboy的例子就可以改成

```elixir
 {:ok, sup_id} = Supervisor.start_link(CowBoySupervisor, []) #没有任何Child
 Supervisor.start_child(sup_id, %{id: "worker1", start: {CowBoySupervisor, :start_node, [1, :"foo@computer-name"]}})
```

但是这样远程就没了，都在本地呢，呵呵。如果要保留这种模式启动分布式，只能把Supervisor进程启动在远程（或者远程启动好注册好，又或者启动了以后通过什么方式把pid发给你），然后一样继续用拿到的远程sup_id调用`Supervisor.start_child`。

[Supervisor Behaviour]: http://erlang.org/doc/design_principles/sup_princ.html
[Child Specification]: http://erlang.org/doc/design_principles/sup_princ.html#id79540
[how process know being requested to exit]: http://erlang.org/doc/man/erlang.html#process_flag-2
[cowboy]: https://github.com/ninenines/cowboy
[心跳]: http://erlang.org/doc/man/net_kernel.html#set_net_ticktime-1
[关于远程节点失效检测的回答]: https://stackoverflow.com/questions/24061270/how-is-the-detection-of-terminated-nodes-in-erlang-working-how-is-net-ticktime