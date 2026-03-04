import os
import uuid
import glob
import logging
import socket
import re
import threading
from urllib.parse import quote, urlparse, parse_qs
from typing import Optional
from enum import Enum

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
    version="0.2.0",
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


# ─── Job Management ─────────────────────────────────────────────────────────

class JobStatus(str, Enum):
    PENDING = "pending"
    DOWNLOADING = "downloading"
    PROCESSING = "processing"
    COMPLETED = "completed"
    FAILED = "failed"


class Job:
    def __init__(self, job_id: str, url: str, format: str):
        self.id = job_id
        self.url = url
        self.format = format
        self.status = JobStatus.PENDING
        self.progress = 0
        self.error: Optional[str] = None
        self.file_path: Optional[str] = None
        self.file_name: Optional[str] = None
        self.title: Optional[str] = None
        self.artist: Optional[str] = None
        self.duration: int = 0
        self.file_size: int = 0


# In-memory job storage (jobs expire after download)
_jobs: dict[str, Job] = {}
_jobs_lock = threading.Lock()


def get_job(job_id: str) -> Optional[Job]:
    with _jobs_lock:
        return _jobs.get(job_id)


def set_job(job: Job):
    with _jobs_lock:
        _jobs[job.id] = job


def delete_job(job_id: str):
    with _jobs_lock:
        _jobs.pop(job_id, None)


# ─── Helpers ────────────────────────────────────────────────────────────────

def get_base_ydl_opts() -> dict:
    """Return base yt-dlp options, including cookies if available."""
    opts = {
        "quiet": True,
        "no_warnings": True,
    }
    if os.path.exists(COOKIES_FILE):
        opts["cookiefile"] = COOKIES_FILE
        logger.info(f"Using cookies from {COOKIES_FILE}")
    return opts


def extract_clean_url(url: str) -> str:
    """Extract video ID from any YouTube URL format and return a clean URL."""
    parsed = urlparse(url)
    if parsed.hostname and "youtu.be" in parsed.hostname:
        video_id = parsed.path.lstrip("/")
        if video_id:
            return f"https://www.youtube.com/watch?v={video_id}"

    shorts_match = re.match(r"/shorts/([a-zA-Z0-9_-]+)", parsed.path)
    if shorts_match:
        return f"https://www.youtube.com/watch?v={shorts_match.group(1)}"

    qs = parse_qs(parsed.query)
    video_id = qs.get("v", [None])[0]
    if video_id:
        return f"https://www.youtube.com/watch?v={video_id}"

    return url


def cleanup_file(filepath: str):
    """Remove a file after it has been sent."""
    try:
        if os.path.exists(filepath):
            os.remove(filepath)
            logger.info(f"Cleaned up: {filepath}")
    except OSError as e:
        logger.warning(f"Failed to cleanup {filepath}: {e}")


