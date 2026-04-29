#!/usr/bin/env ruby
# frozen_string_literal: true

require 'dotenv'
Dotenv.load(File.join(__dir__, '.env'))

require 'slack-ruby-client'
require 'anthropic'
require 'yaml'
require 'json'
require 'faye/websocket'

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
CONFIG = YAML.load_file(File.join(__dir__, 'config.yml'))
MODE = CONFIG['mode'].to_sym          # :monitor | :draft | :auto
RELEVANCE_PROMPT = CONFIG['relevance_prompt'].strip

ANTHROPIC_KEY = ENV.fetch('SLACK_ASSISTANT_ANTHROPIC_TOKEN')
BOT_TOKEN     = ENV.fetch('SLACK_ASSISTANT_BOT_TOKEN')
SOCKET_TOKEN  = ENV.fetch('SLACK_ASSISTANT_SOCKET_TOKEN')

MY_EMAIL           = CONFIG.fetch('email') { abort 'config.yml is missing `email`' }
TEST_MODE          = ARGV.include?('--test')
ALERT_CHANNEL_NAME = CONFIG.fetch('alert_channel', 'slack-assistant')

# ─────────────────────────────────────────────
# Clients
# ─────────────────────────────────────────────
Slack.configure { |c| c.token = BOT_TOKEN }
SLACK        = Slack::Web::Client.new
SLACK_SOCKET = Slack::Web::Client.new(token: SOCKET_TOKEN)
ANTHROPIC = Anthropic::Client.new(api_key: ANTHROPIC_KEY)

# ─────────────────────────────────────────────
# Startup: resolve IDs dynamically
# ─────────────────────────────────────────────
puts '[startup] Resolving user ID...'
MY_USER_ID = SLACK.users_lookupByEmail(email: MY_EMAIL).user.id
puts "  my user ID: #{MY_USER_ID}"

puts '[startup] Resolving team group IDs you belong to...'
all_groups = SLACK.usergroups_list(include_users: true).usergroups
MY_GROUP_IDS = all_groups
  .select { |g| g.users&.include?(MY_USER_ID) }
  .map(&:id)
  .freeze
puts "  group IDs: #{MY_GROUP_IDS.inspect}"

puts '[startup] Resolving channels to monitor...'
channels_resp = SLACK.users_conversations(
  user: MY_USER_ID,
  types: 'public_channel,private_channel',
  exclude_archived: true,
  limit: 500
)
MONITORED_CHANNELS = channels_resp.channels.map { |c| [c.id, c.name] }.to_h.freeze
puts "  monitoring #{MONITORED_CHANNELS.size} channels"

puts '[startup] Finding or creating alert channel...'
existing = SLACK.conversations_list(types: 'private_channel', limit: 200).channels
             .find { |c| c.name == ALERT_CHANNEL_NAME }

ALERT_CHANNEL_ID = if existing
  puts "  found existing ##{ALERT_CHANNEL_NAME} (#{existing.id})"
  existing.id
else
  created = SLACK.conversations_create(name: ALERT_CHANNEL_NAME, is_private: true).channel
  puts "  created ##{ALERT_CHANNEL_NAME} (#{created.id})"
  created.id
end

# Invite the user to the alert channel (no-op if already there)
begin
  SLACK.conversations_invite(channel: ALERT_CHANNEL_ID, users: MY_USER_ID)
rescue Slack::Web::Api::Errors::SlackError => e
  raise unless e.message.include?('already_in_channel')
end

# ─────────────────────────────────────────────
# Pending interactions: ts → { channel, thread_ts, draft }
# ─────────────────────────────────────────────
PENDING = {}
SEEN_ENVELOPES = {}

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────
def mention?(text)
  return false unless text

  text.include?("<@#{MY_USER_ID}>") ||
    MY_GROUP_IDS.any? { |gid| text.include?("<!subteam^#{gid}>") }
end

def relevant?(channel_name, text, thread_context = nil)
  full_text = [thread_context, text].compact.join("\n")
  prompt = <<~PROMPT
    #{RELEVANCE_PROMPT}

    ---
    Channel: ##{channel_name}
    Message: #{full_text}

    Is this message relevant to me? Reply with exactly one word: YES or NO.
  PROMPT

  resp = ANTHROPIC.messages.create(
    model: 'claude-haiku-4-5-20251001',
    max_tokens: 5,
    messages: [{ role: 'user', content: prompt }]
  )
  resp.content.first.text.strip.upcase.start_with?('YES')
rescue => e
  puts "  [haiku error] #{e.message}"
  false
end

def draft_reply(channel_name, text, thread_context = nil)
  full_text = [thread_context, text].compact.join("\n")
  prompt = <<~PROMPT
    #{RELEVANCE_PROMPT}

    ---
    Channel: ##{channel_name}
    Message: #{full_text}

    Draft a short, natural Slack reply on my behalf. Be concise. Just the reply text, no preamble.
  PROMPT

  resp = ANTHROPIC.messages.create(
    model: 'claude-sonnet-4-6',
    max_tokens: 300,
    messages: [{ role: 'user', content: prompt }]
  )
  resp.content.first.text.strip
