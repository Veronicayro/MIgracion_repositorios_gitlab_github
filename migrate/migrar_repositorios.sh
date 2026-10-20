#!/usr/bin/env bash
#
# migrar_gitlab_github_completo.sh
#
# Migración GitLab -> GitHub:
#   - Repositorios Git: ramas y tags.
#   - Selección por archivo, grupo o todos los proyectos visibles.
#   - Variables y Secrets GitLab.
#   - GitHub Environments para environment_scope GitLab.
#   - Branch Protection Rules básicas.
#   - Miembros del repositorio mediante archivo de equivalencias.
#   - Análisis, preservación o migración Git LFS.
#   - Auditoría y migración de pipelines mediante GitHub Actions Importer.
#
# Requisitos base:
#   bash, curl, jq, git, mktemp, awk, sed, sort, tee
#
# Requisitos opcionales:
#   gh                  Para variables, Environments y miembros GitHub.
#   git-lfs             Para LFS_MODE=preserve o LFS_MODE=migrate.
#   gh actions-importer Para MIGRATE_PIPELINES=true.
#
# Variables obligatorias:
#   GITLAB_URL
#   TOKEN_GITLAB
#   OWNER
#   TOKEN_GITHUB
#
# Selección:
#   REPOSITORIES_FILE tiene prioridad sobre GROUP_GITLAB.
#
# REPOSITORIES_FILE:
#   Un proyecto GitLab por línea usando path_with_namespace o ID.
#
# Ejemplo:
#   nexo-personas/web/nexo-personas
#   grupo/subgrupo/proyecto-api
#   123
#
# Environment mapping opcional:
#   ENVIRONMENT_MAPPING_FILE="./environment-mapping.tsv"
#
# Formato:
#   gitlab_scope|github_environment|allowed_branches
#
# Ejemplo:
#   dev|dev|dev
#   qa|qa|qa
#   production|production|main
#
# Formato:
#   gitlab_username|github_username|github_permission
#
# Ejemplo:
#   usuario_gitlab|usuario_github|maintain
#   developer01|developer01|push
#
# LFS:
#   LFS_MODE=off|report|preserve|migrate
#
#   off      No analiza ni procesa LFS.
#   report   Reporta blobs grandes, sin modificar historial.
#   preserve Copia objetos LFS existentes desde GitLab hacia GitHub.
#   migrate  Convierte patrones definidos en LFS_INCLUDE_PATTERNS a Git LFS.
#
# IMPORTANTE:
#   LFS_MODE=migrate reescribe el historial Git y cambia hashes SHA.
#   Solo se permite si ALLOW_HISTORY_REWRITE=true y el repo GitHub fue
#   creado durante esta misma ejecución.
#

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="$(basename "$0")"
readonly START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

GITLAB_URL="${GITLAB_URL:-}"
TOKEN_GITLAB="${TOKEN_GITLAB:-}"
GROUP_GITLAB="${GROUP_GITLAB:-}"
REPOSITORIES_FILE="${REPOSITORIES_FILE:-}"

OWNER="${OWNER:-}"
TOKEN_GITHUB="${TOKEN_GITHUB:-}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"

PRIVATE_REPOSITORIES="${PRIVATE_REPOSITORIES:-true}"
ALLOW_MIRROR_OVERWRITE="${ALLOW_MIRROR_OVERWRITE:-false}"
DRY_RUN="${DRY_RUN:-false}"
SYNC_DEFAULT_BRANCH="${SYNC_DEFAULT_BRANCH:-true}"

GITLAB_HOST_HEADER="${GITLAB_HOST_HEADER:-}"
GITLAB_CURL_NO_PROXY="${GITLAB_CURL_NO_PROXY:-false}"
GITLAB_GIT_BASE_URL="${GITLAB_GIT_BASE_URL:-}"
GITLAB_GIT_EXTRA_HEADER="${GITLAB_GIT_EXTRA_HEADER:-}"

MIGRATE_VARIABLES="${MIGRATE_VARIABLES:-false}"
VARIABLES_REQUIRED="${VARIABLES_REQUIRED:-false}"
GITHUB_ACTIONS_VARIABLES="${GITHUB_ACTIONS_VARIABLES:-}"
MIGRATE_ENVIRONMENT_SCOPED_VARIABLES="${MIGRATE_ENVIRONMENT_SCOPED_VARIABLES:-false}"
CREATE_GITHUB_ENVIRONMENTS="${CREATE_GITHUB_ENVIRONMENTS:-true}"
CREATE_ENVIRONMENT_BRANCH_POLICIES="${CREATE_ENVIRONMENT_BRANCH_POLICIES:-false}"
ALLOW_DIRECT_ENVIRONMENT_SCOPE_MAPPING="${ALLOW_DIRECT_ENVIRONMENT_SCOPE_MAPPING:-false}"
ENVIRONMENT_MAPPING_FILE="${ENVIRONMENT_MAPPING_FILE:-}"

MIGRATE_BRANCH_PROTECTIONS="${MIGRATE_BRANCH_PROTECTIONS:-false}"
BRANCH_PROTECTIONS_REQUIRED="${BRANCH_PROTECTIONS_REQUIRED:-false}"

MIGRATE_REPOSITORY_MEMBERS="${MIGRATE_REPOSITORY_MEMBERS:-false}"
MEMBERS_REQUIRED="${MEMBERS_REQUIRED:-false}"
ALLOW_GITHUB_ADMIN_PERMISSION="${ALLOW_GITHUB_ADMIN_PERMISSION:-false}"

LFS_MODE="${LFS_MODE:-report}"
LFS_THRESHOLD_MB="${LFS_THRESHOLD_MB:-50}"
LFS_INCLUDE_PATTERNS="${LFS_INCLUDE_PATTERNS:-*.jar,*.war,*.zip,*.tar,*.tar.gz}"
ALLOW_HISTORY_REWRITE="${ALLOW_HISTORY_REWRITE:-false}"

MIGRATE_PIPELINES="${MIGRATE_PIPELINES:-false}"
PIPELINE_MODE="${PIPELINE_MODE:-dry-run}"
PIPELINES_REQUIRED="${PIPELINES_REQUIRED:-false}"
PIPELINE_BRANCHES="${PIPELINE_BRANCHES:-master,main,dev,qa}"
GITLAB_IMPORTER_URL="${GITLAB_IMPORTER_URL:-${GITLAB_URL}}"
CONFIGURE_ACTIONS_IMPORTER="${CONFIGURE_ACTIONS_IMPORTER:-false}"
AUDIT_PIPELINES="${AUDIT_PIPELINES:-true}"

LOG_DIRECTORY="${LOG_DIRECTORY:-$(pwd)/logs}"
LOG_FILE="${LOG_FILE:-${LOG_DIRECTORY}/migracion-$(date +%Y%m%d-%H%M%S).log}"
PIPELINE_REPORT_DIRECTORY="${PIPELINE_REPORT_DIRECTORY:-${LOG_DIRECTORY}/pipelines-$(date +%Y%m%d-%H%M%S)}"
LFS_REPORT_DIRECTORY="${LFS_REPORT_DIRECTORY:-${LOG_DIRECTORY}/lfs-$(date +%Y%m%d-%H%M%S)}"

MEMBER_CONFLICTS_FILE="${MEMBER_CONFLICTS_FILE:-${LOG_DIRECTORY}/member-conflicts-$(date +%Y%m%d-%H%M%S).tsv}"

WORK_ROOT=""
PROJECTS_FILE=""
ASKPASS_FILE=""
HTTP_BODY=""
HTTP_HEADERS=""
HTTP_STATUS=""

CURRENT_GITHUB_REPOSITORY_CREATED=false
CURRENT_GITHUB_REPOSITORY_EXISTED=false
CURRENT_GITHUB_CLONE_URL=""
CURRENT_LARGE_FILE_OVER_GITHUB_LIMIT=false

TOTAL_PROJECTS=0
MIGRATED_PROJECTS=0
CREATED_PROJECTS=0
EXISTING_PROJECTS=0
SKIPPED_PROJECTS=0
FAILED_PROJECTS=0
EMPTY_PROJECTS=0
VARIABLES_MIGRATED=0
VARIABLES_SKIPPED=0
PROTECTIONS_MIGRATED=0
PROTECTIONS_SKIPPED=0
MEMBERS_MIGRATED=0
MEMBERS_SKIPPED=0
MEMBERS_VALIDATED=0
MEMBER_CONFLICTS=0
PIPELINES_ANALYZED=0
PIPELINES_MIGRATED=0
PIPELINES_WITH_WARNING=0
LFS_REPOSITORIES_DETECTED=0
LFS_REPOSITORIES_MIGRATED=0

mkdir -p "${LOG_DIRECTORY}"
printf 'fecha\trepositorio\tgitlab_username\tgitlab_access_level\tgithub_username\tmotivo\tdetalle\n' \
  > "${MEMBER_CONFLICTS_FILE}"


exec > >(tee -a "${LOG_FILE}") 2>&1

if [[ -t 1 ]]; then
  readonly COLOR_RED=$'\033[0;31m'
  readonly COLOR_GREEN=$'\033[0;32m'
  readonly COLOR_YELLOW=$'\033[0;33m'
  readonly COLOR_BLUE=$'\033[0;34m'
  readonly COLOR_RESET=$'\033[0m'
