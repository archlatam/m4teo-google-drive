#!/usr/bin/env bash
#
# sync.sh — backend de sincronización selectiva bidireccional con Google Drive.
#
# Reemplaza el montaje FUSE por una carpeta local real (~/DriveSync) sincronizada
# con rclone bisync, limitada a los elementos (raíz) que el usuario marca en el
# widget. El filtro de selección vive en filters.txt (reglas `+`/`-` de rclone).
#
# Subcomandos:
#   list              → JSON de archivos/carpetas raíz con estado seleccionado
#   set <ruta> <0|1>  → marcar(1)/desmarcar(0) un elemento en el filtro
#   sync [ruta]       → ejecutar bisync (toda la selección o un solo elemento)
#   status            → estado de la última sync (hora, errores, selección activa)
#
set -u

# The widget passes this from its `remoteName` setting. The default also keeps
# the helper convenient to use directly from a terminal.
REMOTE="gdrive"
if [ "${1:-}" = "--remote" ]; then
  [ -n "${2:-}" ] || { echo "remote required" >&2; exit 1; }
  REMOTE="${2%:}"
  shift 2
fi

# A Drive/OAuth request must not leave the UI waiting forever. One retry is
# enough for transient failures; the original error is then shown in the panel.
RCLONE_NETWORK_ARGS=(--contimeout 10s --timeout 30s --retries 1 --low-level-retries 1)
LOCAL="${HOME}/DriveSync"
# Directorio de estado fuera del plugin. Los watchers del shell (inotify) vigilan
# el dir del plugin; si el estado (filters/sync-state/sync.log/lock) viviera ahí,
# cada clic/sync dispararía un "Local plugin changed, reloading" encadenado que
# acaba reiniciando la shell entera.
STATE_DIR="${HOME}/.config/m4teo-rclone-drive"
FILTERS="${STATE_DIR}/filters.txt"
STATE="${STATE_DIR}/sync-state.json"
STATE_LST_DIR="${HOME}/.cache/rclone/bisync"
LOG_FILE="${STATE_DIR}/sync.log"
LOCK_FILE="${STATE_DIR}/sync.lock"

log() {
  printf '%s\n' "$1" >>"$LOG_FILE"
  tail -n 300 "$LOG_FILE" >"$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
}

json_escape() {
  local n="$1"
  n="${n//\\/\\\\}"
  n="${n//\"/\\\"}"
  n="${n//$'\n'/\\n}"
  printf '%s' "$n"
}

# ¿Está el elemento ya seleccionado en filters.txt? (formas posibles:
# `+ ruta` para archivo, `+ ruta/**` o `+ ruta/` para carpeta).
is_selected() {
  local rel="$1" esc
  esc="$(printf '%s' "$rel" | sed 's/[.[\*^$()+?{|]/\\&/g')"
  grep -qE "^\+ ${esc}(/\*\*|/)?$" "$FILTERS" 2>/dev/null
}

# ¿Es el elemento una carpeta a nivel raíz? La lista de directorios de la raíz
# se consulta una vez; no usamos `lsf` con barra (Google Drive no distingue).
is_remote_dir() {
  local rel="$1"
  [ -n "$rel" ] || return 1
  # `lsf --dirs-only` devuelve nombres con barra final (p.ej. "CursoPython/").
  rclone lsf "${REMOTE}:" --dirs-only --format "p" "${RCLONE_NETWORK_ARGS[@]}" 2>/dev/null | sed 's#/$##' | grep -qxF "$rel"
}

