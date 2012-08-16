#!/bin/bash

setterm -powersave off -blank 0
LINES=$(tput lines)
COLUMNS=$(tput cols)
STATUS_FIFO=/opt/rpcs/.status_fifo
LOG_FILE=/var/log/post-install.log
PRODUCT="Rackspace (TM) Private Cloud Software"
PRODUCT_SHORT="Rackspace (TM) Private Cloud Software"
CMDPID=""
CMD="dialog"
LOG_W="--no-shadow --tailboxbg ${LOG_FILE} $[ LINES - 20 ] $[ COLUMNS - 4 ]"

function render {
    KILL_CHILD
    local RUN="$CMD --title \"Install Log\" --keep-window --begin 19 2 ${LOG_W}" 
    [ -n "$SUBSTATUS_W" ] && RUN="${RUN} --and-widget --keep-window --begin 10 7 ${SUBSTATUS_W}"
    [ -n "$STATUS_W" ] && RUN="${RUN} --and-widget --keep-window --title \"Installation Progress\" --begin 2 2 ${STATUS_W}"
    eval "${RUN} </dev/null &"
    CMDPID=$!
}

function KILL_CHILD {
    pkill dialog
    #if ! [ -z $CMDPID ] ; then kill $CMDPID &>/dev/null; CMDPID=""; fi
}

function STATUS()
{
    local percent=$1
    shift
    local msg="$@"
    STATUS_W="--no-shadow --backtitle 'Installing ${PRODUCT}' --gauge '${msg}' 6 $[ COLUMNS - 4 ] '${percent}'"
    render
}

function SUBSTATUS()
{
    local percent=$1
    local k=$2
    local v=$3
    shift
    local msg="$@"
    SUBSTATUS_W="--no-shadow --mixedgauge '' 7 $[ COLUMNS - 13 ] '${percent}' '$k' '$v'"
    render
}

function SUBSTATUS_CLOSE() {
    SUBSTATUS_W=""
    render
}

function GET_STATUS() {
    #Waiting for evan's commit.
    return $(</opt/rpcs/.status)
}

function COMPLETE() {
    KILL_CHILD
    if GET_STATUS; then
        touch /opt/rpcs/.completed
        clear
        exec /opt/rpcs/status.rb /root/.chef/knife.rb
    else
        # errored in some way -- should get a failure descriptor or something
        # maybe even prompt to email stuffs
        DIALOGRC=<(echo "screen_color = (WHITE,RED,ON)") dialog --backtitle "Internal Error" --begin 2 2 --keep-window --no-shadow --infobox "${PRODUCT_SHORT} could not be installed.  Please refer to the log box below or /var/log/post-install.log for additional information.  The installation process will be restarted in 30 seconds." 6 $[ COLUMNS - 4 ]  --and-widget --keep-window --begin 19 2 ${LOG_W} &
        CMD_PID=$!
        sleep 30
        KILL_CHILD
        /etc/rc.local
        exit 1
    fi
    rm -f ${STATUS_FIFO}
}

function main()
{
    local f
    while :; do
        # If already completed update with error or run status.rb
        if [ -f /opt/rpcs/.completed ]; then
            COMPLETE
        fi
        if [ ! -p ${STATUS_FIFO} ]; then
            rm -f ${STATUS_FIFO}
            mkfifo ${STATUS_FIFO} || {
                echo "Couldn't make fifo ${STATUS_FIFO}"
                exit 2
            }
            STATUS 0 "Starting installation of ${PRODUCT_SHORT}"
        fi
        while read -r line; do
            unset f
            declare -a "f=(${line})"
            if declare -f ${f[0]} > /dev/null; then
                ${f[0]} "${f[@]:1}"
            fi
        done < ${STATUS_FIFO}
    done
}

function do_exit()
{
    KILL_CHILD
    clear
    exit 0
}

trap do_exit ERR EXIT SIGINT SIGTERM

main
