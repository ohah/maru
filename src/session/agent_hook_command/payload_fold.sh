# Embedded into the inline hook; never installed or executed as a separate script.
# Split quotes/backslashes with shell word splitting, with globbing disabled. This
# avoids quadratic prefix removal on the large string that triggered the fold.
# Validate container grammar and escapes before retaining only root metadata.
mh_budget() { mh_fuel=$((mh_fuel - 1)); [ "$mh_fuel" -ge 0 ]; };
mh_top() { mh_state=${mh_states%"${mh_states#?}"}; };
mh_state_set() { mh_states="$1${mh_states#?}"; };
mh_capture() {
    case "$mh_rootkey" in
        hook_event_name)
            [ "$1" = string ] && [ "$mh_small" -eq 1 ] || return 1; mh_ev=$mh_text ;;
        session_id|turn_id|prompt_id|agent_id|tool_name|tool_use_id|notification_type)
            case "$1" in
                string)
                    [ "$mh_small" -eq 1 ] || return 1;
                    if [ "$mh_rootkey" = tool_use_id ]; then
                        case "$mh_text" in *[!__TOOL_USE_ID_CLASS__]*) return 0 ;; esac;
                        [ -n "$mh_text" ] || return 0;
                    fi;
                    mh_meta="$mh_meta,\"$mh_rootkey\":\"$mh_text\"" ;;
                null) mh_meta="$mh_meta,\"$mh_rootkey\":null" ;;
                *) return 1 ;;
            esac ;;
        stop_hook_active)
            case "$1" in boolean|null) mh_meta="$mh_meta,\"$mh_rootkey\":$mh_text" ;; *) return 1 ;; esac ;;
        tool_input) mh_meta="$mh_meta,\"tool_input\":null" ;;
    esac;
};
mh_accept_value() {
    mh_top;
    case "$mh_state" in
        R) [ "$1" = object ] || return 1; mh_state_set E ;;
        v) if [ "${#mh_states}" -eq 2 ]; then mh_capture "$1" || return 1; fi; mh_state_set c ;;
        a|V) mh_state_set d ;;
        *) return 1 ;;
    esac;
};
mh_accept_string() {
    mh_top;
    case "$mh_state" in
        k|K)
            if [ "${#mh_states}" -eq 2 ]; then
                mh_rootkey=$mh_text;
                case "$mh_rootkey" in
                    hook_event_name|session_id|turn_id|prompt_id|agent_id|tool_name|tool_use_id|notification_type|stop_hook_active|tool_input)
                        case "$mh_seen" in *"|$mh_rootkey|"*) return 1 ;; esac; mh_seen="$mh_seen$mh_rootkey|" ;;
                esac;
            fi; mh_state_set ':' ;;
        *) mh_accept_value string || return 1 ;;
    esac;
};
mh_number() {
    mh_num=${mh_j%%[!0123456789eE+.-]*};
    [ -n "$mh_num" ] && [ "${#mh_num}" -le "$mh_limit" ] || return 1;
    mh_j=${mh_j#"$mh_num"}; mh_digits=$mh_num;
    case "$mh_digits" in -*) mh_digits=${mh_digits#?} ;; esac;
    case "$mh_digits" in
        0*) mh_digits=${mh_digits#?} ;;
        [123456789]*) mh_run=${mh_digits%%[!0123456789]*}; mh_digits=${mh_digits#"$mh_run"} ;;
        *) return 1 ;;
    esac;
    case "$mh_digits" in .*) mh_digits=${mh_digits#?}; mh_run=${mh_digits%%[!0123456789]*}; [ -n "$mh_run" ] || return 1; mh_digits=${mh_digits#"$mh_run"} ;; esac;
    case "$mh_digits" in e*|E*)
        mh_digits=${mh_digits#?}; case "$mh_digits" in +*|-*) mh_digits=${mh_digits#?} ;; esac;
        mh_run=${mh_digits%%[!0123456789]*}; [ -n "$mh_run" ] || return 1; mh_digits=${mh_digits#"$mh_run"} ;;
    esac;
    [ -z "$mh_digits" ];
};
mh_raw_tokens() {
    mh_j=$1;
    while [ -n "$mh_j" ]; do
        mh_budget || return 1; mh_top;
        case "$mh_j" in
            ' '*|"$mh_tab"*|"$mh_cr"*) mh_j=${mh_j#?} ;;
            '{'*) mh_accept_value object || return 1; mh_states="k$mh_states"; mh_j=${mh_j#?} ;;
            '['*) mh_accept_value array || return 1; mh_states="a$mh_states"; mh_j=${mh_j#?} ;;
            '}'*) case "$mh_state" in k|c) mh_states=${mh_states#?} ;; *) return 1 ;; esac; mh_j=${mh_j#?} ;;
            ']'*) case "$mh_state" in a|d) mh_states=${mh_states#?} ;; *) return 1 ;; esac; mh_j=${mh_j#?} ;;
            ':'*) [ "$mh_state" = ':' ] || return 1; mh_state_set v; mh_j=${mh_j#?} ;;
            ','*) case "$mh_state" in c) mh_state_set K ;; d) mh_state_set V ;; *) return 1 ;; esac; mh_j=${mh_j#?} ;;
            true*) mh_text=true; mh_accept_value boolean || return 1; mh_j=${mh_j#true} ;;
            false*) mh_text=false; mh_accept_value boolean || return 1; mh_j=${mh_j#false} ;;
            null*) mh_text=null; mh_accept_value null || return 1; mh_j=${mh_j#null} ;;
            *) mh_number && mh_accept_value number || return 1 ;;
        esac;
        [ "${#mh_states}" -le 33 ] || return 1;
    done;
};
mh_string_piece() {
    case "$1" in *[[:cntrl:]]*) return 1 ;; esac;
    mh_end_slash=0; case "$1" in *'\') mh_end_slash=1 ;; esac;
    mh_piece=$1; mh_empty_run=0; mh_has_text=0;
    if [ "$mh_small" -eq 1 ]; then
        if [ $(( ${#mh_text} + ${#1} )) -le "$mh_limit" ]; then mh_text="$mh_text$1"; else mh_small=0; mh_text=""; fi;
    fi;
    mh_string_ifs=$IFS; IFS='\'; set -- $mh_piece; IFS=$mh_string_ifs; [ "$#" -le "$mh_fuel" ] || return 1; mh_escape=0;
    for mh_fragment do
        mh_fuel=$((mh_fuel - 1)); [ "$mh_fuel" -ge 0 ] || return 1;
        if [ -n "$mh_fragment" ]; then mh_empty_run=0; mh_has_text=1; else mh_empty_run=$((mh_empty_run + 1)); fi;
        if [ "$mh_escape" -eq 1 ]; then
            case "$mh_fragment" in
                '') mh_escape=0; continue ;;
                '"'*|/*|b*|f*|n*|r*|t*) : ;;
                u[0123456789abcdefABCDEF][0123456789abcdefABCDEF][0123456789abcdefABCDEF][0123456789abcdefABCDEF]*) : ;;
                *) return 1 ;;
            esac;
        fi;
        mh_escape=1;
    done;
    mh_odd=0;
    if [ "$mh_end_slash" -eq 1 ]; then mh_odd=$(( (mh_empty_run + mh_has_text) % 2 )); fi;
    if [ "$mh_odd" -eq 1 ] && [ "$mh_small" -eq 1 ]; then if [ "${#mh_text}" -lt "$mh_limit" ]; then mh_text="$mh_text\""; else mh_small=0; mh_text=""; fi; fi;
};
mh_project() {
    mh_fuel=2048; mh_states=R; mh_meta=""; mh_seen='|'; mh_ev=""; mh_rootkey="";
    mh_saved_ifs=$IFS; IFS='"'; set -f; set -- $mh_raw; IFS=$mh_saved_ifs; [ "$#" -le "$mh_fuel" ] || return 1; mh_mode=raw;
    while [ "$#" -gt 0 ]; do
        mh_part=$1; shift; mh_fuel=$((mh_fuel - 1)); [ "$mh_fuel" -ge 0 ] || return 1;
        if [ "$mh_mode" = raw ]; then
            mh_raw_tokens "$mh_part" || return 1; mh_mode=string; mh_text=""; mh_small=1;
        else
            mh_string_piece "$mh_part" || return 1;
            if [ "$mh_odd" -eq 0 ]; then mh_accept_string || return 1; mh_mode=raw; fi;
        fi;
    done;
    [ "$mh_states" = E ] && [ "$mh_mode" = string ];
};
