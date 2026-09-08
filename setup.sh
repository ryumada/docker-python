#!/usr/bin/env bash
# ==============================================================================
# Setup & Granian Code Verification Script for SMIS Mock Server
# Target App: /home/ryumada/git_repositories/docker-python/app/unitama_mockserver_smis/index.py
# Source Addon: /home/ryumada/git_repositories/unitama-18ent-addons/custom_addons/tilabs_unitama_api_base/mock_server.py
# ==============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve APP_DIRNAME (auto-detects if unset)
APP_DIRNAME="$(grep -E '^APP_DIRNAME=' "${SCRIPT_DIR}/.env" 2>/dev/null | cut -d '=' -f2- | tr -d ' "\r\n' || echo '')"
if [ -z "${APP_DIRNAME}" ]; then
    APP_DIRNAME="$(find "${SCRIPT_DIR}/app" -mindepth 1 -maxdepth 1 -type d ! -name ".*" -printf '%f\n' 2>/dev/null | head -n 1 || echo '')"
fi
[ -z "${APP_DIRNAME}" ] && APP_DIRNAME="unitama_mockserver_smis"

# Resolve GRANIAN_TARGET (Generic Framework & Entrypoint Support)
GRANIAN_TARGET="$(grep -E '^GRANIAN_TARGET=' "${SCRIPT_DIR}/.env" 2>/dev/null | cut -d '=' -f2- | tr -d ' "\r\n' || echo 'index:app')"
[ -z "${GRANIAN_TARGET}" ] && GRANIAN_TARGET="index:app"

ENTRY_MODULE="${GRANIAN_TARGET%%:*}"
ENTRY_CALLABLE="${GRANIAN_TARGET##*:}"
TARGET_FILE="${SCRIPT_DIR}/app/${APP_DIRNAME}/${ENTRY_MODULE}.py"
SOURCE_FILE="${SCRIPT_DIR}/../unitama-18ent-addons/custom_addons/tilabs_unitama_api_base/mock_server.py"

# Formatting
BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
RESET='\033[0m'

ERRORS=0
WARNINGS=0

