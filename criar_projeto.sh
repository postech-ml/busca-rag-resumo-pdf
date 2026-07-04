#!/usr/bin/env bash
set -e

echo "Criando estrutura do projeto RAG com PDFs (FastAPI + HTML)..."

mkdir -p static .github/workflows

mkdir -p "$(dirname ".env.example")"
cat > '.env.example' << 'CLAUDE_EOF'
GEMINI_API_KEY=sua_chave_gemini_aqui
GROQ_API_KEY=sua_chave_groq_aqui

# ── Dataset do Hugging Face Hub como storage (opcional) ────────
# Persiste o ./chroma_bancos em um Dataset privado do seu perfil do
# Hugging Face, para não perder os PDFs indexados quando o container
# do Space reiniciar. Deixe essas variáveis vazias/removidas para
# rodar só com disco local (sem persistência).
#
# HF_TOKEN: gere em https://huggingface.co/settings/tokens (tipo "Write")
# HF_DATASET_REPO: ex "seu-usuario/rag-chroma-storage" (não precisa existir,
#                  é criado automaticamente na primeira indexação)
HF_TOKEN=
HF_DATASET_REPO=
HF_DATASET_PRIVATE=true
CLAUDE_EOF

mkdir -p "$(dirname ".gitignore")"
cat > '.gitignore' << 'CLAUDE_EOF'
.env
chroma_bancos/
__pycache__/
*.pyc
.venv/
venv/
CLAUDE_EOF

mkdir -p "$(dirname "Dockerfile")"
cat > 'Dockerfile' << 'CLAUDE_EOF'
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# HF Spaces (sdk: docker) espera o app respondendo na porta 7860
ENV PORT=7860
EXPOSE 7860

CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT}"]
CLAUDE_EOF

mkdir -p "$(dirname "README.md")"
cat > 'README.md' << 'CLAUDE_EOF'
---
title: RAG com PDFs
emoji: 📚
colorFrom: blue
colorTo: indigo
sdk: docker
app_port: 7860
pinned: false
license: mit
---

# 📚 RAG com PDFs

Sistema de perguntas e respostas sobre documentos PDF com suporte multimodal.
Frontend em HTML/CSS/JS puro, backend em FastAPI.

## Stack

| Componente | Tecnologia |
|---|---|
| Frontend | HTML / CSS / JavaScript puro |
| Backend | FastAPI + Uvicorn (Docker) |
| Embeddings | Gemini `gemini-embedding-2-preview` (multimodal) |
| LLM | Groq `llama-3.1-8b-instant` |
| Banco vetorial | ChromaDB local |
| Reranking | Flashrank |

## Configuração

```bash
pip install -r requirements.txt
cp .env.example .env
# edite o .env com suas chaves
```

## Rodar localmente

```bash
uvicorn main:app --reload --port 8000
```

Acesse: http://localhost:8000

## Estrutura

```
├── main.py             # Backend FastAPI
├── indexar.py          # Indexação multimodal
├── perguntar.py        # Busca e reranking
├── gerar_pdf.py        # Geração de PDFs
├── static/
│   ├── index.html      # Frontend HTML
│   ├── style.css       # Estilos
│   └── app.js          # Lógica do frontend (fetch para a API)
├── requirements.txt
├── Dockerfile           # Usado no deploy para HF Spaces (sdk: docker)
├── .env.example
└── .gitignore
```

## Persistência do ChromaDB (Dataset do Hugging Face)

O Hugging Face Spaces (tier gratuito, sem "Persistent Storage" pago) apaga o
disco do container a cada reinício/redeploy. Sem um storage externo, todo PDF
indexado se perderia. O `main.py` sincroniza `./chroma_bancos` com um
**Dataset privado do seu perfil do Hugging Face** automaticamente:

- No startup: baixa todos os bancos já existentes do dataset.
- Após cada PDF indexado com sucesso: envia os arquivos daquele banco de volta
  (um commit por banco atualizado).

Não precisa de nenhum serviço externo (S3, R2 etc.) — usa a própria conta do
Hugging Face, e o Dataset é criado automaticamente na primeira indexação.

### Configurar

1. Gere um token em [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)
   do tipo **Write**
2. Escolha um nome de repositório, ex: `seu-usuario/rag-chroma-storage`
   (não precisa criar antes — o app cria automaticamente)
3. Preencha no `.env` (ou nos Secrets do Space):

```bash
HF_TOKEN=hf_xxx...
HF_DATASET_REPO=seu-usuario/rag-chroma-storage
HF_DATASET_PRIVATE=true
```

Se `HF_TOKEN` ou `HF_DATASET_REPO` não estiverem definidos, a sincronização é
ignorada e o app roda 100% local, como antes. A aba **Status** do app mostra
se o dataset está conectado e tem um botão para forçar a sincronização
manualmente.

> **Nota:** o Dataset guarda histórico de commits (como um repositório git).
> Como o ChromaDB reescreve seus arquivos a cada indexação, o espaço ocupado
> no Hub cresce ao longo do tempo. Para uso de estudo normal isso não costuma
> ser um problema (o Hub oferece armazenamento gratuito generoso), mas vale
> saber caso o dataset cresça muito depois de muitas indexações.

## Secrets

Necessários tanto em um `.env` local quanto nas **Settings → Variables and secrets** do Hugging Face Space:

