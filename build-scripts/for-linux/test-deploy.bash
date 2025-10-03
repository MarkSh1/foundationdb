#!/bin/bash

# Test deploying foundationdb on rpm-and deb-based linux
# $1 - full Foundationdb version, ex. 7.1.29-0.ow.1
# $2 - distr dir. Default is bld/linux/packages relative to the current dir
# $3 - a rpm-based linux docker image. Default is oraclelinux:8
# $4 - a deb-based linux docker image. Default is debian:10

set -e

FULL_VERSION="$1"
DISTR_DIR="$(readlink -f ${2:-bld/linux/packages})"
RPM_IMAGE=${3:-oraclelinux:8}
DEB_IMAGE=${4:-debian:10}
CONTAINER_NAME="test_deploy"
CONTAINER_MOUNTS="$DISTR_DIR:/mnt/distr"

err() { 
  echo -e "\033[1;31m$*\033[0m" >&2; 
}

log() { 
  echo -e "\033[1;34m$*\033[0m"; 
}

print_usage() {
  err "Usage: $0 FullFdbVersion [FdbDistrDir] [RpmImage] [DebImage]"
}

# testing parameters
if [[ -z "$FULL_VERSION" ]]; then
  err "FullFdbVersion is not specified."
  print_usage
  return 1 2>/dev/null || exit 1
fi

if ! ls "$DISTR_DIR"/foundationdb-*$FULL_VERSION*.{rpm,deb}; then
  err "No $DISTR_DIR/foundationdb-*$FULL_VERSION*.{rpm,deb} files have been found."
  err "Possible FdbDistrDir is not correct."
  print_usage
  return 1 2>/dev/null || exit 1
fi

# foundationdb writes to files with 2600 mode
# but podman under kernel 6.1 or 6.2 does not respect this
# so test if the writing works and choose an appropriate container engine
test_container_engine() {
  local CONTAINER_ENGINE="$1"
  local CONTAINER_TEST_RUNNABLE='bash -c "touch /tmp/file01.tst; chgrp users /tmp/file01.tst; chmod 2600 /tmp/file01.tst; echo test >/tmp/file01.tst"'
  eval "$CONTAINER_ENGINE run --rm $1 $CONTAINER_TEST_RUNNABLE"
}

#choose an appropriate CONTAINER_ENGINE
if [[ -n "$CONTAINER_ENGINE" ]]; then
  if ! test_container_engine $CONTAINER_ENGINE; then
    err "Fatal: The specified CONTAINER_ENGINE ($CONTAINER_ENGINE) does not pass the test."
    return 1 2>/dev/null || exit 1
  fi
elif test_container_engine podman; then
  CONTAINER_ENGINE=podman
elif test_container_engine docker; then
  CONTAINER_ENGINE=docker
else
  err "Fatal: Neigther podman nor docker passes the test"
  return 1 2>/dev/null || exit 1
fi
log "Using $CONTAINER_ENGINE as a container image"

# check images
$CONTAINER_ENGINE pull "$RPM_IMAGE"
$CONTAINER_ENGINE pull "$DEB_IMAGE"

MY_ARCH_RPM=$(uname -m)
MY_ARCH_DEB=$(dpkg-architecture -q DEB_HOST_ARCH)

wait_for_systemd() {
  local CONTAINER_NAME="$1"
  local TIMEOUT_SEC=20
  local SYSTEMD_READY=""
  local STATE=""
  while true; do
    STATE=$($CONTAINER_ENGINE exec "${CONTAINER_NAME}" systemctl is-system-running 2>/dev/null || true)
    case "$STATE" in
      running|degraded|initializing|starting)
        SYSTEMD_READY=1
        break
        ;;
    esac
    printf "\r\033[K[*] %s (%ds)" "$STATE" "$TIMEOUT_SEC"
    sleep 1
    ((TIMEOUT_SEC--))
    if [[ $TIMEOUT_SEC -le 0 ]]; then
      break
    fi
  done
  if [[ -z "$SYSTEMD_READY" ]]; then
      err "\nSystemd did not start in container (final state: $STATE)"
      return 1
  else
      return 0
  fi
}

get_pkg_type() {
  local FILE="$1"
  if [[ "$FILE" == *".deb"* ]]; then
    echo "deb"
  elif [[ "$FILE" == *".rpm"* ]]; then
    echo "rpm"
  else
    echo "unknown"
  fi
}

