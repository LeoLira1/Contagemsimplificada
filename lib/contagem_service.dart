import 'package:libsql_dart/libsql_dart.dart';

import 'enderecos.dart';
import 'turso_service.dart';

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

/// Status de um item na lista de contagem — os mesmos três valores que o
/// dashboard grava em `contagem_itens.status`.
enum StatusContagem { pendente, certa, divergencia }

StatusContagem _statusDe(String bruto) {
  switch (bruto.trim().toLowerCase()) {
    case 'certa':
      return StatusContagem.certa;
    case 'divergencia':
      return StatusContagem.divergencia;
    default:
      return StatusContagem.pendente;
  }
}

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

/// Um item da lista de contagem, já cruzado com as posições físicas.
class ItemContagem {
  final int id;
  final String codigo;
  final String produto;
  final String categoria;

  /// Quantidade que o sistema diz existir — o número que o conferente
  /// confirma ou contesta.
  final int qtdEstoque;

  final StatusContagem status;

  /// Texto que o dashboard usa para explicar por que o item entrou na lista
  /// (entrada recente, saída sem venda). Vazio na maior parte dos itens.
  final String motivo;

  /// Observação do produto no cadastro (ou o último cooperado com
  /// divergência), vinda de `estoque_mestre`.
  final String observacoes;

  /// Onde o produto está na loja, do app Gôndolas. Vazio quando o produto
  /// nunca foi endereçado — o conferente vai ter de procurar.
  final List<EnderecoProduto> enderecos;

  const ItemContagem({
    required this.id,
    required this.codigo,
    required this.produto,
    required this.categoria,
    required this.qtdEstoque,
    required this.status,
    required this.motivo,
    required this.observacoes,
    required this.enderecos,
  });

  ItemContagem comEnderecos(List<EnderecoProduto> novos) => ItemContagem(
        id: id,
        codigo: codigo,
        produto: produto,
        categoria: categoria,
        qtdEstoque: qtdEstoque,
        status: status,
        motivo: motivo,
        observacoes: observacoes,
        enderecos: novos,
      );

  /// Cópia com o novo status, aplicada na tela logo após a gravação dar
  /// certo. Evita recarregar a lista inteira do banco a cada item conferido —
  /// com rede de loja, esse recarregamento é a diferença entre conferir num
  /// ritmo e esperar a cada toque.
  ItemContagem comStatus(StatusContagem novo) => ItemContagem(
        id: id,
        codigo: codigo,
        produto: produto,
        categoria: categoria,
        qtdEstoque: qtdEstoque,
        status: novo,
        motivo: motivo,
        observacoes: observacoes,
        enderecos: enderecos,
      );

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

  /// Carrega a lista de contagem inteira (a mesma da aba Contagem do
  /// dashboard) e cruza cada item com as posições do app Gôndolas.
  Future<ListaContagem> carregar() async {
    final client = await _conexao();
    if (client == null) return ListaContagem.vazia;

    final itens = await _carregarItens(client);
    if (itens.isEmpty) {
      return const ListaContagem(
        itens: [],
        resumo:
            ResumoContagem(total: 0, certas: 0, divergencias: 0, pendentes: 0),
      );
    }

    final enderecos = await _carregarEnderecos(client);
    final comEndereco = itens
        .map((i) => i.comEnderecos(enderecos[_norm(i.codigo)] ?? const []))
        .toList();

    return ListaContagem(
      itens: comEndereco,
      resumo: ResumoContagem(
        total: comEndereco.length,
        certas: comEndereco
            .where((i) => i.status == StatusContagem.certa)
            .length,
        divergencias: comEndereco
            .where((i) => i.status == StatusContagem.divergencia)
            .length,
        pendentes: comEndereco
            .where((i) => i.status == StatusContagem.pendente)
            .length,
      ),
    );
  }

  static String _norm(String codigo) => codigo.trim().toUpperCase();

