FROM python:3.11-slim

# Install system dependencies (ffmpeg for audio extraction, curl for deno, unzip)
RUN apt-get update && \
    apt-get install -y --no-install-recommends ffmpeg curl unzip && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user (Render requirement)
RUN useradd -m -u 1000 user
USER user

# Install Deno for the non-root user (required for yt-dlp YouTube support)
RUN curl -fsSL https://deno.land/install.sh | sh
ENV DENO_INSTALL="/home/user/.deno"
ENV PATH="${DENO_INSTALL}/bin:/home/user/.local/bin:${PATH}"

WORKDIR /app

# Install Python dependencies
COPY --chown=user requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir --upgrade "yt-dlp[default]"

# Copy application code
COPY --chown=user . .

# Render uses PORT env var (default 10000), fallback to 7860 for local dev
EXPOSE 10000

CMD ["sh", "-c", "uvicorn app:app --host 0.0.0.0 --port ${PORT:-10000}"]
