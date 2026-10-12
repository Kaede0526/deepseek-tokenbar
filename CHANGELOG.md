# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.0] - 2026-10-12

首个版本。

### 新增

- `src/collect.py` — 采集 DeepSeek 余额与 DSH 本地 token 用量，输出 `usage.json`
- `src/verify.py` — 独立实现重算并与 `usage.json` 对拍，退出码可用于 CI
- `src/TokenBar.swift` — 菜单栏 App（AppKit + SwiftUI），余额低额变色、毛玻璃面板、无 Dock 图标
- `scripts/build.sh` — 只用 Command Line Tools 编译成 `.app`，含工具链预检
- `scripts/install.sh` / `scripts/uninstall.sh` — 一键装卸 + LaunchAgent 定时采集
- `scripts/make-icon.sh` — 任意图片转 App 图标，非正方形自动裁切
- `docs/HOW-IT-WORKS.md` — 运行原理、常见疑问、排错

### 修复

- **同一会话重复计数**：`session.v4.jsonl.zstd` 与旧版 `session.jsonl.zstd` 同时存在时
  会读到两份日志，用量正好翻倍。现在优先只读 v4。
- **旧版日志去重键选错**：旧版把同一次调用记两遍（`assistant/chunk` 时间 T、
  `assistant/message` 时间 T+4ms），`totalTokens` 相同但时间不同。原先用
  `(turn, step, total, time)` 当去重键会失效，现改为按 `(turn, step)` 去重并优先保留
  `assistant/message`。
- **对拍会误报**：`verify.py` 原先拿当前仍在写入的会话一起比对，必然对不上。
  现在排除活跃会话，只比对已封存的日志。

### 已知限制

- `reasoningTokens` 只在旧版日志中存在，v4 日志不再记录该字段
- 本地日志只覆盖本机的 DSH 会话，其他途径直接调用 API 的消耗只能从余额变化看出
- `spend.today` 依赖余额差值，首次运行需要积累数个采样点后才有值
