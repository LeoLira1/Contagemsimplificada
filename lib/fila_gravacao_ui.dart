import 'package:flutter/material.dart';

import 'fila_gravacao.dart';
import 'gravacao_lote.dart';
import 'tema.dart';

/// Aviso de uma conferência que o banco não aceitou — o texto do snackbar.
///
/// Diz O QUE não entrou e POR QUÊ, porque a tela volta ao que está no banco
/// e a pessoa precisa saber o que refazer.
String mensagemFalhaFila(EventoFila evento) {
  final op = evento.operacao;
  final falha = evento.falha;
  if (falha == null) return '';
  if (falha.tipo == TipoFalhaGravacao.conflito) {
    return switch (falha.motivo) {
      'lista_trocada' =>
        'Não gravou ${op.descricao}: a lista de contagem foi trocada no '
            'dashboard enquanto o celular estava sem rede.',
      'ja_conferido' =>
        'Não gravou ${op.descricao}: o produto já tinha sido conferido no '
            'banco (outro aparelho ou o dashboard).',
      _ => 'Não gravou ${op.descricao}: o banco mudou antes do envio.',
    };
  }
  return 'O banco recusou ${op.descricao}. A lista voltou ao que está gravado.';
}

/// Barra de baixo enquanto há conferência na fila.
///
/// Dois estados que a pessoa precisa distinguir num relance: "está indo"
/// (rodinha) e "a rede não deixou, mas está guardado" (nuvem riscada, com o
/// botão de tentar já).
class BarraFilaGravacao extends StatelessWidget {
  final FilaGravacao fila;

  const BarraFilaGravacao({super.key, required this.fila});

  @override
  Widget build(BuildContext context) {
    final n = fila.pendentes.length;
    if (n == 0) return const SizedBox.shrink();
    final semRede = fila.tentativas > 0 && !fila.enviando;
    final plural = n == 1 ? 'conferência guardada' : 'conferências guardadas';
    return SafeArea(
      top: false,
      child: Material(
        color: CoresCamda.superficieAlta,
        child: InkWell(
          onTap: () => mostrarPendentes(context, fila),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: semRede
                      ? const Icon(
                          Icons.cloud_off,
                          size: 20,
                          color: CoresCamda.ambar,
                        )
                      : const CircularProgressIndicator(
                          strokeWidth: 2,
                          color: CoresCamda.verde,
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        semRede
                            ? 'Sem resposta do banco · $n $plural'
                            : n == 1
                                ? 'Enviando ao banco…'
                                : 'Enviando ao banco… ($n na fila)',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: CoresCamda.texto,
                          fontSize: 13,
                        ),
                      ),
                      if (semRede)
                        const Text(
                          'Ficam no celular e vão sozinhas quando a rede '
                          'voltar. Pode continuar conferindo.',
                          maxLines: 2,
                          style: TextStyle(
                            color: CoresCamda.textoFraco,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
                if (semRede)
                  TextButton(
                    onPressed: fila.tentarAgora,
                    child: const Text('Tentar já'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Lista do que está na fila, com a saída de emergência (descartar tudo).
Future<void> mostrarPendentes(BuildContext context, FilaGravacao fila) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: CoresCamda.superficie,
    builder: (ctx) => ListenableBuilder(
      listenable: fila,
      builder: (ctx, _) {
        final ops = fila.pendentes;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  ops.isEmpty
                      ? 'Tudo gravado no banco.'
                      : 'Esperando o banco (${ops.length})',
                  style: const TextStyle(
                    color: CoresCamda.texto,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Vão uma por vez, na ordem em que foram feitas. Reenviar '
                  'nunca grava duas vezes.',
                  style: TextStyle(color: CoresCamda.textoFraco, fontSize: 11),
                ),
                if (fila.ultimoErro != null && !fila.enviando) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Último erro: ${fila.ultimoErro}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: CoresCamda.textoApagado,
                      fontSize: 11,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final (i, op) in ops.indexed)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            i == 0 && fila.enviando
                                ? Icons.upload
                                : Icons.schedule,
                            size: 18,
                            color: CoresCamda.textoFraco,
                          ),
                          title: Text(
                            op.descricao,
                            style: const TextStyle(
                              color: CoresCamda.texto,
                              fontSize: 13,
                            ),
                          ),
                          subtitle: Text(
                            _hora(op.criadaEm),
                            style: const TextStyle(
                              color: CoresCamda.textoApagado,
                              fontSize: 11,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (ops.isNotEmpty)
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => _confirmarDescarte(ctx, fila),
                        style: TextButton.styleFrom(
                          foregroundColor: CoresCamda.vermelho,
                        ),
                        child: const Text('Descartar todas'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: fila.tentarAgora,
                        child: const Text('Tentar já'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

String _hora(DateTime t) =>
    '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')} '
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

Future<void> _confirmarDescarte(BuildContext context, FilaGravacao fila) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Descartar as conferências pendentes?'),
      content: const Text(
        'Elas ainda não chegaram ao banco e os itens voltam a ficar '
        'pendentes. Só faça isso se tiver certeza de que não valem mais.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Manter'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Descartar'),
        ),
      ],
    ),
  );
  if (ok == true) await fila.descartarTodas();
}
