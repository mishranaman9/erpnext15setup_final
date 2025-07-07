#!/bin/bash

# Script to install ERPNext version 15 on Ubuntu, tailored for existing MariaDB setup
# Logs to /var/log/erpnext_install.log
# Run as root or with sudo

# Exit on error
set -e

# Logging setup
LOG_FILE="/var/log/erpnext_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[$(date)] Starting ERPNext installation..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root or with sudo."
    exit 1
fi

# Check disk space (minimum 40GB recommended)
echo "[$(date)] Checking disk space..."
if [ $(df -k / | tail -1 | awk '{print $4}') -lt 40000000 ]; then
    echo "Error: Insufficient disk space. At least 40GB is recommended."
    exit 1
fi

# Prompt for backup
echo "WARNING: Ensure you have backed up your MariaDB databases before proceeding."
echo "Run 'mysqldump -u root -p --all-databases > backup.sql' to create a backup."
read -p "Have you backed up your databases? (y/n): " backup_confirmed
if [ "$backup_confirmed" != "y" ]; then
    echo "Please back up your databases and try again."
    exit 1
fi

# Prompt for MariaDB root password
read -s -p "Enter MariaDB root password: " DB_ROOT_PASSWORD
echo

# Prompt for ERPNext site name
read -p "Enter ERPNext site name (e.g., site1.local): " SITE_NAME
if [ -z "$SITE_NAME" ]; then
    echo "Error: Site name cannot be empty."
    exit 1
fi

# Check if MariaDB is running
echo "[$(date)] Checking MariaDB service..."
if ! systemctl is-active --quiet mariadb; then
    echo "Error: MariaDB service is not running. Start it with 'sudo systemctl start mariadb'."
    exit 1
fi

# Check for port conflicts (80 for nginx, 8000 for development)
echo "[$(date)] Checking for port conflicts..."
if netstat -tuln | grep -E ':80|:8000' > /dev/null; then
    echo "Error: Ports 80 or 8000 are in use. Free them before proceeding."
    exit 1
fi

# Update system and install dependencies
echo "[$(date)] Updating system and installing dependencies..."
apt update && apt upgrade -y
apt install -y python3 python3-pip python3-dev python3-setuptools python3-venv \
    redis-server nginx git curl nodejs supervisor wkhtmltopdf
npm install -g yarn

# Install frappe-bench
echo "[$(date)] Installing frappe-bench..."
pip3 install --no-cache-dir frappe-bench

# Create frappe user
echo "[$(date)] Creating frappe user..."
if ! id "frappe" &>/dev/null; then
    adduser --disabled-password --gecos "" frappe
    usermod -aG sudo frappe
fi

# Set up bench directory
echo "[$(date)] Setting up bench directory..."
su - frappe -c "bench init --frappe-branch version-15 frappe-bench"
cd /home/frappe/frappe-bench

# Check if Galera is enabled and disable if not needed
echo "[$(date)] Checking MariaDB Galera settings..."
if grep -q "wsrep_on=ON" /etc/mysql/mariadb.conf.d/*; then
    echo "Galera cluster detected. Disabling wsrep_on if not needed."
    sed -i 's/wsrep_on=ON/wsrep_on=OFF/' /etc/mysql/mariadb.conf.d/*.cnf
    systemctl restart mariadb
fi

# Create new ERPNext site
echo "[$(date)] Creating new ERPNext site: $SITE_NAME..."
su - frappe -c "bench new-site $SITE_NAME --db-root-password \"$DB_ROOT_PASSWORD\" --install-app erpnext --source https://github.com/frappe/erpnext --branch version-15"

# Set up production
echo "[$(date)] Configuring production environment..."
sudo bench setup production frappe
su - frappe -c "bench restart"

# Install certbot for SSL (optional)
echo "[$(date)] Installing certbot for SSL..."
apt install -y python3-certbot-nginx

# Set permissions
echo "[$(date)] Setting permissions..."
chown -R frappe:frappe /home/frappe/frappe-bench
chmod -R 755 /home/frappe/frappe-bench

# Save credentials
echo "[$(date)] Saving credentials..."
ADMIN_PASSWORD=$(su - frappe -c "cat /home/frappe/frappe-bench/sites/$SITE_NAME/site_config.json" | grep admin_password | awk -F'"' '{print $4}')
echo "ERPNext credentials:" > /home/frappe/frappe_passwords.txt
echo "Site: $SITE_NAME" >> /home/frappe/frappe_passwords.txt
echo "Administrator Password: $ADMIN_PASSWORD" >> /home/frappe/frappe_passwords.txt
echo "MariaDB Root Password: [Not saved for security]" >> /home/frappe/frappe_passwords.txt
chown frappe:frappe /home/frappe/frappe_passwords.txt

# Verify services
echo "[$(date)] Verifying services..."
systemctl restart nginx supervisor
if systemctl is-active --quiet nginx && systemctl is-active --quiet supervisor; then
    echo "Services started successfully."
else
    echo "Error: Failed to start nginx or supervisor. Check logs in $LOG_FILE."
    exit 1
fi

# Final instructions
echo "[$(date)] ERPNext installation complete!"
echo "Access ERPNext at http://<server_ip> or http://$SITE_NAME:8000 (development mode)"
echo "Login with Username: Administrator, Password: See /home/frappe/frappe_passwords.txt"
echo "To enable SSL, run: sudo certbot --nginx -d <your_domain>"
echo "Logs saved to $LOG_FILE"
