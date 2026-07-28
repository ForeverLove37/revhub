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




---

**Status Update & Failure Analysis of Previous Run:**
Your previous deployment was functionally incomplete. You successfully installed Nginx configurations, but you failed to provision any SSL certificates (including for hf.erailab.com), and you only configured 4 proxy endpoints instead of the full comprehensive list required.

You must immediately rectify these omissions and implement a new environment management script. Read the following strict requirements and execute them completely.

Phase 1: Mandatory SSL Provisioning (Strict Enforcement)
You must automate the SSL certificate request process using Certbot.

For hf.erailab.com: This domain is already manually resolved to the server's IP. You MUST execute standard Certbot with the Nginx plugin:
certbot --nginx -d hf.erailab.com --non-interactive --agree-tos -m <extract-email-from-setup>

For *.cloudengine.host: You MUST use the Cloudflare DNS plugin with the token stored in /opt/revhub/.env (CF_ZONE_TOKEN) to generate a wildcard certificate or individual certificates for all the subdomains listed in Phase 2. Do not skip this step. Nginx must be configured to use port 443 with these generated certificates.

Phase 2: Comprehensive Proxy Targets Expansion
You must expand the Nginx configuration to include transparent reverse proxies for the following easily blocked developer ecosystems. Ensure client_max_body_size 0; and extended timeouts are applied where massive file transfers are expected.

hf.erailab.com & hf.cloudengine.host -> huggingface.co

raw.cloudengine.host -> raw.githubusercontent.com

ghcr.cloudengine.host -> ghcr.io

docker.cloudengine.host -> registry-1.docker.io

[NEW] gcr.cloudengine.host -> gcr.io (Google Container Registry)

[NEW] k8s.cloudengine.host -> registry.k8s.io (Kubernetes Registry)

[NEW] quay.cloudengine.host -> quay.io (Red Hat Quay)

[NEW] civitai.cloudengine.host -> civitai.com (AI Models)

[NEW] kaggle.cloudengine.host -> kaggle.com (Datasets)

[NEW] goproxy.cloudengine.host -> proxy.golang.org

[NEW] hashicorp.cloudengine.host -> releases.hashicorp.com

Phase 3: Develop mirror.sh Utility Script
You must write a Bash script named mirror.sh in the project root. The purpose of this script is to inject environment variables or configurations into the user's system to seamlessly route traffic through the new proxies.

Script Interface:
source ./mirror.sh [target] [persistence]

Parameter 1 [target]: Accepts all (default), hf, git (for raw files), docker, go.

Parameter 2 [persistence]: Accepts t (Temporary, affects only current shell session) or l (Permanent, writes to ~/.bashrc, ~/.zshrc, or system config files). Default is t.

Script Logic & Mappings:

hf: export HF_ENDPOINT=[https://hf.cloudengine.host](https://hf.cloudengine.host)

go: export GOPROXY=[https://goproxy.cloudengine.host](https://goproxy.cloudengine.host),direct

docker: Since Docker registries aren't shell variables, the script must intelligently modify /etc/docker/daemon.json to add docker.cloudengine.host to registry-mirrors, and output a message telling the user to restart Docker daemon (or restart it automatically if run as root). For GHCR/GCR/K8s, remind the user to rewrite image tags.

git: Execute git config --global url."[https://raw.cloudengine.host/](https://raw.cloudengine.host/)".insteadOf "[https://raw.githubusercontent.com/](https://raw.githubusercontent.com/)". (If t is selected, use --local instead of --global, or inform the user it applies system-wide).

all: Apply all the above.

Persistence (l): If l is passed, the export commands must be appended to the user's ~/.bashrc profile.

Phase 4: README Updates & Git Commit
Update the README.md to list ALL the newly supported endpoints.

Explicitly document how to use mirror.sh. Add a crucial note warning the user that to apply variables to the current window, they MUST run the script via source ./mirror.sh and not just ./mirror.sh.

Commit all changes (the updated setup.sh, the newly generated mirror.sh, the Nginx templates, and the README.md) and push them directly to git@github.com:ForeverLove37/revhub.git.
