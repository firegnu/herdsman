
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
       只要有任何 accepted finding 导致 artifact 改动，就必须再开一轮验证，
       不限于 blocking；没有 accepted finding 或 artifact 未改动时不开新轮。
       should / nit 仍留在本轮 findings，随 docs/reviews/<sha>.md 归档，
       不单独立文件。
   3 → 再次运行 request-review 继续等待。
   2 / 4 / 5 → 停下，把输出原样报告给人。
   其他退出码 → 脚本崩溃，同样停下原样报告，不要重试。

### request.md 格式
```
artifact:      <被评审的东西>
base sha:      <上一个提交>
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
计划与文档 2 轮，代码 3 轮；若最后一轮报出 regressed，允许为验证该修复再加一轮。
