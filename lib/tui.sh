# shellcheck shell=bash

read_key() {
  local key rest=''
  IFS= read -rsn1 key || return 1
  if [[ "$key" == $'\e' ]]; then IFS= read -rsn2 -t 0.05 rest || true; key+="$rest"; fi
  printf '%s' "$key"
}

tui_enter() {
  [[ -t 0 && -t 1 ]] || fail "TUI требует терминал; используйте --help для CLI"
  printf '\e[?1049h\e[?25l'
  trap 'printf "\e[?25h\e[?1049l"' EXIT INT TERM
}

tui_leave() { printf '\e[?25h\e[?1049l'; trap - EXIT INT TERM; }

show_message() {
  local title="$1" body="$2"
  printf '\e[H\e[2J%s\n\n%b\n\nНажмите любую клавишу…' "$title" "$body"
  read_key >/dev/null || true
}

update_servers_tui() {
  local result stats instance_count server_count
  if result="$(manual_update_servers 2>&1)"; then
    stats="${result##*$'\n'}"
    IFS='|' read -r instance_count server_count <<< "$stats"
    show_message "Server list updated" "Инстансов: $instance_count\nСерверов в общем списке: $server_count"
  else
    show_message "Ошибка" "$result"
  fi
}

render_instance_picker() {
  local selected="$1" i instance prefix count=${#instances[@]}
  printf '\e[H\e[2JPrism Sync  %s\n\nИнстансы\n\n' "$VERSION"
  for i in "${!instances[@]}"; do
    instance="${instances[$i]}"; prefix='  '; ((i == selected)) && prefix='› '
    printf '%s%-30s %s\n' "$prefix" "$(get_instance_name "$instance")" "$(status_line "$instance")"
  done
  if has_managed_servers; then
    prefix='  '; ((selected == count)) && prefix='› '
    printf '\n%s↻ Update server list\n' "$prefix"
    printf '\n↑/↓ выбрать   Enter открыть   u обновить серверы   q выход\n'
  else
    printf '\n↑/↓ выбрать   Enter открыть   q выход\n'
  fi
}

tui_pick_instance() {
  local selected=0 key count total
  TUI_SELECTED=-1
  while true; do
    count=${#instances[@]}; total=$count; has_managed_servers && ((total += 1)); ((selected >= total)) && selected=$((total - 1))
    render_instance_picker "$selected"
    key="$(read_key)" || return 1
    case "$key" in
      $'\e[A'|k) ((selected = (selected - 1 + total) % total)) ;;
      $'\e[B'|j) ((selected = (selected + 1) % total)) ;;
      ''|$'\n'|$'\r')
        if ((selected == count)); then update_servers_tui; continue; fi
        TUI_SELECTED="$selected"; return 0 ;;
      u|U) has_managed_servers && update_servers_tui ;;
      q|Q) return 1 ;;
    esac
  done
}

render_item_picker() {
  local instance="$1" selected="$2"; shift 2
  local -a desired=("$@")
  local i item prefix box current note core_count=${#CORE_ITEMS[@]}
  printf '\e[H\e[2JPrism Sync  %s\n\n%s\n\nОсновное\n' "$VERSION" "$(get_instance_name "$instance")"
  for i in "${!SYNC_ITEMS[@]}"; do
    ((i == core_count)) && printf '\nAdditional\n'
    item="${SYNC_ITEMS[$i]}"; prefix='  '; ((i == selected)) && prefix='› '
    box='[ ]'; [[ "${desired[$i]}" == 1 ]] && box='[✓]'
    current=0; is_synced "$instance" "$item" && current=1
    note=''; [[ "$current" != "${desired[$i]}" ]] && note='  *'
    printf '%s%s %-27s%s\n' "$prefix" "$box" "$(pretty_item "$item")" "$note"
  done
  printf '\n↑/↓ выбрать   Space изменить   a всё   Enter применить   Esc назад   q выход\n* будет изменено\n'
}

tui_edit_instance() {
  local instance="$1" selected=0 key i item current all_on error
  local -a desired=()
  for item in "${SYNC_ITEMS[@]}"; do current=0; is_synced "$instance" "$item" && current=1; desired+=("$current"); done
  while true; do
    render_item_picker "$instance" "$selected" "${desired[@]}"
    key="$(read_key)" || return 2
    case "$key" in
      $'\e[A'|k) ((selected = (selected - 1 + ${#SYNC_ITEMS[@]}) % ${#SYNC_ITEMS[@]})) ;;
      $'\e[B'|j) ((selected = (selected + 1) % ${#SYNC_ITEMS[@]})) ;;
      ' ') desired[$selected]=$((1 - desired[$selected])) ;;
      a|A)
        all_on=1; for i in "${!desired[@]}"; do [[ "${desired[$i]}" == 0 ]] && all_on=0; done
        for i in "${!desired[@]}"; do desired[$i]=$((1 - all_on)); done ;;
      $'\e') return 0 ;;
      q|Q) return 2 ;;
      ''|$'\n'|$'\r')
        for i in "${!SYNC_ITEMS[@]}"; do
          item="${SYNC_ITEMS[$i]}"; current=0; is_synced "$instance" "$item" && current=1; error=''
          if [[ "${desired[$i]}" == 1 && "$current" == 0 ]]; then
            if ! error="$(enable_sync "$instance" "$item" 2>&1)"; then show_message "Ошибка" "$error"; return 0; fi
          elif [[ "${desired[$i]}" == 0 && "$current" == 1 ]]; then
            if ! error="$(disable_sync "$instance" "$item" 2>&1)"; then show_message "Ошибка" "$error"; return 0; fi
          fi
        done
        return 0 ;;
    esac
  done
}

run_tui() {
  tui_enter
  local rc
  while true; do
    tui_pick_instance || break
    rc=0; tui_edit_instance "${instances[$TUI_SELECTED]}" || rc=$?
    ((rc == 2)) && break
  done
  tui_leave
}