log_info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
log_success() { echo -e "${GREEN}[OK]${RESET} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; ((WARNINGS++)); }
log_fail()    { echo -e "${RED}[FAIL]${RESET} $*"; ((ERRORS++)); }

print_banner() {
    echo -e "${BOLD}${CYAN}"
    echo "============================================================"
    echo "   SMIS Mock Server - Granian & Docker Readiness Checker    "
    echo "   App: app/unitama_mockserver_smis/index.py                "
    echo "============================================================"
    echo -e "${RESET}"
}

print_help() {
    print_banner
    echo -e "${BOLD}Usage:${RESET} ./setup.sh [COMMAND]"
    echo ""
    echo -e "${BOLD}Commands:${RESET}"
    echo "  --check       (Default) Run complete verification (system, Granian code, .env, ports)"
    echo "  --check-code  Check only python code compatibility for Granian deployment"
    echo "  --fix-code    Automatically patch index.py (and mock_server.py) with Granian-ready code"
    echo "  --create-env  Create .env from .env.example with a cryptographically secure secret"
    echo "  --build       Run checks and build the Docker image"
    echo "  --up, --start Run checks, build and start container in background"
    echo "  --down, --stop Stop and remove running container"
    echo "  --restart     Restart the container"
    echo "  --test        Send test authentication request to the running server"
    echo "  --logs        View live container logs"
    echo "  --help        Display this help message"
    echo ""
}

# 1. Check Host Tools
check_system_tools() {
    echo -e "\n${BOLD}${CYAN}[1/5] Checking System Prerequisites...${RESET}"

    # Docker CLI
    if command -v docker >/dev/null 2>&1; then
        local docker_ver
        docker_ver="$(docker --version 2>/dev/null || echo 'Unknown')"
        log_success "Docker CLI: ${DIM}${docker_ver}${RESET}"
    else
        log_fail "Docker is NOT installed. Please install Docker first."
    fi

    # Docker Daemon Connectivity
    if docker info >/dev/null 2>&1; then
        log_success "Docker daemon is running and accessible."
    else
        log_fail "Cannot connect to Docker daemon. Ensure Docker is running."
    fi

    # Docker Compose
    if docker compose version >/dev/null 2>&1; then
        local compose_ver
        compose_ver="$(docker compose version 2>/dev/null || echo 'Unknown')"
        log_success "Docker Compose plugin: ${DIM}${compose_ver}${RESET}"
    elif command -v docker-compose >/dev/null 2>&1; then
        local compose_ver
        compose_ver="$(docker-compose --version 2>/dev/null || echo 'Unknown')"
        log_success "Docker Compose standalone: ${DIM}${compose_ver}${RESET}"
    else
        log_fail "Docker Compose is NOT installed."
    fi

    # curl
    if command -v curl >/dev/null 2>&1; then
        log_success "curl is available."
    else
        log_warn "curl is not installed (needed for endpoint testing)."
    fi
}

# 2. Granian Python Code Requirements Analysis
verify_python_code() {
    local file_to_check="$1"
    local file_label="$2"

    echo -e "\n${BOLD}Analyzing ${file_label}:${RESET} ${DIM}${file_to_check}${RESET}"

    if [ ! -f "${file_to_check}" ]; then
        log_fail "File does not exist: ${file_to_check}"
        return 1
    fi

    # Run AST-based code analysis via Python
    local result
    result="$(python3 - <<PYEOF
import ast, sys

filepath = "${file_to_check}"
try:
    with open(filepath, "r", encoding="utf-8") as f:
        source = f.read()
    tree = ast.parse(source)
except Exception as e:
    print(f"FATAL: {e}")
    sys.exit(1)

# Check 1: Entrypoint callable defined at module level
expected_callable = "${ENTRY_CALLABLE}"
has_callable = False
for node in tree.body:
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == expected_callable:
                has_callable = True
                break

if has_callable:
    print(f"PASS:Entrypoint callable '{expected_callable}' defined at module level.")
else:
    print(f"FAIL:Callable '{expected_callable}' (from GRANIAN_TARGET) not found at module root.")

# Check 2: Top-level blocking calls (e.g. unconditional app.run)
blocking_run = False
for node in tree.body:
    if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call):
        func = node.value.func
        if isinstance(func, ast.Attribute) and func.attr == "run":
            blocking_run = True
            break

if blocking_run:
    print("FAIL:'app.run()' is called at top level outside 'if __name__ == \"__main__\":'! This will block Granian.")
else:
    print("PASS:No blocking 'app.run()' at module root.")

# Check 3: Host-specific .env path
if "/opt/odoo_data" in source:
    print("FAIL:Hardcoded host path '/opt/odoo_data/odoo18/server/.env' detected. This file does NOT exist inside Docker container.")
else:
    print("PASS:No hardcoded host path for .env file.")

# Check 4: Dynamic SECRET_KEY
secret_dynamic = False
secret_found = False
for node in tree.body:
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == "SECRET_KEY":
                secret_found = True
                if isinstance(node.value, ast.Call):
                    secret_dynamic = True
                elif isinstance(node.value, ast.Constant):
                    if node.value.value in ("your-secret-key", "change-this-to-a-secure-random-secret-key"):
                        print(f"WARN:SECRET_KEY is hardcoded to placeholder '{node.value.value}' (does not read from os.getenv).")
                    else:
                        print("WARN:SECRET_KEY is a static string constant (does not read from os.getenv).")

if secret_dynamic:
    print("PASS:SECRET_KEY reads dynamically from environment variables.")

# Check 5: Dynamic VALID_USERNAME / VALID_PASSWORD
user_dynamic = False
for node in tree.body:
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == "VALID_USERNAME":
                if isinstance(node.value, ast.Call):
                    user_dynamic = True
                else:
                    print("WARN:VALID_USERNAME is hardcoded (does not read from os.getenv).")

if user_dynamic:
    print("PASS:VALID_USERNAME reads dynamically from environment variables.")

PYEOF
)"

    # Parse Python output line by line
    while IFS= read -r line; do
        if [[ "${line}" == PASS:* ]]; then
            log_success "${line#PASS:}"
        elif [[ "${line}" == WARN:* ]]; then
            log_warn "${line#WARN:}"
        elif [[ "${line}" == FAIL:* ]]; then
            log_fail "${line#FAIL:}"
        elif [ -n "${line}" ]; then
            log_info "${line}"
        fi
    done <<< "${result}"
}

