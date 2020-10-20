# This software is public domain. No rights are reserved. See LICENSE for more information.
#
# **NOTE**: This version of rapture is no longer supported. I've written a new
# Golang version which adds more features, integrates into more shells, and runs
# much faster. Check it out at https://github.com/daveadams/go-rapture.
#
# The remainder of the README and the code to Rapture itself can be found in the
# commit history.

rapture() {
    cat >&2 <<EOF

** IMPORTANT NOTICE **

This bash version of rapture is no longer supported. A new Golang version which
adds more features, integrates into more shells, and runs much faster can be
found at https://github.com/daveadams/go-rapture

EOF
    return 1
}
