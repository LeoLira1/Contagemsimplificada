import 'package:libsql_dart/libsql_dart.dart';

import 'agrupamento.dart';
import 'enderecos.dart';
import 'turso_service.dart';

export 'agrupamento.dart'
    show StatusContagem, CodigoDoGrupo, MapaProdutos, normalizarCodigo;

// ─────────────────────────────────────────────────────────────────────────────
// Conversores tolerantes
// ─────────────────────────────────────────────────────────────────────────────
// O libsql devolve INTEGER como int e REAL como double, mas colunas do banco
// da CAMDA foram criadas por três clientes diferentes ao longo do tempo
// (Streamlit, Flutter, importações) e algumas guardam número em coluna TEXT.
// Ler tudo por estes três helpers evita um cast estourando a tela inteira por
// causa de uma linha malformada.

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v.trim()) ?? 0;
  return 0;
}

double _asDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim().replaceAll(',', '.')) ?? 0;
  return 0;
}

String _asString(Object? v) => v == null ? '' : v.toString();

/// Uma divergência já aberta para o produto (tabela `divergencias`), mostrada
/// antes de registrar uma nova. Sem isso o conferente registra a mesma falta
/// duas vezes e o saldo do cooperado dobra.
class DivergenciaAberta {
  final String cooperado;
  final int delta; // negativo = falta, positivo = sobra
  final String status; // 'falta' | 'sobra'

  const DivergenciaAberta({
    required this.cooperado,
    required this.delta,
    required this.status,
  });

  String get descricao {
    final quem = cooperado.trim().isEmpty ? 'sem cooperado' : cooperado.trim();
    final tipo = status == 'sobra' ? 'sobra' : 'falta';
    return '$quem — ${delta.abs()} un ($tipo)';
  }
}

/// Um item da lista de contagem: um PRODUTO físico, com todos os seus códigos
/// somados (ver `agrupamento.dart`) e cruzado com as posições da loja.
class ItemContagem {
  /// Linhas de `contagem_itens` que este card representa — uma por código do
  /// produto que o dashboard pediu para conferir.
  final List<int> ids;

  /// Código que recebe o lançamento de divergência.
  final String codigoAncora;

  /// Todos os códigos do produto, com o saldo de cada um.
  final List<CodigoDoGrupo> codigos;

  /// False quando o parentesco entre os códigos foi deduzido pelo nome, sem
  /// respaldo do `mapa_produtos` — o total pode estar incompleto.
  final bool vinculadoNoMapa;

  final String produto;
  final String categoria;

  /// Soma dos saldos de TODOS os códigos do produto — o número que o
  /// conferente compara com a pilha na prateleira.
  final int qtdEstoque;

  final StatusContagem status;
  final String motivo;
  final String observacoes;

  /// Onde o produto está na loja, vindo do app Gôndolas. Reúne os endereços
  /// de todos os códigos do grupo.
  final List<EnderecoProduto> enderecos;

  const ItemContagem({
    required this.ids,
    required this.codigoAncora,
    required this.codigos,
    required this.vinculadoNoMapa,
    required this.produto,
    required this.categoria,
    required this.qtdEstoque,
    required this.status,
    required this.motivo,
    required this.observacoes,
    required this.enderecos,
  });

  /// Identidade estável do card para as chaves de widget e o controle de
  /// gravação em andamento.
  int get id => ids.isEmpty ? codigoAncora.hashCode : ids.first;

  bool get temVariosCodigos => codigos.length > 1;

  ItemContagem _copiaCom({
    List<EnderecoProduto>? enderecos,
    StatusContagem? status,
  }) =>
      ItemContagem(
        ids: ids,
        codigoAncora: codigoAncora,
        codigos: codigos,
        vinculadoNoMapa: vinculadoNoMapa,
        produto: produto,
        categoria: categoria,
        qtdEstoque: qtdEstoque,
        status: status ?? this.status,
        motivo: motivo,
        observacoes: observacoes,
        enderecos: enderecos ?? this.enderecos,
      );

