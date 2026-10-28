#!/usr/bin/env bash
#
# migrar_repositorios.sh
#
# Migración GitLab -> GitHub:
#   - Repositorios Git: ramas y tags.
#   - Selección por variable REPOSITORIES_FILE o GROUP_GITLAB.
#   - Variables y Secrets GitLab.
#   - GitHub Environments para environment_scope GitLab.
#   - Branch Protection Rules básicas.
#   - Miembros del repositorio.
#   - Análisis, preservación o migración Git LFS.
#   - Auditoría y migración de pipelines mediante GitHub Actions Importer.
#
# REPOSITORIES_FILE:
#   Variable opcional con proyectos GitLab separados por coma.
#   Tiene prioridad sobre GROUP_GITLAB.
#
# Ejemplo:
#   export REPOSITORIES_FILE="grupo/proyecto-api,grupo/proyecto-web,123"
#
# Cada elemento puede ser:
#   - path_with_namespace: grupo/subgrupo/proyecto
#   - ID numérico GitLab: 123
#
# Requisitos base:
#   bash, curl, jq, git, mktemp, awk, sed, sort, tee
#
# Requisitos opcionales:
#   gh                  Para variables, Environments y pipelines.
#   git-lfs             Para LFS_MODE=preserve o LFS_MODE=migrate.
#   gh actions-importer Para MIGRATE_PIPELINES=true.
#

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="$(basename "$0")"
readonly START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

GITLAB_URL="${GITLAB_URL:-}"
TOKEN_GITLAB="${TOKEN_GITLAB:-}"
GROUP_GITLAB="${GROUP_GITLAB:-}"

# Lista separada por coma. No es un path de archivo externo.
REPOSITORIES_FILE="${REPOSITORIES_FILE:-}"
PROJECT_SELECTION_FILE=""

OWNER="${OWNER:-}"
TOKEN_GITHUB="${TOKEN_GITHUB:-}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"

ALLOW_MIRROR_OVERWRITE="${ALLOW_MIRROR_OVERWRITE:-false}"
DRY_RUN="${DRY_RUN:-false}"
SYNC_DEFAULT_BRANCH="${SYNC_DEFAULT_BRANCH:-true}"

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

# Sufijo corporativo aplicado al username GitLab para buscar GitHub.
# Ejemplo: jperez -> jperez_bexca
GITHUB_USERNAME_SUFFIX="${GITHUB_USERNAME_SUFFIX:-_bexca}"

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

