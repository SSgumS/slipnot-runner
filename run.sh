#!/bin/bash

# Automated cleanup on script exit or interrupt
cleanup() {
    echo ""
    echo "[$(date)] Termination signal received. Cleaning up all processes..."
    trap - SIGINT SIGTERM EXIT
    kill -- -$$ 2>/dev/null
    exit 0
}

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS] {server|client} [resolver1 resolver2 ...]

Commands:
  server    Start the slipstream server manager
  client    Start the slipstream client manager

Options (position-independent):
  -p              Use Plus version
  -d DOMAIN       Domain name (default: p.gum.moe)
  -a TARGET       Target address for server (default: 127.0.0.1:443)
  -ha HOST        Listen host (--dns-listen-host for server, --tcp-listen-host for client)
  -hp PORT        Listen port (--dns-listen-port for server, --tcp-listen-port for client)
                  In multi-client mode, this is the starting port (default: 5201)
  -mc COUNT       Max connections for server (default: 128)
  -t SECONDS      Idle timeout seconds for server (default: 90)
  -c COUNT        Number of client instances to run (client mode only, default: 1)
  -rc COUNT       Resolvers per client in plus mode (default: all resolvers per client)
  -hc URL         Health check URL (default: https://127.0.0.1:$HC_PORT/).
                  In client mode, port is replaced per client automatically.
  -hi SECONDS     Health check interval in client mode (default: 10)
  -ht COUNT       Health check consecutive failure threshold (default: 3)
  -f [FILE]       Load resolvers from FILE (client mode, default if specified: benchmark.txt).
                  Repeatable for multiple files. Priority = order of appearance.
                  Files are re-read every 30 seconds. Replaces CLI/default resolvers.
  -ft COUNT       Total resolver threshold across all files (default: 8)
  -e CODE         Additional curl exit code to treat as success (repeatable, e.g. -e 52 -e 56)
  -nh             Disable active health checks (both server and client modes)
  -h, --help      Show this help message

Examples:
  $0 server
  $0 -d example.com -ha 0.0.0.0 -hp 8853 -mc 64 server
  $0 client 1.1.1.1:53 8.8.8.8:53
  $0 -c 3 client 1.1.1.1:53 8.8.8.8:53
  $0 -p -c 2 -rc 2 client 1.1.1.1:53 8.8.8.8:53 9.9.9.9:53 208.67.222.222:53
  $0 -f -f gum.txt client
  $0 -f benchmark.txt -f backup.txt -ft 12 client
EOF
    exit 0
}

# Configuration
SERVER_BIN="./slipnot-server"
CLIENT_BIN="./slipnot-client"
USE_PLUS_VERSION=false
HC_PORT=5202
HC_TEST_PORT=5203
HC_URL="https://127.0.0.1:$HC_PORT/"
HC_THRESHOLD=3

# Defaults
DOMAIN="p.gum.moe"
TARGET="127.0.0.1:443"
LISTEN_HOST=""
LISTEN_PORT=""
MAX_CONNECTIONS=128
IDLE_TIMEOUT=90
CLIENT_COUNT=1
RESOLVERS_PER_CLIENT=""
HC_INTERVAL=10
COMMAND=""
RESOLVERS=()
RESOLVER_FILES=()
RESOLVER_FILE_THRESHOLD=8
FILE_MODE=false
FILE_MONITOR_INTERVAL=30
HC_SUCCESS_CODES=(0)
NO_HEALTH_CHECK=false

