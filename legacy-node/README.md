# 旧版：Node + Express（已停用，仅留档）

这个目录里是 2026-10-17 之前使用的 Node + Express 版后端，**已经不参与运行**。
现在跑的是上一层的 `server/app.py`（Python + Flask），数据库、表结构、
前端页面和接口约定都没有变。

留在这里只是为了两件事：

1. **对照**：改写成 Python 时逐接口比对过响应，原版留着方便回查
   （对照脚本在 `.tmp/test_parity.py`，跑一次 54 项全一致）。
2. **回滚**：万一 Python 版出问题，把 `app.js` 拷回 `../server/` 就能退回去。

## 文件

| 文件 | 说明 |
|---|---|
| `app.js` | 原 `server/app.js`，全部后端逻辑 |
| `schema.sql` | 原 `server/schema.sql` 的**冻结快照**（真正在用的仍是 `../server/schema.sql`） |
| `package.json` / `package-lock.json` | 原依赖清单（express / pg / cors） |

## 想重新跑起来

`app.js` 读的是**同目录**下的 `schema.sql`，所以不能直接在这里启动。步骤：

```bat
copy app.js ..\server\app.js
cd ..
node server\app.js            :: 启动服务
node server\app.js --init     :: 初始化数据库
```

`node_modules/` 留在项目根目录（已被 `.gitignore` 忽略），
Node 会从 `server/` 往上找到它，不用重装。
