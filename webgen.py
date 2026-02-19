import os
import json
import shutil
import requests
from glob import glob
import asyncio
import aiofiles
import aiofiles.os
import subprocess
import io
import zipfile

from pydantic import BaseModel
from fastapi import FastAPI, HTTPException, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

BASE_DIR = '/workspace/'


def zip_directory_to_bytes(dir_path: str) -> io.BytesIO:
    zip_buffer = io.BytesIO()
    index_path = os.path.join(dir_path, "index.html")
    if not os.path.isfile(index_path):
        raise FileNotFoundError("index.html not found in website directory")
    with zipfile.ZipFile(zip_buffer, "w", zipfile.ZIP_DEFLATED) as zipf:
        zipf.write(index_path, "index.html")
    zip_buffer.seek(0)
    return zip_buffer


async def zip_directory_async(dir_path: str) -> io.BytesIO:
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, zip_directory_to_bytes, dir_path)


class SendRequest(BaseModel):
    snapshot: str


class ReceiveRequest(BaseModel):
    website_id: str


def save_snapshot_and_update_task(snapshot, website_dir):
    sources = []
    for line in snapshot.splitlines():
        if line.startswith("Source: https:"):
            sources.append([
                line.split("Source: ")[-1].replace('/', '_').replace('.', '_'), []
            ])
        else:
            if sources:
                sources[-1][-1].append(line)

    filenames = []
    for [filename, lines] in sources:
        output_file = os.path.join(website_dir, f'{filename}.md')
        content = '\n\n'.join(lines)
        mode = 'a'
        if os.path.isfile(output_file):
            content = "\n\n" + content
        with open(output_file, mode) as fout:
            fout.write(content)
        fname = f"@{filename}"
        if fname not in filenames:
            filenames.append(fname)

    customer_data = " - use the data in the following files to customize the website: " + ", ".join(filenames)
    with open(os.path.join(website_dir, 'task.txt'), 'a') as fout:
        fout.write(customer_data)


@app.post("/start")
def start(send_request: SendRequest):
    existing_websites = sorted(
        glob(os.path.join(BASE_DIR, 'website_*')),
        key=lambda x: int(x.split('_')[-1])
    )
    website_id = 'website_1'
    if existing_websites:
        last_id = int(existing_websites[-1].split(os.path.sep)[-1].split('_')[-1])
        website_id = f'website_{last_id + 1}'

    WEBSITE_DIR = os.path.join(BASE_DIR, website_id)
    shutil.copytree(os.path.join(BASE_DIR, "webgen_template"), WEBSITE_DIR, dirs_exist_ok=False)
    save_snapshot_and_update_task(send_request.snapshot, WEBSITE_DIR)

    log_path = os.path.join(WEBSITE_DIR, "ccr.log")
    nvm_setup = (
        'export HOME=/home/dev && export NVM_DIR="$HOME/.nvm" && '
        '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
    )

    with open(log_path, "wb") as log_file:
        proc = subprocess.Popen(
            [
                "su",
                "dev",
                "-s",
                "/bin/bash",
                "-c",
                f'{nvm_setup} && NODE_NO_WARNINGS=1 ccr code '
                '--dangerously-skip-permissions '
                '--verbose '
                '--system-prompt-file task.txt '
                '--print "Customize this landing page"'
            ],
            cwd=WEBSITE_DIR,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )

    meta = {
        "website_id": website_id,
        "pid": proc.pid,
        "pgid": os.getpgid(proc.pid),
        "status": "running"
    }
    with open(os.path.join(WEBSITE_DIR, "process.json"), "w") as f:
        json.dump(meta, f)

    return Response(
        content=json.dumps({"website_id": website_id, "status": "accepted"}),
        media_type="application/json",
        status_code=202
    )


async def process_state(pid: int) -> str:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return "dead"
    except PermissionError:
        pass  # exists

    try:
        async with aiofiles.open(f"/proc/{pid}/stat", "r") as f:
            data = await f.read()
            return "zombie" if data.split()[2] == "Z" else "running"
    except FileNotFoundError:
        return "dead"


@app.get("/status/{website_id}")
async def status(website_id: str):
    meta_path = os.path.join(BASE_DIR, website_id, "process.json")
    if not await aiofiles.os.path.exists(meta_path):
        raise HTTPException(status_code=404, detail="Job not found")
    async with aiofiles.open(meta_path, "r") as f:
        meta = json.loads(await f.read())
    pid = meta.get("pid")
    if not pid:
        return {"status": "failed"}
    state = await process_state(pid)
    return {"status": "running" if state == "running" else "done"}


@app.get("/download/{website_id}")
async def download(website_id: str):
    website_dir = os.path.join(BASE_DIR, website_id)
    meta_path = os.path.join(website_dir, "process.json")
    if not await aiofiles.os.path.exists(meta_path):
        raise HTTPException(status_code=404, detail="Job not found")
    async with aiofiles.open(meta_path, "r") as f:
        meta = json.loads(await f.read())
    pid = meta.get("pid")
    if not pid:
        raise HTTPException(status_code=400, detail="Invalid job metadata")
    state = await process_state(pid)
    if state == "running":
        raise HTTPException(status_code=409, detail="Job still running")
    zip_bytes = await zip_directory_async(website_dir)
    return StreamingResponse(
        zip_bytes,
        media_type="application/zip",
        headers={"Content-Disposition": f"attachment; filename={website_id}.zip"}
    )


@app.delete("/delete/{website_id}")
async def delete_website(website_id: str):
    website_dir = os.path.join(BASE_DIR, website_id)
    if not os.path.exists(website_dir):
        raise HTTPException(status_code=404, detail="Not found")
    shutil.rmtree(website_dir)
    return {"status": "deleted", "website_id": website_id}
