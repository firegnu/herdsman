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
- 第 6b 部分：规划者（可选角色）
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

③ 写手：按种类切 commit —— 代码一个、计划文档一个、状态记录一个
        每个 commit 后跑 request-review，不自己判断要不要审

③' 脚本路由，看的是「上次评审以来」这一整段，不是最新一个提交：
            简报缺失或过期（verified-at 之后 >50 提交）→ exit 7，写手先写/重写简报（单独提交，自动走 plan 评审）
            自上次 plan 评审起碰了 REVIEW_PLAN_PATHS 或规则文件（AGENTS.md / CLAUDE.md / brief / .review-map）→ REVIEW（kind: plan），exit 6
            范围 = 这段里未被人 SKIP_REVIEW 的提交各自改的文件
            自上次 code 评审起只改 .md/.rst/.txt（且图上没把它们标为 deep/review）→ SKIP，记 self-closed.md，exit 0
            风险图 .review-map 能定的直接定：全 skip → SKIP；有等级 → REVIEW 带 level，exit 6
            上次 SKIP 之后只新增纯文本提交 → 沿用 SKIP
            累积超上限（20 提交 / 2000 行）→ REVIEW，exit 6
            还有图上没有的路径 → 给评审方发 triage prompt（范围、提交列表、未映射路径）
                   评审方一行 REVIEW [deep|light] / SKIP + 理由 + 可选 map: 建议 → exit 0 / 6
   写手：exit 0 → 结束；exit 6 → 照抄输出里的 kind / level / base sha，继续 ④
   SKIP 不是终审：那段改动留在下一次的范围里，直到某次评审覆盖它

④ 写手：写 ~/.review/<项目>/request.md（artifact、kind、level、base sha=脚本给的、target sha=HEAD、round: 1/3）
        跑 request-review。有针对 HEAD 的 request.md 就是明确的评审请求，不再 triage

⑤ 脚本：简报过期门 → 检查工作区干净 → 读 round → 校验 kind、level、base sha 是 HEAD 祖先
        （脚本路由过的 HEAD，round 1 核对 request 的 kind 与路由判定一致；不看单个提交碰了什么文件）
        → 归档上一周期并清空交接目录
        按 cwd 找评审方（没有就建 pane 起一个）
        把 review worktree reset --hard 到 target sha
        注入 prompt（rubric 路径、request 路径、round、level、target sha）
        --wait 返回后校验哨兵，未满足则每 10 秒轮询

⑥ 评审方：读 rubric → brief → request → 按 kind 只执行一套契约 → diff
          写 r<n>-findings.md，末行 REVIEW-COMPLETE，停

⑦ 脚本：认到哨兵 → 打印路径 → exit 0
        顺手写 timing.md 和 precision.md

⑧ 写手：读 findings
        对每条写一行 accept/defer/reject + 理由 → r<n>-responses.md
        defer 只限 should/nit：承认但本轮不改，随归档进 Backlog
        必须先写完再动代码 —— 这是判断闸门

⑨ 分叉：
   没有 accept（全 defer）  → 结束，一轮
   有 accept 且改了 artifact → 改代码 → 回到 ④，round 改成 2/3
   有任何 reject            → 下一轮开头脚本 exit 5，写手停下报告给你 → ⑩
   把 blocking 标成 defer   → 同上 exit 5 → ⑩

⑩ 你裁决那条争议 → 告诉写手继续或收工
```

**你只出现在 ①、⑩，以及轮次到顶时。** 其余全自动。

路由里没有写手的判断：机械规则由脚本执行，语义判断由评审方做（它没有"少审一次"的利益）。项目知识全部来自 `docs/reviewer-brief.md`，常驻指令模板对所有项目一字不差。写手保留的只有"主动请求评审"的权力：直接写 request.md 运行即可。

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

它把 `request-review`、`review-archive`、`herdsman-init`、`review-board` 安装到 `~/.local/bin`，把 `rubric.md`、`agents-section.md`、`brief-prompt.md` 安装到 `~/.config/review/`。

验证：在家目录跑 `request-review`，应报 `ERROR: 不在 git 仓库中`。若报 `command not found`，把 `~/.local/bin` 加进 `.zshrc` 的 PATH。

验证：`grep -F '## Restated facts' ~/.config/review/rubric.md` 应恰好输出一行。

验证：`review-board --open` 应在浏览器里打开 `~/.review/board.html`；还没配项目时左栏为空。

### 步骤 2 — 项目初始化

```bash
cd <repo>
herdsman-init <短名>
```

它自动创建评审 worktree，写 `.review.conf` 和 `.gitignore` 条目，建立 `docs/reviews/`、三个度量文件与交接目录。命令幂等，已存在的内容不会被覆盖。

`.review.conf` 有四个必填变量：`REVIEW_KIND` 是评审 agent 类型，`REVIEW_WT` 是评审 worktree，`REVIEW_DIR` 是交接目录，`REVIEW_WAIT` 是等待秒数；其中路径值必须是绝对路径。

可选的 `REVIEW_PLAN_PATHS` 是计划/设计文档的路径模式（空格分隔，按 shell `case` 匹配，`*` 可跨 `/`，如 `"docs/plans/*"`）。配了以后，范围里碰到这些路径的改动会先以 `kind: plan` 送审，代码范围随后单独送审；不再校验单个提交是否混装。不配就只靠 `.review-map` 的 plan 行和规则文件。

可选的 `REVIEW_WAKE=1` 打开唤醒模式。默认（`0`）写手派发之后在前台等满 `REVIEW_WAIT` 秒才返回，
这段时间它的回合没结束，**人插不进话**。打开后，派发那次运行会 fork 一个只盯这一次的进程，然后立刻
返回 exit 3 并让写手停下；等哨兵齐了（或被盯的 agent blocked、连续两次空转、超过 `REVIEW_WAKE_MAX` 秒），
那个进程用 `herdr agent prompt` 把写手叫醒，叫完就退出——不是常驻的东西，没有评审在跑时一个都没有。
三个等待点（triage / 规划者 / 评审方）共用同一个 `wait_sentinel`，所以一次打开全部生效。

它只往身份核对通过（`terminal_id` 与 `agent_session` 都对得上）且已经 idle 的写手 pane 注入；核不准
就什么都不做，宁可让你自己跑一次也不往不确定的 agent 里打字。脚本不在 herdr 里跑（没有 `HERDR_PANE_ID`）
时没人能叫醒它，自动退回前台等待。唤醒进程不写 `.last`／`.last.out`、不刷看板——那三样是写手那次运行的
记录，被后台进程覆盖会让看板显示错的东西。

没有 `REVIEWER` 这一项。脚本按 `REVIEW_WT` 的 cwd 找评审方，不依赖 agent 名字，因为名字需要人维护、进程一退就没，cwd 是进程自带属性。

评审 worktree 建一次就一直在，跟评审 agent 的死活无关；每轮脚本把它 `reset --hard` 到本次要审的 sha，目录内容变、目录本身不动。

可选：`chmod 444 .review.conf`。挡不住恶意，但挡得住写手顺手改。

### 步骤 3 — 两件必须手工做的事

1. 把 `~/.config/review/agents-section.md`（第 5.4 节）追加到 `<repo>/AGENTS.md`（Codex 系）或 `CLAUDE.md`（Claude Code）。模板对所有项目一样，不需要改。
2. 用第 6 部分的提示词让写手生成 `docs/reviewer-brief.md`，生成后你亲自过一遍「核心路径」和「不变量」两节——**triage 的项目知识全部来自这两节**。

**这一步现在由脚本强制。** 没有简报时写手第一次跑 `request-review` 就 exit 7 要求生成，生成的简报走一次 plan 评审
由评审方核对。你也可以按上面的提示词提前让写手生成。简报是空的话，评审方每轮从零爬全仓库，triage 也只能一律说 REVIEW。

有计划/设计文档目录的项目，在 `.review.conf` 加 `REVIEW_PLAN_PATHS`，否则 `.md` 计划会被当成纯文本跳过。

### 步骤 4 — 第一个真实周期

不要空跑假 request（`artifact: PIPELINE-TEST` 这种评审方会拒绝，因为它核验不到，那是正确行为）。直接拿一个**你自己已经审过**的真实提交跑：

```bash
cd <repo>
. .review.conf
mkdir -p "$REVIEW_DIR"
cat > "$REVIEW_DIR/request.md" <<EOF
artifact:      $(git diff --name-only HEAD~1 HEAD | tr '\n' ' ')
kind:          code
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

### 升级已有项目

本仓库更新后，三层东西各有各的到达方式：

| 层 | 到达方式 | 已有项目要做什么 |
|---|---|---|
| `bin/*`、`config/rubric.md` | `./install.sh` 全局覆盖 | 重跑一次 `install.sh` |
| `templates/agents-section.md` | `install.sh` 装到 `~/.config/review/`，再手工追加到各项目 AGENTS.md / CLAUDE.md | 把旧的那一段整体替换（`herdsman-init` 只检测存在，不检测版本）；旧的核心路径清单不用保留，triage 读 brief |
| `.review.conf`、`docs/reviews/*.md` | 项目私有 | 有计划文档目录的加 `REVIEW_PLAN_PATHS`（否则 .md 计划会被当纯文本跳过）；重跑 `herdsman-init` 会补建缺的度量文件 |

request.md 的格式变化（`kind:` 必填、`base sha` 校验）由脚本在下一次 `request-review` 时以 exit 2 直接告诉写手，不需要额外通知。

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
✋ ~/.local/bin/review-board            # 全局；看板生成器，request-review 每次退出时调用
✋ ~/.local/bin/review-map              # 全局；从归档/依赖/测试生成风险图草案，--suggest 给出差异
✋ ~/Library/LaunchAgents/dev.herdsman.review-board.plist   # 每 30 秒生成一次看板，install.sh 装
✋ ~/.config/review/rubric.md           # 全局
⚙ ~/.review/board.html                 # 只读看板，review-board 生成，浏览器常开
⚙ ~/.review/<短名>/                     # 交接目录，脚本 mkdir -p
   🤖 request.md                       # 写手每轮改写
   🤖 r<n>-findings.md                 # 评审方写
   🤖 r<n>-responses.md                # 写手写
   ⚙ .r<n>.sent                        # 防重发标记 + 已派发 reviewer 身份
   ⚙ .pane                             # pane 缓存
   ⚙ .cycle / .cycle-request.md        # 周期快照，供归档
✋ <repo>/.review.conf                  # 路由配置（加 .gitignore）
⚙ <repo>/.review-map                   # 风险图：review-map 生成初版，脚本自动升级，降级要人点头；规则文件
✋ <repo>/docs/reviewer-brief.md        # 项目简报（第 6 部分生成）
✋ <repo>/AGENTS.md 的常驻指令段
⚙ <repo>/docs/reviews/
   ⚙ <sha>.md                          # 周期归档，下一周期开始时自动生成
   ✋ escapes.md                        # 漏检记录，你填
   ✋ precision.md                      # 误报记录，脚本填一半
   ⚙ self-closed.md                     # 未送审记录（脚本或 triage 判的），追溯漏网用
   ⚙ timing.md / skipped.md