check_all_python_codes() {
    echo -e "\n${BOLD}${CYAN}[2/5] Verifying Python Code Requirements for Granian...${RESET}"

    # Verify primary deployment file (index.py)
    if [ -f "${TARGET_FILE}" ]; then
        verify_python_code "${TARGET_FILE}" "Target Deployment File (index.py)"
    else
        log_fail "Target index.py not found at: ${TARGET_FILE}"
    fi

    # Verify source file (mock_server.py) in addon repo if available
    if [ -f "${SOURCE_FILE}" ]; then
        verify_python_code "${SOURCE_FILE}" "Source Addon File (mock_server.py)"
    fi
}

# 3. Check Container Files & Granian Alignment
check_container_files() {
    echo -e "\n${BOLD}${CYAN}[3/5] Checking Docker & Granian Configuration...${RESET}"

    # requirements.txt
    local req_file="${SCRIPT_DIR}/requirements.txt"
    if [ -f "${req_file}" ]; then
        log_success "requirements.txt found."
        for pkg in granian flask pyjwt python-dotenv; do
            if grep -iq "^${pkg}" "${req_file}"; then
                log_success "  - Dependency '${pkg}' listed."
            else
                log_warn "  - Dependency '${pkg}' might be missing from requirements.txt."
            fi
        done
    else
        log_fail "requirements.txt not found!"
    fi

    # Dockerfile alignment
    local df_file="${SCRIPT_DIR}/Dockerfile"
    if [ -f "${df_file}" ]; then
        log_success "Dockerfile found."
        if grep -q "GRANIAN_TARGET" "${df_file}"; then
            log_success "Dockerfile dynamically runs GRANIAN_TARGET (${GRANIAN_TARGET})."
        elif grep -q "index:app" "${df_file}"; then
            log_success "Dockerfile is configured with default entrypoint index:app."
        fi

        if grep -q "\-\-interface[[:space:]]\+wsgi" "${df_file}" || grep -q "GRANIAN_INTERFACE=wsgi" "${SCRIPT_DIR}/.env" 2>/dev/null; then
            log_success "Granian WSGI interface is explicitly configured."
        else
            log_fail "Granian interface MUST be specified as WSGI for Flask! Add '--interface wsgi'."
        fi
    else
        log_fail "Dockerfile not found!"
    fi

    # docker-compose.yml
    if [ -f "${SCRIPT_DIR}/docker-compose.yml" ]; then
        log_success "docker-compose.yml found."
    else
        log_fail "docker-compose.yml not found."
    fi
}

