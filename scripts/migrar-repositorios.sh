#!/bin/bash

# ============================================================
# CONFIGURACIÓN
# ============================================================

BUSCAR_GITLAB="gitlab.com"
BUSCAR_GITHUB="github.com"

ruta_inicial=$(pwd)

echo "========================================"
echo "INICIO DE MIGRACIÓN"
echo "========================================"

echo "GROUP_GITLAB recibido: [$GROUP_GITLAB]"
echo "PROJECT_GITLAB recibido: [$PROJECT_GITLAB]"
echo "OWNER recibido: [$OWNER]"

# ============================================================
# VALIDAR VARIABLES
# ============================================================

if [ -z "$GROUP_GITLAB" ]; then
    echo "ERROR: GROUP_GITLAB no recibido"
    exit 1
fi

if [ -z "$PROJECT_GITLAB" ]; then
    echo "ERROR: PROJECT_GITLAB no recibido"
    exit 1
fi

if [ -z "$OWNER" ]; then
    echo "ERROR: OWNER no recibido"
    exit 1
fi

if [ -z "$TOKEN_GITLAB" ]; then
    echo "ERROR: TOKEN_GITLAB no recibido"
    exit 1
else
    echo "TOKEN_GITLAB recibido correctamente"
fi

if [ -z "$TOKEN_GITHUB" ]; then
    echo "ERROR: TOKEN_GITHUB no recibido"
    exit 1
else
    echo "TOKEN_GITHUB recibido correctamente"
fi

# ============================================================
# OBTENER PROYECTOS DEL GRUPO DE GITLAB
# ============================================================

echo ""
echo "========================================"
echo "BUSCANDO PROYECTO EN GITLAB"
echo "========================================"

echo "GRUPO: $GROUP_GITLAB"
echo "PROYECTO: $PROJECT_GITLAB"

URL_GITLAB="https://gitlab.com/api/v4/groups/${GROUP_GITLAB}/projects"

echo "URL GITLAB: $URL_GITLAB"

PROJECT_INFO=$(curl -fsS \
    --header "PRIVATE-TOKEN: ${TOKEN_GITLAB}" \
    "$URL_GITLAB")

if [ $? -ne 0 ]; then
    echo "ERROR: No se pudo consultar los proyectos del grupo en GitLab"
    exit 1
fi

echo "RESPUESTA DE GITLAB OBTENIDA"

# ============================================================
# VERIFICAR QUE LA RESPUESTA SEA UN ARRAY
# ============================================================

TIPO_RESPUESTA=$(echo "$PROJECT_INFO" | jq -r 'type')

if [ "$TIPO_RESPUESTA" != "array" ]; then
    echo "ERROR: La respuesta de GitLab no es un array"
    echo ""
    echo "RESPUESTA:"
    echo "$PROJECT_INFO"
    exit 1
fi

# ============================================================
# BUSCAR EL PROYECTO ESPECÍFICO
# ============================================================

PROJECT_DATA=$(echo "$PROJECT_INFO" |
    jq -c --arg repo "$PROJECT_GITLAB" '
        .[] | select(.name == $repo)
    ')

if [ -z "$PROJECT_DATA" ]; then

    echo ""
    echo "ERROR: No se encontró el repositorio:"
    echo "[$PROJECT_GITLAB]"
    echo ""
    echo "dentro del grupo:"
    echo "[$GROUP_GITLAB]"
    echo ""

    echo "========================================"
    echo "REPOSITORIOS ENCONTRADOS EN EL GRUPO"
    echo "========================================"

    echo "$PROJECT_INFO" | jq -r '.[].name'

    exit 1
fi

echo ""
echo "PROYECTO ENCONTRADO EN GITLAB"

# ============================================================
# OBTENER DATOS DEL PROYECTO
# ============================================================

repositorio=$(echo "$PROJECT_DATA" | jq -r '.name')

url_repo_gitlab=$(echo "$PROJECT_DATA" |
    jq -r '.http_url_to_repo')

description=$(echo "$PROJECT_DATA" |
    jq -r '.description // ""')

echo ""
echo "========================================"
echo "DATOS DEL PROYECTO"
echo "========================================"

echo "REPOSITORIO: $repositorio"
echo "URL GITLAB: $url_repo_gitlab"
echo "DESCRIPCIÓN: $description"

# ============================================================
# PREPARAR CARPETA DE MIGRACIÓN
# ============================================================

echo ""
echo "========================================"
echo "PREPARANDO CARPETA DE MIGRACIÓN"
echo "========================================"

if [ -d "./migracion" ]; then
    rm -rf "./migracion"
fi

mkdir -p "./migracion"

cd "./migracion" || exit 1

echo "CARPETA DE MIGRACIÓN CREADA"

# ============================================================
# COMPROBAR SI EL REPOSITORIO EXISTE EN GITHUB
# ============================================================

echo ""
echo "========================================"
echo "COMPROBANDO REPOSITORIO EN GITHUB"
echo "========================================"

HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" \
    -H "Authorization: token $TOKEN_GITHUB" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/${OWNER}/${repositorio}")

echo "HTTP CODE: $HTTP_CODE"

if [[ "$HTTP_CODE" == "200" ]]; then

    echo ""
    echo "EL REPOSITORIO EXISTE EN GITHUB"
    echo "SE VA A SOBREESCRIBIR"