else
  readonly COLOR_RED=""
  readonly COLOR_GREEN=""
  readonly COLOR_YELLOW=""
  readonly COLOR_BLUE=""
  readonly COLOR_RESET=""
fi

log() {
  printf '%s [%s] %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$1" \
    "$2" >&2
}

info() {
  log "INFO" "${COLOR_BLUE}$1${COLOR_RESET}"
}

success() {
  log "OK" "${COLOR_GREEN}$1${COLOR_RESET}"
}

warn() {
  log "ADVERTENCIA" "${COLOR_YELLOW}$1${COLOR_RESET}"
}

error() {
  log "ERROR" "${COLOR_RED}$1${COLOR_RESET}"
}

fatal() {
  error "$1"
  exit 1
}

cleanup() {
  local exit_code=$?

  [[ -n "${HTTP_BODY}" && -f "${HTTP_BODY}" ]] && rm -f "${HTTP_BODY}"
  [[ -n "${HTTP_HEADERS}" && -f "${HTTP_HEADERS}" ]] && rm -f "${HTTP_HEADERS}"
  [[ -n "${WORK_ROOT}" && -d "${WORK_ROOT}" ]] && rm -rf "${WORK_ROOT}"

  if [[ "${exit_code}" -ne 0 ]]; then
    error "El script terminó con código de salida ${exit_code}."
  fi
}

trap cleanup EXIT

require_command() {
  local command_name="$1"  

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    fatal "No se encontró el comando requerido: ${command_name}."
  fi
}

validate_boolean() {
  local variable_name="$1"
  local variable_value="$2"

  case "${variable_value}" in
    true|false)
      ;;
    *)
      fatal "La variable ${variable_name} debe tener valor true o false. Valor recibido: ${variable_value}."
      ;;
  esac
}

validate_url() {
  local variable_name="$1"
  local variable_value="$2"

  if [[ ! "${variable_value}" =~ ^https?://[^[:space:]/]+ ]]; then
    fatal "La variable ${variable_name} no contiene una URL HTTP/HTTPS válida."
  fi
}

url_encode() {
  jq -nr --arg value "$1" '$value | @uri'
}

http_status_is_success() {
  [[ "$1" =~ ^2[0-9]{2}$ ]]
}

is_github_actions_variable() {
  local variable_name="$1"
  local item=""
  local IFS=','
  local variable_list=()

  read -r -a variable_list <<< "${GITHUB_ACTIONS_VARIABLES}"

  for item in "${variable_list[@]}"; do
    [[ "${item}" == "${variable_name}" ]] && return 0
  done

  return 1
}

validate_github_variable_name() {
  local variable_name="$1"

  [[ "${variable_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  [[ "${variable_name}" != GITHUB_* ]] || return 1

  return 0
}

register_member_conflict() {
  local github_repository="$1"
  local gitlab_username="$2"
  local gitlab_access_level="$3"
  local github_username="$4"
  local reason="$5"
  local detail="${6:-}"

  detail="${detail//$'\t'/ }"
  detail="${detail//$'\n'/ }"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "${github_repository}" \
    "${gitlab_username}" \
    "${gitlab_access_level}" \
    "${github_username}" \
    "${reason}" \
    "${detail}" >> "${MEMBER_CONFLICTS_FILE}"

  MEMBER_CONFLICTS=$((MEMBER_CONFLICTS + 1))
}

show_http_error() {
  local system_name="$1"
  local url="$2"

  error "${system_name} respondió HTTP ${HTTP_STATUS} para: ${url}"

  if [[ ! -s "${HTTP_BODY}" ]]; then
    return
  fi

  if jq -e . >/dev/null 2>&1 < "${HTTP_BODY}"; then
    jq -r '
      if type == "object" then
        if .message then .message
        elif .error then .error
        else tojson
        end
      elif type == "array" then
        map(
          if type == "object" and .message then .message
          else tojson
          end
        ) | join("; ")
      else
        tostring
      end
    ' "${HTTP_BODY}" | head -c 3000 >&2

    printf '\n' >&2
  else
    head -c 3000 "${HTTP_BODY}" >&2
    printf '\n' >&2
  fi
}

request_api() {
  local system_name="$1"
  local method="$2"
  local url="$3"
  local payload="${4:-}"

  rm -f "${HTTP_BODY:-}" "${HTTP_HEADERS:-}"

  HTTP_BODY="$(mktemp "${WORK_ROOT}/http-body.XXXXXX")"
  HTTP_HEADERS="$(mktemp "${WORK_ROOT}/http-headers.XXXXXX")"

  local curl_arguments=(
    curl
    --silent
    --show-error
    --location
    --connect-timeout 20
    --max-time 180
    --retry 3
    --retry-delay 2
    --retry-all-errors
    --request "${method}"
    --dump-header "${HTTP_HEADERS}"
    --output "${HTTP_BODY}"
    --write-out "%{http_code}"
  )

  case "${system_name}" in
    GitLab)
      curl_arguments+=(
        --header "PRIVATE-TOKEN: ${TOKEN_GITLAB}"
        --header "Accept: application/json"
      )

      [[ -n "${GITLAB_HOST_HEADER}" ]] &&
        curl_arguments+=(--header "Host: ${GITLAB_HOST_HEADER}")

      [[ "${GITLAB_CURL_NO_PROXY}" == "true" ]] &&
        curl_arguments+=(--noproxy "*")
      ;;
    GitHub)
      curl_arguments+=(
        --header "Authorization: Bearer ${TOKEN_GITHUB}"
        --header "Accept: application/vnd.github+json"
        --header "X-GitHub-Api-Version: 2022-11-28"
        --header "User-Agent: gitlab-github-migration-script"
      )
      ;;
    *)
      fatal "Sistema API no soportado: ${system_name}."
      ;;
  esac

  if [[ -n "${payload}" ]]; then
    curl_arguments+=(
      --header "Content-Type: application/json"
      --data "${payload}"
    )
  fi

  curl_arguments+=("${url}")

  if ! HTTP_STATUS="$("${curl_arguments[@]}")"; then
    error "No fue posible conectarse con ${system_name}."
    return 1
  fi

  return 0
}

create_askpass_script() {
  ASKPASS_FILE="${WORK_ROOT}/git-askpass.sh"

  cat > "${ASKPASS_FILE}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

case "${1:-}" in
  *Username*|*username*)
    printf '%s\n' "${GIT_AUTH_USERNAME:?Falta GIT_AUTH_USERNAME}"
    ;;
  *Password*|*password*)
    printf '%s\n' "${GIT_AUTH_PASSWORD:?Falta GIT_AUTH_PASSWORD}"
    ;;
  *)
    exit 1
    ;;
esac
EOF

  chmod 700 "${ASKPASS_FILE}"
}

git_with_credentials() {
  local username="$1"
  local password="$2"
  shift 2

  GIT_TERMINAL_PROMPT=0 \
  GIT_ASKPASS="${ASKPASS_FILE}" \
  GIT_AUTH_USERNAME="${username}" \
  GIT_AUTH_PASSWORD="${password}" \
  "$@"
}

rewrite_gitlab_clone_url() {
  local original_url="$1"
  local url_without_scheme=""
  local repository_path=""

  if [[ -z "${GITLAB_GIT_BASE_URL}" ]]; then
    printf '%s\n' "${original_url}"
    return
  fi

  url_without_scheme="${original_url#*://}"

  if [[ "${url_without_scheme}" != */* ]]; then
    fatal "La URL GitLab no contiene un path válido: ${original_url}"
  fi

  repository_path="/${url_without_scheme#*/}"

  printf '%s%s\n' "${GITLAB_GIT_BASE_URL%/}" "${repository_path}"
}

resolve_github_environment() {
  local gitlab_scope="$1"
  local source_scope=""
  local github_environment=""
  local allowed_branches=""

  if [[ "${gitlab_scope}" == "*" ]]; then
    printf '%s|%s\n' "REPOSITORY" ""
    return 0
  fi

  if [[ "${gitlab_scope}" == *"*"* ]]; then
    return 2
  fi

  if [[ -n "${ENVIRONMENT_MAPPING_FILE}" ]]; then
    while IFS='|' read -r source_scope github_environment allowed_branches; do
      source_scope="$(printf '%s' "${source_scope}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      github_environment="$(printf '%s' "${github_environment}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      allowed_branches="$(printf '%s' "${allowed_branches}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

      [[ -z "${source_scope}" ]] && continue
      [[ "${source_scope}" == \#* ]] && continue

      if [[ "${source_scope}" == "${gitlab_scope}" ]]; then
        [[ -n "${github_environment}" ]] || return 1
        printf '%s|%s\n' "${github_environment}" "${allowed_branches}"
        return 0
      fi
    done < "${ENVIRONMENT_MAPPING_FILE}"
  fi

  if [[ "${ALLOW_DIRECT_ENVIRONMENT_SCOPE_MAPPING}" == "true" ]]; then
    printf '%s|%s\n' "${gitlab_scope}" ""
    return 0
  fi

  return 1
}

ensure_github_environment() {
  local github_repository="$1"
  local environment_name="$2"
  local environment_encoded=""

  [[ "${CREATE_GITHUB_ENVIRONMENTS}" == "true" ]] || return 0

  environment_encoded="$(url_encode "${environment_name}")"

  if ! GH_TOKEN="${TOKEN_GITHUB}" \
    gh api \
      --method PUT \
      "repos/${github_repository}/environments/${environment_encoded}" \
      >/dev/null; then
    error "No fue posible crear GitHub Environment ${environment_name}."
    return 1
  fi

  success "GitHub Environment disponible: ${environment_name}."
  return 0
}

ensure_github_environment_branch_policies() {
  local github_repository="$1"
  local environment_name="$2"
  local branch_list="$3"

  local environment_encoded=""
  local policy_url=""
  local branch_name=""
  local existing_policies=""
  local IFS=','
  local branches=()

  [[ "${CREATE_ENVIRONMENT_BRANCH_POLICIES}" == "true" ]] || return 0
  [[ -n "${branch_list}" ]] || return 0

  environment_encoded="$(url_encode "${environment_name}")"
  policy_url="repos/${github_repository}/environments/${environment_encoded}/deployment-branch-policies"

  existing_policies="$(
    GH_TOKEN="${TOKEN_GITHUB}" \
    gh api "${policy_url}" \
      --paginate \
      --jq '.branch_policies[]? | "\(.name)|\(.type)"' \
      2>/dev/null || true
  )"

  read -r -a branches <<< "${branch_list}"

  for branch_name in "${branches[@]}"; do
    branch_name="$(printf '%s' "${branch_name}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "${branch_name}" ]] && continue

    if grep -Fxq "${branch_name}|branch" <<< "${existing_policies}"; then
      continue
    fi

    if ! GH_TOKEN="${TOKEN_GITHUB}" \
      gh api \
        --method POST \
        "${policy_url}" \
        -f "name=${branch_name}" \
        -f "type=branch" \
        >/dev/null; then
      error "No fue posible crear política ${environment_name} -> ${branch_name}."
      return 1
    fi

    success "Política de Environment creada: ${environment_name} -> ${branch_name}."
  done

  return 0
}