# 4. Check Environment Configuration (.env)
check_env_config() {
    echo -e "\n${BOLD}${CYAN}[4/5] Checking Environment Configuration (.env)...${RESET}"

    local env_file="${SCRIPT_DIR}/.env"

    if [ ! -f "${env_file}" ]; then
        log_warn ".env file is missing."
        create_env_file
    else
        log_success ".env file exists."
    fi

    # GRANIAN_TARGET (Generic Entrypoint)
    local target
    target="$(grep -E '^GRANIAN_TARGET=' "${env_file}" 2>/dev/null | cut -d '=' -f2- | tr -d ' "\r\n' || echo 'index:app')"
    [ -z "${target}" ] && target="index:app"
    log_success "GRANIAN_TARGET='${target}' (Module: ${target%%:*}.py, Callable: ${target##*:})."

    # GRANIAN_INTERFACE (Generic Framework Support - WSGI / ASGI)
    local iface
    iface="$(grep -E '^GRANIAN_INTERFACE=' "${env_file}" 2>/dev/null | cut -d '=' -f2- | tr -d ' "\r\n' || echo 'wsgi')"
    [ -z "${iface}" ] && iface="wsgi"
    if [ "${iface}" = "wsgi" ]; then
        log_success "GRANIAN_INTERFACE='wsgi' (WSGI mode for Flask, Django, etc.)."
    elif [ "${iface}" = "asgi" ]; then
        log_success "GRANIAN_INTERFACE='asgi' (ASGI mode for FastAPI, Starlette, etc.)."
    else
        log_fail "GRANIAN_INTERFACE='${iface}' is unrecognized. Must be 'wsgi' or 'asgi'."
    fi
    # GRANIAN_HOST
    local host
    host="$(grep -E '^GRANIAN_HOST=' "${env_file}" 2>/dev/null | cut -d '=' -f2- | tr -d ' "\r\n' || echo '')"
    if [ "${host}" = "0.0.0.0" ]; then
        log_success "GRANIAN_HOST='0.0.0.0' (Bound to all interfaces for Docker)."
    else
        log_warn "GRANIAN_HOST is '${host:-unset}'. Set to '0.0.0.0' for Docker port forwarding."
    fi

    # GRANIAN_PORT
    local port
    port="$(grep -E '^GRANIAN_PORT=' "${env_file}" 2>/dev/null | cut -d '=' -f2- | tr -d ' "\r\n' || echo '5000')"
    if [[ "${port}" =~ ^[0-9]+$ ]]; then
        log_success "GRANIAN_PORT='${port}'."
    else
        log_fail "GRANIAN_PORT is invalid: '${port}'."
    fi

    # SECRET_KEY
    local secret
    secret="$(grep -E '^SECRET_KEY=' "${env_file}" 2>/dev/null | cut -d '=' -f2- | tr -d ' "\r\n' || echo '')"
    if [ -z "${secret}" ] || [ "${secret}" = "your-secret-key" ] || [ "${secret}" = "change-this-to-a-secure-random-secret-key" ]; then
        log_warn "SECRET_KEY in .env is using default placeholder. Generate a strong key."
    else
        log_success "SECRET_KEY has custom secret configured."
    fi

    # PYTHONUNBUFFERED
    local unbuffered
    unbuffered="$(grep -E '^PYTHONUNBUFFERED=' "${env_file}" 2>/dev/null | cut -d '=' -f2- | tr -d ' "\r\n' || echo '')"
    if [ "${unbuffered}" = "1" ]; then
        log_success "PYTHONUNBUFFERED=1 (Immediate container logging)."
    else
        log_warn "PYTHONUNBUFFERED is not set to 1. Logs might be delayed."
    fi
}

# 5. Check Port Availability
check_port_availability() {
    echo -e "\n${BOLD}${CYAN}[5/5] Checking Port Availability...${RESET}"

    local env_file="${SCRIPT_DIR}/.env"
    local port="5000"

    if [ -f "${env_file}" ]; then
        port="$(grep -E '^GRANIAN_PORT=' "${env_file}" 2>/dev/null | cut -d '=' -f2- | tr -d ' "\r\n' || echo '5000')"
    fi

    local occupied=0

    if command -v ss >/dev/null 2>&1; then
        if ss -tuln | grep -E "[: ]${port}[[:space:]]" >/dev/null 2>&1; then
            occupied=1
        fi
    elif command -v lsof >/dev/null 2>&1; then
        if lsof -i ":${port}" >/dev/null 2>&1; then
            occupied=1
        fi
    fi

    if [ "${occupied}" -eq 1 ]; then
        if docker ps --filter "name=smis_mock_server" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
            log_info "Port ${port} is currently active and mapped to our 'smis_mock_server' container."
        else
            log_warn "Port ${port} is already bound by another process on the host!"
            if command -v lsof >/dev/null 2>&1; then
                lsof -i ":${port}" | head -n 5
            fi
        fi
    else
        log_success "Port ${port} is available for binding."
    fi
}

print_summary() {
    echo -e "\n${BOLD}${CYAN}Pre-flight Verification Summary${RESET}"
    echo "------------------------------------------------------------"
    if [ "${ERRORS}" -eq 0 ] && [ "${WARNINGS}" -eq 0 ]; then
        echo -e "${BOLD}${GREEN}✔ ALL CHECKS PASSED! Ready for Granian Docker deployment.${RESET}"
    elif [ "${ERRORS}" -eq 0 ]; then
        echo -e "${BOLD}${YELLOW}⚠ CHECKS PASSED WITH ${WARNINGS} WARNING(S). Review recommendations above.${RESET}"
        echo -e "Tip: You can auto-patch code with: ${BOLD}./setup.sh --fix-code${RESET}"
    else
        echo -e "${BOLD}${RED}✘ ${ERRORS} CRITICAL ERROR(S) AND ${WARNINGS} WARNING(S) FOUND.${RESET}"
        echo -e "Please fix critical errors before deploying."
        echo -e "Tip: You can auto-patch code with: ${BOLD}./setup.sh --fix-code${RESET}"
        return 1
    fi
    echo "------------------------------------------------------------"
    return 0
}

