import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:shared_preferences/shared_preferences.dart';

import 'gravacao_lote.dart';
import 'turso_service.dart';

/// O que aconteceu com uma operação que saiu da fila.
class EventoFila {
  final OperacaoContagem operacao;

  /// Null = gravada no servidor. Preenchida = descartada por conflito ou
  /// recusa (reenviar não resolveria).
  final FalhaGravacao? falha;

  const EventoFila(this.operacao, [this.falha]);

  bool get gravada => falha == null;
}

/// Fila das conferências: a tela marca na hora e a fila leva ao banco, em
/// ordem, quando der. É a mesma fila do app Gôndolas (fila_gravacao.dart).
///
/// Antes o "OK ✓" esperava a ida ao banco com o card travado; com sinal ruim
/// a espera não tinha fim e, se a rede caía, a conferência se perdia e era
/// preciso tocar de novo.
///
/// Agora:
///
/// - **Nada se perde.** A operação é gravada no aparelho (preferências) ANTES
///   de qualquer tentativa de rede, e sobrevive a fechar o app. Ela sai da
///   fila só quando o servidor confirma — ou quando o servidor diz que ela
///   não cabe mais (ver [TipoFalhaGravacao.conflito]).
/// - **Uma por vez, na ordem.**
/// - **Reenvio sozinho.** Falha de rede → espera crescente (1 s, 2 s, 4 s…
///   até 20 s) e tenta de novo com o MESMO UUID. O lote é idempotente, então
///   uma resposta perdida nunca vira divergência em dobro.
/// - **Uma requisição por operação.**
class FilaGravacao extends ChangeNotifier {
  FilaGravacao.para({
    required Future<void> Function(OperacaoContagem) executar,
    required Future<String?> Function() ler,
    required Future<void> Function(String) gravar,
    Future<void> Function(Duration)? esperar,
  })  : _executar = executar,
        _ler = ler,
        _gravar = gravar,
        _esperarFn = esperar;

  static FilaGravacao? _instancia;

  /// A fila do app.
  factory FilaGravacao() => _instancia ??= FilaGravacao.para(
        executar: executarOperacao,
        ler: () async =>
            (await SharedPreferences.getInstance()).getString(chaveDisco),
        gravar: (texto) async {
          final prefs = await SharedPreferences.getInstance();
          if (!await prefs.setString(chaveDisco, texto)) {
            throw StateError('fila não persistida');
          }
        },
      );

  static const String chaveDisco = chaveFilaGravacao;

  final Future<void> Function(OperacaoContagem) _executar;
  final Future<String?> Function() _ler;
  final Future<void> Function(String) _gravar;
  final Future<void> Function(Duration)? _esperarFn;

  final List<OperacaoContagem> _fila = [];
  Future<void>? _carregando;
  bool _carregada = false;
  bool _processando = false;
  bool _enviando = false;
  int _tentativas = 0;
  String? _ultimoErro;
  Completer<void>? _espera;
  final _eventos = StreamController<EventoFila>.broadcast();

  /// O que ainda não foi confirmado pelo servidor, na ordem em que foi feito.
  List<OperacaoContagem> get pendentes => List.unmodifiable(_fila);

  bool get vazia => _fila.isEmpty;

  /// True enquanto uma requisição está no ar.
  bool get enviando => _enviando;

  /// Tentativas seguidas que falharam por rede. Zero = a última deu certo.
  int get tentativas => _tentativas;

  /// Por que a última tentativa falhou (texto cru), ou null.
  String? get ultimoErro => _ultimoErro;

  /// Cada operação que saiu da fila — gravada ou descartada.
  Stream<EventoFila> get eventos => _eventos.stream;

  /// Lê do aparelho o que ficou pendente (de uma sessão anterior, inclusive)
  /// e começa a enviar. Pode ser chamada quantas vezes for: só a primeira lê.
  Future<void> carregar() => _carregando ??= _carregarDoDisco();

  Future<void> _carregarDoDisco() async {
    try {
      final salvas = OperacaoContagem.decodificarLista(await _ler());
      final jaNaFila = {for (final o in _fila) o.uuid};
      _fila.insertAll(0, salvas.where((o) => !jaNaFila.contains(o.uuid)));
    } catch (_) {
      // Sem leitura do disco a fila segue com o que entrar nesta sessão.
    }
    _carregada = true;
    notifyListeners();
    // Grava a fila juntada (antigas + o que entrou durante a leitura) ANTES
    // do primeiro envio: senão a primeira conferência da sessão ia ao banco
    // sem estar no disco, e se perdia se o app fechasse no meio.
    if (_fila.isNotEmpty) await _persistir();
    unawaited(_processar());
  }

