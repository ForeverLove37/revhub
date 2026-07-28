#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TEMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

command -v nginx >/dev/null 2>&1
command -v openssl >/dev/null 2>&1

mkdir -p "${TEMP_DIR}/live/revhub-cloudengine" "${TEMP_DIR}/live/revhub-hf-erailab" \
    "${TEMP_DIR}/acme" "${TEMP_DIR}/client_body" "${TEMP_DIR}/proxy" \
    "${TEMP_DIR}/fastcgi" "${TEMP_DIR}/uwsgi" "${TEMP_DIR}/scgi"
openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout "${TEMP_DIR}/key.pem" -out "${TEMP_DIR}/cert.pem" \
    -subj '/CN=revhub-config-test' >/dev/null 2>&1
for cert_name in revhub-cloudengine revhub-hf-erailab; do
    cp "${TEMP_DIR}/cert.pem" "${TEMP_DIR}/live/${cert_name}/fullchain.pem"
    cp "${TEMP_DIR}/key.pem" "${TEMP_DIR}/live/${cert_name}/privkey.pem"
done

sed -e "s|__ACME_WEBROOT__|${TEMP_DIR}/acme|g" \
    -e "s|__LETSENCRYPT_LIVE_DIR__|${TEMP_DIR}/live|g" \
    -e 's/listen 80;/listen 18080;/g' \
    -e 's/listen \[::\]:80;/listen [::]:18080;/g' \
    "${ROOT_DIR}/nginx/revhub.bootstrap.conf.template" > "${TEMP_DIR}/bootstrap.conf"
sed -e "s|__ACME_WEBROOT__|${TEMP_DIR}/acme|g" \
    -e "s|__LETSENCRYPT_LIVE_DIR__|${TEMP_DIR}/live|g" \
    -e 's/listen 443 ssl;/listen 18443 ssl;/g' \
    -e 's/listen \[::\]:443 ssl;/listen [::]:18443 ssl;/g' \
    -e 's/listen 80;/listen 18080;/g' \
    -e 's/listen \[::\]:80;/listen [::]:18080;/g' \
    "${ROOT_DIR}/nginx/revhub.conf.template" > "${TEMP_DIR}/revhub.conf"

for config in bootstrap.conf revhub.conf; do
    cat > "${TEMP_DIR}/nginx.conf" <<EOF
pid ${TEMP_DIR}/nginx.pid;
error_log stderr notice;
user root;
events {}
http {
    access_log off;
    client_body_temp_path ${TEMP_DIR}/client_body;
    proxy_temp_path ${TEMP_DIR}/proxy;
    fastcgi_temp_path ${TEMP_DIR}/fastcgi;
    uwsgi_temp_path ${TEMP_DIR}/uwsgi;
    scgi_temp_path ${TEMP_DIR}/scgi;
    include ${TEMP_DIR}/${config};
}
EOF
    if ! nginx_output="$(nginx -t -p "${TEMP_DIR}" -c "${TEMP_DIR}/nginx.conf" 2>&1)"; then
        if [[ "${nginx_output}" == *"syntax is ok"* && "${nginx_output}" == *"Operation not permitted"* ]]; then
            printf 'Nginx parsed %s; this sandbox does not permit test socket binds.\n' "${config}" >&2
        else
            printf '%s\n' "${nginx_output}" >&2
            exit 1
        fi
    fi
done

bash -n "${ROOT_DIR}/setup.sh"
bash -n "${ROOT_DIR}/mirror.sh"

for domain in hf.cloudengine.host hf.erailab.com raw.cloudengine.host ghcr.cloudengine.host docker.cloudengine.host \
    gcr.cloudengine.host k8s.cloudengine.host quay.cloudengine.host civitai.cloudengine.host kaggle.cloudengine.host \
    goproxy.cloudengine.host hashicorp.cloudengine.host; do
    rg -F "server_name ${domain};" "${ROOT_DIR}/nginx/revhub.conf.template" >/dev/null
done

for relay in /__hf_xet/cas-server /__hf_xet/cas-bridge /__docker_blobs/cloudfront /__docker_blobs/cloudflare \
    /__ghcr_blobs/ /__gcr_blobs/ /__quay_blobs/; do
    rg -F "${relay}" "${ROOT_DIR}/nginx/revhub.conf.template" >/dev/null
done

test "$(rg -F -c 'proxy_pass https://$revhub_hf_upstream;' "${ROOT_DIR}/nginx/revhub.conf.template")" -eq 2
test "$(rg -F -c 'proxy_redirect https://huggingface.co/ /;' "${ROOT_DIR}/nginx/revhub.conf.template")" -eq 2
test "$(rg -F -c "sub_filter '\"xet\":' '\"nox\":';" "${ROOT_DIR}/nginx/revhub.conf.template")" -eq 2

bash -c 'source "$1/mirror.sh" hf t >/dev/null && test "$HF_ENDPOINT" = "https://hf.cloudengine.host"' bash "${ROOT_DIR}"
bash -c 'source "$1/mirror.sh" go t >/dev/null && test "$GOPROXY" = "https://goproxy.cloudengine.host,direct"' bash "${ROOT_DIR}"
printf 'RevHub configuration templates and utility scripts are valid.\n'
