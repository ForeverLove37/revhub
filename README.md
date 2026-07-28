# RevHub

RevHub is a self-hosted Nginx reverse-proxy hub for model and dataset downloads, source files, OCI registries, Go modules, and HashiCorp releases. It provisions Cloudflare DNS records and a wildcard TLS certificate for these public endpoints:

| Ingress address | Upstream | Intended use |
| --- | --- | --- |
| `hf.cloudengine.host` | `huggingface.co` | Hugging Face web/API/download traffic |
| `hf.erailab.com` | `huggingface.co` | The existing, externally managed Hugging Face hostname |
| `raw.cloudengine.host` | `raw.githubusercontent.com` | Raw GitHub file downloads |
| `ghcr.cloudengine.host` | `ghcr.io` | OCI image pulls from GHCR |
| `docker.cloudengine.host` | `registry-1.docker.io` and `auth.docker.io` | OCI image pulls from Docker Hub |
| `gcr.cloudengine.host` | `gcr.io` | OCI image pulls from Google Container Registry |
| `k8s.cloudengine.host` | `registry.k8s.io` | Kubernetes OCI image pulls |
| `quay.cloudengine.host` | `quay.io` | Red Hat Quay OCI image pulls |
| `civitai.cloudengine.host` | `civitai.com` | Civitai models and web traffic |
| `kaggle.cloudengine.host` | `kaggle.com` | Kaggle datasets and web traffic |
| `goproxy.cloudengine.host` | `proxy.golang.org` | Go module downloads |
| `hashicorp.cloudengine.host` | `releases.hashicorp.com` | HashiCorp release downloads |

The generated proxy configuration is deliberately streaming-oriented: it disables request and response buffering for large Hugging Face and OCI payloads, removes Nginx's body-size cap, uses one-hour transfer timeouts, and uses runtime DNS resolution for all upstream hosts. It does not create Nginx 302 redirects to external storage; upstream responses remain transparent.

## Prerequisites

- A Debian or Ubuntu server with a public IPv4 address and ports `80` and `443` reachable from the Internet.
- Nginx, Certbot, `curl`, and `jq` installed. The script installs `python3-certbot-dns-cloudflare` when Certbot does not already have that plugin.
- A Cloudflare API token with `Zone:Read` and `DNS:Edit` scoped to `cloudengine.host`.
- `hf.erailab.com` already resolving directly to this server. RevHub never changes the `erailab.com` zone.
- No existing Nginx virtual host claiming the twelve RevHub `server_name` values.

The Cloudflare DNS records are intentionally DNS-only (`proxied: false`). Letting Cloudflare proxy these registry and large-download endpoints can introduce payload and protocol limits that this setup is intended to avoid.

## Deploy

On a fresh server, clone the repository and create a local token file. Do not commit that file.

```bash
git clone git@github.com:ForeverLove37/revhub.git /opt/revhub
cd /opt/revhub
printf 'CF_ZONE_TOKEN=replace-with-your-token\n' | sudo tee .env >/dev/null
sudo chmod 600 .env
sudo ./setup.sh --email admin@example.com
```

The script performs the following in order:

1. Detects the public IPv4 address and creates or updates the eleven `cloudengine.host` A records.
2. Installs a temporary HTTP-only Nginx site, allowing the `hf.erailab.com` HTTP-01 challenge through while redirecting other HTTP traffic to HTTPS.
3. Uses Cloudflare DNS-01 to issue a wildcard certificate for `*.cloudengine.host`, then uses Certbot's Nginx plugin to issue the certificate for `hf.erailab.com`.
4. Installs the final TLS Nginx configuration at `/etc/nginx/conf.d/revhub.conf`, verifies Nginx, and reloads it.
5. Installs a Certbot deploy hook that reloads Nginx after successful renewals.

Pass the address explicitly when automatic IPv4 discovery is unsuitable, such as behind a NAT:

```bash
sudo ./setup.sh --email admin@example.com --ip 203.0.113.10
```

For a first dry run against Let's Encrypt's staging environment, use `--staging`; its certificates are intentionally untrusted by clients:

```bash
sudo ./setup.sh --email admin@example.com --staging
```

After DNS and HTTP routing are known to work, run the command once more without `--staging` to obtain production certificates.

## Redeploy and recovery

Run the same command after pulling changes. DNS records and certificates are kept up to date rather than blindly duplicated, and the existing RevHub site is timestamp-backed up under `/etc/nginx/revhub-backups/` before replacement.

```bash
cd /opt/revhub
git pull --ff-only
sudo ./setup.sh --email admin@example.com
```

To re-render Nginx while retaining certificates and deliberately leaving DNS untouched:

```bash
sudo ./setup.sh --email admin@example.com \
  --skip-dns --skip-cloudengine-cert --skip-erailab-cert
```

Those skip flags require the named certificates to already exist. The deployment otherwise stops before installing the final TLS site. Validate automatic renewal periodically:

```bash
sudo certbot renew --dry-run
sudo nginx -t
```

The credentials copied for Certbot live at `/etc/letsencrypt/revhub-cloudflare.ini` with mode `0600`. Rotate the Cloudflare token through the server's `.env` file and rerun the setup script.

## Usage

### Hugging Face

Set `HF_ENDPOINT` for Python programs and the Hugging Face CLI:

```bash
export HF_ENDPOINT=https://hf.cloudengine.host
python -c 'from huggingface_hub import snapshot_download; snapshot_download("gpt2")'
```