# Position-independent parameter parsing
while [[ "$#" -gt 0 ]]; do
    case $1 in
    -h | --help) show_help ;;
    -p)
        USE_PLUS_VERSION=true
        shift
        ;;
    -d)
        DOMAIN="$2"
        shift 2
        ;;
    -a)
        TARGET="$2"
        shift 2
        ;;
    -ha)
        LISTEN_HOST="$2"
        shift 2
        ;;
    -hp)
        LISTEN_PORT="$2"
        shift 2
        ;;
    -mc)
        MAX_CONNECTIONS="$2"
        shift 2
        ;;
    -t)
        IDLE_TIMEOUT="$2"
        shift 2
        ;;
    -c)
        CLIENT_COUNT="$2"
        shift 2
        ;;
    -rc)
        RESOLVERS_PER_CLIENT="$2"
        shift 2
        ;;
    -hc)
        HC_URL="$2"
        shift 2
        ;;
    -hi)
        HC_INTERVAL="$2"
        shift 2
        ;;
    -ht)
        HC_THRESHOLD="$2"
        shift 2
        ;;
    -ft)
        RESOLVER_FILE_THRESHOLD="$2"
        shift 2
        ;;
    -f)
        FILE_MODE=true
        # Peek at next arg: if missing, a flag, or a command -> use default
        if [[ -z "$2" || "$2" == -* || "$2" == "server" || "$2" == "client" ]]; then
            RESOLVER_FILES+=("benchmark.txt")
            shift
        else
            RESOLVER_FILES+=("$2")
            shift 2
        fi
        ;;
    -e)
        HC_SUCCESS_CODES+=("$2")
        shift 2
        ;;
    -nh)
        NO_HEALTH_CHECK=true
        shift
        ;;
    server | client)
        COMMAND="$1"
        shift
        ;;
    -*)
        echo "Unknown option: $1"
        exit 1
        ;;
    *)
        # Collect resolvers (non-option args after or before command)
        RESOLVERS+=("$1")
        shift
        ;;
    esac
done

if [[ -z "$COMMAND" ]]; then
    echo "Error: Must specify 'server' or 'client' command."
    echo "Use -h or --help for usage information."
    exit 1
fi
if [ "$USE_PLUS_VERSION" = true ]; then
    SERVER_BIN="./slipnotp-server"
    CLIENT_BIN="./slipnotp-client"
fi

trap cleanup SIGINT SIGTERM EXIT

case "$COMMAND" in
server)
    echo "Starting Server Manager (Domain: $DOMAIN, Target: $TARGET)..."
    [[ -n "$LISTEN_HOST" ]] && echo "  Listen Host: $LISTEN_HOST"
    [[ -n "$LISTEN_PORT" ]] && echo "  Listen Port: $LISTEN_PORT"
    echo "  Max Connections: $MAX_CONNECTIONS"
    echo "  Idle Timeout: $IDLE_TIMEOUT"

    build_server_opts() {
        local opts="-a $TARGET -c ./fullchain.pem -k ./privkey.pem -d $DOMAIN"
        opts+=" --idle-timeout-seconds $IDLE_TIMEOUT"
        opts+=" --max-connections $MAX_CONNECTIONS"
        opts+=" --reset-seed ./reset-seed"
        [[ -n "$LISTEN_HOST" ]] && opts+=" --dns-listen-host $LISTEN_HOST"
        [[ -n "$LISTEN_PORT" ]] && opts+=" --dns-listen-port $LISTEN_PORT"
        echo "$opts"
    }

    start_server() {
        $SERVER_BIN $(build_server_opts) &
        SERVER_PID=$!
        echo "[$(date)] Server started (PID: $SERVER_PID)"
        sleep 2
    }

    start_hc_client() {
        >"health_client.log"
        $CLIENT_BIN -c bbr -r 127.0.0.1:53 -d "$DOMAIN" --tcp-listen-port $HC_PORT >"health_client.log" 2>&1 &
        CHECK_PID=$!
        for ((i = 0; i < 10; i++)); do
            sleep 1
            if grep -q "Connection ready" "health_client.log"; then return 0; fi
            ! kill -0 $CHECK_PID 2>/dev/null && break
        done
        kill $CHECK_PID 2>/dev/null
        return 1
    }

    test_client_connection() {
        >"test_client.log"
        $CLIENT_BIN -c bbr -r 127.0.0.1:53 -d "$DOMAIN" --tcp-listen-port $HC_TEST_PORT >"test_client.log" 2>&1 &
        TEST_PID=$!
        for ((i = 0; i < 10; i++)); do
            sleep 1
            if grep -q "Connection ready" "test_client.log"; then
                kill $TEST_PID 2>/dev/null
                return 0
            fi
            ! kill -0 $TEST_PID 2>/dev/null && break
        done
        kill $TEST_PID 2>/dev/null
        return 1
    }

    start_server
    if [ "$NO_HEALTH_CHECK" = true ]; then
        echo "[$(date)] Health checks disabled (-nh), server running without monitoring."
        wait $SERVER_PID
    else
        client_fails=0
        connection_fails=0
        http_cycle=0
        http_fails=0
        while true; do
            if ! kill -0 $CHECK_PID 2>/dev/null; then
                if start_hc_client; then client_fails=0; else
                    ((client_fails++))
                    echo "[$(date)] HC Client start failed ($client_fails/3)"
                    if [ "$client_fails" -ge 3 ]; then
                        kill $SERVER_PID 2>/dev/null
                        wait $SERVER_PID 2>/dev/null
                        start_server
                        client_fails=0
                    fi
                    sleep 10
                    continue
                fi
            fi
            if curl -s -m 5 -k "$HC_URL" >/dev/null; then http_fails=0; else
                ((http_fails++))
                if [ "$http_fails" -ge "$HC_THRESHOLD" ]; then
                    kill $CHECK_PID 2>/dev/null
                    http_fails=0
                fi
            fi
            ((http_cycle++))
            if [ $((http_cycle % 5)) -eq 0 ]; then
                if test_client_connection; then connection_fails=0; else
                    ((connection_fails++))
                    if [ "$connection_fails" -ge 5 ]; then
                        kill $CHECK_PID 2>/dev/null
                        kill $SERVER_PID 2>/dev/null
                        wait $SERVER_PID 2>/dev/null
                        start_server
                        connection_fails=0
                        http_cycle=0
                    fi
                fi
            fi
            sleep 10
        done
    fi
    ;;

