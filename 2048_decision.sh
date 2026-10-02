#!/usr/bin/env bash

set -u
set -o pipefail

SESSION="decision-2048"

API="http://localhost:8001/v1/systemone"
HEALTH="http://localhost:8001/health"

LOG="/tmp/decision-2048.log"
BOARD_LOG="/tmp/decision-2048-board.txt"
RESPONSE_FILE="/tmp/decision-2048-response.$$"

MOVE_DELAY=0.25

for cmd in tmux curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "sudo apt install 2048 tmux curl jq"
        exit 1
    fi
done

GAME="$(command -v 2048 2>/dev/null || true)"

if [[ -z "$GAME" && -x /usr/games/2048 ]]; then
    GAME="/usr/games/2048"
fi

if [[ -z "$GAME" || ! -x "$GAME" ]]; then
    echo "2048 not found."
    echo
    echo "Install with:"
    echo "  sudo apt install 2048"
    exit 1
fi

if ! curl -sf --max-time 5 "$HEALTH" >/dev/null 2>&1; then
    echo "Decision model server is not responding:"
    echo "  $HEALTH"
    exit 1
fi

tmux kill-session -t "$SESSION" 2>/dev/null || true

rm -f "$LOG"
rm -f "$BOARD_LOG"
rm -f "$RESPONSE_FILE"

touch "$LOG"

tmux new-session -d \
    -s "$SESSION" \
    -x 100 \
    -y 40 \
    "exec '$GAME'"

sleep 1

GAME_PANE="$(
    tmux display-message \
        -p \
        -t "$SESSION:0.0" \
        '#{pane_id}'
)"

echo "$(date '+%H:%M:%S') 2048 started" >> "$LOG"

tmux split-window \
    -v \
    -t "$GAME_PANE" \
    -l 10 \
    "tail -n 30 -F '$LOG'"

tmux select-pane -t "$GAME_PANE"

# Give 2048 a moment to redraw after the resize
sleep 0.5

capture_board() {

    tmux capture-pane \
        -p \
        -t "$GAME_PANE" 2>/dev/null |
    sed 's/[[:space:]]\+$//'
}

CONTROLLER_PID=""

cleanup() {

    if [[ -n "${CONTROLLER_PID:-}" ]]; then
        kill "$CONTROLLER_PID" 2>/dev/null || true
    fi

    tmux kill-session -t "$SESSION" 2>/dev/null || true

    rm -f "$RESPONSE_FILE"
}

trap cleanup EXIT INT TERM

game_alive() {

    tmux list-panes \
        -a \
        -F '#{pane_id}' 2>/dev/null |
    grep -qx "$GAME_PANE"
}

