Securing Docker Containers with a Web Application Firewall (WAF) built on ModSecurity and NGINX
====

One can never be too paranoid about online security for a number of reasons. Containers are generally considered to be more secure by default that virtual machines because they substantially reduce the attack surface for a given application and its supporting infrastructure. This does not imply, however, that one should not be vigilant about secure containers. In addition to following secure practices for mitigating security risks with containers, those that use them should also use edge security to protect containers as well. Most applications that are being deployed into containers are in some way connected to the internet with ports exposed and so on. Traditionally, applications are secured with edge devices such as Unified Threat Management (UTM) that provides a suite of protection services including application protection. The nature of containers though makes using a UTM harder, because container loads are portable and elastic. Likewise, container loads are also being shifted to the cloud. 

A [Web Application Firewall (WAF)](https://www.owasp.org/index.php/Web_Application_Firewall) is a purpose-built firewall designed to protect against attacks common to web apps. One of the most widely used WAF’s is [ModSecurity](https://modsecurity.org/). Originally, it was written as a module for the Apache webserver, but it has since been ported to NGINX and IIS. ModSecurity protects against attacks by looking for:

*   SQL Injection
*   Insuring the content type matches the body data.
*   Protection against malformed POST requests.
*   HTTP Protocol Protection
*   Real-time Blacklist Lookups
*   HTTP Denial of Service Protections
*   Generic Web Attack Protection
*   Error Detection and Hiding

NGINX, though, is more than merely a web server. It can also act as a load balancer, reverse proxy, and do SSL offloading. Combine with ModSecurity, it has all the features to be a full-blown WAF. The NGINX/ModSecurity WAF has traditionally be deployed on VM’s and bare-metal servers, however it too can also be containerized. Using NGINX/ModSecurity in a container means that a container itself can be a WAF and carry with it all the advantages of containers. Likewise, it can scale and deploy with containers loads with on premise and cloud based solutions while VM’s and physical firewalls cannot. The Dockerfile and script herein builds NGINX and ModSecurity from their sources inside a container, then uploads three config files. These files are configured with the defaults settings on.

*   **nginx.conf** – This is the NGINX configuration file that contains the directives for load balancing and reverse proxying.
    *   Line 44 starts the section about enabling and disabling ModSecurity
    *   Line 52 starts the section to configure the reverse proxy. For docker, this will usually be the name of the container that is being fronted by the app.
    *   Line 53 contains the internal URL that nginx is proxying.
*   **modsecurity.conf** – this contains the configuration for modsecurity and some configuration for the defaults and exclusion of the rules used by mod security. Most everything in the modsecurity.conf file can be left as is.
    *   Line 230 starts the configuration of the rules.
    *   The rules are downloaded and installed (/usr/local/nginx/conf/rules) when the container is built. Individual rules can be disabled or enabled, or they can all be enabled.
*   **crs-setup.conf** – this configures the rules used by ModSecurity. The file has integrated documentation. Reading through this file explains what the settings are for. For more information about crs-setup.conf, visit OWASP's website.

Using the Dockerfile is simple. Change directories to the dockerfile, and build the image.

Multi-Stage Build:

```
docker build --tag mywaf .
```

Then run it.

```
docker run --name my-container-name -p 80:80 mywaf
```

This creates container.

Also, the image can be used with Docker Compose. The docker-compose.yml isa simple example that will deploy a simple node application along with the WAF. Change directories to the docker compose file, then run.

```
docker-compose up
```

### Use with Kubernetes

It is possible to use the WAF with Kubernetes too. In short, you create a deployment and load balancer service with the WAF, then use the WAF to connect to your applicaiton running on a deployment with a a cluster IP service. Reference the kube.yml file in the code for specifics.

Then use `kubectl` to deploy the kube.yml file to your Kubernetes environment.

```
kubectl create -f kube.yml
```