  ItemContagem comEnderecos(List<EnderecoProduto> novos) =>
      _copiaCom(enderecos: novos);

  /// Cópia com o novo status, aplicada na tela logo após a gravação dar
  /// certo. Evita recarregar a lista inteira do banco a cada item conferido —
  /// com rede de loja, esse recarregamento é a diferença entre conferir num
  /// ritmo e esperar a cada toque.
  ItemContagem comStatus(StatusContagem novo) => _copiaCom(status: novo);

  /// Endereços que ainda existem no chão da loja. Os de estante removida
  /// continuam na lista completa (`enderecos`) para o card poder avisar que o
  /// cadastro está velho, mas não servem de destino.
  List<EnderecoProduto> get enderecosValidos =>
      enderecos.where((e) => !e.removido).toList();

  bool get temEnderecoRemovido => enderecos.any((e) => e.removido);
}

/// Resumo da lista para o cabeçalho.
class ResumoContagem {
  final int total;
  final int certas;
  final int divergencias;
  final int pendentes;

  const ResumoContagem({
    required this.total,
    required this.certas,
    required this.divergencias,
    required this.pendentes,
  });

  bool get concluida => total > 0 && pendentes == 0;

  factory ResumoContagem.de(List<ItemContagem> itens) => ResumoContagem(
        total: itens.length,
        certas: itens.where((i) => i.status == StatusContagem.certa).length,
        divergencias:
            itens.where((i) => i.status == StatusContagem.divergencia).length,
        pendentes:
            itens.where((i) => i.status == StatusContagem.pendente).length,
      );
}

/// Lista de contagem carregada do banco, com o resumo já calculado.
class ListaContagem {
  final List<ItemContagem> itens;
  final ResumoContagem resumo;

  const ListaContagem({required this.itens, required this.resumo});

  static const ListaContagem vazia = ListaContagem(
    itens: [],
    resumo: ResumoContagem(total: 0, certas: 0, divergencias: 0, pendentes: 0),
  );
}

class ContagemService {
  static final ContagemService _instance = ContagemService._internal();
  factory ContagemService() => _instance;
  ContagemService._internal();

  Future<LibsqlClient?> _conexao() async {
    if (!await TursoService().garantirConexao()) return null;
    return TursoService().client;
  }

