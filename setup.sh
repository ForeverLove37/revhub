#!/usr/bin/env bash
# Deploys the RevHub Nginx reverse proxies on Debian or Ubuntu hosts.
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly BASE_DOMAIN="cloudengine.host"
readonly ERAILAB_DOMAIN="hf.erailab.com"
readonly CLOUD_DOMAINS=(
    "hf.cloudengine.host"
    "raw.cloudengine.host"
    "ghcr.cloudengine.host"
    "docker.cloudengine.host"
    "gcr.cloudengine.host"
    "k8s.cloudengine.host"
    "quay.cloudengine.host"
    "civitai.cloudengine.host"
    "kaggle.cloudengine.host"
    "goproxy.cloudengine.host"
    "hashicorp.cloudengine.host"
)
readonly CLOUD_CERT_NAME="revhub-cloudengine"
readonly ERAILAB_CERT_NAME="revhub-hf-erailab"

ENV_FILE="${SCRIPT_DIR}/.env"
EMAIL=""
PUBLIC_IP=""
ACME_WEBROOT="/var/lib/revhub/acme"
LETSENCRYPT_LIVE_DIR="/etc/letsencrypt/live"
NGINX_CONFIG_DIR="/etc/nginx/conf.d"
NGINX_SITE_NAME="revhub.conf"
CF_PROPAGATION_SECONDS="30"
USE_STAGING=0
SKIP_DNS=0
SKIP_CLOUD_CERT=0
SKIP_ERAILAB_CERT=0

log() {
    printf '[revhub] %s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  sudo ./setup.sh --email admin@example.com [options]

Options:
  --email ADDRESS                 Email registered with Let's Encrypt (required).
  --ip IPV4                       Public IPv4 for Cloudflare A records. Auto-detected if omitted.
  --env-file PATH                 File containing CF_ZONE_TOKEN (default: ./.env).
  --acme-webroot PATH             Webroot used for hf.erailab.com HTTP-01 challenges.
  --dns-propagation-seconds N     Cloudflare DNS-01 propagation wait (default: 30).
  --staging                       Use the Let's Encrypt staging environment.
  --skip-dns                      Do not create or update Cloudflare DNS records.
  --skip-cloudengine-cert         Reuse an existing cloudengine.host certificate.
  --skip-erailab-cert             Reuse an existing hf.erailab.com certificate.
  -h, --help                      Show this help text.

The Cloudflare token needs Zone:Read and DNS:Edit for cloudengine.host.
EOF
}

