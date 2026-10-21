#!/usr/bin/env bash
#
# validar_integridad_migracion.sh
#
# Certifica la migración GitLab -> GitHub realizada por
# migrar_repositorios.sh.
#
# Valida:
#   - Ramas, tags, referencias, commits, objetos e integridad Git.
#   - Rama predeterminada cuando SYNC_DEFAULT_BRANCH=true.
#   - Variables y Secrets GitLab -> GitHub Actions.
#   - GitHub Environments y deployment branch policies.
#   - Branch Protection Rules básicas migradas.
#   - Miembros y permisos mínimos del repositorio.
#   - Auditorías y workflows de pipelines.
#   - Objetos Git LFS para LFS_MODE=preserve o migrate.
#
# REPOSITORIES_FILE:
#   Lista de repositorios GitLab separados por coma.
#   Tiene prioridad sobre GROUP_GITLAB.
#
# Ejemplo:
#   export REPOSITORIES_FILE="grupo/api,grupo/web,123"
#
# Nota importante sobre LFS_MODE=migrate:
#   La migración reescribe historial Git. Por ello no se pueden comparar
#   hashes de ramas, tags, commits ni objetos entre GitLab y GitHub.
#   En ese modo se valida integridad Git y disponibilidad LFS en GitHub.
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
GITHUB_USERNAME_SUFFIX="${GITHUB_USERNAME_SUFFIX:-_bexca}"

LFS_MODE="${LFS_MODE:-report}"

MIGRATE_PIPELINES="${MIGRATE_PIPELINES:-false}"
PIPELINE_MODE="${PIPELINE_MODE:-dry-run}"
PIPELINES_REQUIRED="${PIPELINES_REQUIRED:-false}"
PIPELINE_BRANCHES="${PIPELINE_BRANCHES:-master,main,dev,qa}"
AUDIT_PIPELINES="${AUDIT_PIPELINES:-true}"
PIPELINE_REPORT_DIRECTORY="${PIPELINE_REPORT_DIRECTORY:-}"

OUTPUT_DIRECTORY="${OUTPUT_DIRECTORY:-$(pwd)/certificacion-$(date +%Y%m%d-%H%M%S)}"
LOG_FILE="${OUTPUT_DIRECTORY}/certificacion.log"
JSON_REPORT_FILE="${OUTPUT_DIRECTORY}/errores-certificacion.json"

WORK_ROOT=""
PROJECTS_FILE=""
PROJECT_SELECTION_FILE=""
ASKPASS_FILE=""
HTTP_BODY=""
HTTP_HEADERS=""
HTTP_STATUS=""
EVENTS_NDJSON=""
RESULTS_NDJSON=""

CURRENT_REPOSITORY="GLOBAL"

TOTAL_PROJECTS=0
PROCESSED_PROJECTS=0
CERTIFIED_PROJECTS=0
WARNING_PROJECTS=0
FAILED_PROJECTS=0
SKIPPED_PROJECTS=0

METADATA_ERROR_COUNT=0
METADATA_WARNING_COUNT=0

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

mkdir -p "${OUTPUT_DIRECTORY}"
exec > >(tee -a "${LOG_FILE}") 2>&1

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

  command -v "${command_name}" >/dev/null 2>&1 ||
    fatal "No se encontró el comando requerido: ${command_name}."
}

validate_boolean() {
  local variable_name="$1"
  local variable_value="$2"

  case "${variable_value}" in
    true|false)
      ;;
    *)
      fatal "La variable ${variable_name} debe ser true o false. Valor recibido: ${variable_value}."
      ;;
  esac
}

validate_url() {
  local variable_name="$1"
  local variable_value="$2"

  [[ "${variable_value}" =~ ^https?://[^[:space:]/]+ ]] ||
    fatal "La variable ${variable_name} no contiene una URL HTTP/HTTPS válida."
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

github_repository_api_url() {
  local repository_name="$1"

  printf '%s/repos/%s/%s\n' \
    "${GITHUB_API_URL}" \
    "$(url_encode "${OWNER}")" \
    "$(url_encode "${repository_name}")"
}

registrar_incidencia() {
  local severity="$1"
  local repository="$2"
  local stage="$3"
  local message="$4"
  local evidence_file="${5:-}"
  local evidence=""

  if [[ -n "${evidence_file}" && -f "${evidence_file}" && -s "${evidence_file}" ]]; then
    evidence="$(sed -n '1,300p' "${evidence_file}")"
  fi

  jq -cn \
    --arg fecha "$(date '+%Y-%m-%d %H:%M:%S')" \
    --arg severidad "${severity}" \
    --arg repositorio "${repository}" \
    --arg etapa "${stage}" \
    --arg mensaje "${message}" \
    --arg evidencia "${evidence}" \
    '{
      fecha: $fecha,
      severidad: $severidad,
      repositorio: $repositorio,
      etapa: $etapa,
      mensaje: $mensaje,
      evidencia: $evidencia
    }' >> "${EVENTS_NDJSON}"
}

registrar_incidencia_metadata() {
  local required="$1"
  local stage="$2"
  local message="$3"
  local evidence_file="${4:-}"

  if [[ "${required}" == "true" ]]; then
    error "${stage}: ${message}"

    registrar_incidencia \
      "ERROR" \
      "${CURRENT_REPOSITORY}" \
      "${stage}" \
      "${message}" \
      "${evidence_file}"

    METADATA_ERROR_COUNT=$((METADATA_ERROR_COUNT + 1))
  else
    warn "${stage}: ${message}"

    registrar_incidencia \
      "ADVERTENCIA" \
      "${CURRENT_REPOSITORY}" \
      "${stage}" \
      "${message}" \
      "${evidence_file}"

    METADATA_WARNING_COUNT=$((METADATA_WARNING_COUNT + 1))
  fi
}

component_status_from_counters() {
  local errors_before="$1"
  local warnings_before="$2"

  if [[ "${METADATA_ERROR_COUNT}" -gt "${errors_before}" ]]; then
    printf '%s\n' "ERROR"
  elif [[ "${METADATA_WARNING_COUNT}" -gt "${warnings_before}" ]]; then
    printf '%s\n' "ADVERTENCIA"
  else
    printf '%s\n' "OK"
  fi
}

registrar_resultado() {
  local repository="$1"
  local status="$2"
  local branches_status="$3"
  local tags_status="$4"
  local references_status="$5"
  local commits_status="$6"
  local objects_status="$7"
  local gitlab_fsck_status="$8"
  local github_fsck_status="$9"
  local default_branch_status="${10}"
  local variables_status="${11}"
  local environments_status="${12}"
  local protections_status="${13}"
  local members_status="${14}"
  local pipelines_status="${15}"
  local lfs_status="${16}"
  local detail="${17}"

  jq -cn \
    --arg repositorio "${repository}" \
    --arg resultado "${status}" \
    --arg ramas "${branches_status}" \
    --arg tags "${tags_status}" \
    --arg referencias "${references_status}" \
    --arg commits "${commits_status}" \
    --arg objetos "${objects_status}" \
    --arg fsck_gitlab "${gitlab_fsck_status}" \
    --arg fsck_github "${github_fsck_status}" \
    --arg rama_predeterminada "${default_branch_status}" \
    --arg variables "${variables_status}" \
    --arg environments "${environments_status}" \
    --arg protecciones "${protections_status}" \
    --arg miembros "${members_status}" \
    --arg pipelines "${pipelines_status}" \
    --arg lfs "${lfs_status}" \
    --arg detalle "${detail}" \
    '{
      repositorio: $repositorio,
      resultado: $resultado,
      validaciones: {
        ramas: $ramas,
        tags: $tags,
        referencias: $referencias,
        commits: $commits,
        objetos: $objetos,
        integridad_gitlab: $fsck_gitlab,
        integridad_github: $fsck_github,
        rama_predeterminada: $rama_predeterminada
      },
      metadatos: {
        variables_y_secrets: $variables,
        environments: $environments,
        protecciones_de_rama: $protecciones,
        miembros_y_permisos: $miembros,
        pipelines: $pipelines,
        lfs: $lfs
      },
      detalle: $detalle
    }' >> "${RESULTS_NDJSON}"
}

show_http_error() {
  local system_name="$1"
  local url="$2"

  error "${system_name} respondió HTTP ${HTTP_STATUS} para: ${url}"

  [[ -s "${HTTP_BODY}" ]] || return 0

  if jq -e . >/dev/null 2>&1 < "${HTTP_BODY}"; then
    jq -r '
      if type == "object" then
        .message // .error // tojson
      elif type == "array" then
        map(.message // tojson) | join("; ")
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
        --header "User-Agent: gitlab-github-certification"
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

  if [[ "${ALLOW_DIRECT_ENVIRONMENT_SCOPE_MAPPING}" == "true" ]]; then
    printf '%s|%s\n' "${gitlab_scope}" ""
    return 0
  fi

  return 1
}

map_gitlab_access_to_github_permission() {
  local access_level="$1"

  case "${access_level}" in
    0|10|20) printf '%s\n' "pull" ;;
    30)      printf '%s\n' "push" ;;
    40|50)   printf '%s\n' "maintain" ;;
    *)       printf '%s\n' "pull" ;;
  esac
}

