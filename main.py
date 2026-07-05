"""
main.py — Backend FastAPI para RAG com PDFs
Substitui a interface Streamlit por uma API + frontend HTML puro.

Embeddings : Gemini gemini-embedding-2-preview (multimodal — texto + imagens)
LLM        : Gemini gemini-2.5-flash-lite (grátis, 1M de contexto, infraestrutura própria do Google)

Variável de ambiente necessária no .env:
    GEMINI_API_KEY=...
"""

import os
import re
import time
import uuid
import random
import logging
import threading
import collections
import concurrent.futures

from fastapi import FastAPI, UploadFile, File, Form, HTTPException, Request
from fastapi.responses import FileResponse, Response, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import chromadb
from google import genai
from google.genai import types
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
MODELO_LLM      = "gemini-2.5-flash-lite"  # grátis, 1M de contexto, infra própria do Google

_ERROS_429 = ("429", "rate_limit_exceeded", "rate limit", "too many requests", "resource_exhausted", "quota")
_ERROS_413 = ("413", "request too large", "request_too_large", "token limit", "context length", "context_length_exceeded")

BASE_DIR = os.path.dirname(os.path.abspath(__file__))


# ── inicialização dos clientes (uma vez, no startup) ───────────
def _inicializar():
    gemini_key = os.environ.get("GEMINI_API_KEY")

    if not gemini_key:
        raise RuntimeError("Chave não encontrada no .env: GEMINI_API_KEY")

    cliente_gemini = genai.Client(api_key=gemini_key)
    ranker         = Ranker()
    return cliente_gemini, ranker


cliente_gemini, ranker = _inicializar()

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

# Nº de chamadas simultâneas ao LLM durante o resumo. Mantido em 1 (sequencial):
# o gargalo real é a fila de baixa prioridade do modelo gratuito no backend,
# não o nosso lado — disparar chamadas em paralelo não acelera um backend
# que já está processando na capacidade dele, só faz elas competirem.
MAX_PARALELISMO_RESUMO = 1

# ── rastreamento e controle de requisições/minuto ao LLM ────────
LIMITE_REQUISICOES_MINUTO = 20  # tier gratuito real do Gemini (confirmado no erro da API)
MARGEM_SEGURANCA_REQUISICOES = 3  # deixa folga maior — testes/restarts recentes também contam
_req_lock = threading.Lock()
_req_timestamps: collections.deque = collections.deque()


def _aguardar_vaga_llm():
    """Bloqueia até haver uma vaga dentro do limite de requisições/minuto.
    Evita bater no 429 em vez de só reagir a ele — espera proativamente
    quando já estamos perto do teto do tier gratuito."""
    limite_seguro = max(1, LIMITE_REQUISICOES_MINUTO - MARGEM_SEGURANCA_REQUISICOES)
    while True:
        agora = time.time()
        with _req_lock:
            while _req_timestamps and agora - _req_timestamps[0] > 60:
                _req_timestamps.popleft()
            if len(_req_timestamps) < limite_seguro:
                _req_timestamps.append(agora)
                return
            espera = 60 - (agora - _req_timestamps[0]) + 0.5
        time.sleep(max(espera, 0.5))


def _contar_requisicoes_ultimo_minuto() -> int:
    agora = time.time()
    with _req_lock:
        while _req_timestamps and agora - _req_timestamps[0] > 60:
            _req_timestamps.popleft()
        return len(_req_timestamps)


# ── bloqueio global de cota (circuit breaker) ───────────────────
# Insistir em chamar a API enquanto a cota já está estourada parece
# CONTAR como mais uma requisição e prolongar o bloqueio (o tempo de
# espera sugerido pelo Gemini às vezes AUMENTA entre tentativas). Por
# isso, em vez de cada chamada tentar por conta própria, guardamos um
# horário global até quando o app inteiro deve evitar chamar o LLM.
_bloqueio_lock = threading.Lock()
_bloqueado_ate = 0.0


def _verificar_bloqueio_global():
    """Se alguma chamada recente já descobriu que a cota está estourada,
    espera até o horário conhecido de liberação antes de tentar de novo."""
    with _bloqueio_lock:
        ate = _bloqueado_ate
    agora = time.time()
    if agora < ate:
        time.sleep(ate - agora + 0.5)


def _registrar_bloqueio_global(segundos: float):
    global _bloqueado_ate
    with _bloqueio_lock:
        _bloqueado_ate = max(_bloqueado_ate, time.time() + segundos)


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


# ── geração de resposta via Gemini com backoff exponencial ─────
def gerar_resposta(prompt: str, max_tentativas: int = 6, max_tokens: int = 4096) -> str:
    espera_base = 5.0
    espera_max  = 90.0

    for tentativa in range(1, max_tentativas + 1):
        try:
            _verificar_bloqueio_global()
            _aguardar_vaga_llm()
            resposta = cliente_gemini.models.generate_content(
                model=MODELO_LLM,
                contents=prompt,
                config=types.GenerateContentConfig(
                    system_instruction=SYSTEM_PROMPT,
                    temperature=0.2,
                    max_output_tokens=max_tokens,
                ),
            )
            return resposta.text

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

            retry_after = None
            if hasattr(e, "response") and e.response is not None:
                retry_after = e.response.headers.get("retry-after")

            # O Gemini costuma informar o tempo exato de espera no corpo do
            # erro (ex: "Please retry in 30.98s"). Usar esse valor é mais
            # preciso do que nosso backoff estimado — e registramos esse
            # horário globalmente, pra nenhuma outra chamada insistir antes
            # da hora (insistir parece prolongar o próprio bloqueio).
            espera_sugerida_gemini = None
            match_retry = re.search(r"retry in ([\d.]+)\s*s", str(e), re.IGNORECASE)
            if match_retry:
                espera_sugerida_gemini = float(match_retry.group(1))

            if espera_sugerida_gemini is not None:
                espera = espera_sugerida_gemini + random.uniform(0.5, 2.0)
                _registrar_bloqueio_global(espera_sugerida_gemini)
            elif retry_after:
                espera = min(float(retry_after), 60.0) + random.uniform(0.5, 2.0)
                _registrar_bloqueio_global(float(retry_after))
            else:
                espera = min(espera_base * (2 ** (tentativa - 1)), espera_max)
                espera += random.uniform(-2.0, 2.0)
                espera = max(espera, 2.0)

            if tentativa == max_tentativas:
                raise RuntimeError(
                    f"Limite de {max_tentativas} tentativas no Gemini. Último erro: {e}"
                )

            logger.warning(
                "[gerar_resposta] 429 Gemini (tentativa %d/%d). Aguardando %.1fs... Detalhe: %s",
                tentativa, max_tentativas, espera, str(e)[:500],
            )
            time.sleep(espera)


