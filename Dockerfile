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

# 2. 安装 FRP (v0.54.0)
WORKDIR /tmp
RUN wget -O frp.tar.gz https://github.com/fatedier/frp/releases/download/v0.54.0/frp_0.54.0_linux_amd64.tar.gz \
    && tar -zxvf frp.tar.gz \
    && mkdir -p /frp \
    && mv frp_*/frpc /frp/frpc \
    && chmod +x /frp/frpc \
    && rm -rf /tmp/*

# 3. 配置 SSH (含心跳保活)、PHP 和 MySQL 运行目录
RUN mkdir -p /var/run/sshd /run/php /var/run/mysqld \
    && chown -R mysql:mysql /var/run/mysqld \
    && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config \
    # 修复 PAM 登录问题
    && sed -i 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' /etc/pam.d/sshd \
    # --- 关键：配置 SSH 心跳，防止 Serverless 平台断开连接 ---
    && echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config \
    && echo "ClientAliveCountMax 3" >> /etc/ssh/sshd_config

# 4. 复制配置文件 (作为初始模板)
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY nginx-app.conf /etc/nginx/sites-available/default
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 5. 声明挂载点
VOLUME ["/data"]

# 6. 启动
CMD ["/entrypoint.sh"]
