import 'dart:async';

import 'package:contagem_camda/fila_gravacao.dart';
import 'package:contagem_camda/gravacao_lote.dart';
import 'package:flutter_test/flutter_test.dart';

OperacaoContagem _op(String uuid) => OperacaoContagem(
      uuid: uuid,
      tipo: TipoOperacao.certa,
      banco: 'libsql://x',
      criadaEm: DateTime(2026, 11, 3),
      ids: [uuid.hashCode],
      codigos: const ['1'],
      produto: 'P-$uuid',
    );

/// Fila com disco e rede falsos.
class _Banco {
  String? disco;
  final enviados = <String>[];
  final respostas = <Object?>[]; // null = ok; senão, o erro lançado
  final List<String> discoNoEnvio = [];

  late final FilaGravacao fila = FilaGravacao.para(
    executar: (op) async {
      discoNoEnvio.add(disco ?? '');
      enviados.add(op.uuid);
      final r = respostas.isEmpty ? null : respostas.removeAt(0);
      if (r != null) throw r;
    },
    ler: () async => disco,
    gravar: (t) async => disco = t,
    // Sem espera de verdade entre tentativas.
    esperar: (_) async {},
  );
}

void main() {
  test('guarda no disco ANTES de mandar ao banco', () async {
    final b = _Banco();
    await b.fila.enfileirar(_op('a'));
    await b.fila.esvaziada();
    expect(b.discoNoEnvio.single, contains('"uuid":"a"'));
    expect(OperacaoContagem.decodificarLista(b.disco), isEmpty);
  });

  test('falha de rede reenvia o MESMO uuid até passar', () async {
    final b = _Banco()
      ..respostas.addAll([
        TimeoutException('lenta'),
        Exception('SocketException: Connection reset'),
        null,
      ]);
    final eventos = <EventoFila>[];
    b.fila.eventos.listen(eventos.add);
    await b.fila.enfileirar(_op('a'));
    await b.fila.esvaziada();
    await Future<void>.delayed(Duration.zero);
    expect(b.enviados, ['a', 'a', 'a']);
    expect(eventos.single.gravada, isTrue);
    expect(b.fila.tentativas, 0);
  });

  test('conflito sai da fila com aviso, sem reenviar', () async {
    final b = _Banco()
      ..respostas.add(Exception(
          "bad JSON path: '$marcadorConflito:lista_trocada'"));
    final eventos = <EventoFila>[];
    b.fila.eventos.listen(eventos.add);
    await b.fila.enfileirar(_op('a'));
    await b.fila.esvaziada();
    await Future<void>.delayed(Duration.zero);
    expect(b.enviados, ['a']);
    expect(eventos.single.falha?.motivo, 'lista_trocada');
  });

  test('mantém a ordem e retoma o que ficou de uma sessão anterior',
      () async {
    final b = _Banco()
      ..disco = OperacaoContagem.codificarLista([_op('velha')]);
    await b.fila.enfileirar(_op('nova'));
    await b.fila.esvaziada();
    expect(b.enviados, ['velha', 'nova']);
  });

  test('descartar esvazia a fila e o disco', () async {
    final trava = Completer<void>();
    String? disco;
    final fila = FilaGravacao.para(
      executar: (_) => trava.future,
      ler: () async => disco,
      gravar: (t) async => disco = t,
    );
    await fila.enfileirar(_op('a'));
    expect(fila.pendentes, hasLength(1));
    await fila.descartarTodas();
    expect(fila.vazia, isTrue);
    expect(OperacaoContagem.decodificarLista(disco), isEmpty);
    trava.complete();
  });

  test('espera entre tentativas cresce até 20 s', () {
    expect(FilaGravacao.atrasoParaTentativa(1), const Duration(seconds: 1));
    expect(FilaGravacao.atrasoParaTentativa(3), const Duration(seconds: 4));
    expect(FilaGravacao.atrasoParaTentativa(9), const Duration(seconds: 20));
  });
}
