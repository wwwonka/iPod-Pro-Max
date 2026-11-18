#!/usr/bin/env python3
"""
SLSK-15 reproducible searchWindowSeconds benchmark.
Spawns ONE persistent soulseek-plugin JSON-RPC process and measures find rate and
time-to-first-accepted-candidate across 50 real tracks for windows [4, 6, 8, 12] s.
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import tempfile
import threading
import time

TRACKS = [
    ("Olivia Dean", "Man I Need", "Messy"),
    ("Daft Punk", "Around the World", "Homework"),
    ("Radiohead", "Creep", "Pablo Honey"),
    ("Kendrick Lamar", "HUMBLE.", "DAMN."),
    ("Beyoncé", "Halo", "I Am... Sasha Fierce"),
    ("Stromae", "Papaoutai", "Racine carrée"),
    ("Tame Impala", "The Less I Know The Better", "Currents"),
    ("Lorde", "Royals", "Pure Heroine"),
    ("Frank Ocean", "Nights", "Blonde"),
    ("Arctic Monkeys", "Do I Wanna Know?", "AM"),
    ("The Weeknd", "Blinding Lights", "After Hours"),
    ("Taylor Swift", "Cruel Summer", "Lover"),
    ("Billie Eilish", "bad guy", "WHEN WE ALL FALL ASLEEP, WHERE DO WE GO?"),
    ("Gorillaz", "Feel Good Inc.", "Demon Days"),
    ("Portishead", "Glory Box", "Dummy"),
    ("Miles Davis", "So What", "Kind of Blue"),
    ("Stevie Wonder", "Superstition", "Talking Book"),
    ("Fleetwood Mac", "Dreams", "Rumours"),
    ("Nirvana", "Smells Like Teen Spirit", "Nevermind"),
    ("Amy Winehouse", "Back to Black", "Back to Black"),
    ("Phoebe Bridgers", "Motion Sickness", "Stranger in the Alps"),
    ("Bon Iver", "Holocene", "Bon Iver"),
    ("Kaytranada", "10%", "BUBBA"),
    ("Disclosure", "Latch", "Settle"),
    ("Justice", "D.A.N.C.E.", "Cross"),
    ("Fred again..", "Delilah (pull me out of this)", "Actual Life 3"),
    ("Khruangbin", "Time (You and I)", "Mordechai"),
    ("Men I Trust", "Show Me How", "Oncle Jazz"),
    ("Alvvays", "Archie, Marry Me", "Alvvays"),
    ("Vampire Weekend", "A-Punk", "Vampire Weekend"),
    ("Phoenix", "1901", "Wolfgang Amadeus Phoenix"),
    ("MGMT", "Electric Feel", "Oracular Spectacular"),
    ("The Strokes", "Reptilia", "Room on Fire"),
    ("Interpol", "Obstacle 1", "Turn On the Bright Lights"),
    ("Outkast", "Ms. Jackson", "Stankonia"),
    ("MF DOOM", "Doomsday", "Operation: Doomsday"),
    ("J Dilla", "Don't Cry", "Donuts"),
    ("Nujabes", "Feather", "Modal Soul"),
    ("Ryuichi Sakamoto", "Merry Christmas Mr. Lawrence", "Merry Christmas Mr. Lawrence"),
    ("Air", "Sexy Boy", "Moon Safari"),
    ("Massive Attack", "Teardrop", "Mezzanine"),
    ("Björk", "Hyperballad", "Post"),
    ("Kate Bush", "Running Up That Hill", "Hounds of Love"),
    ("Talking Heads", "Once in a Lifetime", "Remain in Light"),
    ("The Cure", "Just Like Heaven", "Kiss Me, Kiss Me, Kiss Me"),
    ("Depeche Mode", "Enjoy the Silence", "Violator"),
    ("New Order", "Blue Monday", "Power, Corruption & Lies"),
    ("Fontaines D.C.", "Starburster", "Romance"),
    ("Charli XCX", "360", "BRAT"),
    ("Sabrina Carpenter", "Espresso", "Short n' Sweet"),
]

def is_accepted(candidate: dict, title: str) -> bool:
    name = (candidate.get("displayName", "") + " " + (candidate.get("title") or "")).lower()
    words = [w for w in "".join(c if c.isalnum() else " " for c in title.lower()).split() if len(w) >= 3 and w not in ("the", "and")]
    if words and not all(w in name for w in words):
        return False
    container = candidate.get("container", "").lower()
    kbps = candidate.get("bitrateKbps") or (1000 if container in ("flac", "alac", "wav", "aiff") else 320)
    if container not in ("flac", "alac", "wav", "aiff") and kbps < 192:
        return False
    return True

class RpcSession:
    def __init__(self, binary: str, data_dir: str):
        self.proc = subprocess.Popen(
            [binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.lock = threading.Lock()
        self.pending = {}
        self.partial_hooks = {}
        self.next_id = 1
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()

    def _read_loop(self):
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                continue
            if "id" in msg and msg["id"] is not None:
                req_id = msg["id"]
                with self.lock:
                    entry = self.pending.pop(req_id, None)
                if entry:
                    entry["resp"] = msg
                    entry["ev"].set()
            elif msg.get("method") == "resolver/candidates":
                p = msg.get("params") or {}
                req_id = str(p.get("requestID", ""))
                cands = p.get("candidates") or []
                with self.lock:
                    hook = self.partial_hooks.get(req_id)
                if hook:
                    hook(cands)

    def notify(self, method: str, params: dict):
        line = json.dumps({"jsonrpc": "2.0", "method": method, "params": params}) + "\n"
        with self.lock:
            assert self.proc.stdin is not None
            self.proc.stdin.write(line)
            self.proc.stdin.flush()

    def call(self, method: str, params: dict, on_partial=None, timeout: float = 35.0):
        ev = threading.Event()
        with self.lock:
            req_id = self.next_id
            self.next_id += 1
            holder = {"ev": ev, "resp": None}
            self.pending[req_id] = holder
            if on_partial:
                self.partial_hooks[str(req_id)] = on_partial
            line = json.dumps({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params}) + "\n"
            assert self.proc.stdin is not None
            self.proc.stdin.write(line)
            self.proc.stdin.flush()
        ok = ev.wait(timeout)
        with self.lock:
            self.partial_hooks.pop(str(req_id), None)
        if not ok:
            raise TimeoutError(f"Timeout on {method}")
        resp = holder["resp"]
        if "error" in resp and resp["error"] is not None:
            raise RuntimeError(resp["error"])
        return resp.get("result") or {}

    def close(self):
        try:
            self.call("shutdown", {}, timeout=5.0)
        except Exception:
            pass
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=3)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default="Plug-ins/Soulseek/bin/macos/soulseek-plugin")
    parser.add_argument("--windows", default="4,6,8,12")
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--pace", type=float, default=2.2, help="Minimum spacing (s) between search starts per worker to avoid Soulseek flood mutes")
    args = parser.parse_args()

    windows = [int(x) for x in args.windows.split(",")]
    tracks = TRACKS[:args.limit]

    results_table = []
    for w in windows:
        tmp = tempfile.mkdtemp(prefix=f"slsk-bench-w{w}-")
        sess = RpcSession(args.binary, tmp)
        sess.call("initialize", {
            "apiVersion": 1,
            "host": {"os": "macos", "arch": "arm64", "appVersion": "0.1", "onIPod": False},
            "paths": {"data": os.path.join(tmp, "data"), "cache": os.path.join(tmp, "cache"), "temp": tmp},
            "settings": {"searchWindowSeconds": w, "share": False},
            "config": {"serverHost": "server.slsknet.org", "serverPort": 2242},
        }, timeout=15.0)
        found_count = 0
        free_slot_lossless = 0
        first_times = []
        total_times = []

        # Concurrent batches of 2 with polite spacing so server.slsknet.org never mutes searches
        sem = threading.Semaphore(2)
        lock = threading.Lock()
        threads = []

        def run_one(idx, artist, title, album):
            nonlocal found_count, free_slot_lossless
            with sem:
                time.sleep(args.pace)
                t0 = time.monotonic()
                first_ms = None
                first_lock = threading.Lock()
                def on_part(cands):
                    nonlocal first_ms
                    for c in cands:
                        if is_accepted(c, title):
                            with first_lock:
                                if first_ms is None:
                                    first_ms = int((time.monotonic() - t0) * 1000)
                            break
                try:
                    res = sess.call("resolver/search", {
                        "track": {"source": "spotify", "sourceID": f"b-{idx}", "title": title, "artists": [artist], "album": album},
                        "policy": {"preferredFormats": ["flac", "alac", "mp3-320", "aac-256", "other"], "minimumBitrateKbps": 192, "acceptYouTubeFallback": True},
                    }, on_partial=on_part, timeout=max(30.0, w * 3.5))
                    cands = res.get("candidates") or []
                except Exception:
                    cands = []
                elapsed_ms = int((time.monotonic() - t0) * 1000)
                accepted = [c for c in cands if is_accepted(c, title)]
                with lock:
                    total_times.append(elapsed_ms)
                    if accepted:
                        found_count += 1
                        first_times.append(first_ms if first_ms is not None else elapsed_ms)
                        if any(c.get("container") == "flac" and (c.get("availability") or {}).get("freeSlot") for c in accepted):
                            free_slot_lossless += 1

        for idx, (a, t, al) in enumerate(tracks):
            th = threading.Thread(target=run_one, args=(idx, a, t, al))
            th.start()
            threads.append(th)
        for th in threads:
            th.join()

        med_first = int(statistics.median(first_times)) if first_times else -1
        p90_first = int(sorted(first_times)[min(len(first_times)-1, int(0.9 * len(first_times)))]) if first_times else -1
        avg_total = int(statistics.mean(total_times)) if total_times else -1
        row = {
            "window_s": w,
            "tracks": len(tracks),
            "found": found_count,
            "rate_pct": round(100.0 * found_count / len(tracks), 1),
            "free_flac": free_slot_lossless,
            "median_first_ms": med_first,
            "p90_first_ms": p90_first,
            "avg_wall_ms": avg_total,
        }
        results_table.append(row)
        print(json.dumps(row), flush=True)
        sess.close()
        time.sleep(5.0)

if __name__ == "__main__":
    main()