| Variável | Onde obter |
|---|---|
| `GEMINI_API_KEY` | [aistudio.google.com](https://aistudio.google.com) |
| `GROQ_API_KEY` | [console.groq.com](https://console.groq.com) |
| `HF_TOKEN` / `HF_DATASET_REPO` | opcional — ver seção acima |

## Deploy no Hugging Face Spaces

O workflow em `.github/workflows/deploy_hf.yml` publica automaticamente a cada push na branch `main`,
usando os secrets `HF_TOKEN` (token de escrita do Hugging Face) e `HF_SPACE` (ex: `seu-usuario/rag-pdfs`)
configurados no repositório do GitHub.

> **Atenção:** esse `HF_TOKEN` do GitHub Actions (usado para *enviar os arquivos* ao Space) é
> configurado nos *Secrets do repositório GitHub*. Já o `HF_TOKEN` usado pela persistência do
> ChromaDB (seção acima) é configurado nos *Secrets do próprio Space*, no Hugging Face. São dois
> lugares diferentes — pode ser o mesmo token nos dois, mas cada um precisa ser cadastrado
> separadamente.
CLAUDE_EOF

mkdir -p "$(dirname "requirements.txt")"
cat > 'requirements.txt' << 'CLAUDE_EOF'
# Backend
fastapi>=0.111.0
uvicorn>=0.30.0
python-multipart>=0.0.9

# Google Gemini (embeddings multimodais)
google-genai>=1.10.0

# LLM
groq>=0.9.0

# Banco vetorial
chromadb>=0.5.23

# Reranking
flashrank>=0.2.9

# Extração de texto e renderização de PDFs
pymupdf>=1.24.11

# Processamento de imagens
Pillow>=10.0.0

# Chunking de texto
langchain-text-splitters>=0.3.3

# Geração de PDF
fpdf2>=2.7.9

# Variáveis de ambiente
python-dotenv>=1.0.0

# Dataset do Hugging Face Hub usado como "bucket" (persistência do ChromaDB)
huggingface_hub>=0.24.0
CLAUDE_EOF

mkdir -p "$(dirname "gerar_pdf.py")"
cat > 'gerar_pdf.py' << 'CLAUDE_EOF'
"""
gerar_pdf.py — Gera PDFs formatados de resumos e respostas
Usa fpdf2 para evitar problemas de encoding
"""

from fpdf import FPDF
from datetime import datetime
import io
import re


def _sanitizar(texto: str) -> str:
    """Remove caracteres fora do range latin-1."""
    substituicoes = {
        "\u2013": "-", "\u2014": "-",
        "\u2018": "'", "\u2019": "'",
        "\u201c": '"', "\u201d": '"',
        "\u2026": "...", "\u2022": "-",
        "\u20ac": "EUR", "\u00e2": "a",
        "\u2192": "->", "\u2190": "<-",
        "\u2605": "*", "\u2713": "OK",
    }
    for orig, sub in substituicoes.items():
        texto = texto.replace(orig, sub)
    # Remove markdown bold/italic simples
    texto = re.sub(r"\*\*(.+?)\*\*", r"\1", texto)
    texto = re.sub(r"\*(.+?)\*",     r"\1", texto)
    texto = re.sub(r"#+\s*",         "",    texto)
    return texto.encode("latin-1", errors="replace").decode("latin-1")


class PDFRelatorio(FPDF):
    def __init__(self, titulo: str):
        super().__init__()
        self.titulo_doc = _sanitizar(titulo)
        self.set_auto_page_break(auto=True, margin=15)
        self.add_page()
        self._cabecalho()

    def _cabecalho(self):
        self.set_font("Arial", "B", 16)
        self.cell(0, 12, self.titulo_doc, ln=True, align="C")
        self.set_font("Arial", "I", 9)
        self.cell(0, 6, f"Gerado em: {datetime.now().strftime('%d/%m/%Y %H:%M')}", ln=True, align="C")
        self.ln(6)
        self.set_draw_color(100, 100, 200)
        self.set_line_width(0.5)
        self.line(10, self.get_y(), 200, self.get_y())
        self.ln(6)

    def secao(self, titulo: str):
        self.set_font("Arial", "B", 13)
        self.set_fill_color(230, 235, 255)
        self.cell(0, 9, _sanitizar(titulo), ln=True, fill=True)
        self.ln(2)

    def subsecao(self, titulo: str):
        self.set_font("Arial", "B", 11)
        self.cell(0, 7, _sanitizar(titulo), ln=True)
        self.ln(1)

    def corpo(self, texto: str):
        self.set_font("Arial", "", 10)
        self.multi_cell(0, 6, _sanitizar(texto))
        self.ln(3)

    def separador(self):
        self.set_draw_color(200, 200, 200)
        self.line(10, self.get_y(), 200, self.get_y())
        self.ln(4)

    def rodape(self):
        self.set_y(-15)
        self.set_font("Arial", "I", 8)
        self.set_text_color(150, 150, 150)
        self.cell(0, 10, f"Pagina {self.page_no()}", align="C")


def gerar_pdf_resumo(nome_pdf: str, banco: str, resumo: str, estilo: str = "") -> bytes:
    """Gera PDF de um resumo completo."""
    pdf = PDFRelatorio(f"Resumo: {nome_pdf}")

    pdf.secao("Informacoes")
    pdf.corpo(f"Documento: {nome_pdf}")
    pdf.corpo(f"Banco: {banco}")
    if estilo:
        pdf.corpo(f"Tipo de resumo: {estilo}")
    pdf.separador()

    pdf.secao("Resumo Completo")
    pdf.corpo(resumo)

    buf = io.BytesIO()
    pdf.output(buf)
    return buf.getvalue()


def gerar_pdf_resposta(pergunta: str, resposta: str, banco: str, trechos: list) -> bytes:
    """Gera PDF de uma pergunta e sua resposta com trechos utilizados."""
    pdf = PDFRelatorio("Resposta RAG")

    pdf.secao("Informacoes")
    pdf.corpo(f"Banco: {banco}")
    pdf.separador()

    pdf.secao("Pergunta")
    pdf.corpo(pergunta)
    pdf.separador()

    pdf.secao("Resposta")
    pdf.corpo(resposta)
    pdf.separador()

    pdf.secao("Trechos Utilizados")
    for i, t in enumerate(trechos, 1):
        pdf.subsecao(f"#{i} - {t['arquivo']} | rerank: {t['relevancia_rerank']} | embed: {t['relevancia']}")
        pdf.corpo(t["texto"])
        if i < len(trechos):
            pdf.separador()

    buf = io.BytesIO()
    pdf.output(buf)
    return buf.getvalue()
CLAUDE_EOF

mkdir -p "$(dirname "indexar.py")"
cat > 'indexar.py' << 'CLAUDE_EOF'
"""
indexar.py — processa PDFs e salva no ChromaDB
Embeddings multimodais via gemini-embedding-2-preview
Suporte a: texto nativo, PDFs escaneados, figuras e gráficos
"""

import io
import time
import tempfile

import fitz  # PyMuPDF
from PIL import Image
from google import genai
from google.genai import types
from langchain_text_splitters import RecursiveCharacterTextSplitter

# ── configuração ──────────────────────────────────────────────
CHUNK_SIZE      = 800
CHUNK_OVERLAP   = 100
EMBEDDING_MODEL = "gemini-embedding-2-preview"

# Máximo de imagens por requisição de embedding (limite da API)
MAX_IMGS_POR_LOTE = 6

# Limite de tokens por minuto (free tier) — pausa entre lotes
BATCH_SIZE  = 20   # chunks de texto por lote
BATCH_PAUSE = 10   # segundos entre lotes
MAX_RETRY   = 5
RETRY_WAIT  = 60

# Mínimo de chars para considerar que a página tem texto nativo
MIN_CHARS_TEXTO = 50

splitter = RecursiveCharacterTextSplitter(
    chunk_size=CHUNK_SIZE,
    chunk_overlap=CHUNK_OVERLAP,
    separators=["\n\n", "\n", ". ", " "]
)


# ── helpers de imagem ─────────────────────────────────────────
def _pagina_para_pil(pagina: fitz.Page, dpi: int = 150) -> Image.Image:
    """Renderiza uma página PDF como imagem PIL."""
    pix = pagina.get_pixmap(dpi=dpi)
    return Image.open(io.BytesIO(pix.tobytes("png"))).convert("RGB")


def _extrair_imagens_pagina(pagina: fitz.Page) -> list[Image.Image]:
    """Extrai imagens embutidas de uma página PDF como PIL Images."""
    imagens = []
    for img_info in pagina.get_images(full=True):
        xref = img_info[0]
        try:
            base_img  = pagina.parent.extract_image(xref)
            img       = Image.open(io.BytesIO(base_img["image"])).convert("RGB")
            # Ignora imagens muito pequenas (ícones, decorações)
            if img.width > 100 and img.height > 100:
                imagens.append(img)
        except Exception:
            continue
    return imagens


# ── extração de conteúdo por página ──────────────────────────
def extrair_conteudo_pdf(conteudo: bytes) -> dict:
    """
    Extrai conteúdo de um PDF separando:
    - chunks de texto (para embedding de texto)
    - imagens de páginas (para embedding de imagem)

    Retorna:
        {
            "chunks_texto": list[str],
            "imagens_pagina": list[{"pagina": int, "imagem": PIL.Image}],
            "imagens_figura": list[{"pagina": int, "figura": int, "imagem": PIL.Image}]
        }
    """
    chunks_texto    = []
    imagens_pagina  = []
    imagens_figura  = []
    texto_acumulado = []

    with tempfile.NamedTemporaryFile(suffix=".pdf", delete=True) as tmp:
        tmp.write(conteudo)
        tmp.flush()
        doc = fitz.open(tmp.name)

        for num_pag, pagina in enumerate(doc, 1):
            texto_nativo = pagina.get_text().strip()

            if len(texto_nativo) >= MIN_CHARS_TEXTO:
                # Página com texto nativo — acumula para chunking
                texto_acumulado.append(f"[Página {num_pag}]\n{texto_nativo}")

                # Extrai figuras embutidas para embedding visual
                figuras = _extrair_imagens_pagina(pagina)
                for i, img in enumerate(figuras, 1):
                    imagens_figura.append({
                        "pagina": num_pag,
                        "figura": i,
                        "imagem": img
                    })
            else:
                # Página escaneada — indexa como imagem
                img_pagina = _pagina_para_pil(pagina)
                imagens_pagina.append({
                    "pagina": num_pag,
                    "imagem": img_pagina
                })

    # Gera chunks do texto acumulado
    if texto_acumulado:
        texto_completo = "\n\n".join(texto_acumulado)
        chunks_texto   = splitter.split_text(texto_completo)

    return {
        "chunks_texto":   chunks_texto,
        "imagens_pagina": imagens_pagina,
        "imagens_figura": imagens_figura,
    }


# ── embeddings com retry ──────────────────────────────────────
def _embed_com_retry(cliente: genai.Client, contents, task_type: str) -> list[float]:
    """Gera embedding de um conteúdo (texto ou imagem) com retry."""
    for tentativa in range(1, MAX_RETRY + 1):
        try:
            resultado = cliente.models.embed_content(
                model=EMBEDDING_MODEL,
                contents=contents,
                config=types.EmbedContentConfig(task_type=task_type)
            )
            return resultado.embeddings[0].values
        except Exception as e:
            erro = str(e)
            if "429" in erro or "RESOURCE_EXHAUSTED" in erro:
                print(f"[429] Aguardando {RETRY_WAIT}s... (tentativa {tentativa}/{MAX_RETRY})")
                time.sleep(RETRY_WAIT)
            else:
                raise
    raise RuntimeError(f"Falha ao gerar embedding após {MAX_RETRY} tentativas.")


def _embed_texto_lote(
    cliente: genai.Client,
    chunks: list[str],
    task_type: str = "RETRIEVAL_DOCUMENT"
) -> list[list[float]]:
    """Gera embeddings de uma lista de chunks de texto em lotes."""
    todos = []
    total = (len(chunks) + BATCH_SIZE - 1) // BATCH_SIZE

    for i in range(0, len(chunks), BATCH_SIZE):
        lote     = chunks[i:i + BATCH_SIZE]
        lote_num = i // BATCH_SIZE + 1
        print(f"[embedding texto] Lote {lote_num}/{total} — {len(lote)} chunks...")

        for chunk in lote:
            emb = _embed_com_retry(cliente, chunk, task_type)
            todos.append(emb)

        if i + BATCH_SIZE < len(chunks):
            time.sleep(BATCH_PAUSE)

    return todos


def _embed_imagem(cliente: genai.Client, imagem: Image.Image) -> list[float]:
    """Gera embedding de uma imagem PIL."""
    return _embed_com_retry(cliente, imagem, "RETRIEVAL_DOCUMENT")


# ── indexação principal ───────────────────────────────────────
def indexar_pdf_bytes(
    nome: str,
    conteudo: bytes,
    colecao,
    cliente: genai.Client,
    callback=None,
    pausar_ao_final: bool = False,
) -> dict:
    """
    Indexa um PDF com embeddings multimodais (gemini-embedding-2-preview).

    - Texto nativo → embedding de texto
    - Páginas escaneadas → embedding de imagem da página inteira
    - Figuras/gráficos embutidos → embedding de imagem da figura

    Retorna dict com:
        status : "ok" | "ja_indexado" | "erro"
        chunks : int  (se ok)
        erro   : str  (se erro)
    """
    # Verifica se já foi indexado
    if colecao.count() > 0:
        ja_indexados = {m.get("arquivo") for m in colecao.get()["metadatas"]}
        if nome in ja_indexados:
            return {"status": "ja_indexado", "chunks": 0}

    try:
        print(f"[indexar] Extraindo conteúdo de '{nome}'...")
        conteudo_pdf = extrair_conteudo_pdf(conteudo)

        chunks_texto   = conteudo_pdf["chunks_texto"]
        imgs_pagina    = conteudo_pdf["imagens_pagina"]
        imgs_figura    = conteudo_pdf["imagens_figura"]

        total_items = len(chunks_texto) + len(imgs_pagina) + len(imgs_figura)
        if total_items == 0:
            return {"status": "erro", "erro": "PDF vazio — nenhum conteúdo extraído"}

        print(f"[indexar] '{nome}' → {len(chunks_texto)} chunks texto, "
              f"{len(imgs_pagina)} páginas escaneadas, "
              f"{len(imgs_figura)} figuras")

        ids        = []
        embeddings = []
        documents  = []
        metadatas  = []
        contador   = 0
        total_lotes = (len(chunks_texto) + BATCH_SIZE - 1) // BATCH_SIZE or 1

        # ── 1. Embeddings de texto ────────────────────────────
        for i, chunk in enumerate(chunks_texto):
            emb = _embed_com_retry(cliente, chunk, "RETRIEVAL_DOCUMENT")
            ids.append(f"{nome}_texto_{i}")
            embeddings.append(emb)
            documents.append(chunk)
            metadatas.append({"arquivo": nome, "tipo": "texto", "chunk": i})
            contador += 1

            if callback and i % BATCH_SIZE == 0:
                lote_num = i // BATCH_SIZE + 1
                callback(lote_num, total_lotes)

            if (i + 1) % BATCH_SIZE == 0 and i + 1 < len(chunks_texto):
                time.sleep(BATCH_PAUSE)

        # ── 2. Embeddings de páginas escaneadas ───────────────
        for item in imgs_pagina:
            num_pag = item["pagina"]
            img     = item["imagem"]
            print(f"[indexar] Embedding página escaneada {num_pag}...")

            emb = _embed_imagem(cliente, img)
            ids.append(f"{nome}_pagina_{num_pag}")
            embeddings.append(emb)
            documents.append(f"[Página escaneada {num_pag} de {nome}]")
            metadatas.append({
                "arquivo": nome,
                "tipo":    "pagina_escaneada",
                "pagina":  num_pag
            })
            time.sleep(2)  # pausa entre imagens

        # ── 3. Embeddings de figuras embutidas ────────────────
        for item in imgs_figura:
            num_pag = item["pagina"]
            num_fig = item["figura"]
            img     = item["imagem"]
            print(f"[indexar] Embedding figura {num_fig} da página {num_pag}...")

            emb = _embed_imagem(cliente, img)
            ids.append(f"{nome}_figura_{num_pag}_{num_fig}")
            embeddings.append(emb)
            documents.append(f"[Figura {num_fig} da página {num_pag} de {nome}]")
            metadatas.append({
                "arquivo": nome,
                "tipo":    "figura",
                "pagina":  num_pag,
                "figura":  num_fig
            })
            time.sleep(2)  # pausa entre imagens

        if pausar_ao_final:
            print("[indexar] Pausa de 10s antes do próximo arquivo...")
            time.sleep(10)

        # ── Salva no ChromaDB ─────────────────────────────────
        colecao.add(
            ids=ids,
            embeddings=embeddings,
            documents=documents,
            metadatas=metadatas
        )

        return {"status": "ok", "chunks": len(ids)}

    except Exception as e:
        return {"status": "erro", "erro": str(e)}
CLAUDE_EOF

mkdir -p "$(dirname "main.py")"
cat > 'main.py' << 'CLAUDE_EOF'
"""
main.py — Backend FastAPI para RAG com PDFs
Substitui a interface Streamlit por uma API + frontend HTML puro.

Embeddings : Gemini gemini-embedding-2-preview (multimodal — texto + imagens)
LLM        : Groq  llama-3.1-8b-instant

Variáveis de ambiente necessárias no .env:
    GEMINI_API_KEY=...
    GROQ_API_KEY=...
"""

import os
import re
import time
import uuid
import random
import logging
import threading

from fastapi import FastAPI, UploadFile, File, Form, HTTPException
from fastapi.responses import FileResponse, Response, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import chromadb
from google import genai
from groq import Groq
from flashrank import Ranker
from dotenv import load_dotenv

from indexar import indexar_pdf_bytes
from perguntar import buscar_trechos, rerankar_trechos, montar_contexto, SYSTEM_PROMPT
from gerar_pdf import gerar_pdf_resumo, gerar_pdf_resposta
import storage

load_dotenv()

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ── configuração ──────────────────────────────────────────────
CHROMA_BASE_DIR = "./chroma_bancos"
MODELO_GROQ     = "llama-3.1-8b-instant"

_ERROS_429 = ("429", "rate_limit_exceeded", "rate limit", "too many requests")
_ERROS_413 = ("413", "request too large", "request_too_large")

BASE_DIR = os.path.dirname(os.path.abspath(__file__))


# ── inicialização dos clientes (uma vez, no startup) ───────────
def _inicializar():
    gemini_key = os.environ.get("GEMINI_API_KEY")
    groq_key   = os.environ.get("GROQ_API_KEY")

    faltando = []
    if not gemini_key:
        faltando.append("GEMINI_API_KEY")
    if not groq_key:
        faltando.append("GROQ_API_KEY")
    if faltando:
        raise RuntimeError(f"Chaves não encontradas no .env: {', '.join(faltando)}")

    cliente_gemini = genai.Client(api_key=gemini_key)
    cliente_groq   = Groq(api_key=groq_key)
    ranker         = Ranker()
    return cliente_gemini, cliente_groq, ranker


cliente_gemini, cliente_groq, ranker = _inicializar()

app = FastAPI(title="RAG com PDFs")


@app.on_event("startup")
async def _ao_iniciar():
    # Restaura os bancos já indexados do Dataset do Hugging Face (se configurado).
    # Sem isso, o ChromaDB local seria perdido a cada reinício do container.
    storage.sincronizar_tudo_do_bucket()


# jobs em memória (indexação e resumo rodam em background threads)
JOBS: dict[str, dict] = {}
_JOBS_LOCK = threading.Lock()


# ── helpers de banco (idênticos ao app.py, sem cache do Streamlit) ─
def _slug(texto: str) -> str:
    texto = texto.strip().lower()
    texto = re.sub(r"[^\w\s-]", "", texto)
    texto = re.sub(r"[\s\_-]+", "_", texto)
    return texto[:50] or "banco"


_chroma_clientes: dict[str, chromadb.PersistentClient] = {}
_chroma_lock = threading.Lock()


def _get_chroma_cliente(nome_banco: str):
    with _chroma_lock:
        if nome_banco not in _chroma_clientes:
            path = os.path.join(CHROMA_BASE_DIR, nome_banco)
            os.makedirs(path, exist_ok=True)
            _chroma_clientes[nome_banco] = chromadb.PersistentClient(path=path)
        return _chroma_clientes[nome_banco]


def get_colecao(nome_banco: str):
    cliente = _get_chroma_cliente(nome_banco)
    return cliente.get_or_create_collection(
        name="pdfs",
        metadata={"hnsw:space": "cosine"}
    )


def listar_bancos() -> list[str]:
    if not os.path.exists(CHROMA_BASE_DIR):
        return []
    return sorted([
        d for d in os.listdir(CHROMA_BASE_DIR)
        if os.path.isdir(os.path.join(CHROMA_BASE_DIR, d))
    ])


def listar_pdfs(nome_banco: str) -> list[str]:
    try:
        col = get_colecao(nome_banco)
        if col.count() == 0:
            return []
        metas = col.get()["metadatas"]
        return sorted(set(m.get("arquivo", "") for m in metas if m.get("arquivo")))
    except Exception:
        return []


# ── geração de resposta via Groq com backoff exponencial ──────
def gerar_resposta(prompt: str, max_tentativas: int = 6) -> str:
    espera_base = 5.0
    espera_max  = 90.0

    for tentativa in range(1, max_tentativas + 1):
        try:
            resposta = cliente_groq.chat.completions.create(
                model=MODELO_GROQ,
                messages=[
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user",   "content": prompt},
                ],
                temperature=0.2,
                max_tokens=4096,
            )
            return resposta.choices[0].message.content

        except Exception as e:
            erro_str = str(e).lower()
            eh_413   = any(t in erro_str for t in _ERROS_413)
            eh_429   = any(t in erro_str for t in _ERROS_429)

            if eh_413:
                raise RuntimeError(
                    f"Prompt muito grande ({len(prompt.split())} palavras aprox). "
                    "Reduza o tamanho do contexto ou use lotes menores."
                ) from e

            if not eh_429:
                raise

            if tentativa == max_tentativas:
                raise RuntimeError(
                    f"Limite de {max_tentativas} tentativas no Groq. Último erro: {e}"
                )

            retry_after = None
            if hasattr(e, "response") and e.response is not None:
                retry_after = e.response.headers.get("retry-after")

            if retry_after:
                espera = min(float(retry_after), 60.0) + random.uniform(0.5, 2.0)
            else:
                espera = min(espera_base * (2 ** (tentativa - 1)), espera_max)
                espera += random.uniform(-2.0, 2.0)
                espera = max(espera, 2.0)

            logger.warning(
                "[gerar_resposta] 429 Groq (tentativa %d/%d). Aguardando %.1fs...",
                tentativa, max_tentativas, espera,
            )
            time.sleep(espera)


# ── estilos de resumo (mesmos textos do app.py) ────────────────
ESTILOS_RESUMO = {
    "didatico": {
        "label": "📖 Didático",
        "descricao": "Explica cada parte do texto em linguagem simples, com exemplos do cotidiano.",
        "prompt_lote": lambda pdf, texto: f"""Voce e um professor explicando um documento para um aluno iniciante.
Abaixo estao trechos do documento '{pdf}'.
Para CADA parte do texto encontrada, explique o que ela significa em linguagem simples e direta.
Use exemplos do cotidiano quando possivel.
Organize a explicacao em topicos, um para cada parte do texto.

TRECHOS:
{texto}

EXPLICACAO DIDATICA DE CADA PARTE:""",
        "prompt_final": lambda pdf, consolidado: f"""Voce recebeu explicacoes didaticas de varias partes do documento '{pdf}'.
Consolide tudo em um unico texto explicativo, organizado e coeso, mantendo a linguagem simples.
Preserve as explicacoes de cada parte mas elimine repeticoes.

PARTES EXPLICADAS:
{consolidado}

EXPLICACAO FINAL CONSOLIDADA:"""
    },
    "tecnico": {
        "label": "🔬 Técnico",
        "descricao": "Analisa cada parte com linguagem técnica, mantendo termos e referências do documento.",
        "prompt_lote": lambda pdf, texto: f"""Voce e um especialista tecnico analisando o documento '{pdf}'.
Para CADA parte do texto encontrada, faca uma analise tecnica detalhada.
Mantenha os termos tecnicos, referencias normativas e dados quantitativos encontrados.
Organize em topicos, um por parte do texto analisada.

TRECHOS:
{texto}

ANALISE TECNICA DE CADA PARTE:""",
        "prompt_final": lambda pdf, consolidado: f"""Consolide as analises tecnicas das partes do documento '{pdf}'.
Mantenha o rigor tecnico, os termos especializados e as referencias encontradas.
Elimine repeticoes mas preserve todos os dados tecnicos relevantes.

ANALISES:
{consolidado}

ANALISE TECNICA FINAL CONSOLIDADA:"""
    },
    "resumido": {
        "label": "⚡ Resumido",
        "descricao": "Resume cada parte em 2-3 frases objetivas, destacando apenas o essencial.",
        "prompt_lote": lambda pdf, texto: f"""Resuma de forma extremamente objetiva cada parte do documento '{pdf}'.
Para CADA parte do texto encontrada, escreva no maximo 2 a 3 frases destacando apenas o ponto principal.
Seja direto e elimine qualquer informacao secundaria.

TRECHOS:
{texto}

RESUMO OBJETIVO DE CADA PARTE:""",
        "prompt_final": lambda pdf, consolidado: f"""Consolide os resumos objetivos das partes do documento '{pdf}'.
Mantenha apenas os pontos mais importantes de cada parte.
O resultado deve ser um resumo executivo curto e direto.

RESUMOS:
{consolidado}

RESUMO EXECUTIVO FINAL:"""
    },
    "analitico": {
        "label": "🧠 Analítico",
        "descricao": "Analisa criticamente cada parte, identificando argumentos, evidências e conclusões.",
        "prompt_lote": lambda pdf, texto: f"""Voce e um analista critico examinando o documento '{pdf}'.
Para CADA parte do texto encontrada, identifique e explique:
- Qual e o argumento ou ideia central dessa parte
- Quais evidencias ou dados sao apresentados
- Qual e a conclusao ou implicacao dessa parte
Organize em topicos, um por parte analisada.

TRECHOS:
{texto}

ANALISE CRITICA DE CADA PARTE:""",
        "prompt_final": lambda pdf, consolidado: f"""Consolide a analise critica das partes do documento '{pdf}'.
Identifique os padroes, contradicoes e conclusoes gerais que emergem da analise de cada parte.
Apresente uma visao critica integrada do documento.

ANALISES:
{consolidado}

ANALISE CRITICA FINAL INTEGRADA:"""
    },
    "comparativo": {
        "label": "📋 Comparativo",
        "descricao": "Compara cada parte com conceitos similares, destacando diferenças e inovações.",
        "prompt_lote": lambda pdf, texto: f"""Voce e um especialista comparando o conteudo do documento '{pdf}' com conhecimentos estabelecidos na area.
Para CADA parte do texto encontrada, compare com versoes anteriores, conceitos similares ou praticas comuns.
Destaque o que e novo, diferente ou inovador em cada parte.
Organize em topicos, um por parte comparada.

TRECHOS:
{texto}

COMPARACAO DE CADA PARTE:""",
        "prompt_final": lambda pdf, consolidado: f"""Consolide as comparacoes das partes do documento '{pdf}'.
Apresente uma visao geral das diferencas e inovacoes encontradas ao longo de todo o documento.

COMPARACOES:
{consolidado}

COMPARACAO FINAL CONSOLIDADA:"""
    },
}


# ══════════════════════════════════════════════════════════════
# JOB: INDEXAR (roda em thread separada, progresso via polling)
# ══════════════════════════════════════════════════════════════
def _job_indexar(job_id: str, nome_banco: str, arquivos: list[tuple[str, bytes]]):
    job = JOBS[job_id]
    try:
        colecao = get_colecao(nome_banco)
        total_arquivos = len(arquivos)
        job["total_arquivos"] = total_arquivos

        for idx, (nome, conteudo) in enumerate(arquivos, 1):
            job["arquivo_idx"]  = idx
            job["arquivo_nome"] = nome
            job["lote_num"]     = 0
            job["total_lotes"]  = 0

            def callback(lote_num, total_lotes, _job=job):
                _job["lote_num"]    = lote_num
                _job["total_lotes"] = total_lotes

            eh_ultimo = idx == total_arquivos
            try:
                resultado = indexar_pdf_bytes(
                    nome, conteudo, colecao, cliente_gemini,
                    callback=callback,
                    pausar_ao_final=not eh_ultimo,
                )
                if resultado["status"] == "ok":
                    job["mensagens"].append(
                        f"✅ {nome} — {resultado['chunks']} itens indexados (texto + imagens)"
                    )
                    storage.sincronizar_banco_para_bucket(nome_banco)
                elif resultado["status"] == "ja_indexado":
                    job["mensagens"].append(f"↩️ {nome} — já indexado, pulando")
                else:
                    job["mensagens"].append(f"❌ {nome} — {resultado['erro']}")
            except Exception as e:
                job["mensagens"].append(f"❌ {nome} — erro: {e}")

        job["total_itens_banco"] = colecao.count()
        job["status"] = "concluido"
    except Exception as e:
        job["status"] = "erro"
        job["erro"]   = str(e)
    finally:
        job["concluido"] = True


class IniciarIndexarResposta(BaseModel):
    job_id: str


@app.post("/api/indexar/iniciar")
async def api_indexar_iniciar(
    nome_banco: str = Form(...),
    arquivos: list[UploadFile] = File(...),
):
    if not nome_banco.strip():
        raise HTTPException(400, "Digite um nome para o banco.")
    if not arquivos:
        raise HTTPException(400, "Selecione ao menos um PDF.")

    nome_banco_slug = _slug(nome_banco)
    conteudos = [(a.filename, await a.read()) for a in arquivos]

    job_id = str(uuid.uuid4())
    JOBS[job_id] = {
        "tipo": "indexar",
        "banco": nome_banco_slug,
        "status": "rodando",
        "concluido": False,
        "erro": None,
        "total_arquivos": len(conteudos),
        "arquivo_idx": 0,
        "arquivo_nome": "",
        "lote_num": 0,
        "total_lotes": 0,
        "mensagens": [],
        "total_itens_banco": None,
    }

    thread = threading.Thread(
        target=_job_indexar, args=(job_id, nome_banco_slug, conteudos), daemon=True
    )
    thread.start()

    return {"job_id": job_id, "banco": nome_banco_slug}


# ══════════════════════════════════════════════════════════════
# JOB: RESUMIR (roda em thread separada, progresso via polling)
# ══════════════════════════════════════════════════════════════
def _job_resumir(job_id: str, banco: str, pdf_sel: str, estilo_key: str):
    job = JOBS[job_id]
    try:
        estilo  = ESTILOS_RESUMO[estilo_key]
        colecao = get_colecao(banco)

        resultado = colecao.get(where={"arquivo": pdf_sel})
        chunks    = resultado["documents"]

        if not chunks:
            job["status"] = "erro"
            job["erro"]   = "Nenhum chunk encontrado para este PDF."
            return

        LOTE = 20
        PAUSA_ENTRE_LOTES = 5
        resumos_parciais  = []
        total_lotes = (len(chunks) + LOTE - 1) // LOTE
        job["total_lotes"] = total_lotes
        job["etapa"] = "analisando"

        for i in range(0, len(chunks), LOTE):
            lote       = chunks[i:i + LOTE]
            lote_num   = i // LOTE + 1
            job["lote_atual"] = lote_num
            texto_lote = "\n\n---PARTE---\n\n".join(lote)
            prompt     = estilo["prompt_lote"](pdf_sel, texto_lote)

            try:
                resumos_parciais.append(gerar_resposta(prompt))
            except Exception as e:
                resumos_parciais.append(f"[Erro no lote {lote_num}: {e}]")

            if lote_num < total_lotes:
                time.sleep(PAUSA_ENTRE_LOTES)

        if len(resumos_parciais) == 1:
            resumo_final = resumos_parciais[0]
        else:
            job["etapa"] = "consolidando"
            GRUPO  = 3
            grupos = [resumos_parciais[g:g + GRUPO] for g in range(0, len(resumos_parciais), GRUPO)]
            intermediarios = []
            for gi, grupo in enumerate(grupos):
                sub        = "\n\n===\n\n".join([f"Secao {i+1}:\n{r}" for i, r in enumerate(grupo)])
                prompt_sub = estilo["prompt_final"](pdf_sel, sub)
                try:
                    intermediarios.append(gerar_resposta(prompt_sub))
                    if gi < len(grupos) - 1:
                        time.sleep(PAUSA_ENTRE_LOTES)
                except Exception as e:
                    intermediarios.append(f"[Erro grupo {gi+1}: {e}]")

            if len(intermediarios) == 1:
                resumo_final = intermediarios[0]
            else:
                consolidado_final = "\n\n===\n\n".join(
                    [f"Parte {i+1}:\n{r}" for i, r in enumerate(intermediarios)]
                )
                prompt_final = estilo["prompt_final"](pdf_sel, consolidado_final)
                try:
                    resumo_final = gerar_resposta(prompt_final)
                except Exception as e:
                    resumo_final = f"(Erro final: {e})\n\n" + consolidado_final

        job["resumo_final"] = resumo_final
        job["status"] = "concluido"
    except Exception as e:
        job["status"] = "erro"
        job["erro"]   = str(e)
    finally:
        job["concluido"] = True


class ResumirRequest(BaseModel):
    banco: str
    pdf: str
    estilo: str


@app.post("/api/resumir/iniciar")
async def api_resumir_iniciar(req: ResumirRequest):
    if req.estilo not in ESTILOS_RESUMO:
        raise HTTPException(400, "Estilo de resumo inválido.")

    job_id = str(uuid.uuid4())
    JOBS[job_id] = {
        "tipo": "resumir",
        "status": "rodando",
        "concluido": False,
        "erro": None,
        "etapa": "iniciando",
        "total_lotes": 0,
        "lote_atual": 0,
        "resumo_final": None,
    }

    thread = threading.Thread(
        target=_job_resumir, args=(job_id, req.banco, req.pdf, req.estilo), daemon=True
    )
    thread.start()

    return {"job_id": job_id}


# ── consulta genérica de progresso de jobs ─────────────────────
@app.get("/api/jobs/{job_id}")
async def api_job_status(job_id: str):
    job = JOBS.get(job_id)
    if job is None:
        raise HTTPException(404, "Job não encontrado.")
    return job


# ══════════════════════════════════════════════════════════════
# BANCOS / STATUS
# ══════════════════════════════════════════════════════════════
@app.get("/api/bancos")
async def api_listar_bancos():
    return {"bancos": listar_bancos()}


@app.get("/api/bancos/{banco}/pdfs")
async def api_listar_pdfs(banco: str):
    return {"pdfs": listar_pdfs(banco)}


@app.get("/api/status")
async def api_status():
    saida = []
    for banco in listar_bancos():
        try:
            col    = get_colecao(banco)
            pdfs   = listar_pdfs(banco)
            saida.append({
                "banco": banco,
                "chunks": col.count(),
                "pdfs": pdfs,
                "erro": None,
            })
        except Exception as e:
            saida.append({"banco": banco, "chunks": 0, "pdfs": [], "erro": str(e)})
    return {"bancos": saida, "bucket_habilitado": storage.HABILITADO}


@app.post("/api/storage/sincronizar")
async def api_storage_sincronizar():
    """Força o download de todos os bancos do dataset do Hugging Face para o disco local."""
    if not storage.HABILITADO:
        raise HTTPException(400, "Dataset não configurado. Defina HF_TOKEN e HF_DATASET_REPO no .env.")
    storage.sincronizar_tudo_do_bucket()
    return {"status": "ok"}


@app.get("/api/estilos_resumo")
async def api_estilos_resumo():
    return {
        "estilos": [
            {"chave": chave, "label": v["label"], "descricao": v["descricao"]}
            for chave, v in ESTILOS_RESUMO.items()
        ]
    }


# ══════════════════════════════════════════════════════════════
# PERGUNTAR (síncrono — busca + rerank + resposta do LLM)
# ══════════════════════════════════════════════════════════════
class PerguntarRequest(BaseModel):
    banco: str
    pergunta: str
    top_k: int = 10
    top_n: int = 5


@app.post("/api/perguntar")
async def api_perguntar(req: PerguntarRequest):
    if not req.pergunta.strip():
        raise HTTPException(400, "Digite uma pergunta.")

    colecao = get_colecao(req.banco)
    if colecao.count() == 0:
        raise HTTPException(400, "Banco vazio. Indexe PDFs primeiro.")

    try:
        trechos_raw = buscar_trechos(req.pergunta, colecao, cliente_gemini, top_k=req.top_k)
        trechos     = rerankar_trechos(req.pergunta, trechos_raw, ranker, top_n=req.top_n)
    except Exception as e:
        raise HTTPException(500, f"Erro na busca: {e}")

    try:
        contexto = montar_contexto(trechos)
        prompt   = f"TRECHOS RECUPERADOS:\n{contexto}\n\nPERGUNTA: {req.pergunta}"
        resposta = gerar_resposta(prompt)
    except Exception as e:
        raise HTTPException(500, f"Erro ao gerar resposta: {e}")

    return {
        "pergunta": req.pergunta,
        "banco": req.banco,
        "resposta": resposta,
        "trechos": trechos,
    }


# ══════════════════════════════════════════════════════════════
# GERAÇÃO DE PDF (stateless — recebe os dados e devolve o arquivo)
# ══════════════════════════════════════════════════════════════
class GerarPdfRespostaRequest(BaseModel):
    pergunta: str
    resposta: str
    banco: str
    trechos: list[dict]


@app.post("/api/gerar_pdf_resposta")
async def api_gerar_pdf_resposta(req: GerarPdfRespostaRequest):
    pdf_bytes = gerar_pdf_resposta(
        pergunta=req.pergunta,
        resposta=req.resposta,
        banco=req.banco,
        trechos=req.trechos,
    )
    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers={"Content-Disposition": 'attachment; filename="resposta.pdf"'},
    )


class GerarPdfResumoRequest(BaseModel):
    nome_pdf: str
    banco: str
    resumo: str
    estilo: str = ""


@app.post("/api/gerar_pdf_resumo")
async def api_gerar_pdf_resumo(req: GerarPdfResumoRequest):
    pdf_bytes = gerar_pdf_resumo(
        nome_pdf=req.nome_pdf,
        banco=req.banco,
        resumo=req.resumo,
        estilo=req.estilo,
    )
    nome_arquivo = f"resumo_{req.nome_pdf}"
    if not nome_arquivo.lower().endswith(".pdf"):
        nome_arquivo += ".pdf"
    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{nome_arquivo}"'},
    )