# --- Code Patching Utility ---
patch_python_file() {
    local target="$1"
    if [ ! -f "${target}" ]; then
        log_fail "Target not found: ${target}"
        return 1
    fi

    log_info "Creating backup: ${target}.bak..."
    cp "${target}" "${target}.bak"

    python3 - <<PYEOF
import re

filepath = "${target}"
with open(filepath, "r", encoding="utf-8") as f:
    content = f.read()

# 1. Replace dotenv loading (including any comment blocks)
old_dotenv_pattern = r"(?:#.*?\n)*\s*dotenv_path\s*=\s*['\"].*?['\"][^\n]*\n(?:[ \t]*#.*?\n|[ \t]*\n)*\s*load_dotenv\(dotenv_path=dotenv_path\)"
new_dotenv_block = """# Load environment variables: fallback to .env if custom path not specified
dotenv_path = os.getenv('DOTENV_PATH', '.env')
if os.path.exists(dotenv_path):
    load_dotenv(dotenv_path=dotenv_path)
else:
    load_dotenv()"""

content = re.sub(old_dotenv_pattern, new_dotenv_block, content)

# Also clean up any lingering raw /opt/odoo_data references
if "/opt/odoo_data" in content:
    content = re.sub(r"dotenv_path\s*=\s*['\"]/opt/odoo_data.*?['\"]", "dotenv_path = os.getenv('DOTENV_PATH', '.env')", content)

# 2. Replace hardcoded JWT & Credentials
old_jwt_pattern = r'(?:#.*?\n)*\s*SECRET_KEY\s*=\s*["\'].*?["\'].*?\n\s*ALGORITHM\s*=\s*["\'].*?["\'].*?\n\s*TOKEN_EXPIRATION\s*=\s*\d+.*?\n+(?:#.*?\n)*\s*VALID_USERNAME\s*=\s*["\'].*?["\'].*?\n\s*VALID_PASSWORD\s*=\s*["\'].*?["\']'

new_jwt_block = """# JWT configuration from environment variables
SECRET_KEY = os.getenv("SECRET_KEY", "your-secret-key")
ALGORITHM = os.getenv("JWT_ALGORITHM", "HS256")
TOKEN_EXPIRATION = int(os.getenv("TOKEN_EXPIRATION", "3600"))

# Valid login credentials from environment variables
VALID_USERNAME = os.getenv("VALID_USERNAME", "admin")
VALID_PASSWORD = os.getenv("VALID_PASSWORD", "admin")"""

content = re.sub(old_jwt_pattern, new_jwt_block, content)

# 3. Update main runner
old_main_pattern = r"if __name__ == '__main__':\s*\n\s*port = os\.environ\.get\('PORT'\)\s*\n\s*app\.run\(debug=True,\s*port=port\)"
new_main_block = """if __name__ == '__main__':
    port = int(os.environ.get('PORT', os.environ.get('GRANIAN_PORT', 5000)))
    app.run(host='0.0.0.0', debug=False, port=port)"""

content = re.sub(old_main_pattern, new_main_block, content)

with open(filepath, "w", encoding="utf-8") as f:
    f.write(content)

print("SUCCESS")
PYEOF

    log_success "Patched ${target} with Granian-ready code."
}

cmd_fix_code() {
    print_banner
    echo -e "${BOLD}${BLUE}Patching Python files for Granian compatibility...${RESET}\n"

    if [ -f "${TARGET_FILE}" ]; then
        patch_python_file "${TARGET_FILE}"
    fi

    if [ -f "${SOURCE_FILE}" ]; then
        patch_python_file "${SOURCE_FILE}"
    fi

    echo -e "\n${BOLD}${CYAN}Re-running code checks after patch...${RESET}"
    ERRORS=0
    WARNINGS=0
    check_all_python_codes
}