```

新写入的 `.r<n>.sent` 依次保存发送时间、target SHA、派发时 pane ID、稳定 `terminal_id` 和规范化 `agent_session`。续等按 terminal/session 恢复同一 reviewer；旧版三行 marker 只为在途轮次保留兼容，会按保存 pane 的 kind 与稳定 `cwd` 校验并 fail closed。

### 看板：人的阅读面

交接内容只在写手和评审方之间流动，人看到的是写手的转述。`review-board` 把交接目录和归档渲染成
一个静态 HTML（`~/.review/board.html`），浏览器里常开一个 tab，30 秒自动刷新：

- **顶栏**：写手与评审方各是哪个 agent、model、effort（读 `~/.codex/config.toml` 与 `~/.claude/settings.json`，
  会话里临时切换的看不到）、生成时间。
- **顶部横幅**：跨项目列出等你的事 —— 待裁决的 reject / blocking defer，点一条落到那行 finding。没有时一行灰字。
- **左栏**：所有配了 `.review.conf` 的项目，各带状态与停留时长；状态标签按"谁在等"配色：红 = 等你，
  蓝 = 等评审方，琥珀 = 等写手，灰 = 没人在等；等你的排最前。
- **右栏**：项目头下面两行观察量：简报核实于哪个 sha、之后几个提交、离上限多远；"上次代码评审以来 N 个提交 · 多少个 SKIP · 多少个未经路由"（从
  timing.md、self-closed.md 和 git 算，不改机制；路由现在只看 HEAD 一个提交，这行用来看累积到底发生不发生）；
  然后是选中项目的当前周期（标题是 target 提交的 commit 标题，plan 再带文档标题；然后是写手交的
  artifact / checks、折叠的自述、diff stat 与折叠的完整 diff）、
  每轮一张 finding 表（编号、严重度与第 2 轮起的状态、评审方 claim 与 evidence、写手回应、裁决）、
  暂缓清单（历史归档里的 defer）、最近归档（可展开原文）、自闭合记录。页面把协议词翻成中文
  （accept 接受 / defer 暂缓 / reject 拒绝，blocking 阻断 / should 应改 / nit 细节，resolved 已修复 等），
  悬停显示英文原词；文件与协议里仍是英文。

它是**派生视图**：不存自己的状态，不接 agent，写手和评审方不知道它存在。状态判据与 `request-review` 相同
（request 是否指向 HEAD、`.sent` / findings 哨兵 / responses / decision 文件是否存在）。评审中或 triage 中时它还会
问一下 herdr 评审方 pane 的状态：working 只作备注，blocked / idle 视为评审方停了没交付，进"等你"横幅。
周期闭合但尚未归档时收成一行摘要（轮数、回应计数、耗时），点开才见 request 与 Round；下个周期派发时它进归档。`request-review`
每次退出时调用 `review-board --quiet` 重新生成；`install.sh` 还装一个 launchd 任务
（`~/Library/LaunchAgents/dev.herdsman.review-board.plist`）每 30 秒生成一次，覆盖周期最后一轮写手回应后
没有人再跑脚本的空档；手动 `review-board --open` 也行。它看得到节点，看不到节点之间
agent 在做什么 —— 那部分只在 herdr 的 pane 里。

项目发现：`~/Developer/personal_projs/*/.review.conf`，加上 `~/.review/projects` 里登记的路径（`herdsman-init`
自动登记，所以仓库放在哪都会被扫到；一行一个路径，可手动增删）。
`.review.conf` 里 `REVIEW_BOARD=` 置空可关掉退出时的自动生成。

### 风险图：审不审、审多深，由文件说，不由评审方当场猜

`<repo>/.review-map` 一行一个路径模式：`模式  等级  # 理由`。等级 deep（跑测试、三轮、阻断必带复现命令）、
review（常规）、light（一轮、只找阻断、不跑测试）、plan（等同 .review.conf 的计划/规则路径，改了走 plan 评审）、skip。
模式里 `**` 可跨目录、`*` 不跨；命中多条时最长的生效。纯文本（.md/.rst/.txt）默认是状态记录不送审，
除非图上把那个文件标为 deep 或 review（出过阻断的 README 之类）；light/skip 对纯文本等于不审。

- **初版由证据生成**：`review-map <repo>` 读归档里每条 finding 的 evidence 路径与严重度、import 扇入、
  有没有测试，输出带理由的草案。没有归档的新项目只有扇入和测试两个信号，所以几乎全是 review —— 没有理由放松就不放松。
- **往严自动**：某轮在某路径上报出阻断，`request-review` 在 finish 时把那条路径追加为 deep，随写手下次提交带上。
- **往松要人**：`review-map --suggest` 对照现有图，列出证据说可以降的行和图上没有的路径，看板项目头显示为
  "风险图有 N 条建议"。你看理由，同意就改那一行提交。不看也不会出事，只是多审。
- **路由怎么用它**：自上次 code 评审起改动的所有文件在图上取最高等级。任一文件不在图上才叫评审方 triage，
  它判等级并建议 `map:` 行。累积范围按种类各算起点（timing.md 的最新一行 code / plan），SKIP 只是推后，
  上限（`REVIEW_ACCUM_COMMITS` / `REVIEW_ACCUM_LINES`）到了直接审。
- 写手不碰这个文件（它在 `REVIEW_RULE_PATHS` 里，改了走 plan 评审，和 AGENTS.md 同级）。人用 `SKIP_REVIEW`
  放过的提交不进任何累积范围 —— 人的跳过是终审，不是推后。`SKIP_REVIEW=1` 免当前 HEAD 一笔，
  `SKIP_REVIEW=<base>..<tip>` 一次免掉整段（补登记历史上已经口头免掉的范围就用这个；git 规矩，不含 base）。
  两种写法都只往 `skipped.md` 追加，不派发也不过任何门，工作区脏时也能用；改完记得把 `skipped.md` 提交掉。
  注意它只让这些提交不再**触发**评审，不会把它们从后续某次评审读的 diff 里摘掉 —— 那由 `base sha` 决定，
  路由印 base 时若发现紧随其后的一段整段已豁免，会打一行 NOTE 告诉你该改成哪个 sha。
  `.review.conf` 里 `REVIEW_MAP=` 置空可关掉，关掉后所有代码路径都交评审方 triage。

---

## 第 5 部分：所有模板原文

### 5.1 `~/.local/bin/request-review`

```bash
#!/usr/bin/env bash
# 有界对抗评审 —— 由实施方(写手 agent)调用，无参数。
#
# 路由：交接目录里没有针对 HEAD 的 request.md 时，先判定这次提交要不要评审 ——
# 纯文本文档改动直接跳过；触及 REVIEW_PLAN_PATHS 直接要求评审；其余交评审方 triage。
# 有针对 HEAD 的 request.md（或已在第 2 轮之后）则视为明确要求评审，不经 triage。
#
# 寻址方式：按 cwd == ${REVIEW_WT} 找评审方，不依赖 agent 名字。
# 找不到就自己建 pane 并起一个。从不关闭任何 pane —— 关不关由人决定。
#
# 退出码：
#   0 = 评审完成，stdout 为 findings 文件路径；或 triage 判定跳过，stdout 为 SKIP: <理由>
#   2 = 前置条件不满足（未提交 / 缺配置 / 缺 request / 缺依赖 /
#       request 缺 kind 或 base sha / base 不是 HEAD 祖先 / kind 与路由判定不符 / 上轮 responses 格式不合规范）
#   3 = 尚未完成。输出写「已派发」时本回合就该结束：停下等人叫，别重跑（见 REVIEW_WAKE）；
#       否则再次运行本命令续等（两种都不会重发 prompt）
#   4 = 需要人介入（reviewer blocked / 回合结束却没交付 / 无法拉起 / 注入失败 / worktree 里有多个 agent）
#   5 = 流程到界（轮次上限 / 上轮存在未裁决的 reject 或 blocking defer；人裁决记入 r<n>-decision.md 后可继续）
#   6 = 判定需要评审，stdout 为 REVIEW: <理由> 加 kind / level / base sha 三行；照抄进 request.md 后再次运行
#   7 = reviewer brief 缺失或过期，先写/重写 brief（单独提交，它会作为 kind: plan 送审），再运行
#
# request-review plan：请规划者（PLAN_KIND，前沿模型）决定一个任务要不要计划并起草它。写手把任务写进
# $REVIEW_DIR/plan-request.md 后运行；3 = 规划中再运行续等；0 = 已交付，stdout 是 plan.md 的路径；
# 2 = 未配置规划者或工作区未提交；4 = 规划者卡住或停下。规划者自己提交计划并走完计划评审。
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
: "${REVIEW_POLL:=10}"          # 等哨兵时的轮询间隔（秒）；测试用，一般不改
: "${REVIEW_PLAN_PATHS:=}"   # 可选：计划/设计文档的路径模式，空格分隔；路由时这些路径先按 kind: plan 送审
: "${REVIEW_RULE_PATHS=AGENTS.md CLAUDE.md docs/reviewer-brief.md .review-map}"   # 规则文件：按计划文档路由与校验；置空关闭
: "${REVIEW_BRIEF=docs/reviewer-brief.md}"        # 评审方简报；缺失或过期都 exit 7；置空关闭这道门
: "${REVIEW_BRIEF_MAX_COMMITS:=50}"                # 简报 verified-at 之后累计超过这么多提交视为过期
: "${REVIEW_MAP=.review-map}"                      # 风险图（仓库内，规则文件）；置空或不存在则所有代码路径交评审方 triage
: "${REVIEW_ACCUM_COMMITS:=20}"                    # 上次评审以来累计超过这么多提交，不问评审方直接 REVIEW
: "${REVIEW_ACCUM_LINES:=2000}"                    # 同上，按改动行数
: "${REVIEW_WAKE:=0}"              # 1 = 派发后不在前台等：fork 一个只盯这次的进程，把回合交回给人
: "${REVIEW_WAKE_MAX:=3600}"       # 那个进程最长活多久（秒）；到点自杀，不留孤儿
: "${REVIEW_WAKE_FORK:=1}"         # 0 = 只写标记不真的 fork；测试用，一般不改
: "${REVIEW_BOARD=review-board}"   # 退出时重新生成看板的命令；置空则不生成（测试用）
: "${REVIEW_AGENT_ARGS=}"          # 拉起评审方时透传给 agent 的参数，如 "--model claude-opus-5"
: "${PLAN_KIND=}"                  # 规划者 agent 类型；空则没有规划者，写手自己写计划
: "${PLAN_AGENT_ARGS=}"            # 拉起规划者时透传的参数

[ -d "${REVIEW_WT}" ] || { echo "ERROR: REVIEW_WT 不存在：${REVIEW_WT}（先 git worktree add）"; exit 2; }

DIR="${REVIEW_DIR}"; mkdir -p "${DIR}"

# 本次运行的全部输出留一份在 .last.out，退出码和时间写 .last：写手停下时看板直接显示脚本说了什么，
# 人不必去翻写手的终端。每次退出（不论退出码）都刷新看板：状态只在脚本退出时变化。看板是只读的派生视图。
# `plan` 模式（写手每 10 秒续等规划者）和规划者自己的 request-review 会同时跑：续等的输出单独放
# .last-plan.out，只在真的停下（不是 0/3）时才覆盖 .last，免得把规划者那次运行的记录冲掉。
LAST_OUT="${DIR}/.last.out"; [ "${1:-}" = plan ] && LAST_OUT="${DIR}/.last-plan.out"
# 唤醒进程（--wake）只是后台助手：不接管输出、不写 .last、不刷看板。那三样记的是写手
# 那一次运行说了什么，被后台进程覆盖的话看板会显示错的东西。
if [ "${1:-}" != --wake ]; then
: > "${LAST_OUT}"
exec > >(tee -a "${LAST_OUT}"); TEE_OUT=$!
exec 2> >(tee -a "${LAST_OUT}" >&2); TEE_ERR=$!
fi
on_exit() {
  local code=$?
  if [ "${LAST_OUT}" = "${DIR}/.last.out" ]; then
    printf '%s %s\n' "${code}" "$(date +%s)" > "${DIR}/.last"
  else
    case "${code}" in 0|3) ;; *) printf '%s %s\n' "${code}" "$(date +%s)" > "${DIR}/.last"; cp "${LAST_OUT}" "${DIR}/.last.out" 2>/dev/null;; esac
  fi
  exec 1>&- 2>&-; wait "${TEE_OUT}" "${TEE_ERR}" 2>/dev/null
  [ -n "${REVIEW_BOARD}" ] && command -v "${REVIEW_BOARD}" >/dev/null && "${REVIEW_BOARD}" --quiet >/dev/null 2>&1
  true
}
[ "${1:-}" = --wake ] || trap on_exit EXIT
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
WAKE_MARK="${DIR}/.wake"
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
  ls "${DIR}"/r*-findings.md >/dev/null 2>&1 || return 0   # 没有残留
  sha=$(cat "${CYCLE_SHA}" 2>/dev/null); : "${sha:=unknown}"
  out="${ARCHIVE_DIR}/${sha}.md"
  # 绝不覆盖：同名文件可能是写手手写并已提交的，覆盖会弄脏工作区且丢内容
  n=2; while [ -e "${out}" ]; do out="${ARCHIVE_DIR}/${sha}-${n}.md"; n=$((n + 1)); done
  {
    echo "# Review cycle @ ${sha}"
    echo
    echo "归档于 $(date -Iseconds)"
    if [ -f "${CYCLE_REQ}" ]; then
      echo; echo "## Request"; echo; cat "${CYCLE_REQ}"
    fi
    for n in 1 2 3 4 5; do
      for f in "${DIR}/r${n}-findings.md" "${DIR}/r${n}-responses.md" "${DIR}/r${n}-decision.md"; do
        [ -f "${f}" ] || continue
        echo; echo "## $(basename "${f}")"; echo; cat "${f}"
      done
    done
  } > "${out}"
  rm -f "${DIR}"/r*-findings.md "${DIR}"/r*-responses.md "${DIR}"/r*-decision.md "${DIR}"/.r*.sent "${CYCLE_REQ}" "${CYCLE_SHA}"
  echo "NOTE: 上一周期已归档到 ${out}，交接目录已清空。" >&2
}

# 忽略尾部空行，取最后一个非空行。$2 可指定哨兵词，默认 REVIEW-COMPLETE
sentinel_ok() {
  [ -f "$1" ] || return 1
  [ "$(grep -v '^[[:space:]]*$' "$1" | tail -1)" = "${2:-REVIEW-COMPLETE}" ]
}

# ---- 完成处理：记录的是被评审的 target，不是当前 HEAD（两者可能已不同）----
finish() {
  local elapsed sha nb
  rm -f "${WAKE_MARK}"     # 已经领到结果了，还在盯的进程下一轮自己退出
  elapsed=$(( $(date +%s) - START ))
  sha=$(git rev-parse --short "${TARGET:-HEAD}")
  # 同一 sha 同一轮只记一次：写手在写 responses 之前再跑一遍，只是再领一次路径
  grep -q "| ${sha} | round ${cur}/${cap} |" "${ARCHIVE_DIR}/timing.md" 2>/dev/null && { echo "${OUT}"; exit 0; }
  printf '%s | %s | round %s/%s | %ss | %s\n' \
    "$(date +%F)" "${sha}" "${cur}" "${cap}" "${elapsed}" "${kind:-code}" >> "${ARCHIVE_DIR}/timing.md"
  map_auto_upgrade
  # precision 半自动：脚本填 blocking 条数，误报数留问号给人改
  # 容忍格式漂移：允许 ##/###、列表符号、粗体包裹，分隔符可为 | 或 :
  nb=$(grep -icE '^[[:space:]]*[#*_ -]*F[0-9]+[[:space:]*_]*[|:][[:space:]*_]*blocking' "${OUT}" 2>/dev/null || true)
  printf '%s | %s | blocking %s | 误报 ?\n' "$(date +%F)" "${sha}" "${nb:-0}" \
    >> "${ARCHIVE_DIR}/precision.md"
  echo "${OUT}"
  exit 0
}

# ============================================================
# 传输层 —— herdr 只出现在这一段。换 tmux / 非交互只改这里。
# ============================================================

# 传输层按角色参数化：评审方在 REVIEW_WT 里、按 cwd 认；规划者在仓库目录里，和写手同目录，只能按名字认。
ROLE_LABEL="评审方"; AGENT_NAME=""; AGENT_ARGS="${REVIEW_AGENT_ARGS}"
agent_name() { printf '%s-%s' "$1" "$(basename "${REPO}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | cut -c1-24)"; }

# 按 cwd（配了 AGENT_NAME 再按名字）找 agent。输出 "pane_id kind"，找不到输出空。
# 找到多个视为异常（同一 worktree 不该有两个），返回 2。
transport_find() {
  local hits n
  hits=$(herdr agent list 2>/dev/null \
    | jq -r --arg wt "${REVIEW_WT}" --arg name "${AGENT_NAME}" \
        '.result.agents[]
         | select((.cwd // .foreground_cwd) == $wt and ($name == "" or .name == $name))
         | "\(.pane_id) \(.agent)"')
  n=$(printf '%s' "${hits}" | grep -c . || true)
  if [ "${n:-0}" -gt 1 ]; then
    printf '%s\n' "${hits}" >&2
    return 2
  fi
  printf '%s' "${hits}"
}

# 在 REVIEW_WT 里取得评审 pane；已有匹配 agent 就复用，否则启动。输出 pane_id。
# 优先复用上次创建过的 pane（记在 ${PANE_CACHE}），但 pane ID 不是持久身份：
# 不存在或已指向不匹配 agent 时废弃缓存，绝不操作那个 agent。
transport_spawn() {
  local pane="" name err split cached cached_agent="" cached_kind="" cached_cwd=""
  local process_info="" deadline ready_checks=0
  if [ -f "${PANE_CACHE}" ]; then
    cached=$(cat "${PANE_CACHE}")
    if [ -n "${cached}" ]; then
      if herdr pane get "${cached}" >/dev/null 2>&1; then
        pane="${cached}"
        cached_agent=$(herdr agent get "${pane}" 2>/dev/null) || cached_agent=""
        cached_kind=$(printf '%s' "${cached_agent}" | jq -r '.result.agent.agent // empty' 2>/dev/null)
        cached_cwd=$(printf '%s' "${cached_agent}" | jq -r '.result.agent.cwd // .result.agent.foreground_cwd // empty' 2>/dev/null)
        if [ -n "${cached_kind}" ]; then
          if [ "${cached_kind}" = "${REVIEW_KIND}" ] && [ "${cached_cwd}" = "${REVIEW_WT}" ]; then
            echo "NOTE: 缓存 pane ${pane} 已有 ${cached_kind} ${ROLE_LABEL}，直接复用。" >&2
            printf '%s' "${pane}"
            return 0
          fi
          echo "NOTE: 缓存 pane ${pane} 已指向其他 agent（kind=${cached_kind}, cwd=${cached_cwd:-unknown}），废弃缓存并新建；不会操作该 agent。" >&2
          rm -f "${PANE_CACHE}"
          pane=""
        else
          echo "NOTE: 复用上次创建的空 pane ${pane}" >&2
        fi
      else
        echo "NOTE: 缓存 pane ${cached} 已不存在，废弃缓存并新建。" >&2
        rm -f "${PANE_CACHE}"
      fi
    fi
  fi

  if [ -z "${pane}" ]; then
    # --current 让新 pane 挂在写手自己的 pane 旁边；省略目标 herdr 会用 UI 当前聚焦的 pane，
    # 那可能是人正在看的任何地方。脚本在 herdr 外运行时没有 HERDR_PANE_ID，退回旧行为。
    # shellcheck disable=SC2086
    split=$(herdr pane split ${HERDR_PANE_ID:+--current} --direction right --cwd "${REVIEW_WT}" --no-focus 2>&1) \
      || { echo "STOP: 无法创建 pane: ${split}" >&2; return 1; }
    pane=$(printf '%s' "${split}" | jq -r '.result.pane.pane_id // empty')
    [ -n "${pane}" ] || { echo "STOP: pane split 未返回 pane_id: ${split}" >&2; return 1; }
    printf '%s' "${pane}" > "${PANE_CACHE}"
  fi

  # login shell 会在启动脚本执行前短暂看似空闲；完整谓词须连续稳定 500ms。
  deadline=$(( $(date +%s) + 5 ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    process_info=$(herdr pane process-info --pane "${pane}" 2>&1) || true
    if printf '%s' "${process_info}" | jq -e --arg pane "${pane}" '
      .result.process_info as $p
      | ($p.foreground_processes // []) as $fg
      | $p.pane_id == $pane
        and ($p.shell_pid | type == "number")
        and $p.shell_pid > 0
        and $p.foreground_process_group_id == $p.shell_pid
        and ($fg | length) == 1
        and $fg[0].pid == $p.shell_pid
        and ($fg[0].name | type == "string")
        and ($fg[0].name | test("(^|[/\\\\])-?(sh|bash|dash|zsh|fish|ksh|mksh|csh|tcsh)(\\.exe)?$"; "i"))
    ' >/dev/null 2>&1; then
      ready_checks=$((ready_checks + 1))
      [ "${ready_checks}" -ge 11 ] && break
    else
      ready_checks=0
    fi
    sleep 0.05
  done
  if [ "${ready_checks}" -lt 11 ]; then
    echo "STOP: pane ${pane} 未在 5s 内连续 500ms 保持可用 shell；不会执行 agent start。" >&2
    echo "herdr 原始状态: ${process_info:-<empty>}" >&2
    return 1
  fi

  name="${AGENT_NAME:-$(agent_name rv)}"
  # shellcheck disable=SC2086
  err=$(herdr agent start "${name}" --kind "${REVIEW_KIND}" --pane "${pane}" \
          --timeout "${REVIEW_START_TIMEOUT}" ${AGENT_ARGS:+-- ${AGENT_ARGS}} 2>&1 >/dev/null)
  if [ -n "${err}" ]; then
    echo "STOP: 在 ${REVIEW_WT} 的 pane ${pane} 上启动 ${REVIEW_KIND} 失败。" >&2
    echo "herdr 原始返回: ${err}" >&2
    echo "排查: 该 pane 是否停在 shell 提示符? 手动进去跑一次 ${REVIEW_KIND} 看真实报错。" >&2
    echo "该 pane 已记入 ${PANE_CACHE}, 下次重试会复用它, 不会再新建。" >&2
    return 1
  fi
  printf '%s' "${pane}"
}

# 返回当前 reviewer 的规范 JSON；首次派发前保存稳定 terminal/session 身份。
transport_identity() {  # $1=pane_id
  local pane="$1" payload="" kind="" cwd="" terminal=""
  payload=$(herdr agent get "${pane}" 2>/dev/null) || payload=""
  kind=$(printf '%s' "${payload}" | jq -r '.result.agent.agent // empty' 2>/dev/null)
  cwd=$(printf '%s' "${payload}" | jq -r '.result.agent.cwd // .result.agent.foreground_cwd // empty' 2>/dev/null)
  terminal=$(printf '%s' "${payload}" | jq -r '.result.agent.terminal_id // empty' 2>/dev/null)
  if [ "${kind}" != "${REVIEW_KIND}" ] || [ "${cwd}" != "${REVIEW_WT}" ] || [ -z "${terminal}" ]; then
    echo "STOP: 无法确认 pane ${pane} 的${ROLE_LABEL}身份（kind=${kind:-unknown}, cwd=${cwd:-unknown}, terminal_id=${terminal:-missing}）。" >&2
    return 1
  fi
  printf '%s' "${payload}" | jq -cS '.result.agent'
}

# 已发送轮次只恢复保存的 reviewer；身份不存在或变化时 fail closed，绝不新建或重发。
transport_resume() {    # $1=pane_id  $2=terminal_id(legacy 可空)  $3=agent_session JSON(可空)
  local saved_pane="$1" saved_terminal="$2" saved_session="$3"
  local payload="" agent="" pane="" kind="" cwd="" session=""
  if [ -n "${saved_terminal}" ]; then
    payload=$(herdr agent list 2>/dev/null) || payload=""
    agent=$(printf '%s' "${payload}" | jq -cS --arg terminal "${saved_terminal}" \
      '.result.agents[] | select(.terminal_id == $terminal)' 2>/dev/null)
  else
    payload=$(herdr agent get "${saved_pane}" 2>/dev/null) || payload=""
    agent=$(printf '%s' "${payload}" | jq -cS '.result.agent // empty' 2>/dev/null)
  fi
  pane=$(printf '%s' "${agent}" | jq -r '.pane_id // empty' 2>/dev/null)
  kind=$(printf '%s' "${agent}" | jq -r '.agent // empty' 2>/dev/null)
  cwd=$(printf '%s' "${agent}" | jq -r '.cwd // .foreground_cwd // empty' 2>/dev/null)
  session=$(printf '%s' "${agent}" | jq -cS '.agent_session // empty' 2>/dev/null)
  if [ -z "${pane}" ] || [ "${kind}" != "${REVIEW_KIND}" ] || [ "${cwd}" != "${REVIEW_WT}" ] \
    || { [ -n "${saved_session}" ] && [ "${session}" != "${saved_session}" ]; }; then
    echo "STOP: 已发送的${ROLE_LABEL}不存在或身份已变化（pane=${saved_pane}, terminal_id=${saved_terminal:-legacy}）。" >&2
    echo "      不会创建第二个${ROLE_LABEL}，也不会重发 prompt；请你亲自确认当前状态。" >&2
    return 1
  fi
  printf '%s' "${pane}"
}

# 注入 prompt 并等评审方状态变为 working/blocked，那才是送达证据：herdr 在 agent 进程
# 出现后几秒就报 interactive_ready，但 Claude 自身初始化还没完，这段空窗里 prompt 会被
# 静默吞掉而命令仍返回成功（09-06 复现）。成功返回空；失败在 stdout 给出 herdr 的错误 JSON。
transport_dispatch() {   # $1=pane_id  $2=prompt
  { herdr agent prompt "$1" "$2" --wait --until working --until blocked \
      --timeout "${REVIEW_START_TIMEOUT}" >/dev/null; } 2>&1
}

# 等待交互 agent 进入可接收 prompt 的已就绪、非工作态。
transport_wait_ready() { # $1=pane_id
  local pane="$1" deadline payload="" ready="unknown" state="unknown"
  deadline=$(( $(date +%s) + (REVIEW_START_TIMEOUT + 999) / 1000 ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    payload=$(herdr agent get "${pane}" 2>/dev/null) || payload=""
    ready=$(printf '%s' "${payload}" | jq -r '.result.agent.interactive_ready // false' 2>/dev/null) || ready="false"
    state=$(printf '%s' "${payload}" | jq -r '.result.agent.agent_status // "unknown"' 2>/dev/null) || state="unknown"
    : "${ready:=false}" "${state:=unknown}"
    case "${state}" in
      idle|done)
        [ "${ready}" = "true" ] && return 0;;
      blocked)
        echo "STOP: ${ROLE_LABEL}在接收 prompt 前已 blocked（pane ${pane}），请你亲自查看。" >&2
        return 1;;
    esac
    sleep 1
  done
  echo "STOP: ${ROLE_LABEL}未在 ${REVIEW_START_TIMEOUT}ms 内进入可接收状态（pane ${pane}）。" >&2
  echo "      last: interactive_ready=${ready}, agent_status=${state}；期望 interactive_ready=true 且 agent_status=idle/done。" >&2
  return 1
}

# 查生命周期状态
transport_state() {      # $1=pane_id
  herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // empty'
}

# ============================================================

# 定位或拉起评审方，等它就绪，把评审 worktree reset 到 $1。输出 pane_id；失败返回 1（已打印 STOP）。
acquire_reviewer() {     # $1=target sha
  local found pane rkind
  if ! found=$(transport_find); then
    echo "STOP: ${REVIEW_WT} 里有多个 agent（见上）。同一个 worktree 只应有一个评审方。" >&2
    echo "      关掉多余的，或把它们移到别处，再重试。" >&2
    return 1
  fi
  if [ -n "${found}" ]; then
    pane=$(printf '%s' "${found}" | awk '{print $1}')
    rkind=$(printf '%s' "${found}" | awk '{print $2}')
    [ "${rkind}" = "${REVIEW_KIND}" ] || {
      echo "STOP: ${REVIEW_WT} 里跑的是 ${rkind}，期望 ${REVIEW_KIND}。请你确认那个 pane 里是什么。" >&2
      return 1
    }
  else
    echo "NOTE: ${REVIEW_WT} 里没有评审方，正在拉起 ${REVIEW_KIND} …" >&2
    pane=$(transport_spawn) || return 1
  fi
  transport_wait_ready "${pane}" || return 1
  git -C "${REVIEW_WT}" reset --hard "$1" -q \
    || { echo "STOP: 无法将评审 worktree reset 到 $1" >&2; return 1; }
  printf '%s' "${pane}"
}

# 注入 prompt 并写已发送标记（start、target、pane、terminal、session）。失败返回 1（已打印 STOP）。
# 送达以状态变化为准。herdr 报 stalled/timeout 时先核实状态：已在 working/blocked 就是
# 送达（herdr 有过 stalled 误报）；仍 idle 才重发一次；再失败就 fail closed，不写标记。
send_prompt() {          # $1=pane_id  $2=target sha  $3=sent file  $4=prompt
  local identity terminal session err code attempt st
  identity=$(transport_identity "$1") || return 1
  terminal=$(printf '%s' "${identity}" | jq -r '.terminal_id')
  session=$(printf '%s' "${identity}" | jq -cS '.agent_session // empty')
  for attempt in 1 2; do
    if err=$(transport_dispatch "$1" "$4"); then
      { date +%s; echo "$2"; echo "$1"; echo "${terminal}"; echo "${session}"; } > "$3"
      return 0
    fi
    code=$(printf '%s' "${err}" | jq -r '.error.code // empty' 2>/dev/null) || code=""
    : "${code:=unknown_error}"
    case "${code}" in agent_prompt_stalled|timeout) ;; *) break;; esac
    st=$(transport_state "$1")
    case "${st}" in
      working|blocked)
        { date +%s; echo "$2"; echo "$1"; echo "${terminal}"; echo "${session}"; } > "$3"
        return 0;;
    esac
    [ "${attempt}" -eq 1 ] && echo "NOTE: ${code}，${ROLE_LABEL}仍 ${st:-unknown}，prompt 未送达，重发一次（pane $1）。" >&2
  done
  case "${code}" in
    agent_blocked)
      echo "STOP: ${ROLE_LABEL}停在审批或提问对话框，未发送任何输入。" >&2
      echo "      请你亲自查看 pane $1，不要让 agent 代答。" >&2;;
    agent_not_found|agent_not_running)
      echo "STOP: ${ROLE_LABEL}在注入前消失了（pane $1）。重试一次本命令即可。" >&2;;
    agent_prompt_stalled|timeout)
      echo "STOP: ${code}，重发一次后${ROLE_LABEL}仍 ${st:-unknown}，请求未送达（pane $1）。" >&2
      echo "      未写 $3；请你亲自查看 pane，确认状态后再决定是否重试。" >&2;;
    *)
      echo "STOP: 注入失败：${err}" >&2;;
  esac
  return 1
}

# ---- 唤醒：派发之后不占着写手的前台 ----
# 写手的回合必须真的结束，人才能跟它说话。派发时 fork 一个只盯这一次的进程，它在哨兵齐了
# （或被盯的 agent 卡住、空转、超时）时把写手叫醒，叫完就退出 —— 没有常驻的东西。
# 它不做任何判断：判断全在写手重跑时的 request-review 里，这里只负责"该回去看了"。

# 记下写手自己的身份并 fork。认不出自己在哪个 pane（不在 herdr 里跑）就返回 1，退回前台等待。
fork_waker() {           # $1=哨兵文件 $2=哨兵词 $3=被盯的 pane
  local payload term sess pid
  [ "${REVIEW_WAKE}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ] || return 1
  if [ -f "${WAKE_MARK}" ]; then       # 已经有一个活着的，不重复 fork
    pid=$(sed -n '8p' "${WAKE_MARK}")
    case "${pid}" in [1-9]*) kill -0 "${pid}" 2>/dev/null && return 1;; esac
  fi
  payload=$(herdr agent get "${HERDR_PANE_ID}" 2>/dev/null) || return 1
  term=$(printf '%s' "${payload}" | jq -r '.result.agent.terminal_id // empty' 2>/dev/null)
  sess=$(printf '%s' "${payload}" | jq -r '.result.agent.agent_session.value // empty' 2>/dev/null)
  [ -n "${term}" ] || return 1
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "${HERDR_PANE_ID}" "${term}" "${sess}" \
    "${ROLE_LABEL}那边完成了或需要你查看：再次运行${RERUN_HINT:- request-review}。" > "${WAKE_MARK}"
  if [ "${REVIEW_WAKE_FORK}" = "1" ]; then
    nohup "${SELF}" --wake "${WAKE_MARK}" >/dev/null 2>&1 &
    printf '%s\n' "$!" >> "${WAKE_MARK}"
  else
    printf -- '-\n' >> "${WAKE_MARK}"
  fi
  return 0
}

# 只往身份核对通过、且已经闲下来的写手 pane 注入。核不准就什么都不做 —— 宁可让人自己跑一次，
# 也不能往一个不确定是谁的 agent 里打字。成功注入返回 0。
wake_writer() {          # $1=pane $2=terminal $3=session $4=话
  local payload term sess deadline
  deadline=$(( $(date +%s) + REVIEW_WAKE_MAX ))
  while :; do
    payload=$(herdr agent get "$1" 2>/dev/null) || return 1
    term=$(printf '%s' "${payload}" | jq -r '.result.agent.terminal_id // empty' 2>/dev/null)
    sess=$(printf '%s' "${payload}" | jq -r '.result.agent.agent_session.value // empty' 2>/dev/null)
    [ -n "${term}" ] && [ "${term}" = "$2" ] || return 1
    [ -z "$3" ] || [ "${sess}" = "$3" ] || return 1
    case "$(transport_state "$1")" in idle|done) transport_dispatch "$1" "$4" >/dev/null 2>&1; return 0;; esac
    [ "$(date +%s)" -lt "${deadline}" ] || return 1
    sleep "${REVIEW_POLL}"
  done
}

# 只盯这一次派发。标记没了（周期被放弃、或写手自己跑了一次领走了）就静默退出。
wake_loop() {            # $1=标记文件
  local mark="$1" file word watched deadline st idle=0
  file=$(sed -n '1p' "${mark}"); word=$(sed -n '2p' "${mark}"); watched=$(sed -n '3p' "${mark}")
  deadline=$(( $(date +%s) + REVIEW_WAKE_MAX ))
  while :; do
    [ -f "${mark}" ] || return 0
    sentinel_ok "${file}" "${word}" && break
    st=$(transport_state "${watched}")
    case "${st}" in
      blocked) break;;
      idle|done) idle=$((idle + 1)); [ "${idle}" -ge 2 ] && break;;
      *) idle=0;;
    esac
    [ "$(date +%s)" -lt "${deadline}" ] || break
    sleep "${REVIEW_POLL}"
  done
  wake_writer "$(sed -n '4p' "${mark}")" "$(sed -n '5p' "${mark}")" "$(sed -n '6p' "${mark}")" \
    "$(sed -n '7p' "${mark}")" && rm -f "${mark}"
}

# 等哨兵；期间评审方 blocked 则退出 4，超时退出 3。
# 评审方回到 idle 而哨兵还没出现，说明它这个回合已经结束却没交付（忘写结尾行、只回了
# 一句话、或根本没开始）：等满 REVIEW_WAIT 只会让写手反复续等。连续两次看到 idle 即退出 4。
wait_sentinel() {        # $1=file  $2=word  $3=pane_id
  local deadline st idle=0
  sentinel_ok "$1" "$2" && return 0
  if fork_waker "$1" "$2" "$3"; then
    echo "PENDING: 已派发给${ROLE_LABEL}，本回合到此为止。停下把话交回给人；那边完成时会有人叫你继续，不要反复重跑。"
    exit 3
  fi
  deadline=$(( $(date +%s) + REVIEW_WAIT ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    sleep "${REVIEW_POLL}"
    sentinel_ok "$1" "$2" && return 0
    st=$(transport_state "$3")
    case "${st}" in
      blocked)
        echo "STOP: ${ROLE_LABEL}进入 blocked（审批或提问对话框）。请你亲自查看 pane $3。"
        exit 4;;
      idle|done)
        idle=$((idle + 1))
        if [ "${idle}" -ge 2 ]; then
          echo "STOP: ${ROLE_LABEL}已空闲，但 $1 没有以 $2 结尾。它这轮没有交付，请你亲自查看 pane $3。"
          exit 4
        fi;;
      *) idle=0;;
    esac
  done
  echo "PENDING: 尚未完成（已等待 ${REVIEW_WAIT}s）。再次运行${RERUN_HINT:- request-review} 继续等待，不会重发 prompt。"
  exit 3
}

# 路径是否属于计划/规则文档：.review.conf 的 REVIEW_PLAN_PATHS / REVIEW_RULE_PATHS（shell case 匹配，* 可跨 /），
# 或风险图上等级为 plan 的行。
path_is_plan() {         # $1=path
  local pat; set -f
  for pat in ${REVIEW_PLAN_PATHS} ${REVIEW_RULE_PATHS}; do
    # shellcheck disable=SC2254
    case "$1" in ${pat}) set +f; return 0;; esac
  done
  set +f
  [ "$(map_level "$1")" = plan ]
}

# ---- 风险图：`模式  等级  # 理由`，等级 deep/review/light/plan/skip。----
# 模式：`**` 可跨目录，`*` 不跨（src/jbgen/* 只是顶层文件，新子包不会被它盖住）。命中多条时最长的模式生效。
map_file() { [ -n "${REVIEW_MAP}" ] && [ -f "${REPO}/${REVIEW_MAP}" ] && printf '%s' "${REPO}/${REVIEW_MAP}"; }

map_pat_re() {           # $1=模式 → 正则（纯 bash，避开 sed 方言）
  local p="$1" out="" c i
  for ((i = 0; i < ${#p}; i++)); do
    c="${p:i:1}"
    case "${c}" in
      '*') if [ "${p:i+1:1}" = '*' ]; then out+='.*'; i=$((i + 1)); else out+='[^/]*'; fi;;
      '.'|'^'|'$'|'+'|'?'|'('|')'|'{'|'}'|'|'|'['|']'|'\\') out+="\\${c}";;
      *) out+="${c}";;
    esac
  done
  printf '%s' "${out}"
}

map_level() {            # $1=path → 等级；没匹配到输出 unknown；没有图输出 nomap
  local f pat lvl re best="" best_len=0
  f=$(map_file) || { echo nomap; return; }
  while read -r pat lvl _; do
    case "${pat}" in ''|'#'*) continue;; esac
    re=$(map_pat_re "${pat}")
    [[ "$1" =~ ^${re}$ ]] && [ "${#pat}" -gt "${best_len}" ] && { best="${lvl}"; best_len=${#pat}; }
  done < "${f}"
  echo "${best:-unknown}"
}

level_rank() { case "$1" in deep) echo 4;; review) echo 3;; light) echo 2;; skip) echo 1;; *) echo 0;; esac; }

# 一组路径的最高等级；任一路径 unknown 则输出 unknown（要问评审方）。plan 路径不参与。
files_level() {          # stdin=paths
  local f l top=skip any=0 unknown=0
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    path_is_plan "${f}" && continue
    any=1; l=$(map_level "${f}")
    case "${l}" in nomap|unknown) unknown=1;; *) [ "$(level_rank "${l}")" -gt "$(level_rank "${top}")" ] && top="${l}";; esac
  done
  [ "${any}" -eq 1 ] || { echo skip; return; }
  [ "${unknown}" -eq 0 ] && echo "${top}" || echo unknown
}

# 周期结束时的自动升级：本轮 blocking 的 evidence 路径在图上低于 deep 就升到 deep。往严自动，往松要人。
map_auto_upgrade() {
  local f path lvl seen=""
  f=$(map_file) || return 0
  [ -f "${OUT}" ] || return 0
  # 取 blocking finding 块里的路径 token（file.ext 或 dir/file.ext，可带 :行号）
  while IFS= read -r path; do
    [ -n "${path}" ] || continue
    case " ${seen} " in *" ${path} "*) continue;; esac
    seen="${seen} ${path}"
    [ -e "${REPO}/${path}" ] || continue
    path_is_plan "${path}" && continue
    lvl=$(map_level "${path}")
    [ "${lvl}" = deep ] && continue
    printf '%-40s deep    # 自动升级：%s 第 %s 轮出阻断（原 %s）\n' "${path}" "$(git rev-parse --short "${TARGET:-HEAD}")" "${cur}" "${lvl}" >> "${f}"
    echo "NOTE: 风险图升级 ${path} → deep（原 ${lvl}），已写入 ${REVIEW_MAP}，随下次提交带上。" >&2
  done < <(awk '
    /^[[:space:]]*[#*_ -]*F[0-9]+[[:space:]*_]*[|:][[:space:]*_]*blocking/ {inb=1; next}
    /^[[:space:]]*[#*_ -]*F[0-9]+[[:space:]*_]*[|:]/ {inb=0}
    /^#/ {inb=0}
    inb {print}' "${OUT}" | grep -oE '(^|[^[:alnum:]_/.])((([[:alnum:]_.-]+/)+)?[[:alnum:]_.-]+\.(py|js|ts|go|rs|sh|json|yaml|yml|toml))' | sed -E 's/^[^[:alnum:]_/.]//' | sort -u)
}

# ---- 上次评审到哪：timing.md 每完成一轮写一行 `日期 | sha | round | 秒 | kind`。按种类各取最新一行。----
# 旧行没有 kind 列，按那个提交碰没碰计划路径推断。sha 不在 HEAD 历史里（rebase 过）视为没有。
commit_kind() {          # $1=sha → plan|code（按该提交自己的文件）
  local f plan=0 other=0
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    if path_is_plan "${f}"; then plan=1; else other=1; fi
  done < <(commit_files "$1")
  [ "${plan}" -eq 1 ] && [ "${other}" -eq 0 ] && echo plan || echo code
}

last_target() {          # $1=code|plan → 完整 sha，或空
  local line sha rk
  [ -f "${ARCHIVE_DIR}/timing.md" ] || return 0
  while IFS= read -r line; do
    sha=$(printf '%s' "${line}" | awk -F' [|] ' '{print $2}')
    rk=$(printf '%s' "${line}" | awk -F' [|] ' '{print $5}')
    [ -n "${sha}" ] || continue
    git rev-parse -q --verify "${sha}^{commit}" >/dev/null 2>&1 || continue
    [ -n "${rk}" ] || rk=$(commit_kind "${sha}")
    [ "${rk}" = "$1" ] || continue
    git merge-base --is-ancestor "${sha}" HEAD 2>/dev/null && git rev-parse "${sha}^{commit}"
    return 0
  done < <(awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' "${ARCHIVE_DIR}/timing.md")
}

# 脚本自己写的东西自己无视：docs/reviews 下全部，以及 .review-map 里只新增了“# 自动升级”行的改动。
# 它们不算工作区脏、不参与路由、不算改动，随写手下一次真实提交自然带走。
# drop_own 从 stdin 过滤路径；参数是 git diff 的范围（"A B" 为两提交之间，"HEAD" 为工作区对 HEAD，空则不查图）。
ARCHIVE_REL="docs/reviews"
map_only_auto() {        # .review-map 在给定范围内的改动是否只有新增的自动升级行
  [ -n "${REVIEW_MAP}" ] || return 1
  git diff "$@" -- "${REVIEW_MAP}" | grep -E '^[-+][^-+]' | grep -vqE '^\+.*# 自动升级' && return 1
  return 0
}
drop_own() {
  local f keep_map=1
  [ $# -eq 0 ] || ! map_only_auto "$@" || keep_map=0
  while IFS= read -r f; do
    case "${f}" in "${ARCHIVE_REL}"/*) continue;; esac
    [ "${f}" = "${REVIEW_MAP}" ] && [ "${keep_map}" -eq 0 ] && continue
    printf '%s\n' "${f}"
  done
}
tree_clean() { [ -z "$(git diff --name-only HEAD | drop_own HEAD)" ]; }
commit_files() {         # $1=sha → 该提交自己改的文件，已去掉脚本写的
  if git rev-parse -q --verify "$1^" >/dev/null 2>&1; then git diff --name-only "$1^" "$1" | drop_own "$1^" "$1"
  else git diff-tree --root --no-commit-id --name-only -r "$1" | drop_own; fi
}

# 范围内的改动文件 = 范围内每个提交各自改的文件之并集，但跳过人用 SKIP_REVIEW 放过的提交（记在 skipped.md）：
# 人的跳过是终审，不是推后，那些文件不该再把范围推给评审方。
range_files() {          # $1=base(可空) $2=head → 改动文件列表
  local c skipped
  skipped=$(awk -F' [|] ' '{print $2}' "${ARCHIVE_DIR}/skipped.md" 2>/dev/null | tr -d ' ' | tr '\n' ' ')
  for c in $(git rev-list ${1:+"$1.."}"$2"); do
    case " ${skipped} " in *" $(git rev-parse --short "${c}") "*) continue;; esac
    commit_files "${c}"
  done | sort -u
}

# ---- 简报门：评审方每轮都读 brief，没有 brief 它只能从零爬仓库，brief 过期评审就建立在错的地图上。----
# 缺失、verified-at 之后超过 REVIEW_BRIEF_MAX_COMMITS 个提交、或基线不在 HEAD 历史里，
# 都停下让写手先写/重写。这次提交本身改了 brief 时放行 —— 那正是重写提交，它按规则文件路由为 kind: plan 送审。
# 新仓库接入靠的就是这道门：herdsman-init 之后写手第一次跑就被要求写简报。
brief_gate() {
  local v n
  [ -n "${REVIEW_BRIEF}" ] || return 0
  git diff-tree --no-commit-id --name-only -r HEAD | grep -qx "${REVIEW_BRIEF}" && return 0
  if [ ! -f "${REPO}/${REVIEW_BRIEF}" ]; then
    echo "STOP: 还没有 ${REVIEW_BRIEF}，评审方没有项目简报无法有效评审或 triage。"
    echo "      先生成简报：用 ${HOME}/.config/review/brief-prompt.md 的提示词生成 ${REVIEW_BRIEF}，"
    echo "      第一行 verified at 写当前 HEAD；单独提交（不混其他文件）后再运行 request-review，"
    echo "      它会作为 kind: plan 送审，评审方核对简报与代码是否相符。"
    exit 7
  fi
  v=$(sed -n '1s/.*verified at:[[:space:]]*\([0-9a-f]\{7,40\}\).*/\1/p' "${REPO}/${REVIEW_BRIEF}")
  if [ -z "${v}" ]; then
    echo "STOP: ${REVIEW_BRIEF} 第一行没有 \`<!-- verified at: <sha> -->\`，无法判断新旧。"
  elif ! git rev-parse -q --verify "${v}^{commit}" >/dev/null || ! git merge-base --is-ancestor "${v}" HEAD; then
    echo "STOP: ${REVIEW_BRIEF} 的基线 ${v:0:7} 不在 HEAD 的历史里，简报无法核实。"
  else
    n=$(git rev-list --count "${v}..HEAD")
    # 只按提交数判过期。"deep 路径改过就过期"试过：每次改核心代码都会先被要求重写简报，不可行；
    # 简报是否还描述得对核心路径，由评审方在 deep 评审里判断（rubric 读序第 2 条）。
    [ "${n}" -le "${REVIEW_BRIEF_MAX_COMMITS}" ] && return 0
    echo "STOP: ${REVIEW_BRIEF} 自 ${v:0:7} 起已累计 ${n} 个提交（上限 ${REVIEW_BRIEF_MAX_COMMITS}），简报过期。"
  fi
  echo "      先重写简报：用 ${HOME}/.config/review/brief-prompt.md 的提示词重写 ${REVIEW_BRIEF}，"
  echo "      第一行 verified at 写当前 HEAD；单独提交（不混其他文件）后再运行 request-review，"
  echo "      它会作为 kind: plan 送审，评审方核对简报与代码是否相符。"
  exit 7
}

