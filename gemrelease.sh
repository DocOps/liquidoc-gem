#!/bin/sh
# Automates the multi-step release process
# Tags master branch and publishes gem to rubygems.org
# TODO: Publish docs (instigate build/deploy of LDCMF guides)
#
# This script is to be run after the dev branch has been merged to
# the master branch
#
# Usage: ./gemrelease.sh 0.11.0

if [ -z "$1" ] ; then
  echo "Add the release version number: $0 <version>"
  exit 1
fi

version=$1
shift

git checkout master
git pull origin master
rake install
gem push pkg/liquidoc-$version.gem
git tag -a v$version -m "Release $version"
git push origin --tags
echo "✔ Release pushed to RubyGems.org"
echo "Don't forget to manually post the release on GitHub:"
echo "https://github.com/DocOps/liquidoc-gem/releases/new"
exit 0
