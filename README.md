# claude-dotfiles

Персональные скрипты и конфиги для Claude Code. Работают на macOS, Linux
(Debian/Ubuntu/Arch/Alpine), WSL и Synology DSM (через Entware).

## statusline.sh

Кастомный statusLine с:

- моделью (сокр.)
- cwd / git branch
- суммарными токенами сессии + **дельта за текущий запрос** `(+2.5k 9%)`
- топ-тулзом сессии по байтам из транскрипта + дельта
- session cost (`$`), если харнес его отдаёт

Пример:

```
Opus 4.6 | ctf | master | 89.4k tok (+2.5k 9%) | ⬆Bash 17.1k (+800) | $0.4231
```

### Установка

Клонируй репо в постоянное место (не `/tmp`) и запусти инсталлер:

```bash
git clone https://github.com/c4uran/claude-dotfiles.git ~/.claude/dotfiles
bash ~/.claude/dotfiles/install.sh
```

Инсталлер:
1. Определит ОС (macOS / Debian / Arch / Alpine / WSL / Synology).
2. Проверит наличие `bash`, `jq >= 1.5`, `awk`. Если чего-то нет — покажет
   команду для твоего пакетного менеджера и выйдет с кодом 1.
3. Сделает симлинк `~/.claude/statusline.sh -> dotfiles/statusline.sh`
   (старый файл, если был, сохранит в `.bak.<ts>`).
4. Напечатает snippet для `settings.json` — добавь руками.

Добавь в `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  }
}
```

### Зависимости

Обязательные:

- `bash` >= 3.2 (macOS дефолт подходит)
- `jq` >= 1.5 (нужен `from_entries` для парсинга транскрипта)
- `awk` (любой — BSD awk / gawk / mawk)

Опциональные:

- `git` — для показа текущей ветки в строке

Команды установки по платформам:

| ОС | Команда |
|---|---|
| macOS | `brew install jq git` |
| Debian / Ubuntu / WSL | `sudo apt-get install -y jq git` |
| Arch | `sudo pacman -S --needed jq git` |
| Alpine | `sudo apk add jq git` |
| Synology DSM | `opkg install jq git` (нужен [Entware](https://github.com/Entware/Entware/wiki/Install-on-Synology-NAS)) |

### Как работает дельта

State хранится в `$XDG_CACHE_HOME/claude-statusline/<session_id>.state`
(по умолчанию — `~/.cache/claude-statusline/`).

На каждом рендере скрипт:

1. Считает число реальных user-тёрнов в транскрипте (`tool_result`-сообщения
   отфильтровываются).
2. Если счётчик вырос с прошлого раза — снимает новый **бейзлайн** (текущие
   токены + top-tool bytes). Это момент «старт нового запроса».
3. Иначе — показывает `current − baseline` в скобках. Дельта растёт
   монотонно весь тёрн, пока ты не отправишь следующее сообщение.

Таким образом в скобках ты видишь полную цену именно **этого запроса**,
а не шум между отдельными рендерами статуслайна.

Топ-тул считается по транскрипту: парсятся `tool_use.input` и
`tool_result.content`, группируются по имени тула, берётся максимум.
Дельта у топ-тула — прирост его байт с начала текущего тёрна (/4 ≈ токены).

### Кросс-платформенность

- Без `bc` (использует `awk` для форматирования).
- Без жёсткой зависимости от GNU `timeout` (graceful fallback на macOS).
- Без bashism'ов > 3.2, чтобы работало со стоковым `/bin/bash` на macOS.
- `jq`-пайплайн не использует `INDEX` (которое появилось в jq 1.6) —
  заменено на `from_entries`, чтобы работать на jq 1.5 (Synology/Entware,
  старые дистрибутивы).
