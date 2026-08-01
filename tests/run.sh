#!/usr/bin/env bash
# The test doubles below are called indirectly by functions in the sourced script.
# shellcheck disable=SC1091,SC2034,SC2317,SC2329

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../shadowsocks-rust.sh
source "$SCRIPT_DIR/shadowsocks-rust.sh"

PASSED=0
FAILED=0
TEST_CASE_DIR=""

run_test() {
    local name=$1
    shift
    if ("$@"); then
        printf 'ok - %s\n' "$name"
        PASSED=$((PASSED + 1))
    else
        printf 'not ok - %s\n' "$name"
        FAILED=$((FAILED + 1))
    fi
}

test_arch_mapping() {
    uname() { printf 'x86_64\n'; }
    RUST_ARCH=""
    check_arch >/dev/null
    [[ "$RUST_ARCH" == "x86_64-unknown-linux-gnu" ]]
}

test_arch_rejects_unknown() {
    uname() { printf 'mystery-cpu\n'; }
    ! check_arch >/dev/null 2>&1
}

test_2022_password_validation() {
    local valid
    valid=$(head -c 32 /dev/zero | base64 | tr -d '\n')
    validate_2022_password "$valid" && ! validate_2022_password "invalid"
}

test_prompt_rejects_eof() {
    local answer=""
    ! prompt_input answer "" </dev/null >/dev/null
}

mock_release_curl() {
    local output=""

    while (( $# )); do
        if [[ "$1" == "-o" ]]; then
            output=$2
            shift 2
        else
            shift
        fi
    done
    [[ -n "$output" ]] || return 1

    case "$output" in
        */release.json)
            printf '%s\n' '{"tag_name":"v9.9.9","assets":[{"name":"shadowsocks-v9.9.9.x86_64-unknown-linux-gnu.tar.xz","browser_download_url":"https://example.invalid/core"},{"name":"shadowsocks-v9.9.9.x86_64-unknown-linux-gnu.tar.xz.sha256","browser_download_url":"https://example.invalid/checksum"}]}' > "$output"
            ;;
        *.sha256)
            sha256sum "${output%.sha256}" | awk '{print $1}' > "$output"
            ;;
        *)
            printf 'archive-payload\n' > "$output"
            ;;
    esac
}

prepare_core_test() {
    local case_dir=$1
    BIN_PATH="$case_dir/bin/ssserver"
    CORE_BACKUP_PATH="${BIN_PATH}.previous"
    CORE_INSTALLED_THIS_RUN=0
    CORE_HAD_PREVIOUS=0
    TMP_DIR=""
    mkdir -p "$(dirname "$BIN_PATH")"
    printf '#!/usr/bin/env bash\nprintf "old-core\\n"\n' > "$BIN_PATH"
    chmod 0755 "$BIN_PATH"
    check_arch() { RUST_ARCH="x86_64-unknown-linux-gnu"; }
    curl() { mock_release_curl "$@"; }
}

test_extract_failure_preserves_core() {
    local case_dir
    case_dir=$(mktemp -d /tmp/ssrust-test.XXXXXX)
    TEST_CASE_DIR=$case_dir
    trap 'cleanup; rm -rf -- "$TEST_CASE_DIR"' EXIT
    prepare_core_test "$case_dir"
    tar() { return 2; }

    ! install_core >/dev/null 2>&1 && \
        [[ "$("$BIN_PATH")" == "old-core" ]] && \
        (( CORE_INSTALLED_THIS_RUN == 0 ))
}

test_core_rollback() {
    local case_dir
    case_dir=$(mktemp -d /tmp/ssrust-test.XXXXXX)
    TEST_CASE_DIR=$case_dir
    trap 'cleanup; rm -rf -- "$TEST_CASE_DIR"' EXIT
    prepare_core_test "$case_dir"
    tar() {
        local arg extract_dir=""
        for arg in "$@"; do
            [[ "$arg" == --directory=* ]] && extract_dir=${arg#--directory=}
        done
        mkdir -p "$extract_dir"
        printf '#!/usr/bin/env bash\nprintf "shadowsocks 9.9.9\\n"\n' > "$extract_dir/ssserver"
        chmod 0755 "$extract_dir/ssserver"
    }

    install_core >/dev/null && \
        [[ "$("$BIN_PATH")" == "shadowsocks 9.9.9" ]] && \
        [[ -f "$CORE_BACKUP_PATH" ]] && \
        rollback_core_update >/dev/null && \
        [[ "$("$BIN_PATH")" == "old-core" ]]
}

test_health_checks_tcp_and_udp() {
    local case_dir
    case_dir=$(mktemp -d /tmp/ssrust-health.XXXXXX)
    TEST_CASE_DIR=$case_dir
    trap 'rm -rf -- "$TEST_CASE_DIR"' EXIT
    CONFIG_FILE="$case_dir/config.json"
    printf '%s\n' '{"server_port":23456,"mode":"tcp_and_udp"}' > "$CONFIG_FILE"
    systemctl() {
        case "$1" in
            is-active) return 0 ;;
            show) printf '4242\n' ;;
            *) return 0 ;;
        esac
    }
    sleep() { :; }
    lsof() { [[ "$*" == *'-p 4242'* ]]; }

    check_service_health >/dev/null
}

