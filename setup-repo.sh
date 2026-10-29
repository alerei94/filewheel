#!/bin/bash
# Prepara questa cartella come repository git:
# crea .gitignore e LICENSE (MIT) e fa il primo commit.
# Si esegue una sola volta:  bash setup-repo.sh
set -euo pipefail
cd "$(dirname "$0")"

# --- Controlli ---------------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
  echo "git non trovato. Installa i Command Line Tools con: xcode-select --install"
  exit 1
fi

for f in ConvertiMac.swift build.sh AppIcon.png; do
  if [ ! -f "$f" ]; then
    echo "Manca il file $f in questa cartella."
    exit 1
  fi
done

NAME="$(git config user.name || true)"
EMAIL="$(git config user.email || true)"
if [ -z "$NAME" ] || [ -z "$EMAIL" ]; then
  echo "git non conosce ancora il tuo nome e la tua email. Impostali (una volta sola) con:"
  echo '  git config --global user.name  "Il tuo nome"'
  echo '  git config --global user.email "tua@email.it"'
  echo "poi rilancia: bash setup-repo.sh"
  exit 1
fi

# --- .gitignore --------------------------------------------------------------
if [ ! -f .gitignore ]; then
cat > .gitignore <<'GITIGNORE'
# macOS
.DS_Store

# Risultato della compilazione (si rigenera con: bash build.sh)
Converti.app/
build/

# Icone generate al volo
*.icns
*.iconset/

# Editor
.vscode/
.idea/
*.swp
GITIGNORE
echo "Creato .gitignore"
fi

# --- LICENSE (MIT) -----------------------------------------------------------
if [ ! -f LICENSE ]; then
cat > LICENSE <<LICENSE_TEXT
MIT License

Copyright (c) $(date +%Y) $NAME

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
LICENSE_TEXT
echo "Creato LICENSE (MIT, intestato a: $NAME)"
fi

# --- Repository e primo commit ----------------------------------------------
if [ ! -d .git ]; then
  git init -q
  git symbolic-ref HEAD refs/heads/main      # il ramo principale si chiama "main"
  echo "Repository git creato."
fi

git add .
if git diff --cached --quiet; then
  echo "Niente da registrare: è già tutto committato."
else
  git commit -q -m "Primo commit: Converti, convertitore di file per la barra dei menu di macOS"
  echo "Primo commit fatto."
fi

echo
git status --short --branch
echo
echo "Per pubblicarlo su GitHub: crea un repository VUOTO (senza README) e poi esegui:"
echo "  git remote add origin https://github.com/TUO-UTENTE/converti.git"
echo "  git push -u origin main"