The alternative `https://hf.erailab.com` endpoint has the same proxy behavior. The proxy streams large LFS/model responses and allows unlimited request bodies. Xet token responses are rewritten so `cas-server.xethub.hf.co` and `cas-bridge.xethub.hf.co` requests return through the selected Hugging Face RevHub hostname; do not set `HF_HUB_DISABLE_XET=1` for this deployment.

### GitHub raw files

Replace the normal raw-content hostname in scripts with `raw.cloudengine.host`:

```bash
curl -fsSL https://raw.cloudengine.host/owner/repository/main/install.sh | bash
wget https://raw.cloudengine.host/owner/repository/main/config.example.yml
```

`raw.githubusercontent.com` serves file contents, not Git's smart-HTTP protocol. The optional `mirror.sh git` rewrite only changes already-raw URLs; `git clone https://raw.cloudengine.host/...` is not a valid clone endpoint.

### GitHub Container Registry

For public images, use the proxy hostname as the registry component:

```bash
docker pull ghcr.cloudengine.host/owner/image:tag
```

For private images, authenticate against the proxy hostname with a GitHub token that has the needed package permissions:

```bash
printf '%s' "$GHCR_TOKEN" | docker login ghcr.cloudengine.host --username YOUR_GITHUB_USER --password-stdin
docker pull ghcr.cloudengine.host/owner/private-image:tag
```

The configuration rewrites the GHCR bearer-auth realm to `ghcr.cloudengine.host`, so the Docker client asks the proxy for its token instead of bypassing the proxy after the registry's initial `401` response.

### Docker Hub

Use an explicit Docker Hub proxy hostname and namespace:

```bash
docker pull docker.cloudengine.host/library/alpine:3.20
docker pull docker.cloudengine.host/library/ubuntu:24.04
```

For authenticated or private pulls:

```bash
docker login docker.cloudengine.host
docker pull docker.cloudengine.host/your-account/private-image:tag
```

Docker Hub's registry and token service use different upstream hosts. RevHub preserves the OCI Registry API and rewrites the bearer-auth realm to `docker.cloudengine.host/token`, then proxies that token request to `auth.docker.io`. Blob redirects to Docker's CloudFront and Cloudflare delivery hosts are rewritten to fixed RevHub relay paths, so layer downloads stay on the proxy.

### Other OCI registries

Use the matching RevHub hostname in image references:

```bash
docker pull gcr.cloudengine.host/google-containers/pause:3.9
docker pull k8s.cloudengine.host/pause:3.9
docker pull quay.cloudengine.host/prometheus/busybox:latest
```

For private images, run `docker login` against the same RevHub hostname before pulling. Registry bearer-auth challenges for GHCR, Docker Hub, GCR, Kubernetes Registry, and Quay are retained through the proxy. GHCR package-CDN, Google Storage, and Quay CDN blob redirects are relayed through their matching RevHub hostnames.

### Civitai, Kaggle, Go, and HashiCorp

```bash
curl -fL https://civitai.cloudengine.host/api/v1/models
curl -fL https://kaggle.cloudengine.host/
GOPROXY=https://goproxy.cloudengine.host,direct go mod download
curl -fLO https://hashicorp.cloudengine.host/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip
```

### Shell mirror utility

`mirror.sh` must be run with `source`, not `./mirror.sh`, so temporary environment variables affect the current terminal window:

```bash
source ./mirror.sh                 # all targets, temporary shell variables
source ./mirror.sh hf t            # export HF_ENDPOINT in this shell
source ./mirror.sh go l            # export GOPROXY and append it to your shell profile
source ./mirror.sh git l           # persist the GitHub raw URL rewrite globally
source ./mirror.sh docker t        # update Docker's registry mirror and print its restart command
```

Targets are `all` (the default), `hf`, `git`, `docker`, and `go`. Persistence is `t` (temporary, the default) or `l` (persistent). Permanent `hf` and `go` exports are appended to the active shell's `.bashrc` or `.zshrc`. Docker configuration is necessarily system-wide: the script safely adds `https://docker.cloudengine.host` to `/etc/docker/daemon.json`, restarting Docker automatically only when sourced as root. With a normal user, it prompts for `sudo` to update the file and prints the restart command.

The Docker mirror setting handles Docker Hub defaults. Explicitly rewrite GHCR, GCR, Kubernetes Registry, and Quay image tags to their RevHub hostnames as shown above.

## Project layout

```text
setup.sh                              Idempotent DNS, certificate, Nginx, and renewal automation
mirror.sh                             Source-only shell and Docker mirror configuration utility
nginx/revhub.bootstrap.conf.template  HTTP-01 challenge site used before TLS certificates exist
nginx/revhub.conf.template            Final TLS reverse-proxy site
tests/test-config.sh                  Shell and rendered-Nginx configuration validation
```

Run the local checks before making changes:

```bash
./tests/test-config.sh
```

In restricted containers that prohibit all socket binds, Nginx reports that limitation after parsing the templates. The test recognizes that specific condition; on a normal server, `nginx -t` completes its full listener validation.

## Security and operating notes

- Keep `.env` and `/etc/letsencrypt/revhub-cloudflare.ini` private. Both contain the Cloudflare token and are excluded from Git.
- The script requires root because it changes `/etc/nginx`, `/etc/letsencrypt`, and the Nginx service. It does not replace Nginx's default site or delete unrelated Nginx configuration.
- Certbot's normal system timer handles renewal. The installed deploy hook reloads Nginx only after a renewed certificate is available.
- This configuration is a forward proxy for the listed public services only. Do not add arbitrary client-controlled upstream URLs to its `proxy_pass` directives.