require_root() {
    [ "${EUID}" -eq 0 ] || die "Run this script with sudo or as root."
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_nginx_config_dir() {
    [ -d "${NGINX_CONFIG_DIR}" ] || die "Expected Nginx configuration directory is missing: ${NGINX_CONFIG_DIR}"
}

validate_ipv4() {
    local ip="$1" octet
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local -a octets
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        ((10#$octet <= 255)) || return 1
    done
}

read_env_value() {
    local name="$1" value
    [ -f "${ENV_FILE}" ] || die "Environment file not found: ${ENV_FILE}"
    value="$(sed -n -E "s|^[[:space:]]*(export[[:space:]]+)?${name}[[:space:]]*=[[:space:]]*||p" "${ENV_FILE}" | tail -n 1)"
    value="${value%$'\r'}"
    if [[ "${value}" =~ ^\".*\"$ ]] || [[ "${value}" =~ ^\'.*\'$ ]]; then
        value="${value:1:${#value}-2}"
    fi
    [ -n "${value}" ] || die "${name} is missing or empty in ${ENV_FILE}"
    printf '%s' "${value}"
}

certbot_args() {
    local -n args_ref="$1"
    args_ref=(--non-interactive --agree-tos --email "${EMAIL}")
    if [ "${USE_STAGING}" -eq 1 ]; then
        args_ref+=(--staging)
    fi
}

install_apt_packages() {
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" --fix-broken install -y
    DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" install -y "$@"
}

install_cloudflare_certbot_plugin() {
    if certbot plugins 2>/dev/null | grep -q 'dns-cloudflare'; then
        return
    fi
    require_command apt-get
    log "Installing the Certbot Cloudflare DNS plugin."
    install_apt_packages python3-certbot-dns-cloudflare
    certbot plugins 2>/dev/null | grep -q 'dns-cloudflare' || die "Certbot Cloudflare DNS plugin was not installed."
}

install_nginx_certbot_plugin() {
    if certbot plugins 2>/dev/null | grep -q 'nginx'; then
        return
    fi
    require_command apt-get
    log "Installing the Certbot Nginx plugin."
    install_apt_packages python3-certbot-nginx
    certbot plugins 2>/dev/null | grep -q 'nginx' || die "Certbot Nginx plugin was not installed."
}

cloudflare_request() {
    local method="$1" endpoint="$2" payload="${3:-}"
    local response
    if [ -n "${payload}" ]; then
        response="$(curl --fail --silent --show-error --retry 3 --request "${method}" \
            --header "Authorization: Bearer ${CF_ZONE_TOKEN}" \
            --header 'Content-Type: application/json' \
            --data "${payload}" "https://api.cloudflare.com/client/v4${endpoint}")"
    else
        response="$(curl --fail --silent --show-error --retry 3 --request "${method}" \
            --header "Authorization: Bearer ${CF_ZONE_TOKEN}" \
            "https://api.cloudflare.com/client/v4${endpoint}")"
    fi
    jq -e '.success == true' >/dev/null <<< "${response}" || die "Cloudflare API rejected ${method} ${endpoint}: $(jq -c '.errors' <<< "${response}")"
    printf '%s' "${response}"
}

configure_dns_record() {
    local record_name="$1" records response record_id record_count payload
    records="$(curl --fail --silent --show-error --retry 3 --get \
        --header "Authorization: Bearer ${CF_ZONE_TOKEN}" \
        --data-urlencode "name=${record_name}" \
        "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records")"
    jq -e '.success == true' >/dev/null <<< "${records}" || die "Unable to query Cloudflare DNS for ${record_name}."
    record_count="$(jq '.result | length' <<< "${records}")"
    [ "${record_count}" -le 1 ] || die "Refusing to change ${record_name}: Cloudflare has ${record_count} records with that exact name."
    payload="$(jq -cn --arg name "${record_name}" --arg content "${PUBLIC_IP}" '{type:"A",name:$name,content:$content,ttl:1,proxied:false}')"
    if [ "${record_count}" -eq 0 ]; then
        response="$(cloudflare_request POST "/zones/${CF_ZONE_ID}/dns_records" "${payload}")"
        log "Created A record: ${record_name} -> ${PUBLIC_IP}"
    else
        record_id="$(jq -r '.result[0].id' <<< "${records}")"
        response="$(cloudflare_request PUT "/zones/${CF_ZONE_ID}/dns_records/${record_id}" "${payload}")"
        log "Updated A record: ${record_name} -> ${PUBLIC_IP}"
    fi
    [ -n "${response}" ]
}

configure_cloudflare_dns() {
    local zones
    CF_ZONE_TOKEN="$(read_env_value CF_ZONE_TOKEN)"
    zones="$(curl --fail --silent --show-error --retry 3 --get \
        --header "Authorization: Bearer ${CF_ZONE_TOKEN}" \
        --data-urlencode "name=${BASE_DOMAIN}" \
        --data-urlencode 'per_page=1' \
        'https://api.cloudflare.com/client/v4/zones')"
    jq -e '.success == true' >/dev/null <<< "${zones}" || die "Unable to query the Cloudflare zone."
    CF_ZONE_ID="$(jq -r '.result[0].id // empty' <<< "${zones}")"
    [ -n "${CF_ZONE_ID}" ] || die "Cloudflare zone ${BASE_DOMAIN} was not found for this token."
    for domain in "${CLOUD_DOMAINS[@]}"; do
        configure_dns_record "${domain}"
    done
}

detect_public_ipv4() {
    local detected
    detected="$(curl --fail --silent --show-error --retry 3 --connect-timeout 10 https://api.ipify.org)" || die "Could not detect a public IPv4 address; pass --ip explicitly."
    validate_ipv4 "${detected}" || die "Public IPv4 detection returned an invalid value; pass --ip explicitly."
    printf '%s' "${detected}"
}

write_cloudflare_credentials() {
    local credentials_file="/etc/letsencrypt/revhub-cloudflare.ini"
    CF_ZONE_TOKEN="$(read_env_value CF_ZONE_TOKEN)"
    install -d -m 0700 /etc/letsencrypt
    umask 077
    printf 'dns_cloudflare_api_token = %s\n' "${CF_ZONE_TOKEN}" > "${credentials_file}"
    chmod 0600 "${credentials_file}"
    printf '%s' "${credentials_file}"
}

request_cloudengine_certificate() {
    local credentials_file args
    credentials_file="$(write_cloudflare_credentials)"
    install_cloudflare_certbot_plugin
    certbot_args args
    log "Requesting or renewing the wildcard certificate for ${BASE_DOMAIN} proxy names."
    certbot certonly --dns-cloudflare --dns-cloudflare-credentials "${credentials_file}" \
        --dns-cloudflare-propagation-seconds "${CF_PROPAGATION_SECONDS}" \
        --cert-name "${CLOUD_CERT_NAME}" --renew-with-new-domains \
        "${args[@]}" \
        -d "*.${BASE_DOMAIN}"
}

request_erailab_certificate() {
    local args
    certbot_args args
    install_nginx_certbot_plugin
    log "Requesting or renewing the Nginx-managed certificate for ${ERAILAB_DOMAIN}."
    certbot --nginx -d "${ERAILAB_DOMAIN}" --non-interactive --agree-tos -m "${EMAIL}" \
        --cert-name "${ERAILAB_CERT_NAME}" --keep-until-expiring
}

render_template() {
    local template="$1" destination="$2" rendered
    rendered="$(mktemp)"
    sed -e "s|__ACME_WEBROOT__|${ACME_WEBROOT}|g" \
        -e "s|__LETSENCRYPT_LIVE_DIR__|${LETSENCRYPT_LIVE_DIR}|g" \
        "${template}" > "${rendered}"
    install -m 0644 "${rendered}" "${destination}"
    rm -f "${rendered}"
}

backup_existing_site() {
    local site_path="$1" backup_dir="/etc/nginx/revhub-backups"
    [ -e "${site_path}" ] || return 0
    install -d -m 0700 "${backup_dir}"
    cp -a "${site_path}" "${backup_dir}/${NGINX_SITE_NAME}.$(date +%Y%m%d%H%M%S)"
}

test_and_reload_nginx() {
    nginx -t
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        systemctl start nginx
    fi
}

verify_certificate_files() {
    local certificate_name="$1"
    [ -f "${LETSENCRYPT_LIVE_DIR}/${certificate_name}/fullchain.pem" ] || die "Certificate is missing: ${certificate_name}"
    [ -f "${LETSENCRYPT_LIVE_DIR}/${certificate_name}/privkey.pem" ] || die "Private key is missing: ${certificate_name}"
}

install_renewal_hook() {
    local hook="/etc/letsencrypt/renewal-hooks/deploy/reload-revhub-nginx.sh"
    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
    install -m 0755 /dev/stdin "${hook}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl reload nginx
EOF
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --email)
                [ "$#" -ge 2 ] || die "--email requires a value."
                EMAIL="$2"
                shift 2
                ;;
            --ip)
                [ "$#" -ge 2 ] || die "--ip requires a value."
                PUBLIC_IP="$2"
                shift 2
                ;;
            --env-file)
                [ "$#" -ge 2 ] || die "--env-file requires a value."
                ENV_FILE="$2"
                shift 2
                ;;
            --acme-webroot)
                [ "$#" -ge 2 ] || die "--acme-webroot requires a value."
                ACME_WEBROOT="$2"
                shift 2
                ;;
            --dns-propagation-seconds)
                [ "$#" -ge 2 ] || die "--dns-propagation-seconds requires a value."
                CF_PROPAGATION_SECONDS="$2"
                shift 2
                ;;
            --staging)
                USE_STAGING=1
                shift
                ;;
            --skip-dns)
                SKIP_DNS=1
                shift
                ;;
            --skip-cloudengine-cert)
                SKIP_CLOUD_CERT=1
                shift
                ;;
            --skip-erailab-cert)
                SKIP_ERAILAB_CERT=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

