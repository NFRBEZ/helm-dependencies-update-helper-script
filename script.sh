#! /bin/bash

set -eo pipefail

BRANCH=main
FORCE=false
MANIFEST_LOCATION=helm

for file in $(find $MANIFEST_LOCATION -name '*.yml' -or -name '*.yaml'); 
do 
    # Name of the dependency
    name=$(yq e 'select(.kind == "HelmRelease" and .spec.chart.spec.sourceRef.kind == "HelmRepository").spec.releaseName' $file)

    # Read Helm dependencies
    helm_repo_ref=$(yq e 'select(.kind == "HelmRelease" and .spec.chart.spec.sourceRef.kind == "HelmRepository").spec.chart.spec.sourceRef.name' $file)
    chart=$(yq e 'select(.kind == "HelmRelease" and .spec.chart.spec.sourceRef.kind == "HelmRepository").spec.chart.spec.chart' $file)
    version=$(yq e 'select(.kind == "HelmRelease" and .spec.chart.spec.sourceRef.kind == "HelmRepository").spec.chart.spec.version' $file)

    repo_name=$(yq e 'select(.kind == "HelmRepository").metadata.name' $file)
    repo_url=$(yq e 'select(.kind == "HelmRepository").spec.url' $file)

    # Select latest release of Helm chart
    helm repo add $repo_name $repo_url
    helm search repo -r "\v$repo_name/$chart\v" -l -o yaml | yq e 'map(select(key==0)).0' > tmp.txt
    current_version=$(yq e '.version' tmp.txt)
    current_app_version=$(echo $helm_latest | yq e '.app_version' tmp.txt)
    rm -rf tmp.txt

    # Sanitize the repo name
    sanitized_name=$(echo $repo_name | tr -d ' ' | tr '/' '-')

    # Output
    echo "Name: $name"
    echo "Version in HelmRelease: $version"
    echo "Current Version: $current_version"

    # If there's a difference between the versions
    if [ "$version" != "$current_version" ]; then
        echo "Found update for $name ($version -> $current_version)"

        # If a PR with this update exist and has been closed, do not recreate it unless script execution enforced it
        if [ $(gh pr list -H update-helm-$sanitized_name-$current_version -s closed |wc -l) -gt 0 && !$FORCE]; then
            echo "Found a closed PR for $name ($version -> $current_version). To enforce update, please run the script with a FORCE flag set to true"
            continue
        fi

        # If there is no existing branch for this version, create the update
        if [ ! $(git branch -r --list origin/update-helm-$sanitized_name-$current_version) ]; then
            # Get new packages values
            helm show values $repo_name/$chart --version $current_version > new_values.yaml
            helm show values $repo_name/$chart --version $version > old_values.yaml
            
            # Perform a diff on the two files
            diff_result=$(dyff between old_values.yaml new_values.yaml) || true

            # Prepare PR
            echo -e "A new chart update has been found!\n\nRecommended image version: **$current_app_version**\n\nPlease **take a deep look onto compatibility matrix** for this app, **ensure the version match the cluster** and **update your values** before merging.\n\n" > pr.txt
            echo "$diff_result" > diff_result.txt
            awk '{ printf "\t%s\n", $0 }' diff_result.txt >> pr.txt
            pr_body=$(cat pr.txt)

            # Delete the temporary files
            rm old_values.yaml new_values.yaml diff_result.txt pr.txt
            
            # Replace the old version with the new version in the Chart.yaml file using sed
            name=$name current_version=$current_version yq -i 'select(.kind == "HelmRelease" and .spec.releaseName == env(name)).spec.chart.spec.version = env(current_version)' $file
            
            # Cleaning old branch existing
            if [ $(git branch -r --list "origin/update-helm-$sanitized_name-*") ]; then
                echo "There is pending branch for $name"
                for existing_branch in $(git branch -r --list "origin/update-helm-$sanitized_name-*"); 
                do 
                echo "Found outdated update branch which propose update to ${existing_branch##*-}, removing it"
                [[ ${existing_branch##*-} != $current_version ]] && git push -d origin update-helm-$sanitized_name-${existing_branch##*-}
                done
            fi

            # Create a new branch for this change
            git checkout -b update-helm-$sanitized_name-$current_version
            git add "$file"
            git commit -m "Update $name version from $version to $current_version"
            git push origin update-helm-$sanitized_name-$current_version

            # Create a GitHub Pull Request
            gh pr create --title "Update $name version from $version to $current_version" --body "$pr_body" --base main --head update-helm-$sanitized_name-$current_version || true
            
            git checkout $BRANCH
        else
            echo "Branch already exists. Checking out to the existing branch." || true
        fi
    else
        echo "$name is up to date ($version == $current_version)"
    fi
done