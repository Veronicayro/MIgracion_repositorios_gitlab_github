#!/usr/bin/env bash
#
# certificar_migracion_gitlab_github.sh
#
# Certifica la migración GitLab -> GitHub comparando:
#   - Ramas: refs/heads/*
#   - Tags: refs/tags/*
#   - Referencias Git completas permitidas
#   - Commits alcanzables desde ramas y tags
#   - Objetos Git alcanzables desde ramas y tags
#   - Integridad de objetos mediante git fsck
#
# El script NO compara referencias internas exclusivas de GitLab:
#   refs/merge-requests/*
#   refs/pipelines/*
#   refs/environments/*
#   refs/keep-around/*
#
# Genera:
#   1. Un log principal: certificacion.log
#   2. Un archivo JSON consolidado: errores-certificacion.json
#
# Requisitos:
#   bash, curl, jq, git, awk, sed, diff, sort, mktemp, tee
#
# Variables obligatorias:
#   GITLAB_URL
#   TOKEN_GITLAB
#   OWNER
#   TOKEN_GITHUB
#
# Variables opcionales:
#   GROUP_GITLAB
#   GITHUB_API_URL
#   GITLAB_HOST_HEADER
#   GITLAB_CURL_NO_PROXY
#   GITLAB_GIT_BASE_URL
#   GITLAB_GIT_EXTRA_HEADER
#   INCLUDE_ARCHIVED
#   REQUIRE_DEFAULT_BRANCH_MATCH
#   OUTPUT_DIRECTORY
#
# Ejemplo directo:
#   export GITLAB_URL="https://gitlab.empresa.com"
#   export TOKEN_GITLAB="glpat-..."
#   export GROUP_GITLAB="grupo-origen"
#   export OWNER="organizacion-github"
#   export TOKEN_GITHUB="github_pat_..."
#   ./certificar_migracion_gitlab_github.sh
#
# Ejemplo usando gateway/proxy GitLab:
#   export GITLAB_URL="http://IP_GATEWAY_WSL:8080"
#   export GITLAB_HOST_HEADER="gitlab.empresa.com"
#   export GITLAB_CURL_NO_PROXY="true"
#   export GITLAB_GIT_BASE_URL="http://IP_GATEWAY_WSL:8080"
#   export GITLAB_GIT_EXTRA_HEADER="Host: gitlab.empresa.com"
#   ./certificar_migracion_gitlab_github.sh
#

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="$(basename "$0")"
readonly START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

GITLAB_URL="${GITLAB_URL:-}"
TOKEN_GITLAB="${TOKEN_GITLAB:-}"
GROUP_GITLAB="${GROUP_GITLAB:-}"

OWNER="${OWNER:-}"
TOKEN_GITHUB="${TOKEN_GITHUB:-}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"

GITLAB_HOST_HEADER="${GITLAB_HOST_HEADER:-}"
GITLAB_CURL_NO_PROXY="${GITLAB_CURL_NO_PROXY:-false}"
GITLAB_GIT_BASE_URL="${GITLAB_GIT_BASE_URL:-}"
GITLAB_GIT_EXTRA_HEADER="${GITLAB_GIT_EXTRA_HEADER:-}"

INCLUDE_ARCHIVED="${INCLUDE_ARCHIVED:-false}"
REQUIRE_DEFAULT_BRANCH_MATCH="${REQUIRE_DEFAULT_BRANCH_MATCH:-false}"

OUTPUT_DIRECTORY="${OUTPUT_DIRECTORY:-$(pwd)/certificacion-$(date +%Y%m%d-%H%M%S)}"
LOG_FILE="${OUTPUT_DIRECTORY}/certificacion.log"
JSON_REPORT_FILE="${OUTPUT_DIRECTORY}/errores-certificacion.json"

WORK_ROOT=""
PROJECTS_FILE=""
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
      fatal "La variable ${variable_name} debe ser true o false. Valor recibido: ${variable_value}."
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
  local detail="${11}"

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
      detalle: $detalle
    }' >> "${RESULTS_NDJSON}"
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

      if [[ -n "${GITLAB_HOST_HEADER}" ]]; then
        curl_arguments+=(
          --header "Host: ${GITLAB_HOST_HEADER}"
        )
      fi

      if [[ "${GITLAB_CURL_NO_PROXY}" == "true" ]]; then
        curl_arguments+=(
          --noproxy "*"
        )
      fi
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
    fatal "La URL de clonación GitLab no contiene un path válido: ${original_url}"
  fi

  repository_path="/${url_without_scheme#*/}"

  printf '%s%s\n' "${GITLAB_GIT_BASE_URL%/}" "${repository_path}"
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

