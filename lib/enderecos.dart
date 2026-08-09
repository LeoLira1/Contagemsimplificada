/// Endereçamento físico da loja — rótulos de gôndola, estante, expositor e
/// palete.
///
/// Este arquivo é um PORTE do esquema de endereços do app Gôndolas
/// (`leolira1/Gondolas`, `lib/models.dart`). O app de contagem só precisa
/// LER endereços e escrevê-los na tela; toda a parte de geometria 3D, cores
/// e desenho ficou de fora. As constantes e a lógica de rotulagem, porém,
/// precisam bater EXATAMENTE com as do Gôndolas — os dois leem as mesmas
/// linhas de `estoque_localizado` / `estante_layout` / `gondola_layout`, e
/// uma divergência aqui mandaria o conferente para a prateleira errada.
///
/// Ao mexer em qualquer constante deste arquivo, confira o original antes.
library;

import 'dart:math' as math;

// ─────────────────────────────────────────────────────────────────────────────
// Gôndolas
// ─────────────────────────────────────────────────────────────────────────────

/// Face 1-6 da gôndola derivada da posição (px, pz) da caixa na prateleira.
/// Face 1 = voltada para a entrada (+Z), numeração horária vista de cima.
/// A face não é persistida no Turso — é sempre derivada de pos_x/pos_z.
int faceFromPos(double px, double pz) {
  final ang = math.atan2(pz, px) * 180 / math.pi; // graus
  var k = (((90 - ang) / 60).round()) % 6;
  if (k < 0) k += 6;
  return k + 1;
}

/// Nome dos três andares de uma gôndola, de baixo para cima.
const List<String> andarNomes = ['Base', 'Meio', 'Topo'];

// ─────────────────────────────────────────────────────────────────────────────
// Estantes, expositores e paletes
// ─────────────────────────────────────────────────────────────────────────────

const int numColunasEstante = 3;
const int niveisProdutoPadrao = 4;
const int niveisProdutoEstendido = 5;
const Set<int> estantesComLabelEstendido = {3, 4};

// Estante 8: EDR-300 de aço, coluna única, 6 prateleiras.
const int estanteEdr300Num = 8;
const int niveisProdutoEdr300 = 6;

// Estante 6: 3 EDR-300 lado a lado — uma estante só, 3 módulos.
const int estanteEdr300TriplaNum = 6;
const int colunasEdr300Tripla = 3;

bool ehEstanteEdr300(int estanteNum) =>
    estanteNum == estanteEdr300Num || estanteNum == estanteEdr300TriplaNum;

// Expositor MagnoJet: painel canaletado com ganchos.
const int expositorMagnojetNum = 9;
const int colunasExpositorMagnojet = 4;
const int linhasExpositorMagnojet = 6;
const int colunasIntercaladasMagnojet = colunasExpositorMagnojet - 1; // 3
const int colunasTotalMagnojet =
    colunasExpositorMagnojet + colunasIntercaladasMagnojet; // 7
const int nivelBaseMagnojet = linhasExpositorMagnojet;
const int colunasBaseMagnojet = 5;

// Expositor Nellore Isoflex/Avant: painel slatwall.
const int expositorNelloreNum = 19;
const int colunasExpositorNellore = 5;
const int niveisExpositorNellore = 6;

/// Colunas de cada nível do Expositor Nellore: base e cestos têm 4,
/// ganchos e prateleiras têm 5.
int colunasNivelNellore(int nivel) => (nivel == 0 || nivel == 3) ? 4 : 5;

// Expositor Monitor Produtos Agropecuários: escalonado, 4 níveis × 5 colunas.
const int expositorMonitorNum = 20;
const int colunasExpositorMonitor = 5;
const int niveisExpositorMonitor = 4;

// Estante Parede: peça única dividida em 6 seções (13 a 18).
const int estanteParedeMin = 13;
const int estanteParedeMax = 18;
const int niveisProdutoParede = 6;
const int colunasParede = 2;

bool ehEstanteParede(int estanteNum) =>
    estanteNum >= estanteParedeMin && estanteNum <= estanteParedeMax;

// Paletes de madeira do piso — números a partir de 101, nunca reciclados.
const int paleteNumMin = 101;
const int colunasPalete = 5;
const int fileirasPalete = 3;

bool ehPalete(int estanteNum) => estanteNum >= paleteNumMin;