append_project_to_file() {
  local input_file="$1"

  jq -c '
    {
      id: (.id // ""),
      name: (.name // ""),
      path: (.path // ""),
      path_with_namespace: (.path_with_namespace // ""),
      description: (.description // ""),
      default_branch: (.default_branch // ""),
      http_url_to_repo: (.http_url_to_repo // ""),
      archived: (.archived // false)
    }
  ' "${input_file}" >> "${PROJECTS_FILE}"
}

deduplicate_projects_file() {
  local output_file=""
  output_file="$(mktemp "${WORK_ROOT}/projects-deduplicated.XXXXXX.ndjson")"

  jq -sc 'unique_by(.id)[]' "${PROJECTS_FILE}" > "${output_file}"
  mv "${output_file}" "${PROJECTS_FILE}"
}

get_gitlab_projects_from_file() {
  local selector=""
  local selector_encoded=""
  local source_file=""

  [[ -f "${REPOSITORIES_FILE}" ]] ||
    fatal "No existe REPOSITORIES_FILE: ${REPOSITORIES_FILE}"

  while IFS= read -r selector || [[ -n "${selector}" ]]; do
    selector="$(printf '%s' "${selector}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    [[ -z "${selector}" || "${selector}" == \#* ]] && continue

    selector_encoded="$(url_encode "${selector}")"

    if ! request_api \
      "GitLab" \
      "GET" \
      "${GITLAB_URL}/api/v4/projects/${selector_encoded}"; then
      error "No se pudo consultar proyecto GitLab: ${selector}"
      FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
      continue
    fi

    if ! http_status_is_success "${HTTP_STATUS}"; then
      show_http_error "GitLab" "${GITLAB_URL}/api/v4/projects/${selector_encoded}"
      FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
      continue
    fi

    source_file="$(mktemp "${WORK_ROOT}/selected-project.XXXXXX.json")"
    cp "${HTTP_BODY}" "${source_file}"
    append_project_to_file "${source_file}"
    rm -f "${source_file}"
  done < "${REPOSITORIES_FILE}"
}

get_gitlab_projects_from_api() {
  local endpoint=""
  local page=1
  local next_page=""
  local page_url=""
  local page_file=""
  local group_encoded=""

  if [[ -n "${GROUP_GITLAB}" ]]; then
    group_encoded="$(url_encode "${GROUP_GITLAB}")"
    endpoint="${GITLAB_URL}/api/v4/groups/${group_encoded}/projects"
    info "Se consultarán proyectos del grupo GitLab: ${GROUP_GITLAB}"
  else
    endpoint="${GITLAB_URL}/api/v4/projects"
    warn "Se consultarán todos los proyectos visibles para TOKEN_GITLAB."
  fi

  while true; do
    page_url="${endpoint}?per_page=100&page=${page}&order_by=id&sort=asc"

    [[ -n "${GROUP_GITLAB}" ]] &&
      page_url="${page_url}&include_subgroups=true"

    if ! request_api "GitLab" "GET" "${page_url}"; then
      fatal "No se pudo consultar proyectos GitLab."
    fi

    if ! http_status_is_success "${HTTP_STATUS}"; then
      show_http_error "GitLab" "${page_url}"
      fatal "GitLab no permitió consultar proyectos."
    fi

    page_file="$(mktemp "${WORK_ROOT}/projects-page.XXXXXX.json")"
    cp "${HTTP_BODY}" "${page_file}"

    jq -c '
      .[]
      | {
          id: (.id // ""),
          name: (.name // ""),
          path: (.path // ""),
          path_with_namespace: (.path_with_namespace // ""),
          description: (.description // ""),
          default_branch: (.default_branch // ""),
          http_url_to_repo: (.http_url_to_repo // ""),
          archived: (.archived // false)
        }
    ' "${page_file}" >> "${PROJECTS_FILE}"

    rm -f "${page_file}"

    next_page="$(
      awk '
        BEGIN { IGNORECASE=1 }
        /^x-next-page:/ {
          gsub(/\r/, "", $2)
          print $2
        }
      ' "${HTTP_HEADERS}" | tail -n 1
    )"

    [[ -n "${next_page}" ]] || break
    page="${next_page}"
  done
}

get_gitlab_projects() {
  PROJECTS_FILE="$(mktemp "${WORK_ROOT}/projects.XXXXXX.ndjson")"

  if [[ -n "${REPOSITORIES_FILE}" ]]; then
    get_gitlab_projects_from_file
  else
    get_gitlab_projects_from_api
  fi

  [[ -s "${PROJECTS_FILE}" ]] || {
    warn "No se encontraron proyectos GitLab."
    exit 0
  }

  deduplicate_projects_file

  TOTAL_PROJECTS="$(wc -l < "${PROJECTS_FILE}" | tr -d ' ')"
  success "Proyectos GitLab encontrados: ${TOTAL_PROJECTS}."
}

github_repository_exists_or_create() {
  local repository_name="$1"
  local description="$2"
  local owner_encoded=""
  local repository_encoded=""
  local repository_url=""
  local payload=""
  local clone_url=""

  CURRENT_GITHUB_REPOSITORY_CREATED=false
  CURRENT_GITHUB_REPOSITORY_EXISTED=false
  CURRENT_GITHUB_CLONE_URL=""

  owner_encoded="$(url_encode "${OWNER}")"
  repository_encoded="$(url_encode "${repository_name}")"
  repository_url="${GITHUB_API_URL}/repos/${owner_encoded}/${repository_encoded}"

  if ! request_api "GitHub" "GET" "${repository_url}"; then
    return 1
  fi

  case "${HTTP_STATUS}" in
    200)
      CURRENT_GITHUB_REPOSITORY_EXISTED=true
      EXISTING_PROJECTS=$((EXISTING_PROJECTS + 1))

      if [[ "${ALLOW_MIRROR_OVERWRITE}" != "true" ]]; then
        warn "Repositorio existente omitido: ${OWNER}/${repository_name}."
        SKIPPED_PROJECTS=$((SKIPPED_PROJECTS + 1))
        return 10
      fi
      ;;
    404)
      if [[ "${DRY_RUN}" == "true" ]]; then
        CURRENT_GITHUB_REPOSITORY_CREATED=true
        CURRENT_GITHUB_CLONE_URL="https://github.com/${OWNER}/${repository_name}.git"
        return 0
      fi

      payload="$(
        jq -cn \
          --arg name "${repository_name}" \
          --arg description "${description}" \
          '{
            name: $name,
            description: $description,
            private: true,
            has_issues: true,
            has_projects: false,
            has_wiki: false,
            auto_init: false
          }'
      )"

      if ! request_api \
        "GitHub" \
        "POST" \
        "${GITHUB_API_URL}/orgs/${owner_encoded}/repos" \
        "${payload}"; then
        return 1
      fi

      if [[ "${HTTP_STATUS}" != "201" ]]; then
        show_http_error "GitHub" "${GITHUB_API_URL}/orgs/${owner_encoded}/repos"
        return 1
      fi

      CURRENT_GITHUB_REPOSITORY_CREATED=true
      CREATED_PROJECTS=$((CREATED_PROJECTS + 1))
      ;;
    *)
      show_http_error "GitHub" "${repository_url}"
      return 1
      ;;
  esac

  clone_url="$(jq -r '.clone_url // empty' "${HTTP_BODY}")"

  [[ "${clone_url}" =~ ^https://[^[:space:]]+\.git$ ]] || return 1

  CURRENT_GITHUB_CLONE_URL="${clone_url}"
  return 0
}

rollback_new_github_repository() {
  local repository_name="$1"
  local git_migration_completed="$2"
  local owner_encoded=""
  local repository_encoded=""

  [[ "${CURRENT_GITHUB_REPOSITORY_CREATED}" == "true" ]] || return 0
  [[ "${git_migration_completed}" == "false" ]] || return 0
  [[ "${DRY_RUN}" == "false" ]] || return 0

  owner_encoded="$(url_encode "${OWNER}")"
  repository_encoded="$(url_encode "${repository_name}")"

  warn "Rollback: eliminando repositorio nuevo ${OWNER}/${repository_name}."

  if ! request_api \
    "GitHub" \
    "DELETE" \
    "${GITHUB_API_URL}/repos/${owner_encoded}/${repository_encoded}"; then
    error "No se pudo ejecutar rollback de ${OWNER}/${repository_name}."
    return 1
  fi

  if [[ "${HTTP_STATUS}" != "204" ]]; then
    show_http_error \
      "GitHub" \
      "${GITHUB_API_URL}/repos/${owner_encoded}/${repository_encoded}"

    error "GitHub no confirmó el rollback de ${OWNER}/${repository_name}."
    return 1
  fi

  success "Rollback completado: ${OWNER}/${repository_name} eliminado."
  return 0
}

sync_default_branch() {
  local repository_name="$1"
  local default_branch="$2"
  local owner_encoded=""
  local repository_encoded=""
  local payload=""

  [[ "${SYNC_DEFAULT_BRANCH}" == "true" ]] || return 0
  [[ -n "${default_branch}" ]] || return 0

  owner_encoded="$(url_encode "${OWNER}")"
  repository_encoded="$(url_encode "${repository_name}")"

  payload="$(jq -cn --arg branch "${default_branch}" '{default_branch: $branch}')"

  if ! request_api \
    "GitHub" \
    "PATCH" \
    "${GITHUB_API_URL}/repos/${owner_encoded}/${repository_encoded}" \
    "${payload}"; then
    return 1
  fi

  http_status_is_success "${HTTP_STATUS}"
}

report_large_git_objects() {
  local mirror_directory="$1"
  local repository_name="$2"
  local threshold_bytes=""
  local report_file=""

  CURRENT_LARGE_FILE_OVER_GITHUB_LIMIT=false
  threshold_bytes=$((LFS_THRESHOLD_MB * 1024 * 1024))

  mkdir -p "${LFS_REPORT_DIRECTORY}"

  report_file="${LFS_REPORT_DIRECTORY}/${repository_name}-large-files.tsv"

  git -C "${mirror_directory}" rev-list --objects --all |
    git -C "${mirror_directory}" cat-file \
      --batch-check='%(objecttype) %(objectsize) %(objectname) %(rest)' |
    awk -v threshold="${threshold_bytes}" '
      $1 == "blob" && $2 >= threshold {
        printf "%.2f MB\t%s\t%s\n", $2 / 1024 / 1024, $3, $4
      }
    ' |
    sort -rn > "${report_file}"

  if [[ -s "${report_file}" ]]; then
    LFS_REPOSITORIES_DETECTED=$((LFS_REPOSITORIES_DETECTED + 1))

    warn "Se detectaron blobs mayores o iguales a ${LFS_THRESHOLD_MB} MB en ${repository_name}."
    warn "Reporte LFS: ${report_file}"

    sed -n '1,100p' "${report_file}" >&2

    if awk '$1 + 0 >= 100.00 { exit 0 } END { exit 1 }' "${report_file}"; then
      CURRENT_LARGE_FILE_OVER_GITHUB_LIMIT=true
      error "Existen blobs mayores o iguales a 100 MB. GitHub puede rechazar el push."
      return 2
    fi

    return 1
  fi

  return 0
}

prepare_lfs_migration() {
  local mirror_directory="$1"
  local repository_name="$2"

  case "${LFS_MODE}" in
    off)
      return 0
      ;;
    report)
      report_large_git_objects "${mirror_directory}" "${repository_name}" || true
      return 0
      ;;
    preserve)
      info "Descargando objetos LFS existentes desde GitLab."

      if ! git_with_credentials \
        "oauth2" \
        "${TOKEN_GITLAB}" \
        git -C "${mirror_directory}" lfs fetch --all gitlab; then
        error "No se pudieron descargar objetos LFS desde GitLab."
        return 1
      fi

      return 0
      ;;
    migrate)
      if [[ "${ALLOW_HISTORY_REWRITE}" != "true" ]]; then
        error "LFS_MODE=migrate requiere ALLOW_HISTORY_REWRITE=true."
        return 1
      fi

      if [[ "${CURRENT_GITHUB_REPOSITORY_CREATED}" != "true" ]]; then
        error "LFS_MODE=migrate solo está permitido para repositorios GitHub creados en esta ejecución."
        return 1
      fi

      report_large_git_objects "${mirror_directory}" "${repository_name}" || true

      info "Migrando patrones hacia Git LFS: ${LFS_INCLUDE_PATTERNS}"

      if ! git -C "${mirror_directory}" lfs migrate import \
        --everything \
        --include="${LFS_INCLUDE_PATTERNS}"; then
        error "Falló git lfs migrate import para ${repository_name}."
        return 1
      fi

      LFS_REPOSITORIES_MIGRATED=$((LFS_REPOSITORIES_MIGRATED + 1))
      return 0
      ;;
    *)
      error "LFS_MODE inválido: ${LFS_MODE}."
      return 1
      ;;
  esac
}

push_lfs_objects() {
  local mirror_directory="$1"

  case "${LFS_MODE}" in
    preserve|migrate)
      info "Subiendo objetos LFS hacia GitHub."

      if ! git_with_credentials \
        "x-access-token" \
        "${TOKEN_GITHUB}" \
        git -C "${mirror_directory}" lfs push --all github; then
        error "No se pudieron subir objetos LFS hacia GitHub."
        return 1
      fi
      ;;
  esac

  return 0
}

migrate_project_variables() {
  local gitlab_project_id="$1"
  local github_repository="$2"

  local page=1
  local next_page=""
  local variables_url=""
  local variables_page_file=""
  local variable_json=""
  local variables_with_error=0

  local variable_key=""
  local variable_value=""
  local variable_type=""
  local variable_masked=""
  local variable_protected=""
  local environment_scope=""
  local destination_type=""

  local environment_mapping=""
  local github_environment=""
  local environment_branch_policy=""
  local environment_resolution_code=0

  [[ "${MIGRATE_VARIABLES}" == "true" ]] || return 0

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY RUN] Se migrarían variables GitLab para ${github_repository}."
    return 0
  fi

  while true; do
    variables_url="${GITLAB_URL}/api/v4/projects/${gitlab_project_id}/variables?per_page=100&page=${page}"

    if ! request_api "GitLab" "GET" "${variables_url}"; then
      return 1
    fi

    if ! http_status_is_success "${HTTP_STATUS}"; then
      show_http_error "GitLab" "${variables_url}"
      return 1
    fi

    variables_page_file="$(mktemp "${WORK_ROOT}/variables.XXXXXX.json")"
    cp "${HTTP_BODY}" "${variables_page_file}"

    while IFS= read -r variable_json; do
      variable_key="$(jq -r '.key // empty' <<< "${variable_json}")"
      variable_value="$(jq -r '.value // empty' <<< "${variable_json}")"
      variable_type="$(jq -r '.variable_type // "env_var"' <<< "${variable_json}")"
      variable_masked="$(jq -r '.masked // false' <<< "${variable_json}")"
      variable_protected="$(jq -r '.protected // false' <<< "${variable_json}")"
      environment_scope="$(jq -r '.environment_scope // "*"' <<< "${variable_json}")"

      if [[ -z "${variable_key}" ]] ||
         ! validate_github_variable_name "${variable_key}" ||
         [[ "${variable_type}" == "file" ]] ||
         [[ -z "${variable_value}" ]]; then
        warn "Variable GitLab omitida: ${variable_key:-SIN_NOMBRE}."
        VARIABLES_SKIPPED=$((VARIABLES_SKIPPED + 1))
        continue
      fi

      github_environment="REPOSITORY"
      environment_branch_policy=""

      if [[ "${environment_scope}" != "*" ]]; then
        if [[ "${MIGRATE_ENVIRONMENT_SCOPED_VARIABLES}" != "true" ]]; then
          VARIABLES_SKIPPED=$((VARIABLES_SKIPPED + 1))
          continue
        fi

        set +e
        environment_mapping="$(resolve_github_environment "${environment_scope}")"
        environment_resolution_code=$?
        set -e

        if [[ "${environment_resolution_code}" -eq 2 ]]; then
          warn "Scope wildcard no migrado automáticamente: ${environment_scope}."
          VARIABLES_SKIPPED=$((VARIABLES_SKIPPED + 1))
          continue
        fi

        if [[ "${environment_resolution_code}" -ne 0 ]]; then
          warn "No existe mapeo para environment_scope=${environment_scope}."
          VARIABLES_SKIPPED=$((VARIABLES_SKIPPED + 1))
          continue
        fi

        github_environment="${environment_mapping%%|*}"
        environment_branch_policy="${environment_mapping#*|}"

        if ! ensure_github_environment \
          "${github_repository}" \
          "${github_environment}"; then
          variables_with_error=$((variables_with_error + 1))
          continue
        fi

        if ! ensure_github_environment_branch_policies \
          "${github_repository}" \
          "${github_environment}" \
          "${environment_branch_policy}"; then
          variables_with_error=$((variables_with_error + 1))
          continue
        fi
      fi

      destination_type="secret"

      if is_github_actions_variable "${variable_key}"; then
        destination_type="variable"
      fi

      if [[ "${destination_type}" == "secret" ]]; then
        if [[ "${github_environment}" == "REPOSITORY" ]]; then
          if ! printf '%s' "${variable_value}" |
            GH_TOKEN="${TOKEN_GITHUB}" \
            gh secret set "${variable_key}" \
              --repo "${github_repository}"; then
            variables_with_error=$((variables_with_error + 1))
            continue
          fi
        else
          if ! printf '%s' "${variable_value}" |
            GH_TOKEN="${TOKEN_GITHUB}" \
            gh secret set "${variable_key}" \
              --repo "${github_repository}" \
              --env "${github_environment}"; then
            variables_with_error=$((variables_with_error + 1))
            continue
          fi
        fi
      else
        if [[ "${github_environment}" == "REPOSITORY" ]]; then
          if ! GH_TOKEN="${TOKEN_GITHUB}" \
            gh variable set "${variable_key}" \
              --repo "${github_repository}" \
              --body "${variable_value}"; then
            variables_with_error=$((variables_with_error + 1))
            continue
          fi
        else
          if ! GH_TOKEN="${TOKEN_GITHUB}" \
            gh variable set "${variable_key}" \
              --repo "${github_repository}" \
              --env "${github_environment}" \
              --body "${variable_value}"; then
            variables_with_error=$((variables_with_error + 1))
            continue
          fi
        fi
      fi

      VARIABLES_MIGRATED=$((VARIABLES_MIGRATED + 1))

      if [[ "${variable_masked}" == "true" || "${variable_protected}" == "true" ]]; then
        info "Variable masked/protected importada: ${variable_key}."
      fi
    done < <(jq -c '.[]' "${variables_page_file}")

    rm -f "${variables_page_file}"

    next_page="$(
      awk '
        BEGIN { IGNORECASE=1 }
        /^x-next-page:/ {
          gsub(/\r/, "", $2)
          print $2
        }
      ' "${HTTP_HEADERS}" | tail -n 1
    )"

    [[ -n "${next_page}" ]] || break
    page="${next_page}"
  done

  if [[ "${variables_with_error}" -gt 0 ]]; then
    error "Variables/secrets con error en ${github_repository}: ${variables_with_error}."
    return 1
  fi

  return 0
}

migrate_branch_protections() {
  local gitlab_project_id="$1"
  local github_repository="$2"
  local endpoint=""
  local branches_file=""
  local branch_json=""
  local branch_name=""
  local branch_encoded=""
  local allow_force_push=""
  local code_owner_required=""
  local review_rules="null"
  local payload=""

  [[ "${MIGRATE_BRANCH_PROTECTIONS}" == "true" ]] || return 0
  [[ "${DRY_RUN}" == "false" ]] || return 0

  endpoint="${GITLAB_URL}/api/v4/projects/${gitlab_project_id}/protected_branches"

  if ! request_api "GitLab" "GET" "${endpoint}"; then
    return 1
  fi

  if ! http_status_is_success "${HTTP_STATUS}"; then
    show_http_error "GitLab" "${endpoint}"
    return 1
  fi

  branches_file="$(mktemp "${WORK_ROOT}/protected-branches.XXXXXX.json")"
  cp "${HTTP_BODY}" "${branches_file}"

  while IFS= read -r branch_json; do
    branch_name="$(jq -r '.name // empty' <<< "${branch_json}")"
    allow_force_push="$(jq -r '.allow_force_push // false' <<< "${branch_json}")"
    code_owner_required="$(jq -r '.code_owner_approval_required // false' <<< "${branch_json}")"

    [[ -z "${branch_name}" ]] && continue

    if [[ "${branch_name}" == *"*"* || "${branch_name}" == *"?"* || "${branch_name}" == *"["* ]]; then
      warn "Regla wildcard GitLab no migrada automáticamente: ${branch_name}."
      PROTECTIONS_SKIPPED=$((PROTECTIONS_SKIPPED + 1))
      continue
    fi

    branch_encoded="$(url_encode "${branch_name}")"

    if [[ "${code_owner_required}" == "true" ]]; then
      review_rules='{
        "dismissal_restrictions": null,
        "dismiss_stale_reviews": false,
        "require_code_owner_reviews": true,
        "required_approving_review_count": 1,
        "require_last_push_approval": false,
        "bypass_pull_request_allowances": null
      }'
    else
      review_rules="null"
    fi

    payload="$(
      jq -cn \
        --argjson allow_force_pushes "${allow_force_push}" \
        --argjson review_rules "${review_rules}" \
        '{
          required_status_checks: null,
          enforce_admins: false,
          required_pull_request_reviews: $review_rules,
          restrictions: null,
          required_linear_history: false,
          allow_force_pushes: $allow_force_pushes,
          allow_deletions: false,
          block_creations: false,
          required_conversation_resolution: false,
          lock_branch: false,
          allow_fork_syncing: false
        }'
    )"

    if ! request_api \
      "GitHub" \
      "PUT" \
      "${GITHUB_API_URL}/repos/${github_repository}/branches/${branch_encoded}/protection" \
      "${payload}"; then
      rm -f "${branches_file}"
      return 1
    fi

    if ! http_status_is_success "${HTTP_STATUS}"; then
      show_http_error \
        "GitHub" \
        "${GITHUB_API_URL}/repos/${github_repository}/branches/${branch_encoded}/protection"

      rm -f "${branches_file}"
      return 1
    fi

    PROTECTIONS_MIGRATED=$((PROTECTIONS_MIGRATED + 1))
    success "Protección de rama migrada: ${github_repository}/${branch_name}."
  done < <(jq -c '.[]' "${branches_file}")

  rm -f "${branches_file}"
  return 0
}


map_gitlab_access_to_github_permission() {
  local access_level="$1"

  case "${access_level}" in
    0|10|20)
      printf '%s\n' "pull"
      ;;
    30)
      printf '%s\n' "push"
      ;;
    40|50)
      printf '%s\n' "maintain"
      ;;
    *)
      printf '%s\n' "pull"
      ;;
  esac
}

