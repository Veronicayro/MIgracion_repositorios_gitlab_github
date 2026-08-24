#!/bin/bash

BUSCAR_GITLAB="gitlab.com"
ruta_inicial=$(pwd)

echo "========================================"
echo "VALIDACION DE MIGRACION GITLAB -> GITHUB"
echo "========================================"

echo "GROUP_GITLAB recibido: $GROUP_GITLAB"
echo "OWNER recibido: $OWNER"

if [ -z "$GROUP_GITLAB" ]; then
    URL_GITLAB="https://gitlab.com/api/v4/projects"
else
    URL_GITLAB="https://gitlab.com/api/v4/groups/${GROUP_GITLAB}/projects"
fi

echo "URL GITLAB: $URL_GITLAB"

if [ -z "$TOKEN_GITLAB" ]; then
    echo "ERROR: TOKEN_GITLAB no recibido"
    exit 1
fi

if [ -z "$TOKEN_GITHUB" ]; then
    echo "ERROR: TOKEN_GITHUB no recibido"
    exit 1
fi

if [ -z "$OWNER" ]; then
    echo "ERROR: OWNER no recibido"
    exit 1
fi

[ -d "./validacion" ] && rm -rf "./validacion"
mkdir -p "./validacion"

cd "./validacion" || exit 1

repositorios_evaluados=0
repositorios_correctos=0
repositorios_error=0

echo ""
echo "OBTENIENDO REPOSITORIOS DE GITLAB..."
echo ""

curl --fail --silent --show-error \
    --header "PRIVATE-TOKEN: ${TOKEN_GITLAB}" \
    "$URL_GITLAB" |
