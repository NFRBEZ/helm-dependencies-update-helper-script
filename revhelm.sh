#! /bin/bash

set -eo pipefail

BRANCH=main
FORCE=""
DRY_RUN=false

help()
{
    echo "
revhelm.sh
  Find update for HelmRelease and create Pull Request on repository
    
Options:
    -b (--branch)        The branch from which start update branch
    -f (--force)         Enforce creation of update branch when a closed PR has been found for version
    -d (--dry-run)       Dry-run execution
    -h (--help)          Show help"
    exit 2
}

POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    -b | --branch )
      if [ -z "$2" ]; then
        echo "No value found for option branch"
        help
      else
        BRANCH="$2"
        shift 2
      fi
      ;;
    -f | --force )
      FORCE="True"
      shift
      ;;
    -d | --dry-run )
      DRY_RUN=true
      shift
      ;;
    -h | --help )
      help
      ;;
    --)
      shift;
      break
      ;;
    -*|--*)
      echo "Unexpected option: $1"
      help
      ;;
    * )
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

if [ $# -lt 1 ]; then
    echo "ERROR: You should specify a path of manifest on which lookup for HelmRelease / HelmRepository"
    exit 1
fi

MANIFEST_LOCATION=$1

git checkout $BRANCH >> /dev/null

# Load all repo before looping over manifests
repositories=$(yq ea '[select(.kind == "HelmRepository") | {"name": .metadata.name, "url": .spec.url}]' $MANIFEST_LOCATION/*.yaml)
repositories_count=$(echo "$repositories" | yq '. | length - 1')

# If no HelmRepository found, abort script
if [ $repositories_count -lt 0 ] ; then
  echo "Unable to found any HelmRepository in manifest directory. Aborting"
  exit -1
fi

for index in $(seq 0 $repositories_count); do
  repo_name=$(echo "$repositories" | yq ".$index.name")
  repo_url=$(echo "$repositories" | yq ".$index.url")
  helm repo add $repo_name $repo_url
done

for file in $(find $MANIFEST_LOCATION -name '*.yml' -or -name '*.yaml'); 
do 
    # Load all HelmRelease before looping over them
    releases=$(yq ea '[select(.kind == "HelmRelease" and .spec.chart.spec.sourceRef.kind == "HelmRepository") | {"releaseName": .spec.releaseName, "repoName": .spec.chart.spec.sourceRef.name, "chart": .spec.chart.spec.chart, "version": .spec.chart.spec.version}]' $file)
    releases_count=$(echo "$releases" | yq '. | length - 1')

    if [ $releases_count -lt 0 ] ; then
        echo "Unable to found any releases in manifest directory. Aborting"
    fi

    for index in $(seq 0 $releases_count); do
        release_name=$(echo "$releases" | yq ".$index.releaseName")
        repo_name=$(echo "$releases" | yq ".$index.repoName")
        chart=$(echo "$releases" | yq ".$index.chart")
        version=$(echo "$releases" | yq ".$index.version")

        if [ $(echo "$repositories" | yq ".[] | select(.name == \"$repo_name\").name" | wc -l) -lt 1 ] ; then
            echo "HelmRepository \"$repo_name\" not found in manifest directory. Skipping for release $release_name"
            continue
        fi
    
        # Select latest release of Helm chart
        helm_latest=$(helm search repo -r "\v$repo_name/$chart\v" -l -o yaml | yq e 'map(select(key==0)).0')
        current_version=$(echo "$helm_latest" | yq e '.version')
        current_app_version=$(echo "$helm_latest" | yq e '.app_version')

        # Sanitize the repo name
        sanitized_name=$(echo $repo_name | tr -d ' ' | tr '/' '-')

        # If there's a difference between the versions
        if [ "$version" != "$current_version" ]; then
            echo "Found update for $release_name ($version -> $current_version)"

            # If a PR with this update exist and has been closed, do not recreate it unless script execution enforced it
            if [[ $(gh pr list -H update-helm-$sanitized_name-$current_version -s closed | wc -l) -gt 0 && -z "$FORCE" ]]; then
                echo "Found a closed PR for $release_name ($version -> $current_version). To enforce update, please run revhelm with option -f"
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
                
                # Replace the old version with the new version 
                yq -i "select(.kind == \"HelmRelease\" and .spec.releaseName == \"$release_name\").spec.chart.spec.version = \"$current_version\"" $file
                
                if [ !$DRY_RUN ]; then
                    # Cleaning old branch existing
                    if [ $(git branch -r --list "origin/update-helm-$sanitized_name-*") ]; then
                        echo "There is pending branch for $release_name"
                        for existing_branch in $(git branch -r --list "origin/update-helm-$sanitized_name-*"); 
                        do 
                        echo "Found outdated update branch which propose update to ${existing_branch##*-}, removing it"
                        [[ ${existing_branch##*-} != $current_version ]] && git push -d origin update-helm-$sanitized_name-${existing_branch##*-}
                        done
                    fi

                    # Create a new branch for this change
                    git checkout -b update-helm-$sanitized_name-$current_version
                    git add "$file"
                    git commit -m "Update $release_name version from $version to $current_version"
                    git push origin update-helm-$sanitized_name-$current_version

                    # Create a GitHub Pull Request
                    gh pr create --title "Update $release_name version from $version to $current_version" --body "$pr_body" --base main --head update-helm-$sanitized_name-$current_version || true
                    
                    git checkout $BRANCH
                else
                    echo "Dry run execution. Aborting"
                fi
            else
                echo "Branch already exists. Checking out to the existing branch." || true
            fi
        else
            echo "$release_name is up to date ($version == $current_version)"
        fi
    done
done