# change_ssh_port.sh
安全修改SSH端口的Bash脚本
## 使用方法

### 方法1：远程执行指定端口
\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/guyon168/change_ssh_port.sh/main/main.sh | sudo bash -s -- 2222
\`\`\`

### 方法2：远程执行随机端口（推荐）
\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/guyon168/change_ssh_port.sh/main/main.sh | sudo bash -s -- -r
\`\`\`

### 方法3：先下载再执行（第一次建议这样做，可审查代码）
\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/guyon168/change_ssh_port.sh/main/main.sh -o main.sh
chmod +x main.sh
sudo ./main.sh --help    # 查看帮助
sudo ./main.sh -r        # 使用随机端口
sudo ./main.sh 2222      # 使用指定端口2222
\`\`\`
