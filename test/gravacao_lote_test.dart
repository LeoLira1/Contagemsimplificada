import 'dart:async';
import 'dart:math';

import 'package:contagem_camda/gravacao_lote.dart';
import 'package:flutter_test/flutter_test.dart';

OperacaoContagem _certa({List<int> ids = const [10, 11]}) => OperacaoContagem(
      uuid: 'u-1',
      tipo: TipoOperacao.certa,
      banco: 'libsql://x',
      criadaEm: DateTime.utc(2026, 11, 3, 23, 30),
      ids: ids,
      codigos: const ['222534', 'US222534'],
      produto: "PHOSFIX D'AGUA",
      categoria: 'FERTILIZANTE',
    );

OperacaoContagem _divergencia({bool confirmarApenas = false}) =>
    OperacaoContagem(
      uuid: 'u-2',
      tipo: TipoOperacao.divergencia,
      banco: 'libsql://x',
      criadaEm: DateTime.utc(2026, 11, 3, 12),
      ids: const [10],
      codigos: const ['222534'],
      produto: 'PHOSFIX',
      categoria: 'FERTILIZANTE',
      codigoAncora: '222534',
      qtdAncora: 5,
      qtdDivergindo: 8,
      sobra: false,
      motivo: ' JOAO ',
      confirmarApenas: confirmarApenas,
    );

void main() {
  group('literais', () {
    test('texto escapa aspas e tira NUL', () {
      expect(sqlTexto("D'AGUA"), "'D''AGUA'");
      expect(sqlTexto('a\u0000b'), "'ab'");
      expect(sqlTexto(null), 'NULL');
    });

    test('número inteiro sai sem ponto e não finito é recusado', () {
      expect(sqlNumero(3.0), '3');
      expect(sqlNumero(-2), '-2');
      expect(() => sqlNumero(double.nan), throwsArgumentError);
    });
  });

  test('carimbo BRT: 23h30 UTC é 20h30 do mesmo dia', () {
    expect(agoraBrt(DateTime.utc(2026, 11, 3, 23, 30)), '2026-11-03 20:30:00');
    expect(agoraBrt(DateTime.utc(2026, 11, 4, 1)), '2026-11-03 22:00:00');
  });

  test('uuid v4 tem formato certo e não repete', () {
    final a = novoUuid(Random(1));
    expect(
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
              r'[0-9a-f]{12}$')
          .hasMatch(a),
      isTrue,
    );
    expect(novoUuid(), isNot(novoUuid()));
  });

  test('operação vai e volta pelo JSON', () {
    final op = _divergencia(confirmarApenas: true);
    final volta = OperacaoContagem.decodificarLista(
      OperacaoContagem.codificarLista([op, _certa()]),
    );
    expect(volta, hasLength(2));
    expect(volta[0].toJson(), op.toJson());
    expect(volta[1].ids, [10, 11]);
    expect(OperacaoContagem.decodificarLista('lixo'), isEmpty);
    expect(OperacaoContagem.decodificarLista('[{"tipo":"x"}]'), isEmpty);
  });

  group('comandos', () {
    test('OK: guarda, mestre e divergências de cada código, itens, carimbo',
        () {
      final cmds = _certa().comandos(
        esquema: EsquemaContagem.completo,
        dispositivo: 'teste',
      );
      expect(cmds.first, comandoTabelaMutacoes);
      expect(cmds[1], contains('$marcadorConflito:lista_trocada'));
      expect(cmds[2], contains('$marcadorConflito:ja_conferido'));
      expect(cmds.where((c) => c.startsWith('UPDATE estoque_mestre')),
          hasLength(2));
      expect(cmds.where((c) => c.startsWith('DELETE FROM divergencias')),
          hasLength(2));
      final itens =
          cmds.where((c) => c.startsWith('UPDATE contagem_itens')).toList();
      expect(itens, hasLength(2));
      expect(itens.first, contains("confirmado_em = '2026-11-03 20:30:00'"));
      expect(cmds.last, startsWith('INSERT OR IGNORE INTO app_mutacoes'));
      // Toda escrita (menos o carimbo e a tabela) é idempotente pelo UUID.
      for (final c in cmds.sublist(1, cmds.length - 1)) {
        expect(c, contains("uuid = 'u-1'"), reason: c);
      }
      // Itens da contagem por último: são eles que disparam o cíclico.
      final ultimoMestre =
          cmds.lastIndexWhere((c) => c.contains('estoque_mestre'));
      final primeiroItem =
          cmds.indexWhere((c) => c.startsWith('UPDATE contagem_itens'));
      expect(ultimoMestre, lessThan(primeiroItem));
    });

    test('esquema antigo: sem confirmado_em nem observacoes', () {
      const antigo = EsquemaContagem(
        mestreTemObservacoes: false,
        itensTemConfirmadoEm: false,
      );
      final cmds =
          _divergencia().comandos(esquema: antigo, dispositivo: 'teste');
      expect(cmds.join('\n'), isNot(contains('confirmado_em')));
      expect(cmds.join('\n'), isNot(contains('observacoes')));
    });

    test('divergência: saldo do âncora não fica negativo', () {
      final cmds = _divergencia()
          .comandos(esquema: EsquemaContagem.completo, dispositivo: 't');
      final mestre = cmds.firstWhere((c) => c.startsWith('UPDATE estoque'));
      // 5 em estoque, falta de 8 → físico 0, diferença -5.
      expect(mestre, contains('qtd_fisica = 0'));
      expect(mestre, contains('diferenca = -5'));
      expect(mestre, contains("nota = 'JOAO'"));
      final div = cmds.firstWhere((c) => c.startsWith('INSERT INTO diverg'));
      expect(div, contains("-8, 'falta', 'JOAO'"));
      expect(cmds.where((c) => c.contains('historico_divergencias')),
          hasLength(1));
    });

    test('só confirmar a divergência existente não insere outra', () {
      final cmds = _divergencia(confirmarApenas: true)
          .comandos(esquema: EsquemaContagem.completo, dispositivo: 't');
      expect(cmds.where((c) => c.startsWith('INSERT INTO')), isEmpty);
    });
  });

  group('classificação de falhas', () {
    test('timeout e socket são rede (reenviar)', () {
      expect(classificarFalhaGravacao(TimeoutException('x')).transitoria,
          isTrue);
      expect(
        classificarFalhaGravacao(Exception('SocketException: reset'))
            .transitoria,
        isTrue,
      );
      expect(
        classificarFalhaGravacao(Exception('SQLITE_BUSY')).transitoria,
        isTrue,
      );
    });

    test('guarda de conflito vira conflito com motivo', () {
      final f = classificarFalhaGravacao(Exception(
        "SQLite error: bad JSON path: '$marcadorConflito:ja_conferido'",
      ));
      expect(f.tipo, TipoFalhaGravacao.conflito);
      expect(f.motivo, 'ja_conferido');
    });

    test('erro de SQL é recusa', () {
      expect(
        classificarFalhaGravacao(Exception('no such table: divergencias'))
            .tipo,
        TipoFalhaGravacao.recusada,
      );
    });
  });
}
