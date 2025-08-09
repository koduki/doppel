# Doppel

Doppel is a Sinatra-based application that serves as a bridge between various frontends and gemini-cli. It provides a web interface with Server-Sent Events (SSE) for real-time communication and integrates a Discord bot that responds to DMs and mentions.

This application is designed to work with [koduki/gemini-cli-proxy](https://github.com/koduki/gemini-cli-proxy) as its gemini-cli wrapper.

## Features

*   **Web Interface:** A simple web UI to interact with the backend service.
*   **Real-time Streaming:** Uses Server-Sent Events (SSE) to stream responses to the web UI.
*   **Discord Bot Integration:** A fully integrated Discord bot using the `discorb` gem.
    *   Responds to Direct Messages (DMs).
    *   Responds to @mentions in server channels.
    *   Streams responses from the backend service directly into Discord messages by progressively editing them.
*   **Dockerized:** Comes with `Dockerfile` and `docker-compose.yaml` for easy setup and deployment.

## Requirements

*   Docker
*   Docker Compose
*   A running instance of [gemini-cli-proxy](https://github.com/koduki/gemini-cli-proxy)

## Setup

1.  **Set up the backend service:**
    This application requires the [gemini-cli-proxy](https://github.com/koduki/gemini-cli-proxy) to be running as the backend. Please follow the setup instructions in its repository first.

2.  **Clone this repository:**
    ```bash
    git clone <repository-url>
    cd doppel
    ```

3.  **Create the environment file:**
    Create a file named `.env` in the project root and add the following variables.

    ```env
    # The base URL for the backend AI service (gemini-cli-proxy)
    APP_BACKEND_ORIGIN=http://your-backend-service-url:3000/

    # Your Discord Bot Token
    DISCORD_TOKEN=your-discord-bot-token-here
    ```

    *   `APP_BACKEND_ORIGIN`: The application connects to `{APP_BACKEND_ORIGIN}api/chat` via HTTP to create sessions and to `{APP_BACKEND_ORIGIN}` via WebSocket for streaming.
    *   `DISCORD_TOKEN`: Required to run the Discord bot. If this is not provided, the bot will not start.

## Usage

To start the application, run the following command:

```bash
docker compose watch
```

The web interface will be available at `http://localhost:8080`.

## How It Works

*   **Web Server:** `Sinatra` handles HTTP requests.
*   **Web UI Streaming:** The `/stream` endpoint uses Server-Sent Events (SSE) to push data from the backend to the browser.
*   **Discord Bot:** The `discorb` gem connects to the Discord Gateway API to receive and respond to messages in real-time.
*   **Backend Communication:** The application communicates with its backend, [gemini-cli-proxy](https://github.com/koduki/gemini-cli-proxy). It creates a session via a POST request and then establishes a WebSocket connection for streaming the chat conversation.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