# Anexada a todo prompt de resumo — mantém o mesmo padrão de formatação
# do Perguntar, pensado para facilitar a memorização ao estudar.
INSTRUCAO_FORMATO_MD = """

Formate a saida em Markdown pensando em facilitar a memorizacao:
- Use "## " para titulos de cada parte/secao.
- Coloque em **negrito** os termos e conceitos mais importantes.
- Prefira listas com marcadores a paragrafos longos, sempre que possivel."""


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
def _eh_erro_de_tamanho(e: Exception) -> bool:
    return "muito grande" in str(e).lower()


def _gerar_resumo_lote_seguro(pdf_sel: str, estilo: dict, chunks: list[str], profundidade: int = 0) -> str:
    """Gera o resumo de um lote de chunks. Se o prompt ficar grande demais,
    divide o lote ao meio e tenta cada metade recursivamente, em vez de
    gravar a mensagem de erro como se fosse conteúdo do resumo."""
    texto_lote = "\n\n---PARTE---\n\n".join(chunks)
    prompt     = estilo["prompt_lote"](pdf_sel, texto_lote) + INSTRUCAO_FORMATO_MD

    try:
        return gerar_resposta(prompt, max_tokens=8192)
    except Exception as e:
        if _eh_erro_de_tamanho(e) and len(chunks) > 1 and profundidade < 6:
            meio = len(chunks) // 2
            parte1 = _gerar_resumo_lote_seguro(pdf_sel, estilo, chunks[:meio], profundidade + 1)
            time.sleep(2)
            parte2 = _gerar_resumo_lote_seguro(pdf_sel, estilo, chunks[meio:], profundidade + 1)
            return parte1 + "\n\n" + parte2
        return f"[Erro no lote: {e}]"


def _consolidar_recursivo(pdf_sel: str, estilo: dict, textos: list[str], profundidade: int = 0) -> str:
    """Consolida uma lista de textos em um único texto final. Agrupa de 3 em 3
    e chama o LLM em paralelo; se um grupo ficar grande demais, subdivide ao
    meio em vez de gravar o erro como conteúdo. Repete até sobrar um único texto."""
    if len(textos) == 1:
        return textos[0]

    GRUPO  = 3
    grupos = [textos[g:g + GRUPO] for g in range(0, len(textos), GRUPO)]

    def _consolidar_grupo(grupo: list[str]) -> str:
        if len(grupo) == 1:
            return grupo[0]

        sub        = "\n\n===\n\n".join([f"Secao {i+1}:\n{r}" for i, r in enumerate(grupo)])
        prompt_sub = estilo["prompt_final"](pdf_sel, sub) + INSTRUCAO_FORMATO_MD

        try:
            return gerar_resposta(prompt_sub, max_tokens=3072)
        except Exception as e:
            if _eh_erro_de_tamanho(e) and profundidade < 6:
                meio   = len(grupo) // 2
                parte1 = _consolidar_recursivo(pdf_sel, estilo, grupo[:meio], profundidade + 1)
                parte2 = _consolidar_recursivo(pdf_sel, estilo, grupo[meio:], profundidade + 1)
                return parte1 + "\n\n" + parte2
            return f"[Erro ao consolidar grupo: {e}]"

    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_PARALELISMO_RESUMO) as executor:
        proximos = list(executor.map(_consolidar_grupo, grupos))

    return _consolidar_recursivo(pdf_sel, estilo, proximos, profundidade + 1)


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

        LOTE = 60
        lotes = [chunks[i:i + LOTE] for i in range(0, len(chunks), LOTE)]
        total_lotes = len(lotes)
        job["total_lotes"] = total_lotes
        job["etapa"] = "analisando"

        resumos_parciais = [None] * total_lotes
        concluidos = 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_PARALELISMO_RESUMO) as executor:
            futuros = {
                executor.submit(_gerar_resumo_lote_seguro, pdf_sel, estilo, lote): idx
                for idx, lote in enumerate(lotes)
            }
            for futuro in concurrent.futures.as_completed(futuros):
                idx = futuros[futuro]
                resumos_parciais[idx] = futuro.result()
                concluidos += 1
                job["lote_atual"] = concluidos

        if len(resumos_parciais) == 1:
            resumo_final = resumos_parciais[0]
        else:
            job["etapa"] = "consolidando"
            resumo_final = _consolidar_recursivo(pdf_sel, estilo, resumos_parciais)

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


@app.get("/api/llm/requisicoes")
async def api_llm_requisicoes():
    return {
        "ultimo_minuto": _contar_requisicoes_ultimo_minuto(),
        "limite_por_minuto": LIMITE_REQUISICOES_MINUTO,
    }


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