fetch_gitlab_projects() {
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

  PROJECTS_FILE="$(mktemp "${WORK_ROOT}/gitlab-projects.XXXXXX.ndjson")"

  while true; do
    page_url="${endpoint}?per_page=100&page=${page}&order_by=id&sort=asc"

    if [[ -n "${GROUP_GITLAB}" ]]; then
      page_url="${page_url}&include_subgroups=true"
    fi

    info "Consultando GitLab, página ${page}."

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
          default_branch: (.default_branch // ""),
          archived: (.archived // false),
          http_url_to_repo: (.http_url_to_repo // "")
        }
    ' "${HTTP_BODY}" >> "${PROJECTS_FILE}"

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

  TOTAL_PROJECTS="$(wc -l < "${PROJECTS_FILE}" | tr -d ' ')"

  if [[ "${TOTAL_PROJECTS}" -eq 0 ]]; then
    warn "No se encontraron proyectos para certificar."
    exit 0
  fi

  success "Se encontraron ${TOTAL_PROJECTS} proyecto(s) GitLab."
}

certify_repository() {
  local project_json="$1"

  local repository_name=""
  local gitlab_name=""
  local gitlab_default_branch=""
  local gitlab_clone_url_original=""
  local gitlab_clone_url=""
  local github_clone_url=""
  local github_default_branch=""
  local is_archived=""

  local repository_work_directory=""
  local gitlab_mirror_directory=""
  local github_mirror_directory=""

  local branches_status="NO_EVALUADO"
  local tags_status="NO_EVALUADO"
  local references_status="NO_EVALUADO"
  local commits_status="NO_EVALUADO"
  local objects_status="NO_EVALUADO"
  local gitlab_fsck_status="NO_EVALUADO"
  local github_fsck_status="NO_EVALUADO"
  local default_branch_status="NO_EVALUADO"

  local validation_failed=false
  local validation_warning=false
  local final_status=""
  local detail=""
  local gitlab_command=()

  repository_name="$(jq -r '.path // empty' <<< "${project_json}")"
  gitlab_name="$(jq -r '.name // empty' <<< "${project_json}")"
  gitlab_default_branch="$(jq -r '.default_branch // empty' <<< "${project_json}")"
  gitlab_clone_url_original="$(jq -r '.http_url_to_repo // empty' <<< "${project_json}")"
  is_archived="$(jq -r '.archived // false' <<< "${project_json}")"

  CURRENT_REPOSITORY="${repository_name:-SIN_REPOSITORIO}"

  printf '\n'
  info "================================================================"
  info "Certificando repositorio: ${gitlab_name}"
  info "GitLab path: ${CURRENT_REPOSITORY}"
  info "================================================================"

  if [[ -z "${repository_name}" || -z "${gitlab_clone_url_original}" ]]; then
    error "El proyecto GitLab no contiene path o URL de clonación válida."

    registrar_incidencia \
      "ERROR" \
      "${CURRENT_REPOSITORY}" \
      "Datos del proyecto GitLab" \
      "Falta path o http_url_to_repo en la respuesta de GitLab."

    registrar_resultado \
      "${CURRENT_REPOSITORY}" \
      "ERROR" \
      "${branches_status}" \
      "${tags_status}" \
      "${references_status}" \
      "${commits_status}" \
      "${objects_status}" \
      "${gitlab_fsck_status}" \
      "${github_fsck_status}" \
      "${default_branch_status}" \
      "Falta path o URL de clonación GitLab."

    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    return
  fi

  if [[ "${is_archived}" == "true" && "${INCLUDE_ARCHIVED}" != "true" ]]; then
    warn "Repositorio archivado omitido: ${repository_name}."

    registrar_resultado \
      "${repository_name}" \
      "OMITIDO" \
      "${branches_status}" \
      "${tags_status}" \
      "${references_status}" \
      "${commits_status}" \
      "${objects_status}" \
      "${gitlab_fsck_status}" \
      "${github_fsck_status}" \
      "${default_branch_status}" \
      "Repositorio GitLab archivado."

    SKIPPED_PROJECTS=$((SKIPPED_PROJECTS + 1))
    return
  fi

  PROCESSED_PROJECTS=$((PROCESSED_PROJECTS + 1))

  info "Consultando repositorio GitHub: ${OWNER}/${repository_name}."

  if ! request_api \
    "GitHub" \
    "GET" \
    "${GITHUB_API_URL}/repos/$(url_encode "${OWNER}")/$(url_encode "${repository_name}")"; then

    registrar_incidencia \
      "ERROR" \
      "${CURRENT_REPOSITORY}" \
      "Consulta repositorio GitHub" \
      "No fue posible conectar con GitHub para consultar el repositorio."

    registrar_resultado \
      "${repository_name}" \
      "ERROR" \
      "${branches_status}" \
      "${tags_status}" \
      "${references_status}" \
      "${commits_status}" \
      "${objects_status}" \
      "${gitlab_fsck_status}" \
      "${github_fsck_status}" \
      "${default_branch_status}" \
      "No fue posible conectar con GitHub."

    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    return
  fi

  if [[ "${HTTP_STATUS}" != "200" ]]; then
    show_http_error \
      "GitHub" \
      "${GITHUB_API_URL}/repos/$(url_encode "${OWNER}")/$(url_encode "${repository_name}")"

    registrar_incidencia \
      "ERROR" \
      "${CURRENT_REPOSITORY}" \
      "Consulta repositorio GitHub" \
      "El repositorio no existe en GitHub o el token no permite consultarlo." \
      "${HTTP_BODY}"

    registrar_resultado \
      "${repository_name}" \
      "ERROR" \
      "${branches_status}" \
      "${tags_status}" \
      "${references_status}" \
      "${commits_status}" \
      "${objects_status}" \
      "${gitlab_fsck_status}" \
      "${github_fsck_status}" \
      "${default_branch_status}" \
      "El repositorio GitHub no existe o no puede consultarse."

    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    return
  fi

  github_clone_url="$(jq -r '.clone_url // empty' "${HTTP_BODY}")"
  github_default_branch="$(jq -r '.default_branch // empty' "${HTTP_BODY}")"

  if [[ ! "${github_clone_url}" =~ ^https://[^[:space:]]+\.git$ ]]; then
    error "GitHub devolvió una URL clone inválida: ${github_clone_url}"

    registrar_incidencia \
      "ERROR" \
      "${CURRENT_REPOSITORY}" \
      "URL de clonación GitHub" \
      "GitHub no devolvió una clone_url HTTPS válida." \
      "${HTTP_BODY}"

    registrar_resultado \
      "${repository_name}" \
      "ERROR" \
      "${branches_status}" \
      "${tags_status}" \
      "${references_status}" \
      "${commits_status}" \
      "${objects_status}" \
      "${gitlab_fsck_status}" \
      "${github_fsck_status}" \
      "${default_branch_status}" \
      "GitHub no devolvió clone_url válida."

    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))
    return
  fi

  gitlab_clone_url="$(rewrite_gitlab_clone_url "${gitlab_clone_url_original}")"

  repository_work_directory="$(mktemp -d "${WORK_ROOT}/${repository_name}.XXXXXX")"
  gitlab_mirror_directory="${repository_work_directory}/gitlab.git"
  github_mirror_directory="${repository_work_directory}/github.git"

  gitlab_command=(git)

  if [[ -n "${GITLAB_GIT_EXTRA_HEADER}" ]]; then
    gitlab_command+=(
      -c "http.extraHeader=${GITLAB_GIT_EXTRA_HEADER}"
    )
  fi

  info "Clonando GitLab como espejo."

  if ! git_with_credentials \
    "oauth2" \
    "${TOKEN_GITLAB}" \
    "${gitlab_command[@]}" clone --mirror \
    "${gitlab_clone_url}" \
    "${gitlab_mirror_directory}" \
    > "${repository_work_directory}/clone-gitlab.log" 2>&1; then

    error "No se pudo clonar GitLab para ${repository_name}."
    sed -n '1,250p' "${repository_work_directory}/clone-gitlab.log" >&2

    registrar_incidencia \
      "ERROR" \
      "${CURRENT_REPOSITORY}" \
      "Clone GitLab" \
      "No fue posible clonar el repositorio GitLab como espejo." \
      "${repository_work_directory}/clone-gitlab.log"

    registrar_resultado \
      "${repository_name}" \
      "ERROR" \
      "${branches_status}" \
      "${tags_status}" \
      "${references_status}" \
      "${commits_status}" \
      "${objects_status}" \
      "${gitlab_fsck_status}" \
      "${github_fsck_status}" \
      "${default_branch_status}" \
      "Falló clone --mirror desde GitLab."

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

    error "No se pudo clonar GitHub para ${repository_name}."
    sed -n '1,250p' "${repository_work_directory}/clone-github.log" >&2

    registrar_incidencia \
      "ERROR" \
      "${CURRENT_REPOSITORY}" \
      "Clone GitHub" \
      "No fue posible clonar el repositorio GitHub como espejo." \
      "${repository_work_directory}/clone-github.log"

    registrar_resultado \
      "${repository_name}" \
      "ERROR" \
      "${branches_status}" \
      "${tags_status}" \
      "${references_status}" \
      "${commits_status}" \
      "${objects_status}" \
      "${gitlab_fsck_status}" \
      "${github_fsck_status}" \
      "${default_branch_status}" \
      "Falló clone --mirror desde GitHub."

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

  if [[ -z "${gitlab_default_branch}" ]]; then
    default_branch_status="NO_DEFINIDA_EN_GITLAB"
    validation_warning=true

    warn "GitLab no informó una rama predeterminada para ${repository_name}."

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

    warn "Rama predeterminada diferente. GitLab=${gitlab_default_branch}; GitHub=${github_default_branch}."

    registrar_incidencia \
      "ADVERTENCIA" \
      "${CURRENT_REPOSITORY}" \
      "Rama predeterminada" \
      "La rama predeterminada no coincide. GitLab=${gitlab_default_branch}; GitHub=${github_default_branch}."

    if [[ "${REQUIRE_DEFAULT_BRANCH_MATCH}" == "true" ]]; then
      validation_failed=true
    else
      validation_warning=true
    fi
  fi

  if [[ "${validation_failed}" == "true" ]]; then
    final_status="ERROR"
    detail="Existen diferencias de referencias, commits, objetos o integridad Git."
    FAILED_PROJECTS=$((FAILED_PROJECTS + 1))

    error "CERTIFICACIÓN FALLIDA: ${repository_name}."
  elif [[ "${validation_warning}" == "true" ]]; then
    final_status="CERTIFICADO_CON_ADVERTENCIA"
    detail="La migración Git es válida, pero existen advertencias de metadatos."
    WARNING_PROJECTS=$((WARNING_PROJECTS + 1))

    warn "CERTIFICACIÓN EXITOSA CON ADVERTENCIAS: ${repository_name}."
  else
    final_status="CERTIFICADO"
    detail="Ramas, tags, referencias, commits, objetos e integridad Git coinciden."
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
        gitlab_url: $gitlab_url,
        directorio_salida: $directorio_salida,
        log_principal: $log_principal,
        alcance_certificacion: [
          "refs/heads/*",
          "refs/tags/*",
          "commits alcanzables desde ramas y tags",
          "objetos Git alcanzables desde ramas y tags",
          "git fsck --full --no-reflogs"
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

  [[ -n "${GITLAB_URL}" ]] || fatal "Falta la variable obligatoria GITLAB_URL."
  [[ -n "${TOKEN_GITLAB}" ]] || fatal "Falta la variable obligatoria TOKEN_GITLAB."
  [[ -n "${OWNER}" ]] || fatal "Falta la variable obligatoria OWNER."
  [[ -n "${TOKEN_GITHUB}" ]] || fatal "Falta la variable obligatoria TOKEN_GITHUB."

  validate_url "GITLAB_URL" "${GITLAB_URL}"
  validate_url "GITHUB_API_URL" "${GITHUB_API_URL}"
  validate_boolean "GITLAB_CURL_NO_PROXY" "${GITLAB_CURL_NO_PROXY}"
  validate_boolean "INCLUDE_ARCHIVED" "${INCLUDE_ARCHIVED}"
  validate_boolean "REQUIRE_DEFAULT_BRANCH_MATCH" "${REQUIRE_DEFAULT_BRANCH_MATCH}"

  if [[ -n "${GITLAB_GIT_BASE_URL}" ]]; then
    validate_url "GITLAB_GIT_BASE_URL" "${GITLAB_GIT_BASE_URL}"
  fi

  GITLAB_URL="${GITLAB_URL%/}"
  GITHUB_API_URL="${GITHUB_API_URL%/}"
  GITLAB_GIT_BASE_URL="${GITLAB_GIT_BASE_URL%/}"

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
  info "Incluir repositorios archivados: ${INCLUDE_ARCHIVED}"
  info "Exigir misma rama predeterminada: ${REQUIRE_DEFAULT_BRANCH_MATCH}"
  info "Log principal: ${LOG_FILE}"
  info "Reporte JSON final: ${JSON_REPORT_FILE}"

  info "Validando acceso a GitLab."

  if ! request_api "GitLab" "GET" "${GITLAB_URL}/api/v4/user"; then
    fatal "No fue posible conectar con GitLab para validar el token."
  fi

  if ! http_status_is_success "${HTTP_STATUS}"; then
    show_http_error "GitLab" "${GITLAB_URL}/api/v4/user"
    fatal "El token GitLab no es válido o no tiene permisos API."
  fi

  success "Acceso GitLab validado."

  info "Validando acceso a GitHub."

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