  Future<List<ItemContagem>> _carregarItens(LibsqlClient client) async {
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

    final itens = <ItemContagem>[];
    for (final dynamic row in rows) {
      final r = row as Map<String, dynamic>;
      itens.add(ItemContagem(
        id: _asInt(r['id']),
        codigo: _asString(r['codigo']).trim(),
        produto: _asString(r['produto']).trim(),
        categoria: _asString(r['categoria']).trim(),
        qtdEstoque: _asInt(r['qtd_estoque']),
        status: _statusDe(_asString(r['status'])),
        motivo: _asString(r['motivo']).trim(),
        observacoes: _asString(r['observacoes']).trim(),
        enderecos: const [],
      ));
    }
    return itens;
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
  /// justamente quem mais precisa aparecer na tela do conferente. As três
  /// consultas filtram pela própria `contagem_itens` (JOIN em vez de `IN`),
  /// então o tamanho da lista não esbarra no limite de variáveis do SQLite.
  Future<Map<String, List<EnderecoProduto>>> _carregarEnderecos(
      LibsqlClient client) async {
    final porCodigo = <String, List<EnderecoProduto>>{};
    final vistos = <String>{};

    void adicionar(EnderecoProduto e) {
      if (!vistos.add(e.chave)) return;
      porCodigo.putIfAbsent(_norm(e.produtoCodigo), () => []).add(e);
    }

    // 1. estoque_localizado — endereço COM quantidade. Vem primeiro para que
    //    a deduplicação preserve a quantidade quando o mesmo endereço também
    //    estiver no layout.
    try {
      const sql = '''
        SELECT el.produto_codigo, el.local_tipo, el.local_num,
               el.face_ou_coluna, el.andar_ou_nivel, el.quantidade
        FROM estoque_localizado el
        JOIN contagem_itens ci
          ON UPPER(TRIM(ci.codigo)) = UPPER(TRIM(el.produto_codigo))
      ''';
      final rows = (await (await client.prepare(sql)).query()) as List<dynamic>;
      for (final dynamic row in rows) {
        final r = row as Map<String, dynamic>;
        adicionar(EnderecoProduto(
          produtoCodigo: _asString(r['produto_codigo']).trim(),
          localTipo: _asString(r['local_tipo']).trim() == 'gondola'
              ? 'gondola'
              : 'estante',
          localNum: _asInt(r['local_num']),
          faceOuColuna: _asInt(r['face_ou_coluna']),
          andarOuNivel: _asInt(r['andar_ou_nivel']),
          quantidade: _asDouble(r['quantidade']),
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
        SELECT DISTINCT el.produto_codigo, el.estante_num, el.coluna, el.nivel
        FROM estante_layout el
        JOIN contagem_itens ci
          ON UPPER(TRIM(ci.codigo)) = UPPER(TRIM(el.produto_codigo))
      ''';
      final rows = (await (await client.prepare(sql)).query()) as List<dynamic>;
      for (final dynamic row in rows) {
        final r = row as Map<String, dynamic>;
        adicionar(EnderecoProduto(
          produtoCodigo: _asString(r['produto_codigo']).trim(),
          localTipo: 'estante',
          localNum: _asInt(r['estante_num']),
          faceOuColuna: _asInt(r['coluna']),
          andarOuNivel: _asInt(r['nivel']),
        ));
      }
    } catch (_) {
      // idem
    }

    // 3. gondola_layout — a face não é persistida, é derivada de pos_x/pos_z
    //    (mesma regra do app Gôndolas, ver faceFromPos).
    try {
      const sql = '''
        SELECT gl.produto_codigo, gl.gondola_num, gl.andar, gl.pos_x, gl.pos_z
        FROM gondola_layout gl
        JOIN contagem_itens ci
          ON UPPER(TRIM(ci.codigo)) = UPPER(TRIM(gl.produto_codigo))
      ''';
      final rows = (await (await client.prepare(sql)).query()) as List<dynamic>;
      for (final dynamic row in rows) {
        final r = row as Map<String, dynamic>;
        adicionar(EnderecoProduto(
          produtoCodigo: _asString(r['produto_codigo']).trim(),
          localTipo: 'gondola',
          localNum: _asInt(r['gondola_num']),
          faceOuColuna: faceFromPos(_asDouble(r['pos_x']), _asDouble(r['pos_z'])),
          andarOuNivel: _asInt(r['andar']),
        ));
      }
    } catch (_) {
      // idem
    }

    // Ordena cada lista para o card mostrar sempre na mesma ordem: gôndolas
    // primeiro (é por onde se anda na loja), depois estantes por número.
    for (final lista in porCodigo.values) {
      lista.sort((a, b) {
        if (a.ehGondola != b.ehGondola) return a.ehGondola ? -1 : 1;
        if (a.localNum != b.localNum) return a.localNum.compareTo(b.localNum);
        if (a.faceOuColuna != b.faceOuColuna) {
          return a.faceOuColuna.compareTo(b.faceOuColuna);
        }
        return a.andarOuNivel.compareTo(b.andarOuNivel);
      });
    }
    return porCodigo;
  }

  /// Divergências ainda abertas para um produto. O dashboard mostra isso
  /// antes de registrar outra, para o conferente escolher entre confirmar a
  /// que já existe ou somar uma nova.
  Future<List<DivergenciaAberta>> divergenciasAbertas(String codigo) async {
    final client = await _conexao();
    if (client == null) return const [];
    try {
      final stmt = await client.prepare(
        'SELECT cooperado, delta, status FROM divergencias '
        'WHERE UPPER(TRIM(codigo)) = UPPER(TRIM(?))',
      );
      final rows = (await stmt.query(positional: [codigo])) as List<dynamic>;
      return rows.map((dynamic row) {
        final r = row as Map<String, dynamic>;
        return DivergenciaAberta(
          cooperado: _asString(r['cooperado']),
          delta: _asInt(r['delta']),
          status: _asString(r['status']),
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Escrita
  // ───────────────────────────────────────────────────────────────────────────

  /// Marca o item como conferido e certo — o botão "OK ✓".
  ///
  /// Espelha `atualizar_item_contagem(status='certa')` do dashboard: o
  /// produto volta a 'ok' no estoque mestre (só se estava em falta/sobra) e
  /// sai da lista de divergências do cooperado.
  Future<bool> confirmarCerta(ItemContagem item) async {
    final client = await _conexao();
    if (client == null) return false;
    final agora = _agoraBrt();

    try {
      // Estoque mestre ANTES de contagem_itens: os triggers
      // trig_contagem_to_cicli / trig_contagem_status_ciclo disparam na
      // mudança de status de contagem_itens e leem qtd_fisica do mestre. Com
      // esta ordem eles já enxergam o valor final e o inventário cíclico sai
      // certo sem precisar de correção posterior.
      final stmtMestre = await client.prepare(
        "UPDATE estoque_mestre SET status = 'ok', qtd_fisica = qtd_sistema, "
        "diferenca = 0, nota = '', ultima_contagem = ? "
        "WHERE codigo = ? AND status IN ('falta', 'sobra')",
      );
      await stmtMestre.query(positional: [agora, item.codigo]);

      final stmtDel = await client.prepare(
        'DELETE FROM divergencias WHERE codigo = ?',
      );
      await stmtDel.query(positional: [item.codigo]);

      final stmtItem = await client.prepare(
        "UPDATE contagem_itens SET status = 'certa', motivo = '', "
        'qtd_divergencia = 0, confirmado_em = ? WHERE id = ?',
      );
      await stmtItem.query(positional: [agora, item.id]);

      TursoService().dataRevision.value++;
      return true;
    } catch (_) {
      return await _confirmarCertaSemConfirmadoEm(client, item, agora);
    }
  }

  /// Base antiga, sem a coluna `confirmado_em` de `contagem_itens`. O trigger
  /// `trig_contagem_confirmado_em` só existe onde a coluna existe, então aqui
  /// basta gravar o status.
  Future<bool> _confirmarCertaSemConfirmadoEm(
      LibsqlClient client, ItemContagem item, String agora) async {
    try {
      final stmt = await client.prepare(
        "UPDATE contagem_itens SET status = 'certa', motivo = '', "
        'qtd_divergencia = 0 WHERE id = ?',
      );
      await stmt.query(positional: [item.id]);
      TursoService().dataRevision.value++;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Registra uma divergência — o botão "DIVERGÊNCIA".
  ///
  /// [qtdDivergindo] é sempre positiva; [sobra] diz o sentido. [confirmarApenas]
  /// repete o comportamento do dashboard: quando já existe divergência aberta
  /// para o produto, o conferente pode confirmá-la sem criar um registro novo
  /// (senão o saldo do cooperado dobraria).
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
    final qtdSistema = item.qtdEstoque;
    final qtdFisica = sobra ? qtdSistema + qtd : (qtdSistema - qtd).clamp(0, 1 << 31);
    final diferenca = qtdFisica - qtdSistema;
    final statusEstoque = sobra ? 'sobra' : 'falta';
    final motivoLimpo = motivo.trim();

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
          qtdFisica,
          diferenca,
          motivoLimpo,
          motivoLimpo,
          agora,
          item.codigo,
        ]);
      } catch (_) {
        final stmt = await client.prepare(
          'UPDATE estoque_mestre SET status = ?, qtd_fisica = ?, diferenca = ?, '
          'nota = ?, ultima_contagem = ? WHERE codigo = ?',
        );
        await stmt.query(positional: [
          statusEstoque,
          qtdFisica,
          diferenca,
          motivoLimpo,
          agora,
          item.codigo,
        ]);
      }

      // 2. Registro da divergência para a aba Divergências do dashboard.
      //    Pulado quando o conferente só está confirmando uma já existente.
      if (!confirmarApenas) {
        final delta = sobra ? qtd : -qtd;
        final stmtDiv = await client.prepare(
          'INSERT INTO divergencias '
          '(codigo, produto, categoria, delta, status, cooperado, criado_em) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
        );
        await stmtDiv.query(positional: [
          item.codigo,
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
          item.codigo,
          item.produto,
          item.categoria,
          motivoLimpo,
          delta,
          statusEstoque,
          agora,
        ]);
      }

      // 3. Item da contagem por último — dispara os triggers do cíclico.
      try {
        final stmt = await client.prepare(
          "UPDATE contagem_itens SET status = 'divergencia', motivo = ?, "
          'qtd_divergencia = ?, confirmado_em = ? WHERE id = ?',
        );
        await stmt.query(positional: [motivoLimpo, qtd, agora, item.id]);
      } catch (_) {
        final stmt = await client.prepare(
          "UPDATE contagem_itens SET status = 'divergencia', motivo = ?, "
          'qtd_divergencia = ? WHERE id = ?',
        );
        await stmt.query(positional: [motivoLimpo, qtd, item.id]);
      }

      TursoService().dataRevision.value++;
      return true;
    } catch (_) {
      return false;
    }
  }
}
