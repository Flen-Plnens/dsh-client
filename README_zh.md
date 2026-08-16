# DSH Client

[中文](README_zh.md) | [English](README.md)

> 一个用于 DeepSeek Harness 的 Flutter 客户端。

DSH Client 是一个原生 Flutter 桌面客户端，直接通过其线路协议（HTTP RPC + WebSocket 事件流）与 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 服务器通信——无需嵌入式浏览器，也无需 WebView 外壳。将其指向您的 Harness 服务地址（例如 `http://127.0.0.1:3080`）即可连接。

## 截图

![截图 1](https://i.ibb.co/TDCfJWgn/2026-08-16-230618.png)

![截图 2](https://i.ibb.co/1GtGjzFS/2026-08-16-230641.png)

![截图 3](https://i.ibb.co/x86K8ssX/2026-08-16-230652.png)

## 功能特性

当前版本已实现并验证的功能：

- **Harness 会话连接** — 服务地址、`host.describe` 握手、双 WebSocket 下行链路、连接状态及自动重连
- **会话浏览与搜索** — 工作区/会话列表、实时标题、内容+名称搜索
- **模型选择** — 模型目录选择器，支持**推理强度**（关闭 / 高 / 最大）
- **消息发送** — 常规 `queue` 提示和 `steer`（长按发送），待发队列管理（移除 / 编辑 / 转向）
- **提问/审批** — 回答模型问题，允许一次或拒绝审批
- **命令** — 斜杠命令（`/...`），带命令选择器和内联执行状态
- **目标** — 设置 / 编辑 / 暂停 / 恢复 / 完成 / 清除长期运行的目标
- **子代理会话** — 子会话面板，打开和中断
- **Markdown 与代码块** — 渲染消息，支持语法高亮
- **图片输入路径** — 从磁盘选择图片并附加到消息中（需要具备视觉能力的模型）
- **工作区与会话管理** — 创建 / 重命名 / 删除 / 重新排序工作区，归档 / 复刻 / 重命名 / 导出（ZIP）会话

## 系统要求

- **Windows x64**（可移植 Release 构建）
- 正在运行的 **DeepSeek Harness** 服务器（已针对 `0.1.0-rc.6` 验证）；默认服务地址 `http://127.0.0.1:3080`
- **Flutter SDK** — 仅从源代码构建时需要（开发者）

## 下载

**Windows x64 可移植发布版** — 从 [GitHub Releases](https://github.com/Flen-Plnens/dsh-client/releases) 页面下载 ZIP 压缩包，解压到任意位置，然后运行 `dsh_client.exe`。ZIP 包含完整的 Release 目录（可执行文件、运行时 DLL 以及 `data/` 文件夹），因此可以独立运行——无需安装。

## 从源代码构建

```sh
flutter pub get
flutter build windows --release
```

Release 捆绑包生成在 `build/windows/x64/runner/Release/` 目录下。

## 已知限制

- 需要可访问的 DeepSeek Harness 服务器。LAN/远程连接需要服务器以 `--trusted-host` 启动；rc.6 协议没有身份验证层（信任边界是可访问性策略，而非身份）。
- 当所选模型没有原生图像输入时，服务器会拒绝图片附件——客户端会提示切换到具备视觉能力的模型。
- 已归档的会话无法取消归档（rc.6 未暴露 `unarchive` RPC）。
- 流式输出以纯文本渲染；Markdown 仅在最终消息上渲染。
- 协议没有版本号，且 DeepSeek Harness 仍处于开发者预览阶段——本客户端已针对 `0.1.0-rc.6` 验证。

## 许可证

DSH Client 采用 MIT 许可证。有关完整许可证文本，请参见 [LICENSE](LICENSE) 文件。