jq -c '.[] | {name, path, http_url_to_repo}' |
while read -r elemento; do

    nombre_repo=$(echo "$elemento" | jq -r '.name')
    path_repo=$(echo "$elemento" | jq -r '.path')
    url_repo_gitlab=$(echo "$elemento" | jq -r '.http_url_to_repo')

    echo ""
    echo "========================================"
    echo "REPOSITORIO: $nombre_repo"
    echo "========================================"

    echo "GitLab name : $nombre_repo"
    echo "GitLab path : $path_repo"

    # ---------------------------------------------------------
    # IMPORTANTE:
    # GitHub se busca utilizando NAME, no PATH
    # ---------------------------------------------------------

    echo ""
    echo "[1] BUSCANDO REPOSITORIO EN GITHUB..."

    HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" \
        -H "Authorization: token $TOKEN_GITHUB" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${OWNER}/${nombre_repo}")

    if [ "$HTTP_CODE" != "200" ]; then
        echo "ERROR: El repositorio no existe o no se puede acceder en GitHub"
        echo "GitHub esperado: ${OWNER}/${nombre_repo}"
        echo "HTTP CODE: $HTTP_CODE"
        repositorios_error=$((repositorios_error + 1))
        continue
    fi

    echo "Repositorio encontrado en GitHub:"
    echo "https://github.com/${OWNER}/${nombre_repo}"

    # ---------------------------------------------------------
    # URLs autenticadas
    # ---------------------------------------------------------

    url_repo_gitlab_auth=${url_repo_gitlab/${BUSCAR_GITLAB}/oauth2:$TOKEN_GITLAB@$BUSCAR_GITLAB}

    url_repo_github="https://x-access-token:${TOKEN_GITHUB}@github.com/${OWNER}/${nombre_repo}.git"

    # ---------------------------------------------------------
    # CLONAR GITLAB
    # ---------------------------------------------------------

    echo ""
    echo "[2] CLONANDO REPOSITORIO DE GITLAB..."

    rm -rf gitlab.git github.git

    if ! git clone --mirror "$url_repo_gitlab_auth" gitlab.git >/dev/null 2>&1; then
        echo "ERROR: No se pudo clonar el repositorio de GitLab"
        repositorios_error=$((repositorios_error + 1))
        continue
    fi

    # ---------------------------------------------------------
    # CLONAR GITHUB
    # ---------------------------------------------------------

    echo "[3] CLONANDO REPOSITORIO DE GITHUB..."

    if ! git clone --mirror "$url_repo_github" github.git >/dev/null 2>&1; then
        echo "ERROR: No se pudo clonar el repositorio de GitHub"
        repositorios_error=$((repositorios_error + 1))
        continue
    fi

    # ---------------------------------------------------------
    # VALIDAR BRANCHES
    # ---------------------------------------------------------

    echo ""
    echo "[4] VALIDANDO BRANCHES..."

    branches_gitlab=$(git --git-dir=gitlab.git for-each-ref \
        --format='%(refname:strip=2)' refs/heads/ |
        sort)

    branches_github=$(git --git-dir=github.git for-each-ref \
        --format='%(refname:strip=2)' refs/heads/ |
        sort)

    if diff -u <(echo "$branches_gitlab") <(echo "$branches_github") >/dev/null; then
        echo "BRANCHES: OK"
        branches_ok=true
    else
        echo "BRANCHES: ERROR"
        echo "Diferencias:"
        diff -u <(echo "$branches_gitlab") <(echo "$branches_github")
        branches_ok=false
    fi

    # ---------------------------------------------------------
    # VALIDAR TAGS
    # ---------------------------------------------------------

    echo ""
    echo "[5] VALIDANDO TAGS..."

    tags_gitlab=$(git --git-dir=gitlab.git for-each-ref \
        --format='%(refname:strip=2) %(objectname)' refs/tags/ |
        sort)

    tags_github=$(git --git-dir=github.git for-each-ref \
        --format='%(refname:strip=2) %(objectname)' refs/tags/ |
        sort)

    if diff -u <(echo "$tags_gitlab") <(echo "$tags_github") >/dev/null; then
        echo "TAGS: OK"
        tags_ok=true
    else
        echo "TAGS: ERROR"
        echo "Diferencias:"
        diff -u <(echo "$tags_gitlab") <(echo "$tags_github")
        tags_ok=false
    fi

    # ---------------------------------------------------------
    # VALIDAR HISTORIAL DE COMMITS
    # ---------------------------------------------------------

    echo ""
    echo "[6] VALIDANDO HISTORIAL DE COMMITS..."

    commits_gitlab=$(git --git-dir=gitlab.git rev-list --all | sort)
    commits_github=$(git --git-dir=github.git rev-list --all | sort)

    if diff -u <(echo "$commits_gitlab") <(echo "$commits_github") >/dev/null; then
        echo "HISTORIAL DE COMMITS: OK"
        commits_ok=true
    else
        echo "HISTORIAL DE COMMITS: ERROR"
        commits_ok=false

        echo "Commits que no coinciden:"
        diff -u <(echo "$commits_gitlab") <(echo "$commits_github") | head -100
    fi

    # ---------------------------------------------------------
    # VALIDAR CONTENIDO / ESTRUCTURA
    # ---------------------------------------------------------

    echo ""
    echo "[7] VALIDANDO CONTENIDO DEL REPOSITORIO..."

    contenido_gitlab=$(mktemp)
    contenido_github=$(mktemp)

    git --git-dir=gitlab.git ls-tree -r --full-tree HEAD \
        2>/dev/null |
        awk '{$1=""; $2=""; sub(/^  /,""); print}' |
        sort > "$contenido_gitlab"

    git --git-dir=github.git ls-tree -r --full-tree HEAD \
        2>/dev/null |
        awk '{$1=""; $2=""; sub(/^  /,""); print}' |
        sort > "$contenido_github"

    if diff -u "$contenido_gitlab" "$contenido_github" >/dev/null; then
        echo "CONTENIDO / ESTRUCTURA: OK"
        contenido_ok=true
    else
        echo "CONTENIDO / ESTRUCTURA: ERROR"
        echo "Diferencias encontradas:"
        diff -u "$contenido_gitlab" "$contenido_github" | head -100
        contenido_ok=false
    fi

    rm -f "$contenido_gitlab" "$contenido_github"

    # ---------------------------------------------------------
    # VALIDAR INTEGRIDAD COMPLETA DE LOS OBJETOS GIT
    # ---------------------------------------------------------

    echo ""
    echo "[8] VALIDANDO INTEGRIDAD DE OBJETOS GIT..."

    objetos_gitlab=$(git --git-dir=gitlab.git rev-list --objects --all | sort)
    objetos_github=$(git --git-dir=github.git rev-list --objects --all | sort)

    if diff -u <(echo "$objetos_gitlab") <(echo "$objetos_github") >/dev/null; then
        echo "OBJETOS GIT: OK"
        objetos_ok=true
    else
        echo "OBJETOS GIT: ERROR"
        objetos_ok=false
    fi

    # ---------------------------------------------------------
    # RESULTADO DEL REPOSITORIO
    # ---------------------------------------------------------

    repositorios_evaluados=$((repositorios_evaluados + 1))

    if [ "$branches_ok" = true ] &&
       [ "$tags_ok" = true ] &&
       [ "$commits_ok" = true ] &&
       [ "$contenido_ok" = true ] &&
       [ "$objetos_ok" = true ]; then

        echo ""
        echo "RESULTADO: OK"
        repositorios_correctos=$((repositorios_correctos + 1))

    else

        echo ""
        echo "RESULTADO: ERROR"
        repositorios_error=$((repositorios_error + 1))

    fi

    rm -rf gitlab.git github.git

done

cd "$ruta_inicial" || exit 1

echo ""
echo "========================================"
echo "RESUMEN DE VALIDACION"
echo "========================================"

echo "Repositorios evaluados : $repositorios_evaluados"
echo "Repositorios correctos : $repositorios_correctos"
echo "Repositorios con error : $repositorios_error"

echo "========================================"

if [ "$repositorios_evaluados" -eq 0 ]; then
    echo "RESULTADO FINAL: ERROR"
    echo "No se pudo validar ningún repositorio."
    exit 1
fi

if [ "$repositorios_error" -eq 0 ]; then
    echo "RESULTADO FINAL: VALIDACION EXITOSA"
    exit 0
else
    echo "RESULTADO FINAL: VALIDACION CON ERRORES"
    exit 1
fi