# ══════════════════════════════════════════════════════════════
# FRONTEND (HTML estático)
# ══════════════════════════════════════════════════════════════
app.mount("/static", StaticFiles(directory=os.path.join(BASE_DIR, "static")), name="static")


@app.get("/")
async def index():
    return FileResponse(os.path.join(BASE_DIR, "static", "index.html"))
CLAUDE_EOF

mkdir -p "$(dirname "perguntar.py")"
cat > 'perguntar.py' << 'CLAUDE_EOF'
"""
perguntar.py — busca, rerank e montagem de contexto
Usa gemini-embedding-2-preview para embedding da pergunta
LLM: Groq llama-3.1-8b-instant (via app.py)
"""

from google import genai
from google.genai import types
from flashrank import Ranker, RerankRequest

EMBEDDING_MODEL = "gemini-embedding-2-preview"
TOP_K           = 10
TOP_N_RERANK    = 5

SYSTEM_PROMPT = """Você é um assistente de estudo especializado.
Responda sempre em português, de forma clara e didática.
Use apenas as informações dos trechos fornecidos para responder.
Ao final, cite de qual arquivo cada informação veio.
Se a informação não estiver nos trechos, diga isso claramente.
Quando um trecho se referir a uma imagem, figura ou página escaneada,
descreva o que foi encontrado com base no contexto disponível."""


