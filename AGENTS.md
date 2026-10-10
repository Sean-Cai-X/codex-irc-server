all files download to /H/usr/aisrc/
all dutys and lists must save files at /H/usr/aisrc/
all run cmd must save files at /H/usr/aisrc/
all download the apt Packages must mirror copy to /H/usr/aisrc/apt/

【硬性操作边界（违反直接终止任务）】

    禁止以任何方式修改、覆盖、替换宿主系统的 /usr、/lib、/bin 核心目录，禁止热替换系统库、修改系统全局挂载结构；
    所有程序、依赖、运行库，全部放在指定独立目录下，仅通过环境变量（PATH/LD_LIBRARY_PATH）或独立镜像挂载生效；
    操作烈度严格匹配指令：指令仅要求解压、放置文件、创建快捷方式，就只做文件级操作；缺依赖或无法运行时，先告知风险和方案，禁止擅自修改系统；
    涉及 mount、losetup、chroot、修改系统配置的高危操作，必须先得到人工显式确认，禁止自动执行；
    优先级原则：系统完整性 > 功能可用性，宁可不完整运行，也不能破坏宿主系统基线

IRC x86 服务器( Live ISO 启动 可正常一键 run)
IRC 通讯方案完整部署手册（单文件 Web 客户端版）
整体架构（全服务端无 Node/Python，终端零安装）
plaintext

x86 服务器（仅纯C组件常驻）
├─ UnrealIRCd 6.x  IRC核心服务，本地监听 WebSocket
└─ Nginx           静态页面托管 + WebSocket 反向代理
终端设备（ARM/龙芯/x86/FPGA等）
└─ 系统自带浏览器  访问单HTML页面，直接使用

所有服务端组件均为 C 语言实现，无任何解释型语言运行时，攻击面极小；终端仅需支持 HTML5 WebSocket 的浏览器，零安装零适配。
一、UnrealIRCd 6.x 部署（IRC 核心服务）
1. 环境准备
bash



# 下载最新稳定版
 https://www.unrealircd.org/downloads/unrealircd-latest.tar.gz
tar zxvf unrealircd-latest.tar.gz
cd unrealircd-*/

# 默认配置编译（一路回车）
./Config
make -j$(nproc)
make install

# 退回 root 用户
exit

3. 核心配置文件
编辑 /home/irc/unrealircd/conf/unrealircd.conf，写入以下最简内网配置：
c

me {
    name "irc.local";
    info "Local Device IRC Network";
    sid "001";
};

// 仅本地监听 WebSocket，不对外直接暴露，由 Nginx 统一代理
listen {
    ip 127.0.0.1;
    port 8067;
    websocket { type text; }
};

// 全局强制 UTF-8，杜绝中文乱码
set {
    utf8-only yes;
    network-name "LocalNet";
    default-server "irc.local";
    maxchannelsperuser 100;
};

// 默认主频道，客户端打开自动加入
channel "#main" {
    topic "设备互通主频道";
};

// 本地回环免限制
allow {
    mask 127.0.0.1;
    class clients;
    maxperip 100;
};

class clients {
    pingfreq 120;
    maxclients 1000;
    sendq 1M;
    recvq 8k;
};

4. 验证与启动
bash

# 校验配置合法性
sudo -u irc /home/irc/unrealircd/bin/unrealircd configtest

# 启动服务
sudo -u irc /home/irc/unrealircd/bin/unrealircd start

5. 配置开机自启
创建 /etc/systemd/system/unrealircd.service：
ini

[Unit]
Description=UnrealIRCd IRC Server
After=network.target

[Service]
Type=forking
User=irc
WorkingDirectory=/home/irc/unrealircd
ExecStart=/home/irc/unrealircd/bin/unrealircd start
ExecStop=/home/irc/unrealircd/bin/unrealircd stop
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target

执行启用：
bash

sudo systemctl daemon-reload
sudo systemctl enable unrealircd

二、Nginx 部署（静态托管 + WebSocket 代理）
1. 安装 Nginx
bash

sudo apt install -y nginx

2. 创建站点目录
bash

sudo mkdir -p /var/www/irc
sudo mkdir -p /var/www/irc/uploads
sudo chown -R www-data:www-data /var/www/irc

3. 站点配置
创建 /etc/nginx/sites-available/irc：
nginx

