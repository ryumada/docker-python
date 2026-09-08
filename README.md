# Docker Python Granian Deployer

A modular, production-grade Docker deployment harness for Python web applications powered by [Granian](https://github.com/emmett-framework/granian) — a high-performance HTTP server written in Rust.

Designed to serve as a generic deployment wrapper: clone any Python repository into the `app/` directory, configure your target entrypoint, and deploy in seconds.

---

## Key Features

- **Multi-Framework Support**: Seamlessly deploys **WSGI** applications (Flask, Django) and **ASGI** applications (FastAPI, Starlette, Litestar).
- **Generic & Pluggable**: Clone any Python app into `app/<repo-name>` without altering container paths.
- **Dependency Chaining**: Automatically installs container-level dependencies (`requirements.txt`) and app-specific dependencies (`app/<repo-name>/requirements.txt`).
- **High-Performance Rust Core**: Granian handles request routing, multi-process workers, and threading with low memory footprint and high throughput.
- **Automated Pre-flight Checker (`setup.sh`)**:
  - Validates host dependencies (Docker, Compose, curl, port availability).
  - Performs static AST code checks to verify entrypoint callables and detect common container pitfalls (unconditional `app.run()`, hardcoded host paths, static secret keys).
  - Automatically generates cryptographically secure secrets in `.env`.
- **Security & Best Practices**:
  - Based on `python:3.11-slim`.
  - Runs as an unprivileged, non-root user (`appuser`).
  - Real-time unbuffered logging with `PYTHONUNBUFFERED=1`.

---

## Directory Structure

```text
docker-python/
├── Dockerfile             # Multi-framework Dockerfile with dynamic entrypoint
├── docker-compose.yml     # Compose service specification
├── requirements.txt       # Base server dependencies (Granian, python-dotenv, etc.)
├── setup.sh               # Pre-flight checker, test suite, and management script
├── .env.example           # Fully documented environment configuration template
├── .env                   # Local environment configuration (git-ignored)
├── .gitignore             # Standard Python/Docker ignore rules
├── LICENSE                # MIT License
└── app/                   # Root directory for cloned applications
    ├── .gitkeep
    └── <your_app_folder>/ # Cloned Python repository
        ├── index.py (or main.py)
        └── requirements.txt (optional app dependencies)
```

---

## Quick Start

### 1. Clone your application into `app/`
Clone your Python project into a subdirectory under `app/`:

```bash
# Example: Flask or FastAPI repository
git clone https://github.com/your-org/my-python-app.git app/my-python-app
```

### 2. Configure the environment
Create `.env` from the provided template:

```bash
./setup.sh --create-env
```

Edit `.env` to match your application:

```env
# Cloned folder name inside ./app/
APP_DIRNAME=my-python-app

# Entrypoint in <module_filename>:<callable_object> format
GRANIAN_TARGET=index:app

# Interface: wsgi (Flask/Django) or asgi (FastAPI/Starlette)
GRANIAN_INTERFACE=wsgi

# Port exposed on host
GRANIAN_PORT=5000
```

### 3. Run Pre-flight Verification
Check that your environment, code, and ports are ready:

```bash
./setup.sh --check
```

### 4. Build and Start Container
```bash
./setup.sh --up
```

### 5. Verify & Monitor
Test the health of your deployed server:

```bash
# Test endpoint connectivity
./setup.sh --test

# View live container logs
./setup.sh --logs
```

---

## Framework Configuration Examples

| Framework | `GRANIAN_INTERFACE` | Example `GRANIAN_TARGET` | File Location |
| :--- | :--- | :--- | :--- |
| **Flask** | `wsgi` | `index:app` | `app/<repo>/index.py` |
| **Flask** | `wsgi` | `app:app` | `app/<repo>/app.py` |
| **FastAPI** | `asgi` | `main:app` | `app/<repo>/main.py` |
| **Starlette** | `asgi` | `server:app` | `app/<repo>/server.py` |
| **Django** | `wsgi` | `myproject.wsgi:application` | `app/<repo>/myproject/wsgi.py` |

---

## `setup.sh` CLI Reference

The included `setup.sh` script provides full lifecycle management:

| Command | Description |
| :--- | :--- |
| `./setup.sh` or `./setup.sh --check` | Run all 5-stage pre-flight checks (Docker, code, .env, ports) |
| `./setup.sh --check-code` | Statically inspect Python entrypoint for Granian compatibility |
| `./setup.sh --fix-code` | Auto-patch legacy code to load environment variables safely (with `.bak` backup) |
| `./setup.sh --create-env` | Generate `.env` from template with a fresh cryptographic `SECRET_KEY` |
| `./setup.sh --build` | Build or rebuild the Docker container image |
| `./setup.sh --up` (or `--start`) | Build and launch the container in the background |
| `./setup.sh --down` (or `--stop`) | Gracefully stop and tear down the container |
| `./setup.sh --restart` | Restart the container |
| `./setup.sh --test` | Send a test HTTP request to the running server |
| `./setup.sh --logs` | Stream live container logs |
| `./setup.sh --help` | Display command-line usage instructions |

---

## Environment Variables Reference

| Variable | Default | Description |
| :--- | :--- | :--- |
| `APP_DIRNAME` | *(required)* | Folder name of the cloned application under `./app/` |
| `GRANIAN_TARGET` | `index:app` | Entrypoint module and callable (`<module>:<callable>`) |
| `GRANIAN_INTERFACE` | `wsgi` | Application protocol (`wsgi` or `asgi`) |
| `GRANIAN_HOST` | `0.0.0.0` | Bind host address inside the container |
| `GRANIAN_PORT` | `5000` | Port on which Granian listens inside the container |
| `GRANIAN_WORKERS` | `2` | Number of worker processes spawned by Granian |
| `GRANIAN_THREADS` | `1` | Number of threads per worker process |
| `GRANIAN_LOG_LEVEL` | `info` | Granian log verbosity (`info`, `warning`, `error`, `debug`) |
| `PYTHONUNBUFFERED` | `1` | Ensures standard output/error flush immediately to Docker logs |
| `SECRET_KEY` | *(generated)* | Application secret key for JWT signing / session management |

---

## License

This project is licensed under the [MIT License](LICENSE).