def gerar_embedding_pergunta(cliente: genai.Client, pergunta: str) -> list[float]:
    """Gera embedding da pergunta no mesmo espaço vetorial multimodal."""
    resultado = cliente.models.embed_content(
        model=EMBEDDING_MODEL,
        contents=pergunta,
        config=types.EmbedContentConfig(task_type="RETRIEVAL_QUERY")
    )
    return resultado.embeddings[0].values


def buscar_trechos(
    pergunta: str,
    colecao,
    cliente: genai.Client,
    top_k: int = TOP_K
) -> list[dict]:
    """Busca os top_k trechos mais relevantes via embedding multimodal."""
    embedding  = gerar_embedding_pergunta(cliente, pergunta)
    resultados = colecao.query(
        query_embeddings=[embedding],
        n_results=top_k,
        include=["documents", "metadatas", "distances"]
    )
    trechos = []
    for doc, meta, dist in zip(
        resultados["documents"][0],
        resultados["metadatas"][0],
        resultados["distances"][0]
    ):
        tipo = meta.get("tipo", "texto")
        trechos.append({
            "texto":     doc,
            "arquivo":   meta["arquivo"],
            "tipo":      tipo,
            "relevancia": round(1 - dist, 3),
            "meta":      meta
        })
    return trechos


def rerankar_trechos(
    pergunta: str,
    trechos: list[dict],
    ranker: Ranker,
    top_n: int = TOP_N_RERANK
) -> list[dict]:
    """Reordena os trechos usando Flashrank."""
    if not trechos:
        return []

    passages       = [{"id": i, "text": t["texto"]} for i, t in enumerate(trechos)]
    rerank_request = RerankRequest(query=pergunta, passages=passages)
    resultados     = ranker.rerank(rerank_request)

    return [
        {
            "texto":             trechos[r["id"]]["texto"],
            "arquivo":           trechos[r["id"]]["arquivo"],
            "tipo":              trechos[r["id"]]["tipo"],
            "relevancia":        trechos[r["id"]]["relevancia"],
            "relevancia_rerank": round(r["score"], 4),
            "meta":              trechos[r["id"]]["meta"]
        }
        for r in resultados[:top_n]
    ]


