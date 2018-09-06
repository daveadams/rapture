# This software is public domain. No rights are reserved. See LICENSE for more information.

if [ -z "$BASH_VERSION" ]; then
    echo
    echo "ERROR: Rapture only works with Bash. You seem to be running a different shell." >&2
    echo
    return
fi

if (( ${BASH_VERSION:0:1} < 4 )); then
    echo
    echo "ERROR: Rapture requires Bash 4, but you are using $BASH_VERSION." >&2
    echo "  If you are on a Mac: http://clubmate.fi/upgrade-to-bash-4-in-mac-os-x/" >&2
    echo
    return
fi

declare -gA _rapture
declare -ga _rapture_creds_stack
declare -ga _rapture_arn_stack
declare -ga _rapture_failures
declare -gA _rapture_alias
declare -gA _rapture_account
declare -gA _rapture_alias_r
declare -gA _rapture_account_r

_rapture_quiet() { [[ ${_rapture[quiet]} == true ]]; }

# 'say' goes to stdout and can be quieted
_rapture_say() { _rapture_quiet || echo "rapture: $@"; }

# 'msg' goes to stderr but can be quieted
_rapture_msg() { _rapture_quiet || echo "rapture: $@" >&2; }

# 'err' goes to stderr and ignores the quiet setting and explains the failure
_rapture_err() { echo "rapture: ERROR: $@" >&2; _rapture_explain_failure; }