def run_download(job: Job):
    """Background task to download video/audio."""
    try:
        clean_url = extract_clean_url(job.url)
        job.status = JobStatus.DOWNLOADING
        set_job(job)

        base_opts = get_base_ydl_opts()
        file_id = job.id
        output_template = os.path.join(DOWNLOAD_DIR, f"{file_id}.%(ext)s")

        # Progress hook
        def progress_hook(d):
            if d["status"] == "downloading":
                total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
                downloaded = d.get("downloaded_bytes", 0)
                if total > 0:
                    job.progress = int((downloaded / total) * 100)
                    set_job(job)

        if job.format == "mp3":
            # Download best audio in m4a/aac format (no conversion needed)
            # m4a is widely supported and has better quality than mp3 at same bitrate
            ydl_opts = {
                **base_opts,
                "format": "bestaudio[ext=m4a]/bestaudio/best",
                "postprocessors": [
                    {
                        "key": "FFmpegMetadata",
                        "add_metadata": True,
                    },
                ],
                "outtmpl": output_template,
                "progress_hooks": [progress_hook],
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
                "progress_hooks": [progress_hook],
            }

        # Get video info
        with yt_dlp.YoutubeDL(base_opts) as ydl:
            info = ydl.extract_info(clean_url, download=False)
            job.title = info.get("title", "download")
            job.artist = info.get("artist") or info.get("uploader") or "Unknown"
            job.duration = info.get("duration") or 0
            set_job(job)

        logger.info(f"Starting download: {job.title} ({job.format})")

        # Download
        job.status = JobStatus.PROCESSING
        set_job(job)

        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([clean_url])

        # Find the generated file
        pattern = os.path.join(DOWNLOAD_DIR, f"{file_id}.*")
        files = glob.glob(pattern)

        if not files:
            job.status = JobStatus.FAILED
            job.error = "Download completed but file not found"
            set_job(job)
            return

        filepath = files[0]
        file_ext = os.path.splitext(filepath)[1]
        safe_title = "".join(
            c for c in job.title if c.isalnum() or c in " -_"
        ).strip()
        
        job.file_path = filepath
        job.file_name = f"{safe_title}{file_ext}"
        job.file_size = os.path.getsize(filepath)
        job.status = JobStatus.COMPLETED
        job.progress = 100
        set_job(job)

        logger.info(f"Download complete: {job.file_name} ({job.file_size} bytes)")

    except Exception as e:
        logger.error(f"Error downloading: {e}", exc_info=True)
        job.status = JobStatus.FAILED
        job.error = str(e)
        set_job(job)
        
        # Cleanup on error
        pattern = os.path.join(DOWNLOAD_DIR, f"{job.id}.*")
        for f in glob.glob(pattern):
            try:
                os.remove(f)
            except OSError:
                pass


# ─── Request/Response Models ────────────────────────────────────────────────

class InfoRequest(BaseModel):
    url: str


class DownloadRequest(BaseModel):
    url: str
    format: str = "mp3"


class JobResponse(BaseModel):
    job_id: str
    status: str
    progress: int
    error: Optional[str] = None
    title: Optional[str] = None
    artist: Optional[str] = None
    duration: int = 0
    file_size: int = 0


# ─── Endpoints ──────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    """Health check endpoint."""
    cookies_loaded = os.path.exists(COOKIES_FILE)
    cookies_size = 0
    cookies_lines = 0
    if cookies_loaded:
        try:
            with open(COOKIES_FILE, "r") as f:
                content = f.read()
                cookies_size = len(content)
                cookies_lines = len([l for l in content.split("\n") if l.strip() and not l.startswith("#")])
        except Exception:
            pass
    return {
        "status": "ok",
        "service": "vive-downloader",
        "version": "0.2.0",
        "cookies_loaded": cookies_loaded,
        "cookies_size": cookies_size,
        "cookies_lines": cookies_lines,
    }


@app.get("/debug/network")
async def debug_network():
    """Debug endpoint to check outbound network connectivity."""
    import urllib.request
    import subprocess
    results = {}

    try:
        addr = socket.getaddrinfo("www.youtube.com", 443)
        results["dns_youtube"] = f"OK - {addr[0][4][0]}"
    except Exception as e:
        results["dns_youtube"] = f"FAIL - {str(e)}"

    try:
        req = urllib.request.Request("https://www.youtube.com", method="HEAD")
        resp = urllib.request.urlopen(req, timeout=5)
        results["http_youtube"] = f"OK - {resp.status}"
    except Exception as e:
        results["http_youtube"] = f"FAIL - {str(e)}"

    try:
        result = subprocess.run(["deno", "--version"], capture_output=True, text=True, timeout=5)
        results["deno"] = result.stdout.strip().split("\n")[0] if result.returncode == 0 else f"FAIL - {result.stderr}"
    except Exception as e:
        results["deno"] = f"FAIL - {str(e)}"

    try:
        results["yt_dlp_version"] = yt_dlp.version.__version__
    except Exception as e:
        results["yt_dlp_version"] = f"FAIL - {str(e)}"

    try:
        import yt_dlp_ejs
        results["yt_dlp_ejs"] = "OK"
    except ImportError:
        results["yt_dlp_ejs"] = "NOT INSTALLED"
    except Exception as e:
        results["yt_dlp_ejs"] = f"FAIL - {str(e)}"

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


