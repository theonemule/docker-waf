#!/bin/sh

VERSION_MOD_SECURITY=$1

#update and install dependencies
apt-get update
apt-get install -y git wget build-essential libpcre3 libpcre3-dev libssl-dev libtool autoconf apache2-dev libxml2-dev libcurl4-openssl-dev

#make modsecurity
cd /usr/src/
git clone --depth 1 -b v${VERSION_MOD_SECURITY} --single-branch https://github.com/SpiderLabs/ModSecurity.git /usr/src/modsecurity
cd /usr/src/modsecurity
./autogen.sh
./configure --enable-standalone-module --disable-mlogc
make

#make nginx
cd /
wget http://nginx.org/download/nginx-1.10.2.tar.gz
tar xvzf nginx-1.10.2.tar.gz
cd ../nginx-1.10.2
./configure --user=root --group=root --with-debug --with-ipv6 --with-http_ssl_module --add-module=/usr/src/modsecurity/nginx/modsecurity --with-http_ssl_module --without-http_access_module --without-http_auth_basic_module --without-http_autoindex_module --without-http_empty_gif_module --without-http_fastcgi_module --without-http_referer_module --without-http_memcached_module --without-http_scgi_module --without-http_split_clients_module --without-http_ssi_module --without-http_uwsgi_module
make
make install