configure_actions_importer() {
  [[ "${MIGRATE_PIPELINES}" == "true" ]] || return 0
  [[ "${CONFIGURE_ACTIONS_IMPORTER}" == "true" ]] || return 0

  if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    error "CONFIGURE_ACTIONS_IMPORTER=true requiere terminal interactiva."
    return 1
  fi

  GITHUB_ACCESS_TOKEN="${TOKEN_GITHUB}" \
  GITLAB_ACCESS_TOKEN="${TOKEN_GITLAB}" \
  GH_TOKEN="${TOKEN_GITHUB}" \
  gh actions-importer configure \
    < /dev/tty \
    > /dev/tty \
    2> /dev/tty
}

analyze_pipeline_branches() {
  local mirror_directory="$1"
  local repository_name="$2"
  local report_directory="$3"
  local branch=""
  local ci_hash=""
  local IFS=','
  local branches=()
  local hashes_file="${report_directory}/ci-branches.txt"

  mkdir -p "${report_directory}"
  : > "${hashes_file}"

  read -r -a branches <<< "${PIPELINE_BRANCHES}"

  for branch in "${branches[@]}"; do
    branch="$(printf '%s' "${branch}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "${branch}" ]] && continue

    if ! git -C "${mirror_directory}" show-ref \
      --verify \
      --quiet "refs/heads/${branch}"; then
      printf '%s\t%s\n' "${branch}" "RAMA_NO_EXISTE" >> "${hashes_file}"
      continue
    fi

    if ci_hash="$(git -C "${mirror_directory}" rev-parse "refs/heads/${branch}:.gitlab-ci.yml" 2>/dev/null)"; then
      printf '%s\t%s\n' "${branch}" "${ci_hash}" >> "${hashes_file}"
    else
      printf '%s\t%s\n' "${branch}" "SIN_GITLAB_CI" >> "${hashes_file}"
    fi
  done

  cat "${hashes_file}" >&2
}