  /// Fuso de Brasília. O dashboard grava todos os carimbos de data em BRT
  /// (`datetime('now', '-3 hours')` nos triggers, `_BRT` no Python) e o
  /// app tem de gravar no mesmo fuso — senão a contagem de hoje cai no dia
  /// errado do inventário cíclico para quem confere depois das 21h.
  static String _agoraBrt() {
    final t = DateTime.now().toUtc().subtract(const Duration(hours: 3));
    String d2(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${d2(t.month)}-${d2(t.day)} '
        '${d2(t.hour)}:${d2(t.minute)}:${d2(t.second)}';
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Leitura
  // ───────────────────────────────────────────────────────────────────────────

  /// Carrega a lista de contagem, agrupa os códigos do mesmo produto e cruza
  /// cada item com as posições do app Gôndolas.
  Future<ListaContagem> carregar() async {
    final client = await _conexao();
    if (client == null) return ListaContagem.vazia;

    final linhas = await _carregarLinhas(client);
    if (linhas.isEmpty) return ListaContagem.vazia;

    // O mestre inteiro é preciso porque o código irmão pode NÃO estar na
    // lista de contagem: no PHOSFIX só o `222534` foi pedido, e é o
    // `US222534` que carrega 73 das 84 unidades da prateleira.
    final mestre = await _carregarMestre(client);
    final mapa = await _carregarMapa(client);

    final agrupados =
        agruparItens(linhas: linhas, mestre: mestre, mapa: mapa);

    final enderecos = await _carregarEnderecos(client);
    final itens = [
      for (final g in agrupados)
        ItemContagem(
          ids: g.ids,
          codigoAncora: g.codigoAncora,
          codigos: g.codigos,
          vinculadoNoMapa: g.vinculadoNoMapa,
          produto: g.produto,
          categoria: g.categoria,
          qtdEstoque: g.qtdEstoque,
          status: g.status,
          motivo: g.motivo,
          observacoes: g.observacoes,
          // Endereço de QUALQUER código do produto: é uma pilha só na
          // prateleira, e quem está endereçado no Gôndolas costuma ser o
          // código irmão, não o que veio na lista.
          enderecos: _enderecosDoGrupo(g.codigos, enderecos),
        ),
    ];

    return ListaContagem(itens: itens, resumo: ResumoContagem.de(itens));
  }

  static List<EnderecoProduto> _enderecosDoGrupo(
    List<CodigoDoGrupo> codigos,
    Map<String, List<EnderecoProduto>> porCodigo,
  ) {
    final vistos = <String>{};
    final juntos = <EnderecoProduto>[];
    for (final c in codigos) {
      for (final e in porCodigo[c.codigo] ?? const <EnderecoProduto>[]) {
        // Dedup pelo endereço físico, ignorando o código: dois códigos do
        // mesmo produto endereçados na mesma prateleira são um lugar só.
        final chave = '${e.localTipo}|${e.localNum}|'
            '${e.faceOuColuna}|${e.andarOuNivel}';
        if (vistos.add(chave)) juntos.add(e);
      }
    }
    juntos.sort((a, b) {
      if (a.ehGondola != b.ehGondola) return a.ehGondola ? -1 : 1;
      if (a.localNum != b.localNum) return a.localNum.compareTo(b.localNum);
      if (a.faceOuColuna != b.faceOuColuna) {
        return a.faceOuColuna.compareTo(b.faceOuColuna);
      }
      return a.andarOuNivel.compareTo(b.andarOuNivel);
    });
    return juntos;
  }

  Future<List<LinhaContagem>> _carregarLinhas(LibsqlClient client) async {
    // Espelha o SELECT de get_contagem_itens() no dashboard, inclusive a CTE
    // que pega o cooperado da divergência mais recente — é ele que aparece na
    // observação do card quando o produto não tem observação no cadastro.
    const sql = '''
      WITH last_div AS (
        SELECT UPPER(TRIM(codigo)) AS cod,
               cooperado,
               ROW_NUMBER() OVER (
                 PARTITION BY UPPER(TRIM(codigo))
                 ORDER BY criado_em DESC
               ) AS rn
        FROM divergencias
      )
      SELECT ci.id, ci.codigo, ci.produto, ci.categoria, ci.qtd_estoque,
             ci.status, ci.motivo,
             COALESCE(
               NULLIF(TRIM(em.observacoes), ''),
               NULLIF(TRIM(em.nota), ''),
               ld.cooperado,
               ''
             ) AS observacoes
      FROM contagem_itens ci
      LEFT JOIN estoque_mestre em
             ON UPPER(TRIM(em.codigo)) = UPPER(TRIM(ci.codigo))
      LEFT JOIN last_div ld
             ON ld.cod = UPPER(TRIM(ci.codigo)) AND ld.rn = 1
      ORDER BY ci.categoria, ci.produto
    ''';

    // `observacoes` é uma coluna adicionada por migração no dashboard e pode
    // não existir em bases mais antigas. Se faltar, refaz sem ela em vez de
    // deixar a tela vazia — a observação é enfeite, a lista não é.
    List<dynamic> rows;
    try {
      rows = (await (await client.prepare(sql)).query()) as List<dynamic>;
    } catch (_) {
      const fallback = '''
        SELECT ci.id, ci.codigo, ci.produto, ci.categoria, ci.qtd_estoque,
               ci.status, ci.motivo, '' AS observacoes
        FROM contagem_itens ci
        ORDER BY ci.categoria, ci.produto
      ''';
      rows = (await (await client.prepare(fallback)).query()) as List<dynamic>;
    }

    return [
      for (final dynamic row in rows)
        if (row is Map<String, dynamic>)
          LinhaContagem(
            id: _asInt(row['id']),
            codigo: _asString(row['codigo']).trim(),
            produto: _asString(row['produto']).trim(),
            categoria: _asString(row['categoria']).trim(),
            qtdEstoque: _asInt(row['qtd_estoque']),
            status: statusDe(_asString(row['status'])),
            motivo: _asString(row['motivo']).trim(),
            observacoes: _asString(row['observacoes']).trim(),
          ),
    ];
  }

  /// `estoque_mestre` reduzido a três colunas. É a tabela que revela os
  /// códigos irmãos ausentes da lista de contagem.
  Future<List<LinhaMestre>> _carregarMestre(LibsqlClient client) async {
    try {
      const sql = 'SELECT codigo, produto, qtd_sistema FROM estoque_mestre';
      final rows = (await (await client.prepare(sql)).query()) as List<dynamic>;
      return [
        for (final dynamic row in rows)
          if (row is Map<String, dynamic>)
            LinhaMestre(
              codigo: _asString(row['codigo']).trim(),
              produto: _asString(row['produto']).trim(),
              qtdSistema: _asInt(row['qtd_sistema']),
            ),
      ];
    } catch (_) {
      // Sem o mestre a contagem ainda funciona, código a código, sem soma.
      return const [];
    }
  }

  /// Vínculo explícito entre códigos (`mapa_produtos` +
  /// `mapa_produtos_codigos`), criado pelo dashboard em `db_mapa.py`. Pode
  /// não existir — nesse caso o agrupamento cai para o nome do produto.
  Future<MapaProdutos> _carregarMapa(LibsqlClient client) async {
    final produtoPorCodigo = <String, String>{};
    final principalPorProduto = <String, String>{};
    try {
      const sqlPrincipal =
          'SELECT produto_id, codigo FROM mapa_produtos WHERE codigo IS NOT NULL';
      final principais =
          (await (await client.prepare(sqlPrincipal)).query()) as List<dynamic>;
      for (final dynamic row in principais) {
        if (row is! Map<String, dynamic>) continue;
        final id = _asString(row['produto_id']).trim();
        final cod = normalizarCodigo(_asString(row['codigo']));
        if (id.isEmpty || cod.isEmpty) continue;
        principalPorProduto[id] = cod;
        produtoPorCodigo[cod] = id;
      }

      const sqlSecundarios =
          'SELECT produto_id, codigo FROM mapa_produtos_codigos';
      final secundarios = (await (await client.prepare(sqlSecundarios)).query())
          as List<dynamic>;
      for (final dynamic row in secundarios) {
        if (row is! Map<String, dynamic>) continue;
        final id = _asString(row['produto_id']).trim();
        final cod = normalizarCodigo(_asString(row['codigo']));
        if (id.isEmpty || cod.isEmpty) continue;
        produtoPorCodigo[cod] = id;
      }
    } catch (_) {
      // Banco sem as tabelas do mapa: o agrupamento por nome dá conta dos
      // casos conhecidos (prefixos US e 100).
      return MapaProdutos.vazio;
    }
    return MapaProdutos(
      produtoPorCodigo: produtoPorCodigo,
      principalPorProduto: principalPorProduto,
    );
  }

  /// Posições de todos os produtos da lista de contagem, indexadas pelo
  /// código normalizado.
  ///
  /// São TRÊS fontes, e todas importam:
  /// - `estoque_localizado`: endereço + quantidade contada ali (app Gôndolas);
  /// - `estante_layout` e `gondola_layout`: onde o produto está cadastrado,
  ///   mesmo que ninguém tenha contado a posição ainda.
  ///
  /// Um produto endereçado mas nunca contado só aparece nas duas últimas — e é
  /// justamente quem mais precisa aparecer na tela do conferente.
  Future<Map<String, List<EnderecoProduto>>> _carregarEnderecos(
      LibsqlClient client) async {
    final porCodigo = <String, List<EnderecoProduto>>{};
    final vistos = <String>{};

    void adicionar(EnderecoProduto e) {
      if (!vistos.add(e.chave)) return;
      porCodigo
          .putIfAbsent(normalizarCodigo(e.produtoCodigo), () => [])
          .add(e);
    }

    // 1. estoque_localizado — endereço COM quantidade. Vem primeiro para que
    //    a deduplicação preserve a quantidade quando o mesmo endereço também
    //    estiver no layout.
    //
    // As três consultas varrem a tabela inteira em vez de filtrar pela
    // contagem: agora que os endereços são procurados por TODOS os códigos do
    // grupo — inclusive os que não estão em `contagem_itens` —, um JOIN com
    // ela deixaria de fora justamente o irmão endereçado.
    try {
      const sql = '''
        SELECT produto_codigo, local_tipo, local_num,
               face_ou_coluna, andar_ou_nivel, quantidade
        FROM estoque_localizado
      ''';
      final rows = (await (await client.prepare(sql)).query()) as List<dynamic>;
      for (final dynamic row in rows) {
        if (row is! Map<String, dynamic>) continue;
        adicionar(EnderecoProduto(
          produtoCodigo: _asString(row['produto_codigo']).trim(),
          localTipo: _asString(row['local_tipo']).trim() == 'gondola'
              ? 'gondola'
              : 'estante',
          localNum: _asInt(row['local_num']),
          faceOuColuna: _asInt(row['face_ou_coluna']),
          andarOuNivel: _asInt(row['andar_ou_nivel']),
          quantidade: _asDouble(row['quantidade']),
        ));
      }
    } catch (_) {
      // Banco sem as tabelas do app Gôndolas: a contagem funciona sem
      // endereço, apenas sem as duas linhas do meio do card.
    }

    // 2. estante_layout — cadastro de posição em estante/expositor/palete.
    //    `slot` é ignorado: dois slots da mesma célula são a mesma posição
    //    etiquetada na prateleira, e repetir "Posição H" três vezes no card
    //    não ajuda ninguém.
    try {
      const sql = '''
        SELECT DISTINCT produto_codigo, estante_num, coluna, nivel
        FROM estante_layout
      ''';
      final rows = (await (await client.prepare(sql)).query()) as List<dynamic>;
      for (final dynamic row in rows) {
        if (row is! Map<String, dynamic>) continue;
        adicionar(EnderecoProduto(
          produtoCodigo: _asString(row['produto_codigo']).trim(),
          localTipo: 'estante',
          localNum: _asInt(row['estante_num']),
          faceOuColuna: _asInt(row['coluna']),
          andarOuNivel: _asInt(row['nivel']),
        ));
      }
    } catch (_) {
      // idem
    }

    // 3. gondola_layout — a face não é persistida, é derivada de pos_x/pos_z
    //    (mesma regra do app Gôndolas, ver faceFromPos).
    try {
      const sql = '''
        SELECT produto_codigo, gondola_num, andar, pos_x, pos_z
        FROM gondola_layout
      ''';
      final rows = (await (await client.prepare(sql)).query()) as List<dynamic>;
      for (final dynamic row in rows) {
        if (row is! Map<String, dynamic>) continue;
        adicionar(EnderecoProduto(
          produtoCodigo: _asString(row['produto_codigo']).trim(),
          localTipo: 'gondola',
          localNum: _asInt(row['gondola_num']),
          faceOuColuna:
              faceFromPos(_asDouble(row['pos_x']), _asDouble(row['pos_z'])),
          andarOuNivel: _asInt(row['andar']),
        ));
      }
    } catch (_) {
      // idem
    }

    return porCodigo;
  }

  /// Divergências ainda abertas para o produto — em qualquer um dos seus
  /// códigos. O dashboard mostra isso antes de registrar outra, para o
  /// conferente escolher entre confirmar a que já existe ou somar uma nova.
  Future<List<DivergenciaAberta>> divergenciasAbertas(
      ItemContagem item) async {
    final client = await _conexao();
    if (client == null) return const [];
    final abertas = <DivergenciaAberta>[];
    for (final c in item.codigos) {
      try {
        final stmt = await client.prepare(
          'SELECT cooperado, delta, status FROM divergencias '
          'WHERE UPPER(TRIM(codigo)) = UPPER(TRIM(?))',
        );
        final rows = (await stmt.query(positional: [c.codigo])) as List<dynamic>;
        for (final dynamic row in rows) {
          if (row is! Map<String, dynamic>) continue;
          abertas.add(DivergenciaAberta(
            cooperado: _asString(row['cooperado']),
            delta: _asInt(row['delta']),
            status: _asString(row['status']),
          ));
        }
      } catch (_) {
        // Um código que falha não pode esconder as divergências dos outros.
      }
    }
    return abertas;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Escrita
  // ───────────────────────────────────────────────────────────────────────────

  /// Marca o produto como conferido e certo — o botão "OK ✓".
  ///
  /// Resolve TODAS as linhas de `contagem_itens` do produto e limpa a
  /// situação de TODOS os seus códigos: a pilha foi conferida por inteiro, e
  /// deixar o código irmão pendente pediria uma segunda contagem da mesma
  /// prateleira.
  Future<bool> confirmarCerta(ItemContagem item) async {
    final client = await _conexao();
    if (client == null) return false;
    final agora = _agoraBrt();

    try {
      // Estoque mestre ANTES de contagem_itens: os triggers
      // trig_contagem_to_cicli / trig_contagem_status_ciclo disparam na
      // mudança de status de contagem_itens e leem qtd_fisica do mestre. Com
      // esta ordem eles já enxergam o valor final.
      for (final c in item.codigos) {
        final stmtMestre = await client.prepare(
          "UPDATE estoque_mestre SET status = 'ok', qtd_fisica = qtd_sistema, "
          "diferenca = 0, nota = '', ultima_contagem = ? "
          "WHERE codigo = ? AND status IN ('falta', 'sobra')",
        );
        await stmtMestre.query(positional: [agora, c.codigo]);

        final stmtDel = await client.prepare(
          'DELETE FROM divergencias WHERE codigo = ?',
        );
        await stmtDel.query(positional: [c.codigo]);
      }

      for (final id in item.ids) {
        await _marcarItem(client, id, 'certa', '', 0, agora);
      }

      TursoService().dataRevision.value++;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Registra uma divergência — o botão "DIVERGÊNCIA".
  ///
  /// [qtdDivergindo] é sempre positiva; [sobra] diz o sentido, e os dois se
  /// referem ao TOTAL do produto (soma de todos os códigos).
  ///
  /// A diferença é lançada num código só, o [ItemContagem.codigoAncora]: a
  /// pilha na prateleira não distingue código, mas `estoque_mestre` e
  /// `divergencias` são por código e é preciso escolher um. Os irmãos ficam
  /// com o saldo intacto, então a soma do produto continua batendo com o que
  /// foi contado — `ancora + delta` mais os irmãos inalterados dá exatamente
  /// a quantidade contada.
  Future<bool> registrarDivergencia({
    required ItemContagem item,
    required int qtdDivergindo,
    required bool sobra,
    required String motivo,
    bool confirmarApenas = false,
  }) async {
    final client = await _conexao();
    if (client == null) return false;

    final agora = _agoraBrt();
    final qtd = qtdDivergindo.abs();
    final delta = sobra ? qtd : -qtd;
    final statusEstoque = sobra ? 'sobra' : 'falta';
    final motivoLimpo = motivo.trim();

    // Saldo do próprio código âncora — a diferença do produto é aplicada
    // sobre ele, não sobre o total.
    final ancora = item.codigos.firstWhere(
      (c) => c.codigo == item.codigoAncora,
      orElse: () => CodigoDoGrupo(
        codigo: item.codigoAncora,
        quantidade: item.qtdEstoque,
        naLista: true,
      ),
    );
    final qtdFisicaAncora = (ancora.quantidade + delta).clamp(0, 1 << 31);
    final diferencaAncora = qtdFisicaAncora - ancora.quantidade;

    try {
      // 1. Estoque mestre primeiro — ver comentário em confirmarCerta.
      //    `observacoes` é coluna de migração; se não existir, grava sem ela.
      try {
        final stmt = await client.prepare(
          'UPDATE estoque_mestre SET status = ?, qtd_fisica = ?, diferenca = ?, '
          'nota = ?, observacoes = ?, ultima_contagem = ? WHERE codigo = ?',
        );
        await stmt.query(positional: [
          statusEstoque,
          qtdFisicaAncora,
          diferencaAncora,
          motivoLimpo,
          motivoLimpo,
          agora,
          ancora.codigo,
        ]);
      } catch (_) {
        final stmt = await client.prepare(
          'UPDATE estoque_mestre SET status = ?, qtd_fisica = ?, diferenca = ?, '
          'nota = ?, ultima_contagem = ? WHERE codigo = ?',
        );
        await stmt.query(positional: [
          statusEstoque,
          qtdFisicaAncora,
          diferencaAncora,
          motivoLimpo,
          agora,
          ancora.codigo,
        ]);
      }

      // 2. Registro da divergência para a aba Divergências do dashboard.
      //    Pulado quando o conferente só está confirmando uma já existente.
      if (!confirmarApenas) {
        final stmtDiv = await client.prepare(
          'INSERT INTO divergencias '
          '(codigo, produto, categoria, delta, status, cooperado, criado_em) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
        );
        await stmtDiv.query(positional: [
          ancora.codigo,
          item.produto,
          item.categoria,
          delta,
          statusEstoque,
          motivoLimpo,
          agora,
        ]);

        final stmtHist = await client.prepare(
          'INSERT INTO historico_divergencias '
          '(codigo, produto, categoria, cooperado, delta, status, criado_em) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
        );
        await stmtHist.query(positional: [
          ancora.codigo,
          item.produto,
          item.categoria,
          motivoLimpo,
          delta,
          statusEstoque,
          agora,
        ]);
      }

      // 3. Itens da contagem por último — disparam os triggers do cíclico.
      for (final id in item.ids) {
        await _marcarItem(client, id, 'divergencia', motivoLimpo, qtd, agora);
      }

      TursoService().dataRevision.value++;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Grava o status de uma linha de `contagem_itens`.
  ///
  /// `confirmado_em` é coluna de migração do dashboard: onde ela não existe,
  /// regrava sem ela em vez de derrubar a confirmação inteira.
  Future<void> _marcarItem(
    LibsqlClient client,
    int id,
    String status,
    String motivo,
    int qtdDivergencia,
    String agora,
  ) async {
    try {
      final stmt = await client.prepare(
        'UPDATE contagem_itens SET status = ?, motivo = ?, '
        'qtd_divergencia = ?, confirmado_em = ? WHERE id = ?',
      );
      await stmt.query(positional: [status, motivo, qtdDivergencia, agora, id]);
    } catch (_) {
      final stmt = await client.prepare(
        'UPDATE contagem_itens SET status = ?, motivo = ?, '
        'qtd_divergencia = ? WHERE id = ?',
      );
      await stmt.query(positional: [status, motivo, qtdDivergencia, id]);
    }
  }
}