cmd_list() {
  mkdir -p "$STATE_DIR"
  mkdir -p "$LOCAL"
  touch "$FILTERS"

  local listing errors exit_code
  listing="$(mktemp)"
  errors="$(mktemp)"
  rclone lsjson "${REMOTE}:" --files-only=false "${RCLONE_NETWORK_ARGS[@]}" >"$listing" 2>"$errors"
  exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    cat "$errors" >&2
    rm -f "$listing" "$errors"
    return "$exit_code"
  fi

  python3 -c "
import json, sys, os

local_path = '$LOCAL'
filters_file = '$FILTERS'

selected_names = set()
if os.path.exists(filters_file):
    try:
        with open(filters_file, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                line = line.strip()
                if line.startswith('+ '):
                    r = line[2:].strip().rstrip('/*')
                    if r:
                        selected_names.add(r)
    except Exception:
        pass

try:
    data = json.load(sys.stdin)
except Exception:
    data = []

data.sort(key=lambda e: (0 if e.get('IsDir') else 1, e.get('Name', '').lower()))

out = []
for e in data:
    name = e.get('Name', '')
    if not name:
        continue
    is_dir = bool(e.get('IsDir', False))
    size = e.get('Size', 0)

    lp = os.path.join(local_path, name)
    local_found = os.path.exists(lp)
    local_bytes = 0
    if local_found:
        try:
            if os.path.isdir(lp):
                local_bytes = sum(
                    os.path.getsize(os.path.join(dirpath, f))
                    for dirpath, _, filenames in os.walk(lp)
                    for f in filenames
                )
            else:
                local_bytes = os.path.getsize(lp)
        except Exception:
            local_bytes = 0

    is_sel = (name in selected_names) or local_found

    out.append({
        'name': name,
        'isDir': is_dir,
        'selected': 1 if is_sel else 0,
        'sizeBytes': size,
        'local': local_found,
        'localBytes': local_bytes
    })

print(json.dumps(out))
" <"$listing"
  exit_code=$?
  rm -f "$listing" "$errors"
  return "$exit_code"
}

cmd_set() {
  local rel="${1:?path required}" want="${2:?state (0|1) required}"
  rel="${rel%/}"
  [ -n "$rel" ] || { echo '{"ok":false,"error":"empty path"}'; return 1; }

  mkdir -p "$STATE_DIR"
  mkdir -p "$LOCAL"
  touch "$FILTERS"

  # 1. Si pedimos desmarcar (want=0), borrar la copia local DE INMEDIATO (0.001s)
  if [ "$want" = "0" ]; then
    local lp="${LOCAL}/${rel}"
    case "$lp" in
      "${LOCAL}/"*) ;;
      *) lp="" ;;
    esac
    if [ -n "$lp" ] && [ -e "$lp" ]; then
      if rm -rf -- "$lp" 2>/dev/null; then
        log "removed local copy: $rel"
      else
        log "ERROR removing local copy: $rel"
      fi
    fi
  fi

  # 2. Actualizar filters.txt de forma puramente local e instantánea (sin llamadas de red)
  python3 -c "
import sys, os

filters_file = '$FILTERS'
target = sys.argv[1]
want = sys.argv[2]
local_dir = '$LOCAL'

rules = {}
if os.path.exists(filters_file):
    with open(filters_file, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if line.startswith('+ '):
                rule = line[2:].strip()
                if rule.endswith('/**'):
                    name = rule[:-3]
                    rules[name] = True
                elif rule.endswith('/'):
                    name = rule[:-1]
                    rules[name] = True
                else:
                    rules[rule] = False

if want == '1':
    is_dir = rules.get(target, False)
    if not is_dir and os.path.isdir(os.path.join(local_dir, target)):
        is_dir = True
    rules[target] = is_dir
elif want == '0':
    rules.pop(target, None)

with open(filters_file, 'w', encoding='utf-8') as f:
    for name, is_dir in sorted(rules.items()):
        if is_dir:
            f.write(f'+ {name}/**\n')
        else:
            f.write(f'+ {name}\n')
    f.write('- **\n')
" "$rel" "$want"

  rm -f "${FILTERS}.md5" 2>/dev/null || true
  log "selection: $rel -> want=$want"
  echo '{"ok":true}'
}

