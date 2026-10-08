FROM python:3.11-slim

ARG APP_DIRNAME
ENV APP_DIRNAME=${APP_DIRNAME}

# Prevent Python from writing .pyc files and enable unbuffered stdout/stderr
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Install base dependencies (Granian, etc.)
COPY requirements.txt ./base-requirements.txt
RUN pip install --no-cache-dir -r base-requirements.txt

# Copy application files from the cloned repository into /app
COPY app/${APP_DIRNAME}/ ./

# Install application dependencies if present in the cloned repository
RUN if [ -f "requirements.txt" ]; then pip install --no-cache-dir -r requirements.txt; fi

# Create data directory and non-root user for security (UID 1000 standard)
RUN mkdir -p /data && useradd -m appuser && chown -R appuser:appuser /app /data
USER appuser

VOLUME /data
EXPOSE 5000

# Run with Granian (interface, host, port, and entrypoint read from environment)
CMD ["sh", "-c", "granian --interface ${GRANIAN_INTERFACE:-wsgi} --host ${GRANIAN_HOST:-0.0.0.0} --port 5000 ${GRANIAN_TARGET:-index:app}"]
