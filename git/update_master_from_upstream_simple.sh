#!/bin/sh

# this script tries to be posix compliant, so no bash'isms

# function declarations
puts() {
	echo "[*]  $1"
}

echo
git checkout master # just to be safe
# we're going to use the https version here because ssh is blocked where I work
upstream='https://github.com/rapid7/metasploit-framework.git'
#upstream='git://github.com/rapid7/metasploit-framework.git'
if [ -z "$(git remote -v | grep $upstream)" ]; then
	# add the rapid7 repo as a remote branch and call it "upstream"
	puts "Did not find upstream branch, so adding it..."
	git remote add upstream
fi
puts "Downloading updates..."
git fetch upstream # download objects from upstream's master to holding area (.git/FETCH_HEAD)
puts "Rebasing your local master branch with downloaded updates..."
git rebase upstream/master # rebase against your local master (you better be on your master branch?)
puts "Done."
echo
