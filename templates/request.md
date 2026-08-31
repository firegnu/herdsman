artifact:      docs/plan-auth.md
base sha:      1a2b3c4
target sha:    3f9a1c2
round:         1/3
out of scope:  数据库迁移、前端改动
risk areas:    token 刷新的并发路径；错误分支的回滚语义
test paths:    tests/auth/
checks:        npm run lint && npm run typecheck
