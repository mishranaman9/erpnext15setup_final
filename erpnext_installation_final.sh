#!/bin/bash

LOGFILE="/var/log/erpnext15_install.log"
exec > >(tee -a "$LOGFILE") 2>&1

set -euo pipefail

color() { echo -e "\033[$2m$1\033[0m"; }
info() { color "[INFO] $1" "1;34"; }
warn() { color "[WARN] $1" "1;33"; }
error() { color "[ERROR] $1" "1;31"; }

trap 'error "Script failed at line $LINENO. Check the log: $LOGFILE"' ERR

read -p "Enter system username for Frappe (e.g., frappe): " FRAPPE_USER
sudo adduser $FRAPPE_USER

read -p "Enter site name (e.g., erp.mydomain.com): " SITE_NAME
read -s -p "Enter MySQL root password to set: " MYSQL_ROOT_PWD
echo
read -s -p "Enter ERPNext Administrator password: " ADMIN_PASSWORD
echo

info "Updating and installing base packages..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl software-properties-common mariadb-server mariadb-client \
  redis-server xvfb libfontconfig libxrender1 libxext6 libjpeg62-turbo libx11-dev \
  zlib1g-dev libssl-dev libmysqlclient-dev python3-dev python3.10-dev python3-setuptools \
  python3-pip python3-distutils python3.10-venv npm cron supervisor nginx || error "Dependency install failed."

info "Checking required services..."
for svc in mysql redis-server nginx supervisor; do
  if ! systemctl is-active --quiet $svc; then
    warn "$svc is not running. Restarting..."
    sudo systemctl restart $svc
  else
    info "$svc is running."
  fi
done

info "Installing patched wkhtmltopdf..."
if ! wkhtmltopdf -V 2>/dev/null | grep -q "0.12.6"; then
  wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
  sudo apt install -y ./wkhtmltox_0.12.6.1-2.jammy_amd64.deb
  rm wkhtmltox_0.12.6.1-2.jammy_amd64.deb
else
  info "wkhtmltopdf already installed."
fi

info "Securing MySQL root user..."
sudo mysql -u root <<MYSQL_SCRIPT || warn "MySQL setup skipped or failed. Check status manually."
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PWD';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

info "Tuning MySQL configuration..."
sudo tee /etc/mysql/my.cnf > /dev/null <<EOF
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF
sudo systemctl restart mysql

info "Installing Node.js & Yarn as $FRAPPE_USER..."
sudo -u $FRAPPE_USER bash <<'EOF'
cd ~
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
export NVM_DIR="$HOME/.nvm"
source $NVM_DIR/nvm.sh
nvm install 18
npm install -g yarn
yarn add node-sass
EOF

info "Installing Frappe Bench and ERPNext..."
sudo -u $FRAPPE_USER bash <<EOF
cd ~
pip3 install frappe-bench honcho
bench init --frappe-branch version-15 frappe-bench
cd frappe-bench

bench new-site $SITE_NAME --admin-password $ADMIN_PASSWORD --mariadb-root-password $MYSQL_ROOT_PWD
bench use $SITE_NAME

bench get-app payments
bench get-app --branch version-15 erpnext
bench get-app --branch version-15 hrms
bench get-app chat

bench --site $SITE_NAME install-app erpnext
bench --site $SITE_NAME install-app hrms
bench --site $SITE_NAME install-app chat

info "Running bench update --reset (to fix inconsistencies)"
bench update --reset || warn "bench update encountered issues, check log"

bench --site $SITE_NAME enable-scheduler
bench --site $SITE_NAME set-maintenance-mode off
EOF

info "Fixing ownership for $FRAPPE_USER’s home and bench directory..."
sudo chown -R $FRAPPE_USER:$FRAPPE_USER /home/$FRAPPE_USER

info "Setting up NGINX and Supervisor..."
sudo -u $FRAPPE_USER -H bash -c "cd ~/frappe-bench && bench setup nginx"
sudo ln -sf /home/$FRAPPE_USER/frappe-bench/config/nginx.conf /etc/nginx/sites-enabled/frappe
sudo nginx -t && sudo systemctl reload nginx

sudo -u $FRAPPE_USER -H bash -c "cd ~/frappe-bench && bench setup supervisor"
sudo ln -sf /home/$FRAPPE_USER/frappe-bench/config/supervisor.conf /etc/supervisor/conf.d/frappe.conf
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl restart all

sudo systemctl enable nginx
sudo systemctl enable supervisor

info "🎉 ERPNext 15, HRMS, and Chat setup is complete!"
echo "🔗 Access: http://<your_server_ip>/"
echo "👤 Login: administrator"
echo "🔑 Password: $ADMIN_PASSWORD"
echo "📄 Log file: $LOGFILE"