def montar_contexto(trechos: list) -> str:
    """Monta o bloco de contexto para o prompt do LLM."""
    contexto = ""
    for i, t in enumerate(trechos, 1):
        tipo  = t.get("tipo", "texto")
        label = {
            "texto":           "Texto",
            "pagina_escaneada": "Página escaneada",
            "figura":          "Figura"
        }.get(tipo, "Conteúdo")

        contexto += (
            f"\n--- Trecho {i} [{label}] "
            f"(arquivo: {t['arquivo']}, "
            f"relevância rerank: {t['relevancia_rerank']}) ---\n"
        )
        contexto += t["texto"] + "\n"
    return contexto
CLAUDE_EOF

mkdir -p "$(dirname "storage.py")"
cat > 'storage.py' << 'CLAUDE_EOF'
"""
storage.py — sincronização do ChromaDB local com um Dataset privado do
Hugging Face Hub, usado aqui como "bucket" gratuito de armazenamento.

Por quê: o Hugging Face Spaces (tier gratuito, sem "Persistent Storage" pago)
apaga o disco do container a cada reinício/redeploy. Como o ChromaDB do app
grava os bancos em ./chroma_bancos, sem isso todo PDF indexado se perderia.

Como funciona:
- No startup do FastAPI: baixa o conteúdo do dataset para ./chroma_bancos.
- Depois de indexar um PDF com sucesso: envia a pasta daquele banco de volta
  para o dataset (um commit por banco atualizado).

Se HF_TOKEN ou HF_DATASET_REPO não estiverem configurados, a sincronização é
ignorada — o app roda 100% local, como antes.

Variáveis de ambiente (.env):
    HF_TOKEN            token do Hugging Face com permissão de escrita
                         (gerado em huggingface.co/settings/tokens)
    HF_DATASET_REPO      repositório de destino, ex: "seu-usuario/rag-chroma-storage"
    HF_DATASET_PRIVATE   "true"/"false" (padrão: true) — usado só na criação do repo
"""

import os
import logging
import threading

logger = logging.getLogger(__name__)

CHROMA_BASE_DIR = "./chroma_bancos"

HF_TOKEN           = os.environ.get("HF_TOKEN", "").strip()
HF_DATASET_REPO    = os.environ.get("HF_DATASET_REPO", "").strip()
HF_DATASET_PRIVATE = os.environ.get("HF_DATASET_PRIVATE", "true").strip().lower() != "false"

HABILITADO = bool(HF_TOKEN and HF_DATASET_REPO)

_lock        = threading.Lock()
_repo_pronto = False


def _garantir_repo():
    """Cria o dataset no Hub caso ainda não exista (idempotente)."""
    global _repo_pronto
    if _repo_pronto:
        return
    from huggingface_hub import HfApi

    api = HfApi(token=HF_TOKEN)
    api.create_repo(
        repo_id=HF_DATASET_REPO,
        repo_type="dataset",
        private=HF_DATASET_PRIVATE,
        exist_ok=True,
    )
    _repo_pronto = True


def sincronizar_tudo_do_bucket():
    """Baixa todos os bancos existentes no dataset para a pasta local. Chamar no startup."""
    if not HABILITADO:
        logger.info("[storage] Dataset do Hugging Face não configurado — usando apenas disco local.")
        return

    try:
        from huggingface_hub import snapshot_download

        os.makedirs(CHROMA_BASE_DIR, exist_ok=True)
        with _lock:
            _garantir_repo()
            snapshot_download(
                repo_id=HF_DATASET_REPO,
                repo_type="dataset",
                token=HF_TOKEN,
                local_dir=CHROMA_BASE_DIR,
            )
        logger.info(f"[storage] Bancos restaurados do dataset '{HF_DATASET_REPO}'.")
    except Exception as e:
        logger.error(f"[storage] Falha ao restaurar do dataset: {e}")


def sincronizar_banco_para_bucket(nome_banco: str):
    """Envia todos os arquivos de um banco local para o dataset (um commit)."""
    if not HABILITADO:
        return

    try:
        from huggingface_hub import HfApi

        pasta_banco = os.path.join(CHROMA_BASE_DIR, nome_banco)
        if not os.path.isdir(pasta_banco):
            return

        with _lock:
            _garantir_repo()
            api = HfApi(token=HF_TOKEN)
            api.upload_folder(
                repo_id=HF_DATASET_REPO,
                repo_type="dataset",
                folder_path=pasta_banco,
                path_in_repo=nome_banco,
                commit_message=f"Atualiza banco '{nome_banco}'",
            )
        logger.info(f"[storage] Banco '{nome_banco}' sincronizado para o dataset '{HF_DATASET_REPO}'.")
    except Exception as e:
        logger.error(f"[storage] Falha ao sincronizar banco '{nome_banco}' para o dataset: {e}")
CLAUDE_EOF

mkdir -p "$(dirname "static/app.js")"
cat > 'static/app.js' << 'CLAUDE_EOF'
// ── utilidades ──────────────────────────────────────────────
async function apiGet(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || `Erro ${r.status}`);
  return r.json();
}
async function apiPostJSON(url, body) {
  const r = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || `Erro ${r.status}`);
  return r.json();
}
async function apiPostBlob(url, body) {
  const r = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || `Erro ${r.status}`);
  const disposition = r.headers.get("Content-Disposition") || "";
  const match = disposition.match(/filename="?([^"]+)"?/);
  return { blob: await r.blob(), filename: match ? match[1] : "arquivo.pdf" };
}
function baixarBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}
function esperar(ms) { return new Promise((res) => setTimeout(res, ms)); }
function escapeHtml(s) {
  return (s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[c]));
}

// ── navegação entre abas ────────────────────────────────────
const fichas = document.querySelectorAll(".ficha");
const paineis = document.querySelectorAll(".painel");

fichas.forEach((ficha) => {
  ficha.addEventListener("click", () => ativarAba(ficha.dataset.tab));
});

function ativarAba(nome) {
  fichas.forEach((f) => f.setAttribute("aria-selected", f.dataset.tab === nome ? "true" : "false"));
  paineis.forEach((p) => p.classList.toggle("escondido", p.dataset.panel !== nome));

  if (nome === "perguntar") carregarBancosPerguntar();
  if (nome === "resumir") carregarBancosResumir();
  if (nome === "status") carregarStatus();
}

// ══════════════════════════════════════════════════════════
// ABA: INDEXAR
// ══════════════════════════════════════════════════════════
const formIndexar = document.getElementById("form-indexar");
const inputArquivos = document.getElementById("input-arquivos");
const listaArquivosSelecionados = document.getElementById("lista-arquivos-selecionados");
const btnIndexar = document.getElementById("btn-indexar");
const progressoIndexar = document.getElementById("progresso-indexar");
const barraIndexar = document.getElementById("barra-indexar");
const logIndexar = document.getElementById("log-indexar");
const progNomeArquivo = document.getElementById("progresso-indexar-arquivo-nome");
const progContadorArquivo = document.getElementById("progresso-indexar-arquivo-contador");

inputArquivos.addEventListener("change", () => {
  const nomes = Array.from(inputArquivos.files).map((f) => f.name);
  listaArquivosSelecionados.textContent = nomes.length
    ? `${nomes.length} arquivo(s): ${nomes.join(", ")}`
    : "Nenhum arquivo selecionado.";
});

formIndexar.addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const nomeBanco = document.getElementById("input-nome-banco").value.trim();
  const arquivos = inputArquivos.files;

  if (!nomeBanco) { alert("Digite um nome para o banco."); return; }
  if (!arquivos.length) { alert("Selecione ao menos um PDF."); return; }

  btnIndexar.disabled = true;
  btnIndexar.textContent = "Indexando…";
  progressoIndexar.classList.remove("oculto");
  logIndexar.innerHTML = "";
  barraIndexar.style.width = "0%";

  try {
    const fd = new FormData();
    fd.append("nome_banco", nomeBanco);
    Array.from(arquivos).forEach((f) => fd.append("arquivos", f));

    const r = await fetch("/api/indexar/iniciar", { method: "POST", body: fd });
    if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || "Falha ao iniciar indexação.");
    const { job_id } = await r.json();

    await acompanharJobIndexar(job_id);
  } catch (e) {
    logIndexar.innerHTML += `<li class="erro-msg">${escapeHtml(e.message)}</li>`;
  } finally {
    btnIndexar.disabled = false;
    btnIndexar.textContent = "Indexar PDFs";
  }
});

async function acompanharJobIndexar(jobId) {
  while (true) {
    const job = await apiGet(`/api/jobs/${jobId}`);

    const totalArquivos = job.total_arquivos || 0;
    const idxArquivo = job.arquivo_idx || 0;
    progNomeArquivo.textContent = job.arquivo_nome ? `📄 ${job.arquivo_nome}` : "Preparando…";
    progContadorArquivo.textContent = totalArquivos ? `${idxArquivo}/${totalArquivos}` : "";

    const totalLotes = job.total_lotes || 0;
    const loteNum = job.lote_num || 0;
    const pct = totalLotes ? Math.min(100, Math.round((loteNum / totalLotes) * 100)) : 0;
    barraIndexar.style.width = `${pct}%`;

    logIndexar.innerHTML = (job.mensagens || [])
      .map((m) => `<li>${escapeHtml(m)}</li>`)
      .join("");

    if (job.concluido) {
      if (job.status === "erro") {
        logIndexar.innerHTML += `<li class="erro-msg">${escapeHtml(job.erro)}</li>`;
      } else {
        barraIndexar.style.width = "100%";
        logIndexar.innerHTML += `<li>🗄️ Total de itens no banco: ${job.total_itens_banco}</li>`;
        formIndexar.reset();
        listaArquivosSelecionados.textContent = "Nenhum arquivo selecionado.";
      }
      break;
    }
    await esperar(1200);
  }
}

