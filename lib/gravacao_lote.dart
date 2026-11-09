import 'dart:async';
import 'dart:convert';
import 'dart:math';

// ─────────────────────────────────────────────────────────────────────────────
// Gravação em UMA requisição — o mesmo caminho do app Gôndolas
// ─────────────────────────────────────────────────────────────────────────────
//
// Por que existe. O "OK ✓" fazia cada UPDATE/DELETE numa ida ao Turso, em
// fila, e o libsql_dart ainda prepara cada comando antes de rodá-lo. Num
// produto com dois códigos eram umas 10 idas e voltas, sem transação e sem
// prazo. Na rede da loja isso era o "clico em OK, demora e não registra" — e,
// se a rede caía no meio, ficava metade gravada (mestre atualizado, item da
// contagem ainda pendente).
//
// Agora a gravação inteira vira um texto SQL só, mandado num pipeline Hrana
// único (`LibsqlClient.batch`): uma ida e uma volta, dentro de
// BEGIN IMMEDIATE … COMMIT. Ou grava tudo, ou nada.
//
// O que isso exige do SQL (mesmas regras do Gôndolas, gravacao_lote.dart):
//
// - **Sem parâmetros.** O `batch` não aceita `?`. Os valores entram como
//   literais, sempre por [sqlTexto] / [sqlNumero].
//
// - **Idempotente pelo UUID.** Toda escrita leva
//   `NOT EXISTS (… app_mutacoes_aplicadas WHERE uuid = …)` e o carimbo do UUID
//   é o último passo antes do COMMIT. Se a resposta se perde (o servidor
//   gravou, o celular não ouviu), reenviar o MESMO lote não faz nada — é isso
//   que deixa a fila reenviar sozinha sem duplicar divergência.
//
// - **Conflito vira erro com nome.** O lote aborta de propósito avaliando
//   `json_extract('{}', '<marcador>')`, cujo erro carrega o nosso texto. É o
//   que separa "a lista foi trocada no dashboard enquanto você estava sem
//   rede" (não adianta reenviar) de "a rede caiu" (reenviar resolve).

/// Onde a fila guarda as gravações pendentes, nas preferências do aparelho.
const String chaveFilaGravacao = 'fila_contagem_v1';

/// Marca dos erros provocados de propósito pela guarda de conflito.
const String marcadorConflito = 'CONTAGEM_CONFLITO';

/// Literal de texto SQL. Null vira NULL.
///
/// Aspas simples dobradas são o escape completo de string no SQLite (não há
/// barra invertida). O NUL sai porque truncaria o texto no lado C.
String sqlTexto(String? valor) {
  if (valor == null) return 'NULL';
  final limpo = valor.replaceAll('\u0000', '').replaceAll("'", "''");
  return "'$limpo'";
}

/// Literal numérico SQL. NaN e infinito não têm literal — melhor recusar do
/// que gravar lixo num estoque.
String sqlNumero(num valor) {
  if (valor is double && !valor.isFinite) {
    throw ArgumentError.value(valor, 'valor', 'número não finito');
  }
  if (valor is double &&
      valor == valor.truncateToDouble() &&
      valor.abs() < 1e15) {
    return valor.toInt().toString();
  }
  return valor.toString();
}

/// SELECT que aborta o lote quando [condicao] é verdadeira. O [motivo] volta
/// no erro (ver [classificarFalhaGravacao]) e precisa ser uma palavra só.
String guardaConflito(String condicao, String motivo) =>
    'SELECT CASE WHEN $condicao THEN '
    "json_extract('{}', '$marcadorConflito:$motivo') END";

/// Os comandos entre BEGIN IMMEDIATE e COMMIT, num texto só para o `batch`.
///
/// IMMEDIATE pega a trava de escrita já no começo: dois aparelhos gravando
/// ao mesmo tempo são serializados pelo servidor.
String textoDoLote(List<String> comandos) =>
    ['BEGIN IMMEDIATE', ...comandos, 'COMMIT'].join(';\n');

/// Mesma tabela criada pelo app Gôndolas: o banco é compartilhado, e o
/// `IF NOT EXISTS` deixa os dois apps conviverem nela.
const String comandoTabelaMutacoes =
    'CREATE TABLE IF NOT EXISTS app_mutacoes_aplicadas ('
    'uuid TEXT PRIMARY KEY, aplicada_em TEXT NOT NULL, '
    'operacao TEXT, dispositivo TEXT)';