# save a stack of failure reasons for later explanation
_rapture_failed_because() { _rapture_failures[${#_rapture_failures[@]}]="$1"; }

# explain the reason for a failure, if possible, and clear the failure stack
_rapture_explain_failure() {
    local i=${#_rapture_failures[@]}
    while (( i > 0 )); do
        (( i-- ))
        echo "rapture:  * ${_rapture_failures[${i}]}" >&2
    done
    _rapture_failures=()
}

_rapture_load_config() {
    _rapture[VERSION]=1.2.0
    _rapture[srcdir]=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
    _rapture[rootdir]="${RAPTURE_ROOT:-${_rapture[srcdir]}}"
    _rapture[sp]="${_rapture[sp]:-0}"
    _rapture[stashed_env]=false

    ######################################################################
    # config.json
    _rapture[config]="${_rapture[rootdir]}/config.json"

    # if config file does not exist, create an empty one
    if [[ ! -f ${_rapture[config]} ]]; then
        if ! echo "{}" > "${_rapture[config]}"; then
            _rapture_err "Could not initialize ${_rapture[config]}"
            return 1
        fi
    fi

    # read config.json with defaults
    read _rapture[region] \
         _rapture[quiet] \
         _rapture[identifier] \
         _rapture[session_duration] \
    <<< "$( jq -r '[
              (.region//"us-east-1"),
              ((.quiet//false)|tostring),
              ((.identifier//"'"$USER"'")|tostring),
              ((.session_duration//3600)|tostring)
            ]|join(" ")' "${_rapture[config]}" )"

    _rapture[managed_vars]="AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN RAPTURE_ROLE RAPTURE_ASSUMED_ROLE_ARN"
    _rapture[aws_cli_args]="--region ${_rapture[region]} --output json"

    ######################################################################
    # accounts.json
    _rapture[accounts]="${_rapture[rootdir]}/accounts.json"
    if [[ ! -f ${_rapture[accounts]} ]]; then
        if ! echo "{}" > "${_rapture[accounts]}"; then
            _rapture_err "Could not initialize ${_rapture[accounts]}"
            return 1
        fi
    fi

    local key val
    while read key val; do
        _rapture_account[$key]="$val"
        _rapture_account_r[$val]="$key"
    done < <( jq -r 'to_entries[]|.key + " " + .value' "${_rapture[accounts]}" )

    ######################################################################
    # aliases.json
    _rapture[aliases]="${_rapture[rootdir]}/aliases.json"
    if [[ ! -f ${_rapture[aliases]} ]]; then
        if ! echo "{}" > "${_rapture[aliases]}"; then
            _rapture_err "Could not initialize ${_rapture[aliases]}"
            return 1
        fi
    fi

    while read key val; do
        _rapture_alias[$key]="$val"
        _rapture_alias_r[$val]="$key"
    done < <( jq -r 'to_entries[]|.key + " " + .value' "${_rapture[aliases]}" )
}
_rapture_load_config

_rapture_api_sts_get_caller_identity() {
    if ! _rapture_check_env; then
        _rapture_failed_because "No AWS credential environment variables were found"
        return 1
    fi

    local api_out=$(
        aws sts get-caller-identity \
            ${_rapture[aws_cli_args]} \
            2>&1
    )

    unset _rapture[caller_account]
    unset _rapture[caller_userid]
    unset _rapture[caller_arn]

    # check that the return value is not empty
    if [[ -z $api_out ]]; then
        _rapture_failed_because "Call to sts:GetCallerIdentity gave no output"
        return 1
    fi

    # check that the output is valid json
    if ! jq . <<< "$api_out" &>/dev/null; then
        _rapture_failed_because "Call to sts:GetCallerIdentity failed with:\n${api_out}"
        return 1
    fi

    # parse the output into _rapture vars
    read _rapture[caller_account] \
         _rapture[caller_userid] \
         _rapture[caller_arn] \
         <<< "$( jq -r '[.Account,.UserId,.Arn]|join(" ")' <<< "$api_out" )"
    return 0
}

_rapture_api_sts_assume_role() {
    _rapture[sts_assume_role_out]=$(
        aws sts assume-role \
            --role-arn "${_rapture[assume_role_arn]}" \
            --role-session-name "rapture-${_rapture[identifier]}" \
            --duration-seconds "${_rapture[session_duration]}" \
            ${_rapture[aws_cli_args]} \
            2>/dev/null
    )

    if [[ -n ${_rapture[sts_assume_role_out]} ]]; then
        read _rapture[assumed_identity] \
             _rapture[assumed_key_id] \
             _rapture[assumed_secret] \
             _rapture[assumed_token] \
             _rapture[assumed_expiration] \
             <<< "$(
                 jq -r '
                     [
                     .AssumedRoleUser.Arn,
                     .Credentials.AccessKeyId,
                     .Credentials.SecretAccessKey,
                     .Credentials.SessionToken,
                     .Credentials.Expiration
                     ]|join(" ")
                 ' <<< "${_rapture[sts_assume_role_out]}"
                 )"
        return 0
    else
        unset _rapture[sts_assume_role_out]
        unset _rapture[assumed_identity]
        unset _rapture[assumed_key_id]
        unset _rapture[assumed_secret]
        unset _rapture[assumed_token]
        unset _rapture[assumed_expiration]
        return 1
    fi
}

_rapture_parse_identity() {
    unset _rapture[identity_arn]
    unset _rapture[identity_id]
    unset _rapture[identity_type]
    unset _rapture[identity_name]
    unset _rapture[identity_account]

    _rapture_api_sts_get_caller_identity || return 1

    _rapture[identity_arn]="${_rapture[caller_arn]}"

    IFS=: read _rapture[identity_account] _rapture[identity_id] \
        <<< "$( cut -d: -f5- <<< "${_rapture[identity_arn]}" )"
    _rapture[identity_type]=$( cut -d/ -f1 <<< "${_rapture[identity_id]}" )
    case ${_rapture[identity_type]} in
        user)
            _rapture[identity_name]=$( basename "${_rapture[identity_id]}" )
            ;;

        assumed-role)
            _rapture[identity_name]=$( cut -d / -f2 <<< "${_rapture[identity_id]}" )
            ;;

        *)
            _rapture[identity_name]="${_rapture[identity_id]}"
            ;;
    esac
}

_rapture_clear_env() {
    local var
    for var in ${_rapture[managed_vars]}; do
        eval "unset ${var}"
    done
}

_rapture_stash_env() {
    local var
    for var in ${_rapture[managed_vars]}; do
        _rapture[env_${var}]=$( eval "echo \"\$${var}\"" | sed 's/"/\\"/g' )
    done
    _rapture[stashed_env]=true
}

_rapture_env_stashed() { [[ ${_rapture[stashed_env]} == true ]]; }

_rapture_check_stash() {
    if ! _rapture_env_stashed; then
        _rapture_stash_env
    fi

    local var
    for var in ${_rapture[managed_vars]}; do
        if [[ ${_rapture[env_${var}]} != $( eval "echo \"\$${var}\"" ) ]]; then
            return 1
        fi
    done

    return 0
}

_rapture_check_env() {
    [[ -n $AWS_ACCESS_KEY_ID ]] && [[ -n $AWS_SECRET_ACCESS_KEY ]] || return 1
}

_rapture_push() {
    # make sure current identity is cached before we push anything
    if ! _rapture_parse_identity; then
        _rapture_failed_because "Rapture was unable to parse the current identity"
        return 1
    fi

    if [[ -z ${_rapture[identity_arn]} ]]; then
        _rapture_failed_because "No identity ARN was set"
        return 1
    fi

    local encoded=$(
        for var in ${_rapture[managed_vars]}; do
            val=$( eval "echo \"\$${var}\"" | sed 's/"/\\"/g' )
            echo "export ${var}=\"${val}\""
        done
    )
    _rapture_creds_stack[${_rapture[sp]}]="$encoded"
    _rapture_arn_stack[${_rapture[sp]}]="${_rapture[identity_arn]}"
    (( _rapture[sp]++ ))
    _rapture_clear_env
}

_rapture_pop() {
    (( _rapture[sp] > 0 )) || return 1

    (( _rapture[sp]-- ))
    local encoded="${_rapture_creds_stack[${_rapture[sp]}]}"
    unset _rapture_creds_stack[${_rapture[sp]}]
    unset _rapture_arn_stack[${_rapture[sp]}]

    eval "$encoded"
}

_rapture_drop_assumed_identity() {
    _rapture_pop || return 1

    _rapture_stash_env
    _rapture_parse_identity
}

_rapture_use_assumed_identity() {
    _rapture_push
    export AWS_ACCESS_KEY_ID="${_rapture[assumed_key_id]}"
    export AWS_SECRET_ACCESS_KEY="${_rapture[assumed_secret]}"
    export AWS_SESSION_TOKEN="${_rapture[assumed_token]}"
    export AWS_SECURITY_TOKEN="${_rapture[assumed_token]}"
    export RAPTURE_ROLE="${_rapture[role_or_alias_to_assume]}"
    export RAPTURE_ASSUMED_ROLE_ARN="${_rapture[assume_role_arn]}"

    _rapture_stash_env
    _rapture_parse_identity
}

_rapture_require_env() {
    if ! _rapture_check_env; then
        _rapture_err "No AWS credentials found in environment variables"
        return 1
    fi

    if ! _rapture_check_stash; then
        _rapture_failed_because "AWS or rapture environment variables were changed outside of rapture."
        _rapture_err "Rapture cannot safely operate."
        return 1
    fi
}

_rapture_print_usage() {
    cat >&2 <<USAGE
Usage: rapture <command> [<args> ...]

Commands:

  whoami
    prints the IAM ARN of the currently active identity

  assume <role>
    attempts to assume the role given (either an ARN or an alias)

  resume
    reverts to the prior credentials

  alias
    manages ARN aliases

  account
    manages account aliases

  init <vault-name>
    re-initializes environment from Vaulted vault <vault-name>

  version
    prints the current version

USAGE
    return 1
}


_rapture_cmd_whoami() {
    _rapture_require_env || return 1
    if ! _rapture_parse_identity; then
        _rapture_err "no current identity"
        return 1
    fi
    echo "${_rapture[identity_arn]}"
}

_rapture_cmd_reload() {
    source ~/.rapture/rapture.sh
}

_rapture_friendly_description_of_current_principal() {
    local account_name=${_rapture_account_r[${_rapture[identity_account]:--}]}
    local alias_name=${_rapture_alias_r[${RAPTURE_ASSUMED_ROLE_ARN:--}]}

    local friendly_account
    if [[ -n $account_name ]]; then
        friendly_account="'$account_name'"
    else
        friendly_account="${_rapture[identity_account]}"
    fi

    local friendly_description="${_rapture[identity_type]} ${_rapture[identity_name]} in account ${friendly_account}"
    if [[ -n $alias_name ]]; then
        echo "'$alias_name' ($friendly_description)"
    else
        echo "$friendly_description"
    fi
}

_rapture_cmd_assume() {
    _rapture_require_env || return 1
    if [[ -n ${_rapture_alias[$1]} ]]; then
        _rapture[assume_role_arn]="${_rapture_alias[$1]}"
    else
        _rapture[assume_role_arn]="$1"
    fi
    _rapture[role_or_alias_to_assume]="$1"

    if ! _rapture_api_sts_assume_role \
        || ! _rapture_use_assumed_identity; then
        _rapture_err "Could not assume role"
        return 1
    fi
    _rapture_msg "Assumed $( _rapture_friendly_description_of_current_principal )"
}

_rapture_cmd_resume() {
    _rapture_require_env || return 1
    if ! _rapture_drop_assumed_identity; then
        _rapture_err "Could not resume previous identity"
        return 1
    fi
    _rapture_msg "Resumed $( _rapture_friendly_description_of_current_principal )"
}

_rapture_cmd_stack() {
    _rapture_require_env || return 1

    # take care with the current identity
    if [[ -z ${_rapture[identity_arn]} ]]; then
        if ! _rapture_parse_identity; then
            _rapture_err "no current identity"
            return 1
        fi
    fi
    echo "${_rapture[identity_arn]}"

    # for parent identities, just print out the arn stack
    local i
    for i in $( seq $(( ${_rapture[sp]} - 1 )) -1 0 ); do
        echo "${_rapture_arn_stack[$i]}"
    done
}

_rapture_print_account() {
    if [[ -z ${_rapture_account[$1]} ]]; then
        _rapture_err "account '$1' is not defined"
        return 1
    fi
    echo "${_rapture_account[$1]}"
}

_rapture_save_accounts() {
    local key
    for key in "${!_rapture_account[@]}"; do
        echo -n "{\"key\":\"$( sed 's/"/\\"/g' <<< "$key" )\","
        echo "\"value\":\"$( sed 's/"/\\"/g' <<< "${_rapture_account[$key]}" )\"}"
    done \
    | jq -s from_entries \
    > "${_rapture[accounts]}"
}

_rapture_cmd_account_ls() {
    local key
    for key in "${!_rapture_account[@]}"; do
        echo "$key ${_rapture_account[$key]}"
    done |column -t
}

_rapture_cmd_account_add() {
    if [[ -n ${_rapture_account[$1]} ]]; then
        _rapture_err "account '$1' is already defined"
        return 1
    fi
    _rapture_cmd_account_set "$@"
}

_rapture_cmd_account_set() {
    _rapture_account[$1]="$2"
    _rapture_account_r[$2]="$1"
    _rapture_save_accounts
    _rapture_msg "account '$1' was set to '$2'"
}

_rapture_cmd_account_rm() {
    if [[ -z ${_rapture_account[$1]} ]]; then
        _rapture_err "account '$1' is not defined"
        return 1
    fi
    unset _rapture_account_r[${_rapture_account[$1]}]
    unset _rapture_account[$1]
    _rapture_save_accounts
    _rapture_msg "account '$1' has been removed"
}

_rapture_cmd_account() {
    if [[ -z $1 ]]; then
        cat >&2 <<USAGE
Usage: rapture account <command> [<args> ... ]

Commands:

  ls
    lists all currently defined accounts

  set <account> <id>
    creates or updates an account named <account> for the value <id>

  rm <account>
    removes the account <account>

  <account>
    prints the value of <id> for alias <account>

USAGE

        return 1
    fi

    local subcmd="$1"
    shift
    case $subcmd in
        ls|add|set|rm)
            eval "_rapture_cmd_account_${subcmd} \"\$@\""
            ;;

        *)
            _rapture_print_account "$subcmd"
            ;;
    esac
}

_rapture_print_alias() {
    if [[ -z ${_rapture_alias[$1]} ]]; then
        _rapture_err "alias '$1' is not defined"
        return 1
    fi
    echo "${_rapture_alias[$1]}"
}

_rapture_save_aliases() {
    local key
    for key in "${!_rapture_alias[@]}"; do
        echo -n "{\"key\":\"$( sed 's/"/\\"/g' <<< "$key" )\","
        echo "\"value\":\"$( sed 's/"/\\"/g' <<< "${_rapture_alias[$key]}" )\"}"
    done \
    | jq -s from_entries \
    > "${_rapture[aliases]}"
}

_rapture_cmd_alias_ls() {
    local key
    for key in "${!_rapture_alias[@]}"; do
        echo "$key ${_rapture_alias[$key]}"
    done |column -t
}

_rapture_cmd_alias_add() {
    if [[ -n ${_rapture_alias[$1]} ]]; then
        _rapture_err "alias '$1' is already defined"
        return 1
    fi
    _rapture_cmd_alias_set "$@"
}

_rapture_cmd_alias_set() {
    _rapture_alias[$1]="$2"
    _rapture_alias_r[$2]="$1"
    _rapture_save_aliases
    _rapture_msg "alias '$1' was set to '$2'"
}

_rapture_cmd_alias_rm() {
    if [[ -z ${_rapture_alias[$1]} ]]; then
        _rapture_err "alias '$1' is not defined"
        return 1
    fi
    unset _rapture_alias_r[${_rapture_alias[$1]}]
    unset _rapture_alias[$1]
    _rapture_save_aliases
    _rapture_msg "alias '$1' has been removed"
}

_rapture_cmd_alias() {
    if [[ -z $1 ]]; then
        cat >&2 <<USAGE
Usage: rapture alias <command> [<args> ... ]

Commands:

  ls
    lists all currently defined aliases

  set <alias> <arn>
    creates or updates an alias named <alias> for the value <arn>

  rm <alias>
    removes the alias <alias>

  <alias>
    prints the value of <arn> for alias <alias>

USAGE
        return 1
    fi

    local subcmd="$1"
    shift
    case $subcmd in
        ls|add|set|rm)
            eval "_rapture_cmd_alias_${subcmd} \"\$@\""
            ;;

        *)
            _rapture_print_alias "$subcmd"
            ;;
    esac
}

_rapture_cmd_info() {
    _rapture_cmd_version
    echo
    echo "Rapture root directory: ${_rapture[rootdir]}"
    echo "Rapture configuration: ${_rapture[config]}"
    echo
    echo "Stack pointer: ${_rapture[sp]}"
}

_rapture_cmd_version() {
    echo "Rapture ${_rapture[VERSION]}"
}

_rapture_cmd_init() {
    if ! which vaulted &>/dev/null; then
        _rapture_err "'vaulted' was not found in your path. Install it with 'go get github.com/miquella/vaulted'."
    fi

    echo "Initializing vaulted env '$1':"
    eval "$( vaulted env "$1" )"
    unset RAPTURE_ROLE RAPTURE_ASSUMED_ROLE_ARN
    _rapture[sp]=0
    _rapture_load_config
    _rapture_cmd_whoami
}

rapture() {
    local cmd="$1"
    shift
    case $cmd in
        init|whoami|assume|resume|reload|info|stack|account|alias|version)
            eval "_rapture_cmd_${cmd} \"\$@\""
            ;;

        *)
            _rapture_print_usage
            ;;
    esac
}