// ══════════════════════════════════════════════════════════
// ABA: PERGUNTAR
// ══════════════════════════════════════════════════════════
const selectBancoPerguntar = document.getElementById("select-banco-perguntar");
const perguntarSemBanco = document.getElementById("perguntar-sem-banco");
const perguntarFormWrap = document.getElementById("perguntar-form-wrap");
const rangeTopK = document.getElementById("range-top-k");
const rangeTopN = document.getElementById("range-top-n");
const valorTopK = document.getElementById("valor-top-k");
const valorTopN = document.getElementById("valor-top-n");
const inputPergunta = document.getElementById("input-pergunta");
const btnPerguntar = document.getElementById("btn-perguntar");
const perguntarCarregando = document.getElementById("perguntar-carregando");
const resultadoPerguntar = document.getElementById("resultado-perguntar");
const textoResposta = document.getElementById("texto-resposta");
const listaTrechos = document.getElementById("lista-trechos");
const btnBaixarResposta = document.getElementById("btn-baixar-resposta");

let ultimoResultadoPergunta = null;
let bancosPerguntarCarregados = false;

rangeTopK.addEventListener("input", () => (valorTopK.textContent = rangeTopK.value));
rangeTopN.addEventListener("input", () => (valorTopN.textContent = rangeTopN.value));

async function carregarBancosPerguntar() {
  if (bancosPerguntarCarregados) return;
  try {
    const { bancos } = await apiGet("/api/bancos");
    if (!bancos.length) {
      perguntarSemBanco.classList.remove("oculto");
      perguntarFormWrap.style.display = "none";
      return;
    }
    perguntarSemBanco.classList.add("oculto");
    perguntarFormWrap.style.display = "";
    selectBancoPerguntar.innerHTML = bancos.map((b) => `<option value="${escapeHtml(b)}">${escapeHtml(b)}</option>`).join("");
    bancosPerguntarCarregados = true;
  } catch (e) {
    alert("Erro ao carregar bancos: " + e.message);
  }
}

btnPerguntar.addEventListener("click", async () => {
  const banco = selectBancoPerguntar.value;
  const pergunta = inputPergunta.value.trim();
  if (!pergunta) { alert("Digite uma pergunta."); return; }

  btnPerguntar.disabled = true;
  perguntarCarregando.classList.remove("oculto");
  resultadoPerguntar.classList.add("oculto");

  try {
    const resultado = await apiPostJSON("/api/perguntar", {
      banco,
      pergunta,
      top_k: Number(rangeTopK.value),
      top_n: Number(rangeTopN.value),
    });
    ultimoResultadoPergunta = resultado;

    textoResposta.textContent = resultado.resposta;

    const emojiPorTipo = { texto: "📝", pagina_escaneada: "🖼️", figura: "📊" };
    listaTrechos.innerHTML = resultado.trechos.map((t, i) => `
      <div class="trecho-card">
        <div class="trecho-cabecalho">
          <span class="trecho-num">#${i + 1}</span>
          <span>${emojiPorTipo[t.tipo] || "📄"} ${escapeHtml(t.arquivo)}</span>
          <span class="trecho-tipo">[${escapeHtml(t.tipo)}]</span>
          <span class="mono">rerank: ${t.relevancia_rerank} · embed: ${t.relevancia}</span>
        </div>
        <div class="trecho-texto">${escapeHtml(t.texto)}</div>
      </div>
    `).join("");

    resultadoPerguntar.classList.remove("oculto");
  } catch (e) {
    alert("Erro: " + e.message);
  } finally {
    btnPerguntar.disabled = false;
    perguntarCarregando.classList.add("oculto");
  }
});

btnBaixarResposta.addEventListener("click", async () => {
  if (!ultimoResultadoPergunta) return;
  btnBaixarResposta.disabled = true;
  try {
    const { blob, filename } = await apiPostBlob("/api/gerar_pdf_resposta", {
      pergunta: ultimoResultadoPergunta.pergunta,
      resposta: ultimoResultadoPergunta.resposta,
      banco: ultimoResultadoPergunta.banco,
      trechos: ultimoResultadoPergunta.trechos,
    });
    baixarBlob(blob, filename);
  } catch (e) {
    alert("Erro ao gerar PDF: " + e.message);
  } finally {
    btnBaixarResposta.disabled = false;
  }
});

// ══════════════════════════════════════════════════════════
// ABA: RESUMIR
// ══════════════════════════════════════════════════════════
const selectBancoResumir = document.getElementById("select-banco-resumir");
const selectPdfResumir = document.getElementById("select-pdf-resumir");
const selectEstiloResumir = document.getElementById("select-estilo-resumir");
const descricaoEstiloResumir = document.getElementById("descricao-estilo-resumir");
const resumirSemBanco = document.getElementById("resumir-sem-banco");
const resumirFormWrap = document.getElementById("resumir-form-wrap");
const btnResumir = document.getElementById("btn-resumir");
const progressoResumir = document.getElementById("progresso-resumir");
const barraResumir = document.getElementById("barra-resumir");
const progResumirEtapa = document.getElementById("progresso-resumir-etapa");
const progResumirContador = document.getElementById("progresso-resumir-contador");
const resultadoResumir = document.getElementById("resultado-resumir");
const tituloResultadoResumir = document.getElementById("titulo-resultado-resumir");
const textoResumo = document.getElementById("texto-resumo");
const btnBaixarResumo = document.getElementById("btn-baixar-resumo");

let estilosResumo = [];
let bancosResumirCarregados = false;
let ultimoResumo = null; // { nome_pdf, banco, resumo, estilo_label }

async function carregarBancosResumir() {
  if (!bancosResumirCarregados) {
    try {
      const { bancos } = await apiGet("/api/bancos");
      if (!bancos.length) {
        resumirSemBanco.classList.remove("oculto");
        resumirFormWrap.style.display = "none";
        return;
      }
      resumirSemBanco.classList.add("oculto");
      resumirFormWrap.style.display = "";
      selectBancoResumir.innerHTML = bancos.map((b) => `<option value="${escapeHtml(b)}">${escapeHtml(b)}</option>`).join("");
      bancosResumirCarregados = true;

      const { estilos } = await apiGet("/api/estilos_resumo");
      estilosResumo = estilos;
      selectEstiloResumir.innerHTML = estilos.map((e) => `<option value="${escapeHtml(e.chave)}">${escapeHtml(e.label)}</option>`).join("");
      atualizarDescricaoEstilo();
    } catch (e) {
      alert("Erro ao carregar bancos: " + e.message);
      return;
    }
  }
  await carregarPdfsDoBanco();
}

selectBancoResumir.addEventListener("change", carregarPdfsDoBanco);
selectEstiloResumir.addEventListener("change", atualizarDescricaoEstilo);

function atualizarDescricaoEstilo() {
  const atual = estilosResumo.find((e) => e.chave === selectEstiloResumir.value);
  descricaoEstiloResumir.textContent = atual ? atual.descricao : "";
}

async function carregarPdfsDoBanco() {
  const banco = selectBancoResumir.value;
  if (!banco) return;
  try {
    const { pdfs } = await apiGet(`/api/bancos/${encodeURIComponent(banco)}/pdfs`);
    selectPdfResumir.innerHTML = pdfs.length
      ? pdfs.map((p) => `<option value="${escapeHtml(p)}">${escapeHtml(p)}</option>`).join("")
      : `<option value="">Nenhum PDF neste banco</option>`;
  } catch (e) {
    alert("Erro ao carregar PDFs: " + e.message);
  }
}

btnResumir.addEventListener("click", async () => {
  const banco = selectBancoResumir.value;
  const pdf = selectPdfResumir.value;
  const estilo = selectEstiloResumir.value;
  if (!pdf) { alert("Selecione um PDF."); return; }

  btnResumir.disabled = true;
  progressoResumir.classList.remove("oculto");
  resultadoResumir.classList.add("oculto");
  barraResumir.style.width = "0%";

  try {
    const { job_id } = await apiPostJSON("/api/resumir/iniciar", { banco, pdf, estilo });
    await acompanharJobResumir(job_id, pdf, banco, estilo);
  } catch (e) {
    alert("Erro: " + e.message);
  } finally {
    btnResumir.disabled = false;
  }
});

async function acompanharJobResumir(jobId, pdf, banco, estiloChave) {
  const etapaLabel = { iniciando: "Preparando…", analisando: "Analisando partes…", consolidando: "Consolidando análise…" };

  while (true) {
    const job = await apiGet(`/api/jobs/${jobId}`);
    progResumirEtapa.textContent = etapaLabel[job.etapa] || "Processando…";

    const totalLotes = job.total_lotes || 0;
    const loteAtual = job.lote_atual || 0;
    progResumirContador.textContent = totalLotes ? `${loteAtual}/${totalLotes}` : "";
    barraResumir.style.width = totalLotes ? `${Math.min(100, Math.round((loteAtual / totalLotes) * 100))}%` : "0%";

    if (job.concluido) {
      if (job.status === "erro") {
        alert("Erro ao gerar resumo: " + job.erro);
      } else {
        barraResumir.style.width = "100%";
        const estiloInfo = estilosResumo.find((e) => e.chave === estiloChave);
        const estiloLabel = estiloInfo ? estiloInfo.label : estiloChave;
        ultimoResumo = { nome_pdf: pdf, banco, resumo: job.resumo_final, estilo_label: estiloLabel };
        tituloResultadoResumir.textContent = `Resultado — ${estiloLabel}`;
        textoResumo.textContent = job.resumo_final;
        resultadoResumir.classList.remove("oculto");
      }
      break;
    }
    await esperar(1200);
  }
}

btnBaixarResumo.addEventListener("click", async () => {
  if (!ultimoResumo) return;
  btnBaixarResumo.disabled = true;
  try {
    const { blob, filename } = await apiPostBlob("/api/gerar_pdf_resumo", {
      nome_pdf: ultimoResumo.nome_pdf,
      banco: ultimoResumo.banco,
      resumo: ultimoResumo.resumo,
      estilo: ultimoResumo.estilo_label,
    });
    baixarBlob(blob, filename);
  } catch (e) {
    alert("Erro ao gerar PDF: " + e.message);
  } finally {
    btnBaixarResumo.disabled = false;
  }
});

// ══════════════════════════════════════════════════════════
// ABA: STATUS
// ══════════════════════════════════════════════════════════
const statusVazio = document.getElementById("status-vazio");
const listaStatus = document.getElementById("lista-status");
const statusBucket = document.getElementById("status-bucket");
const btnAtualizarStatus = document.getElementById("btn-atualizar-status");
const btnSincronizarBucket = document.getElementById("btn-sincronizar-bucket");

btnAtualizarStatus.addEventListener("click", carregarStatus);

