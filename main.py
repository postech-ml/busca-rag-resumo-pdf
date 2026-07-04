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

from fastapi import FastAPI, UploadFile, File, Form, HTTPException, Request
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


@app.exception_handler(Exception)
async def _excecao_nao_tratada(request: Request, exc: Exception):
    # Sem isso, uma exceção fora dos try/except vira uma resposta 500 em
    # texto puro (não-JSON) — o frontend não consegue mostrar o motivo real.
    logger.exception("Erro não tratado em %s", request.url.path)
    return JSONResponse(status_code=500, content={"detail": str(exc)})


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

    try:
        colecao = get_colecao(req.banco)
        vazio   = colecao.count() == 0
    except Exception as e:
        raise HTTPException(500, f"Erro ao abrir o banco '{req.banco}': {e}")

    if vazio:
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