github_permission_rank() {
  case "$1" in
    pull|read)   printf '%s\n' 1 ;;
    triage)      printf '%s\n' 2 ;;
    push|write)  printf '%s\n' 3 ;;
    maintain)    printf '%s\n' 4 ;;
    admin)       printf '%s\n' 5 ;;
    *)           printf '%s\n' 0 ;;
  esac
}

inventory_branches() {
  local repository_directory="$1"
  local output_file="$2"

  git -C "${repository_directory}" for-each-ref \
    --format='%(refname:strip=2) %(objectname)' \
    refs/heads |
    LC_ALL=C sort > "${output_file}"
}

inventory_tags() {
  local repository_directory="$1"
  local output_file="$2"

  git -C "${repository_directory}" for-each-ref \
    --format='%(refname:strip=2) %(objectname) %(*objectname)' \
    refs/tags |
    LC_ALL=C sort > "${output_file}"
}

inventory_references() {
  local repository_directory="$1"
  local output_file="$2"

  git -C "${repository_directory}" for-each-ref \
    --format='%(refname) %(objectname) %(*objectname)' \
    refs/heads refs/tags |
    LC_ALL=C sort > "${output_file}"
}

inventory_commits() {
  local repository_directory="$1"
  local output_file="$2"

  git -C "${repository_directory}" for-each-ref \
    --format='%(objectname)' \
    refs/heads refs/tags |
    LC_ALL=C sort -u |
    git -C "${repository_directory}" rev-list --stdin |
    LC_ALL=C sort -u > "${output_file}"
}

inventory_objects() {
  local repository_directory="$1"
  local output_file="$2"

  git -C "${repository_directory}" for-each-ref \
    --format='%(objectname)' \
    refs/heads refs/tags |
    LC_ALL=C sort -u |
    git -C "${repository_directory}" rev-list --objects --stdin |
    LC_ALL=C sort > "${output_file}"
}

compare_inventory() {
  local inventory_name="$1"
  local source_file="$2"
  local destination_file="$3"
  local difference_file="$4"

  if diff -u "${source_file}" "${destination_file}" > "${difference_file}"; then
    success "${inventory_name}: OK"
    return 0
  fi

  error "${inventory_name}: ERROR"
  sed -n '1,250p' "${difference_file}" >&2

  registrar_incidencia \
    "ERROR" \
    "${CURRENT_REPOSITORY}" \
    "${inventory_name}" \
    "Se encontraron diferencias entre GitLab y GitHub." \
    "${difference_file}"

  return 1
}

run_git_fsck() {
  local system_name="$1"
  local repository_directory="$2"
  local output_file="$3"

  if git -C "${repository_directory}" fsck --full --no-reflogs > "${output_file}" 2>&1; then
    success "Integridad Git ${system_name}: OK"
    return 0
  fi

  error "Integridad Git ${system_name}: ERROR"
  sed -n '1,250p' "${output_file}" >&2

  registrar_incidencia \
    "ERROR" \
    "${CURRENT_REPOSITORY}" \
    "Integridad Git ${system_name}" \
    "git fsck detectó problemas de integridad." \
    "${output_file}"

  return 1
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

  [[ -s "${PROJECT_SELECTION_FILE}" ]] ||
    fatal "REPOSITORIES_FILE fue definida, pero no contiene repositorios válidos."

  info "Selección temporal creada: ${PROJECT_SELECTION_FILE}"
  info "Repositorios solicitados: $(wc -l < "${PROJECT_SELECTION_FILE}" | tr -d ' ')"
}

