# Linux 常驻部署

Web 和 worker 必须同时运行。worker 每分钟补齐未来 14 天排班、生成提醒、处理候补过期和发送邮件。

1. 备份现有数据库。代码在 `/opt/hms` 时可直接使用模板；其他路径（如 `/home/efface/HMS`）需要修改两个 service 中的 `WorkingDirectory` 和 `ExecStart`。将 `User=efface` 改为实际非 root 运行用户。
2. 在项目目录创建 `.venv` 并安装 `requirements.txt`。将 `hms.env.example` 复制到 `/etc/hms/hms.env`，填写现有数据库连接配置；文件由 root 持有，权限设为 600。示例密码不能用于连接。已有数据库可保持原连接配置，勿创建同名空库替换。
3. 导出相同的数据库环境变量，运行 `.venv/bin/python server/app.py --init` 完成幂等升级。不要使用清库重建参数升级已有数据库。
4. 将两个 service 文件放到 `/etc/systemd/system/`，执行 `sudo systemctl daemon-reload` 和 `sudo systemctl enable --now hms-web hms-worker`。若已有旧的 `hms.service`，切换前先停止旧 Web 服务，避免占用同一端口。
5. 用 `systemctl status hms-web hms-worker`、`journalctl -u hms-worker` 和 `/api/health` 核对运行情况。

应用的业务日期、提醒时间窗及数据库连接统一使用 `Asia/Shanghai`，无需修改整台机器的时区。建议用 systemd 每次运行 worker，单独运行 Web 不会自动创建后台进程。

邮件需要提供实际的 SMTP 配置，将 `MAIL_DRY_RUN=0` 才会真实发送。未配置 SMTP 时仅写演示日志，队列保持 pending，不会被误标为已发送。已存在的 `server/mail.env` 优先于环境变量，迁移配置时请检查该文件，且不要将授权码提交到 Git。

`python server/app.py --remind --force` 现在只忽略提醒时间窗，不再重建数据库。显式的 `--force`（或 `--init --force`）仍是破坏性的重建命令，仅限确认可清空的测试库。