/// UUID v4 a partir de [Random.secure], sem pacote novo.
String novoUuid([Random? random]) {
  final rng = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// Carimbo no fuso de Brasília, no formato que o dashboard grava
/// (`datetime('now', '-3 hours')`). Sem isso a contagem feita depois das 21h
/// cai no dia errado do inventário cíclico.
String agoraBrt([DateTime? instante]) {
  final t = (instante ?? DateTime.now())
      .toUtc()
      .subtract(const Duration(hours: 3));
  String d2(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${d2(t.month)}-${d2(t.day)} '
      '${d2(t.hour)}:${d2(t.minute)}:${d2(t.second)}';
}

// ── Falhas ───────────────────────────────────────────────────────────────────

enum TipoFalhaGravacao {
  /// O banco mudou de um jeito que torna a gravação sem sentido (lista
  /// trocada no dashboard, item já conferido por outro aparelho). Reenviar dá
  /// no mesmo: a operação sai da fila e a tela volta ao que está no banco.
  conflito,

  /// O servidor rodou o SQL e recusou (tabela ausente, restrição violada).
  /// Também não adianta reenviar.
  recusada,

  /// Não deu para falar com o servidor, ou a resposta não chegou. Reenviar
  /// é seguro (o lote é idempotente) e é o que a fila faz sozinha.
  rede,
}

class FalhaGravacao implements Exception {
  final TipoFalhaGravacao tipo;

  /// Para [TipoFalhaGravacao.conflito]: o motivo escrito na guarda
  /// (`lista_trocada`, `ja_conferido`).
  final String? motivo;
  final String detalhe;

  const FalhaGravacao(this.tipo, this.detalhe, {this.motivo});

  bool get transitoria => tipo == TipoFalhaGravacao.rede;

  @override
  String toString() => 'FalhaGravacao(${tipo.name}'
      '${motivo == null ? '' : ': $motivo'}): $detalhe';
}

/// Decide se vale reenviar.
///
/// O libsql_dart transforma os erros do Rust em texto: a mensagem do Hrana
/// com o código do SQLite dentro quando o servidor executou e recusou, ou
/// erro de HTTP/socket quando não houve conversa. Na dúvida é rede —
/// reenviar um lote idempotente custa uma requisição; jogar fora a contagem
/// de alguém custa refazer a prateleira.
FalhaGravacao classificarFalhaGravacao(Object erro) {
  if (erro is FalhaGravacao) return erro;
  if (erro is TimeoutException) {
    return const FalhaGravacao(
      TipoFalhaGravacao.rede,
      'O banco online não respondeu a tempo.',
    );
  }
  final texto = erro.toString();
  final i = texto.indexOf(marcadorConflito);
  if (i >= 0) {
    final resto = texto.substring(i + marcadorConflito.length);
    final m = RegExp(r'^:([A-Za-z0-9_]+)').firstMatch(resto);
    return FalhaGravacao(
      TipoFalhaGravacao.conflito,
      texto,
      motivo: m?.group(1),
    );
  }
  final maiusculo = texto.toUpperCase();
  // Trava de escrita ocupada é passageira por definição.
  if (maiusculo.contains('SQLITE_BUSY') ||
      maiusculo.contains('SQLITE_LOCKED') ||
      maiusculo.contains('DATABASE IS LOCKED')) {
    return FalhaGravacao(TipoFalhaGravacao.rede, texto);
  }
  if (RegExp(r'\bSQL(ITE)?_[A-Z_]+').hasMatch(maiusculo) ||
      maiusculo.contains('CONSTRAINT FAILED') ||
      maiusculo.contains('NO SUCH TABLE') ||
      maiusculo.contains('NO SUCH COLUMN')) {
    return FalhaGravacao(TipoFalhaGravacao.recusada, texto);
  }
  return FalhaGravacao(TipoFalhaGravacao.rede, texto);
}

// ── Esquema ──────────────────────────────────────────────────────────────────

/// Colunas que o dashboard adicionou por migração e podem faltar em bases
/// antigas. Antes isso era descoberto com try/catch em cada gravação — e um
/// erro de REDE caía no mesmo catch e regravava sem a coluna. Agora é lido
/// uma vez (PRAGMA) e o lote já sai certo.
class EsquemaContagem {
  final bool mestreTemObservacoes;
  final bool itensTemConfirmadoEm;

  const EsquemaContagem({
    required this.mestreTemObservacoes,
    required this.itensTemConfirmadoEm,
  });

  static const completo = EsquemaContagem(
    mestreTemObservacoes: true,
    itensTemConfirmadoEm: true,
  );
}

// ── Operação ─────────────────────────────────────────────────────────────────

enum TipoOperacao { certa, divergencia }

/// Uma conferência feita na tela e ainda não confirmada pelo servidor.
///
/// Guarda tudo o que a gravação precisa — inclusive o saldo que a tela
/// mostrava —, porque ela pode subir horas depois, com o app já fechado e
/// reaberto.
class OperacaoContagem {
  /// Identidade da gravação, carimbada em `app_mutacoes_aplicadas`.
  final String uuid;
  final TipoOperacao tipo;

  /// URL do banco em que a conferência foi feita. Nunca vai para outro.
  final String banco;

  /// Quando a pessoa tocou. Vai para `ultima_contagem`/`confirmado_em`: a
  /// prateleira foi conferida nessa hora, mesmo que a rede só deixe avisar
  /// o servidor depois.
  final DateTime criadaEm;

  /// Linhas de `contagem_itens` do produto.
  final List<int> ids;

  /// Todos os códigos do produto.
  final List<String> codigos;

  final String produto;
  final String categoria;

  // ── Só para divergência ──
  final String codigoAncora;

  /// Saldo do código âncora quando a tela foi carregada.
  final int qtdAncora;
  final int qtdDivergindo;
  final bool sobra;
  final String motivo;
  final bool confirmarApenas;

  const OperacaoContagem({
    required this.uuid,
    required this.tipo,
    required this.banco,
    required this.criadaEm,
    required this.ids,
    required this.codigos,
    required this.produto,
    this.categoria = '',
    this.codigoAncora = '',
    this.qtdAncora = 0,
    this.qtdDivergindo = 0,
    this.sobra = false,
    this.motivo = '',
    this.confirmarApenas = false,
  });

  /// Texto curto para avisos: `"PHOSFIX 1L" (OK)`.
  String get descricao => tipo == TipoOperacao.certa
      ? '"$produto" (OK)'
      : '"$produto" (${sobra ? 'sobra' : 'falta'} de $qtdDivergindo un)';

  /// Delta com sinal aplicado ao código âncora: negativo é falta.
  int get delta => sobra ? qtdDivergindo.abs() : -qtdDivergindo.abs();

  Map<String, Object?> toJson() => {
        'uuid': uuid,
        'tipo': tipo.name,
        'banco': banco,
        'criadaEm': criadaEm.toIso8601String(),
        'ids': ids,
        'codigos': codigos,
        'produto': produto,
        'categoria': categoria,
        'codigoAncora': codigoAncora,
        'qtdAncora': qtdAncora,
        'qtdDivergindo': qtdDivergindo,
        'sobra': sobra,
        'motivo': motivo,
        'confirmarApenas': confirmarApenas,
      };

  /// Null quando o registro não é legível (versão futura, disco corrompido):
  /// melhor deixar de fora do que mandar ao banco algo mal interpretado.
  static OperacaoContagem? fromJson(Map<String, Object?> json) {
    try {
      return OperacaoContagem(
        uuid: json['uuid'] as String,
        tipo: TipoOperacao.values.byName(json['tipo'] as String),
        banco: json['banco'] as String? ?? '',
        criadaEm: DateTime.parse(json['criadaEm'] as String),
        ids: [for (final v in json['ids'] as List) (v as num).toInt()],
        codigos: [for (final v in json['codigos'] as List) v as String],
        produto: json['produto'] as String? ?? '',
        categoria: json['categoria'] as String? ?? '',
        codigoAncora: json['codigoAncora'] as String? ?? '',
        qtdAncora: (json['qtdAncora'] as num?)?.toInt() ?? 0,
        qtdDivergindo: (json['qtdDivergindo'] as num?)?.toInt() ?? 0,
        sobra: json['sobra'] as bool? ?? false,
        motivo: json['motivo'] as String? ?? '',
        confirmarApenas: json['confirmarApenas'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  static String codificarLista(Iterable<OperacaoContagem> ops) =>
      jsonEncode([for (final o in ops) o.toJson()]);

  static List<OperacaoContagem> decodificarLista(String? texto) {
    if (texto == null || texto.isEmpty) return [];
    try {
      final ops = <OperacaoContagem>[];
      for (final item in jsonDecode(texto) as List) {
        final op = OperacaoContagem.fromJson(
          Map<String, Object?>.from(item as Map),
        );
        if (op != null) ops.add(op);
      }
      return ops;
    } catch (_) {
      return [];
    }
  }

  /// O lote inteiro, na ordem que os triggers do inventário cíclico pedem:
  /// estoque mestre → divergências → itens da contagem (são eles que disparam
  /// `trig_contagem_to_cicli` / `trig_contagem_status_ciclo`, lendo o mestre
  /// já atualizado).
  List<String> comandos({
    required EsquemaContagem esquema,
    required String dispositivo,
  }) {
    final u = sqlTexto(uuid);
    final naoAplicada =
        'NOT EXISTS (SELECT 1 FROM app_mutacoes_aplicadas WHERE uuid = $u)';
    final quando = sqlTexto(agoraBrt(criadaEm));
    final listaIds = ids.map(sqlNumero).join(', ');
    final idsSql = listaIds.isEmpty ? 'NULL' : listaIds;

    final cmds = <String>[
      comandoTabelaMutacoes,
      // O dashboard recria contagem_itens a cada planilha enviada: se nenhum
      // id ainda existe, a lista foi trocada enquanto o celular estava sem
      // rede, e gravar agora marcaria um item que ninguém pediu mais.
      guardaConflito(
        '$naoAplicada AND NOT EXISTS '
            '(SELECT 1 FROM contagem_itens WHERE id IN ($idsSql))',
        'lista_trocada',
      ),
      // Outro aparelho (ou o dashboard) conferiu o produto antes. Sem esta
      // guarda, uma falta registrada offline seria lançada em dobro.
      guardaConflito(
        '$naoAplicada AND NOT EXISTS '
            '(SELECT 1 FROM contagem_itens WHERE id IN ($idsSql) '
            "AND LOWER(TRIM(COALESCE(status, ''))) "
            "NOT IN ('certa', 'divergencia'))",
        'ja_conferido',
      ),
    ];

    if (tipo == TipoOperacao.certa) {
      for (final c in codigos) {
        final cod = sqlTexto(c);
        cmds.add(
          "UPDATE estoque_mestre SET status = 'ok', qtd_fisica = qtd_sistema, "
          "diferenca = 0, nota = '', ultima_contagem = $quando "
          "WHERE codigo = $cod AND status IN ('falta', 'sobra') "
          'AND $naoAplicada',
        );
        cmds.add('DELETE FROM divergencias WHERE codigo = $cod '
            'AND $naoAplicada');
      }
      for (final id in ids) {
        cmds.add(_comandoItem(esquema, id, 'certa', '', 0, quando, naoAplicada));
      }
    } else {
      final d = delta;
      final status = sobra ? 'sobra' : 'falta';
      final fisica = (qtdAncora + d).clamp(0, 1 << 31);
      final diferenca = fisica - qtdAncora;
      final m = sqlTexto(motivo.trim());
      final anc = sqlTexto(codigoAncora);
      final obs = esquema.mestreTemObservacoes ? 'observacoes = $m, ' : '';
      cmds.add(
        'UPDATE estoque_mestre SET status = ${sqlTexto(status)}, '
        'qtd_fisica = ${sqlNumero(fisica)}, '
        'diferenca = ${sqlNumero(diferenca)}, nota = $m, $obs'
        'ultima_contagem = $quando WHERE codigo = $anc AND $naoAplicada',
      );
      if (!confirmarApenas) {
        final valores = '$anc, ${sqlTexto(produto)}, ${sqlTexto(categoria)}';
        cmds.add(
          'INSERT INTO divergencias '
          '(codigo, produto, categoria, delta, status, cooperado, criado_em) '
          'SELECT $valores, ${sqlNumero(d)}, ${sqlTexto(status)}, $m, $quando '
          'WHERE $naoAplicada',
        );
        cmds.add(
          'INSERT INTO historico_divergencias '
          '(codigo, produto, categoria, cooperado, delta, status, criado_em) '
          'SELECT $valores, $m, ${sqlNumero(d)}, ${sqlTexto(status)}, $quando '
          'WHERE $naoAplicada',
        );
      }
      for (final id in ids) {
        cmds.add(_comandoItem(esquema, id, 'divergencia', motivo.trim(),
            qtdDivergindo.abs(), quando, naoAplicada));
      }
    }

    // Por último, antes do COMMIT: a prova consultável de que o lote entrou.
    cmds.add(
      'INSERT OR IGNORE INTO app_mutacoes_aplicadas '
      '(uuid, aplicada_em, operacao, dispositivo) VALUES '
      '($u, ${sqlTexto(DateTime.now().toIso8601String())}, '
      "${sqlTexto('contagem_${tipo.name}')}, ${sqlTexto(dispositivo)})",
    );
    return cmds;
  }

  static String _comandoItem(
    EsquemaContagem esquema,
    int id,
    String status,
    String motivo,
    int qtd,
    String quando,
    String naoAplicada,
  ) {
    final conf = esquema.itensTemConfirmadoEm ? ', confirmado_em = $quando' : '';
    return 'UPDATE contagem_itens SET status = ${sqlTexto(status)}, '
        'motivo = ${sqlTexto(motivo)}, qtd_divergencia = ${sqlNumero(qtd)}'
        '$conf WHERE id = ${sqlNumero(id)} AND $naoAplicada';
  }
}
