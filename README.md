# bounded-adversarial-review

一个写手 agent 实现，一个评审 agent 挑错，你只在起点和分歧点出现。

基于 [herdr](https://herdr.dev) 的终端多路复用能力，把只为「人坐在键盘前」设计的交互式 agent 变得可脚本、可观测。

## 它解决什么

写手写完代码，自己请求评审、自己读报告、自己逐条表态，然后继续。你不当中介。

评审不是自由讨论 —— 是一次阻塞调用：注入请求 → 评审方写文件 → 哨兵行标记完成 → 写手继续。没有回程，评审方永不主动发起任何调用。

## 三条核心机制

1. **evidence 门槛** —— 每条 blocking 必须带 `file:line` 或复现命令。无证据的判断落进 `## Suspicions`，永不阻塞。这是唯一的硬裁判。
2. **稳定编号 + 范围冻结** —— 第一轮分配的 finding 编号永不重排，第二轮只做逐条验证（resolved / not-resolved / regressed / disputed），不重新评审。这让轮次上限真正成立。
3. **事件驱动替代连续监控** —— 你从「系统里唯一的错误检测器」变成「等它叫你」。这一条不依赖评审质量。

## 为什么不是双 agent 辩论

2026 年多项研究表明多 agent 辩论会因谄媚性趋同而降低准确率，并快速收敛到系统性带偏的共识；额外轮次无法克服自我纠正的固有局限。本方案刻意采用不对称评审 + 外部证据裁判，而非对称讨论。

## 快速开始

```bash
git clone <this-repo> ~/src/bar
cd ~/src/bar && ./install.sh

cd <你的项目>
herdsman-init <短名>
```

完整步骤见 [docs/QUICKSTART.md](docs/QUICKSTART.md)，原理与全部细节见 [docs/HANDBOOK.md](docs/HANDBOOK.md)。

## 依赖

- [herdr](https://herdr.dev) ≥ 0.8.2
- `jq`
- `git` ≥ 2.5（worktree）
- bash ≥ 4
- 两个 CLI agent：一个当写手（Codex 系），一个当评审方（Claude Code 系）

## 目录

```
bin/
  request-review      写手调用的主脚本；注入、等待、哨兵判定、归档、度量
  review-archive      手动归档工具（自动归档已内建在 request-review）
  herdsman-init       项目初始化
config/
  rubric.md           评审契约，全局共用，安装到 ~/.config/review/
templates/
  agents-section.md   常驻指令，追加到项目的 AGENTS.md / CLAUDE.md
  brief-prompt.md     生成项目简报的提示词
  request.md          请求文件示例
  pre-push.sample     可选的确定性触发 hook
docs/
  QUICKSTART.md       纯步骤
  HANDBOOK.md         完整手册
install.sh
```

## 一次评审周期

```
你 → 写手：做 X
写手改代码 → 判断要不要评审 → 按种类切 commit（代码 / 计划 / 状态记录）
  状态记录直接提交；代码或计划各写一份 request.md（含 kind）→ request-review
  脚本：校验 kind、base sha → 找/建评审方 → worktree reset 到 target sha → 注入 → 等哨兵
  评审方：读 rubric → brief → request → 按 kind 只执行一套契约 → 写 findings → 停
  脚本：exit 0，打印路径，记 timing / precision
写手：读 findings → 写 responses（先写后改）→ 改代码
  accept 且改了 artifact → round 2，回到上面
  全部 defer（仅 should/nit）→ 结束
  有 reject / defer 了 blocking → exit 5，交给你裁决
```

## herdr 耦合面

herdr 只出现在 `bin/request-review` 的 `transport_*` 函数里（脚本中有注释框标出）。其余全部逻辑只依赖 git 和文件系统。想换 tmux 或走非交互路线，只改这些函数。

## 已知局限

- **触发依赖写手自觉** —— 「要不要评审」是唯一跳过了也不报错的环节。`templates/pre-push.sample` 提供确定性补丁。
- **无全仓库语义索引** —— 用手写的项目简报替代，需要人维护、会过期。
- **评审通常比实现慢也更贵** —— 因为证据要求让评审方在跑代码而非读代码。压缩杠杆是写好简报和填 `test paths`，不是放松证据要求。
- **评审对遗漏基本无能** —— 「该做但没做」在 diff 里不可见。

## 度量

`docs/reviews/` 下四个文件。`timing.md` 和 `skipped.md` 全自动，`precision.md` 脚本填前三项、你填「误报 ?」，`escapes.md` 全靠你。

行业参照：2026 年独立评测中最好的商用 AI 评审工具精度约 49%，即大约每两条评论有一条真的导致改动。

## 止损点

三个月，或十个真实周期。到点问自己两个问题：误报率是多少？我还愿意读这些报告吗？

如果在维护流程而不是在用它，就退回最简形态 —— 手动粘一句话给评审方，保留上面那三条核心机制。它们都不依赖任何工具。

理由见 HANDBOOK 第 12 部分。
