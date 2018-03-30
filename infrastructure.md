## 分布式的基础设施

### 名字服务
#### 命名空间类型
* 主机名——对应一个主机。一个主机（应该）不能用多个主机名。
* VM/Node名——主机上可以启动多个VM
* VM内本地名字——`local`命名空间下，只在当前VM内可访问，通过`Process.register`注册
* 全局名——`global`命名空间下的名字，所有VM可见
* 自定义命名空间——自己定一个Module实现如何注册名字、查找名字、发送消息(send)

所以只要你愿意（注册），OTP里你可以找到所有节点的所有进程，然后向他们发消息

Elixir好像没有开放同一个Host下多个Node之间的名字访问：[Name Registration]，但OTP本身标准支持: [gen_server ServerRef]。

#### 名字服务程序 [epmd]
这是一个独立运行的程序，随着本机第一个Node启动而启动，也可以单独启动。任何本机Node启动后都会向本机的epmd注册自己的名字，同时empd会对外监听4369[默认值]端口，允许远程Node查询本机的Node。

**epmd 允许可以按照[epmd protocol]自己实现**。

### 序列化

erlang没有自定义类型，所有数据类型就那么几个，可以通过`term_to_binary`和`binary_to_term`，然后加上一些压缩和传输头。[erl_ext_dist文档传送门]

nif resource(C写的带状态的erlang term)应该是不能序列化的，所以不能把C暴露给erlang的term发出去用，但是发出去再收回来如果C里面对应的资源都还在的话，还是能接着用的。

### 链接安全

启动Node是可以指定Cookie，Cookie并不明文在Node之间传输，而是经过在一个[握手过程]中使用。握手成功以后，加密好像是没有的，所以如果要往外网去的话可能要用加密过的tcp隧道。

所以如果本地有一个`node1@host1`，`node2@host2`要用名字`node1@host1`请求节点的时候，应该是先找到host1:4369询问epmd，然后epmd告诉`node2@host2` `node1@host1`的ip和端口，然后node1和node2就可以基于cookie握手链接了。

### 远程调用协议

协议中定义了LINK（链接错误传递）、SEND（发送消息到PID）、MONITOR（监控Process）、EXIT（请求退出process）这些erlang OTP核心的功能。类似于像gen_server这些模式，都是基于消息收发实现的。[Node间RPC协议传送门]

### **很牛逼的：你可以自己实现一套不用tcp/ip的OTP分布式传输层**
http://erlang.org/doc/apps/erts/alt_dist.html 比如你的RPC数据都是TB级别的，那可能写一套机械臂控制插拔ssd的OTP传输层比你用千兆以太网快😁


[Name Registration]: https://hexdocs.pm/elixir/GenServer.html#module-name-registration
[gen_server ServerRef]: http://erlang.org/doc/man/gen_server.html#call-3
[epmd]: http://erlang.org/doc/man/epmd.html
[epmd protocol]: http://erlang.org/doc/apps/erts/erl_dist_protocol.html
[erl_ext_dist文档传送门]: http://erlang.org/doc/apps/erts/erl_ext_dist.html
[握手过程]: http://erlang.org/doc/apps/erts/erl_dist_protocol.html#id105392
[Node间RPC协议传送门]: http://erlang.org/doc/apps/erts/erl_dist_protocol.html#id106278