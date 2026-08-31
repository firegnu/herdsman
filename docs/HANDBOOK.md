# 有界对抗评审 · 完整手册

版本 v4，2026-08-28。已在 macOS / zsh / bash 5.3 / herdr 0.8.2 上完整跑通两个真实周期。

本手册自足：搭建、运行、排错、所有模板全在这一份里，不需要参考其他文档。

---

## 目录

- 第 1 部分：这是什么，以及三条你必须知道的前提
- 第 2 部分：完整流程
- 第 3 部分：搭建（四步）
- 第 4 部分：四份文件的分工
- 第 5 部分：所有模板原文
- 第 6 部分：生成项目简报的提示词
- 第 7 部分：轮次控制
- 第 8 部分：度量
- 第 9 部分：失效模式与警戒线
- 第 10 部分：出错速查
- 第 11 部分：herdr 事实核对与实测记录
- 第 12 部分：止损点

---

## 第 1 部分：这是什么

一个写手 agent 实现，一个评审 agent 挑错，你只在起点和分歧点出现。

### 1.1 角色

| 角色 | 承担者 | 权限 |
|---|---|---|
| 实施方（写手） | Codex 系 | 主工作副本的唯一写入方；跳过确认模式；调用 `request-review` |
| 评审方 | Claude Code 系 | 独立 worktree，可编译可测试可检索，不写主工作副本；**保留确认模式**；**不装 herdr skill** |
| 人 | 你 | 唯一的方向决策者与分歧裁决者 |

### 1.2 五条不变量

违反任何一条，收益假设即失效。

1. **主工作副本只有一个写入方。** 评审方在独立 worktree，findings 写到 repo 外的交接目录。
2. **回程不存在。** 评审方永不主动发起任何调用。`request-review` 是阻塞命令，写手一直在栈上等着，评审方写完文件即停。评审方的无能力是保障不是缺陷。
3. **完成判定以文件哨兵为准。** 不以生命周期状态为准 —— `unknown` 连空 shell 都会出现。
4. **finding 编号第一轮分配后永不重排。** 这是轮次控制的支点：第二轮从"重新评审"变成"逐条验证"。
5. **范围第一轮之后冻结。** 第二轮只处理原有 findings 与修复引入的回归。

### 1.3 三条你必须知道的前提

**评审通常比实现慢，也更贵。** 因为 rubric 要求每条 blocking 带复现命令，评审方不是在读代码而是在跑代码。「写代码 token 密集、评审 token 稀疏」这个模型在冷评审下不成立。这不是缺陷 —— 证据要求正是这套流程唯一的硬裁判，去掉它评审就退化成意见交换。压缩成本的正确杠杆是写好项目简报和收窄测试范围，不是放松证据要求。

**评审对遗漏基本无能。** 它看到的是 diff 与简报里存在的东西，「该做但没做」「需求理解错了」在 diff 里不可见。评审再干净也不能替代你对着原始意图确认一次。

**这套流程没有可靠的自我评估机制。** `precision.md` 半自动化之后勉强算一个，`escapes.md` 大概率会荒废。判断它值不值，最后还是会落回你的主观感受 —— 而主观感受在这件事上系统性地不可靠。唯一的对策见第 12 部分。

---

## 第 2 部分：完整流程

```
① 你 → 写手：「做 X」

② 写手干活，改代码

③ 写手判断：这次要不要评审？
   查 AGENTS.md 的清单：碰核心路径 / 改接口 / 跨 3 文件 / 计划文档 → 要
   不要 → git commit，结束

④ 写手：git commit
        写 ~/.review/<项目>/request.md（artifact、base sha、target sha、round: 1/3）
        跑 request-review

⑤ 脚本：检查工作区干净 → 读 round → 归档上一周期并清空交接目录
        按 cwd 找评审方（没有就建 pane 起一个）
        把 review worktree reset --hard 到 target sha
        注入 prompt（rubric 路径、request 路径、round、target sha）
        --wait 返回后校验哨兵，未满足则每 10 秒轮询

⑥ 评审方：读 rubric → brief → request → 代码
          写 r<n>-findings.md，末行 REVIEW-COMPLETE，停

⑦ 脚本：认到哨兵 → 打印路径 → exit 0
        顺手写 timing.md 和 precision.md

⑧ 写手：读 findings
        对每条写一行 accept/reject + 理由 → r<n>-responses.md
        必须先写完再动代码 —— 这是判断闸门

⑨ 分叉：
   没有 blocking          → 结束
   有 blocking，全 accept → 改代码 → 回到 ④，round 改成 2/3
   有任何 reject          → 下一轮开头脚本 exit 5，写手停下报告给你 → ⑩

⑩ 你裁决那条争议 → 告诉写手继续或收工
```

**你只出现在 ①、⑩，以及轮次到顶时。** 其余全自动。

第二轮跟第一轮的区别只在 ⑤：注入的 prompt 多三行（上一轮 findings/responses 路径、上一轮 target sha），评审方按 rubric 逐条报 resolved / not-resolved / regressed / disputed，不重新评审。

---

## 第 3 部分：搭建

约 30 分钟。**搭建阶段不启动任何 agent** —— 只产出静态的东西。评审方由 `request-review` 在第一次需要时自动拉起。

开始前确认：`jq` 和 `herdr` 在 PATH 里、要配的项目是 git 仓库。

下面用 `<repo>` 指项目根目录，`<短名>` 指项目短标识（自己取，全程一致，例如 `inksample`）。

### 步骤 1 — 全局安装（只做一次，所有项目共用）

```bash
cd <herdsman 仓库>
./install.sh
```

它把 `request-review`、`review-archive`、`herdsman-init` 安装到 `~/.local/bin`，把 `rubric.md` 安装到 `~/.config/review/`。

验证：在家目录跑 `request-review`，应报 `ERROR: 不在 git 仓库中`。若报 `command not found`，把 `~/.local/bin` 加进 `.zshrc` 的 PATH。

验证：`tail -5 ~/.config/review/rubric.md` 应看到 `## Checkability` 那几行。

### 步骤 2 — 项目初始化

```bash
cd <repo>
herdsman-init <短名>
```

它自动创建评审 worktree，写 `.review.conf` 和 `.gitignore` 条目，建立 `docs/reviews/`、两个度量文件与交接目录。命令幂等，已存在的内容不会被覆盖。

`.review.conf` 有四个变量：`REVIEW_KIND` 是评审 agent 类型，`REVIEW_WT` 是评审 worktree，`REVIEW_DIR` 是交接目录，`REVIEW_WAIT` 是等待秒数；其中路径值必须是绝对路径。

没有 `REVIEWER` 这一项。脚本按 `REVIEW_WT` 的 cwd 找评审方，不依赖 agent 名字，因为名字需要人维护、进程一退就没，cwd 是进程自带属性。