main() {
    parse_arguments "$@"
    require_root
    [ -n "${EMAIL}" ] || die "--email is required."
    [[ "${EMAIL}" == *@*.* ]] || die "--email must look like an email address."
    [[ "${CF_PROPAGATION_SECONDS}" =~ ^[0-9]+$ ]] || die "--dns-propagation-seconds must be a non-negative integer."
    require_command curl
    require_command jq
    require_command certbot
    require_command nginx
    require_command systemctl
    require_nginx_config_dir

    if [ "${SKIP_DNS}" -eq 0 ]; then
        if [ -z "${PUBLIC_IP}" ]; then
            PUBLIC_IP="$(detect_public_ipv4)"
        fi
        validate_ipv4 "${PUBLIC_IP}" || die "--ip must be a valid IPv4 address."
        configure_cloudflare_dns
    fi

    install -d -m 0755 "${ACME_WEBROOT}"
    backup_existing_site "${NGINX_CONFIG_DIR}/${NGINX_SITE_NAME}"
    if [ "${SKIP_CLOUD_CERT}" -eq 0 ] || [ "${SKIP_ERAILAB_CERT}" -eq 0 ]; then
        render_template "${SCRIPT_DIR}/nginx/revhub.bootstrap.conf.template" "${NGINX_CONFIG_DIR}/${NGINX_SITE_NAME}"
        test_and_reload_nginx
    fi

    if [ "${SKIP_CLOUD_CERT}" -eq 0 ]; then
        request_cloudengine_certificate
    fi
    if [ "${SKIP_ERAILAB_CERT}" -eq 0 ]; then
        request_erailab_certificate
    fi
    verify_certificate_files "${CLOUD_CERT_NAME}"
    verify_certificate_files "${ERAILAB_CERT_NAME}"

    render_template "${SCRIPT_DIR}/nginx/revhub.conf.template" "${NGINX_CONFIG_DIR}/${NGINX_SITE_NAME}"
    test_and_reload_nginx
    install_renewal_hook
    log "Deployment complete."
}

main "$@"
