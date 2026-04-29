# Slack Assistant

Monitors Slack channels in real-time, surfaces relevant messages to a private alert channel, and can draft or auto-send replies on your behalf.

## How it works

1. **Connects via Socket Mode** — persistent WebSocket, no polling, no public URL needed
2. **Pre-filters** direct mentions of you or your team handles — flagged instantly, no LLM call
3. **Runs everything else through Claude Haiku** — cheap semantic relevance check against your profile
4. **Posts alerts to a private channel** — includes the message, why it was flagged, and (in `draft` mode) a suggested reply with Send / Edit / Dismiss buttons
5. **Drafts replies with Claude Sonnet** — smarter model, only used when a reply is needed

## Setup

### 1. Clone / navigate to the project

```bash
cd slack-assistant
```

### 2. Install gems

```bash
bundle install
```

### 3. Create your Slack app

Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From scratch**.

Under **Socket Mode**: enable it and generate an app-level token (`xapp-...`) with the `connections:write` scope.

Under **OAuth & Permissions**, add these Bot Token Scopes:

`channels:history` `channels:read` `chat:write` `groups:history` `groups:read` `groups:write` `im:history` `mpim:history` `reactions:write` `users:read` `users:read.email` `usergroups:read`

Under **Event Subscriptions**: enable events and subscribe to bot events:

`message.channels` `message.groups`

Install the app to your workspace. Copy the bot token (`xoxb-...`).

### 4. Configure tokens

```bash
cp .env.example .env
```

Fill in `.env` with your tokens:

```
SLACK_ASSISTANT_BOT_TOKEN=xoxb-...
SLACK_ASSISTANT_SOCKET_TOKEN=xapp-...
SLACK_ASSISTANT_ANTHROPIC_TOKEN=sk-ant-...
```

### 5. Configure `config.yml`

```bash
cp config.yml.example config.yml
```

Set your email, alert channel name, and relevance prompt:

```yaml
email: you@yourcompany.com
alert_channel: slack-assistant  # private channel the bot will create

relevance_prompt: |
  I'm [Your Name], on the [Team] team.
  I care about:
  - ...
  Ignore: ...
```

The relevance prompt is plain English — describe yourself and what kinds of messages matter to you. The more specific, the better the filtering.

### 6. Invite the bot to channels

The bot can only receive events from channels it's a member of. Use `/invite @your-bot-name` in any channel you want monitored.

## Usage

```bash
# End-to-end test: fires a synthetic message through the pipeline,
# posts an alert to your alert channel, then exits
bundle exec ruby slack_assistant.rb --test

# Live monitoring
bundle exec ruby slack_assistant.rb
```

On startup the script automatically resolves your user ID, team group handles, and every channel you're a member of — no static config needed beyond your email.

## Modes

Set `mode` in `config.yml`:

| Mode | Behavior |
|---|---|
| `monitor` | Posts alert with context only — no reply drafted |
| `draft` | Posts alert with a suggested reply and **Send / Edit / Dismiss** buttons |
| `auto` | Sends the reply automatically, posts a record to the alert channel |

## Alert channel

The bot automatically creates and joins a private channel (name set by `alert_channel` in config). All alerts go there. In `draft` mode, buttons let you:

- **Send** — posts the drafted reply into the original thread
- **Edit** — opens a modal pre-filled with the draft so you can tweak before sending
- **Dismiss** — removes the alert card

## Project structure

```
slack-assistant/
  slack_assistant.rb   # main script
  config.yml           # your email, mode, and relevance prompt (gitignored)
  config.yml.example   # template — copy to config.yml
  .env                 # your tokens (gitignored)
  .env.example         # template — copy to .env
  Gemfile
  README.md
```