btnSincronizarBucket.addEventListener("click", async () => {
  btnSincronizarBucket.disabled = true;
  btnSincronizarBucket.textContent = "Sincronizando…";
  try {
    await fetch("/api/storage/sincronizar", { method: "POST" }).then(async (r) => {
      if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || `Erro ${r.status}`);
    });
    await carregarStatus();
  } catch (e) {
    alert("Erro ao sincronizar: " + e.message);
  } finally {
    btnSincronizarBucket.disabled = false;
    btnSincronizarBucket.textContent = "Sincronizar do dataset";
  }
});

async function carregarStatus() {
  try {
    const { bancos, bucket_habilitado } = await apiGet("/api/status");

    statusBucket.className = "bucket-tag " + (bucket_habilitado ? "ligado" : "desligado");
    statusBucket.textContent = bucket_habilitado
      ? "☁️ dataset do Hugging Face conectado — bancos persistem entre reinícios"
      : "⚠️ sem dataset configurado — bancos serão perdidos ao reiniciar o container";
    btnSincronizarBucket.style.display = bucket_habilitado ? "" : "none";

    if (!bancos.length) {
      statusVazio.classList.remove("oculto");
      listaStatus.innerHTML = "";
      return;
    }
    statusVazio.classList.add("oculto");
    listaStatus.innerHTML = bancos.map((b, i) => {
      if (b.erro) {
        return `<div class="banco-card"><div class="banco-cabecalho">🗄️ ${escapeHtml(b.banco)} <span class="banco-erro mono">${escapeHtml(b.erro)}</span></div></div>`;
      }
      return `
        <div class="banco-card" data-idx="${i}">
          <div class="banco-cabecalho">
            <span>🗄️ ${escapeHtml(b.banco)}</span>
            <span class="mono">${b.chunks} itens · ${b.pdfs.length} PDF(s)</span>
          </div>
          <div class="banco-pdfs">
            ${b.pdfs.map((p) => `<div>• ${escapeHtml(p)}</div>`).join("") || "<div>Nenhum PDF.</div>"}
          </div>
        </div>
      `;
    }).join("");

    listaStatus.querySelectorAll(".banco-cabecalho").forEach((cab) => {
      cab.addEventListener("click", () => cab.closest(".banco-card").classList.toggle("aberto"));
    });
  } catch (e) {
    alert("Erro ao carregar status: " + e.message);
  }
}

// carrega o status já na primeira visita, para a aba inicial ficar coerente
carregarStatus();
CLAUDE_EOF

mkdir -p "$(dirname "static/index.html")"
cat > 'static/index.html' << 'CLAUDE_EOF'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>RAG com PDFs</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Source+Serif+4:opsz,wght@8..60,500;8..60,600;8..60,700&family=Inter:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/static/style.css">
</head>
<body>

<header class="topo">
  <div class="topo-plate">
    <span class="topo-eyebrow">CATÁLOGO DIGITAL &middot; RAG</span>
    <h1>Perguntas &amp; Respostas sobre PDFs</h1>
    <p class="topo-sub">Gemini Embedding (multimodal) + Llama 3.1 via Groq + Flashrank + ChromaDB</p>
  </div>
</header>

<nav class="fichario" role="tablist" aria-label="Seções">
  <button class="ficha" data-tab="indexar" role="tab" aria-selected="true">
    <span class="ficha-num">01</span><span class="ficha-label">Indexar</span>
  </button>
  <button class="ficha" data-tab="perguntar" role="tab" aria-selected="false">
    <span class="ficha-num">02</span><span class="ficha-label">Perguntar</span>
  </button>
  <button class="ficha" data-tab="resumir" role="tab" aria-selected="false">
    <span class="ficha-num">03</span><span class="ficha-label">Resumir</span>
  </button>
  <button class="ficha" data-tab="status" role="tab" aria-selected="false">
    <span class="ficha-num">04</span><span class="ficha-label">Status</span>
  </button>
</nav>

<main class="conteudo">

  <!-- ══════════════ ABA: INDEXAR ══════════════ -->
  <section class="painel" id="painel-indexar" data-panel="indexar">
    <div class="cartao">
      <div class="cartao-aba">Índice novo</div>
      <p class="cartao-intro">
        Digite um nome para o banco e envie os PDFs. Suporte a texto nativo,
        páginas escaneadas e figuras/gráficos via embeddings multimodais.
      </p>

      <form id="form-indexar" class="form-grid">
        <label class="campo">
          <span>Nome do banco</span>
          <input type="text" id="input-nome-banco" placeholder="Ex: direito_civil, medicina_2024, tcc_joao" required>
          <small>Será convertido para minúsculas e sem espaços.</small>
        </label>

        <label class="campo campo-arquivo" id="dropzone">
          <span>Selecione os PDFs</span>
          <input type="file" id="input-arquivos" accept="application/pdf" multiple required>
          <small id="lista-arquivos-selecionados">Nenhum arquivo selecionado.</small>
        </label>

        <button type="submit" class="botao botao-primario" id="btn-indexar">Indexar PDFs</button>
      </form>

      <div id="progresso-indexar" class="progresso oculto">
        <div class="progresso-arquivo">
          <span id="progresso-indexar-arquivo-nome">—</span>
          <span id="progresso-indexar-arquivo-contador" class="mono"></span>
        </div>
        <div class="barra"><div class="barra-preenchimento" id="barra-indexar"></div></div>
        <ul id="log-indexar" class="log"></ul>
      </div>
    </div>
  </section>

  <!-- ══════════════ ABA: PERGUNTAR ══════════════ -->
  <section class="painel escondido" id="painel-perguntar" data-panel="perguntar">
    <div class="cartao">
      <div class="cartao-aba">Consulta</div>

      <div id="perguntar-sem-banco" class="aviso oculto">Nenhum banco encontrado. Indexe PDFs primeiro.</div>

      <div id="perguntar-form-wrap">
        <div class="form-grid form-grid-2col">
          <label class="campo">
            <span>Banco ativo</span>
            <select id="select-banco-perguntar"></select>
          </label>
          <div class="campo-duplo">
            <label class="campo">
              <span>Candidatos (top_k): <b id="valor-top-k">10</b></span>
              <input type="range" id="range-top-k" min="5" max="20" value="10">
            </label>
            <label class="campo">
              <span>Após rerank (top_n): <b id="valor-top-n">5</b></span>
              <input type="range" id="range-top-n" min="2" max="8" value="5">
            </label>
          </div>
        </div>

        <label class="campo">
          <span>Sua pergunta</span>
          <textarea id="input-pergunta" rows="3" placeholder="Ex: Quais são os principais conceitos abordados?"></textarea>
        </label>

        <button class="botao botao-primario" id="btn-perguntar">Perguntar</button>
      </div>

      <div id="perguntar-carregando" class="carregando oculto">Buscando trechos relevantes e gerando resposta…</div>

      <div id="resultado-perguntar" class="resultado oculto">
        <h3>Resposta</h3>
        <p id="texto-resposta" class="texto-resposta"></p>

        <details class="trechos-detalhe">
          <summary>Trechos utilizados</summary>
          <div id="lista-trechos"></div>
        </details>

        <button class="botao botao-secundario" id="btn-baixar-resposta">Baixar resposta em PDF</button>
      </div>
    </div>
  </section>

  <!-- ══════════════ ABA: RESUMIR ══════════════ -->
  <section class="painel escondido" id="painel-resumir" data-panel="resumir">
    <div class="cartao">
      <div class="cartao-aba">Resumo completo</div>
      <p class="cartao-intro">Gera um resumo de todo o conteúdo de um PDF indexado, explicando cada parte encontrada.</p>

      <div id="resumir-sem-banco" class="aviso oculto">Nenhum banco encontrado. Indexe PDFs primeiro.</div>

      <div id="resumir-form-wrap">
        <div class="form-grid form-grid-2col">
          <label class="campo">
            <span>Banco</span>
            <select id="select-banco-resumir"></select>
          </label>
          <label class="campo">
            <span>PDF para resumir</span>
            <select id="select-pdf-resumir"></select>
          </label>
        </div>

        <label class="campo">
          <span>Tipo de resumo</span>
          <select id="select-estilo-resumir"></select>
          <small id="descricao-estilo-resumir"></small>
        </label>

        <button class="botao botao-primario" id="btn-resumir">Gerar Resumo</button>
      </div>

      <div id="progresso-resumir" class="progresso oculto">
        <div class="progresso-arquivo">
          <span id="progresso-resumir-etapa">—</span>
          <span id="progresso-resumir-contador" class="mono"></span>
        </div>
        <div class="barra"><div class="barra-preenchimento" id="barra-resumir"></div></div>
      </div>

      <div id="resultado-resumir" class="resultado oculto">
        <h3 id="titulo-resultado-resumir">Resultado</h3>
        <p id="texto-resumo" class="texto-resposta"></p>
        <button class="botao botao-secundario" id="btn-baixar-resumo">Baixar resumo em PDF</button>
      </div>
    </div>
  </section>

  <!-- ══════════════ ABA: STATUS ══════════════ -->
  <section class="painel escondido" id="painel-status" data-panel="status">
    <div class="cartao">
      <div class="cartao-aba">Status dos bancos</div>

      <div id="status-bucket" class="bucket-tag"></div>

      <div id="status-vazio" class="aviso oculto">Nenhum banco encontrado.</div>
      <div id="lista-status"></div>

      <div class="botoes-status">
        <button class="botao botao-secundario" id="btn-atualizar-status">Atualizar</button>
        <button class="botao botao-secundario" id="btn-sincronizar-bucket">Sincronizar do dataset</button>
      </div>
    </div>
  </section>

</main>

<footer class="rodape">
  <span>RAG com PDFs &middot; FastAPI + HTML</span>
</footer>

<script src="/static/app.js"></script>
</body>
</html>
CLAUDE_EOF

mkdir -p "$(dirname "static/style.css")"
cat > 'static/style.css' << 'CLAUDE_EOF'
:root {
  --ink:        #1c2b39;
  --ink-soft:   #3d4f5c;
  --paper:      #edf0e7;
  --paper-card: #f8f9f4;
  --brass:      #b3852a;
  --brass-dark: #8f6a1f;
  --verdigris:  #3e6259;
  --coral:      #c1442d;
  --line:       #d7d9cd;
  --shadow:     rgba(28, 43, 57, 0.12);

  --serif: "Source Serif 4", Georgia, serif;
  --sans:  "Inter", -apple-system, BlinkMacSystemFont, sans-serif;
  --mono:  "IBM Plex Mono", "SF Mono", monospace;
}

* { box-sizing: border-box; }

body {
  margin: 0;
  background: var(--paper);
  background-image:
    linear-gradient(var(--line) 1px, transparent 1px);
  background-size: 100% 32px;
  color: var(--ink);
  font-family: var(--sans);
  -webkit-font-smoothing: antialiased;
}

/* ── cabeçalho ─────────────────────────────────────────── */
.topo {
  padding: 48px 24px 0;
  display: flex;
  justify-content: center;
}

.topo-plate {
  max-width: 780px;
  width: 100%;
  text-align: left;
  border-bottom: 3px solid var(--ink);
  padding-bottom: 20px;
}

.topo-eyebrow {
  font-family: var(--mono);
  font-size: 12px;
  letter-spacing: 0.14em;
  color: var(--brass-dark);
  display: block;
  margin-bottom: 10px;
}

.topo-plate h1 {
  font-family: var(--serif);
  font-weight: 600;
  font-size: 34px;
  margin: 0 0 8px;
  letter-spacing: -0.01em;
}

