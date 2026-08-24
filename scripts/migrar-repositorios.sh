#!/bin/bash

clear

#echo "El Token para Gitlab es: $TOKEN_GITLAB"
#echo "El Token para Github es: $TOKEN_GITHUB"
#echo "La organizacion para Github es: $OWNER"

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

echo "URL GITLAB: $ulr_gitlab"
#REVISAR DOCUMENTACIÓN POR SI SE NECESITA FILTROS https://docs.gitlab.com/api/projects/
curl --header "PRIVATE-TOKEN: ${TOKEN_GITLAB}" "$URL_GITLAB" | jq -c '.[] | {name, path, http_url_to_repo, description}' | while read -r elemento; do
    # Extraer campos de cada elemento
    nombre_repo=$(echo "$elemento" | jq -r '.name')
    path_repo=$(echo "$elemento" | jq -r '.path')
    url_repo_gitlab=$(echo "$elemento" | jq -r '.http_url_to_repo')
    description=$(echo "$elemento" | jq -r '.description')

    [ -d "./migracion" ] && rm -rf "./migracion"
    mkdir ./migracion && cd ./migracion

    HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" \
        -H "Authorization: token $TOKEN_GITHUB" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${OWNER}/${nombre_repo}"

    REEMPLAZAR="oauth2:$TOKEN_GITLAB@gitlab.com"
    url_repo_gitlab=${url_repo_gitlab/${BUSCAR_GITLAB}/${REEMPLAZAR}}
    
    if [[ "$HTTP_CODE" == "200" ]]; then
        echo "EL REPOSITORIO EXISTE EN GITHUB Y SE VA A SOBREESCRIBIR"
    else
        echo "EL REPOSITORIO NO EXISTE EN GITHUB Y SE VA CREAR"
        curl -X POST \
            -H "Authorization: token $TOKEN_GITHUB" \
            -H "Accept: application/vnd.github.v3+json" \
            https://api.github.com/orgs/$OWNER/repos \
            -d "{\"name\":\"$nombre_repo\", \"description\":\"$description\", \"private\":true}"

        echo "SE CREO EL REPOSITORIO"
    fi

    echo "BUSQUEDA DE REPOSITORIO"
    url_repo_github=$(curl -H "Authorization: token $TOKEN_GITHUB" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${OWNER}/${nombre_repo}"" | jq -r '.clone_url')

    # 1. Clonar el repo de GitLab como espejo
    git clone --mirror $url_repo_gitlab
    echo "VERIFICANDO CLON DEL REPOSITORIO..."
    git --git-dir="$repositorio.git" rev-parse --is-bare-repository
    echo "REFERENCIAS EN GITLAB:"
    git --git-dir="$repositorio.git" show-ref

    # 2. Entrar en el directorio clonado
    cd "$path_repo.git"
    ls -a

    # 3. Cambiar el remote a GitHub
    REEMPLAZAR="$TOKEN_GITHUB@github.com"
    url_repo_github=${url_repo_github/${BUSCAR_GITHUB}/${REEMPLAZAR}}

    #https://github.com/prmrOrganizacion2/segundo-proyecto    
    #git remote set-url origin https://github.com/user/repo2.git
    echo "EJECUCION DEL REMOTE"
    git remote set-url origin $url_repo_github

    # 4. Hacer push de todo al nuevo destino
    echo "EJECUCION DEL PUSH"
    git push --mirror origin

    cd $ruta_inicial
done