评审 worktree 建一次就一直在，跟评审 agent 的死活无关；每轮脚本把它 `reset --hard` 到本次要审的 sha，目录内容变、目录本身不动。

可选：`chmod 444 .review.conf`。挡不住恶意，但挡得住写手顺手改。

### 步骤 3 — 两件必须手工做的事

1. 把第 5.4 节的 `agents-section.md` 追加到 `<repo>/AGENTS.md`（Codex 系）或 `CLAUDE.md`（Claude Code），然后把 `<核心路径清单>` 换成本项目真实路径。
2. 用第 6 部分的提示词让写手生成 `docs/reviewer-brief.md`，生成后你亲自过一遍「不变量」那节。

**这一步不要跳过。** 简报是空的话，评审方每轮从零爬全仓库，成本可能超过实施本身。

### 步骤 4 — 第一个真实周期

不要空跑假 request（`artifact: PIPELINE-TEST` 这种评审方会拒绝，因为它核验不到，那是正确行为）。直接拿一个**你自己已经审过**的真实提交跑：

```bash
cd <repo>
. .review.conf
mkdir -p "$REVIEW_DIR"
cat > "$REVIEW_DIR/request.md" <<EOF
artifact:      $(git rev-parse --short HEAD) 这个提交的改动
base sha:      $(git rev-parse HEAD~1)
target sha:    $(git rev-parse HEAD)
round:         1/3
out of scope:  无
risk areas:    无
EOF

request-review; echo "exit=$?"
```

第一次会慢 —— 脚本发现 worktree 里没有 agent，会新建 pane、启动 Claude Code、等它就绪再注入。stderr 会打 `NOTE: ... 正在拉起 claude …`。

期望：打印 findings 路径、exit 0、`timing.md` 和 `precision.md` 各有新记录。

**然后对照**：你自己审的结论 vs 它的报告。它漏了什么、有没有编造无证据的 blocking、有没有把 taste 包装成 blocking。这次对照比任何配置都值钱，它给出第一个漏检率数据点。

如果结果显示它漏了大部分你自己能发现的问题，结论不是「调 rubric」，而是**这个模型在评审位上不合适 —— 换模型比调提示词有效得多**。

---

## 第 4 部分：四份文件的分工

评审方每轮按序读四份材料，各管一块，不重叠：

| 文件 | 回答什么 | 谁写 | 多久变一次 | 放哪 |
|---|---|---|---|---|
| `rubric.md` | **怎么审** | 你 | 几乎不变 | `~/.config/review/` |
| `reviewer-brief.md` | **项目是什么样** | 写手生成，你校对 | 改架构时 | `<repo>/docs/` |
| `request.md` | **这次审什么** | 写手 | 每轮 | `~/.review/<短名>/` |
| 代码 | 事实本身 | — | — | 评审 worktree |

**记忆锚点：放在哪就说明它变不变。** config 下的是配置，交接目录下的每轮覆盖。

rubric 放仓库外还有个用意：写手读不到（虽然有 shell 就能 cat，挡不住恶意但挡得住顺手），免得朝规则优化表面合规。

### 目录全貌

`✋` = 你手动建，`⚙` = 脚本自动，`🤖` = agent 生成。

```
✋ ~/.local/bin/request-review          # 全局，所有项目共用
✋ ~/.local/bin/review-archive          # 全局
✋ ~/.config/review/rubric.md           # 全局
⚙ ~/.review/<短名>/                     # 交接目录，脚本 mkdir -p
   🤖 request.md                       # 写手每轮改写
   🤖 r<n>-findings.md                 # 评审方写
   🤖 r<n>-responses.md                # 写手写
   ⚙ .r<n>.sent                        # 防重发标记
   ⚙ .pane                             # pane 缓存
   ⚙ .cycle / .cycle-request.md        # 周期快照，供归档
✋ <repo>/.review.conf                  # 路由配置（加 .gitignore）
✋ <repo>/docs/reviewer-brief.md        # 项目简报（第 6 部分生成）
✋ <repo>/AGENTS.md 的常驻指令段
⚙ <repo>/docs/reviews/
   ⚙ <sha>.md                          # 周期归档，下一周期开始时自动生成
   ✋ escapes.md                        # 漏检记录，你填
   ✋ precision.md                      # 误报记录，脚本填一半
   ⚙ timing.md / skipped.md
```

---

## 第 5 部分：所有模板原文

### 5.1 `~/.local/bin/request-review`