# ---- 路由：判定"上次评审以来"这段改动要不要评审、审多深。总是以 exit 结束。----
TRIAGE_OUT="${DIR}/triage.md"
TRIAGE_SENT="${DIR}/.triage.sent"
TRIAGE_MARK="${DIR}/.triage"     # 六行：sha / 判定 / 理由 / kind / base / level

# 记录判定并退出：SKIP 记入 self-closed.md 后 exit 0；REVIEW 打出 kind/level/base 供写手照抄，exit 6。
triage_conclude() {      # $1=sha  $2=REVIEW|SKIP  $3=谁判的  $4=理由  $5=kind  $6=base  $7=level
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$1" "$2" "$4" "${5:-code}" "${6:-}" "${7:-review}" > "${TRIAGE_MARK}"
  if [ "$2" = SKIP ]; then
    [ -f "${ARCHIVE_DIR}/self-closed.md" ] \
      || printf '# 未送审记录\n\n脚本判定不需评审的提交。escapes.md 出现漏网时回来查它是按什么放过去的。\n\n日期 | sha | 依据 | 理由\n' > "${ARCHIVE_DIR}/self-closed.md"
    printf '%s | %s | %s | %s\n' "$(date +%F)" "$(git rev-parse --short "$1")" "$3" "$4" >> "${ARCHIVE_DIR}/self-closed.md"
    echo "SKIP: $4"; exit 0
  fi
  triage_print_review "$4" "${5:-code}" "${6:-}" "${7:-review}"
}
# base 之后紧跟的、连续整段已豁免的提交里的最后一笔；没有则输出空。
# 豁免只让这些提交不再把范围推去评审，它们的改动仍在 base..target 的 diff 里 —— 脚本据此提示，
# 但不替人前移 base：往严自动、往松要人点头。
waived_prefix() {        # $1=base → 短 sha 或空
  local c last="" skipped
  [ -n "$1" ] || return 0
  skipped=$(awk -F' [|] ' '{print $2}' "${ARCHIVE_DIR}/skipped.md" 2>/dev/null | tr -d ' ' | tr '\n' ' ')
  [ -n "${skipped}" ] || return 0
  for c in $(git rev-list --reverse "$1..HEAD" 2>/dev/null); do
    case " ${skipped} " in
      *" $(git rev-parse --short "${c}") "*) last="${c}";;
      *) break;;
    esac
  done
  [ -n "${last}" ] && git rev-parse --short "${last}"
}

triage_print_review() {  # $1=理由 $2=kind $3=base $4=level
  local base adv
  base="${3:-$(git rev-parse HEAD~1 2>/dev/null || git rev-parse HEAD)}"
  echo "REVIEW: $1"
  echo "kind: $2"
  echo "level: $4"
  echo "base sha: ${base}   ← request.md 的 base sha 用这个"
  adv=$(waived_prefix "${base}")
  [ -z "${adv}" ] || echo "NOTE: base 之后紧跟的 $(git rev-list --count "${base}..${adv}") 笔已在 skipped.md 中豁免；要把它们排除在 diff 之外，base sha 改用 ${adv}" >&2
  exit 6
}

triage_head() {
  local head files f plan_hits verdict reason pane saved level
  local code_base plan_base ncommits nlines prev_sha prev_verdict prev_base new_text
  head=$(git rev-parse HEAD)
  tree_clean || { echo "ERROR: 工作区未提交。先提交，再运行 request-review 判定要不要评审"; exit 2; }
  brief_gate

  # 已对这个 HEAD 判过：直接复用，不再问评审方。上次判的是 SKIP 且之后只多了脚本自己写的记录，也复用，
  # 不再记一行。REVIEW 不跨提交复用 —— 评审做完后 timing 已把起点推过去，重新路由才是对的。
  if [ -f "${TRIAGE_MARK}" ] && { [ "$(sed -n '1p' "${TRIAGE_MARK}")" = "${head}" ] \
       || { [ "$(sed -n '2p' "${TRIAGE_MARK}")" = SKIP ] \
            && git merge-base --is-ancestor "$(sed -n '1p' "${TRIAGE_MARK}")" "${head}" 2>/dev/null \
            && [ -z "$(range_files "$(sed -n '1p' "${TRIAGE_MARK}")" "${head}")" ]; }; }; then
    verdict=$(sed -n '2p' "${TRIAGE_MARK}"); reason=$(sed -n '3p' "${TRIAGE_MARK}")
    if [ "${verdict}" = SKIP ]; then echo "SKIP: ${reason}（已记录）"; exit 0; fi
    triage_print_review "${reason}（已判定，写 ${REQ} 后再运行）" "$(sed -n '4p' "${TRIAGE_MARK}")" "$(sed -n '5p' "${TRIAGE_MARK}")" "$(sed -n '6p' "${TRIAGE_MARK}")"
  fi

  # 累积起点按种类各算：上次 code 评审的 target、上次 plan 评审的 target。没有就只看本提交。
  code_base=$(last_target code); plan_base=$(last_target plan)
  [ -n "${code_base}" ] || { code_base=$(git rev-parse -q --verify HEAD~1 2>/dev/null || true); echo "NOTE: 尚无可追溯的代码评审，只看本提交。" >&2; }
  [ -n "${plan_base}" ] || plan_base=$(git rev-parse -q --verify HEAD~1 2>/dev/null || true)

  # 1. 计划/规则文档：自上次 plan 评审起碰过就必审（kind: plan）
  plan_hits=""
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    path_is_plan "${f}" && plan_hits="${plan_hits}${f} "
  done < <(range_files "${plan_base}" "${head}")
  [ -z "${plan_hits}" ] || triage_conclude "${head}" REVIEW 脚本 "触及计划/规则文档（自 ${plan_base:0:7} 起）：${plan_hits}" plan "${plan_base}" review

  # 1.5 范围里只有脚本写的评审记录：不路由、不记录，直接结束
  [ -n "$(range_files "${code_base}" "${head}")" ] \
    || { echo "SKIP: 自 ${code_base:0:7} 起只有脚本写的评审记录，无需路由"; exit 0; }

  # 2. 代码范围：自上次 code 评审起。纯文本文件默认是状态记录、不参与判定，除非风险图明确把它标为 deep 或 review
  #    （README 之类出过阻断的文档）；light / skip / 图上没有的文本一律不算。
  files=""
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    case "${f}" in
      *.md|*.markdown|*.rst|*.txt)
        case "$(map_level "${f}")" in deep|review) files="${files}${f}"$'\n';; esac;;
      *) files="${files}${f}"$'\n';;
    esac
  done < <(range_files "${code_base}" "${head}")
  [ -n "${files}" ] || triage_conclude "${head}" SKIP 纯文本 "自 ${code_base:0:7} 起只改了 .md/.rst/.txt（风险图未要求审），视为状态记录"

  # 3. 风险图能定的直接定：全 skip → SKIP；有等级 → REVIEW 带等级；有没在图上的路径 → 往下问评审方
  level=$(printf '%s\n' "${files}" | files_level)
  case "${level}" in
    skip)  triage_conclude "${head}" SKIP 风险图 "自 ${code_base:0:7} 起改动的路径在风险图上全为 skip";;
    deep|review|light)
      triage_conclude "${head}" REVIEW 风险图 "自 ${code_base:0:7} 起 $(printf '%s\n' "${files}" | grep -c .) 个文件，最高等级 ${level}" code "${code_base}" "${level}";;
  esac

  # 4. 沿用：上次判 SKIP、起点没变、之后新增的提交全是纯文本 → 不再问
  if [ -f "${TRIAGE_MARK}" ]; then
    prev_sha=$(sed -n '1p' "${TRIAGE_MARK}"); prev_verdict=$(sed -n '2p' "${TRIAGE_MARK}"); prev_base=$(sed -n '5p' "${TRIAGE_MARK}")
    if [ "${prev_verdict}" = SKIP ] && [ "${prev_base}" = "${code_base}" ] \
       && git merge-base --is-ancestor "${prev_sha}" "${head}" 2>/dev/null; then
      new_text=1
      while IFS= read -r f; do
        [ -n "${f}" ] || continue
        case "${f}" in
          *.md|*.markdown|*.rst|*.txt) case "$(map_level "${f}")" in deep|review) new_text=0;; esac;;
          *) new_text=0;;
        esac
      done < <(range_files "${prev_sha}" "${head}")
      [ "${new_text}" -eq 0 ] || triage_conclude "${head}" SKIP 沿用 "自 ${prev_sha:0:7} 起只新增纯文本提交，沿用上次 SKIP" code "${code_base}"
    fi
  fi

  # 5. 累积上限：不问评审方直接审
  ncommits=$(git rev-list --count "${code_base:+${code_base}..}${head}" 2>/dev/null || echo 1)
  nlines=$(git diff --shortstat ${code_base:+"${code_base}"} "${head}" -- . ":(exclude)${ARCHIVE_REL}" 2>/dev/null | grep -oE '[0-9]+ (insertion|deletion)' | awk '{s+=$1} END{print s+0}')
  if [ "${ncommits}" -gt "${REVIEW_ACCUM_COMMITS}" ] || [ "${nlines:-0}" -gt "${REVIEW_ACCUM_LINES}" ]; then
    triage_conclude "${head}" REVIEW 脚本 "自 ${code_base:0:7} 起累积 ${ncommits} 个提交、${nlines:-0} 行改动，超过上限（${REVIEW_ACCUM_COMMITS} 提交 / ${REVIEW_ACCUM_LINES} 行）" code "${code_base}" review
  fi

  # 6. 交评审方判定整段。已发送且 sha 未变则续等；sha 变了则丢弃旧的重发。
  if [ -f "${TRIAGE_SENT}" ] && [ "$(sed -n '2p' "${TRIAGE_SENT}")" != "${head}" ]; then
    rm -f "${TRIAGE_SENT}" "${TRIAGE_OUT}"
  fi
  if [ -f "${TRIAGE_SENT}" ]; then
    saved=$(sed -n '3p' "${TRIAGE_SENT}")
    pane=$(transport_resume "${saved}" "$(sed -n '4p' "${TRIAGE_SENT}")" "$(sed -n '5p' "${TRIAGE_SENT}")") || exit 4
    echo "NOTE: triage 已发送，继续等待 reviewer ${pane}；不会重发 prompt。" >&2
  else
    rm -f "${TRIAGE_OUT}"
    pane=$(acquire_reviewer "${head}") || exit 4
    send_prompt "${pane}" "${head}" "${TRIAGE_SENT}" "Triage request.
Rubric: ${HOME}/.config/review/rubric.md
Range: ${code_base:-<root>}..${head}  (${ncommits} commits since the last code review)
Commits:
$(git log --format='  %h %s' "${code_base:+${code_base}..}${head}")
Unmapped paths (not in ${REVIEW_MAP:-the risk map}): $(printf '%s\n' "${files}" | while IFS= read -r f; do [ -n "${f}" ] || continue; path_is_plan "${f}" && continue; case "$(map_level "${f}")" in nomap|unknown) printf '%s ' "${f}";; esac; done)
Judge the whole range, not only the newest commit. Do not run tests, do not gather evidence.
Write to ${TRIAGE_OUT}: first line REVIEW or SKIP, optionally followed by a level (deep, review or light);
second line one sentence why; then optionally one line per unmapped path as 'map: <pattern> <level>';
last line TRIAGE-COMPLETE. Reply with only that path." || exit 4
  fi
  wait_sentinel "${TRIAGE_OUT}" TRIAGE-COMPLETE "${pane}"
  verdict=$(grep -v '^[[:space:]]*$' "${TRIAGE_OUT}" | sed -n '1p' | tr -d '*_#' | tr '[:lower:]' '[:upper:]')
  level=$(printf '%s' "${verdict}" | grep -oE 'DEEP|REVIEW|LIGHT' | tail -1 | tr '[:upper:]' '[:lower:]')
  verdict=$(printf '%s' "${verdict}" | grep -oE '^[[:space:]]*(REVIEW|SKIP)' | tr -d '[:space:]')
  reason=$(grep -v '^[[:space:]]*$' "${TRIAGE_OUT}" | sed -n '2p')
  grep -E '^[[:space:]]*map:' "${TRIAGE_OUT}" | sed 's/^[[:space:]]*map:[[:space:]]*/NOTE: 评审方建议加进风险图：/' >&2
  case "${verdict}" in
    SKIP)   triage_conclude "${head}" SKIP triage "${reason:-无理由}" code "${code_base}";;
    REVIEW) triage_conclude "${head}" REVIEW triage "${reason:-无理由}" code "${code_base}" "${level:-review}";;
    *) echo "STOP: triage 文件第一行不是 REVIEW 或 SKIP：${TRIAGE_OUT}"; exit 4;;
  esac
}

