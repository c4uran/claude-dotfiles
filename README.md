# claude-dotfiles

Персональные скрипты для Claude Code.

## statusline.sh

Кастомный statusLine с:

- моделью (сокр.)
- cwd / git branch
- суммарными токенами сессии + **дельта за ход** `(+1.2k 9%)`
- топ-тулзом сессии по байтам из транскрипта + дельта
- session cost (`$`), если харнес его отдаёт

Пример:

```
Opus 4.6 | ctf | master | 89.4k tok (+2.5k 9%) | ⬆Bash 17.1k (+800)
```

### Установка (в одну команду)

```bash
mkdir -p ~/.claude && \
curl -fsSL https://raw.githubusercontent.com/c4uran/claude-dotfiles/master/statusline.sh \
  -o ~/.claude/statusline.sh && \
chmod +x ~/.claude/statusline.sh
```

Затем добавь в `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  }
}
```

### Зависимости

- `jq` (`sudo apt-get install -y jq`)
- `bash`, `git`, `bc` — стандартные

### Как работает дельта

State хранится в `~/.cache/claude-statusline/<session_id>.state`.
На каждом рендере сравнивается `total_input_tokens + total_output_tokens`
с предыдущим значением — так видно сколько токенов добавил каждый запрос.

Топ-тул считается по транскрипту сессии (`transcript_path`):
парсятся `tool_use.input` и `tool_result.content`, группируются
по имени тула, берётся максимум. Дельта у топ-тула — прирост
его байт с прошлого рендера (/4 ≈ токены).