remove_container_if_exists() {
  if $CONTAINER_ENGINE ps -a --format "{{.Names}}" | grep -qx "${CONTAINER_NAME}"; then
    $CONTAINER_ENGINE rm -f "${CONTAINER_NAME}"
  fi
}

get_install_cmd() {
  local pkg_type="$1"
  declare -A INSTALL_CMDS=(
    [deb]="apt-get install -y"
    [rpm]="dnf install -y"
  )
  echo "${INSTALL_CMDS[$pkg_type]}"
}

start_systemd_container() {
  local IMAGE="$1"
  local INSTALL_SYSTEMD="$2"
  $CONTAINER_ENGINE run -d --privileged --systemd=always --name "${CONTAINER_NAME}" \
    -e container=podman \
    --tmpfs /run --tmpfs /tmp \
    -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
    -v "${CONTAINER_MOUNTS}:Z,ro" \
    "$IMAGE" \
    /bin/bash -c "$INSTALL_SYSTEMD"
}

reinit_fdb_service() {
  $CONTAINER_ENGINE exec -it "${CONTAINER_NAME}" /bin/bash -c "\
    systemctl enable foundationdb >/dev/null 2>&1 && \
    systemctl start foundationdb >/dev/null 2>&1 && \
    fdbcli --exec 'configure new single memory; status' --timeout 20"
}

run_simple_container() {
  local IMAGE="$1"
  local INSTALL_CMD="$2"
  local INSTALL_DISTR="$3"
  $CONTAINER_ENGINE run --rm \
    -v"${CONTAINER_MOUNTS}:Z,ro" \
    "$IMAGE" \
    /bin/bash -c "$INSTALL_CMD $INSTALL_DISTR"
}

run_in_container() {
  local IMAGE="$1"
  local INSTALL_SYSTEMD=${2:-}
  local INSTALL_DISTR="$3"

  local PKG_TYPE
  PKG_TYPE=$(get_pkg_type "$INSTALL_DISTR")
  local INSTALL_CMD
  INSTALL_CMD=$(get_install_cmd "$PKG_TYPE")

  remove_container_if_exists
  trap 'remove_container_if_exists' RETURN
  
  if [[ -n "$INSTALL_SYSTEMD" ]]
  then
    if ! start_systemd_container "$IMAGE" "$INSTALL_SYSTEMD"
    then
      err "Cannot start a container from $IMAGE"
      return 1
    fi
    if ! wait_for_systemd ${CONTAINER_NAME}; then
      return 1
    fi
    if ! $CONTAINER_ENGINE exec -it ${CONTAINER_NAME} /bin/bash -c "$INSTALL_CMD $INSTALL_DISTR"
    then
      if ! reinit_fdb_service
      then
        err "FDB installation or start failed"
        return 1
      fi
    fi
  else 
    if ! run_simple_container "$IMAGE" "$INSTALL_CMD" "$INSTALL_DISTR"
    then
      err "Cannot start a container from $IMAGE"
      return 1
    fi
  fi
}

run_install_test() {
  local IMAGE="$1"
  local INSTALL_SYSTEMD="$2"
  local INSTALL_DISTR="$3"
  local SHOULD_FAIL="${4:-0}"
  local ERRMSG="$5"


  if run_in_container "$IMAGE" "$INSTALL_SYSTEMD" "$INSTALL_DISTR"; then
    if [[ "$SHOULD_FAIL" -eq 1 ]]; then
      err "$ERRMSG"
      return 1
    fi
    log "<Test passed: $INSTALL_DISTR>"
  else
    if [[ "$SHOULD_FAIL" -eq 0 ]]; then
      err "$ERRMSG"
      return 1
    fi
    log "<Test failed as expected: $INSTALL_DISTR>"
  fi
}


prepare_ol8_systemd() {
  exec /lib/systemd/systemd
}

prepare_debian10_systemd() {
  echo 'deb http://archive.debian.org/debian buster main' > /etc/apt/sources.list
  echo 'deb http://archive.debian.org/debian buster-updates main' >> /etc/apt/sources.list
  echo 'deb http://archive.debian.org/debian-security buster/updates main' >> /etc/apt/sources.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y systemd systemd-sysv dbus
  exec /lib/systemd/systemd
}