# ============================================================
# 规划者 —— request-review plan。写手把任务写进 plan-request.md，规划者（前沿模型）决定
# 直接做 / 短计划 / 完整计划，起草计划、单独提交、自己跑 request-review 走完计划评审，
# 然后把答复写进 plan.md（首行 PLAN: <路径> / DIRECT / STOP: <原因>，末行 PLAN-COMPLETE）。
# 规划者在仓库目录里工作，写手等待期间不碰工作区。这段不影响评审周期的任何逻辑。
# ============================================================
plan_prompt() {
  printf 'Plan request for %s.\nRead %s/.config/review/planner-prompt.md first, then %s.\nReviewer brief: %s\nHandoff dir: %s\nWrite your answer to %s with last line PLAN-COMPLETE. Reply with only that path.' \
    "$(basename "${REPO}")" "${HOME}" "${PREQ}" "${REPO}/${REVIEW_BRIEF:-docs/reviewer-brief.md}" "${DIR}" "${POUT}"
}
acquire_planner() {      # 定位或拉起规划者，输出 pane_id；失败返回 1（已打印 STOP）
  local found pane rkind
  if ! found=$(transport_find); then
    echo "STOP: 仓库里有多个叫 ${AGENT_NAME} 的 agent（见上）。关掉多余的再重试。" >&2; return 1
  fi
  if [ -n "${found}" ]; then
    pane=$(printf '%s' "${found}" | awk '{print $1}'); rkind=$(printf '%s' "${found}" | awk '{print $2}')
    [ "${rkind}" = "${REVIEW_KIND}" ] || { echo "STOP: ${AGENT_NAME} 是 ${rkind}，期望 ${REVIEW_KIND}。" >&2; return 1; }
  else
    echo "NOTE: 没有规划者，正在仓库目录里拉起 ${REVIEW_KIND} …" >&2
    pane=$(transport_spawn) || return 1
  fi
  transport_wait_ready "${pane}" || return 1
  printf '%s' "${pane}"
}
plan_deliver() {         # plan.md 已完成时的交付；返回 1 表示还没完成
  local first
  sentinel_ok "${POUT}" PLAN-COMPLETE || return 1
  first=$(sed -n '1p' "${POUT}")
  case "${first}" in
    STOP*) echo "STOP: 规划者停下了：${first#STOP:}"; echo "      详情见 ${POUT}，请你亲自查看 pane $(sed -n '3p' "${PSENT}")。"; exit 4;;
  esac
  tree_clean || { echo "STOP: 规划者交活了，但工作区还有未提交的改动。请你看一眼 pane $(sed -n '3p' "${PSENT}")，确认后再让写手继续。"; exit 4; }
  # 规划者只准动计划文件：派发时的 HEAD 到现在，去掉脚本记录后必须全是计划/规则路径
  base=$(sed -n '6p' "${PSENT}"); stray=""
  if [ -n "${base}" ] && git rev-parse -q --verify "${base}^{commit}" >/dev/null; then
    while IFS= read -r f; do
      [ -n "${f}" ] || continue
      path_is_plan "${f}" || stray="${stray}${f} "
    done < <(git diff --name-only "${base}" HEAD | drop_own "${base}" HEAD)
  fi
  if [ -n "${stray}" ]; then
    echo "STOP: 规划者改了计划以外的文件：${stray}"
    echo "      规划者只准写 docs/plans 下的计划。请你看一眼 pane $(sed -n '3p' "${PSENT}") 和这些提交，处理后再让写手继续。"; exit 4
  fi
  echo "${POUT}"; exit 0
}
if [ "${1:-}" = plan ]; then
  [ -n "${PLAN_KIND}" ] || { echo "ERROR: 未配置规划者（.review.conf 里 PLAN_KIND 为空）。这个项目由写手自己写计划。"; exit 2; }
  PREQ="${DIR}/plan-request.md"; PSENT="${DIR}/.plan.sent"; POUT="${DIR}/plan.md"
  [ -s "${PREQ}" ] || { echo "ERROR: 缺 ${PREQ}。把任务原话和已知约束写进去，再运行 request-review plan"; exit 2; }
  # 角色切换：传输层按这些全局变量工作
  REVIEW_WT="${REPO}"; REVIEW_KIND="${PLAN_KIND}"; PANE_CACHE="${DIR}/.plan-pane"
  ROLE_LABEL="规划者"; AGENT_NAME=$(agent_name pl); AGENT_ARGS="${PLAN_AGENT_ARGS}"; RERUN_HINT=" request-review plan"
  fp=$(shasum -a 256 < "${PREQ}" | cut -c1-40)
  # 请求内容变了 = 新请求，旧的发送记录与答复作废
  if [ -f "${PSENT}" ] && [ "$(sed -n '2p' "${PSENT}")" != "${fp}" ]; then rm -f "${PSENT}" "${POUT}"; fi
  [ -f "${PSENT}" ] && plan_deliver
  if [ -f "${PSENT}" ]; then
    pane=$(transport_resume "$(sed -n '3p' "${PSENT}")" "$(sed -n '4p' "${PSENT}")" "$(sed -n '5p' "${PSENT}")") || exit 4
    echo "NOTE: 规划请求已发送，继续等待规划者 ${pane}；不会重发。" >&2
  else
    tree_clean || { echo "ERROR: 工作区未提交。规划者要在你的提交之上写计划，先提交再请它。"; exit 2; }
    brief_gate   # 规划者读简报，之后送审也过这道门：简报过期就让写手先重写（exit 7），别让规划者卡在那
    rm -f "${POUT}"
    pane=$(acquire_planner) || exit 4
    send_prompt "${pane}" "${fp}" "${PSENT}" "$(plan_prompt)" || exit 4
    git rev-parse HEAD >> "${PSENT}"   # 第 6 行：派发时的 HEAD，交活时据此核对规划者只动了计划
  fi
  wait_sentinel "${POUT}" PLAN-COMPLETE "${pane}"
  plan_deliver
  exit 3
fi

# ---- 唤醒进程：由派发那次运行 fork 出来，只盯一次哨兵，叫醒写手后退出 ----
if [ "${1:-}" = --wake ]; then
  [ -f "${2:-}" ] || exit 0
  wake_loop "$2"; exit 0
fi

# ---- 豁免路径：SKIP_REVIEW 只能由人设置，写手不得自行设置 ----
# SKIP_REVIEW=1 免当前 HEAD 一笔；SKIP_REVIEW=<base>..<tip> 免该范围内的每一笔（git 规矩，不含 base）。
# 只往 skipped.md 追加，不派发、不归档、不过任何门 —— 工作区脏或简报过期时也能用。
# 只认这两种写法：裸 rev（如 SKIP_REVIEW=HEAD）会被 rev-list 展开成全部历史，不接受。
if [ "${SKIP_REVIEW:-0}" != "0" ]; then
  case "${SKIP_REVIEW}" in
    1)     skip_commits=$(git rev-parse HEAD);;
    *..*)  skip_commits=$(git rev-list "${SKIP_REVIEW}" 2>/dev/null) \
             || { echo "ERROR: SKIP_REVIEW=${SKIP_REVIEW} 不是本仓库的提交范围"; exit 2; }
           [ -n "${skip_commits}" ] \
             || { echo "ERROR: SKIP_REVIEW=${SKIP_REVIEW} 没匹配到提交（A..B 不含 A）"; exit 2; };;
    *)     echo "ERROR: SKIP_REVIEW 只能是 1（当前 HEAD 一笔）或 <base>..<tip>（一段范围），现在是 ${SKIP_REVIEW}"; exit 2;;
  esac
  n=0
  for c in ${skip_commits}; do
    printf '%s | %s | %s\n' "$(date +%F)" "$(git rev-parse --short "${c}")" "${1:-未填写原因}" \
      >> "${ARCHIVE_DIR}/skipped.md"
    n=$((n + 1))
  done
  echo "SKIPPED: ${n} 笔已记入 docs/reviews/skipped.md"; exit 0
fi

# ---- 路由：只有针对 HEAD 的 request，或仍未答复的第 2 轮之后，才是明确的评审请求 ----
# 第 n 轮的 findings 一旦有了 responses，这个周期就是结束的；留下的 request.md 不能让
# 后续提交被当成续等（会因 target 与 HEAD 不一致 exit 4），它们照常走 triage。
explicit=0
if [ -f "${REQ}" ]; then
  req_round=$(sed -n 's|^round:[[:space:]]*\([0-9]\{1,\}\)/.*|\1|p' "${REQ}" | tail -1)
  req_target=$(sed -n 's|^target sha:[[:space:]]*\([^[:space:]]\{1,\}\).*|\1|p' "${REQ}" | tail -1)
  if [ "${req_round:-1}" -gt 1 ] && [ ! -f "${DIR}/r${req_round}-responses.md" ]; then explicit=1
  elif [ -n "${req_target}" ] && [ "$(git rev-parse --verify -q "${req_target}^{commit}")" = "$(git rev-parse HEAD)" ]; then explicit=1
  fi
fi
[ "${explicit}" -eq 1 ] || triage_head

# ---- 前置条件 ----

parsed=$(sed -n 's|^round:[[:space:]]*\([0-9]\{1,\}\)/\([0-9]\{1,\}\).*|\1 \2|p' "${REQ}" | tail -1)
[ -n "${parsed}" ] || { echo "ERROR: ${REQ} 缺少或写错 round: n/cap 行"; exit 2; }
read -r cur cap <<< "${parsed}"
[ "${cur}" -le "${cap}" ] || {
  echo "STOP: 轮次上限 ${cap} 已到。出口只有三种：带着已知问题接受并记入本轮 findings 的 ## Backlog /"
  echo "      把该条 finding 升级给强模型直接写补丁 / 判定框定有误退回重写计划。交给人决定。"
  exit 5
}

# ---- 评审单元：kind 决定评审方执行哪套契约；base 决定它读哪段 diff ----
kind=$(sed -n 's|^kind:[[:space:]]*\([a-z]\{1,\}\).*|\1|p' "${REQ}" | tail -1)
case "${kind}" in
  code|plan) ;;
  "") echo "ERROR: ${REQ} 缺 kind: code|plan 行 —— 一个 request 只装一种产物"; exit 2;;
  *)  echo "ERROR: ${REQ} 的 kind 只能是 code 或 plan，现在是 ${kind}"; exit 2;;
esac

base=$(sed -n 's|^base sha:[[:space:]]*\([^[:space:]]\{1,\}\).*|\1|p' "${REQ}" | tail -1)
[ -n "${base}" ] || { echo "ERROR: ${REQ} 缺 base sha 行"; exit 2; }
base=$(git rev-parse --verify -q "${base}^{commit}") \
  || { echo "ERROR: base sha 不是本仓库的提交：$(sed -n 's|^base sha:[[:space:]]*||p' "${REQ}" | tail -1)"; exit 2; }
git merge-base --is-ancestor "${base}" HEAD \
  || { echo "ERROR: base sha ${base} 不是 HEAD 的祖先。base 必须是本次评审改动之前的提交"; exit 2; }

# 评审深度：request 的 level 行；没写就按风险图对 base..HEAD 取最高等级，图上没有就 review。
level=$(sed -n 's|^level:[[:space:]]*\([a-z]\{1,\}\).*|\1|p' "${REQ}" | tail -1)
case "${level}" in
  deep|review|light) ;;
  "") level=$(git diff --name-only "${base}" HEAD | files_level); case "${level}" in deep|review|light) ;; *) level=review;; esac;;
  *) echo "ERROR: ${REQ} 的 level 只能是 deep、review 或 light，现在是 ${level}"; exit 2;;
esac

# round 1 时 kind 跟着脚本的路由判定走：路由已对这个 HEAD 判过 REVIEW 的话，request 的 kind 必须照抄。
# 不再看 target 提交自己碰了什么文件 —— 范围评审里 target 只是最后一个提交，计划和代码各按自己的范围
# 分别送审（计划范围先审，之后代码范围仍包含那些提交），不需要靠单个提交的纯度来隔离。
# 人直接要求的评审（没有路由记录）kind 由人定。（round 2+ 范围已冻结，不再校验。）
if [ "${cur}" -eq 1 ] && [ -f "${TRIAGE_MARK}" ] \
   && [ "$(sed -n '1p' "${TRIAGE_MARK}")" = "$(git rev-parse HEAD)" ] && [ "$(sed -n '2p' "${TRIAGE_MARK}")" = REVIEW ]; then
  routed_kind=$(sed -n '4p' "${TRIAGE_MARK}")
  [ "${kind}" = "${routed_kind}" ] \
    || { echo "ERROR: request 的 kind 是 ${kind}，但脚本对这个 HEAD 的路由判定是 ${routed_kind}。kind 照抄 request-review 的输出。"; exit 2; }
fi

OUT="${DIR}/r${cur}-findings.md"
SENT="${DIR}/.r${cur}.sent"

# ---- 已完成但尚未领取的评审优先交付。HEAD 动过也不算新周期：写手往往先提交了别的东西
#      才回来领结果，把它当新周期会归档一份没人读过的 findings 再让评审方白审一遍。----
if [ -f "${SENT}" ] && sentinel_ok "${OUT}" && [ ! -f "${DIR}/r${cur}-responses.md" ]; then
  START=$(sed -n '1p' "${SENT}"); TARGET=$(sed -n '2p' "${SENT}")
  [ "${TARGET}" = "$(git rev-parse HEAD)" ] \
    || echo "NOTE: round ${cur} @ ${TARGET:0:7} 已完成且未处理，先交付它；HEAD 已是 $(git rev-parse --short HEAD)。" >&2
  finish
fi

# 只在即将派发时要求工作区干净。续等时 target 已钉在 .sent 里，而且脚本自己会弄脏
# 工作区（归档、timing、precision），再查一次只会把写手挡在已完成的评审外面。
if [ ! -f "${SENT}" ]; then
  tree_clean || { echo "ERROR: 工作区未提交。评审必须对着已提交的 sha，否则行号会漂、构建产物互踩"; exit 2; }
fi

# ---- 新周期开始：先归档上一周期，再记录本周期的 request 与 sha ----
if [ "${cur}" -eq 1 ]; then
  [ -f "${SENT}" ] || brief_gate
  current_target=$(git rev-parse HEAD)
  sent_target=$(sed -n '2p' "${SENT}" 2>/dev/null)
  if [ ! -f "${SENT}" ] || { [ -n "${sent_target}" ] && [ "${sent_target}" != "${current_target}" ]; }; then
    archive_previous_cycle
    cp "${REQ}" "${CYCLE_REQ}"
    git rev-parse --short HEAD > "${CYCLE_SHA}"
  fi
fi

# ---- 上一轮存在 reject 或把 blocking 标成 defer → 分歧不是缺陷，升级给人，不消耗轮次 ----
# 人的裁决记在 r<prev>-decision.md，一行一条：`F<n> uphold|overrule — 理由`
# （uphold = 写手的 reject/defer 成立；overrule = finding 成立，写手须改）。每个待裁决
# 的 id 都有裁决行才放行；周期、findings、responses 都不动，评审方在下一轮看到裁决路径。
prev=$((cur - 1)); PREV_RESP="${DIR}/r${prev}-responses.md"; PREV_DEC="${DIR}/r${prev}-decision.md"
if [ "${prev}" -ge 1 ] && [ -f "${PREV_RESP}" ]; then
  PREV_OUT="${DIR}/r${prev}-findings.md"; pending=""; undecided=""
  # 先验格式：下面的 reject/defer 检测只认行首顶格的 `F<n> accept|defer|reject`。写手把行写成
  # `- F1 reject`、`**F1** reject`、`F1: reject` 时会被当成没有 reject 静默放行，所以凡是
  # 看起来像回应却不合规范的行，以及同一编号出现两次，都在这里拦下。不要求逐条对应 findings：
  # 第 2 轮起写手只回应仍未关闭的编号是既有做法。
  drift=$(grep -iE '^[[:space:]]*[#*_>-]*[[:space:]]*\**F[0-9]+\**[[:space:]:|—-]*(accept|defer|reject)' "${PREV_RESP}" \
            | grep -viE '^[[:space:]]*F[0-9]+[[:space:]]+(accept|defer|reject)([[:space:]]|$)')
  dup=$(grep -ioE '^[[:space:]]*F[0-9]+[[:space:]]+(accept|defer|reject)([[:space:]]|$)' "${PREV_RESP}" \
          | grep -ioE 'F[0-9]+' | tr a-z A-Z | sort | uniq -d | tr '\n' ' ')
  if [ -n "${drift}${dup}" ]; then
    echo "ERROR: ${PREV_RESP} 有不合规范的回应行，reject/defer 检测无法识别，不进入下一轮："
    [ -n "${drift}" ] && printf '%s\n' "${drift}" | sed 's/^/       /'
    [ -n "${dup}" ] && echo "       重复编号：${dup% }"
    echo "       每条一行、行首顶格、编号只出现一次，不加列表符号或粗体：F<n> accept|defer|reject — 理由"
    exit 2
  fi
  for id in $(grep -ioE '^[[:space:]]*F[0-9]+[[:space:]]+reject' "${PREV_RESP}" | grep -ioE 'F[0-9]+'); do
    pending="${pending} ${id}(reject)"
  done
  for id in $(grep -ioE '^[[:space:]]*F[0-9]+[[:space:]]+defer' "${PREV_RESP}" | grep -ioE 'F[0-9]+'); do
    # 严重度行的容错规则与 finish 里的 precision 统计保持一致
    grep -qiE "^[[:space:]]*[#*_ -]*${id}[[:space:]*_]*[|:][[:space:]*_]*blocking" "${PREV_OUT}" 2>/dev/null \
      && pending="${pending} ${id}(blocking-defer)"
  done
  for item in ${pending}; do
    id="${item%%(*}"
    grep -qiE "^[[:space:]]*${id}[[:space:]]+(uphold|overrule)" "${PREV_DEC}" 2>/dev/null || undecided="${undecided} ${item}"
  done
  if [ -n "${undecided}" ]; then
    echo "STOP: round ${prev} 有待人工裁决的 finding，不进入下一轮：${undecided}"
    echo "      人裁决后逐条记入 ${PREV_DEC}（每行 F<n> uphold|overrule — 理由），再次运行即可继续本周期。"
    exit 5
  fi
fi

START=$(date +%s)

# ---- 已发送：只恢复保存的 reviewer 并续等；绝不再发现、创建或派发 ----
if [ -f "${SENT}" ]; then
  START=$(sed -n '1p' "${SENT}")
  saved_target=$(sed -n '2p' "${SENT}")
  saved_pane=$(sed -n '3p' "${SENT}")
  saved_terminal=$(sed -n '4p' "${SENT}")
  saved_session=$(sed -n '5p' "${SENT}")
  [ "${saved_target}" = "$(git rev-parse HEAD)" ] \
    || { echo "STOP: ${SENT} 的 target 与当前 HEAD 不一致，需人工确认。"; exit 4; }
  [ -n "${saved_pane}" ] || { echo "STOP: ${SENT} 缺保存的 reviewer pane，需人工确认。"; exit 4; }
  RPANE=$(transport_resume "${saved_pane}" "${saved_terminal}" "${saved_session}") || exit 4
  TARGET="${saved_target}"
  echo "NOTE: round ${cur} 已发送，继续等待 reviewer ${RPANE}；不会重发 prompt。" >&2
else
  # ---- 未发送：定位或拉起评审方，首次注入 ----
  rm -f "${OUT}"
  TARGET=$(git rev-parse HEAD)
  RPANE=$(acquire_reviewer "${TARGET}") || exit 4

  prev_block=""
  if [ "${prev}" -ge 1 ]; then
    prev_sha=$(sed -n '2p' "${DIR}/.r${prev}.sent" 2>/dev/null)
    prev_block="Previous findings: ${DIR}/r${prev}-findings.md
Previous responses: ${DIR}/r${prev}-responses.md
"
    [ -f "${PREV_DEC}" ] && prev_block="${prev_block}Previous decisions: ${PREV_DEC}
"
    prev_block="${prev_block}Previous target sha: ${prev_sha:-unknown}
"
  fi

  send_prompt "${RPANE}" "${TARGET}" "${SENT}" "Review request.
Rubric: ${HOME}/.config/review/rubric.md
Request: ${REQ}
Round: ${cur}/${cap}
Level: ${level}
Target sha: ${TARGET}
${prev_block}Write findings to ${OUT} and reply with only that path." || exit 4
fi

wait_sentinel "${OUT}" REVIEW-COMPLETE "${RPANE}"
finish
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

## Triage (when the injected prompt says "Triage request")
You decide whether the accumulated change since the last code review needs a
review, and how deep. The prompt gives you the range, its commit list, and
the paths the risk map does not cover — the script has already decided about
everything the map covers; you are asked only because of the unmapped paths.
Read the brief, then `git log --oneline <base>..<sha>` and `git diff <base> <sha>`
in your worktree. Judge the whole range: several small commits can add up to a
change none of them looks like alone. Do not run tests, do not gather evidence,
do not write findings. This should take a minute, not ten.

Answer REVIEW when any of these holds for the range:
- it touches a path or module the brief calls core, or could violate
  an invariant or frozen contract the brief lists
- it adds, changes or removes a public interface, CLI behavior, a data
  format crossing a module boundary, persisted state, a schema, a
  migration, or the meaning of a config option
- it touches auth, permissions, security, concurrency, transactions,
  idempotency, or destructive operations
- it moves responsibility between modules, changes cross-module data flow,
  or changes build, release, deploy or rollback behavior
- it deletes, weakens or rewrites an existing regression assertion, shared
  fixture, or acceptance baseline
- it visibly departs from a plan that was reviewed
- you cannot tell from the diff and the brief

Otherwise answer SKIP. File count, line count and file extension are not
reasons by themselves. A SKIP is a judgement you sign: the range is recorded
under your reason in docs/reviews/self-closed.md, and it stays in the next
range until a review covers it.

With REVIEW, name the level: `REVIEW deep` when the change could break an
invariant, a contract or persisted state; `REVIEW light` when it is confined
and a diff read suffices; plain `REVIEW` otherwise. For each unmapped path add
one line `map: <pattern> <level>` proposing where it belongs in the risk map;
the human decides whether to adopt it.

Write to the path given in the prompt: first line REVIEW / REVIEW deep /
REVIEW light / SKIP, second line one sentence why, then the optional map
lines, last line TRIAGE-COMPLETE. Reply with only that path.

## Levels (the injected prompt's Level line)
The level sets how much you must do, never how much you may find.
- deep   — run the request's checks and the tests under its test paths
           yourself; every blocking needs a reproducing command; read the
           callers of anything whose signature or semantics changed.
- review — read the diff and the code it touches; run checks when a claim
           depends on them; blocking needs file:line or a command.
- light  — read the diff; report blocking only, plus should when it is
           plainly visible; do not run tests; no Suspicions section needed.
A level below what the change deserves is a finding: say `level too low`
as the first line under "## Suspicions" with one sentence why, and continue
at the level you were given.

## Read order (for a review request)
1. <repo>/docs/reviewer-brief.md — project brief. Note its "verified at" sha.
2. git log --oneline --stat <brief-sha>..HEAD — only the delta since the brief.
   Staleness by commit count is enforced by the script before you are called;
   do not report it. If the delta touches paths the brief calls core, say so
   in one line at the top of your findings as context, not as a finding.
3. The request file at the absolute path given in the injected prompt.
   Its `kind:` line is `code` or `plan` and selects which contract below
   applies ("For code" or "For plans and documents"). Apply only that one.
   The prompt's `Level:` line (deep / review / light) sets the depth, see
   "Levels" above.
   Files of the other kind inside the diff are context: read them if you
   need them, but they get no findings under this request.
4. If Round > 1, read the previous round's two files, whose absolute paths are
   given in the injected prompt:
     - the previous findings file — this is where your finding ids come from
     - the previous responses file — the author's accept/reject/defer per id
   Assume you remember nothing from the previous round. These two files are the
   only record. If either is missing, stop and say so.
5. The artifact at the target sha. For `kind: code` that is the diff from
   the request's base sha to the target sha; for `kind: plan` it is the
   named document in full. In Round > 1 also read the diff between the
   previous round's target sha and this one — that is what the author
   changed in response.

If the target sha or any path in the request does not exist, stop and say so.
Do not proceed on a request you cannot verify.

## Output contract
Write everything to the absolute findings path given in the injected prompt.
Reply with only that file path. Never paste findings into the terminal.
After the findings, add a "## 过程" section of 3–5 plain lines: what you read, what you
ran and what it returned, what you did not check. No findings there; it is for the human
reading the board, and it is archived with the round.
End the file with a single line: REVIEW-COMPLETE

## Finding format
Stable ids assigned in round 1, never renumbered.

F<n> | blocking | should | nit
claim:    one sentence
evidence: file:line, or a command that reproduces it
fix-hint: optional, one sentence, no patches

A finding with no evidence goes under "## Suspicions" and is never blocking.

## Severity
blocking = incorrect, unsafe, or contradicts the stated plan/scope.
should   = real but deferrable. nit = style/taste.
Beyond round 2, only blocking findings can cause another round.
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
    - a "Previous decisions" file is given and lists the id as uphold -> the
      human sided with the author: report "upheld" and nothing else, do not
      re-raise it. Listed as overrule -> the human sided with you: verify the
      fix as if the author had accepted.
    - author deferred (allowed for should/nit only) -> report "deferred" and
      nothing else. It is archived as backlog; do not verify or argue.
  New unrelated issues go to "## Backlog", never into this cycle.