test_health_fails_without_udp_listener() {
    local case_dir
    case_dir=$(mktemp -d /tmp/ssrust-health.XXXXXX)
    TEST_CASE_DIR=$case_dir
    trap 'rm -rf -- "$TEST_CASE_DIR"' EXIT
    CONFIG_FILE="$case_dir/config.json"
    printf '%s\n' '{"server_port":23456,"mode":"tcp_and_udp"}' > "$CONFIG_FILE"
    systemctl() {
        case "$1" in
            is-active) return 0 ;;
            show) printf '4242\n' ;;
            *) return 0 ;;
        esac
    }
    sleep() { :; }
    lsof() { [[ "$*" != *'-iUDP:'* ]]; }

    ! check_service_health >/dev/null 2>&1
}

test_config_transaction_rollback() {
    local case_dir restart_called=0
    case_dir=$(mktemp -d /tmp/ssrust-config.XXXXXX)
    TEST_CASE_DIR=$case_dir
    trap 'rm -rf -- "$TEST_CASE_DIR"' EXIT
    CONFIG_DIR="$case_dir/etc/shadowsocks-rust"
    CONFIG_FILE="$CONFIG_DIR/config.json"
    REMARKS_FILE="$CONFIG_DIR/remarks"
    SERVICE_FILE="$case_dir/shadowsocks-rust.service"
    CONFIG_TXN_DIR=""
    CONFIG_TXN_ACTIVE=0
    CORE_INSTALLED_THIS_RUN=0
    mkdir -p "$CONFIG_DIR"
    printf 'old-config\n' > "$CONFIG_FILE"
    printf 'old-remarks\n' > "$REMARKS_FILE"
    printf 'old-service\n' > "$SERVICE_FILE"
    systemctl() {
        case "$1" in
            is-active|is-enabled) return 0 ;;
            restart) restart_called=1 ;;
            *) return 0 ;;
        esac
    }

    begin_config_transaction >/dev/null || return 1
    printf 'new-config\n' > "$CONFIG_FILE"
    printf 'new-remarks\n' > "$REMARKS_FILE"
    printf 'new-service\n' > "$SERVICE_FILE"
    rollback_config_transaction >/dev/null || return 1

    [[ "$(< "$CONFIG_FILE")" == "old-config" ]] && \
        [[ "$(< "$REMARKS_FILE")" == "old-remarks" ]] && \
        [[ "$(< "$SERVICE_FILE")" == "old-service" ]] && \
        (( restart_called == 1 && CONFIG_TXN_ACTIVE == 0 ))
}

test_existing_identity_is_not_marked_or_removed() {
    local case_dir userdel_called=0 groupdel_called=0
    case_dir=$(mktemp -d /tmp/ssrust-identity.XXXXXX)
    TEST_CASE_DIR=$case_dir
    trap 'rm -rf -- "$TEST_CASE_DIR"' EXIT
    STATE_DIR="$case_dir/state"
    MANAGED_USER_MARKER="$STATE_DIR/managed-user"
    MANAGED_GROUP_MARKER="$STATE_DIR/managed-group"
    install() {
        local destination=${!#}
        if [[ " $* " == *' -d '* ]]; then
            mkdir -p "$destination"
        else
            : > "$destination"
        fi
    }
    id() { return 0; }
    getent() { return 0; }
    groupadd() { return 99; }
    useradd() { return 99; }
    userdel() { userdel_called=1; }
    groupdel() { groupdel_called=1; }

    ensure_service_user >/dev/null && \
        [[ ! -e "$MANAGED_USER_MARKER" && ! -e "$MANAGED_GROUP_MARKER" ]] && \
        remove_managed_service_identity >/dev/null && \
        (( userdel_called == 0 && groupdel_called == 0 ))
}

run_test "architecture mapping" test_arch_mapping
run_test "unknown architecture rejection" test_arch_rejects_unknown
run_test "SS2022 password validation" test_2022_password_validation
run_test "EOF cancels prompts" test_prompt_rejects_eof
run_test "extract failure preserves installed core" test_extract_failure_preserves_core
run_test "core update can roll back" test_core_rollback
run_test "health check verifies TCP and UDP" test_health_checks_tcp_and_udp
run_test "health check detects missing UDP" test_health_fails_without_udp_listener
run_test "configuration transaction can roll back" test_config_transaction_rollback
run_test "existing service identity is preserved" test_existing_identity_is_not_marked_or_removed

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
(( FAILED == 0 ))
