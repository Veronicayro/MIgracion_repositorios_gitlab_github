#!/bin/bash

clear

BUSCAR_GITLAB="gitlab.com"
BUSCAR_GITHUB="github.com"

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

TOTAL=0
EXITOSOS=0
ERRORES=0

[ -d "./validacion" ] && rm -rf "./validacion"
mkdir -p "./validacion"

curl --header "PRIVATE-TOKEN: ${TOKEN_GITLAB}" "$URL_GITLAB" |
jq -c '.[] | {name, path, http_url_to_repo}' |
while read -r elemento; do

    TOTAL=$((TOTAL + 1))

    nombre_repo=$(echo "$elemento" | jq -r '.name')
    path_repo=$(echo "$elemento" | jq -r '.path')
    url_repo_gitlab=$(echo "$elemento" | jq -r '.http_url_to_repo')

    echo ""
    echo "========================================"
    echo "REPOSITORIO: $nombre_repo"
    echo "========================================"

    resultado=0

    REEMPLAZAR="oauth2:$TOKEN_GITLAB@gitlab.com"
    url_repo_gitlab=${url_repo_gitlab/${BUSCAR_GITLAB}/${REEMPLAZAR}}

    URL_GITHUB="https://github.com/${OWNER}/${nombre_repo}.git"

    echo "GitLab : $url_repo_gitlab"
    echo "GitHub : $URL_GITHUB"

    [ -d "./validacion/$path_repo.git" ] && rm -rf "./validacion/$path_repo.git"

    echo ""
    echo "[1] OBTENIENDO REPOSITORIO DE GITLAB..."

    git clone --mirror "$url_repo_gitlab" "./validacion/$path_repo.git" >/dev/null 2>&1

    if [ $? -ne 0 ]; then
        echo "ERROR: No se pudo clonar el repositorio de GitLab"
        ERRORES=$((ERRORES + 1))
        continue
    fi

    GITLAB_DIR="./validacion/$path_repo.git"

    REEMPLAZAR="$TOKEN_GITHUB@github.com"
    URL_GITHUB_AUTH=${URL_GITHUB/${BUSCAR_GITHUB}/${REEMPLAZAR}}

    echo ""
    echo "[2] VALIDANDO REPOSITORIO DE GITHUB..."

    git ls-remote "$URL_GITHUB_AUTH" > "./validacion/github_refs.tmp" 2>/dev/null

    if [ $? -ne 0 ]; then
        echo "ERROR: No se pudo acceder al repositorio de GitHub"
        resultado=1
    else

        echo ""
        echo "[3] VALIDANDO BRANCHES..."

        git --git-dir="$GITLAB_DIR" for-each-ref \
            --format='%(objectname) %(refname)' \
            'refs/heads/*' | sort > "./validacion/gitlab_branches.tmp"

        grep 'refs/heads/' "./validacion/github_refs.tmp" |
            sort > "./validacion/github_branches.tmp"

        if diff -w \
            "./validacion/gitlab_branches.tmp" \
            "./validacion/github_branches.tmp" >/dev/null 2>&1; then

            echo "Branches: OK"
        else

            echo "Branches: ERROR"
            echo "Diferencias encontradas:"
            diff -u \
                "./validacion/gitlab_branches.tmp" \
                "./validacion/github_branches.tmp"

            resultado=1
        fi

        echo ""
        echo "[4] VALIDANDO TAGS..."

        git --git-dir="$GITLAB_DIR" for-each-ref \
            --format='%(objectname) %(refname)' \
            'refs/tags/*' | sort > "./validacion/gitlab_tags.tmp"

        grep 'refs/tags/' "./validacion/github_refs.tmp" |
            sort > "./validacion/github_tags.tmp"

        if diff -w \
            "./validacion/gitlab_tags.tmp" \
            "./validacion/github_tags.tmp" >/dev/null 2>&1; then

            echo "Tags: OK"
        else

            echo "Tags: ERROR"
            echo "Diferencias encontradas:"
            diff -u \
                "./validacion/gitlab_tags.tmp" \
                "./validacion/github_tags.tmp"

            resultado=1
        fi

        echo ""
        echo "[5] VALIDANDO HISTORIAL COMPLETO DE COMMITS..."

        git --git-dir="$GITLAB_DIR" rev-list --all --objects |
            sort > "./validacion/gitlab_objects.tmp"

        git --git-dir="$GITLAB_DIR" rev-list --all |
            sort > "./validacion/gitlab_commits.tmp"

        git ls-remote "$URL_GITHUB_AUTH" |
            awk '{print $1}' > "./validacion/github_refs_sha.tmp"

        git clone --mirror "$URL_GITHUB_AUTH" "./validacion/github_temp.git" \
            >/dev/null 2>&1

        if [ $? -ne 0 ]; then

            echo "Historial: ERROR"
            resultado=1

        else

            git --git-dir="./validacion/github_temp.git" rev-list --all |
                sort > "./validacion/github_commits.tmp"

            if diff -w \
                "./validacion/gitlab_commits.tmp" \
                "./validacion/github_commits.tmp" >/dev/null 2>&1; then

                echo "Historial completo: OK"
            else

                echo "Historial completo: ERROR"
                resultado=1
            fi

            rm -rf "./validacion/github_temp.git"
        fi

        echo ""
        echo "[6] VALIDANDO AUTORES Y FECHAS DE COMMITS..."

        git --git-dir="$GITLAB_DIR" rev-list --all |
        while read -r commit; do

            git --git-dir="$GITLAB_DIR" show -s \
                --format='%H|%an|%ae|%aI|%cn|%ce|%cI' "$commit"

        done | sort > "./validacion/gitlab_commit_metadata.tmp"

        git clone --mirror "$URL_GITHUB_AUTH" "./validacion/github_temp.git" \
            >/dev/null 2>&1

        if [ $? -eq 0 ]; then

            git --git-dir="./validacion/github_temp.git" rev-list --all |
            while read -r commit; do

                git --git-dir="./validacion/github_temp.git" show -s \
                    --format='%H|%an|%ae|%aI|%cn|%ce|%cI' "$commit"

            done | sort > "./validacion/github_commit_metadata.tmp"

            if diff -w \
                "./validacion/gitlab_commit_metadata.tmp" \
                "./validacion/github_commit_metadata.tmp" >/dev/null 2>&1; then

                echo "Autores y fechas: OK"
            else

                echo "Autores y fechas: ERROR"
                resultado=1
            fi

            rm -rf "./validacion/github_temp.git"

        else

            echo "Autores y fechas: ERROR"
            resultado=1
        fi
    fi

    if [ "$resultado" -eq 0 ]; then
        echo ""
        echo "RESULTADO: OK"
        EXITOSOS=$((EXITOSOS + 1))
    else
        echo ""
        echo "RESULTADO: ERROR"
        ERRORES=$((ERRORES + 1))
    fi

    rm -f ./validacion/*.tmp
    rm -rf "$GITLAB_DIR"

done

echo ""
echo "========================================"
echo "RESUMEN DE VALIDACION"
echo "========================================"
echo "Repositorios evaluados : $TOTAL"
echo "Repositorios correctos : $EXITOSOS"
echo "Repositorios con error  : $ERRORES"
echo "========================================"

if [ "$ERRORES" -eq 0 ]; then
    echo "RESULTADO FINAL: VALIDACION EXITOSA"
    exit 0
else
    echo "RESULTADO FINAL: VALIDACION CON ERRORES"
    exit 1
fi
