#!/bin/sh

#configure env
ln -s /usr/local/nginx/sbin/nginx /bin/nginx
cp /usr/src/modsecurity/unicode.mapping /usr/local/nginx/conf/
mkdir -p /opt/modsecurity/var/audit/

#install signature
apt-get update
apt-get install -y git libpcre3 libpcre3-dev libssl-dev libtool autoconf apache2-dev libxml2-dev libcurl4-openssl-dev
git clone https://github.com/SpiderLabs/owasp-modsecurity-crs.git /usr/src/owasp-modsecurity-crs
cp -R /usr/src/owasp-modsecurity-crs/rules/ /usr/local/nginx/conf/
mv /usr/local/nginx/conf/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf{.example,}
mv /usr/local/nginx/conf/rules/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf{.example,}

apt-get purge -y git
apt-get autoremove -y