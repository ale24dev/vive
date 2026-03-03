import os
import uuid
import glob
import logging
import socket
import re
from urllib.parse import quote, urlparse, parse_qs

from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.responses import FileResponse
from pydantic import BaseModel
import yt_dlp

# Force IPv4 — some containers have broken IPv6 DNS
_original_getaddrinfo = socket.getaddrinfo

def _ipv4_only_getaddrinfo(*args, **kwargs):
    responses = _original_getaddrinfo(*args, **kwargs)
    return [r for r in responses if r[0] == socket.AF_INET] or responses

socket.getaddrinfo = _ipv4_only_getaddrinfo

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="Vive Downloader",
    description="YouTube audio/video downloader API for Vive app",
    version="0.1.0",
)

DOWNLOAD_DIR = "/tmp/downloads"
COOKIES_FILE = "/tmp/cookies.txt"
os.makedirs(DOWNLOAD_DIR, exist_ok=True)

# Write cookies from environment variable to file (if provided)
_cookies_content = os.environ.get("YOUTUBE_COOKIES")
if _cookies_content:
    with open(COOKIES_FILE, "w") as f:
        f.write(_cookies_content)
    logger.info("YouTube cookies loaded from environment")


def get_base_ydl_opts() -> dict:
    """Return base yt-dlp options, including cookies if available."""
    opts = {
        "quiet": True,
        "no_warnings": True,
    }
    if os.path.exists(COOKIES_FILE):
        opts["cookiefile"] = COOKIES_FILE
    return opts


def extract_clean_url(url: str) -> str:
    """Extract video ID from any YouTube URL format and return a clean URL.

    Supports:
      - https://www.youtube.com/watch?v=ID&list=...&start_radio=...
      - https://youtu.be/ID?list=...
      - https://youtube.com/watch?v=ID
      - https://m.youtube.com/watch?v=ID
      - https://www.youtube.com/shorts/ID
    """
    # Try youtu.be short format
    parsed = urlparse(url)
    if parsed.hostname and "youtu.be" in parsed.hostname:
        video_id = parsed.path.lstrip("/")
        if video_id:
            return f"https://www.youtube.com/watch?v={video_id}"

    # Try youtube.com/shorts/ID
    shorts_match = re.match(r"/shorts/([a-zA-Z0-9_-]+)", parsed.path)
    if shorts_match:
        return f"https://www.youtube.com/watch?v={shorts_match.group(1)}"

    # Try youtube.com/watch?v=ID (strip playlist params)
    qs = parse_qs(parsed.query)
    video_id = qs.get("v", [None])[0]
    if video_id:
        return f"https://www.youtube.com/watch?v={video_id}"

    # Fallback: return as-is
    return url


def cleanup_file(filepath: str):
    """Remove a file after it has been sent."""
    try:
        if os.path.exists(filepath):
            os.remove(filepath)
            logger.info(f"Cleaned up: {filepath}")
    except OSError as e:
        logger.warning(f"Failed to cleanup {filepath}: {e}")


class InfoRequest(BaseModel):
    url: str


class DownloadRequest(BaseModel):
    url: str
    format: str = "mp3"  # "mp3" or "mp4"


@app.get("/health")
async def health():
    """Health check endpoint."""
    cookies_loaded = os.path.exists(COOKIES_FILE)
    return {
        "status": "ok",
        "service": "vive-downloader",
        "cookies_loaded": cookies_loaded,
    }


@app.get("/debug/network")
async def debug_network():
    """Debug endpoint to check outbound network connectivity."""
    import urllib.request
    results = {}

    # DNS test
    try:
        addr = socket.getaddrinfo("www.youtube.com", 443)
        results["dns_youtube"] = f"OK - {addr[0][4][0]}"
    except Exception as e:
        results["dns_youtube"] = f"FAIL - {str(e)}"

    # HTTP test
    try:
        req = urllib.request.Request("https://www.youtube.com", method="HEAD")
        resp = urllib.request.urlopen(req, timeout=5)
        results["http_youtube"] = f"OK - {resp.status}"
    except Exception as e:
        results["http_youtube"] = f"FAIL - {str(e)}"

    # Generic DNS
    try:
        addr = socket.getaddrinfo("huggingface.co", 443)
        results["dns_hf"] = f"OK - {addr[0][4][0]}"
    except Exception as e:
        results["dns_hf"] = f"FAIL - {str(e)}"

    return results


