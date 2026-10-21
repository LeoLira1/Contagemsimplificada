/// Agrupamento de códigos que são o MESMO produto físico.
///
/// Um produto da CAMDA pode ter mais de um código ativo — tipicamente um
/// numérico e um com prefixo (`222534` e `US222534`, `237191` e `100237191`),
/// **cada um com sua própria linha de saldo em `estoque_mestre`**. Na
/// prateleira existe uma pilha só.
///
/// Sem agrupar, o conferente vê "11 un" num card, conta as 84 que estão na
/// gôndola e registra uma divergência de 73 unidades que não existe. O erro é
/// silencioso e vai direto para o estoque — daí este arquivo ser lógica pura,
/// testável linha a linha, e não uma consulta perdida no meio do serviço.
///
/// A regra de resolução é a mesma do app `scanner` (`estoque_service.dart`) e
/// do `db_mapa.py` do dashboard, com uma extensão: ver [chaveDeGrupo].
library;

/// Status de um item na lista de contagem — os mesmos três valores que o
/// dashboard grava em `contagem_itens.status`.
enum StatusContagem { pendente, certa, divergencia }

StatusContagem statusDe(String bruto) {
  switch (bruto.trim().toLowerCase()) {
    case 'certa':
      return StatusContagem.certa;
    case 'divergencia':
      return StatusContagem.divergencia;
    default:
      return StatusContagem.pendente;
  }
}

/// Uma linha crua de `contagem_itens`.
class LinhaContagem {
  final int id;
  final String codigo;
  final String produto;
  final String categoria;
  final int qtdEstoque;
  final StatusContagem status;
  final String motivo;
  final String observacoes;

  const LinhaContagem({
    required this.id,
    required this.codigo,
    required this.produto,
    required this.categoria,
    required this.qtdEstoque,
    required this.status,
    this.motivo = '',
    this.observacoes = '',
  });
}

/// Uma linha de `estoque_mestre` — o saldo por código.
class LinhaMestre {
  final String codigo;
  final String produto;
  final int qtdSistema;

  const LinhaMestre({
    required this.codigo,
    required this.produto,
    required this.qtdSistema,
  });
}

/// O mapa de produtos do dashboard (`mapa_produtos` +
/// `mapa_produtos_codigos`), quando existe. É a fonte autoritativa do
/// vínculo entre códigos.
class MapaProdutos {
  /// codigo normalizado → produto_id.
  final Map<String, String> produtoPorCodigo;

  /// produto_id → código principal (`mapa_produtos.codigo`).
  final Map<String, String> principalPorProduto;

  const MapaProdutos({
    this.produtoPorCodigo = const {},
    this.principalPorProduto = const {},
  });

  static const MapaProdutos vazio = MapaProdutos();

  bool get disponivel => produtoPorCodigo.isNotEmpty;
}

/// Um código que compõe o total de um item, com o saldo que ele contribui.
class CodigoDoGrupo {
  final String codigo;
  final int quantidade;

  /// True quando este código tem linha própria em `contagem_itens` — ou
  /// seja, o dashboard pediu para conferi-lo.
  final bool naLista;

  const CodigoDoGrupo({
    required this.codigo,
    required this.quantidade,
    required this.naLista,
  });
}

/// Normaliza um código para a forma canônica: UPPER(TRIM()). Mesma regra do
/// `_norm_codigo` do dashboard e do `normalizarCodigo` do scanner.
String normalizarCodigo(String codigo) => codigo.trim().toUpperCase();

const _comAcento = 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑáàâãäéèêëíìîïóòôõöúùûüçñ';
const _semAcento = 'AAAAAEEEEIIIIOOOOOUUUUCNAAAAAEEEEIIIIOOOOOUUUUCN';

