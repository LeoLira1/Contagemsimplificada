import 'package:contagem_camda/contagem_service.dart';
import 'package:contagem_camda/enderecos.dart';
import 'package:contagem_camda/item_card.dart';
import 'package:contagem_camda/tema.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ItemContagem _item({
  List<EnderecoProduto> enderecos = const [],
  String motivo = '',
  String observacoes = '',
  List<CodigoDoGrupo> codigos = const [
    CodigoDoGrupo(codigo: '10432', quantidade: 24, naLista: true),
  ],
  bool vinculadoNoMapa = true,
}) =>
    ItemContagem(
      ids: const [1],
      codigoAncora: codigos.first.codigo,
      codigos: codigos,
      vinculadoNoMapa: vinculadoNoMapa,
      produto: 'GLIFOSATO 480 SL 20L',
      categoria: 'HERBICIDAS',
      qtdEstoque: codigos.fold(0, (s, c) => s + c.quantidade),
      status: StatusContagem.pendente,
      motivo: motivo,
      observacoes: observacoes,
      enderecos: enderecos,
    );

Widget _envolver(Widget filho) => MaterialApp(
      theme: temaCamda(),
      home: Scaffold(body: SingleChildScrollView(child: filho)),
    );

void main() {
  testWidgets('mostra as quatro linhas do card: nome, código, local e qtd',
      (tester) async {
    await tester.pumpWidget(_envolver(ItemCard(
      item: _item(enderecos: const [
        EnderecoProduto(
          produtoCodigo: '10432',
          localTipo: 'estante',
          localNum: 8,
          faceOuColuna: 0,
          andarOuNivel: 5,
          quantidade: 12,
        ),
      ]),
      onCerta: () {},
      onDivergencia: () {},
    )));

    expect(find.textContaining('GLIFOSATO 480 SL 20L'), findsOneWidget);
    expect(find.textContaining('10432'), findsOneWidget);
    expect(find.text('ESTANTE 8'), findsOneWidget);
    expect(find.textContaining('Posição A'), findsOneWidget);
    expect(find.text('24'), findsOneWidget);
  });

  testWidgets('avisa quando o produto não tem endereço cadastrado',
      (tester) async {
    await tester.pumpWidget(_envolver(ItemCard(
      item: _item(),
      onCerta: () {},
      onDivergencia: () {},
    )));

    expect(find.text('SEM ENDEREÇO CADASTRADO'), findsOneWidget);
  });

  testWidgets('lista os endereços extras em vez de esconder', (tester) async {
    // Produto em dois lugares: mandar o conferente só ao primeiro faria a
    // contagem sair errada por omissão.
    await tester.pumpWidget(_envolver(ItemCard(
      item: _item(enderecos: const [
        EnderecoProduto(
          produtoCodigo: '10432',
          localTipo: 'gondola',
          localNum: 9,
          faceOuColuna: 3,
          andarOuNivel: 1,
        ),
        EnderecoProduto(
          produtoCodigo: '10432',
          localTipo: 'estante',
          localNum: 8,
          faceOuColuna: 0,
          andarOuNivel: 5,
        ),
      ]),
      onCerta: () {},
      onDivergencia: () {},
    )));

    expect(find.text('GÔNDOLA 9'), findsOneWidget);
    expect(find.textContaining('Face 3 · Andar Meio'), findsOneWidget);
    expect(find.text('E8·A'), findsOneWidget);
  });

  testWidgets('endereço de estante removida vira aviso, não destino',
      (tester) async {
    await tester.pumpWidget(_envolver(ItemCard(
      item: _item(enderecos: const [
        EnderecoProduto(
          produtoCodigo: '10432',
          localTipo: 'estante',
          localNum: 3,
          faceOuColuna: 0,
          andarOuNivel: 0,
        ),
      ]),
      onCerta: () {},
      onDivergencia: () {},
    )));

    // A estante 3 saiu da loja: não pode aparecer como local válido.
    expect(find.text('ESTANTE 3'), findsNothing);
    expect(find.text('SEM ENDEREÇO CADASTRADO'), findsOneWidget);
    expect(find.textContaining('saiu da loja'), findsOneWidget);
  });

  testWidgets('os dois botões disparam os callbacks', (tester) async {
    var certas = 0;
    var divergencias = 0;

    await tester.pumpWidget(_envolver(ItemCard(
      item: _item(),
      onCerta: () => certas++,
      onDivergencia: () => divergencias++,
    )));

    await tester.tap(find.text('OK'));
    await tester.tap(find.byIcon(Icons.report_gmailerrorred_outlined));
    await tester.pump();

    expect(certas, 1);
    expect(divergencias, 1);
  });

  testWidgets('card ocupado não aceita toque enquanto grava', (tester) async {
    var certas = 0;

    await tester.pumpWidget(_envolver(ItemCard(
      item: _item(),
      ocupado: true,
      onCerta: () => certas++,
      onDivergencia: () {},
    )));

    await tester.tap(find.text('OK'));
    await tester.pump();

    expect(certas, 0);
  });

  testWidgets('PHOSFIX: mostra o total somado e as parcelas', (tester) async {
    // 11 na lista + 73 do código irmão. Se o card mostrar 11, o conferente
    // conta 84 na prateleira e registra uma falta de 73 que não existe.
    await tester.pumpWidget(_envolver(ItemCard(
      item: _item(
        vinculadoNoMapa: false,
        codigos: const [
          CodigoDoGrupo(codigo: '222534', quantidade: 11, naLista: true),
          CodigoDoGrupo(codigo: 'US222534', quantidade: 73, naLista: false),
        ],
      ),
      onCerta: () {},
      onDivergencia: () {},
    )));

    expect(find.text('84'), findsOneWidget);
    expect(find.text('11 + 73'), findsOneWidget);
    expect(find.textContaining('222534 + US222534'), findsOneWidget);
    // Grupo montado por nome, sem vínculo no mapa: a tela tem de dizer que o
    // total pode estar incompleto, em vez de apresentá-lo como certeza.
    expect(find.textContaining('total pode estar incompleto'), findsOneWidget);
  });

  testWidgets('produto de código único não mostra soma', (tester) async {
    await tester.pumpWidget(_envolver(ItemCard(
      item: _item(),
      onCerta: () {},
      onDivergencia: () {},
    )));

    expect(find.text('24'), findsOneWidget);
    expect(find.textContaining('total pode estar incompleto'), findsNothing);
  });
}
