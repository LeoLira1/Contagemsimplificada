import 'package:flutter/material.dart';

import 'config_page.dart';
import 'contagem_service.dart';
import 'divergencia_sheet.dart';
import 'item_card.dart';
import 'tema.dart';
import 'turso_service.dart';

/// Como a lista é agrupada.
enum Agrupamento {
  /// Por categoria — mesma ordem da aba Contagem do dashboard.
  categoria,

  /// Por local físico — a ordem de quem anda pela loja com o celular na mão.
  /// É o que justifica cruzar a contagem com o app Gôndolas: conferir um
  /// corredor inteiro antes de ir para o próximo, em vez de atravessar a loja
  /// a cada item porque a lista veio ordenada por categoria.
  local,
}

/// Quais itens estão à vista.
enum Filtro { pendentes, conferidos }

class ContagemPage extends StatefulWidget {
  const ContagemPage({super.key});

  @override
  State<ContagemPage> createState() => _ContagemPageState();
}

class _ContagemPageState extends State<ContagemPage>
    with WidgetsBindingObserver {
  ListaContagem _lista = ListaContagem.vazia;
  bool _carregando = true;
  String? _erro;

  Agrupamento _agrupamento = Agrupamento.categoria;
  Filtro _filtro = Filtro.pendentes;
  String _busca = '';

  /// Ids com gravação em andamento — trava os botões daquele card.
  final Set<int> _gravando = {};

  final _buscaCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _carregar();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _buscaCtrl.dispose();
    super.dispose();
  }

  /// O Android devolve o app minimizado com a lista de quando ele foi aberto.
  /// Se o dashboard subiu planilha nesse meio-tempo, o conferente contaria
  /// em cima de saldo velho — então recarrega ao voltar para a frente. Não
  /// recarrega no meio de uma gravação, para não trocar o card embaixo dela.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        !_carregando &&
        _gravando.isEmpty) {
      _carregar();
    }
  }

  Future<void> _carregar() async {
    setState(() {
      _carregando = true;
      _erro = null;
    });

    final conectou = await TursoService().garantirConexao();
    if (!mounted) return;

    if (!conectou) {
      setState(() {
        _carregando = false;
        _erro = TursoService().ultimoErro ?? 'Não foi possível conectar.';
      });
      return;
    }

    try {
      final lista = await ContagemService().carregar();
      if (!mounted) return;
      setState(() {
        _lista = lista;
        _carregando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _carregando = false;
        _erro = 'Falha ao carregar a lista: $e';
      });
    }
  }

  void _aplicarStatus(ItemContagem item, StatusContagem novo) {
    setState(() {
      final itens = _lista.itens
          .map((i) => i.id == item.id ? i.comStatus(novo) : i)
          .toList();
      _lista = ListaContagem(
        itens: itens,
        resumo: ResumoContagem(
          total: itens.length,
          certas: itens.where((i) => i.status == StatusContagem.certa).length,
          divergencias: itens
              .where((i) => i.status == StatusContagem.divergencia)
              .length,
          pendentes:
              itens.where((i) => i.status == StatusContagem.pendente).length,
        ),
      );
    });
  }

  void _avisar(String texto, {bool erro = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(texto),
        duration: Duration(seconds: erro ? 5 : 2),
        backgroundColor:
            erro ? CoresCamda.vermelho.withValues(alpha: 0.92) : null,
      ));
  }

  Future<void> _confirmarCerta(ItemContagem item) async {
    setState(() => _gravando.add(item.id));
    final ok = await ContagemService().confirmarCerta(item);
    if (!mounted) return;
    setState(() => _gravando.remove(item.id));

    if (!ok) {
      _avisar('Não deu para salvar "${item.produto}". Verifique a conexão e '
          'tente de novo.', erro: true);
      return;
    }
    _aplicarStatus(item, StatusContagem.certa);
    _avisar('${item.produto} conferido ✓');
  }

  Future<void> _abrirDivergencia(ItemContagem item) async {
    final resultado = await abrirFolhaDivergencia(context, item);
    if (resultado == null || !mounted) return;

    setState(() => _gravando.add(item.id));
    final ok = await ContagemService().registrarDivergencia(
      item: item,
      qtdDivergindo: resultado.qtdDivergindo,
      sobra: resultado.sobra,
      motivo: resultado.motivo,
      confirmarApenas: resultado.confirmarApenas,
    );
    if (!mounted) return;
    setState(() => _gravando.remove(item.id));

    if (!ok) {
      _avisar('Não deu para registrar a divergência de "${item.produto}". '
          'Verifique a conexão e tente de novo.', erro: true);
      return;
    }
    _aplicarStatus(item, StatusContagem.divergencia);
    _avisar(
      '${resultado.sobra ? "Sobra" : "Falta"} de ${resultado.qtdDivergindo} un '
      'registrada em ${item.produto}',
    );
  }

  Future<void> _abrirConfig() async {
    final mudou = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const ConfigPage()),
    );
    if (mudou == true) await _carregar();
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Recorte e agrupamento
  // ───────────────────────────────────────────────────────────────────────────

  List<ItemContagem> get _itensVisiveis {
    final termo = _busca.trim().toLowerCase();
    return _lista.itens.where((i) {
      final combinaFiltro = _filtro == Filtro.pendentes
          ? i.status == StatusContagem.pendente
          : i.status != StatusContagem.pendente;
      if (!combinaFiltro) return false;
      if (termo.isEmpty) return true;
      // Busca também pelo endereço: "e5" acha tudo que está na estante 5, que
      // é como o conferente pensa quando está parado na frente dela.
      return i.produto.toLowerCase().contains(termo) ||
          i.codigos.any((c) => c.codigo.toLowerCase().contains(termo)) ||
          i.categoria.toLowerCase().contains(termo) ||
          i.enderecosValidos.any((e) =>
              e.compacto.toLowerCase().contains(termo) ||
              e.estrutura.toLowerCase().contains(termo));
    }).toList();
  }

  /// Agrupa preservando a ordem que veio do banco dentro de cada grupo.
  List<(String, List<ItemContagem>)> _agrupar(List<ItemContagem> itens) {
    final grupos = <String, List<ItemContagem>>{};

    for (final item in itens) {
      final chave = _agrupamento == Agrupamento.categoria
          ? (item.categoria.isEmpty ? 'SEM CATEGORIA' : item.categoria)
          : _grupoLocalDe(item);
      grupos.putIfAbsent(chave, () => []).add(item);
    }

    final chaves = grupos.keys.toList()..sort(_compararGrupos);
    return [for (final c in chaves) (c, grupos[c]!)];
  }

  /// Nome do grupo por local — a estrutura do primeiro endereço válido. Os
  /// sem endereço vão para um grupo próprio, no fim: o conferente precisa
  /// procurá-los, então não devem se misturar a um corredor definido.
  String _grupoLocalDe(ItemContagem item) {
    final enderecos = item.enderecosValidos;
    if (enderecos.isEmpty) return _grupoSemEndereco;
    return enderecos.first.estrutura;
  }

  static const _grupoSemEndereco = 'Sem endereço cadastrado';

  int _compararGrupos(String a, String b) {
    if (_agrupamento == Agrupamento.categoria) return a.compareTo(b);
    // Por local: gôndolas primeiro (é onde se entra na loja), depois o resto
    // em ordem alfabética, e os sem endereço sempre por último.
    if (a == _grupoSemEndereco) return 1;
    if (b == _grupoSemEndereco) return -1;
    final aGondola = a.startsWith('Gôndola');
    final bGondola = b.startsWith('Gôndola');
    if (aGondola != bGondola) return aGondola ? -1 : 1;
    // "Gôndola 10" depois de "Gôndola 9": compara o número quando os prefixos
    // são iguais, senão a ordem alfabética joga o 10 antes do 2.
    final numA = _numeroFinal(a);
    final numB = _numeroFinal(b);
    if (numA != null && numB != null) {
      final prefA = a.substring(0, a.length - numA.toString().length);
      final prefB = b.substring(0, b.length - numB.toString().length);
      if (prefA == prefB) return numA.compareTo(numB);
    }
    return a.compareTo(b);
  }

  static int? _numeroFinal(String s) {
    final m = RegExp(r'(\d+)$').firstMatch(s);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  // ───────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Contagem',
          style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.3),
        ),
        actions: [
          IconButton(
            onPressed: _carregando ? null : _carregar,
            icon: const Icon(Icons.refresh),
            tooltip: 'Recarregar do banco',
          ),
          IconButton(
            onPressed: _abrirConfig,
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Conexão',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _carregar,
        color: CoresCamda.verde,
        backgroundColor: CoresCamda.superficie,
        child: _corpo(),
      ),
    );
  }

  Widget _corpo() {
    if (_carregando && _lista.itens.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_erro != null) {
      return _EstadoVazio(
        icone: Icons.cloud_off,
        titulo: 'Sem conexão com o banco',
        detalhe: _erro!,
        acao: ('Tentar de novo', _carregar),
        acaoSecundaria: ('Configurar conexão', _abrirConfig),
      );
    }
    if (_lista.resumo.total == 0) {
      return _EstadoVazio(
        icone: Icons.inventory_2_outlined,
        titulo: 'Nenhuma contagem em aberto',
        detalhe: 'A lista é montada no dashboard, ao enviar uma planilha '
            'parcial. Assim que ela existir, aparece aqui.',
        acao: ('Recarregar', _carregar),
      );
    }

    final visiveis = _itensVisiveis;
    final grupos = _agrupar(visiveis);

    return CustomScrollView(
      // Garante que o "puxar para atualizar" funcione mesmo com a lista curta.
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
            child: Column(
              children: [
                _BarraResumo(resumo: _lista.resumo),
                const SizedBox(height: 12),
                TextField(
                  controller: _buscaCtrl,
                  onChanged: (v) => setState(() => _busca = v),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Buscar produto, código ou local (ex: E5)',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    suffixIcon: _busca.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _buscaCtrl.clear();
                              setState(() => _busca = '');
                            },
                          ),
                  ),
                ),
                const SizedBox(height: 10),
                _BarraControles(
                  filtro: _filtro,
                  agrupamento: _agrupamento,
                  onFiltro: (f) => setState(() => _filtro = f),
                  onAgrupamento: (a) => setState(() => _agrupamento = a),
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ),
        if (_lista.resumo.concluida && _filtro == Filtro.pendentes)
          const SliverToBoxAdapter(child: _BannerConcluida()),
        if (visiveis.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EstadoVazio(
              icone: _filtro == Filtro.pendentes
                  ? Icons.task_alt
                  : Icons.hourglass_empty,
              titulo: _busca.isNotEmpty
                  ? 'Nada encontrado para "$_busca"'
                  : _filtro == Filtro.pendentes
                      ? 'Nenhum item pendente'
                      : 'Nenhum item conferido ainda',
              detalhe: _busca.isNotEmpty
                  ? 'Tente outro nome, código ou local.'
                  : _filtro == Filtro.pendentes
                      ? 'Tudo desta lista já foi conferido.'
                      : 'Confira alguns itens para eles aparecerem aqui.',
            ),
          )
        else
          for (final (titulo, itens) in grupos) ...[
            SliverToBoxAdapter(
              child: _CabecalhoGrupo(
                titulo: titulo,
                quantidade: itens.length,
                porLocal: _agrupamento == Agrupamento.local,
              ),
            ),
            SliverList.builder(
              itemCount: itens.length,
              itemBuilder: (context, i) {
                final item = itens[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: item.status == StatusContagem.pendente
                      ? ItemCard(
                          item: item,
                          ocupado: _gravando.contains(item.id),
                          onCerta: () => _confirmarCerta(item),
                          onDivergencia: () => _abrirDivergencia(item),
                        )
                      : _CardConferido(item: item),
                );
              },
            ),
          ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pedaços da tela
// ─────────────────────────────────────────────────────────────────────────────

class _BarraResumo extends StatelessWidget {
  final ResumoContagem resumo;

  const _BarraResumo({required this.resumo});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Contador(
            valor: resumo.pendentes, rotulo: 'Pendentes', cor: CoresCamda.ambar),
        const SizedBox(width: 8),
        _Contador(valor: resumo.certas, rotulo: 'Certas', cor: CoresCamda.verde),
        const SizedBox(width: 8),
        _Contador(
            valor: resumo.divergencias,
            rotulo: 'Divergências',
            cor: CoresCamda.vermelho),
        const SizedBox(width: 8),
        _Contador(
            valor: resumo.total, rotulo: 'Total', cor: CoresCamda.textoFraco),
      ],
    );
  }
}

