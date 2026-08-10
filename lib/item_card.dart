import 'package:flutter/material.dart';

import 'contagem_service.dart';
import 'enderecos.dart';
import 'tema.dart';

/// O card do esboço, linha por linha:
///
///     NOME DO PRODUTO — CÓDIGO
///     ESTANTE OU GÔNDOLA
///     NÚMERO NA ESTANTE
///     QUANTIDADE.            [ OK ✓ ]  [ DIVERGÊNCIA ]
///
/// Um produto pode estar endereçado em mais de um lugar (mesmo item em duas
/// gôndolas, ou estante + palete). O card mostra o primeiro endereço em
/// destaque e os demais logo abaixo, em vez de escolher um e esconder o
/// resto — mandar o conferente a um só lugar quando há dois é como não dar
/// endereço nenhum.
class ItemCard extends StatelessWidget {
  final ItemContagem item;
  final VoidCallback onCerta;
  final VoidCallback onDivergencia;

  /// True enquanto a gravação deste item está no ar — trava os dois botões
  /// para o toque nervoso não gravar duas vezes.
  final bool ocupado;

  const ItemCard({
    super.key,
    required this.item,
    required this.onCerta,
    required this.onDivergencia,
    this.ocupado = false,
  });

  @override
  Widget build(BuildContext context) {
    final enderecos = item.enderecosValidos;
    final principal = enderecos.isNotEmpty ? enderecos.first : null;
    final extras = enderecos.length > 1 ? enderecos.sublist(1) : const [];

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: CoresCamda.superficie,
        border: Border.all(color: CoresCamda.borda),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Linha 1: nome do produto — código ───────────────────────
                Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: item.produto,
                      style: const TextStyle(
                        color: CoresCamda.texto,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                    TextSpan(
                      text: '  —  ${item.codigos.map((c) => c.codigo).join(' + ')}',
                      style: const TextStyle(
                        color: CoresCamda.textoFraco,
                        fontSize: 13,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 10),

                // ── Linhas 2 e 3: onde está e em que posição ────────────────
                if (principal == null)
                  const _SemEndereco()
                else
                  _BlocoEndereco(endereco: principal),

                if (extras.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      const Text(
                        'também em:',
                        style: TextStyle(
                          color: CoresCamda.textoApagado,
                          fontSize: 11,
                        ),
                      ),
                      for (final e in extras) _ChipEndereco(endereco: e),
                    ],
                  ),
                ],

                if (item.temVariosCodigos && !item.vinculadoNoMapa) ...[
                  const SizedBox(height: 6),
                  const _Aviso(
                    icone: Icons.functions,
                    texto: 'Códigos somados pelo nome do produto — não há '
                        'vínculo cadastrado no mapa, então o total pode estar '
                        'incompleto.',
                    cor: CoresCamda.ambar,
                  ),
                ],

                if (item.temEnderecoRemovido) ...[
                  const SizedBox(height: 6),
                  const _Aviso(
                    icone: Icons.history,
                    texto: 'Este produto tem endereço em estante que saiu da '
                        'loja — o cadastro precisa ser refeito no app Gôndolas.',
                    cor: CoresCamda.ambar,
                  ),
                ],

                if (item.motivo.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _Aviso(
                    icone: Icons.info_outline,
                    texto: item.motivo,
                    cor: CoresCamda.roxo,
                  ),
                ],
                if (item.observacoes.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _Aviso(
                    icone: Icons.person_outline,
                    texto: item.observacoes,
                    cor: CoresCamda.textoFraco,
                  ),
                ],
              ],
            ),
          ),

          // ── Linha 4: quantidade + os dois botões ────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                Expanded(
                  child: _Quantidade(
                    qtd: item.qtdEstoque,
                    parcelas: item.temVariosCodigos ? item.codigos : null,
                    incerto: item.temVariosCodigos && !item.vinculadoNoMapa,
                  ),
                ),
                const SizedBox(width: 10),
                _BotaoAcao(
                  rotulo: 'OK',
                  icone: Icons.check,
                  cor: CoresCamda.verde,
                  preenchido: true,
                  onPressed: ocupado ? null : onCerta,
                ),
                const SizedBox(width: 8),
                _BotaoAcao(
                  rotulo: 'Divergência',
                  icone: Icons.report_gmailerrorred_outlined,
                  cor: CoresCamda.vermelho,
                  preenchido: false,
                  onPressed: ocupado ? null : onDivergencia,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Endereço em destaque: a estrutura numa linha, a posição etiquetada na
/// outra — as duas linhas do meio do esboço.
class _BlocoEndereco extends StatelessWidget {
  final EnderecoProduto endereco;

  const _BlocoEndereco({required this.endereco});

  @override
  Widget build(BuildContext context) {
    final qtd = endereco.quantidade;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: CoresCamda.azul.withValues(alpha: 0.07),
        border: Border(
          left: BorderSide(color: CoresCamda.azul.withValues(alpha: 0.8), width: 3),
        ),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(8),
          bottomRight: Radius.circular(8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                endereco.ehGondola ? Icons.hexagon_outlined : Icons.shelves,
                size: 15,
                color: CoresCamda.azul,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  endereco.estrutura.toUpperCase(),
                  style: const TextStyle(
                    color: CoresCamda.texto,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: 21),
            child: Text(
              endereco.posicao +
                  (qtd != null ? '   ·   ${_fmtQtd(qtd)} un no local' : ''),
              style: const TextStyle(
                color: CoresCamda.textoFraco,
                fontSize: 12.5,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChipEndereco extends StatelessWidget {
  final EnderecoProduto endereco;

  const _ChipEndereco({required this.endereco});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: CoresCamda.superficieAlta,
        border: Border.all(color: CoresCamda.borda),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        endereco.compacto,
        style: const TextStyle(
          color: CoresCamda.textoFraco,
          fontSize: 11,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

class _SemEndereco extends StatelessWidget {
  const _SemEndereco();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: CoresCamda.superficieAlta,
        border: Border(
          left: BorderSide(
              color: CoresCamda.textoApagado.withValues(alpha: 0.6), width: 3),
        ),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(8),
          bottomRight: Radius.circular(8),
        ),
      ),
      child: const Row(
        children: [
          Icon(Icons.help_outline, size: 15, color: CoresCamda.textoApagado),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              'SEM ENDEREÇO CADASTRADO',
              style: TextStyle(
                color: CoresCamda.textoApagado,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A quantidade que o conferente compara com a pilha.
///
/// Quando o produto tem mais de um código, o número grande é a SOMA e as
/// parcelas aparecem embaixo — "11 + 73". Sem essa conta explícita, quem
/// confere vê 11, conta 84 e registra uma divergência de 73 unidades que não
/// existe.
class _Quantidade extends StatelessWidget {
  final int qtd;
  final List<CodigoDoGrupo>? parcelas;

  /// True quando os códigos foram reunidos pelo nome, sem vínculo no
  /// `mapa_produtos` — o total pode estar incompleto.
  final bool incerto;

  const _Quantidade({
    required this.qtd,
    this.parcelas,
    this.incerto = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = parcelas;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '$qtd',
              style: const TextStyle(
                color: CoresCamda.texto,
                fontSize: 26,
                fontWeight: FontWeight.w800,
                fontFamily: 'monospace',
                height: 1,
              ),
            ),
            const SizedBox(width: 5),
            const Text(
              'un',
              style: TextStyle(color: CoresCamda.textoApagado, fontSize: 13),
            ),
          ],
        ),
        if (p != null && p.length > 1) ...[
          const SizedBox(height: 3),
          Text(
            p.map((c) => '${c.quantidade}').join(' + '),
            style: TextStyle(
              color: incerto ? CoresCamda.ambar : CoresCamda.textoApagado,
              fontSize: 11.5,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ],
    );
  }
}

class _BotaoAcao extends StatelessWidget {
  final String rotulo;
  final IconData icone;
  final Color cor;
  final bool preenchido;
  final VoidCallback? onPressed;

  const _BotaoAcao({
    required this.rotulo,
    required this.icone,
    required this.cor,
    required this.preenchido,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // Alvo de toque generoso: quem confere está de pé, segurando o celular
    // com uma mão e um produto na outra.
    const altura = 46.0;
    return SizedBox(
      height: altura,
      child: preenchido
          ? FilledButton.icon(
              onPressed: onPressed,
              icon: Icon(icone, size: 19),
              label: Text(rotulo,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              style: FilledButton.styleFrom(
                backgroundColor: cor,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            )
          : OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: cor,
                side: BorderSide(color: cor.withValues(alpha: 0.7)),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: Icon(icone, size: 21, semanticLabel: rotulo),
            ),
    );
  }
}

class _Aviso extends StatelessWidget {
  final IconData icone;
  final String texto;
  final Color cor;

  const _Aviso({required this.icone, required this.texto, required this.cor});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icone, size: 13, color: cor),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            texto,
            style: TextStyle(color: cor, fontSize: 11.5, height: 1.3),
          ),
        ),
      ],
    );
  }
}

/// Quantidade sem `.0` quando é inteira — no chão da loja ninguém conta
/// "12,0 unidades".
String _fmtQtd(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