/// Estantes que saíram da loja (substituídas pela Estante Parede). As linhas
/// antigas continuam no Turso, mas o produto deve ser recadastrado na parede —
/// mandar o conferente até elas seria mandá-lo a um lugar que não existe mais.
const Set<int> estantesRemovidas = {3, 4};

bool temNivelTopoPara(int estanteNum) =>
    estantesComLabelEstendido.contains(estanteNum);

int niveisProdutoPara(int estanteNum) {
  if (ehPalete(estanteNum)) return fileirasPalete;
  return ehEstanteEdr300(estanteNum)
      ? niveisProdutoEdr300
      : estanteNum == expositorMagnojetNum
          ? linhasExpositorMagnojet + 1 // ganchos (0–5) + base (6)
          : estanteNum == expositorNelloreNum
              ? niveisExpositorNellore
              : estanteNum == expositorMonitorNum
                  ? niveisExpositorMonitor
                  : ehEstanteParede(estanteNum)
                      ? niveisProdutoParede
                      : temNivelTopoPara(estanteNum)
                          ? niveisProdutoEstendido
                          : niveisProdutoPadrao;
}

int numColunasPara(int estanteNum) {
  if (ehPalete(estanteNum)) return colunasPalete;
  return estanteNum == estanteEdr300Num
      ? 1
      : estanteNum == estanteEdr300TriplaNum
          ? colunasEdr300Tripla
          : estanteNum == expositorMagnojetNum
              ? colunasTotalMagnojet
              : estanteNum == expositorNelloreNum
                  ? colunasExpositorNellore
                  : estanteNum == expositorMonitorNum
                      ? colunasExpositorMonitor
                      : ehEstanteParede(estanteNum)
                          ? colunasParede
                          : numColunasEstante;
}

/// Offset (0-based) somado ao índice local antes de virar letra. Só a
/// Estante 4 precisa, para continuar a sequência da Estante 3.
int letraOffsetPara(int estanteNum) =>
    estanteNum == 4 ? niveisProdutoPara(3) * numColunasEstante : 0;

/// Converte um índice 0-based em rótulo estilo planilha: A, B, ..., Z, AA, AB…
String letraDoIndice(int index) {
  var n = index + 1;
  var s = '';
  while (n > 0) {
    n--;
    s = String.fromCharCode(0x41 + n % 26) + s;
    n ~/= 26;
  }
  return s;
}

/// Letra (ou número) da posição de uma célula (coluna, nível) — a mesma que
/// está etiquetada fisicamente na prateleira. É o "NÚMERO NA ESTANTE" que o
/// conferente procura com o olho.
String letraEstanteCelula(int estanteNum, int coluna, int nivel) {
  // Palete: grade HORIZONTAL, 1–5 na frente, 6–10 no meio, 11–15 no fundo.
  if (ehPalete(estanteNum)) {
    return '${nivel * colunasPalete + coluna + 1}';
  }
  final nNiveis = niveisProdutoPara(estanteNum);
  // Estante Parede: números contínuos 1..72, de cima pra baixo por coluna.
  if (ehEstanteParede(estanteNum)) {
    final numero = (estanteNum - estanteParedeMin) * nNiveis * colunasParede +
        coluna * nNiveis +
        (nNiveis - 1 - nivel) +
        1;
    return '$numero';
  }
  // Estante 6: cada coluna é um módulo EDR-300 — A–F, G–L, M–R.
  if (estanteNum == estanteEdr300TriplaNum) {
    return letraDoIndice(coluna * nNiveis + (nNiveis - 1 - nivel));
  }
  // Nellore: níveis 1–5 com nº de colunas variável; nível 0 (base) numérico.
  if (estanteNum == expositorNelloreNum) {
    if (nivel == 0) return '${coluna + 1}';
    var offset = 0;
    for (var n = niveisExpositorNellore - 1; n > nivel; n--) {
      offset += colunasNivelNellore(n);
    }
    return letraDoIndice(offset + coluna);
  }
  // Monitor: base (nível 0) 1–5; prateleiras A–E, F–J, K–O.
  if (estanteNum == expositorMonitorNum) {
    if (nivel == 0) return '${coluna + 1}';
    final row = niveisExpositorMonitor - 1 - nivel;
    return letraDoIndice(row * colunasExpositorMonitor + coluna);
  }
  // MagnoJet: base numérica; ganchos primários A–X; intercalados A1, B1…
  if (estanteNum == expositorMagnojetNum) {
    if (nivel == nivelBaseMagnojet) return '${coluna + 1}';
    final row = linhasExpositorMagnojet - 1 - nivel;
    if (coluna < colunasExpositorMagnojet) {
      return letraDoIndice(row * colunasExpositorMagnojet + coluna);
    }
    final primariaVizinha = coluna - colunasExpositorMagnojet;
    return '${letraDoIndice(row * colunasExpositorMagnojet + primariaVizinha)}1';
  }
  final nColunas = numColunasPara(estanteNum);
  final offset =
      estanteNum == estanteEdr300Num ? 0 : letraOffsetPara(estanteNum);
  final row = nNiveis - 1 - nivel;
  return letraDoIndice(offset + row * nColunas + coluna);
}

