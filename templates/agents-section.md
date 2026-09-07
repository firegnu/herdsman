
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

### 评审单元（送审前先切 commit）
一个 request 只装一种产物，由 request.md 的 `kind:` 声明，评审方据此只执行一套契约：
- `code`：代码及其直接相关的测试、docstring
- `plan`：用于约束后续实施或验收的计划或设计文档

状态记录——进度摘要、plan 状态、README 指针、Decision Board、reviewer brief 标记
之类——单独 commit，不得与 code 或 plan 同一 commit；纯文本的会被脚本直接跳过。
一个任务同时产出代码和计划时，各自一个 commit、各自一个评审周期。
`base sha` 用 request-review 输出里给的那个（上次评审的 target）；脚本会校验它是 HEAD 的祖先，
还会校验 target 提交只碰一种产物、种类等于 kind，不符则 exit 2。范围里更早的提交是上下文，不再验。

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
   3 → 再次运行 request-review 继续等待。
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
- 不要重试退出码 4 的注入，也不要用任何其它方式操作评审 pane
- 不要替评审方回答审批或提问对话框
- 不要关闭不是自己创建的 pane，不要运行 herdr server stop
- 不要修改 rubric、.review.conf、.review-map、或本文件中的评审规则。脚本自己会往 .review-map
  追加升级行，随下次提交带上即可；不要 checkout 或 stash 掉脚本写进 docs/reviews 或 .review-map 的内容
- 不要手写或提前创建 docs/reviews/<sha>.md —— 归档由脚本在下一周期开始时自动生成，
  手写的会被视为已有文件，脚本改写到 <sha>-2.md，留下两份

### 上限
计划与文档 2 轮，代码 3 轮；若最后一轮报出 regressed，允许为验证该修复再加一轮。
