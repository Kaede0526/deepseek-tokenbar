# TokenBar 原理与使用

面向使用者的说明：它怎么跑的、为什么有个 python3 在后台、出问题看哪里。
想改代码或了解构建细节看 [../README.md](../README.md)。

## 一句话

两半：一个**定时跑的 Python 脚本**去拿数据，一个**菜单栏 App** 负责显示。
两者不直接通信，只通过一个 JSON 文件见面。

```
DeepSeek 余额接口 ──┐
                    ├──►  collect.py  ──►  usage.json  ──►  TokenBar.app  ──►  菜单栏
DSH 会话日志 ───────┘      (每 60 秒)       (一个文件)       (每 5 秒读一次)
```

这样拆的好处：App 不联网、不碰你的 API Key；脚本崩了 App 也不会崩；
任何一半都能单独换掉（想换界面就只换 App，想换算法就只换脚本）。

## 三块东西

| 谁 | 多久跑一次 | 干什么 |
|---|---|---|
| `src/collect.py` | 每 60 秒（自动） | 拿余额 + 算 token → 写 `.data/usage.json` |
| `TokenBar.app` | 常驻 | 每 5 秒读一次 `usage.json`，画菜单栏和面板 |
| `src/verify.py` | 手动 | 独立重算，检查 `collect.py` 有没有算错 |

采集 60 秒一次、界面 5 秒读一次，是故意不同的：**采集要联网，慢一点省事；
读本地文件几乎不花钱，快一点看起来才像实时。**

## 为什么登录项里有个 python3？

这是最容易被误会的地方，先说结论：**你看到的 python3 就是上面那个定时采集任务，
不是恶意软件，也不是「Python 在后台偷偷跑」。真正的菜单栏 App 不在登录项里。**

原因是 macOS 上「让某个脚本定时自动跑」的标准做法叫 **LaunchAgent**：
在 `~/Library/LaunchAgents/` 放一个 plist 文件，告诉系统「这个程序每 N 秒跑一次」。
安装脚本生成的内容是：

```xml
<key>ProgramArguments</key>
<array>
    <string>/opt/homebrew/bin/python3</string>   <!-- ← 就是它 -->
    <string>…/src/collect.py</string>
</array>
<key>StartInterval</key><integer>60</integer>
```

系统设置里的显示名取自**可执行文件本身**，也就是 `python3`。用 `sfltool dumpbtm` 能看到：

```
Name:             python3
Identifier:       8.com.lanzhusu.tokenbar.collect
URL:              file:///Users/<你>/Library/LaunchAgents/com.lanzhusu.tokenbar.collect.plist
Executable Path:  /opt/homebrew/bin/python3
```

它的实际行为：每 60 秒醒来约 **0.3 秒**，读完写完后立刻退出，不留常驻进程。
`launchctl print` 里的 `state = not running` 是正常的（它本来就不是常驻的），
`runs` 那个数字会随时间一直涨——就是它累计跑过的次数。

### 想让那个 python3 消失

| 做法 | 操作 |
|---|---|
| 只是不想让它开机自启 | 系统设置 → 通用 → 登录项与扩展 → 「允许在后台」里关掉 |
| 彻底删掉 | `scripts/uninstall.sh` |
| 什么都不做 | 也行。它没有图标、没有窗口，只在那个列表里露个名字 |

## 数据从哪来

| 数据 | 来源 | 说明 |
|---|---|---|
| 余额 | `https://api.deepseek.com/user/balance` | Key 每次运行时现读 `~/.dsh/.credentials.yaml`，不写进代码 |
| token 用量 | `~/.dsh/sessions/` 里的会话日志 | 只统计本机的 DSH 会话 |
| 今日已花 | 余额差值（记在 `.data/history.json`） | **不用价格表**，所以永远准确 |

「余额差值」的意思是：每次采集顺手记一下当前余额，下次再记一下，两次的差就是这段时间花的钱。
好处是不用维护模型价格表，也不会因为调价而算错。

## 常用命令

```bash
scripts/install.sh              # 安装（编译 + 装 App + 注册定时采集 + 启动）
scripts/uninstall.sh            # 全部撤掉
python3 src/collect.py --print  # 手动采一次并打印摘要（不开界面）
python3 src/verify.py           # 检查 collect.py 算得对不对
```

改刷新频率：改 `scripts/install.sh` 顶部的 `INTERVAL`，然后重跑。
不想等定时：点面板上的「立即刷新」。

## 日常怎么用

装好之后**不需要「打开」它**，菜单栏上一直在。

- **看数字**：抬头看菜单栏
- **看详情**：点一下图标 → 弹出面板 → 点面板外任意地方收起
- **退出**：面板右下角「退出」。注意它是辅助类 App，**Cmd+Q 无效**（没有主菜单）

**重启电脑后**：后台采集会自动恢复（plist 里有 `RunAtLoad`），
但菜单栏图标要手动开一次：`open ~/Applications/TokenBar.app`。
双击后「看起来没反应」是正常的，它没有 Dock 图标也没有窗口。

## 已知的两个坑（代码里已经处理）

1. **同一会话有两份日志**（新旧格式），全读会让用量**正好翻倍** → 只读 v4。
2. **旧版日志把每次调用记两遍**（流式一条、最终一条，`totalTokens` 相同但时间差几毫秒）
   → 按 `(turn, step)` 去重，优先保留最终那条。**拿时间当去重键会失效。**

## 出问题先看这里

| 现象 | 怎么看 |
|---|---|
| 菜单栏图标不见了 | `TOKENBAR_DEBUG=1` 跑一次 App，会打印状态项位置和标题 |
| 数字不更新 | `tail .data/collect.log` 看采集有没有报错 |
| 余额显示「—」 | 正常降级。`usage.json` 里的 `error` 会写原因（Key 失效 / 断网） |
| 想确认算得对 | `python3 src/verify.py`，退出码 0 才算通过 |
| 编译报 `redefinition of module` | Command Line Tools 的已知 bug，见 [README](../README.md) 与 `scripts/build.sh` 的提示 |

采集脚本的设计约定：**余额拿不到也会照常写文件**，用量数字还在，
只是 `balance` 变 `null` 并把原因写进 `error`——所以界面不会空白，只会显示得旧一点。

## 现在还没有的功能

只做了基础五项，保持简单：系统通知、7 天柱状图、模型分布、多账户、云端同步。
数据其实已经备好了（`usage.json` 里的 `week` 字段），想做随时能加。