append_project_to_file() {
  local input_file="$1"

  jq -c '
    {
      id: (.id // ""),
      name: (.name // ""),
      path: (.path // ""),
      path_with_namespace: (.path_with_namespace // ""),
      default_branch: (.default_branch // ""),
      archived: (.archived // false),
      http_url_to_repo: (.http_url_to_repo // "")
    }
  ' "${input_file}" >> "${PROJECTS_FILE}"
}

deduplicate_projects_file() {
  local output_file=""

  output_file="$(mktemp "${WORK_ROOT}/projects-deduplicated.XXXXXX.ndjson")"
  jq -sc 'unique_by(.id)[]' "${PROJECTS_FILE}" > "${output_file}"
  mv "${output_file}" "${PROJECTS_FILE}"
}

fetch_gitlab_projects_from_selection() {
  local selector=""
  local selector_encoded=""
  local source_file=""

  while IFS= read -r selector || [[ -n "${selector}" ]]; do
    selector="$(printf '%s' "${selector}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "${selector}" ]] && continue

    selector_encoded="$(url_encode "${selector}")"

    if ! request_api \
      "GitLab" \
      "GET" \
      "${GITLAB_URL}/api/v4/projects/${selector_encoded}"; then
      error "No fue posible consultar proyecto GitLab: ${selector}"
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

fetch_gitlab_projects_from_api() {
  local endpoint=""
  local group_encoded=""
  local page=1
  local next_page=""
  local page_url=""

  if [[ -n "${GROUP_GITLAB}" ]]; then
    group_encoded="$(url_encode "${GROUP_GITLAB}")"
    endpoint="${GITLAB_URL}/api/v4/groups/${group_encoded}/projects"
    info "Consultando proyectos del grupo GitLab: ${GROUP_GITLAB}"
  else
    endpoint="${GITLAB_URL}/api/v4/projects"
    warn "GROUP_GITLAB no fue definido. Se validarán todos los proyectos visibles para el token."
  fi

  while true; do
    page_url="${endpoint}?per_page=100&page=${page}&order_by=id&sort=asc"

    [[ -n "${GROUP_GITLAB}" ]] &&
      page_url="${page_url}&include_subgroups=true"

    if ! request_api "GitLab" "GET" "${page_url}"; then
      fatal "No fue posible obtener la lista de proyectos GitLab."
    fi

    if ! http_status_is_success "${HTTP_STATUS}"; then
      show_http_error "GitLab" "${page_url}"
      fatal "GitLab no permitió consultar la lista de proyectos."
    fi

    if ! jq -e 'type == "array"' "${HTTP_BODY}" >/dev/null 2>&1; then
      fatal "GitLab devolvió una respuesta no válida al consultar proyectos."
    fi

    jq -c '
      .[]
      | {
          id: (.id // ""),
          name: (.name // ""),
          path: (.path // ""),
          path_with_namespace: (.path_with_namespace // ""),
          default_branch: (.default_branch // ""),
          archived: (.archived // false),
          http_url_to_repo: (.http_url_to_repo // "")
        }
    ' "${HTTP_BODY}" >> "${PROJECTS_FILE}"

    next_page="$(get_gitlab_next_page)"
    [[ -n "${next_page}" ]] || break
    page="${next_page}"
  done
}

fetch_gitlab_projects() {
  PROJECTS_FILE="$(mktemp "${WORK_ROOT}/gitlab-projects.XXXXXX.ndjson")"

  if [[ -n "${REPOSITORIES_FILE}" ]]; then
    build_project_selection_file
    fetch_gitlab_projects_from_selection
  else
    fetch_gitlab_projects_from_api
  fi

  [[ -s "${PROJECTS_FILE}" ]] || {
    warn "No se encontraron proyectos para certificar."
    exit 0
  }

  deduplicate_projects_file

  TOTAL_PROJECTS="$(wc -l < "${PROJECTS_FILE}" | tr -d ' ')"
  success "Se encontraron ${TOTAL_PROJECTS} proyecto(s) GitLab."
}

validate_github_environment() {
  local repository_name="$1"
  local environment_name="$2"
  local allowed_branches="$3"
  local evidence_file="$4"
  local environment_encoded=""
  local endpoint=""
  local branch=""
  local IFS=','
  local branches=()

  environment_encoded="$(url_encode "${environment_name}")"
  endpoint="$(github_repository_api_url "${repository_name}")/environments/${environment_encoded}"

  if ! request_api "GitHub" "GET" "${endpoint}"; then
    printf 'No fue posible consultar GitHub Environment: %s\n' "${environment_name}" >> "${evidence_file}"

    registrar_incidencia_metadata \
      "${VARIABLES_REQUIRED}" \
      "GitHub Environments" \
      "No fue posible consultar el Environment ${environment_name}." \
      "${evidence_file}"

    return 1
  fi

  if [[ "${HTTP_STATUS}" != "200" ]]; then
    printf 'Environment esperado: %s\nHTTP GitHub: %s\n' \
      "${environment_name}" \
      "${HTTP_STATUS}" >> "${evidence_file}"

    registrar_incidencia_metadata \
      "${VARIABLES_REQUIRED}" \
      "GitHub Environments" \
      "No existe el Environment esperado: ${environment_name}." \
      "${evidence_file}"

    return 1
  fi

  if [[ "${CREATE_ENVIRONMENT_BRANCH_POLICIES}" != "true" || -z "${allowed_branches}" ]]; then
    return 0
  fi

  endpoint="$(github_repository_api_url "${repository_name}")/environments/${environment_encoded}/deployment-branch-policies"

  if ! request_api "GitHub" "GET" "${endpoint}"; then
    printf 'No fue posible consultar deployment branch policies: %s\n' \
      "${environment_name}" >> "${evidence_file}"

    registrar_incidencia_metadata \
      "${VARIABLES_REQUIRED}" \
      "Políticas de Environment" \
      "No fue posible consultar políticas de ${environment_name}." \
      "${evidence_file}"

    return 1
  fi

  if ! http_status_is_success "${HTTP_STATUS}"; then
    printf 'Environment: %s\nHTTP GitHub: %s\n' \
      "${environment_name}" \
      "${HTTP_STATUS}" >> "${evidence_file}"

    registrar_incidencia_metadata \
      "${VARIABLES_REQUIRED}" \
      "Políticas de Environment" \
      "GitHub no permitió consultar las políticas de ${environment_name}." \
      "${evidence_file}"

    return 1
  fi

  read -r -a branches <<< "${allowed_branches}"

  for branch in "${branches[@]}"; do
    branch="$(printf '%s' "${branch}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "${branch}" ]] && continue

    if ! jq -e \
      --arg branch "${branch}" \
      '.branch_policies[]? | select(.name == $branch and .type == "branch")' \
      "${HTTP_BODY}" >/dev/null 2>&1; then

      printf 'Environment: %s\nPolicy esperada: %s|branch\n' \
        "${environment_name}" \
        "${branch}" >> "${evidence_file}"

      registrar_incidencia_metadata \
        "${VARIABLES_REQUIRED}" \
        "Políticas de Environment" \
        "No existe la política ${environment_name} -> ${branch}." \
        "${evidence_file}"
    fi
  done
}

validate_project_variables_and_secrets() {
  local gitlab_project_id="$1"
  local repository_name="$2"
  local work_directory="$3"

  local page=1
  local next_page=""
  local endpoint=""
  local variables_file=""
  local variable_json=""
  local variable_key=""
  local variable_value=""
  local variable_type=""
  local environment_scope=""
  local destination_type=""
  local environment_mapping=""
  local github_environment=""
  local allowed_branches=""
  local environment_resolution_code=0
  local github_endpoint=""
  local evidence_file="${work_directory}/variables-secrets-validation.tsv"
  local validated_environments_file="${work_directory}/validated-environments.txt"
  local errors_before="${METADATA_ERROR_COUNT}"
  local warnings_before="${METADATA_WARNING_COUNT}"

  : > "${evidence_file}"
  : > "${validated_environments_file}"

  while true; do
    endpoint="${GITLAB_URL}/api/v4/projects/${gitlab_project_id}/variables?per_page=100&page=${page}"

    if ! request_api "GitLab" "GET" "${endpoint}"; then
      printf 'No fue posible consultar variables GitLab. Proyecto ID: %s\n' \
        "${gitlab_project_id}" >> "${evidence_file}"

      registrar_incidencia_metadata \
        "${VARIABLES_REQUIRED}" \
        "Variables y Secrets" \
        "No fue posible consultar variables GitLab." \
        "${evidence_file}"

      break
    fi

    if ! http_status_is_success "${HTTP_STATUS}"; then
      printf 'GitLab HTTP: %s\nEndpoint: %s\n' \
        "${HTTP_STATUS}" \
        "${endpoint}" >> "${evidence_file}"

      registrar_incidencia_metadata \
        "${VARIABLES_REQUIRED}" \
        "Variables y Secrets" \
        "GitLab no permitió consultar variables del proyecto." \
        "${evidence_file}"

      break
    fi

    next_page="$(get_gitlab_next_page)"

    variables_file="$(mktemp "${WORK_ROOT}/variables-gitlab.XXXXXX.json")"
    cp "${HTTP_BODY}" "${variables_file}"

    while IFS= read -r variable_json; do
      variable_key="$(jq -r '.key // empty' <<< "${variable_json}")"
      variable_value="$(jq -r '.value // empty' <<< "${variable_json}")"
      variable_type="$(jq -r '.variable_type // "env_var"' <<< "${variable_json}")"
      environment_scope="$(jq -r '.environment_scope // "*"' <<< "${variable_json}")"

      if [[ -z "${variable_key}" ]] ||
         ! validate_github_variable_name "${variable_key}" ||
         [[ "${variable_type}" == "file" ]] ||
         [[ -z "${variable_value}" ]]; then
        continue
      fi

      github_environment="REPOSITORY"
      allowed_branches=""

      if [[ "${environment_scope}" != "*" ]]; then
        [[ "${MIGRATE_ENVIRONMENT_SCOPED_VARIABLES}" == "true" ]] || continue

        set +e
        environment_mapping="$(resolve_github_environment "${environment_scope}")"
        environment_resolution_code=$?
        set -e

        [[ "${environment_resolution_code}" -eq 0 ]] || continue

        github_environment="${environment_mapping%%|*}"
        allowed_branches="${environment_mapping#*|}"

        if ! grep -Fxq "${github_environment}" "${validated_environments_file}"; then
          printf '%s\n' "${github_environment}" >> "${validated_environments_file}"

          validate_github_environment \
            "${repository_name}" \
            "${github_environment}" \
            "${allowed_branches}" \
            "${evidence_file}" || true
        fi
      fi

      destination_type="secret"
      is_github_actions_variable "${variable_key}" && destination_type="variable"

      if [[ "${github_environment}" == "REPOSITORY" ]]; then
        if [[ "${destination_type}" == "secret" ]]; then
          github_endpoint="$(github_repository_api_url "${repository_name}")/actions/secrets/$(url_encode "${variable_key}")"
        else
          github_endpoint="$(github_repository_api_url "${repository_name}")/actions/variables/$(url_encode "${variable_key}")"
        fi
      else
        if [[ "${destination_type}" == "secret" ]]; then
          github_endpoint="$(github_repository_api_url "${repository_name}")/environments/$(url_encode "${github_environment}")/secrets/$(url_encode "${variable_key}")"
        else
          github_endpoint="$(github_repository_api_url "${repository_name}")/environments/$(url_encode "${github_environment}")/variables/$(url_encode "${variable_key}")"
        fi
      fi

      if ! request_api "GitHub" "GET" "${github_endpoint}"; then
        printf 'Variable GitLab: %s\nDestino esperado: %s %s\n' \
          "${variable_key}" \
          "${github_environment}" \
          "${destination_type}" >> "${evidence_file}"

        registrar_incidencia_metadata \
          "${VARIABLES_REQUIRED}" \
          "Variables y Secrets" \
          "No fue posible validar ${variable_key} en GitHub." \
          "${evidence_file}"

        continue
      fi

      if [[ "${HTTP_STATUS}" != "200" ]]; then
        printf 'Variable GitLab: %s\nScope GitLab: %s\nDestino esperado: %s %s\nHTTP GitHub: %s\n' \
          "${variable_key}" \
          "${environment_scope}" \
          "${github_environment}" \
          "${destination_type}" \
          "${HTTP_STATUS}" >> "${evidence_file}"

        registrar_incidencia_metadata \
          "${VARIABLES_REQUIRED}" \
          "Variables y Secrets" \
          "No existe ${destination_type} ${variable_key} en el scope esperado." \
          "${evidence_file}"
      fi
    done < <(jq -c '.[]' "${variables_file}")

    rm -f "${variables_file}"

    [[ -n "${next_page}" ]] || break
    page="${next_page}"
  done

  component_status_from_counters "${errors_before}" "${warnings_before}"
}

validate_branch_protections() {
  local gitlab_project_id="$1"
  local repository_name="$2"
  local work_directory="$3"

  local endpoint=""
  local branches_file=""
  local branch_json=""
  local branch_name=""
  local branch_encoded=""
  local allow_force_push=""
  local code_owner_required=""
  local github_allow_force_push=""
  local github_code_owner_required=""
  local github_review_count=""
  local evidence_file="${work_directory}/branch-protections-validation.tsv"
  local errors_before="${METADATA_ERROR_COUNT}"
  local warnings_before="${METADATA_WARNING_COUNT}"

  : > "${evidence_file}"

  endpoint="${GITLAB_URL}/api/v4/projects/${gitlab_project_id}/protected_branches"

  if ! request_api "GitLab" "GET" "${endpoint}"; then
    printf 'No fue posible consultar protected branches GitLab.\n' >> "${evidence_file}"

    registrar_incidencia_metadata \
      "${BRANCH_PROTECTIONS_REQUIRED}" \
      "Branch Protection Rules" \
      "No fue posible consultar protected branches en GitLab." \
      "${evidence_file}"

    component_status_from_counters "${errors_before}" "${warnings_before}"
    return
  fi

  if ! http_status_is_success "${HTTP_STATUS}"; then
    printf 'GitLab HTTP: %s\nEndpoint: %s\n' \
      "${HTTP_STATUS}" \
      "${endpoint}" >> "${evidence_file}"

    registrar_incidencia_metadata \
      "${BRANCH_PROTECTIONS_REQUIRED}" \
      "Branch Protection Rules" \
      "GitLab no permitió consultar protected branches." \
      "${evidence_file}"

    component_status_from_counters "${errors_before}" "${warnings_before}"
    return
  fi

  branches_file="$(mktemp "${WORK_ROOT}/protected-branches.XXXXXX.json")"
  cp "${HTTP_BODY}" "${branches_file}"

  while IFS= read -r branch_json; do
    branch_name="$(jq -r '.name // empty' <<< "${branch_json}")"
    allow_force_push="$(jq -r '.allow_force_push // false' <<< "${branch_json}")"
    code_owner_required="$(jq -r '.code_owner_approval_required // false' <<< "${branch_json}")"

    [[ -z "${branch_name}" ]] && continue

    if [[ "${branch_name}" == *"*"* ||
          "${branch_name}" == *"?"* ||
          "${branch_name}" == *"["* ]]; then
      printf 'Regla wildcard GitLab no migrada: %s\n' \
        "${branch_name}" >> "${evidence_file}"

      registrar_incidencia_metadata \
        "false" \
        "Branch Protection Rules" \
        "La regla wildcard ${branch_name} fue omitida por el migrador." \
        "${evidence_file}"

      continue
    fi

    branch_encoded="$(url_encode "${branch_name}")"
    endpoint="$(github_repository_api_url "${repository_name}")/branches/${branch_encoded}/protection"

    if ! request_api "GitHub" "GET" "${endpoint}"; then
      printf 'Rama: %s\nNo fue posible consultar protección GitHub.\n' \
        "${branch_name}" >> "${evidence_file}"

      registrar_incidencia_metadata \
        "${BRANCH_PROTECTIONS_REQUIRED}" \
        "Branch Protection Rules" \
        "No fue posible consultar la protección de ${branch_name}." \
        "${evidence_file}"

      continue
    fi

    if [[ "${HTTP_STATUS}" != "200" ]]; then
      printf 'Rama: %s\nHTTP GitHub: %s\n' \
        "${branch_name}" \
        "${HTTP_STATUS}" >> "${evidence_file}"

      registrar_incidencia_metadata \
        "${BRANCH_PROTECTIONS_REQUIRED}" \
        "Branch Protection Rules" \
        "No existe protección GitHub para la rama ${branch_name}." \
        "${evidence_file}"

      continue
    fi

    github_allow_force_push="$(jq -r '.allow_force_pushes.enabled // false' "${HTTP_BODY}")"
    github_code_owner_required="$(jq -r '.required_pull_request_reviews.require_code_owner_reviews // false' "${HTTP_BODY}")"
    github_review_count="$(jq -r '.required_pull_request_reviews.required_approving_review_count // 0' "${HTTP_BODY}")"

    if [[ "${github_allow_force_push}" != "${allow_force_push}" ]]; then
      printf 'Rama: %s\nallow_force_push GitLab: %s\nallow_force_pushes GitHub: %s\n' \
        "${branch_name}" \
        "${allow_force_push}" \
        "${github_allow_force_push}" >> "${evidence_file}"

      registrar_incidencia_metadata \
        "${BRANCH_PROTECTIONS_REQUIRED}" \
        "Branch Protection Rules" \
        "allow_force_push no coincide para ${branch_name}." \
        "${evidence_file}"
    fi

    if [[ "${github_code_owner_required}" != "${code_owner_required}" ]]; then
      printf 'Rama: %s\nCode Owner GitLab: %s\nCode Owner GitHub: %s\n' \
        "${branch_name}" \
        "${code_owner_required}" \
        "${github_code_owner_required}" >> "${evidence_file}"

      registrar_incidencia_metadata \
        "${BRANCH_PROTECTIONS_REQUIRED}" \
        "Branch Protection Rules" \
        "La exigencia de Code Owners no coincide para ${branch_name}." \
        "${evidence_file}"
    fi

    if [[ "${code_owner_required}" == "true" && "${github_review_count}" -lt 1 ]]; then
      printf 'Rama: %s\nAprobaciones GitHub requeridas: %s\n' \
        "${branch_name}" \
        "${github_review_count}" >> "${evidence_file}"

      registrar_incidencia_metadata \
        "${BRANCH_PROTECTIONS_REQUIRED}" \
        "Branch Protection Rules" \
        "La rama ${branch_name} requiere Code Owners, pero no tiene una aprobación mínima." \
        "${evidence_file}"
    fi
  done < <(jq -c '.[]' "${branches_file}")

  rm -f "${branches_file}"

  component_status_from_counters "${errors_before}" "${warnings_before}"
}

validate_repository_members() {
  local gitlab_project_id="$1"
  local repository_name="$2"
  local work_directory="$3"

  local page=1
  local next_page=""
  local endpoint=""
  local members_file=""
  local member_json=""
  local gitlab_username=""
  local gitlab_access_level=""
  local github_username=""
  local expected_permission=""
  local actual_permission=""
  local expected_rank=""
  local actual_rank=""
  local evidence_file="${work_directory}/members-validation.tsv"
  local errors_before="${METADATA_ERROR_COUNT}"
  local warnings_before="${METADATA_WARNING_COUNT}"

  : > "${evidence_file}"

  while true; do
    endpoint="${GITLAB_URL}/api/v4/projects/${gitlab_project_id}/members/all?per_page=100&page=${page}"

    if ! request_api "GitLab" "GET" "${endpoint}"; then
      printf 'No fue posible consultar miembros GitLab.\n' >> "${evidence_file}"

      registrar_incidencia_metadata \
        "${MEMBERS_REQUIRED}" \
        "Miembros y permisos" \
        "No fue posible consultar miembros GitLab." \
        "${evidence_file}"

      break
    fi

    if ! http_status_is_success "${HTTP_STATUS}"; then
      printf 'GitLab HTTP: %s\nEndpoint: %s\n' \
        "${HTTP_STATUS}" \
        "${endpoint}" >> "${evidence_file}"

      registrar_incidencia_metadata \
        "${MEMBERS_REQUIRED}" \
        "Miembros y permisos" \
        "GitLab no permitió consultar miembros del proyecto." \
        "${evidence_file}"

      break
    fi

    next_page="$(get_gitlab_next_page)"

    members_file="$(mktemp "${WORK_ROOT}/members-gitlab.XXXXXX.json")"
    cp "${HTTP_BODY}" "${members_file}"

    while IFS= read -r member_json; do
      gitlab_username="$(jq -r '.username // empty' <<< "${member_json}")"
      gitlab_access_level="$(jq -r '.access_level // 0' <<< "${member_json}")"

      [[ -z "${gitlab_username}" ]] && continue

      github_username="${gitlab_username}${GITHUB_USERNAME_SUFFIX}"
      expected_permission="$(map_gitlab_access_to_github_permission "${gitlab_access_level}")"

      if [[ "${expected_permission}" == "admin" &&
            "${ALLOW_GITHUB_ADMIN_PERMISSION}" != "true" ]]; then
        expected_permission="maintain"
      fi

      endpoint="$(github_repository_api_url "${repository_name}")/collaborators/$(url_encode "${github_username}")/permission"

      if ! request_api "GitHub" "GET" "${endpoint}"; then
        printf 'GitLab user: %s\nGitHub user esperado: %s\n' \
          "${gitlab_username}" \
          "${github_username}" >> "${evidence_file}"

        registrar_incidencia_metadata \
          "${MEMBERS_REQUIRED}" \
          "Miembros y permisos" \
          "No fue posible validar permisos de ${github_username}." \
          "${evidence_file}"

        continue
      fi

      if [[ "${HTTP_STATUS}" != "200" ]]; then
        printf 'GitLab user: %s\nGitHub user esperado: %s\nHTTP GitHub: %s\n' \
          "${gitlab_username}" \
          "${github_username}" \
          "${HTTP_STATUS}" >> "${evidence_file}"

        registrar_incidencia_metadata \
          "${MEMBERS_REQUIRED}" \
          "Miembros y permisos" \
          "El usuario ${github_username} no tiene acceso al repositorio GitHub." \
          "${evidence_file}"

        continue
      fi

      actual_permission="$(jq -r '.role_name // .permission // empty' "${HTTP_BODY}")"
      expected_rank="$(github_permission_rank "${expected_permission}")"
      actual_rank="$(github_permission_rank "${actual_permission}")"

      if [[ "${actual_rank}" -eq 0 ]]; then
        printf 'GitLab user: %s\nGitHub user: %s\nPermiso no reconocido: %s\n' \
          "${gitlab_username}" \
          "${github_username}" \
          "${actual_permission}" >> "${evidence_file}"

        registrar_incidencia_metadata \
          "${MEMBERS_REQUIRED}" \
          "Miembros y permisos" \
          "No se pudo interpretar el permiso GitHub de ${github_username}." \
          "${evidence_file}"

        continue
      fi

      if [[ "${actual_rank}" -lt "${expected_rank}" ]]; then
        printf 'GitLab user: %s\nGitHub user: %s\nPermiso esperado: %s\nPermiso efectivo: %s\n' \
          "${gitlab_username}" \
          "${github_username}" \
          "${expected_permission}" \
          "${actual_permission}" >> "${evidence_file}"

        registrar_incidencia_metadata \
          "${MEMBERS_REQUIRED}" \
          "Miembros y permisos" \
          "El permiso de ${github_username} es inferior al esperado." \
          "${evidence_file}"
      fi
    done < <(jq -c '.[]' "${members_file}")

    rm -f "${members_file}"

    [[ -n "${next_page}" ]] || break
    page="${next_page}"
  done

  component_status_from_counters "${errors_before}" "${warnings_before}"
}

validate_pipelines() {
  local gitlab_mirror_directory="$1"
  local repository_name="$2"
  local work_directory="$3"

  local first_branch=""
  local endpoint=""
  local workflow_count=""
  local audit_directory=""
  local evidence_file="${work_directory}/pipelines-validation.tsv"
  local errors_before="${METADATA_ERROR_COUNT}"
  local warnings_before="${METADATA_WARNING_COUNT}"

  : > "${evidence_file}"

  first_branch="${PIPELINE_BRANCHES%%,*}"
  first_branch="$(printf '%s' "${first_branch}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  if [[ "${AUDIT_PIPELINES}" == "true" ]]; then
    if [[ -z "${PIPELINE_REPORT_DIRECTORY}" ]]; then
      printf 'PIPELINE_REPORT_DIRECTORY no fue definido.\n' >> "${evidence_file}"

      registrar_incidencia_metadata \
        "${PIPELINES_REQUIRED}" \
        "Pipelines" \
        "No se puede validar auditoría de pipelines sin PIPELINE_REPORT_DIRECTORY." \
        "${evidence_file}"
    else
      audit_directory="${PIPELINE_REPORT_DIRECTORY}/${repository_name}/audit"

      if [[ ! -d "${audit_directory}" ]] ||
         ! find "${audit_directory}" -type f -print -quit | grep -q .; then
        printf 'Directorio de auditoría esperado: %s\n' \
          "${audit_directory}" >> "${evidence_file}"

        registrar_incidencia_metadata \
          "${PIPELINES_REQUIRED}" \
          "Pipelines" \
          "No existe reporte de auditoría GitHub Actions Importer." \
          "${evidence_file}"
      fi
    fi
  fi

  if [[ "${PIPELINE_MODE}" != "migrate" ]]; then
    component_status_from_counters "${errors_before}" "${warnings_before}"
    return
  fi

  if [[ -z "${first_branch}" ]] ||
     ! git -C "${gitlab_mirror_directory}" show-ref \
       --verify \
       --quiet "refs/heads/${first_branch}"; then
    printf 'Rama inicial de pipeline inexistente: %s\n' \
      "${first_branch}" >> "${evidence_file}"

    registrar_incidencia_metadata \
      "${PIPELINES_REQUIRED}" \
      "Pipelines" \
      "No existe la rama inicial configurada para validar pipelines." \
      "${evidence_file}"

    component_status_from_counters "${errors_before}" "${warnings_before}"
    return
  fi

  if ! git -C "${gitlab_mirror_directory}" cat-file \
    -e "refs/heads/${first_branch}:.gitlab-ci.yml" 2>/dev/null; then
    info "No existe .gitlab-ci.yml en ${repository_name}/${first_branch}; no se exige workflow GitHub Actions."
    component_status_from_counters "${errors_before}" "${warnings_before}"
    return
  fi

  endpoint="$(github_repository_api_url "${repository_name}")/actions/workflows?per_page=100"

  if ! request_api "GitHub" "GET" "${endpoint}"; then
    printf 'No fue posible consultar workflows GitHub Actions.\n' >> "${evidence_file}"

    registrar_incidencia_metadata \
      "${PIPELINES_REQUIRED}" \
      "Pipelines" \
      "No fue posible consultar workflows GitHub Actions." \
      "${evidence_file}"

    component_status_from_counters "${errors_before}" "${warnings_before}"
    return
  fi

  if ! http_status_is_success "${HTTP_STATUS}"; then
    printf 'GitHub HTTP: %s\nEndpoint: %s\n' \
      "${HTTP_STATUS}" \
      "${endpoint}" >> "${evidence_file}"

    registrar_incidencia_metadata \
      "${PIPELINES_REQUIRED}" \
      "Pipelines" \
      "GitHub no permitió consultar workflows." \
      "${evidence_file}"

    component_status_from_counters "${errors_before}" "${warnings_before}"
    return
  fi

  workflow_count="$(jq -r '.total_count // 0' "${HTTP_BODY}")"

  if [[ "${workflow_count}" -eq 0 ]]; then
    printf '.gitlab-ci.yml detectado en: %s\nWorkflows GitHub encontrados: %s\n' \
      "${first_branch}" \
      "${workflow_count}" >> "${evidence_file}"

    registrar_incidencia_metadata \
      "${PIPELINES_REQUIRED}" \
      "Pipelines" \
      "No se encontraron workflows GitHub Actions después de la migración." \
      "${evidence_file}"
  fi

  component_status_from_counters "${errors_before}" "${warnings_before}"
}

validate_lfs_repository() {
  local github_mirror_directory="$1"
  local work_directory="$2"
  local evidence_file="${work_directory}/github-lfs-validation.log"
  local errors_before="${METADATA_ERROR_COUNT}"
  local warnings_before="${METADATA_WARNING_COUNT}"

  if ! git_with_credentials \
    "x-access-token" \
    "${TOKEN_GITHUB}" \
    git -C "${github_mirror_directory}" lfs fetch --all origin > "${evidence_file}" 2>&1; then

    registrar_incidencia_metadata \
      "true" \
      "Git LFS" \
      "No fue posible descargar todos los objetos LFS desde GitHub." \
      "${evidence_file}"

    component_status_from_counters "${errors_before}" "${warnings_before}"
    return
  fi

  if ! git -C "${github_mirror_directory}" lfs fsck >> "${evidence_file}" 2>&1; then
    registrar_incidencia_metadata \
      "true" \
      "Git LFS" \
      "git lfs fsck detectó objetos LFS inválidos o faltantes." \
      "${evidence_file}"

    component_status_from_counters "${errors_before}" "${warnings_before}"
    return
  fi

  success "Git LFS: OK"
  component_status_from_counters "${errors_before}" "${warnings_before}"
}

certify_repository() {
  local project_json="$1"

  local gitlab_project_id=""
  local repository_name=""
  local gitlab_name=""
  local gitlab_default_branch=""
  local gitlab_clone_url=""
  local github_clone_url=""
  local github_default_branch=""
  local repository_work_directory=""
  local gitlab_mirror_directory=""
  local github_mirror_directory=""
  local refs_count=0

  local branches_status="NO_EVALUADO"
  local tags_status="NO_EVALUADO"
  local references_status="NO_EVALUADO"
  local commits_status="NO_EVALUADO"
  local objects_status="NO_EVALUADO"
  local gitlab_fsck_status="NO_EVALUADO"
  local github_fsck_status="NO_EVALUADO"
  local default_branch_status="NO_EVALUADO"
  local variables_status="NO_APLICA"
  local environments_status="NO_APLICA"
  local protections_status="NO_APLICA"
  local members_status="NO_APLICA"
  local pipelines_status="NO_APLICA"
  local lfs_status="NO_APLICA"

  local validation_failed=false
  local validation_warning=false
  local final_status=""
  local detail=""

  gitlab_project_id="$(jq -r '.id // empty' <<< "${project_json}")"
  repository_name="$(jq -r '.path // empty' <<< "${project_json}")"
  gitlab_name="$(jq -r '.name // empty' <<< "${project_json}")"
  gitlab_default_branch="$(jq -r '.default_branch // empty' <<< "${project_json}")"
  gitlab_clone_url="$(jq -r '.http_url_to_repo // empty' <<< "${project_json}")"

  CURRENT_REPOSITORY="${repository_name:-SIN_REPOSITORIO}"
  METADATA_ERROR_COUNT=0
  METADATA_WARNING_COUNT=0

  printf '\n'
  info "================================================================"
  info "Certificando repositorio: ${gitlab_name}"
  info "GitLab path: ${CURRENT_REPOSITORY}"
  info "GitHub repository: ${OWNER}/${CURRENT_REPOSITORY}"
  info "================================================================"

  if [[ -z "${gitlab_project_id}" ||
        -z "${repository_name}" ||
        -z "${gitlab_clone_url}" ]]; then
    error "El proyecto GitLab no contiene ID, path o URL de clonación válida."

    registrar_incidencia \
      "ERROR" \
      "${CURRENT_REPOSITORY}" \
      "Datos del proyecto GitLab" \
      "Falta ID, path o http_url_to_repo en la respuesta de GitLab."

    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    return
  fi

  PROCESSED_PROJECTS=$((PROCESSED_PROJECTS + 1))

  if ! request_api "GitHub" "GET" "$(github_repository_api_url "${repository_name}")"; then
    registrar_incidencia \
      "ERROR" \
      "${CURRENT_REPOSITORY}" \
      "Consulta repositorio GitHub" \
      "No fue posible conectar con GitHub para consultar el repositorio."

    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    return
  fi

  if [[ "${HTTP_STATUS}" != "200" ]]; then
    show_http_error "GitHub" "$(github_repository_api_url "${repository_name}")"

    registrar_incidencia \
      "ERROR" \
      "${CURRENT_REPOSITORY}" \
      "Consulta repositorio GitHub" \
      "El repositorio no existe en GitHub o el token no permite consultarlo." \
      "${HTTP_BODY}"

    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    return
  fi

  github_clone_url="$(jq -r '.clone_url // empty' "${HTTP_BODY}")"
  github_default_branch="$(jq -r '.default_branch // empty' "${HTTP_BODY}")"

  if [[ ! "${github_clone_url}" =~ ^https://[^[:space:]]+\.git$ ]]; then
    error "GitHub devolvió una URL clone inválida: ${github_clone_url}"
    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    return
  fi

  repository_work_directory="$(mktemp -d "${WORK_ROOT}/${repository_name}.XXXXXX")"
  gitlab_mirror_directory="${repository_work_directory}/gitlab.git"
  github_mirror_directory="${repository_work_directory}/github.git"

  info "Clonando GitLab como espejo."

  if ! git_with_credentials \
    "oauth2" \
    "${TOKEN_GITLAB}" \
    git clone --mirror \
    "${gitlab_clone_url}" \
    "${gitlab_mirror_directory}" \
    > "${repository_work_directory}/clone-gitlab.log" 2>&1; then

    registrar_incidencia \
      "ERROR" \
      "${CURRENT_REPOSITORY}" \
      "Clone GitLab" \
      "No fue posible clonar el repositorio GitLab como espejo." \
      "${repository_work_directory}/clone-gitlab.log"

    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    rm -rf "${repository_work_directory}"
    return
  fi

  info "Clonando GitHub como espejo."

  if ! git_with_credentials \
    "x-access-token" \
    "${TOKEN_GITHUB}" \
    git clone --mirror \
    "${github_clone_url}" \
    "${github_mirror_directory}" \
    > "${repository_work_directory}/clone-github.log" 2>&1; then

    registrar_incidencia \
      "ERROR" \
      "${CURRENT_REPOSITORY}" \
      "Clone GitHub" \
      "No fue posible clonar el repositorio GitHub como espejo." \
      "${repository_work_directory}/clone-github.log"

    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    rm -rf "${repository_work_directory}"
    return
  fi

  if run_git_fsck \
    "GitLab" \
    "${gitlab_mirror_directory}" \
    "${repository_work_directory}/gitlab-fsck.log"; then
    gitlab_fsck_status="OK"
  else
    gitlab_fsck_status="ERROR"
    validation_failed=true
  fi

  if run_git_fsck \
    "GitHub" \
    "${github_mirror_directory}" \
    "${repository_work_directory}/github-fsck.log"; then
    github_fsck_status="OK"
  else
    github_fsck_status="ERROR"
    validation_failed=true
  fi

  if [[ "${LFS_MODE}" == "migrate" ]]; then
    branches_status="NO_COMPARABLE_REESCRITURA_LFS"
    tags_status="NO_COMPARABLE_REESCRITURA_LFS"
    references_status="NO_COMPARABLE_REESCRITURA_LFS"
    commits_status="NO_COMPARABLE_REESCRITURA_LFS"
    objects_status="NO_COMPARABLE_REESCRITURA_LFS"

    warn "LFS_MODE=migrate: se omite comparación de hashes Git porque el historial fue reescrito."
  else
    inventory_branches \
      "${gitlab_mirror_directory}" \
      "${repository_work_directory}/gitlab-branches.txt"

    inventory_branches \
      "${github_mirror_directory}" \
      "${repository_work_directory}/github-branches.txt"

    if compare_inventory \
      "Ramas" \
      "${repository_work_directory}/gitlab-branches.txt" \
      "${repository_work_directory}/github-branches.txt" \
      "${repository_work_directory}/branches.diff"; then
      branches_status="OK"
    else
      branches_status="ERROR"
      validation_failed=true
    fi

    inventory_tags \
      "${gitlab_mirror_directory}" \
      "${repository_work_directory}/gitlab-tags.txt"

    inventory_tags \
      "${github_mirror_directory}" \
      "${repository_work_directory}/github-tags.txt"

    if compare_inventory \
      "Tags" \
      "${repository_work_directory}/gitlab-tags.txt" \
      "${repository_work_directory}/github-tags.txt" \
      "${repository_work_directory}/tags.diff"; then
      tags_status="OK"
    else
      tags_status="ERROR"
      validation_failed=true
    fi

    inventory_references \
      "${gitlab_mirror_directory}" \
      "${repository_work_directory}/gitlab-references.txt"

    inventory_references \
      "${github_mirror_directory}" \
      "${repository_work_directory}/github-references.txt"

    if compare_inventory \
      "Referencias permitidas" \
      "${repository_work_directory}/gitlab-references.txt" \
      "${repository_work_directory}/github-references.txt" \
      "${repository_work_directory}/references.diff"; then
      references_status="OK"
    else
      references_status="ERROR"
      validation_failed=true
    fi

    inventory_commits \
      "${gitlab_mirror_directory}" \
      "${repository_work_directory}/gitlab-commits.txt"

    inventory_commits \
      "${github_mirror_directory}" \
      "${repository_work_directory}/github-commits.txt"

    if compare_inventory \
      "Commits alcanzables desde ramas y tags" \
      "${repository_work_directory}/gitlab-commits.txt" \
      "${repository_work_directory}/github-commits.txt" \
      "${repository_work_directory}/commits.diff"; then
      commits_status="OK"
    else
      commits_status="ERROR"
      validation_failed=true
    fi

    inventory_objects \
      "${gitlab_mirror_directory}" \
      "${repository_work_directory}/gitlab-objects.txt"

    inventory_objects \
      "${github_mirror_directory}" \
      "${repository_work_directory}/github-objects.txt"

    if compare_inventory \
      "Objetos Git alcanzables desde ramas y tags" \
      "${repository_work_directory}/gitlab-objects.txt" \
      "${repository_work_directory}/github-objects.txt" \
      "${repository_work_directory}/objects.diff"; then
      objects_status="OK"
    else
      objects_status="ERROR"
      validation_failed=true
    fi
  fi

  if [[ "${SYNC_DEFAULT_BRANCH}" != "true" ]]; then
    default_branch_status="NO_APLICA"
  elif [[ -z "${gitlab_default_branch}" ]]; then
    default_branch_status="NO_DEFINIDA_EN_GITLAB"
    validation_warning=true

    registrar_incidencia \
      "ADVERTENCIA" \
      "${CURRENT_REPOSITORY}" \
      "Rama predeterminada" \
      "GitLab no informó una rama predeterminada."
  elif [[ "${gitlab_default_branch}" == "${github_default_branch}" ]]; then
    default_branch_status="OK"
    success "Rama predeterminada: OK (${gitlab_default_branch})."
  else
    default_branch_status="DIFERENTE"
    validation_failed=true

    registrar_incidencia \
      "ERROR" \
      "${CURRENT_REPOSITORY}" \
      "Rama predeterminada" \
      "La rama predeterminada no coincide. GitLab=${gitlab_default_branch}; GitHub=${github_default_branch}."
  fi

  refs_count="$(
    git -C "${gitlab_mirror_directory}" for-each-ref refs/heads refs/tags |
      wc -l |
      tr -d ' '
  )"

  if [[ "${MIGRATE_VARIABLES}" == "true" ]]; then
    variables_status="$(
      validate_project_variables_and_secrets \
        "${gitlab_project_id}" \
        "${repository_name}" \
        "${repository_work_directory}"
    )"

    if [[ "${variables_status}" == "ERROR" ]]; then
      validation_failed=true
    elif [[ "${variables_status}" == "ADVERTENCIA" ]]; then
      validation_warning=true
    fi

    if [[ "${MIGRATE_ENVIRONMENT_SCOPED_VARIABLES}" == "true" ]]; then
      environments_status="${variables_status}"
    fi
  fi

  # El migrador original solo ejecuta variables en repositorios vacíos.
  # Branch protections, miembros y pipelines se validan únicamente si hay refs.
  if [[ "${refs_count}" -gt 0 ]]; then
    if [[ "${MIGRATE_BRANCH_PROTECTIONS}" == "true" ]]; then
      protections_status="$(
        validate_branch_protections \
          "${gitlab_project_id}" \
          "${repository_name}" \
          "${repository_work_directory}"
      )"

      if [[ "${protections_status}" == "ERROR" ]]; then
        validation_failed=true
      elif [[ "${protections_status}" == "ADVERTENCIA" ]]; then
        validation_warning=true
      fi
    fi

    if [[ "${MIGRATE_REPOSITORY_MEMBERS}" == "true" ]]; then
      members_status="$(
        validate_repository_members \
          "${gitlab_project_id}" \
          "${repository_name}" \
          "${repository_work_directory}"
      )"

      if [[ "${members_status}" == "ERROR" ]]; then
        validation_failed=true
      elif [[ "${members_status}" == "ADVERTENCIA" ]]; then
        validation_warning=true
      fi
    fi

    if [[ "${MIGRATE_PIPELINES}" == "true" ]]; then
      pipelines_status="$(
        validate_pipelines \
          "${gitlab_mirror_directory}" \
          "${repository_name}" \
          "${repository_work_directory}"
      )"

      if [[ "${pipelines_status}" == "ERROR" ]]; then
        validation_failed=true
      elif [[ "${pipelines_status}" == "ADVERTENCIA" ]]; then
        validation_warning=true
      fi
    fi
  else
    [[ "${MIGRATE_BRANCH_PROTECTIONS}" == "true" ]] &&
      protections_status="NO_APLICA_REPOSITORIO_VACIO"

    [[ "${MIGRATE_REPOSITORY_MEMBERS}" == "true" ]] &&
      members_status="NO_APLICA_REPOSITORIO_VACIO"

    [[ "${MIGRATE_PIPELINES}" == "true" ]] &&
      pipelines_status="NO_APLICA_REPOSITORIO_VACIO"
  fi

  if [[ "${LFS_MODE}" == "preserve" || "${LFS_MODE}" == "migrate" ]]; then
    lfs_status="$(
      validate_lfs_repository \
        "${github_mirror_directory}" \
        "${repository_work_directory}"
    )"

    if [[ "${lfs_status}" == "ERROR" ]]; then
      validation_failed=true
    elif [[ "${lfs_status}" == "ADVERTENCIA" ]]; then
      validation_warning=true
    fi
  elif [[ "${LFS_MODE}" == "report" ]]; then
    lfs_status="NO_APLICA_REPORT"
  fi

  if [[ "${validation_failed}" == "true" ]]; then
    final_status="ERROR"
    detail="Existen diferencias Git o errores en metadatos requeridos."
    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))

    error "CERTIFICACIÓN FALLIDA: ${repository_name}."
  elif [[ "${validation_warning}" == "true" ]]; then
    final_status="CERTIFICADO_CON_ADVERTENCIA"
    detail="La migración Git es válida, pero existen advertencias de metadatos."
    WARNING_PROJECTS=$((WARNING_PROJECTS + 1))

    warn "CERTIFICACIÓN EXITOSA CON ADVERTENCIAS: ${repository_name}."
  else
    final_status="CERTIFICADO"
    detail="Ramas, tags, referencias, commits, objetos, integridad Git y metadatos configurados fueron validados."
    CERTIFIED_PROJECTS=$((CERTIFIED_PROJECTS + 1))

    success "CERTIFICACIÓN EXITOSA: ${repository_name}."
  fi

  registrar_resultado \
    "${repository_name}" \
    "${final_status}" \
    "${branches_status}" \
    "${tags_status}" \
    "${references_status}" \
    "${commits_status}" \
    "${objects_status}" \
    "${gitlab_fsck_status}" \
    "${github_fsck_status}" \
    "${default_branch_status}" \
    "${variables_status}" \
    "${environments_status}" \
    "${protections_status}" \
    "${members_status}" \
    "${pipelines_status}" \
    "${lfs_status}" \
    "${detail}"

  rm -rf "${repository_work_directory}"
}

generate_json_report() {
  jq -n \
    --arg script "${SCRIPT_NAME}" \
    --arg fecha_generacion "$(date '+%Y-%m-%d %H:%M:%S')" \
    --arg inicio "${START_TIME}" \
    --arg fin "$(date '+%Y-%m-%d %H:%M:%S')" \
    --arg organizacion_github "${OWNER}" \
    --arg grupo_gitlab "${GROUP_GITLAB:-Todos los proyectos visibles para el token}" \
    --arg repositorios_seleccionados "${REPOSITORIES_FILE:-No especificado}" \
    --arg gitlab_url "${GITLAB_URL}" \
    --arg directorio_salida "${OUTPUT_DIRECTORY}" \
    --arg log_principal "${LOG_FILE}" \
    --argjson total_proyectos "${TOTAL_PROJECTS}" \
    --argjson proyectos_procesados "${PROCESSED_PROJECTS}" \
    --argjson proyectos_certificados "${CERTIFIED_PROJECTS}" \
    --argjson proyectos_advertencia "${WARNING_PROJECTS}" \
    --argjson proyectos_error "${FAILED_PROJECTS}" \
    --argjson proyectos_omitidos "${SKIPPED_PROJECTS}" \
    --slurpfile resultados "${RESULTS_NDJSON}" \
    --slurpfile incidencias "${EVENTS_NDJSON}" \
    '{
      metadatos: {
        script: $script,
        fecha_generacion: $fecha_generacion,
        inicio: $inicio,
        fin: $fin,
        organizacion_github: $organizacion_github,
        grupo_gitlab: $grupo_gitlab,
        repositorios_seleccionados: $repositorios_seleccionados,
        gitlab_url: $gitlab_url,
        directorio_salida: $directorio_salida,
        log_principal: $log_principal,
        alcance_certificacion: [
          "refs/heads/*",
          "refs/tags/*",
          "commits alcanzables desde ramas y tags",
          "objetos Git alcanzables desde ramas y tags",
          "git fsck --full --no-reflogs",
          "variables y secrets",
          "GitHub Environments",
          "deployment branch policies",
          "Branch Protection Rules básicas",
          "miembros y permisos mínimos",
          "pipelines GitHub Actions",
          "Git LFS cuando aplique"
        ]
      },
      resumen: {
        total_proyectos: $total_proyectos,
        proyectos_procesados: $proyectos_procesados,
        proyectos_certificados: $proyectos_certificados,
        proyectos_con_advertencias: $proyectos_advertencia,
        proyectos_con_error: $proyectos_error,
        proyectos_omitidos: $proyectos_omitidos,
        certificacion_exitosa: ($proyectos_error == 0)
      },
      resultados_por_repositorio: $resultados,
      errores: ($incidencias | map(select(.severidad == "ERROR"))),
      advertencias: ($incidencias | map(select(.severidad == "ADVERTENCIA")))
    }' > "${JSON_REPORT_FILE}"

  success "Reporte JSON generado: ${JSON_REPORT_FILE}"
}

print_summary() {
  generate_json_report

  printf '\n'
  info "================================================================"
  info "RESUMEN DE CERTIFICACIÓN GITLAB -> GITHUB"
  info "================================================================"
  info "Inicio: ${START_TIME}"
  info "Fin: $(date '+%Y-%m-%d %H:%M:%S')"
  info "Proyectos encontrados: ${TOTAL_PROJECTS}"
  info "Proyectos procesados: ${PROCESSED_PROJECTS}"
  info "Proyectos certificados: ${CERTIFIED_PROJECTS}"
  info "Proyectos certificados con advertencias: ${WARNING_PROJECTS}"
  info "Proyectos con error: ${FAILED_PROJECTS}"
  info "Proyectos omitidos: ${SKIPPED_PROJECTS}"
  info "Log principal: ${LOG_FILE}"
  info "Reporte JSON: ${JSON_REPORT_FILE}"
  info "================================================================"

  if [[ "${FAILED_PROJECTS}" -gt 0 ]]; then
    error "RESULTADO FINAL: CERTIFICACIÓN CON ERRORES."
    return 1
  fi

  if [[ "${WARNING_PROJECTS}" -gt 0 ]]; then
    warn "RESULTADO FINAL: CERTIFICACIÓN EXITOSA CON ADVERTENCIAS."
    return 0
  fi

  success "RESULTADO FINAL: CERTIFICACIÓN EXITOSA."
  return 0
}

main() {
  require_command bash
  require_command curl
  require_command jq
  require_command git
  require_command awk
  require_command sed
  require_command diff
  require_command sort
  require_command mktemp
  require_command tee
  require_command find
  require_command grep

  [[ -n "${GITLAB_URL}" ]] || fatal "Falta GITLAB_URL."
  [[ -n "${TOKEN_GITLAB}" ]] || fatal "Falta TOKEN_GITLAB."
  [[ -n "${OWNER}" ]] || fatal "Falta OWNER."
  [[ -n "${TOKEN_GITHUB}" ]] || fatal "Falta TOKEN_GITHUB."

  validate_url "GITLAB_URL" "${GITLAB_URL}"
  validate_url "GITHUB_API_URL" "${GITHUB_API_URL}"

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

  validate_boolean "MIGRATE_PIPELINES" "${MIGRATE_PIPELINES}"
  validate_boolean "PIPELINES_REQUIRED" "${PIPELINES_REQUIRED}"
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

  if [[ "${LFS_MODE}" == "preserve" || "${LFS_MODE}" == "migrate" ]]; then
    require_command git-lfs
  fi

  GITLAB_URL="${GITLAB_URL%/}"
  GITHUB_API_URL="${GITHUB_API_URL%/}"

  WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gitlab-github-certification.XXXXXX")"
  EVENTS_NDJSON="$(mktemp "${WORK_ROOT}/eventos.XXXXXX.ndjson")"
  RESULTS_NDJSON="$(mktemp "${WORK_ROOT}/resultados.XXXXXX.ndjson")"

  : > "${EVENTS_NDJSON}"
  : > "${RESULTS_NDJSON}"

  create_askpass_script

  info "Inicio de certificación GitLab -> GitHub."
  info "Organización GitHub: ${OWNER}"
  info "GitLab API: ${GITLAB_URL}"
  info "GitHub API: ${GITHUB_API_URL}"
  info "Grupo GitLab: ${GROUP_GITLAB:-No especificado}"
  info "Lista repositorios: ${REPOSITORIES_FILE:-No especificada}"
  info "LFS_MODE: ${LFS_MODE}"
  info "Validar variables: ${MIGRATE_VARIABLES}"
  info "Validar protecciones: ${MIGRATE_BRANCH_PROTECTIONS}"
  info "Validar miembros: ${MIGRATE_REPOSITORY_MEMBERS}"
  info "Validar pipelines: ${MIGRATE_PIPELINES}"
  info "Log principal: ${LOG_FILE}"
  info "Reporte JSON final: ${JSON_REPORT_FILE}"

  if ! request_api "GitLab" "GET" "${GITLAB_URL}/api/v4/user"; then
    fatal "No fue posible conectar con GitLab para validar el token."
  fi

  if ! http_status_is_success "${HTTP_STATUS}"; then
    show_http_error "GitLab" "${GITLAB_URL}/api/v4/user"
    fatal "El token GitLab no es válido o no tiene permisos API."
  fi

  success "Acceso GitLab validado."

  if ! request_api \
    "GitHub" \
    "GET" \
    "${GITHUB_API_URL}/orgs/$(url_encode "${OWNER}")"; then
    fatal "No fue posible conectar con GitHub para validar la organización."
  fi

  if ! http_status_is_success "${HTTP_STATUS}"; then
    show_http_error "GitHub" "${GITHUB_API_URL}/orgs/$(url_encode "${OWNER}")"
    fatal "No fue posible consultar la organización GitHub."
  fi

  success "Acceso GitHub validado."

  fetch_gitlab_projects

  while IFS= read -r project_json; do
    certify_repository "${project_json}"
  done < "${PROJECTS_FILE}"

  print_summary
}

main "$@"
