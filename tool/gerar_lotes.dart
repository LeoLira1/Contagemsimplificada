// Imprime, em JSON, os lotes que o app manda ao Turso — para o
// verify_lote_sql.py rodá-los num SQLite real. Dart puro (sem Flutter):
//   dart run tool/gerar_lotes.dart
import 'dart:convert';
import 'dart:io';

import 'package:contagem_camda/gravacao_lote.dart';

void main() {
  OperacaoContagem op(String uuid, TipoOperacao tipo, List<int> ids,
          {bool confirmarApenas = false}) =>
      OperacaoContagem(
        uuid: uuid,
        tipo: tipo,
        banco: 'libsql://teste',
        criadaEm: DateTime.utc(2026, 11, 3, 15),
        ids: ids,
        codigos: const ['222534', 'US222534'],
        produto: "PHOSFIX D'AGUA",
        categoria: 'FERTILIZANTE',
        codigoAncora: '222534',
        qtdAncora: 11,
        qtdDivergindo: 3,
        sobra: false,
        motivo: 'JOAO',
        confirmarApenas: confirmarApenas,
      );

  String lote(OperacaoContagem o, EsquemaContagem e) =>
      textoDoLote(o.comandos(esquema: e, dispositivo: 'verificador'));

  const antigo = EsquemaContagem(
    mestreTemObservacoes: false,
    itensTemConfirmadoEm: false,
  );
  stdout.write(jsonEncode({
    'certa': lote(op('u-certa', TipoOperacao.certa, [1, 2]),
        EsquemaContagem.completo),
    'divergencia': lote(op('u-div', TipoOperacao.divergencia, [3]),
        EsquemaContagem.completo),
    'lista_trocada': lote(op('u-sumiu', TipoOperacao.certa, [999]),
        EsquemaContagem.completo),
    'ja_conferido': lote(op('u-dobro', TipoOperacao.divergencia, [3]),
        EsquemaContagem.completo),
    'antigo': lote(op('u-antigo', TipoOperacao.certa, [4]), antigo),
  }));
}