class _Contador extends StatelessWidget {
  final int valor;
  final String rotulo;
  final Color cor;

  const _Contador({
    required this.valor,
    required this.rotulo,
    required this.cor,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: CoresCamda.superficie,
          border: Border.all(color: CoresCamda.borda),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            Text(
              '$valor',
              style: TextStyle(
                color: cor,
                fontSize: 19,
                fontWeight: FontWeight.w800,
                fontFamily: 'monospace',
                height: 1.1,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              rotulo.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: CoresCamda.textoApagado,
                fontSize: 8.5,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BarraControles extends StatelessWidget {
  final Filtro filtro;
  final Agrupamento agrupamento;
  final ValueChanged<Filtro> onFiltro;
  final ValueChanged<Agrupamento> onAgrupamento;

  const _BarraControles({
    required this.filtro,
    required this.agrupamento,
    required this.onFiltro,
    required this.onAgrupamento,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Alternador(
          opcoes: const ['Pendentes', 'Conferidos'],
          selecionado: filtro == Filtro.pendentes ? 0 : 1,
          onSelecionar: (i) =>
              onFiltro(i == 0 ? Filtro.pendentes : Filtro.conferidos),
        ),
        const Spacer(),
        _Alternador(
          opcoes: const ['Categoria', 'Local'],
          icones: const [Icons.category_outlined, Icons.place_outlined],
          selecionado: agrupamento == Agrupamento.categoria ? 0 : 1,
          onSelecionar: (i) => onAgrupamento(
              i == 0 ? Agrupamento.categoria : Agrupamento.local),
        ),
      ],
    );
  }
}

class _Alternador extends StatelessWidget {
  final List<String> opcoes;
  final List<IconData>? icones;
  final int selecionado;
  final ValueChanged<int> onSelecionar;

  const _Alternador({
    required this.opcoes,
    required this.selecionado,
    required this.onSelecionar,
    this.icones,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CoresCamda.superficie,
        border: Border.all(color: CoresCamda.borda),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < opcoes.length; i++)
            InkWell(
              onTap: () => onSelecionar(i),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                decoration: BoxDecoration(
                  color: i == selecionado
                      ? CoresCamda.azul.withValues(alpha: 0.18)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icones != null) ...[
                      Icon(
                        icones![i],
                        size: 14,
                        color: i == selecionado
                            ? CoresCamda.azul
                            : CoresCamda.textoApagado,
                      ),
                      const SizedBox(width: 5),
                    ],
                    Text(
                      opcoes[i],
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            i == selecionado ? FontWeight.w700 : FontWeight.w500,
                        color: i == selecionado
                            ? CoresCamda.azul
                            : CoresCamda.textoApagado,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CabecalhoGrupo extends StatelessWidget {
  final String titulo;
  final int quantidade;
  final bool porLocal;

  const _CabecalhoGrupo({
    required this.titulo,
    required this.quantidade,
    required this.porLocal,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          if (porLocal) ...[
            const Icon(Icons.place_outlined,
                size: 13, color: CoresCamda.textoApagado),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              titulo.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: CoresCamda.textoApagado,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$quantidade',
            style: const TextStyle(
              color: CoresCamda.textoApagado,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(child: Divider(color: CoresCamda.borda)),
        ],
      ),
    );
  }
}

/// Card compacto de um item já conferido — sem botões, só o registro do que
/// foi decidido, para o conferente poder revisar sem risco de tocar de novo.
class _CardConferido extends StatelessWidget {
  final ItemContagem item;

  const _CardConferido({required this.item});

  @override
  Widget build(BuildContext context) {
    final divergente = item.status == StatusContagem.divergencia;
    final cor = divergente ? CoresCamda.vermelho : CoresCamda.verde;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cor.withValues(alpha: 0.06),
        border: Border.all(color: cor.withValues(alpha: 0.28)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(divergente ? Icons.report_gmailerrorred : Icons.check_circle,
              size: 19, color: cor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.produto,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: CoresCamda.texto,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${item.codigos.map((c) => c.codigo).join(" + ")}  ·  ${item.qtdEstoque} un'
                  '${item.enderecosValidos.isEmpty ? "" : "  ·  ${item.enderecosValidos.first.compacto}"}',
                  style: const TextStyle(
                    color: CoresCamda.textoApagado,
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          Text(
            divergente ? 'DIVERGÊNCIA' : 'OK',
            style: TextStyle(
              color: cor,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _BannerConcluida extends StatelessWidget {
  const _BannerConcluida();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CoresCamda.verde.withValues(alpha: 0.10),
        border: Border.all(color: CoresCamda.verde.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Row(
        children: [
          Icon(Icons.celebration_outlined, color: CoresCamda.verde, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Contagem concluída! Encerre a lista pelo dashboard.',
              style: TextStyle(
                color: CoresCamda.verde,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EstadoVazio extends StatelessWidget {
  final IconData icone;
  final String titulo;
  final String detalhe;
  final (String, VoidCallback)? acao;
  final (String, VoidCallback)? acaoSecundaria;

  const _EstadoVazio({
    required this.icone,
    required this.titulo,
    required this.detalhe,
    this.acao,
    this.acaoSecundaria,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icone, size: 44, color: CoresCamda.textoApagado),
            const SizedBox(height: 14),
            Text(
              titulo,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: CoresCamda.texto,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              detalhe,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: CoresCamda.textoFraco,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            if (acao != null) ...[
              const SizedBox(height: 20),
              FilledButton(
                onPressed: acao!.$2,
                style: FilledButton.styleFrom(
                  backgroundColor: CoresCamda.verde,
                  foregroundColor: Colors.black,
                ),
                child: Text(acao!.$1),
              ),
            ],
            if (acaoSecundaria != null) ...[
              const SizedBox(height: 6),
              TextButton(
                onPressed: acaoSecundaria!.$2,
                style: TextButton.styleFrom(
                    foregroundColor: CoresCamda.textoFraco),
                child: Text(acaoSecundaria!.$1),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
