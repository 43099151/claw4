FROM ubuntu:22.04

# 避免交互式安装卡住
ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_BREAK_SYSTEM_PACKAGES=1

# 1. 安装基础工具、网络工具、开发工具、服务
RUN apt-get update && apt-get install -y \
    supervisor \
    openssh-server \
    nginx \
    mysql-server \
    # --- PHP 全家桶 (PHP 8.1) ---
    php-fpm \
    php-mysql \
    php-curl \
    php-gd \
    php-mbstring \
    php-xml \
    php-zip \
    php-bcmath \
    # --- 常用工具 ---
    curl wget sshpass net-tools iputils-ping \
    tar gzip unzip busybox nano vim bash sudo \
    git build-essential python3 python3-dev python3-pip python3-venv \
    # --- 清理缓存 ---
    && rm -rf /var/lib/apt/lists/*

# 2. 使用 APT 仓库安装 Tailscale（稳定版，自动适配 Linux）
RUN curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null \
    && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list \
    && apt-get update \
    && apt-get install -y tailscale \
    && rm -rf /var/lib/apt/lists/*

# 3. 安装 phpMyAdmin (新增步骤)
# 下载 5.2.1 版本
RUN wget https://files.phpmyadmin.net/phpMyAdmin/5.2.1/phpMyAdmin-5.2.1-all-languages.zip \
    && unzip phpMyAdmin-5.2.1-all-languages.zip \
    && mv phpMyAdmin-5.2.1-all-languages /usr/share/phpmyadmin \
    && rm phpMyAdmin-5.2.1-all-languages.zip \
    # 创建临时目录
    && mkdir -p /usr/share/phpmyadmin/tmp \
    && chown -R www-data:www-data /usr/share/phpmyadmin \
    && chmod 777 /usr/share/phpmyadmin/tmp

# 4. 配置 SSH (含心跳保活)、PHP 和 MySQL 运行目录
RUN mkdir -p /var/run/sshd /run/php /var/run/mysqld \
    && chown -R mysql:mysql /var/run/mysqld \
    && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' /etc/pam.d/sshd \
    && echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config \
    && echo "ClientAliveCountMax 3" >> /etc/ssh/sshd_config

# 5. 复制配置文件
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY nginx-app.conf /etc/nginx/sites-available/default
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 6. 声明挂载点
VOLUME ["/data"]

# 7. 启动
CMD ["/entrypoint.sh"]