  /// Põe a operação na fila (e no disco) e dispara o envio. Volta assim que
  /// ela está guardada no aparelho — a ida ao banco acontece por trás.
  Future<void> enfileirar(OperacaoContagem op) async {
    _fila.add(op);
    notifyListeners();
    // O disco é lido ANTES de ser escrito: gravar primeiro trocaria o que uma
    // sessão anterior deixou pendente por esta operação sozinha.
    await carregar();
    await _persistir();
    tentarAgora();
    unawaited(_processar());
  }

  /// Interrompe a espera entre tentativas e tenta já — o botão da barra, a
  /// volta do app para a frente, uma gravação nova.
  void tentarAgora() {
    final espera = _espera;
    if (espera != null && !espera.isCompleted) espera.complete();
  }

  /// Joga fora tudo o que não foi confirmado. Só por pedido explícito da
  /// pessoa (a fila nunca descarta sozinha o que pode ter conserto).
  Future<List<OperacaoContagem>> descartarTodas() async {
    final descartadas = List<OperacaoContagem>.of(_fila);
    _fila.clear();
    _tentativas = 0;
    _ultimoErro = null;
    notifyListeners();
    await _persistir();
    return descartadas;
  }

  /// Completa quando a fila esvaziar (ou na hora, se já está vazia).
  Future<void> esvaziada() {
    if (_fila.isEmpty) return Future<void>.value();
    final pronto = Completer<void>();
    void ouvir() {
      if (_fila.isNotEmpty || pronto.isCompleted) return;
      removeListener(ouvir);
      pronto.complete();
    }

    addListener(ouvir);
    return pronto.future;
  }

  Future<void> _persistir() async {
    try {
      await _gravar(OperacaoContagem.codificarLista(_fila));
    } catch (_) {
      // Sem disco a operação ainda vale nesta sessão; perder a cópia é
      // menos grave do que recusar a conferência.
    }
  }

  /// Espera entre tentativas: 1, 2, 4, 8, 16 e depois 20 s. Curta no começo
  /// porque o comum na loja é o sinal voltar em segundos.
  static Duration atrasoParaTentativa(int tentativa) =>
      Duration(seconds: min(20, 1 << min(tentativa - 1, 5)));

  Future<void> _aguardar(Duration atraso) async {
    final espera = _espera = Completer<void>();
    final fn = _esperarFn;
    if (fn != null) {
      await Future.any([fn(atraso), espera.future]);
    } else {
      final timer = Timer(atraso, () {
        if (!espera.isCompleted) espera.complete();
      });
      await espera.future;
      timer.cancel();
    }
    _espera = null;
  }

  Future<void> _processar() async {
    if (_processando || !_carregada) return;
    _processando = true;
    try {
      while (_fila.isNotEmpty) {
        final op = _fila.first;
        _enviando = true;
        notifyListeners();
        FalhaGravacao? falha;
        try {
          await _executar(op);
        } catch (e) {
          falha = classificarFalhaGravacao(e);
        }
        _enviando = false;
        // Descartada pela pessoa enquanto estava no ar: nada a fazer com ela.
        if (_fila.isEmpty || !identical(_fila.first, op)) continue;
        if (falha != null && falha.transitoria) {
          _tentativas++;
          _ultimoErro = falha.detalhe;
          notifyListeners();
          await _aguardar(atrasoParaTentativa(_tentativas));
          continue;
        }
        _fila.removeAt(0);
        _tentativas = 0;
        _ultimoErro = null;
        // O evento sai ANTES do aviso aos ouvintes: a tela registra a
        // confirmação (microtarefa) antes do próximo quadro, e o item não
        // pisca como pendente entre sair da fila e ser dado como gravado.
        _eventos.add(EventoFila(op, falha));
        notifyListeners();
        await _persistir();
      }
    } finally {
      _processando = false;
      _enviando = false;
      notifyListeners();
    }
  }
}

/// Manda UMA operação ao banco: um lote, uma requisição (ver
/// [TursoService.executarLote]). Lança [FalhaGravacao].
Future<void> executarOperacao(OperacaoContagem op) async {
  final turso = TursoService();
  if (!await turso.garantirConexao()) {
    throw FalhaGravacao(
      TipoFalhaGravacao.rede,
      turso.ultimoErro ?? 'Sem conexão com o banco online.',
    );
  }
  // O banco da operação é o banco em que a pessoa a fez. Se as credenciais
  // mudaram, ela não vai para o banco novo de jeito nenhum.
  final ativo = turso.urlAtiva;
  if (ativo != null && op.banco.isNotEmpty && op.banco != ativo) {
    throw const FalhaGravacao(
      TipoFalhaGravacao.recusada,
      'Conferência feita em outro banco (a URL foi trocada em ⚙️).',
    );
  }
  final esquema = await turso.esquema();
  await turso.executarLote(
    op.comandos(esquema: esquema, dispositivo: 'app_contagem'),
  );
  turso.dataRevision.value++;
}