server {
    listen 80 default_server;
    server_name _;

    root /var/www/irc;
    index index.html;

    # 静态页面访问
    location / {
        try_files $uri $uri/ /index.html;
    }

    # WebSocket 代理到 UnrealIRCd
    location /ws {
        proxy_pass http://127.0.0.1:8067;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    # 图片静态资源目录（后续上传功能复用）
    location /uploads/ {
        alias /var/www/irc/uploads/;
        expires 30d;
    }
}

4. 启用配置
bash

# 禁用默认站点
sudo unlink /etc/nginx/sites-enabled/default

# 启用 IRC 站点
sudo ln -s /etc/nginx/sites-available/irc /etc/nginx/sites-enabled/

# 校验并重启
sudo nginx -t
sudo systemctl restart nginx
sudo systemctl enable nginx

三、单文件 Web IRC 客户端（核心交付物）
部署方式
创建文件 /var/www/irc/index.html，写入以下完整代码。零外部依赖、零服务端逻辑，纯浏览器原生运行。
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
        #header { padding: 8px 12px; background: #f5f5f5; border-bottom: 1px solid #ddd; font-size: 14px; }
        #messages { flex: 1; overflow-y: auto; padding: 12px; line-height: 1.5; font-size: 14px; }
        .msg { margin-bottom: 6px; word-break: break-all; }
        .nick { font-weight: bold; margin-right: 6px; color: #2563eb; }
        .msg img { max-width: 300px; max-height: 200px; display: block; margin-top: 4px; border-radius: 4px; }
        #input-area { display: flex; padding: 8px; border-top: 1px solid #ddd; gap: 8px; }
        #nick-input { width: 120px; padding: 8px; border: 1px solid #ccc; border-radius: 4px; }
        #msg-input { flex: 1; padding: 8px; border: 1px solid #ccc; border-radius: 4px; }
        button { padding: 8px 16px; background: #2563eb; color: white; border: none; border-radius: 4px; cursor: pointer; }
        button:disabled { background: #94a3b8; }
        #status { margin-left: 8px; color: #666; }
    </style>
</head>
<body>
    <div id="header">
        <span id="status">未连接</span>
    </div>
    <div id="messages"></div>
    <div id="input-area">
        <input type="text" id="nick-input" placeholder="昵称" maxlength="20">
        <input type="text" id="msg-input" placeholder="输入消息，回车发送">
        <button id="send-btn" disabled>发送</button>
    </div>

    <script>
        const wsUrl = `ws://${window.location.host}/ws`;
        const channel = "#main";
        let ws = null;
        let connected = false;

        const msgInput = document.getElementById('msg-input');
        const nickInput = document.getElementById('nick-input');
        const sendBtn = document.getElementById('send-btn');
        const messagesDiv = document.getElementById('messages');
        const statusSpan = document.getElementById('status');

        // 生成默认设备昵称
        nickInput.value = "device_" + Math.floor(Math.random() * 10000);

        function connect() {
            statusSpan.textContent = "连接中...";
            ws = new WebSocket(wsUrl);

            ws.onopen = () => {
                const nick = nickInput.value.trim() || "guest";
                // IRC 标准握手
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

            ws.onerror = () => {
                statusSpan.textContent = "连接失败";
            };
        }

        function parseIrcMessage(line) {
            // 处理 PING 保活，防止连接超时断开
            if (line.startsWith("PING")) {
                ws.send("PONG " + line.slice(5));
                return;
            }

            const parts = line.match(/^:([^!]+)!?[^ ]* ([^ ]+) ([^:]+)?(?::(.*))?$/);
            if (!parts) return;

            const [, from, command, target, content] = parts;

            // 收到欢迎消息，自动加入主频道
            if (command === "001") {
                ws.send(`JOIN ${channel}`);
                connected = true;
                sendBtn.disabled = false;
                statusSpan.textContent = "已连接 - " + channel;
                addSystemMessage("已进入频道");
                return;
            }

            // 渲染频道消息
            if (command === "PRIVMSG" && target === channel) {
                addMessage(from, content);
            }
        }

        function addMessage(nick, text) {
            const div = document.createElement('div');
            div.className = "msg";
            
            // 图片链接自动识别并内嵌渲染
            const imgRegex = /(https?:\/\/[^\s]+\.(jpg|jpeg|png|gif|webp))/gi;
            const html = text.replace(imgRegex, '<img src="$1" alt="图片">');
            
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

        // 页面加载自动连接
        window.addEventListener('load', connect);
    </script>
</body>
</html>

权限设置
bash

sudo chown www-data:www-data /var/www/irc/index.html

四、终端使用方式（全架构通用）
任意设备打开系统自带浏览器，访问：
plaintext

http://<x86服务器IP地址>

    页面自动生成随机昵称，可自行修改
    自动连接并加入 #main 主频道
    输入文字回车发送，图片直链会自动渲染为图片
    断线自动重连，无需人工干预

五、验证清单（交付前自检）

    UnrealIRCd 进程正常：sudo systemctl status unrealircd
    Nginx 进程正常：sudo systemctl status nginx
    本地端口监听正常：ss -tlnp | grep -E '80|8067'
    浏览器访问服务器 IP 可正常打开页面并显示「已连接」
    两台设备同时接入，可互相收发消息、中文无乱码

Live ISO 启动 可正常一键 run