cmd_status() {
  local last_ts="" ok=false err=""
  if [ -f "$STATE" ]; then
    last_ts="$(python3 -c "import json;print(json.load(open('$STATE')).get('lastRun',''))" 2>/dev/null || echo "")"
    if python3 -c "import json,sys;sys.exit(0 if json.load(open('$STATE')).get('ok') else 1)" 2>/dev/null; then ok=true; fi
    err="$(python3 -c "import json;print(json.load(open('$STATE')).get('error',''))" 2>/dev/null || echo "")"
  fi

  # Telemetría en vivo: si LOCK_FILE existe, extraer archivo actual, %, velocidad y ETA
  local progress="{}"
  if [ -e "$LOCK_FILE" ]; then
    progress="$(python3 -c "
import json, re, os

lock_data = ''
try:
    with open('$LOCK_FILE', 'r', encoding='utf-8', errors='replace') as f:
        lock_data = f.read().strip()
except Exception:
    pass

op = 'sync'
target = ''
if ':' in lock_data:
    op, target = lock_data.split(':', 1)
elif lock_data:
    op = lock_data

active = True
percent = 0.0
speed = ''
eta = ''
current_file = target
bytes_done = ''
bytes_total = ''

lines = []
if os.path.exists('$LOG_FILE'):
    try:
        with open('$LOG_FILE', 'r', encoding='utf-8', errors='replace') as f:
            lines = f.read().splitlines()[-150:]
    except Exception:
        pass

# Buscar archivo específico en transferencia (bloque 'Transferring:')
in_transferring = False
for ln in reversed(lines):
    if 'Transferring:' in ln:
        break
    m_file = re.search(r'^\s*\*\s*([^:]+):\s*([\d.]+)%', ln)
    if m_file:
        current_file = m_file.group(1).strip()
        try:
            # Si encontramos porcentaje por archivo
            percent = float(m_file.group(2))
        except Exception:
            pass
        break

# Buscar línea general de transferencia
# Formato: Transferred: 12.345 MiB / 50 MiB, 25%, 2.5 MiB/s, ETA 15s
for ln in reversed(lines):
    if 'Transferred:' in ln or re.search(r'[\d.]+\s*[KMGT]?i?B\s*/\s*[\d.]+\s*[KMGT]?i?B', ln):
        m_stat = re.search(
            r'([\d.]+)\s*([KMGT]?i?B)\s*/\s*([\d.]+)\s*([KMGT]?i?B),\s*([\d.]+)%,\s*([^,]+?)(?:,\s*ETA\s+(\S+))?$',
            ln.strip()
        )
        if m_stat:
            bytes_done = m_stat.group(1) + ' ' + m_stat.group(2)
            bytes_total = m_stat.group(3) + ' ' + m_stat.group(4)
            try:
                percent = float(m_stat.group(5))
            except Exception:
                pass
            speed = m_stat.group(6).strip()
            raw_eta = m_stat.group(7) or ''
            if raw_eta and raw_eta != '-':
                eta = raw_eta
            break

res = {
    'active': True,
    'operation': op,
    'target': target,
    'currentFile': current_file,
    'percent': round(percent, 1),
    'speed': speed,
    'eta': eta,
    'bytesDone': bytes_done,
    'bytesTotal': bytes_total
}
print(json.dumps(res))
" 2>/dev/null || echo '{"active":true,"currentFile":"","percent":0,"speed":"","eta":""}')"
  else
    progress='{"active":false,"currentFile":"","percent":0,"speed":"","eta":""}'
  fi

  printf '{"lastRun":"%s","ok":%s,"error":"%s","progress":%s,"lastLine":"%s"}\n' \
    "$(json_escape "$last_ts")" "$ok" "$(json_escape "$err")" "$progress" \
    "$(json_escape "$(tail -n 1 "$LOG_FILE" 2>/dev/null)")"
}

