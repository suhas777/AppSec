FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

# ── System packages ──────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    python3 python3-pip \
    vsftpd \
    openssh-server \
    net-tools \
    curl wget \
    gcc \
    sudo \
    vim \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install flask flask-sqlalchemy requests


# ══════════════════════════════════════════════════════════════════════════════
# 1. VULNERABLE FTP  (port 21)
#    Exploit: anonymous login + readable flag file
# ══════════════════════════════════════════════════════════════════════════════
RUN mkdir -p /var/ftp/pub && \
    echo "secret_flag{ftp_anonymous_access}" > /var/ftp/pub/flag.txt

RUN cat > /etc/vsftpd.conf <<'EOF'
listen=YES
anonymous_enable=YES
local_enable=YES
write_enable=YES
anon_upload_enable=YES
anon_mkdir_write_enable=YES
anon_root=/var/ftp
no_anon_password=YES
ftp_username=ftp
EOF


# ══════════════════════════════════════════════════════════════════════════════
# 2. WEAK SSH (port 22)
#    Exploit: brute-force with trivial credentials  root:toor
# ══════════════════════════════════════════════════════════════════════════════
RUN mkdir /var/run/sshd && \
    echo 'root:toor' | chpasswd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config


# ══════════════════════════════════════════════════════════════════════════════
# 3. VULNERABLE FLASK WEB APP  (port 5000)
#    Vulnerabilities:
#      a) SQL Injection  → /login
#      b) Command Injection → /ping
#      c) Path Traversal / IDOR → /file?name=
#      d) Reflected XSS → /search
# ══════════════════════════════════════════════════════════════════════════════
RUN mkdir -p /app/secret_files

RUN echo "secret_flag{idor_file_read}" > /app/secret_files/secret.txt

RUN cat > /app/vuln_app.py <<'PYEOF'
from flask import Flask, request
import sqlite3, os, subprocess

app = Flask(__name__)
DB = "/app/users.db"

# Seed DB
with sqlite3.connect(DB) as con:
    con.execute("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, username TEXT, password TEXT)")
    con.execute("INSERT OR IGNORE INTO users VALUES (1,'admin','supersecret')")
    con.execute("INSERT OR IGNORE INTO users VALUES (2,'alice','password123')")

# ── a) SQL Injection ──────────────────────────────────────────────────────────
@app.route("/login")
def login():
    """
    Exploit:
        /login?username=admin'--&password=anything
        /login?username=' OR '1'='1&password=x
    """
    username = request.args.get("username", "")
    password = request.args.get("password", "")
    db = sqlite3.connect(DB)
    query = f"SELECT * FROM users WHERE username='{username}' AND password='{password}'"
    try:
        row = db.execute(query).fetchone()
    except Exception as e:
        return f"DB Error: {e}<br>Query: {query}"
    if row:
        return f"<h2>Welcome {row[1]}!</h2><p>Flag: secret_flag{{sqli_bypass}}</p>"
    return "Login failed."

# ── b) Command Injection ──────────────────────────────────────────────────────
@app.route("/ping")
def ping():
    """
    Exploit:
        /ping?host=127.0.0.1;id
        /ping?host=127.0.0.1;cat /app/secret_files/secret.txt
    """
    host = request.args.get("host", "127.0.0.1")
    result = subprocess.getoutput(f"ping -c 1 {host}")
    return f"<pre>{result}</pre>"

# ── c) Path Traversal / IDOR ──────────────────────────────────────────────────
@app.route("/file")
def read_file():
    """
    Exploit:
        /file?name=secret.txt
        /file?name=../etc/passwd
    """
    name = request.args.get("name", "")
    path = os.path.join("/app/secret_files", name)
    try:
        with open(path) as f:
            return f"<pre>{f.read()}</pre>"
    except Exception as e:
        return f"Error: {e}"

# ── d) Reflected XSS ─────────────────────────────────────────────────────────
@app.route("/search")
def search():
    """
    Exploit:
        /search?q=<script>alert('XSS')</script>
    """
    q = request.args.get("q", "")
    return f"<html><body><h2>Search results for: {q}</h2></body></html>"

@app.route("/")
def index():
    return """
    <h1>Vulnerable Lab</h1>
    <ul>
      <li><b>/login</b> — SQL Injection</li>
      <li><b>/ping</b>  — Command Injection</li>
      <li><b>/file</b>  — Path Traversal / IDOR</li>
      <li><b>/search</b> — Reflected XSS</li>
    </ul>
    """

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
PYEOF


# ══════════════════════════════════════════════════════════════════════════════
# 4. MAGIC-BYTES TCP SERVICE  (port 9999)
#    Exploit: send exact magic bytes to receive the flag
# ══════════════════════════════════════════════════════════════════════════════
RUN cat > /app/tcp_service.py <<'PYEOF'
import socket, threading

FLAG  = "secret_flag{magic_bytes_pwned}"
MAGIC = b"\x41\x41\x41\x41\xde\xad\xbe\xef"   # 4x'A' + 0xdeadbeef

def handle(conn, addr):
    conn.sendall(b"Welcome to EchoService v0.1\nSend your data: ")
    data = conn.recv(1024)
    if data.strip() == MAGIC:
        conn.sendall(f"Flag: {FLAG}\n".encode())
    else:
        conn.sendall(b"Echo: " + data)
    conn.close()

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("0.0.0.0", 9999))
server.listen(5)
print("TCP service listening on :9999")
while True:
    conn, addr = server.accept()
    threading.Thread(target=handle, args=(conn, addr)).start()
PYEOF


# ══════════════════════════════════════════════════════════════════════════════
# Startup script
# ══════════════════════════════════════════════════════════════════════════════
RUN printf '#!/bin/bash\nservice ssh start\nservice vsftpd start\npython3 /app/vuln_app.py &\npython3 /app/tcp_service.py &\necho ""\necho "Vulnerable Lab READY"\necho "  FTP   port 21   (anonymous)"\necho "  SSH   port 22   (root:toor)"\necho "  HTTP  port 5000 (Flask)"\necho "  TCP   port 9999 (magic bytes)"\ntail -f /dev/null\n' > /start.sh && chmod +x /start.sh

EXPOSE 21 22 5000 9999

CMD ["/start.sh"]