audit_project_pipeline() {
  local gitlab_full_path="$1"
  local gitlab_project_path="$2"
  local pipeline_output_directory="$3"
  local namespace=""
  local audit_directory=""
  local importer_help=""
  local result=0

  [[ "${AUDIT_PIPELINES}" == "true" ]] || return 0

  namespace="${gitlab_full_path%/*}"
  audit_directory="${pipeline_output_directory}/audit"

  mkdir -p "${audit_directory}"

  importer_help="$(gh actions-importer audit gitlab --help 2>&1 || true)"

  local arguments=(
    audit gitlab
    --output-dir "${audit_directory}"
    --namespace "${namespace}"
    --project "${gitlab_project_path}"
  )

  if grep -q -- '--source-url' <<< "${importer_help}"; then
    arguments+=(--source-url "${GITLAB_IMPORTER_URL}")
  fi

  set +e
  GITHUB_ACCESS_TOKEN="${TOKEN_GITHUB}" \
  GITLAB_ACCESS_TOKEN="${TOKEN_GITLAB}" \
  GH_TOKEN="${TOKEN_GITHUB}" \
  gh actions-importer "${arguments[@]}"
  result=$?
  set -e

  [[ "${result}" -eq 0 ]] || return 20
  return 0
}

migrate_repository_members() {
  local gitlab_project_id="$1"
  local github_repository="$2"

  local page=1
  local next_page=""
  local endpoint=""
  local members_file=""
  local member_json=""

  local gitlab_username=""
  local gitlab_access_level=""
  local github_username=""
  local github_permission=""
  local github_user_url=""
  local github_user_status=""
  local github_invite_url=""
  local github_invite_payload=""
  local github_invite_status=""
  local github_error_detail=""

  [[ "${MIGRATE_REPOSITORY_MEMBERS}" == "true" ]] || return 0

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY RUN] Se validarían e invitarían miembros GitLab en ${github_repository}."
    return 0
  fi

  info "Migrando miembros GitLab hacia ${github_repository} usando usernames equivalentes."

  while true; do
    endpoint="${GITLAB_URL}/api/v4/projects/${gitlab_project_id}/members/all?per_page=100&page=${page}"

    if ! request_api "GitLab" "GET" "${endpoint}"; then
      error "No fue posible consultar miembros GitLab del proyecto ID ${gitlab_project_id}."
      return 1
    fi

    if ! http_status_is_success "${HTTP_STATUS}"; then
      show_http_error "GitLab" "${endpoint}"
      error "GitLab no permitió consultar miembros del proyecto ID ${gitlab_project_id}."
      return 1
    fi

    cat "${HTTP_BODY}"

    if ! jq -e 'type == "array"' "${HTTP_BODY}" >/dev/null 2>&1; then
      error "GitLab devolvió una respuesta inválida al consultar miembros."
      return 1
    fi

    # Debe obtenerse antes de hacer llamadas a GitHub, porque request_api
    # reemplaza HTTP_HEADERS en cada consulta posterior.
    next_page="$(
      awk '
        BEGIN { IGNORECASE=1 }
        /^x-next-page:/ {
          gsub(/\r/, "", $2)
          print $2
        }
      ' "${HTTP_HEADERS}" | tail -n 1
    )"

    members_file="$(mktemp "${WORK_ROOT}/gitlab-members.XXXXXX.json")"
    cp "${HTTP_BODY}" "${members_file}"

    while IFS= read -r member_json; do
      gitlab_username="$(jq -r '.username // empty' <<< "${member_json}")"
      gitlab_access_level="$(jq -r '.access_level // 0' <<< "${member_json}")"

      [[ -z "${gitlab_username}" ]] && continue

      # Se asume misma identidad GitLab/GitHub.
      github_username="${gitlab_username}"

      github_user_url="${GITHUB_API_URL}/users/$(url_encode "${github_username}")"

      echo $github_user_url
      echo $HTTP_BODY

      if ! request_api "GitHub" "GET" "${github_user_url}"; then
        register_member_conflict \
          "${github_repository}" \
          "${gitlab_username}" \
          "${gitlab_access_level}" \
          "${github_username}" \
          "ERROR_CONSULTA_GITHUB" \
          "No fue posible consultar el usuario GitHub."

        MEMBERS_SKIPPED=$((MEMBERS_SKIPPED + 1))
        continue
      fi

      github_user_status="${HTTP_STATUS}"

      if [[ "${github_user_status}" != "200" ]]; then
        github_error_detail="$(jq -r '.message // "HTTP '"${github_user_status}"'"' "${HTTP_BODY}" 2>/dev/null || true)"

        register_member_conflict \
          "${github_repository}" \
          "${gitlab_username}" \
          "${gitlab_access_level}" \
          "${github_username}" \
          "USUARIO_GITHUB_NO_EXISTE" \
          "${github_error_detail}"

        warn "No existe usuario GitHub equivalente para GitLab username=${gitlab_username}."

        MEMBERS_SKIPPED=$((MEMBERS_SKIPPED + 1))
        continue
      fi

      MEMBERS_VALIDATED=$((MEMBERS_VALIDATED + 1))

      github_permission="$(map_gitlab_access_to_github_permission "${gitlab_access_level}")"

      if [[ "${github_permission}" == "admin" &&
            "${ALLOW_GITHUB_ADMIN_PERMISSION}" != "true" ]]; then
        github_permission="maintain"
      fi

      github_invite_url="${GITHUB_API_URL}/repos/${github_repository}/collaborators/$(url_encode "${github_username}")"

      github_invite_payload="$(
        jq -cn \
          --arg permission "${github_permission}" \
          '{permission: $permission}'
      )"

      if ! request_api \
        "GitHub" \
        "PUT" \
        "${github_invite_url}" \
        "${github_invite_payload}"; then

        register_member_conflict \
          "${github_repository}" \
          "${gitlab_username}" \
          "${gitlab_access_level}" \
          "${github_username}" \
          "ERROR_INVITACION_GITHUB" \
          "No fue posible invitar o actualizar al colaborador."

        MEMBERS_SKIPPED=$((MEMBERS_SKIPPED + 1))
        continue
      fi

      github_invite_status="${HTTP_STATUS}"

      case "${github_invite_status}" in
        201)
          success "Invitación GitHub creada: ${github_username} (${github_permission})."
          MEMBERS_MIGRATED=$((MEMBERS_MIGRATED + 1))
          ;;
        204)
          success "Colaborador GitHub validado/actualizado: ${github_username} (${github_permission})."
          MEMBERS_MIGRATED=$((MEMBERS_MIGRATED + 1))
          ;;
        *)
          github_error_detail="$(jq -r '.message // "HTTP '"${github_invite_status}"'"' "${HTTP_BODY}" 2>/dev/null || true)"

          register_member_conflict \
            "${github_repository}" \
            "${gitlab_username}" \
            "${gitlab_access_level}" \
            "${github_username}" \
            "INVITACION_RECHAZADA" \
            "${github_error_detail}"

          warn "GitHub rechazó la invitación de ${github_username}. HTTP ${github_invite_status}."

          MEMBERS_SKIPPED=$((MEMBERS_SKIPPED + 1))
          ;;
      esac
    done < <(jq -c '.[]' "${members_file}")

    rm -f "${members_file}"

    [[ -n "${next_page}" ]] || break

    page="${next_page}"
  done

  if [[ "${MEMBER_CONFLICTS}" -gt 0 ]]; then
    warn "Se generaron conflictos de miembros. Revise: ${MEMBER_CONFLICTS_FILE}"
  fi

  return 0
}

