
## Applies to the implementing agent only

### 任务完成后的评审路由（你只读此清单，不得自行豁免）
完成当前产物并运行相关检查后，在请求评审与自行闭合之间二选一。
计划和实现分别在各自完成时判断；计划已经评审，不代表实现自动免审。
按以下顺序判断；命中前一项后，不得用后一项豁免。

**1. 必须评审。** 满足任一条即走 request-review：
- 人明确要求评审
- 当前产物是用于约束后续实施或验收的计划或设计文档；调研记录、状态记录和会议纪要不算
- 修改项目文档明确声明的不变量或冻结合同
- 新增、修改或删除公开接口、CLI 行为、对外或跨模块数据格式、持久化状态、schema、迁移或配置语义
- 涉及认证、权限、安全、并发、事务、幂等或破坏性操作
- 移动模块职责、改变既有跨模块数据流，或改变构建、发布、部署、回滚行为
- 删除、放宽或改写既有回归断言、共享 fixture 或验收基线
- 实现实质偏离已经确认或评审过的计划

**2. 核心路径内的低风险语义修改。** 对
<核心路径清单：如 src/core/、migrations/、auth/> 作语义修改、但未命中第 1 项时，
只有同时满足以下条件才能自行闭合；否则请求评审：
- 改动局限于一个模块，不移动职责或改变跨模块数据流
- 有直接覆盖目标行为的确定性回归或验收检查，且已经通过

**3. 其余改动。** 未命中前两项且相关检查通过时自行闭合。典型情况包括：
纯文案与注释、格式化、仅修改依赖版本号且不含代码适配、声明未变的生成物或
lockfile 刷新，以及只新增且不改变共享 fixture 或既有验收语义的测试。

文件数量、diff 行数和文件扩展名不单独构成送审理由。
相关检查因本次改动失败时，任务尚未完成：先修复，不得用评审代替验证。
不确定命中哪一项，或不能确认第 2 项条件全部成立时：请求评审。
自行闭合时向 docs/reviews/self-closed.md 追加一行：
`日期 | sha | 命中第几项 | 一句理由`。
你不得设置 SKIP_REVIEW —— 该变量只由人设置。

### 评审单元（送审前先切 commit）
一个 request 只装一种产物，由 request.md 的 `kind:` 声明，评审方据此只执行一套契约：
- `code`：代码及其直接相关的测试、docstring
- `plan`：用于约束后续实施或验收的计划或设计文档

状态记录——进度摘要、plan 状态、README 指针、Decision Board、reviewer brief 标记
之类——单独 commit，按路由第 1 项自行闭合，不送审，不得与 code 或 plan 同一 commit。
一个任务同时产出代码和计划时，各自一个 commit、各自一个评审周期。
`base sha` 必须是本次评审改动之前紧邻的提交；request-review 会校验它是 HEAD 的祖先，
配置了 REVIEW_PLAN_PATHS 的项目还会校验 round 1 的 diff 与 kind 一致，不符则 exit 2。

### 流程
1. 提交产物（工作区必须干净）
2. 写 $REVIEW_DIR/request.md，含 kind 与 round: n/cap；sha 与路径必须真实
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
   其他退出码 → 脚本崩溃，同样停下原样报告，不要重试。

### request.md 格式
```
artifact:      <被评审的路径或路径集合，不写清单式描述>
kind:          <code 或 plan>
base sha:      <本次评审改动之前紧邻的提交>
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

脚本靠 `^F<n> accept|defer|reject` 解析，格式漂移会导致 reject / defer 检测失效。

### 你不得做的事
- 不得修改任何 finding 的严重度。不同意就写 reject，交给人裁决。
  严重度由评审方定 —— 这是轮次机制成立的前提。
- 不要重试退出码 4 的注入，也不要用任何其它方式操作评审 pane
- 不要替评审方回答审批或提问对话框
- 不要关闭不是自己创建的 pane，不要运行 herdr server stop
- 不要修改 rubric、.review.conf、或本文件中的评审规则
- 不要手写或提前创建 docs/reviews/<sha>.md —— 归档由脚本在下一周期开始时自动生成，
  手写的会被视为已有文件，脚本改写到 <sha>-2.md，留下两份

### 上限
计划与文档 2 轮，代码 3 轮；若最后一轮报出 regressed，允许为验证该修复再加一轮。
