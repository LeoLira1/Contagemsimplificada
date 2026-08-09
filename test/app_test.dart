import 'package:contagem_camda/config_page.dart';
import 'package:contagem_camda/contagem_page.dart';
import 'package:contagem_camda/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Teste de fumaça da abertura. Além de checar a decisão "configuração ou
/// lista", ele compila o app inteiro num binário de teste — inclusive as
/// telas que os outros testes não tocam.
void main() {
  testWidgets('sem credenciais salvas, abre na configuração', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const AppContagem());
    await tester.pumpAndSettle();

    expect(find.byType(ConfigPage), findsOneWidget);
    expect(find.text('Contagem CAMDA'), findsOneWidget);
    expect(find.text('Testar e salvar'), findsOneWidget);
    // Sendo a tela raiz, não pode oferecer um "voltar" para lugar nenhum.
    expect(find.byType(BackButton), findsNothing);
  });

  testWidgets('com credenciais salvas, abre direto na lista', (tester) async {
    SharedPreferences.setMockInitialValues({
      'turso_db_url': 'libsql://exemplo.turso.io',
      'turso_db_token': 'token-de-teste',
    });

    await tester.pumpWidget(const AppContagem());
    await tester.pump();

    expect(find.byType(ContagemPage), findsOneWidget);

    // A conexão real falha no ambiente de teste; o que importa é que a tela
    // trate isso como estado de erro visível em vez de travar carregando.
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(ConfigPage), findsNothing);
  });
}
