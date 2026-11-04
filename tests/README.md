# 审查问题回归测试

后端测试会清空指定的隔离库。必须使用 `hms_test_` 前缀的新数据库，不要填写业务库名；代码对此有强制校验。

```sh
pip install -r requirements.txt
export PGDATABASE=hms_test_audit_regressions
export HMS_DB_HOST=127.0.0.1
export HMS_DB_USER=postgres
export HMS_DB_PASSWORD=你的测试数据库密码
export MAIL_DRY_RUN=1
python -m unittest discover -s tests -p 'test_*.py' -v
node tests/frontend_regressions.js
```

数据库账号需要创建测试库的权限。测试使用虚构患者；前端测试为原始 JS + Node VM/最小 DOM 模拟，不访问真实网络，也不替代浏览器端到端测试。执行后可删除指定的隔离库。

## 覆盖关系

| 已报告问题 | 修复与回归覆盖 |
|---|---|
| 提醒命令误清库 | 强制提醒保留业务数据，拒绝含糊命令组合 |
| 窗口代约调用缺失函数 | 实际执行 submitProxy，覆盖验证码重试、取消 |
| 停诊与挂号竞态 | 控制事务交错，新预约被拒绝、原预约取消 |
| docKey 泄露证件 | desk 的列表/详情不返回完整证件，明文访问仍需要授权及审计 |
| 取消 offer 不补位 | 下一个候补自动变 offered |
| 多 offer 过期只补一位 | 两个过期名额全部补位，重复扫描幂等 |
| 个人页状态筛选失效 | 三个状态及 limit 参数正确传递 |
| 号源缓存不刷新 | 返回选医生页面重新读取，写操作使缓存失效 |
| 自助机残留资料 | 关闭弹窗、清空输入、取消认证/验证码、拒绝过期响应 |
| 并发 offer 超额预留 | 重叠事务只产生一个有效 offer |
| 调额忽略预留 | API 和直接 SQL 均拒绝撤掉有效预留容量 |
| 联系方式被旧 session 覆盖 | 改号后本地及下一次挂号预填使用新号码 |
| 第 11 位患者凭证丢失 | 当前患者及最近验证凭证优先，重新验证可恢复 |
| 排班续建缺失 | tick 补回未来排班，保留现有调额，重复执行幂等 |
| 提醒业务时区 | 应用及 PostgreSQL 会话均为 Asia/Shanghai |
| 邮件 dry-run 丢队列 | 演示投递不标记 sent，补好 SMTP 后仍可发 |

已经修复的“当天结束诊次仍可预约”规则继续保留。Linux Web/worker 部署模板见 `deploy/`；真实邮件仍需要部署者填写 SMTP 授权信息。