Round 2 is required whenever the author changed the artifact in response to
ANY accepted finding, not only blocking ones. An accepted should/nit fix can
break something the original finding never touched.

## For code (kind: code)
Every blocking finding needs a reproducing command or a failing test name.
If the request names relevant test paths, run those first.

## For the reviewer brief (kind: plan, artifact is docs/reviewer-brief.md)
The brief is the map you read every round; this review checks the map
against the territory. Same output sections as for plans, plus:
- "verified at" must be the parent of the target sha. Otherwise -> blocking.
- Every path under "核心路径" must exist. Check each against
  `git log --oneline --stat <verified-sha>~50..` and the import graph:
  a directory many modules import, or one fixed repeatedly, that the
  brief omits -> should. A listed path that nothing depends on and that
  was never fixed -> nit, and ask for the reason.
- Every test / lint / typecheck command the brief states: run it once,
  with a 5-minute cap. Past the cap, stop it and record how far it got
  and whether anything failed; that is not a finding. A command that
  does not exist or does not start -> blocking (the brief claims a check
  it does not have). A failure the brief calls GREEN -> blocking.
- Every invariant or frozen contract the brief states: point at the code
  that enforces it. None found -> should.
- Do not rewrite the brief and do not propose wording; findings only.

## For plans and documents (kind: plan)
Required sections:
  "## Missing"        — what the plan omits
  "## Failure modes"  — what makes this plan fail in practice
  "## Unmatched"      — join the plan's exit criteria and acceptance items
                        against its own steps; list ONLY what does not match.
                        No step discharges it                    -> blocking
                        Nothing could ever discharge it, and
                        acceptance depends on it                 -> blocking
                        Asserts a number or judgement nobody can
                        recompute                                -> should,
                        and require it attributed, not asserted
                        Items the plan itself labels subjective or
                        descriptive are not findings.
  "## Restated facts" — every figure, status and identity the artifact copies
                        from an upstream document, diffed against that
                        document with line numbers. List only mismatches.
                        Mismatch -> blocking.
```

### 5.4 常驻指令（追加到 `<repo>/AGENTS.md` 或 `CLAUDE.md`）

评审方也在同一 repo，会读到同一份文件，标题必须写明适用对象。

````markdown

## Applies to the implementing agent only

### 评审路由（你不做判断，脚本和评审方做）
每次提交后运行 request-review。没有针对 HEAD 的 request.md 时，它判定**上次评审以来的全部改动**
要不要评审、审多深：只改 .md/.rst/.txt 的直接跳过；触及 REVIEW_PLAN_PATHS 或规则文件
（AGENTS.md、CLAUDE.md、docs/reviewer-brief.md、.review-map）的直接要求评审（kind: plan）；其余按仓库里的
风险图 `.review-map` 取等级，图上没有的路径才交给评审方 triage（只读 diff 和 reviewer-brief，
不跑测试，约一分钟）。SKIP 不是终审：那段改动留在下一次的范围里。按退出码办：
- 0 且输出 `SKIP: …` → 结束，已记入 docs/reviews/self-closed.md
- 6 且输出 `REVIEW: …` → 输出还有 `kind:`、`level:`、`base sha:` 三行，**照抄**进 request.md
  （target sha 为 HEAD），再次运行进入评审周期。base 是上次评审的 target，不是紧邻的前一个提交
- 3 → 再次运行继续等待

人明确要求评审时，直接写 request.md 运行，不经 triage。你可以随时主动请求评审；
你不得推翻 REVIEW，不得跳过 request-review 就结束含代码的任务。
相关检查因本次改动失败时，任务尚未完成：先修复，不得用评审代替验证。
你不得设置 SKIP_REVIEW —— 该变量只由人设置。

### 计划由规划者写（项目配了 PLAN_KIND 时；你自己就是规划者时本节不适用）
收到任务先查 docs/plans/ 里有没有已批准的计划覆盖它。有，照计划做。没有或不确定，
不要自己起草：把任务原话和你知道的约束写进 $REVIEW_DIR/plan-request.md，运行
`request-review plan`，按退出码办：
- 3 → 看输出第一行：写着「已派发」就停下，把那句原样报告给人，**不要重跑** —— 规划者
      交活时会有人叫你继续，被叫醒后再运行一次即可。没写「已派发」就是还在等，
      再次运行续等。两种情况都不改任何文件、不提交、不运行别的 request-review
- 0 → 读它输出的 plan.md：首行 `PLAN: <路径>` 就照那份计划做（它已评审闭合）；
      `DIRECT` 就按后面几行的边界直接做
- 2 / 4 → 停下，把输出原样报告给人
规划者会在你的工作区里提交计划，所以请它之前工作区必须干净。已有计划里的进度表、
状态行、决策记录仍由你自己改，那是记账不是设计。项目没配 PLAN_KIND 时这一节不适用，
计划由你自己写。

### 评审单元（送审前先切 commit）
一个 request 只装一种产物，由 request.md 的 `kind:` 声明，评审方据此只执行一套契约：
- `code`：代码及其直接相关的测试、docstring
- `plan`：用于约束后续实施或验收的计划或设计文档

状态记录——进度摘要、plan 状态、README 指针、Decision Board、reviewer brief 标记
之类——单独 commit，不得与 code 或 plan 同一 commit；纯文本的会被脚本直接跳过。
一个任务同时产出代码和计划时，各自一个 commit、各自一个评审周期。
`base sha` 用 request-review 输出里给的那个（上次评审的 target）；脚本会校验它是 HEAD 的祖先，
kind 也照抄，脚本会核对它与自己的判定一致，不符则 exit 2。不看单个提交碰了什么文件：计划范围先审，代码范围随后。

### 评审周期（triage 判 REVIEW 或人要求评审之后）
1. 提交产物（工作区必须干净）
2. 写 $REVIEW_DIR/request.md，含 kind、target sha（= HEAD）与 round: n/cap；sha 与路径必须真实
3. 运行 request-review，按退出码处理：
   0 → 读它输出的路径。对每条 finding 写一行 accept、defer 或 reject 加一句理由，
       写入同目录 r<n>-responses.md，**然后**才改代码。
       accept = 本轮改；defer = 承认但本轮不改，只限 should / nit，随本轮归档进 Backlog；
       reject = 不同意，交人裁决。blocking 只能 accept 或 reject。
       只要有任何 accepted finding 导致 artifact 改动，就必须再开一轮验证，
       不限于 blocking；没有 accepted finding 或 artifact 未改动时不开新轮，
       全部 defer 即一轮结束。
       should / nit 仍留在本轮 findings，随 docs/reviews/<sha>.md 归档，
       不单独立文件。
   3 → 看输出第一行：写着「已派发」就停下，把那句原样报告给人，**不要重跑** ——
       评审方交活时会有人叫你继续，被叫醒后再运行一次就能领到 findings。
       没写「已派发」就是还在等，再次运行 request-review 继续等待。
   2 / 4 / 5 → 停下，把输出原样报告给人。
       5 因 reject 或 blocking defer 停下时：人裁决后，把裁决逐字记入同目录
       r<n>-decision.md（每行 `F<n> uphold — 理由` 或 `F<n> overrule — 理由`，
       uphold = 你的 reject/defer 成立，overrule = finding 成立、你须改），再次运行
       即在本周期继续下一轮，不重置、不消耗轮次。裁决只能来自人；没有人的话不得写此文件。
   7 → 评审方简报缺失或过期。按输出提示，用 ~/.config/review/brief-prompt.md 的提示词生成或重写
       docs/reviewer-brief.md（第一行 verified at 写当前 HEAD），**单独提交**，再次运行；
       该提交会作为 kind: plan 送审，评审方核对简报与代码是否相符。不要把简报和代码混在一个提交里。
   其他退出码 → 脚本崩溃，同样停下原样报告，不要重试。

### request.md 格式
```
artifact:      <被评审的路径或路径集合，不写清单式描述>
kind:          <code 或 plan>
level:         <deep、review 或 light；照抄 request-review 的输出>
base sha:      <照抄 request-review 的输出：上次评审的 target>
target sha:    <本次提交>
round:         1/3
out of scope:  <本次明确不做的>
risk areas:    <自我声明的风险点>
test paths:    <相关测试目录，填了能显著缩短评审时间>
checks:        <确定性检查命令，如 npm run lint && npm run typecheck>
```
只放事实与自我声明的风险点，不放辩解。

### responses 文件格式
一行一条，行首顶格，不加标题、列表符号或粗体：

F1 accept — 一句理由
F2 defer — 一句理由
F3 reject — 一句理由

脚本只认 `^F<n> accept|defer|reject`；写成列表、粗体或冒号分隔的回应行会被拦下（exit 2
并列出那些行），改成上面的格式后再次运行即可，不必报告给人。

### 你不得做的事
- 不得修改任何 finding 的严重度。不同意就写 reject，交给人裁决。
  严重度由评审方定 —— 这是轮次机制成立的前提。
- 不要重试退出码 4 的注入，也不要用任何其它方式操作评审 pane 或规划者 pane
- 不要替评审方回答审批或提问对话框
- 不要关闭不是自己创建的 pane，不要运行 herdr server stop
- 不要修改 rubric、.review.conf、.review-map、或本文件中的评审规则。脚本自己会往 .review-map
  追加升级行，随下次提交带上即可；不要 checkout 或 stash 掉脚本写进 docs/reviews 或 .review-map 的内容
- 不要手写或提前创建 docs/reviews/<sha>.md —— 归档由脚本在下一周期开始时自动生成，
  手写的会被视为已有文件，脚本改写到 <sha>-2.md，留下两份

### 上限
计划与文档 2 轮，代码 3 轮；若最后一轮报出 regressed，允许为验证该修复再加一轮。
````

### 5.5 `$REVIEW_DIR/request.md`（写手每轮改写）

```markdown
artifact:      docs/plan-auth.md
kind:          plan
level:         review
base sha:      1a2b3c4
target sha:    3f9a1c2
round:         1/3
out of scope:  数据库迁移、前端改动
risk areas:    token 刷新的并发路径；错误分支的回滚语义
test paths:    tests/auth/
checks:        npm run lint && npm run typecheck
```

只放事实与自我声明的风险点，**不放辩解** —— 转述权的限制就落在这个模板上。

`round:`、`kind:`、`base sha:` 三行是脚本解析的：`round` 决定轮次；`kind` 只能是 `code` 或 `plan`，评审方据此只执行 rubric 里对应的一套契约；`base sha` 必须是 HEAD 的祖先，评审方从 `base..target` 圈定读什么。三者缺一或不合法 exit 2。

`artifact:` 写路径或路径集合，不写「runner、addendum、tests、summary…」这种清单式描述 —— 清单越长，评审方越只能把 target 下相关的东西全翻一遍。

**sha 和路径必须真实** —— 评审方会自行核验（实测中它会先 `ls` 再决定是否执行），写错会被直接拒绝。

`test paths` 填了能显著缩短评审时间。

### 5.6 `$REVIEW_DIR/r<n>-responses.md`（写手写）

```
F1 accept — 漏了并发路径，已加锁，fix 3f9a1c2
F2 reject — 该行为在 request 中声明为 out-of-scope
F3 accept — 已补测试 test_token_refresh_race
F4 defer — 命名问题成立，但本轮不改，留 Backlog
```

每条一行、行首顶格、编号只出现一次。脚本只认这个格式：写成 `- F1 reject` 或 `**F1** reject` 的行会在下一次调用时 exit 2 并被逐行列出，写手改正后再运行；不拦的话那条 reject 会被当成不存在直接进下一轮。第 2 轮起只回应仍未关闭的编号是允许的。

`defer` 只允许用于 should / nit：承认 finding 成立，本轮不改，随本周期归档进 Backlog，不触发新一轮。blocking 写 defer 会在下一次调用时 exit 5 交给你 —— 跟 reject 的拦截点一样。你裁决后写手把结论记入同目录 `r<n>-decision.md`（每行 `F<n> uphold — 理由` 或 `F<n> overrule — 理由`），再运行就在本周期继续下一轮：findings、responses 不动，不消耗轮次；评审方会在 prompt 里拿到裁决文件路径，upheld 的不再提，overruled 的按 accept 验证。这个选项存在的原因：没有它，写手会把所有 should / nit 全 accept 全改，于是零 blocking 的周期也要买一整轮验证。

### 5.7 `~/.local/bin/review-board`

```python
#!/usr/bin/env python3
"""review-board —— 评审流程的只读看板。

扫所有配了 .review.conf 的仓库，从交接目录（REVIEW_DIR）和归档（docs/reviews）生成一个
静态 HTML，写到 ~/.review/board.html。不存任何自己的状态，不接 agent，刷新等于重跑。

用法:
  review-board            生成
  review-board --open     生成后用浏览器打开
  review-board --quiet    生成，不打印路径（request-review 退出时调用）
  review-board --out P    写到 P
  review-board --projects F   只看 F 里列出的仓库（一行一个），不做默认发现；测试用

项目发现: ~/Developer/personal_projs/*/.review.conf；另可在 ~/.review/projects 里一行一个仓库路径。
"""
import glob
import html
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime

PROJ_GLOB = os.path.expanduser("~/Developer/personal_projs/*/.review.conf")
HERDR = os.environ.get("HERDR_BIN_PATH", "herdr")
PROJ_LIST = os.path.expanduser("~/.review/projects")
DEFAULT_OUT = os.path.expanduser("~/.review/board.html")
STAT_FILES = {"precision.md", "self-closed.md", "timing.md", "skipped.md", "escapes.md"}
DIFF_MAX_LINES = 2000
ARCHIVES_SHOWN = 5
SELF_CLOSED_SHOWN = 12
NOW = time.time()


# ============================================================ 读文件 / git
def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return None


def git(repo, *args):
    try:
        return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, timeout=30).stdout
    except Exception:
        return ""


def esc(s):
    return html.escape(s or "", quote=True)


def dur(seconds):
    if seconds is None or seconds < 0:
        return ""
    seconds = int(seconds)
    return f"{seconds // 60}m{seconds % 60:02d}s" if seconds >= 60 else f"{seconds}s"


def reviewer_status(pane):
    """问 herdr 评审方 pane 的 agent_status；herdr 不在、pane 不存在都返回 unknown。"""
    if not pane:
        return "unknown"
    try:
        out = subprocess.run([HERDR, "agent", "get", pane], capture_output=True, text=True, timeout=5).stdout
        m = re.search(r'"agent_status"\s*:\s*"([a-z]+)"', out)
        return m.group(1) if m else "unknown"
    except Exception:
        return "unknown"


_AGENTS = None


def herdr_agents():
    """`herdr agent list` 一次，全页共用；herdr 不在就是空列表。"""
    global _AGENTS
    if _AGENTS is None:
        try:
            out = subprocess.run([HERDR, "agent", "list"], capture_output=True, text=True, timeout=5).stdout
            _AGENTS = json.loads(out).get("result", {}).get("agents", []) or []
        except Exception:
            _AGENTS = []
    return _AGENTS


