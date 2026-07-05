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
function renderizarMarkdown(texto, elemento) {
  const html = marked.parse(texto ?? "", { breaks: true });
  elemento.innerHTML = DOMPurify.sanitize(html);
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

    textoResposta.classList.add("markdown-corpo");
    renderizarMarkdown(resultado.resposta, textoResposta);

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

const coberturaPdf = document.getElementById("cobertura-pdf");
const coberturaPdfResultado = document.getElementById("cobertura-pdf-resultado");

function renderizarCobertura(dados, elemento) {
  const { total_paginas, paginas_cobertas, paginas_faltando } = dados;

  if (total_paginas === null || total_paginas === undefined) {
    elemento.className = "cobertura-pdf desconhecido";
    elemento.textContent = `ℹ️ Este PDF foi indexado antes da checagem de cobertura existir — não é possível confirmar se todas as páginas foram capturadas.`;
  } else if (!paginas_faltando || paginas_faltando.length === 0) {
    elemento.className = "cobertura-pdf ok";
    elemento.textContent = `✅ Todas as ${total_paginas} páginas do PDF têm conteúdo indexado.`;
  } else {
    elemento.className = "cobertura-pdf aviso";
    const listaFaltando = paginas_faltando.length > 12
      ? paginas_faltando.slice(0, 12).join(", ") + `... (+${paginas_faltando.length - 12})`
      : paginas_faltando.join(", ");
    elemento.textContent = `⚠️ ${paginas_cobertas}/${total_paginas} páginas cobertas. Faltando: ${listaFaltando}. Considere reindexar este PDF.`;
  }
  elemento.classList.remove("oculto");
}

async function verificarCobertura(banco, pdf, elemento) {
  if (!banco || !pdf) { elemento.classList.add("oculto"); return; }
  try {
    const dados = await apiGet(`/api/bancos/${encodeURIComponent(banco)}/pdfs/${encodeURIComponent(pdf)}/cobertura`);
    renderizarCobertura(dados, elemento);
  } catch (e) {
    elemento.classList.add("oculto");
  }
}

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
    await verificarCobertura(banco, selectPdfResumir.value, coberturaPdf);
  } catch (e) {
    alert("Erro ao carregar PDFs: " + e.message);
  }
}

selectPdfResumir.addEventListener("change", () => {
  verificarCobertura(selectBancoResumir.value, selectPdfResumir.value, coberturaPdf);
});

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
        await verificarCobertura(banco, pdf, coberturaPdfResultado);
        textoResumo.classList.add("markdown-corpo");
        renderizarMarkdown(job.resumo_final, textoResumo);
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
        <div class="banco-card" data-idx="${i}" data-banco="${escapeHtml(b.banco)}">
          <div class="banco-cabecalho">
            <span>🗄️ ${escapeHtml(b.banco)}</span>
            <span class="banco-cabecalho-acoes">
              <span class="mono">${b.chunks} itens · ${b.pdfs.length} PDF(s)</span>
              <button class="botao-excluir-banco" title="Excluir banco inteiro" data-banco="${escapeHtml(b.banco)}">🗑️</button>
            </span>
          </div>
          <div class="banco-pdfs">
            ${b.pdfs.map((p) => `
              <div class="pdf-linha">
                <span>${escapeHtml(p)}</span>
                <button class="botao-excluir-pdf" title="Excluir este PDF" data-banco="${escapeHtml(b.banco)}" data-pdf="${escapeHtml(p)}">🗑️</button>
              </div>
            `).join("") || "<div>Nenhum PDF.</div>"}
          </div>
        </div>
      `;
    }).join("");

    listaStatus.querySelectorAll(".banco-cabecalho").forEach((cab) => {
      cab.addEventListener("click", (ev) => {
        if (ev.target.closest(".botao-excluir-banco")) return;
        cab.closest(".banco-card").classList.toggle("aberto");
      });
    });

    listaStatus.querySelectorAll(".botao-excluir-banco").forEach((btn) => {
      btn.addEventListener("click", async (ev) => {
        ev.stopPropagation();
        const banco = btn.dataset.banco;
        if (!confirm(`Excluir o banco inteiro "${banco}"? Isso apaga todos os PDFs indexados nele, sem volta.`)) return;
        btn.disabled = true;
        try {
          const r = await fetch(`/api/bancos/${encodeURIComponent(banco)}`, { method: "DELETE" });
          if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || `Erro ${r.status}`);
          bancosPerguntarCarregados = false;
          bancosResumirCarregados = false;
          await carregarStatus();
        } catch (e) {
          alert("Erro ao excluir banco: " + e.message);
          btn.disabled = false;
        }
      });
    });

    listaStatus.querySelectorAll(".botao-excluir-pdf").forEach((btn) => {
      btn.addEventListener("click", async (ev) => {
        ev.stopPropagation();
        const banco = btn.dataset.banco;
        const pdf = btn.dataset.pdf;
        if (!confirm(`Excluir o PDF "${pdf}" do banco "${banco}"? Sem volta.`)) return;
        btn.disabled = true;
        try {
          const r = await fetch(`/api/bancos/${encodeURIComponent(banco)}/pdfs/${encodeURIComponent(pdf)}`, { method: "DELETE" });
          if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || `Erro ${r.status}`);
          await carregarStatus();
        } catch (e) {
          alert("Erro ao excluir PDF: " + e.message);
          btn.disabled = false;
        }
      });
    });
  } catch (e) {
    alert("Erro ao carregar status: " + e.message);
  }
}

// carrega o status já na primeira visita, para a aba inicial ficar coerente
carregarStatus();

// ══════════════════════════════════════════════════════════
// CONTADOR DE REQUISIÇÕES/MINUTO (visível em qualquer aba)
// ══════════════════════════════════════════════════════════
const contadorReq = document.getElementById("contador-requisicoes");
const contadorReqValor = document.getElementById("contador-req-valor");
const contadorReqLimite = document.getElementById("contador-req-limite");

async function atualizarContadorRequisicoes() {
  try {
    const { ultimo_minuto, limite_por_minuto } = await apiGet("/api/llm/requisicoes");
    contadorReqValor.textContent = ultimo_minuto;
    contadorReqLimite.textContent = limite_por_minuto;

    const proporcao = ultimo_minuto / limite_por_minuto;
    contadorReq.classList.toggle("aviso", proporcao >= 0.6 && proporcao < 0.9);
    contadorReq.classList.toggle("critico", proporcao >= 0.9);
  } catch (e) {
    // silencioso — não interrompe o uso do app por causa do contador
  }
}

atualizarContadorRequisicoes();
setInterval(atualizarContadorRequisicoes, 3000);