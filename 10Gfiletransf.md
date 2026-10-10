10G 大文件传输扩展方案（纯 C 栈，零 Node.js）
方案总览
全程沿用纯 C 技术栈，基于现有 Nginx + UnrealIRCd 架构扩展，无任何解释型语言运行时：

    上传：基于 Nginx 官方 DAV 模块（C 语言）实现 HTTP PUT 直传，单文件最大支持 15G
    下载：Nginx 原生静态文件服务，支持 HTTP 断点续传，内网跑满带宽
    交互：上传完成自动在 IRC 频道生成下载链接，图片自动内嵌渲染，大文件显示文件名 + 大小
    终端：纯浏览器原生 API 实现，零插件零安装，全架构设备通用

一、服务端部署：编译带大文件上传能力的 Nginx
1. 安装编译依赖
bash

sudo apt update && sudo apt install -y build-essential libpcre3-dev zlib1g-dev libssl-dev

2. 下载并编译 Nginx（带官方 DAV 模块）
使用官方稳定版，编译时加入 http_dav_module 实现文件上传能力，全程无第三方代码：
bash

cd /opt
# 下载 Nginx 最新稳定版，可替换为最新版本号
curl -O http://nginx.org/download/nginx-1.24.0.tar.gz
tar zxvf nginx-1.24.0.tar.gz
cd nginx-1.24.0

# 编译配置，与系统原 Nginx 路径一致，保留原有配置兼容
./configure \
  --prefix=/usr/share/nginx \
  --sbin-path=/usr/sbin/nginx \
  --conf-path=/etc/nginx/nginx.conf \
  --error-log-path=/var/log/nginx/error.log \
  --http-log-path=/var/log/nginx/access.log \
  --pid-path=/run/nginx.pid \
  --lock-path=/run/lock/nginx.lock \
  --user=www-data \
  --group=www-data \
  --with-http_ssl_module \
  --with-http_dav_module \
  --with-file-aio \
  --with-threads

# 编译安装
make -j$(nproc)
sudo make install

3. 大文件专属 Nginx 配置
编辑 /etc/nginx/sites-available/irc，在原有配置基础上添加上传与下载优化：
nginx

