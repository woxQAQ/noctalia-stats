# Noctalia Stats

Noctalia 的资源监控插件，提供 CPU、内存、磁盘、网络详情和 Magpie 用量统计。

Collector 是随插件分发的 Bash 脚本，无需编译。运行依赖为 Bash、jq、iproute2 和提供 `getconf` 的 libc 工具。进程数据直接读取 `/proc`，网卡地址通过 `ip -j address show` 获取。

在项目目录执行以下命令可注册本地插件：

```nu
just register
```

修改后执行 `just reload`。开发环境中执行 `just check`，检查脚本、采集协议以及 service/UI 场景。

高级设置中的 Collector 路径默认为 `bin/noctalia-stats-collector`，相对路径以插件目录为基准。CPU、内存和网络吞吐等基础指标不依赖 Collector；进程详情和本地网卡地址需要它。
