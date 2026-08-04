#!/usr/bin/env bash
# Applies every migration to a throwaway PostgreSQL instance and runs the
# backend assertions against it — schema, RLS coverage, the transactional
# booking RPC, and tenant isolation.
#
# This needs no Supabase account and no network: Backend/supabase/tests/
# platform_shim.sql recreates the `auth` schema and the anon/authenticated
# roles the hosted platform would provide, so the real migrations run
# unmodified.
#
# Requires postgresql (initdb, pg_ctl, psql) on PATH or under
# /usr/lib/postgresql/*/bin.
#
# Usage: Scripts/backend-tests.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS="${ROOT}/Backend/supabase/migrations"
TESTS="${ROOT}/Backend/supabase/tests"
PORT="${PRV_TEST_PGPORT:-55432}"
SOCKET_DIR="$(mktemp -d)"
PGDATA="$(mktemp -d)/prvdata"
DB=prv_test

# Prefer a versioned Postgres install when the tools are not already on PATH.
if ! command -v initdb >/dev/null 2>&1; then
    for candidate in /usr/lib/postgresql/*/bin; do
        [ -d "${candidate}" ] && export PATH="${candidate}:${PATH}"
    done
fi

# Postgres refuses to run as root, so fall back to the postgres account when
# this script is invoked by root (CI containers usually are).
RUNNER=""
if [ "$(id -u)" -eq 0 ]; then
    RUNNER="postgres"
    mkdir -p "${PGDATA}" "${SOCKET_DIR}"
    chown -R postgres "${PGDATA}" "${SOCKET_DIR}" "$(dirname "${PGDATA}")"
fi

run() {
    if [ -n "${RUNNER}" ]; then
        su "${RUNNER}" -c "PATH='${PATH}' $1"
    else
        bash -c "$1"
    fi
}

cleanup() {
    run "pg_ctl -D '${PGDATA}' -m immediate stop" >/dev/null 2>&1 || true
    rm -rf "${PGDATA}" "${SOCKET_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> starting a throwaway PostgreSQL on port ${PORT}"
run "initdb -D '${PGDATA}' -A trust" >/dev/null
run "pg_ctl -D '${PGDATA}' -l '${PGDATA}/server.log' -o '-k ${SOCKET_DIR} -p ${PORT} -c listen_addresses=' -w start" >/dev/null

PSQL="psql -h ${SOCKET_DIR} -p ${PORT} -U postgres -v ON_ERROR_STOP=1 -q"
[ -n "${RUNNER}" ] && PSQL="su ${RUNNER} -c \"PATH='${PATH}' ${PSQL}"

psql_run() {
    if [ -n "${RUNNER}" ]; then
        su "${RUNNER}" -c "PATH='${PATH}' psql -h '${SOCKET_DIR}' -p ${PORT} -U postgres -v ON_ERROR_STOP=1 -q $*"
    else
        psql -h "${SOCKET_DIR}" -p "${PORT}" -U postgres -v ON_ERROR_STOP=1 -q $*
    fi
}

psql_run "-c 'create database ${DB};'"

echo "==> installing the Supabase platform shim (test-only)"
psql_run "-d ${DB} -f '${TESTS}/platform_shim.sql'" >/dev/null

echo "==> applying migrations"
for migration in "${MIGRATIONS}"/*.sql; do
    echo "    $(basename "${migration}")"
    psql_run "-d ${DB} -f '${migration}'" >/dev/null
done

echo "==> running assertions"
psql_run "-d ${DB} -c 'create schema if not exists tests;'" >/dev/null
psql_run "-d ${DB} -f '${TESTS}/assertions.sql'"

echo
echo "Backend verified: migrations apply, RLS covers every table, the booking"
echo "RPC rejects overlaps, and tenants are isolated."
