FROM ubuntu:18.04
RUN apt-get update && \
	apt-get install -y wget nginx tar apt-utils autoconf automake build-essential git libcurl4-openssl-dev libgeoip-dev liblmdb-dev libpcre++-dev libtool libxml2-dev libyajl-dev pkgconf zlib1g-dev && \
	git clone --depth 1 -b v3/master --single-branch https://github.com/SpiderLabs/ModSecurity && \
	cd ModSecurity && \
	git submodule init && \
	git submodule update && \
	./build.sh && \
	./configure && \
	make && \
	make install && \
	cd / && \
	git clone --depth 1 https://github.com/SpiderLabs/ModSecurity-nginx.git && \
	wget http://nginx.org/download/nginx-1.14.0.tar.gz && \
	tar zxvf nginx-1.14.0.tar.gz && \
	cd nginx-1.14.0 && \
	./configure --with-compat --add-dynamic-module=../ModSecurity-nginx && \
	make modules && \
	cp objs/ngx_http_modsecurity_module.so /etc/nginx/modules && \
	cd / && \
	git clone https://github.com/SpiderLabs/owasp-modsecurity-crs.git  && \
	cp -R /owasp-modsecurity-crs/rules/ /etc/nginx/  && \
	mv /etc/nginx/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf.example  /etc/nginx/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf && \
	mv /etc/nginx/rules/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf.example  /etc/nginx/rules/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf && \	
	apt-get remove -y --purge apt-utils autoconf automake build-essential git pkgconf 
COPY nginx.conf /etc/nginx/nginx.conf
COPY modsec_includes.conf /etc/nginx/modsec_includes.conf
COPY modsecurity.conf /etc/nginx/modsecurity.conf
COPY crs-setup.conf /etc/nginx/crs-setup.conf
CMD nginx -g 'daemon off;'
EXPOSE 80
	
	
	
	
	