create_env_file() {
    local env_file="${SCRIPT_DIR}/.env"
    local env_example="${SCRIPT_DIR}/.env.example"

    if [ ! -f "${env_example}" ]; then
        log_fail ".env.example does not exist."
        return 1
    fi

    log_info "Creating .env from .env.example..."
    cp "${env_example}" "${env_file}"

    local secret
    if command -v openssl >/dev/null 2>&1; then
        secret="$(openssl rand -hex 32)"
    else
        secret="$(python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null || date +%s%N | sha256sum | head -c 64)"
    fi

    if [ -n "${secret}" ]; then
        sed -i "s|SECRET_KEY=change-this-to-a-secure-random-secret-key|SECRET_KEY=${secret}|g" "${env_file}"
        log_success "Generated new cryptographically secure SECRET_KEY in .env."
    fi
    log_success ".env created successfully."
}

cmd_build() {
    check_all_python_codes
    check_container_files
    check_env_config
    if ! print_summary; then exit 1; fi

    echo -e "\n${BOLD}${BLUE}Building Docker image...${RESET}"
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" build
    log_success "Docker image built successfully."
}

cmd_up() {
    check_all_python_codes
    check_container_files
    check_env_config
    check_port_availability
    if ! print_summary; then exit 1; fi

    echo -e "\n${BOLD}${BLUE}Starting container in background...${RESET}"
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d --build
    log_success "Container 'smis_mock_server' started!"
    echo -e "\nManagement commands:"
    echo "  - Test endpoint: ./setup.sh --test"
    echo "  - View logs:     ./setup.sh --logs"
    echo "  - Stop server:   ./setup.sh --down"
}

cmd_down() {
    echo -e "\n${BOLD}${BLUE}Stopping container...${RESET}"
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" down
    log_success "Container stopped."
}

cmd_restart() {
    cmd_down
    cmd_up
}

cmd_logs() {
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" logs -f
}

cmd_test() {
    local env_file="${SCRIPT_DIR}/.env"
    local port="5000"
    local user="admin"
    local pass="admin"

    if [ -f "${env_file}" ]; then
        port="$(grep -E '^GRANIAN_PORT=' "${env_file}" 2>/dev/null | cut -d '=' -f2- | tr -d ' "\r\n' || echo '5000')"
        user="$(grep -E '^VALID_USERNAME=' "${env_file}" 2>/dev/null | cut -d '=' -f2- | tr -d ' "\r\n' || echo 'admin')"
        pass="$(grep -E '^VALID_PASSWORD=' "${env_file}" 2>/dev/null | cut -d '=' -f2- | tr -d ' "\r\n' || echo 'admin')"
    fi

    echo -e "\n${BOLD}${CYAN}Testing /auth/token endpoint (http://localhost:${port}/auth/token)...${RESET}"

    if ! command -v curl >/dev/null 2>&1; then
        log_fail "curl is not installed."
        exit 1
    fi

    local response
    response="$(curl -s -w "\n%{http_code}" -X POST "http://localhost:${port}/auth/token" \
        -H "Content-Type: application/json" \
        -d "{\"username\": \"${user}\", \"password\": \"${pass}\"}" 2>&1)"

    local http_code
    http_code="$(echo "${response}" | tail -n1)"
    local body
    body="$(echo "${response}" | sed '$d')"

    if [ "${http_code}" = "200" ]; then
        log_success "Success! Received HTTP 200 with JWT token:"
        echo -e "${DIM}${body}${RESET}"
    else
        log_fail "Request failed with HTTP status ${http_code}:"
        echo -e "${RED}${body}${RESET}"
        exit 1
    fi
}

# --- Router ---
ACTION="${1:---check}"

case "${ACTION}" in
    --check)
        print_banner
        check_system_tools
        check_all_python_codes
        check_container_files
        check_env_config
        check_port_availability
        print_summary
        ;;
    --check-code)
        print_banner
        check_all_python_codes
        ;;
    --fix-code|--patch)
        cmd_fix_code
        ;;
    --create-env)
        print_banner
        create_env_file
        ;;
    --build)
        print_banner
        cmd_build
        ;;
    --up|--start)
        print_banner
        cmd_up
        ;;
    --down|--stop)
        cmd_down
        ;;
    --restart)
        cmd_restart
        ;;
    --test)
        cmd_test
        ;;
    --logs)
        cmd_logs
        ;;
    --help|-h)
        print_help
        ;;
    *)
        echo -e "${RED}Unknown command: ${ACTION}${RESET}"
        print_help
        exit 1
        ;;
esac
