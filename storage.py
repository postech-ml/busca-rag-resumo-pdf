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