```bash
#!/usr/bin/env bash
# 有界对抗评审 —— 由实施方(写手 agent)调用，无参数。
#
# 寻址方式：按 foreground_cwd == $REVIEW_WT 找评审方，不依赖 agent 名字。
# 找不到就自己建 pane 并起一个。从不关闭任何 pane —— 关不关由人决定。
#
# 退出码：
#   0 = 评审完成，stdout 为 findings 文件路径
#   2 = 前置条件不满足（未提交 / 缺配置 / 缺 request / 缺依赖）
#   3 = 尚未完成，再次运行本命令续等（不会重发 prompt）
#   4 = 需要人介入（reviewer blocked / 无法拉起 / 注入失败 / worktree 里有多个 agent）
#   5 = 流程到界（轮次上限 / 上轮存在 reject）
set -uo pipefail

command -v jq    >/dev/null || { echo "ERROR: jq 不在 PATH 中（PATH=${PATH}）"; exit 2; }
command -v herdr >/dev/null || { echo "ERROR: herdr 不在 PATH 中（PATH=${PATH}）"; exit 2; }

REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: 不在 git 仓库中"; exit 2; }
CONF="${REPO}/.review.conf"
[ -f "${CONF}" ] || { echo "ERROR: 缺 ${CONF}，本 checkout 未配置评审方"; exit 2; }
# shellcheck disable=SC1090
. "${CONF}"
: "${REVIEW_WT:?.review.conf 缺 REVIEW_WT}"
: "${REVIEW_DIR:?.review.conf 缺 REVIEW_DIR}"
: "${REVIEW_KIND:=claude}"
: "${REVIEW_WAIT:=600}"
: "${REVIEW_START_TIMEOUT:=60000}"

[ -d "${REVIEW_WT}" ] || { echo "ERROR: REVIEW_WT 不存在：${REVIEW_WT}（先 git worktree add）"; exit 2; }

DIR="${REVIEW_DIR}"; mkdir -p "${DIR}"
REQ="${DIR}/request.md"
PANE_CACHE="${DIR}/.pane"
CYCLE_SHA="${DIR}/.cycle"
CYCLE_REQ="${DIR}/.cycle-request.md"
ARCHIVE_DIR="${REPO}/docs/reviews"; mkdir -p "${ARCHIVE_DIR}"

# 归档上一个周期的全部交接文件，然后清空。
# 在新周期（round 1）开始时调用，所以不论上一周期以何种方式结束
# （正常收尾 / reject 升级 / 轮次到顶 / 半途放弃）记录都不会丢。
archive_previous_cycle() {
  local sha out n f
  ls "${DIR}"/r*-findings.md >/dev/null 2>&1 || return 0
  sha=$(cat "${CYCLE_SHA}" 2>/dev/null); : "${sha:=unknown}"
  out="${ARCHIVE_DIR}/${sha}.md"
  {
    echo "# Review cycle @ ${sha}"
    echo
    echo "归档于 $(date -Iseconds)"
    if [ -f "${CYCLE_REQ}" ]; then
      echo; echo "## Request"; echo; cat "${CYCLE_REQ}"
    fi
    for n in 1 2 3 4 5; do
      for f in "${DIR}/r${n}-findings.md" "${DIR}/r${n}-responses.md"; do
        [ -f "${f}" ] || continue
        echo; echo "## $(basename "${f}")"; echo; cat "${f}"
      done
    done
  } > "${out}"
  rm -f "${DIR}"/r*-findings.md "${DIR}"/r*-responses.md "${DIR}"/.r*.sent "${CYCLE_REQ}" "${CYCLE_SHA}"
  echo "NOTE: 上一周期已归档到 ${out}，交接目录已清空。" >&2
}

# 忽略尾部空行，取最后一个非空行
sentinel_ok() {
  [ -f "$1" ] || return 1
  [ "$(grep -v '^[[:space:]]*$' "$1" | tail -1)" = "REVIEW-COMPLETE" ]
}

# ============================================================
# 传输层 —— herdr 只出现在这一段。换 tmux / 非交互只改这里。
# ============================================================

# 按 cwd 找评审 agent。输出 "pane_id kind"，找不到输出空。
# 找到多个视为异常（同一 worktree 不该有两个 agent），返回 2。
transport_find() {
  local hits n
  hits=$(herdr agent list 2>/dev/null \
    | jq -r --arg wt "${REVIEW_WT}" \
        '.result.agents[]
         | select((.foreground_cwd // .cwd) == $wt)
         | "\(.pane_id) \(.agent)"')
  n=$(printf '%s' "${hits}" | grep -c . || true)
  if [ "${n:-0}" -gt 1 ]; then
    printf '%s\n' "${hits}" >&2
    return 2
  fi
  printf '%s' "${hits}"
}

# 在 REVIEW_WT 里取得一个可用 pane 并起评审 agent。输出 pane_id。
# 优先复用上次创建过的 pane（记在 $PANE_CACHE），避免失败重试时堆积孤儿 pane。
transport_spawn() {
  local pane="" name err split cached
  if [ -f "${PANE_CACHE}" ]; then
    cached=$(cat "${PANE_CACHE}")
    if [ -n "${cached}" ] && herdr pane get "${cached}" >/dev/null 2>&1; then
      pane="${cached}"
      echo "NOTE: 复用上次创建的 pane ${pane}" >&2
    fi
  fi

  if [ -z "${pane}" ]; then
    split=$(herdr pane split --direction right --cwd "${REVIEW_WT}" --no-focus 2>&1) \
      || { echo "STOP: 无法创建 pane: ${split}" >&2; return 1; }
    pane=$(printf '%s' "${split}" | jq -r '.result.pane.pane_id // empty')
    [ -n "${pane}" ] || { echo "STOP: pane split 未返回 pane_id: ${split}" >&2; return 1; }
    printf '%s' "${pane}" > "${PANE_CACHE}"
  fi

  name="rv-$(basename "${REPO}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | cut -c1-24)"
  err=$(herdr agent start "${name}" --kind "${REVIEW_KIND}" --pane "${pane}" \
          --timeout "${REVIEW_START_TIMEOUT}" 2>&1 >/dev/null)
  if [ -n "${err}" ]; then
    echo "STOP: 在 ${REVIEW_WT} 的 pane ${pane} 上启动 ${REVIEW_KIND} 失败。" >&2
    echo "herdr 原始返回: ${err}" >&2
    echo "排查: 该 pane 是否停在 shell 提示符? 手动进去跑一次 ${REVIEW_KIND} 看真实报错。" >&2
    echo "该 pane 已记入 ${PANE_CACHE}, 下次重试会复用它, 不会再新建。" >&2
    return 1
  fi
  printf '%s' "${pane}"
}

# 注入 prompt。成功返回空；失败在 stdout 给出 herdr 的错误 JSON。
transport_dispatch() {   # $1=pane_id  $2=prompt
  herdr agent prompt "$1" "$2" --wait --timeout 300000 2>&1 >/dev/null
}

# 查生命周期状态
transport_state() {      # $1=pane_id
  herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // empty'
}

# ============================================================

# ---- 豁免路径：SKIP_REVIEW 只能由人设置，写手不得自行设置 ----
if [ "${SKIP_REVIEW:-0}" = "1" ]; then
  printf '%s | %s | %s\n' "$(date +%F)" "$(git rev-parse --short HEAD)" "${1:-未填写原因}" \
    >> "${ARCHIVE_DIR}/skipped.md"
  echo "SKIPPED: 已记入 docs/reviews/skipped.md"; exit 0
fi

# ---- 前置条件 ----
git diff --quiet && git diff --cached --quiet \
  || { echo "ERROR: 工作区未提交。评审必须对着已提交的 sha，否则行号会漂、构建产物互踩"; exit 2; }
[ -f "${REQ}" ] || { echo "ERROR: 先写 ${REQ}"; exit 2; }

parsed=$(sed -n 's|^round:[[:space:]]*\([0-9]\{1,\}\)/\([0-9]\{1,\}\).*|\1 \2|p' "${REQ}" | tail -1)
[ -n "${parsed}" ] || { echo "ERROR: ${REQ} 缺少或写错 round: n/cap 行"; exit 2; }
read -r cur cap <<< "${parsed}"
[ "${cur}" -le "${cap}" ] || {
  echo "STOP: 轮次上限 ${cap} 已到。出口只有三种：带着已知问题接受并记入本轮 findings 的 ## Backlog /"
  echo "      把该条 finding 升级给强模型直接写补丁 / 判定框定有误退回重写计划。交给人决定。"
  exit 5
}

# ---- 新周期开始：先归档上一周期，再记录本周期的 request 与 sha ----
if [ "${cur}" -eq 1 ]; then
  archive_previous_cycle
  cp "${REQ}" "${CYCLE_REQ}"
  git rev-parse --short HEAD > "${CYCLE_SHA}"
fi

# ---- 上一轮存在 reject → 分歧不是缺陷，立即升级，不消耗轮次 ----
prev=$((cur - 1)); PREV_RESP="${DIR}/r${prev}-responses.md"
if [ "${prev}" -ge 1 ] && [ -f "${PREV_RESP}" ] && grep -qiE '^[[:space:]]*F[0-9]+[[:space:]]+reject' "${PREV_RESP}"; then
  echo "STOP: round ${prev} 存在 reject，需人工裁决，不要进入下一轮："
  grep -iE '^[[:space:]]*F[0-9]+[[:space:]]+reject' "${PREV_RESP}"
  exit 5
fi

OUT="${DIR}/r${cur}-findings.md"
SENT="${DIR}/.r${cur}.sent"
START=$(date +%s)

# ---- 定位或拉起评审方 ----
if ! found=$(transport_find); then
  echo "STOP: ${REVIEW_WT} 里有多个 agent（见上）。同一个 worktree 只应有一个评审方。"
  echo "      关掉多余的，或把它们移到别处，再重试。"
  exit 4
fi
if [ -n "${found}" ]; then
  RPANE=$(printf '%s' "${found}" | awk '{print $1}')
  RKIND=$(printf '%s' "${found}" | awk '{print $2}')
  [ "${RKIND}" = "${REVIEW_KIND}" ] || {
    echo "STOP: ${REVIEW_WT} 里跑的是 ${RKIND}，期望 ${REVIEW_KIND}。请你确认那个 pane 里是什么。"
    exit 4
  }
else
  echo "NOTE: ${REVIEW_WT} 里没有评审方，正在拉起 ${REVIEW_KIND} …" >&2
  RPANE=$(transport_spawn) || exit 4
fi

# ---- 注入（仅首次；续等时跳过，防双投）----
if [ ! -f "${SENT}" ]; then
  rm -f "${OUT}"
  TARGET=$(git rev-parse HEAD)

  git -C "${REVIEW_WT}" reset --hard "${TARGET}" -q \
    || { echo "STOP: 无法将评审 worktree reset 到 ${TARGET}"; exit 4; }

  prev_block=""
  if [ "${prev}" -ge 1 ]; then
    prev_sha=$(sed -n '2p' "${DIR}/.r${prev}.sent" 2>/dev/null)
    prev_block="Previous findings: ${DIR}/r${prev}-findings.md
Previous responses: ${DIR}/r${prev}-responses.md
Previous target sha: ${prev_sha:-unknown}
"
  fi

  err=$(transport_dispatch "${RPANE}" "Review request.
Rubric: ${HOME}/.config/review/rubric.md
Request: ${REQ}
Round: ${cur}/${cap}
Target sha: ${TARGET}
${prev_block}Write findings to ${OUT} and reply with only that path.")

  if [ -n "${err}" ]; then
    code=$(printf '%s' "${err}" | jq -r '.error.code // empty' 2>/dev/null) || code=""
    : "${code:=unknown_error}"
    case "${code}" in
      agent_blocked)
        echo "STOP: 评审方停在审批或提问对话框，未发送任何输入。"
        echo "      请你亲自查看 pane ${RPANE}，不要让 agent 代答。"
        exit 4;;
      agent_not_found|agent_not_running)
        echo "STOP: 评审方在注入前消失了（pane ${RPANE}）。重试一次本命令即可。"
        exit 4;;
      agent_prompt_stalled|timeout)
        # 已知缺陷或正常超时：prompt 可能已送达。绝不重发，落到轮询。
        { date +%s; echo "${TARGET}"; echo "${RPANE}"; } > "${SENT}"
        echo "NOTE: ${code}（prompt 可能已送达）。不重发，转入哨兵轮询。" >&2;;
      *)
        echo "STOP: 注入失败：${err}"; exit 4;;
    esac
  fi
  if [ ! -f "${SENT}" ]; then
    { date +%s; echo "${TARGET}"; echo "${RPANE}"; } > "${SENT}"
  fi
else
  START=$(sed -n '1p' "${SENT}")
  saved=$(sed -n '3p' "${SENT}")
  [ -n "${saved}" ] && RPANE="${saved}"
fi

# ---- 完成处理 ----
finish() {
  local elapsed sha nb
  elapsed=$(( $(date +%s) - START ))
  sha=$(git rev-parse --short HEAD)
  printf '%s | %s | round %s/%s | %ss\n' \
    "$(date +%F)" "${sha}" "${cur}" "${cap}" "${elapsed}" >> "${ARCHIVE_DIR}/timing.md"
  # 容忍格式漂移：允许 ##/###、列表符号、粗体包裹，分隔符可为 | 或 :
  nb=$(grep -icE '^[[:space:]]*[#*_ -]*F[0-9]+[[:space:]*_]*[|:][[:space:]*_]*blocking' "${OUT}" 2>/dev/null || true)
  printf '%s | %s | blocking %s | 误报 ?\n' "$(date +%F)" "${sha}" "${nb:-0}" \
    >> "${ARCHIVE_DIR}/precision.md"
  echo "${OUT}"
  exit 0
}

# --wait 返回后先查一次哨兵，再进轮询
sentinel_ok "${OUT}" && finish

deadline=$(( $(date +%s) + REVIEW_WAIT ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
  sleep 10
  sentinel_ok "${OUT}" && finish
  st=$(transport_state "${RPANE}")
  if [ "${st}" = "blocked" ]; then
    echo "STOP: 评审方进入 blocked（审批或提问对话框）。请你亲自查看 pane ${RPANE}。"
    exit 4
  fi
done

echo "PENDING: 尚未完成（已等待 ${REVIEW_WAIT}s）。再次运行 request-review 继续等待，不会重发 prompt。"
exit 3
```

