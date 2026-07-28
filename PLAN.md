**Mission Objective**
You are tasked with autonomously developing, configuring, and deploying an automated Reverse Proxy Hub ("RevHub") on the current server. After scripting the deployment, you must push the entire project (scripts, configuration templates, and documentation) to a designated remote GitHub repository.

**Available Environment & Tech Stack**

* **Pre-installed Software:** Nginx, Docker, Certbot.
* **Authentication:** A Cloudflare DNS API token is stored at `/opt/revhub/.env` under the variable `CF_ZONE_TOKEN`.
* **Base Domain:** `cloudengine.host` (DNS controlled via the provided Cloudflare token).
* **Target Git Repository:** `git@github.com:ForeverLove37/revhub.git` (Empty repository, already created).

---

### Phase 1: Service Requirements & Routing Logic

You must write configuration templates and automation scripts to deploy Nginx reverse proxies for the following services.

**1. Hugging Face (Web UI & Large File Downloads)**

* **Ingress Domains:** `hf.erailab.com` AND `hf.cloudengine.host`.
* *Note:* The user has already manually resolved `hf.erailab.com` to this server. Do not attempt to modify DNS for `erailab.com`. You only need to automate DNS records for the `cloudengine.host` subdomains.


* **Routing Logic:**
* Proxy all traffic to `huggingface.co`.
* **Crucial Constraint:** The server must handle BOTH standard web UI traffic and large file/LFS downloads (e.g., `.bin`, `.safetensors`, `.gguf`) directly on this single machine. **Do NOT** implement any 302 redirects to external storage nodes. Ensure Nginx is configured to handle massive payloads (disable max body size limits and extend timeouts) and utilize dynamic DNS resolvers to prevent 502 errors when upstream IPs change.



**2. GitHub Raw (Static File Delivery)**

* **Ingress Domain:** `raw.cloudengine.host`.
* **Routing Logic:** Pure transparent proxy to `raw.githubusercontent.com` for downloading installation scripts and raw code files via CLI (e.g., `curl` / `wget`).

**3. GitHub Container Registry (GHCR)**

* **Ingress Domain:** `ghcr.cloudengine.host`.
* **Routing Logic:** Pure transparent proxy to `ghcr.io`. Must be fully compliant with the OCI (Open Container Initiative) protocol to allow `docker pull` commands to work seamlessly.

**4. Docker Hub Registry**

* **Ingress Domain:** `docker.cloudengine.host`.
* **Routing Logic:** Proxy to Docker Hub's registry to bypass network restrictions for standard `docker pull` commands.

---

### Phase 2: Automation & Scripting Directives

You must create a deployment script (e.g., `install.sh` or `setup.sh`) that automates the following when executed by the user:

1. **DNS Automation:** Parse `/opt/revhub/.env` to retrieve `CF_ZONE_TOKEN`. Use Cloudflare's API to automatically create `A` or `CNAME` records for all required `*.cloudengine.host` subdomains pointing to this server.
2. **SSL Provisioning:** Use `certbot` with the Cloudflare DNS plugin (using the provided token) to request wildcard or specific SSL certificates for the `cloudengine.host` subdomains. Use standard HTTP/webroot challenges or existing certs for `hf.erailab.com`.
3. **Nginx Configuration:** Generate the Nginx configuration files based on the routing logic defined in Phase 1, apply them to the Nginx directories, and reload the Nginx service.

*Constraint Reminder:* Focus purely on Nginx routing for these services. While Docker is pre-installed and available if you deem it necessary for auxiliary tasks, the core traffic routing must be handled efficiently by Nginx.

---

### Phase 3: Documentation & Version Control

1. **Documentation (`README.md`):**
Write a comprehensive, user-friendly `README.md` in English. It must include:
* **Deployment Instructions:** Exactly how the user should execute your setup scripts to deploy or redeploy the services on a fresh server.
* **Usage Guide:** Clear examples of how the user should utilize the newly deployed proxies. (e.g., Show how to change a `git clone` URL, how to pull a GHCR image using the new domain, and how to set the `HF_ENDPOINT` environment variable for Python scripts).


2. **Git Operations:**
* Initialize a local Git repository in your working directory.
* Add all deployment scripts, Nginx configuration templates, and the `README.md`.
* Commit the files with clear, descriptive messages.
* Set the remote origin to `git@github.com:ForeverLove37/revhub.git`.
* Push the `main` branch to the remote repository.
