#!/bin/bash

# ================= 环境变量缺省值 =================
ROOT_PASS=${ROOT_PASSWORD:-"DefaultPass123!"}
D_SITE1=${DOMAIN_SITE1:-"site1.example.com"}
D_SITE2=${DOMAIN_SITE2:-"site2.example.com"}
D_SITE3=${DOMAIN_SITE3:-"site3.example.com"}
D_SITE4=${DOMAIN_SITE4:-"site4.example.com"}
# ================================================

echo ">>> Setting Root Password..."
echo "root:$ROOT_PASS" | chpasswd

# 准备持久化配置目录
mkdir -p /data/config

# ==========================================
# 函数: 配置文件持久化
# ==========================================
link_config() {
    sys_path=$1; data_path=$2; init_func=$3
    if [ ! -e "$data_path" ]; then
        echo ">>> Initializing config: $data_path"
        mkdir -p $(dirname "$data_path")
        if [ -n "$init_func" ]; then eval "$init_func"; elif [ -e "$sys_path" ]; then cp -r "$sys_path" "$data_path"; fi
    else
        echo ">>> Using existing config: $data_path"
    fi
    rm -rf "$sys_path"
    ln -s "$data_path" "$sys_path"
}

# --- 1. 数据持久化 (MySQL & WWW) ---
if [ ! -d "/data/mysql" ]; then
    echo ">>> Initializing MySQL data..."
    if [ -d "/var/lib/mysql" ]; then mv /var/lib/mysql /data/mysql; else mkdir -p /data/mysql; fi
else
    rm -rf /var/lib/mysql
fi
ln -s /data/mysql /var/lib/mysql

if [ ! -d "/data/www" ]; then
    echo ">>> Initializing Web data..."
    if [ -d "/var/www/html" ]; then mv /var/www/html /data/www; else mkdir -p /data/www; fi
else
    rm -rf /var/www/html
fi
ln -s /data/www /var/www/html

# 修复权限
chown -R mysql:mysql /data/mysql
chown -R www-data:www-data /data/www
mkdir -p /run/mysqld && chown -R mysql:mysql /run/mysqld
mkdir -p /run/php

# --- 2. 持久化 Nginx 配置 ---
init_nginx() {
    sed -i "s/site1.example.com/$D_SITE1/g" /etc/nginx/sites-available/default
    sed -i "s/site2.example.com/$D_SITE2/g" /etc/nginx/sites-available/default
    sed -i "s/site3.example.com/$D_SITE3/g" /etc/nginx/sites-available/default
    sed -i "s/site4.example.com/$D_SITE4/g" /etc/nginx/sites-available/default
    cp -r /etc/nginx/sites-available /data/config/nginx
}
link_config "/etc/nginx/sites-enabled" "/data/config/nginx" "init_nginx"

# --- 3. 持久化 Supervisor 配置 ---
link_config "/etc/supervisor/conf.d/supervisord.conf" "/data/config/supervisord.conf"

# --- 4. 持久化 FRP 配置 ---
init_frp() {
cat > /data/config/frpc.toml <<EOF
[common]
serverAddr = "$FRPS_ADDR"
serverPort = $FRPS_PORT
token = "$FRPS_TOKEN"
logLevel = "error"
loginFailExit = false
tcpKeepAlive = 20
heartbeatInterval = 20
heartbeatTimeout = 30
transport.heartbeatInterval = 20
transport.heartbeatTimeout = 30

[[proxies]]
name = "ssh-vps"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = $REMOTE_PORT
useEncryption = true
useCompression = true

[[proxies]]
name = "web-site1"
type = "http"
localPort = 80
customDomains = ["$D_SITE1"]

[[proxies]]
name = "web-site2"
type = "http"
localPort = 80
customDomains = ["$D_SITE2"]

[[proxies]]
name = "web-site3"
type = "http"
localPort = 80
customDomains = ["$D_SITE3"]

[[proxies]]
name = "web-site4"
type = "http"
localPort = 80
customDomains = ["$D_SITE4"]
EOF
}
link_config "/frp/frpc.toml" "/data/config/frpc.toml" "init_frp"

# --- 5. 初始化 MySQL ---
if [ ! -d "/data/mysql/mysql" ]; then
    echo ">>> First time MySQL setup..."
    mysqld --initialize-insecure --user=mysql
fi

# --- 6. 启动临时 MySQL ---
echo ">>> Starting temporary MySQL..."
/usr/bin/mysqld_safe --skip-networking --socket=/var/run/mysqld/mysqld.sock &
TEMP_PID=$!

echo ">>> Waiting for MySQL socket..."
for i in {1..30}; do
    if [ -S /var/run/mysqld/mysqld.sock ]; then break; fi
    sleep 1
done

echo ">>> Configuring Databases..."
mysql -u root --socket=/var/run/mysqld/mysqld.sock -e "CREATE DATABASE IF NOT EXISTS db_site1;"
mysql -u root --socket=/var/run/mysqld/mysqld.sock -e "CREATE DATABASE IF NOT EXISTS db_site2;"
mysql -u root --socket=/var/run/mysqld/mysqld.sock -e "CREATE DATABASE IF NOT EXISTS db_site3;"
mysql -u root --socket=/var/run/mysqld/mysqld.sock -e "CREATE DATABASE IF NOT EXISTS db_site4;"
mysql -u root --socket=/var/run/mysqld/mysqld.sock -e "CREATE USER IF NOT EXISTS 'admin'@'%' IDENTIFIED BY '$ROOT_PASS'; GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%'; FLUSH PRIVILEGES;"

echo ">>> Shutting down temporary MySQL..."
mysqladmin -u root --socket=/var/run/mysqld/mysqld.sock shutdown
wait $TEMP_PID
echo ">>> Temporary MySQL stopped."

# --- 7. 补全网站目录 和 phpMyAdmin (新增部分) ---
mkdir -p /data/www/{default,site1,site2,site3,site4}

# 生成 phpMyAdmin 配置文件 (如果不存在)
if [ ! -f "/usr/share/phpmyadmin/config.inc.php" ]; then
    # 生成一个随机密钥
    RANDOM_SECRET=$(openssl rand -base64 32)
    cat > /usr/share/phpmyadmin/config.inc.php <<EOF
<?php
\$cfg['blowfish_secret'] = '$RANDOM_SECRET';
\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';

/* --- 修改这里：强制使用 TCP 连接，解决 Permission denied 问题 --- */
\$cfg['Servers'][\$i]['host'] = '127.0.0.1'; 

\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';

/* --- 修复 HTTPS 协议不匹配警告 --- */
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    \$cfg['PmaAbsoluteUri'] = 'https://' . \$_SERVER['HTTP_HOST'] . '/phpmyadmin/';
} else {
    \$cfg['PmaAbsoluteUri'] = 'https://' . \$_SERVER['HTTP_HOST'] . '/phpmyadmin/';
}
?>
EOF
fi

# 将 phpMyAdmin 软链接到 default 站点，使其可访问
if [ ! -d "/data/www/default/phpmyadmin" ]; then
    echo ">>> Linking phpMyAdmin to default site..."
    ln -s /usr/share/phpmyadmin /data/www/default/phpmyadmin
fi

if [ ! -f /data/www/default/index.php ]; then
    echo "<?php phpinfo(); ?>" > /data/www/default/index.php
    echo "<h1>VPS Ready</h1><p>phpMyAdmin: <a href='/phpmyadmin'>/phpmyadmin</a></p>" > /data/www/default/index.html
fi

echo ">>> Starting Supervisord..."
exec /usr/bin/supervisord -c /data/config/supervisord.conf