migrate_project_pipeline() {
  local gitlab_full_path="$1"
  local gitlab_project_path="$2"
  local github_repository="$3"
  local mirror_directory="$4"

  local namespace=""
  local pipeline_output_directory=""
  local importer_help=""
  local result=0
  local first_branch=""

  [[ "${MIGRATE_PIPELINES}" == "true" ]] || return 0

  namespace="${gitlab_full_path%/*}"
  pipeline_output_directory="${PIPELINE_REPORT_DIRECTORY}/${gitlab_project_path}"

  mkdir -p "${pipeline_output_directory}"

  analyze_pipeline_branches \
    "${mirror_directory}" \
    "${gitlab_project_path}" \
    "${pipeline_output_directory}"

  if ! audit_project_pipeline \
    "${gitlab_full_path}" \
    "${gitlab_project_path}" \
    "${pipeline_output_directory}"; then
    error "Falló la auditoría GitLab CI/CD para ${gitlab_full_path}."
    return 20
  fi

  first_branch="${PIPELINE_BRANCHES%%,*}"

  if ! git -C "${mirror_directory}" cat-file \
    -e "refs/heads/${first_branch}:.gitlab-ci.yml" 2>/dev/null; then
    warn "No se encontró .gitlab-ci.yml en ${first_branch}; se omite conversión."
    return 0
  fi

  [[ "${DRY_RUN}" == "false" ]] || return 0

  importer_help="$(gh actions-importer "${PIPELINE_MODE}" gitlab --help 2>&1 || true)"

  local arguments=(
    "${PIPELINE_MODE}" gitlab
    --output-dir "${pipeline_output_directory}/${PIPELINE_MODE}"
    --namespace "${namespace}"
    --project "${gitlab_project_path}"
  )

  if grep -q -- '--source-url' <<< "${importer_help}"; then
    arguments+=(--source-url "${GITLAB_IMPORTER_URL}")
  fi

  if [[ "${PIPELINE_MODE}" == "migrate" ]]; then
    arguments+=(--target-url "https://github.com/${github_repository}")
  fi

  set +e
  GITHUB_ACCESS_TOKEN="${TOKEN_GITHUB}" \
  GITLAB_ACCESS_TOKEN="${TOKEN_GITLAB}" \
  GH_TOKEN="${TOKEN_GITHUB}" \
  gh actions-importer "${arguments[@]}"
  result=$?
  set -e

  if [[ "${result}" -ne 0 ]]; then
    return 21
  fi

  PIPELINES_ANALYZED=$((PIPELINES_ANALYZED + 1))

  if [[ "${PIPELINE_MODE}" == "migrate" ]]; then
    PIPELINES_MIGRATED=$((PIPELINES_MIGRATED + 1))
  fi

  return 0
}