/// Nome em maiúsculo, sem acento e com espaços colapsados — a forma em que
/// nomes de produto são comparados. Mesma `chaveBusca` do scanner.
String chaveNome(String texto) {
  final buffer = StringBuffer();
  for (final c in texto.trim().toUpperCase().split('')) {
    final i = _comAcento.indexOf(c);
    buffer.write(i >= 0 ? _semAcento[i] : c);
  }
  return buffer
      .toString()
      .replaceAll(RegExp('[̀-ͯ]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Chave que decide quais códigos são o mesmo produto, em três degraus:
///
/// 1. **`mapa_produtos`** — o vínculo explícito cadastrado no dashboard.
///    Autoritativo: `mapa_produtos_codigos.codigo` tem índice UNIQUE, então
///    um código pertence a um produto só.
/// 2. **Nome do produto** — quando o código não está no mapa. O scanner usa
///    aqui a convenção `US` (`254185` ↔ `US254185`), que NÃO cobre o prefixo
///    `100` do Ultimato (`237191` ↔ `100237191`). Agrupar por nome cobre
///    qualquer prefixo, presente ou futuro, sem adivinhar aritmética de
///    string — e `mapa_produtos.nome` é UNIQUE no dashboard, então nome
///    igual significa produto igual.
/// 3. **O próprio código** — produto sem nome legível: fica sozinho, que é o
///    comportamento seguro.
String chaveDeGrupo({
  required String codigo,
  required String nome,
  required MapaProdutos mapa,
}) {
  final cod = normalizarCodigo(codigo);
  final produtoId = mapa.produtoPorCodigo[cod];
  if (produtoId != null && produtoId.isNotEmpty) return 'mapa:$produtoId';

  final chave = chaveNome(nome);
  if (chave.isNotEmpty) return 'nome:$chave';

  return 'codigo:$cod';
}

/// Um item da lista de contagem, já com todos os códigos do mesmo produto
/// somados. É o que vira um card na tela.
class ItemAgrupado {
  /// Ids de `contagem_itens` que este card representa. Confirmar o card
  /// resolve TODOS eles — senão o código irmão ficaria pendente para sempre,
  /// pedindo uma segunda contagem da mesma pilha.
  final List<int> ids;

  /// Código que recebe o lançamento de divergência (ver [ItemAgrupado.ancora]).
  final String codigoAncora;

  final String produto;
  final String categoria;

  /// Soma dos saldos de todos os códigos do produto.
  final int qtdEstoque;

  final StatusContagem status;
  final String motivo;
  final String observacoes;

  /// Os códigos que compõem o total, em ordem estável.
  final List<CodigoDoGrupo> codigos;

  /// False quando o grupo foi montado por nome, sem respaldo do
  /// `mapa_produtos`. O total pode estar incompleto — mesma ressalva que o
  /// scanner mostra —, e a tela avisa.
  final bool vinculadoNoMapa;

  const ItemAgrupado({
    required this.ids,
    required this.codigoAncora,
    required this.produto,
    required this.categoria,
    required this.qtdEstoque,
    required this.status,
    required this.codigos,
    required this.vinculadoNoMapa,
    this.motivo = '',
    this.observacoes = '',
  });

  bool get temVariosCodigos => codigos.length > 1;

  /// Códigos que têm linha em `contagem_itens` — os que o dashboard pediu.
  List<String> get codigosNaLista =>
      [for (final c in codigos) if (c.naLista) c.codigo];
}

/// Junta as linhas de `contagem_itens` em cards por produto, somando os
/// saldos dos códigos irmãos.
///
/// [linhas] são as linhas da contagem; [mestre] é `estoque_mestre` inteiro
/// (é ele que traz os códigos irmãos que NÃO estão na lista de contagem — o
/// caso do PHOSFIX, em que só `222534` foi pedido e `US222534` carrega 73 das
/// 84 unidades); [mapa] é o vínculo explícito, quando o banco o tiver.
///
/// O saldo de cada código é o `qtd_sistema` ATUAL do `estoque_mestre` — o
/// mesmo número que o scanner mostra. O `qtd_estoque` de `contagem_itens` é
/// só uma foto de quando o item entrou na lista: uploads posteriores (Parcial
/// Estoque, vendas de outro horário, entradas detectadas depois) atualizam o
/// mestre mas nem sempre a foto, e o card mostraria um saldo que já mudou —
/// o conferente lançaria uma falta ou sobra que não existe. O trigger
/// `trig_contagem_to_cicli` do dashboard já compara com o mestre pelo mesmo
/// motivo. A foto só é usada quando o código não tem linha no mestre
/// (produto novo, ou zerado e removido).
List<ItemAgrupado> agruparItens({
  required List<LinhaContagem> linhas,
  required List<LinhaMestre> mestre,
  MapaProdutos mapa = MapaProdutos.vazio,
}) {
  // Índice do estoque mestre por código e por chave de grupo.
  final mestrePorCodigo = <String, LinhaMestre>{};
  final mestrePorGrupo = <String, List<LinhaMestre>>{};
  for (final m in mestre) {
    final cod = normalizarCodigo(m.codigo);
    if (cod.isEmpty) continue;
    mestrePorCodigo[cod] = m;
    final chave =
        chaveDeGrupo(codigo: cod, nome: m.produto, mapa: mapa);
    mestrePorGrupo.putIfAbsent(chave, () => []).add(m);
  }

  // Agrupa as linhas da contagem, preservando a ordem de chegada (o SELECT
  // já vem ordenado por categoria e produto).
  final ordem = <String>[];
  final porGrupo = <String, List<LinhaContagem>>{};
  for (final linha in linhas) {
    final cod = normalizarCodigo(linha.codigo);
    // O nome do estoque_mestre é preferido ao da contagem: é o mesmo campo
    // que dá nome aos irmãos, então casa a chave de grupo dos dois lados.
    final nome = mestrePorCodigo[cod]?.produto ?? linha.produto;
    final chave = chaveDeGrupo(codigo: cod, nome: nome, mapa: mapa);
    if (!porGrupo.containsKey(chave)) ordem.add(chave);
    porGrupo.putIfAbsent(chave, () => []).add(linha);
  }

  final itens = <ItemAgrupado>[];
  for (final chave in ordem) {
    final doGrupo = porGrupo[chave]!;
    final naLista = {
      for (final l in doGrupo) normalizarCodigo(l.codigo): l,
    };

    // Todos os códigos do produto: os da lista mais os irmãos que só existem
    // no estoque_mestre.
    final codigos = <CodigoDoGrupo>[];
    for (final entrada in naLista.entries) {
      codigos.add(CodigoDoGrupo(
        codigo: entrada.key,
        quantidade: mestrePorCodigo[entrada.key]?.qtdSistema ??
            entrada.value.qtdEstoque,
        naLista: true,
      ));
    }
    for (final m in mestrePorGrupo[chave] ?? const <LinhaMestre>[]) {
      final cod = normalizarCodigo(m.codigo);
      if (naLista.containsKey(cod)) continue;
      codigos.add(CodigoDoGrupo(
        codigo: cod,
        quantidade: m.qtdSistema,
        naLista: false,
      ));
    }
    // Ordem estável e previsível: primeiro os que o dashboard pediu, depois
    // os irmãos, cada bloco em ordem alfabética.
    codigos.sort((a, b) {
      if (a.naLista != b.naLista) return a.naLista ? -1 : 1;
      return a.codigo.compareTo(b.codigo);
    });

    final total = codigos.fold<int>(0, (soma, c) => soma + c.quantidade);
    final primeira = doGrupo.first;

    itens.add(ItemAgrupado(
      ids: [for (final l in doGrupo) l.id],
      codigoAncora: _ancora(chave, codigos, mapa),
      produto: mestrePorCodigo[normalizarCodigo(primeira.codigo)]?.produto
              .trim()
              .isNotEmpty ==
              true
          ? mestrePorCodigo[normalizarCodigo(primeira.codigo)]!.produto.trim()
          : primeira.produto,
      categoria: primeira.categoria,
      qtdEstoque: total,
      status: _statusDoGrupo(doGrupo),
      motivo: doGrupo.map((l) => l.motivo).firstWhere(
            (m) => m.trim().isNotEmpty,
            orElse: () => '',
          ),
      observacoes: doGrupo.map((l) => l.observacoes).firstWhere(
            (o) => o.trim().isNotEmpty,
            orElse: () => '',
          ),
      codigos: codigos,
      vinculadoNoMapa: chave.startsWith('mapa:'),
    ));
  }
  return itens;
}

/// Código que recebe o lançamento da divergência.
///
/// A divergência é do PRODUTO — a pilha na prateleira não distingue código —,
/// mas `estoque_mestre` e `divergencias` são por código, então é preciso
/// escolher um. A ordem é: o principal do `mapa_produtos`, senão o de maior
/// saldo (a linha que de fato carrega o estoque), senão o primeiro da lista.
String _ancora(String chave, List<CodigoDoGrupo> codigos, MapaProdutos mapa) {
  if (chave.startsWith('mapa:')) {
    final produtoId = chave.substring(5);
    final principal = mapa.principalPorProduto[produtoId];
    if (principal != null && principal.trim().isNotEmpty) {
      final norm = normalizarCodigo(principal);
      if (codigos.any((c) => c.codigo == norm)) return norm;
    }
  }
  if (codigos.isEmpty) return '';
  var maior = codigos.first;
  for (final c in codigos) {
    if (c.quantidade > maior.quantidade) maior = c;
  }
  return maior.codigo;
}

/// Status do card quando as linhas do grupo discordam.
///
/// Basta uma linha pendente para o card continuar pendente: a pilha ainda
/// não foi conferida por inteiro. Entre as já resolvidas, divergência manda
/// sobre certa — é a que exige atenção.
StatusContagem _statusDoGrupo(List<LinhaContagem> linhas) {
  if (linhas.any((l) => l.status == StatusContagem.pendente)) {
    return StatusContagem.pendente;
  }
  if (linhas.any((l) => l.status == StatusContagem.divergencia)) {
    return StatusContagem.divergencia;
  }
  return StatusContagem.certa;
}
