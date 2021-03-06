#!/bin/bash -e

if [ ! -e $3 ]; then
  exit
fi

src_dir="$(readlink -e $1)"
project_fqdn="$2"
patchsets_info_file="$(readlink -e $3)"

git config --get user.name >/dev/null  2>&1 || git config --global user.name "tf-jenkins"
git config --get user.email >/dev/null 2>&1 || git config --global user.email "tf-jenkins@tf"

cd $src_dir/$project_fqdn
for ref in $(cat $patchsets_info_file | jq -r --arg project $project_fqdn '.[] | select(.project == $project) | .ref'); do
  echo "INFO: run 'git fetch $GERRIT_URL/$project_fqdn $ref && git cherry-pick FETCH_HEAD'"
  git fetch $GERRIT_URL/$project_fqdn $ref && git cherry-pick FETCH_HEAD
done