rescue => e
  puts "  [sonnet error] #{e.message}"
  '(could not draft reply)'
end

def fetch_thread_context(channel_id, thread_ts)
  replies = SLACK.conversations_replies(channel: channel_id, ts: thread_ts, limit: 10)
  replies.messages.map { |m| "<@#{m.user}>: #{m.text}" }.join("\n")
rescue
  nil
end

def post_alert(channel_id:, channel_name:, event:, reason:, draft: nil)
  thread_ts = event['thread_ts'] || event['ts']
  ts_clean = event['ts'].gsub('.', '')
  message_url = "https://slack.com/archives/#{channel_id}/p#{ts_clean}"

  blocks = [
    {
      type: 'section',
      text: {
        type: 'mrkdwn',
        text: ":bell: *Relevant message in ##{channel_name}*  (<#{message_url}|View>)\n> #{event['text']&.slice(0, 400)}"
      }
    },
    {
      type: 'context',
      elements: [{ type: 'mrkdwn', text: "*Why flagged:* #{reason}" }]
    }
  ]

  if draft
    blocks << {
      type: 'section',
      text: { type: 'mrkdwn', text: "*Suggested reply:*\n#{draft}" }
    }
    blocks << {
      type: 'actions',
      block_id: 'reply_actions',
      elements: [
        {
          type: 'button',
          text: { type: 'plain_text', text: 'Send' },
          style: 'primary',
          action_id: 'send_reply',
          value: JSON.generate(channel_id: channel_id, thread_ts: thread_ts, draft: draft)
        },
        {
          type: 'button',
          text: { type: 'plain_text', text: 'Edit' },
          action_id: 'edit_reply',
          value: JSON.generate(channel_id: channel_id, thread_ts: thread_ts, draft: draft)
        },
        {
          type: 'button',
          text: { type: 'plain_text', text: 'Dismiss' },
          action_id: 'dismiss_reply',
          value: 'dismiss'
        }
      ]
    }
  end

  resp = SLACK.chat_postMessage(channel: ALERT_CHANNEL_ID, blocks: blocks, text: "Relevant: ##{channel_name}", unfurl_links: false)
  PENDING[resp.ts] = { channel_id: channel_id, thread_ts: thread_ts, draft: draft }
end

def handle_action(payload)
  action = payload.dig('actions', 0)
  return unless action

  action_id = action['action_id']
  value = begin; JSON.parse(action['value']); rescue; {}; end
  alert_ts = payload.dig('message', 'ts')
  trigger_id = payload['trigger_id']

  case action_id
  when 'send_reply'
    SLACK.chat_postMessage(
      channel: value['channel_id'],
      thread_ts: value['thread_ts'],
      text: value['draft']
    )
    SLACK.chat_update(
      channel: ALERT_CHANNEL_ID,
      ts: alert_ts,
      text: ':white_check_mark: Reply sent.',
      blocks: []
    )

  when 'edit_reply'
    SLACK.views_open(
      trigger_id: trigger_id,
      view: {
        type: 'modal',
        callback_id: 'send_edited_reply',
        private_metadata: JSON.generate(
          channel_id: value['channel_id'],
          thread_ts: value['thread_ts'],
          alert_ts: alert_ts
        ),
        title: { type: 'plain_text', text: 'Edit Reply' },
        submit: { type: 'plain_text', text: 'Send' },
        close: { type: 'plain_text', text: 'Cancel' },
        blocks: [
          {
            type: 'input',
            block_id: 'reply_input',
            element: {
              type: 'plain_text_input',
              action_id: 'reply_text',
              multiline: true,
              initial_value: value['draft']
            },
            label: { type: 'plain_text', text: 'Your reply' }
          }
        ]
      }
    )

  when 'dismiss_reply'
    SLACK.chat_update(
      channel: ALERT_CHANNEL_ID,
      ts: alert_ts,
      text: ':x: Dismissed.',
      blocks: []
    )
  end
end

def handle_modal_submit(payload)
  meta = JSON.parse(payload.dig('view', 'private_metadata') || '{}')
  text = payload.dig('view', 'state', 'values', 'reply_input', 'reply_text', 'value')
  return unless text && meta['channel_id']

  SLACK.chat_postMessage(
    channel: meta['channel_id'],
    thread_ts: meta['thread_ts'],
    text: text
  )
  if meta['alert_ts']
    SLACK.chat_update(
      channel: ALERT_CHANNEL_ID,
      ts: meta['alert_ts'],
      text: ':white_check_mark: Reply sent (edited).',
      blocks: []
    )
  end
end

puts "\n[ready] Slack Assistant running in :#{MODE} mode"
puts "  monitoring #{MONITORED_CHANNELS.size} channels"
puts "  alerts → ##{ALERT_CHANNEL_NAME}"