def pane_activity(pane):
    """pane 最后几行里那句「Working (47m · esc to interrupt)」；拿不到就空。只在 working 时问。"""
    try:
        out = subprocess.run([HERDR, "agent", "read", pane, "--lines", "15", "--format", "text"],
                             capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return ""
    for line in reversed(out.splitlines()):
        if "esc to interrupt" in line:
            line = re.sub(r'\s*[•·]\s*esc to interrupt', "", line).strip().lstrip("•·*✻✽✶✳✢⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏ ")
            return line[:80]
    return ""


def agents_of(repo, wt, reviewer_pane):
    """{"writer": info, "reviewer": info}：写手 = cwd 是仓库的 agent；评审方 = 派发时记下的 pane，或 cwd 是评审 worktree。
    info = {status, title, activity}；找不到的角色不出现。"""
    def real(x):
        return os.path.realpath(x) if x else ""
    out = {}
    for a in herdr_agents():
        cwd = real(a.get("cwd"))
        role = None
        if (a.get("name") or "").startswith("pl-") and cwd == real(repo):
            role = "planner"
        elif reviewer_pane and a.get("pane_id") == reviewer_pane or (wt and cwd == real(wt)):
            role = "reviewer"
        elif cwd == real(repo):
            role = "writer"
        if not role or role in out:
            continue
        st = a.get("agent_status") or "unknown"
        title = (a.get("terminal_title_stripped") or "").strip()
        if title == os.path.basename(repo):
            title = ""
        out[role] = {"status": st, "title": title, "pane": a.get("pane_id", ""), "kind": a.get("agent", ""),
                     "activity": pane_activity(a.get("pane_id", "")) if st == "working" else ""}
    return out


def ago(ts):
    if not ts:
        return ""
    d = int(NOW - ts)
    if d < 60:
        return f"{d}s"
    if d < 3600:
        return f"{d // 60}m"
    if d < 86400:
        return f"{d // 3600}h{(d % 3600) // 60:02d}m"
    return f"{d // 86400}d"


def sentinel_ok(text, word="REVIEW-COMPLETE"):
    if text is None:
        return False
    lines = [l for l in text.splitlines() if l.strip()]
    return bool(lines) and lines[-1].strip() == word


# ============================================================ 解析交接文件
def parse_conf(path):
    conf = {}
    for line in (read(path) or "").splitlines():
        m = re.match(r'\s*([A-Z_]+)=(.*)', line)
        if m:
            conf[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    return conf


def parse_request(text):
    req = {}
    for line in (text or "").splitlines():
        m = re.match(r'^([a-z ]+?):\s*(.*)$', line)
        if m:
            req[m.group(1).strip()] = m.group(2).strip()
    m = re.match(r'(\d+)\s*/\s*(\d+)', req.get("round", ""))
    req["_round"] = int(m.group(1)) if m else 1
    req["_cap"] = int(m.group(2)) if m else 0
    return req


FINDING_RE = re.compile(r'^[\s#*_-]*F(\d+)[\s*_]*[|:—-]+\s*(.*)$')
RESP_RE = re.compile(r'^\s*F(\d+)\s+(accept|defer|reject)\b\s*[—-]*\s*(.*)$', re.I)
DEC_RE = re.compile(r'^\s*F(\d+)\s+(uphold|overrule)\b\s*[—-]*\s*(.*)$', re.I)
SEVS = ("blocking", "should", "nit")
STATUSES = ("resolved", "not-resolved", "regressed", "upheld", "deferred", "disputed", "overruled")
FIELDS = {"claim": "claim", "evidence": "evidence", "fix-hint": "hint", "status": "status", "verdict": "status"}


def parse_findings(text):
    """{id: {sev, status, claim, evidence, hint}}，按出现顺序。
    头行 `F<n> | blocking`（第 2 轮起还有 `| resolved` 等），字段行 `claim: …`；
    旧格式把字段值写在标签下一行且可能多行，空行结束。"""
    out = {}
    cur = field = None
    for line in (text or "").splitlines():
        m = FINDING_RE.match(line)
        if m and not line.lstrip().startswith(("-", "*")):
            fid = "F" + m.group(1)
            cells = [c.strip().strip("*_ ") for c in re.split(r'\s*(?:[|]|→|->)\s*', m.group(2).replace("*", "")) if c.strip()]
            sev = status = ""
            for c in cells:
                cl = c.lower()
                if cl in SEVS:
                    sev = cl
                elif cl in STATUSES:
                    status = cl
                elif not sev and not status:
                    status = c
            cur = out.setdefault(fid, {"sev": sev, "status": status, "claim": "", "evidence": "", "hint": ""})
            if sev:
                cur["sev"] = sev
            if status:
                cur["status"] = status
            field = None
            continue
        if not cur:
            continue
        m2 = re.match(r'^\s*(claim|evidence|fix-hint|status|verdict)\s*:\s*(.*)$', line, re.I)
        if m2:
            field = FIELDS[m2.group(1).lower()]
            cur[field] = m2.group(2).strip()
        elif re.match(r'^#{1,6}\s', line) or re.match(r'^\s*F\d+\s*[|:]', line):
            cur = field = None
        elif field and line.strip():
            cur[field] = (cur[field] + " " + line.strip()).strip()
        elif line.strip() and not cur["claim"] and field is None:
            # 第 2 轮起评审方常写 `F1 — resolved` 后直接跟自由文本（作者接受：… 核实：…），没有标签；当 claim 收
            field = "claim"
            cur["claim"] = line.strip()
        elif not line.strip():
            field = None
    return out


def parse_lines(text, rx):
    out = {}
    for line in (text or "").splitlines():
        m = rx.match(line)
        if m:
            out["F" + m.group(1)] = (m.group(2).lower(), m.group(3).strip())
    return out


def parse_sent(text):
    ls = (text or "").splitlines()
    try:
        return {"start": int(ls[0]), "target": ls[1].strip(), "pane": ls[2].strip() if len(ls) > 2 else ""}
    except (IndexError, ValueError):
        return None


def parse_process(text):
    """findings 里评审方写的「过程」一节（读了什么、跑了什么、没查什么）：从 `## 过程` / `## Process` 到下一个标题或哨兵。"""
    lines, keep = [], False
    for line in (text or "").splitlines():
        if re.match(r'^#{1,6}\s*(过程|process|how i looked)\b', line.strip(), re.I):
            keep = True
            continue
        if keep and (re.match(r'^#{1,6}\s', line) or line.strip() == "REVIEW-COMPLETE"):
            break
        if keep:
            lines.append(line.rstrip())
    return "\n".join(lines).strip()


def load_rounds(d):
    rounds = []
    for n in range(1, 6):
        ft = read(f"{d}/r{n}-findings.md")
        rt = read(f"{d}/r{n}-responses.md")
        dt = read(f"{d}/r{n}-decision.md")
        st = parse_sent(read(f"{d}/.r{n}.sent"))
        if ft is None and rt is None and st is None:
            continue
        rounds.append({
            "n": n, "findings": parse_findings(ft), "done": sentinel_ok(ft), "process": parse_process(ft),
            "responses": parse_lines(rt, RESP_RE) if rt is not None else None,
            "decisions": parse_lines(dt, DEC_RE) if dt is not None else None,
            "sent": st, "t_findings": mtime(f"{d}/r{n}-findings.md"), "t_responses": mtime(f"{d}/r{n}-responses.md"),
        })
    return rounds


def pending_decisions(rnd):
    """上一轮 reject 与 blocking defer 里尚无裁决的 → [(fid, verb, sev, reason)]。与 request-review 的判据一致。"""
    out = []
    if not rnd or rnd["responses"] is None:
        return out
    dec = rnd["decisions"] or {}
    for fid, (verb, reason) in rnd["responses"].items():
        sev = rnd["findings"].get(fid, {}).get("sev", "")
        if (verb == "reject" or (verb == "defer" and sev == "blocking")) and fid not in dec:
            out.append((fid, verb, sev, reason))
    return out


# ============================================================ 项目状态
def watch_reviewer(p, pane, expecting, who="评审方"):
    """评审中 / triage 中 / 规划中时问一下对方在干什么。blocked 和 idle 都是它停了而没交付，等人去看 pane。"""
    st = reviewer_status(pane)
    p["reviewer"] = st
    if st == "blocked":
        p.update(needs_me=True, waiting="等你", state=p["state"] + f" · {who} blocked")
        p["human"].append(("stop", "", "blocked", "", f"{who}停在审批或提问对话框，去看 pane {pane}"))
    elif st in ("idle", "done"):
        p.update(needs_me=True, waiting="等你", state=p["state"] + f" · {who} idle")
        p["human"].append(("stop", "", "idle", "", f"{who}已空闲但 {expecting} 没交付，去看 pane {pane}"))
    elif st == "working":
        p["cycle_note"] += f"；{who} working"


EV_LOC_RE = re.compile(r'((?:[\w.-]+/)*[\w.-]+\.[A-Za-z0-9]+):(\d+)')


def linkify(text, repo):
    """evidence 里的 path:line 变成 zed://file/… 链接，点了直接到那一行。文本先转义，链接后拼。"""
    out, pos = [], 0
    for m in EV_LOC_RE.finditer(text or ""):
        out.append(esc(text[pos:m.start()]))
        out.append(f'<a class="loc" href="zed://file{esc(os.path.join(repo, m.group(1)))}:{m.group(2)}">{esc(m.group(0))}</a>')
        pos = m.end()
    out.append(esc((text or "")[pos:]))
    return "".join(out)


def last_run(d):
    """写手上次运行 request-review 的结果：.last 是「退出码 时间」，.last.out 是全部输出。
    只有停下的那几种退出码（2/4/5/7）值得显示；写手之后跑成功一次就自然消失。"""
    raw = (read(f"{d}/.last") or "").split()
    if len(raw) < 2 or raw[0] not in ("2", "4", "5", "7"):
        return None
    out = (read(f"{d}/.last.out") or "").strip()
    head = next((l for l in out.splitlines() if l.startswith(("ERROR", "STOP"))), out.splitlines()[0] if out else "")
    return {"code": raw[0], "ts": int(raw[1]), "head": head, "out": out}


def project_state(repo, conf):
    d = conf["REVIEW_DIR"]
    head = git(repo, "rev-parse", "HEAD").strip()
    req = parse_request(read(f"{d}/request.md"))
    cyc_req = parse_request(read(f"{d}/.cycle-request.md")) if os.path.exists(f"{d}/.cycle-request.md") else req
    rounds = load_rounds(d)
    p = {"name": os.path.basename(repo), "repo": repo, "dir": d, "head": head, "req": req, "cycle_req": cyc_req,
         "kind": conf.get("REVIEW_KIND", "claude"), "review_args": conf.get("REVIEW_AGENT_ARGS", ""),
         "plan_kind": conf.get("PLAN_KIND", ""), "plan_args": conf.get("PLAN_AGENT_ARGS", ""),
         "rounds": rounds, "state": "空闲", "since": None, "waiting": "", "needs_me": False,
         "human": [], "cycle_note": "", "closed": False, "reviewer": ""}
    cur = req.get("_round", 1)
    explicit = bool(req) and (req.get("target sha") == head or (cur > 1 and not os.path.exists(f"{d}/r{cur}-responses.md")))
    prev = next((r for r in rounds if r["n"] == cur - 1), None)
    this = next((r for r in rounds if r["n"] == cur), None)

    latest = max([mtime(f"{d}/{f}") or 0 for f in os.listdir(d)] or [0]) if os.path.isdir(d) else 0
    p["last_activity"] = latest
    p["accum"] = since_last_review(repo, conf)
    p["brief"] = brief_status(repo, conf)
    p["map"] = map_suggestions(repo)
    if explicit:
        pend = pending_decisions(prev)
        if this and this["sent"]:
            if this["done"]:
                if this["responses"] is None:
                    p.update(state="待写手回应", waiting="等写手", since=mtime(f"{d}/r{cur}-findings.md"),
                             cycle_note="findings 已完成，等写手写 responses")
                else:
                    accepted = any(v[0] == "accept" for v in this["responses"].values())
                    p.update(state="本轮已回应" if accepted else "已闭合", closed=True, since=mtime(f"{d}/r{cur}-responses.md"),
                             cycle_note="写手已回应，有 accepted 改动，等写手改完开下一轮" if accepted else "写手已回应，无 accepted 改动，周期到此结束")
            else:
                p.update(state="评审中", waiting="等评审方", since=this["sent"]["start"],
                         cycle_note="prompt 已送达，等评审方写 findings")
                watch_reviewer(p, this["sent"].get("pane"), f"r{cur}-findings.md")
        elif pend:
            p.update(state="待人裁决", waiting="等你", needs_me=True, since=mtime(f"{d}/r{cur - 1}-responses.md"),
                     human=[("decision", fid, verb, sev, reason) for fid, verb, sev, reason in pend],
                     cycle_note="写手" + "、".join(f"{ZH.get(v, v)}了 {f}" for f, v, _, _ in pend) + "，等人裁决")
        else:
            p.update(state="待派发", waiting="等写手", since=mtime(f"{d}/request.md"),
                     cycle_note=f"request 已写（round {req.get('round', '')}），等写手运行 request-review")
    else:
        tri = (read(f"{d}/.triage") or "").splitlines()
        tsent = parse_sent(read(f"{d}/.triage.sent"))
        tout = read(f"{d}/triage.md")
        if tri and tri[0].strip() == head:
            verdict = tri[1].strip() if len(tri) > 1 else "?"
            p.update(state=f"triage 已判 {verdict}", since=mtime(f"{d}/.triage"),
                     waiting="等写手" if verdict == "REVIEW" else "",
                     triage_reason=tri[2].strip() if len(tri) > 2 else "")
        elif tsent and tsent["target"] == head and not sentinel_ok(tout, "TRIAGE-COMPLETE"):
            p.update(state="triage 中", waiting="等评审方", since=tsent["start"])
            watch_reviewer(p, tsent.get("pane"), "triage.md")
        if rounds:
            p["closed"] = True
            p["cycle_note"] = "已闭合；下面的 Round 是它的最终结果"
    # 规划者：plan-request 已发出、plan.md 还没写完 → 规划中。规划者自己走的计划评审会以 explicit 周期出现在上面，
    # 这一行让人知道那个周期是规划的一部分。
    psent = parse_sent(read(f"{d}/.plan.sent"))
    if psent and not sentinel_ok(read(f"{d}/plan.md"), "PLAN-COMPLETE"):
        task = next((l.strip() for l in (read(f"{d}/plan-request.md") or "").splitlines() if l.strip()), "")
        p["planning"] = {"task": task, "since": psent["start"], "pane": psent.get("pane")}
        if not explicit:
            p.update(state="规划中", waiting="等规划者", since=psent["start"], cycle_note="任务已交规划者，等它决定要不要计划")
            watch_reviewer(p, psent.get("pane"), "plan.md", "规划者")
    pane = ((this or {}).get("sent") or {}).get("pane") if explicit else (parse_sent(read(f"{d}/.triage.sent")) or {}).get("pane")
    p["agents"] = agents_of(repo, conf.get("REVIEW_WT"), pane)
    p["last_run"] = last_run(d)
    return p


# ============================================================ 归档
def load_archives(repo):
    adir = f"{repo}/docs/reviews"
    timing = {}
    for line in (read(f"{adir}/timing.md") or "").splitlines():
        m = re.match(r'\S+ \| (\w+) \| round \d+/\d+ \| (\d+)s', line)
        if m:
            timing[m.group(1)] = timing.get(m.group(1), 0) + int(m.group(2))
    out = []
    for f in sorted(glob.glob(f"{adir}/*.md"), key=os.path.getmtime, reverse=True):
        if os.path.basename(f) in STAT_FILES:
            continue
        text = read(f) or ""
        m = re.match(r'# Review cycle @ (\S+)', text)
        if not m:
            continue
        sha = m.group(1)
        when = re.search(r'归档于 (\S+)', text)
        secs = dict(re.findall(r'^## (r\d+-\w+\.md)\n(.*?)(?=^## r\d+-\w+\.md\n|\Z)', text, re.S | re.M))
        reqm = re.search(r'^## Request\n(.*?)(?=^## )', text, re.S | re.M)
        req = parse_request(reqm.group(1) if reqm else "")
        rounds = []
        for n in range(1, 6):
            if f"r{n}-findings.md" in secs:
                rounds.append({"n": n, "findings": parse_findings(secs[f"r{n}-findings.md"]),
                               "responses": parse_lines(secs.get(f"r{n}-responses.md", ""), RESP_RE),
                               "decisions": parse_lines(secs.get(f"r{n}-decision.md", ""), DEC_RE)})
        r1 = rounds[0]["findings"] if rounds else {}
        deferred, seen = [], set()
        for r in rounds:
            for fid, (verb, reason) in r["responses"].items():
                if verb == "defer" and fid not in seen:
                    seen.add(fid)
                    deferred.append((fid, r1.get(fid, {}).get("sev", ""), r1.get(fid, {}).get("claim", ""), reason))
        ending = "正常"
        if any(r["decisions"] for r in rounds):
            ending = "有裁决"
        if rounds and any(v[0] == "reject" for v in rounds[-1]["responses"].values()) and not rounds[-1]["decisions"]:
            ending = "reject 未裁决"
        if req.get("_cap") and rounds and rounds[-1]["n"] >= req["_cap"]:
            ending += "，到顶"
        out.append({"sha": sha, "when": (when.group(1) if when else "")[:10], "kind": req.get("kind", ""),
                    "rounds": len(rounds), "blocking": sum(1 for v in r1.values() if v["sev"] == "blocking"),
                    "secs": timing.get(sha, 0), "deferred": deferred, "ending": ending,
                    "artifact": req.get("artifact", ""), "text": text})
    return out


def path_is_plan(path, patterns):
    import fnmatch
    return any(fnmatch.fnmatch(path, pat) for pat in patterns)


def since_last_review(repo, conf):
    """观察用：上次 code 评审的 target 到 HEAD 之间积了多少提交，其中多少被 SKIP、多少走了 plan 评审、
    多少根本没经过路由。只读 timing.md / self-closed.md / git，不改任何机制。"""
    plan_pats = (conf.get("REVIEW_PLAN_PATHS") or "").split()
    rows = [l for l in (read(f"{repo}/docs/reviews/timing.md") or "").splitlines() if re.match(r'\S+ \| \w+ \|', l)]
    def row_kind(sha):
        cols = [c.strip() for c in l.split("|")]
        if len(cols) >= 5 and cols[4] in ("code", "plan"):
            return cols[4]
        files = git(repo, "diff-tree", "--no-commit-id", "--name-only", "-r", sha).split()
        return "plan" if files and all(path_is_plan(f, plan_pats) for f in files) else "code"
    base = None
    plan_targets = set()
    for l in reversed(rows):
        sha = [c.strip() for c in l.split("|")][1]
        k = row_kind(sha)
        if k == "plan":
            plan_targets.add(sha[:7]); continue
        if subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", sha, "HEAD"], capture_output=True).returncode == 0:
            base = sha; break
    if not base:
        return None
    commits = [c for c in git(repo, "rev-list", f"{base}..HEAD").split() if c]
    if not commits:
        return {"base": base, "n": 0, "skipped": 0, "plan": 0, "unrouted": 0}
    closed = read(f"{repo}/docs/reviews/self-closed.md") or ""
    skipped = sum(1 for c in commits if c[:7] in closed)
    plan = sum(1 for c in commits if c[:7] in plan_targets)
    return {"base": base, "n": len(commits), "skipped": skipped, "plan": plan, "unrouted": len(commits) - skipped - plan}


def map_suggestions(repo):
    """review-map --suggest 的输出：降级建议（要人点头）与图上没有的路径。没有 .review-map 或找不到命令 → []。"""
    if not os.path.exists(f"{repo}/.review-map"):
        return None
    exe = os.path.join(os.path.dirname(os.path.abspath(__file__)), "review-map")
    if not os.path.exists(exe):
        exe = "review-map"
    try:
        out = subprocess.run([exe, repo, "--suggest"], capture_output=True, text=True, timeout=30).stdout
    except Exception:
        return []
    rows = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) >= 4:
            rows.append(parts)
    return rows


def brief_status(repo, conf):
    """简报新旧：verified-at 之后几个提交，上限多少。返回 None 表示项目没有简报或关闭了检查。"""
    rel = conf.get("REVIEW_BRIEF", "docs/reviewer-brief.md") if "REVIEW_BRIEF" in conf else "docs/reviewer-brief.md"
    if not rel or not os.path.exists(f"{repo}/{rel}"):
        return None
    cap = int(conf.get("REVIEW_BRIEF_MAX_COMMITS") or 50)
    first = (read(f"{repo}/{rel}") or "").splitlines()[:1]
    m = re.search(r'verified at:\s*([0-9a-f]{7,40})', first[0]) if first else None
    if not m:
        return {"sha": "", "n": None, "cap": cap, "state": "缺 verified at"}
    sha = m.group(1)
    ok = subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", sha, "HEAD"], capture_output=True).returncode == 0
    if not ok:
        return {"sha": sha, "n": None, "cap": cap, "state": "基线不在 HEAD 历史里"}
    n = int((git(repo, "rev-list", "--count", f"{sha}..HEAD").strip() or "0"))
    return {"sha": sha, "n": n, "cap": cap, "state": "过期" if n > cap else ("将过期" if n > cap * 0.8 else "")}


def load_self_closed(repo):
    text = read(f"{repo}/docs/reviews/self-closed.md") or ""
    rows = [l for l in text.splitlines() if re.match(r'^\d{4}-\d{2}-\d{2} \|', l)]
    return [[c.strip() for c in l.split("|")] for l in reversed(rows[-SELF_CLOSED_SHOWN:])]


# ============================================================ 最小 markdown（归档原文）
def md(text):
    out, para, table, in_code = [], [], [], False

    def inline(s):
        s = esc(s)
        s = re.sub(r'`([^`]+)`', r'<code>\1</code>', s)
        return re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', s)

    def flush_para():
        if para:
            out.append("<p>" + inline(" ".join(para)) + "</p>")
            para.clear()

    def flush_table():
        if table:
            rows = [r for r in table if not re.match(r'^\s*\|?\s*:?-{2,}', r)]
            out.append("<table>" + "".join(
                "<tr>" + "".join(f"<td>{inline(c.strip())}</td>" for c in r.strip().strip("|").split("|")) + "</tr>"
                for r in rows) + "</table>")
            table.clear()

    for line in text.splitlines():
        if line.startswith("```"):
            flush_para(); flush_table()
            out.append("</pre>" if in_code else "<pre>")
            in_code = not in_code
            continue
        if in_code:
            out.append(esc(line))
            continue
        if line.lstrip().startswith("|"):
            flush_para(); table.append(line)
            continue
        flush_table()
        m = re.match(r'^(#{1,6})\s+(.*)', line)
        if m:
            flush_para()
            lvl = min(len(m.group(1)) + 2, 6)
            out.append(f"<h{lvl}>{inline(m.group(2))}</h{lvl}>")
            continue
        m = re.match(r'^\s*[-*]\s+(.*)', line)
        if m:
            flush_para(); out.append(f"<li>{inline(m.group(1))}</li>")
            continue
        if not line.strip():
            flush_para()
            continue
        para.append(line)
    flush_para(); flush_table()
    if in_code:
        out.append("</pre>")
    return "\n".join(out)


# ============================================================ 渲染
CSS = """
html,body{color-scheme:dark;margin:0;padding:0;background:#161616;color:#e6e4df;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Hiragino Sans GB","Helvetica Neue","Microsoft YaHei",sans-serif;font-size:13px;line-height:1.55;-webkit-font-smoothing:antialiased}
a{color:inherit;text-decoration:none}a:hover{text-decoration:underline}
code,pre{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace}
code{font-size:11.5px}
summary{cursor:pointer;list-style:none}summary::-webkit-details-marker{display:none}
details[open]>summary .tri{transform:rotate(90deg)}
.tri{display:inline-block;transition:transform .1s;color:#8b8985;font-size:10px}
.hit{outline:2px solid #c8375a;outline-offset:2px}
.mute{color:#8b8985}.dim{color:#a3a19b}.ink{color:#4a4a4a}
.wrap{min-height:100vh;display:flex;flex-direction:column;min-width:1200px}
.mast{display:flex;align-items:baseline;gap:28px;padding:10px 24px 9px;background:#0f0f0f;color:#e8e6e1;border-bottom:4px solid #c8375a;position:sticky;top:0;z-index:5}
.mast .brand{font-weight:700;font-size:14px;letter-spacing:.02em;color:#fff}
.mast .agents{display:flex;gap:22px;font-size:13px}.mast .ag b{font-weight:600;margin-right:6px}
.mast .ag.wr{color:#e5b866}.mast .ag.rv{color:#8fb8ee}.mast .ag.pl{color:#c4a6f0}.mast .ag .off{color:#6a6866}
.mast .agents .mute{color:#8b8985}
.mast .gen{margin-left:auto;font-size:12px;color:#8b8985;font-variant-numeric:tabular-nums}
.banner{background:#3a1a22;border-bottom:2px solid #c8375a;padding:9px 24px;display:flex;gap:28px;align-items:baseline}
.banner .t{font-weight:700;color:#f0a3b3;font-size:14px;flex:none}
.banner .items{display:flex;flex-wrap:wrap;gap:8px 24px}
.banner a{display:flex;gap:10px;align-items:baseline;color:#f0a3b3}
.banner a b{font-weight:600}.banner a .age{color:#d98aa0}.banner a .arr{color:#c8375a}
.nowait{padding:7px 24px;color:#8b8985;border-bottom:1px solid #2e2e2e;font-size:12px}
.grid{display:grid;grid-template-columns:232px minmax(0,1fr);flex:1;align-items:start}
.side{border-right:1px solid #2e2e2e;position:sticky;top:44px;align-self:start;padding:14px 0;max-height:calc(100vh - 44px);overflow:auto}
.side .cap{padding:0 16px 8px;font-size:11px;color:#8b8985;letter-spacing:.04em}
.proj{padding:9px 16px 9px 14px;cursor:pointer;border-left:2px solid transparent}
.proj:hover{background:#262626}.proj.sel{background:#1f1f1f;border-left-color:#e6e4df}
.proj .row{display:flex;justify-content:space-between;align-items:baseline;gap:8px}
.proj .nm{font-weight:500;font-size:13.5px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.proj.sel .nm{font-weight:700}
.proj .age{font-size:11.5px;color:#8b8985;flex:none;font-variant-numeric:tabular-nums}
.proj .st{display:flex;align-items:center;gap:6px;margin-top:2px}
.proj .st .status{font-size:12px;color:#a3a19b}.proj .st .who{font-size:11.5px;color:#7c7a76}
.me{background:#c8375a;color:#fff;font-size:11px;font-weight:600;padding:0 6px;border-radius:2px;line-height:18px;display:inline-block}
.badge{display:inline-block;font-size:11px;font-weight:600;padding:0 6px;border-radius:2px;line-height:18px}
.badge.me{background:#c8375a;color:#fff}
.badge.rv{background:#1e3350;color:#8fb8ee}
.badge.pl{background:#2a2140;color:#c4a6f0}
.badge.wr{background:#3d2e12;color:#e5b866}
.badge.none{background:#262626;color:#a3a19b;font-weight:500}
.main{padding:18px 28px 60px;min-width:0}
.panel{display:none}.panel.sel{display:block}
.head{display:flex;align-items:baseline;gap:14px;padding-bottom:12px;border-bottom:1px solid #2e2e2e}
.head h1{margin:0;font-size:20px;font-weight:700;letter-spacing:-.01em}
.head .badge{font-size:12px;padding:1px 8px}
.head .hd{margin-left:auto;color:#a3a19b;font-size:12.5px}
.crew{display:flex;flex-wrap:wrap;gap:8px 12px;padding:12px 0 2px;font-size:14px;color:#e6e4df}
.crew .agent{display:inline-flex;align-items:center;gap:10px;padding:7px 14px;border-radius:4px;background:#232323;border:1px solid #333}
.crew .agent.st-working{border-color:#2f5a36;background:#1c2a1e}
.crew .agent.st-blocked{border-color:#7a2f26;background:#2b1a17}
.crew .agent b{font-weight:600}
.crew .st{font-family:ui-monospace,Menlo,monospace;font-size:12.5px;color:#a3a19b}
.crew .st.st-working{color:#7fd48a}.crew .st.st-blocked{color:#f0776a}
.crew .ttl{color:#d6d3cc}.crew .act{color:#a3a19b}
.crew .ttl::before,.crew .act::before{content:"·";color:#5a5955;margin-right:10px}
.dot{display:inline-block;width:10px;height:10px;border-radius:50%;background:#5a5955;flex:none}
.planning{margin:10px 0 0;border:1px solid #4a3a72;background:#231c33;border-radius:4px;padding:8px 12px;font-size:13.5px;display:flex;gap:12px;align-items:baseline;flex-wrap:wrap}
.planning b{color:#c4a6f0}.planning .age{color:#a3a19b;font-size:12px}.planning .task{color:#e6e4df}.planning .dim{color:#8b8985;font-size:12px}
details.lastrun{margin:10px 0 0;border:1px solid #7a2f26;background:#2b1a17;border-radius:4px;padding:8px 12px}
details.lastrun>summary{display:flex;gap:12px;align-items:baseline;cursor:pointer;font-size:13.5px;color:#f0776a}
details.lastrun .age{color:#a3a19b;font-size:12px}details.lastrun .msg{color:#e6e4df;font-family:ui-monospace,Menlo,monospace;font-size:12.5px}
details.lastrun pre{margin:8px 0 0;font-size:12px;white-space:pre-wrap;color:#c9c7c1}
a.loc{color:#8fb8ee;text-decoration:none;border-bottom:1px dotted #4a6a95}a.loc:hover{border-bottom-style:solid}
.dot.st-working{background:#5fb36a;box-shadow:0 0 0 3px rgba(95,179,106,.25)}.dot.st-blocked{background:#e5533d;box-shadow:0 0 0 3px rgba(229,83,61,.25)}.dot.st-idle,.dot.st-done{background:#8b8985}
details.proc{margin-top:8px}details.proc>summary{color:#8b8985;font-size:11.5px;display:flex;gap:6px;align-items:center;cursor:pointer}
details.proc pre{margin:6px 0 0;padding:8px 10px;background:#1c1c1c;border:1px solid #2e2e2e;border-radius:4px;font-size:12px;white-space:pre-wrap;color:#c9c7c1}
.idle{padding:28px 0;color:#8b8985}
.accum{font-size:12px;margin-top:8px}
details.mapsug{margin-top:8px;font-size:12px}details.mapsug>summary{color:#e5b866;cursor:pointer}details.mapsug li{margin:3px 0 3px 16px}.accum.warn{color:#e5b866}.accum b{font-weight:700}
.cycle{margin-top:20px;border:1px solid #2e2e2e;background:#1f1f1f;padding:14px 18px 14px 20px;border-left:4px solid #4a4a4a}
.cycle.s-pl{border-left-color:#8f6ccf}.cycle.s-rv{border-left-color:#4a7fc1}.cycle.s-wr{border-left-color:#d9a83a}.cycle.s-me{border-left-color:#c8375a}
.cycle .title{font-size:16px;font-weight:700;letter-spacing:-.01em;margin-bottom:2px}
.cycle .subtitle{font-size:13px;color:#4a4a4a;margin-bottom:2px}
.cycle .body-msg{white-space:pre-wrap;color:#4a4a4a;font-size:12.5px;margin:4px 0 6px;max-width:900px}
.cycle .commits{font-size:12px;color:#a3a19b;margin:2px 0 8px}.cycle .commits div{margin:1px 0}
.title-sm{font-weight:700;color:#e6e4df}
.cycle .top{display:flex;gap:18px;align-items:baseline;flex-wrap:wrap;margin:6px 0 12px}
.d-add{color:#7fd18a;background:#1e3323;display:block}.d-del{color:#f28b82;background:#3b1f1d;display:block}
.d-hunk{color:#b3a7f0;display:block}.d-file{font-weight:700;display:block}.d-hdr{color:#8b8985;display:block;margin-top:8px}.d-ctx{display:block;min-height:1.5em}
details.prev{margin-top:18px;border:1px dashed #3a3a3a;background:#1b1b1b;padding:0 18px}
details.prev>summary{padding:12px 0;display:flex;gap:16px;align-items:baseline;flex-wrap:wrap}
details.prev>summary .lab{font-size:12px;color:#8b8985}
details.prev .cycle{border:0;background:transparent;padding:0 0 14px;margin-top:0}
details.desc>summary,details.ev>summary{color:#8b8985;font-size:11.5px;display:flex;gap:6px;align-items:center}
details.ev{margin-top:5px}details.ev>summary{display:flex;gap:8px;align-items:center;min-width:0}
.evbtn{display:inline-block;border:1px solid #4a4a4a;border-radius:3px;padding:0 6px;line-height:17px;font-size:11px;color:#4a4a4a;background:#1f1f1f;flex:none}
.evbtn::before{content:"▸ ";font-size:9px;color:#8b8985}details[open].ev .evbtn::before{content:"▾ "}
details.ev>summary:hover .evbtn{background:#262626}
.evteaser{font-size:11px;color:#8b8985;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
details[open].ev .evteaser{display:none}
details.bgrp{margin-top:10px}details.bgrp>summary.bhead{cursor:pointer}
details.sc>summary{cursor:pointer}details.sc>summary h2{display:inline}
.filter{margin:0 0 8px;font:12.5px inherit;padding:4px 8px;border:1px solid #3a3a3a;border-radius:2px;width:320px;background:#1f1f1f}
.cycle .top .lab{font-size:12px;color:#8b8985}
.lvl{display:inline-block;font-size:11px;font-weight:600;padding:0 6px;line-height:18px;border-radius:2px;background:#262626;color:#a3a19b}
.lvl.deep{background:#3b1f1d;color:#f28b82}.lvl.light{background:#262626;color:#a3a19b}.lvl.review{background:#1e3350;color:#8fb8ee}
.kv{display:grid;grid-template-columns:88px minmax(0,1fr);gap:6px 14px;font-size:12.5px}
.kv .k{color:#8b8985;padding-top:1px}.kv .v{color:#4a4a4a}
.chips{display:flex;flex-wrap:wrap;gap:4px 8px}
.chip{font-size:11.5px;background:#161616;padding:1px 5px;border-radius:2px;color:#4a4a4a}
.diff summary{display:flex;gap:8px;align-items:center;color:#4a4a4a}
pre.block{margin:8px 0 0;padding:10px 12px;background:#111;border:1px solid #2e2e2e;font-size:11.5px;line-height:1.5;overflow:auto;max-height:520px;white-space:pre}
.round{margin-top:26px}
.round .rh{display:flex;align-items:baseline;gap:12px;margin-bottom:8px}
h2{margin:0;font-size:15px;font-weight:700}
h2 .sub{font-weight:400;color:#8b8985;font-size:12px;margin-left:6px}
.ftab{border-top:1px solid #4a4a4a;font-size:12.5px}
.fcols{display:grid;grid-template-columns:44px 96px minmax(0,2.1fr) minmax(0,1.6fr) minmax(0,1.2fr)}
.fcols>div{padding:6px 8px;font-size:11px;color:#8b8985}
.frow{display:grid;grid-template-columns:44px 96px minmax(0,2.1fr) minmax(0,1.6fr) minmax(0,1.2fr);border-top:1px solid #2e2e2e;background:#1f1f1f}
.frow.pend{background:#2a1a1e}
.frow>div{padding:10px 8px}.frow .claim{max-width:72ch}.frow>div:first-child{padding-left:0;font-weight:700}.frow>div:last-child{padding-right:0}
.sev{display:inline-block;font-size:11px;font-weight:600;padding:0 6px;line-height:18px;border-radius:2px;border:1px solid transparent;color:#a3a19b;background:#262626}
.sev.blocking{color:#f28b82;background:#3b1f1d;font-weight:700}
.sev.should{color:#e5b866;background:#3d2e12}
.sev.nit{color:#a3a19b;background:#262626}
.fstat.ok{color:#7fd18a}.fstat.bad{color:#f28b82;font-weight:600}.fstat.wait{color:#e5b866}
.fstat{margin-top:4px;font-size:11.5px;color:#a3a19b}
.claim{text-wrap:pretty}.evid{display:block;margin-top:5px;font-size:11.5px;color:#a3a19b;word-break:break-all}
.verb{display:inline-block;font-size:11px;font-weight:600;padding:0 6px;line-height:18px;border-radius:2px;margin-right:6px}
.verb.accept{color:#7fd18a;background:#1e3323}.verb.defer{color:#e5b866;background:#3d2e12}.verb.reject{color:#161616;background:#e6e4df;font-weight:700}
.dec{display:inline-block;font-size:11px;font-weight:600;color:#4a4a4a;border:1px solid #4a4a4a;padding:0 6px;line-height:18px;border-radius:2px;margin-right:6px}
.pending{color:#f0a3b3;font-weight:600;display:flex;align-items:center;gap:6px}
.pending .dot{width:8px;height:8px;background:#c8375a;border-radius:50%;flex:none}
.pending-hint{font-size:11.5px;color:#d98aa0;margin-top:4px}
.sec{margin-top:40px}
.list{border-top:1px solid #4a4a4a;font-size:12.5px}
.bgrp{margin-top:10px}
.bhead{display:flex;gap:14px;align-items:baseline;padding:6px 10px;background:#262626;border-radius:2px}
.bitem{padding:8px 10px 8px 22px;border-bottom:1px solid #262626}
.bid{display:flex;gap:8px;align-items:baseline;margin-bottom:3px}.bid code{font-weight:700}
.bl{display:grid;grid-template-columns:44px minmax(0,1fr);gap:0 8px;max-width:1100px}
.bl .who{font-size:11.5px;color:#8b8985;padding-top:1px}
.acols,.arow{display:grid;grid-template-columns:20px 72px 92px 48px 48px 84px 72px minmax(0,1fr);gap:0 12px;align-items:baseline}
.acols{padding:5px 0;font-size:11px;color:#8b8985}
.arow{padding:8px 0}
.arch{border-top:1px solid #2e2e2e}
.arch .body{margin:0 0 10px 32px;padding:10px 14px;background:#1f1f1f;border:1px solid #2e2e2e;font-size:12.5px;overflow-x:auto}
.arch .body h3,.arch .body h4,.arch .body h5,.arch .body h6{font-size:12.5px;margin:12px 0 4px}
.arch .body h3{font-size:14px}
.arch .body table{border-collapse:collapse;margin:6px 0}.arch .body td{border:1px solid #2e2e2e;padding:3px 8px;vertical-align:top}
.arch .body li{margin:2px 0 2px 18px}.arch .body pre{background:#161616;padding:8px 10px;white-space:pre-wrap}
.arch .body p{margin:6px 0}
.srow{display:grid;grid-template-columns:92px 72px 120px minmax(0,1fr);gap:0 12px;padding:8px 0;border-bottom:1px solid #2e2e2e}
.tab{font-variant-numeric:tabular-nums}
.foot{padding:14px 24px;color:#8b8985;font-size:11.5px;border-top:1px solid #2e2e2e}
.empty{color:#8b8985;padding:8px 0}
"""

JS = """
(function(){
  var KEY='rb.selected';
  function select(name,push){
    document.querySelectorAll('.proj').forEach(function(e){e.classList.toggle('sel',e.dataset.p===name)});
    document.querySelectorAll('.panel').forEach(function(e){e.classList.toggle('sel',e.dataset.p===name)});
    try{localStorage.setItem(KEY,name)}catch(e){}
  }
  function hit(anchor){
    document.querySelectorAll('.hit').forEach(function(e){e.classList.remove('hit')});
    var el=document.getElementById(anchor);if(!el)return;
    el.classList.add('hit');
    window.scrollTo({top:el.getBoundingClientRect().top+window.scrollY-72});
    history.replaceState(null,'','#'+anchor);
  }
  window.rbFilter=function(inp){var q=inp.value.trim().toLowerCase();
    inp.nextElementSibling.querySelectorAll('.bgrp').forEach(function(g,i){var any=false;
      g.querySelectorAll('.bitem').forEach(function(r){var hit=!q||r.textContent.toLowerCase().indexOf(q)>=0;r.style.display=hit?'':'none';any=any||hit});
      g.style.display=any?'':'none';if(q)g.open=any;else g.open=(i===0)})};
  window.rbGo=function(name,anchor){select(name);setTimeout(function(){hit(anchor)},30);return false};
  var names=[].map.call(document.querySelectorAll('.proj'),function(e){return e.dataset.p});
  var first=document.querySelector('.proj.needs');
  var saved=null;try{saved=localStorage.getItem(KEY)}catch(e){}
  var pick=(first&&first.dataset.p)||(names.indexOf(saved)>=0?saved:names[0]);
  if(names.indexOf(saved)>=0&&!first)pick=saved;
  if(location.hash.length>1){var t=document.getElementById(decodeURIComponent(location.hash.slice(1)));
    var pn=t&&t.closest('.panel');if(pn){pick=pn.dataset.p;setTimeout(function(){hit(t.id)},30)}}
  if(pick)select(pick);
  document.querySelectorAll('.proj').forEach(function(e){e.addEventListener('click',function(){select(e.dataset.p)})});
  // 自动刷新：整页重载前存滚动位置与展开项，重载后恢复（file:// 下无法局部拉取）
  try{var st=JSON.parse(sessionStorage.rb||'{}');
    (st.open||[]).forEach(function(i){var d=document.querySelectorAll('details')[i];if(d)d.open=true});
    if(st.y)window.scrollTo(0,st.y)}catch(e){}
  setInterval(function(){if(document.hidden)return;
    try{sessionStorage.rb=JSON.stringify({y:window.scrollY,
      open:[].map.call(document.querySelectorAll('details'),function(d,i){return d.open?i:-1}).filter(function(i){return i>=0})})}catch(e){}
    location.reload()},30000);
})();
"""


def cycle_subject(p):
    """这次送审做的是什么：target 提交的标题与正文、base..target 的提交列表、plan 的文档标题。
    这些是写手本来就写的，不是 request 里的自述。"""
    req, cr = p["req"], p["cycle_req"]
    sent1 = (p["rounds"][0].get("sent") or {}) if p["rounds"] else {}
    target = cr.get("target sha") or req.get("target sha") or sent1.get("target") or ""
    base = cr.get("base sha") or ""
    out = {"subject": "", "body": "", "commits": [], "plan_title": ""}
    if not target:
        return out
    msg = git(p["repo"], "log", "-1", "--format=%s%n%b", target)
    lines = msg.splitlines()
    out["subject"] = lines[0].strip() if lines else ""
    out["body"] = "\n".join(l for l in lines[1:] if not re.match(r'^(Co-Authored-By|Claude-Session|Signed-off-by):', l)).strip()
    if base:
        out["commits"] = [l for l in git(p["repo"], "log", "--format=%h %s", f"{base}..{target}").splitlines() if l.strip()]
    if cr.get("kind") == "plan":
        for path in cr.get("artifact", "").split():
            if path.endswith((".md", ".markdown")):
                for l in git(p["repo"], "show", f"{target}:{path}").splitlines()[:30]:
                    m = re.match(r'^#\s+(.*)', l)
                    if m:
                        out["plan_title"] = m.group(1).strip(); break
            if out["plan_title"]:
                break
    return out


def agents_line(kind, writer_kind, review_args="", plan_kind="", plan_args=""):
    """三个角色各是哪个 agent、什么 model、什么 effort。写手是谁看 herdr 在仓库里见到的 agent；
    规划者和评审方看 .review.conf。model 只能读配置文件：herdr 不报 model，会话里临时切换的看不到，
    所以页面上标"按配置文件"；拉起参数里指定的 model / effort 覆盖配置文件。"""
    def override(base, args):
        model, eff = base
        m = re.search(r'(?:--model[= ]|\bmodel=)"?([^\s"]+)', args or "")
        e = re.search(r'model_reasoning_effort=\\?"?([A-Za-z]+)', args or "")
        return (m.group(1) if m else model, e.group(1) if e else eff)
    def codex():
        t = read(os.path.expanduser("~/.codex/config.toml")) or ""
        m = re.search(r'^model\s*=\s*"([^"]+)"', t, re.M); e = re.search(r'^model_reasoning_effort\s*=\s*"([^"]+)"', t, re.M)
        return (m.group(1) if m else "?", e.group(1) if e else "?")
    def claude():
        try:
            d = json.loads(read(os.path.expanduser("~/.claude/settings.json")) or "{}")
        except ValueError:
            d = {}
        model = str(d.get("model", "?"))
        base = re.sub(r'\[.*\]$', '', model)
        eff = (d.get("modelSettings", {}).get(base, {}) or {}).get("effortLevel") or d.get("effortLevel", "?")
        return (model, eff)
    readers = {"codex": codex, "claude": claude}
    r = override(readers.get(kind, lambda: ("?", "?"))(), review_args)
    if not writer_kind:
        wtxt = "未在运行"
    else:
        w = readers.get(writer_kind, lambda: ("?", "?"))()
        wtxt = f"{esc(writer_kind)} · {esc(w[0])} · {esc(w[1])}"
    if plan_kind:
        pl = override(readers.get(plan_kind, lambda: ("?", "?"))(), plan_args)
        ptxt = f"{esc(plan_kind)} · {esc(pl[0])} · {esc(pl[1])}"
    else:
        ptxt = '<span class="off">未配置</span>'
    return (f'<span class="ag wr"><b>写手</b> {wtxt}</span>'
            f'<span class="ag pl"><b>规划者</b> {ptxt}</span>'
            f'<span class="ag rv"><b>评审方</b> {esc(kind)} · {esc(r[0])} · {esc(r[1])}</span><span class="mute">按配置文件</span>')


def state_badge(p):
    """状态标签按"谁在等"配色：红 = 等你，蓝 = 等评审方，琥珀 = 等写手，灰 = 没人在等。"""
    cls = "me" if p["needs_me"] else {"等评审方": "rv", "等写手": "wr", "等规划者": "pl"}.get(p["waiting"], "none")
    return f'<span class="badge {cls}">{esc(p["state"])}</span>'


# 页面用词：文件与协议里仍是英文（脚本靠它们解析），页面翻成中文，悬停显示原词。
ZH = {"accept": "接受", "defer": "暂缓", "reject": "拒绝",
      "blocking": "阻断", "should": "应改", "nit": "细节",
      "resolved": "已修复", "not-resolved": "未修复", "regressed": "有回退",
      "upheld": "维持原判", "overruled": "已改判", "deferred": "已暂缓", "disputed": "有争议",
      "uphold": "维持原判", "overrule": "改判"}


def zh(word, cls=""):
    w = (word or "").lower()
    if w not in ZH:
        return esc(word)
    return f'<span class="{cls}" title="{esc(w)}">{ZH[w]}</span>' if cls else f'<span title="{esc(w)}">{ZH[w]}</span>'


def sev_tag(sev):
    return f'<span class="sev {esc(sev)}" title="{esc(sev)}">{ZH.get(sev, esc(sev))}</span>' if sev else ""


def render_round(p, rnd):
    f, r, dcs = rnd["findings"], rnd.get("responses") or {}, rnd.get("decisions") or {}
    ids = list(f.keys()) + [k for k in r if k not in f]
    pend_ids = {fid for _, fid, _, _, _ in p["human"]} if rnd["n"] == p["req"].get("_round", 1) - 1 else set()
    nsev = {s: sum(1 for v in f.values() if v["sev"] == s) for s in SEVS}
    summary = f"{len(ids)} 条" + "".join(f" · {nsev[s]} {ZH[s]}" for s in SEVS if nsev[s])
    if pend_ids:
        summary += f" · {len(pend_ids)} 条待裁决"
    if not rnd["done"]:
        summary += " · 评审未完成"
    t0 = (rnd.get("sent") or {}).get("start")
    tf, tr = rnd.get("t_findings"), rnd.get("t_responses")
    timing = []
    if t0 and tf and rnd["done"]:
        timing.append(f"评审 {dur(tf - t0)}")
    if tf and tr:
        timing.append(f"回应 {dur(tr - tf)}")
    if timing:
        summary += " · " + " · ".join(timing)
    rows = []
    for fid in ids:
        v = f.get(fid, {})
        resp, dec = r.get(fid), dcs.get(fid)
        anchor = f"f-{p['name']}-{fid}"
        pend = fid in pend_ids
        st = (v.get("status") or "").lower()
        stc = {"resolved": "ok", "not-resolved": "bad", "regressed": "bad", "deferred": "wait"}.get(st, "")
        sev_cell = sev_tag(v.get("sev", "")) + (f'<div class="fstat {stc}">{zh(v["status"])}</div>' if st else "")
        if v.get("claim"):
            ev = v.get("evidence", "")
            teaser = ev if len(ev) <= 60 else ev[:60] + "…"
            claim_cell = f'<div class="claim">{esc(v["claim"])}</div>' + (
                f'<details class="ev"><summary><span class="evbtn">evidence</span><code class="evteaser">{esc(teaser)}</code></summary>'
                f'<code class="evid">{linkify(ev, p["repo"])}</code></details>' if ev else "")
        else:  # 第 2 轮常只有 evidence（核实叙述），没有 claim：直接当正文
            claim_cell = f'<div class="claim">{linkify(v.get("evidence", ""), p["repo"])}</div>'
        if resp:
            resp_cell = zh(resp[0], f"verb {resp[0]}") + f'<span class="claim">{esc(resp[1])}</span>'
        elif rnd["responses"] is None:
            resp_cell = '<span class="mute">—</span>'
        else:
            resp_cell = '<span class="mute">未回应</span>'
        if pend:
            dec_cell = '<div class="pending"><span class="dot"></span>等你裁决</div><div class="pending-hint">维持原判 uphold / 改判 overrule · 记入 r%d-decision.md</div>' % rnd["n"]
        elif dec:
            dec_cell = zh(dec[0], "dec") + f'<span>{esc(dec[1])}</span>'
        else:
            dec_cell = '<span class="mute">—</span>'
        rows.append(f'<div class="frow{" pend" if pend else ""}" id="{esc(anchor)}"><div><code>{fid}</code></div>'
                    f'<div>{sev_cell}</div><div>{claim_cell}</div><div>{resp_cell}</div><div>{dec_cell}</div></div>')
    if not rows and not rnd["done"]:
        return (f'<div class="round"><div class="rh"><h2>Round {rnd["n"]}</h2>'
                f'<span class="mute" style="font-size:12px">评审中，findings 尚未完成</span></div></div>')
    if not rows:
        rows.append('<div class="empty">没有可解析的 finding 行</div>')
    proc = ""
    if rnd.get("process"):
        proc = (f'<details class="proc"><summary><span class="tri">▶</span>评审方怎么看的</summary>'
                f'<pre>{esc(rnd["process"])}</pre></details>')
    return (f'<div class="round"><div class="rh"><h2>Round {rnd["n"]}</h2><span class="mute" style="font-size:12px">{esc(summary)}</span></div>'
            f'<div class="ftab"><div class="fcols"><div>编号</div><div>严重度 · 状态</div><div>评审方 claim</div>'
            f'<div>写手回应</div><div>裁决</div></div>{"".join(rows)}</div>{proc}</div>')


def render_cycle(p):
    req, cr = p["req"], p["cycle_req"]
    sent1 = (p["rounds"][0].get("sent") or {}) if p["rounds"] else {}
    target = (cr.get("target sha") or req.get("target sha") or sent1.get("target") or "")[:7]
    base = (cr.get("base sha") or "")[:7]
    stale = bool(p["rounds"]) and p["closed"] and not p["waiting"]
    lvl = (req.get("level") or cr.get("level") or "").lower()
    lvl_html = f'<span class="lvl {esc(lvl)}" title="level">{ {"deep": "深审", "review": "常规", "light": "轻审"}.get(lvl, esc(lvl)) }</span>' if lvl else ""
    top = (f'<span class="lab">{"周期" if stale else "当前周期"}</span><span><code style="font-weight:600">@ {esc(target)}</code></span>'
           f'<span>{esc(cr.get("kind", ""))}</span>{lvl_html}<span>round {esc(req.get("round", cr.get("round", "")))}</span>'
           f'<span class="dim">{esc(p["cycle_note"])}</span>')
    sub = cycle_subject(p)
    title = ""
    if sub["subject"] and not stale:   # 折叠的上一周期在 summary 行里已经有标题
        title = f'<div class="title">{esc(sub["subject"])}</div>'
        if sub["plan_title"]:
            title += f'<div class="subtitle">计划：{esc(sub["plan_title"])}</div>'
        if sub["body"]:
            title += f'<div class="body-msg">{esc(sub["body"])}</div>'
        if len(sub["commits"]) > 1:
            title += '<div class="commits">' + "".join(f'<div><code>{esc(c[:7])}</code> {esc(c[8:])}</div>' for c in sub["commits"]) + "</div>"
    kv = []
    art = cr.get("artifact", "")
    if art:
        kv.append('<div class="k">artifact</div><div class="chips">' + "".join(f'<code class="chip">{esc(a)}</code>' for a in art.split()) + "</div>")
    if cr.get("checks"):
        kv.append(f'<div class="k">checks</div><div><code>{esc(cr["checks"])}</code></div>')
    # 写手的自述（不是事实）默认折起，需要对照时再看
    self_desc = [(k, cr[k]) for k in ("out of scope", "risk areas", "test paths") if cr.get(k)]
    if self_desc:
        kv.append('<div class="k">写手自述</div><div><details class="desc"><summary><span class="tri">▶</span>'
                  + esc(" · ".join(k for k, _ in self_desc)) + '</summary><div class="kv" style="margin-top:6px">'
                  + "".join(f'<div class="k">{k}</div><div class="v">{esc(v)}</div>' for k, v in self_desc)
                  + '</div></details></div>')
    if base and target:
        stat = git(p["repo"], "diff", "--stat", f"{base}..{target}")
        full = git(p["repo"], "diff", f"{base}..{target}").splitlines()
        trunc = ""
        if len(full) > DIFF_MAX_LINES:
            full = full[:DIFF_MAX_LINES]
            trunc = f"\n\n… 已截断，完整 diff：git -C {p['repo']} diff {base}..{target}"
        last = stat.strip().splitlines()[-1].strip() if stat.strip() else "空"
        body = []
        for ln in full:
            if ln.startswith("+++") or ln.startswith("---"):
                body.append(f'<span class="d-file">{esc(ln)}</span>')
            elif ln.startswith("diff --git"):
                body.append(f'<span class="d-hdr">{esc(ln)}</span>')
            elif ln.startswith("@@"):
                body.append(f'<span class="d-hunk">{esc(ln)}</span>')
            elif ln.startswith("+"):
                body.append(f'<span class="d-add">{esc(ln)}</span>')
            elif ln.startswith("-"):
                body.append(f'<span class="d-del">{esc(ln)}</span>')
            else:
                body.append(f'<span class="d-ctx">{esc(ln)}</span>')
        kv.append(f'<div class="k">diff</div><div><details class="diff"><summary><span class="tri">▶</span><code>{esc(last)}</code>'
                  f'<span class="mute" style="font-size:11.5px">展开完整 diff</span></summary>'
                  f'<pre class="block">{esc(stat)}\n{"".join(body)}{esc(trunc)}</pre></details></div>')
    scls = "s-me" if p["needs_me"] else {"等评审方": "s-rv", "等写手": "s-wr", "等规划者": "s-pl"}.get(p["waiting"], "")
    return f'<div class="cycle {scls}">{title}<div class="top">{top}</div><div class="kv">{"".join(kv)}</div></div>'


def render_panel(p, archives, self_closed):
    parts = [f'<div class="panel" data-p="{esc(p["name"])}" id="p-{esc(p["name"])}">']
    badge = state_badge(p)
    parts.append(f'<div class="head"><h1>{esc(p["name"])}</h1>{badge}<span class="mute">{ago(p["since"])}</span>'
                 f'<span class="hd">HEAD <code>{esc(p["head"][:7])}</code></span></div>')
    ag = p.get("agents") or {}
    if ag:
        chips = []
        for role, label in (("writer", "写手"), ("planner", "规划者"), ("reviewer", "评审方")):
            a = ag.get(role)
            if not a:
                continue
            st = esc(a["status"])
            bits = [f'<span class="dot st-{st}"></span><b>{label}</b><span class="st st-{st}">{st}</span>']
            if a["title"]:
                bits.append(f'<span class="ttl">{esc(a["title"])}</span>')
            if a["activity"]:
                bits.append(f'<span class="act">{esc(a["activity"])}</span>')
            chips.append(f'<span class="agent st-{st}" title="pane {esc(a["pane"])}">{"".join(bits)}</span>')
        parts.append(f'<div class="crew">{"".join(chips)}</div>')
    pl = p.get("planning")
    if pl:
        parts.append(f'<div class="planning"><b>规划中</b><span class="age">{ago(pl["since"])}</span>'
                     f'<span class="task">{esc(pl["task"])}</span><span class="dim">规划者决定要不要计划；它提交的计划会作为一个评审周期出现在下面</span></div>')
    lr = p.get("last_run")
    if lr:
        parts.append(f'<details class="lastrun"><summary><span class="tri">▶</span><b>上次运行 request-review：exit {esc(lr["code"])}</b>'
                     f'<span class="age">{ago(lr["ts"])} 前</span><span class="msg">{esc(lr["head"])}</span></summary>'
                     f'<pre>{esc(lr["out"])}</pre></details>')
    b = p.get("brief")
    if b:
        if b["n"] is None:
            parts.append(f'<div class="accum warn">简报 {esc(b["state"])}，写手下次运行会被要求重写</div>')
        else:
            cls = "accum warn" if b["state"] else "accum mute"
            tail = f' · <b>{esc(b["state"])}</b>' if b["state"] else ""
            parts.append(f'<div class="{cls}">简报核实于 <code>{esc(b["sha"][:7])}</code>，之后 {b["n"]} 个提交，上限 {b["cap"]}{tail}</div>')
    ms = p.get("map")
    if ms is None:
        parts.append('<div class="accum mute">没有 .review-map，代码路径全部由评审方 triage</div>')
    elif ms:
        items = "".join(f'<li><span class="mute">{"建议降级" if k == "lower" else "建议加入"}</span> <code>{esc(g)}</code> {esc(lv)} <span class="dim">· {esc(why)}</span></li>' for k, g, lv, why in ms)
        parts.append(f'<details class="mapsug"><summary>风险图有 {len(ms)} 条建议，等你点头</summary><ul>{items}</ul></details>')
    acc = p.get("accum")
    if acc is None:
        parts.append('<div class="accum mute">尚无已完成的代码评审，无法计算累积</div>')
    else:
        bits = [f'上次代码评审 <code>{esc(acc["base"][:7])}</code> 以来 <b>{acc["n"]}</b> 个提交']
        if acc["n"]:
            bits.append(f'{acc["skipped"]} 个 SKIP')
            if acc["plan"]:
                bits.append(f'{acc["plan"]} 个走了计划评审')
            if acc["unrouted"]:
                bits.append(f'<b>{acc["unrouted"]} 个未经路由</b>')
        cls = "accum warn" if acc["n"] and not p["waiting"] and not p["needs_me"] else "accum mute"
        parts.append(f'<div class="{cls}">' + " · ".join(bits) + '</div>')
    if p.get("triage_reason"):
        parts.append(f'<div class="idle" style="padding:14px 0">{esc(p["triage_reason"])}</div>')
    stale = bool(p["rounds"]) and p["closed"] and not p["waiting"]
    if stale:
        # 闭合但还没归档：收成一行，点开才看 request 与 Round。下个周期派发时它进"最近归档"。
        req, cr = p["req"], p["cycle_req"]
        last = p["rounds"][-1]
        resp = last.get("responses") or {}
        counts = " / ".join(f"{sum(1 for v in resp.values() if v[0] == k)} {ZH[k]}" for k in ("accept", "defer", "reject") if any(v[0] == k for v in resp.values())) or "无回应"
        t0 = (p["rounds"][0].get("sent") or {}).get("start"); t1 = last.get("t_responses") or last.get("t_findings")
        sent1 = p["rounds"][0].get("sent") or {}
        target = (cr.get("target sha") or req.get("target sha") or sent1.get("target") or "")[:7]
        subj = cycle_subject(p)["subject"]
        parts.append(f'<details class="prev"><summary><span class="tri">▶</span><span class="lab">上一周期</span>'
                     + (f'<span class="title-sm">{esc(subj)}</span>' if subj else "")
                     + f'<code style="font-weight:600">@ {esc(target)}</code><span>{esc(cr.get("kind", ""))}</span>'
                     f'<span>{len(p["rounds"])} 轮</span><span>{esc(counts)}</span><span class="tab">{dur((t1 - t0) if t0 and t1 else None)}</span>'
                     f'<span class="dim">已闭合，等下个周期派发时归档</span></summary>')
        parts.append(render_cycle(p))
        for rnd in p["rounds"]:
            parts.append(render_round(p, rnd))
        parts.append('</details>')
    elif p["rounds"] or (p["req"] and p["state"] not in ("空闲",) and not p["state"].startswith("triage")):
        parts.append(render_cycle(p))
        for rnd in p["rounds"]:
            parts.append(render_round(p, rnd))
    elif not p.get("triage_reason"):
        parts.append('<div class="idle">无在途周期。最近一次周期见下方归档。</div>')

    groups = [a for a in archives if a["deferred"]]
    total = sum(len(a["deferred"]) for a in groups)
    parts.append(f'<div class="sec"><h2>暂缓清单<span class="sub">评审方指出、写手承认但没改的 · {total} 条 · {len(groups)} 个周期</span></h2>'
                 f'<input class="filter" type="search" placeholder="过滤暂缓清单…" oninput="rbFilter(this)"><div class="list">')
    for i, a in enumerate(groups):
        parts.append(f'<details class="bgrp"{" open" if i == 0 else ""}><summary class="bhead" title="{esc(a["artifact"])}">'
                     f'<span class="tri">▶</span><code>{esc(a["sha"])}</code>'
                     f'<span class="dim tab">{esc(a["when"])}</span><span>{esc(a["kind"])}</span>'
                     f'<span class="dim">{len(a["deferred"])} 条</span></summary>')
        for fid, sev, claim, reason in a["deferred"]:
            said = esc(claim) if claim else '<span class="mute">评审方用了别的编号，见归档原文</span>'
            parts.append(f'<div class="bitem"><div class="bid"><code>{fid}</code>{sev_tag(sev)}</div>'
                         f'<div class="bl"><span class="who">评审方</span><span class="claim">{said}</span></div>'
                         f'<div class="bl dim"><span class="who">写手</span><span class="claim">{esc(reason)}</span></div></div>')
        parts.append('</details>')
    if not groups:
        parts.append('<div class="empty">没有暂缓的 finding</div>')
    parts.append("</div></div>")

    parts.append('<div class="sec"><h2>最近归档</h2><div class="list"><div class="acols"><span></span><span>sha</span><span>日期</span>'
                 '<span>kind</span><span>轮数</span><span title="blocking">阻断</span><span>总耗时</span><span>结束方式</span></div>')
    for a in archives[:ARCHIVES_SHOWN]:
        took = dur(a["secs"]) if a["secs"] else "—"
        bw = "700" if a["blocking"] else "400"
        parts.append(f'<details class="arch"><summary class="arow"><span class="tri">▶</span><code>{esc(a["sha"])}</code>'
                     f'<span class="dim tab">{esc(a["when"])}</span><span>{esc(a["kind"])}</span><span>{a["rounds"]} 轮</span>'
                     f'<span style="font-weight:{bw}">{a["blocking"]}</span><span class="tab">{took}</span><span>{esc(a["ending"])}</span></summary>'
                     f'<div class="body">{md(a["text"])}</div></details>')
    if not archives:
        parts.append('<div class="empty">无归档</div>')
    parts.append("</div></div>")

    rows = [(cells + ["", "", "", ""])[:4] for cells in self_closed]
    kinds = {}
    for c in rows:
        kinds[c[2] or "?"] = kinds.get(c[2] or "?", 0) + 1
    gist = "、".join(f"{n} 条{esc(k)}" for k, n in kinds.items()) if rows else "无记录"
    parts.append(f'<div class="sec"><details class="sc"><summary><h2>自闭合<span class="sub">最近 {len(rows)} 条：{gist}</span></h2></summary><div class="list">')
    for c in rows:
        parts.append(f'<div class="srow"><span class="dim tab">{esc(c[0])}</span><code>{esc(c[1])}</code>'
                     f'<span>{esc(c[2])}</span><span class="ink">{esc(c[3])}</span></div>')
    parts.append("</div></details></div></div>")
    return "".join(parts)


def render(projects, archives, self_closed):
    waits = []
    for p in projects:
        for kind, fid, verb, sev, reason in p["human"]:
            if kind == "stop":
                waits.append((p["name"], f"STOP · {reason}", ago(p["since"]), f"p-{p['name']}"))
                continue
            what = f"{fid} {ZH.get(sev, sev)} · 写手{ZH.get(verb, verb)}" if sev else f"{fid} · 写手{ZH.get(verb, verb)}"
            waits.append((p["name"], what, ago(p["since"]), f"f-{p['name']}-{fid}"))
    if waits:
        banner = (f'<div class="banner"><div class="t">等你 · {len(waits)}</div><div class="items">' + "".join(
            f'<a href="#{esc(a)}" onclick="return rbGo(\'{esc(n)}\',\'{esc(a)}\')"><b>{esc(n)}</b><span>{esc(w)}</span>'
            f'<span class="age">{esc(t)}</span><span class="arr">→</span></a>' for n, w, t, a in waits) + "</div></div>")
    else:
        banner = '<div class="nowait">没有等你的</div>'
    side = [f'<div class="cap">项目 · {len(projects)}</div>']
    for p in projects:
        status = state_badge(p)
        side.append(f'<div class="proj{" needs" if p["needs_me"] else ""}" data-p="{esc(p["name"])}"><div class="row"><span class="nm">{esc(p["name"])}</span>'
                    f'<span class="age">{ago(p["since"])}</span></div><div class="st">{status}<span class="who">{esc(p["waiting"])}</span></div></div>')
    panels = "".join(render_panel(p, archives[p["name"]], self_closed[p["name"]]) for p in projects)
    gen = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    kinds = sorted({p["kind"] for p in projects}) or ["claude"]
    writer_kinds = [((p.get("agents") or {}).get("writer") or {}).get("kind") for p in projects]
    p0 = next((p for p in projects if p["kind"] == kinds[0]), projects[0] if projects else {})
    agents = agents_line(kinds[0], next((k for k in writer_kinds if k), ""), p0.get("review_args", ""),
                         next((p["plan_kind"] for p in projects if p.get("plan_kind")), ""),
                         next((p["plan_args"] for p in projects if p.get("plan_kind")), ""))
    mast = (f'<div class="mast"><span class="brand">Review board</span><span class="agents">{agents}</span>'
            f'<span class="gen">生成于 {gen[11:]}</span></div>')
    return (f'<!doctype html><html><head><meta charset="utf-8"><title>Review board</title><style>{CSS}</style></head><body>'
            f'<div class="wrap">{mast}{banner}<div class="grid"><div class="side">{"".join(side)}</div><div class="main">{panels}</div></div>'
            f'<div class="foot">生成于 {gen} · 只读，30s 自动刷新 · 来源：各项目 .review.conf 指向的交接目录与 docs/reviews</div></div>'
            f'<script>{JS}</script></body></html>')


# ============================================================ main
def discover(list_path):
    repos = [] if list_path else [os.path.dirname(c) for c in glob.glob(PROJ_GLOB)]
    for line in (read(list_path or PROJ_LIST) or "").splitlines():
        line = os.path.expanduser(line.strip())
        if line and not line.startswith("#") and os.path.isfile(f"{line}/.review.conf"):
            repos.append(line)
    seen, out = set(), []
    for r in sorted(set(repos)):
        real = os.path.realpath(r)
        if real not in seen:
            seen.add(real); out.append(r)
    return out


def main():
    args = sys.argv[1:]
    out_path = args[args.index("--out") + 1] if "--out" in args else DEFAULT_OUT
    list_path = args[args.index("--projects") + 1] if "--projects" in args else None
    projects, archives, self_closed = [], {}, {}
    for repo in discover(list_path):
        conf = parse_conf(f"{repo}/.review.conf")
        if "REVIEW_DIR" not in conf:
            continue
        p = project_state(repo, conf)
        projects.append(p)
        archives[repo] = load_archives(repo)
        self_closed[repo] = load_self_closed(repo)
    # 同名仓库（不同目录下的同名 checkout）用上一级目录区分，name 是页面里的唯一键
    names = [p["name"] for p in projects]
    for p in projects:
        if names.count(p["name"]) > 1:
            p["name"] = os.path.basename(os.path.dirname(p["repo"])) + "/" + p["name"]
    archives = {p["name"]: archives[p["repo"]] for p in projects}
    self_closed = {p["name"]: self_closed[p["repo"]] for p in projects}
    projects.sort(key=lambda p: (not p["needs_me"], -(p["since"] or p["last_activity"] or 0), p["name"]))
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    # 先写临时文件再改名：浏览器 30 秒一刷，直接覆盖会有一瞬读到空文件
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(render(projects, archives, self_closed))
    os.replace(tmp, out_path)
    if "--quiet" not in args:
        print(out_path)
    if "--open" in args:
        subprocess.run(["open", out_path])


if __name__ == "__main__":
    main()
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
   工作区必须干净（docs/reviews/ 和 .review-map 里评审脚本自己写的记录除外，随本文件一起
   提交即可）；若还有别的输出，停下并告知用户先提交或 stash，不要在脏工作树上生成本文件。
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

简报有自己的生命周期，不靠人记得：

- **缺失和过期都由脚本判**。没有简报的仓库第一次跑 `request-review` 就 exit 7 要求写一份 —— 新仓库接入靠的就是这道门。
  有简报时看第一行的 verified-at：之后累计超过
  `REVIEW_BRIEF_MAX_COMMITS`（默认 50）个提交，或该 sha 不在 HEAD 历史里，就 exit 7 停下，输出里写明
  怎么重写。写手用 `~/.config/review/brief-prompt.md` 的提示词重写、verified-at 写当前 HEAD、单独提交。
- **重写由评审方核对**。简报是规则文件（`REVIEW_RULE_PATHS`），那个提交自动路由为 kind: plan 评审，rubric
  里"For the reviewer brief"一段规定核对什么：verified-at 是否为 target 的父提交、核心路径是否真实且与
  依赖图/修复史相符、写的测试命令能否复现、不变量在代码里有没有落点。写手评审方一致就过，不一致才到你。
- **你只裁决**。不用读代码，也不用记得它什么时候该更新。看板项目头显示"简报核实于 X，之后 N 个提交，上限 50"，
  快到时变琥珀色。
- `.review.conf` 里 `REVIEW_BRIEF=` 置空可关掉这道门。

### 简报与 worktree 的同步

不会不同步，有两道保险：脚本强制工作区干净才允许评审；每轮 `reset --hard` 到 target sha。所以评审方读到的简报**正是被评审那个提交里的版本** —— 这正是想要的，它评审 commit X 就该看 commit X 时的项目描述。

---

## 第 6b 部分：规划者（可选角色）

写手这个槽位可以放任意便宜的模型，规划者和评审方锁定前沿模型。写手收到没有已批准计划覆盖的
任务时，把任务原话和已知约束写进 `$REVIEW_DIR/plan-request.md`，运行 `request-review plan`：

- 脚本在仓库目录里定位或拉起规划者（`PLAN_KIND`，参数 `PLAN_AGENT_ARGS`），按名字 `pl-<仓库名>` 认，
  因为它和写手同目录。注入提示指向 `~/.config/review/planner-prompt.md` 和 plan-request。
- 规划者先读简报，决定「直接做 / 短计划 / 完整计划」。要计划就写进 docs/plans、单独提交、
  自己跑 request-review 走完计划评审（这段它就是写手），闭合后把答复写进 `plan.md`：首行
  `PLAN: <路径>` / `DIRECT` / `STOP: <原因>`，末行 `PLAN-COMPLETE`。
- 写手每 10 秒续等（exit 3）；交付时脚本核对工作区干净，并核对派发以来的提交去掉脚本记录后只碰了计划/规则
  路径（规划者 yolo 模式下也不能动代码），才 exit 0。
  规划者 blocked、空闲没交活、答 STOP，都是 exit 4，人去看它的 pane。
- plan-request 内容变了就是新请求，旧答复作废。
- 派发前先过简报门：简报缺失或过期时 exit 7 给写手，写手按正常流程重写简报后再请规划者。规划者读的就是
  这份简报，它送审的计划评审也要过同一道门，所以不能让它带着过期简报开工。

不配 `PLAN_KIND` 时 `request-review plan` exit 2，写手自己写计划。规划者不给写手派活、不盯进度、
不改简报；派活仍由人。规划者的规则原文：

````markdown
# 规划者工作规则

你是这个仓库的规划者。写手（一个可能很便宜的模型）收到了一个任务，还没有计划覆盖它，
于是把任务交给你。你的产出只有一样：一个答复文件，必要时外加一份计划文档。你不写代码。

AGENTS.md §16 里「计划由规划者写」那一节是写给写手的：你就是规划者，不要再运行
`request-review plan`，也不要写 plan-request。§16 其余部分（评审周期、退出码、你不得做的事）
在你提交计划并送审时同样适用于你。

## 先读什么

1. 注入提示里给的 plan-request.md：任务原话和写手已知的约束。
2. Reviewer brief（docs/reviewer-brief.md）：项目地图。先读它，再只深入任务真正碰到的路径，
   不要从零爬仓库。
3. docs/plans/ 里已有的计划：看它们的格式、章节和验收写法，你写的要和它们一个样子；
   也看有没有已经覆盖这个任务的计划，有就在答复里指出来，不要重复写。

## 三种答复，你来定

- **直接做**：任务小、边界清楚、不需要设计判断。答复里写清楚边界、不能碰的东西、
  完成时应该核对什么。写手照做。
- **短计划**：几条步骤加验收标准就够，但值得留档。写进 docs/plans/。
- **完整计划**：新子项目或新阶段，按仓库里现有计划的完整格式写。

判断标准是「写手照着做会不会走偏」，不是任务大小。宁可多写一份短计划，也不要让写手
在没有边界的情况下开工。

## 写计划时

1. 只新建或修改 docs/plans/ 下的文件，不碰代码、测试、简报、AGENTS.md。
2. 单独提交，提交信息以 `docs: plan` 开头。工作区里评审脚本写的记录（docs/reviews/、
   .review-map 的自动升级行）随这次提交一起带上即可。
3. 提交后运行 `request-review`，按 AGENTS.md §16 的退出码办：它会把这份计划送去评审。
   评审方的 findings 由你回应、你修订、你开下一轮，直到周期闭合。这一段你就是「写手」。
4. 周期闭合后再写答复文件。

## 答复文件（注入提示里给的 plan.md 路径）

第一行三选一：

    PLAN: docs/plans/<文件名>.md      计划已提交并评审闭合
    DIRECT                            不需要计划
    STOP: <一句话原因>                无法规划：任务和已有计划冲突、需要人先做决定、
                                      或评审方给了你无法处理的阻断

后面几行给写手：边界、不能碰的东西、完成时核对什么。DIRECT 时这几行就是全部指令。
最后一行单独写 PLAN-COMPLETE。写完只回复这个文件的路径，不要把内容贴进终端。

## 你不做的事

- 不给写手派活，不看写手的进度，不修改写手的代码。
- 不改 reviewer brief。它过期了脚本会让写手重写。
- 不在答复里放计划正文。计划在仓库里，答复只是指路。
````

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
| `self-closed.md` | 未送审的提交：sha、依据（纯文本 / triage）、理由 | 脚本 | 当场 |

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

### self-closed.md 是 triage 唯一的校准数据

送审的那一半有 precision.md 和 timing.md；没送审的那一半靠这份记录。escapes.md 出现一条漏网时，先查它是被「纯文本」规则放的还是 triage 放的、理由是什么。另外盯一眼 REVIEW 率（归档数 ÷ 归档数 + triage SKIP 数）：接近 100% 说明评审方偏保守，等于代码全审，安全但贵。

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
| `ERROR: 缺 kind` / `kind 只能是 code 或 plan` | request.md 没声明评审单元种类 | 补 `kind:` 行；混合产物先拆 commit |
| `ERROR: base sha ... 不是 HEAD 的祖先` | base 填成了别的分支或未来的提交 | base 写本次改动之前紧邻的提交 |
| `ERROR: kind: code 的 request 混入了计划文档` | 代码和计划文档同一个 commit | 拆成两个 commit，各自一个周期；状态记录单独提交不送审 |
| `ERROR: … 有不合规范的回应行` | 写手把 responses 写成 `- F1 reject` / `**F1** reject` / `F1: reject`，或同一编号两行 | 写手改成行首顶格的 `F<n> accept|defer|reject — 理由` 再运行；不拦的话 reject 会被当成没有 |
| `STOP: 评审方已空闲，但 … 没有以 REVIEW-COMPLETE 结尾` | 评审方结束了回合却没交付：忘写结尾行、只回了一句话、或没真正开始 | 亲自看那个 pane；补上结尾行或让它继续，再运行即续等，不会重发 |
| `STOP: 有待人工裁决的 finding` | 写手 reject 了 finding，或把 blocking 标成 defer | 你裁决，写手记入 `r<n>-decision.md`（`F<n> uphold|overrule — 理由`）后再运行，本周期继续 |
| `exit 6` / `REVIEW: …` | triage 判定要审 | 写手写 request.md 再运行，正常 |
| `REVIEW: …` 后跟 `level: deep` | 风险图判为深审 | 写手照抄进 request，评审方会跑测试、三轮；正常 |
| `NOTE: 风险图升级 X → deep` | 本轮在 X 上报出阻断 | 脚本已把 X 追加进 .review-map，写手随下次提交带上；不用管 |
| 看板"风险图有 N 条建议" | 证据说某路径可以降级，或有新目录不在图上 | 你看理由，同意就改 .review-map 那一行提交；不同意不理 |
| `exit 7` / `STOP: 还没有 … 简报` 或 `… 简报过期` | 没有 brief；或 verified-at 之后超过 50 个提交、基线不在 HEAD 历史里 | 写手按输出写/重写 brief 单独提交，自动走 plan 评审；正常 |
| `ERROR: kind: code 的 request 混入了计划/规则文档` | 代码和 AGENTS.md / CLAUDE.md / reviewer-brief.md 同一个 commit | 拆开，规则文件单独提交走 plan 评审 |
| `STOP: triage 文件第一行不是 REVIEW 或 SKIP` | 评审方没按格式写 | 看 triage.md，手动改成 REVIEW/SKIP 后重跑，或删掉重发 |
| 想跳过 triage 直接审 | — | 写 request.md（target sha = HEAD）再运行即可 |
| `STOP: 里有多个 agent` | worktree 里开了不止一个 agent | 关掉多余的 |
| `STOP: 里跑的是 X，期望 claude` | 那个 pane 里是别的东西 | 去看看那个 pane |
| `STOP: 启动 claude 失败` + `agent_name_taken` | 已有同名 agent，但发现阶段漏掉了它 | 检查 `REVIEW_WT` 与 agent 的稳定 `cwd` 是否完全一致；已发送轮次不应进入启动路径 |
| `STOP: 停在对话框` | 评审方弹了审批 | 亲自去那个 pane 看，**不要让 agent 代答** |
| 评审方拒绝执行 | request 里的 sha 或路径不存在 | 这是正确行为；修正 request |
| 提交后重跑 round 1，findings 被归档、评审方重审 | 旧版脚本把 HEAD 变化当新周期 | 已修：已完成且无 responses 的评审优先交付，不看 HEAD |
| `docs/reviews/<sha>-2.md` 出现 | 写手手写并提交了同名归档，脚本另存了一份 | 二选一删掉，提醒写手不要手写归档 |
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
      "terminal_id": "term_...",     // 稳定终端身份，不随公开 pane ID 变化
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
| prompt 派送与审阅等待 | `--wait --until working --until blocked`，评审方状态变化才算送达；报 stalled/timeout 时核实状态，仍 idle 才重发一次，再失败不写 `.sent`。完成状态只由 findings 文件哨兵轮询 |
| 审阅等待中的 idle | 派送后每 `REVIEW_POLL`（默认 10s）轮询一次；哨兵未到而评审方连续两次 idle/done，判定它这轮没交付，exit 4 指向 pane，而不是等满 `REVIEW_WAIT` 让写手反复续等。`.sent` 保留，再次运行续等不重发 |
| 启动空窗 | herdr 在 claude 进程出现后约 4s 报 `interactive_ready`，但 Claude 自身初始化可能还没完成，此时 `agent prompt` 返回成功而输入被吞（09-06 复现，与就绪判定差不到 1s）。所以就绪判定只是省时，送达以状态变化为准 |
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

herdr 只出现在 `request-review` 的 `transport_*` 函数里（脚本中有注释框标出）：

- `transport_find` — 按 cwd 找 agent
- `transport_spawn` — 建 pane 起 agent
- `transport_identity` — 首次派发前保存 terminal/session 身份
- `transport_resume` — 已发送轮次按保存身份恢复并校验 agent
- `transport_dispatch` — 注入 prompt 并等状态变化作送达证据
- `transport_wait_ready` — 等待 agent 可接收首次 prompt
- `transport_state` — 查生命周期状态

其余全部逻辑（轮次、编号、范围冻结、reject 升级、哨兵、归档、度量）只依赖 git 和文件系统。日后想换 tmux 或走非交互路线，只改这些函数。worktree 是纯 git 的，不用动。

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
