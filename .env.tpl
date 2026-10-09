# loopex environment template: secrets are 1Password references (vault Dev).
# Make .env with:  op inject -i .env.tpl -o .env && chmod 600 .env
# Edit secrets in 1Password, not here. Plain settings below are not secret.

OPENAI_API_KEY=op://Dev/OpenAI API/credential
ANTHROPIC_API_KEY=op://Dev/Anthropic API/credential
GEMINI_API_KEY=op://Dev/Google Gemini API/credential
GROQ_API_KEY=op://Dev/Groq API/credential
OLLAMA_HOST=
XAI_API_KEY=op://Dev/xAI API/credential
HFHUB_API_KEY=op://Dev/Hugging Face API/credential
OPENROUTER_API_KEY=op://Dev/OpenRouter API/credential
TYPESAFE_API_KEY=op://Dev/Typesafe API/credential
# Logging configuration
# Valid levels: OFF, ERROR, WARN, INFO, DEBUG (default: INFO)
GO_LLMS_LOG_LEVEL=
#https://home.openweathermap.org/api_keys
WEATHER_API_KEY=op://Dev/Weather API/credential

#https://api-dashboard.search.brave.com/app/keys
BRAVE_API_KEY=op://Dev/Brave Search API/credential

#https://app.tavily.com/home
TAVILY_API_KEY=op://Dev/Tavily API/credential

#https://serpapi.com/dashboard
SERPAPI_API_KEY=op://Dev/SerpApi/credential

#https://serper.dev/
SERPERDEV_API_KEY=op://Dev/Serper API/credential

GITHUB_API_KEY=op://Dev/GitHub Token/credential

#https://www.ncbi.nlm.nih.gov/books/NBK25497/
PUBMED_API_KEY=op://Dev/PubMed API/credential

#https://api.core.ac.uk/docs/v3
COREAC_API_KEY=op://Dev/CORE API/credential

#https://newsapi.org/
NEWSAPI_API_KEY=op://Dev/NewsAPI/credential


## Validation steps for channels

ALLBERT_DISCORD_GATEWAY_INTENTS=
ALLBERT_DISCORD_MESSAGE_CONTENT_INTENT=
ALLBERT_DISCORD_AUTH_OK=
ALLBERT_DISCORD_ENDPOINT_OK=
ALLBERT_DISCORD_GATEWAY_STATUS=
ALLBERT_DISCORD_BOT_ID=
ALLBERT_DISCORD_BOT_USERNAME=


ALLBERT_EMAIL_IMAP_HOST=
ALLBERT_EMAIL_IMAP_PORT=
ALLBERT_EMAIL_IMAP_USERNAME=
ALLBERT_EMAIL_IMAP_PASSWORD=op://Dev/Allbert Email/imap_password
ALLBERT_EMAIL_SMTP_HOST=
ALLBERT_EMAIL_SMTP_PORT=
ALLBERT_EMAIL_SMTP_USERNAME=
ALLBERT_EMAIL_SMTP_PASSWORD=op://Dev/Allbert Email/smtp_password
ALLBERT_EMAIL_FROM_ADDRESS=

ALLBERT_EMAIL_MAPPED_SENDER=
ALLBERT_EMAIL_TO_ADDRESS=

#telegram allbert bot token
ALLBERT_TELEGRAM_BOT_TOKEN=op://Dev/Allbert Telegram/bot_token
ALLBERT_TELEGRAM_CHAT_ID=
ALLBERT_TELEGRAM_USER_ID=


ALLBERT_MATRIX_ROOM_ID=
ALLBERT_MATRIX_HOMESERVER_URL=
ALLBERT_MATRIX_ACCESS_TOKEN=op://Dev/Allbert Matrix/access_token
ALLBERT_MATRIX_USER_ID=
ALLBERT_MATRIX_UNMAPPED_USER_ID=

ALLBERT_DISCORD_BOT_TOKEN=op://Dev/Allbert Discord/bot_token
#ALLBERT)_ASSIST specific settings
ALLBERT_DISCORD_APPLICATION_ID=
ALLBERT_DISCORD_PUBLIC_KEY=
ALLBERT_DISCORD_GUILD_ID=
ALLBERT_DISCORD_CHANNEL_ID=
ALLBERT_DISCORD_USER_ID=
ALLBERT_DISCORD_UNMAPPED_USER_ID=
ALLBERT_MESSAGING_CHANNEL_INBOUND_TIMEOUT_MS=

ALLBERT_SLACK_BOT_TOKEN=op://Dev/Allbert Slack/bot_token
ALLBERT_SLACK_TEAM_ID=
ALLBERT_SLACK_CHANNEL_ID=
ALLBERT_SLACK_USER_ID=
ALLBERT_SLACK_DM_CHANNEL_ID=
ALLBERT_SLACK_UNMAPPED_USER_ID=
ALLBERT_SLACK_CLIENT_SECRET=op://Dev/Allbert Slack/client_secret
ALLBERT_SLACK_SIGNING_SECRET=op://Dev/Allbert Slack/signing_secret
ALLBERT_SLACK_CLIENT_ID=
ALLBERT_SLACK_APP_ID=
ALLBERT_SLACK_APP_TOKEN=op://Dev/Allbert Slack/app_token