test_deploy_pkgs() {
  local IMAGE=$1
  local SERVER_FILE=$2
  local CLIENT_FILE=$3
  local USER_AFTER_CLIENT=${4:-Y}
  local WITH_SYSTEMD=${5:-}
  
  local INSTALL_SYSTEMD=""
  local CLIENT_CHECK_WITH=""
  local ERRMSG_CLIENT=""

  log SERVER_FILE="$SERVER_FILE"
  log CLIENT_FILE="$CLIENT_FILE"

  if [[ $USER_AFTER_CLIENT == Y ]]; then
    CLIENT_CHECK_WITH=""
    ERRMSG_CLIENT="not created"
  else
    CLIENT_CHECK_WITH="!"
    ERRMSG_CLIENT="created unexpectedly"
  fi

  if [[ "$WITH_SYSTEMD" == "systemd" ]]
  then
    if [[ "$IMAGE" == *debian:10* ]]; then
      INSTALL_SYSTEMD="$(declare -f prepare_debian10_systemd); prepare_debian10_systemd"
    elif [[ "$IMAGE" == *oraclelinux:8* ]]; then
      INSTALL_SYSTEMD="$(declare -f prepare_ol8_systemd); prepare_ol8_systemd"
    else
      err "Systemd preparation script is not defined for $IMAGE"
      return 1
    fi
  fi

  declare -a tests=(
    # "desc|install_distr|should_fail|errmsg|errcode"
    "client_only|/mnt/distr/$CLIENT_FILE && $CLIENT_CHECK_WITH getent passwd foundationdb|0|Installation of $CLIENT_FILE failed or the foundationdb user was $ERRMSG_CLIENT.|3"
    "client_and_server|/mnt/distr/$SERVER_FILE /mnt/distr/$CLIENT_FILE && getent passwd foundationdb|0|Installation $SERVER_FILE and $CLIENT_FILE failed or the foundationdb user was not created.|2"
    "server_only|/mnt/distr/$SERVER_FILE|1|Installation $SERVER_FILE without a client must fail.|1"
  )

  for TEST in "${tests[@]}"; do
    IFS="|" read -r DESC INSTALL_DISTR SHOULD_FAIL ERRMSG ERRCODE<<< "$TEST"
    log "<Trying to install: $DESC...>\n"
    run_install_test "$IMAGE" "$INSTALL_SYSTEMD" "$INSTALL_DISTR" "$SHOULD_FAIL" "$ERRMSG" || return "$ERRCODE"
    log "<Test $DESC completed>\n"
  done
}


declare -a DEPLOY_SCENARIOS=(
  # "desc|container_image|server_package_file|client_package_file|check_user_after_client|with_systemd"
  "Testing DEBs deploy|$DEB_IMAGE|foundationdb-server_${FULL_VERSION}_$MY_ARCH_DEB.deb|foundationdb-clients_${FULL_VERSION}_$MY_ARCH_DEB.deb|Y|systemd"
  "Testing versioned DEBs deploy|$DEB_IMAGE|foundationdb-${FULL_VERSION}-server-versioned_${FULL_VERSION}_$MY_ARCH_DEB.deb|foundationdb-${FULL_VERSION}-clients-versioned_${FULL_VERSION}_$MY_ARCH_DEB.deb|N|systemd"
  "Testing RPMs deploy|$RPM_IMAGE|foundationdb-server-${FULL_VERSION}.$MY_ARCH_RPM.rpm|foundationdb-clients-${FULL_VERSION}.$MY_ARCH_RPM.rpm|Y|systemd"
  "Testing versioned RPMs deploy|$RPM_IMAGE|foundationdb-${FULL_VERSION}-server-versioned-${FULL_VERSION}.$MY_ARCH_RPM.rpm|foundationdb-${FULL_VERSION}-clients-versioned-${FULL_VERSION}.$MY_ARCH_RPM.rpm|N|systemd"
)

for SCENARIO in "${DEPLOY_SCENARIOS[@]}"; do
  IFS="|" read -r DESC IMAGE SERVER_FILE CLIENT_FILE USER_AFTER_CLIENT WITH_SYSTEMD <<< "$SCENARIO"
  log "\n<<<$DESC...>>>\n"
  test_deploy_pkgs "$IMAGE" "$SERVER_FILE" "$CLIENT_FILE" "$USER_AFTER_CLIENT" "$WITH_SYSTEMD"
done

log "\n<<<All deployment tests completed successfully>>>\n"