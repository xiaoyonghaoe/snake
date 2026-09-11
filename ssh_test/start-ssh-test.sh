#!/bin/zsh
set -euo pipefail
umask 077

SSH_TEST_DIR="${0:A:h}"
SSH_TEST_MODE="${1:-start}"
SSH_TEST_CONFIG="$SSH_TEST_DIR/sshd_config"
SSH_TEST_CLIENT_KEY="$SSH_TEST_DIR/client_key"
SSH_TEST_HOST_KEY="$SSH_TEST_DIR/host_key"
SSH_TEST_PID="$SSH_TEST_DIR/sshd.pid"
SSH_TEST_LOG="$SSH_TEST_DIR/sshd.log"

if (( $# > 1 )) || [[ "$SSH_TEST_MODE" != start && "$SSH_TEST_MODE" != --check ]]; then
  print -u2 "用法：$0 [start|--check]"
  exit 1
fi

if [[ "$(/usr/bin/id -un)" != xiaoyong ]]; then
  print -u2 "请使用 xiaoyong 用户运行此脚本，无需 sudo。"
  exit 1
fi

if [[ "$SSH_TEST_MODE" == start ]]; then
  SSH_TEST_LISTENERS="$(/usr/sbin/lsof -nP -iTCP:49326 -sTCP:LISTEN -t 2>/dev/null || true)"
  if [[ -n "$SSH_TEST_LISTENERS" ]]; then
    print -u2 "端口 49326 已被占用（PID：${SSH_TEST_LISTENERS//$'\n'/, }），未启动新服务。"
    print -u2 "查看占用：lsof -nP -iTCP:49326 -sTCP:LISTEN"
    exit 1
  fi
fi

for SSH_TEST_KEY in "$SSH_TEST_CLIENT_KEY" "$SSH_TEST_HOST_KEY"; do
  if [[ ! -e "$SSH_TEST_KEY" && ! -e "$SSH_TEST_KEY.pub" ]]; then
    /usr/bin/ssh-keygen -q -t ed25519 -N '' -C snake-local-ssh-test -f "$SSH_TEST_KEY"
  elif [[ ! -f "$SSH_TEST_KEY" || ! -f "$SSH_TEST_KEY.pub" ]]; then
    print -u2 "测试密钥不完整，请检查：$SSH_TEST_KEY 及其 .pub 文件。"
    exit 1
  fi
  /bin/chmod 600 "$SSH_TEST_KEY" "$SSH_TEST_KEY.pub"
done

# Quote paths for sshd's configuration parser, including directories with spaces.
SSH_TEST_OPTIONS=(
  -f "$SSH_TEST_CONFIG"
  -h "$SSH_TEST_HOST_KEY"
  -o "AuthorizedKeysFile \"$SSH_TEST_CLIENT_KEY.pub\""
  -o "PidFile \"$SSH_TEST_PID\""
)
/usr/sbin/sshd -t "${SSH_TEST_OPTIONS[@]}"

if [[ "$SSH_TEST_MODE" == --check ]]; then
  print "SSH 配置校验通过，测试密钥已就绪；未启动服务。"
else
  /usr/sbin/sshd "${SSH_TEST_OPTIONS[@]}" -E "$SSH_TEST_LOG"
  print "SSH 测试服务已启动：xiaoyong@127.0.0.1:49326"
  print "日志：$SSH_TEST_LOG"
fi

print "客户端私钥：$SSH_TEST_CLIENT_KEY"
print "主机密钥指纹："
/usr/bin/ssh-keygen -lf "$SSH_TEST_HOST_KEY.pub"
print "连接命令："
printf 'ssh -p 49326 -o IdentitiesOnly=yes -i %q xiaoyong@127.0.0.1\n' "$SSH_TEST_CLIENT_KEY"
