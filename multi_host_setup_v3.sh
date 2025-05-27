#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 全局变量
declare -a HOSTS
HOST_COUNT=0
COMMON_PASSWORD=""
SYSTEM_TYPE=""
IP_PREFIX=""

# 检查系统类型
check_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo -e "${GREEN}检测到系统类型: $ID $VERSION_ID${NC}"
        case $ID in
            ubuntu|debian)
                SYSTEM_TYPE="debian"
                REPO_FILE="/etc/apt/sources.list"
                PKG_MANAGER="apt-get"
                ;;
            centos|rhel|fedora|rocky|almalinux)
                SYSTEM_TYPE="centos"
                REPO_FILE="/etc/yum.repos.d/CentOS-Base.repo"
                PKG_MANAGER="yum"
                ;;
            *)
                echo -e "${RED}不支持的系统类型: $ID${NC}"
                exit 1
                ;;
        esac
    else
        echo -e "${RED}无法检测系统类型${NC}"
        exit 1
    fi
}

# 检查 repo 源是否可用
check_repo_availability() {
    local ip=$1
    local pwd=$2
    
    echo -e "${YELLOW}正在检查主机 $ip 的repo源是否可用...${NC}"
    
    case $SYSTEM_TYPE in
        debian)
            result=$(sshpass -p "$pwd" ssh -o StrictHostKeyChecking=no root@$ip "apt-get update > /dev/null 2>&1 && echo 'OK' || echo 'FAIL'")
            ;;
        centos)
            result=$(sshpass -p "$pwd" ssh -o StrictHostKeyChecking=no root@$ip "yum makecache > /dev/null 2>&1 && echo 'OK' || echo 'FAIL'")
            ;;
    esac
    
    if [ "$result" == "OK" ]; then
        echo -e "${GREEN}主机 $ip repo源可用${NC}"
        return 0
    else
        echo -e "${RED}主机 $ip repo源不可用${NC}"
        return 1
    fi
}

# 更换为国内源
change_to_mirror() {
    local ip=$1
    local pwd=$2
    
    echo -e "${YELLOW}正在为主机 $ip 配置国内源...${NC}"
    
    case $SYSTEM_TYPE in
        debian)
            sshpass -p "$pwd" ssh root@$ip "
            cp /etc/apt/sources.list /etc/apt/sources.list.bak
            echo 'deb https://mirrors.aliyun.com/ubuntu/ \$(lsb_release -cs) main restricted universe multiverse
            deb https://mirrors.aliyun.com/ubuntu/ \$(lsb_release -cs)-security main restricted universe multiverse
            deb https://mirrors.aliyun.com/ubuntu/ \$(lsb_release -cs)-updates main restricted universe multiverse
            deb https://mirrors.aliyun.com/ubuntu/ \$(lsb_release -cs)-backports main restricted universe multiverse' > /etc/apt/sources.list
            apt-get update
            "
            ;;
        centos)
            sshpass -p "$pwd" ssh root@$ip "
            cp /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo.bak
            curl -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.aliyun.com/repo/Centos-7.repo
            sed -i -e '/mirrors.cloud.aliyuncs.com/d' -e '/mirrors.aliyuncs.com/d' /etc/yum.repos.d/CentOS-Base.repo
            yum makecache
            "
            ;;
    esac
    
    echo -e "${GREEN}主机 $ip 国内源配置完成${NC}"
}

# 安装必要工具
install_ssh_tools() {
    local ip=$1
    local pwd=$2
    
    echo -e "${YELLOW}正在为主机 $ip 安装SSH相关工具...${NC}"
    
    case $SYSTEM_TYPE in
        debian)
            sshpass -p "$pwd" ssh root@$ip "apt-get install -y sshpass openssh-client openssh-server"
            ;;
        centos)
            sshpass -p "$pwd" ssh root@$ip "yum install -y sshpass openssh-clients openssh-server"
            ;;
    esac
    
    sshpass -p "$pwd" ssh root@$ip "systemctl restart sshd"
    echo -e "${GREEN}主机 $ip SSH工具安装完成${NC}"
}