if TEST_MODE
  puts "\n[test] Sending synthetic message through the pipeline..."
  fake_channel_id, fake_channel_name = MONITORED_CHANNELS.first
  fake_event = {
    'channel' => fake_channel_id,
    'user'    => 'U_SOMEONE_ELSE',
    'ts'      => Time.now.to_f.to_s,
    'text'    => "Hey, is there anyone who can help with this? Getting some errors in production."
  }
  puts "  channel: ##{fake_channel_name}"
  puts "  text: #{fake_event['text']}"

  if relevant?(fake_channel_name, fake_event['text'])
    puts "  → relevant! posting alert..."
    case MODE
    when :monitor
      post_alert(channel_id: fake_channel_id, channel_name: fake_channel_name, event: fake_event, reason: 'Test: semantically relevant')
    when :draft, :auto
      draft = draft_reply(fake_channel_name, fake_event['text'])
      puts "  draft: #{draft}"
      post_alert(channel_id: fake_channel_id, channel_name: fake_channel_name, event: fake_event, reason: 'Test: semantically relevant', draft: draft)
    end
    puts "  [test] Check ##{ALERT_CHANNEL_NAME} in Slack — alert should be there."
  else
    puts "  → not relevant (try adjusting your relevance_prompt)"
  end
  exit 0
end

puts "  Press Ctrl+C to stop\n\n"

# ─────────────────────────────────────────────
# Socket Mode
# ─────────────────────────────────────────────
def handle_message_event(event)
  channel_id = event['channel']
  return if channel_id == ALERT_CHANNEL_ID
  return unless MONITORED_CHANNELS.key?(channel_id)
  return if event['subtype']
  return if event['user'] == MY_USER_ID && !CONFIG['monitor_self']

  channel_name = MONITORED_CHANNELS[channel_id]
  text = event['text'] || ''

  puts "[msg] ##{channel_name}: #{text.slice(0, 80)}"

  thread_context = event['thread_ts'] ? fetch_thread_context(channel_id, event['thread_ts']) : nil

  reason = if mention?(text)
    puts '  → direct mention, flagging immediately'
    'You were directly mentioned'
  elsif relevant?(channel_name, text, thread_context)
    puts '  → semantically relevant'
    'Relevant to your team/domain'
  else
    puts '  → not relevant, skipping'
    return
  end

  case MODE
  when :monitor
    post_alert(channel_id: channel_id, channel_name: channel_name, event: event, reason: reason)
  when :draft
    draft = draft_reply(channel_name, text, thread_context)
    post_alert(channel_id: channel_id, channel_name: channel_name, event: event, reason: reason, draft: draft)
  when :auto
    draft = draft_reply(channel_name, text, thread_context)
    thread_ts = event['thread_ts'] || event['ts']
    SLACK.chat_postMessage(channel: channel_id, thread_ts: thread_ts, text: draft)
    puts '  → auto-sent reply'
    post_alert(channel_id: channel_id, channel_name: channel_name, event: event, reason: reason, draft: "(auto-sent) #{draft}")
  end
end

def open_wss_url
  SLACK_SOCKET.apps_connections_open.url
end

def connect_socket
  wss_url = open_wss_url
  ws = Faye::WebSocket::Client.new(wss_url)

  ws.on :open do
    puts '[socket] Connected'
    # Ping every 30s — forces close detection if connection goes stale after sleep/wake
    @ping_timer = EM.add_periodic_timer(30) { ws.ping }
  end

  ws.on :message do |msg|
    data = JSON.parse(msg.data) rescue next

    # Ack immediately so Slack doesn't retry before we finish processing
    if (eid = data['envelope_id'])
      ws.send(JSON.generate(envelope_id: eid))
      next if SEEN_ENVELOPES[eid]
      SEEN_ENVELOPES[eid] = true
      SEEN_ENVELOPES.delete(SEEN_ENVELOPES.keys.first) if SEEN_ENVELOPES.size > 500
    end

    # Defer blocking work (Anthropic API calls) off the reactor thread
    EM.defer do
      begin
        case data['type']
        when 'events_api'
          slack_event = data.dig('payload', 'event')
          handle_message_event(slack_event) if slack_event&.fetch('type', nil) == 'message'

        when 'interactive'
          payload = data['payload']
          case payload&.fetch('type', nil)
          when 'block_actions'   then handle_action(payload)
          when 'view_submission' then handle_modal_submit(payload)
          end
        end
      rescue => e
        puts "[event error] #{e.message}"
      end
    end
  end

  ws.on :close do |event|
    @ping_timer&.cancel
    puts "[socket] Disconnected (#{event.code}): #{event.reason}. Reconnecting in 5s..."
    EM.add_timer(5) { connect_socket }
  end

  ws.on :error do |event|
    puts "[socket error] #{event.message}"
  end
end

EM.run do
  Signal.trap('INT')  { EM.stop }
  Signal.trap('TERM') { EM.stop }

  connect_socket
end