@app.post("/info")
async def get_info(req: InfoRequest):
    """Extract video metadata without downloading."""
    clean_url = extract_clean_url(req.url)
    logger.info(f"Info request: {req.url} -> {clean_url}")

    try:
        ydl_opts = get_base_ydl_opts()

        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(clean_url, download=False)

            return {
                "title": info.get("title"),
                "artist": info.get("artist") or info.get("uploader"),
                "duration": info.get("duration"),
                "thumbnail": info.get("thumbnail"),
                "description": (info.get("description") or "")[:200],
            }

    except Exception as e:
        logger.error(f"Error extracting info: {e}")
        raise HTTPException(status_code=400, detail=f"Cannot process URL: {str(e)}")


@app.post("/download")
async def download(req: DownloadRequest, background_tasks: BackgroundTasks):
    """Download video/audio and return the file."""
    if req.format not in ("mp3", "mp4"):
        raise HTTPException(status_code=400, detail="Format must be 'mp3' or 'mp4'")

    clean_url = extract_clean_url(req.url)
    logger.info(f"Download request: {req.url} -> {clean_url}")

    file_id = str(uuid.uuid4())
    output_template = os.path.join(DOWNLOAD_DIR, f"{file_id}.%(ext)s")

    try:
        base_opts = get_base_ydl_opts()

        if req.format == "mp3":
            ydl_opts = {
                **base_opts,
                "format": "bestaudio/best",
                "postprocessors": [
                    {
                        "key": "FFmpegExtractAudio",
                        "preferredcodec": "mp3",
                        "preferredquality": "320",
                    },
                    {
                        "key": "FFmpegMetadata",
                        "add_metadata": True,
                    },
                ],
                "outtmpl": output_template,
            }
        else:
            ydl_opts = {
                **base_opts,
                "format": "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
                "postprocessors": [
                    {
                        "key": "FFmpegVideoRemuxer",
                        "preferedformat": "mp4",
                    },
                ],
                "outtmpl": output_template,
            }

        # Get video info first for the filename
        with yt_dlp.YoutubeDL(base_opts) as ydl:
            info = ydl.extract_info(clean_url, download=False)
            video_title = info.get("title", "download")
            artist = info.get("artist") or info.get("uploader") or "Unknown"
            duration = info.get("duration") or 0

        logger.info(f"Starting download: {video_title} ({req.format})")

        # Download (blocking — runs in thread pool via uvicorn)
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([clean_url])

        # Find the generated file
        pattern = os.path.join(DOWNLOAD_DIR, f"{file_id}.*")
        files = glob.glob(pattern)

        if not files:
            raise HTTPException(
                status_code=500,
                detail="Download completed but file not found",
            )

        filepath = files[0]
        file_ext = os.path.splitext(filepath)[1]
        safe_title = "".join(
            c for c in video_title if c.isalnum() or c in " -_"
        ).strip()
        download_filename = f"{safe_title}{file_ext}"
        file_size = os.path.getsize(filepath)

        logger.info(f"Download complete: {download_filename} ({file_size} bytes)")

        # Schedule cleanup AFTER the response is sent
        background_tasks.add_task(cleanup_file, filepath)

        # Use ASCII-safe headers (URL-encode non-ASCII values)
        return FileResponse(
            path=filepath,
            filename=download_filename,
            media_type="application/octet-stream",
            headers={
                "X-Video-Title": quote(video_title, safe=""),
                "X-Video-Artist": quote(artist, safe=""),
                "X-Video-Duration": str(duration),
                "X-File-Size": str(file_size),
            },
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error downloading: {e}", exc_info=True)
        # Cleanup on error
        pattern = os.path.join(DOWNLOAD_DIR, f"{file_id}.*")
        for f in glob.glob(pattern):
            try:
                os.remove(f)
            except OSError:
                pass
        raise HTTPException(status_code=500, detail=f"Download failed: {str(e)}")


@app.get("/")
async def root():
    """Root endpoint with API info."""
    return {
        "service": "Vive Downloader",
        "version": "0.1.0",
        "endpoints": {
            "GET /health": "Health check",
            "POST /info": "Get video metadata (body: {url: string})",
            "POST /download": "Download video/audio (body: {url: string, format: 'mp3'|'mp4'})",
        },
    }