**改这个脚本时的两条 lint**（我踩过三次坑）：

```bash
# 1. 变量后紧跟中文标点会被 bash 5.3 当成变量名的一部分 → unbound variable
LC_ALL=C grep -nP '^\s*[^#].*\$[A-Za-z_][A-Za-z0-9_]*(?=[\x80-\xff])' request-review

# 2. 不要盲目全局把 $VAR 改成 ${VAR} —— 单引号里的 jq 程序有自己的 $ 变量
grep -n "jq" request-review | grep '\${'
```

### 5.2 `~/.local/bin/review-archive`

平时不用 —— 归档由 `request-review` 在新周期开始时自动完成。这是手动工具，用于周期结束后想立刻归档而不等下一周期。

```bash
#!/usr/bin/env bash
# 周期结束后手动归档。原文原样拼接，不做摘要。
set -euo pipefail

command -v git >/dev/null || { echo "ERROR: 缺 git"; exit 2; }

REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: 不在 git 仓库中"; exit 2; }
CONF="${REPO}/.review.conf"
[ -f "${CONF}" ] || { echo "ERROR: 缺 ${CONF}"; exit 2; }
# shellcheck disable=SC1090
. "${CONF}"
: "${REVIEW_DIR:?.review.conf 缺 REVIEW_DIR}"

[ -f "${REVIEW_DIR}/request.md" ] || { echo "ERROR: 没有 ${REVIEW_DIR}/request.md，本周期无可归档内容"; exit 2; }

sha=$(cat "${REVIEW_DIR}/.cycle" 2>/dev/null); : "${sha:=$(git rev-parse --short HEAD)}"
mkdir -p "${REPO}/docs/reviews"
out="${REPO}/docs/reviews/${sha}.md"

{
  echo "# Review cycle @ ${sha}"
  echo
  echo "归档于 $(date -Iseconds)"
  echo
  echo "## Request"
  echo
  cat "${REVIEW_DIR}/.cycle-request.md" 2>/dev/null || cat "${REVIEW_DIR}/request.md"
  for n in 1 2 3 4 5; do
    for f in "${REVIEW_DIR}/r${n}-findings.md" "${REVIEW_DIR}/r${n}-responses.md"; do
      [ -f "${f}" ] || continue
      echo
      echo "## $(basename "${f}")"
      echo
      cat "${f}"
    done
  done
} > "${out}"

echo "${out}"
```

