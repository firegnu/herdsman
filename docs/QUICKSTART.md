# 快速开始

## A. 全局（只做一次，所有项目共用）

```bash
git clone <本仓库> ~/src/bar
cd ~/src/bar && ./install.sh
```

安装 `request-review`、`review-archive`、`herdsman-init` 到 `~/.local/bin`，
`rubric.md` 到 `~/.config/review/`，并检查依赖（jq / herdr / git / PATH）。

验证：

```bash
request-review
```

必须报 `ERROR: 不在 git 仓库中`。报 `command not found` 则把 `~/.local/bin` 加进 `~/.zshrc` 的 PATH。

---

## B. 每个项目

### B1 — 自动部分

```bash
cd <repo>
herdsman-init <短名>
```

它会建评审 worktree、写 `.review.conf`、加 `.gitignore`、建两个度量文件和交接目录，
然后告诉你还剩哪两件手动的事。幂等，重复跑不会覆盖已有内容。

### B2 — 常驻指令（手动）

```bash
cat ~/src/bar/templates/agents-section.md >> AGENTS.md
```

（Claude Code 系则追加到 `CLAUDE.md`。）

**然后改里面的 `<核心路径清单>` 为本项目真实路径。**

### B3 — 项目简报（手动）

用 `templates/brief-prompt.md` 里的提示词让写手生成 `docs/reviewer-brief.md`，
生成后你亲自过一遍「不变量」那节，然后提交。

不写的话评审方每轮从零爬全仓库，成本可能超过实施本身。

### B4 — 验证

拿一个你**已经审过**的真实提交跑通一次：

```bash
cd <repo>
. .review.conf
cat > "$REVIEW_DIR/request.md" <<EOF
artifact:      $(git rev-parse --short HEAD) 这个提交的改动
base sha:      $(git rev-parse HEAD~1)
target sha:    $(git rev-parse HEAD)
round:         1/3
out of scope:  无
risk areas:    无
test paths:
checks:
EOF

request-review; echo "exit=$?"
```

第一次会慢（脚本自动建 pane、起 Claude Code）。

期望：打印 findings 路径、`exit=0`，且这两个文件各有一行新记录：

```bash
tail -1 docs/reviews/timing.md
tail -1 docs/reviews/precision.md
```

**然后对照**：你自己审的结论 vs 它的报告。它漏了什么、有没有编造无证据的 blocking。
这次对照比任何配置都值钱 —— 它是你的第一个漏检率数据点。

清理：

```bash
rm -f "$REVIEW_DIR"/r1-* "$REVIEW_DIR"/.r1.sent "$REVIEW_DIR"/request.md
```

完成。之后由写手自己调用 `request-review`，你不用再敲命令。

### B5 — 可选：pre-push hook

把「要不要评审」从写手的自觉判断变成确定性检查：

```bash
cp ~/src/bar/templates/pre-push.sample .git/hooks/pre-push
chmod +x .git/hooks/pre-push
# 改里面的 CORE_PATHS
```

---

## C. 日常只需你做的两件事

1. 每轮读完 findings，把 `docs/reviews/precision.md` 那行的 `误报 ?` 改成数字。
2. 写手报告退出码 2/4/5 时，看它原样输出，做裁决。

---

## D. 完整说明

见 `docs/HANDBOOK.md` —— 流程全貌、所有模板原文、轮次控制、度量、失效模式、
出错速查、herdr 实测记录、止损点。