get_gitlab_next_page() {
  awk '
    BEGIN { IGNORECASE=1 }
    /^x-next-page:/ {
      gsub(/\r/, "", $2)
      print $2
    }
  ' "${HTTP_HEADERS}" | tail -n 1
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

      [[ -z "${source_scope}" || "${source_scope}" == \#* ]] && continue

      if [[ "${source_scope}" == "${gitlab_scope}" ]]; then
        [[ -n "${github_environment}" ]] || return 1
        printf '%s|%s\n' "${github_environment}" "${allowed_branches}"
        return 0
      fi
    done < "${ENVIRONMENT_MAPPING_FILE}"
  fi

  if [[ "${ALLOW_DIRECT_ENVIRONMENT_SCOPE_MAPPING}" == "true" || -z "${ENVIRONMENT_MAPPING_FILE}" ]]; then
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

build_project_selection_file() {
  local raw_item=""
  local selector=""
  local IFS=','
  local repository_list=()

  [[ -n "${REPOSITORIES_FILE}" ]] || return 1

  PROJECT_SELECTION_FILE="$(mktemp "${WORK_ROOT}/repositories-selection.XXXXXX.txt")"
  : > "${PROJECT_SELECTION_FILE}"

  read -r -a repository_list <<< "${REPOSITORIES_FILE}"

  for raw_item in "${repository_list[@]}"; do
    selector="$(printf '%s' "${raw_item}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    [[ -z "${selector}" ]] && continue

    printf '%s\n' "${selector}" >> "${PROJECT_SELECTION_FILE}"
  done

  [[ -s "${PROJECT_SELECTION_FILE}" ]] || {
    rm -f "${PROJECT_SELECTION_FILE}"
    PROJECT_SELECTION_FILE=""
    fatal "REPOSITORIES_FILE fue definida, pero no contiene repositorios válidos."
  }

  info "Selección de repositorios creada desde REPOSITORIES_FILE: ${PROJECT_SELECTION_FILE}"
  info "Repositorios solicitados: $(wc -l < "${PROJECT_SELECTION_FILE}" | tr -d ' ')"

  return 0
}

get_gitlab_projects_from_selection() {
  local selector=""
  local selector_encoded=""
  local source_file=""

  [[ -n "${PROJECT_SELECTION_FILE}" && -f "${PROJECT_SELECTION_FILE}" ]] ||
    fatal "No existe el archivo temporal de selección de repositorios."

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
  done < "${PROJECT_SELECTION_FILE}"
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

    next_page="$(get_gitlab_next_page)"
    [[ -n "${next_page}" ]] || break

    page="${next_page}"
  done
}

get_gitlab_projects() {
  PROJECTS_FILE="$(mktemp "${WORK_ROOT}/projects.XXXXXX.ndjson")"

  if [[ -n "${REPOSITORIES_FILE}" ]]; then
    build_project_selection_file
    get_gitlab_projects_from_selection
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
        "${GITHUB_API_URL}/user/repos" \
        "${payload}"; then
        return 1
      fi

      if [[ "${HTTP_STATUS}" != "201" ]]; then
        show_http_error "GitHub" "${GITHUB_API_URL}/user/repos"
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

resolve_variable_environment_scopes() {
  local variable_key="$1" source_scope="$2" variables_file="$3" environments_file="$4"
  jq -r --arg key "${variable_key}" --arg scope "${source_scope}" --slurpfile envs "${environments_file}" '
    def quote_regex:
      explode | map(. as $code | if ([46,92,43,63,94,36,124,40,41,91,93,123,125] | index($code)) != null
        then [92,$code] else [$code] end) | flatten | implode;
    def matches($pattern; $name):
      ($pattern | split("*") | map(quote_regex) | join(".*")) as $regex
      | $name | test("^" + $regex + "$");
    . as $variables
    | if any(.[]; (.key | ascii_upcase) == ($key | ascii_upcase) and .key != $key) then
        error("Claves diferentes colisionan en GitHub (case insensitive)")
      elif $scope == "*" or ($scope | contains("*") | not) then $scope
      else
        ([$envs[0][] | .name] + [.[] | (.environment_scope // "*") | select(contains("*") | not)] | unique)[]
        | . as $name | select(matches($scope; $name))
        | [$variables[] | select(.key == $key) | (.environment_scope // "*") as $candidate
            | select(matches($candidate; $name))
            | {scope:$candidate,score:(if $candidate == $name then 1000000 + ($candidate | length)
                else ($candidate | gsub("\\*"; "") | length) end)}] as $candidates
        | ($candidates | map(.score) | max) as $max
        | ($candidates | map(select(.score == $max))) as $best
        | select(($best | length) == 1 and $best[0].scope == $scope)
        | $name
      end
  ' "${variables_file}"
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
  local inventory_file="" environments_file="" scopes_file="" source_environment_scope=""

  [[ "${MIGRATE_VARIABLES}" == "true" ]] || return 0

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY RUN] Se migrarían variables GitLab para ${github_repository}."
    return 0
  fi

  inventory_file="$(mktemp "${WORK_ROOT}/variable-inventory.XXXXXX.json")"
  environments_file="$(mktemp "${WORK_ROOT}/variable-environments.XXXXXX.json")"
  scopes_file="$(mktemp "${WORK_ROOT}/variable-scopes.XXXXXX.txt")"
  printf '[]\n' > "${environments_file}"
  : > "${inventory_file}.ndjson"
  while true; do
    variables_url="${GITLAB_URL}/api/v4/projects/${gitlab_project_id}/variables?per_page=100&page=${page}"

    if ! request_api "GitLab" "GET" "${variables_url}"; then
      return 1
    fi

    if ! http_status_is_success "${HTTP_STATUS}"; then
      show_http_error "GitLab" "${variables_url}"
      return 1
    fi

    if ! jq -e 'type == "array"' "${HTTP_BODY}" >/dev/null; then
      error "GitLab devolvió una lista de variables inválida."
      return 1
    fi
    next_page="$(get_gitlab_next_page)"
    jq -c '.[]' "${HTTP_BODY}" >> "${inventory_file}.ndjson"
    [[ -n "${next_page}" ]] || break
    page="${next_page}"
  done
  jq -s '.' "${inventory_file}.ndjson" > "${inventory_file}"
  if [[ "${MIGRATE_ENVIRONMENT_SCOPED_VARIABLES}" == "true" ]] &&
     jq -e 'any(.[]; (.environment_scope // "*") as $scope | $scope != "*" and ($scope | contains("*")))' "${inventory_file}" >/dev/null; then
    if ! branch_protection_fetch_array GitLab "${GITLAB_URL}/api/v4/projects/${gitlab_project_id}/environments" "${environments_file}"; then
      printf '[]\n' > "${environments_file}"
      warn "No se pudo inventariar entornos GitLab; los comodines solo se expandirán a scopes exactos conocidos."
    fi
  fi
  while IFS= read -r variable_json; do
      variable_key="$(jq -r '.key // empty' <<< "${variable_json}")"
      variable_value="$(jq -r '.value // empty' <<< "${variable_json}")"
      variable_type="$(jq -r '.variable_type // "env_var"' <<< "${variable_json}")"
      variable_masked="$(jq -r '.masked // false' <<< "${variable_json}")"
      variable_protected="$(jq -r '.protected // false' <<< "${variable_json}")"
      environment_scope="$(jq -r '.environment_scope // "*"' <<< "${variable_json}")"
      source_environment_scope="${environment_scope}"

      if [[ -z "${variable_key}" ]] ||
         ! validate_github_variable_name "${variable_key}" ||
         [[ "${variable_type}" == "file" ]] ||
         [[ -z "${variable_value}" ]]; then
        warn "Variable GitLab omitida: ${variable_key:-SIN_NOMBRE}."
        VARIABLES_SKIPPED=$((VARIABLES_SKIPPED + 1))
        continue
      fi

      if [[ "${environment_scope}" != "*" && "${MIGRATE_ENVIRONMENT_SCOPED_VARIABLES}" != "true" ]]; then
        warn "Variable ${variable_key} omitida: migración por entorno desactivada (scope=${environment_scope})."
        VARIABLES_SKIPPED=$((VARIABLES_SKIPPED + 1))
        continue
      fi
      if ! resolve_variable_environment_scopes "${variable_key}" "${environment_scope}" "${inventory_file}" "${environments_file}" > "${scopes_file}"; then
        error "Variable ${variable_key}: no se pudieron resolver scopes sin colisiones."
        variables_with_error=$((variables_with_error + 1))
        VARIABLES_SKIPPED=$((VARIABLES_SKIPPED + 1))
        continue
      fi
      if [[ ! -s "${scopes_file}" ]]; then
        warn "Variable ${variable_key} scope=${environment_scope}: sin destinos actuales o sustituida por scopes más específicos."
        VARIABLES_SKIPPED=$((VARIABLES_SKIPPED + 1))
        continue
      fi
      if [[ "${environment_scope}" != "*" && "${environment_scope}" == *"*"* ]]; then
        warn "Variable ${variable_key}: scope ${environment_scope} expandido a entornos actuales; los futuros requieren repetir la sincronización."
      fi
      while IFS= read -r environment_scope; do
      environment_scope="${environment_scope%$'\r'}"
      github_environment="REPOSITORY"
      environment_branch_policy=""

      if [[ "${environment_scope}" != "*" ]]; then
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
          VARIABLES_SKIPPED=$((VARIABLES_SKIPPED + 1))
          continue
        fi

        if ! ensure_github_environment_branch_policies \
          "${github_repository}" \
          "${github_environment}" \
          "${environment_branch_policy}"; then
          variables_with_error=$((variables_with_error + 1))
          VARIABLES_SKIPPED=$((VARIABLES_SKIPPED + 1))
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
      success "Variable/Secret importado: ${variable_key}, destino=${github_environment}, scope origen=${source_environment_scope}."

      if [[ "${variable_masked}" == "true" || "${variable_protected}" == "true" ]]; then
        info "Variable masked/protected importada: ${variable_key}."
      fi
      done < "${scopes_file}"
  done < <(jq -c '.[]' "${inventory_file}")

  if [[ "${variables_with_error}" -gt 0 ]]; then
    error "Variables/secrets con error en ${github_repository}: ${variables_with_error}."
    return 1
  fi

  return 0
}

branch_protection_fetch_array() {
  local system_name="$1" endpoint="$2" output_file="$3"
  local page=1 count=0 separator="?" items_file=""
  [[ "${endpoint}" == *"?"* ]] && separator="&"
  items_file="$(mktemp "${WORK_ROOT}/protection-items.XXXXXX")"
  while true; do
    if ! request_api "${system_name}" GET "${endpoint}${separator}per_page=100&page=${page}" ||
       ! http_status_is_success "${HTTP_STATUS}" ||
       ! jq -e 'type == "array"' "${HTTP_BODY}" >/dev/null; then
      show_http_error "${system_name}" "${endpoint}"
      rm -f "${items_file}"
      return 1
    fi
    jq -c '.[]' "${HTTP_BODY}" >> "${items_file}"
    count="$(jq 'length' "${HTTP_BODY}")"
    [[ "${count}" -lt 100 ]] && break
    page=$((page + 1))
  done
  jq -s '.' "${items_file}" > "${output_file}"
  rm -f "${items_file}"
}

branch_protection_read_object() {
  local system_name="$1" endpoint="$2" output_file="$3"
  if ! request_api "${system_name}" GET "${endpoint}" ||
     ! http_status_is_success "${HTTP_STATUS}" ||
     ! jq -e 'type == "object"' "${HTTP_BODY}" >/dev/null; then
    show_http_error "${system_name}" "${endpoint}"
    return 1
  fi
  cp "${HTTP_BODY}" "${output_file}"
}

branch_protection_resolve_user() {
  local gitlab_user="$1" github_repository="$2" directory="$3"
  local github_id="" github_login="" gitlab_id=""
  gitlab_id="$(jq -r '.id // empty' <<< "${gitlab_user}")"
  [[ "${gitlab_id}" =~ ^[0-9]+$ ]] || return 1
  if ! branch_protection_read_object GitLab "${GITLAB_URL}/api/v4/users/${gitlab_id}" "${directory}/identity-source.json"; then
    return 1
  fi
  jq -e '.state == "active"' "${directory}/identity-source.json" >/dev/null || return 1
  github_id="$(jq -r '[.identities[]? | select(.provider == "github") | .extern_uid | tostring] | unique | if length == 1 then .[0] else empty end' "${directory}/identity-source.json")"
  if [[ "${github_id}" =~ ^[0-9]+$ ]]; then
    if ! branch_protection_read_object GitHub "${GITHUB_API_URL}/user/${github_id}" "${directory}/identity-target.json" ||
       ! jq -e --arg id "${github_id}" '(.id | tostring) == $id' "${directory}/identity-target.json" >/dev/null; then
      return 1
    fi
  else
    if ! branch_protection_read_object GitHub "${GITHUB_API_URL}/user" "${directory}/identity-target.json" ||
       ! branch_protection_fetch_array GitHub "${GITHUB_API_URL}/user/emails" "${directory}/identity-target-emails.json"; then
      warn "SKIPPED identidad GitLab ${gitlab_id}: sin vínculo GitHub comprobable; no se infiere por username/sufijo."
      return 1
    fi
    cp "${directory}/identity-source.json" "${directory}/identity-self-source.json"
    printf '[]\n' > "${directory}/identity-source-emails.json"
    if ! jq -e '.confirmed_at != null and (.email | type == "string" and length > 0)' "${directory}/identity-source.json" >/dev/null; then
      if ! branch_protection_read_object GitLab "${GITLAB_URL}/api/v4/user" "${directory}/identity-self-source.json" ||
         ! jq -e --arg id "${gitlab_id}" '(.id | tostring) == $id and .state == "active"' "${directory}/identity-self-source.json" >/dev/null ||
         ! branch_protection_fetch_array GitLab "${GITLAB_URL}/api/v4/user/emails" "${directory}/identity-source-emails.json"; then
        warn "SKIPPED identidad GitLab ${gitlab_id}: la API no expone una identidad/correo confirmado verificable."
        return 1
      fi
    fi
    if ! jq -en --slurpfile source "${directory}/identity-source-emails.json" \
      --slurpfile self "${directory}/identity-self-source.json" --slurpfile target "${directory}/identity-target-emails.json" '
      ([$source[0][] | select(.confirmed_at != null) | .email] +
        [$self[0] | select(.confirmed_at != null) | .email] | map(select(type == "string" and length > 0) | ascii_downcase)) as $emails
      | any($target[0][]; .verified == true and (.email | ascii_downcase) as $email | $emails | index($email) != null)
    ' >/dev/null; then
      warn "SKIPPED identidad GitLab ${gitlab_id}: no hay correo confirmado común; no se asume equivalencia."
      return 1
    fi
    github_id="$(jq -r '.id // empty' "${directory}/identity-target.json")"
  fi
  github_login="$(jq -r '.login // empty' "${directory}/identity-target.json")"
  [[ "${github_id}" =~ ^[0-9]+$ && "${github_login}" =~ ^[A-Za-z0-9-]+$ ]] || return 1
  if ! request_api GitHub GET "${GITHUB_API_URL}/repos/${github_repository}/collaborators/${github_login}/permission" ||
     [[ "${HTTP_STATUS}" != "200" ]] ||
     ! jq -e --arg id "${github_id}" '(.user.id | tostring) == $id and .user.permissions.push == true' "${HTTP_BODY}" >/dev/null; then
    warn "SKIPPED identidad ${github_login}: acceso de escritura no verificable; no se conceden permisos."
    return 1
  fi
  jq -cn --argjson id "${github_id}" --arg login "${github_login}" '{actor_id:$id,actor_type:"User",bypass_mode:"always",login:$login}'
}

branch_protection_resolve_actors() {
  local entries="$1" members_file="$2" directory="$3" github_repository="$4"
  local project_file="$5"
  local entry="" user_id="" group_id="" access_level="" users="[]" group_file=""
  local gitlab_user="" actor="" actors="[]"
  if ! jq -e 'type == "array"' <<< "${entries}" >/dev/null; then
    warn "SKIPPED acceso: lista de autorizaciones desconocida."
    return 1
  fi
  if jq -e 'any(.[]; .user_id != null or .group_id != null or .deploy_key_id != null or .member_role_id != null or
      (.access_level != 0 and .access_level != 60))' <<< "${entries}" >/dev/null &&
     ! jq -e 'type == "array"' "${members_file}" >/dev/null; then
    warn "SKIPPED acceso: membresías efectivas no disponibles; no se asumen actores autorizados."
    return 1
  fi
  while IFS= read -r entry; do
    if jq -e '.deploy_key_id != null or .member_role_id != null' <<< "${entry}" >/dev/null; then
      warn "SKIPPED: deploy keys/roles personalizados requieren una traducción explícita de política."
      return 1
    fi
    user_id="$(jq -r '.user_id // empty' <<< "${entry}")"
    group_id="$(jq -r '.group_id // empty' <<< "${entry}")"
    access_level="$(jq -r '.access_level // empty' <<< "${entry}")"
    if [[ -n "${user_id}" ]]; then
      if ! branch_protection_read_object GitLab "${GITLAB_URL}/api/v4/users/${user_id}" "${WORK_ROOT}/protection-user.json"; then
        return 1
      fi
      users="$(jq '[.]' "${WORK_ROOT}/protection-user.json")"
      if ! jq -e --argjson id "${user_id}" 'any(.[]; .id == $id and .state == "active" and .access_level >= 30)' "${members_file}" >/dev/null; then
        warn "SKIPPED: el usuario GitLab ${user_id} no tiene membresía activa con acceso efectivo suficiente."
        return 1
      fi
    elif [[ -n "${group_id}" ]]; then
      if ! jq -e --argjson id "${group_id}" 'any(.shared_with_groups[]?; .group_id == $id and .group_access_level >= 30)' "${project_file}" >/dev/null; then
        warn "SKIPPED: el proyecto no está compartido directamente con el grupo ${group_id} con nivel suficiente."
        return 1
      fi
      group_file="$(mktemp "${directory}/protection-group.XXXXXX")"
      if ! branch_protection_fetch_array GitLab "${GITLAB_URL}/api/v4/groups/${group_id}/members" "${group_file}"; then
        return 1
      fi
      users="$(jq --slurpfile members "${members_file}" '[.[] | . as $user | select(.state == "active" and .access_level >= 30 and
        any($members[0][]; .id == $user.id and .state == "active" and .access_level >= 30))]' "${group_file}")"
      warn "Grupo GitLab ${group_id}: se conserva una instantánea de miembros; no se crea ni amplía un equipo GitHub."
    elif [[ "${access_level}" == "0" ]]; then
      continue
    elif [[ "${access_level}" == "60" ]]; then
      group_file="$(mktemp "${directory}/protection-admins.XXXXXX")"
      if ! branch_protection_fetch_array GitLab "${GITLAB_URL}/api/v4/users?admins=true" "${group_file}" ||
         ! jq -e 'length > 0 and all(.[]; .is_admin == true)' "${group_file}" >/dev/null; then
        warn "SKIPPED rol 60: no se pudo consultar/verificar la lista de administradores GitLab; no se traduce a administradores GitHub."
        return 1
      fi
      users="$(jq '[.[] | select(.state == "active")]' "${group_file}")"
      warn "Rol GitLab 60: se comprueban administradores concretos, sin otorgar permisos administrativos GitHub."
    elif [[ "${access_level}" == "30" || "${access_level}" == "40" || "${access_level}" == "50" ]]; then
      jq -e 'type == "array"' "${members_file}" >/dev/null || return 1
      users="$(jq --argjson level "${access_level}" '[.[] | select(.access_level >= $level and .state == "active")]' "${members_file}")"
      warn "Rol GitLab ${access_level}: se resuelven miembros actuales, no un permiso de repositorio GitHub."
    else
      warn "SKIPPED: nivel de acceso desconocido o ausente: ${entry}."
      return 1
    fi
    while IFS= read -r gitlab_user; do
      if ! actor="$(branch_protection_resolve_user "${gitlab_user}" "${github_repository}" "${directory}")"; then
        return 1
      fi
      actors="$(jq -cn --argjson actors "${actors}" --argjson actor "${actor}" '$actors + [$actor | del(.login)] | unique_by(.actor_id)')"
    done < <(jq -c '.[] | select(.state == "active")' <<< "${users}")
  done < <(jq -c '.[]' <<< "${entries}")
  printf '%s\n' "${actors}"
}

branch_protection_verify_ruleset() {
  local expected="$1" actual_file="$2"
  jq -e --argjson expected "${expected}" '
    def policy: {name,target,enforcement,conditions,
      bypass_actors: ((.bypass_actors // []) | sort_by(.actor_type,.actor_id,.bypass_mode)),
      rules: ((.rules // []) | sort_by(.type))};
    has("bypass_actors") and (policy == ($expected | policy))
  ' "${actual_file}" >/dev/null
}

branch_protection_verify_codeowners() {
  local gitlab_project_id="$1" github_repository="$2" branch_name="$3"
  local directory="$4" path="" source_blob="" target_blob="" source_path="" content=""
  local owner="" actor="" user="" users_file="${directory}/codeowner-users.json"
  for path in CODEOWNERS docs/CODEOWNERS .gitlab/CODEOWNERS; do
    if ! request_api GitLab GET "${GITLAB_URL}/api/v4/projects/${gitlab_project_id}/repository/files/$(url_encode "${path}")?ref=$(url_encode "${branch_name}")"; then
      return 1
    fi
    if [[ "${HTTP_STATUS}" == "200" ]]; then
      source_blob="$(jq -r '.blob_id // empty' "${HTTP_BODY}")"
      content="$(jq -r '.content | @base64d' "${HTTP_BODY}")" || return 1
      source_path="${path}"
      break
    fi
    [[ "${HTTP_STATUS}" == "404" ]] || return 1
  done
  [[ "${source_blob}" =~ ^[0-9a-f]{40,64}$ ]] || return 1
  if ! jq -en --arg content "${content}" '
    [$content | split("\n")[] | sub("#.*$"; "") | gsub("\r"; "")
      | [splits("[ \t]+") | select(length > 0)] | select(length > 0)] as $lines
    | ($lines | length > 0) and all($lines[];
        length >= 2 and (.[0] | test("^[!\\[\\^]|\\\\") | not) and
        all(.[1:][]; test("^@[A-Za-z0-9-]+$")))
  ' >/dev/null; then
    warn "SKIPPED Code Owners: sintaxis avanzada o grupos sin equivalencia comprobable."
    return 1
  fi
  while IFS= read -r owner; do
    if ! branch_protection_fetch_array GitLab "${GITLAB_URL}/api/v4/users?username=$(url_encode "${owner}")" "${users_file}" ||
       ! jq -e --arg owner "${owner}" '[.[] | select(.username == $owner and .state == "active")] | length == 1' "${users_file}" >/dev/null; then
      return 1
    fi
    user="$(jq -c --arg owner "${owner}" '.[] | select(.username == $owner and .state == "active")' "${users_file}")"
    if ! actor="$(branch_protection_resolve_user "${user}" "${github_repository}" "${directory}")" ||
       ! jq -e --arg owner "${owner}" '(.login | ascii_downcase) == ($owner | ascii_downcase)' <<< "${actor}" >/dev/null; then
      warn "SKIPPED Code Owners: identidad ${owner} no verificable o requiere modificar CODEOWNERS."
      return 1
    fi
  done < <(jq -nr --arg content "${content}" '[$content | split("\n")[] | sub("#.*$"; "") | [splits("[ \t\r]+") | select(length > 0)] | .[1:][] | ltrimstr("@")] | unique[]')
  for path in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
    if ! request_api GitHub GET "${GITHUB_API_URL}/repos/${github_repository}/contents/${path}?ref=$(url_encode "${branch_name}")"; then
      return 1
    fi
    if [[ "${HTTP_STATUS}" == "200" ]]; then
      target_blob="$(jq -r '.sha // empty' "${HTTP_BODY}")"
      break
    fi
    [[ "${HTTP_STATUS}" == "404" ]] || return 1
  done
  if [[ "${source_blob}" != "${target_blob}" ]]; then
    warn "SKIPPED Code Owners: ${source_path} no coincide con el archivo efectivo de GitHub."
    return 1
  fi
  if ! request_api GitHub GET "${GITHUB_API_URL}/repos/${github_repository}/codeowners/errors?ref=$(url_encode "${branch_name}")" ||
     [[ "${HTTP_STATUS}" != "200" ]] || ! jq -e '.errors == []' "${HTTP_BODY}" >/dev/null; then
    return 1
  fi
}

branch_protection_discover_checks() {
  local gitlab_project_id="$1" github_repository="$2" branch_name="$3" directory="$4"
  local sha="" pipeline_id="" checks_file="${directory}/check-runs.ndjson" page=1
  if [[ "${branch_name}" == *"*"* || "${branch_name}" == *"?"* || "${branch_name}" == *"["* ]]; then
    warn "SKIPPED pipeline ${branch_name}: no se puede demostrar cobertura futura del patrón."
    return 1
  fi
  if ! branch_protection_read_object GitLab "${GITLAB_URL}/api/v4/projects/${gitlab_project_id}/repository/branches/$(url_encode "${branch_name}")" "${directory}/check-source-branch.json" ||
     ! branch_protection_read_object GitHub "${GITHUB_API_URL}/repos/${github_repository}/branches/$(url_encode "${branch_name}")" "${directory}/check-target-branch.json"; then
    return 1
  fi
  sha="$(jq -r '.commit.id // empty' "${directory}/check-source-branch.json")"
  [[ "${sha}" =~ ^[0-9a-f]{40,64}$ ]] || return 1
  jq -e --arg sha "${sha}" '.commit.sha == $sha' "${directory}/check-target-branch.json" >/dev/null || return 1
  if ! branch_protection_fetch_array GitLab "${GITLAB_URL}/api/v4/projects/${gitlab_project_id}/pipelines?ref=$(url_encode "${branch_name}")&sha=${sha}" "${directory}/check-pipelines.json"; then
    return 1
  fi
  pipeline_id="$(jq -r 'sort_by(.id) | last | select(.source == "external") | .id // empty' "${directory}/check-pipelines.json")"
  if [[ ! "${pipeline_id}" =~ ^[0-9]+$ ]]; then
    warn "SKIPPED pipeline ${branch_name}: un pipeline GitLab nativo no identifica checks GitHub equivalentes."
    return 1
  fi
  if ! branch_protection_fetch_array GitLab "${GITLAB_URL}/api/v4/projects/${gitlab_project_id}/repository/commits/${sha}/statuses?all=false" "${directory}/check-statuses.json"; then
    return 1
  fi
  : > "${checks_file}"
  while true; do
    if ! request_api GitHub GET "${GITHUB_API_URL}/repos/${github_repository}/commits/${sha}/check-runs?per_page=100&page=${page}" ||
       [[ "${HTTP_STATUS}" != "200" ]] || ! jq -e '.check_runs | type == "array"' "${HTTP_BODY}" >/dev/null; then
      return 1
    fi
    jq -c '.check_runs[]' "${HTTP_BODY}" >> "${checks_file}"
    [[ "$(jq '.check_runs | length' "${HTTP_BODY}")" -lt 100 ]] && break
    page=$((page + 1))
  done
  if ! jq -en --argjson pipeline "${pipeline_id}" --slurpfile statuses "${directory}/check-statuses.json" --slurpfile runs "${checks_file}" '
    [$statuses[0][] | select(.pipeline_id == $pipeline and .allow_failure == false)] as $required
    | ($required | length > 0) and all($required[]; . as $status |
        any($runs[]; .name == $status.name and .html_url == $status.target_url and (.app.id | type == "number")))
  ' >/dev/null; then
    warn "SKIPPED pipeline ${branch_name}: faltan vínculos exactos entre estados GitLab y checks GitHub."
    return 1
  fi
  jq -cn --argjson pipeline "${pipeline_id}" --slurpfile statuses "${directory}/check-statuses.json" --slurpfile runs "${checks_file}" '
    [$statuses[0][] | select(.pipeline_id == $pipeline and .allow_failure == false) | . as $status |
      $runs[] | select(.name == $status.name and .html_url == $status.target_url) |
      {context:.name,integration_id:.app.id}] | unique_by(.context,.integration_id)'
}

branch_protection_apply_ruleset() {
  local github_repository="$1" payload="$2" rulesets_file="$3" evidence_file="$4"
  local endpoint="${GITHUB_API_URL}/repos/${github_repository}/rulesets" ruleset_id="" name=""
  if ! jq -e 'type == "array"' "${rulesets_file}" >/dev/null; then
    branch_protection_fetch_array GitHub "${endpoint}" "${rulesets_file}" || return 1
  fi
  name="$(jq -r '.name' <<< "${payload}")"
  ruleset_id="$(jq -r --arg name "${name}" '.[] | select(.name == $name) | .id' "${rulesets_file}")"
  if [[ -n "${ruleset_id}" ]]; then
    [[ "${ruleset_id}" =~ ^[0-9]+$ ]] || return 1
    if ! branch_protection_read_object GitHub "${endpoint}/${ruleset_id}" "${WORK_ROOT}/protection-existing.json" ||
       ! branch_protection_verify_ruleset "${payload}" "${WORK_ROOT}/protection-existing.json"; then
      warn "SKIPPED: ruleset ${name} existente difiere o no es consultable; no se sobrescribe."
      return 1
    fi
  else
    jq -cn --argjson payload "${payload}" '{estado:"ATTEMPT",github:$payload}' >> "${evidence_file}"
    if ! request_api GitHub POST "${endpoint}" "${payload}" || [[ "${HTTP_STATUS}" != "201" ]]; then
      show_http_error GitHub "${endpoint}"
      return 1
    fi
    ruleset_id="$(jq -r '.id // empty' "${HTTP_BODY}")"
    [[ "${ruleset_id}" =~ ^[0-9]+$ ]] || return 1
  fi
  if ! branch_protection_read_object GitHub "${endpoint}/${ruleset_id}" "${WORK_ROOT}/protection-verified.json" ||
     ! branch_protection_verify_ruleset "${payload}" "${WORK_ROOT}/protection-verified.json"; then
    error "Validación posterior fallida: ${name}. No se cuenta como migrado."
    return 1
  fi
  jq -cn --argjson payload "${payload}" --argjson id "${ruleset_id}" '{estado:"VERIFIED",id:$id,github:$payload}' >> "${evidence_file}"
  jq --argjson policy "$(jq -c '.' "${WORK_ROOT}/protection-verified.json")" '. + [$policy] | unique_by(.id)' "${rulesets_file}" > "${rulesets_file}.next"
  mv "${rulesets_file}.next" "${rulesets_file}"
}

migrate_branch_protections() {
  local gitlab_project_id="$1"
  local github_repository="$2"
  [[ "${MIGRATE_BRANCH_PROTECTIONS}" == "true" ]] || return 0
  [[ "${DRY_RUN}" == "false" ]] || return 0
  local directory="" branch_json="" branch_name="" pattern="" reason="" failed=0
  local push_actors="[]" merge_actors="[]" access_actors="[]" payloads="" payload=""
  local approvals="[]" approval_count=0 corequired=false checks="[]" rule_key="" approvals_known=false
  local approvals_display="" force_display="" verified_for_branch=0 verified_rulesets=0
  local push_known=false merge_known=false access_known=false reviews_needed=false
  local dismiss_stale=false resolve_threads=false safety_rules="[]" review_rules="[]"
  local endpoint="${GITLAB_URL}/api/v4/projects/${gitlab_project_id}"
  local evidence_file="" resource="" output=""
  directory="$(mktemp -d "${WORK_ROOT}/protections.XXXXXX")"
  evidence_file="$(mktemp "${LOG_DIRECTORY}/branch-protections-${gitlab_project_id}.XXXXXX.ndjson")"
  info "Evidencia de protecciones: ${evidence_file}"
  if ! branch_protection_fetch_array GitLab "${endpoint}/protected_branches" "${directory}/branches.json"; then
    return 1
  fi
  if [[ "$(jq 'length' "${directory}/branches.json")" == "0" ]]; then
    info "Sin ramas protegidas en GitLab; no se modifica GitHub."
    return 0
  fi
  for resource in project settings; do
    output="${directory}/${resource}.json"
    if [[ "${resource}" == "project" ]]; then
      if branch_protection_read_object GitLab "${endpoint}" "${output}"; then continue; fi
    else
      if branch_protection_read_object GitLab "${endpoint}/approvals" "${output}"; then continue; fi
    fi
    printf '{}\n' > "${output}"
    warn "SKIPPED inventario ${resource}: se intentarán los demás componentes conocidos."
  done
  if ! branch_protection_fetch_array GitLab "${endpoint}/approval_rules" "${directory}/approvals.json"; then
    printf 'null\n' > "${directory}/approvals.json"
  fi
  if ! branch_protection_fetch_array GitLab "${endpoint}/members/all" "${directory}/members.json"; then
    printf 'null\n' > "${directory}/members.json"
  fi
  if ! branch_protection_fetch_array GitHub "${GITHUB_API_URL}/repos/${github_repository}/rulesets" "${directory}/rulesets.json"; then
    printf 'null\n' > "${directory}/rulesets.json"
  fi
  jq -cn --slurpfile project "${directory}/project.json" --slurpfile settings "${directory}/settings.json" \
    --slurpfile approvals "${directory}/approvals.json" \
    '{estado:"INVENTORY",proyecto:($project[0] | {id,shared_with_groups,only_allow_merge_if_pipeline_succeeds,
      only_allow_merge_if_all_discussions_are_resolved}),
      settings:($settings[0] | {approvals_before_merge,reset_approvals_on_push,selective_code_owner_removals,
        merge_requests_author_approval,merge_requests_disable_committers_approval,
        require_reauthentication_to_approve,require_password_to_approve}),approvals:$approvals[0]}' >> "${evidence_file}"
  while IFS= read -r branch_json; do
    branch_name="$(jq -r '.name // empty' <<< "${branch_json}")"
    reason=""
    jq -cn --argjson source "${branch_json}" '{estado:"SOURCE",gitlab:$source}' >> "${evidence_file}"
    if ! jq -e '(.id | type == "number" and . > 0 and floor == .) and (.name | type == "string" and length > 0)' <<< "${branch_json}" >/dev/null; then
      reason="identificador/nombre de regla ausente o inválido"
    fi
    pattern="refs/heads/${branch_name}"
    if [[ "${branch_name}" == *"?"* || "${branch_name}" == *"["* || "${branch_name}" == *"\\"* ]]; then
      reason="patrón no traducible con seguridad a fnmatch GitHub"
    elif [[ "${branch_name}" == *"*"* ]]; then
      if [[ "${branch_name}" != "*" && "${branch_name}" != */\* ]] || [[ "${branch_name%\*}" == *"*"* ]]; then
        reason="solo se admite * o un prefijo de directorio seguido de /*; requiere revisión de equivalencia"
      else
        pattern="refs/heads/${branch_name%\*}**/*"
      fi
    fi
    if [[ -n "${reason}" ]]; then
      warn "SKIPPED ${github_repository}/${branch_name}: ${reason}."
      jq -cn --arg branch "${branch_name}" --arg reason "${reason}" '{estado:"SKIPPED",rama:$branch,motivo:$reason}' >> "${evidence_file}"
      PROTECTIONS_SKIPPED=$((PROTECTIONS_SKIPPED + 1))
      failed=1
      continue
    fi
    safety_rules='[{"type":"deletion"}]'
    if jq -e '.allow_force_push == false' <<< "${branch_json}" >/dev/null; then
      safety_rules="$(jq -c '. + [{type:"non_fast_forward"}]' <<< "${safety_rules}")"
    elif ! jq -e '.allow_force_push == true' <<< "${branch_json}" >/dev/null; then
      reason+="force push desconocido; "
    fi
    push_known=false
    merge_known=false
    access_known=false
    push_actors="[]"
    merge_actors="[]"
    if push_actors="$(branch_protection_resolve_actors "$(jq -c '.push_access_levels' <<< "${branch_json}")" "${directory}/members.json" "${directory}" "${github_repository}" "${directory}/project.json")"; then
      push_known=true
    else
      push_actors="[]"
      reason+="actores de push no verificables automáticamente; "
    fi
    if merge_actors="$(branch_protection_resolve_actors "$(jq -c '.merge_access_levels' <<< "${branch_json}")" "${directory}/members.json" "${directory}" "${github_repository}" "${directory}/project.json")"; then
      merge_known=true
    else
      merge_actors="[]"
      reason+="actores de merge no verificables automáticamente; "
    fi
    if [[ "${push_known}" == "true" && "${merge_known}" == "true" ]]; then
      access_known=true
    fi
    access_actors="$(jq -cn --argjson push "${push_actors}" --argjson merge "${merge_actors}" '$push + ($merge | map(.bypass_mode="pull_request")) | unique_by(.actor_id) | map(. as $actor | if any($push[]; .actor_id == $actor.actor_id) then .bypass_mode="always" else . end)')"
    reviews_needed=false
    if [[ "${push_known}" == "true" && "${push_actors}" == "[]" ]]; then reviews_needed=true; fi
    approval_count=0
    approvals_known=false
    if jq -e 'type == "array"' "${directory}/approvals.json" >/dev/null; then
      approvals="$(jq -c --argjson branch "${branch_json}" '[.[] | select(
        .applies_to_all_protected_branches == true or ((.protected_branches // []) | length == 0) or
        any(.protected_branches[]?; .id == $branch.id or .name == $branch.name))]' "${directory}/approvals.json")"
      if jq -e 'all(.[]; (.approvals_required | type == "number" and . >= 0 and floor == .)) and
          all(.[]; .approvals_required == 0 or (.rule_type == "any_approver" and .contains_hidden_groups != true and
            ((.users // []) | length == 0) and ((.groups // []) | length == 0)))' <<< "${approvals}" >/dev/null; then
        approval_count="$(jq '[.[].approvals_required] | max // 0' <<< "${approvals}")"
        approvals_known=true
      else
        reason+="approvals específicos/reportes/cantidades no equivalentes; "
      fi
    else
      reason+="API approval_rules no disponible; "
    fi
    if jq -e '.approvals_before_merge | type == "number" and . >= 0 and floor == .' "${directory}/settings.json" >/dev/null; then
      approval_count="$(jq --argjson count "${approval_count}" '[.approvals_before_merge,$count] | max' "${directory}/settings.json")"
      approvals_known=true
    elif [[ "${approvals_known}" != "true" ]] &&
         jq -e '.approvals_before_merge | type == "number" and . >= 0 and floor == .' "${directory}/project.json" >/dev/null; then
      approval_count="$(jq -r '.approvals_before_merge' "${directory}/project.json")"
      approvals_known=true
      warn "${branch_name}: se recuperó la cantidad legacy de approvals desde los datos del proyecto; reglas específicas/reset siguen sin comprobarse."
    fi
    if [[ "${approval_count}" -gt 10 ]]; then
      reason+="más de 10 approvals no soportados; "
      approval_count=0
    fi
    [[ "${approval_count}" -gt 0 ]] && reviews_needed=true
    dismiss_stale=false
    if jq -e '.reset_approvals_on_push | type == "boolean"' "${directory}/settings.json" >/dev/null; then
      dismiss_stale="$(jq -r '.reset_approvals_on_push' "${directory}/settings.json")"
      [[ "${dismiss_stale}" == "true" ]] && reviews_needed=true
    else
      reason+="reset de approvals no determinado; "
    fi
    if jq -e '.merge_requests_disable_committers_approval == true or .selective_code_owner_removals == true or
        .require_reauthentication_to_approve == true or .require_password_to_approve == true' "${directory}/settings.json" >/dev/null; then
      reason+="restricciones de committers/reset selectivo/reautenticación sin equivalente 1:1; "
    fi
    resolve_threads=false
    if jq -e '.only_allow_merge_if_all_discussions_are_resolved | type == "boolean"' "${directory}/project.json" >/dev/null; then
      resolve_threads="$(jq -r '.only_allow_merge_if_all_discussions_are_resolved' "${directory}/project.json")"
      [[ "${resolve_threads}" == "true" ]] && reviews_needed=true
    else
      reason+="conversaciones no determinadas; "
    fi
    corequired=false
    if jq -e '.code_owner_approval_required == true' <<< "${branch_json}" >/dev/null; then
      if [[ "${push_known}" == "true" && "${push_actors}" == "[]" && "${branch_name}" != *"*"* ]] &&
         branch_protection_verify_codeowners "${gitlab_project_id}" "${github_repository}" "${branch_name}" "${directory}"; then
        corequired=true
        reviews_needed=true
        [[ "${approval_count}" -lt 1 ]] && approval_count=1
      else
        reason+="Code Owners no verificable/equivalente para esta rama; "
      fi
    elif ! jq -e '.code_owner_approval_required == false' <<< "${branch_json}" >/dev/null; then
      reason+="Code Owners desconocido; "
    fi
    checks="[]"
    if jq -e '.only_allow_merge_if_pipeline_succeeds == true' "${directory}/project.json" >/dev/null; then
      if ! checks="$(branch_protection_discover_checks "${gitlab_project_id}" "${github_repository}" "${branch_name}" "${directory}")"; then
        checks="[]"
        reason+="pipeline obligatorio sin vínculo verificable con checks GitHub; "
      fi
    elif ! jq -e '.only_allow_merge_if_pipeline_succeeds == false' "${directory}/project.json" >/dev/null; then
      reason+="pipeline obligatorio no determinado; "
    fi
    rule_key="gitlab-${gitlab_project_id}-$(jq -r '.id // empty' <<< "${branch_json}")"
    review_rules="$(jq -cn --argjson needed "${reviews_needed}" --argjson stale "${dismiss_stale}" \
      --argjson owner "${corequired}" --argjson count "${approval_count}" --argjson threads "${resolve_threads}" '
      if $needed then [{type:"pull_request",parameters:{dismiss_stale_reviews_on_push:$stale,
        require_code_owner_review:$owner,require_last_push_approval:false,required_approving_review_count:$count,
        required_review_thread_resolution:$threads}}] else [] end')"
    payloads="$(jq -cn --arg key "${rule_key}" --arg pattern "${pattern}" --argjson safety "${safety_rules}" \
      --argjson access "${access_actors}" --argjson push "${push_actors}" --argjson access_known "${access_known}" \
      --argjson reviews "${review_rules}" --argjson checks "${checks}" '
      def policy($suffix; $actors; $rules): {name:($key + $suffix),target:"branch",enforcement:"active",
        bypass_actors:$actors,conditions:{ref_name:{include:[$pattern],exclude:[]}},rules:$rules};
      [policy("-safety"; []; $safety),
       policy("-access"; $access; if $access_known then [{type:"creation"},{type:"update",parameters:{update_allows_fetch_and_merge:false}}] else [] end),
       policy("-reviews"; $push; $reviews),
       policy("-checks"; []; if ($checks | length) > 0 then [{type:"required_status_checks",parameters:{
         required_status_checks:$checks,strict_required_status_checks_policy:false}}] else [] end)]
      | map(select(.rules | length > 0))')"
    approvals_display="NO_DETERMINADO"
    [[ "${approvals_known}" == "true" ]] && approvals_display="${approval_count}"
    force_display="$(jq -r 'if .allow_force_push == true then "true" elif .allow_force_push == false then "false" else "NO_DETERMINADO" end' <<< "${branch_json}")"
    info "Protección ${branch_name}: force_push origen=${force_display}, approvals determinados=${approvals_display}, CodeOwners aplicado=${corequired}; rulesets aditivos."
    if jq -e '.inherited == true' <<< "${branch_json}" >/dev/null; then
      warn "${branch_name}: política heredada convertida en instantánea local; no replica gobierno de grupo."
    fi
    warn "${branch_name}: reglas existentes permanecen intactas; reglas superpuestas pueden ser más restrictivas. require_last_push_approval no se infiere de GitLab."
    verified_for_branch=0
    while IFS= read -r payload; do
      if ! branch_protection_apply_ruleset "${github_repository}" "${payload}" "${directory}/rulesets.json" "${evidence_file}"; then
        reason+="falló aplicación/verificación $(jq -r '.name' <<< "${payload}"); "
      else
        verified_for_branch=$((verified_for_branch + 1))
        verified_rulesets=$((verified_rulesets + 1))
      fi
    done < <(jq -c '.[]' <<< "${payloads}")
    if [[ -n "${reason}" ]]; then
      warn "Protección incompleta ${github_repository}/${branch_name}: ${verified_for_branch} rulesets VERIFIED; SKIPPED: ${reason}."
      jq -cn --arg branch "${branch_name}" --arg reason "${reason}" '{estado:"SKIPPED",rama:$branch,motivo:$reason}' >> "${evidence_file}"
      PROTECTIONS_SKIPPED=$((PROTECTIONS_SKIPPED + 1))
      failed=1
      continue
    fi
    PROTECTIONS_MIGRATED=$((PROTECTIONS_MIGRATED + 1))
    success "Protección de rama migrada y verificada: ${github_repository}/${branch_name}."
  done < <(jq -c '.[]' "${directory}/branches.json")
  info "Rulesets aplicados/reutilizados y verificados en ${github_repository}: ${verified_rulesets}. El contador de protecciones migradas exige la regla completa."
  return "${failed}"
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

  info "Migrando miembros GitLab hacia ${github_repository}."

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

    if ! jq -e 'type == "array"' "${HTTP_BODY}" >/dev/null 2>&1; then
      error "GitLab devolvió una respuesta inválida al consultar miembros."
      return 1
    fi

    next_page="$(get_gitlab_next_page)"

    members_file="$(mktemp "${WORK_ROOT}/gitlab-members.XXXXXX.json")"
    cp "${HTTP_BODY}" "${members_file}"

    while IFS= read -r member_json; do
      gitlab_username="$(jq -r '.username // empty' <<< "${member_json}")"
      gitlab_access_level="$(jq -r '.access_level // 0' <<< "${member_json}")"

      [[ -z "${gitlab_username}" ]] && continue

      github_username="${gitlab_username}${GITHUB_USERNAME_SUFFIX}"

      github_user_url="${GITHUB_API_URL}/users/$(url_encode "${github_username}")"

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

        warn "No existe usuario GitHub equivalente para GitLab username=${gitlab_username}; GitHub=${github_username}."

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
  first_branch="$(printf '%s' "${first_branch}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

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
  local github_clone_url=""
  local repository_work_dir=""
  local mirror_directory=""
  local refs_count=""
  local github_refs_count=""
  local github_return_code=0
  local git_migration_completed=false
  local push_log=""
  local push_head_refspec="refs/heads/*:refs/heads/*"
  local push_tag_refspec="refs/tags/*:refs/tags/*"

  gitlab_project_id="$(jq -r '.id // empty' <<< "${project_json}")"
  gitlab_name="$(jq -r '.name // empty' <<< "${project_json}")"
  gitlab_full_path="$(jq -r '.path_with_namespace // empty' <<< "${project_json}")"
  repository_name="$(jq -r '.path // empty' <<< "${project_json}")"
  description="$(jq -r '.description // ""' <<< "${project_json}")"
  default_branch="$(jq -r '.default_branch // empty' <<< "${project_json}")"
  gitlab_clone_url="$(jq -r '.http_url_to_repo // empty' <<< "${project_json}")"

  printf '\n'
  info "================================================================"
  info "Proyecto GitLab: ${gitlab_name}"
  info "Ruta GitLab: ${gitlab_full_path}"
  info "Repositorio GitHub: ${OWNER}/${repository_name}"
  info "================================================================"

  if [[ -z "${gitlab_project_id}" ||
        -z "${repository_name}" ||
        -z "${gitlab_clone_url}" ]]; then
    error "Datos incompletos del proyecto GitLab."
    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    return
  fi

  if [[ ! "${repository_name}" =~ ^[A-Za-z0-9._-]{1,100}$ ]]; then
    error "Nombre inválido para GitHub: ${repository_name}"
    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    return
  fi

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

  if ! git_with_credentials \
    "oauth2" \
    "${TOKEN_GITLAB}" \
    git clone --mirror \
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

    if ! migrate_project_variables \
      "${gitlab_project_id}" \
      "${OWNER}/${repository_name}"; then

      if [[ "${VARIABLES_REQUIRED}" == "true" ]]; then
        error "Repositorio vacío: falló la migración requerida de variables/secrets."
        FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
        rm -rf "${repository_work_dir}"
        return
      fi
    fi

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
  local github_login=""

  require_command bash
  require_command curl
  require_command jq
  require_command git
  require_command mktemp
  require_command awk
  require_command sed
  require_command sort
  require_command tee
  require_command grep

  [[ -n "${GITLAB_URL}" ]] || fatal "Falta GITLAB_URL."
  [[ -n "${TOKEN_GITLAB}" ]] || fatal "Falta TOKEN_GITLAB."
  [[ -n "${TOKEN_GITHUB}" ]] || fatal "Falta TOKEN_GITHUB."

  validate_url "GITLAB_URL" "${GITLAB_URL}"
  validate_url "GITHUB_API_URL" "${GITHUB_API_URL}"
  validate_url "GITLAB_IMPORTER_URL" "${GITLAB_IMPORTER_URL}"

  validate_boolean "ALLOW_MIRROR_OVERWRITE" "${ALLOW_MIRROR_OVERWRITE}"
  validate_boolean "DRY_RUN" "${DRY_RUN}"
  validate_boolean "SYNC_DEFAULT_BRANCH" "${SYNC_DEFAULT_BRANCH}"
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

  [[ -z "${ENVIRONMENT_MAPPING_FILE}" || -f "${ENVIRONMENT_MAPPING_FILE}" ]] ||
    fatal "No existe ENVIRONMENT_MAPPING_FILE: ${ENVIRONMENT_MAPPING_FILE}"

  if [[ "${MIGRATE_VARIABLES}" == "true" ||
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
  GITLAB_IMPORTER_URL="${GITLAB_IMPORTER_URL%/}"

  WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gitlab-github-migration.XXXXXX")"
  create_askpass_script

  if ! configure_actions_importer; then
    fatal "No fue posible configurar GitHub Actions Importer."
  fi

  info "Inicio de migración GitLab -> GitHub."
  info "Grupo GitLab: ${GROUP_GITLAB:-No especificado}"
  info "Lista repositorios: ${REPOSITORIES_FILE:-No especificada}"
  info "LFS_MODE: ${LFS_MODE}"
  info "Migrar variables: ${MIGRATE_VARIABLES}"
  info "Migrar protecciones: ${MIGRATE_BRANCH_PROTECTIONS}"
  info "Migrar miembros: ${MIGRATE_REPOSITORY_MEMBERS}"
  info "Migrar pipelines: ${MIGRATE_PIPELINES}"

  if ! request_api \
    "GitHub" \
    "GET" \
    "${GITHUB_API_URL}/user"; then
    fatal "No fue posible conectar con GitHub."
  fi

  if ! http_status_is_success "${HTTP_STATUS}"; then
    show_http_error "GitHub" "${GITHUB_API_URL}/user"
    fatal "No se pudo validar TOKEN_GITHUB."
  fi

  github_login="$(jq -r '.login // empty' "${HTTP_BODY}")"
  [[ -n "${github_login}" ]] || fatal "GitHub no devolvió el usuario asociado a TOKEN_GITHUB."

  if [[ -n "${OWNER}" && "${github_login,,}" != "${OWNER,,}" ]]; then
    warn "OWNER=${OWNER} no coincide con el token; se usará la cuenta personal ${github_login}."
  fi

  OWNER="${github_login}"
  info "Cuenta GitHub destino detectada: ${OWNER}"

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