**不要让 agent 干归档这件事** —— 它会顺手「总结」，而归档要的是原文。

### 5.3 `~/.config/review/rubric.md`

```markdown
# Reviewer contract

You are the reviewer. You do not modify any file outside your own worktree,
do not run other agents, and do not redesign. You judge one artifact.

You may compile, run tests, and search your own worktree. Every objection must
have reproducible evidence behind it.

## Read order
1. <repo>/docs/reviewer-brief.md — project brief. Note its "verified at" sha.
2. git log --oneline --stat <brief-sha>..HEAD — only the delta since the brief.
   If that delta exceeds 50 commits or touches paths the brief calls core,
   say so as a finding: the brief is stale and must be re-verified.
3. The request file at the absolute path given in the injected prompt.
4. If Round > 1, read the previous round's two files, whose absolute paths are
   given in the injected prompt:
     - the previous findings file — this is where your finding ids come from
     - the previous responses file — the author's accept/reject per id
   Assume you remember nothing from the previous round. These two files are the
   only record. If either is missing, stop and say so.
5. The artifact itself at the target sha. In Round > 1 also read the diff
   between the previous round's target sha and this one — that is what the
   author changed in response.

If the target sha or any path in the request does not exist, stop and say so.
Do not proceed on a request you cannot verify.

## Output contract
Write everything to the absolute findings path given in the injected prompt.
Reply with only that file path. Never paste findings into the terminal.
End the file with a single line: REVIEW-COMPLETE

## Finding format
Stable ids assigned in round 1, never renumbered.
The first line of each finding must start at column 1 and be exactly:

F<n> | blocking | should | nit

No markdown heading marks, no list bullets, no bold. A downstream script
parses these lines; formatting variants break it.

Then, on following lines:

claim:    one sentence
evidence: file:line, or a command that reproduces it
fix-hint: optional, one sentence, no patches

A finding with no evidence goes under "## Suspicions" and is never blocking.

## Severity
blocking = incorrect, unsafe, or contradicts the stated plan/scope.
should   = real but deferrable. nit = style/taste.
Only blocking findings can cause another round.
"I would have done it differently" is not a finding.

A claim that something is impossible, infeasible, or must be downgraded needs
the same evidence as a defect claim: show the candidate space you searched.
Unsearched, it goes under Suspicions, never blocking.

NOTE ON SCOPE: this contract targets correctness, not design quality.
An abstraction that is correct today but will not survive the next requirement
is a `should`, not a `blocking`. Design quality belongs to plan review.

## Round semantics
Round 1: full review. List EVERY blocking issue you can find now.
  Do not hold issues back for later rounds.
Round 2+: VERIFICATION ONLY. Scope is frozen at round 1.
  Reuse the ids from the previous findings file — never renumber, never drop
  an id, never invent a new one for this cycle.
  For each existing id report exactly one of:
    resolved / not-resolved / regressed
  Judge against the author's stated response for that id:
    - author accepted and it is fixed        -> resolved
    - author accepted but it is not fixed    -> not-resolved (say what is missing)
    - the fix broke something else           -> regressed
    - author rejected -> report "disputed", state in one sentence whether their
      reason holds, and do not argue further. The human decides, not you.
  New unrelated issues go to "## Backlog", never into this cycle.

## For code
Every blocking finding needs a reproducing command or a failing test name.
If the request names relevant test paths, run those first.

## For plans and documents
Required sections:
  "## Missing"        — what the plan omits
  "## Failure modes"  — what makes this plan fail in practice
  "## Checkability"   — rewrite each of the plan's claims as a mechanically
                        checkable acceptance clause. Any claim you cannot
                        rewrite that way IS the defect; list it as blocking.
```

**关于 `## Checkability`**：原始设计里计划支路没有任何裁判，`## Missing` 和 `## Failure modes` 按构造不可证伪。这一节是给计划支路造一个裁判 —— 把评审方的产出从「意见」变成「可判条款清单」，写不成条款的地方就是缺陷本身。

### 5.4 常驻指令（追加到 `<repo>/AGENTS.md` 或 `CLAUDE.md`）

评审方也在同一 repo，会读到同一份文件，标题必须写明适用对象。

```markdown
## Applies to the implementing agent only

### 何时必须请求评审（你只读此清单，不得自行豁免）
满足任一条即必须走 request-review：
- 改动触及 <核心路径清单：如 src/core/、migrations/、auth/>
- 新增或修改公开接口 / 数据格式 / 配置项语义
- 改动跨越 3 个以上文件，或 diff 超过 200 行
- 任何计划文档

以下可直接提交：纯文案与注释、格式化、依赖版本号升级（不含代码适配）、
已有测试的补充。

不确定属于哪一类时：请求评审。
你不得设置 SKIP_REVIEW —— 该变量只由人设置。

### 流程
1. 提交产物（工作区必须干净）
2. 写 $REVIEW_DIR/request.md，含 round: n/cap；sha 与路径必须真实
3. 运行 request-review，按退出码处理：
   0 → 读它输出的路径。对每条 finding 写一行 accept 或 reject 加一句理由，
       写入同目录 r<n>-responses.md，**然后**才改代码。
       只有 blocking 需要下一轮；should / nit 留在本轮 findings，随
       docs/reviews/<sha>.md 归档，不单独立文件。
   3 → 再次运行 request-review 继续等待。
   2 / 4 / 5 → 停下，把输出原样报告给人。
   其他退出码 → 脚本崩溃，同样停下原样报告，不要重试。

### responses 文件格式
一行一条，行首顶格，不加标题、列表符号或粗体：

F1 accept — 一句理由
F2 reject — 一句理由

脚本靠 `^F<n> accept|reject` 解析，格式漂移会导致 reject 检测失效。

### 你不得做的事
- 不得修改任何 finding 的严重度。不同意就写 reject，交给人裁决。
  严重度由评审方定 —— 这是轮次机制成立的前提。
- 不要重试退出码 4 的注入，也不要用任何其它方式操作评审 pane
- 不要替评审方回答审批或提问对话框
- 不要关闭不是自己创建的 pane，不要运行 herdr server stop
- 不要修改 rubric、.review.conf、或本文件中的评审规则

### 上限
计划与文档 2 轮，代码 3 轮。
```

