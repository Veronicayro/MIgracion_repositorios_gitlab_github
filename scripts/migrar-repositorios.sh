#!/bin/bash

clear

BUSCAR_GITLAB="gitlab.com"
BUSCAR_GITHUB="github.com"
ruta_inicial=$(pwd)

echo "GROUP_GITLAB recibido: $GROUP_GITLAB"
echo "OWNER recibido: $OWNER"

if [ -z "$GROUP_GITLAB" ]; then
    URL_GITLAB="https://gitlab.com/api/v4/projects"
else
    URL_GITLAB="https://gitlab.com/api/v4/groups/${GROUP_GITLAB}/projects"
fi

echo "URL GITLAB: $URL_GITLAB"

if [ -n "$TOKEN_GITLAB" ]; then
    echo "TOKEN_GITLAB recibido correctamente"
else
    echo "ERROR: TOKEN_GITLAB no recibido"
    exit 1
fi

if [ -n "$TOKEN_GITHUB" ]; then
    echo "TOKEN_GITHUB recibido correctamente"
else
    echo "ERROR: TOKEN_GITHUB no recibido"
    exit 1
fi

if [ -n "$OWNER" ]; then
    echo "OWNER recibido correctamente"
else
    echo "ERROR: OWNER no recibido"
    exit 1
fi

echo "URL GITLAB: $URL_GITLAB"

# Obtener repositorios de GitLab
curl --fail --silent --show-error \
    --header "PRIVATE-TOKEN: ${TOKEN_GITLAB}" \
    "$URL_GITLAB" |
jq -c '.[] | {name, http_url_to_repo, description}' |
while read -r elemento; do

    # Extraer campos
    repositorio=$(echo "$elemento" | jq -r '.name')
    url_repo_gitlab=$(echo "$elemento" | jq -r '.http_url_to_repo')
    description=$(echo "$elemento" | jq -r '.description')

    echo ""
    echo "=============================================="
    echo "MIGRANDO REPOSITORIO: $repositorio"
    echo "=============================================="

    # Crear directorio temporal limpio
    rm -rf "${ruta_inicial}/migracion"
    mkdir -p "${ruta_inicial}/migracion"

    cd "${ruta_inicial}/migracion" || exit 1

    # ---------------------------------------------------------
    # 1. Verificar si el repositorio existe en GitHub
    # ---------------------------------------------------------

    HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" \
        -H "Authorization: token $TOKEN_GITHUB" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${OWNER}/${repositorio}")

    # ---------------------------------------------------------
    # 2. Preparar URL autenticada de GitLab
    # ---------------------------------------------------------

    REEMPLAZAR="oauth2:${TOKEN_GITLAB}@gitlab.com"
    url_repo_gitlab=${url_repo_gitlab/${BUSCAR_GITLAB}/${REEMPLAZAR}}

    # ---------------------------------------------------------
    # 3. Crear repositorio en GitHub si no existe
    # ---------------------------------------------------------

    if [[ "$HTTP_CODE" == "200" ]]; then

        echo "EL REPOSITORIO EXISTE EN GITHUB Y SE VA A SOBREESCRIBIR"

    elif [[ "$HTTP_CODE" == "404" ]]; then

        echo "EL REPOSITORIO NO EXISTE EN GITHUB Y SE VA A CREAR"

        RESPUESTA=$(curl -s -w "\n%{http_code}" -X POST \
            -H "Authorization: token $TOKEN_GITHUB" \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/orgs/${OWNER}/repos" \
            -d "$(jq -n \
                --arg name "$repositorio" \
                --arg description "$description" \
                '{name: $name, description: $description, private: true}')")

        HTTP_CREACION=$(echo "$RESPUESTA" | tail -n1)

        if [[ "$HTTP_CREACION" != "201" ]]; then
            echo "ERROR: No se pudo crear el repositorio $repositorio en GitHub"
            echo "$RESPUESTA"
            cd "$ruta_inicial"
            continue
        fi

        echo "SE CREO EL REPOSITORIO"

    else

        echo "ERROR: GitHub devolvio HTTP $HTTP_CODE al consultar $repositorio"
        cd "$ruta_inicial"
        continue

    fi

    # ---------------------------------------------------------
    # 4. Obtener URL de GitHub
    # ---------------------------------------------------------

    echo "BUSQUEDA DE REPOSITORIO"

    url_repo_github=$(curl --fail --silent --show-error \
        -H "Authorization: token $TOKEN_GITHUB" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${OWNER}/${repositorio}" |
        jq -r '.clone_url')

    if [[ -z "$url_repo_github" || "$url_repo_github" == "null" ]]; then
        echo "ERROR: No se pudo obtener la URL del repositorio de GitHub"
        cd "$ruta_inicial"
        continue
    fi

    echo "GitLab : $url_repo_gitlab"
    echo "GitHub : $url_repo_github"

    # ---------------------------------------------------------
    # 5. Clonar GitLab como espejo
    # ---------------------------------------------------------

    echo ""
    echo "CLONANDO REPOSITORIO DE GITLAB..."

    rm -rf repositorio.git

    if ! git clone --mirror "$url_repo_gitlab" repositorio.git; then
        echo "ERROR: No se pudo clonar $repositorio desde GitLab"
        cd "$ruta_inicial"
        continue
    fi

    # ---------------------------------------------------------
    # 6. Verificar que el clone realmente contiene Git
    # ---------------------------------------------------------

    cd repositorio.git || {
        echo "ERROR: No se pudo acceder al repositorio clonado"
        cd "$ruta_inicial"
        continue
    }

    echo "VERIFICANDO CLON DEL REPOSITORIO..."

    if ! git rev-parse --is-bare-repository; then
        echo "ERROR: El repositorio clonado no es un repositorio bare válido"
        cd "$ruta_inicial"
        continue
    fi

    echo "REFERENCIAS OBTENIDAS DESDE GITLAB:"
    git show-ref || true

    echo "CONTENIDO DEL REPOSITORIO:"
    ls -la

    # ---------------------------------------------------------
    # 7. Configurar remote de GitHub
    # ---------------------------------------------------------

    REEMPLAZAR="${TOKEN_GITHUB}@github.com"
    url_repo_github=${url_repo_github/${BUSCAR_GITHUB}/${REEMPLAZAR}}

    echo ""
    echo "EJECUCION DEL REMOTE"

    if ! git remote set-url origin "$url_repo_github"; then
        echo "ERROR: No se pudo configurar el remote de GitHub"
        cd "$ruta_inicial"
        continue
    fi

    echo "REMOTE CONFIGURADO:"
    git remote -v

    # ---------------------------------------------------------
    # 8. Migrar TODO el repositorio
    # ---------------------------------------------------------

    echo ""
    echo "EJECUCION DEL PUSH"
    echo "MIGRANDO BRANCHES, TAGS E HISTORIAL COMPLETO..."

    if git push --mirror origin; then
        echo ""
        echo "=============================================="
        echo "MIGRACION EXITOSA: $repositorio"
        echo "=============================================="
    else
        echo ""
        echo "=============================================="
        echo "ERROR EN LA MIGRACION: $repositorio"
        echo "=============================================="
    fi

    # ---------------------------------------------------------
    # 9. Volver al directorio inicial
    # ---------------------------------------------------------

    cd "$ruta_inicial" || exit 1

done
