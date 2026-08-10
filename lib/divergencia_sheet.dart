import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'contagem_service.dart';
import 'tema.dart';

/// O que o conferente decidiu na folha de divergência.
class ResultadoDivergencia {
  /// Quantidade contada de fato na prateleira.
  final int qtdContada;

  /// Diferença em módulo contra o que o sistema diz.
  final int qtdDivergindo;

  /// True quando sobrou (contou mais do que o sistema tinha).
  final bool sobra;

  final String motivo;

  /// Confirma uma divergência que já existia, sem criar registro novo.
  final bool confirmarApenas;

  const ResultadoDivergencia({
    required this.qtdContada,
    required this.qtdDivergindo,
    required this.sobra,
    required this.motivo,
    required this.confirmarApenas,
  });
}

/// Abre a folha de divergência de um item.
///
/// O dashboard pede a DIFERENÇA com sinal ("−3 falta / +2 sobra"); aqui se
/// pede a quantidade CONTADA e o app calcula a diferença. Quem está na frente
/// da prateleira sabe quantas unidades tem na mão — fazer a subtração de
/// cabeça, em pé, é onde nasce erro de inventário.
Future<ResultadoDivergencia?> abrirFolhaDivergencia(
  BuildContext context,
  ItemContagem item,
) {
  return showModalBottomSheet<ResultadoDivergencia>(
    context: context,
    isScrollControlled: true,
    backgroundColor: CoresCamda.superficie,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (ctx) => _FolhaDivergencia(item: item),
  );
}

class _FolhaDivergencia extends StatefulWidget {
  final ItemContagem item;

  const _FolhaDivergencia({required this.item});

  @override
  State<_FolhaDivergencia> createState() => _FolhaDivergenciaState();
}

class _FolhaDivergenciaState extends State<_FolhaDivergencia> {
  late final TextEditingController _qtdCtrl;
  late final TextEditingController _motivoCtrl;

  List<DivergenciaAberta> _abertas = const [];
  bool _carregandoAbertas = true;
  bool _confirmarApenas = true;

  @override
  void initState() {
    super.initState();
    _qtdCtrl = TextEditingController();
    // Pré-preenche com a observação do produto (normalmente o cooperado),
    // igual ao dashboard faz.
    _motivoCtrl = TextEditingController(text: widget.item.observacoes);
    _qtdCtrl.addListener(() => setState(() {}));
    _carregarAbertas();
  }

  @override
  void dispose() {
    _qtdCtrl.dispose();
    _motivoCtrl.dispose();
    super.dispose();
  }

  Future<void> _carregarAbertas() async {
    final abertas =
        await ContagemService().divergenciasAbertas(widget.item);
    if (!mounted) return;
    setState(() {
      _abertas = abertas;
      _carregandoAbertas = false;
    });
  }

  int? get _qtdContada => int.tryParse(_qtdCtrl.text.trim());

  /// Diferença com sinal: negativa é falta, positiva é sobra.
  int? get _diferenca {
    final contada = _qtdContada;
    if (contada == null) return null;
    return contada - widget.item.qtdEstoque;
  }

  bool get _podeConfirmar {
    final d = _diferenca;
    return d != null && d != 0;
  }