### 5.5 `$REVIEW_DIR/request.md`（写手每轮改写）

```markdown
artifact:      docs/plan-auth.md
base sha:      1a2b3c4
target sha:    3f9a1c2
round:         1/3
out of scope:  数据库迁移、前端改动
risk areas:    token 刷新的并发路径；错误分支的回滚语义
test paths:    tests/auth/
```

只放事实与自我声明的风险点，**不放辩解** —— 转述权的限制就落在这个模板上。

`round:` 一行是脚本解析的唯一真相源。

**sha 和路径必须真实** —— 评审方会自行核验（实测中它会先 `ls` 再决定是否执行），写错会被直接拒绝。

`test paths` 填了能显著缩短评审时间。

### 5.6 `$REVIEW_DIR/r<n>-responses.md`（写手写）

```
F1 accept — 漏了并发路径，已加锁，fix 3f9a1c2
F2 reject — 该行为在 request 中声明为 out-of-scope
F3 accept — 已补测试 test_token_refresh_race
```

---

## 第 6 部分：生成项目简报的提示词

在 `<repo>` 里对**写手**说下面这段。不要让评审方写 —— 它写的简报带着它自己的理解偏差，下一轮它再读自己写的，会形成自我确认的闭环。

```
生成用户指定的文件；未指定时生成 docs/reviewer-brief.md。它供评审 agent
每轮开头阅读，目的是让评审方不必每次从零爬全仓库。

## 动笔前必须先做的验证

完成以下验证后再写正文：

1. 用 `git rev-parse HEAD` 取得完整 sha；用 `git status --short` 判断工作区是否干净。
   工作区必须干净；若输出非空，停下并告知用户先提交或 stash，不要在脏工作树上
   生成本文件。
2. 实际尝试运行项目的测试与检查命令，不得照抄 README 或其他文档的结论：
   - 运行一次全量测试，记录真实结果（通过、失败或无法运行，以及失败位置或阻塞原因）。
   - 运行 lint 与 typecheck；若没有相应配置，确认并记录“不存在”。
   - 确认测试是否需要额外的工作目录、环境变量、服务或其他前提。
   - 若因环境、外部依赖或合理超时而无法完成，记录执行过的命令、退出状态和原因；
     不得把“未执行”写成“通过”，也不要无限等待。
3. 确认每个准备写进“核心路径”的目录或文件真实存在。
4. 确认缺陷来源。默认从 `docs/reviews/` 的归档周期里捞未闭合的 should / nit；
   用户另行指定则用指定的。

## 输出格式

第一行必须是：`<!-- verified at: <当前完整 HEAD sha> -->`

紧随其后用一行注明：该 sha 是本简报核实所依据的代码基线，不要求等于当前 HEAD；
该 sha 之后的提交触及“核心路径”，或累计超过 50 个提交时，本简报需要重新复核。

按以下章节写，总长控制在 170 行以内：

## 这是什么
一两句话说清项目干什么，附出处（README 或架构文档的 file:line）。

## 核心路径
列出改动到就必须走评审的目录或文件，每条附一句为什么它是核心。按这些类别
从代码中确认，不要凭印象：公开接口与数据格式的定义处、被冻结的合同/schema/迁移、
状态与身份的唯一定义处、格式编解码的唯一实现，以及 git 历史上反复修复的文件。

## 架构与数据流
状态存在哪、如何变更、组件间怎么传递。只写读代码不易一眼看出的部分，尤其是
“改 A 会意外影响 B”的耦合；每条尽量附 file:line。不要罗列目录树或复述模块名。

## 不变量
每条写成「必须 X，因为 Y」。Y 优先从过往修复中确认，例如 git log、事故记录和
回归测试名称，因为“为什么”通常无法仅从当前代码反推。Y 的出处可以是 commit sha
或测试名，不必强求 file:line。

## 已知取舍
故意没做的抽象、选了 A 没选 B 的原因；每条都要附可核实的出处。

## 已知缺陷
默认从 `docs/reviews/` 的归档周期里摘录未闭合的 should / nit；用户另行指定则使用
指定来源，一条一行。若该来源为空，明确写“尚无已知缺陷来源”，并列出完成其他章节的
验证过程中已经确认的缺陷，逐条标注“非台账来源，本轮直接复核”；不要为本节额外发起
全仓缺陷普查。同时在“待补充”中提出建立缺陷来源。

## 测试
测试在哪、实测如何运行（包括必要的路径与环境前提）、哪些测试覆盖核心路径，以及
lint/typecheck 等确定性检查命令。若全量测试当前无法通过，写清失败位置、阻塞原因，
以及是否能确认与当前 HEAD 有关。没有 lint 或 typecheck 配置时明确写“没有”。

## 待补充
不确定或需要人决定的内容，一条一行。

## 硬要求

- 只写能从代码、命令输出和 git 历史确认的事实。每条实质陈述都必须能指向
  file:line、commit sha，或本轮真实执行并看到输出的命令；做不到就移进“待补充”。
- 先验不是证据。凡是“我以为需要 X”“通常这类项目会 Y”，必须实测后再写。
- 不复制大段代码。
- 不写评审流程与报告格式、当前进度与下一步、凭证与内网地址，或推测性的架构演进建议。
- 超长时先删“这是什么”的展开，再删“已知取舍”；“架构与数据流”和“不变量”最后删。
```

生成后**你亲自过一遍「不变量」那节**。其余部分机械生成没问题，但不变量是这份文件的价值所在，写手可能写不全或写错。

### 维护规则

**改架构时更新头部那行 sha。** rubric 让评审方只读该 sha 之后的增量，sha 不更新它就会带着旧前提自信推理。

rubric 里那条「增量超 50 个提交就报 finding」是个自动提醒 —— 它会主动告诉你简报该更新了。

### 简报与 worktree 的同步

不会不同步，有两道保险：脚本强制工作区干净才允许评审；每轮 `reset --hard` 到 target sha。所以评审方读到的简报**正是被评审那个提交里的版本** —— 这正是想要的，它评审 commit X 就该看 commit X 时的项目描述。

---

## 第 7 部分：轮次控制

**单位**：一轮 = 一次评审 pass 加一次作者响应 pass，针对同一个物件。

### 三个前提，缺一个上限就形同虚设

1. 计数器写在物件里（`request.md` 的 `round:`），不写在提示词里 —— 两个 agent 各有上下文，评审方还可能是全新 session
2. finding 编号第一轮分配后永不重排
3. 第一轮之后冻结范围