client)
    [[ ${#RESOLVERS[@]} -eq 0 ]] && RESOLVERS=("2.188.21.130:53" "8.8.8.8:53")

    # --- File-based resolver loading ---
    # Reads resolvers from RESOLVER_FILES[], distributing RESOLVER_FILE_THRESHOLD
    # across files by priority. Returns results in LOADED_RESOLVERS array.
    # Returns 0 on success (at least 1 resolver), 1 on failure.
    load_resolvers_from_files() {
        LOADED_RESOLVERS=()
        local num_files=${#RESOLVER_FILES[@]}
        local threshold=$RESOLVER_FILE_THRESHOLD

        # Per-file share: integer division, remainder goes to first file
        local base_share=$((threshold / num_files))
        local remainder=$((threshold % num_files))

        # First pass: read each file up to its share
        declare -a file_share     # how many each file should contribute
        declare -a file_collected # how many each file actually contributed
        declare -a file_lines     # all valid unique lines per file (for redistribution)
        local seen=()             # global dedup set

        for ((fi = 0; fi < num_files; fi++)); do
            local share=$base_share
            ((fi < remainder)) && ((share++))
            file_share[$fi]=$share
            file_collected[$fi]=0
            file_lines[$fi]=""

            local fpath="${RESOLVER_FILES[$fi]}"
            if [[ ! -f "$fpath" ]]; then
                echo "[$(date)] WARNING: Resolver file '$fpath' not found, skipping."
                continue
            fi

            # Read all valid unique entries from this file
            local all_entries=()
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -z "$line" || "$line" == \#* ]] && continue
                local addr
                addr=$(echo "$line" | awk '{print $1}')
                [[ -z "$addr" ]] && continue
                # Dedup against global seen set
                local dup=false
                for s in "${seen[@]}"; do
                    [[ "$s" == "$addr" ]] && {
                        dup=true
                        break
                    }
                done
                $dup && continue
                all_entries+=("$addr")
            done <"$fpath"

            # Store all valid entries for redistribution pass
            file_lines[$fi]=$(printf '%s\n' "${all_entries[@]}")

            # Take up to this file's share
            local count=0
            for addr in "${all_entries[@]}"; do
                ((count >= share)) && break
                LOADED_RESOLVERS+=("$addr")
                seen+=("$addr")
                ((count++))
            done
            file_collected[$fi]=$count
        done

        # Redistribution pass: fill shortfall from files that have remaining entries
        local total=${#LOADED_RESOLVERS[@]}
        if ((total < threshold)); then
            local shortfall=$((threshold - total))
            for ((fi = 0; fi < num_files && shortfall > 0; fi++)); do
                [[ -z "${file_lines[$fi]}" ]] && continue
                local collected=${file_collected[$fi]}
                local idx=0
                while IFS= read -r addr; do
                    ((shortfall <= 0)) && break
                    [[ -z "$addr" ]] && continue
                    ((idx++))
                    # Skip entries already taken in first pass
                    ((idx <= collected)) && continue
                    # Dedup check
                    local dup=false
                    for s in "${seen[@]}"; do
                        [[ "$s" == "$addr" ]] && {
                            dup=true
                            break
                        }
                    done
                    $dup && continue
                    LOADED_RESOLVERS+=("$addr")
                    seen+=("$addr")
                    ((shortfall--))
                done <<<"${file_lines[$fi]}"
            done
        fi

        if [[ ${#LOADED_RESOLVERS[@]} -eq 0 ]]; then
            echo "[$(date)] WARNING: No resolvers found in any file."
            return 1
        fi
        echo "[$(date)] Loaded ${#LOADED_RESOLVERS[@]} resolvers from files: ${LOADED_RESOLVERS[*]}"
        return 0
    }

    # Apply file-based resolvers if -f was specified
    if [[ "$FILE_MODE" = true ]]; then
        if load_resolvers_from_files; then
            RESOLVERS=("${LOADED_RESOLVERS[@]}")
        else
            echo "[$(date)] WARNING: Falling back to resolvers: ${RESOLVERS[*]}"
        fi
    fi
    CERT_OPT=""
    [[ -f "./cert.pem" ]] && CERT_OPT="--cert ./cert.pem"

    HOST_OPT=""
    [[ -n "$LISTEN_HOST" ]] && HOST_OPT="--tcp-listen-host $LISTEN_HOST"

    # Default starting port for multi-client mode
    BASE_PORT="${LISTEN_PORT:-5201}"

    NUM_RESOLVERS=${#RESOLVERS[@]}

    # --- Validation & capping ---
    if [ "$USE_PLUS_VERSION" = true ] && [[ -n "$RESOLVERS_PER_CLIENT" ]]; then
        # Plus with -rc: can have at most floor(#resolvers / rc) clients
        max_clients=$((NUM_RESOLVERS / RESOLVERS_PER_CLIENT))
        if ((max_clients == 0)); then
            echo "Error: Not enough resolvers ($NUM_RESOLVERS) for rc=$RESOLVERS_PER_CLIENT"
            exit 1
        fi
        if ((CLIENT_COUNT > max_clients)); then
            echo "Warning: Capping client count from $CLIENT_COUNT to $max_clients (rc=$RESOLVERS_PER_CLIENT, $NUM_RESOLVERS resolvers)"
            CLIENT_COUNT=$max_clients
        fi
    else
        # Non-plus or plus without -rc: cap to number of resolvers
        if ((CLIENT_COUNT > NUM_RESOLVERS)); then
            echo "Warning: Capping client count from $CLIENT_COUNT to $NUM_RESOLVERS (only $NUM_RESOLVERS resolvers)"
            CLIENT_COUNT=$NUM_RESOLVERS
        fi
    fi

    # Single consolidated log file
    LOG_FILE="slipnot_client.log"
    >"$LOG_FILE"

    echo "========================================"
    echo "[$(date)] Starting Client Manager"
    echo "  Domain: $DOMAIN"
    echo "  Resolvers: ${RESOLVERS[*]}"
    echo "  Client count: $CLIENT_COUNT"
    echo "  Plus mode: $USE_PLUS_VERSION"
    [[ -n "$RESOLVERS_PER_CLIENT" ]] && echo "  Resolvers per client (rc): $RESOLVERS_PER_CLIENT"
    if [[ "$FILE_MODE" = true ]]; then
        echo "  File mode: ON (threshold: $RESOLVER_FILE_THRESHOLD, interval: ${FILE_MONITOR_INTERVAL}s)"
        echo "  Monitored files: ${RESOLVER_FILES[*]}"
    fi
    [[ -n "$LISTEN_HOST" ]] && echo "  Listen Host: $LISTEN_HOST"
    echo "  Port range: $BASE_PORT - $((BASE_PORT + CLIENT_COUNT - 1))"
    echo "  Log file: $LOG_FILE"
    echo "========================================"

    # --- Per-client state arrays ---
    declare -a CLIENT_PIDS
    declare -a CLIENT_READY
    declare -a CLIENT_LOG_MARKER
    declare -a CLIENT_HC_FAILS
    # CLIENT_RESOLVERS[i] = space-separated resolver indices assigned to client i
    declare -a CLIENT_RESOLVERS

    # --- Initial resolver assignment ---
    assign_initial_resolvers() {
        if [ "$USE_PLUS_VERSION" = true ]; then
            if [[ -n "$RESOLVERS_PER_CLIENT" ]]; then
                # Plus with -rc: each client gets rc resolvers, sequential blocks
                local rc=$RESOLVERS_PER_CLIENT
                for ((i = 0; i < CLIENT_COUNT; i++)); do
                    local indices=""
                    for ((j = 0; j < rc; j++)); do
                        local idx=$((i * rc + j))
                        indices+="$idx "
                    done
                    CLIENT_RESOLVERS[$i]="${indices% }"
                done
            else
                # Plus without -rc: split all resolvers evenly
                local per_client=$((NUM_RESOLVERS / CLIENT_COUNT))
                local remainder=$((NUM_RESOLVERS % CLIENT_COUNT))
                local offset=0
                for ((i = 0; i < CLIENT_COUNT; i++)); do
                    local count=$per_client
                    ((i < remainder)) && ((count++))
                    local indices=""
                    for ((j = 0; j < count; j++)); do
                        indices+="$((offset + j)) "
                    done
                    CLIENT_RESOLVERS[$i]="${indices% }"
                    offset=$((offset + count))
                done
            fi
        else
            # Non-plus: each client gets 1 resolver
            for ((i = 0; i < CLIENT_COUNT; i++)); do
                CLIENT_RESOLVERS[$i]="$i"
            done
        fi
    }

    assign_initial_resolvers

    # Global monotonic counter: each assignment increments this.
    # RESOLVER_LAST_USED[idx] = counter value when idx was last assigned.
    # Lower value = more stale = should be picked first on rotation.
    ASSIGN_COUNTER=0
    declare -a RESOLVER_LAST_USED
    for ((idx = 0; idx < NUM_RESOLVERS; idx++)); do
        RESOLVER_LAST_USED[$idx]=0
    done
    # Mark initially assigned resolvers as used
    for ((i = 0; i < CLIENT_COUNT; i++)); do
        for idx in ${CLIENT_RESOLVERS[$i]}; do
            ((ASSIGN_COUNTER++))
            RESOLVER_LAST_USED[$idx]=$ASSIGN_COUNTER
        done
    done

    for ((i = 0; i < CLIENT_COUNT; i++)); do
        CLIENT_PIDS[$i]=0
        CLIENT_READY[$i]=false
        CLIENT_LOG_MARKER[$i]=0
        CLIENT_HC_FAILS[$i]=0
    done

    # --- Helper: get all indices assigned to other clients ---
    get_used_indices() {
        local exclude_cid=$1
        local used=""
        for ((c = 0; c < CLIENT_COUNT; c++)); do
            [[ $c -eq $exclude_cid ]] && continue
            used+="${CLIENT_RESOLVERS[$c]} "
        done
        echo "$used"
    }

    # --- Rotation ---
    # Picks resolvers not used by other clients, preferring the ones
    # that were least-recently-assigned (lowest RESOLVER_LAST_USED value).
    # The caller's own old resolvers are deprioritized (sorted to end).
    rotate_client() {
        local cid=$1
        local old_set="${CLIENT_RESOLVERS[$cid]}"

        if [ "$USE_PLUS_VERSION" = true ] && [[ -z "$RESOLVERS_PER_CLIENT" ]]; then
            # Plus without -rc: no rotation, all resolvers split, no reserve
            log_client "$cid" "Restarting (no rotation in split mode)"
            return
        fi

        # Determine how many resolvers this client needs
        local need=1
        if [ "$USE_PLUS_VERSION" = true ] && [[ -n "$RESOLVERS_PER_CLIENT" ]]; then
            need=$RESOLVERS_PER_CLIENT
        fi

        # Get indices used by other clients
        local used
        used=$(get_used_indices "$cid")

        # Collect free indices (not used by others), split into fresh vs old
        local fresh=()
        local old_free=()
        local old_arr=($old_set)
        for ((idx = 0; idx < NUM_RESOLVERS; idx++)); do
            # Skip if used by another client
            local in_used=false
            for u in $used; do
                [[ $idx -eq $u ]] && {
                    in_used=true
                    break
                }
            done
            $in_used && continue

            # Separate into old_set vs fresh
            local in_old=false
            for o in "${old_arr[@]}"; do
                [[ $idx -eq $o ]] && {
                    in_old=true
                    break
                }
            done
            if $in_old; then
                old_free+=("$idx")
            else
                fresh+=("$idx")
            fi
        done

        # Sort fresh[] by RESOLVER_LAST_USED ascending (least recently used first)
        if ((${#fresh[@]} > 1)); then
            local sorted_fresh=()
            # Simple selection sort (small array, fine for bash)
            local tmp_fresh=("${fresh[@]}")
            while ((${#tmp_fresh[@]} > 0)); do
                local min_idx=0
                for ((si = 1; si < ${#tmp_fresh[@]}; si++)); do
                    if ((RESOLVER_LAST_USED[${tmp_fresh[$si]}] < RESOLVER_LAST_USED[${tmp_fresh[$min_idx]}])); then
                        min_idx=$si
                    fi
                done
                sorted_fresh+=("${tmp_fresh[$min_idx]}")
                # Remove element at min_idx
                tmp_fresh=("${tmp_fresh[@]:0:$min_idx}" "${tmp_fresh[@]:$((min_idx + 1))}")
            done
            fresh=("${sorted_fresh[@]}")
        fi

        # Queue = fresh (sorted by staleness) + old_set (fallback)
        local queue=("${fresh[@]}" "${old_free[@]}")

        # Pick first 'need' from queue
        local picked=""
        for ((q = 0; q < need && q < ${#queue[@]}; q++)); do
            picked+="${queue[$q]} "
            # Update last-used tracking
            ((ASSIGN_COUNTER++))
            RESOLVER_LAST_USED[${queue[$q]}]=$ASSIGN_COUNTER
        done
        CLIENT_RESOLVERS[$cid]="${picked% }"

        # Log what we picked
        local resolver_names=""
        for idx in ${CLIENT_RESOLVERS[$cid]}; do
            resolver_names+="${RESOLVERS[$idx]} "
        done
        log_client "$cid" "Rotated -> ${resolver_names% }"
    }

    # Replace or inject port in a URL: https://host/path -> https://host:PORT/path
    inject_port() {
        local url=$1
        local port=$2
        local proto="${url%%://*}"
        local rest="${url#*://}"
        local hostport="${rest%%/*}"
        local path="/${rest#*/}"
        [[ "$rest" != */* ]] && path=""
        local host="${hostport%%:*}"
        echo "${proto}://${host}:${port}${path}"
    }

    build_resolver_args() {
        local cid=$1
        local args=""
        if [ "$USE_PLUS_VERSION" = true ]; then
            for idx in ${CLIENT_RESOLVERS[$cid]}; do
                args+=" -r ${RESOLVERS[$idx]}"
            done
        else
            local idx=${CLIENT_RESOLVERS[$cid]}
            args="-r ${RESOLVERS[$idx]}"
        fi
        echo "$args"
    }

    log_client() {
        local cid=$1
        local msg=$2
        local port=$((BASE_PORT + cid))
        echo "[$(date)] [Client $cid :$port] $msg" | tee -a "$LOG_FILE"
    }

    stop_client() {
        local cid=$1
        local pid=${CLIENT_PIDS[$cid]}
        [[ "$pid" -eq 0 ]] && return

        pkill -P "$pid" 2>/dev/null
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null

        CLIENT_PIDS[$cid]=0
        sleep 0.3
    }

    start_client() {
        local cid=$1
        local port=$((BASE_PORT + cid))
        local prefix="[Client $cid :$port]"
        local resolver_args
        resolver_args=$(build_resolver_args "$cid")

        stop_client "$cid"

        CLIENT_LOG_MARKER[$cid]=$(wc -l <"$LOG_FILE")

        # Log assigned resolvers
        local resolver_names=""
        for idx in ${CLIENT_RESOLVERS[$cid]}; do
            resolver_names+="${RESOLVERS[$idx]} "
        done
        log_client "$cid" "Starting -> ${resolver_names% }"

        # shellcheck disable=SC2086
        { $CLIENT_BIN -c bbr $resolver_args -d "$DOMAIN" $CERT_OPT $HOST_OPT --tcp-listen-port "$port" -t 50 2>&1 |
            sed -u "s/^/$prefix /" >>"$LOG_FILE"; } &
        CLIENT_PIDS[$cid]=$!
        CLIENT_READY[$cid]=false
        CLIENT_HC_FAILS[$cid]=0
    }

    check_log_since_marker() {
        local cid=$1
        local pattern=$2
        local marker=${CLIENT_LOG_MARKER[$cid]}
        local port=$((BASE_PORT + cid))
        tail -n +$((marker + 1)) "$LOG_FILE" | grep -q "\[Client $cid :$port\].*$pattern"
    }

    # --- Start all clients ---
    for ((i = 0; i < CLIENT_COUNT; i++)); do
        start_client "$i"
        sleep 0.5
    done

    # --- Main monitoring loop ---
    hc_cycle=0
    file_monitor_cycle=0
    while true; do
        for ((i = 0; i < CLIENT_COUNT; i++)); do
            pid=${CLIENT_PIDS[$i]}

            # Check if process died
            if ! kill -0 "$pid" 2>/dev/null; then
                log_client "$i" "Process died, rotating"
                rotate_client "$i"
                start_client "$i"
                continue
            fi

            # Check for connection ready (only log once per lifecycle)
            if [ "${CLIENT_READY[$i]}" = false ] && check_log_since_marker "$i" "Connection ready"; then
                log_client "$i" "EVENT: Connection ready"
                CLIENT_READY[$i]=true
            fi

            # Check for connection close
            if check_log_since_marker "$i" "Connection close"; then
                log_client "$i" "EVENT: Connection closed, rotating"
                rotate_client "$i"
                start_client "$i"
            fi
        done

        # Health check every HC_INTERVAL seconds
        if [ "$NO_HEALTH_CHECK" = false ]; then
            ((hc_cycle++))
            if ((hc_cycle % HC_INTERVAL == 0)); then
                for ((i = 0; i < CLIENT_COUNT; i++)); do
                    [[ "${CLIENT_READY[$i]}" = false ]] && continue
                    local_port=$((BASE_PORT + i))
                    probe_url=$(inject_port "$HC_URL" "$local_port")
                    curl -s -m 5 -k "$probe_url" >/dev/null
                    CURL_EXIT=$?
                    hc_success=false
                    for ecode in "${HC_SUCCESS_CODES[@]}"; do
                        [[ "$CURL_EXIT" -eq "$ecode" ]] && {
                            hc_success=true
                            break
                        }
                    done
                    if [ "$hc_success" = true ]; then
                        CLIENT_HC_FAILS[$i]=0
                    else
                        ((CLIENT_HC_FAILS[$i]++))
                        log_client "$i" "Health check failed (Exit code: $CURL_EXIT, ${CLIENT_HC_FAILS[$i]}/$HC_THRESHOLD)"
                        if ((CLIENT_HC_FAILS[$i] >= HC_THRESHOLD)); then
                            log_client "$i" "Health check failed ${HC_THRESHOLD}x, rotating"
                            rotate_client "$i"
                            start_client "$i"
                        fi
                    fi
                done
            fi
        fi

        # --- File monitor: reload resolvers every FILE_MONITOR_INTERVAL seconds ---
        if [[ "$FILE_MODE" = true ]]; then
            ((file_monitor_cycle++))
            if ((file_monitor_cycle >= FILE_MONITOR_INTERVAL)); then
                file_monitor_cycle=0
                if load_resolvers_from_files; then
                    # Compare new list to current
                    local_new="${LOADED_RESOLVERS[*]}"
                    local_old="${RESOLVERS[*]}"
                    if [[ "$local_new" != "$local_old" ]]; then
                        echo "[$(date)] File monitor: resolver list changed, hot-swapping."
                        echo "[$(date)]   Old: $local_old"
                        echo "[$(date)]   New: $local_new"
                        RESOLVERS=("${LOADED_RESOLVERS[@]}")
                        NUM_RESOLVERS=${#RESOLVERS[@]}
                    fi
                else
                    echo "[$(date)] File monitor: reload failed, keeping current resolvers."
                fi
            fi
        fi

        sleep 1
    done
    ;;
esac
