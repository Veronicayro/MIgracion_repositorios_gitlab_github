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

if [ -n "$TOKEN_GITHUB" ]; then
    echo "TOKEN_GITHUB recibido correctamente"
else
    echo "ERROR: TOKEN_GITHUB no recibido"
    exit 1
fi

curl --header "PRIVATE-TOKEN: ${TOKEN_GITLAB}" "$URL_GITLAB" |
jq -c '.[] | {name, http_url_to_repo, description}' |
while read -r elemento; do

    repositorio=$(echo "$elemento" | jq -r '.name')
    url_repo_gitlab=$(echo "$elemento" | jq -r '.http_url_to_repo')
    description=$(echo "$elemento" | jq -r '.description')

    echo ""
    echo "========================================"
    echo "REPOSITORIO: $repositorio"
    echo "========================================"

    [ -d "./migracion" ] && rm -rf "./migracion"
    mkdir -p ./migracion
    cd ./migracion

    HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" \
        -H "Authorization: token $TOKEN_GITHUB" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${OWNER}/${repositorio}")

    REEMPLAZAR="oauth2:$TOKEN_GITLAB@gitlab.com"
    url_repo_gitlab=${url_repo_gitlab/${BUSCAR_GITLAB}/${REEMPLAZAR}}

    if [[ "$HTTP_CODE" == "200" ]]; then

        echo "EL REPOSITORIO EXISTE EN GITHUB Y SE VA A SOBREESCRIBIR"

    else

        echo "EL REPOSITORIO NO EXISTE EN GITHUB Y SE VA CREAR"

        curl -s -X POST \
            -H "Authorization: token $TOKEN_GITHUB" \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/orgs/$OWNER/repos" \
            -d "{\"name\":\"$repositorio\", \"description\":\"$description\", \"private\":true}"

        echo ""
        echo "SE CREO EL REPOSITORIO"

    fi

    echo ""
    echo "BUSQUEDA DE REPOSITORIO"

    url_repo_github=$(curl -s \
        -H "Authorization: token $TOKEN_GITHUB" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${OWNER}/${repositorio}" |
        jq -r '.clone_url')

    if [ -z "$url_repo_github" ] || [ "$url_repo_github" = "null" ]; then
        echo "ERROR: No se pudo obtener la URL de GitHub"
        cd "$ruta_inicial"
        continue
    fi

    echo "URL GITHUB OBTENIDA: $url_repo_github"

    # ============================================================
    # 1. CLONAR GITLAB COMO ESPEJO
    # ============================================================

    echo ""
    echo "CLONANDO REPOSITORIO DE GITLAB..."

    git clone --mirror "$url_repo_gitlab" repositorio.git

    if [ $? -ne 0 ]; then
        echo "ERROR: No se pudo clonar el repositorio de GitLab"
        cd "$ruta_inicial"
        continue
    fi

    if [ ! -d "repositorio.git" ]; then
        echo "ERROR: No existe repositorio.git después del clone"
        cd "$ruta_inicial"
        continue
    fi

    echo "CLON DEL REPOSITORIO CORRECTO"

    # ============================================================
    # 2. VERIFICAR QUE EL CLON TIENE CONTENIDO
    # ============================================================

    echo ""
    echo "VERIFICANDO CONTENIDO DEL REPOSITORIO..."

    cd repositorio.git

    echo "REFERENCIAS OBTENIDAS DESDE GITLAB:"
    git show-ref

    TOTAL_REFS=$(git show-ref | wc -l)

    echo ""
    echo "TOTAL DE REFERENCIAS: $TOTAL_REFS"

    if [ "$TOTAL_REFS" -eq 0 ]; then
        echo "ERROR: EL REPOSITORIO DE GITLAB NO TIENE REFERENCIAS"
        cd "$ruta_inicial"
        continue
    fi

    echo "EL CLON CONTIENE REFERENCIAS"

    # ============================================================
    # 3. CONFIGURAR REMOTE DE GITHUB
    # ============================================================

    REEMPLAZAR="$TOKEN_GITHUB@github.com"
    url_repo_github=${url_repo_github/${BUSCAR_GITHUB}/${REEMPLAZAR}}

    echo ""
    echo "CONFIGURANDO REMOTE DE GITHUB..."

    git remote set-url origin "$url_repo_github"

    echo ""
    echo "REMOTE CONFIGURADO:"
    git remote -v

    # ============================================================
    # 4. PUSH COMPLETO DEL ESPEJO
    # ============================================================

    echo ""
    echo "EJECUCION DEL PUSH --MIRROR"

    git push --mirror origin

    if [ $? -ne 0 ]; then
        echo "ERROR: FALLO EL PUSH DEL REPOSITORIO"
        cd "$ruta_inicial"
        continue
    fi

    echo ""
    echo "PUSH COMPLETADO CORRECTAMENTE"

    # ============================================================
    # 5. VALIDACION FINAL
    # ============================================================

    echo ""
    echo "VALIDANDO REFERENCIAS EN GITHUB..."

    git ls-remote origin

    echo ""
    echo "MIGRACION FINALIZADA: $repositorio"

    cd "$ruta_inicial"

done