### 提前退出条件（任一满足即结束）

- 没有 blocking 级 findings（should / nit 永不触发下一轮）
- 同一编号在作者声称修好后再次出现第二次 —— 通常意味着修复方向错了或双方理解不一致
- 某一轮没有任何编号被关闭 —— 说明任务框定有问题而非实现有问题
- **出现 reject** —— 分歧不是缺陷，立即升级给人，不消耗轮次（脚本已实现，exit 5）

### 到顶的三个合法出口，agent 不得自行继续

1. 带着已知问题接受并记入本轮 findings 的 `## Backlog`
2. 把那条具体 finding 升级给强模型直接写补丁
3. 判定框定有误，退回重写计划

### 副作用

有了上限，第一轮的质量更重要 —— 不再有「后面还能聊」的余量。所以第一轮输入要喂足，rubric 里明确要求一次性列完全部 blocking。

---

## 第 8 部分：度量

| 文件 | 记什么 | 谁填 | 反馈周期 |
|---|---|---|---|
| `precision.md` | 每轮一行：blocking 数 / 其中你判定为误报的数 | 脚本填前半，**你填问号** | 当场 |
| `timing.md` | 脚本自动写墙钟时长 | 脚本 | 当场 |
| `escapes.md` | 日后发现的、本该被某次评审抓到的问题 | 你 | 周到月 |
| `skipped.md` | 豁免记录 | 脚本 | 当场 |

### 那个问号

脚本每轮追加一行：

```
2026-08-28 | e956e05 | blocking 1 | 误报 ?
```

前三项脚本能填。**最后那个只有你能判** —— 评审方报的 blocking 里有几条其实不成立（读错代码了、把风格偏好包装成正确性问题）。读完 findings 顺手把问号换成数字，十秒钟。

**为什么必须人来填**：判断一条 blocking 成不成立，正是这套流程存在的理由。能自动判就不需要评审方了。

**为什么它比 escapes 重要**：当场就有，不用回忆。而且它盯的是最可能先杀死这套流程的问题 —— 评审方胡说八道几次，你就开始不信任报告，然后开始跳过。误报率能提前几周告诉你这件事在发生。

### escapes.md 的现实预期

它需要你在几周后发现 bug 时主动回想「这本该被哪次评审抓到」，没有任何外部触发，全靠自律。**大概率会荒废，别把流程的存续押在它上面。** 建了但只有三条记录，也比零条强。

跟你已有的某个固定动作绑一下会好些：每次修完一个非平凡的 bug 就问自己一句。

### 统计漏检而非发现数量

发现数量是最容易自我欺骗的指标。

---

## 第 9 部分：失效模式与警戒线

### 结构性的

**评审对遗漏基本无能。** 范围冻结把这个盲区制度化了，第一轮的召回率因此成为整条流程的单点故障。

**强评审 + 稍弱实施的组合里，弱方几乎不会反驳。** 会把所有 findings 照单全收（包括错的），设计慢慢漂向评审方偏好。逐条表态加理由是为此设的判断闸门 —— 但写表态的是弱方本人，所以 reject 必须立即升级给你，那是你在循环里为数不多的重新入场点。

**作者自行降级严重度是同一个失效的镜像版本。** 它没有照单全收，而是把 blocking 改判成 should 塞进 backlog —— 效果一样，绕过了轮次机制。常驻指令里已明写禁止，但这条只能靠指令，脚本挡不住。

**跨模型的价值来自失败模式不同，不是来自强弱。** 同厂商的强弱两档共享训练数据和失败模式，盲区高度相关。若两个轴只能优化一个，优先跨厂商。

**你自己的注意力会漂移。** 报告连续干净之后你会开始盖章而不是读。第一次出现 blocking 0 时，值得自己扫一眼那个 diff 确认。

### 操作性的

- 评审要对着**已提交的 sha**（脚本已强制）
- `unknown` 不代表完成 —— 空 shell 都报 unknown。完成判定以文件哨兵为准
- `agent_blocked` 时不要替对方回答对话框
- 永远不要关闭不是自己创建的 pane，不要在活动会话里停 server
- 评审借评审之名重做设计是无底洞，rubric 已明确排除
- **递归委派靠「不给能力」来防**：实施方装 herdr skill，评审方不装。若评审方也有控制面，它能再叫一个评审的评审、能开 pane、能改文件，单一写入方假设随之崩塌。评审方的无能力是保障，不是缺陷。
- **投错目标的表现形式是「一切正常」** —— 另一个仓库的 agent 照样能读能写能打哨兵，脚本会返回 0。cwd + kind 双条断言是唯一的防线，不要因为「应该不会错」而删掉它。

### 被高估的收益

**评审 worktree 的构建缓存不会真的热。** 每轮 `reset --hard` 到新 sha，改动文件时间戳全变，增量构建收益远小于预期。若评审方跑测试太慢，解法是在 `request.md` 里给出 `test paths` 缩小范围，不是指望缓存。

**评审方的 token 不是稀疏的。** 见 1.3。

---

## 第 10 部分：出错速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `command not found: request-review` | `~/.local/bin` 不在 PATH | 加进 `.zshrc` |
| `ERROR: jq/herdr 不在 PATH 中` | agent 环境的 PATH 与你终端不同 | 脚本里用绝对路径 |
| `ERROR: 缺 .review.conf` | 不在配好的仓库里，或忘了建 | 见步骤 2 |
| `ERROR: REVIEW_WT 不存在` | 路径写错，或 worktree 被删了 | 见步骤 2 |
| `STOP: 里有多个 agent` | worktree 里开了不止一个 agent | 关掉多余的 |
| `STOP: 里跑的是 X，期望 claude` | 那个 pane 里是别的东西 | 去看看那个 pane |
| `STOP: 启动 claude 失败` + `agent_name_taken` | 那个 pane 里已有同名 agent | 通常是 `transport_find` 没找到它；检查 `REVIEW_WT` 与 agent 的 `foreground_cwd` 是否完全一致 |
| `STOP: 停在对话框` | 评审方弹了审批 | 亲自去那个 pane 看，**不要让 agent 代答** |
| 评审方拒绝执行 | request 里的 sha 或路径不存在 | 这是正确行为；修正 request |
| `exit 3` 一直不结束 | 评审方卡住或任务太大 | 看它屏幕；必要时关掉那个 pane，下次自动重建 |
| 非 0/2/3/4/5 的退出码 | 脚本崩溃 | 让写手原样报告，不要重试 |

### 评审方进程重启后

不需要做任何事。脚本按 cwd 找，找不到就自己起一个。你随时可以关掉那个 pane。