server {
    listen 80 default_server;
    server_name _;

    root /var/www/irc;
    index index.html;

    # 全局大文件限制
    client_max_body_size 15G;
    client_body_timeout 3600s;
    client_header_timeout 30s;
    send_timeout 3600s;

    # 静态页面与聊天入口
    location / {
        try_files $uri $uri/ /index.html;
    }

    # WebSocket 代理（原有配置保留）
    location /ws {
        proxy_pass http://127.0.0.1:8067;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    # 大文件上传 + 下载目录
    location /uploads/ {
        alias /var/www/irc/uploads/;

        # 开启 DAV 上传能力
        dav_methods PUT DELETE MKCOL;
        create_full_put_path on;
        dav_access user:rw group:r all:r;

        # 下载优化：零拷贝传输，跑满内网带宽
        sendfile on;
        tcp_nopush on;
        aio threads;
        directio 10M;

        # 原生支持 HTTP Range 断点续传
        max_ranges 10;
    }
}

4. 创建上传目录并授权
bash

sudo mkdir -p /var/www/irc/uploads
sudo chown -R www-data:www-data /var/www/irc/uploads
sudo chmod -R 755 /var/www/irc/uploads

# 校验配置并重启
sudo nginx -t
sudo systemctl restart nginx

二、前端集成：单 HTML 页面加大文件上传功能
替换原有 /var/www/irc/index.html，完整保留 IRC 聊天功能，新增拖拽上传、进度显示、自动发链接能力。纯原生 JS，无任何外部依赖。
html

<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>本地设备互通频道</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { height: 100vh; display: flex; flex-direction: column; font-family: system-ui, sans-serif; }
        #header { padding: 8px 12px; background: #f5f5f5; border-bottom: 1px solid #ddd; font-size: 14px; display: flex; align-items: center; gap: 12px; }
        #messages { flex: 1; overflow-y: auto; padding: 12px; line-height: 1.5; font-size: 14px; }
        .msg { margin-bottom: 8px; word-break: break-all; }
        .nick { font-weight: bold; margin-right: 6px; color: #2563eb; }
        .msg img { max-width: 300px; max-height: 200px; display: block; margin-top: 4px; border-radius: 4px; cursor: pointer; }
        .file-card { display: inline-block; padding: 8px 12px; background: #f0f9ff; border: 1px solid #bae6fd; border-radius: 6px; margin-top: 4px; text-decoration: none; color: #0369a1; }
        .file-card:hover { background: #e0f2fe; }
        .file-size { color: #64748b; font-size: 12px; margin-left: 8px; }

        #upload-area { padding: 8px 12px; border-bottom: 1px solid #eee; background: #fafafa; }
        #upload-progress { height: 4px; background: #e2e8f0; border-radius: 2px; margin-top: 6px; overflow: hidden; display: none; }
        #upload-bar { height: 100%; width: 0%; background: #2563eb; transition: width 0.2s; }
        .upload-tip { font-size: 12px; color: #666; }

        #input-area { display: flex; padding: 8px; border-top: 1px solid #ddd; gap: 8px; align-items: center; }
        #nick-input { width: 120px; padding: 8px; border: 1px solid #ccc; border-radius: 4px; }
        #msg-input { flex: 1; padding: 8px; border: 1px solid #ccc; border-radius: 4px; }
        button { padding: 8px 16px; background: #2563eb; color: white; border: none; border-radius: 4px; cursor: pointer; }
        button:disabled { background: #94a3b8; cursor: not-allowed; }
        #file-btn { background: #64748b; }
        #status { color: #666; }
        .drag-over { background: #eff6ff !important; border-color: #2563eb !important; }
    </style>
</head>
<body>
    <div id="header">
        <span id="status">未连接</span>
        <span class="upload-tip">拖拽文件到窗口即可上传，最大15G</span>
    </div>
    <div id="upload-area">
        <div id="upload-progress"><div id="upload-bar"></div></div>
    </div>
    <div id="messages"></div>
    <div id="input-area">
        <input type="text" id="nick-input" placeholder="昵称" maxlength="20">
        <input type="text" id="msg-input" placeholder="输入消息，回车发送">
        <input type="file" id="file-input" style="display:none">
        <button id="file-btn">上传文件</button>
        <button id="send-btn" disabled>发送</button>
    </div>

    <script>
        const wsUrl = `ws://${window.location.host}/ws`;
        const uploadBase = `/uploads/`;
        const channel = "#main";
        let ws = null;
        let connected = false;
        let uploading = false;

        const msgInput = document.getElementById('msg-input');
        const nickInput = document.getElementById('nick-input');
        const sendBtn = document.getElementById('send-btn');
        const fileBtn = document.getElementById('file-btn');
        const fileInput = document.getElementById('file-input');
        const messagesDiv = document.getElementById('messages');
        const statusSpan = document.getElementById('status');
        const uploadProgress = document.getElementById('upload-progress');
        const uploadBar = document.getElementById('upload-bar');

        nickInput.value = "device_" + Math.floor(Math.random() * 10000);

        // ========== IRC 核心逻辑（原有保留） ==========
        function connect() {
            statusSpan.textContent = "连接中...";
            ws = new WebSocket(wsUrl);

            ws.onopen = () => {
                const nick = nickInput.value.trim() || "guest";
                ws.send(`NICK ${nick}`);
                ws.send(`USER ${nick} 0 * :${nick}`);
            };

            ws.onmessage = (e) => {
                const lines = e.data.split("\n").filter(l => l.trim());
                lines.forEach(parseIrcMessage);
            };

            ws.onclose = () => {
                connected = false;
                sendBtn.disabled = true;
                statusSpan.textContent = "已断开，3秒后重连...";
                setTimeout(connect, 3000);
            };

            ws.onerror = () => statusSpan.textContent = "连接失败";
        }

        function parseIrcMessage(line) {
            if (line.startsWith("PING")) {
                ws.send("PONG " + line.slice(5));
                return;
            }
            const parts = line.match(/^:([^!]+)!?[^ ]* ([^ ]+) ([^:]+)?(?::(.*))?$/);
            if (!parts) return;
            const [, from, command, target, content] = parts;

            if (command === "001") {
                ws.send(`JOIN ${channel}`);
                connected = true;
                sendBtn.disabled = false;
                statusSpan.textContent = "已连接 - " + channel;
                addSystemMessage("已进入频道");
                return;
            }

            if (command === "PRIVMSG" && target === channel) {
                addMessage(from, content);
            }
        }

        function formatFileSize(bytes) {
            if (bytes < 1024) return bytes + 'B';
            if (bytes < 1024*1024) return (bytes/1024).toFixed(1) + 'KB';
            if (bytes < 1024*1024*1024) return (bytes/1024/1024).toFixed(1) + 'MB';
            return (bytes/1024/1024/1024).toFixed(2) + 'GB';
        }

        function addMessage(nick, text) {
            const div = document.createElement('div');
            div.className = "msg";

            // 图片链接自动渲染
            const imgRegex = /(https?:\/\/[^\s]+\.(jpg|jpeg|png|gif|webp))/gi;
            let html = text.replace(imgRegex, '<img src="$1" alt="图片" onclick="window.open(this.src)">');

            // 本站文件链接自动转为卡片
            const fileRegex = /(\/uploads\/[^\s]+)/g;
            html = html.replace(fileRegex, (match) => {
                const fileName = decodeURIComponent(match.split('/').pop());
                return `<a href="${match}" class="file-card" target="_blank">📄 ${fileName}</a>`;
            });

            div.innerHTML = `<span class="nick">${nick}:</span>${html}`;
            messagesDiv.appendChild(div);
            messagesDiv.scrollTop = messagesDiv.scrollHeight;
        }

        function addSystemMessage(text) {
            const div = document.createElement('div');
            div.className = "msg";
            div.style.color = "#666";
            div.style.fontStyle = "italic";
            div.textContent = "* " + text;
            messagesDiv.appendChild(div);
            messagesDiv.scrollTop = messagesDiv.scrollHeight;
        }

        function sendMessage() {
            const text = msgInput.value.trim();
            if (!text || !connected) return;
            ws.send(`PRIVMSG ${channel} :${text}`);
            addMessage(nickInput.value.trim() || "guest", text);
            msgInput.value = "";
        }

        sendBtn.addEventListener('click', sendMessage);
        msgInput.addEventListener('keydown', (e) => {
            if (e.key === "Enter") sendMessage();
        });

        // ========== 大文件上传核心逻辑 ==========
        function uploadFile(file) {
            if (uploading) {
                alert("已有文件正在上传，请等待完成");
                return;
            }
            uploading = true;
            fileBtn.disabled = true;
            uploadProgress.style.display = "block";

            const encodedName = encodeURIComponent(file.name);
            const uploadUrl = uploadBase + encodedName;
            const xhr = new XMLHttpRequest();

            xhr.upload.onprogress = (e) => {
                if (e.lengthComputable) {
                    const percent = (e.loaded / e.total) * 100;
                    uploadBar.style.width = percent + "%";
                }
            };

            xhr.onload = () => {
                uploading = false;
                fileBtn.disabled = false;
                uploadProgress.style.display = "none";
                uploadBar.style.width = "0%";

                if (xhr.status === 201 || xhr.status === 200) {
                    // 上传完成，自动发送链接到频道
                    const fileLink = `/uploads/${encodedName}`;
                    const sizeText = formatFileSize(file.size);
                    ws.send(`PRIVMSG ${channel} :[文件] ${file.name} (${sizeText}) ${fileLink}`);
                    addMessage(nickInput.value.trim() || "guest", `[文件] ${file.name} (${sizeText}) ${fileLink}`);
                } else {
                    addSystemMessage(`上传失败：${xhr.statusText}`);
                }
            };

            xhr.onerror = () => {
                uploading = false;
                fileBtn.disabled = false;
                uploadProgress.style.display = "none";
                addSystemMessage("上传中断，请重试");
            };

            xhr.open("PUT", uploadUrl, true);
            xhr.send(file);
        }

        // 按钮选择文件
        fileBtn.addEventListener('click', () => fileInput.click());
        fileInput.addEventListener('change', (e) => {
            if (e.target.files[0]) uploadFile(e.target.files[0]);
        });

        // 拖拽上传
        document.body.addEventListener('dragover', (e) => {
            e.preventDefault();
            document.body.classList.add('drag-over');
        });
        document.body.addEventListener('dragleave', () => {
            document.body.classList.remove('drag-over');
        });
        document.body.addEventListener('drop', (e) => {
            e.preventDefault();
            document.body.classList.remove('drag-over');
            if (e.dataTransfer.files[0]) uploadFile(e.dataTransfer.files[0]);
        });

        // 启动连接
        window.addEventListener('load', connect);
    </script>
</body>
</html>

权限更新
bash

sudo chown www-data:www-data /var/www/irc/index.html

三、使用方式与验证
终端操作（全设备通用）

    浏览器访问服务器 IP，自动进入聊天界面
    两种上传方式：
        点击「上传文件」按钮选择本地文件
        直接拖拽文件到浏览器窗口
    上传过程显示进度条，完成后自动在频道发送文件卡片
    其他设备点击文件卡片即可下载，支持浏览器原生断点续传（暂停 / 继续）

服务端验证命令
bash

# 验证 Nginx 配置正常
sudo nginx -t

# 查看上传目录文件
ls -lh /var/www/irc/uploads/

# 测试单文件上传（本地命令行验证）
curl -T /path/to/test.file http://127.0.0.1/uploads/test.file

四、当前不开发，步骤留底 ,进阶可选：分片上传 + 断点续传（针对不稳定网络）
如果后续跨公网传输、网络易中断，可升级为分片续传方案，依然保持纯 C 栈：

    前端：JS 按 100MB / 片 切割文件，并发 3 片上传，记录已传分片索引
    服务端：保留 Nginx 接收分片，新增一个极简 C 语言合并工具（单二进制，内存 < 1MB），负责分片校验与合并
    能力：刷新页面、断网重连后自动续传，无需从头开始