run_bisync() {
  local only="${1:-}"
  local extra=()
  if [ -n "$only" ]; then
    local tmp
    tmp="$(mktemp)"
    if is_remote_dir "$only"; then
      printf '+ %s/**\n' "$only" >"$tmp"
    else
      printf '+ %s\n' "$only" >"$tmp"
    fi
    printf '%s\n' '- **' >>"$tmp"
    extra=(--filters-file "$tmp")
  else
    extra=(--filters-file "$FILTERS")
  fi
  local ACTIVE_FILTERS="$FILTERS"
  if [ -n "$only" ]; then ACTIVE_FILTERS="$tmp"; fi

  mkdir -p "$STATE_DIR"
  mkdir -p "$LOCAL"
  local resync=()
  local NEEDS_RESYNC=0
  if [ ! -f "${STATE_LST_DIR}/bisync.lst" ] && [ ! -f "${STATE_LST_DIR}/.lock" ]; then
    NEEDS_RESYNC=1
  else
    local cur_md5 saved_md5=""
    cur_md5="$(md5sum "$ACTIVE_FILTERS" 2>/dev/null | awk '{print $1}')"
    [ -f "${FILTERS}.md5" ] && saved_md5="$(cat "${FILTERS}.md5" 2>/dev/null)"
    [ -n "$cur_md5" ] && [ "$cur_md5" != "$saved_md5" ] && NEEDS_RESYNC=1
  fi
  if [ "$NEEDS_RESYNC" -eq 1 ]; then
    resync=(--resync)
  fi

  log "--- bisync start $(date -Is) ---"
  if rclone bisync "$LOCAL" "${REMOTE}:" "${resync[@]}" "${extra[@]}" "${RCLONE_NETWORK_ARGS[@]}" --verbose --stats=1s >>"$LOG_FILE" 2>&1; then
    md5sum "$ACTIVE_FILTERS" 2>/dev/null | awk '{print $1}' >"${FILTERS}.md5"
    printf '{"ok":true,"error":"","lastRun":"%s"}\n' "$(date -Is)" >"$STATE"
    log "--- bisync success $(date -Is) ---"
  else
    printf '{"ok":false,"error":"bisync failed","lastRun":"%s"}\n' "$(date -Is)" >"$STATE"
    log "--- bisync FAILED $(date -Is) ---"
    return 1
  fi
}

cmd_download() {
  local rel="${1:?path required}"
  rel="${rel%/}"
  mkdir -p "$STATE_DIR"
  mkdir -p "$LOCAL"

  if [ -e "$LOCK_FILE" ]; then
    echo '{"ok":false,"error":"operation already in progress"}'
    return 0
  fi
  printf 'download:%s\n' "$rel" >"$LOCK_FILE"

  log "--- download start: $rel $(date -Is) ---"
  local exit_code=0
  if is_remote_dir "$rel"; then
    mkdir -p "${LOCAL}/${rel}"
    rclone copy "${REMOTE}:${rel}" "${LOCAL}/${rel}" "${RCLONE_NETWORK_ARGS[@]}" --stats=1s --verbose >>"$LOG_FILE" 2>&1 || exit_code=$?
  else
    rclone copyto "${REMOTE}:${rel}" "${LOCAL}/${rel}" "${RCLONE_NETWORK_ARGS[@]}" --stats=1s --verbose >>"$LOG_FILE" 2>&1 || exit_code=$?
  fi

  rm -f "$LOCK_FILE"

  if [ "$exit_code" -eq 0 ]; then
    log "--- download success: $rel $(date -Is) ---"
    printf '{"ok":true,"error":"","downloaded":"%s"}\n' "$(json_escape "$rel")"
    return 0
  else
    log "--- download FAILED: $rel (code $exit_code) $(date -Is) ---"
    printf '{"ok":false,"error":"download failed: %s"}\n' "$(json_escape "$rel")"
    return 1
  fi
}

cmd_sync() {
  if [ -e "$LOCK_FILE" ]; then
    printf '{"ok":false,"error":"sync already in progress","lastRun":""}\n' >"$STATE"
    echo '{"ok":false,"error":"sync already in progress"}'
    return 0
  fi
  printf 'sync\n' >"$LOCK_FILE"
  if ! run_bisync "${1:-}"; then
    echo '{"ok":false,"error":"bisync failed"}'
    rm -f "$LOCK_FILE"
    return 1
  fi
  rm -f "$LOCK_FILE"
  echo '{"ok":true,"error":"","lastRun":"'"$(date -Is)"'"}'
}

case "${1:-}" in
  list) cmd_list ;;
  set)
    [ -n "${2:-}" ] || { echo "path required" >&2; exit 1; }
    [ -n "${3:-}" ] || { echo "state (0|1) required" >&2; exit 1; }
    cmd_set "$2" "$3"
    ;;
  download) cmd_download "${2:-}" ;;
  sync) cmd_sync "${2:-}" ;;
  status) cmd_status ;;
  *)
    echo "Usage: $0 {list|set <path> <0|1>|download <path>|sync [path]|status}" >&2
    exit 1
    ;;
esac
