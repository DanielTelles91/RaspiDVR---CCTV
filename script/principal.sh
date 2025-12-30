#!/bin/bash
set -u

BASE="/media/teste/USB/Videos_Camera"
mkdir -p "$BASE"

CAM1="rtsp://192.168.1.112:8554/cam1"
CAM2="rtsp://192.168.1.112:8554/cam2"

# Array para rastrear PIDs do ffmpeg iniciados por este script
declare -a FFMPEG_PIDS=()

# Flag para parar tudo
PARAR=0

log() { echo "[$(date '+%F %T')] $*"; }

add_pid() {
    FFMPEG_PIDS+=( "$1" )
}

remove_pid() {
    local pid=$1
    local new=()
    for p in "${FFMPEG_PIDS[@]:-}"; do
        if [ "$p" != "$pid" ]; then new+=( "$p" ); fi
    done
    FFMPEG_PIDS=("${new[@]}")
}

# cleanup: encerra ffmpegs que o script iniciou
cleanup() {
    log "Recebi sinal de término. Finalizando ffmpeg childs..."
    PARAR=1
    for p in "${FFMPEG_PIDS[@]:-}"; do
        if kill -0 "$p" >/dev/null 2>&1; then
            log "Enviando SIGINT a PID $p"
            kill -INT "$p" >/dev/null 2>&1
            # espera curto para que finalize corretamente
            for i in {1..8}; do
                if ! kill -0 "$p" >/dev/null 2>&1; then break; fi
                sleep 1
            done
            if kill -0 "$p" >/dev/null 2>&1; then
                log "SIGINT não finalizou $p, enviando SIGTERM"
                kill -TERM "$p" >/dev/null 2>&1
                sleep 2
            fi
            if kill -0 "$p" >/dev/null 2>&1; then
                log "SIGTERM não finalizou $p, enviando SIGKILL"
                kill -KILL "$p" >/dev/null 2>&1
            fi
        fi
    done
    exit 0
}
trap cleanup SIGINT SIGTERM

# Função principal: grava contínuo, reinicia em erro, troca pasta ao mudar dia
gravar_camera() {
    local CAM_URL="$1"
    local NOME_CAM="$2"

    # loop infinito: cria novo arquivo sempre que ffmpeg terminar por erro ou por decisão (mudanca de dia)
    while true; do
        # detecta dia corrente e garante pasta
        local DIA_ATUAL
        DIA_ATUAL=$(date +'%Y-%m-%d')
        local PASTA="$BASE/$DIA_ATUAL"
        mkdir -p "$PASTA"

        # nome do arquivo com timestamp de inicio (hora-minuto-segundo)
        local START_TS
        START_TS=$(date +'%H-%M-%S')
        local ARQUIVO="$PASTA/${NOME_CAM}_$START_TS.mkv"

        log "[$NOME_CAM] Iniciando gravação em: $ARQUIVO"

        # Inicia ffmpeg em background e pega PID
        # - use_wallclock_as_timestamps ajuda com timestamps inconsistentes
        ffmpeg -rtsp_transport tcp -use_wallclock_as_timestamps 1 \
               -i "$CAM_URL" -an -c copy -fflags +genpts -fps_mode vfr "$ARQUIVO" &
        local FFMPEG_PID=$!
        add_pid "$FFMPEG_PID"

        # MONITOR: enquanto ffmpeg estiver rodando, checar se dia mudou ou se devemos parar
        while kill -0 "$FFMPEG_PID" >/dev/null 2>&1; do
            # Se script recebeu ordem de parar, quebrar para finalizar ffmpeg
            if [ "$PARAR" -eq 1 ]; then
                log "[$NOME_CAM] Parada solicitada; finalizando PID $FFMPEG_PID"
                kill -INT "$FFMPEG_PID" >/dev/null 2>&1 || true
                break
            fi
            
            # Verifica mudança de dia
            local NOVO_DIA
            NOVO_DIA=$(date +'%Y-%m-%d')
            if [ "$NOVO_DIA" != "$DIA_ATUAL" ]; then
                log "[$NOME_CAM] Mudou o dia ($DIA_ATUAL -> $NOVO_DIA). Solicitando finalizacao do ffmpeg (PID $FFMPEG_PID) para iniciar nova pasta."
                # pede ao ffmpeg terminar elegantemente
                kill -INT "$FFMPEG_PID" >/dev/null 2>&1 || true
                # aguarda um tempo para fechar corretamente
                local waitsec=0
                while kill -0 "$FFMPEG_PID" >/dev/null 2>&1 && [ $waitsec -lt 12 ]; do
                    sleep 1
                    waitsec=$((waitsec+1))
                done
                # se ainda não fechou, força TERM e depois KILL
                if kill -0 "$FFMPEG_PID" >/dev/null 2>&1; then
                    log "[$NOME_CAM] ffmpeg não finalizou após SIGINT; enviando SIGTERM"
                    kill -TERM "$FFMPEG_PID" >/dev/null 2>&1 || true
                    sleep 2
                fi
                if kill -0 "$FFMPEG_PID" >/dev/null 2>&1; then
                    log "[$NOME_CAM] ffmpeg ainda ativo; enviando SIGKILL"
                    kill -KILL "$FFMPEG_PID" >/dev/null 2>&1 || true
                fi
                break
            fi

            # espera curto e repete
            sleep 1
        done
        
        # espera o ffmpeg encerrar e coleta exit code
        if wait "$FFMPEG_PID" >/dev/null 2>&1; then
            rc=$?
        else
            rc=$?
        fi

        remove_pid "$FFMPEG_PID"

        if [ "$PARAR" -eq 1 ]; then
            log "[$NOME_CAM] Parada global detectada. Saindo do loop."
            break
        fi

        if [ "$rc" -eq 0 ]; then
            log "[$NOME_CAM] ffmpeg finalizou normalmente ($ARQUIVO). Iniciando novo arquivo imediatamente."
            # loop recomeça e criará novo arquivo (se dia mudou, já será pasta nova)
            sleep 1
            continue
        else
            log "[$NOME_CAM] ffmpeg terminou com erro (rc=$rc). Aguardando 5s antes de tentar reconectar..."
            sleep 5
            # re-tentará: novo arquivo criado no loop
            continue
        fi
    done
}

# Inicia gravações em background
gravar_camera "$CAM1" "cam1" &
gravar_camera "$CAM2" "cam2" &

# Espera os filhos (mantém script vivo)
wait
