# Remote SSH Launcher

把临时 Linux / GPU 实例快速暴露成可从公网连接的 SSH 入口。

## 一条命令启动

```bash
curl -fsSL https://raw.githubusercontent.com/witrer/Sesame-AG-TK/main/start.sh | sudo bash
```

启动后会输出：

```text
User     : remoteai
Password : <random-password>
Connect  : ssh -p <port> remoteai@<host>.pinggy.link
```

## 自定义用户名和本地 SSH 端口

```bash
curl -fsSL https://raw.githubusercontent.com/witrer/Sesame-AG-TK/main/start.sh | sudo SSH_USER=myuser SSH_PORT=22222 bash
```

## 说明

- 使用本机 `sshd`
- SSH 只监听 `127.0.0.1`
- 禁止 root 远程登录
- 自动生成随机密码
- 通过 Pinggy TCP 隧道暴露 SSH
- 隧道断开后自动重连
- 免费隧道重连后公网地址或端口可能变化

适合临时 Notebook、ModelScope、GPU 容器等环境。实例必须允许 root、安装软件和访问外网。
