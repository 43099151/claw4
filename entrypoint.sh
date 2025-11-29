#!/bin/bash

# ================= 配置区 =================
ROOT_PASS=${ROOT_PASSWORD:-"DefaultPass123!"}
# 默认域名占位符，如果没传环境变量
D_SITE1=${DOMAIN_SITE1:-"site1.example.com"}
D_SITE2=${DOMAIN_SITE2:-"site2.example.com"}
D_SITE3=${DOMAIN_SITE3:-"site3.example.com"}
D_SITE4=${DOMAIN_SITE4:-"site4.example.com"}
# ==========================================

echo ">>> Setting Root Password..."
echo "root:$ROOT_PASS" | chpasswd

# --- 1. 数据持久化处理 (Symlink Magic) ---
# 功能：如果 /data 下没有数据，就把原本的数据移过去；如果有，就软链接回来
persist_dir() {
    src=$1  # 原系统路径 /var/lib/mysql
    dst=$2  # 目标路径 /data/mysql
    
    if [ ! -d "/data" ]; then echo "Warning: /data volume not mounted!"; return; fi

    if [ -d "$dst" ]; then
        echo ">>> Found existing data in $dst, linking..."
        rm -rf "$src"
    else
        echo ">>> Initializing data to $dst..."
        mkdir -p $(dirname "$dst")
        if [ -d "$src" ]; then mv "$src" "$dst"; else mkdir -p "$dst"; fi
    fi
    ln -s "$dst" "$src"
}

# 停止服务以防万一
service mysql stop
service nginx stop

# 执行迁移
persist_dir "/var/lib/mysql" "/data/mysql"
persist_dir "/var/www/html"  "/data/www"

# 修复权限
chown -R mysql:mysql /data/mysql
chown -R www-data:www-data /data/www
mkdir -p /run/mysqld && chown -R mysql:mysql /run/mysqld
mkdir -p /run/php

# --- 2. 创建 4 个网站目录结构 ---
mkdir -p /data/www/{default,site1,site2,site3,site4}
# 创建一个测试文件
if [ ! -f /data/www/default/index.php ]; then
    echo "<?php phpinfo(); ?>" > /data/www/default/index.php
    echo "<h1>VPS Ready</h1>" > /data/www/default/index.html
fi

# --- 3. 动态替换 Nginx 域名 ---
# 将 nginx 配置里的占位符替换为环境变量里的真实域名
sed -i "s/site1.example.com/$D_SITE1/g" /etc/nginx/sites-available/default
sed -i "s/site2.example.com/$D_SITE2/g" /etc/nginx/sites-available/default
sed -i "s/site3.example.com/$D_SITE3/g" /etc/nginx/sites-available/default
sed -i "s/site4.example.com/$D_SITE4/g" /etc/nginx/sites-available/default

# --- 4. 初始化 MySQL (如果为空) ---
if [ ! -d "/data/mysql/mysql" ]; then
    echo ">>> Initializing MySQL Database..."
    mysqld --initialize-insecure --user=mysql
fi

# --- 5. 启动临时 MySQL 以创建数据库 ---
echo ">>> Starting temporary MySQL for setup..."
/usr/bin/mysqld_safe --skip-networking &
PID=$!
sleep 10

echo ">>> Creating Databases..."
mysql -u root -e "CREATE DATABASE IF NOT EXISTS db_site1;"
mysql -u root -e "CREATE DATABASE IF NOT EXISTS db_site2;"
mysql -u root -e "CREATE DATABASE IF NOT EXISTS db_site3;"
mysql -u root -e "CREATE DATABASE IF NOT EXISTS db_site4;"
# 创建超级用户 admin，密码同 root 密码 (也可自行修改)
mysql -u root -e "CREATE USER IF NOT EXISTS 'admin'@'%' IDENTIFIED BY '$ROOT_PASS'; GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%'; FLUSH PRIVILEGES;"

# 关闭临时 MySQL，交给 Supervisor 接管
kill $PID
sleep 3

# --- 6. 生成 FRP 配置 ---
cat > /frp/frpc.ini <<EOF
[common]
server_addr = $FRPS_ADDR
server_port = $FRPS_PORT
token = $FRPS_TOKEN

[ssh-vps]
type = tcp
local_ip = 127.0.0.1
local_port = 22
remote_port = $REMOTE_PORT

[web-site1]
type = http
local_port = 80
custom_domains = $D_SITE1

[web-site2]
type = http
local_port = 80
custom_domains = $D_SITE2

[web-site3]
type = http
local_port = 80
custom_domains = $D_SITE3

[web-site4]
type = http
local_port = 80
custom_domains = $D_SITE4
EOF

echo ">>> Starting Supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