@app.post("/download/start", response_model=JobResponse)
async def start_download(req: DownloadRequest, background_tasks: BackgroundTasks):
    """Start an async download job. Returns immediately with job_id."""
    if req.format not in ("mp3", "mp4"):
        raise HTTPException(status_code=400, detail="Format must be 'mp3' or 'mp4'")

    job_id = str(uuid.uuid4())
    job = Job(job_id, req.url, req.format)
    set_job(job)

    logger.info(f"Created job {job_id} for {req.url}")

    # Start download in background
    background_tasks.add_task(run_download, job)

    return JobResponse(
        job_id=job.id,
        status=job.status.value,
        progress=job.progress,
    )


@app.get("/download/status/{job_id}", response_model=JobResponse)
async def get_download_status(job_id: str):
    """Check the status of a download job."""
    job = get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")

    return JobResponse(
        job_id=job.id,
        status=job.status.value,
        progress=job.progress,
        error=job.error,
        title=job.title,
        artist=job.artist,
        duration=job.duration,
        file_size=job.file_size,
    )


@app.get("/download/file/{job_id}")
async def get_download_file(job_id: str, background_tasks: BackgroundTasks):
    """Download the completed file."""
    job = get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")

    if job.status != JobStatus.COMPLETED:
        raise HTTPException(status_code=400, detail=f"Job not ready: {job.status.value}")

    if not job.file_path or not os.path.exists(job.file_path):
        raise HTTPException(status_code=404, detail="File not found")

    # Schedule cleanup after response
    background_tasks.add_task(cleanup_file, job.file_path)
    background_tasks.add_task(delete_job, job_id)

    return FileResponse(
        path=job.file_path,
        filename=job.file_name,
        media_type="application/octet-stream",
        headers={
            "X-Video-Title": quote(job.title or "", safe=""),
            "X-Video-Artist": quote(job.artist or "", safe=""),
            "X-Video-Duration": str(job.duration),
            "X-File-Size": str(job.file_size),
        },
    )


# Keep old endpoint for backwards compatibility
@app.post("/download")
async def download_sync(req: DownloadRequest, background_tasks: BackgroundTasks):
    """Legacy sync download - prefer /download/start for new clients."""
    if req.format not in ("mp3", "mp4"):
        raise HTTPException(status_code=400, detail="Format must be 'mp3' or 'mp4'")

    clean_url = extract_clean_url(req.url)
    logger.info(f"Download request: {req.url} -> {clean_url}")

    file_id = str(uuid.uuid4())
    output_template = os.path.join(DOWNLOAD_DIR, f"{file_id}.%(ext)s")

    try:
        base_opts = get_base_ydl_opts()

        if req.format == "mp3":
            # Download best audio in m4a/aac format (no conversion needed)
            ydl_opts = {
                **base_opts,
                "format": "bestaudio[ext=m4a]/bestaudio/best",
                "postprocessors": [
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

        with yt_dlp.YoutubeDL(base_opts) as ydl:
            info = ydl.extract_info(clean_url, download=False)
            video_title = info.get("title", "download")
            artist = info.get("artist") or info.get("uploader") or "Unknown"
            duration = info.get("duration") or 0

        logger.info(f"Starting download: {video_title} ({req.format})")

        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([clean_url])

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

        background_tasks.add_task(cleanup_file, filepath)

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
        "version": "0.2.0",
        "endpoints": {
            "GET /health": "Health check",
            "POST /info": "Get video metadata",
            "POST /download/start": "Start async download (returns job_id)",
            "GET /download/status/{job_id}": "Check job status",
            "GET /download/file/{job_id}": "Download completed file",
            "POST /download": "Legacy sync download",
        },
    }