  void _confirmar() {
    final contada = _qtdContada;
    final d = _diferenca;
    if (contada == null || d == null || d == 0) return;
    Navigator.of(context).pop(ResultadoDivergencia(
      qtdContada: contada,
      qtdDivergindo: d.abs(),
      sobra: d > 0,
      motivo: _motivoCtrl.text,
      confirmarApenas: _abertas.isNotEmpty && _confirmarApenas,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final d = _diferenca;

    return Padding(
      // Sobe junto com o teclado, senão o campo de motivo fica embaixo dele.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: CoresCamda.borda,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                item.produto,
                style: const TextStyle(
                  color: CoresCamda.texto,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${item.codigos.map((c) => c.codigo).join(" + ")}   ·   sistema: ${item.qtdEstoque} un',
                style: const TextStyle(
                  color: CoresCamda.textoFraco,
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 18),

              if (_carregandoAbertas)
                const Padding(
                  padding: EdgeInsets.only(bottom: 14),
                  child: LinearProgressIndicator(minHeight: 2),
                )
              else if (_abertas.isNotEmpty) ...[
                _AvisoDivergenciaAberta(abertas: _abertas),
                const SizedBox(height: 10),
                _EscolhaModo(
                  confirmarApenas: _confirmarApenas,
                  onChanged: (v) => setState(() => _confirmarApenas = v),
                ),
                const SizedBox(height: 18),
              ],

              const Text(
                'Quantas unidades você contou?',
                style: TextStyle(
                  color: CoresCamda.texto,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _qtdCtrl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                    signed: false, decimal: false),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                ),
                decoration: const InputDecoration(
                  hintText: '0',
                  suffixText: 'un',
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                ),
              ),
              const SizedBox(height: 10),
              _ResumoDiferenca(diferenca: d, qtdSistema: item.qtdEstoque),
              const SizedBox(height: 18),

              const Text(
                'Motivo / cooperado',
                style: TextStyle(
                  color: CoresCamda.texto,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _motivoCtrl,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Ex: vencido, avariado, nome do cooperado…',
                ),
              ),
              const SizedBox(height: 22),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: CoresCamda.textoFraco,
                        side: const BorderSide(color: CoresCamda.borda),
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _podeConfirmar ? _confirmar : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: CoresCamda.vermelho,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: CoresCamda.superficieAlta,
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('Registrar divergência',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResumoDiferenca extends StatelessWidget {
  final int? diferenca;
  final int qtdSistema;

  const _ResumoDiferenca({required this.diferenca, required this.qtdSistema});

  @override
  Widget build(BuildContext context) {
    final d = diferenca;

    if (d == null) {
      return const Text(
        'Digite a quantidade contada para o app calcular a diferença.',
        style: TextStyle(color: CoresCamda.textoApagado, fontSize: 12.5),
      );
    }
    if (d == 0) {
      // Contou exatamente o que o sistema tem: isso não é divergência, é um
      // "OK". Dizer isso aqui evita registrar divergência de zero unidade.
      return const Row(
        children: [
          Icon(Icons.check_circle_outline, size: 16, color: CoresCamda.verde),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              'Bate com o sistema. Feche esta folha e use o botão OK.',
              style: TextStyle(color: CoresCamda.verde, fontSize: 12.5),
            ),
          ),
        ],
      );
    }

    final sobra = d > 0;
    final cor = sobra ? CoresCamda.azul : CoresCamda.vermelho;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cor.withValues(alpha: 0.10),
        border: Border.all(color: cor.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(sobra ? Icons.trending_up : Icons.trending_down,
              size: 18, color: cor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              sobra
                  ? 'SOBRA de ${d.abs()} un (sistema tem $qtdSistema)'
                  : 'FALTA de ${d.abs()} un (sistema tem $qtdSistema)',
              style: TextStyle(
                color: cor,
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AvisoDivergenciaAberta extends StatelessWidget {
  final List<DivergenciaAberta> abertas;

  const _AvisoDivergenciaAberta({required this.abertas});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CoresCamda.ambar.withValues(alpha: 0.10),
        border: Border.all(color: CoresCamda.ambar.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 17, color: CoresCamda.ambar),
              SizedBox(width: 7),
              Text(
                'Já existe divergência aberta',
                style: TextStyle(
                  color: CoresCamda.ambar,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final a in abertas)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 2),
              child: Text(
                a.descricao,
                style: const TextStyle(
                    color: CoresCamda.textoFraco, fontSize: 12.5),
              ),
            ),
        ],
      ),
    );
  }
}

class _EscolhaModo extends StatelessWidget {
  final bool confirmarApenas;
  final ValueChanged<bool> onChanged;

  const _EscolhaModo({required this.confirmarApenas, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _OpcaoModo(
          titulo: 'Confirmar a que já existe',
          subtitulo: 'Não cria registro novo',
          selecionado: confirmarApenas,
          onTap: () => onChanged(true),
        ),
        const SizedBox(height: 6),
        _OpcaoModo(
          titulo: 'Registrar divergência adicional',
          subtitulo: 'Soma ao total do produto',
          selecionado: !confirmarApenas,
          onTap: () => onChanged(false),
        ),
      ],
    );
  }
}

class _OpcaoModo extends StatelessWidget {
  final String titulo;
  final String subtitulo;
  final bool selecionado;
  final VoidCallback onTap;

  const _OpcaoModo({
    required this.titulo,
    required this.subtitulo,
    required this.selecionado,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selecionado
              ? CoresCamda.azul.withValues(alpha: 0.10)
              : Colors.transparent,
          border: Border.all(
            color: selecionado ? CoresCamda.azul : CoresCamda.borda,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(
              selecionado
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selecionado ? CoresCamda.azul : CoresCamda.textoApagado,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titulo,
                    style: const TextStyle(
                      color: CoresCamda.texto,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    subtitulo,
                    style: const TextStyle(
                      color: CoresCamda.textoApagado,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