唯一要注意的时机：**一个评审周期中间（第一轮和第二轮之间）不要关** —— 会丢掉跨轮上下文和缓存复用，第二轮要重读简报和 diff。周期之间随便关，里程碑边界甚至建议主动清一次上下文，防止长会话退化和一致性压力。

---

## 第 11 部分：herdr 事实核对与实测记录

基于 herdr 0.8.2 官方文档，并在本机实测。

### 11.1 已验证的 JSON 字段路径

`agent get` / `agent list` / `agent rename` / `agent prompt` 返回的 agent 对象结构一致。单查外层是 `.result.agent`，列表是 `.result.agents[]`。

```json
{
  "result": {
    "agent": {
      "agent": "codex",              // kind：codex / claude / pi
      "agent_status": "idle",        // 生命周期状态，不是 "state"
      "name": "probe-cx",            // rename 之后才有
      "pane_id": "w34:pA",
      "cwd": "...",
      "foreground_cwd": "...",
      "workspace_id": "w34",
      "tab_id": "w34:t1",
      "agent_session": { },              // 官方集成上报时才有
      "screen_detection_skipped": true   // 仅原生上报的 agent（如 pi）有
    }
  }
}
```

错误响应：`{"error": {"code": "agent_not_found", "message": "..."}, "id": "..."}`。可用 `jq -r '.error.code'` 精确解析。

### 11.2 命令要点

- **超时上限只约束 `agent start`**：默认 30000ms，显式值须 >3000 且 ≤300000。`agent prompt --wait` / `agent wait` 省略 `--timeout` 时无限等待。实测 `--timeout 120000` / `300000` 可用。
- **错误一律走 stderr**，退出码统一为 1；CLI 语法错误退出码 2。退出码无法区分错误类型，必须解析 `.error.code`。
- **`agent prompt` 遇到 blocked** 返回 `agent_blocked` 且不发送任何输入。
- **agent 名字规则** `[a-z][a-z0-9_-]{0,31}`，在所有存活 agent 中唯一。实测 agent 退出后名字被清除（`agent_not_found`）。本方案不依赖名字。
- **`unknown` 不代表工作成功** —— 实测空 shell 的 pane 也报 unknown。
- **全屏 agent 的历史读取**：Claude Code 等在 alternate screen 渲染历史，`agent read --lines N` 在 agent 处于 working/blocked/unknown 时返回 `agent_not_idle`。herdr 官方文档自己的建议就是让 agent 把结果写成文件、只回复路径 —— 与本方案一致。

### 11.3 实测结论

| 项 | 结果 |
|---|---|
| 写手 bash 工具长时阻塞 | `sleep 180` 完整等回，`REVIEW_WAIT=600` 可用 |
| 多行 prompt 注入 | 六行模板完整送达，作为单条消息处理 |
| 文件哨兵 | 末行 `REVIEW-COMPLETE` 无尾随空行；判据仍用「最后一个非空行」以容错 |
| `agent_prompt_stalled` 误报（issue #2690） | 本机不复现；脚本仍保留规避（不重发，落到轮询） |
| agent 退出后名字清除 | 确认，返回 `agent_not_found` |
| `pane wait-output` 作完成信号 | **不可用** —— 它会立即检查已有输出，注入的 prompt 就在屏幕上，哨兵词会瞬间假匹配 |
| blocked 状态识别 | 写手侧无法测（跳过确认模式不弹窗）；评审方侧保留确认模式时可触发 |
| 评审方自行核验请求 | 确认 —— 给它不存在的 sha/路径，它会先 `ls` 验证再拒绝，理由是「这会向自动化系统谎报一次评审已完成」 |

### 11.4 写手跳过确认模式的三个后果

实测让 codex 执行 `rm` 直接执行，未弹审批。

1. **`blocked` 分支在写手侧是死代码。** 写手卡住时不会有 blocked 信号，只会一直 working 或 unknown 直到 `REVIEW_WAIT` 耗尽 —— 超时保护是唯一兜底。
2. **`agent_blocked` 的「不发任何字节」保护在写手侧用不上。**
3. **写手能改 `.review.conf`、rubric、常驻指令。** 常驻指令里那句「不要修改评审规则」从约定变成了唯一防线。想真的挡住只能靠文件权限。这是「无人介入的代价是权限」的具体形态。

**建议评审方反过来配：保留确认模式。** 它本来就不该写任何东西，弹窗停住反而是正确行为。

### 11.5 herdr 耦合面

herdr 只出现在 `request-review` 的四个 `transport_*` 函数里（脚本中有注释框标出）：

- `transport_find` — 按 cwd 找 agent
- `transport_spawn` — 建 pane 起 agent
- `transport_dispatch` — 注入 prompt
- `transport_state` — 查生命周期状态

其余全部逻辑（轮次、编号、范围冻结、reject 升级、哨兵、归档、度量）只依赖 git 和文件系统。日后想换 tmux 或走非交互路线，只改这四个函数。worktree 是纯 git 的，不用动。

---

## 第 12 部分：止损点

**三个月，或十个真实周期。** 到点强制自己回答两个问题：

1. `precision.md` 里的误报率是多少？
2. 我还愿意读这些报告吗？

如果那时候你在维护流程而不是在用它，就退回最简形态：**写手写完，你手动粘一句话给评审方**。丢掉脚本、worktree、度量、轮次守卫。

保留的是三条真正有价值的东西，它们都不依赖任何工具：

1. **evidence 门槛** —— 每条 blocking 必须带 `file:line` 或复现命令。这是全套东西里唯一有硬裁判的地方，也是唯一能防 Goodhart 的。
2. **稳定编号 + 范围冻结** —— 把第二轮从「重新评审」变成「逐条验证」。验证便宜且天然收敛，这是轮次上限能成立的全部原因。
3. **事件驱动替代连续监控** —— 你从「系统里唯一的错误检测器」变成「等它叫你」。这是最真实的收益，而且它不依赖评审质量：哪怕评审方一无是处，产出变成离散物件这件事本身就改善了工作节奏。

### 为什么现在就要写下止损点

因为没有它，这套东西会靠惯性活很久。而它的自我评估机制本来就弱 —— `escapes.md` 大概率荒废，`precision.md` 半自动，剩下的全是主观感受。

主观感受在这件事上有个特定的失效方式：**报告连续干净会让你觉得它在正常工作，实际可能是它什么都没抓到而你也不再检查了。** 这两种状态从内部看一模一样。

### 唯一能穿透这个的办法

**前五个周期里做两次完整对照**：挑一个改动自己完整审一遍，跟报告比，统计漏检而非发现数量。

成本是白干两遍。但它一次给出的信息比攒三个月的记录还多，而且不依赖持续自律 —— 是一次性动作。

如果对照显示评审方漏了大部分你自己能发现的问题，结论不是「调 rubric」，而是**这个模型在评审位上不合适。换模型比调提示词有效得多**。