migrate_project() {
  local project_json="$1"
  local gitlab_project_id=""
  local gitlab_name=""
  local gitlab_full_path=""
  local repository_name=""
  local description=""
  local default_branch=""
  local gitlab_clone_url=""
  local gitlab_clone_url_original=""
  local github_clone_url=""
  local repository_work_dir=""
  local mirror_directory=""
  local refs_count=""
  local github_refs_count=""
  local github_return_code=0
  local git_migration_completed=false
  local gitlab_command=()
  local push_log=""
  local push_head_refspec="refs/heads/*:refs/heads/*"
  local push_tag_refspec="refs/tags/*:refs/tags/*"

  gitlab_project_id="$(jq -r '.id // empty' <<< "${project_json}")"
  gitlab_name="$(jq -r '.name // empty' <<< "${project_json}")"
  gitlab_full_path="$(jq -r '.path_with_namespace // empty' <<< "${project_json}")"
  repository_name="$(jq -r '.path // empty' <<< "${project_json}")"
  description="$(jq -r '.description // ""' <<< "${project_json}")"
  default_branch="$(jq -r '.default_branch // empty' <<< "${project_json}")"
  gitlab_clone_url_original="$(jq -r '.http_url_to_repo // empty' <<< "${project_json}")"

  printf '\n'
  info "================================================================"
  info "Proyecto GitLab: ${gitlab_name}"
  info "Ruta GitLab: ${gitlab_full_path}"
  info "Repositorio GitHub: ${OWNER}/${repository_name}"
  info "================================================================"

  if [[ -z "${gitlab_project_id}" ||
        -z "${repository_name}" ||
        -z "${gitlab_clone_url_original}" ]]; then
    error "Datos incompletos del proyecto GitLab."
    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    return
  fi

  if [[ ! "${repository_name}" =~ ^[A-Za-z0-9._-]{1,100}$ ]]; then
    error "Nombre inválido para GitHub: ${repository_name}"
    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    return
  fi

  gitlab_clone_url="$(rewrite_gitlab_clone_url "${gitlab_clone_url_original}")"

  if github_repository_exists_or_create "${repository_name}" "${description}"; then
    github_clone_url="${CURRENT_GITHUB_CLONE_URL}"
  else
    github_return_code=$?

    [[ "${github_return_code}" -eq 10 ]] && return

    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY RUN] Se migraría ${repository_name}."
    return
  fi

  repository_work_dir="$(mktemp -d "${WORK_ROOT}/repository-${repository_name}.XXXXXX")"
  mirror_directory="${repository_work_dir}/repository.git"

  gitlab_command=(git)
  [[ -n "${GITLAB_GIT_EXTRA_HEADER}" ]] &&
    gitlab_command+=(-c "http.extraHeader=${GITLAB_GIT_EXTRA_HEADER}")

  if ! git_with_credentials \
    "oauth2" \
    "${TOKEN_GITLAB}" \
    "${gitlab_command[@]}" clone --mirror \
    "${gitlab_clone_url}" \
    "${mirror_directory}"; then

    rollback_new_github_repository "${repository_name}" "${git_migration_completed}" || true
    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    rm -rf "${repository_work_dir}"
    return
  fi

  if ! git -C "${mirror_directory}" remote rename origin gitlab; then
    rollback_new_github_repository "${repository_name}" "${git_migration_completed}" || true
    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    rm -rf "${repository_work_dir}"
    return
  fi

  if ! git -C "${mirror_directory}" remote add github "${github_clone_url}"; then
    rollback_new_github_repository "${repository_name}" "${git_migration_completed}" || true
    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    rm -rf "${repository_work_dir}"
    return
  fi

  refs_count="$(
    git -C "${mirror_directory}" for-each-ref refs/heads refs/tags |
      wc -l |
      tr -d ' '
  )"

  if [[ "${refs_count}" -eq 0 ]]; then
    warn "Repositorio vacío: ${repository_name}."

    migrate_project_variables \
      "${gitlab_project_id}" \
      "${OWNER}/${repository_name}" || true

    EMPTY_PROJECTS=$((EMPTY_PROJECTS + 1))
    rm -rf "${repository_work_dir}"
    return
  fi

  if ! prepare_lfs_migration "${mirror_directory}" "${repository_name}"; then
    rollback_new_github_repository "${repository_name}" "${git_migration_completed}" || true
    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    rm -rf "${repository_work_dir}"
    return
  fi

  if [[ "${CURRENT_LARGE_FILE_OVER_GITHUB_LIMIT}" == "true" &&
        "${LFS_MODE}" != "migrate" ]]; then
    error "Migración detenida: hay archivos de 100 MB o más y no se configuró LFS_MODE=migrate."
    rollback_new_github_repository "${repository_name}" "${git_migration_completed}" || true
    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    rm -rf "${repository_work_dir}"
    return
  fi

  if [[ "${LFS_MODE}" == "migrate" ]]; then
    push_head_refspec="+refs/heads/*:refs/heads/*"
    push_tag_refspec="+refs/tags/*:refs/tags/*"
  fi

  if ! push_lfs_objects "${mirror_directory}"; then
    rollback_new_github_repository "${repository_name}" "${git_migration_completed}" || true
    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    rm -rf "${repository_work_dir}"
    return
  fi

  push_log="${repository_work_dir}/git-push.log"

  if ! git_with_credentials \
    "x-access-token" \
    "${TOKEN_GITHUB}" \
    git -C "${mirror_directory}" push github \
      "${push_head_refspec}" \
      "${push_tag_refspec}" \
      > "${push_log}" 2>&1; then

    error "Falló el push Git para ${repository_name}."
    sed -n '1,300p' "${push_log}" >&2

    rollback_new_github_repository "${repository_name}" "${git_migration_completed}" || true
    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    rm -rf "${repository_work_dir}"
    return
  fi

  cat "${push_log}"

  if ! github_refs_count="$(
    git_with_credentials \
      "x-access-token" \
      "${TOKEN_GITHUB}" \
      git -C "${mirror_directory}" ls-remote github |
      wc -l |
      tr -d ' '
  )"; then

    rollback_new_github_repository "${repository_name}" "${git_migration_completed}" || true
    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    rm -rf "${repository_work_dir}"
    return
  fi

  git_migration_completed=true

  if ! sync_default_branch "${repository_name}" "${default_branch}"; then
    error "Git migrado, pero falló la configuración de rama predeterminada."
    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    rm -rf "${repository_work_dir}"
    return
  fi

  if ! migrate_project_variables \
    "${gitlab_project_id}" \
    "${OWNER}/${repository_name}"; then

    error "Git migrado, pero falló la migración de variables/secrets."

    if [[ "${VARIABLES_REQUIRED}" == "true" ]]; then
      FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
      rm -rf "${repository_work_dir}"
      return
    fi
  fi

  if ! migrate_branch_protections \
    "${gitlab_project_id}" \
    "${OWNER}/${repository_name}"; then

    error "Git migrado, pero falló la migración de Branch Protection Rules."

    if [[ "${BRANCH_PROTECTIONS_REQUIRED}" == "true" ]]; then
      FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
      rm -rf "${repository_work_dir}"
      return
    fi
  fi

  if ! migrate_repository_members \
    "${gitlab_project_id}" \
    "${OWNER}/${repository_name}"; then

    error "Git migrado, pero falló la migración de miembros."

    if [[ "${MEMBERS_REQUIRED}" == "true" ]]; then
      FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
      rm -rf "${repository_work_dir}"
      return
    fi
  fi

  if ! migrate_project_pipeline \
    "${gitlab_full_path}" \
    "${repository_name}" \
    "${OWNER}/${repository_name}" \
    "${mirror_directory}"; then

    error "Git migrado, pero falló auditoría/conversión del pipeline."

    if [[ "${PIPELINES_REQUIRED}" == "true" ]]; then
      FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
      rm -rf "${repository_work_dir}"
      return
    fi

    PIPELINES_WITH_WARNING=$((PIPELINES_WITH_WARNING + 1))
  fi

  success "Migración completada: ${repository_name}. Referencias GitHub: ${github_refs_count}."
  MIGRATED_PROJECTS=$((MIGRATED_PROJECTS + 1))

  rm -rf "${repository_work_dir}"
}

