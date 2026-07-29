#!/usr/bin/env bash
# Source this file so temporary environment variables remain in the current shell.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'Run this utility with: source ./mirror.sh [all|hf|git|docker|go] [t|l]\n' >&2
    exit 1
fi

revhub_mirror_usage() {
    printf 'Usage: source ./mirror.sh [all|hf|git|docker|go] [t|l]\n' >&2
}

revhub_profile_path() {
    case "${SHELL:-}" in
        */zsh) printf '%s/.zshrc' "${ZDOTDIR:-${HOME}}" ;;
        *) printf '%s/.bashrc' "${HOME}" ;;
    esac
}

revhub_append_profile_export() {
    local name="$1" value="$2" profile line
    profile="$(revhub_profile_path)"
    line="export ${name}='${value}'"
    touch "${profile}"
    if ! grep -Fqx "${line}" "${profile}"; then
        printf '\n# Added by RevHub mirror.sh\n%s\n' "${line}" >> "${profile}"
        printf 'Persisted %s in %s.\n' "${name}" "${profile}"
    fi
}

revhub_apply_hf() {
    local persistence="$1"
    export HF_ENDPOINT='https://hf.cloudengine.host'
    printf 'HF_ENDPOINT=https://hf.cloudengine.host\n'
    [ "${persistence}" = 'l' ] && revhub_append_profile_export HF_ENDPOINT "${HF_ENDPOINT}"
    return 0
}

revhub_apply_go() {
    local persistence="$1"
    export GOPROXY='https://goproxy.cloudengine.host,direct'
    printf 'GOPROXY=https://goproxy.cloudengine.host,direct\n'
    [ "${persistence}" = 'l' ] && revhub_append_profile_export GOPROXY "${GOPROXY}"
    return 0
}

revhub_apply_git() {
    local persistence="$1" scope
    if [ "${persistence}" = 'l' ]; then
        scope='--global'
    else
        if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            printf 'Git temporary mode requires sourcing mirror.sh from inside a Git repository.\n' >&2
            return 1
        fi
        scope='--local'
    fi
    git config "${scope}" url."https://raw.cloudengine.host/".insteadOf 'https://raw.githubusercontent.com/'
    printf 'Git raw-content rewrite configured with %s.\n' "${scope}"
}

revhub_apply_docker() {
    local docker_config='/etc/docker/daemon.json' mirror='https://docker.cloudengine.host' temporary_config
    if ! command -v jq >/dev/null 2>&1; then
        printf 'jq is required to update %s.\n' "${docker_config}" >&2
        return 1
    fi

    temporary_config="$(mktemp)" || return 1
    if [ -f "${docker_config}" ]; then
        if ! jq -e --arg mirror "${mirror}" '
            if type != "object" or ((."registry-mirrors" // []) | type) != "array" then
                error("daemon.json must be an object with an array registry-mirrors value")
            else
                .["registry-mirrors"] = ((.["registry-mirrors"] // []) + [$mirror] | unique)
            end
        ' "${docker_config}" > "${temporary_config}"; then
            rm -f "${temporary_config}"
            printf 'Unable to safely parse %s; it was not changed.\n' "${docker_config}" >&2
            return 1
        fi
    else
        jq -n --arg mirror "${mirror}" '{"registry-mirrors": [$mirror]}' > "${temporary_config}"
    fi

    if [ "${EUID}" -eq 0 ]; then
        install -d -m 0755 /etc/docker
        install -m 0644 "${temporary_config}" "${docker_config}"
        rm -f "${temporary_config}"
        systemctl restart docker
        printf 'Docker restarted with registry mirror %s.\n' "${mirror}"
    else
        if ! command -v sudo >/dev/null 2>&1; then
            rm -f "${temporary_config}"
            printf 'Root access is required to update %s.\n' "${docker_config}" >&2
            return 1
        fi
        sudo install -d -m 0755 /etc/docker && sudo install -m 0644 "${temporary_config}" "${docker_config}"
        local install_status=$?
        rm -f "${temporary_config}"
        [ "${install_status}" -eq 0 ] || return "${install_status}"
        printf 'Docker mirror set to %s. Restart Docker with: sudo systemctl restart docker\n' "${mirror}"
    fi
}

revhub_mirror() {
    local target="${1:-all}" persistence="${2:-t}" status=0
    case "${target}" in
        all|hf|git|docker|go) ;;
        *) revhub_mirror_usage; return 1 ;;
    esac
    case "${persistence}" in
        t|l) ;;
        *) revhub_mirror_usage; return 1 ;;
    esac

    if [ "${target}" = 'all' ] || [ "${target}" = 'hf' ]; then
        revhub_apply_hf "${persistence}" || status=1
    fi
    if [ "${target}" = 'all' ] || [ "${target}" = 'go' ]; then
        revhub_apply_go "${persistence}" || status=1
    fi
    if [ "${target}" = 'all' ] || [ "${target}" = 'git' ]; then
        revhub_apply_git "${persistence}" || status=1
    fi
    if [ "${target}" = 'all' ] || [ "${target}" = 'docker' ]; then
        revhub_apply_docker || status=1
    fi
    if [ "${target}" = 'all' ] || [ "${target}" = 'docker' ]; then
        printf 'Rewrite GHCR, GCR, Kubernetes, and Quay image tags to their RevHub hostnames when pulling.\n'
    fi
    return "${status}"
}

revhub_mirror "$@"
_revhub_mirror_status=$?
unset -f revhub_mirror revhub_apply_docker revhub_apply_git revhub_apply_go revhub_apply_hf revhub_append_profile_export revhub_profile_path revhub_mirror_usage
return "${_revhub_mirror_status}"
