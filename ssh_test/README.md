# 本机 SSH 测试服务

以 `xiaoyong` 用户运行，无需 `sudo`：

```sh
./ssh_test/start-ssh-test.sh
```

首次运行自动在本目录生成专用客户端密钥和主机密钥，后续复用。密钥、PID 和日志不提交 Git；不修改系统 SSH 配置或 `~/.ssh/authorized_keys`。仅监听本机回环地址，支持 SSH 终端和 SFTP。

Snake 中填写：

- 地址：`127.0.0.1`
- 端口：`49326`
- 用户：`xiaoyong`
- 认证：私钥
- 私钥文件：本目录下的 `client_key`，无口令

首次连接时核对脚本输出的主机密钥指纹。本地测试密钥仅供本机测试使用。

只生成密钥并校验配置，不启动服务：

```sh
./ssh_test/start-ssh-test.sh --check
```

如果端口已被占用，脚本会退出并显示占用进程，不会停止已有服务。运行 `lsof -nP -iTCP:49326 -sTCP:LISTEN` 可检查占用情况。服务日志位于本目录的 `sshd.log`。
