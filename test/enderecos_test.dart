import 'dart:math' as math;

import 'package:contagem_camda/enderecos.dart';
import 'package:flutter_test/flutter_test.dart';

/// Estes testes travam o porte do endereçamento feito a partir do app
/// Gôndolas (`leolira1/Gondolas`, `lib/models.dart`).
///
/// Não são testes de UI nem de banco: são o contrato de que "Posição H" neste
/// app é a MESMA prateleira que "H" no app das gôndolas e na etiqueta colada
/// no aço. Um erro aqui não quebra nada visivelmente — só manda o conferente
/// para o lugar errado, e a contagem sai errada sem ninguém perceber.
///
/// Os casos abaixo vêm dos comentários normativos do repositório Gôndolas:
/// Estante 3 vai de A a O, a 4 continua de P a AD, a Estante 6 usa A–F/G–L/M–R
/// por módulo, a Parede usa 1–72, o Nellore A–E/F–J/K–N/O–S/T–X, etc.
void main() {
  group('letraDoIndice', () {
    test('vai de A a Z e continua em duas letras', () {
      expect(letraDoIndice(0), 'A');
      expect(letraDoIndice(25), 'Z');
      expect(letraDoIndice(26), 'AA');
      expect(letraDoIndice(29), 'AD');
    });
  });

  group('Estantes de madeira', () {
    test('estante padrão: 4 níveis × 3 colunas, contando de cima', () {
      // Nível mais alto (3) à esquerda é o A; o canto de baixo à direita é o L.
      expect(letraEstanteCelula(5, 0, 3), 'A');
      expect(letraEstanteCelula(5, 2, 3), 'C');
      expect(letraEstanteCelula(5, 0, 2), 'D');
      expect(letraEstanteCelula(5, 2, 0), 'L');
    });

    test('estante 3 usa os 5 níveis e termina no O', () {
      expect(letraEstanteCelula(3, 0, 4), 'A');
      expect(letraEstanteCelula(3, 2, 0), 'O');
    });

    test('estante 4 continua a sequência da 3, de P a AD', () {
      // As duas ficam coladas na loja, então não podem repetir letra.
      expect(letraEstanteCelula(4, 0, 4), 'P');
      expect(letraEstanteCelula(4, 2, 0), 'AD');
    });
  });

  group('Estantes EDR-300 de aço', () {
    test('estante 8: coluna única, 6 prateleiras, A em cima e F embaixo', () {
      expect(letraEstanteCelula(8, 0, 5), 'A');
      expect(letraEstanteCelula(8, 0, 0), 'F');
    });

    test('estante 6: letras contínuas por módulo — A–F, G–L, M–R', () {
      expect(letraEstanteCelula(6, 0, 5), 'A');
      expect(letraEstanteCelula(6, 0, 0), 'F');
      expect(letraEstanteCelula(6, 1, 5), 'G');
      expect(letraEstanteCelula(6, 2, 5), 'M');
      expect(letraEstanteCelula(6, 2, 0), 'R');
    });
  });

  group('Estante Parede', () {
    test('numeração física contínua de 1 a 72 pelas seções 13–18', () {
      expect(letraEstanteCelula(13, 0, 5), '1');
      expect(letraEstanteCelula(13, 0, 0), '6');
      expect(letraEstanteCelula(13, 1, 5), '7');
      expect(letraEstanteCelula(14, 0, 5), '13');
      expect(letraEstanteCelula(18, 1, 0), '72');
    });

    test('as seis seções são reconhecidas como parede', () {
      for (var n = 13; n <= 18; n++) {
        expect(ehEstanteParede(n), isTrue, reason: 'seção $n');
      }
      expect(ehEstanteParede(12), isFalse);
      expect(ehEstanteParede(19), isFalse);
    });
  });

  group('Expositores', () {
    test('MagnoJet: base numérica, ganchos A–X, intercalados com sufixo 1', () {
      expect(letraEstanteCelula(9, 0, nivelBaseMagnojet), '1');
      expect(letraEstanteCelula(9, 4, nivelBaseMagnojet), '5');
      expect(letraEstanteCelula(9, 0, 5), 'A');
      expect(letraEstanteCelula(9, 3, 0), 'X');
      // Coluna 4 é o gancho intercalado à direita da primária 0 (A).
      expect(letraEstanteCelula(9, 4, 5), 'A1');
    });

    test('Nellore: A–E, F–J (ganchos), K–N (cestos), O–S e T–X (prateleiras)',
        () {
      expect(letraEstanteCelula(19, 0, 5), 'A');
      expect(letraEstanteCelula(19, 0, 4), 'F');
      expect(letraEstanteCelula(19, 0, 3), 'K');
      expect(letraEstanteCelula(19, 3, 3), 'N'); // cesto tem só 4 colunas
      expect(letraEstanteCelula(19, 0, 2), 'O');
      expect(letraEstanteCelula(19, 4, 1), 'X');
    });

    test('Monitor: base 1–5 e prateleiras A–E, F–J, K–O', () {
      expect(letraEstanteCelula(20, 0, 0), '1');
      expect(letraEstanteCelula(20, 0, 3), 'A');
      expect(letraEstanteCelula(20, 4, 3), 'E');
      expect(letraEstanteCelula(20, 0, 2), 'F');
      expect(letraEstanteCelula(20, 4, 1), 'O');
    });
  });

  group('Paletes', () {
    test('grade horizontal: 1–5 na frente, 6–10 no meio, 11–15 no fundo', () {
      expect(ehPalete(101), isTrue);
      expect(ehPalete(100), isFalse);
      expect(letraEstanteCelula(101, 0, 0), '1');
      expect(letraEstanteCelula(101, 4, 0), '5');
      expect(letraEstanteCelula(101, 0, 1), '6');
      expect(letraEstanteCelula(101, 4, 2), '15');
    });
  });

  group('faceFromPos', () {
    test('face 1 é a voltada para a entrada (+Z)', () {
      expect(faceFromPos(0, 1), 1);
    });

    test('as seis faces cobrem a volta completa, sem furo nem repetição', () {
      final faces = <int>{};
      for (var i = 0; i < 6; i++) {
        // Ponto no meio de cada face, no raio 1.
        final ang = (90 - i * 60) * math.pi / 180;
        faces.add(faceFromPos(math.cos(ang), math.sin(ang)));
      }
      expect(faces, {1, 2, 3, 4, 5, 6});
    });
  });

  group('Nomes das estruturas', () {
    test('gôndola, estante, palete e parede', () {
      expect(nomeEstrutura('gondola', 7), 'Gôndola 7');
      expect(nomeEstrutura('estante', 5), 'Estante 5');
      expect(nomeEstrutura('estante', 101), 'Palete 101');
      expect(nomeEstrutura('estante', 15), 'Estante Parede 15');
    });

    test('os três expositores têm nome próprio, não "Estante 9"', () {
      expect(nomeEstrutura('estante', 9), 'Expositor MagnoJet');
      expect(nomeEstrutura('estante', 19), 'Expositor Nellore');
      expect(nomeEstrutura('estante', 20), 'Expositor Monitor');
    });

    test('rótulo curto acompanha a etiqueta da loja', () {
      expect(rotuloCurtoEstrutura('gondola', 7), 'G7');
      expect(rotuloCurtoEstrutura('estante', 5), 'E5');
      expect(rotuloCurtoEstrutura('estante', 102), 'P102');
    });
  });

  group('EnderecoProduto', () {
    test('gôndola mostra face e andar por extenso', () {
      const e = EnderecoProduto(
        produtoCodigo: '1234',
        localTipo: 'gondola',
        localNum: 9,
        faceOuColuna: 3,
        andarOuNivel: 1,
      );
      expect(e.estrutura, 'Gôndola 9');
      expect(e.posicao, 'Face 3 · Andar Meio');
      expect(e.compacto, 'G9·F3·A2');
      expect(e.removido, isFalse);
    });

    test('estante mostra a posição etiquetada', () {
      const e = EnderecoProduto(
        produtoCodigo: '1234',
        localTipo: 'estante',
        localNum: 8,
        faceOuColuna: 0,
        andarOuNivel: 5,
        quantidade: 12,
      );
      expect(e.estrutura, 'Estante 8');
      expect(e.posicao, 'Posição A');
      expect(e.compacto, 'E8·A');
    });

    test('estante que saiu da loja é marcada como removida', () {
      // As estantes 3 e 4 foram substituídas pela Estante Parede; endereços
      // antigos continuam no banco e não podem virar destino de conferência.
      for (final num in estantesRemovidas) {
        final e = EnderecoProduto(
          produtoCodigo: '1234',
          localTipo: 'estante',
          localNum: num,
          faceOuColuna: 0,
          andarOuNivel: 0,
        );
        expect(e.removido, isTrue, reason: 'estante $num');
      }
    });

    test('a chave distingue endereços diferentes do mesmo produto', () {
      const a = EnderecoProduto(
        produtoCodigo: '1234',
        localTipo: 'estante',
        localNum: 5,
        faceOuColuna: 0,
        andarOuNivel: 1,
      );
      const b = EnderecoProduto(
        produtoCodigo: '1234',
        localTipo: 'estante',
        localNum: 5,
        faceOuColuna: 1,
        andarOuNivel: 1,
      );
      expect(a.chave, isNot(b.chave));
    });
  });
}
