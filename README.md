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
