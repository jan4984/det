## 部署

几个基础特性：
* OTP字节码就是一个binary，而且可以随便到处发，收到的人就能加载起来跑。
* VM自带编译器和执行器，所以你可以编译执行，也可以解释执行
* 运行时可以替换字节码

所以可以想象，配合Supervisor树，技术层面模块级别的自动化部署完全是很好做的：CI上找到需要的字节码，确定要丢到哪些节点去，丢过去控制节点加载，完事。这中间可能要结合一些状态判断加载新版本的时机，如果我们所有进程都在Supervisor树里，其实一般就通过Supervisor状态就能知道时机了。

### 官方部署标准：Application

虽然上面提到我们可以针对Module单独部署，但一般不会这么玩。因为一个模块总是依赖很多其他模块或者被其他模块依赖，如果你传递一个模块的字节码出去，而不把他的依赖也一起传出去加载，那其实远程节点是没法加载这个新的模块的。

OTP里面用[application]来组织一个完整的发布包。app带版本号，然后定义了一组属于这个app的model，还定义了依赖哪些其他app。app并不一定是一个逻辑入口（当然也可以定一个入口），也可以是一个库，总之就是为了发布模块组织的一个描述。

如果你要用OTP自带的升级，那就要按照OTP定义的规范[发布app包]。OTP提供了[systools]执行打包和升级，包括提供一些升级指令让你自己可以配置不同版本之间转化是应该增删改哪些模块。

**牛逼的来了** gen_server可以自己不结束进程状态下升级自己：版本变化时`code_change`会被调用到，用于把当前的`state`转成对应版本的`state`。

### 其他部署工具

之前也提到其实因为OTP的那几个基础特性很方便自己写动态部署，所以有一些比较好用的打包和（分布式）部署工具。

https://github.com/bitwalker/distillery

https://github.com/edeliver/edeliver

https://github.com/Tubitv/ex_loader

[application]: http://erlang.org/doc/man/app.html
[发布app包]: http://erlang.org/doc/design_principles/release_structure.html#id84116
[systools]: http://erlang.org/doc/man/systools.html