print_summary() {
  printf '\n'
  info "================================================================"
  info "RESUMEN DE MIGRACIÓN GITLAB -> GITHUB"
  info "================================================================"
  info "Inicio: ${START_TIME}"
  info "Fin: $(date '+%Y-%m-%d %H:%M:%S')"
  info "Proyectos encontrados: ${TOTAL_PROJECTS}"
  info "Repositorios creados: ${CREATED_PROJECTS}"
  info "Repositorios existentes: ${EXISTING_PROJECTS}"
  info "Repositorios Git migrados: ${MIGRATED_PROJECTS}"
  info "Repositorios vacíos: ${EMPTY_PROJECTS}"
  info "Repositorios omitidos: ${SKIPPED_PROJECTS}"
  info "Repositorios con error: ${FAILED_PROJECTS}"
  info "Variables/Secrets migrados: ${VARIABLES_MIGRATED}"
  info "Variables/Secrets omitidos: ${VARIABLES_SKIPPED}"
  info "Protecciones migradas: ${PROTECTIONS_MIGRATED}"
  info "Protecciones omitidas: ${PROTECTIONS_SKIPPED}"
  info "Miembros migrados/invitados: ${MEMBERS_MIGRATED}"
  info "Miembros omitidos: ${MEMBERS_SKIPPED}"
  info "Miembros GitHub validados: ${MEMBERS_VALIDATED}"
  info "Conflictos de miembros: ${MEMBER_CONFLICTS}"
  info "Archivo de conflictos de miembros: ${MEMBER_CONFLICTS_FILE}"
  info "Repositorios con blobs grandes: ${LFS_REPOSITORIES_DETECTED}"
  info "Repositorios migrados a LFS: ${LFS_REPOSITORIES_MIGRATED}"
  info "Pipelines analizados: ${PIPELINES_ANALYZED}"
  info "Pipelines migrados: ${PIPELINES_MIGRATED}"
  info "Pipelines con advertencia: ${PIPELINES_WITH_WARNING}"
  info "Log: ${LOG_FILE}"
  info "================================================================"

  if [[ "${FAILED_PROJECTS}" -gt 0 ]]; then
    error "RESULTADO FINAL: MIGRACIÓN CON ERRORES."
    return 1
  fi

  success "RESULTADO FINAL: MIGRACIÓN EXITOSA."
  return 0
}

main() {
  require_command bash
  require_command curl
  require_command jq
  require_command git
  require_command mktemp
  require_command awk
  require_command sed
  require_command sort
  require_command tee

  [[ -n "${OWNER}" ]] || fatal "Falta OWNER."
  [[ -n "${GITLAB_URL}" ]] || fatal "Falta GITLAB_URL."
  [[ -n "${TOKEN_GITLAB}" ]] || fatal "Falta TOKEN_GITLAB."
  [[ -n "${TOKEN_GITHUB}" ]] || fatal "Falta TOKEN_GITHUB."

  validate_url "GITLAB_URL" "${GITLAB_URL}"
  validate_url "GITHUB_API_URL" "${GITHUB_API_URL}"
  validate_url "GITLAB_IMPORTER_URL" "${GITLAB_IMPORTER_URL}"

  validate_boolean "PRIVATE_REPOSITORIES" "${PRIVATE_REPOSITORIES}"
  validate_boolean "ALLOW_MIRROR_OVERWRITE" "${ALLOW_MIRROR_OVERWRITE}"
  validate_boolean "DRY_RUN" "${DRY_RUN}"
  validate_boolean "SYNC_DEFAULT_BRANCH" "${SYNC_DEFAULT_BRANCH}"
  validate_boolean "GITLAB_CURL_NO_PROXY" "${GITLAB_CURL_NO_PROXY}"
  validate_boolean "MIGRATE_VARIABLES" "${MIGRATE_VARIABLES}"
  validate_boolean "VARIABLES_REQUIRED" "${VARIABLES_REQUIRED}"
  validate_boolean "MIGRATE_ENVIRONMENT_SCOPED_VARIABLES" "${MIGRATE_ENVIRONMENT_SCOPED_VARIABLES}"
  validate_boolean "CREATE_GITHUB_ENVIRONMENTS" "${CREATE_GITHUB_ENVIRONMENTS}"
  validate_boolean "CREATE_ENVIRONMENT_BRANCH_POLICIES" "${CREATE_ENVIRONMENT_BRANCH_POLICIES}"
  validate_boolean "ALLOW_DIRECT_ENVIRONMENT_SCOPE_MAPPING" "${ALLOW_DIRECT_ENVIRONMENT_SCOPE_MAPPING}"
  validate_boolean "MIGRATE_BRANCH_PROTECTIONS" "${MIGRATE_BRANCH_PROTECTIONS}"
  validate_boolean "BRANCH_PROTECTIONS_REQUIRED" "${BRANCH_PROTECTIONS_REQUIRED}"
  validate_boolean "MIGRATE_REPOSITORY_MEMBERS" "${MIGRATE_REPOSITORY_MEMBERS}"
  validate_boolean "MEMBERS_REQUIRED" "${MEMBERS_REQUIRED}"
  validate_boolean "ALLOW_GITHUB_ADMIN_PERMISSION" "${ALLOW_GITHUB_ADMIN_PERMISSION}"
  validate_boolean "ALLOW_HISTORY_REWRITE" "${ALLOW_HISTORY_REWRITE}"
  validate_boolean "MIGRATE_PIPELINES" "${MIGRATE_PIPELINES}"
  validate_boolean "PIPELINES_REQUIRED" "${PIPELINES_REQUIRED}"
  validate_boolean "CONFIGURE_ACTIONS_IMPORTER" "${CONFIGURE_ACTIONS_IMPORTER}"
  validate_boolean "AUDIT_PIPELINES" "${AUDIT_PIPELINES}"

  case "${LFS_MODE}" in
    off|report|preserve|migrate)
      ;;
    *)
      fatal "LFS_MODE debe ser off, report, preserve o migrate."
      ;;
  esac

  case "${PIPELINE_MODE}" in
    dry-run|migrate)
      ;;
    *)
      fatal "PIPELINE_MODE debe ser dry-run o migrate."
      ;;
  esac

  [[ "${PRIVATE_REPOSITORIES}" == "true" ]] ||
    fatal "Este script requiere PRIVATE_REPOSITORIES=true."

  [[ -z "${ENVIRONMENT_MAPPING_FILE}" || -f "${ENVIRONMENT_MAPPING_FILE}" ]] ||
    fatal "No existe ENVIRONMENT_MAPPING_FILE: ${ENVIRONMENT_MAPPING_FILE}"

  if [[ -n "${GITLAB_GIT_BASE_URL}" ]]; then
    validate_url "GITLAB_GIT_BASE_URL" "${GITLAB_GIT_BASE_URL}"
  fi

  if [[ "${MIGRATE_VARIABLES}" == "true" ||
        "${MIGRATE_REPOSITORY_MEMBERS}" == "true" ||
        "${MIGRATE_PIPELINES}" == "true" ]]; then
    require_command gh
  fi

  if [[ "${LFS_MODE}" == "preserve" || "${LFS_MODE}" == "migrate" ]]; then
    require_command git-lfs
  fi

  if [[ "${MIGRATE_PIPELINES}" == "true" ]]; then
    require_command docker

    if ! docker info >/dev/null 2>&1; then
      fatal "Docker no está disponible para GitHub Actions Importer."
    fi

    if ! gh actions-importer --help >/dev/null 2>&1; then
      fatal "No está instalada la extensión gh actions-importer."
    fi

    mkdir -p "${PIPELINE_REPORT_DIRECTORY}"

    export GITHUB_ACCESS_TOKEN="${TOKEN_GITHUB}"
    export GITLAB_ACCESS_TOKEN="${TOKEN_GITLAB}"
    export GH_TOKEN="${TOKEN_GITHUB}"
  fi

  GITLAB_URL="${GITLAB_URL%/}"
  GITHUB_API_URL="${GITHUB_API_URL%/}"
  GITLAB_GIT_BASE_URL="${GITLAB_GIT_BASE_URL%/}"
  GITLAB_IMPORTER_URL="${GITLAB_IMPORTER_URL%/}"

  WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gitlab-github-migration.XXXXXX")"
  create_askpass_script

  if ! configure_actions_importer; then
    fatal "No fue posible configurar GitHub Actions Importer."
  fi

  info "Inicio de migración GitLab -> GitHub."
  info "Organización GitHub: ${OWNER}"
  info "Grupo GitLab: ${GROUP_GITLAB:-No especificado}"
  info "Archivo repositorios: ${REPOSITORIES_FILE:-No especificado}"
  info "LFS_MODE: ${LFS_MODE}"
  info "Migrar variables: ${MIGRATE_VARIABLES}"
  info "Migrar protecciones: ${MIGRATE_BRANCH_PROTECTIONS}"
  info "Migrar miembros: ${MIGRATE_REPOSITORY_MEMBERS}"
  info "Migrar pipelines: ${MIGRATE_PIPELINES}"

  if ! request_api \
    "GitHub" \
    "GET" \
    "${GITHUB_API_URL}/orgs/$(url_encode "${OWNER}")"; then
    fatal "No fue posible conectar con GitHub."
  fi

  if ! http_status_is_success "${HTTP_STATUS}"; then
    show_http_error "GitHub" "${GITHUB_API_URL}/orgs/$(url_encode "${OWNER}")"
    fatal "No se pudo validar organización GitHub."
  fi

  if ! request_api "GitLab" "GET" "${GITLAB_URL}/api/v4/user"; then
    fatal "No fue posible conectar con GitLab."
  fi

  if ! http_status_is_success "${HTTP_STATUS}"; then
    show_http_error "GitLab" "${GITLAB_URL}/api/v4/user"
    fatal "No se pudo validar TOKEN_GITLAB."
  fi

  get_gitlab_projects

  while IFS= read -r project_json; do
    migrate_project "${project_json}"
  done < "${PROJECTS_FILE}"

  print_summary
}

main "$@"