controller() {

    echo "$(date '+%H:%M:%S') controller started" >> "$LOG"

    # Moves that were tried on the CURRENT board and did nothing.
    #
    # Example:
    # {"up":true,"left":true}
    #
    # They are removed from the next decision request.
    BANNED='{}'

    TURN=0

    while tmux has-session -t "$SESSION" 2>/dev/null; do

        if ! game_alive; then
            echo "$(date '+%H:%M:%S') game exited" >> "$LOG"
            break
        fi

        BOARD="$(capture_board)"

        if [[ -z "$BOARD" ]]; then
            echo "$(date '+%H:%M:%S') empty board capture" >> "$LOG"
            sleep 0.5
            continue
        fi

        printf '%s\n' "$BOARD" > "$BOARD_LOG"

        # If all four directions failed, you're screwed.

        BANNED_COUNT="$(
            jq 'length' <<< "$BANNED"
        )"

        if [[ "$BANNED_COUNT" -ge 4 ]]; then
            echo "$(date '+%H:%M:%S') no valid moves" >> "$LOG"
            break
        fi

        TURN=$((TURN + 1))

        # Build request

        REQUEST="$(
            jq -n \
                --arg board "$BOARD" \
                --argjson banned "$BANNED" \
                '
                def moves:
                    {
                        up:
                            "Slide all tiles upward",

                        down:
                            "Slide all tiles downward",

                        left:
                            "Slide all tiles to the left",

                        right:
                            "Slide all tiles to the right"
                    };

                def allowed_moves:
                    moves
                    | with_entries(
                        select(
                            ($banned[.key] // false) | not
                        )
                    );

                {
                    state: (
                        "Current 2048 game state:\n\n" +
                        $board
                    ),

                    questions: {

                        move: {
                            type: "choice",

                            instructions: (
                                "Choose the best legal next move in the game 2048. " +
                                "The goal is to survive and build increasingly large tiles. " +
                                "Prefer moves that merge tiles, preserve empty cells, keep large tiles together, " +
                                "and maintain an ordered board with the largest tile near a corner. " +
                                "Avoid scattering large tiles or unnecessarily reducing free space. " +
                                "Choose only from the available directions."
                            ),

                            criteria: allowed_moves
                        }
                    }
                }
                '
        )"

        if [[ -z "$REQUEST" ]]; then
            echo "$(date '+%H:%M:%S') request construction failed" >> "$LOG"
            sleep 1
            continue
        fi

        echo \
            "$(date '+%H:%M:%S') turn=$TURN thinking..." \
            >> "$LOG"

        HTTP_CODE="$(
            curl \
                -sS \
                --max-time 30 \
                -o "$RESPONSE_FILE" \
                -w '%{http_code}' \
                "$API" \
                -H 'Content-Type: application/json' \
                -d "$REQUEST"
        )"

        CURL_STATUS=$?

        if [[ $CURL_STATUS -ne 0 ]]; then
            echo \
                "$(date '+%H:%M:%S') curl error=$CURL_STATUS" \
                >> "$LOG"

            sleep 1
            continue
        fi

        if [[ "$HTTP_CODE" != "200" ]]; then
            ERROR_BODY="$(
                cat "$RESPONSE_FILE" 2>/dev/null || true
            )"

            echo \
                "$(date '+%H:%M:%S') HTTP $HTTP_CODE: $ERROR_BODY" \
                >> "$LOG"

            sleep 1
            continue
        fi

        RESPONSE="$(cat "$RESPONSE_FILE")"

        if ! jq empty <<< "$RESPONSE" >/dev/null 2>&1; then
            echo \
                "$(date '+%H:%M:%S') invalid JSON response" \
                >> "$LOG"

            sleep 1
            continue
        fi

        # answer
        MOVE="$(
            jq -r \
                '.answers.move.choice // empty' \
                <<< "$RESPONSE"
        )"

        UP_PROB="$(
            jq -r \
                '.answers.move.probabilities.up // "-"' \
                <<< "$RESPONSE"
        )"

        DOWN_PROB="$(
            jq -r \
                '.answers.move.probabilities.down // "-"' \
                <<< "$RESPONSE"
        )"

        LEFT_PROB="$(
            jq -r \
                '.answers.move.probabilities.left // "-"' \
                <<< "$RESPONSE"
        )"

        RIGHT_PROB="$(
            jq -r \
                '.answers.move.probabilities.right // "-"' \
                <<< "$RESPONSE"
        )"

        case "$MOVE" in
            up|down|left|right)
                ;;
            *)
                echo \
                    "$(date '+%H:%M:%S') invalid model choice '$MOVE'" \
                    >> "$LOG"

                sleep 0.5
                continue
                ;;
        esac

        # decision to the log

        printf \
            "%s U=%-6s D=%-6s L=%-6s R=%-6s -> %s\n" \
            "$(date '+%H:%M:%S')" \
            "$UP_PROB" \
            "$DOWN_PROB" \
            "$LEFT_PROB" \
            "$RIGHT_PROB" \
            "$MOVE" \
            >> "$LOG"

        # Send the arrow key from the decision

        case "$MOVE" in

            up)
                tmux send-keys \
                    -t "$GAME_PANE" \
                    Up
                ;;

            down)
                tmux send-keys \
                    -t "$GAME_PANE" \
                    Down
                ;;

            left)
                tmux send-keys \
                    -t "$GAME_PANE" \
                    Left
                ;;

            right)
                tmux send-keys \
                    -t "$GAME_PANE" \
                    Right
                ;;

        esac

        # Wait for redraw / new tile
        sleep "$MOVE_DELAY"

        if ! game_alive; then
            echo "$(date '+%H:%M:%S') game finished" >> "$LOG"
            break
        fi

        # If nothing changed, that's not a valid move. Try something
	# else.

        NEW_BOARD="$(capture_board)"

        if [[ "$NEW_BOARD" == "$BOARD" ]]; then

            BANNED="$(
                jq \
                    --arg move "$MOVE" \
                    '. + {($move): true}' \
                    <<< "$BANNED"
            )"

            echo \
                "$(date '+%H:%M:%S') $MOVE had no effect; excluding it" \
                >> "$LOG"

        else

            # New board = all directions need reevaluation.
            BANNED='{}'
        fi

    done

    echo "$(date '+%H:%M:%S') controller stopped" >> "$LOG"
}

controller &
CONTROLLER_PID=$!

tmux select-pane -t "$GAME_PANE"

tmux attach-session -t "$SESSION"

wait "$CONTROLLER_PID" 2>/dev/null || true
