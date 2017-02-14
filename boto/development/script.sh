#!/bin/bash
{
disk="/dev/xvdb"
lv_size=20 ##in GB
server=SERVER
env=ENV
hostname="$server-$env.$server.com"
swap_size="2048" #in MB
lv_size=$((lv_size-1))

if [[ "$1" == "input" ]];then
    echo -n "Setup hostname: "
    read hostname
    echo -n "Set lv size: "
    read lv_size
fi

echo "setting hostname"
sed -i 's/127.0.0.1.*/127.0.0.1 localhost localhost.localdomain/g' /etc/hosts
hostname $hostname
sed -i.bak "s/\(HOSTNAME\).*/\1=$hostname/g" /etc/sysconfig/network 

echo "enabling wheel"
echo "%wheel ALL=NOPASSWD: ALL" >> /etc/sudoers

echo "Creating LVM lv_app"
pvcreate $disk
vgcreate vg_app $disk
lvcreate -L"$lv_size"G -n lv_app vg_app
mkfs.ext4 /dev/vg_app/lv_app
echo "/dev/mapper/vg_app-lv_app /apps ext4 defaults   0   0"   >> /etc/fstab
mkdir /apps
mount -a

echo "creating directory structures"
pushd /apps
mkdir node-apps lib local tmp src backup logs mysql mongo
chmod 777 /apps/tmp/
popd

echo "Updating Yum Updates"

yum update
yum groupinstall 'Development Tools'

echo "installing node and pm2" 
pushd /apps/lib
yum install -y wget
yum install -y git	
wget https://nodejs.org/dist/v4.4.7/node-v4.4.7-linux-x64.tar.gz
tar -zxf node-v4.4.7-linux-x64.tar.gz
ln -s -f /apps/lib/node-v4.4.7-linux-x64/bin/node /usr/bin/node
ln -s -f /apps/lib/node-v4.4.7-linux-x64/bin/npm /usr/bin/npm
npm install pm2
useradd pm2 -d /apps/pm2
rm -f `which pm2`
echo "export PATH=$PATH:/apps/lib/node_modules/pm2/bin" >> /apps/pm2/.bashrc
echo "export HISTTIMEFORMAT='%d/%m/%y %T	'" >> /apps/pm2/.bashrc
echo "export LC_ALL=en_US.UTF-8" >> /apps/pm2/.bashrc
chown pm2. /apps/pm2/.bashrc
chown pm2. /apps/node-apps
popd 

echo "Custom access to pm2"
echo $hostname | grep -E 'dev|poc' 
if [[ $? == 0 ]];then
    echo 'granting sudo access to pm2'
    usermod -G wheel pm2
fi

echo "Creating swap file"
dd if=/dev/zero of=/apps/.swap bs=1M count=$swap_size
chmod 0600 /apps/.swap
mkswap /apps/.swap
swapon /apps/.swap
echo "/apps/.swap    none    swap    sw    0   0"  >> /etc/fstab 

echo "installing mongo"
echo "[mongodb-org-3.2]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/6/mongodb-org/3.2/x86_64/
gpgcheck=0
enabled=1" >> /etc/yum.repos.d/mongodb-org-3.2.repo
yum install -y mongodb-org
sed -i.bak 's/dbPath.*/dbPath: \/apps\/mongo/g'  /etc/mongod.conf
sed -i.bak 's/bindIp: 127.0.0.1/bindIp: 0.0.0.0/g' /etc/mongod.conf
chown -R mongod. /apps/mongo
service mongod start

echo "installing redis"
rpm -Uvh http://rpms.famillecollet.com/enterprise/remi-release-6.rpm 
yum install -y redis --enablerepo=epel

echo "installing mysql"
wget http://repo.mysql.com/mysql-community-release-el6-5.noarch.rpm
rpm -ivh mysql-community-release-el6-5.noarch.rpm
rpm -Uvh ftp://ftp.pbone.net/mirror/ftp5.gwdg.de/pub/opensuse/repositories/home:/michalstrnad/CentOS_CentOS-6/x86_64/pwgen-2.06-278.1.x86_64.rpm
yum install -y mysql-server
sed -i.bak 's/\/var\/lib\/mysql/\/apps\/mysql/g' /etc/my.conf
chown -R mysql. /apps/mysql
service mysqld start
password=`pwgen -s 16 1`
echo "MySQL password is $password"
mysql_secure_installation <<EOF

y
$password
$password
y
y
y
y
EOF
echo "export MYSQL_USER=root">> /apps/pm2/.bashrc
echo "export MYSQL_PASS=$password">> /apps/pm2/.bashrc

export LC_ALL=C
adminpass=`pwgen -s 16 1`
userpass=`pwgen -s 16 1`
mongo <<EOF
use admin
db.createUser({user : 'mongoadmin', pwd : '$adminpass', roles : ['root']})
use $server-dev
db.createUser({user : '$server', pwd : '$userpass', roles : ['readWrite']})
use $server-test
db.createUser({user : '$server', pwd : '$userpass', roles : ['readWrite']})
use $server-live
db.createUser({user : '$server', pwd : '$userpass', roles : ['readWrite']})
EOF
echo "export ADMIN_PASS='$adminpass'" >> /apps/pm2/.bashrc
echo "export MONGO_USER='$server'" >> /apps/pm2/.bashrc
echo "export MONGO_PASS='$userpass'" >> /apps/pm2/.bashrc
echo "export MONGO_DBNAME_DEV='$server-dev'" >> /apps/pm2/.bashrc
echo "export MONGO_DBNAME_TEST='$server-test'" >> /apps/pm2/.bashrc
echo "export MONGO_DBNAME_LIVE='$server-live'" >> /apps/pm2/.bashrc
sed -i.bak 's/#security:/security:\n  authorization: enabled/g' /etc/mongod.conf
sudo service mongod restart

echo "Installation of Imagemagick and graphicsmagick"
yum install -y gcc libpng libjpeg libpng-devel libjpeg-devel ghostscript libtiff libtiff-devel freetype freetype-devel
wget ftp://ftp.graphicsmagick.org/pub/GraphicsMagick/1.3/GraphicsMagick-1.3.21.tar.gz
tar zxvf GraphicsMagick-1.3.21.tar.gz
cd GraphicsMagick-1.3.21
./configure --enable-shared
make
make install
sudo ln -s /usr/local/bin/gm /usr/bin/
gm version
yum install -y php-pear gcc php-devel php-pear
yum install -y ImageMagick ImageMagick-devel

echo "installing other packages"
yum install ant ant-contrib
yum install -y telnet
yum groupinstall 'Development Tools'
yum install -y sysstat
yum install -y httpd24
sed -i "s/#ServerName www.example.com:80/ServerName $hostname:80/g" /etc/httpd/conf/httpd.conf
sed -i "s/Indexes//g" /etc/httpd/conf/httpd.conf 

echo "updating config"
mv /var/www/ /apps/
ln -s /apps/www /var/www
mv /var/log /apps/logs/var_log
ln -s /apps/logs/var_log /var/log
#chown -R mysql. /apps/mysql

echo "Installing phpmyadmin"
rpm -Uvh http://download.fedoraproject.org/pub/epel/6/i386/epel-release-6-8.noarch.rpm
rpm -Uvh http://rpms.famillecollet.com/enterprise/remi-release-6.rpm
rpm -e `rpm -qa | grep php`
rpm -e `rpm -qa | grep httpd`
yum install -y php56
yum --enablerepo=remi install -y phpmyadmin
sed -i 's/local/all granted/g'  /etc/httpd/conf.d/phpMyAdmin.conf
sed -i 's/Deny from All/Allow from All/g'  /etc/httpd/conf.d/phpMyAdmin.conf
sed -i 's/Allow from None/#Allow from None/g'  /etc/httpd/conf.d/phpMyAdmin.conf

chkconfig httpd on
chkconfig mongod on
chkconfig redis on
chkconfig mysqld on

service httpd start
service redis start

} | tee /tmp/setup.log