.topo-sub {
  margin: 0;
  color: var(--ink-soft);
  font-size: 14px;
}

/* ── navegação em fichas ───────────────────────────────── */
.fichario {
  max-width: 780px;
  margin: 0 auto;
  padding: 0 24px;
  display: flex;
  gap: 6px;
  position: relative;
  top: 1px;
}

.ficha {
  font-family: var(--sans);
  font-weight: 600;
  font-size: 14px;
  background: #dfe3d7;
  color: var(--ink-soft);
  border: 1px solid var(--ink);
  border-bottom: none;
  border-radius: 8px 8px 0 0;
  padding: 10px 18px 12px;
  cursor: pointer;
  display: flex;
  align-items: baseline;
  gap: 8px;
  transition: background 0.15s ease, color 0.15s ease;
}

.ficha-num {
  font-family: var(--mono);
  font-size: 11px;
  color: var(--brass-dark);
}

.ficha[aria-selected="true"] {
  background: var(--paper-card);
  color: var(--ink);
}

.ficha[aria-selected="true"] .ficha-num { color: var(--brass); }

.ficha:hover { background: #eaeee0; }
.ficha[aria-selected="true"]:hover { background: var(--paper-card); }

/* ── conteúdo / cartões ────────────────────────────────── */
.conteudo {
  max-width: 780px;
  margin: 0 auto;
  padding: 0 24px 64px;
}

.painel.escondido { display: none; }

.cartao {
  background: var(--paper-card);
  border: 1px solid var(--ink);
  border-radius: 0 8px 8px 8px;
  padding: 32px;
  box-shadow: 0 6px 0 var(--shadow);
  animation: surgir 0.25s ease;
}

@keyframes surgir {
  from { opacity: 0; transform: translateY(4px); }
  to   { opacity: 1; transform: translateY(0); }
}

.cartao-aba {
  font-family: var(--mono);
  font-size: 11px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--brass-dark);
  border-bottom: 1px dashed var(--line);
  padding-bottom: 12px;
  margin-bottom: 20px;
}

.cartao-intro {
  color: var(--ink-soft);
  font-size: 14px;
  margin-top: 0;
  margin-bottom: 24px;
}

/* ── formulários ───────────────────────────────────────── */
.form-grid {
  display: flex;
  flex-direction: column;
  gap: 18px;
}

.form-grid-2col {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 18px;
}

.campo-duplo {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
}

.campo {
  display: flex;
  flex-direction: column;
  gap: 6px;
  font-size: 13px;
  font-weight: 600;
  color: var(--ink);
}

.campo input[type="text"],
.campo textarea,
.campo select {
  font-family: var(--sans);
  font-weight: 400;
  font-size: 14px;
  padding: 10px 12px;
  border: 1px solid var(--line);
  border-radius: 5px;
  background: #fff;
  color: var(--ink);
}

.campo input[type="text"]:focus,
.campo textarea:focus,
.campo select:focus,
.campo input[type="range"]:focus-visible,
button:focus-visible {
  outline: 2px solid var(--verdigris);
  outline-offset: 1px;
}

.campo small {
  font-weight: 400;
  color: var(--ink-soft);
  font-size: 12px;
}

.campo input[type="file"] {
  font-size: 13px;
  font-family: var(--sans);
}

.campo-arquivo {
  border: 1px dashed var(--line);
  border-radius: 6px;
  padding: 14px;
  background: #fff;
}

/* ── botões ────────────────────────────────────────────── */
.botao {
  font-family: var(--sans);
  font-weight: 600;
  font-size: 14px;
  border-radius: 5px;
  padding: 11px 20px;
  cursor: pointer;
  border: 1px solid transparent;
  width: fit-content;
  transition: transform 0.1s ease, background 0.15s ease;
}

.botao:active { transform: translateY(1px); }

.botao-primario {
  background: var(--ink);
  color: #fff;
}
.botao-primario:hover { background: #142029; }
.botao-primario:disabled { background: #8a97a1; cursor: not-allowed; }

.botao-secundario {
  background: transparent;
  border-color: var(--ink);
  color: var(--ink);
  margin-top: 16px;
}
.botao-secundario:hover { background: var(--ink); color: #fff; }

/* ── progresso ─────────────────────────────────────────── */
.progresso { margin-top: 24px; }
.progresso.oculto { display: none; }

.progresso-arquivo {
  display: flex;
  justify-content: space-between;
  font-size: 13px;
  margin-bottom: 6px;
}

.mono { font-family: var(--mono); color: var(--ink-soft); }

.barra {
  height: 8px;
  background: #dfe3d7;
  border-radius: 4px;
  overflow: hidden;
  border: 1px solid var(--line);
}

.barra-preenchimento {
  height: 100%;
  width: 0%;
  background: var(--brass);
  transition: width 0.3s ease;
}

.log {
  list-style: none;
  margin: 16px 0 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 6px;
  font-size: 13px;
}

.log li {
  padding: 8px 12px;
  background: #fff;
  border: 1px solid var(--line);
  border-radius: 5px;
}

/* ── avisos / carregando ───────────────────────────────── */
.aviso {
  background: #fbf3e6;
  border: 1px solid var(--brass);
  color: var(--brass-dark);
  border-radius: 5px;
  padding: 12px 16px;
  font-size: 14px;
}
.aviso.oculto { display: none; }

.carregando {
  font-size: 14px;
  color: var(--ink-soft);
  margin-top: 20px;
  font-style: italic;
}
.carregando.oculto { display: none; }

.erro-msg {
  background: #faeae7;
  border: 1px solid var(--coral);
  color: var(--coral);
  border-radius: 5px;
  padding: 12px 16px;
  font-size: 14px;
  margin-top: 16px;
}

/* ── resultado ─────────────────────────────────────────── */
.resultado { margin-top: 28px; }
.resultado.oculto { display: none; }

.resultado h3 {
  font-family: var(--serif);
  font-size: 20px;
  margin: 0 0 12px;
  border-bottom: 1px dashed var(--line);
  padding-bottom: 10px;
}

.texto-resposta {
  white-space: pre-wrap;
  line-height: 1.6;
  font-size: 14.5px;
}

.trechos-detalhe {
  margin-top: 20px;
  border: 1px solid var(--line);
  border-radius: 6px;
  padding: 12px 16px;
  background: #fff;
}

.trechos-detalhe summary {
  cursor: pointer;
  font-weight: 600;
  font-size: 13px;
  color: var(--verdigris);
}

/* ── trecho: mini ficha de catálogo ────────────────────── */
.trecho-card {
  position: relative;
  margin-top: 14px;
  padding: 14px 14px 12px 18px;
  border: 1px solid var(--line);
  border-left: 4px solid var(--verdigris);
  border-radius: 4px;
  background: var(--paper-card);
}

.trecho-cabecalho {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  align-items: center;
  font-size: 12px;
  color: var(--ink-soft);
  margin-bottom: 8px;
}

.trecho-num {
  font-family: var(--mono);
  background: var(--ink);
  color: #fff;
  border-radius: 3px;
  padding: 1px 6px;
  font-size: 11px;
}

.trecho-tipo {
  font-family: var(--mono);
  color: var(--brass-dark);
}

.trecho-texto {
  font-size: 13.5px;
  line-height: 1.55;
  color: var(--ink);
}

/* ── status: fichas de banco ───────────────────────────── */
.banco-card {
  border: 1px solid var(--line);
  border-radius: 6px;
  margin-bottom: 14px;
  overflow: hidden;
}

.banco-cabecalho {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 14px 16px;
  background: #fff;
  cursor: pointer;
  font-weight: 600;
}

.banco-cabecalho .mono { font-size: 12px; }

.banco-pdfs {
  padding: 4px 16px 14px;
  font-size: 13.5px;
  color: var(--ink-soft);
  display: none;
}

.banco-card.aberto .banco-pdfs { display: block; }

.banco-pdfs div {
  padding: 4px 0;
  border-bottom: 1px dashed var(--line);
}
.banco-pdfs div:last-child { border-bottom: none; }

.banco-erro { color: var(--coral); }

/* ── bucket / storage ──────────────────────────────────── */
.bucket-tag {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  font-family: var(--mono);
  font-size: 12px;
  padding: 6px 12px;
  border-radius: 20px;
  margin-bottom: 18px;
}
.bucket-tag.ligado {
  background: #e9f3ee;
  color: var(--verdigris);
  border: 1px solid var(--verdigris);
}
.bucket-tag.desligado {
  background: #f4efe3;
  color: var(--brass-dark);
  border: 1px solid var(--brass);
}

.botoes-status {
  display: flex;
  gap: 12px;
  flex-wrap: wrap;
}
.botoes-status .botao { margin-top: 16px; }

/* ── rodapé ────────────────────────────────────────────── */
.rodape {
  text-align: center;
  font-size: 12px;
  color: var(--ink-soft);
  padding: 24px;
  font-family: var(--mono);
}

/* ── responsivo ────────────────────────────────────────── */
@media (max-width: 640px) {
  .form-grid-2col, .campo-duplo { grid-template-columns: 1fr; }
  .topo-plate h1 { font-size: 26px; }
  .cartao { padding: 22px; }
  .fichario { overflow-x: auto; }
  .ficha { padding: 8px 12px 10px; font-size: 13px; }
}

@media (prefers-reduced-motion: reduce) {
  .cartao { animation: none; }
  .botao, .ficha, .barra-preenchimento { transition: none; }
}
CLAUDE_EOF

mkdir -p "$(dirname ".github/workflows/deploy_hf.yml")"
cat > '.github/workflows/deploy_hf.yml' << 'CLAUDE_EOF'
name: Deploy para Hugging Face Spaces

on:
  push:
    branches:
      - main

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout do repositório
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          lfs: true

      - name: Instalar huggingface-hub
        run: pip install huggingface-hub

      - name: Deploy para Hugging Face Spaces
        env:
          HF_TOKEN: ${{ secrets.HF_TOKEN }}
          HF_SPACE: ${{ secrets.HF_SPACE }}
        run: |
          python - <<'EOF'
          import os
          from huggingface_hub import HfApi

          api      = HfApi(token=os.environ["HF_TOKEN"])
          space_id = os.environ["HF_SPACE"]  # ex: seu-usuario/rag-edital-pdf

          # Arquivos enviados para o Space
          # .env NAO e enviado — as chaves ficam nos Secrets do Space
          arquivos = [
              "main.py",
              "indexar.py",
              "perguntar.py",
              "gerar_pdf.py",
              "storage.py",
              "requirements.txt",
              "Dockerfile",
              "README.md",  # mesmo README do GitHub — tem o cabecalho YAML que o HF Space le
              "static/index.html",
              "static/style.css",
              "static/app.js",
          ]

          print(f"Fazendo deploy para: {space_id}")

          for arquivo in arquivos:
              if os.path.exists(arquivo):
                  api.upload_file(
                      path_or_fileobj=arquivo,
                      path_in_repo=arquivo,
                      repo_id=space_id,
                      repo_type="space",
                  )
                  print(f"✅ {arquivo}")
              else:
                  print(f"⚠️  {arquivo} não encontrado, pulando")

          print("🚀 Deploy concluído!")
          EOF
CLAUDE_EOF

echo "✅ Projeto criado com sucesso!"
echo ""
echo "Próximos passos:"
echo "  1. cp .env.example .env  # e edite com suas chaves"
echo "  2. pip install -r requirements.txt"
echo "  3. uvicorn main:app --reload --port 8000"
