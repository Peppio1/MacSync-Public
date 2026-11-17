"""MacSync: generate Sparkle-compatible Ed25519 keys locally (Python 3.9+).
Dependency: cryptography. No network calls, no plaintext private key file.
Run: py macsync_keys.py generate
     py macsync_keys.py export-secret
The encrypted backup is PKCS#8 PEM, not the GitHub secret. Keep it safe.
"""
import argparse
import base64
import getpass
import os
from pathlib import Path
import subprocess
import sys

try:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
except ImportError:
    sys.exit("Dipendenza mancante. Esegui: py -m pip install cryptography")

ROOT = Path.home() / "MacSync-Signing"
PRIVATE = ROOT / "MacSync_PrivateKey.encrypted.pem"
PUBLIC = ROOT / "MacSync_PublicKey.txt"

def b64(data):
    return base64.b64encode(data).decode("ascii")

def public_text(key):
    return b64(key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw))

def generate():
    if ROOT.exists():
        sys.exit("Cartella gia esistente: nessuna chiave sovrascritta. " + str(ROOT))
    password = getpass.getpass("Password per cifrare il backup (almeno 16 caratteri): ")
    if len(password) < 16:
        sys.exit("Password troppo corta.")
    if password != getpass.getpass("Conferma password: "):
        sys.exit("Password diverse.")
    key = Ed25519PrivateKey.generate()
    signature = key.sign(b"MacSync key self-test")
    key.public_key().verify(signature, b"MacSync key self-test")
    encrypted = key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
        serialization.BestAvailableEncryption(password.encode("utf-8")))
    ROOT.mkdir(mode=0o700)
    with PRIVATE.open("xb") as f:
        f.write(encrypted)
    # Re-open encrypted backup and verify it before exposing public key.
    restored = serialization.load_pem_private_key(
        PRIVATE.read_bytes(), password=password.encode("utf-8"))
    if public_text(restored) != public_text(key):
        sys.exit("Verifica backup fallita.")
    with PUBLIC.open("x", encoding="ascii") as f:
        f.write(public_text(key) + "\n")
    print("Backup cifrato: " + str(PRIVATE))
    print("Chiave PUBBLICA (condivisibile): " + public_text(key))
    print("Conserva una seconda copia del backup cifrato e la password separatamente.")
    print("Per configurare GitHub: py macsync_keys.py export-secret")

def export_secret():
    pwd = getpass.getpass("Password del backup cifrato: ")
    key = serialization.load_pem_private_key(
        PRIVATE.read_bytes(), password=pwd.encode("utf-8"))
    if not isinstance(key, Ed25519PrivateKey):
        sys.exit("Chiave non Ed25519.")
    if public_text(key) != PUBLIC.read_text(encoding="ascii").strip():
        sys.exit("Chiave pubblica non corrispondente: esportazione bloccata.")
    if os.name != "nt":
        sys.exit("Esportazione clipboard predisposta per Windows.")
    print("Disattiva cronologia e sincronizzazione appunti di Windows prima di continuare.")
    print("Apri l'ambiente GitHub protetto e il campo del secret MACSYNC_SPARKLE_PRIVATE_KEY.")
    if input("Scrivi COPIA per copiare la chiave privata negli appunti: ") != "COPIA":
        sys.exit("Annullato.")
    seed = key.private_bytes(serialization.Encoding.Raw,
                             serialization.PrivateFormat.Raw,
                             serialization.NoEncryption())
    # Send via stdin, never command line arguments or printed output.
    subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
                    "$v=[Console]::In.ReadToEnd(); Set-Clipboard -Value $v"],
                   input=b64(seed), text=True, check=True)
    print("Incolla SOLO nel campo del secret GitHub e salva.")
    try:
        input("Premi Invio dopo aver salvato per svuotare gli appunti.")
    finally:
        subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
                        "Set-Clipboard -Value ' ' "], check=True)
        print("Appunti sovrascritti. Verifica che non esista cronologia residua.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("generate", "export-secret"))
    args = parser.parse_args()
    try:
        {"generate": generate, "export-secret": export_secret}[args.action]()
    except (OSError, ValueError, TypeError, subprocess.SubprocessError) as exc:
        sys.exit("Operazione non riuscita: " + type(exc).__name__ + ". Nessun segreto stampato.")
