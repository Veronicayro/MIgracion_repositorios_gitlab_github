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
# OBTENER INFORMACIÓN DEL PROYECTO DE GITLAB
# ============================================================

PROJECT_PATH="${GROUP_GITLAB}/${PROJECT_GITLAB}"

echo ""
echo "========================================"
echo "BUSCANDO PROYECTO EN GITLAB"
echo "========================================"

echo "PROJECT PATH: $PROJECT_PATH"

PROJECT_INFO=$(curl -fsS \
    --header "PRIVATE-TOKEN: ${TOKEN_GITLAB}" \
    --get \
    --data-urlencode "id=${PROJECT_PATH}" \
    "https://gitlab.com/api/v4/projects")

if [ $? -ne 0 ]; then
    echo "ERROR: No se pudo consultar el proyecto en GitLab"
    exit 1
fi

echo "PROYECTO ENCONTRADO EN GITLAB"

# ============================================================
# OBTENER DATOS DEL PROYECTO
# ============================================================

repositorio=$(echo "$PROJECT_INFO" | jq -r '.name')
url_repo_gitlab=$(echo "$PROJECT_INFO" | jq -r '.http_url_to_repo')
description=$(echo "$PROJECT_INFO" | jq -r '.description // ""')

if [ -z "$repositorio" ] || [ "$repositorio" = "null" ]; then
    echo "ERROR: No se pudo obtener el nombre del repositorio"
    echo "Respuesta de GitLab:"
    echo "$PROJECT_INFO"
    exit 1
fi

if [ -z "$url_repo_gitlab" ] || [ "$url_repo_gitlab" = "null" ]; then
    echo "ERROR: No se pudo obtener la URL del repositorio"
    exit 1
fi

echo ""
echo "========================================"
echo "REPOSITORIO: $repositorio"
echo "========================================"

echo "URL GITLAB: $url_repo_gitlab"

# ============================================================
# PREPARAR CARPETA DE MIGRACIÓN
# ============================================================

if [ -d "./migracion" ]; then
    rm -rf "./migracion"
fi

mkdir -p ./migracion

cd ./migracion || exit 1

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

if [[ "$HTTP_CODE" == "200" ]]; then

    echo "EL REPOSITORIO EXISTE EN GITHUB"
    echo "SE VA A SOBREESCRIBIR"

else

    echo "EL REPOSITORIO NO EXISTE EN GITHUB"
    echo "SE VA A CREAR"

    RESPONSE_CREATE=$(curl -s -X POST \
        -H "Authorization: token $TOKEN_GITHUB" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/orgs/$OWNER/repos" \
        -d "{\"name\":\"$repositorio\", \"description\":\"$description\", \"private\":true}")

    CREATED_NAME=$(echo "$RESPONSE_CREATE" | jq -r '.name // empty')

    if [ -z "$CREATED_NAME" ]; then
        echo "ERROR: No se pudo crear el repositorio en GitHub"
        echo "Respuesta de GitHub:"
        echo "$RESPONSE_CREATE"
        cd "$ruta_inicial"
        exit 1
    fi

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
# PREPARAR CREDENCIALES DE GITLAB
# ============================================================

REEMPLAZAR="oauth2:$TOKEN_GITLAB@gitlab.com"

url_repo_gitlab_auth=${url_repo_gitlab/${BUSCAR_GITLAB}/${REEMPLAZAR}}

# ============================================================
# 1. CLONAR GITLAB COMO ESPEJO
# ============================================================

echo ""
echo "========================================"
echo "CLONANDO REPOSITORIO DE GITLAB"
echo "========================================"

git clone --mirror "$url_repo_gitlab_auth" repositorio.git

if [ $? -ne 0 ]; then
    echo "ERROR: No se pudo clonar el repositorio de GitLab"
    cd "$ruta_inicial"
    exit 1
fi

if [ ! -d "repositorio.git" ]; then
    echo "ERROR: No existe repositorio.git después del clone"
    cd "$ruta_inicial"
    exit 1
fi

echo "CLON DEL REPOSITORIO CORRECTO"

# ============================================================
# 2. VERIFICAR CONTENIDO
# ============================================================

echo ""
echo "========================================"
echo "VERIFICANDO CONTENIDO"
echo "========================================"

cd repositorio.git || exit 1

echo "REFERENCIAS OBTENIDAS DESDE GITLAB:"

git show-ref

TOTAL_REFS=$(git show-ref | wc -l)

echo ""
echo "TOTAL DE REFERENCIAS: $TOTAL_REFS"

if [ "$TOTAL_REFS" -eq 0 ]; then
    echo "ERROR: EL REPOSITORIO DE GITLAB NO TIENE REFERENCIAS"
    cd "$ruta_inicial"
    exit 1
fi

echo "EL CLON CONTIENE REFERENCIAS"

# ============================================================
# 3. CONFIGURAR REMOTE DE GITHUB
# ============================================================

REEMPLAZAR_GITHUB="$TOKEN_GITHUB@github.com"

url_repo_github_auth=${url_repo_github/${BUSCAR_GITHUB}/${REEMPLAZAR_GITHUB}}

echo ""
echo "========================================"
echo "CONFIGURANDO REMOTE DE GITHUB"
echo "========================================"

git remote set-url origin "$url_repo_github_auth"

echo "REMOTE CONFIGURADO"

# No mostramos el token en el log
echo "REMOTE DE GITHUB CONFIGURADO CORRECTAMENTE"

# ============================================================
# 4. PUSH COMPLETO DEL ESPEJO
# ============================================================

echo ""
echo "========================================"
echo "EJECUTANDO PUSH --MIRROR"
echo "========================================"

git push --mirror origin

if [ $? -ne 0 ]; then
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
echo "VALIDANDO REFERENCIAS EN GITHUB"
echo "========================================"

git ls-remote origin

if [ $? -ne 0 ]; then
    echo "ERROR: NO SE PUDIERON OBTENER LAS REFERENCIAS DE GITHUB"
    cd "$ruta_inicial"
    exit 1
fi

echo ""
echo "========================================"
echo "MIGRACIÓN FINALIZADA"
echo "========================================"

echo "REPOSITORIO: $repositorio"
echo "GITLAB: $PROJECT_PATH"
echo "GITHUB: ${OWNER}/${repositorio}"

cd "$ruta_inicial"

echo ""
echo "========================================"
echo "FIN DE MIGRACIÓN"
echo "========================================"