else

    echo ""
    echo "EL REPOSITORIO NO EXISTE EN GITHUB"
    echo "SE VA A CREAR"

    RESPONSE_CREATE=$(curl -s -X POST \
        -H "Authorization: token $TOKEN_GITHUB" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/orgs/$OWNER/repos" \
        -d "{\"name\":\"$repositorio\", \"description\":\"$description\", \"private\":true}")

    CREATED_NAME=$(echo "$RESPONSE_CREATE" |
        jq -r '.name // empty')

    if [ -z "$CREATED_NAME" ]; then

        echo ""
        echo "ERROR: No se pudo crear el repositorio en GitHub"

        echo ""
        echo "RESPUESTA DE GITHUB:"
        echo "$RESPONSE_CREATE"

        cd "$ruta_inicial"
        exit 1
    fi

    echo ""
    echo "SE CREÓ EL REPOSITORIO: $CREATED_NAME"

fi

# ============================================================
# OBTENER URL DEL REPOSITORIO DE GITHUB
# ============================================================

echo ""
echo "========================================"
echo "OBTENIENDO URL DE GITHUB"
echo "========================================"

url_repo_github=$(curl -s \
    -H "Authorization: token $TOKEN_GITHUB" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/${OWNER}/${repositorio}" |
    jq -r '.clone_url')

if [ -z "$url_repo_github" ] || [ "$url_repo_github" = "null" ]; then

    echo "ERROR: No se pudo obtener la URL de GitHub"

    cd "$ruta_inicial"
    exit 1
fi

echo "URL GITHUB OBTENIDA: $url_repo_github"

# ============================================================
# PREPARAR URL AUTENTICADA DE GITLAB
# ============================================================

REEMPLAZAR="oauth2:${TOKEN_GITLAB}@gitlab.com"

url_repo_gitlab_auth=${url_repo_gitlab/${BUSCAR_GITLAB}/${REEMPLAZAR}}

# ============================================================
# 1. CLONAR GITLAB COMO ESPEJO
# ============================================================

echo ""
echo "========================================"
echo "1. CLONANDO REPOSITORIO DE GITLAB"
echo "========================================"

git clone --mirror "$url_repo_gitlab_auth" repositorio.git

if [ $? -ne 0 ]; then

    echo ""
    echo "ERROR: No se pudo clonar el repositorio de GitLab"

    cd "$ruta_inicial"
    exit 1
fi

if [ ! -d "repositorio.git" ]; then

    echo ""
    echo "ERROR: No existe repositorio.git después del clone"

    cd "$ruta_inicial"
    exit 1
fi

echo ""
echo "CLON DEL REPOSITORIO CORRECTO"

# ============================================================
# 2. VERIFICAR CONTENIDO
# ============================================================

echo ""
echo "========================================"
echo "2. VERIFICANDO CONTENIDO"
echo "========================================"

cd repositorio.git || exit 1

echo ""
echo "REFERENCIAS OBTENIDAS DESDE GITLAB:"

git show-ref

TOTAL_REFS=$(git show-ref | wc -l)

echo ""
echo "TOTAL DE REFERENCIAS: $TOTAL_REFS"

if [ "$TOTAL_REFS" -eq 0 ]; then

    echo ""
    echo "ERROR: EL REPOSITORIO DE GITLAB NO TIENE REFERENCIAS"

    cd "$ruta_inicial"
    exit 1
fi

echo ""
echo "EL CLON CONTIENE REFERENCIAS"

# ============================================================
# 3. CONFIGURAR REMOTE DE GITHUB
# ============================================================

echo ""
echo "========================================"
echo "3. CONFIGURANDO REMOTE DE GITHUB"
echo "========================================"

REEMPLAZAR_GITHUB="${TOKEN_GITHUB}@github.com"

url_repo_github_auth=${url_repo_github/${BUSCAR_GITHUB}/${REEMPLAZAR_GITHUB}}

git remote set-url origin "$url_repo_github_auth"

if [ $? -ne 0 ]; then

    echo ""
    echo "ERROR: No se pudo configurar el remote de GitHub"

    cd "$ruta_inicial"
    exit 1
fi

echo ""
echo "REMOTE DE GITHUB CONFIGURADO CORRECTAMENTE"

# ============================================================
# 4. PUSH COMPLETO DEL ESPEJO
# ============================================================

echo ""
echo "========================================"
echo "4. EJECUTANDO PUSH --MIRROR"
echo "========================================"

git push --mirror origin

if [ $? -ne 0 ]; then

    echo ""
    echo "ERROR: FALLO EL PUSH DEL REPOSITORIO"

    cd "$ruta_inicial"
    exit 1
fi

echo ""
echo "PUSH COMPLETADO CORRECTAMENTE"

# ============================================================
# 5. VALIDACIÓN FINAL
# ============================================================

echo ""
echo "========================================"
echo "5. VALIDANDO REFERENCIAS EN GITHUB"
echo "========================================"

git ls-remote origin

if [ $? -ne 0 ]; then

    echo ""
    echo "ERROR: NO SE PUDIERON OBTENER LAS REFERENCIAS DE GITHUB"

    cd "$ruta_inicial"
    exit 1
fi

# ============================================================
# FINAL
# ============================================================

cd "$ruta_inicial"

echo ""
echo "========================================"
echo "MIGRACIÓN FINALIZADA"
echo "========================================"

echo "REPOSITORIO GITLAB:"
echo "$GROUP_GITLAB/$PROJECT_GITLAB"

echo ""
echo "REPOSITORIO GITHUB:"
echo "$OWNER/$repositorio"

echo ""
echo "========================================"
echo "FIN DE MIGRACIÓN"
echo "========================================"