# 配置SSH互信
configure_ssh() {
    local pwd=$1
    
    echo -e "${YELLOW}开始配置SSH证书互信${NC}"
    
    # 生成SSH密钥对(本地)
    echo -e "${YELLOW}正在生成SSH密钥对...${NC}"
    if [ ! -f ~/.ssh/id_rsa ]; then
        ssh-keygen -t rsa -P "" -f ~/.ssh/id_rsa
    fi
    
    # 配置互信
    for IP in "${HOSTS[@]}"; do
        echo -e "${YELLOW}正在配置主机: $IP${NC}"
        
        # 复制公钥到远程主机
        sshpass -p "$pwd" ssh-copy-id -o StrictHostKeyChecking=no root@$IP
        
        # 将本地known_hosts复制到远程主机
        scp /root/.ssh/known_hosts root@$IP:/root/.ssh/known_hosts
        
        # 将远程主机公钥添加到本地known_hosts
        ssh-keyscan $IP >> ~/.ssh/known_hosts
        
        # 在所有主机之间建立互信
        for OTHER_IP in "${HOSTS[@]}"; do
            if [ "$IP" != "$OTHER_IP" ]; then
                ssh root@$IP "ssh-keyscan $OTHER_IP >> ~/.ssh/known_hosts"
            fi
        done
    done
    
    echo -e "${GREEN}SSH证书互信配置完成${NC}"
}

# 禁用密码登录
disable_password_login() {
    local pwd=$1
    
    read -p "是否要禁用密码登录? (y/n, 默认n): " choice
    if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
        echo -e "${YELLOW}正在禁用密码登录...${NC}"
        for IP in "${HOSTS[@]}"; do
            sshpass -p "$pwd" ssh root@$IP "sed -i 's/^#\?PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config"
            sshpass -p "$pwd" ssh root@$IP "systemctl restart sshd"
            echo -e "${GREEN}主机 $IP 已禁用密码登录${NC}"
        done
    else
        echo -e "${YELLOW}保持密码登录启用状态${NC}"
    fi
}

# 获取连续IP地址
get_sequential_ips() {
    local base_ip=$1
    local count=$2
    
    # 提取IP前缀和最后一位
    IFS='.' read -r -a ip_parts <<< "$base_ip"
    prefix="${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}."
    start=${ip_parts[3]}
    
    for ((i=0; i<count; i++)); do
        HOSTS+=("$prefix$((start+i))")
    done
}

# 主函数
main() {
    # 1. 检查本地系统类型
    check_system
    
    # 2. 获取主机信息
    read -p "请输入需要配置的主机数量: " HOST_COUNT
    
    read -p "请输入第一个主机的IP地址(如192.168.1.10): " FIRST_IP
    read -p "所有主机使用相同密码吗? (直接回车使用相同密码，或输入n使用不同密码): " SAME_PWD
    
    if [ "$SAME_PWD" != "n" ]; then
        read -s -p "请输入所有主机的共同密码: " COMMON_PASSWORD
        echo
        # 生成连续IP
        get_sequential_ips "$FIRST_IP" "$HOST_COUNT"
    else
        # 逐个输入IP和密码
        for ((i=1; i<=$HOST_COUNT; i++)); do
            if [ $i -eq 1 ]; then
                read -p "请输入主机${i}的IP地址: " IP
            else
                read -p "请输入主机${i}的IP地址(直接回车使用${IP_PREFIX}$((LAST_NUM+1)): " IP
                if [ -z "$IP" ]; then
                    IP="${IP_PREFIX}$((LAST_NUM+1))"
                fi
            fi
            
            # 提取IP前缀和最后一位
            IFS='.' read -r -a ip_parts <<< "$IP"
            IP_PREFIX="${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}."
            LAST_NUM=${ip_parts[3]}
            
            HOSTS+=($IP)
            read -s -p "请输入主机${i}的密码: " PWD
            echo
            PASSWORDS+=($PWD)
        done
    fi
    
    # 3. 检查所有主机的repo源并配置
    for IP in "${HOSTS[@]}"; do
        if [ "$SAME_PWD" != "n" ]; then
            PWD=$COMMON_PASSWORD
        else
            PWD=${PASSWORDS[$i]}
        fi
        
        if ! check_repo_availability "$IP" "$PWD"; then
            change_to_mirror "$IP" "$PWD"
        fi
        
        install_ssh_tools "$IP" "$PWD"
    done
    
    # 4. 配置SSH互信
    configure_ssh "$COMMON_PASSWORD"
    
    # 5. 可选禁用密码登录
    disable_password_login "$COMMON_PASSWORD"
    
    echo -e "${GREEN}所有配置完成!${NC}"
    echo -e "${YELLOW}配置的主机列表:${NC}"
    printf '%s\n' "${HOSTS[@]}"
}

# 执行主函数
main