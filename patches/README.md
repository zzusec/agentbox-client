# Local patches

这些补丁必须在官方源码检出后按文件名顺序应用，不能直接修改官方文件。

当前补丁按文件名顺序应用：

- `0001-agentbox-custom2.patch`
  - 官方基线：`v0.1.6` (`51d52807613f64c448c9e72184d8427ff184f6a4`)
  - 包含合并前已有的全部自定义改动：macOS 客户端、终端、项目同步、配对、
    自动更新，以及相应服务端和前端改动。
- `0002-agentbox-git-bridge.patch`
  - 基线：`0001` 应用后的 `67a60361e220c68c48483c2549f521f1d1ee79c9`
  - 用途：让 HTTPS Git 传输复用 `proxy_bridge` 已开放的端口，避免容器访问
    `172.17.0.1` 随机高位端口时被宿主机防火墙拦截。

应用方式：

```sh
while IFS= read -r patch; do
  git apply --3way "/opt/agentbox/local/patches/$patch"
done < /opt/agentbox/local/patches/series
```

官方代码更新后，保留并重新应用这些补丁。`/usr/local/sbin/agentbox-auto-upgrade`
检测到本地补丁目录非空时，会直接跳过官方自动升级。
