import 'package:contagem_camda/agrupamento.dart';
import 'package:flutter_test/flutter_test.dart';

/// O agrupamento de códigos é a diferença entre "conte 84 unidades" e
/// "conte 11 unidades" no card de um produto que tem 84 na prateleira. Errar
/// aqui não quebra nada visivelmente: gera uma divergência falsa de 73
/// unidades, gravada direto no estoque.
///
/// Os dois casos nomeados abaixo são reais, tirados do banco da CAMDA.

LinhaContagem _linha(int id, String codigo, int qtd,
        {String produto = 'PRODUTO', String categoria = 'CAT'}) =>
    LinhaContagem(
      id: id,
      codigo: codigo,
      produto: produto,
      categoria: categoria,
      qtdEstoque: qtd,
      status: StatusContagem.pendente,
    );

LinhaMestre _mestre(String codigo, int qtd, {String produto = 'PRODUTO'}) =>
    LinhaMestre(codigo: codigo, produto: produto, qtdSistema: qtd);

void main() {
  group('chaveNome', () {
    test('ignora acento, caixa e espaço repetido', () {
      expect(chaveNome('  Herbicida  Últimato SC 20L '),
          chaveNome('HERBICIDA ULTIMATO SC 20L'));
    });
  });

  group('PHOSFIX — prefixo US', () {
    // 222534 (11) + US222534 (73) = 84. Só o 222534 está na contagem.
    final linhas = [_linha(1, '222534', 11, produto: 'ADJUVANTE PHOSFIX NORTOX 5L')];
    final mestre = [
      _mestre('222534', 11, produto: 'ADJUVANTE PHOSFIX NORTOX 5L'),
      _mestre('US222534', 73, produto: 'ADJUVANTE PHOSFIX NORTOX 5L'),
    ];

    test('soma o irmão que nem está na lista de contagem', () {
      final itens = agruparItens(linhas: linhas, mestre: mestre);
      expect(itens, hasLength(1));
      expect(itens.single.qtdEstoque, 84);
    });

    test('mostra os dois códigos, o pedido primeiro', () {
      final item = agruparItens(linhas: linhas, mestre: mestre).single;
      expect(item.codigos.map((c) => c.codigo), ['222534', 'US222534']);
      expect(item.codigos.first.naLista, isTrue);
      expect(item.codigos.last.naLista, isFalse);
    });

    test('a âncora é o código de maior saldo, sem mapa', () {
      // Sem mapa_produtos, lançar a divergência no código que carrega 11 de
      // 84 unidades deixaria o saldo negativo à toa.
      final item = agruparItens(linhas: linhas, mestre: mestre).single;
      expect(item.codigoAncora, 'US222534');
    });

    test('avisa que o vínculo não veio do mapa', () {
      final item = agruparItens(linhas: linhas, mestre: mestre).single;
      expect(item.vinculadoNoMapa, isFalse);
    });
  });

  group('ULTIMATO — prefixo 100', () {
    // O scanner resolve o par pela convenção US, que NÃO cobre este caso.
    final linhas = [
      _linha(7, '237191', 40, produto: 'HERBICIDA ULTIMATO SC 20L'),
    ];
    final mestre = [
      _mestre('237191', 40, produto: 'HERBICIDA ULTIMATO SC 20L'),
      _mestre('100237191', 125, produto: 'HERBICIDA ULTIMATO SC 20L'),
    ];

    test('agrupa por nome, cobrindo um prefixo que não é US', () {
      final itens = agruparItens(linhas: linhas, mestre: mestre);
      expect(itens, hasLength(1));
      expect(itens.single.qtdEstoque, 165);
      expect(itens.single.codigos.map((c) => c.codigo),
          containsAll(['237191', '100237191']));
    });
  });

  group('mapa_produtos manda mais que o nome', () {
    test('agrupa códigos de nomes diferentes quando o mapa os vincula', () {
      final linhas = [_linha(1, 'A1', 5, produto: 'NOME VELHO')];
      final mestre = [
        _mestre('A1', 5, produto: 'NOME VELHO'),
        _mestre('B2', 9, produto: 'NOME NOVO DO MESMO PRODUTO'),
      ];
      const mapa = MapaProdutos(
        produtoPorCodigo: {'A1': 'P1', 'B2': 'P1'},
        principalPorProduto: {'P1': 'A1'},
      );

      final item = agruparItens(linhas: linhas, mestre: mestre, mapa: mapa).single;
      expect(item.qtdEstoque, 14);
      expect(item.vinculadoNoMapa, isTrue);
      // Com mapa, a âncora é o principal cadastrado — mesmo não sendo o de
      // maior saldo.
      expect(item.codigoAncora, 'A1');
    });

    test('não junta produtos de nomes iguais que o mapa separa', () {
      final linhas = [_linha(1, 'X1', 3, produto: 'GENERICO')];
      final mestre = [
        _mestre('X1', 3, produto: 'GENERICO'),
        _mestre('X2', 8, produto: 'GENERICO'),
      ];
      const mapa = MapaProdutos(
        produtoPorCodigo: {'X1': 'P1', 'X2': 'P2'},
        principalPorProduto: {'P1': 'X1', 'P2': 'X2'},
      );

      final item = agruparItens(linhas: linhas, mestre: mestre, mapa: mapa).single;
      expect(item.qtdEstoque, 3);
      expect(item.codigos, hasLength(1));
    });
  });

  group('os dois códigos na lista de contagem', () {
    final linhas = [
      _linha(1, '222534', 11, produto: 'PHOSFIX'),
      _linha(2, 'US222534', 73, produto: 'PHOSFIX'),
    ];
    final mestre = [
      _mestre('222534', 11, produto: 'PHOSFIX'),
      _mestre('US222534', 73, produto: 'PHOSFIX'),
    ];

    test('vira UM card, não dois', () {
      // Dois cards fariam o conferente contar a mesma pilha duas vezes.
      final itens = agruparItens(linhas: linhas, mestre: mestre);
      expect(itens, hasLength(1));
      expect(itens.single.qtdEstoque, 84);
    });

    test('carrega os dois ids, para confirmar os dois de uma vez', () {
      final item = agruparItens(linhas: linhas, mestre: mestre).single;
      expect(item.ids, [1, 2]);
      expect(item.codigosNaLista, ['222534', 'US222534']);
    });
  });

  group('status do grupo', () {
    LinhaContagem com(int id, String cod, StatusContagem s) => LinhaContagem(
          id: id,
          codigo: cod,
          produto: 'P',
          categoria: 'C',
          qtdEstoque: 1,
          status: s,
        );

    final mestre = [_mestre('A', 1, produto: 'P'), _mestre('B', 1, produto: 'P')];

    test('uma linha pendente mantém o card pendente', () {
      final itens = agruparItens(
        linhas: [
          com(1, 'A', StatusContagem.certa),
          com(2, 'B', StatusContagem.pendente),
        ],
        mestre: mestre,
      );
      expect(itens.single.status, StatusContagem.pendente);
    });

    test('divergência manda sobre certa quando nada está pendente', () {
      final itens = agruparItens(
        linhas: [
          com(1, 'A', StatusContagem.certa),
          com(2, 'B', StatusContagem.divergencia),
        ],
        mestre: mestre,
      );
      expect(itens.single.status, StatusContagem.divergencia);
    });
  });

  group('saldo atual do estoque_mestre', () {
    test('a foto velha da lista de contagem não manda no saldo', () {
      // Entrou na lista com 40; depois o upload de vendas baixou o mestre
      // para 32. O card tem de mostrar 32, como o scanner.
      final itens = agruparItens(
        linhas: [_linha(1, '237191', 40, produto: 'ULTIMATO')],
        mestre: [_mestre('237191', 32, produto: 'ULTIMATO')],
      );
      expect(itens.single.qtdEstoque, 32);
      expect(itens.single.codigos.single.quantidade, 32);
    });

    test('vale também para os dois códigos na lista', () {
      final itens = agruparItens(
        linhas: [
          _linha(1, '222534', 11, produto: 'PHOSFIX'),
          _linha(2, 'US222534', 73, produto: 'PHOSFIX'),
        ],
        mestre: [
          _mestre('222534', 9, produto: 'PHOSFIX'),
          _mestre('US222534', 70, produto: 'PHOSFIX'),
        ],
      );
      expect(itens.single.qtdEstoque, 79);
    });
  });

  group('casos de borda', () {
    test('produto sem irmão continua com o próprio saldo', () {
      final itens = agruparItens(
        linhas: [_linha(1, 'SOZINHO', 7, produto: 'UNICO')],
        mestre: [_mestre('SOZINHO', 7, produto: 'UNICO')],
      );
      expect(itens.single.qtdEstoque, 7);
      expect(itens.single.temVariosCodigos, isFalse);
    });

    test('código sem linha em estoque_mestre não some da lista', () {
      // Produto novo, ainda não no mestre: tem de aparecer para conferência.
      final itens = agruparItens(
        linhas: [_linha(1, 'NOVO', 4, produto: 'RECEM CHEGADO')],
        mestre: const [],
      );
      expect(itens, hasLength(1));
      expect(itens.single.qtdEstoque, 4);
      expect(itens.single.codigoAncora, 'NOVO');
    });

    test('nome vazio deixa o produto sozinho, sem juntar com outros', () {
      final itens = agruparItens(
        linhas: [_linha(1, 'C1', 2, produto: '')],
        mestre: [_mestre('C1', 2, produto: ''), _mestre('C2', 90, produto: '')],
      );
      // Nome vazio não é sinal de parentesco — juntar aqui somaria produtos
      // sem relação nenhuma.
      expect(itens.single.qtdEstoque, 2);
    });

    test('caixa e espaço no código não criam grupos separados', () {
      final itens = agruparItens(
        linhas: [_linha(1, ' us222534 ', 73, produto: 'PHOSFIX')],
        mestre: [
          _mestre('US222534', 73, produto: 'PHOSFIX'),
          _mestre('222534', 11, produto: 'PHOSFIX'),
        ],
      );
      expect(itens.single.qtdEstoque, 84);
      expect(itens.single.codigos.map((c) => c.codigo),
          containsAll(['US222534', '222534']));
    });

    test('a lista preserva a ordem que veio do banco', () {
      final itens = agruparItens(
        linhas: [
          _linha(1, 'B', 1, produto: 'BETA', categoria: 'X'),
          _linha(2, 'A', 1, produto: 'ALFA', categoria: 'X'),
        ],
        mestre: [_mestre('B', 1, produto: 'BETA'), _mestre('A', 1, produto: 'ALFA')],
      );
      expect(itens.map((i) => i.produto), ['BETA', 'ALFA']);
    });
  });
}