// ─────────────────────────────────────────────────────────────────────────────
// Rótulos prontos para a tela
// ─────────────────────────────────────────────────────────────────────────────

/// Rótulo curto etiquetado na loja: "G7", "E5", "P101".
String rotuloCurtoEstrutura(String tipo, int numero) => tipo == 'gondola'
    ? 'G$numero'
    : ehPalete(numero)
        ? 'P$numero'
        : 'E$numero';

/// Nome por extenso da estrutura. Os três expositores têm nome próprio na
/// loja — quem confere procura "o painel da MagnoJet", não "a estante 9".
String nomeEstrutura(String tipo, int numero) {
  if (tipo == 'gondola') return 'Gôndola $numero';
  if (ehPalete(numero)) return 'Palete $numero';
  if (numero == expositorMagnojetNum) return 'Expositor MagnoJet';
  if (numero == expositorNelloreNum) return 'Expositor Nellore';
  if (numero == expositorMonitorNum) return 'Expositor Monitor';
  if (ehEstanteParede(numero)) return 'Estante Parede $numero';
  return 'Estante $numero';
}

/// Um endereço físico de um produto, já pronto para virar as duas linhas do
/// meio do card ("ESTANTE OU GÔNDOLA" / "NÚMERO NA ESTANTE").
class EnderecoProduto {
  final String produtoCodigo;
  final String localTipo; // 'gondola' | 'estante'
  final int localNum;
  final int faceOuColuna; // gôndola: face 1-6 | estante: coluna
  final int andarOuNivel; // gôndola: andar 0-2 | estante: nível

  /// Quantidade registrada neste endereço, quando existe linha em
  /// `estoque_localizado`. Null quando o endereço veio só do layout — o
  /// produto está cadastrado ali, mas ninguém contou a posição ainda.
  final double? quantidade;

  const EnderecoProduto({
    required this.produtoCodigo,
    required this.localTipo,
    required this.localNum,
    required this.faceOuColuna,
    required this.andarOuNivel,
    this.quantidade,
  });

  bool get ehGondola => localTipo == 'gondola';

  /// Chave do endereço lógico — usada para deduplicar as três fontes
  /// (estoque_localizado, gondola_layout, estante_layout), que descrevem os
  /// mesmos lugares por caminhos diferentes.
  String get chave =>
      '$produtoCodigo|$localTipo|$localNum|$faceOuColuna|$andarOuNivel';

  /// Endereço que saiu da loja: continua no banco, mas não existe mais no
  /// chão. Sinalizado na tela em vez de escondido, para o conferente saber
  /// que o cadastro daquele produto está velho.
  bool get removido =>
      !ehGondola && estantesRemovidas.contains(localNum);

  /// Linha 1 do endereço: "Gôndola 7", "Estante Parede 15", "Palete 102".
  String get estrutura => nomeEstrutura(localTipo, localNum);

  /// Linha 2 do endereço: a posição etiquetada na prateleira.
  /// Gôndola: "Face 3 · Andar Meio". Estante: "Posição H".
  String get posicao {
    if (ehGondola) {
      final andar = andarOuNivel.clamp(0, 2);
      return 'Face $faceOuColuna · Andar ${andarNomes[andar]}';
    }
    return 'Posição ${letraEstanteCelula(localNum, faceOuColuna, andarOuNivel)}';
  }

  /// Forma compacta usada nas listas densas: "G7·F3·A2", "E5·H".
  String get compacto => ehGondola
      ? '${rotuloCurtoEstrutura(localTipo, localNum)}·F$faceOuColuna·A${andarOuNivel + 1}'
      : '${rotuloCurtoEstrutura(localTipo, localNum)}·'
          '${letraEstanteCelula(localNum, faceOuColuna, andarOuNivel)}';
}
